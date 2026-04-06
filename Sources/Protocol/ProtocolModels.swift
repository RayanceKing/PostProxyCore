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

    public func render(using environment: Environment) -> Result<HTTPRequest, RequestRenderError> {
        render(using: environment.values)
    }
}

public enum RequestRenderError: Error, Sendable, Equatable {
    case invalidURL(String)
}

public struct HTTPRequest: Sendable, Equatable, Codable {
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

public struct HTTPResponse: Sendable, Equatable, Codable {
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

public struct HistoryRecord: Sendable, Equatable, Codable {
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
    public var requestHeaders: [String: String]
    public var responseHeaders: [String: String]
    public var requestBodySize: Int
    public var responseBodySize: Int
    public var durationMS: Int?
    public var protocolKind: SessionProtocolKind
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        host: String,
        method: HTTPMethod,
        path: String,
        statusCode: Int? = nil,
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        requestBodySize: Int = 0,
        responseBodySize: Int = 0,
        durationMS: Int? = nil,
        protocolKind: SessionProtocolKind = .unknown,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.host = host
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBodySize = requestBodySize
        self.responseBodySize = responseBodySize
        self.durationMS = durationMS
        self.protocolKind = protocolKind
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

public struct EnvironmentVariable: Sendable, Equatable, Codable {
    public var key: String
    public var value: String
    public var enabled: Bool
    public var secret: Bool

    public init(key: String, value: String, enabled: Bool = true, secret: Bool = false) {
        self.key = key
        self.value = value
        self.enabled = enabled
        self.secret = secret
    }
}

public struct Environment: Sendable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var variables: [EnvironmentVariable]

    public init(id: UUID = UUID(), name: String, variables: [EnvironmentVariable] = []) {
        self.id = id
        self.name = name
        self.variables = variables
    }

    public var values: [String: String] {
        variables.reduce(into: [String: String]()) { result, variable in
            guard variable.enabled else { return }
            result[variable.key] = variable.value
        }
    }

    public mutating func setValue(_ value: String, for key: String, enabled: Bool = true, secret: Bool = false) {
        if let index = variables.firstIndex(where: { $0.key == key }) {
            variables[index].value = value
            variables[index].enabled = enabled
            variables[index].secret = secret
        } else {
            variables.append(EnvironmentVariable(key: key, value: value, enabled: enabled, secret: secret))
        }
    }

    public mutating func removeValue(for key: String) {
        variables.removeAll { $0.key == key }
    }
}

public struct RequestItem: Sendable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var request: RequestTemplate
    public var preRequest: [PreRequestStep]
    public var tests: [TestStep]

    public init(
        id: UUID = UUID(),
        name: String,
        request: RequestTemplate,
        preRequest: [PreRequestStep] = [],
        tests: [TestStep] = []
    ) {
        self.id = id
        self.name = name
        self.request = request
        self.preRequest = preRequest
        self.tests = tests
    }
}

public struct RequestCollection: Sendable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var items: [RequestItem]

