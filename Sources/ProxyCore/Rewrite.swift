import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
import Protocol

public enum RewriteAction: Sendable, Equatable {
    case setRequestHeader(name: String, value: String)
    case removeRequestHeader(name: String)
    case replaceRequestBodyText(find: String, replace: String)
    case setResponseHeader(name: String, value: String)
    case removeResponseHeader(name: String)
    case replaceResponseBodyText(find: String, replace: String)
    case setResponseStatus(Int)
}

public struct RewriteRule: Sendable, Equatable {
    public var id: UUID
    public var enabled: Bool
    public var hostContains: String?
    public var pathContains: String?
    public var methods: Set<String>
    public var actions: [RewriteAction]

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        hostContains: String? = nil,
        pathContains: String? = nil,
        methods: Set<String> = [],
        actions: [RewriteAction]
    ) {
        self.id = id
        self.enabled = enabled
        self.hostContains = hostContains
        self.pathContains = pathContains
        self.methods = methods
        self.actions = actions
    }
}

public final class RewriteEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PostProxyCore.RewriteEngine", attributes: .concurrent)
    private var rules: [RewriteRule]

    public init(rules: [RewriteRule] = []) {
        self.rules = rules
    }

    public func listRules() -> [RewriteRule] {
        queue.sync { rules }
    }

    public func setRules(_ newRules: [RewriteRule]) {
        queue.sync(flags: .barrier) {
            rules = newRules
        }
    }

    public func addRule(_ rule: RewriteRule) {
        queue.sync(flags: .barrier) {
            rules.append(rule)
        }
    }

    public func clearRules() {
        queue.sync(flags: .barrier) {
            rules.removeAll()
        }
    }

    func applyRequest(
        host: String,
        methodRaw: String,
        path: String,
        head: inout HTTPRequestHead,
        body: inout ByteBuffer
    ) {
        let currentRules = queue.sync { rules }
        for rule in currentRules where shouldApply(rule: rule, host: host, methodRaw: methodRaw, path: path) {
            for action in rule.actions {
                switch action {
                case .setRequestHeader(let name, let value):
                    head.headers.replaceOrAdd(name: name, value: value)
                case .removeRequestHeader(let name):
                    head.headers.remove(name: name)
                case .replaceRequestBodyText(let find, let replace):
                    replaceBodyText(find: find, replace: replace, body: &body, headers: &head.headers)
                default:
                    continue
                }
            }
        }
    }

    func applyResponse(
        host: String,
        methodRaw: String,
        path: String,
        head: inout HTTPResponseHead,
        body: inout ByteBuffer
    ) {
        let currentRules = queue.sync { rules }
        for rule in currentRules where shouldApply(rule: rule, host: host, methodRaw: methodRaw, path: path) {
            for action in rule.actions {
                switch action {
                case .setResponseHeader(let name, let value):
                    head.headers.replaceOrAdd(name: name, value: value)
                case .removeResponseHeader(let name):
                    head.headers.remove(name: name)
                case .replaceResponseBodyText(let find, let replace):
                    replaceBodyText(find: find, replace: replace, body: &body, headers: &head.headers)
                case .setResponseStatus(let code):
                    head.status = HTTPResponseStatus(statusCode: code)
                default:
                    continue
                }
            }
        }
    }

    private func shouldApply(rule: RewriteRule, host: String, methodRaw: String, path: String) -> Bool {
        guard rule.enabled else {
            return false
        }
        if let hostContains = rule.hostContains, !host.localizedCaseInsensitiveContains(hostContains) {
            return false
        }
        if let pathContains = rule.pathContains, !path.localizedCaseInsensitiveContains(pathContains) {
            return false
        }
        if !rule.methods.isEmpty, !rule.methods.contains(methodRaw.uppercased()) {
            return false
        }
        return true
    }

    private func replaceBodyText(
        find: String,
        replace: String,
        body: inout ByteBuffer,
        headers: inout HTTPHeaders
    ) {
        guard
            let original = body.getString(at: body.readerIndex, length: body.readableBytes),
            !find.isEmpty
        else {
            return
        }
        let updated = original.replacingOccurrences(of: find, with: replace)
        guard updated != original else {
            return
        }
        body = ByteBuffer(string: updated)
        headers.replaceOrAdd(name: "Content-Length", value: "\(body.readableBytes)")
    }
}
