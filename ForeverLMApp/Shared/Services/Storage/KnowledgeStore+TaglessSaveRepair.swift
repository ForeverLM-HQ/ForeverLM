import CloudKit
import Foundation
import SQLite3

/// A save CloudKit refused as an optimistic-lock miss without sending its own
/// copy, parked in `sync_conflicts` by the sent-changes handler.
///
/// That refusal has one common cause: a record the server already holds was
/// sent with no change tag, as an unconditional create. `sync_metadata` then
/// has no `system_fields` for it, which is the discriminator this repair keys
/// on — on 2026-09-01 every one of the 63 records stranded by the container
/// rebase matched it, and none of the records that were syncing did.
struct CloudKitTaglessSaveQuarantine: Equatable, Sendable {
    let entity: CloudKitSyncEntity
    let logicalKey: String
    let recordName: String
    let localModificationDate: Date
    let detectedAt: Date
}

enum CloudKitTaglessSaveRepairOutcome: Equatable, Sendable {
    /// The local row is still there and now carries the server's change tag;
    /// its save is queued again and will go up as a conditional write.
    case requeuedSave
    /// The local row was deleted while the record sat in quarantine. The
    /// quarantine guard withheld that tombstone (it must never delete an
    /// unrelated server winner), so the delete is queued now instead.
    case tombstoned
}

extension KnowledgeStore {
    /// `reason` pattern of a rejected-save quarantine carrying
    /// `CKError.serverRecordChanged`.
    static var taglessRejectedSaveReasonPattern: String {
        CloudKitRejectedSaveQuarantine.reasonPrefix
            + String(CKError.Code.serverRecordChanged.rawValue)
            + "\n%"
    }

    /// Parked oplock misses whose local metadata has no change tag. Bounded and
    /// indexed; cheap to ask on every flush.
    func loadTaglessRejectedSaveQuarantines(limit: Int = 200) throws -> [CloudKitTaglessSaveQuarantine] {
        var result: [CloudKitTaglessSaveQuarantine] = []
        try queryBind("""
            SELECT conflicts.entity_type, conflicts.logical_key, conflicts.record_name,
                   conflicts.local_modification_at, conflicts.detected_at
            FROM sync_conflicts AS conflicts
            LEFT JOIN sync_metadata AS metadata
              ON metadata.entity_type = conflicts.entity_type
             AND metadata.logical_key = conflicts.logical_key
            WHERE conflicts.reason LIKE ?
              AND metadata.system_fields IS NULL
            ORDER BY conflicts.detected_at
            LIMIT \(max(0, limit))
        """, bind: { statement in
            bind(statement, 1, Self.taglessRejectedSaveReasonPattern)
        }) { statement in
            guard let entityRaw = self.string(statement, 0),
                  let entity = CloudKitSyncEntity(rawValue: entityRaw),
                  let logicalKey = self.string(statement, 1),
                  let recordName = self.string(statement, 2) else { return }
            result.append(CloudKitTaglessSaveQuarantine(
                entity: entity,
                logicalKey: logicalKey,
                recordName: recordName,
                localModificationDate: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)
                ),
                detectedAt: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4)
                )
            ))
        }
        return result
    }

    /// Give a parked record the server's change tag and put it back in the
    /// queue, so its next save is a conditional write the server can accept.
    /// Local content wins: the caller has already decided the local copy is
    /// at least as new as the server's.
    func adoptServerChangeTag(
        for quarantine: CloudKitTaglessSaveQuarantine,
        systemFields: Data,
        now: Date = Date()
    ) throws -> CloudKitTaglessSaveRepairOutcome {
        let outcome: CloudKitTaglessSaveRepairOutcome
        try exec("BEGIN IMMEDIATE")
        do {
            try clearSyncConflict(entity: quarantine.entity, logicalKey: quarantine.logicalKey)
            if try hasLocalSyncRecord(entity: quarantine.entity, logicalKey: quarantine.logicalKey) {
                try saveSyncMetadata(CloudKitSyncMetadata(
                    entity: quarantine.entity,
                    logicalKey: quarantine.logicalKey,
                    recordName: quarantine.recordName,
                    systemFieldsData: systemFields,
                    userModificationDate: quarantine.localModificationDate,
                    isDeleted: false
                ))
                try upsertSyncSave(
                    entity: quarantine.entity,
                    logicalKey: quarantine.logicalKey,
                    at: max(now, quarantine.localModificationDate),
                    preserveExistingScope: true
                )
                outcome = .requeuedSave
            } else {
                try markRecordDeleted(entity: quarantine.entity, logicalKey: quarantine.logicalKey, at: now)
                outcome = .tombstoned
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return outcome
    }

    /// The server does not hold the record after all, so the unconditional
    /// create that was refused can simply be sent again. A row deleted locally
    /// in the meantime has nothing to send and its metadata is settled as gone.
    func releaseTaglessSaveQuarantine(
        for quarantine: CloudKitTaglessSaveQuarantine,
        now: Date = Date()
    ) throws -> CloudKitTaglessSaveRepairOutcome {
        let outcome: CloudKitTaglessSaveRepairOutcome
        try exec("BEGIN IMMEDIATE")
        do {
            try clearSyncConflict(entity: quarantine.entity, logicalKey: quarantine.logicalKey)
            if try hasLocalSyncRecord(entity: quarantine.entity, logicalKey: quarantine.logicalKey) {
                try upsertSyncSave(
                    entity: quarantine.entity,
                    logicalKey: quarantine.logicalKey,
                    at: max(now, quarantine.localModificationDate),
                    preserveExistingScope: true
                )
                outcome = .requeuedSave
            } else {
                try markRecordDeleted(entity: quarantine.entity, logicalKey: quarantine.logicalKey, at: now)
                outcome = .tombstoned
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return outcome
    }
}
