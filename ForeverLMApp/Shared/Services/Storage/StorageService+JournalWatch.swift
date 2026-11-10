import Foundation

/// Off-main access to the journal tables. Plain pass-throughs: nothing here
/// syncs, so there is no urgency to schedule (docs/journals-design.md).
extension StorageService {

    func loadJournalFeeds() throws -> [JournalFeed] {
        try notebookFilesKnowledgeStore().loadJournalFeeds()
    }

    @discardableResult
    func addJournalFeed(feedURL: String, title: String, siteURL: String?) throws -> (feed: JournalFeed, inserted: Bool) {
        try notebookFilesKnowledgeStore().addJournalFeed(feedURL: feedURL, title: title, siteURL: siteURL)
    }

    func deleteJournalFeed(_ feedID: String) throws {
        try notebookFilesKnowledgeStore().deleteJournalFeed(feedID)
    }

    func recordJournalFeedCheck(
        feedID: String,
        at now: Date,
        succeeded: Bool,
        error: String?,
        etag: String?,
        lastModified: String?,
        title: String?
    ) throws {
        try notebookFilesKnowledgeStore().recordJournalFeedCheck(
            feedID: feedID,
            at: now,
            succeeded: succeeded,
            error: error,
            etag: etag,
            lastModified: lastModified,
            title: title
        )
    }

    @discardableResult
    func recordJournalFeedItems(feedID: String, items: [ParsedJournalItem], now: Date = Date()) throws -> [JournalFeedItem] {
        try notebookFilesKnowledgeStore().recordJournalFeedItems(feedID: feedID, items: items, now: now)
    }

    func loadUnjudgedJournalItems(limit: Int = 500) throws -> [JournalFeedItem] {
        try notebookFilesKnowledgeStore().loadUnjudgedJournalItems(limit: limit)
    }

    func markJournalItemsJudged(_ itemURLs: [String], at now: Date = Date()) throws {
        try notebookFilesKnowledgeStore().markJournalItemsJudged(itemURLs, at: now)
    }

    @discardableResult
    func pruneJournalItems(olderThan cutoff: Date) throws -> Int {
        try notebookFilesKnowledgeStore().pruneJournalItems(olderThan: cutoff)
    }

    @discardableResult
    func recordJournalMatches(_ verdicts: [JournalArticleVerdict], at now: Date = Date()) throws -> [JournalArticleMatch] {
        try notebookFilesKnowledgeStore().recordJournalMatches(verdicts, at: now)
    }

    func setJournalMatchState(
        itemURL: String,
        notebookID: String,
        state: JournalArticleMatchState,
        sourceID: String? = nil
    ) throws {
        try notebookFilesKnowledgeStore().setJournalMatchState(
            itemURL: itemURL,
            notebookID: notebookID,
            state: state,
            sourceID: sourceID
        )
    }

    func loadPendingJournalSuggestions(notebookID: String? = nil) throws -> [JournalArticleSuggestion] {
        try notebookFilesKnowledgeStore().loadPendingJournalSuggestions(notebookID: notebookID)
    }

    func pendingJournalSuggestionCounts() throws -> [String: Int] {
        try notebookFilesKnowledgeStore().pendingJournalSuggestionCounts()
    }

    func journalMatchedItemURLs(notebookID: String) throws -> Set<String> {
        try notebookFilesKnowledgeStore().journalMatchedItemURLs(notebookID: notebookID)
    }

    /// Whether an announced article is already a library source, by URL or DOI.
    func journalItemExistsInLibrary(url: String, doi: String?) throws -> Bool {
        try notebookFilesKnowledgeStore().journalItemExistsInLibrary(url: url, doi: doi)
    }
}
