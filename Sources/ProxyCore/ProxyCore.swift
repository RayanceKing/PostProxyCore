import Foundation
import Protocol

public struct ProxyFilter: Sendable {
    public var hostContains: String?
    public var methods: Set<HTTPMethod>

    public init(hostContains: String? = nil, methods: Set<HTTPMethod> = []) {
        self.hostContains = hostContains
        self.methods = methods
    }

    public func matches(_ session: ProxySession) -> Bool {
        if let hostContains, !session.host.localizedCaseInsensitiveContains(hostContains) {
            return false
        }
        if !methods.isEmpty, !methods.contains(session.method) {
            return false
        }
        return true
    }
}

public actor ProxySessionRegistry {
    private var sessions: [ProxySession] = []

    public init() {}

    public func register(_ session: ProxySession) {
        sessions.append(session)
    }

    public func all() -> [ProxySession] {
        sessions
    }

    public func filtered(by filter: ProxyFilter) -> [ProxySession] {
        sessions.filter { filter.matches($0) }
    }

    public func clear() {
        sessions.removeAll()
    }
}
