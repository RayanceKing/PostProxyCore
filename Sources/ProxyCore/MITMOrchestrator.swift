import CoreSecurity
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOHTTP2
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
@preconcurrency import NIOTLS
@preconcurrency import NIOWebSocket
import Protocol
import Storage

private enum InboundProtocol {
    case http1
    case http2
}

public final class DefaultMITMOrchestrator: MITMOrchestrating {
    private let certificateProvider: any MITMCertificateProviding
    private let upstreamTLSVerification: UpstreamTLSVerification
    private let sessionRegistry: ProxySessionRegistry
    private let historyStore: any HistoryStore
    private let rewriteEngine: RewriteEngine

    public init(
        certificateProvider: any MITMCertificateProviding = InMemoryCertificateManager(),
        upstreamTLSVerification: UpstreamTLSVerification = .fullVerification,
        sessionRegistry: ProxySessionRegistry = ProxySessionRegistry(),
        historyStore: any HistoryStore = InMemoryHistoryStore(),
        rewriteEngine: RewriteEngine = RewriteEngine()
    ) {
        self.certificateProvider = certificateProvider
        self.upstreamTLSVerification = upstreamTLSVerification
        self.sessionRegistry = sessionRegistry
        self.historyStore = historyStore
        self.rewriteEngine = rewriteEngine
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
                        serverTLS.applicationProtocols = ["h2", "http/1.1"]

                        let sslContext = try NIOSSLContext(configuration: serverTLS)
                        let sslHandler = NIOSSLServerHandler(context: sslContext)

                        try inboundChannel.pipeline.syncOperations.addHandler(sslHandler)
                        try inboundChannel.pipeline.syncOperations.addHandler(
                            ApplicationProtocolNegotiationHandler { result, channel in
                                self.configureInboundPipeline(
                                    on: channel,
                                    target: target,
                                    negotiation: result
                                )
                            }
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

    private func configureInboundPipeline(
        on channel: Channel,
        target: ConnectTarget,
        negotiation: ALPNResult
    ) -> EventLoopFuture<Void> {
        switch negotiation {
        case .negotiated(let proto) where proto == "h2":
            return channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
                do {
                    try streamChannel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                    try streamChannel.pipeline.syncOperations.addHandler(
                        MITMHTTPHandler(
                            target: target,
                            upstreamTLSVerification: self.upstreamTLSVerification,
                            sessionRegistry: self.sessionRegistry,
                            historyStore: self.historyStore,
                            rewriteEngine: self.rewriteEngine,
                            inboundProtocol: .http2
                        )
                    )
                    return streamChannel.eventLoop.makeSucceededFuture(())
                } catch {
                    return streamChannel.eventLoop.makeFailedFuture(error)
                }
            }.map { _ in }

        default:
            do {
                try channel.pipeline.syncOperations.addHandler(
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                )
                try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
                try channel.pipeline.syncOperations.addHandler(
                    MITMHTTPHandler(
                        target: target,
                        upstreamTLSVerification: self.upstreamTLSVerification,
                        sessionRegistry: self.sessionRegistry,
                        historyStore: self.historyStore,
                        rewriteEngine: self.rewriteEngine,
                        inboundProtocol: .http1
                    )
                )
                return channel.eventLoop.makeSucceededFuture(())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
    }
}

private final class MITMHTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let target: ConnectTarget
    private let upstreamTLSVerification: UpstreamTLSVerification
    private let sessionRegistry: ProxySessionRegistry
    private let historyStore: any HistoryStore
    private let rewriteEngine: RewriteEngine
    private let inboundProtocol: InboundProtocol

    private var currentHead: HTTPRequestHead?
    private var currentBody: ByteBuffer?
    private var currentStartedAt: Date?

    init(
        target: ConnectTarget,
        upstreamTLSVerification: UpstreamTLSVerification,
        sessionRegistry: ProxySessionRegistry,
        historyStore: any HistoryStore,
        rewriteEngine: RewriteEngine,
        inboundProtocol: InboundProtocol
    ) {
        self.target = target
        self.upstreamTLSVerification = upstreamTLSVerification
        self.sessionRegistry = sessionRegistry
        self.historyStore = historyStore
        self.rewriteEngine = rewriteEngine
        self.inboundProtocol = inboundProtocol
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            currentHead = head
            currentBody = context.channel.allocator.buffer(capacity: 0)
            currentStartedAt = Date()

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
            respond502(channel: context.channel, message: "Missing HTTP request head")
            return
        }

        let startedAt = currentStartedAt ?? Date()
        var forwardHead = HTTPRequestHead(
            version: inboundHead.version,
            method: inboundHead.method,
            uri: normalizeURI(inboundHead.uri),
            headers: inboundHead.headers
        )
        var forwardBody = currentBody ?? context.channel.allocator.buffer(capacity: 0)
        currentHead = nil
        currentBody = nil
        currentStartedAt = nil

        let requestMethodRaw = inboundHead.method.rawValue
        let requestPath = forwardHead.uri

        rewriteEngine.applyRequest(
            host: target.host,
            methodRaw: requestMethodRaw,
            path: requestPath,
            head: &forwardHead,
            body: &forwardBody
        )

        let isGRPC = Self.isGRPC(headers: forwardHead.headers)
        let isWebSocket = Self.isWebSocketUpgrade(headers: forwardHead.headers)

        if isWebSocket, inboundProtocol == .http1 {
            handleWebSocket(
                inboundChannel: context.channel,
                requestHead: forwardHead,
                requestBody: forwardBody,
                requestMethodRaw: requestMethodRaw,
                requestPath: requestPath,
                startedAt: startedAt
            )
            return
        }

        let responsePromise = context.eventLoop.makePromise(of: ProxiedResponse.self)
        let useHTTP2Upstream = inboundProtocol == .http2 || isGRPC

        if useHTTP2Upstream {
            forwardUpstreamHTTP2(head: forwardHead, body: forwardBody, responsePromise: responsePromise)
        } else {
            forwardUpstreamHTTP1(head: forwardHead, body: forwardBody, responsePromise: responsePromise)
        }

        finalizeResponse(
            on: context.channel,
            responseFuture: responsePromise.futureResult,
            requestHead: forwardHead,
            requestBody: forwardBody,
            requestMethodRaw: requestMethodRaw,
            requestPath: requestPath,
            startedAt: startedAt
        )
    }

    private func forwardUpstreamHTTP1(
        head: HTTPRequestHead,
        body: ByteBuffer,
        responsePromise: EventLoopPromise<ProxiedResponse>
    ) {
        let outboundBootstrap = ClientBootstrap(group: responsePromise.futureResult.eventLoop)
        let tlsVerification = upstreamTLSVerification

        outboundBootstrap.channelInitializer { [target] channel in
            do {
                var clientTLS = TLSConfiguration.makeClientConfiguration()
                clientTLS.applicationProtocols = ["http/1.1"]
                switch tlsVerification {
                case .fullVerification:
                    clientTLS.certificateVerification = .fullVerification
                case .noVerification:
                    clientTLS.certificateVerification = .none
                }

                let sslContext = try NIOSSLContext(configuration: clientTLS)
                let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: target.host)

                try channel.pipeline.syncOperations.addHandler(sslHandler)
                try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder())
                try channel.pipeline.syncOperations.addHandler(
                    ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
                )
                try channel.pipeline.syncOperations.addHandler(OutboundResponseCollector(promise: responsePromise))
                return channel.eventLoop.makeSucceededFuture(())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.connect(host: target.host, port: target.port).flatMap { outboundChannel in
            outboundChannel.write(HTTPClientRequestPart.head(head), promise: nil)
            if body.readableBytes > 0 {
                outboundChannel.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
            }
            return outboundChannel.writeAndFlush(HTTPClientRequestPart.end(nil))
        }.whenFailure { error in
            responsePromise.fail(error)
        }
    }

    private func forwardUpstreamHTTP2(
        head: HTTPRequestHead,
        body: ByteBuffer,
        responsePromise: EventLoopPromise<ProxiedResponse>
    ) {
        let outboundBootstrap = ClientBootstrap(group: responsePromise.futureResult.eventLoop)
        let tlsVerification = upstreamTLSVerification

        outboundBootstrap.channelInitializer { [target] channel in
            do {
                var clientTLS = TLSConfiguration.makeClientConfiguration()
                clientTLS.applicationProtocols = ["h2", "http/1.1"]
                switch tlsVerification {
                case .fullVerification:
                    clientTLS.certificateVerification = .fullVerification
                case .noVerification:
                    clientTLS.certificateVerification = .none
                }

                let sslContext = try NIOSSLContext(configuration: clientTLS)
                let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: target.host)
                try channel.pipeline.syncOperations.addHandler(sslHandler)
                return channel.eventLoop.makeSucceededFuture(())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.connect(host: target.host, port: target.port).flatMap { outboundChannel in
            outboundChannel.configureHTTP2Pipeline(mode: .client, inboundStreamInitializer: nil).flatMap { multiplexer in
                multiplexer.createStreamChannel { streamChannel in
                    do {
                        try streamChannel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                        try streamChannel.pipeline.syncOperations.addHandler(
                            OutboundResponseCollector(
                                promise: responsePromise,
                                parentChannelToClose: outboundChannel
                            )
                        )
                        return streamChannel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return streamChannel.eventLoop.makeFailedFuture(error)
                    }
                }.flatMap { streamChannel in
                    streamChannel.write(HTTPClientRequestPart.head(head), promise: nil)
                    if body.readableBytes > 0 {
                        streamChannel.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
                    }
                    return streamChannel.writeAndFlush(HTTPClientRequestPart.end(nil))
                }
            }
        }.whenFailure { error in
            responsePromise.fail(error)
        }
    }

    private func finalizeResponse(
        on inboundChannel: Channel,
        responseFuture: EventLoopFuture<ProxiedResponse>,
        requestHead: HTTPRequestHead,
        requestBody: ByteBuffer,
        requestMethodRaw: String,
        requestPath: String,
        startedAt: Date
    ) {
        responseFuture.whenSuccess { response in
            var responseHead = HTTPResponseHead(
                version: response.head.version,
                status: response.head.status,
                headers: response.head.headers
            )
            var responseBody = response.body
            self.rewriteEngine.applyResponse(
                host: self.target.host,
                methodRaw: requestMethodRaw,
                path: requestPath,
                head: &responseHead,
                body: &responseBody
            )

            inboundChannel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
            if responseBody.readableBytes > 0 {
                inboundChannel.write(HTTPServerResponsePart.body(.byteBuffer(responseBody)), promise: nil)
            }
            inboundChannel.writeAndFlush(HTTPServerResponsePart.end(response.trailers), promise: nil)

            let requestURL = self.buildRequestURL(host: self.target.host, uri: requestPath)
            let requestMethod = methodFromRaw(requestMethodRaw)
            let request = HTTPRequest(
                name: "\(requestMethod.rawValue) \(requestPath)",
                url: requestURL,
                method: requestMethod,
                headers: requestHead.headers.dictionaryValue,
                body: requestBody.readableBytes > 0 ? .data(Data(requestBody.readableBytesView)) : .none
            )
            let responseModel = HTTPResponse(
                statusCode: Int(responseHead.status.code),
                headers: responseHead.headers.dictionaryValue,
                body: Data(responseBody.readableBytesView),
                durationMS: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            )
            let historyRecord = HistoryRecord(request: request, response: responseModel, createdAt: startedAt)
            let session = ProxySession(
                host: self.target.host,
                method: requestMethod,
                path: requestPath,
                statusCode: Int(responseHead.status.code),
                requestHeaders: requestHead.headers.dictionaryValue,
                responseHeaders: responseHead.headers.dictionaryValue,
                requestBodySize: requestBody.readableBytes,
                responseBodySize: responseBody.readableBytes,
                durationMS: responseModel.durationMS,
                protocolKind: TrafficClassifier.classify(
                    requestHeaders: requestHead.headers.dictionaryValue,
                    responseHeaders: responseHead.headers.dictionaryValue,
                    path: requestPath,
                    httpVersion: "\(responseHead.version.major).\(responseHead.version.minor)"
                ),
                startedAt: startedAt
            )

            Task {
                await self.historyStore.save(historyRecord)
                await self.sessionRegistry.register(session)
            }
        }

        responseFuture.whenFailure { _ in
            self.respond502(channel: inboundChannel, message: "Failed to proxy TLS upstream request")
        }
    }

    private func handleWebSocket(
        inboundChannel: Channel,
        requestHead: HTTPRequestHead,
        requestBody: ByteBuffer,
        requestMethodRaw: String,
        requestPath: String,
        startedAt: Date
    ) {
        let handshakePromise = inboundChannel.eventLoop.makePromise(of: WebSocketHandshakeResult.self)
        let outboundBootstrap = ClientBootstrap(group: inboundChannel.eventLoop)
        let tlsVerification = upstreamTLSVerification

        outboundBootstrap.channelInitializer { [target] channel in
            do {
                var clientTLS = TLSConfiguration.makeClientConfiguration()
                clientTLS.applicationProtocols = ["http/1.1"]
                switch tlsVerification {
                case .fullVerification:
                    clientTLS.certificateVerification = .fullVerification
                case .noVerification:
                    clientTLS.certificateVerification = .none
                }

                let sslContext = try NIOSSLContext(configuration: clientTLS)
                let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: target.host)

                try channel.pipeline.syncOperations.addHandler(sslHandler)
                try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder(), name: "ws.req.encoder")
                try channel.pipeline.syncOperations.addHandler(
                    ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                    name: "ws.res.decoder"
                )
                try channel.pipeline.syncOperations.addHandler(
                    OutboundWebSocketHandshakeCollector(promise: handshakePromise),
                    name: "ws.handshake.collector"
                )
                return channel.eventLoop.makeSucceededFuture(())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.connect(host: target.host, port: target.port).flatMap { outboundChannel in
            outboundChannel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
            if requestBody.readableBytes > 0 {
                outboundChannel.write(HTTPClientRequestPart.body(.byteBuffer(requestBody)), promise: nil)
            }
            return outboundChannel.writeAndFlush(HTTPClientRequestPart.end(nil))
        }.whenFailure { error in
            handshakePromise.fail(error)
        }

        handshakePromise.futureResult.whenSuccess { result in
            guard result.responseHead.status == .switchingProtocols else {
                self.respond502(channel: inboundChannel, message: "WebSocket upgrade rejected by upstream")
                result.outboundChannel.close(promise: nil)
                return
            }

            let responseHead = HTTPResponseHead(
                version: .http1_1,
                status: .switchingProtocols,
                headers: result.responseHead.headers
            )
            inboundChannel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
            inboundChannel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)

            do {
                try self.configureInboundWebSocketRelay(channel: inboundChannel, peer: result.outboundChannel)
                try self.configureOutboundWebSocketRelay(channel: result.outboundChannel, peer: inboundChannel)
            } catch {
                self.respond502(channel: inboundChannel, message: "Failed to switch WebSocket relay")
                result.outboundChannel.close(promise: nil)
                return
            }

            let requestURL = self.buildRequestURL(host: self.target.host, uri: requestPath)
            let requestMethod = methodFromRaw(requestMethodRaw)
            let request = HTTPRequest(
                name: "\(requestMethod.rawValue) \(requestPath)",
                url: requestURL,
                method: requestMethod,
                headers: requestHead.headers.dictionaryValue,
                body: requestBody.readableBytes > 0 ? .data(Data(requestBody.readableBytesView)) : .none
            )
            let response = HTTPResponse(
                statusCode: Int(result.responseHead.status.code),
                headers: result.responseHead.headers.dictionaryValue,
                body: Data(),
                durationMS: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
            )
            let session = ProxySession(
                host: self.target.host,
                method: requestMethod,
                path: requestPath,
                statusCode: Int(result.responseHead.status.code),
                requestHeaders: requestHead.headers.dictionaryValue,
                responseHeaders: result.responseHead.headers.dictionaryValue,
                requestBodySize: requestBody.readableBytes,
                responseBodySize: 0,
                durationMS: response.durationMS,
                protocolKind: .websocket,
                startedAt: startedAt
            )
            let historyRecord = HistoryRecord(request: request, response: response, createdAt: startedAt)

            Task {
                await self.historyStore.save(historyRecord)
                await self.sessionRegistry.register(session)
            }
        }

        handshakePromise.futureResult.whenFailure { _ in
            self.respond502(channel: inboundChannel, message: "WebSocket upstream handshake failed")
        }
    }

    private func configureInboundWebSocketRelay(channel: Channel, peer: Channel) throws {
        let sync = channel.pipeline.syncOperations
        if let reqDecoder = try? sync.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self) {
            _ = sync.removeHandler(reqDecoder)
        }
        if let resEncoder = try? sync.handler(type: HTTPResponseEncoder.self) {
            _ = sync.removeHandler(resEncoder)
        }
        _ = sync.removeHandler(self)

        try sync.addHandler(WebSocketFrameEncoder())
        try sync.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1 << 24)))
        try sync.addHandler(WebSocketFrameRelayHandler(peer: peer))
    }

    private func configureOutboundWebSocketRelay(channel: Channel, peer: Channel) throws {
        let sync = channel.pipeline.syncOperations
        _ = sync.removeHandler(name: "ws.req.encoder")
        _ = sync.removeHandler(name: "ws.res.decoder")
        _ = sync.removeHandler(name: "ws.handshake.collector")

        try sync.addHandler(WebSocketFrameEncoder())
        try sync.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 1 << 24)))
        try sync.addHandler(WebSocketFrameRelayHandler(peer: peer))
    }

    private func respond502(channel: Channel, message: String) {
        let body = ByteBuffer(string: message)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(body.readableBytes)")

        let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
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

    private func buildRequestURL(host: String, uri: String) -> URL {
        if let absolute = URL(string: uri), absolute.scheme != nil {
            return absolute
        }
        return URL(string: "https://\(host)\(uri)") ?? URL(string: "https://\(host)/")!
    }

    private static func isWebSocketUpgrade(headers: HTTPHeaders) -> Bool {
        let upgrade = headers["Upgrade"].first ?? headers["upgrade"].first
        let connection = headers["Connection"].first ?? headers["connection"].first
        return (upgrade?.lowercased().contains("websocket") == true)
            && (connection?.lowercased().contains("upgrade") == true)
    }

    private static func isGRPC(headers: HTTPHeaders) -> Bool {
        let contentType = headers["Content-Type"].first ?? headers["content-type"].first ?? ""
        return contentType.lowercased().contains("application/grpc")
    }
}

