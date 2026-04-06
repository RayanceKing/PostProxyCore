import Testing
import Foundation
import HTTPClient
import NIOCore
import NIOHTTP1
@testable import Protocol
@testable import ProxyCore
@testable import Storage

@Test("Proxy filter matches host and method")
func proxyFilterMatching() async {
    let registry = ProxySessionRegistry()

    await registry.register(ProxySession(host: "api.example.com", method: .get, path: "/users"))
    await registry.register(ProxySession(host: "cdn.example.com", method: .get, path: "/image"))
    await registry.register(ProxySession(host: "api.example.com", method: .post, path: "/users"))

    let filter = ProxyFilter(hostContains: "api.", methods: [.get])
    let results = await registry.filtered(by: filter)

    #expect(results.count == 1)
    #expect(results[0].path == "/users")
    #expect(results[0].method == .get)
}

@Test("CONNECT authority parses host and default port")
func connectTargetParsing() {
    let explicitPort = ConnectTarget(authority: "example.com:8443")
    #expect(explicitPort?.host == "example.com")
    #expect(explicitPort?.port == 8443)

    let defaultPort = ConnectTarget(authority: "api.example.com")
    #expect(defaultPort?.host == "api.example.com")
    #expect(defaultPort?.port == 443)
}

@Test("Invalid CONNECT authority is rejected")
func connectTargetInvalid() {
    let invalid = ConnectTarget(authority: "://bad")
    #expect(invalid == nil)
}

@Test("Rewrite engine mutates request and response")
func rewriteEngineApplyRules() {
    let engine = RewriteEngine(rules: [
        RewriteRule(
            hostContains: "example.com",
            pathContains: "/v1",
            methods: ["POST"],
            actions: [
                .setRequestHeader(name: "X-Debug", value: "1"),
                .replaceRequestBodyText(find: "old", replace: "new"),
                .setResponseHeader(name: "X-Rewritten", value: "yes"),
                .setResponseStatus(299),
                .replaceResponseBodyText(find: "upstream", replace: "rewritten")
            ]
        )
    ])

    var requestHead = HTTPRequestHead(
        version: .http1_1,
        method: .POST,
        uri: "/v1/users",
        headers: HTTPHeaders([("Content-Type", "text/plain")])
    )
    var requestBody = ByteBuffer(string: "old payload")
    engine.applyRequest(
        host: "api.example.com",
        methodRaw: "POST",
        path: "/v1/users",
        head: &requestHead,
        body: &requestBody
    )

    #expect(requestHead.headers["X-Debug"].first == "1")
    #expect(requestBody.getString(at: requestBody.readerIndex, length: requestBody.readableBytes) == "new payload")

    var responseHead = HTTPResponseHead(
        version: .http1_1,
        status: .ok,
        headers: HTTPHeaders([("Content-Type", "text/plain")])
    )
    var responseBody = ByteBuffer(string: "upstream body")
    engine.applyResponse(
        host: "api.example.com",
        methodRaw: "POST",
        path: "/v1/users",
        head: &responseHead,
        body: &responseBody
    )

    #expect(responseHead.status.code == 299)
    #expect(responseHead.headers["X-Rewritten"].first == "yes")
    #expect(
        responseBody.getString(at: responseBody.readerIndex, length: responseBody.readableBytes) == "rewritten body"
    )
}

@Test("Session replayer replays from history and saves new record")
func sessionReplayerReplay() async throws {
    let store = InMemoryHistoryStore()
    let request = HTTPRequest(
        name: "source",
        url: URL(string: "https://api.example.com/v1/users")!,
        method: .get
    )
    let sourceRecord = HistoryRecord(
        request: request,
        response: HTTPResponse(statusCode: 200, headers: [:], body: Data(), durationMS: 5)
    )
    await store.save(sourceRecord)

    let sender = MockRequestSender(
        response: HTTPResponse(statusCode: 201, headers: ["X-Replay": "1"], body: Data("ok".utf8), durationMS: 12)
    )
    let replayer = SessionReplayer(historyStore: store, requestSender: sender)
    let replayed = try await replayer.replay(recordID: sourceRecord.id, saveAsNewRecord: true)

    #expect(replayed.response.statusCode == 201)
    #expect(replayed.request.url.absoluteString == request.url.absoluteString)
    #expect(await store.list(limit: 10).count == 2)
}

private struct MockRequestSender: RequestSending {
    let response: HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        response
    }
}
