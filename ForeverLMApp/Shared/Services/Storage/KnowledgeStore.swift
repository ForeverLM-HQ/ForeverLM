import Foundation
import SQLite3
import OSLog
import CloudKit

// MARK: - Entity Types

/// Entity types that can carry an embedding vector.
enum KnowledgeEntityType: String, Codable {
    case source
    case sourceChunk = "source_chunk"
    case concept
}

// MARK: - KnowledgeStore

/// SQLite-backed store for sources, source content, and embeddings.
///
/// Thread safety: SQLite is opened with FULLMUTEX, so concurrent access is safe.
/// This class is always accessed from within `StorageService` (an actor), providing
/// additional serialization. Marked `@unchecked Sendable` for cross-actor passing.
final class KnowledgeStore: @unchecked Sendable {
    var db: OpaquePointer?
    let dbPath: String
    /// Canonical root for files whose metadata lives in SQLite. Production keeps
    /// the database in `.appdata` and content in the sibling `Content` tree;
    /// tests normally use one directory for both.
    let contentDirectory: URL?
    /// Historical iCloud roots remain read-only compatibility locations. Files
    /// found here are republished through CloudKit but never moved or deleted by
    /// database startup.
    let legacyContentDirectories: [URL]
    /// A launch-time copy of the app's pre-SQLite preference domain. Generic
    /// stores deliberately receive an empty snapshot so temporary databases,
    /// test fixtures, and auxiliary readers cannot absorb host-machine state.
    let startupPreferenceSnapshot: [String: Any]
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "KnowledgeStore")
    var syncTrackingSuppressionDepth = 0
    /// The sync generation this store runs under (D40). Generation 1 behaves exactly as the builds
    /// before schema v2; tests that exercise a generation-2 path pass `.two`.
    let syncGeneration: SyncGeneration
    /// Once a generation-2 store's activation has finished, generation 1's change queue (`sync_changes`) is
    /// never written again: the outbox's triggers record every change, and a row left here would read as a
    /// pending old-world change at a reconcile (§13.5). Only a true answer is kept.
    private let activatedLock = NSLock()
    private var activatedCache = false
    var writesGenerationOneQueue: Bool {
        guard syncGeneration == .two else { return true }
        activatedLock.lock()
        defer { activatedLock.unlock() }
        if !activatedCache, (try? isActivatedForGeneration2()) == true { activatedCache = true }
        return !activatedCache
    }
    /// The rollback copy this open took before migrating (§13.3 step 1), nil when it took none, as
    /// every later open of the store in the launch does.
    var rollbackCopy: KnowledgeRollbackCopy.Record?
    /// `PRAGMA quick_check` of that copy, running on its own `.utility` queue while the store is used.
    var rollbackCopyCheck: Task<KnowledgeRollbackCopy.Record, Never>?
    /// Why a copy this open should have taken could not be taken.
    var rollbackCopyFailure: String?
    /// The room the disk lacked for that copy, when this open therefore held the store below 154.
    var upgradeWaitingForSpace: KnowledgeRollbackCopy.SpaceCheck?
    /// The source types automatic audio is switched on for, the only kinds a
    /// change to a source's text prepares Listen for at once
    /// (`enqueueSourceListenableContentPreparation`). Empty unless the owner
    /// installs the live settings — `StorageService` and the sync engine do —
    /// so a temporary store or a test never reads this Mac's preferences.
    var automaticAudioSourceTypes: @Sendable () -> Set<String> = { [] }
    /// What the open inbound apply has written into the rows so far (`ProjectionApply`): handed to
    /// `appliedRemoteChangesHandler` when its transaction commits, dropped when it rolls back.
    var appliedRemoteChanges = AppliedRemoteChanges()
    /// Told what each committed inbound apply changed, and of a source save whose copy was behind the
    /// stored row (`saveSource`), so a stale copy on screen is read again. Nil unless the owner
    /// installs it, as `StorageService` does for the app's own store, so a temporary store or a test
    /// never reaches the app's surfaces.
    var appliedRemoteChangesHandler: (@Sendable (AppliedRemoteChanges) -> Void)?

    #if DEBUG
    /// Deterministic unit-test seam for proving that inbound MemoryItem conflict
    /// decisions happen only after the SQLite write lock is acquired. Production
    /// code never installs this closure.
    var beforeInboundMemoryItemWriteTransactionForTesting: (() throws -> Void)?

    /// Deterministic unit-test seam for holding a projection-view replacement
    /// between its DROP and CREATE statements. The surrounding transaction must
    /// keep the previous view visible to readers on other connections.
    var afterSourceProjectionDropForTesting: (() -> Void)?
    #endif

    /// The current user's home directory, cached at init time.
    /// Used to normalize absolute paths that were stored on a different Mac (different username).
    let currentHome: String

    /// Initialize with a directory URL. The database file will be created at `<dir>/knowledge.db`.
    ///
    /// Opening decides and takes the rollback copy (§13.3 step 1) and then migrates, under one gate per
    /// database file, so a second open in this process waits for the first and finds the store current.
    /// The first open decides about the copy for the launch; later ones follow it.
    /// When the copy has no room on the disk (`freeSpace`, the volume's capacity for important usage),
    /// generation 1 migrates the store through 153 and no further, and generation 2 refuses.
    init(
        storeDirectory: URL,
        contentDirectory: URL? = nil,
        legacyContentDirectories: [URL] = [],
        startupPreferenceSnapshot: [String: Any] = [:],
        syncGeneration: SyncGeneration = ForeverLMRuntimeIdentity.syncGeneration,
        freeSpace: (URL) throws -> Int64? = KnowledgeRollbackCopy.availableCapacity(at:)
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        self.dbPath = storeDirectory.appendingPathComponent("knowledge.db").path
        self.contentDirectory = (contentDirectory ?? storeDirectory).standardizedFileURL
        self.legacyContentDirectories = legacyContentDirectories.map(\.standardizedFileURL)
        self.startupPreferenceSnapshot = startupPreferenceSnapshot
        self.currentHome = NSHomeDirectory()
        self.syncGeneration = syncGeneration

        let openGate = KnowledgeStoreOpening.gate(forDatabaseAt: dbPath)
        openGate.lock()
        defer { openGate.unlock() }

        var dbPtr: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &dbPtr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let dbPtr else {
            if let dbPtr { sqlite3_close(dbPtr) }
            throw KnowledgeStoreError.openFailed(rc)
        }
        sqlite3_busy_timeout(dbPtr, 10_000)
        self.db = dbPtr

        do {
            try pragmas()
            // A generation-1 build never opens a store generation 2 runs on (§13.2): it would not
            // send what the learner writes, and the triggers would record it for nobody.
            if syncGeneration == .one, try isActivatedForGeneration2() {
                throw KnowledgeStoreError.activatedForGeneration2
            }
            // Short of room for the copy, generation 1 still runs every step below 154, none of
            // which needs one, and waits at 153 for a launch with room.
            let laysDownSchema154 = try takeRollbackCopyBeforeMigrating(storeDirectory: storeDirectory, freeSpace: freeSpace)
            try createSchema(stoppingBeforeSchema154: !laysDownSchema154)
        } catch {
            sqlite3_close(dbPtr)
            self.db = nil
            throw error
        }
        // A store opened while a `full` activation holds the library read-only is read-only too.
        KnowledgeStoreWriteGate.register(self)
    }

    /// In-memory initializer for unit tests. Opens an empty `:memory:` database and
    /// installs the current schema.
    init(inMemory: Bool, syncGeneration: SyncGeneration = ForeverLMRuntimeIdentity.syncGeneration) throws {
        precondition(inMemory, "Use init(storeDirectory:) for on-disk databases")
        self.dbPath = ":memory:"
        self.contentDirectory = nil
        self.legacyContentDirectories = []
        self.startupPreferenceSnapshot = [:]
        self.currentHome = NSHomeDirectory()
        self.syncGeneration = syncGeneration

        var dbPtr: OpaquePointer?
        let rc = sqlite3_open_v2(":memory:", &dbPtr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let dbPtr else {
            if let dbPtr { sqlite3_close(dbPtr) }
            throw KnowledgeStoreError.openFailed(rc)
        }
        sqlite3_busy_timeout(dbPtr, 10_000)
        self.db = dbPtr

        do {
            try pragmas()
            try createSchema()
        } catch {
            sqlite3_close(dbPtr)
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - SQLite Helpers

    func tableColumnNames(_ tableName: String) throws -> Set<String> {
        var result = Set<String>()
        try query("PRAGMA table_info(\(tableName))") { stmt in
            if let name = self.string(stmt, 1) {
                result.insert(name)
            }
        }
        return result
    }

    /// `tableColumnNames` plus generated columns, which `table_info` leaves out.
    func tableColumnNamesIncludingGenerated(_ tableName: String) throws -> Set<String> {
        var result = Set<String>()
        try query("PRAGMA table_xinfo(\(tableName))") { stmt in
            if let name = self.string(stmt, 1) {
                result.insert(name)
            }
        }
        return result
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(err)
            throw KnowledgeStoreError.execFailed(sql, msg)
        }
    }

    func execBind(_ sql: String, _ binder: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            throw KnowledgeStoreError.execFailed(sql, msg)
        }
        defer { sqlite3_finalize(stmt) }
        binder(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed"
            throw KnowledgeStoreError.execFailed(sql, msg)
        }
    }

    func query(_ sql: String, _ handler: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            throw KnowledgeStoreError.execFailed(sql, msg)
        }
        defer { sqlite3_finalize(stmt) }
        try stepRows(stmt, sql: sql, handler)
    }

    /// Steps a prepared statement to its end, handing each row to `handler`.
    /// Until 2026-09-19 the loop was `while step == SQLITE_ROW`, which read a
    /// failing step — SQLITE_BUSY after the timeout, SQLITE_IOERR, SQLITE_CORRUPT,
    /// SQLITE_FULL, SQLITE_INTERRUPT — as "no more rows" and returned normally
    /// with whatever had arrived, so a library could "shrink", a dedupe lookup
    /// could say "not found" and a sync backfill could see an empty table with
    /// nothing surfaced. Only SQLITE_DONE ends a query quietly now.
    private func stepRows(_ stmt: OpaquePointer?, sql: String, _ handler: (OpaquePointer?) throws -> Void) throws {
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try handler(stmt)
                continue
            }
            guard rc == SQLITE_DONE else {
                let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed (\(rc))"
                throw KnowledgeStoreError.execFailed(sql, msg)
            }
            return
        }
    }

    func queryBind(_ sql: String, bind binder: (OpaquePointer?) -> Void, _ handler: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            throw KnowledgeStoreError.execFailed(sql, msg)
        }
        defer { sqlite3_finalize(stmt) }
        binder(stmt)
        try stepRows(stmt, sql: sql, handler)
    }

    func bind(_ stmt: OpaquePointer?, _ idx: Int, _ value: String?) {
        if let value {
            SQLiteText.bind(stmt, Int32(idx), value)
        } else {
            sqlite3_bind_null(stmt, Int32(idx))
        }
    }

    func bind(_ stmt: OpaquePointer?, _ idx: Int, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, Int32(idx), Int32(value))
        } else {
            sqlite3_bind_null(stmt, Int32(idx))
        }
    }

    func bind(_ stmt: OpaquePointer?, _ idx: Int, _ value: Double) {
        sqlite3_bind_double(stmt, Int32(idx), value)
    }

    func bind(_ stmt: OpaquePointer?, _ idx: Int, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, Int32(idx), value)
        } else {
            sqlite3_bind_null(stmt, Int32(idx))
        }
    }

    func bind(_ stmt: OpaquePointer?, _ idx: Int, _ value: Data?) {
        guard let value else {
            sqlite3_bind_null(stmt, Int32(idx))
            return
        }
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                stmt,
                Int32(idx),
                buffer.baseAddress,
                Int32(value.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
    }

    func string(_ stmt: OpaquePointer?, _ idx: Int) -> String? {
        SQLiteText.column(stmt, Int32(idx))
    }

    func optionalInt(_ stmt: OpaquePointer?, _ idx: Int) -> Int? {
        guard sqlite3_column_type(stmt, Int32(idx)) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, Int32(idx)))
    }

    func optionalDouble(_ stmt: OpaquePointer?, _ idx: Int) -> Double? {
        guard sqlite3_column_type(stmt, Int32(idx)) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, Int32(idx))
    }

    func data(_ stmt: OpaquePointer?, _ idx: Int) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, Int32(idx)) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, Int32(idx)))
        guard length > 0 else { return Data() }
        return Data(bytes: bytes, count: length)
    }

    func jsonString(from values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func decodeStringArray(json: String?) -> [String]? {
        guard let json else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    /// Shared ISO-8601 formatter for `archived_at` text columns. Hoisted to a
    /// `static let` so hot read/write paths don't allocate a formatter per row.
    /// `ISO8601DateFormatter` is safe for concurrent formatting/parsing.
    static let iso8601Formatter = ISO8601DateFormatter()

    static func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

// MARK: - Model Reconstruction

/// These functions reconstruct model objects with `let id` fields from database values.
/// They use the Codable round-trip: build a dictionary → encode to JSON → decode to model.
extension KnowledgeStore {

    func reconstructStudioArticle(
        id: String, url: String, title: String, domain: String, dateAdded: Date,
        content: String?, wordCount: Int?, state: StudioArticleState,
        errorMessage: String?, sourceType: StudioSourceType,
        artworkURL: String?, discoveryOrigin: DiscoveryOrigin?, parentGroup: String?,
        localFilePath: String?, podcastWebPageURL: String?, author: String?,
        publicURL: String? = nil,
        journal: String? = nil, publishedYear: String? = nil,
        doi: String? = nil,
        paperIngestionMethod: PaperIngestionMethod? = nil,
        courseSortIndex: Int? = nil, lectureGroupId: String? = nil,
        isHidden: Bool = false
    ) -> StudioArticle? {
        // Build a JSON dictionary matching StudioArticle's CodingKeys
        var dict: [String: Any] = [
            "id": id,
            "url": url,
            "title": title,
            "domain": domain,
            "dateAdded": dateAdded.timeIntervalSinceReferenceDate,
            "state": state.rawValue,
            "sourceType": sourceType.rawValue,
        ]
        if let content { dict["content"] = content }
        if let wordCount { dict["wordCount"] = wordCount }
        if let errorMessage { dict["errorMessage"] = errorMessage }
        if let artworkURL { dict["artworkURL"] = artworkURL }
        if let discoveryOrigin { dict["discoveryOrigin"] = discoveryOrigin.rawValue }
        if let parentGroup { dict["parentGroup"] = parentGroup }
        if let localFilePath { dict["localFilePath"] = localFilePath }
        if let publicURL { dict["publicURL"] = publicURL }
        if let podcastWebPageURL { dict["podcastWebPageURL"] = podcastWebPageURL }
        if let author { dict["author"] = author }
        if let journal { dict["journal"] = journal }
        if let publishedYear { dict["publishedYear"] = publishedYear }
        if let doi { dict["doi"] = doi }
        if let paperIngestionMethod { dict["paperIngestionMethod"] = paperIngestionMethod.rawValue }
        if let courseSortIndex { dict["courseSortIndex"] = courseSortIndex }
        if let lectureGroupId { dict["lectureGroupId"] = lectureGroupId }
        dict["isHidden"] = isHidden

        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode(StudioArticle.self, from: jsonData)
    }

}

// MARK: - Errors

enum KnowledgeStoreError: Error, LocalizedError {
    /// Whether `error` is SQLite giving up on a lock another connection held for
    /// the whole busy timeout. The write can succeed a moment later.
    static func isTransientLock(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("database is locked") || message.contains("database is busy")
    }

    case openFailed(Int32)
    case execFailed(String, String)
    case invalidData(String)
    /// A browser-authored CloudKit PDF record is structurally invalid and must
    /// not be retried until the server record changes.
    case permanentInboundWebPDF(String)
    /// The record is valid, but its CKAsset or one of the destination file
    /// providers was temporarily unavailable. CKSyncEngine may already advance
    /// its token, so callers must persist an explicit direct-fetch retry.
    case transientInboundWebPDF(String)
    case sourceContentChanged
    /// The identity a row was about to take is already held by another active
    /// source; the caller folds the two together rather than keeping both.
    case duplicateSourceIdentity(existingSourceID: String)
    /// Generation 2 cannot start on a store it could not copy first, and the
    /// disk has no room for the copy (§13.3 step 1).
    case noRoomForRollbackCopy(bytesToFree: Int64)
    /// A generation-1 build opened a store generation 2 runs on (§13.2).
    case activatedForGeneration2

    var errorDescription: String? {
        switch self {
        case .openFailed(let code): return "Failed to open knowledge database (SQLite error \(code))"
        case .execFailed(let sql, let msg): return "SQLite error: \(msg) [SQL: \(sql.prefix(200))]"
        case .invalidData(let message): return message
        case .permanentInboundWebPDF(let message): return message
        case .transientInboundWebPDF(let message): return message
        case .sourceContentChanged:
            return "Source text changed while listenable content was being prepared; it will be retried."
        case .duplicateSourceIdentity(let existingSourceID):
            return "Another source (\(existingSourceID)) already carries this identity."
        case .noRoomForRollbackCopy(let bytesToFree):
            return "Free up \(KnowledgeRollbackCopy.readableBytes(bytesToFree)) on this Mac: ForeverLM keeps a copy of your library before it moves it to the new iCloud store."
        case .activatedForGeneration2:
            return "This library moved to the new iCloud store. Install the current ForeverLM."
        }
    }
}

/// Text that goes into SQLite and comes back out byte for byte.
///
/// Binding a string as a C string (`utf8String` with length -1) stores only
/// what precedes its first U+0000, and reading one back with
/// `String(cString:)` stops at the same place. PDFKit hands an unmapped glyph
/// back as U+0000 — a minus sign, an "fi" ligature — so on 2026-09-23 three
/// papers re-extracted by cleaner v19 kept 1,631, 16,241 and 91,591 of their
/// 65k, 114k and 140k characters while `raw_sha256`, `clean_sha256` and
/// `word_count`, computed on the Swift string, described the whole paper. The
/// row then contradicted itself, its CloudKit record carried a raw asset that
/// failed the integrity check against its own metadata, and Listen read the
/// stub. An explicit byte length makes storage faithful to the string the
/// caller hashed, whatever it contains.
enum SQLiteText {
    /// SQLITE_TRANSIENT: SQLite copies the bytes before the call returns.
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    @discardableResult
    static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) -> Int32 {
        var value = value
        return value.withUTF8 { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else {
                // An empty string is text, not NULL: a nil pointer would bind NULL.
                return sqlite3_bind_text(stmt, index, "", 0, transient)
            }
            return sqlite3_bind_text64(
                stmt,
                index,
                UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self),
                sqlite3_uint64(buffer.count),
                transient,
                UInt8(SQLITE_UTF8)
            )
        }
    }

    /// The column's full text, embedded U+0000 included. `sqlite3_column_bytes`
    /// must follow `sqlite3_column_text`, which is the call that fixes the
    /// value's encoding as UTF-8.
    static func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
    }
}
