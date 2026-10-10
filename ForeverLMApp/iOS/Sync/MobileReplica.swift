import Foundation
import OSLog

/// The CloudKit environment this iPhone build signs for (`com.apple.developer.icloud-container-environment`),
/// carried in Info.plist as `ForeverLMCloudKitEnvironment` from the `FOREVERLM_CLOUDKIT_ENVIRONMENT` build
/// setting: Development for Debug, Production for Release. Development and Production are separate
/// copies of every container with the same record names, so synced state kept on the phone (the
/// generation-1 mirror and its change token, the generation-2 replica) is kept apart per environment:
/// a Debug install, which shares the app's container with a TestFlight one, never reads Production's
/// tokens against Development or the other way round (docs/cloudkit-schema-design.md §2.1 C4).
enum MobileCloudKitEnvironment: String, Sendable {
    case development = "Development"
    case production = "Production"

    static let infoKey = "ForeverLMCloudKitEnvironment"

    /// This build's environment. A bundle without the key was signed for Production, as every iPhone
    /// build before the Debug entitlements was.
    static let current: MobileCloudKitEnvironment = resolve(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)

    static func resolve(_ value: String?) -> MobileCloudKitEnvironment {
        value.flatMap { MobileCloudKitEnvironment(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .production
    }

    /// A synced-state file's or folder's name in this environment: Production keeps the name every
    /// earlier build used, so a Release install finds what it had; Development's carries the environment.
    func scopedName(_ name: String) -> String {
        guard self == .development else { return name }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        return url.pathExtension.isEmpty ? "\(stem)-\(rawValue)" : "\(stem)-\(rawValue).\(url.pathExtension)"
    }
}

/// One index column of the replica: its SQL type and how it is read from a record's envelope when the
/// record is applied (D33). Values are the wire's: times are integer epoch milliseconds.
struct MobileIndexColumn {
    let name: String
    let sqlType: String
    let value: (SyncEnvelope) -> SQLiteValue

    /// A string field; NULL when absent, cleared or not a string (a spilled body).
    static func text(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "TEXT") { .text($0.fields[field]?.stringValue) }
    }

    /// A string field folded for sorting and matching (case and diacritics), as the Mac's lists sort.
    static func folded(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "TEXT") { envelope in
            .text(envelope.fields[field]?.stringValue.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) })
        }
    }

    static func integer(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "INTEGER") { .integer($0.fields[field]?.int64Value) }
    }

    static func bool(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "INTEGER") { envelope in
            .integer(envelope.fields[field]?.boolValue.map { $0 ? 1 : 0 })
        }
    }

    /// One key of an object field (`ingest.state`).
    static func member(_ name: String, _ field: String, _ key: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "TEXT") { .text($0.fields[field]?[key]?.stringValue) }
    }

    /// Whether a string field holds more than whitespace (`Exchange.userAnswer`): 1 or 0.
    static func nonEmpty(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "INTEGER NOT NULL DEFAULT 0") { envelope in
            let text = envelope.fields[field]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .integer(text.isEmpty ? 0 : 1)
        }
    }

    /// One whole-number key of an object field (`metrics.wordCount`).
    static func memberInteger(_ name: String, _ field: String, _ key: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "INTEGER") { .integer($0.fields[field]?[key]?.int64Value) }
    }

    /// Whether a map field holds a live element whose key starts with `prefix` (`files.audio.*`): 1 or 0.
    static func holdsPrefixed(_ name: String, _ field: String, _ prefix: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "INTEGER NOT NULL DEFAULT 0") { envelope in
            let held = envelope.fields[field]?.objectValue?.contains { key, value in
                key.hasPrefix(prefix) && value != .null
            } ?? false
            return .integer(held ? 1 : 0)
        }
    }

    /// A set field's members (the elements whose value is `true`), sorted, as a JSON array; NULL when
    /// it has none.
    static func members(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "TEXT") { envelope in
            let members = (envelope.fields[field]?.objectValue ?? [:]).compactMap { $0.value == .bool(true) ? $0.key : nil }.sorted()
            guard !members.isEmpty else { return .null }
            return .text(String(decoding: SyncJSON.array(members.map { .string($0) }).serialized(), as: UTF8.self))
        }
    }

    /// Whether a map field holds a live element (`files.cover`): 1 or 0.
    static func holds(_ name: String, _ field: String, _ element: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "INTEGER NOT NULL DEFAULT 0") { envelope in
            switch envelope.fields[field]?[element] {
            case nil, .null?: return .integer(0)
            default: return .integer(1)
            }
        }
    }

    /// An array of strings, joined for a list line (`authors`).
    static func joined(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "TEXT") { envelope in
            guard let items = envelope.fields[field]?.arrayValue?.compactMap(\.stringValue), !items.isEmpty else { return .null }
            return .text(items.joined(separator: "; "))
        }
    }

    /// Any field as its JSON text (a Setting's value).
    static func json(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "TEXT") { envelope in
            guard let value = envelope.fields[field] else { return .null }
            return .text(String(decoding: value.serialized(), as: UTF8.self))
        }
    }

    /// The field's stamp, as the chat ticks compare it (`Entry.state`, `Entry.approval`, §5.6).
    static func stamp(_ name: String, _ field: String) -> MobileIndexColumn {
        MobileIndexColumn(name: name, sqlType: "TEXT") { envelope in
            guard case .value(let stamp)? = envelope.stamps[field] else { return .null }
            return .text(stamp.rawValue)
        }
    }
}