    public init(id: UUID = UUID(), name: String, items: [RequestItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

public enum PreRequestStep: Sendable, Equatable, Codable {
    case setHeader(name: String, value: String)
    case removeHeader(name: String)
    case setBodyText(String)
    case setEnvironmentValue(key: String, value: String)
}

public enum TestStep: Sendable, Equatable, Codable {
    case statusCodeEquals(Int)
    case headerContains(name: String, value: String)
    case bodyContains(String)
    case jsonFieldEquals(path: String, value: String)
    case setEnvironmentValue(key: String, value: String)
    case setEnvironmentValueFromJSON(key: String, path: String)
}

public struct TestResult: Sendable, Equatable {
    public var step: String
    public var passed: Bool
    public var message: String?

    public init(step: String, passed: Bool, message: String? = nil) {
        self.step = step
        self.passed = passed
        self.message = message
    }
}

public struct TestReport: Sendable, Equatable {
    public var results: [TestResult]

    public init(results: [TestResult]) {
        self.results = results
    }

    public var passedCount: Int {
        results.filter(\.passed).count
    }

    public var failedCount: Int {
        results.count - passedCount
    }

    public var succeeded: Bool {
        failedCount == 0
    }
}

public enum ScriptRunner {
    public static func applyPreRequest(
        _ steps: [PreRequestStep],
        request: inout HTTPRequest,
        environment: inout Environment
    ) {
        for step in steps {
            switch step {
            case .setHeader(let name, let value):
                request.headers[name] = VariableRenderer.render(value, environment: environment.values)
            case .removeHeader(let name):
                request.headers.removeValue(forKey: name)
            case .setBodyText(let text):
                request.body = .text(VariableRenderer.render(text, environment: environment.values))
            case .setEnvironmentValue(let key, let value):
                environment.setValue(
                    VariableRenderer.render(value, environment: environment.values),
                    for: key
                )
            }
        }
    }

    public static func runTests(
        _ steps: [TestStep],
        response: HTTPResponse,
        environment: inout Environment
    ) -> TestReport {
        var results: [TestResult] = []
        let bodyText = String(data: response.body, encoding: .utf8) ?? ""

        for step in steps {
            switch step {
            case .statusCodeEquals(let expected):
                let passed = response.statusCode == expected
                results.append(
                    TestResult(
                        step: "statusCodeEquals(\(expected))",
                        passed: passed,
                        message: passed ? nil : "expected \(expected), got \(response.statusCode)"
                    )
                )
            case .headerContains(let name, let value):
                let rendered = VariableRenderer.render(value, environment: environment.values)
                let actual = response.headers[name]
                let passed = actual?.contains(rendered) == true
                results.append(
                    TestResult(
                        step: "headerContains(\(name))",
                        passed: passed,
                        message: passed ? nil : "header \(name) not contains \(rendered)"
                    )
                )
            case .bodyContains(let expected):
                let rendered = VariableRenderer.render(expected, environment: environment.values)
                let passed = bodyText.contains(rendered)
                results.append(
                    TestResult(
                        step: "bodyContains",
                        passed: passed,
                        message: passed ? nil : "body not contains expected text"
                    )
                )
            case .jsonFieldEquals(let path, let expected):
                let rendered = VariableRenderer.render(expected, environment: environment.values)
                let actual = jsonValue(path: path, data: response.body)
                let passed = actual == rendered
                results.append(
                    TestResult(
                        step: "jsonFieldEquals(\(path))",
                        passed: passed,
                        message: passed ? nil : "expected \(rendered), got \(actual ?? "nil")"
                    )
                )
            case .setEnvironmentValue(let key, let value):
                environment.setValue(
                    VariableRenderer.render(value, environment: environment.values),
                    for: key
                )
                results.append(TestResult(step: "setEnvironmentValue(\(key))", passed: true))
            case .setEnvironmentValueFromJSON(let key, let path):
                if let value = jsonValue(path: path, data: response.body) {
                    environment.setValue(value, for: key)
                    results.append(TestResult(step: "setEnvironmentValueFromJSON(\(key))", passed: true))
                } else {
                    results.append(
                        TestResult(
                            step: "setEnvironmentValueFromJSON(\(key))",
                            passed: false,
                            message: "json path \(path) not found"
                        )
                    )
                }
            }
        }

        return TestReport(results: results)
    }
}

private func jsonValue(path: String, data: Data) -> String? {
    guard
        let jsonObject = try? JSONSerialization.jsonObject(with: data),
        !path.isEmpty
    else {
        return nil
    }

    let keys = path.split(separator: ".").map(String.init)
    var current: Any = jsonObject

    for key in keys {
        if let index = Int(key), let array = current as? [Any], array.indices.contains(index) {
            current = array[index]
        } else if let dictionary = current as? [String: Any], let value = dictionary[key] {
            current = value
        } else {
            return nil
        }
    }

    switch current {
    case let value as String:
        return value
    case let value as NSNumber:
        return value.stringValue
    case is NSNull:
        return nil
    default:
        if let data = try? JSONSerialization.data(withJSONObject: current),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }
}
