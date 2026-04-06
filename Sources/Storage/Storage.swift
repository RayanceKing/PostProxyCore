import Foundation
import Protocol

public protocol HistoryStore: Sendable {
    func save(_ record: HistoryRecord) async
    func list(limit: Int) async -> [HistoryRecord]
    func clear() async
}

public actor InMemoryHistoryStore: HistoryStore {
    private var records: [HistoryRecord] = []

    public init() {}

    public func save(_ record: HistoryRecord) {
        records.append(record)
    }

    public func list(limit: Int = 100) -> [HistoryRecord] {
        Array(records.suffix(max(0, limit))).reversed()
    }

    public func clear() {
        records.removeAll()
    }
}
