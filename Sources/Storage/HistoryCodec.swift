import Foundation
import Protocol

enum HistoryCodec {
    static func exportJSON(records: [HistoryRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records)
    }

    static func importJSON(data: Data) throws -> [HistoryRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([HistoryRecord].self, from: data)
        } catch {
            throw HistoryExchangeError.invalidJSON
        }
    }

    static func exportHAR(records: [HistoryRecord]) throws -> Data {
        let har = HARRoot(log: HARLog(records: records))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(har)
    }

    static func importHAR(data: Data) throws -> [HistoryRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let har: HARRoot
        do {
            har = try decoder.decode(HARRoot.self, from: data)
        } catch {
            throw HistoryExchangeError.invalidHAR
        }
        return har.log.entries.compactMap { $0.toHistoryRecord() }
    }
}

private struct HARRoot: Codable {
    let log: HARLog
}

private struct HARLog: Codable {
    let version: String
    let creator: HARCreator
    let entries: [HAREntry]

    init(records: [HistoryRecord]) {
        self.version = "1.2"
        self.creator = HARCreator(name: "PostProxyCore", version: "0.1.0")
        self.entries = records.map(HAREntry.init(record:))
    }
}

private struct HARCreator: Codable {
    let name: String
    let version: String
}

private struct HAREntry: Codable {
    let startedDateTime: Date
    let time: Double
    let request: HARRequest
    let response: HARResponse
    let timings: HARTimings

    init(record: HistoryRecord) {
        self.startedDateTime = record.createdAt
        self.time = Double(record.response.durationMS)
        self.request = HARRequest(request: record.request)
        self.response = HARResponse(response: record.response)
        self.timings = HARTimings(wait: Double(record.response.durationMS))
    }

    func toHistoryRecord() -> HistoryRecord? {
        guard let request = request.toHTTPRequest() else {
            return nil
        }
        let response = response.toHTTPResponse(durationMS: Int(time))
        return HistoryRecord(request: request, response: response, createdAt: startedDateTime)
    }
}

private struct HARRequest: Codable {
    let method: String
    let url: String
    let httpVersion: String
    let headers: [HARNameValue]
    let queryString: [HARNameValue]
    let postData: HARPostData?
    let headersSize: Int
    let bodySize: Int

    init(request: HTTPRequest) {
        self.method = request.method.rawValue
        self.url = request.url.absoluteString
        self.httpVersion = "HTTP/1.1"
        self.headers = request.headers.map { HARNameValue(name: $0.key, value: $0.value) }
        self.queryString = []

        if let bodyData = request.body.dataValue, !bodyData.isEmpty {
            let text = String(data: bodyData, encoding: .utf8) ?? bodyData.base64EncodedString()
            let encoding: String? = String(data: bodyData, encoding: .utf8) == nil ? "base64" : nil
            self.postData = HARPostData(
                mimeType: request.headers["Content-Type"] ?? "application/octet-stream",
                text: text,
                encoding: encoding
            )
            self.bodySize = bodyData.count
        } else {
            self.postData = nil
            self.bodySize = 0
        }
        self.headersSize = -1
    }

    func toHTTPRequest() -> HTTPRequest? {
        guard let parsedURL = URL(string: url) else {
            return nil
        }
        var headersMap: [String: String] = [:]
        for header in headers {
            headersMap[header.name] = header.value
        }
        let method = HTTPMethod(rawValue: method.uppercased()) ?? .get
        let body: RequestBody
        if let postData {
            if postData.encoding?.lowercased() == "base64",
               let decoded = Data(base64Encoded: postData.text) {
                body = .data(decoded)
            } else {
                body = .text(postData.text)
            }
        } else {
            body = .none
        }
        return HTTPRequest(name: "\(method.rawValue) \(parsedURL.path)", url: parsedURL, method: method, headers: headersMap, body: body)
    }
}

private struct HARResponse: Codable {
    let status: Int
    let statusText: String
    let httpVersion: String
    let headers: [HARNameValue]
    let content: HARContent
    let redirectURL: String
    let headersSize: Int
    let bodySize: Int

    init(response: HTTPResponse) {
        self.status = response.statusCode
        self.statusText = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        self.httpVersion = "HTTP/1.1"
        self.headers = response.headers.map { HARNameValue(name: $0.key, value: $0.value) }

        if let text = String(data: response.body, encoding: .utf8) {
            self.content = HARContent(
                size: response.body.count,
                mimeType: response.headers["Content-Type"] ?? "application/octet-stream",
                text: text,
                encoding: nil
            )
        } else {
            self.content = HARContent(
                size: response.body.count,
                mimeType: response.headers["Content-Type"] ?? "application/octet-stream",
                text: response.body.base64EncodedString(),
                encoding: "base64"
            )
        }
        self.redirectURL = ""
        self.headersSize = -1
        self.bodySize = response.body.count
    }

    func toHTTPResponse(durationMS: Int) -> HTTPResponse {
        var headersMap: [String: String] = [:]
        for header in headers {
            headersMap[header.name] = header.value
        }

        let bodyData: Data
        if content.encoding?.lowercased() == "base64",
           let decoded = Data(base64Encoded: content.text ?? "") {
            bodyData = decoded
        } else {
            bodyData = Data((content.text ?? "").utf8)
        }

        return HTTPResponse(
            statusCode: status,
            headers: headersMap,
            body: bodyData,
            durationMS: max(0, durationMS)
        )
    }
}

private struct HARContent: Codable {
    let size: Int
    let mimeType: String
    let text: String?
    let encoding: String?
}

private struct HARPostData: Codable {
    let mimeType: String
    let text: String
    let encoding: String?
}

private struct HARNameValue: Codable {
    let name: String
    let value: String
}

private struct HARTimings: Codable {
    let send: Double
    let wait: Double
    let receive: Double

    init(wait: Double) {
        self.send = 0
        self.wait = wait
        self.receive = 0
    }
}