/// One table of index columns for one record type, keyed by the zone and the record's logical id.
struct MobileIndexTable {
    let name: String
    let type: SyncRecordType
    let columns: [MobileIndexColumn]
    let indexes: [String]

    init(_ name: String, _ type: SyncRecordType, _ columns: [MobileIndexColumn], indexes: [String] = []) {
        self.name = name
        self.type = type
        self.columns = columns
        self.indexes = indexes
    }

    var createStatement: String {
        let lines = ["zone_key TEXT NOT NULL", "id TEXT NOT NULL", "record_name TEXT"]
            + columns.map { "\($0.name) \($0.sqlType)" }
            + ["PRIMARY KEY (zone_key, id)"]
        return "CREATE TABLE IF NOT EXISTS \(name) (\n    \(lines.joined(separator: ",\n    "))\n)"
    }

    var upsertStatement: String {
        let names = ["zone_key", "id", "record_name"] + columns.map(\.name)
        return "INSERT OR REPLACE INTO \(name) (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))"
    }
}

/// The iPhone's replica (docs/cloudkit-schema-design.md D33, §2.3, §14.1): one SQLite file of its own,
/// `Application Support/ForeverLMReplica.sqlite` (Development's carries the environment), with the
/// replica tables the Mac's `knowledge.db` holds (`ReplicaStore.sharedTables`) and, beside them, the
/// index columns the screens query, extracted from each record when it is applied. Screens never
/// decode the library to show it: they page through the index (`MobileProjection`) and decode a
/// record's payload only when it is opened.
///
/// It is the private engine's and SpaceSync's local store on the phone. Every body runs on one serial
/// queue that owns the connection, never on the main actor, so an apply's transaction never spans an
/// await and nothing else writes inside it. What the phone writes reaches the replica as RecordPatches
/// (`ck_patches`, §6.6), which an inbound record merges with (`InboundApply`) and the index shows merged;
/// `MobileRecordWriter` makes them and `MobilePatchOutbox` sends them. Nothing runs under generation 1.
final class MobileReplica: PrivateSyncLocalStore, PrivateSyncLocalState, @unchecked Sendable {
    /// The index tables' version. A build that changes a table or a column moves it, and the next open
    /// builds the index again from the replica's records (`rebuildIndex`), the one time every record is
    /// decoded outside an apply. 2: the columns the screens' read models need (WP19b) and the
    /// ActivityLog table the Memory grid folds. 3: the Sittings the phone writes and reads back (its
    /// quiz scores, its review answers, a learning bout's break; WP20b). 4: a course's retired
    /// `notebookID` and `homing` leave `m_courses`, since a notebook lists the courses it follows
    /// (spec revision 9). 5: the Schedule's Placements, the member's Highlights, and each ActivityLog's
    /// sources, which the Schedule folds into activity days (WP20c).
    static let indexVersion: Int64 = 5
    static let fileName = "ForeverLMReplica.sqlite"
    /// Records indexed again per transaction when the index is rebuilt.
    static let rebuildBatch = 500

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileReplica")

