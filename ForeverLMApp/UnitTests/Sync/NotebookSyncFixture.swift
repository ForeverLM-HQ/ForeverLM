import Foundation
import Testing
@testable import ForeverLM

/// Stores, rows and records for WP8's suites (docs/cloudkit-schema-design.md §3.5.6–§3.5.8, §3.5.20,
/// §5.6): a generation-2 store with the real registry's triggers, a replica holding `Library`'s root
/// and the `Catalog` zone, notebooks, Goals and pool items written as the app writes them, and
/// inbound records as another device would send them. It reads nothing but the store, the replica and
/// the feeder, so the suites built on it also run standalone over the real sources.
enum NotebookSyncFixture {
    static let registry = KnowledgeStore.projectionRegistry
    static let libraryZoneKey = "private/Library"
    static let catalogZoneKey = "private/Catalog"
    static var salt: Data { OutboxTestProjections.salt }
    /// 2100-01-01: the deadline a notebook is stored with (`LearningGoalShape`).
    static let openEnd = 3_124_137_600.0

    /// A store in a folder of its own, with the registry's triggers installed as the activation leaves
    /// them, or none (`triggers: false`).
    static func makeStore(_ name: String, triggers: Bool = true) throws -> (root: URL, store: KnowledgeStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WP8-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try KnowledgeStore(storeDirectory: root)
        if triggers { try store.installOutboxTriggers(registry) }
        return (root, store)
    }

    /// `Library`'s root with the salt, the `Catalog` zone, and a clock that knows its server offset.
    static func prepareReplica(_ store: KnowledgeStore) throws {
        try OutboxTestProjections.prepareReplica(store)
        try store.replica.upsertZone(ReplicaZone(
            zoneKey: catalogZoneKey, database: .private, zoneName: "Catalog", kind: "catalog", saltID: OutboxTestProjections.saltID
        ))
    }

    // MARK: Local rows, as the app writes them

    /// A notebook as `createCompanionGoal` leaves one, then classified as a generation-2 write does.
    static func addNotebook(_ store: KnowledgeStore, _ id: String, title: String = "🧬 Mitochondria", classify: Bool = true) throws {
        try store.execute("""
            INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind, description, topic, discovery_enabled, daily_target)
            VALUES (?, ?, 1000, ?, 1000, 1000, 'active', 'companion', 'Read carefully', 'mitochondria', 1, 3)
        """, [.text(id), .text(title), .real(openEnd)])
        if classify { try store.keepNotebookRowsForGeneration2(goalIDs: [id]) }
    }

    /// A dated Goal inside `parent` (or standalone).
    static func addGoal(_ store: KnowledgeStore, _ id: String, parent: String?) throws {
        try store.execute("""
            INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind, parent_notebook_id, daily_target)
            VALUES (?, 'Finish the review', 1000, 800000000, 1000, 1000, 'active', 'companion', ?, 2)
        """, [.text(id), .text(parent)])
        try store.keepNotebookRowsForGeneration2(goalIDs: [id])
    }

    /// A team's copy of `personalID`, as generation 1 holds one and WP7's wire ids name it.
    static func addTeamCopy(_ store: KnowledgeStore, _ id: String, of personalID: String) throws {
        try store.execute("""
            INSERT INTO sources (id, date_added, state, source_type, status, team_id, wire_id)
            VALUES (?, 1, 'ready', 'article', 'active', 'team-1', ?)
        """, [.text(id), .text(personalID)])
        try store.execute(
            "INSERT INTO articles (source_id, url, normalized_url, title, domain) VALUES (?, ?, ?, 'Team copy', 'example.com')",
            [.text(id), .text("https://example.com/\(personalID)"), .text("example.com/\(personalID)")]
        )
    }

    /// Runs `body` under the apply guard, so its writes queue nothing: a library as generation 1 left it.
    static func quietly(_ store: KnowledgeStore, _ body: () throws -> Void) throws {
        try store.execute("INSERT INTO ck_apply_guard (id) VALUES (1)")
        defer { try? store.execute("DELETE FROM ck_apply_guard") }
        try body()
    }

    static func addSource(_ store: KnowledgeStore, _ id: String) throws {
        try store.execute("INSERT INTO sources (id, date_added, state, source_type, status) VALUES (?, 1, 'ready', 'article', 'active')", [.text(id)])
        try store.execute(
            "INSERT INTO articles (source_id, url, normalized_url, title, domain) VALUES (?, ?, ?, ?, 'example.com')",
            [.text(id), .text("https://example.com/\(id)"), .text("example.com/\(id)"), .text("Title \(id)")]
        )
    }

