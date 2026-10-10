import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// What the refresh's and the deferred catch-up's suites add to `MigrationImportRig` (docs/cloudkit-schema-design.md
/// §13.3, §13.4 step 0, WP16b2). The Mac under test is a generation-2 store whose tables hold what its last
/// generation-1 sync left (`syncedHere`: the old record applied, its change tag in `sync_metadata`, nothing in the
/// outbox, as the activation leaves rows it derived), the server holds only what `seed()` or a test puts there, and
/// the old world is another Mac's generation-1 store writing the old container.
extension MigrationImportRig {
    // MARK: This Mac's rows, as the last sync left them

    /// The old record as the old container holds it now.
    func oldRecord(_ entity: CloudKitSyncEntity, _ key: String) throws -> CloudRecord {
        let name = CloudKitRecordMapper.recordName(for: entity, logicalKey: key)
        return try #require(server.storedRecord(name, zone: Self.zoneName, owner: Self.learner, container: FakeCloudKit.legacyContainer))
    }

    /// Drops what the triggers queued: the rows stand as the activation derived them from generation-1 truth, with
    /// nothing unsent.
    func settleRows() throws {
        try store.execute("DELETE FROM ck_outbox_fields")
        try store.execute("DELETE FROM ck_outbox")
    }

    /// This Mac as it was when it last received the old record: applied into its tables, with its tag in
    /// `sync_metadata`, and no unsent change left (neither generation 1's nor the outbox's).
    func syncedHere(_ entity: CloudKitSyncEntity, _ key: String) throws {
        let record = try oldRecord(entity, key)
        let applied = try CloudKitRecordMapper.apply(record: OldContainerWalk.ckRecord(record), to: store)
        try store.saveSyncMetadata(CloudKitSyncMetadata(
            entity: applied.entity, logicalKey: applied.logicalKey, recordName: record.id.recordName,
            systemFieldsData: Data((record.changeTag ?? "").utf8), userModificationDate: applied.userModificationDate, isDeleted: false
        ))
        try store.clearPendingSyncChange(entity: applied.entity, logicalKey: applied.logicalKey)
        if entity == .learningGoal { try store.keepNotebookRowsForGeneration2(goalIDs: [key]) }
        try settleRows()
    }

    /// A pending change this Mac's generation-1 drain never sent, at `date`.
    func pendingOldChange(_ entity: CloudKitSyncEntity, _ key: String, at date: Date) throws {
        try store.clearPendingSyncChange(entity: entity, logicalKey: key)
        try store.markRecordChanged(entity: entity, logicalKey: key, at: date)
    }

    /// This Mac's `ck_activation` journal, as an activation left it.
    func activate(_ mode: ActivationMode, account: String? = nil) throws {
        var journal = try store.activationJournal() ?? ActivationJournal()
        journal.mode = mode
        journal.account = account
        try store.writeActivationJournal(journal)
    }

    // MARK: This Mac's own snapshot

