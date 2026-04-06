import Foundation

public enum SessionProtocolKind: String, Codable, Sendable, Equatable {
    case http1
    case http2
    case websocket
    case sse
    case grpc
    case graphql
    case unknown
}

public struct GraphQLRequest: Sendable, Equatable, Codable {
    public var operationName: String?
    public var query: String
    public var variables: [String: String]

    public init(operationName: String? = nil, query: String, variables: [String: String] = [:]) {
        self.operationName = operationName
        self.query = query
        self.variables = variables
    }

    public func toRequestBody() -> RequestBody {
        var object: [String: Any] = [
            "query": query,
            "variables": variables
        ]
        if let operationName {
            object["operationName"] = operationName
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            return .none
        }
        return .text(text)
    }
}

public struct SSEEvent: Sendable, Equatable, Codable {
    public var id: String?
    public var event: String?
    public var data: String

    public init(id: String? = nil, event: String? = nil, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

public enum SSEParser {
    public static func parse(_ raw: String) -> [SSEEvent] {
        let blocks = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return blocks.compactMap { block in
            var id: String?
            var event: String?
            var dataLines: [String] = []

            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("id:") {
                    id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("event:") {
                    event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                }
            }

            let data = dataLines.joined(separator: "\n")
            guard !data.isEmpty else { return nil }
            return SSEEvent(id: id, event: event, data: data)
        }
    }
}

public struct GRPCFrame: Sendable, Equatable {
    public var compressed: Bool
    public var message: Data

    public init(compressed: Bool, message: Data) {
        self.compressed = compressed
        self.message = message
    }
}

public enum GRPCParser {
    public static func parseFrames(_ data: Data) -> [GRPCFrame] {
        var frames: [GRPCFrame] = []
        var index = 0
        let bytes = [UInt8](data)

        while index + 5 <= bytes.count {
            let compressed = bytes[index] == 1
            let length = Int(bytes[index + 1]) << 24
                | Int(bytes[index + 2]) << 16
                | Int(bytes[index + 3]) << 8
                | Int(bytes[index + 4])
            index += 5
            guard index + length <= bytes.count else { break }
            let payload = Data(bytes[index..<index + length])
            frames.append(GRPCFrame(compressed: compressed, message: payload))
            index += length
        }

        return frames
    }
}

public enum TrafficClassifier {
    public static func classify(
        requestHeaders: [String: String],
        responseHeaders: [String: String],
        path: String,
        httpVersion: String
    ) -> SessionProtocolKind {
        let request = lowercasedHeaders(requestHeaders)
        let response = lowercasedHeaders(responseHeaders)
        let contentType = response["content-type"] ?? request["content-type"] ?? ""
        let accept = request["accept"] ?? ""
        let upgrade = request["upgrade"] ?? ""

        if upgrade.lowercased().contains("websocket") {
            return .websocket
        }
        if contentType.lowercased().contains("text/event-stream") || accept.lowercased().contains("text/event-stream") {
            return .sse
        }
        if contentType.lowercased().contains("application/grpc") {
            return .grpc
        }
        if contentType.lowercased().contains("application/graphql")
            || path.lowercased().contains("/graphql") {
            return .graphql
        }
        if httpVersion.lowercased().contains("2") {
            return .http2
        }
        if httpVersion.lowercased().contains("1.1") {
            return .http1
        }
        return .unknown
    }

    private static func lowercasedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { result, item in
            result[item.key.lowercased()] = item.value
        }
    }
}
