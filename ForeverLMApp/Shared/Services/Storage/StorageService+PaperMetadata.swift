// StorageService: paper reference lists, registered paper titles and YouTube transcript checks.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Paper reference lists (schema 174)
    //
    // Local-only (nothing here syncs or marks a record changed): a list is derived from the
    // paper's own PDF, so the Mac that holds the PDF makes it.

    func paperReferenceReadCandidates(limit: Int) throws -> [PaperReferenceReadCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().paperReferenceReadCandidates(limit: limit)
    }

    @discardableResult
    func requeueOlderPaperReferenceReads() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().requeueOlderPaperReferenceReads()
    }

    func paperReferenceReadQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().paperReferenceReadQueueCount()
    }

    func paperReferenceReadState(sourceID: String) throws -> PaperReferenceReadState? {
        try ensureStoreExists()
        return try knowledgeStore().paperReferenceReadState(sourceID: sourceID)
    }

    func loadPaperReferences(sourceID: String) throws -> [PaperReference] {
        try ensureStoreExists()
        return try knowledgeStore().loadPaperReferences(sourceID: sourceID)
    }

    /// A paper's stored list as the snapshot the citation popover reads a link through.
    func paperReferenceIndex(sourceID: String) throws -> PaperReferenceIndex {
        PaperReferenceIndex(sourceID: sourceID, references: try loadPaperReferences(sourceID: sourceID))
    }

    func replacePaperReferenceList(sourceID: String, entries: [PaperReference]) throws {
        try ensureStoreExists()
        try knowledgeStore().replacePaperReferenceList(sourceID: sourceID, entries: entries)
    }

    func savePaperReference(_ reference: PaperReference) throws {
        try ensureStoreExists()
        try knowledgeStore().savePaperReference(reference)
    }

    func savePaperReferencesAuthoredByAgent(
        sourceID: String,
        references: [PaperReference],
        replacing: Bool
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().savePaperReferencesAuthoredByAgent(
            sourceID: sourceID, references: references, replacing: replacing
        )
    }

    func finishPaperReferenceRead(sourceID: String, pdfPath: String?, failure: String?, authoredBy: String) throws {
        try ensureStoreExists()
        try knowledgeStore().finishPaperReferenceRead(
            sourceID: sourceID, pdfPath: pdfPath, failure: failure, authoredBy: authoredBy
        )
    }

    func dropPaperReferences(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().dropPaperReferences(sourceID: sourceID)
    }

    // MARK: - Registered paper titles (schema 144)

    func registeredPaperTitleCandidates(limit: Int) throws -> [RegisteredPaperTitleCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().registeredPaperTitleCandidates(limit: limit)
    }

    func registeredPaperTitleQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().registeredPaperTitleQueueCount()
    }

    func dropRegisteredPaperTitleChecksWithoutPapers() throws {
        try ensureStoreExists()
        try knowledgeStore().dropRegisteredPaperTitleChecksWithoutPapers()
    }

    func completeRegisteredPaperTitleCheck(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().completeRegisteredPaperTitleCheck(sourceID: sourceID)
    }

    func recordRegisteredPaperTitleCheckFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordRegisteredPaperTitleCheckFailure(sourceID: sourceID, message: message)
    }

    @discardableResult
    func restoreRegisteredPaperTitle(
        sourceID: String,
        checkedTitle: String,
        registeredTitle: String
    ) throws -> Bool {
        try ensureStoreExists()
        let changed = try knowledgeStore().restoreRegisteredPaperTitle(
            sourceID: sourceID,
            checkedTitle: checkedTitle,
            registeredTitle: registeredTitle
        )
        if changed { scheduleCloudKitSync(.coalesced) }
        return changed
    }

    // MARK: - YouTube transcript checks (schema 148)

    func youTubeTranscriptCheckCandidates(limit: Int) throws -> [YouTubeTranscriptCheckCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().youTubeTranscriptCheckCandidates(limit: limit)
    }

    func youTubeTranscriptCheckQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().youTubeTranscriptCheckQueueCount()
    }

    func dropYouTubeTranscriptChecksWithoutVideos() throws {
        try ensureStoreExists()
        try knowledgeStore().dropYouTubeTranscriptChecksWithoutVideos()
    }

    func completeYouTubeTranscriptCheck(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().completeYouTubeTranscriptCheck(sourceID: sourceID)
    }

    func recordYouTubeTranscriptCheckFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordYouTubeTranscriptCheckFailure(sourceID: sourceID, message: message)
    }

    func memoryAnchorExcerpts(sourceID: String) throws -> [String] {
        try ensureStoreExists()
        return try knowledgeStore().memoryAnchorExcerpts(sourceID: sourceID)
    }

    @discardableResult
    func replaceCheckedYouTubeTranscript(
        sourceID: String,
        checkedContent: String,
        content: String
    ) throws -> Bool {
        try ensureStoreExists()
        let changed = try knowledgeStore().replaceCheckedYouTubeTranscript(
            sourceID: sourceID,
            checkedContent: checkedContent,
            content: content
        )
        if changed { scheduleCloudKitSync(.coalesced) }
        return changed
    }

    func podcastTranscriptDetruncationCandidates(
        fetchingTTML: Bool,
        limit: Int
    ) throws -> [PodcastTranscriptDetruncationCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptDetruncationCandidates(
            fetchingTTML: fetchingTTML,
            limit: limit
        )
    }

    func podcastTranscriptDetruncationQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptDetruncationQueueCount()
    }

    func podcastTranscriptAuditInputs(sourceID: String) throws -> PodcastTranscriptAuditInputs? {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptAuditInputs(sourceID: sourceID)
    }

    /// See `KnowledgeStore.restorePodcastTranscript`. A replaced transcript is
    /// sent to the other devices and starts the derived work that follows a
    /// new transcript (the ad pass, the indexes).
    @discardableResult
    func restorePodcastTranscript(
        sourceID: String,
        auditedTranscript: String,
        restoredTranscript: String,
        fetchedTTML: String?,
        ttmlSHA256: String
    ) throws -> Bool {
        try ensureStoreExists()
        let restored = try knowledgeStore().restorePodcastTranscript(
            sourceID: sourceID,
            auditedTranscript: auditedTranscript,
            restoredTranscript: restoredTranscript,
            fetchedTTML: fetchedTTML,
            ttmlSHA256: ttmlSHA256
        )
        if restored {
            scheduleCloudKitSync()
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        }
        return restored
    }

    func removePodcastTranscriptFromDetruncationQueue(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().removePodcastTranscriptFromDetruncationQueue(sourceID: sourceID)
    }

    func recordPodcastTranscriptAudit(
        sourceID: String,
        ttmlSHA256: String?,
        outcome: PodcastTranscriptAuditOutcome
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPodcastTranscriptAudit(
            sourceID: sourceID,
            ttmlSHA256: ttmlSHA256,
            outcome: outcome
        )
    }

    func recordPodcastTranscriptDetruncationFailure(
        sourceID: String,
        message: String,
        retryAfter: Date?
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPodcastTranscriptDetruncationFailure(
            sourceID: sourceID,
            message: message,
            retryAfter: retryAfter
        )
    }

    func nextCanonicalContentCleanupCandidate() throws -> CanonicalContentCleanupCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().nextCanonicalContentCleanupCandidate()
    }

    func canonicalContentCleanupCandidates(
        limit: Int,
        pendingIngestionOnly: Bool = false,
        now: Date = Date()
    ) throws -> [CanonicalContentCleanupCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().canonicalContentCleanupCandidates(
            limit: limit,
            pendingIngestionOnly: pendingIngestionOnly,
            now: now
        )
    }

    func canonicalContentCleanupQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().canonicalContentCleanupQueueCount()
    }

    func nextCanonicalContentCleanupRetryDate() throws -> Date? {
        try ensureStoreExists()
        return try knowledgeStore().nextCanonicalContentCleanupRetryDate()
    }

    func pruneIneligibleCanonicalContentCleanupQueue() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().pruneIneligibleCanonicalContentCleanupQueue()
    }

    @discardableResult
    func recordCanonicalContentCleanupFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String? = nil,
        consumesAttempt: Bool = true
    ) throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().recordCanonicalContentCleanupFailure(
            sourceID: sourceID,
            message: message,
            sourceSHA256: sourceSHA256,
            consumesAttempt: consumesAttempt
        )
    }

    func failPendingCanonicalContentCleanup(
        candidate: CanonicalContentCleanupCandidate,
        message: String
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().failPendingCanonicalContentCleanup(
            candidate: candidate,
            message: message
        )
        scheduleCloudKitSync(.coalesced)
    }

    func clearCompletedCanonicalContentCleanupFailure(sourceID: String) throws -> Bool {
        try ensureStoreExists()
        let changed = try knowledgeStore().clearCompletedCanonicalContentCleanupFailure(
            sourceID: sourceID
        )
        if changed { scheduleCloudKitSync(.coalesced) }
        return changed
    }

    /// See `KnowledgeStore.auditCanonicalContentIntegrity`.
    func auditCanonicalContentIntegrity(
        limit: Int
    ) throws -> (audited: Int, requeuedSourceIDs: [String], remaining: Int) {
        try ensureStoreExists()
        let result = try knowledgeStore().auditCanonicalContentIntegrity(limit: limit)
        if !result.requeuedSourceIDs.isEmpty { scheduleCloudKitSync(.coalesced) }
        return result
    }

    func applyCanonicalContentCleanup(
        candidate: CanonicalContentCleanupCandidate,
        prepared: PreparedPaperContent
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)
        removeFromSearchIndexes(candidate.sourceID)
        scheduleCloudKitSync(.coalesced)
    }

    /// The Dev build's substitute for `applyCanonicalContentCleanup`: the raw
    /// text is published as-is and no model is called. See
    /// `PaidSourceCleanupPolicy`.
    func publishCanonicalContentWithoutCleanup(
        candidate: CanonicalContentCleanupCandidate
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().publishCanonicalContentWithoutCleanup(candidate: candidate)
        removeFromSearchIndexes(candidate.sourceID)
        scheduleCloudKitSync(.coalesced)
    }

    func podcastTranscriptCleanupCandidates(
        limit: Int,
        formattingOnly: Bool = false
    ) throws -> [PodcastTranscriptCleanupCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptCleanupCandidates(
            limit: limit,
            formattingOnly: formattingOnly
        )
    }

    func podcastTranscriptCleanupQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().podcastTranscriptCleanupQueueCount()
    }

    func recordPodcastTranscriptCleanupFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String,
        consumesAttempt: Bool
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordPodcastTranscriptCleanupFailure(
            sourceID: sourceID,
            message: message,
            sourceSHA256: sourceSHA256,
            consumesAttempt: consumesAttempt
        )
    }

    func applyPodcastTranscriptCleanup(
        candidate: PodcastTranscriptCleanupCandidate,
        prepared: PreparedPodcastTranscriptCleanup
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().applyPodcastTranscriptCleanup(candidate: candidate, prepared: prepared)
        removeFromSearchIndexes(candidate.sourceID)
        scheduleCloudKitSync(.coalesced)
    }

    func restorePodcastTranscriptCleanups(limit: Int) throws -> [String] {
        try ensureStoreExists()
        let sourceIDs = try knowledgeStore().restorePodcastTranscriptCleanups(limit: limit)
        for sourceID in sourceIDs { removeFromSearchIndexes(sourceID) }
        if !sourceIDs.isEmpty { scheduleCloudKitSync(.coalesced) }
        return sourceIDs
    }

}