    /// A source filed into a pool through the app's own item write (`saveLearningGoalItem`).
    static func file(_ store: KnowledgeStore, _ sourceID: String, into goalID: String, reviewState: String? = "approved", origin: String = "seed") throws {
        try store.insertLearningGoalItem(goalID: goalID, sourceID: sourceID, addedAt: Date(timeIntervalSinceReferenceDate: 2_000), origin: origin, reviewState: reviewState)
    }

    // MARK: Records from another device

    /// A record's stored payload as another device would have written it, every field stamped at `ms`
    /// by `device`: a map's or set's keys each stamped as elements, every other field whole.
    static func record(
        _ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], zoneKey: String = libraryZoneKey,
        ms: Int64 = 1_759_400_000_000, device: String = "otheraaa"
    ) throws -> ReplicaRecord {
        var envelope = SyncEnvelope.new(type, id: id, saltID: OutboxTestProjections.saltID)
        var patch = RecordPatch(type, id: id)
        for (field, value) in fields {
            if let kind = type.spec.field(field)?.kind, kind != .scalar, let elements = value.objectValue {
                patch.changes[field] = .elements(elements)
            } else {
                patch.changes[field] = .value(value)
            }
        }
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: ms, counter: counter, deviceID: device)
        }
        return ReplicaRecord(
            zoneKey: zoneKey, recordName: RecordNaming.recordName(type: type, id: id, salt: salt), recordType: type.rawValue,
            wireID: id, systemFields: Data([1]), payload: try envelope.storedPayload(), seenPass: nil
        )
    }

    /// An Entry of `container` holding `source`, as another device writes one.
    static func entryRecord(
        _ containerID: String, _ sourceID: String, kind: String = "notebook", state: String = "active", approval: String? = "approved",
        orderKey: String = "a0", ms: Int64 = 1_759_400_000_000, device: String = "otheraaa"
    ) throws -> ReplicaRecord {
        var fields: [String: SyncJSON] = [
            "containerKind": .string(kind), "containerID": .string(containerID), "itemKind": .string("source"),
            "itemID": .string(sourceID), "state": .string(state), "orderKey": .string(orderKey), "origin": .string("added"),
            "addedAt": SyncJSON(Int64(1_759_000_000_000)),
        ]
        if let approval { fields["approval"] = .string(approval) }
        return try record(.entry, SyncIdentity.entryID(containerID: containerID, itemKind: "source", itemID: sourceID), fields, ms: ms, device: device)
    }

    /// Applies records as the engine does: replica rows and projections in one guarded transaction,
    /// then whatever their arrival freed.
    static func apply(_ store: KnowledgeStore, _ records: [ReplicaRecord]) throws {
        try store.replica.apply { replica in
            let projections = ProjectionApply(store: store, registry: registry)
            for record in records {
                try replica.upsertRecord(record)
                try projections.project(record)
            }
            try projections.drainReady()
        }
    }

    // MARK: What the feeder would send

    /// Every pending change past every debounce, by `<type>:<wire id>`.
    static func pending(_ store: KnowledgeStore) throws -> [String: OutboxChange] {
        let changes = try OutboxFeeder(connection: store, registry: registry).pendingChanges(now: Date().addingTimeInterval(60))
        return Dictionary(changes.map { ("\($0.recordType.rawValue):\($0.wireID)", $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func savedFields(_ change: OutboxChange?) -> [String: SyncJSON]? {
        guard case .save(let envelope)? = change?.action else { return nil }
        return envelope.fields
    }

    /// Sends every due change and acknowledges it as the server would, so the replica holds what was sent.
    static func sendAll(_ store: KnowledgeStore) throws {
        let feeder = OutboxFeeder(connection: store, registry: registry)
        for change in try feeder.nextBatch(now: Date().addingTimeInterval(60)) {
            switch change.action {
            case .save: try feeder.acknowledgeSave(change, serverRecord: try OutboxTestProjections.serverRecord(for: change))
            case .delete: try feeder.acknowledgeDelete(change)
            }
        }
    }

    /// The replica's envelope of a record in `Library`.
    static func held(_ store: KnowledgeStore, _ type: SyncRecordType, _ id: String, zoneKey: String = libraryZoneKey) throws -> SyncEnvelope? {
        try store.replica.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: id).map { try SyncEnvelope(storedPayload: $0.payload) }
    }

    static func count(_ store: KnowledgeStore, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64 {
        try store.scalarInteger(sql, parameters) ?? -1
    }

    static func text(_ store: KnowledgeStore, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        try store.scalarText(sql, parameters)
    }
}
