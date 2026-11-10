// The on-device store of source usage history.

import Foundation
import SQLite3

/// The usage ledger's cache on this phone, one SQLite file in Application Support (which Xcode app
/// rebuilds preserve; only uninstalling the app removes it). A file written before keeps the old
/// zone mirror's table (version 1), unread.
final class MobileUsageHistoryStore {
    private static let schemaVersion: Int32 = 2
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            if let opened { sqlite3_close(opened) }
            throw MobileUsageHistoryStoreError.sqlite(message)
        }
        database = opened

        do {
            try migrateIfNeeded()
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func loadUsageHistorySnapshot() throws -> MobileUsageHistorySnapshot? {
        guard let database else { throw MobileUsageHistoryStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT state FROM mobile_usage_history_cache WHERE id = 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError() }
        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, 0) else {
            throw MobileUsageHistoryStoreError.invalidSnapshot
        }
        do {
            return try JSONDecoder().decode(
                MobileUsageHistorySnapshot.self,
                from: Data(bytes: bytes, count: byteCount)
            )
        } catch {
            throw MobileUsageHistoryStoreError.decode(error.localizedDescription)
        }
    }

    func saveUsageHistorySnapshot(_ snapshot: MobileUsageHistorySnapshot) throws {
        guard let database else { throw MobileUsageHistoryStoreError.closed }
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            throw MobileUsageHistoryStoreError.encode(error.localizedDescription)
        }

        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO mobile_usage_history_cache (id, state) VALUES (1, ?) " +
                    "ON CONFLICT(id) DO UPDATE SET state = excluded.state",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw sqliteError()
            }
            defer { sqlite3_finalize(statement) }
            let bindResult = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    1,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    Self.transientDestructor
                )
            }
            guard bindResult == SQLITE_OK else { throw sqliteError() }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migrateIfNeeded() throws {
        guard let database else { throw MobileUsageHistoryStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        let version = sqlite3_column_int(statement, 0)

        guard version <= Self.schemaVersion else {
            throw MobileUsageHistoryStoreError.unsupportedSchema(version)
        }
        guard version < Self.schemaVersion else { return }

        try execute("BEGIN IMMEDIATE")
        do {
            if version < 2 {
                try execute(
                    "CREATE TABLE IF NOT EXISTS mobile_usage_history_cache (" +
                        "id INTEGER PRIMARY KEY CHECK (id = 1), " +
                        "state BLOB NOT NULL)"
                )
            }
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw MobileUsageHistoryStoreError.closed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw MobileUsageHistoryStoreError.sqlite(message)
        }
    }

    private func sqliteError() -> MobileUsageHistoryStoreError {
        guard let database else { return .closed }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private enum MobileUsageHistoryStoreError: LocalizedError {
    case closed
    case sqlite(String)
    case encode(String)
    case decode(String)
    case invalidSnapshot
    case unsupportedSchema(Int32)

    var errorDescription: String? {
        switch self {
        case .closed:
            return "The mobile source catalog database is closed."
        case .sqlite(let message):
            return "The mobile source catalog database failed: \(message)"
        case .encode(let message):
            return "The mobile source catalog could not be encoded: \(message)"
        case .decode(let message):
            return "The saved mobile source catalog could not be decoded: \(message)"
        case .invalidSnapshot:
            return "The saved mobile source catalog is empty or corrupt."
        case .unsupportedSchema(let version):
            return "The mobile source catalog database uses unsupported schema version \(version)."
        }
    }
}
