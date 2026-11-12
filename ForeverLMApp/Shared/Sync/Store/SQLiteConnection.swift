import Foundation
import SQLite3

/// A value bound to, or read from, one SQLite parameter or column.
enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func text(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
    static func blob(_ value: Data?) -> SQLiteValue { value.map { .blob($0) } ?? .null }
    static func real(_ value: Double?) -> SQLiteValue { value.map { .real($0) } ?? .null }
    static func integer(_ value: Int64?) -> SQLiteValue { value.map { .integer($0) } ?? .null }
}

/// One result row while a query steps; read its columns before the handler returns.
struct SQLiteRow {
    let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

    /// The column's whole text, U+0000 included (the length is read, never the C string).
    func text(_ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func integer(_ column: Int32) -> Int64? {
        isNull(column) ? nil : sqlite3_column_int64(statement, column)
    }

    func real(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(statement, column)
    }

    func blob(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

enum SQLiteConnectionError: Error, LocalizedError, Equatable {
    case openFailed(path: String, message: String)
    case statementFailed(sql: String, message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path, let message):
            return "Could not open \(path): \(message)"
        case .statementFailed(let sql, let message):
            return "SQLite error: \(message) [SQL: \(sql.prefix(200))]"
        }
    }
}

/// The SQLite connection the replica runs on (docs/cloudkit-schema-design.md §6.6 step 3). On the Mac
/// it is `KnowledgeStore`'s own connection, inside its storage-actor transaction: the replica never
/// opens a handle of its own on `knowledge.db`, because an apply made on another handle would fire the
/// outbox triggers and echo back to the server for ever. On the iPhone it is the replica's own handle
/// (`SQLiteHandle`).
protocol SQLiteConnection: AnyObject {
    /// Runs one or more statements that take no parameters.
    func executeScript(_ sql: String) throws
    /// Runs one statement with positional parameters (`?`), stepping it to its end.
    func execute(_ sql: String, _ parameters: [SQLiteValue]) throws
    /// Runs one query, handing each row to `row` while it is current.
    func query(_ sql: String, _ parameters: [SQLiteValue], _ row: (SQLiteRow) throws -> Void) throws
    /// Rows the last finished INSERT, UPDATE or DELETE changed.
    var changedRowCount: Int { get }
    /// An inbound apply's transaction ended (`ReplicaStore.apply`): committed, or rolled back. The Mac's
    /// store hands what the apply changed in its rows to the surfaces that hold them in memory
    /// (`AppliedRemoteChanges`); a connection with nothing in memory ignores it.
    func replicaApplyDidEnd(committed: Bool)
}

extension SQLiteConnection {
    func replicaApplyDidEnd(committed: Bool) {}

    func execute(_ sql: String) throws { try execute(sql, []) }

    /// The first column of the first row, as text (nil when there is no row or it is NULL).
    func scalarText(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        var value: String?
        var seen = false
        try query(sql, parameters) { row in
            guard !seen else { return }
            seen = true
            value = row.text(0)
        }
        return value
    }

    func scalarInteger(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64? {
        var value: Int64?
        var seen = false
        try query(sql, parameters) { row in
            guard !seen else { return }
            seen = true
            value = row.integer(0)
        }
        return value
    }
}

/// The statement runner both connections share: prepare, bind, step to the end, finalize. A step
/// that fails is an error, never "no more rows" (as in `KnowledgeStore.stepRows`).
enum SQLiteStatements {
    /// SQLITE_TRANSIENT: SQLite copies the bytes before the bind returns.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    static func message(_ db: OpaquePointer?) -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    static func executeScript(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let text = error.map { String(cString: $0) } ?? message(db)
            sqlite3_free(error)
            throw SQLiteConnectionError.statementFailed(sql: sql, message: text)
        }
    }

    static func run(_ db: OpaquePointer?, _ sql: String, _ parameters: [SQLiteValue]) throws {
        try run(db, sql, parameters) { _ in }
    }

    static func run(
        _ db: OpaquePointer?,
        _ sql: String,
        _ parameters: [SQLiteValue],
        _ row: (SQLiteRow) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteConnectionError.statementFailed(sql: sql, message: message(db))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in parameters.enumerated() {
            try bind(value, at: Int32(offset + 1), in: statement, db: db, sql: sql)
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try row(SQLiteRow(statement: statement))
                continue
            }
            guard code == SQLITE_DONE else {
                throw SQLiteConnectionError.statementFailed(sql: sql, message: message(db))
            }
            return
        }
    }

    private static func bind(
        _ value: SQLiteValue,
        at index: Int32,
        in statement: OpaquePointer,
        db: OpaquePointer?,
        sql: String
    ) throws {
        let code: Int32
        switch value {
        case .null:
            code = sqlite3_bind_null(statement, index)
        case .integer(let number):
            code = sqlite3_bind_int64(statement, index, number)
        case .real(let number):
            code = sqlite3_bind_double(statement, index, number)
        case .text(var text):
            // An explicit byte length, so a U+0000 inside the text is stored too.
            code = text.withUTF8 { buffer in
                guard let base = buffer.baseAddress, !buffer.isEmpty else {
                    return sqlite3_bind_text(statement, index, "", 0, transient)
                }
                return sqlite3_bind_text64(
                    statement, index,
                    UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self),
                    sqlite3_uint64(buffer.count), transient, UInt8(SQLITE_UTF8)
                )
            }
        case .blob(let data):
            if data.isEmpty {
                // A zero-length blob is still a blob, not NULL.
                code = sqlite3_bind_zeroblob(statement, index, 0)
            } else {
                code = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob64(statement, index, buffer.baseAddress, sqlite3_uint64(buffer.count), transient)
                }
            }
        }
        guard code == SQLITE_OK else {
            throw SQLiteConnectionError.statementFailed(sql: sql, message: message(db))
        }
    }
}

/// A connection that owns its handle: the iPhone's replica file, and in-memory stores in tests.
final class SQLiteHandle: SQLiteConnection {
    private(set) var db: OpaquePointer?
    let path: String

    /// Opens (creating it if needed) the database at `path`, or an in-memory one for ":memory:".
    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            let text = SQLiteStatements.message(handle)
            sqlite3_close(handle)
            throw SQLiteConnectionError.openFailed(path: path, message: text)
        }
        sqlite3_busy_timeout(handle, 10_000)
        db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func executeScript(_ sql: String) throws {
        try SQLiteStatements.executeScript(db, sql)
    }

    func execute(_ sql: String, _ parameters: [SQLiteValue]) throws {
        try SQLiteStatements.run(db, sql, parameters)
    }

    func query(_ sql: String, _ parameters: [SQLiteValue], _ row: (SQLiteRow) throws -> Void) throws {
        try SQLiteStatements.run(db, sql, parameters, row)
    }

    var changedRowCount: Int { Int(sqlite3_changes(db)) }
}
