// StorageService: meeting session merges, source ordering and positions, and source saves.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - One sitting, one session

    /// Fold the named sessions of one series into the one that started first
    /// (`KnowledgeStore.mergeMeetingSessions`), then take the absorbed rows out
    /// of the search indexes and queue the sync, the way a removed session
    /// leaves. The survivor's new text is re-embedded by the derived-work drain.
    func mergeMeetingSessions(_ ids: [String]) throws -> MeetingSessionMergeOutcome? {
        try ensureStoreExists()
        guard let outcome = try knowledgeStore().mergeMeetingSessions(ids) else { return nil }
        finishMeetingSessionMerge(outcome)
        return outcome
    }

    /// The explicit rule: every day of the series that holds more than one
    /// finished session becomes one session, or only `date` (`YYYY-MM-DD`)
    /// does. Idempotent — a series already at one session a day does nothing.
    func mergeSameDayMeetingSessions(groupID: String, date: String? = nil) throws -> [MeetingSessionMergeOutcome] {
        try ensureStoreExists()
        let store = try knowledgeStore()
        let canonical = try store.canonicalMeetingGroupID(groupID)
        var outcomes: [MeetingSessionMergeOutcome] = []
        for run in try store.sameDayMeetingSessionRuns(groupID: canonical, date: date) {
            guard let outcome = try store.mergeMeetingSessions(run) else { continue }
            finishMeetingSessionMerge(outcome)
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// The automatic rule, run when a session's transcript has landed
    /// (`MeetingActionItemExtractor.noteTranscriptReady`, the one funnel every
    /// ingest route ends in): when another ready session of the series began
    /// on the same day within `MeetingSessionContinuation.window`, the two —
    /// or more — become one. Nil when the session stands alone.
    func absorbMeetingSessionContinuation(sourceID: String) throws -> MeetingSessionMergeOutcome? {
        try ensureStoreExists()
        let store = try knowledgeStore()
        guard let run = try store.meetingSessionContinuationRun(for: sourceID),
              let outcome = try store.mergeMeetingSessions(run) else { return nil }
        finishMeetingSessionMerge(outcome)
        return outcome
    }

    private func finishMeetingSessionMerge(_ outcome: MeetingSessionMergeOutcome) {
        for id in outcome.absorbedIDs {
            removeFromSearchIndexes(id)
        }
        scheduleCloudKitSync(.immediate)
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    @discardableResult
    func updateCourseSortIndex(_ sourceId: String, _ sortIndex: Int) throws -> Bool {
        let changed = try knowledgeStore().updateCourseSortIndex(sourceId, sortIndex)
        if changed { scheduleCloudKitSync() }
        return changed
    }

    @discardableResult
    func updateVideoFeedDates(_ sourceId: String, likedAt: Date?, videoPublishedAt: Date?) throws -> Bool {
        let changed = try knowledgeStore().updateVideoFeedDates(
            sourceID: sourceId,
            likedAt: likedAt,
            videoPublishedAt: videoPublishedAt
        )
        if changed { scheduleCloudKitSync() }
        return changed
    }

    /// Update course_sort_index for multiple sources in a single transaction.
    func updateCourseSortOrder(_ ordering: [(String, Int)]) throws {
        try knowledgeStore().updateCourseSortOrder(ordering)
        scheduleCloudKitSync(.immediate)
    }

    func updateBookSortOrder(_ ordering: [(String, Int)]) throws {
        try knowledgeStore().updateBookSortOrder(ordering)
        scheduleCloudKitSync(.immediate)
    }

    func updateSourceReadingPosition(sourceID: String, page: Int?) throws {
        try ensureStoreExists()
        try knowledgeStore().updateSourceReadingPosition(sourceID: sourceID, page: page)
        scheduleCloudKitSync(.coalesced)
    }

    func updateSourceReadingLocator(sourceID: String, locator: String?) throws {
        try ensureStoreExists()
        try knowledgeStore().updateSourceReadingLocator(sourceID: sourceID, locator: locator)
        scheduleCloudKitSync(.coalesced)
    }

    func updateSourceReadAt(sourceID: String, readAt: Date?) throws {
        try ensureStoreExists()
        try knowledgeStore().updateSourceReadAt(sourceID: sourceID, readAt: readAt)
        scheduleCloudKitSync(.coalesced)
    }

    /// The narration's resume point in the source's ReadingState (generation 2; nil, and no write,
    /// under generation 1, where it rides `listen.position.*`).
    func loadListenPosition(sourceID: String) throws -> ArticleSpeechPlaybackPosition? {
        try ensureStoreExists()
        return try knowledgeStore().loadListenPosition(sourceID: sourceID)
    }

    func saveListenPosition(_ position: ArticleSpeechPlaybackPosition?, sourceID: String) throws {
        try ensureStoreExists()
        try knowledgeStore().saveListenPosition(position, sourceID: sourceID)
    }

    /// Mark as Watched / Mark as Not Watched; see `KnowledgeStore.setVideoWatched`.
    @discardableResult
    func setVideoWatched(sourceID: String, watched: Bool) throws -> VideoWatchedMark {
        try ensureStoreExists()
        let mark = try knowledgeStore().setVideoWatched(sourceID: sourceID, watched: watched)
        if mark.changed { scheduleCloudKitSync(.coalesced) }
        return mark
    }

    /// Persist a single source (full upsert). Use for write-through after
    /// mutating an article's fields in the view model.
    func saveSource(_ article: StudioArticle, syncImmediately: Bool = false) throws {
        try ensureStoreExists()
        try knowledgeStore().saveSource(article)
        if (article.sourceType == .paper
                && (article.paperContentPreparationForPersistence != nil
                    || (article.state != .ready && article.content != nil)))
            || article.articleContentPreparationForPersistence != nil {
            removeFromSearchIndexes(article.id)
        }
        refreshTeamCopiesAwaitingText(of: [article])
        scheduleCloudKitSync(syncImmediately ? .immediate : .coalesced)
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    /// Persist a source whose text was just replaced at its root, clearing the
    /// old text and everything derived from it in the same transaction
    /// (`KnowledgeStore.saveSourceReplacingDerivedData`).
    func saveSourceReplacingDerivedData(_ article: StudioArticle, syncImmediately: Bool = false) throws {
        try ensureStoreExists()
        try knowledgeStore().saveSourceReplacingDerivedData(article)
        removeFromSearchIndexes(article.id)
        refreshTeamCopiesAwaitingText(of: [article])
        scheduleCloudKitSync(syncImmediately ? .immediate : .coalesced)
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

    /// Merge deterministic paper metadata into the freshest persisted source.
    ///
    /// This stays on the storage actor so a slow metadata lookup cannot save the
    /// whole `StudioArticle` snapshot it captured before a concurrent PDF
    /// attachment. Only compare-and-swap metadata fields are eligible to change.
    func mergePaperMetadataBackfill(_ patch: PaperMetadataBackfillPatch) throws -> StudioArticle? {
        try ensureStoreExists()
        let store = try knowledgeStore()
        guard var current = try store.loadSourceForSync(patch.sourceID),
              patch.apply(to: &current) else {
            return nil
        }
        try store.saveSource(current)
        scheduleCloudKitSync(.coalesced)
        return current
    }

    /// Persist multiple sources individually. Useful after batch mutations.
    func saveSourcesBatchOnly(_ articles: [StudioArticle]) throws {
        try ensureStoreExists()
        let ks = try knowledgeStore()
        for article in articles {
            try ks.saveSource(article)
        }
        refreshTeamCopiesAwaitingText(of: articles)
        scheduleCloudKitSync()
        NotificationCenter.default.post(name: .derivedSourceWorkNeeded, object: nil)
    }

}
