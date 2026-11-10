// StorageService: background AI spend control.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Background AI spend control (schema 135)

    /// Dollars background AI tasks spent in `[start, end)`, own-key calls
    /// included (`BackgroundAIBudget`).
    func backgroundAISpendUSD(from start: Date, to end: Date) throws -> Double {
        try ensureStoreExists()
        return try knowledgeStore().backgroundAISpendUSD(from: start, to: end)
    }

    /// Bulk re-queues waiting for the learner, with counts and estimates.
    func pendingBackgroundAIBulkJobs() throws -> [BackgroundAIBulkJob] {
        try ensureStoreExists()
        return try knowledgeStore().pendingBackgroundAIBulkJobs()
    }

    /// Applies the learner's choice and starts the drains on what it released.
    func decideBackgroundAIBulkJob(
        id: String,
        decision: BackgroundAIBulkDecision
    ) throws -> KnowledgeStore.BackgroundAIBulkDecisionOutcome {
        try ensureStoreExists()
        let outcome = try knowledgeStore().decideBackgroundAIBulkJob(id: id, decision: decision)
        NotificationCenter.default.post(name: .backgroundAIBulkJobsDidChange, object: nil)
        if outcome.releasedCount > 0 {
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        }
        return outcome
    }

    /// Released bulk re-queues the drains are still working through.
    func runningBackgroundAIBulkJobs() throws -> [KnowledgeStore.RunningBackgroundAIBulkJob] {
        try ensureStoreExists()
        return try knowledgeStore().runningBackgroundAIBulkJobs()
    }

    /// Stops a released run; what is left waits for the learner again.
    func stopBackgroundAIBulkJob(id: String) throws -> KnowledgeStore.BackgroundAIBulkStopOutcome {
        try ensureStoreExists()
        let outcome = try knowledgeStore().stopBackgroundAIBulkJob(id: id)
        NotificationCenter.default.post(name: .backgroundAIBulkJobsDidChange, object: nil)
        return outcome
    }

    func nextSourceListenableContentCandidate() throws -> SourceListenableContentCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().nextSourceListenableContentCandidate()
    }

    /// Queues one source's Listen preparation for automatic audio that found
    /// none ready, and wakes the drain.
    func queueSourceListenableContentPreparation(sourceID: String) throws {
        try ensureStoreExists()
        if try knowledgeStore().queueSourceListenableContentPreparation(sourceID: sourceID) {
            NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
        }
    }

    func sourceListenableContentCandidates(limit: Int) throws -> [SourceListenableContentCandidate] {
        try ensureStoreExists()
        return try knowledgeStore().sourceListenableContentCandidates(limit: limit)
    }

    func sourceListenableContentQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceListenableContentQueueCount()
    }

    func recordSourceListenableContentFailure(
        sourceID: String,
        message: String,
        sourceSHA256: String
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().recordSourceListenableContentFailure(
            sourceID: sourceID,
            message: message,
            sourceSHA256: sourceSHA256
        )
    }

    func applySourceListenableContent(
        candidate: SourceListenableContentCandidate,
        text: String,
        preparationSignature: String?
    ) throws {
        try ensureStoreExists()
        try knowledgeStore().applySourceListenableContent(
            candidate: candidate,
            text: text,
            preparationSignature: preparationSignature
        )
        scheduleCloudKitSync(.coalesced)
    }

    func loadSourceListenableContent(_ sourceID: String) throws -> StoredSourceListenableContent? {
        try ensureStoreExists()
        return try knowledgeStore().loadSourceListenableContent(sourceID)
    }

    func sourceListenableContentSummaries(
        for sourceIDs: [String]
    ) -> [String: SourceListenableContentSummary] {
        guard let ks = try? knowledgeStore() else { return [:] }
        return (try? ks.sourceListenableContentSummaries(for: sourceIDs)) ?? [:]
    }

    func sourceReviewGuideCandidate(sourceID: String) throws -> SourceReviewGuideCandidate? {
        try ensureStoreExists()
        return try knowledgeStore().sourceReviewGuideCandidate(sourceID: sourceID)
    }

    func ensureSourceReviewGuidePreparationQueued(sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().ensureSourceReviewGuidePreparation(sourceID: sourceID)
    }

    func sourceReviewGuideQueueCount() throws -> Int {
        try ensureStoreExists()
        return try knowledgeStore().sourceReviewGuideQueueCount()
    }

    func recordSourceReviewGuideFailure(sourceID: String, message: String) throws {
        try ensureStoreExists()
        try knowledgeStore().recordSourceReviewGuideFailure(sourceID: sourceID, message: message)
    }

    func applySourceReviewGuide(candidate: SourceReviewGuideCandidate, guide: String) throws {
        try ensureStoreExists()
        try knowledgeStore().applySourceReviewGuide(candidate: candidate, guide: guide)
        scheduleCloudKitSync(.coalesced)
    }

    func loadSourceReviewGuide(_ sourceID: String) throws -> SourceReviewGuide? {
        try ensureStoreExists()
        return try knowledgeStore().loadSourceReviewGuide(sourceID)
    }

}
