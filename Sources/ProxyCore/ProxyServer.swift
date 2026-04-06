import Foundation
import CoreSecurity
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
import Protocol

public enum ProxyMode: Sendable {
    case passthrough
    case mitm
}

public enum UpstreamTLSVerification: Sendable {
    case fullVerification
    case noVerification
}

public struct ProxyServerConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var mode: ProxyMode
    public var upstreamTLSVerification: UpstreamTLSVerification

    public init(
        host: String = "127.0.0.1",
        port: Int = 9090,
        mode: ProxyMode = .passthrough,
        upstreamTLSVerification: UpstreamTLSVerification = .fullVerification
    ) {
        self.host = host
        self.port = port
        self.mode = mode
        self.upstreamTLSVerification = upstreamTLSVerification
    }
}

public enum ProxyServerError: Error, Sendable {
    case invalidConnectTarget(String)
    case unsupportedMethod(String)
    case mitmNotImplemented
}

public struct ConnectTarget: Sendable, Equatable {
    public let host: String
    public let port: Int

    public init?(authority: String) {
        let uri = authority.contains("://") ? authority : "http://\(authority)"
        guard
            let components = URLComponents(string: uri),
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }

        self.host = host
        self.port = components.port ?? 443
    }
}

public protocol MITMOrchestrating: Sendable {
    func startMITM(inboundChannel: Channel, target: ConnectTarget) -> EventLoopFuture<Void>
}

public struct NoopMITMOrchestrator: MITMOrchestrating {
    public init() {}

    public func startMITM(inboundChannel: Channel, target: ConnectTarget) -> EventLoopFuture<Void> {
        inboundChannel.eventLoop.makeFailedFuture(ProxyServerError.mitmNotImplemented)
    }
}

public final class ProxyServer {
    private let configuration: ProxyServerConfiguration
    private let sessionRegistry: ProxySessionRegistry
    private let mitmOrchestrator: any MITMOrchestrating
    private let group: MultiThreadedEventLoopGroup
    private let ownsGroup: Bool
    private var channel: Channel?

    public init(
        configuration: ProxyServerConfiguration,
        sessionRegistry: ProxySessionRegistry = ProxySessionRegistry(),
        mitmOrchestrator: (any MITMOrchestrating)? = nil,
        eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    ) {
        self.configuration = configuration
        self.sessionRegistry = sessionRegistry
        self.mitmOrchestrator = mitmOrchestrator
            ?? DefaultMITMOrchestrator(upstreamTLSVerification: configuration.upstreamTLSVerification)
        if let eventLoopGroup {
            self.group = eventLoopGroup
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            self.ownsGroup = true
        }
    }

    deinit {
        if ownsGroup {
            try? group.syncShutdownGracefully()
        }
    }

