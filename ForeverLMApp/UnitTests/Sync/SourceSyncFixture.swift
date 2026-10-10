import Foundation
import Testing
@testable import ForeverLM

/// Stores, sources and records for WP7's suites (docs/cloudkit-schema-design.md §3.5.4, §3.5.5): a
/// generation-2 store with the real Source, Collection and playlist Entry projections and their
/// triggers, a replica holding `Library`'s root and the `Catalog` zone, sources of each kind written
/// the way the app writes them, and inbound records as another device would send them.
enum SourceSyncFixture {
    static let registry = KnowledgeStore.projectionRegistry
    static let catalogZoneKey = "private/Catalog"
    static var salt: Data { OutboxTestProjections.salt }

    /// A generation-2 store in a folder of its own with the registry's triggers installed, as the
    /// activation leaves one; `triggers: false` leaves it as it is before the activation.
    static func makeStore(_ name: String, triggers: Bool = true) throws -> (root: URL, store: KnowledgeStore) {
        let root = try Schema154Fixture.temporaryRoot("WP7-\(name)")
        let store = try KnowledgeStore(storeDirectory: root, syncGeneration: .two, freeSpace: Schema154Fixture.roomy)
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

    /// A source saved through the app's own write path, inside its transaction.
    @discardableResult
    static func save(_ store: KnowledgeStore, _ article: StudioArticle) throws -> StudioArticle {
        try store.saveSource(article)
        return article
    }

    static func article(_ url: String, title: String, type: StudioSourceType = .article, state: StudioArticleState = .queued) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: type)
        article.state = state
        return article
    }

    /// A record's stored payload as another device would have written it: a map's or set's keys each
    /// stamped as elements, every other field whole.
    static func payload(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON]) throws -> Data {
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
            return SyncStamp(policy: policy, milliseconds: 1_759_400_000_000, counter: counter, deviceID: "otheraaa")
        }
        return try envelope.storedPayload()
    }

    /// A Catalog record as another device would deliver it.
    static func record(_ type: SyncRecordType, _ id: String, _ fields: [String: SyncJSON], zoneKey: String = catalogZoneKey) throws -> ReplicaRecord {
        ReplicaRecord(
            zoneKey: zoneKey, recordName: RecordNaming.recordName(type: type, id: id, salt: salt), recordType: type.rawValue,
            wireID: id, systemFields: Data([1]), payload: try payload(type, id, fields), seenPass: nil
        )
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

    /// What the feeder would send now, past every debounce, by record.
    static func pending(_ store: KnowledgeStore) throws -> [String: OutboxChange] {
        let changes = try OutboxFeeder(connection: store, registry: registry).pendingChanges(now: Date().addingTimeInterval(60))
        return Dictionary(changes.map { ("\($0.recordType.rawValue):\($0.wireID)", $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The fields a pending change would save.
    static func savedFields(_ change: OutboxChange?) -> [String: SyncJSON]? {
        guard case .save(let envelope)? = change?.action else { return nil }
        return envelope.fields
    }

    /// Sends every due change and acknowledges it as the server would, so the replica holds what was sent.
    static func sendAll(_ store: KnowledgeStore) throws {
        let feeder = OutboxFeeder(connection: store, registry: registry)
        for change in try feeder.nextBatch(now: Date().addingTimeInterval(60)) {
            switch change.action {
            case .save:
                try feeder.acknowledgeSave(change, serverRecord: try OutboxTestProjections.serverRecord(for: change))
            case .delete:
                try feeder.acknowledgeDelete(change)
            }
        }
    }

    static func count(_ store: KnowledgeStore, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64 {
        try store.scalarInteger(sql, parameters) ?? -1
    }

    static func text(_ store: KnowledgeStore, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        try store.scalarText(sql, parameters)
    }
}
