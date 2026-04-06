import Foundation
import Testing
@testable import Protocol
@testable import HTTPClient

@Test("Request sender conforms to protocol")
func senderConformance() {
    let sender: any RequestSending = NIORequestSender()
    #expect(type(of: sender) == NIORequestSender.self)
}

@Test("Collection runner executes pre-request and tests")
func collectionRunnerExecution() async throws {
    let mock = MockRequestSender(
        response: HTTPResponse(
            statusCode: 201,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"user":{"id":"u-1"},"message":"created"}"#.utf8),
            durationMS: 23
        )
    )
    let runner = CollectionRunner(sender: mock)

    let item = RequestItem(
        name: "create-user",
        request: RequestTemplate(
            name: "create-user",
            url: "https://{{host}}/users",
            method: .post,
            headers: ["Authorization": "Bearer {{token}}"],
            body: .text(#"{"name":"neo"}"#)
        ),
        preRequest: [
            .setHeader(name: "X-Env", value: "{{envName}}")
        ],
        tests: [
            .statusCodeEquals(201),
            .setEnvironmentValueFromJSON(key: "userID", path: "user.id")
        ]
    )

    let environment = Environment(
        name: "dev",
        variables: [
            EnvironmentVariable(key: "host", value: "api.example.com"),
            EnvironmentVariable(key: "token", value: "abc"),
            EnvironmentVariable(key: "envName", value: "DEV")
        ]
    )
    let result = try await runner.run(item: item, environment: environment)

    #expect(result.request.url.absoluteString == "https://api.example.com/users")
    #expect(result.request.headers["X-Env"] == "DEV")
    #expect(result.report.succeeded)
    #expect(result.environment.values["userID"] == "u-1")
}

private struct MockRequestSender: RequestSending {
    let response: HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        response
    }
}
