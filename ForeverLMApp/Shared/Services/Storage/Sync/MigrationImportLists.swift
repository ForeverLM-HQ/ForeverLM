import Foundation

// MARK: - What an import pass keeps between passes (docs/cloudkit-schema-design.md §13.6)

/// A tripped 5% guard's question (§13.6, R7-m3): an import pass or a refresh offers **Apply** (the pass
/// runs once with the guard lifted) and **Keep** (it applies everything else and lists those removals).
/// It waits in `ck_engine_state` until answered; while it waits, the importer's hourly pass applies
/// nothing and leaves the base where it was, and a Mac whose pass runs before its reconcile or a
/// takeover does not reconcile, take over or send (R8-m5).
struct MigrationImportGuardQuestion: Codable, Equatable, Sendable {
    enum Answer: String, Codable, Sendable {
        case apply
        case keep
    }

    /// The removals the pass would make, and the records it covers.
    var removing: Int
    var of: Int
    var askedAt: Date
    var answer: Answer?
}

/// The importer's pending advance of the base: its patches are on their way, and the shards and tokens
/// move once they are acknowledged (§13.6 "Bookkeeping"). Kept in `ck_engine_state`, so a Mac that quits
/// between the pass and the acknowledgements finishes the advance on its next launch instead of
/// starting another pass.
struct MigrationAdvanceJournal: Codable, Equatable, Sendable {
    /// The pass this journal belongs to; its manifest delta's key is `<deviceID>.<passID>`.
    var passID: String
    /// Each changed old record's next entry as JSON text (`MigrationBaseEntry.jsonWithTag`), or nil when
    /// the old record is gone.
    var entries: [String: String?]
    var watermark: String
    /// The records the pass patched and created: acknowledged once no `ck_patches` row names them.
    var patched: [MigrationRecordRef]
    /// The records the pass deleted: acknowledged once the replica no longer holds them.
    var deleted: [MigrationRecordRef]
    var startedAt: Date
}

/// A record by zone key, type and logical id, as `ck_patches` and `ck_records` name it.
struct MigrationRecordRef: Codable, Hashable, Sendable {
    var zoneKey: String
    var type: String
    var id: String
}

/// Which pass a question, a journal or a waiting list belongs to: the importer's and any other Mac's import
/// pass (from the shared base), or the refresh (from this Mac's own snapshot, §13.4 step 0). The refresh's
/// own, so an answer to one pass's question never lifts the other's guard; the Kept and Not applied lists
/// are one, since Settings shows one "Kept from an older ForeverLM".
enum MigrationPassKind: String, CaseIterable, Sendable {
    case importPass
    case refresh
}

/// The lists and bookkeeping an import pass writes, on this Mac: "Kept from an older ForeverLM" (every
/// removal an old build made that late import did not apply), "Not applied" (a value dropped after 30
/// days of waiting), when each old record's values first waited, the guard's question and the advance
/// journal. Local to the Mac that ran the pass, as the spec lists them (§13.6).
enum MigrationImportState {
    enum Scope {
        static let kept = "migration.kept"
        static let notApplied = "migration.notApplied"
        static let waiting = "migration.waiting"
        static let guardQuestion = "migration.importGuard"
        static let journal = "migration.advanceJournal"
        static let refreshWaiting = "migration.refresh.waiting"
        static let refreshGuardQuestion = "migration.refresh.guard"
        static let refreshJournal = "migration.refresh.journal"
    }

    private static func waitingScope(_ pass: MigrationPassKind) -> String { pass == .refresh ? Scope.refreshWaiting : Scope.waiting }
    private static func questionScope(_ pass: MigrationPassKind) -> String { pass == .refresh ? Scope.refreshGuardQuestion : Scope.guardQuestion }
    private static func journalScope(_ pass: MigrationPassKind) -> String { pass == .refresh ? Scope.refreshJournal : Scope.journal }

    /// The newest entries a list keeps.
    static let listLimit = 500

    // MARK: Lists

    static func kept(_ connection: SQLiteConnection) throws -> [MigrationLogEntry] {
        try load(Scope.kept, connection) ?? []
    }

    static func notApplied(_ connection: SQLiteConnection) throws -> [MigrationLogEntry] {
        try load(Scope.notApplied, connection) ?? []
    }

    /// Adds entries to the Kept list; one old record's removal of one record is listed once.
    static func appendKept(_ entries: [MigrationLogEntry], _ connection: SQLiteConnection) throws {
        try append(entries, to: Scope.kept, connection)
    }

    static func appendNotApplied(_ entries: [MigrationLogEntry], _ connection: SQLiteConnection) throws {
        try append(entries, to: Scope.notApplied, connection)
    }

