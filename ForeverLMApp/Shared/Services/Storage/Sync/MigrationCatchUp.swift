import CloudKit
import Foundation
import OSLog
import SQLite3

// MARK: - The migration catch-up (docs/cloudkit-schema-design.md §13.4 step 0, WP16a)

/// How the catch-up's async code reaches the store: on the storage actor in the app
/// (`StorageService.performSync`), directly in a test. Every call is one bounded step.
protocol MigrationStoreAccess: Sendable {
    func perform<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) async throws -> T
}

/// Runs each step directly on the store, with the read-only window lifted for it, as the storage actor does.
struct DirectStoreAccess: MigrationStoreAccess {
    let store: KnowledgeStore

    func perform<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) async throws -> T {
        try KnowledgeStoreWriteGate.allowingWrites(on: store) { try body(store) }
    }
}

struct MigrationCatchUpConfiguration: Sendable {
    /// The change tag a stored `sync_metadata.system_fields` blob holds. A test whose transport hands out
    /// blobs of its own supplies the reader of those.
    var changeTag: @Sendable (Data) -> String? = { CloudKitRecordMapper.decodeSystemFields($0)?.recordChangeTag }
    /// Records applied in one step on the storage actor, so a window that stays readable never waits on
    /// the whole walk.
    var batchSize = 150
    /// The learner answered **Apply** to a tripped 5% guard (§13.3): the deferred catch-up runs once with
    /// the guard lifted. Never set for the full catch-up's own first run.
    var guardLifted = false
    var now: @Sendable () -> Date = { Date() }
    var assetsRoot: URL = FileManager.default.temporaryDirectory
}

/// What a catch-up did, for the log, Settings and the tests.
struct MigrationCatchUpReport: Equatable, Sendable {
    var returned = 0
    var applied = 0
    var unchanged = 0
    var keptLocal = 0
    var skippedDeletedLocally = 0
    var failed: [String] = []
    var deletedLocally = 0
    /// Names the old world deleted that this Mac keeps because a local change is pending.
    var keptPendingDeletions: [String] = []
    var mergedDocs: [String] = []
    /// Recovered Docs this run made, by id.
    var recoveredDocs: [String] = []
    var notesBases = 0
    var stagedPackages = 0
    var queuedAssets = 0
    var snapshotRows = 0
}

/// The question a tripped 5% guard asks (§13.4 step 0, D46): Apply, or Not this library.
struct MigrationGuardQuestion: Codable, Equatable, Sendable {
    var deleting: Int
    var of: Int
    var account: String?
    var askedAt: Date
}

enum MigrationCatchUpOutcome: Equatable, Sendable {
    /// `Knowledge` is not there: no old world, nothing applied, nothing deleted (R4-m4).
    case noOldWorld(account: String?)
    /// The walk would delete more than 5% of what `sync_metadata` names: nothing applied.
    case guardTripped(MigrationGuardQuestion)
    case applied(MigrationCatchUpReport)
}

// MARK: - What the walk planned

/// One old record the walk returned, decoded and decided.
struct MigrationPlannedRecord: Sendable {
    let cloud: CloudRecord
    let database: CloudDatabaseScope
    let home: CloudKitZoneHome
    let snapshotZone: String
    let entity: CloudKitSyncEntity
    let logicalKey: String
    let modifiedAt: Date
    let decision: MigrationRecordDecision
    let local: MigrationLocalFacts
    /// Nil when the record did not decode (it is still a returned name, so nothing is deleted for it).
    let decoded: LegacyRecord?

    var recordName: String { cloud.id.recordName }
}

struct MigrationCatchUpPlan: Sendable {
    var records: [MigrationPlannedRecord]
    var deletions: MigrationCatchUpRules.Deletions
    /// The rows `sync_metadata` names in the zones the walk covered.
    var held: Int
    /// Metadata of the records to delete locally, by record name.
    var deletionMetadata: [String: CloudKitSyncMetadata]

    var guardQuestion: MigrationGuardQuestion?
}

// MARK: - Planning

enum MigrationCatchUpPlanner {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationCatchUp")

