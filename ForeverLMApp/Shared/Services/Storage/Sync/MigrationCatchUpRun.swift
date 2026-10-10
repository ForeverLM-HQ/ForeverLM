import CloudKit
import Foundation
import OSLog

// MARK: - Applying a walk into today's tables, and the snapshot (docs/cloudkit-schema-design.md §13.4 step 0)

/// The full catch-up keeps generation 1's own rules (§13.4 step 0): an old record is applied with the
/// writers generation 1 uses for an inbound record, its deletions included, bodies decided by §13.6's
/// body rule. It runs inside the activation, before the derivations, on a store no generation-2 sync
/// has touched, so the triggers are not installed yet and nothing is queued for the new container.
enum MigrationCatchUpApplier {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationCatchUp")

    /// The record types whose file assets (`sourcePDFAsset` and the rest) wait in `ck_backfill_queue`
    /// until after `activated_at` (§13.3 step 4): no derivation reads them.
    private static let assetEntities: Set<CloudKitSyncEntity> = [.source, .book, .meetingGroup, .course]
    /// The old file fields a queued record may carry (`CKRecord.FieldKey`).
    static let assetFields = [
        CKRecord.FieldKey.sourcePDFAsset, CKRecord.FieldKey.sourceReaderHTMLAsset, CKRecord.FieldKey.sourceContentAsset,
        CKRecord.FieldKey.sourceListenableContentAsset, CKRecord.FieldKey.sourceRawContentAsset, CKRecord.FieldKey.podcastRawTTMLAsset,
        CKRecord.FieldKey.paperThumbnailAsset, CKRecord.FieldKey.bookCoverAsset, CKRecord.FieldKey.meetingIconAsset,
        CKRecord.FieldKey.courseQuizPicturesAsset, CKRecord.FieldKey.walkthroughPicturesAsset,
    ]
    static let assetQueueKind = "oldContainerAssets"