    /// The snapshot a catch-up's walk leaves, as of now: every record of the old zone mapped and kept as a base
    /// entry with its change tag, and the zone's token.
    func ownSnapshot() async throws {
        let zone = try #require(MigrationOldZone(name: Self.zoneName))
        let fetched = try await MigrationOldChangeFetcher(transport: oldContainer).fetch(zone, since: nil)
        var walk = OldContainerWalkResult(startedAt: clock.now)
        walk.zones = [OldContainerWalkedZone(zoneID: zone.zoneID, database: .private, records: fetched.modified, token: try #require(fetched.token))]
        var needs = Set<String>()
        for record in fetched.modified {
            switch CloudKitSyncEntity.from(recordType: record.recordType) {
            case .artifact?: needs.insert(record.id.recordName)
            case .reviewSession? where record.hasEmptyPayload: needs.insert(record.id.recordName)
            default: break
            }
        }
        try await OldContainerWalk(transport: oldContainer).fetchPayloadAssets([zone.zoneID: needs], into: &walk)
        defer { walk.discard() }
        let context = StoreLegacyMappingContext(connection: store)
        var entries: [String: MigrationBaseEntry] = [:]
        for cloud in walk.zones[0].records {
            let mapping = try LegacyV2Mapping.map(try MigrationLateImport.decode(cloud), context: context)
            entries[MigrationBaseShards.entryKey(zone: Self.zoneName, recordName: cloud.id.recordName)] = MigrationBaseEntry(mapping: mapping, changeTag: cloud.changeTag)
        }
        try await OwnSnapshotBase(store: local).replaceAll(entries: entries, tokens: [Self.zoneName: try #require(fetched.tokenText)], zones: [Self.zoneName])
    }

    /// The token of the old zone in this Mac's own snapshot.
    func ownToken() async throws -> String? {
        try await OwnSnapshotBase(store: local).watermark()?.tokens[Self.zoneName]
    }

    // MARK: The refresh

    func refresher() -> MigrationRefresh {
        MigrationRefresh(
            oldContainer: oldContainer, store: local, ledger: ledger, gate: StoreMigrationFetchGate(store: local), uploader: uploader,
            probe: StoreMigrationBodyEditProbe(store: store), configuration: passConfiguration()
        )
    }

    func passConfiguration() -> MigrationLateImport.Configuration {
        var configuration = MigrationLateImport.Configuration(deviceID: Self.deviceID)
        configuration.clock = { [clock] in clock.now }
        return configuration
    }

    func refresh(guardLifted: Bool = false) async throws -> MigrationRefresh.Outcome {
        try await refresher().run(guardLifted: guardLifted)
    }

    /// The report of a refresh that ran.
    @discardableResult
    func refreshed(guardLifted: Bool = false) async throws -> MigrationPassReport {
        guard case .refreshed(let report) = try await refresh(guardLifted: guardLifted) else {
            Issue.record("the refresh did not run")
            return MigrationPassReport(passID: "")
        }
        return report
    }

    // MARK: The deferred catch-up

    func deferredCatchUp() -> MigrationDeferredCatchUp {
        var catchUp = MigrationDeferredCatchUp(
            oldContainer: oldContainer, store: local, base: base, ledger: ledger, gate: StoreMigrationFetchGate(store: local), uploader: uploader,
            configuration: passConfiguration()
        )
        catchUp.walkConfiguration.changeTag = MigrationCatchUpRig.tagReader
        return catchUp
    }

    func catchUp(guardLifted: Bool = false) async throws -> MigrationDeferredCatchUp.Outcome {
        try await deferredCatchUp().run(guardLifted: guardLifted)
    }

    /// The report of a deferred catch-up that ran.
    @discardableResult
    func caughtUp(guardLifted: Bool = false) async throws -> MigrationDeferredCatchUp.Report {
        guard case .caughtUp(let report) = try await catchUp(guardLifted: guardLifted) else {
            Issue.record("the deferred catch-up did not run")
            return MigrationDeferredCatchUp.Report()
        }
        return report
    }

    // MARK: Reading the store

    func rowCount(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int {
        Int(try store.scalarInteger(sql, parameters) ?? 0)
    }

    func hasEntryRow(_ notebookID: String, _ sourceID: String) throws -> Bool {
        try rowCount("SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = ? AND source_id = ?", [.text(notebookID), .text(sourceID)]) == 1
    }

    func patchCount(_ type: SyncRecordType) throws -> Int {
        try rowCount("SELECT COUNT(*) FROM ck_patches WHERE record_type = ?", [.text(type.rawValue)])
    }

    func recoveredPatches(prefix: String) throws -> Int {
        try rowCount("SELECT COUNT(*) FROM ck_patches WHERE record_type = 'Artifact' AND wire_id LIKE ?", [.text(prefix + "%")])
    }

    func catchUpAt() throws -> Double? {
        try store.activationJournal()?.catchUpAt
    }

    func hasSnapshotRows() throws -> Bool {
        try rowCount("SELECT COUNT(*) FROM ck_legacy_snapshot") > 0
    }

    /// The old container's own writes of one old record by its entity and key, with a record of the replica's
    /// view on the server (an acknowledged copy of what the Mac holds).
    func serverHolds(_ type: SyncRecordType, _ id: String) throws -> Bool {
        let zoneKey = type == .source || type == .collection ? Self.N.catalogZoneKey : Self.N.libraryZoneKey
        return try store.replica.record(zoneKey: zoneKey, recordType: type.rawValue, wireID: id) != nil
    }

    /// Puts the record of the rows into the replica as the server would hold it after another Mac's seed, every field
    /// stamped by that Mac (a build-N write), so a pass sees the server holding it.
    func serverReceives(_ type: SyncRecordType, _ id: String, ms: Int64 = 1_759_400_000_000) throws {
        let reference = ProjectionRecordRef(zoneKey: PrivateSyncZones.libraryKey, zone: .library, type: type, wireID: id, localID: id)
        let projection = try #require(Self.N.registry.projection(for: type))
        let fields = try #require(try projection.encode(reference, connection: store))
        var envelope = SyncEnvelope.new(type, id: id, saltID: OutboxTestProjections.saltID)
        var patch = RecordPatch(type, id: id)
        for (field, value) in fields where !value.isNull {
            guard let spec = type.spec.field(field) else { continue }
            if spec.kind == .scalar {
                patch.changes[field] = .value(value)
            } else if let elements = value.objectValue {
                patch.changes[field] = .elements(elements)
            }
        }
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: ms, counter: counter, deviceID: "otheraaa")
        }
        let zoneKey = type == .source || type == .collection ? Self.N.catalogZoneKey : Self.N.libraryZoneKey
        try store.replica.upsertRecord(ReplicaRecord(
            zoneKey: zoneKey, recordName: RecordNaming.recordName(type: type, id: id, salt: Self.N.salt), recordType: type.rawValue,
            wireID: id, systemFields: Data([2]), payload: try envelope.storedPayload(), seenPass: nil
        ))
    }
}