    private static func append(_ entries: [MigrationLogEntry], to scope: String, _ connection: SQLiteConnection) throws {
        guard !entries.isEmpty else { return }
        var list: [MigrationLogEntry] = try load(scope, connection) ?? []
        for entry in entries where !list.contains(where: { same($0, entry) }) { list.append(entry) }
        if list.count > listLimit { list.removeFirst(list.count - listLimit) }
        try save(list, scope, connection)
    }

    private static func same(_ lhs: MigrationLogEntry, _ rhs: MigrationLogEntry) -> Bool {
        lhs.oldRecord == rhs.oldRecord && lhs.type == rhs.type && lhs.id == rhs.id && lhs.reason == rhs.reason
    }

    // MARK: Waiting

    /// When each old record's values first waited, by `MigrationOldRecord.id`.
    static func waitingSince(_ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws -> [String: Date] {
        try load(waitingScope(pass), connection) ?? [:]
    }

    static func saveWaitingSince(_ since: [String: Date], _ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws {
        try save(since, waitingScope(pass), connection)
    }

    /// Records this pass's outcome: an old record that waits keeps the time it first did, one that no longer
    /// waits (or is gone) leaves the list.
    static func updateWaiting(_ plan: MigrationPassPlan, now: Date, _ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws {
        var since = try waitingSince(connection, pass: pass)
        for old in plan.olds {
            if old.waiting {
                if since[old.oldRecord] == nil { since[old.oldRecord] = now }
            } else {
                since[old.oldRecord] = nil
            }
        }
        try save(since, waitingScope(pass), connection)
    }

    /// The old records that wait, by `<zone>/<name>`: fetched by name on every pass until the record
    /// exists, a listing shows it deleted, or 30 days pass.
    static func waitingRecords(_ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws -> [String] {
        try waitingSince(connection, pass: pass).keys.sorted()
    }

    /// When each old record that waits first did, whichever pass left it; the earliest time when two passes both wait for one.
    static func allWaitingSince(_ connection: SQLiteConnection) throws -> [String: Date] {
        var all: [String: Date] = [:]
        for kind in MigrationPassKind.allCases {
            for (id, since) in try waitingSince(connection, pass: kind) { all[id] = min(all[id] ?? since, since) }
        }
        return all
    }

    /// Every old record that waits for a record that does not exist yet, whichever pass left it (the importer's,
    /// the refresh's, the deferred catch-up's): what "Remove old iCloud data" names before it removes (§13.8).
    static func allWaitingRecords(_ connection: SQLiteConnection) throws -> [String] {
        var all = Set<String>()
        for kind in MigrationPassKind.allCases { all.formUnion(try waitingRecords(connection, pass: kind)) }
        return all.sorted()
    }

    // MARK: The guard's question

    static func guardQuestion(_ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws -> MigrationImportGuardQuestion? {
        try load(questionScope(pass), connection)
    }

    static func ask(_ question: MigrationImportGuardQuestion, _ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws {
        try save(question, questionScope(pass), connection)
    }

    /// The learner's answer; the pass that asked consumes it. With no `pass`, every question that waits is
    /// answered: Settings shows one question, whichever pass asked it.
    static func answer(_ answer: MigrationImportGuardQuestion.Answer, _ connection: SQLiteConnection, pass: MigrationPassKind? = nil) throws {
        for kind in pass.map({ [$0] }) ?? MigrationPassKind.allCases {
            guard var question = try guardQuestion(connection, pass: kind), question.answer == nil else { continue }
            question.answer = answer
            try save(question, questionScope(kind), connection)
        }
    }

    static func clearQuestion(_ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws {
        try ReplicaStore(connection: connection).setEngineState(questionScope(pass), nil)
    }

    /// The question that waits for the learner, whichever pass asked it: while one does, a Mac whose
    /// refresh or import pass runs before its reconcile or a takeover does not reconcile, take over or send
    /// (R8-m5).
    static func waitingQuestion(_ connection: SQLiteConnection) throws -> MigrationImportGuardQuestion? {
        for kind in MigrationPassKind.allCases {
            if let question = try guardQuestion(connection, pass: kind), question.answer == nil { return question }
        }
        return nil
    }

    // MARK: The advance journal

    static func journal(_ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws -> MigrationAdvanceJournal? {
        try load(journalScope(pass), connection)
    }

    static func saveJournal(_ journal: MigrationAdvanceJournal, _ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws {
        try save(journal, journalScope(pass), connection)
    }

    static func clearJournal(_ connection: SQLiteConnection, pass: MigrationPassKind = .importPass) throws {
        try ReplicaStore(connection: connection).setEngineState(journalScope(pass), nil)
    }

    // MARK: Storage

    private static func load<T: Decodable>(_ scope: String, _ connection: SQLiteConnection) throws -> T? {
        try ReplicaStore(connection: connection).engineState(scope).flatMap { try? decoder.decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, _ scope: String, _ connection: SQLiteConnection) throws {
        try ReplicaStore(connection: connection).setEngineState(scope, try encoder.encode(value))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
