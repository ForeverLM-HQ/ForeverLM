// StorageService: opening the knowledge store, the paper figure index and reader highlights.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Knowledge Store (SQLite)

    /// Screen record mode's scope against this store's Notebooks (see
    /// `ScreenRecordScope`); nil when the mode is off, which it is for every
    /// learner but the admin. Readers that hold no view model — the Planner,
    /// the memory review — narrow what they show with it.
    func screenRecordScope() -> ScreenRecordScope? {
        guard ScreenRecordMode.isEffective else { return nil }
        return (try? knowledgeStore())?.screenRecordScope()
    }

    /// Runs one body of the schema-v2 private sync on the store, on this actor, so an apply's
    /// transaction never interleaves with another write (`MacPrivateSyncStore`, generation 2 only).
    func performSync(_ body: (KnowledgeStore) throws -> Void) throws {
        try body(try knowledgeStore())
    }

    /// One bounded step of the generation-2 activation on the store, on this actor, returning what it
    /// read (`StorageStoreAccess`).
    func performStoreWork<T: Sendable>(_ body: @Sendable (KnowledgeStore) throws -> T) throws -> T {
        try body(try knowledgeStore())
    }

    /// Lazily initialized SQLite-backed knowledge store.
    func knowledgeStore() throws -> KnowledgeStore {
        if let _knowledgeStore { return _knowledgeStore }
        try ensureStoreExists()
        let store = try KnowledgeStore(
            storeDirectory: storeRoot,
            contentDirectory: contentRoot,
            startupPreferenceSnapshot: overrideStoreRoot == nil
                ? UserDefaults.standard.dictionaryRepresentation()
                : [:]
        )
        if overrideStoreRoot == nil {
            store.automaticAudioSourceTypes = { SourceAudioAutomation.enabledSourceTypes() }
            // What another device changed reaches the models that hold the rows in memory.
            store.appliedRemoteChangesHandler = { AppliedRemoteChangesAnnouncer.announce($0) }
        }
        _knowledgeStore = store
        return store
    }

    /// Narrow internal bridge for the Notebook Files extension. The projection
    /// still shares this actor's one lazily opened store; callers outside
    /// StorageService never receive the handle.
    func notebookFilesKnowledgeStore() throws -> KnowledgeStore {
        try knowledgeStore()
    }

    /// The same narrow bridge for the learning-cohort extension, which needs both
    /// the store and this actor's in-memory vector index to assemble a cohort.
    func cohortKnowledgeStore() throws -> KnowledgeStore {
        try knowledgeStore()
    }

    enum CloudKitSyncUrgency {
        /// Bulk imports and content extraction: one send for the burst, not one per record.
        case coalesced
        /// Review exchange streams: push soon, but avoid sending after every prompt/answer pair.
        case soon
        /// Small user intent writes: collapse bursts, then push now so another Mac catches up quickly.
        case immediate
    }

    /// How long a bulk write waits before its send, so a burst shares one: the outbox watcher's old interval,
    /// so bulk work sends no more often than it did.
    private static let coalescedSendDelay: TimeInterval = 10

    /// A write announces itself: the outbox triggers recorded it already, and the Mac's generation-2 session
    /// sends it a few seconds later, past the outbox's debounce (`MacSyncSession.localWrite`). `OutboxWatcher`
    /// is the backstop for writes that announce nothing. No session (the First Run app, a unit-test host)
    /// sends nothing.
    func scheduleCloudKitSync(_ urgency: CloudKitSyncUrgency = .coalesced) {
        guard let session = MacSyncSession.current else { return }
        let delay = urgency == .coalesced ? Self.coalescedSendDelay : SyncCoordinator.sendSoonDelay
        Task { await session.localWrite(after: delay) }
    }

    /// `scheduleCloudKitSync` stays private so the urgency choice cannot leak
    /// out of this actor. These two named bridges let the scheduled-tasks
    /// extension pick between the same two urgencies without widening it.
    func scheduleImmediateCloudKitSyncForScheduledTasks() {
        scheduleCloudKitSync(.immediate)
    }

    /// The same bridge for the teams extension: a share, a task edit or an
    /// accepted invitation should reach the other members promptly.
    func scheduleImmediateCloudKitSyncForTeams() {
        keepTeamCopiesForGeneration2()
        scheduleCloudKitSync(.immediate)
    }

    func scheduleSoonCloudKitSyncForScheduledTasks() {
        scheduleCloudKitSync(.soon)
    }

    /// The planner's bridge: a redrawn day should be on the other Mac before
    /// the learner sits down at it.
    func scheduleImmediateCloudKitSyncForDayPlans() {
        scheduleCloudKitSync(.immediate)
    }

    /// A source's draft deck grew (`StorageService+CardDrafts`): the other
    /// Mac should see the cards to check soon, without a push per card.
    func scheduleSoonCloudKitSyncForCardDrafts() {
        scheduleCloudKitSync(.soon)
    }

    /// A mnemonic reading's answer kept or answered a card, or a source's
    /// questions were written (`StorageService+MnemonicReading`): the other
    /// devices should see it soon.
    func scheduleSoonCloudKitSyncForMnemonicReadings() {
        scheduleCloudKitSync(.soon)
    }

    /// "Sync now": a round of the generation-2 sync, which starts one that did not get going.
    func syncCloudKitNow() async {
        await MacSyncSession.current?.syncNow()
    }

    /// The SQLite half of `ICloudStorageUsage.measure(storage:)`, which does the
    /// file half off this actor.
    func iCloudSyncedSourceStorage() throws -> ICloudSyncedSourceStorage {
        try knowledgeStore().iCloudSyncedSourceStorage()
    }

    /// "Retry now": the same round; the coordinator's pacer owns every wait.
    func retryCloudKitNow() async {
        await MacSyncSession.current?.syncNow()
    }

    /// Pushes the outbox now and waits for it, for a durability boundary such as a finished import: rounds
    /// until it is empty or a round stops making progress. Returns how many local changes still wait, zero
    /// only when the outbox is empty. A Mac that does not sync (no session) has nothing to wait for.
    func syncCloudKitNowAndWaitForDrain(maxAttempts: Int = 4) async -> Int {
        await MacSyncSession.current?.pushAndWaitForOutbox(maxAttempts: maxAttempts) ?? 0
    }

    /// The local changes still waiting for iCloud; zero on a Mac that does not sync. Throws when the
    /// outbox cannot be read, rather than saying nothing waits.
    func pendingCloudKitChangeCount() async throws -> Int {
        try await MacSyncSession.current?.outboxBacklog() ?? 0
    }

    func drainZoomMeetingAdoptionBatch(limit: Int = 50) throws -> [String] {
        try ensureStoreExists()
        let adopted = try knowledgeStore().drainZoomMeetingAdoptionBatch(limit: limit)
        if !adopted.isEmpty { scheduleCloudKitSync(.immediate) }
        return adopted
    }

    /// Returns the sources whose text actually changed, so the caller can drop
    /// its in-memory copies and let them reload from canonical storage.
    func drainSourceTextReferenceRepairBatch(limit: Int = 50) throws -> [String] {
        try ensureStoreExists()
        let repaired = try knowledgeStore().drainSourceTextReferenceRepairBatch(limit: limit)
        if !repaired.isEmpty {
            scheduleCloudKitSync(.immediate)
        }
        return repaired
    }

    func sourceTextReferenceRepairQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceTextReferenceRepairQueueCount()
    }

    /// One batch of schema 166's soft hyphen repair. It asks no CloudKit sync of
    /// its own: at launch it runs before sync starts, which then sends what it
    /// changed, and once sync runs, the changes it records reach it like any other.
    func drainStoredSoftHyphenRepairBatch(limit: Int = 50) throws -> StoredSoftHyphenRepairBatch {
        try ensureStoreExists()
        return try knowledgeStore().drainStoredSoftHyphenRepairBatch(limit: limit)
    }

    /// One batch of the word count repair. The counts it wrote are returned so
    /// the caller can give its in-memory copies the same numbers.
    func drainSourceWordCountRepairBatch(after cursor: String?, limit: Int = 50) throws -> SourceWordCountRepairBatch {
        try ensureStoreExists()
        let batch = try knowledgeStore().drainSourceWordCountRepairBatch(after: cursor, limit: limit)
        if !batch.counts.isEmpty {
            scheduleCloudKitSync()
        }
        return batch
    }

    // MARK: - Paper Figure Index

    func nextPaperFigureIndexCandidate() throws -> PaperFigureIndexCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().nextPaperFigureIndexCandidate()
    }

    func paperFigureIndexCandidate(sourceID: String) throws -> PaperFigureIndexCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexCandidate(sourceID: sourceID)
    }

    func paperFigureIndexTarget(sourceID: String) throws -> PaperFigureIndexCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexTarget(sourceID: sourceID)
    }

    func ensurePaperFigureIndexQueuedForReview(sourceID: String, force: Bool) throws {
        try ensureStoreExists()
        try knowledgeStore().ensurePaperFigureIndexQueuedForReview(sourceID: sourceID, force: force)
    }

    func paperFigureIndexIsCurrent(sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexIsCurrent(sourceID: sourceID)
    }

    func otherSourceUsesLocalFile(_ storedPath: String, excludingSourceID sourceID: String) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().otherSourceUsesLocalFile(storedPath, excludingSourceID: sourceID)
    }

    func papersNeedingFigureIndex() throws -> [String] {
        try ensureStoreExists()
        return try knowledgeStore().papersNeedingFigureIndex()
    }

    func paperFigureIndexQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexQueueCount()
    }

    func recordPaperFigureIndexFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPaperFigureIndexFailure(sourceID: sourceID, message: message)
    }

    @discardableResult
    func updatePaperFigureAnalysis(
        sourceID: String,
        figureID: String,
        analysis: PaperFigureAnalysis
    ) throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().updatePaperFigureAnalysis(
            sourceID: sourceID,
            figureID: figureID,
            analysis: analysis
        )
    }

    func replacePaperFigureIndex(
        sourceID: String,
        pdfPath: String,
        pageCount: Int,
        figures: [PaperFigureRecord],
        indexVersion: Int
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().replacePaperFigureIndex(
            sourceID: sourceID,
            pdfPath: pdfPath,
            pageCount: pageCount,
            figures: figures,
            indexVersion: indexVersion
        )
    }

    /// Stable figure/page relationships for multimodal retrieval. Image paths
    /// remain portable and must be resolved off-main immediately before use.
    func paperFigureImageSweepIsPending() throws -> Bool {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureImageSweepIsPending()
    }

    func completePaperFigureImageSweep(removedDirectoryCount: Int) throws {
        try ensureStoreExists()
        try knowledgeStore().completePaperFigureImageSweep(
            removedDirectoryCount: removedDirectoryCount
        )
    }

    func recordPaperFigureImageSweepFailure(message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPaperFigureImageSweepFailure(message: message)
    }

    func paperFigureIndexedPDFPath(sourceID: String) throws -> String? {
        try ensureStoreExists()
        return try knowledgeStore().paperFigureIndexedPDFPath(sourceID: sourceID)
    }

    func paperFigures(sourceID: String) throws -> [PaperFigureRecord] {
        try ensureStoreExists()
        return try knowledgeStore().paperFigures(sourceID: sourceID)
    }

    // MARK: - Reader Highlights and Notes

    func sourceHighlights(sourceID: String) throws -> [SourceHighlight] {
        try ensureStoreExists()
        return try knowledgeStore().sourceHighlights(sourceID: sourceID)
    }

    func sourceHighlights(sourceIDs: [String]) throws -> [String: [SourceHighlight]] {
        try ensureStoreExists()
        return try knowledgeStore().sourceHighlights(sourceIDs: sourceIDs)
    }

    /// The marks the learner set aside to follow up or doubt, across the library.
    func openSourceHighlights() throws -> [FollowUpMark] {
        try ensureStoreExists()
        return try knowledgeStore().openSourceHighlights()
    }

    func saveSourceHighlight(_ highlight: SourceHighlight) throws {
        try ensureStoreExists()
        try knowledgeStore().saveSourceHighlight(highlight)
    }

    @discardableResult
    func linkSourceHighlight(id: String, toChat sessionID: String?) throws -> SourceHighlight? {
        try ensureStoreExists()
        return try knowledgeStore().linkSourceHighlight(id: id, toChat: sessionID)
    }

    func deleteSourceHighlight(id: String) throws {
        try ensureStoreExists()
        try knowledgeStore().deleteSourceHighlight(id: id)
    }

    func insertImportedSourceHighlights(_ highlights: [SourceHighlight]) throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().insertImportedSourceHighlights(highlights)
    }

}
