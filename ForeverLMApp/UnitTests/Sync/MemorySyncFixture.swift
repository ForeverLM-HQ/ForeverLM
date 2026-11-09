import Foundation
@testable import ForeverLM

/// Stores and rows for the memory record suites (WP13): an activated generation-2 store with the
/// registry's triggers and `Library`'s root, records as another device sends them, and the memory rows
/// written in SQL where generation 1's writers would put them.
enum MemorySyncFixture {
    static let registry = KnowledgeStore.projectionRegistry
    static let libraryZoneKey = OutboxTestProjections.libraryZoneKey
    /// The clock `OutboxTestProjections.prepareReplica` gives this Mac.
    static let deviceID = "macaaaaa"

    /// A generation-2 store as its activation leaves it: activated, triggers in place, `Library`'s root
    /// held and a clock with its device id.
    static func makeStore(_ name: String, triggers: Bool = true, activated: Bool = true) throws -> (root: URL, store: KnowledgeStore) {
        let root = try Schema154Fixture.temporaryRoot("WP13-\(name)")
        let store = try KnowledgeStore(storeDirectory: root, freeSpace: Schema154Fixture.roomy)
        if activated {
            try store.execForTesting("INSERT INTO ck_activation (id, activated_at) VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET activated_at = 1")
        }
        if triggers { try store.installOutboxTriggers(registry) }
        try OutboxTestProjections.prepareReplica(store)
        return (root, store)
    }

    /// A `Library` record as another device delivers it.
    static func record(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON]) throws -> ReplicaRecord {
        try SourceSyncFixture.record(type, id, fields, zoneKey: libraryZoneKey)
    }

    static func apply(_ store: KnowledgeStore, _ records: [ReplicaRecord]) throws {
        try SourceSyncFixture.apply(store, records)
    }

    static func pending(_ store: KnowledgeStore) throws -> [String: OutboxChange] {
        try SourceSyncFixture.pending(store)
    }

    /// The record a change would save, whole: what the replica holds with the change on it.
    static func fields(_ change: OutboxChange?) -> [String: SyncJSON]? {
        guard case .save(let envelope)? = change?.action else { return nil }
        return envelope.fields
    }

    /// The fields a change stamps: what it sends that the server does not hold.
    static func changed(_ change: OutboxChange?) -> Set<String> {
        Set(change?.stamps.keys.map(\.field) ?? [])
    }

    /// Sends everything due and acknowledges it, as the server would take it.
    static func sendAll(_ store: KnowledgeStore) throws {
        let feeder = OutboxFeeder(connection: store, registry: registry)
        for change in try feeder.nextBatch(now: Date().addingTimeInterval(600)) {
            switch change.action {
            case .save: try feeder.acknowledgeSave(change, serverRecord: try OutboxTestProjections.serverRecord(for: change))
            case .delete: try feeder.acknowledgeDelete(change)
            }
        }
    }

    static func text(_ store: KnowledgeStore, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        try store.scalarText(sql, parameters)
    }

    static func count(_ store: KnowledgeStore, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        Int(try store.scalarInteger(sql, parameters) ?? -1)
    }

    /// A Memory item with one anchor, as generation 1 keeps a card (`saveMemoryItem`).
    static func item(_ store: KnowledgeStore, id: String, target: String = "Four protons per NADH", sourceID: String = "src-1",
                     rubric: String = "{}", createdAt: Double = 700_000_000, status: String = "active") throws {
        try store.execute("""
            INSERT INTO memory_items (id, kind, target, rubric_json, status, created_at, updated_at) VALUES (?, 'concept', ?, ?, ?, ?, ?)
        """, [.text(id), .text(target), .text(rubric), .text(status), .real(createdAt), .real(createdAt)])
        try store.execute("""
            INSERT INTO memory_item_sources (id, memory_item_id, source_id, excerpt, source_sha256, sort_index) VALUES (?, ?, ?, 'pumps protons', 'abc', 0)
        """, [.text(id + "-anchor"), .text(id), .text(sourceID)])
    }

    /// An attempt as generation 1 records it.
    static func attempt(_ store: KnowledgeStore, id: String, item: String, at: Double, rating: String? = "good",
                        grade: String = "graded", session: String? = nil) throws {
        try store.execute("""
            INSERT INTO memory_attempts (id, memory_item_id, session_id, attempt_type, prompt, learner_answer, schedule_rating,
                grade_state, attempted_at)
            VALUES (?, ?, ?, 'review', 'How many?', 'Four', ?, ?, ?)
        """, [.text(id), .text(item), .text(session), .text(rating), .text(grade), .real(at)])
    }

    /// A preference row as `writePreference` keeps it: the value as a property list's XML.
    static func preference(_ store: KnowledgeStore, key: String, value: Any) throws {
        // As the app stores a preference: the plist `PreferenceStore.encodePlist` writes.
        guard let xml = PreferenceStore.encodePlist(value) else { throw KnowledgeStoreError.invalidData("not a property-list value") }
        try store.execute(
            "INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, 1) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(xml)]
        )
    }

    /// The local day `cocoaSeconds` falls on, as the learner's calendar names it.
    static func day(_ cocoaSeconds: Double) -> String {
        DayPlan.dateString(for: Date(timeIntervalSinceReferenceDate: cocoaSeconds))
    }
}
