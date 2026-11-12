// StorageService: targeted source persistence and the memory tutor entry points.
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StorageService {

    // MARK: - Targeted Source Persistence

    /// Insert a source if it doesn't already exist (by normalized URL). Returns true if inserted.
    @discardableResult
    func sourceExistsByURL(_ url: String) throws -> (id: String, status: SourceStatus)? {
        try ensureStoreExists()
        return try knowledgeStore().sourceExistsByURL(url)
    }

    func insertSourceIfNew(_ article: inout StudioArticle, alsoAt: [String] = []) throws -> Bool {
        let inserted = try knowledgeStore().insertSourceIfNew(&article, alsoAt: alsoAt)
        // An import that found its source may still have taught it an address.
        if inserted || !alsoAt.isEmpty {
            scheduleCloudKitSync(.immediate)
        }
        return inserted
    }

    /// Whether a source of the learner's own library is saved at `address` or
    /// holds it as a work key.
    func holdsSource(atAddress address: String) throws -> Bool {
        try knowledgeStore().sourceID(
            forWorkKeys: SourceWorkKeys.keys(url: address, normalizedURL: nil), teamID: nil
        ) != nil
    }

    func substackAppLinkSourcesWithoutPostAddress() throws -> [(id: String, url: String)] {
        try knowledgeStore().substackAppLinkSourcesWithoutPostAddress()
    }

    /// Records the other address each saved source is at, in one sync.
    func addAddresses(_ addresses: [(sourceID: String, address: String)]) throws {
        guard !addresses.isEmpty else { return }
        let store = try knowledgeStore()
        for entry in addresses {
            try store.addAddress(entry.address, toSource: entry.sourceID)
        }
        scheduleCloudKitSync(.immediate)
    }

    func newSourceCandidates(from articles: [StudioArticle]) throws -> [StudioArticle] {
        try knowledgeStore().newSourceCandidates(from: articles)
    }

    /// Load all active (non-archived) sources.
    /// One library at a time: nil is My Library, a team id is that team's.
    func loadActiveSources(teamID: String? = nil) throws -> [StudioArticle] {
        try knowledgeStore().loadActiveSources(teamID: teamID)
    }

    /// What the Studio lists, whichever library is open: the learner's own
    /// sources and every team's (`KnowledgeStore.loadLibrarySources`).
    func loadLibrarySources() throws -> LibrarySourceList {
        try knowledgeStore().loadLibrarySources()
    }

    /// Returns the latest review date for each source, including completed Schedule items.
    func sourceReviewDates() throws -> [String: Date] {
        try knowledgeStore().sourceReviewDates()
    }

    /// Per-source retention stats for the daily memory-training surface. Optionally
    /// restricted to a set of source IDs (one Notebook's sources) for a per-notebook refresh.
    func memoryReviewStats(restrictToSourceIDs: Set<String>? = nil) throws -> [MemoryReviewStat] {
        try knowledgeStore().memoryReviewStats(restrictToSourceIDs: restrictToSourceIDs)
    }

    /// Consumed-but-never-reviewed sources — the never-reviewed half of the daily
    /// memory-training surface. Same optional per-Notebook restriction.
    func unreviewedConsumedSources(restrictToSourceIDs: Set<String>? = nil) throws -> [MemoryReviewNewCandidate] {
        try knowledgeStore().unreviewedConsumedSources(restrictToSourceIDs: restrictToSourceIDs)
    }

    /// Keeps source-history intake, candidate fetches, exclusion joins, and
    /// scheduling sorts on the storage actor. Both intake buckets — previously
    /// reviewed sources that are due again, and consumed-never-reviewed sources —
    /// are gathered in full and bounded together by
    /// `MemoryReviewScheduler.firstReviewIntake`, so a large backlog of earlier source reviews can
    /// no longer spend the whole daily plan before recently consumed material is
    /// even considered.
    func firstReviewMemoryItems(
        now: Date,
        limit: Int,
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> [MemoryReviewNewItem] {
        let boundedLimit = Swift.max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let store = try knowledgeStore()
        let representedSourceIDs = try store.activeMemoryItemSourceIDs(
            restrictToSourceIDs: restrictToSourceIDs
        )
        let sourceStats = try store.memoryReviewStats(
            restrictToSourceIDs: restrictToSourceIDs
        ).filter { !representedSourceIDs.contains($0.sourceID) }
        let newCandidates = try store.unreviewedConsumedSources(
            restrictToSourceIDs: restrictToSourceIDs
        ).filter { !representedSourceIDs.contains($0.sourceID) }
        return MemoryReviewScheduler.firstReviewIntake(
            sourceStats: sourceStats,
            freshCandidates: newCandidates,
            now: now,
            limit: boundedLimit
        )
    }

    func recentReviewSourceActivity(
        now: Date = Date(),
        sessionLimit: Int = 12,
        maximumAgeDays: Int = 14
    ) throws -> [MemoryTutorRecentSourceActivity] {
        try knowledgeStore().recentReviewSourceActivity(
            now: now,
            sessionLimit: sessionLimit,
            maximumAgeDays: maximumAgeDays
        )
    }

}
