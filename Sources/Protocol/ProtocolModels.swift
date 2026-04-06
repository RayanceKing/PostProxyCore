import Foundation

public enum HTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
    case connect = "CONNECT"
}

public enum RequestBody: Codable, Sendable, Equatable {
    case none
    case text(String)
    case data(Data)

    public var dataValue: Data? {
        switch self {
        case .none:
            return nil
        case .text(let value):
            return value.data(using: .utf8)
        case .data(let value):
            return value
        }
    }
}

public struct RequestTemplate: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var url: String
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: RequestBody

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        method: HTTPMethod,
        headers: [String: String] = [:],
        body: RequestBody = .none
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    public func render(using environment: [String: String]) -> Result<HTTPRequest, RequestRenderError> {
        let renderedURL = VariableRenderer.render(url, environment: environment)
        guard let parsedURL = URL(string: renderedURL) else {
            return .failure(.invalidURL(renderedURL))
        }

        var renderedHeaders: [String: String] = [:]
        for (key, value) in headers {
            renderedHeaders[key] = VariableRenderer.render(value, environment: environment)
        }

        let renderedBody: RequestBody
        switch body {
        case .none:
            renderedBody = .none
        case .text(let value):
            renderedBody = .text(VariableRenderer.render(value, environment: environment))
        case .data:
            renderedBody = body
        }

        return .success(
            HTTPRequest(
                id: id,
                name: name,
                url: parsedURL,
                method: method,
                headers: renderedHeaders,
                body: renderedBody
            )
        )
    }
}

public enum RequestRenderError: Error, Sendable, Equatable {
    case invalidURL(String)
}

public struct HTTPRequest: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: RequestBody

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        method: HTTPMethod,
        headers: [String: String] = [:],
        body: RequestBody = .none
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    public var durationMS: Int

    public init(statusCode: Int, headers: [String: String], body: Data, durationMS: Int) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.durationMS = durationMS
    }
}

public struct HistoryRecord: Sendable, Equatable {
    public var id: UUID
    public var request: HTTPRequest
    public var response: HTTPResponse
    public var createdAt: Date

    public init(id: UUID = UUID(), request: HTTPRequest, response: HTTPResponse, createdAt: Date = Date()) {
        self.id = id
        self.request = request
        self.response = response
        self.createdAt = createdAt
    }
}

public struct ProxySession: Sendable, Equatable {
    public var id: UUID
    public var host: String
    public var method: HTTPMethod
    public var path: String
    public var statusCode: Int?
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        host: String,
        method: HTTPMethod,
        path: String,
        statusCode: Int? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.startedAt = startedAt
    }
}

public enum VariableRenderer {
    public static func render(_ text: String, environment: [String: String]) -> String {
        var output = text
        for (key, value) in environment {
            output = output.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return output
    }
}
