import Foundation
import OSLog

// MARK: - A pass over the library's rows (docs/cloudkit-schema-design.md §13.4 step 2, §13.5)

/// `ck_seed_cursor`: where each table of a pass stopped, so a launch after a kill resumes there. A row
/// holds the table's cursor (`<sort>|<rowid>` of the last row taken) and, once the table is finished, the
/// time it finished.
enum SeedCursors {
    struct Cursor: Equatable, Sendable {
        var cursor: String?
        var completedAt: Double?
    }

    static func load(_ pass: String, in connection: SQLiteConnection) throws -> Cursor {
        var found = Cursor()
        try connection.query("SELECT cursor, completed_at FROM ck_seed_cursor WHERE pass = ?", [.text(pass)]) { row in
            found = Cursor(cursor: row.text(0), completedAt: row.real(1))
        }
        return found
    }

    static func save(_ pass: String, cursor: String?, completedAt: Double?, now: Date, in connection: SQLiteConnection) throws {
        try connection.execute("""
            INSERT INTO ck_seed_cursor (pass, cursor, completed_at, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(pass) DO UPDATE SET cursor = excluded.cursor, completed_at = excluded.completed_at, updated_at = excluded.updated_at
        """, [.text(pass), .text(cursor), .real(completedAt), .real(now.timeIntervalSinceReferenceDate)])
    }

    static func isDone(_ pass: String, in connection: SQLiteConnection) throws -> Bool {
        try load(pass, in: connection).completedAt != nil
    }
}

enum SeedPassError: Error, Equatable {
    case engineStalled
}

/// What a pass does with a row, from the records it feeds.
enum SeedRowAction: Equatable, Sendable {
    case skip
    /// Hand the row to the outbox at its migrated time.
    case enqueue
    /// The server does not hold the record and the manifest lists it: it was in the new world and deleted
    /// there, so the local row goes and nothing is uploaded (§13.5).
    case deleteLocally
}

/// How a pass decides, per row (§13.4 step 2, §13.5).
enum SeedRowDecider: Sendable {
    /// The first seed on an empty server: everything the library holds, a space's copies left to P6.
    case seed
    /// P6: only the rows a space holds copies of.
    case spaces
    /// Reconcile mode (a second Mac, a takeover, a seed resumed on records the server already holds): a
    /// record the server holds keeps the server's value, one it lacks that the manifest lists is deleted
    /// locally, and one in neither is uploaded and listed in this pass's manifest delta (`deltaPassKey`;
    /// nil lists nothing, as the seeder's own manifest is read from its replica).
    case reconcile(manifest: Set<SeedManifestEntry>, deltaPassKey: String?)

    func action(for refs: [SeedRecordRef], in connection: SQLiteConnection) throws -> SeedRowAction {
        switch self {
        case .seed:
            return refs.contains { !$0.isSpaceCopy } ? .enqueue : .skip
        case .spaces:
            return refs.contains { $0.isSpaceCopy } ? .enqueue : .skip
        case .reconcile(let manifest, _):
            let mine = refs.filter { !$0.isSpaceCopy }
            guard !mine.isEmpty else { return .skip }
            let held = try mine.map { try Self.serverHolds($0, in: connection) }
            // A row that feeds records of which only some are on the server cannot be sent for the missing
            // ones alone: sending it would send the held ones' local values too.
            guard held.allSatisfy({ !$0 }) else { return .skip }
            let listed = mine.map { manifest.contains(SeedManifestEntry(type: $0.type.rawValue, id: $0.wireID)) }
            if listed.allSatisfy({ $0 }) { return .deleteLocally }
            return listed.contains(true) ? .skip : .enqueue
        }
    }

    var deltaPassKey: String? {
        if case .reconcile(_, let key) = self { return key }
        return nil
    }

    /// Whether the replica holds the record in `Library` or `Catalog`.
    static func serverHolds(_ ref: SeedRecordRef, in connection: SQLiteConnection) throws -> Bool {
        let replica = ReplicaStore(connection: connection)
        for zoneKey in [PrivateSyncZones.libraryKey, PrivateSyncZones.key(PrivateSyncZones.catalog)] {
            if try replica.record(zoneKey: zoneKey, recordType: ref.type.rawValue, wireID: ref.wireID) != nil { return true }
        }
        return false
    }
}

/// One pass's tally.
struct SeedPassTally: Equatable, Sendable {
    var rows = 0
    var enqueued = 0
    var deleted = 0
    var skipped = 0

    mutating func add(_ other: SeedPassTally) {
        rows += other.rows
        enqueued += other.enqueued
        deleted += other.deleted
        skipped += other.skipped
    }
}

