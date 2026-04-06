import Foundation
import Testing
@testable import Protocol

@Test("Render template with environment variables")
func renderTemplate() {
    let template = RequestTemplate(
        name: "user-list",
        url: "https://{{host}}/api/{{version}}/users",
        method: .get,
        headers: ["Authorization": "Bearer {{token}}"],
        body: .none
    )

    let result = template.render(using: [
        "host": "example.com",
        "version": "v1",
        "token": "abc123"
    ])

    switch result {
    case .failure(let error):
        Issue.record("unexpected failure: \(error)")
    case .success(let request):
        #expect(request.url.absoluteString == "https://example.com/api/v1/users")
        #expect(request.headers["Authorization"] == "Bearer abc123")
    }
}

@Test("Environment values render and can be updated")
func environmentValues() {
    var environment = Environment(
        name: "dev",
        variables: [
            EnvironmentVariable(key: "host", value: "example.com"),
            EnvironmentVariable(key: "token", value: "abc", enabled: false)
        ]
    )

    #expect(environment.values["host"] == "example.com")
    #expect(environment.values["token"] == nil)

    environment.setValue("v1", for: "version")
    #expect(environment.values["version"] == "v1")
}

@Test("Script runner validates response and writes environment")
func scriptRunnerTests() {
    var environment = Environment(name: "qa")
    let response = HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json", "X-Trace": "trace-123"],
        body: Data(#"{"data":{"token":"xyz","id":7},"message":"ok"}"#.utf8),
        durationMS: 18
    )

    let report = ScriptRunner.runTests(
        [
            .statusCodeEquals(200),
            .headerContains(name: "X-Trace", value: "trace"),
            .jsonFieldEquals(path: "data.id", value: "7"),
            .setEnvironmentValueFromJSON(key: "token", path: "data.token")
        ],
        response: response,
        environment: &environment
    )

    #expect(report.succeeded)
    #expect(environment.values["token"] == "xyz")
}

@Test("Traffic classifier identifies websocket, sse, grpc and graphql")
func trafficClassifier() {
    let websocket = TrafficClassifier.classify(
        requestHeaders: ["Upgrade": "websocket"],
        responseHeaders: [:],
        path: "/chat",
        httpVersion: "1.1"
    )
    #expect(websocket == .websocket)

    let sse = TrafficClassifier.classify(
        requestHeaders: ["Accept": "text/event-stream"],
        responseHeaders: [:],
        path: "/events",
        httpVersion: "1.1"
    )
    #expect(sse == .sse)

    let grpc = TrafficClassifier.classify(
        requestHeaders: ["Content-Type": "application/grpc+proto"],
        responseHeaders: [:],
        path: "/pkg.Service/Call",
        httpVersion: "2"
    )
    #expect(grpc == .grpc)

    let graphql = TrafficClassifier.classify(
        requestHeaders: ["Content-Type": "application/json"],
        responseHeaders: [:],
        path: "/graphql",
        httpVersion: "1.1"
    )
    #expect(graphql == .graphql)
}

@Test("SSE parser splits stream into events")
func sseParser() {
    let raw = """
    id: 1
    event: message
    data: hello

    id: 2
    data: world

    """
    let events = SSEParser.parse(raw)
    #expect(events.count == 2)
    #expect(events[0].id == "1")
    #expect(events[0].event == "message")
    #expect(events[0].data == "hello")
    #expect(events[1].data == "world")
}

@Test("gRPC parser decodes binary frames")
func grpcParser() {
    let payload = Data([0x41, 0x42, 0x43]) // ABC
    var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x03]
    bytes.append(contentsOf: payload)
    let data = Data(bytes)

    let frames = GRPCParser.parseFrames(data)
    #expect(frames.count == 1)
    #expect(frames[0].compressed == false)
    #expect(frames[0].message == payload)
}

@Test("GraphQL request serializes to JSON body")
func graphQLRequestBody() {
    let gql = GraphQLRequest(
        operationName: "UserQuery",
        query: "query UserQuery { user { id } }",
        variables: ["id": "u-1"]
    )
    let body = gql.toRequestBody()
    switch body {
    case .text(let value):
        #expect(value.contains("\"operationName\":\"UserQuery\""))
        #expect(value.contains("\"query\":\"query UserQuery { user { id } }\""))
    default:
        Issue.record("GraphQL body should be text JSON")
    }
}