    /// The tables the screens query. Per-member types (NotebookState, Mark, ReadingState, Card, Goal,
    /// ActivityLog, Sitting, Placement, Highlight) are only ever in `Library`; the rest also in spaces.
    static let indexTables: [MobileIndexTable] = [
        MobileIndexTable("m_notebooks", .notebook, [
            .text("title", "title"), .text("status", "status"), .integer("created_at", "createdAt"),
            .integer("edited_at", "editedAt"), .text("layout", "layout"), .text("primary_course_id", "primaryCourseID"),
            .text("merged_into", "mergedInto"), .text("moved_to", "movedTo"), .text("moving_to", "movingTo"),
            .holds("has_cover", "files", "cover"), .text("instructions", "instructions"), .text("summary", "summary"),
            .member("repository", "repository", "url"), .members("related_json", "relatedNotebookIDs"),
        ]),
        MobileIndexTable("m_entries", .entry, [
            .text("container_kind", "containerKind"), .text("container_id", "containerID"), .text("item_kind", "itemKind"),
            .text("item_id", "itemID"), .text("state", "state"), .text("approval", "approval"), .text("order_key", "orderKey"),
            .text("origin", "origin"), .text("role", "role"), .integer("added_at", "addedAt"),
            .stamp("state_stamp", "state"), .stamp("approval_stamp", "approval"), .text("label", "label"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_entries_container ON m_entries(zone_key, container_id, state, order_key, id)",
            "CREATE INDEX IF NOT EXISTS idx_m_entries_item ON m_entries(item_id)",
        ]),
        MobileIndexTable("m_sources", .source, [
            .text("type", "type"), .text("title", "title"), .folded("title_key", "title"), .joined("authors", "authors"),
            .text("venue", "venue"), .text("url", "url"), .text("collection_id", "collectionID"),
            .text("collection_order", "collectionOrder"), .text("status", "status"), .member("ingest_state", "ingest", "state"),
            .integer("added_at", "addedAt"), .integer("published_at", "publishedAt"), .integer("edited_at", "editedAt"),
            .text("merged_into", "mergedInto"), .holds("has_pdf", "files", "pdf"), .text("subtitle", "subtitle"),
            .text("doi", "doi"), .memberInteger("word_count", "metrics", "wordCount"), .holdsPrefixed("has_audio", "files", "audio."),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_sources_added ON m_sources(zone_key, status, added_at DESC, id)",
            "CREATE INDEX IF NOT EXISTS idx_m_sources_title ON m_sources(zone_key, status, title_key, id)",
            "CREATE INDEX IF NOT EXISTS idx_m_sources_collection ON m_sources(collection_id, collection_order)",
        ]),
        MobileIndexTable("m_collections", .collection, [
            .text("kind", "kind"), .text("title", "title"), .text("status", "status"), .integer("added_at", "addedAt"),
            .text("author", "author"), .text("subtitle", "subtitle"),
        ]),
        MobileIndexTable("m_chats", .chat, [
            .text("kind", "kind"), .text("notebook_id", "notebookID"), .text("course_id", "courseID"), .text("title", "title"),
            .text("status", "status"), .integer("created_at", "createdAt"), .integer("edited_at", "editedAt"),
            .members("context_json", "contextSourceIDs"), .member("model_id", "model", "id"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_chats_notebook ON m_chats(notebook_id, edited_at DESC)",
        ]),
        MobileIndexTable("m_exchanges", .exchange, [
            .text("chat_id", "chatID"), .integer("seq", "seq"), .integer("created_at", "createdAt"),
            .nonEmpty("has_answer", "userAnswer"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_exchanges_chat ON m_exchanges(zone_key, chat_id, seq, created_at, id)",
        ]),
        MobileIndexTable("m_artifacts", .artifact, [
            .text("kind", "kind"), .text("title", "title"), .text("notebook_id", "notebookID"), .text("course_id", "courseID"),
            .text("status", "status"), .text("preview", "preview"), .integer("created_at", "createdAt"), .integer("edited_at", "editedAt"),
            .members("linked_json", "linkedNotebookIDs"), .members("source_ids_json", "sourceIDs"), .text("linked_url", "linkedURL"),
            .member("body_hash", "body", "hash"), .bool("is_draft", "isDraft"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_artifacts_notebook ON m_artifacts(notebook_id, edited_at DESC)",
        ]),
        MobileIndexTable("m_courses", .course, [
            .text("title", "title"), .text("status", "status"), .integer("created_at", "createdAt"), .text("provider", "provider"),
        ]),
        MobileIndexTable("m_lessons", .lesson, [
            .text("course_id", "courseID"), .text("order_key", "orderKey"), .text("kind", "kind"), .text("title", "title"),
            .text("label", "label"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_lessons_course ON m_lessons(course_id, order_key)",
        ]),
        MobileIndexTable("m_quizzes", .quiz, [
            .text("course_id", "courseID"), .text("lesson_id", "lessonID"), .text("kind", "kind"), .text("title", "title"),
            .integer("revision", "revision"), .integer("question_count", "questionCount"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_quizzes_course ON m_quizzes(course_id)",
        ]),
        MobileIndexTable("m_goals", .goal, [
            .text("title", "title"), .text("notebook_id", "notebookID"), .integer("due_at", "dueAt"), .text("status", "status"),
        ]),
        MobileIndexTable("m_notebook_states", .notebookState, [
            .text("notebook_id", "notebookID"), .text("sidebar_key", "sidebarKey"), .bool("pinned", "pinned"),
            .text("layout_override", "layoutOverride"), .json("excluded_json", "excluded"),
            .members("context_json", "contextNotebooks"),
        ]),
        MobileIndexTable("m_marks", .mark, [
            .text("kind", "kind"), .text("target", "target"), .bool("on_flag", "on"), .integer("at", "at"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_marks_kind ON m_marks(kind, on_flag, target)",
        ]),
        MobileIndexTable("m_reading_states", .readingState, [
            .text("target_kind", "targetKind"), .text("target_id", "targetID"), .integer("read_at", "readAt"),
            .integer("completed_at", "completedAt"), .integer("last_read_at", "lastReadAt"),
            .integer("consumed_at", "consumedAt"), .json("listen_json", "listen"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_reading_states_target ON m_reading_states(target_id)",
        ]),
        MobileIndexTable("m_cards", .card, [
            .text("status", "status"), .text("deck_source_id", "deckSourceID"), .text("origin", "origin"),
            .integer("drafted_at", "draftedAt"), .integer("kept_at", "keptAt"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_cards_deck ON m_cards(deck_source_id)",
        ]),
        MobileIndexTable("m_settings", .setting, [
            .text("key", "key"), .json("value_json", "value"),
        ]),
        // One per device per day (§3.5.24): the Memory grid folds the review clock of every log.
        MobileIndexTable("m_activity_logs", .activityLog, [
            .text("day", "day"), .text("device_id", "deviceID"), .json("review_json", "review"),
            .json("review_by_device_json", "reviewByDevice"), .json("sources_json", "sources"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_activity_logs_day ON m_activity_logs(day)",
        ]),
        // A quiz's sittings by its scope, a chat's sitting by its writer, a bout by when it started
        // (§3.5.23); the answers stay in the payload, decoded only for the sitting being written.
        MobileIndexTable("m_sittings", .sitting, [
            .text("device_id", "deviceID"), .text("kind", "kind"), .text("chat_id", "chatID"), .integer("started_at", "startedAt"),
            .integer("ended_at", "endedAt"), .integer("part", "part"), .member("quiz_id", "scope", "quizID"),
            .member("scope_source_id", "scope", "sourceID"), .json("result_json", "result"), .integer("break_ends_at", "breakEndsAt"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_sittings_kind ON m_sittings(kind, started_at)",
            "CREATE INDEX IF NOT EXISTS idx_m_sittings_chat ON m_sittings(device_id, chat_id)",
        ]),
        // One per source (`pl:<sourceID>`, §3.5.21): the Schedule's day, order, tags and completion.
        MobileIndexTable("m_placements", .placement, [
            .text("source_id", "sourceID"), .text("state", "state"), .text("day", "day"), .text("order_key", "orderKey"),
            .text("origin", "origin"), .members("goals_json", "goalIDs"), .integer("completed_at", "completedAt"),
            .integer("added_at", "addedAt"), .integer("edited_at", "editedAt"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_placements_day ON m_placements(state, day)",
        ]),
        // The member's highlights (§3.5.17), whole: the Reader shows a source's from the index alone.
        MobileIndexTable("m_highlights", .highlight, [
            .text("source_id", "sourceID"), .text("text", "text"), .text("color", "color"), .text("note", "note"),
            .text("chat_id", "chatID"), .json("locator_json", "locator"), .json("refs_json", "refs"),
            .integer("created_at", "createdAt"), .integer("edited_at", "editedAt"),
        ], indexes: [
            "CREATE INDEX IF NOT EXISTS idx_m_highlights_source ON m_highlights(source_id, created_at, id)",
        ]),
    ]

    private static let tablesByType: [SyncRecordType: MobileIndexTable] = Dictionary(
        uniqueKeysWithValues: indexTables.map { ($0.type, $0) }
    )

    static func indexTable(for type: SyncRecordType) -> MobileIndexTable? { tablesByType[type] }

    /// The phone's replica file in this build's environment.
    static func fileURL(environment: MobileCloudKitEnvironment = .current) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return directory.appendingPathComponent(environment.scopedName(fileName))
    }

    let connection: SQLiteConnection
    private let queue = DispatchQueue(label: "com.foreverlm.mobile-replica", qos: .utility)
    private let counter = NSLock()
    private var decodes = 0
    private var heldMoveMaps: MoveMapIndex?
    private var heldMemoryRevision = 0

    /// Opens (or creates) the replica at `path`, or an in-memory one for ":memory:", installs its
    /// tables, and builds the index again when its version moved. Call it off the main actor.
    init(path: String) throws {
        let handle = try SQLiteHandle(path: path)
        connection = handle
        if path != ":memory:" {
            try handle.executeScript("PRAGMA journal_mode = WAL")
            var url = URL(fileURLWithPath: path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        try ReplicaStore(connection: handle).installSharedSchema()
        let version = try handle.scalarInteger("PRAGMA user_version") ?? 0
        if version == Self.indexVersion {
            try installIndexTables()
        } else {
            try rebuildIndex()
        }
        try MobileTextIndex.fillIfNeeded(self)
    }

    // MARK: - The store

    func perform<T>(_ body: @escaping (PrivateSyncLocalState) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    /// Runs a read (or the writer's own transaction) where the connection belongs.
    func read<T>(_ body: @escaping (MobileReplica) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    /// The moves the personal root lists (D51), the session's own index, so a pending write to a record
    /// a move took elsewhere goes to its copy (`MobilePatchOutbox`).
    var moveMaps: MoveMapIndex? {
        get { counter.withLock { heldMoveMaps } }
        set { counter.withLock { heldMoveMaps = newValue } }
    }

    /// The phone's local changes are its RecordPatches and pending deletes (`MobileRecordWriter`), sent
    /// by the engine and SpaceSync through `MobilePatchOutbox`.
    func nextChanges(now: Date, limit: Int, scope: OutboxScope) throws -> [OutboxChange] {
        try MobilePatchOutbox(replica: self, moveMaps: moveMaps).changes(now: now, limit: limit, scope: scope)
    }

    /// Nothing: an inbound record meets the phone's pending patch through `PendingPatch` itself.
    func pendingChanges(now: Date) throws -> [OutboxChange] { [] }

    func acknowledgeSave(_ change: OutboxChange, serverRecord: ReplicaRecord) throws {
        try replica.upsertRecord(serverRecord)
        try MobilePatchOutbox.settle(change, in: connection)
        try reindex(zoneKey: change.zoneKey, type: change.recordType, wireID: change.wireID)
    }

    func acknowledgeDelete(_ change: OutboxChange, now: Date) throws {
        try replica.deleteRecord(zoneKey: change.zoneKey, recordName: change.recordName)
        try connection.execute("DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?", [.text(change.zoneKey), .text(change.recordName)])
        try reindex(zoneKey: change.zoneKey, type: change.recordType, wireID: change.wireID)
    }

    func release(_ change: OutboxChange) throws {}

    /// A change that will never be sent (a write SpaceSync refused, one a move's copy took): what it
    /// carried leaves the pending patch, a delete its row.
    func discard(_ change: OutboxChange) throws {
        if change.action == .delete {
            try connection.execute("DELETE FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?", [.text(change.zoneKey), .text(change.recordName)])
        } else {
            try MobilePatchOutbox.settle(change, in: connection)
        }
        try reindex(zoneKey: change.zoneKey, type: change.recordType, wireID: change.wireID)
    }

    /// Extracts a record's index columns, inside the apply that wrote it. The record is what the
    /// projection takes: the server's version, or its merge with a pending patch (§6.2).
    func project(_ record: ReplicaRecord) throws {
        guard let type = SyncRecordType(rawValue: record.recordType), let table = Self.indexTable(for: type) else { return }
        guard let envelope = decode(record.payload) else { return }
        try index(envelope, in: table, zoneKey: record.zoneKey, recordName: record.recordName)
        movedMemory(type)
    }

    func projectDeletion(zoneKey: String, recordName: String, type: SyncRecordType, wireID: String) throws {
        guard let table = Self.indexTable(for: type) else { return }
        try connection.execute("DELETE FROM \(table.name) WHERE zone_key = ? AND id = ?", [.text(zoneKey), .text(wireID)])
        movedMemory(type)
    }

    /// Moves when a Card or a Sitting arrived from the server or was deleted there: what the Memory screens
    /// decode from their payloads (`MobileReadModels.memory`) is kept until it moves. The phone's own writes
    /// do not move it, since they add to what is kept (`MobileCloudSourceCatalog.noteRecordedMemoryAttempt`).
    var memoryRevision: Int { counter.withLock { heldMemoryRevision } }

    private func movedMemory(_ type: SyncRecordType) {
        guard type == .card || type == .sitting else { return }
        counter.withLock { heldMemoryRevision &+= 1 }
    }

    /// No index row waits for a parent: the phone's tables have no foreign keys.
    func drainReady() throws {}

    // MARK: - The index

    /// Decodes one stored payload, counting it (`decodedRecords`); nil for one this build cannot read.
    func decode(_ payload: Data) -> SyncEnvelope? {
        counter.withLock { decodes += 1 }
        return try? SyncEnvelope(storedPayload: payload)
    }

    /// Payloads decoded since the replica opened (or since `resetDecodeCount`), outside or inside applies.
    var decodedRecords: Int { counter.withLock { decodes } }

    func resetDecodeCount() { counter.withLock { decodes = 0 } }

    private func index(_ envelope: SyncEnvelope, in table: MobileIndexTable, zoneKey: String, recordName: String?) throws {
        guard envelope.type == table.type.rawValue else { return }
        try connection.execute(table.upsertStatement, [.text(zoneKey), .text(envelope.id), .text(recordName)] + table.columns.map { $0.value(envelope) })
        // A source's metadata is searchable from the same apply (WP21).
        if table.type == .source { try MobileTextIndex.index(envelope, zoneKey: zoneKey, in: connection) }
    }

    /// Indexes one record again from what the phone holds: the replica's version with its pending patch
    /// laid over it, the patch alone for a record created here and not acknowledged yet, or nothing,
    /// which removes the row. The writer calls it inside its transaction after it saves a patch (WP20).
    func reindex(zoneKey: String, type: SyncRecordType, wireID: String) throws {
        guard let table = Self.indexTable(for: type) else { return }
        var held = try replica.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: wireID)
        // A record the phone deletes is gone from its screens while the delete is on its way.
        if let record = held, try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_pending_deletes WHERE zone_key = ? AND record_name = ?)", [.text(zoneKey), .text(record.recordName)]
        ) == 1 {
            held = nil
        }
        let patch = try PendingPatch.load(zoneKey: zoneKey, type: type.rawValue, wireID: wireID, in: connection)
        var envelope = held.flatMap { decode($0.payload) }
        if let patch {
            let saltID = try replica.zone(key: zoneKey)?.saltID ?? ""
            envelope = patch.applied(to: envelope ?? SyncEnvelope.new(type, id: wireID, saltID: saltID))
        }
        guard let envelope else {
            try connection.execute("DELETE FROM \(table.name) WHERE zone_key = ? AND id = ?", [.text(zoneKey), .text(wireID)])
            return
        }
        try index(envelope, in: table, zoneKey: zoneKey, recordName: held?.recordName)
    }

    private func installIndexTables() throws {
        for table in Self.indexTables {
            try connection.executeScript(table.createStatement)
            for index in table.indexes { try connection.executeScript(index) }
        }
        try connection.executeScript(Self.forgetTrigger)
        try MobileTextIndex.install(in: connection)
    }

    /// A record the replica forgets without an inbound deletion takes its index row with it: a purge
    /// or an account switch (`PurgeHandler`), a space that went (`SpaceSync.spaceGone`), the original
    /// of a record a move took into a space, whose deletion the apply swallows because its rows are the
    /// copy's (`InboundApply.serverLost`). A row a pending patch still makes stays. The trigger lives
    /// only in the phone's own file, which no outbox reads.
    static var forgetTrigger: String {
        let deletes = indexTables.map { table in
            """
                DELETE FROM \(table.name) WHERE OLD.record_type = '\(table.type.rawValue)' AND zone_key = OLD.zone_key AND id = OLD.wire_id
                  AND NOT EXISTS (SELECT 1 FROM ck_patches p WHERE p.zone_key = OLD.zone_key AND p.record_type = OLD.record_type AND p.wire_id = OLD.wire_id);
            """
        }
        return "CREATE TRIGGER IF NOT EXISTS mobile_index_forget AFTER DELETE ON ck_records BEGIN\n\(deletes.joined(separator: "\n"))\nEND"
    }

    /// Builds the index from the replica's records, a bounded batch per transaction, then stamps the
    /// version. Interrupted, it starts again at the next open: the version moves only at the end.
    func rebuildIndex() throws {
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            try connection.executeScript("DROP TRIGGER IF EXISTS mobile_index_forget")
            for table in Self.indexTables { try connection.executeScript("DROP TABLE IF EXISTS \(table.name)") }
            try installIndexTables()
            try connection.executeScript("COMMIT")
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
        let indexed = Self.indexTables.map { "'\($0.type.rawValue)'" }.joined(separator: ", ")
        var after: Int64 = 0
        var total = 0
        while true {
            var batch: [(rowid: Int64, zoneKey: String, type: SyncRecordType, wireID: String)] = []
            try connection.query("""
                SELECT rowid, zone_key, record_type, wire_id FROM ck_records
                WHERE rowid > ? AND record_type IN (\(indexed)) ORDER BY rowid LIMIT ?
            """, [.integer(after), .integer(Int64(Self.rebuildBatch))]) { row in
                guard let type = SyncRecordType(rawValue: row.text(2) ?? "") else { return }
                batch.append((row.integer(0) ?? 0, row.text(1) ?? "", type, row.text(3) ?? ""))
            }
            guard let last = batch.last else { break }
            try transaction {
                for record in batch { try reindex(zoneKey: record.zoneKey, type: record.type, wireID: record.wireID) }
            }
            after = last.rowid
            total += batch.count
        }
        // Records created on the phone and not acknowledged yet exist only as patches.
        var unsent: [(zoneKey: String, type: SyncRecordType, wireID: String)] = []
        try connection.query("""
            SELECT p.zone_key, p.record_type, p.wire_id FROM ck_patches p
            WHERE NOT EXISTS (SELECT 1 FROM ck_records r WHERE r.zone_key = p.zone_key AND r.record_type = p.record_type AND r.wire_id = p.wire_id)
        """, []) { row in
            guard let type = SyncRecordType(rawValue: row.text(1) ?? "") else { return }
            unsent.append((row.text(0) ?? "", type, row.text(2) ?? ""))
        }
        try transaction {
            for record in unsent { try reindex(zoneKey: record.zoneKey, type: record.type, wireID: record.wireID) }
            // The dropped `m_sources` took no search rows with it; those it no longer backs go now.
            try MobileTextIndex.prune(in: connection)
            try connection.executeScript("PRAGMA user_version = \(Self.indexVersion)")
        }
        if total > 0 { Self.logger.info("Indexed \(total) replica records again (index version \(Self.indexVersion))") }
    }

    /// Removes the index rows the replica no longer backs: every row of a space that went (the phone
    /// drops its mirror, §2.5, §9.6; a record a move took elsewhere keeps its replica row there), and
    /// any row whose record is gone from `ck_records`, unless a pending patch still makes it (the
    /// trigger already removes those as they go; this catches what an older index left). Returns the
    /// rows removed.
    @discardableResult
    func sweepIndex() throws -> Int {
        var gone: [String] = []
        let prefix = SpaceSync.StateScope.gonePrefix
        try connection.query("SELECT scope FROM ck_engine_state WHERE substr(scope, 1, ?) = ?",
                             [.integer(Int64(prefix.count)), .text(prefix)]) { gone.append(String(($0.text(0) ?? "").dropFirst(prefix.count))) }
        var removed = 0
        try transaction {
            for table in Self.indexTables {
                for zoneKey in gone {
                    try connection.execute("DELETE FROM \(table.name) WHERE zone_key = ?", [.text(zoneKey)])
                    removed += connection.changedRowCount
                }
                try connection.execute("""
                    DELETE FROM \(table.name) WHERE NOT EXISTS (
                        SELECT 1 FROM ck_records r WHERE r.zone_key = \(table.name).zone_key AND r.record_type = ? AND r.wire_id = \(table.name).id
                    ) AND NOT EXISTS (
                        SELECT 1 FROM ck_patches p WHERE p.zone_key = \(table.name).zone_key AND p.record_type = ? AND p.wire_id = \(table.name).id
                    )
                """, [.text(table.type.rawValue), .text(table.type.rawValue)])
                removed += connection.changedRowCount
            }
        }
        if removed > 0 { Self.logger.info("Swept \(removed) index rows the replica no longer holds") }
        return removed
    }

    /// Sweeps when what a sweep depends on (the private database's stop, the spaces that went) moved
    /// since the last sweep, which `ck_engine_state` remembers. Returns the rows removed.
    @discardableResult
    func sweepIndexIfNeeded(now: Date = Date()) throws -> Int {
        let signature = try sweepSignature()
        let swept = try replica.engineState(Self.sweptScope).map { String(decoding: $0, as: UTF8.self) }
        guard swept != signature else { return 0 }
        let removed = try sweepIndex()
        try replica.setEngineState(Self.sweptScope, Data(signature.utf8), now: now)
        return removed
    }

    /// `ck_engine_state` scope of the last sweep's signature.
    static let sweptScope = "mobile.index.swept"

    /// What a sweep depends on: the private database's stop and the spaces that went.
    func sweepSignature() throws -> String {
        var parts: [String] = []
        try connection.query("SELECT scope, state FROM ck_engine_state WHERE scope = ? OR substr(scope, 1, ?) = ? ORDER BY scope", [
            .text(ReplicaStore.EngineScope.privateStop), .integer(Int64(SpaceSync.StateScope.gonePrefix.count)), .text(SpaceSync.StateScope.gonePrefix),
        ]) { parts.append(($0.text(0) ?? "") + "=" + String(decoding: $0.blob(1) ?? Data(), as: UTF8.self)) }
        return parts.joined(separator: "\n")
    }

    private func transaction(_ body: () throws -> Void) throws {
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            try body()
            try connection.executeScript("COMMIT")
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
    }
}
