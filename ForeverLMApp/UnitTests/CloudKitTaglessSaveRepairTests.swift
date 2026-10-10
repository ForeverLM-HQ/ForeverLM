import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The repair for saves CloudKit refused as an optimistic-lock miss without
/// sending its copy — the 63 records the container rebase stranded.
@Suite("CloudKit tagless save repair")
struct CloudKitTaglessSaveRepairTests {
    private func makeSource(_ url: String) -> StudioArticle {
        var article = StudioArticle(url: url, title: url)
        article.normalizedURL = URLNormalizer.normalize(url)
        return article
    }

    private func park(
        _ source: StudioArticle,
        in store: KnowledgeStore,
        errorCode: Int = CKError.Code.serverRecordChanged.rawValue,
        localModificationDate: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    ) throws -> String {
        let recordName = CloudKitRecordMapper.recordName(for: .source, logicalKey: source.id)
        try store.quarantineSyncConflict(CloudKitSyncConflict(
            entity: .source,
            logicalKey: source.id,
            recordName: recordName,
            reason: CloudKitRejectedSaveQuarantine.encodedReason(
                errorCode: errorCode,
                message: "Unknown oplock failed"
            ),
            localModificationDate: localModificationDate,
            serverModificationDate: localModificationDate,
            detectedAt: Date(),
            serverPayload: nil,
            serverSystemFields: nil
        ))
        return recordName
    }

    private func serverSystemFields(recordName: String) -> Data {
        let record = CKRecord(
            recordType: "Source",
            recordID: CKRecord.ID(recordName: recordName, zoneID: CloudKitRecordMapper.zoneID)
        )
        return CloudKitRecordMapper.encodeSystemFields(record)
    }

    @Test("Only oplock refusals whose metadata has no change tag are candidates")
    func loadsOnlyTaglessOplockRefusals() throws {
        let store = try KnowledgeStore(inMemory: true)
        let tagless = makeSource("https://example.com/tagless")
        let refusedForAnotherReason = makeSource("https://example.com/refused")
        let alreadyTagged = makeSource("https://example.com/tagged")
        for source in [tagless, refusedForAnotherReason, alreadyTagged] {
            try store.saveSource(source)
        }
        let taglessRecord = try park(tagless, in: store)
        _ = try park(refusedForAnotherReason, in: store, errorCode: CKError.Code.permissionFailure.rawValue)
        let taggedRecord = try park(alreadyTagged, in: store)
        try store.saveSyncMetadata(CloudKitSyncMetadata(
            entity: .source,
            logicalKey: alreadyTagged.id,
            recordName: taggedRecord,
            systemFieldsData: serverSystemFields(recordName: taggedRecord),
            userModificationDate: Date(),
            isDeleted: false
        ))

        let parked = try store.loadTaglessRejectedSaveQuarantines()
        #expect(parked.map(\.recordName) == [taglessRecord])
        #expect(parked.first?.entity == .source)
        #expect(parked.first?.logicalKey == tagless.id)
        #expect(parked.first?.localModificationDate == Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    @Test("Adopting the server's tag re-queues the save as a conditional write")
    func adoptingTagRequeuesSave() throws {
        let store = try KnowledgeStore(inMemory: true)
        let source = makeSource("https://example.com/adopt")
        try store.saveSource(source)
        let recordName = try park(source, in: store)
        // Quarantine took it out of the queue; that is the state the repair finds.
        #expect(try !store.hasPendingSyncChange(entity: .source, logicalKey: source.id))
        #expect(try store.hasSyncConflict(entity: .source, logicalKey: source.id))
        let quarantine = try #require(try store.loadTaglessRejectedSaveQuarantines().first)

        let systemFields = serverSystemFields(recordName: recordName)
        let outcome = try store.adoptServerChangeTag(for: quarantine, systemFields: systemFields)

        #expect(outcome == .requeuedSave)
        #expect(try !store.hasSyncConflict(entity: .source, logicalKey: source.id))
        let metadata = try #require(try store.loadSyncMetadata(entity: .source, logicalKey: source.id))
        #expect(metadata.systemFieldsData == systemFields)
        #expect(metadata.isDeleted == false)
        let pending = try #require(try store.pendingSyncChanges().first { $0.logicalKey == source.id })
        #expect(pending.operation == .save)
        #expect(pending.changedAt > quarantine.localModificationDate)
        #expect(try store.loadTaglessRejectedSaveQuarantines().isEmpty)
    }

    @Test("A row deleted while parked becomes a queued delete, not a resurrected save")
    func deletedRowBecomesTombstone() throws {
        let store = try KnowledgeStore(inMemory: true)
        let source = makeSource("https://example.com/deleted-while-parked")
        try store.saveSource(source)
        let recordName = try park(source, in: store)
        // Deleting a quarantined row enqueues no tombstone by design (the
        // conflict guard); this is the gap the repair closes.
        try store.deleteSource(source.id)
        #expect(try !store.pendingSyncChanges().contains { $0.logicalKey == source.id })
        let quarantine = try #require(try store.loadTaglessRejectedSaveQuarantines().first)

        let outcome = try store.adoptServerChangeTag(
            for: quarantine,
            systemFields: serverSystemFields(recordName: recordName)
        )

        #expect(outcome == .tombstoned)
        #expect(try !store.hasSyncConflict(entity: .source, logicalKey: source.id))
        let pending = try #require(try store.pendingSyncChanges().first { $0.logicalKey == source.id })
        #expect(pending.operation == .delete)
        #expect(try store.loadSyncMetadata(entity: .source, logicalKey: source.id)?.isDeleted == true)
    }

    @Test("A record the server does not hold is re-armed as the create it was")
    func missingServerRecordIsReleased() throws {
        let store = try KnowledgeStore(inMemory: true)
        let source = makeSource("https://example.com/unknown-item")
        try store.saveSource(source)
        _ = try park(source, in: store)
        let quarantine = try #require(try store.loadTaglessRejectedSaveQuarantines().first)

        let outcome = try store.releaseTaglessSaveQuarantine(for: quarantine)

        #expect(outcome == .requeuedSave)
        #expect(try !store.hasSyncConflict(entity: .source, logicalKey: source.id))
        let pending = try #require(try store.pendingSyncChanges().first { $0.logicalKey == source.id })
        #expect(pending.operation == .save)
        // Still no tag: the next send is the unconditional create the server
        // said it had no record for.
        #expect(try store.loadSyncMetadata(entity: .source, logicalKey: source.id)?.systemFieldsData == nil)
    }
}
