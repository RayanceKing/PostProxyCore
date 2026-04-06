import Foundation
import Protocol
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteHistoryStore: HistoryStore, HistoryExchange {
    private var db: OpaquePointer?

    public init(path: String = SQLiteHistoryStore.defaultDatabasePath()) throws {
        try Self.ensureDirectory(for: path)
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteError.openFailed
        }
        self.db = handle
        try Self.execute(
            db: handle,
            sql: """
            CREATE TABLE IF NOT EXISTS history_records (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                request_json BLOB NOT NULL,
                response_json BLOB NOT NULL
            );
            """
        )
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    public func save(_ record: HistoryRecord) {
        guard let db else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard
            let requestData = try? encoder.encode(record.request),
            let responseData = try? encoder.encode(record.response)
        else {
            return
        }

        let sql = """
        INSERT OR REPLACE INTO history_records (id, created_at, request_json, response_json)
        VALUES (?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return
        }
        defer { sqlite3_finalize(statement) }

        _ = record.id.uuidString.withCString { cString in
            sqlite3_bind_text(statement, 1, cString, -1, sqliteTransientDestructor)
        }
        sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
        _ = requestData.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(buffer.count), sqliteTransientDestructor)
        }
        _ = responseData.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), sqliteTransientDestructor)
        }
        _ = sqlite3_step(statement)
    }

    public func list(limit: Int = 100) -> [HistoryRecord] {
        guard let db else { return [] }
        let sql = """
        SELECT id, created_at, request_json, response_json
        FROM history_records
        ORDER BY created_at DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
        return decodeRecords(from: statement)
    }

    public func record(id: UUID) -> HistoryRecord? {
        guard let db else { return nil }
        let sql = """
        SELECT id, created_at, request_json, response_json
        FROM history_records
        WHERE id = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        _ = id.uuidString.withCString { cString in
            sqlite3_bind_text(statement, 1, cString, -1, sqliteTransientDestructor)
        }
        return decodeRecords(from: statement).first
    }

    public func clear() {
        guard let db else { return }
        _ = try? Self.execute(db: db, sql: "DELETE FROM history_records;")
    }

    public func exportData(format: HistoryExchangeFormat, limit: Int = 1000) throws -> Data {
        let records = list(limit: limit)
        switch format {
        case .json:
            return try HistoryCodec.exportJSON(records: records.reversed())
        case .har:
            return try HistoryCodec.exportHAR(records: records.reversed())
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
        for record in imported {
            save(record)
        }
        return imported.count
    }

    public static func defaultDatabasePath() -> String {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".postproxycore")
            .appendingPathComponent("storage")
        #else
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("postproxycore-storage")
        #endif
        return base.appendingPathComponent("history.sqlite").path
    }

    private func decodeRecords(from statement: OpaquePointer) -> [HistoryRecord] {
        var records: [HistoryRecord] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idCString = sqlite3_column_text(statement, 0),
                let id = UUID(uuidString: String(cString: idCString))
            else {
                continue
            }
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))

            let requestBytes = sqlite3_column_blob(statement, 2)
            let requestLength = Int(sqlite3_column_bytes(statement, 2))
            let responseBytes = sqlite3_column_blob(statement, 3)
            let responseLength = Int(sqlite3_column_bytes(statement, 3))
            guard
                let requestBytes,
                let responseBytes
            else {
                continue
            }

            let requestData = Data(bytes: requestBytes, count: requestLength)
            let responseData = Data(bytes: responseBytes, count: responseLength)
            guard
                let request = try? decoder.decode(HTTPRequest.self, from: requestData),
                let response = try? decoder.decode(HTTPResponse.self, from: responseData)
            else {
                continue
            }
            records.append(HistoryRecord(id: id, request: request, response: response, createdAt: createdAt))
        }

        return records
    }

    private static func ensureDirectory(for databasePath: String) throws {
        let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func execute(db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer { sqlite3_free(errorMessage) }
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            throw SQLiteError.executeFailed
        }
    }
}

private enum SQLiteError: Error {
    case openFailed
    case executeFailed
}