    static func facts(_ entity: CloudKitSyncEntity, _ logicalKey: String, store: KnowledgeStore, configuration: MigrationCatchUpConfiguration) throws -> MigrationLocalFacts {
        var facts = MigrationLocalFacts()
        if let metadata = try store.loadSyncMetadata(entity: entity, logicalKey: logicalKey) {
            facts.syncedChangeTag = metadata.systemFieldsData.flatMap(configuration.changeTag)
            facts.isDeletedLocally = metadata.isDeleted
        }
        if try store.hasPendingSyncChange(entity: entity, logicalKey: logicalKey) {
            facts.pendingChangedAt = try store.pendingSyncChangeDate(entity: entity, logicalKey: logicalKey)
        }
        return facts
    }

    /// The records whose `payloadAsset` the walk must fetch by name, per zone (§13.4 step 0): a
    /// ReviewSession whose `payload` is empty, every changed Artifact (its Doc body package is its
    /// payload), and every Doc, changed or not, whose own encoding on this Mac does not reproduce its old
    /// `bodyRevision`, whose package the seed needs (R8-m6).
    static func assetNeeds(walk: OldContainerWalkResult, store: KnowledgeStore, configuration: MigrationCatchUpConfiguration) throws -> [CloudZoneID: Set<String>] {
        var needs: [CloudZoneID: Set<String>] = [:]
        for zone in walk.zones {
            for record in zone.records {
                guard let entity = CloudKitSyncEntity.from(recordType: record.recordType) else { continue }
                switch entity {
                case .reviewSession where record.hasEmptyPayload:
                    needs[zone.zoneID, default: []].insert(record.id.recordName)
                case .artifact:
                    guard let metadata = try store.loadSyncMetadata(recordName: record.id.recordName) else {
                        needs[zone.zoneID, default: []].insert(record.id.recordName)
                        continue
                    }
                    let local = MigrationLocalFacts(syncedChangeTag: metadata.systemFieldsData.flatMap(configuration.changeTag), isDeletedLocally: metadata.isDeleted)
                    if MigrationCatchUpRules.isChanged(serverChangeTag: record.changeTag, local: local) {
                        needs[zone.zoneID, default: []].insert(record.id.recordName)
                    } else if try ownEncodingDiffers(record, artifactID: metadata.logicalKey, store: store) {
                        needs[zone.zoneID, default: []].insert(record.id.recordName)
                    }
                default:
                    continue
                }
            }
        }
        return needs
    }

    /// Whether this Mac holds the Doc's body and encodes it to another revision than the old record's.
    private static func ownEncodingDiffers(_ record: CloudRecord, artifactID: String, store: KnowledgeStore) throws -> Bool {
        guard let data = record.payload,
              let revision = (try? JSONDecoder().decode(CloudKitArtifactPayload.self, from: data))?.bodyRevision,
              let own = try store.loadArtifactBodyPackageForSync(artifactID) else { return false }
        return own.revision != revision
    }

