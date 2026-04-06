import Testing
@testable import Protocol
@testable import ProxyCore

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
