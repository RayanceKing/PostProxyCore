import Foundation
import Testing
@testable import Protocol
@testable import Storage

@Test("History store returns newest records first")
func historyStoreOrdering() async {
    let store = InMemoryHistoryStore()

    for index in 1...3 {
        let request = HTTPRequest(
            name: "r\(index)",
            url: URL(string: "https://example.com/\(index)")!,
            method: .get
        )
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(), durationMS: index)
        await store.save(HistoryRecord(request: request, response: response))
    }

    let list = await store.list(limit: 2)
    #expect(list.count == 2)
    #expect(list[0].request.name == "r3")
    #expect(list[1].request.name == "r2")

    let found = await store.record(id: list[0].id)
    #expect(found?.request.name == "r3")
}

@Test("History store supports JSON and HAR export/import")
func historyExchangeJSONHAR() async throws {
    let source = InMemoryHistoryStore()
    let request = HTTPRequest(
        name: "sample",
        url: URL(string: "https://example.com/api")!,
        method: .post,
        headers: ["Content-Type": "application/json"],
        body: .text(#"{"name":"alice"}"#)
    )
    let response = HTTPResponse(
        statusCode: 201,
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"id":"u-1"}"#.utf8),
        durationMS: 42
    )
    await source.save(HistoryRecord(request: request, response: response))

    let jsonData = try await source.exportData(format: .json, limit: 100)
    let harData = try await source.exportData(format: .har, limit: 100)

    let jsonTarget = InMemoryHistoryStore()
    let harTarget = InMemoryHistoryStore()
    let jsonImported = try await jsonTarget.importData(jsonData, format: .json)
    let harImported = try await harTarget.importData(harData, format: .har)

    #expect(jsonImported == 1)
    #expect(harImported == 1)
    #expect(await jsonTarget.list(limit: 10).first?.response.statusCode == 201)
    #expect(await harTarget.list(limit: 10).first?.request.method == .post)
}

@Test("SQLite history store persists and lists records")
func sqliteHistoryStore() async throws {
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("postproxycore-tests")
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("history.sqlite")
        .path

    let store = try SQLiteHistoryStore(path: dbPath)
    let request = HTTPRequest(
        name: "sqlite",
        url: URL(string: "https://example.com/sqlite")!,
        method: .get
    )
    let response = HTTPResponse(statusCode: 200, headers: [:], body: Data("ok".utf8), durationMS: 9)
    let record = HistoryRecord(request: request, response: response)
    await store.save(record)

    let listed = await store.list(limit: 10)
    #expect(listed.count == 1)
    #expect(listed[0].request.name == "sqlite")

    let loaded = await store.record(id: record.id)
    #expect(loaded?.response.statusCode == 200)

    let exported = try await store.exportData(format: .json, limit: 10)
    #expect(!exported.isEmpty)
}
