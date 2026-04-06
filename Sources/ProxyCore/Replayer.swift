import Foundation
import HTTPClient
import Protocol
import Storage

public enum ReplayError: Error, Sendable {
    case recordNotFound(UUID)
}

public actor SessionReplayer {
    private let historyStore: any HistoryStore
    private let requestSender: any RequestSending

    public init(
        historyStore: any HistoryStore,
        requestSender: any RequestSending = NIORequestSender()
    ) {
        self.historyStore = historyStore
        self.requestSender = requestSender
    }

    public func replay(recordID: UUID, saveAsNewRecord: Bool = true) async throws -> HistoryRecord {
        guard let source = await historyStore.record(id: recordID) else {
            throw ReplayError.recordNotFound(recordID)
        }
        return try await replay(source.request, saveAsNewRecord: saveAsNewRecord)
    }

    public func replay(_ request: HTTPRequest, saveAsNewRecord: Bool = true) async throws -> HistoryRecord {
        let startedAt = Date()
        let response = try await requestSender.send(request)
        let record = HistoryRecord(
            request: request,
            response: response,
            createdAt: startedAt
        )
        if saveAsNewRecord {
            await historyStore.save(record)
        }
        return record
    }
}