    /// One bounded batch of the plan, applied on the storage actor.
    static func apply(_ batch: [MigrationPlannedRecord], store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        for planned in batch {
            do {
                switch planned.decision {
                case .skipDeletedLocally:
                    state.report.skippedDeletedLocally += 1
                case .unchanged:
                    state.report.unchanged += 1
                    try MigrationBodies.saveNotesBase(planned, store: store, state: state)
                case .keepLocal:
                    state.report.keptLocal += 1
                    switch planned.entity {
                    case .artifact: try MigrationBodies.keepArtifactLocal(planned, store: store, state: state)
                    case .learningGoal: try MigrationBodies.keepLearningGoalLocal(planned, store: store, state: state)
                    default: break
                    }
                    try MigrationBodies.saveNotesBase(planned, store: store, state: state)
                    try queueAssets(planned, store: store, state: state)
                case .apply:
                    try applyOne(planned, store: store, state: state)
                    try MigrationBodies.saveNotesBase(planned, store: store, state: state)
                    try queueAssets(planned, store: store, state: state)
                    state.report.applied += 1
                }
            } catch {
                state.report.failed.append("\(planned.entity.rawValue):\(planned.logicalKey)")
                logger.error("Could not apply the old \(planned.entity.rawValue, privacy: .public) \(planned.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func applyOne(_ planned: MigrationPlannedRecord, store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        let ck = OldContainerWalk.ckRecord(planned.cloud)
        let descriptor = CloudKitRecordDescriptor(entity: planned.entity, logicalKey: planned.logicalKey, userModificationDate: planned.modifiedAt)
        // The team's own record names its zone and, on the owner's other Macs, is how the team first appears.
        if planned.entity == .team, case .team(let payload)? = planned.decoded?.payload {
            try store.upsertTeamFromZone(payload, home: planned.home, permission: nil)
        }
        if planned.entity == .memoryItem || planned.entity == .memoryAttempt,
           try store.hasLocalSyncRecord(entity: planned.entity, logicalKey: planned.logicalKey) {
            do {
                try CloudKitRecordMapper.validateLocalNewerImmutableConflict(record: ck, to: store)
            } catch {
                // An immutable record that diverges: a Memory item's server winner is adopted, anything
                // else is left as it is and logged (generation 1 parks it in `sync_conflicts`).
                guard let applied = try CloudKitRecordMapper.adoptDivergentMemoryItemServerWinner(record: ck, to: store) else { throw error }
                try saveMetadata(planned, ck: ck, applied: applied, store: store)
                return
            }
        }
        let applied: CloudKitAppliedRecord
        switch planned.entity {
        case .artifact: applied = try MigrationBodies.applyArtifact(planned, ck: ck, descriptor: descriptor, store: store, state: state)
        case .learningGoal: applied = try MigrationBodies.applyLearningGoal(planned, ck: ck, descriptor: descriptor, store: store, state: state)
        default: applied = try CloudKitRecordMapper.applyFetched(record: ck, descriptor: descriptor, home: planned.home, to: store)
        }
        try saveMetadata(planned, ck: ck, applied: applied, store: store)
    }

    /// The record is now what this Mac last synced: its system fields, and no pending change.
    private static func saveMetadata(_ planned: MigrationPlannedRecord, ck: CKRecord, applied: CloudKitAppliedRecord, store: KnowledgeStore) throws {
        if applied.logicalKey != planned.logicalKey {
            // An old random id that an alias already owns: a tombstone, so it is not applied again.
            try store.saveSyncMetadata(CloudKitSyncMetadata(
                entity: planned.entity, logicalKey: planned.logicalKey, recordName: planned.recordName, systemFieldsData: nil,
                userModificationDate: planned.modifiedAt, isDeleted: true, home: planned.home
            ))
            try store.clearPendingSyncChange(entity: applied.entity, logicalKey: applied.logicalKey)
            return
        }
        try store.saveSyncMetadata(CloudKitSyncMetadata(
            entity: applied.entity, logicalKey: applied.logicalKey, recordName: planned.recordName,
            systemFieldsData: planned.cloud.systemFields ?? CloudKitRecordMapper.encodeSystemFields(ck),
            userModificationDate: applied.userModificationDate, isDeleted: false, home: planned.home
        ))
        try store.clearSyncConflict(entity: applied.entity, logicalKey: applied.logicalKey)
        try store.clearPendingSyncChange(entity: applied.entity, logicalKey: applied.logicalKey)
    }

    /// The old record's file assets, to be downloaded after `activated_at` (§13.3 step 4, R4-m15).
    private static func queueAssets(_ planned: MigrationPlannedRecord, store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        guard assetEntities.contains(planned.entity) else { return }
        let payload: [String: Any] = [
            "database": planned.database.rawValue, "zone": planned.cloud.id.zoneID.zoneName, "owner": planned.cloud.id.zoneID.ownerName,
            "recordName": planned.recordName, "entity": planned.entity.rawValue, "fields": assetFields,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        try store.execute("""
            INSERT INTO ck_backfill_queue (kind, target, payload_json, enqueued_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(kind, target) DO UPDATE SET payload_json = excluded.payload_json
        """, [.text(assetQueueKind), .text("\(planned.snapshotZone)/\(planned.recordName)"), .text(json), .real(Date().timeIntervalSinceReferenceDate)])
        state.report.queuedAssets += 1
    }

    /// The old world's deletions: each row `sync_metadata` names that the walk did not return, unless a
    /// local change is pending (kept and logged).
    static func applyDeletions(_ names: [String], metadata: [String: CloudKitSyncMetadata], store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        for name in names {
            guard let held = metadata[name] else { continue }
            do {
                try CloudKitSyncEngine.applyRemoteDeletion(for: held, store: store)
                try store.clearPendingSyncChange(entity: held.entity, logicalKey: held.logicalKey)
                try store.clearSyncConflict(entity: held.entity, logicalKey: held.logicalKey)
                state.report.deletedLocally += 1
            } catch {
                state.report.failed.append("delete:\(held.entity.rawValue):\(held.logicalKey)")
                logger.error("Could not apply an old deletion of \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - The snapshot

/// This Mac's view of the old zones after its walk (`ck_legacy_snapshot`, §13.3, §13.4 step 0): per old
/// record its change tag and, from `LegacyV2Mapping`, the owner flag and field hash of every v2 record it
/// gives, as the shared base's shards hold them; and the walk's change tokens (`ck_engine_state`, one
/// scope per zone, `OldContainerZoneKey.stateKey`). The seeder publishes it as the base in P0.
enum MigrationCatchUpSnapshot {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MigrationCatchUp")
    private static let unmappable = #"{"r":{},"w":false}"#

    /// Replaces the snapshot rows of the walk's zones with this batch's first call (`first`), then adds.
    static func write(_ batch: [MigrationPlannedRecord], first: Bool, zones: [String], store: KnowledgeStore, state: MigrationCatchUpRunState) throws {
        try store.exec("BEGIN IMMEDIATE")
        do {
            if first {
                for zone in zones { try store.execute("DELETE FROM ck_legacy_snapshot WHERE old_zone = ?", [.text(zone)]) }
            }
            let context = StoreLegacyMappingContext(connection: store)
            for planned in batch {
                var entry = unmappable
                if let decoded = planned.decoded {
                    do {
                        entry = String(decoding: try LegacyV2Mapping.map(decoded, context: context).baseEntry().serialized(), as: UTF8.self)
                    } catch {
                        logger.error("An old record does not map: \(planned.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                try store.execute("""
                    INSERT INTO ck_legacy_snapshot (old_zone, record_name, change_tag, field_hashes) VALUES (?, ?, ?, ?)
                    ON CONFLICT(old_zone, record_name) DO UPDATE SET change_tag = excluded.change_tag, field_hashes = excluded.field_hashes
                """, [.text(planned.snapshotZone), .text(planned.recordName), .text(planned.cloud.changeTag), .text(entry)])
                state.report.snapshotRows += 1
            }
            try store.exec("COMMIT")
        } catch {
            try? store.exec("ROLLBACK")
            throw error
        }
    }

    /// The walk's tokens, one scope per zone.
    static func writeTokens(_ zones: [OldContainerWalkedZone], store: KnowledgeStore, now: Date) throws {
        for zone in zones { try store.replica.setEngineState(zone.stateKey, zone.token.data, now: now) }
    }

    static func token(zoneKey: String, store: KnowledgeStore) throws -> CloudChangeToken? {
        try store.replica.engineState(zoneKey).map(CloudChangeToken.init(data:))
    }
}

// MARK: - The run

/// The full migration catch-up (§13.4 step 0): walk the old zones, decide every record, apply them in
/// bounded batches once the walk is complete, apply the old world's deletions under the 5% guard, make
/// the Recovered Docs, stage the packages the seed needs, and keep the snapshot, the tokens and the
/// walk's start time. A walk that fails, or trips the guard, has applied nothing.
struct MigrationCatchUp {
    let transport: any CloudTransport
    let access: any MigrationStoreAccess
    var configuration = MigrationCatchUpConfiguration()
    /// Told as the run moves: "walking", "applying 300 of 16000".
    var progress: (@Sendable (String) -> Void)?

    func run() async throws -> MigrationCatchUpOutcome {
        let config = configuration
        let walker = OldContainerWalk(transport: transport, now: config.now, assetsRoot: config.assetsRoot)
        progress?("Reading the old iCloud store")
        var walk = try await walker.fetchZones()
        defer { walk.discard() }
        if walk.knowledgeMissing { return .noOldWorld(account: walk.account) }

        let first = walk
        let needs = try await access.perform { store in try MigrationCatchUpPlanner.assetNeeds(walk: first, store: store, configuration: config) }
        try await walker.fetchPayloadAssets(needs, into: &walk)

        let fetched = walk
        let plan = try await access.perform { store in try MigrationCatchUpPlanner.plan(walk: fetched, store: store, configuration: config) }
        if let question = plan.guardQuestion { return .guardTripped(question) }

        let state = MigrationCatchUpRunState()
        state.report.returned = fetched.recordCount
        let records = plan.records
        for start in stride(from: 0, to: records.count, by: config.batchSize) {
            try Task.checkCancellation()
            let batch = Array(records[start ..< min(start + config.batchSize, records.count)])
            progress?("Applying \(start + batch.count) of \(records.count)")
            try await access.perform { store in try MigrationCatchUpApplier.apply(batch, store: store, state: state) }
            await Task.yield()
        }
        let deletions = plan.deletions
        let metadata = plan.deletionMetadata
        state.report.keptPendingDeletions = deletions.keptPending
        try await access.perform { store in try MigrationCatchUpApplier.applyDeletions(deletions.apply, metadata: metadata, store: store, state: state) }

        // After every record is in, so a Recovered Doc finds its notebook.
        try await access.perform { store in try MigrationBodies.makeRecoveries(state, store: store) }
        for start in stride(from: 0, to: records.count, by: config.batchSize) {
            let batch = Array(records[start ..< min(start + config.batchSize, records.count)])
            try await access.perform { store in
                for planned in batch where planned.entity == .artifact && planned.decision != .skipDeletedLocally {
                    try MigrationBodies.stagePackage(planned, store: store, state: state)
                }
            }
        }

        progress?("Keeping this Mac's view of the old store")
        let zoneNames = fetched.zones.map { OldContainerZoneKey.snapshotZone(database: $0.database, zoneID: $0.zoneID) }
        // A record that did not apply keeps no snapshot row: its old change never reached this Mac's rows, so
        // the shared base must not call it handled. Without an entry the first late-import pass applies
        // every field of it (F9); a resumed catch-up tries it again the next time one runs.
        let failedNames = Set(state.report.failed)
        let snapshotRecords = records.filter { !failedNames.contains("\($0.entity.rawValue):\($0.logicalKey)") }
        var wrote = false
        for start in stride(from: 0, to: max(snapshotRecords.count, 1), by: 200) {
            let batch = Array(snapshotRecords[min(start, snapshotRecords.count) ..< min(start + 200, snapshotRecords.count)])
            let isFirst = !wrote
            wrote = true
            try await access.perform { store in try MigrationCatchUpSnapshot.write(batch, first: isFirst, zones: zoneNames, store: store, state: state) }
        }
        let zones = fetched.zones
        let startedAt = fetched.startedAt
        let account = fetched.account
        try await access.perform { store in
            try MigrationCatchUpSnapshot.writeTokens(zones, store: store, now: startedAt)
            var journal = try store.activationJournal() ?? ActivationJournal()
            journal.catchUpAt = startedAt.timeIntervalSinceReferenceDate
            if journal.account == nil { journal.account = account }
            try store.writeActivationJournal(journal)
        }
        return .applied(state.report)
    }
}
