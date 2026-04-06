import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import Protocol

public enum HTTPClientError: Error, Sendable {
    case invalidResponseBody
}

public protocol RequestSending: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public final class NIORequestSender: RequestSending, @unchecked Sendable {
    private let client: AsyncHTTPClient.HTTPClient
    private let ownedClient: Bool

    public init(client: AsyncHTTPClient.HTTPClient? = nil) {
        if let client {
            self.client = client
            self.ownedClient = false
        } else {
            self.client = AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .singleton)
            self.ownedClient = true
        }
    }

    deinit {
        guard ownedClient else { return }
        try? client.syncShutdown()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var clientRequest = HTTPClientRequest(url: request.url.absoluteString)
        clientRequest.method = .RAW(value: request.method.rawValue)

        var headers = HTTPHeaders()
        for (header, value) in request.headers {
            headers.add(name: header, value: value)
        }
        clientRequest.headers = headers

        if let bodyData = request.body.dataValue {
            var buffer = ByteBufferAllocator().buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            clientRequest.body = .bytes(buffer)
        }

        let start = Date()
        let response = try await client.execute(clientRequest, timeout: .seconds(60))
        let end = Date()

        let responseBody: ByteBuffer
        do {
            responseBody = try await response.body.collect(upTo: 20 * 1024 * 1024)
        } catch {
            throw HTTPClientError.invalidResponseBody
        }
        let responseData = Data(responseBody.readableBytesView)

        let responseHeaders = response.headers.reduce(into: [String: String]()) { partialResult, header in
            partialResult[header.name] = header.value
        }

        return HTTPResponse(
            statusCode: Int(response.status.code),
            headers: responseHeaders,
            body: responseData,
            durationMS: max(0, Int(end.timeIntervalSince(start) * 1_000))
        )
    }
}
