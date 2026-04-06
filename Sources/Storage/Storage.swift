import Foundation
import Protocol

public protocol HistoryStore: Sendable {
    func save(_ record: HistoryRecord) async
    func list(limit: Int) async -> [HistoryRecord]
    func record(id: UUID) async -> HistoryRecord?
    func clear() async
}

public enum HistoryExchangeFormat: Sendable {
    case json
    case har
}

public enum HistoryExchangeError: Error, Sendable {
    case invalidHAR
    case invalidJSON
}

public protocol HistoryExchange: Sendable {
    func exportData(format: HistoryExchangeFormat, limit: Int) async throws -> Data
    func importData(_ data: Data, format: HistoryExchangeFormat) async throws -> Int
}

public actor InMemoryHistoryStore: HistoryStore, HistoryExchange {
    private var records: [HistoryRecord] = []

    public init() {}

    public func save(_ record: HistoryRecord) {
        records.append(record)
    }

    public func list(limit: Int = 100) -> [HistoryRecord] {
        Array(records.suffix(max(0, limit))).reversed()
    }

    public func record(id: UUID) -> HistoryRecord? {
        records.first { $0.id == id }
    }

    public func clear() {
        records.removeAll()
    }

    public func exportData(format: HistoryExchangeFormat, limit: Int = 1000) throws -> Data {
        let selected = Array(Array(records.suffix(max(0, limit))).reversed())
        switch format {
        case .json:
            return try HistoryCodec.exportJSON(records: selected)
        case .har:
            return try HistoryCodec.exportHAR(records: selected)
        }
    }

    public func importData(_ data: Data, format: HistoryExchangeFormat) throws -> Int {
        let imported: [HistoryRecord]
        switch format {
        case .json:
            imported = try HistoryCodec.importJSON(data: data)
        case .har:
            imported = try HistoryCodec.importHAR(data: data)
        }
        records.append(contentsOf: imported)
        return imported.count
    }
}