    /// Decodes and decides every record, and works out the deletions and the guard. Reads only.
    static func plan(walk: OldContainerWalkResult, store: KnowledgeStore, configuration: MigrationCatchUpConfiguration) throws -> MigrationCatchUpPlan {
        var planned: [MigrationPlannedRecord] = []
        var returned: [String: Set<String>] = [:]
        for zone in walk.zones {
            let snapshotZone = OldContainerZoneKey.snapshotZone(database: zone.database, zoneID: zone.zoneID)
            for record in zone.records {
                returned[snapshotZone, default: []].insert(record.id.recordName)
                guard let entity = CloudKitSyncEntity.from(recordType: record.recordType) else { continue }
                let ck = OldContainerWalk.ckRecord(record)
                let decoded: LegacyRecord?
                let descriptor: CloudKitRecordDescriptor
                do {
                    decoded = try LegacyRecordDecoder.decode(ck)
                    descriptor = try CloudKitRecordMapper.descriptor(for: ck)
                } catch {
                    logger.error("An old record does not decode: \(record.id.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
                if LegacyOwnership.dropped.contains(entity) { continue }
                let local = try facts(entity, descriptor.logicalKey, store: store, configuration: configuration)
                let decision = MigrationCatchUpRules.decide(serverChangeTag: record.changeTag, serverModifiedAt: descriptor.userModificationDate, local: local)
                planned.append(MigrationPlannedRecord(
                    cloud: record, database: zone.database, home: zone.home, snapshotZone: snapshotZone, entity: entity,
                    logicalKey: descriptor.logicalKey, modifiedAt: descriptor.userModificationDate, decision: decision, local: local, decoded: decoded
                ))
            }
        }
        // Parents before children, as the first-generation engine applies a fetch.
        let ordered = planned.enumerated().sorted { lhs, rhs in
            let left = priority(lhs.element.entity), right = priority(rhs.element.entity)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)

        let (held, deletions, metadata) = try deletions(walk: walk, returned: returned, store: store)
        var plan = MigrationCatchUpPlan(records: ordered, deletions: deletions, held: held.count, deletionMetadata: metadata)
        if !configuration.guardLifted, MigrationCatchUpRules.tripsGuard(deleting: deletions.apply.count, of: held.count) {
            plan.guardQuestion = MigrationGuardQuestion(deleting: deletions.apply.count, of: held.count, account: walk.account, askedAt: configuration.now())
        }
        return plan
    }

    private static func priority(_ entity: CloudKitSyncEntity) -> Int {
        switch entity {
        case .source: return 0
        case .course, .memoryAttempt, .sourceHighlight, .notebookTask: return 2
        default: return 1
        }
    }

    /// The names `sync_metadata` holds in the zones the walk covered that the walk did not return. A
    /// zone the walk could not read, or a team zone that went away, deletes nothing (§13.4 step 0).
    private static func deletions(
        walk: OldContainerWalkResult, returned: [String: Set<String>], store: KnowledgeStore
    ) throws -> (held: Set<String>, deletions: MigrationCatchUpRules.Deletions, metadata: [String: CloudKitSyncMetadata]) {
        var held = Set<String>()
        var pending = Set<String>()
        var result = MigrationCatchUpRules.Deletions()
        var metadata: [String: CloudKitSyncMetadata] = [:]
        for zone in walk.zones {
            let snapshotZone = OldContainerZoneKey.snapshotZone(database: zone.database, zoneID: zone.zoneID)
            let home = zone.home
            var zoneHeld = Set<String>()
            var zonePending = Set<String>()
            try store.queryBind("""
                SELECT m.entity_type, m.logical_key, m.record_name,
                       EXISTS(SELECT 1 FROM sync_changes c WHERE c.entity_type = m.entity_type AND c.logical_key = m.logical_key)
                FROM sync_metadata m
                WHERE m.is_deleted = 0 AND m.system_fields IS NOT NULL AND m.zone_scope = ? AND m.zone_name = ?
                  AND COALESCE(m.zone_owner_record_name, '') = ?
            """, bind: { stmt in
                store.bind(stmt, 1, home.scope.rawValue)
                store.bind(stmt, 2, home.zoneName)
                store.bind(stmt, 3, home.ownerRecordName ?? "")
            }) { stmt in
                guard let entityRaw = store.string(stmt, 0), let entity = CloudKitSyncEntity(rawValue: entityRaw),
                      !LegacyOwnership.dropped.contains(entity), let key = store.string(stmt, 1), let name = store.string(stmt, 2) else { return }
                zoneHeld.insert(name)
                if sqlite3_column_int(stmt, 3) != 0 { zonePending.insert(name) }
                metadata[name] = CloudKitSyncMetadata(entity: entity, logicalKey: key, recordName: name, systemFieldsData: nil, userModificationDate: Date(), isDeleted: false, home: home)
            }
            held.formUnion(zoneHeld)
            pending.formUnion(zonePending)
            let split = MigrationCatchUpRules.deletions(held: zoneHeld, pending: zonePending, returned: returned[snapshotZone] ?? [])
            result.apply += split.apply
            result.keptPending += split.keptPending
        }
        return (held, result, metadata)
    }
}

extension KnowledgeStore {
    /// `changed_at` of the pending change generation 1's drain has not sent (the same row
    /// `hasPendingSyncChange` finds).
    func pendingSyncChangeDate(entity: CloudKitSyncEntity, logicalKey: String) throws -> Date? {
        var changedAt: Date?
        try queryBind("SELECT changed_at FROM sync_changes WHERE entity_type = ? AND logical_key = ? AND operation = 'save'", bind: { stmt in
            bind(stmt, 1, entity.rawValue)
            bind(stmt, 2, logicalKey)
        }) { stmt in
            changedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return changedAt
    }
}
