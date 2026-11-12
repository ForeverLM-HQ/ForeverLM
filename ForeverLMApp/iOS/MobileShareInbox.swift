import Foundation
import SQLite3

struct MobileShareInboxItem: Sendable {
    let id: String
    let url: String?
    let filePath: String?
    let title: String?
    let sourceType: String
    let createdAt: Date
    /// The notebook the share sheet filed it into; nil for the library only,
    /// and for an item queued without one.
    let notebookID: String?

    init(
        id: String,
        url: String?,
        filePath: String?,
        title: String?,
        sourceType: String,
        createdAt: Date,
        notebookID: String? = nil
    ) {
        self.id = id
        self.url = url
        self.filePath = filePath
        self.title = title
        self.sourceType = sourceType
        self.createdAt = createdAt
        self.notebookID = notebookID
    }
}

actor MobileShareInbox {
    static let shared = MobileShareInbox()

    static let appGroup = "group.com.foreverlm"
    private static let databaseName = "mobile-share-inbox.sqlite"

    /// The queue's file when it is not the app group's: a test's own.
    private let databaseURL: URL?

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    func enqueueURL(
        _ url: URL,
        title: String?,
        sourceType: String = "unclassified",
        notebookID: String? = nil
    ) throws {
        let item = MobileShareInboxItem(
            id: UUID().uuidString,
            url: url.absoluteString,
            filePath: nil,
            title: Self.cleanTitle(title),
            sourceType: sourceType,
            createdAt: Date(),
            notebookID: Self.cleanNotebookID(notebookID)
        )
        try insert(item)
    }

    func enqueueStashedFile(path: String, title: String?, notebookID: String? = nil) throws {
        let item = MobileShareInboxItem(
            id: UUID().uuidString,
            url: nil,
            filePath: path,
            title: Self.cleanTitle(title),
            sourceType: "file",
            createdAt: Date(),
            notebookID: Self.cleanNotebookID(notebookID)
        )
        try insert(item)
    }

    func pending() throws -> [MobileShareInboxItem] {
        try withDatabase { database in
            let sql = "SELECT id, url, file_path, title, source_type, created_at, notebook_id FROM inbox ORDER BY created_at ASC"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw Self.sqliteError(database)
            }
            defer { sqlite3_finalize(statement) }
            var values: [MobileShareInboxItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = Self.string(statement, 0) else { continue }
                values.append(
                    MobileShareInboxItem(
                        id: id,
                        url: Self.string(statement, 1),
                        filePath: Self.string(statement, 2),
                        title: Self.string(statement, 3),
                        sourceType: Self.string(statement, 4) ?? "article",
                        createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)),
                        notebookID: Self.string(statement, 6)
                    )
                )
            }
            return values
        }
    }

    func remove(_ item: MobileShareInboxItem) throws {
        try withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM inbox WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
                throw Self.sqliteError(database)
            }
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, 1, item.id)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.sqliteError(database) }
        }
        if let filePath = item.filePath {
            let url = URL(fileURLWithPath: filePath)
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Called inside NSItemProvider's file callback while its temporary URL is
    /// still valid. Only copies bytes into the extension's app-group container;
    /// the SQLite row is added asynchronously immediately afterward.
    nonisolated static func stashFile(from temporaryURL: URL) throws -> String {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { throw MobileShareInboxError.missingAppGroup }
        let directory = root
            .appendingPathComponent("ShareInboxFiles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(temporaryURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            return destination.path
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func insert(_ item: MobileShareInboxItem) throws {
        try withDatabase { database in
            let sql = "INSERT INTO inbox (id, url, file_path, title, source_type, created_at, notebook_id) VALUES (?, ?, ?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw Self.sqliteError(database)
            }
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, 1, item.id)
            Self.bind(statement, 2, item.url)
            Self.bind(statement, 3, item.filePath)
            Self.bind(statement, 4, item.title)
            Self.bind(statement, 5, item.sourceType)
            sqlite3_bind_double(statement, 6, item.createdAt.timeIntervalSinceReferenceDate)
            Self.bind(statement, 7, item.notebookID)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.sqliteError(database) }
        }
    }

    private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        let databaseURL: URL
        if let url = self.databaseURL {
            databaseURL = url
        } else {
            guard let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroup
            ) else { throw MobileShareInboxError.missingAppGroup }
            databaseURL = root.appendingPathComponent(Self.databaseName)
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            throw MobileShareInboxError.sqlite("Could not open the share inbox.")
        }
        defer { sqlite3_close(database) }
        // The app drains the queue while the share sheet may be adding to it.
        sqlite3_busy_timeout(database, 2_000)
        let createSQL = """
            CREATE TABLE IF NOT EXISTS inbox (
                id TEXT PRIMARY KEY,
                url TEXT,
                file_path TEXT,
                title TEXT,
                source_type TEXT NOT NULL,
                created_at REAL NOT NULL,
                notebook_id TEXT
            )
            """
        guard sqlite3_exec(database, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw Self.sqliteError(database)
        }
        try Self.addNotebookColumnIfMissing(database)
        return try operation(database)
    }

    /// A queue made without a notebook column gains one, and
    /// the items already in it are filed into no notebook. The share sheet and
    /// the app may both get here first, so a column the other just added is
    /// no failure.
    private static func addNotebookColumnIfMissing(_ database: OpaquePointer) throws {
        guard try !hasColumn("notebook_id", database) else { return }
        guard sqlite3_exec(database, "ALTER TABLE inbox ADD COLUMN notebook_id TEXT", nil, nil, nil) == SQLITE_OK else {
            let error = sqliteError(database)
            if try hasColumn("notebook_id", database) { return }
            throw error
        }
    }

    private static func hasColumn(_ name: String, _ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(inbox)", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if string(statement, 1) == name { return true }
        }
        return false
    }

    private static func cleanNotebookID(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func cleanTitle(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(500))
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(
                statement,
                index,
                (value as NSString).utf8String,
                -1,
                transientDestructor
            )
        }
        else { sqlite3_bind_null(statement, index) }
    }

    private static func string(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func sqliteError(_ database: OpaquePointer?) -> MobileShareInboxError {
        MobileShareInboxError.sqlite(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error")
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum MobileShareInboxError: LocalizedError {
    case missingAppGroup
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .missingAppGroup: return "The ForeverLM share container is unavailable."
        case .sqlite(let message): return "The shared source could not be queued: \(message)"
        }
    }
}