private struct ProxiedResponse {
    let head: HTTPResponseHead
    var body: ByteBuffer
    var trailers: HTTPHeaders?
}

private final class OutboundResponseCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<ProxiedResponse>
    private let parentChannelToClose: Channel?
    private var head: HTTPResponseHead?
    private var bodyBuffer: ByteBuffer
    private var trailers: HTTPHeaders?

    init(
        promise: EventLoopPromise<ProxiedResponse>,
        parentChannelToClose: Channel? = nil
    ) {
        self.promise = promise
        self.parentChannelToClose = parentChannelToClose
        self.bodyBuffer = ByteBuffer()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.head = head

        case .body(var chunk):
            bodyBuffer.writeBuffer(&chunk)

        case .end(let trailers):
            self.trailers = trailers
            if let head {
                promise.succeed(ProxiedResponse(head: head, body: bodyBuffer, trailers: trailers))
            } else {
                promise.fail(ProxyServerError.mitmNotImplemented)
            }
            context.close(promise: nil)
            parentChannelToClose?.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
        parentChannelToClose?.close(promise: nil)
    }
}

extension OutboundResponseCollector: @unchecked Sendable {}

private struct WebSocketHandshakeResult {
    let outboundChannel: Channel
    let responseHead: HTTPResponseHead
}

private final class OutboundWebSocketHandshakeCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<WebSocketHandshakeResult>
    private var responseHead: HTTPResponseHead?

    init(promise: EventLoopPromise<WebSocketHandshakeResult>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            responseHead = head
        case .body:
            break
        case .end:
            if let responseHead {
                promise.succeed(WebSocketHandshakeResult(outboundChannel: context.channel, responseHead: responseHead))
            } else {
                promise.fail(ProxyServerError.mitmNotImplemented)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

extension OutboundWebSocketHandshakeCollector: @unchecked Sendable {}

private final class WebSocketFrameRelayHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        peer.writeAndFlush(frame, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(mode: .all, promise: nil)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(mode: .all, promise: nil)
        context.fireChannelInactive()
    }
}

extension WebSocketFrameRelayHandler: @unchecked Sendable {}

private extension HTTPHeaders {
    var dictionaryValue: [String: String] {
        reduce(into: [String: String]()) { result, header in
            result[header.name] = header.value
        }
    }
}
