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