    public func start() async throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [configuration, sessionRegistry, mitmOrchestrator] channel in
                channel.pipeline.addHandler(
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                    name: HTTPPipelineNames.requestDecoder
                ).flatMap {
                    channel.pipeline.addHandler(HTTPResponseEncoder(), name: HTTPPipelineNames.responseEncoder)
                }.flatMap {
                    channel.pipeline.addHandler(
                        ConnectProxyHandler(
                            configuration: configuration,
                            sessionRegistry: sessionRegistry,
                            mitmOrchestrator: mitmOrchestrator
                        ),
                        name: HTTPPipelineNames.connectHandler
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        self.channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
    }

    public func stop() async throws {
        if let channel {
            try await channel.close().get()
            self.channel = nil
        }

        if ownsGroup {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                group.shutdownGracefully { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

private enum HTTPPipelineNames {
    static let requestDecoder = "proxy.request.decoder"
    static let responseEncoder = "proxy.response.encoder"
    static let connectHandler = "proxy.connect.handler"
}

private final class ConnectProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: ProxyServerConfiguration
    private let sessionRegistry: ProxySessionRegistry
    private let mitmOrchestrator: any MITMOrchestrating
    private var targetChannel: Channel?

    init(
        configuration: ProxyServerConfiguration,
        sessionRegistry: ProxySessionRegistry,
        mitmOrchestrator: any MITMOrchestrating
    ) {
        self.configuration = configuration
        self.sessionRegistry = sessionRegistry
        self.mitmOrchestrator = mitmOrchestrator
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            handleHead(head, context: context)
        case .body:
            break
        case .end:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        targetChannel?.close(mode: .all, promise: nil)
        context.fireChannelInactive()
    }

    private func handleHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        guard head.method == .CONNECT else {
            respondAndClose(
                context: context,
                status: .notImplemented,
                reason: "Only CONNECT is supported in this stage"
            )
            return
        }

        guard let connectTarget = ConnectTarget(authority: head.uri) else {
            respondAndClose(context: context, status: .badRequest, reason: "Invalid CONNECT authority")
            return
        }

        let registry = sessionRegistry
        let connectHost = connectTarget.host
        let connectPath = head.uri
        Task {
            await registry.register(
                ProxySession(host: connectHost, method: .connect, path: connectPath)
            )
        }

        switch configuration.mode {
        case .passthrough:
            establishTunnel(to: connectTarget, context: context)
        case .mitm:
            sendConnectionEstablished(context: context)
                .flatMap {
                    self.switchToMITM(context: context, target: connectTarget)
                }
                .whenFailure { _ in
                    self.respondAndClose(
                        context: context,
                        status: .badGateway,
                        reason: "MITM setup failed"
                    )
                }
        }
    }

    private func establishTunnel(to target: ConnectTarget, context: ChannelHandlerContext) {
        let outboundBootstrap = ClientBootstrap(group: context.eventLoop)

        outboundBootstrap.connect(host: target.host, port: target.port).flatMap { outboundChannel in
            self.targetChannel = outboundChannel

            return outboundChannel.pipeline.addHandler(TunnelRelayHandler(peer: context.channel)).flatMap {
                self.sendConnectionEstablished(context: context)
            }.flatMap {
                self.switchToRawTunnel(context: context, outboundChannel: outboundChannel)
            }
        }.whenFailure { _ in
            self.respondAndClose(context: context, status: .badGateway, reason: "Failed to connect upstream")
        }
    }

    private func sendConnectionEstablished(context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let head = HTTPResponseHead(version: .http1_1, status: .ok)
        let promise = context.eventLoop.makePromise(of: Void.self)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        return promise.futureResult
    }

    private func switchToMITM(
        context: ChannelHandlerContext,
        target: ConnectTarget
    ) -> EventLoopFuture<Void> {
        context.pipeline.removeHandler(name: HTTPPipelineNames.requestDecoder).flatMap {
            context.pipeline.removeHandler(name: HTTPPipelineNames.responseEncoder)
        }.flatMap {
            context.pipeline.removeHandler(self)
        }.flatMap {
            self.mitmOrchestrator.startMITM(inboundChannel: context.channel, target: target)
        }
    }

    private func switchToRawTunnel(
        context: ChannelHandlerContext,
        outboundChannel: Channel
    ) -> EventLoopFuture<Void> {
        context.pipeline.removeHandler(name: HTTPPipelineNames.requestDecoder).flatMap {
            context.pipeline.removeHandler(name: HTTPPipelineNames.responseEncoder)
        }.flatMap {
            context.pipeline.addHandler(TunnelRelayHandler(peer: outboundChannel))
        }.flatMap {
            context.pipeline.removeHandler(self)
        }
    }

    private func respondAndClose(context: ChannelHandlerContext, status: HTTPResponseStatus, reason: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        let body = ByteBuffer(string: reason)
        headers.add(name: "Content-Length", value: "\(body.readableBytes)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

extension ConnectProxyHandler: @unchecked Sendable {}
