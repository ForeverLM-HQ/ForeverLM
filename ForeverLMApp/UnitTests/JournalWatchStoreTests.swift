import Foundation
import Testing
@testable import ForeverLM

/// The journal tables: following is idempotent, an article is one row however
/// many feeds carry it, verdicts become pending suggestions once, a dismissal
/// is a tombstone, and unfollowing forgets everything but the library.
@Suite("Journal watch store")
struct JournalWatchStoreTests {

    private func makeStore() throws -> KnowledgeStore {
        try KnowledgeStore(inMemory: true)
    }

    private static func item(_ url: String, title: String, doi: String? = nil, published: Date? = nil) -> ParsedJournalItem {
        ParsedJournalItem(url: url, title: title, summary: "Summary of \(title)", authors: ["A. Author"], doi: doi, journal: "Nature", publishedAt: published)
    }

    private static func article(id: String, url: String, title: String, type: StudioSourceType = .article, doi: String? = nil) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: type, discoveryOrigin: .manual, id: id)
        article.domain = URL(string: url)?.host ?? ""
        article.doi = doi
        return article
    }

    @Test("Following twice returns the same feed; unfollowing forgets its pending suggestions but keeps its decided verdicts")
    func followAndUnfollow() throws {
        let store = try makeStore()
        let first = try store.addJournalFeed(feedURL: "https://www.nature.com/nrm.rss", title: "Nature Reviews MCB", siteURL: "https://www.nature.com/nrm")
        #expect(first.inserted)
        let again = try store.addJournalFeed(feedURL: "https://www.nature.com/nrm.rss", title: "Renamed", siteURL: nil)
        #expect(!again.inserted)
        #expect(again.feed.id == first.feed.id)
        #expect(again.feed.title == "Nature Reviews MCB")
        #expect(try store.loadJournalFeeds().map(\.id) == [first.feed.id])
        #expect(throws: (any Error).self) {
            _ = try store.addJournalFeed(feedURL: "   ", title: "Blank", siteURL: nil)
        }

        try store.recordJournalFeedItems(feedID: first.feed.id, items: [
            Self.item("https://www.nature.com/articles/x1", title: "X1"),
            Self.item("https://www.nature.com/articles/x2", title: "X2"),
        ])
        _ = try store.recordJournalMatches([
            JournalArticleVerdict(itemID: "https://www.nature.com/articles/x1", notebookID: "p1", reason: "fits"),
            JournalArticleVerdict(itemID: "https://www.nature.com/articles/x2", notebookID: "p1", reason: "fits"),
        ])
        try store.markJournalItemsJudged(["https://www.nature.com/articles/x1", "https://www.nature.com/articles/x2"])
        try store.setJournalMatchState(itemURL: "https://www.nature.com/articles/x2", notebookID: "p1", state: .dismissed)
        #expect(try store.loadPendingJournalSuggestions().count == 1)

        try store.deleteJournalFeed(first.feed.id)
        #expect(try store.loadJournalFeeds().isEmpty)
        #expect(try store.loadUnjudgedJournalItems().isEmpty)
        #expect(try store.loadPendingJournalSuggestions().isEmpty)

        // The dismissal outlives the feed: the same article from another feed
        // is neither judged again nor offered again to that Notebook.
        let other = try store.addJournalFeed(feedURL: "https://www.nature.com/subjects/cell-biology.rss", title: "Cell biology", siteURL: nil).feed
        try store.recordJournalFeedItems(feedID: other.id, items: [Self.item("https://www.nature.com/articles/x2", title: "X2")])
        #expect(try store.loadUnjudgedJournalItems().isEmpty)
        _ = try store.recordJournalMatches([JournalArticleVerdict(itemID: "https://www.nature.com/articles/x2", notebookID: "p1", reason: "fits")])
        #expect(try store.loadPendingJournalSuggestions().isEmpty)
    }

    @Test("Articles are recorded once by URL, across fetches and across feeds")
    func itemsAreIdempotent() throws {
        let store = try makeStore()
        let nature = try store.addJournalFeed(feedURL: "https://www.nature.com/nature.rss", title: "Nature", siteURL: nil).feed
        let subject = try store.addJournalFeed(feedURL: "https://www.nature.com/subjects/cell-biology.rss", title: "Cell biology", siteURL: nil).feed
        let items = [
            Self.item("https://www.nature.com/articles/a1", title: "A1", doi: "10.1038/a1"),
            Self.item("https://www.nature.com/articles/a2", title: "A2"),
        ]
        let inserted = try store.recordJournalFeedItems(feedID: nature.id, items: items)
        #expect(inserted.map(\.itemURL) == ["https://www.nature.com/articles/a1", "https://www.nature.com/articles/a2"])
        #expect(inserted[0].doi == "10.1038/a1")
        #expect(inserted[0].authors == "A. Author")

        #expect(try store.recordJournalFeedItems(feedID: nature.id, items: items).isEmpty, "a re-fetch adds nothing")
        let fromSubject = try store.recordJournalFeedItems(feedID: subject.id, items: [items[0], Self.item("https://www.nature.com/articles/a3", title: "A3")])
        #expect(fromSubject.map(\.itemURL) == ["https://www.nature.com/articles/a3"], "an article two feeds carry stays one row")
        #expect(try store.loadUnjudgedJournalItems().count == 3)

        try store.recordJournalFeedCheck(feedID: nature.id, at: Date(), succeeded: true, error: nil, etag: "\"e1\"", lastModified: "Mon", title: "Nature ")
        let reloaded = try #require(try store.loadJournalFeeds().first { $0.id == nature.id })
        #expect(reloaded.itemCount == 2)
        #expect(reloaded.etag == "\"e1\"")
        #expect(reloaded.lastModified == "Mon")
        #expect(reloaded.lastError == nil)
        #expect(reloaded.lastCheckedAt != nil && reloaded.lastSucceededAt != nil)

        try store.recordJournalFeedCheck(feedID: nature.id, at: Date(), succeeded: false, error: "HTTP 503", etag: nil, lastModified: nil, title: nil)
        let failed = try #require(try store.loadJournalFeeds().first { $0.id == nature.id })
        #expect(failed.lastError == "HTTP 503")
        #expect(failed.etag == "\"e1\"", "a failure keeps the validators")
        #expect(failed.title == "Nature")
    }

    @Test("Verdicts become pending suggestions once; a dismissal is a tombstone; acceptance records the source")
    func matches() throws {
        let store = try makeStore()
        let feed = try store.addJournalFeed(feedURL: "https://www.nature.com/nature.rss", title: "Nature", siteURL: nil).feed
        let published = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try store.recordJournalFeedItems(feedID: feed.id, items: [
            Self.item("https://www.nature.com/articles/a1", title: "A1", published: published),
            Self.item("https://www.nature.com/articles/a2", title: "A2"),
        ])
        let recorded = try store.recordJournalMatches([
            JournalArticleVerdict(itemID: "https://www.nature.com/articles/a1", notebookID: "p1", reason: "Cristae"),
            JournalArticleVerdict(itemID: "https://www.nature.com/articles/a1", notebookID: "p2", reason: "Also here"),
            JournalArticleVerdict(itemID: "https://www.nature.com/articles/a2", notebookID: "p1", reason: ""),
        ])
        #expect(recorded.count == 3)
        #expect(recorded.allSatisfy { $0.state == .pending })
        #expect(try store.recordJournalMatches([JournalArticleVerdict(itemID: "https://www.nature.com/articles/a1", notebookID: "p1", reason: "again")]).isEmpty)

        let forP1 = try store.loadPendingJournalSuggestions(notebookID: "p1")
        #expect(forP1.count == 2)
        let a1 = try #require(forP1.first { $0.item.itemURL == "https://www.nature.com/articles/a1" })
        #expect(a1.match.reason == "Cristae")
        #expect(a1.item.title == "A1")
        #expect(a1.item.publishedAt == published)
        #expect(a1.feedTitle == "Nature")
        #expect(a1.journalName == "Nature")
        let a2 = try #require(forP1.first { $0.item.itemURL == "https://www.nature.com/articles/a2" })
        #expect(a2.match.reason == nil, "an empty reason is stored as none")
        #expect(try store.loadPendingJournalSuggestions().count == 3)
        #expect(try store.pendingJournalSuggestionCounts() == ["p1": 2, "p2": 1])
        #expect(try store.journalMatchedItemURLs(notebookID: "p1") == ["https://www.nature.com/articles/a1", "https://www.nature.com/articles/a2"])

        try store.setJournalMatchState(itemURL: "https://www.nature.com/articles/a2", notebookID: "p1", state: .dismissed)
        try store.setJournalMatchState(itemURL: "https://www.nature.com/articles/a1", notebookID: "p1", state: .accepted, sourceID: "src-1")
        #expect(try store.loadPendingJournalSuggestions(notebookID: "p1").isEmpty)
        #expect(try store.loadPendingJournalSuggestions(notebookID: "p2").count == 1, "the other Notebook keeps its own suggestion")
        #expect(try store.recordJournalMatches([JournalArticleVerdict(itemID: "https://www.nature.com/articles/a2", notebookID: "p1", reason: "back?")]).isEmpty, "a dismissed pair is never re-offered")
        #expect(try store.journalMatchedItemURLs(notebookID: "p1").count == 2)
    }

    @Test("Judging marks articles seen; pruning drops old unmatched ones and keeps matched ones")
    func judgingAndPruning() throws {
        let store = try makeStore()
        let feed = try store.addJournalFeed(feedURL: "https://www.nature.com/nature.rss", title: "Nature", siteURL: nil).feed
        try store.recordJournalFeedItems(feedID: feed.id, items: [
            Self.item("https://www.nature.com/articles/old-matched", title: "Old matched"),
            Self.item("https://www.nature.com/articles/old-unmatched", title: "Old unmatched"),
            Self.item("https://www.nature.com/articles/new", title: "New"),
        ])
        let longAgo = Date(timeIntervalSinceReferenceDate: 100)
        try store.markJournalItemsJudged(["https://www.nature.com/articles/old-matched", "https://www.nature.com/articles/old-unmatched"], at: longAgo)
        #expect(try store.loadUnjudgedJournalItems().map(\.itemURL) == ["https://www.nature.com/articles/new"])
        try store.recordJournalMatches([JournalArticleVerdict(itemID: "https://www.nature.com/articles/old-matched", notebookID: "p1", reason: "")])

        #expect(try store.pruneJournalItems(olderThan: Date(timeIntervalSinceReferenceDate: 1_000)) == 1)
        let remaining = try store.loadUnjudgedJournalItems() + (try store.loadPendingJournalSuggestions().map(\.item))
        #expect(Set(remaining.map(\.itemURL)) == ["https://www.nature.com/articles/new", "https://www.nature.com/articles/old-matched"])
        #expect(try store.markJournalItemsJudged([]) == ())
    }

    @Test("Notebooks are watched unless excluded, and an exclusion can be lifted")
    func exclusions() throws {
        let store = try makeStore()
        #expect(try store.journalWatchExcludedNotebookIDs().isEmpty)
        try store.setJournalWatchNotebookExcluded("p1", excluded: true)
        try store.setJournalWatchNotebookExcluded("p1", excluded: true)
        try store.setJournalWatchNotebookExcluded("p2", excluded: true)
        #expect(try store.journalWatchExcludedNotebookIDs() == ["p1", "p2"])
        try store.setJournalWatchNotebookExcluded("p1", excluded: false)
        #expect(try store.journalWatchExcludedNotebookIDs() == ["p2"])
    }

    @Test("An announced article already in the library is recognised by URL or by DOI")
    func libraryLookup() throws {
        let store = try makeStore()
        try store.saveSource(Self.article(id: "src-url", url: "https://www.nature.com/articles/known?utm_source=feed", title: "Known"))
        try store.saveSource(Self.article(id: "src-doi", url: "https://doi.org/10.1038/s41586-026-00001-1", title: "Known paper", type: .paper, doi: "10.1038/s41586-026-00001-1"))

        #expect(store.journalItemExistsInLibrary(url: "https://www.nature.com/articles/known", doi: nil), "tracking parameters do not hide a match")
        #expect(store.journalItemExistsInLibrary(url: "https://www.nature.com/articles/s41586-026-00001-1", doi: "10.1038/s41586-026-00001-1"), "a different URL for the same DOI is the same paper")
        #expect(!store.journalItemExistsInLibrary(url: "https://www.nature.com/articles/unknown", doi: "10.1038/unknown"))
        #expect(!store.journalItemExistsInLibrary(url: "https://www.nature.com/articles/unknown", doi: nil))
    }
}