/// Takes the library's rows in bounded batches, hands the ones that must go to the outbox at their
/// migrated time, and has the engine send each batch before the next (§13.4: never everything at once).
/// The engine's feeder then encodes, places and stamps exactly as for any edit, and acknowledges into the
/// replica; the cursor moves once a batch is sent, so a launch after a kill resumes at the next row.
struct SeedPassRunner: Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CutoverSeed")

    let store: PrivateSyncLocalStore
    let registry: ProjectionRegistry
    /// Sends what the outbox holds through the engine until it has nothing pending.
    let send: @Sendable () async throws -> Void
    let pendingCount: @Sendable () async -> Int
    let decider: SeedRowDecider
    /// `seed` or `reconcile`: the cursor rows of the two never meet.
    let cursorPrefix: String
    var batchSize = 200
    /// How many times a batch is sent before the pass goes on; what the engine could not send stays in
    /// the outbox for the ordinary rounds.
    var sendAttempts = 8
    var clock: @Sendable () -> Date = { Date() }

    private func settle() async throws {
        for _ in 0..<sendAttempts {
            try await send()
            if await pendingCount() == 0 { return }
        }
        // The engine could not send what it holds (the database stopped, a pause, a refusal): the seed does
        // not go on enqueuing against it, and the next round resumes from the cursor.
        throw SeedPassError.engineStalled
    }

    /// Runs every table of `pass` that is not finished. `between` runs after each sent batch (the seeder
    /// renews its claim there). A table that holds no row finishes at once.
    @discardableResult
    func run(_ pass: SeedPass, fallbackTime: Double, between: @Sendable (_ tally: SeedPassTally) async throws -> Void = { _ in }) async throws -> SeedPassTally {
        var total = SeedPassTally()
        let tables = SeedTable.tables(of: pass, in: registry)
        for table in tables {
            let key = "\(cursorPrefix).\(pass.rawValue).\(table.name)"
            var cursor = try await store.perform { try SeedCursors.load(key, in: $0.connection) }
            if cursor.completedAt != nil { continue }
            while true {
                let after = cursor.cursor
                let decider = decider
                let registry = registry
                let batchSize = batchSize
                let latest = clock().timeIntervalSinceReferenceDate
                let batch = try await store.perform { state in
                    try Self.takeBatch(
                        table, after: after, limit: batchSize, state: state, registry: registry, decider: decider, fallbackTime: fallbackTime, now: latest
                    )
                }
                guard batch.tally.rows > 0 else { break }
                total.add(batch.tally)
                if batch.tally.enqueued > 0 { try await settle() }
                cursor.cursor = batch.lastCursor
                let now = clock()
                try await store.perform { try SeedCursors.save(key, cursor: batch.lastCursor, completedAt: nil, now: now, in: $0.connection) }
                try await between(total)
            }
            let now = clock()
            try await store.perform { try SeedCursors.save(key, cursor: cursor.cursor, completedAt: now.timeIntervalSinceReferenceDate, now: now, in: $0.connection) }
        }
        return total
    }

    struct Batch: Sendable {
        var tally: SeedPassTally
        var lastCursor: String?
    }

    /// One batch, in one transaction: the rows' outbox entries and the manifest listing of what a
    /// reconcile will upload. Rows a reconcile deletes are removed afterwards, under the apply guard.
    static func takeBatch(
        _ table: SeedTable, after cursor: String?, limit: Int, state: PrivateSyncLocalState, registry: ProjectionRegistry,
        decider: SeedRowDecider, fallbackTime: Double, now: Double
    ) throws -> Batch {
        let connection = state.connection
        let reader = SeedRowReader(connection: connection, registry: registry, fallbackTime: fallbackTime, now: now)
        let rows = try reader.nextBatch(of: table, after: cursor, limit: limit)
        guard let last = rows.last else { return Batch(tally: SeedPassTally(), lastCursor: cursor) }
        var tally = SeedPassTally(rows: rows.count)
        var deletions: [SeedRecordRef] = []
        try connection.executeScript("BEGIN IMMEDIATE")
        do {
            for row in rows {
                let refs = try reader.records(of: row, in: table)
                switch try decider.action(for: refs, in: connection) {
                case .skip:
                    tally.skipped += 1
                case .enqueue:
                    try reader.enqueue(row, of: table)
                    tally.enqueued += 1
                    if let passKey = decider.deltaPassKey {
                        for ref in refs where !ref.isSpaceCopy {
                            let zoneKey = ref.type == .source || ref.type == .collection
                                ? PrivateSyncZones.key(PrivateSyncZones.catalog) : PrivateSyncZones.libraryKey
                            try SeedManifestPending.add(passKey: passKey, zoneKey: zoneKey, type: ref.type.rawValue, wireID: ref.wireID, in: connection)
                        }
                    }
                case .deleteLocally:
                    deletions += refs.filter { !$0.isSpaceCopy }
                    tally.deleted += 1
                }
            }
            try connection.executeScript("COMMIT")
        } catch {
            try? connection.executeScript("ROLLBACK")
            throw error
        }
        if !deletions.isEmpty {
            try state.replica.apply { _ in
                for ref in deletions {
                    let zoneKey = ref.type == .source || ref.type == .collection
                        ? PrivateSyncZones.key(PrivateSyncZones.catalog) : PrivateSyncZones.libraryKey
                    try state.projectionDeletion(zoneKey: zoneKey, type: ref.type, wireID: ref.wireID)
                }
            }
        }
        return Batch(tally: tally, lastCursor: SeedRowReader.cursor(after: last))
    }
}

extension PrivateSyncLocalState {
    /// A record of the manifest that the server no longer holds: its local rows go (`projectDeletion`).
    func projectionDeletion(zoneKey: String, type: SyncRecordType, wireID: String) throws {
        try projectDeletion(zoneKey: zoneKey, recordName: "", type: type, wireID: wireID)
    }
}
