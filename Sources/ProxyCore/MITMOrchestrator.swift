import CoreSecurity
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL

public final class DefaultMITMOrchestrator: MITMOrchestrating {
    private let certificateProvider: any MITMCertificateProviding
    private let upstreamTLSVerification: UpstreamTLSVerification

    public init(
        certificateProvider: any MITMCertificateProviding = InMemoryCertificateManager(),
        upstreamTLSVerification: UpstreamTLSVerification = .fullVerification
    ) {
        self.certificateProvider = certificateProvider
        self.upstreamTLSVerification = upstreamTLSVerification
    }

    public func startMITM(inboundChannel: Channel, target: ConnectTarget) -> EventLoopFuture<Void> {
        let promise = inboundChannel.eventLoop.makePromise(of: Void.self)
        let provider = certificateProvider

        Task {
            do {
                let identity = try await provider.leafIdentity(for: target.host)
                inboundChannel.eventLoop.execute {
                    do {
                        var serverTLS = TLSConfiguration.makeServerConfiguration(
                            certificateChain: identity.certificateChain.map { .certificate($0) },
                            privateKey: .privateKey(identity.privateKey)
                        )
                        serverTLS.applicationProtocols = ["http/1.1"]

                        let context = try NIOSSLContext(configuration: serverTLS)
                        let sslHandler = NIOSSLServerHandler(context: context)

                        try inboundChannel.pipeline.syncOperations.addHandler(sslHandler)
                        try inboundChannel.pipeline.syncOperations.addHandler(
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                        )
                        try inboundChannel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
                        try inboundChannel.pipeline.syncOperations.addHandler(
                            MITMHTTPHandler(target: target, upstreamTLSVerification: self.upstreamTLSVerification)
                        )
                        promise.succeed(())
                    } catch {
                        promise.fail(error)
                    }
                }
            } catch {
                promise.fail(error)
            }
        }

        return promise.futureResult
    }
}

private final class MITMHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let target: ConnectTarget
    private let upstreamTLSVerification: UpstreamTLSVerification
    private var currentHead: HTTPRequestHead?
    private var currentBody: ByteBuffer?

    init(target: ConnectTarget, upstreamTLSVerification: UpstreamTLSVerification) {
        self.target = target
        self.upstreamTLSVerification = upstreamTLSVerification
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            currentHead = head
            currentBody = context.channel.allocator.buffer(capacity: 0)

        case .body(var bodyChunk):
            if currentBody == nil {
                currentBody = context.channel.allocator.buffer(capacity: bodyChunk.readableBytes)
            }
            currentBody?.writeBuffer(&bodyChunk)

        case .end:
            forwardCurrentRequest(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func forwardCurrentRequest(context: ChannelHandlerContext) {
        guard let inboundHead = currentHead else {
            respond502(context: context, message: "Missing HTTP request head")
            return
        }

        let requestBody = currentBody ?? context.channel.allocator.buffer(capacity: 0)
        currentHead = nil
        currentBody = nil

        let responsePromise = context.eventLoop.makePromise(of: ProxiedResponse.self)
        let outboundBootstrap = ClientBootstrap(group: context.eventLoop)
        let tlsVerification = upstreamTLSVerification

        outboundBootstrap.channelInitializer { [target] channel in
            do {
                var clientTLS = TLSConfiguration.makeClientConfiguration()
                switch tlsVerification {
                case .fullVerification:
                    clientTLS.certificateVerification = .fullVerification
                case .noVerification:
                    clientTLS.certificateVerification = .none
                }
                clientTLS.applicationProtocols = ["http/1.1"]

                let sslContext = try NIOSSLContext(configuration: clientTLS)
                let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: target.host)

                return channel.pipeline.addHandler(sslHandler).flatMap {
                    channel.pipeline.addHandler(HTTPRequestEncoder())
                }.flatMap {
                    channel.pipeline.addHandler(
                        ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
                    )
                }.flatMap {
                    channel.pipeline.addHandler(OutboundResponseCollector(promise: responsePromise))
                }
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.connect(host: target.host, port: target.port).flatMap { outboundChannel in
            let forwardHead = HTTPRequestHead(
                version: inboundHead.version,
                method: inboundHead.method,
                uri: self.normalizeURI(inboundHead.uri),
                headers: inboundHead.headers
            )

            outboundChannel.write(HTTPClientRequestPart.head(forwardHead), promise: nil)
            if requestBody.readableBytes > 0 {
                outboundChannel.write(HTTPClientRequestPart.body(.byteBuffer(requestBody)), promise: nil)
            }
            return outboundChannel.writeAndFlush(HTTPClientRequestPart.end(nil))
        }.whenFailure { error in
            responsePromise.fail(error)
        }

        responsePromise.futureResult.whenSuccess { response in
            let responseHead = HTTPResponseHead(
                version: response.head.version,
                status: response.head.status,
                headers: response.head.headers
            )
            context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            if response.body.readableBytes > 0 {
                context.write(self.wrapOutboundOut(.body(.byteBuffer(response.body))), promise: nil)
            }
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }

        responsePromise.futureResult.whenFailure { _ in
            self.respond502(context: context, message: "Failed to proxy TLS upstream request")
        }
    }

    private func respond502(context: ChannelHandlerContext, message: String) {
        let body = ByteBuffer(string: message)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.readableBytes)")

        let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func normalizeURI(_ rawURI: String) -> String {
        guard let components = URLComponents(string: rawURI), components.scheme != nil else {
            return rawURI
        }

        var path = components.percentEncodedPath
        if path.isEmpty {
            path = "/"
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?\(query)"
        }
        return path
    }
}

extension MITMHTTPHandler: @unchecked Sendable {}

private struct ProxiedResponse {
    let head: HTTPResponseHead
    var body: ByteBuffer
}

private final class OutboundResponseCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<ProxiedResponse>
    private var head: HTTPResponseHead?
    private var bodyBuffer: ByteBuffer

    init(promise: EventLoopPromise<ProxiedResponse>) {
        self.promise = promise
        self.bodyBuffer = ByteBuffer()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.head = head

        case .body(var chunk):
            bodyBuffer.writeBuffer(&chunk)

        case .end:
            if let head {
                promise.succeed(ProxiedResponse(head: head, body: bodyBuffer))
            } else {
                promise.fail(ProxyServerError.mitmNotImplemented)
            }
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

extension OutboundResponseCollector: @unchecked Sendable {}
