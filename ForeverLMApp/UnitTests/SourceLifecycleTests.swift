import Testing
import Foundation
@testable import ForeverLM

private func makeInMemoryStore() throws -> KnowledgeStore {
    try KnowledgeStore(inMemory: true)
}

private func makeArticle(url: String, title: String? = nil, sourceType: StudioSourceType = .article) -> StudioArticle {
    var article = StudioArticle(url: url, title: title, sourceType: sourceType)
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

@Suite("Source Lifecycle")
struct SourceLifecycleTests {

    // MARK: - Archive

    @Test("archiveSource sets status to archived")
    func archiveSourceSetsStatusToArchived() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/post-1", title: "Post 1")
        try store.insertSourceIfNew(&article)

        try store.archiveSource(article.id)

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].status == .archived)
    }

    @Test("archiveSource deletes content")
    func archiveSourceDeletesContent() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/post-2", title: "Post 2")
        try store.insertSourceIfNew(&article)
        try store.saveTranscript(article.id, "Some transcript text here.")

        let contentBefore = try store.loadSourceContent(article.id)
        #expect(contentBefore == "Some transcript text here.")

        try store.archiveSource(article.id)

        let contentAfter = try store.loadSourceContent(article.id)
        #expect(contentAfter == nil)
    }

    @Test("archiving a ready source stops it claiming text it no longer has")
    func archiveResetsFetchStateAndWordCount() throws {
        // `ready` means "content fetched, available via MCP". Leaving it set
        // while deleting the content row is what let 57 revived videos
        // advertise a nine-thousand-word transcript they no longer had: nothing
        // requeues a source that reports success, so it is invisible as a
        // problem to every consumer downstream.
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/talk", title: "A Talk", sourceType: .video)
        article.content = "Nine thousand words of transcript."
        article.state = .ready
        article.wordCount = 9_354
        try store.saveSource(article)

        try store.archiveSource(article.id)

        let archived = try #require(try store.loadSources().first)
        #expect(archived.state == .queued)
        #expect(archived.wordCount == nil)
    }

    @Test("a revived source comes back queued so its text is refetched")
    func unarchiveReturnsSourceToTheFetchQueue() throws {
        // The liked-YouTube sweep archives and revives in bulk on a background
        // pass, so this round trip runs over the whole liked library at once.
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/liked", title: "Liked Video", sourceType: .video)
        article.content = "Transcript text."
        article.state = .ready
        article.wordCount = 4_200
        try store.saveSource(article)

        try store.archiveSource(article.id)
        try store.unarchiveSource(article.id)

        let revived = try #require(try store.loadSources().first)
        #expect(revived.status == .active)
        #expect(revived.state == .queued)
        #expect(try store.loadSourceContent(article.id) == nil)
    }

    @Test("a source whose fetch is known to fail is not requeued")
    func archiveKeepsStateForSourcesWithAKnownFailure() throws {
        // A paywalled paper legitimately has no text. Requeuing it would retry
        // a fetch that cannot succeed, on every archive round trip.
        let store = try makeInMemoryStore()
        var paper = makeArticle(url: "https://example.com/paywalled", title: "Paywalled", sourceType: .paper)
        paper.state = .error
        paper.errorMessage = "paywall"
        try store.saveSource(paper)

        try store.archiveSource(paper.id)

        let archived = try #require(try store.loadSources().first)
        #expect(archived.state == .error)
    }

    @Test("a stale podcast metadata save cannot demote a stored transcript")
    func storedPodcastTranscriptStaysReady() throws {
        let store = try makeInMemoryStore()
        var episode = makeArticle(
            url: "apple-podcast://episode/12345",
            title: "Finished episode",
            sourceType: .podcast
        )
        try store.saveSource(episode)
        try store.saveTranscript(episode.id, "The complete podcast transcript.")

        episode.state = .queued
        episode.errorMessage = "Stale queue metadata"
        try store.saveSource(episode)

        let reloaded = try #require(try store.loadSources().first)
        #expect(reloaded.state == .ready)
        #expect(reloaded.errorMessage == nil)
        #expect(try store.loadSourceContent(episode.id) == "The complete podcast transcript.")
    }

    @Test("YouTube recovery atomically preserves podcast identity and records transcript provenance")
    func youtubePodcastTranscriptRecoveryPersistsProvenance() throws {
        let store = try makeInMemoryStore()
        var episode = makeArticle(
            url: "apple-podcast://episode/12345",
            title: "A paid podcast episode",
            sourceType: .podcast
        )
        episode.domain = "Example Show"
        episode.podcastWebPageURL = "https://example.com/episodes/12345"
        episode.state = .error
        episode.errorMessage = StudioViewModel.unavailablePodcastTranscriptMessage
        try store.saveSource(episode)
        try store.saveTranscript(episode.id, "Stale Apple text", rawTTML: "<tt>stale</tt>")
        episode.state = .error
        episode.errorMessage = StudioViewModel.unavailablePodcastTranscriptMessage
        try store.saveSource(episode)

        let youtubeURL = "https://www.youtube.com/watch?v=abc123def45"
        try store.savePodcastYouTubeTranscript(
            episode.id,
            "[0:00] Confirmed YouTube captions",
            youtubeURL: youtubeURL
        )

        let recovered = try #require(try store.loadSources().first)
        #expect(recovered.url == episode.url)
        #expect(recovered.podcastWebPageURL == episode.podcastWebPageURL)
        #expect(recovered.publicURL == youtubeURL)
        #expect(recovered.state == .ready)
        #expect(recovered.errorMessage == nil)
        #expect(recovered.wordCount == 4)
        #expect(try store.loadSourceContent(episode.id) == "[0:00] Confirmed YouTube captions")
        #expect(try store.loadPodcastRawTTML(episode.id) == nil)

        let payloadData = try JSONEncoder().encode(CloudKitSourcePayload(article: recovered))
        let synced = try JSONDecoder().decode(CloudKitSourcePayload.self, from: payloadData)
        #expect(synced.article.publicURL == youtubeURL)
        #expect(synced.article.url == episode.url)
    }

    @Test("YouTube podcast recovery rolls back when the target is not a podcast")
    func youtubePodcastTranscriptRecoveryRejectsOtherSources() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/article", title: "Article")
        try store.insertSourceIfNew(&article)

        #expect(throws: (any Error).self) {
            try store.savePodcastYouTubeTranscript(
                article.id,
                "This must not be committed.",
                youtubeURL: "https://www.youtube.com/watch?v=abc123def45"
            )
        }

        #expect(try store.loadSourceContent(article.id) == nil)
        #expect(try store.loadSources().first?.publicURL != "https://www.youtube.com/watch?v=abc123def45")
    }

    @Test("archiveSource on non-existent ID does not crash")
    func archiveSourceNonExistentID() throws {
        let store = try makeInMemoryStore()
        try store.archiveSource("non-existent-id-12345")
        // Should complete without throwing
    }

    @Test("archiving already-archived source is idempotent")
    func archiveSourceIdempotent() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/post-3", title: "Post 3")
        try store.insertSourceIfNew(&article)

        try store.archiveSource(article.id)
        try store.archiveSource(article.id)

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].status == .archived)
    }

    @Test("archived source excluded from loadActiveSources but included in loadSources")
    func archivedSourceVisibility() throws {
        let store = try makeInMemoryStore()
        var article1 = makeArticle(url: "https://example.com/active", title: "Active")
        var article2 = makeArticle(url: "https://example.com/archived", title: "Archived")
        try store.insertSourceIfNew(&article1)
        try store.insertSourceIfNew(&article2)

        try store.archiveSource(article2.id)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].title == "Active")

        let all = try store.loadSources()
        #expect(all.count == 2)
    }

    // MARK: - Clear Derived Data

    @Test("clearSourceDerivedData deletes content but source remains active")
    func clearDerivedDataDeletesContentKeepsActive() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/clear-1", title: "Clear 1")
        try store.insertSourceIfNew(&article)
        try store.saveTranscript(article.id, "Content to clear.")

        try store.clearSourceDerivedData(article.id)

        let content = try store.loadSourceContent(article.id)
        #expect(content == nil)

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].status == .active)
    }

    @Test("source still appears in loadActiveSources after clearing derived data")
    func clearDerivedDataSourceStillActive() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/clear-2", title: "Clear 2")
        try store.insertSourceIfNew(&article)
        try store.saveTranscript(article.id, "Will be cleared.")

        try store.clearSourceDerivedData(article.id)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].id == article.id)
    }

    @Test("clearSourceDerivedData is no-op on source without content")
    func clearDerivedDataNoOpWithoutContent() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/clear-3", title: "Clear 3")
        try store.insertSourceIfNew(&article)

        // Should not throw even though there is no content to delete
        try store.clearSourceDerivedData(article.id)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].id == article.id)
    }

    // MARK: - Whole-book self-group invariant

    @Test("A whole-book source keeps its self-group while it is a book")
    func wholeBookKeepsSelfGroup() throws {
        let store = try makeInMemoryStore()
        var book = makeArticle(url: "https://example.com/whole-book.pdf", title: "Whole Book", sourceType: .book)
        book.parentGroup = book.id
        try store.insertSourceIfNew(&book)

        let loaded = try #require(try store.loadSources().first)
        #expect(loaded.parentGroup == book.id)
    }

    @Test("Reclassifying a whole-book source to paper drops the self-group and book metadata")
    func reclassifiedWholeBookDropsSelfGroupAndMetadata() throws {
        let store = try makeInMemoryStore()
        var book = makeArticle(url: "https://arxiv.org/abs/2602.05993", title: "A Paper", sourceType: .book)
        book.parentGroup = book.id
        try store.insertSourceIfNew(&book)
        try store.saveBookMetadata(groupName: book.id, title: "A Paper", author: nil, coverPath: nil, kind: nil)

        try store.updateSourceType(book.id, to: StudioSourceType.paper.rawValue)

        let loaded = try #require(try store.loadSources().first)
        #expect(loaded.sourceType == .paper)
        // The raw source id must never survive as a group name — that is what
        // surfaced as a `src_…` subtitle in the reader's Continue reading rows.
        #expect(loaded.parentGroup == nil)
        #expect(try store.loadBooks().titles[book.id] == nil)
    }

    @Test("Reclassifying a chapter of a real book leaves the book's metadata intact")
    func reclassifiedChapterLeavesRealBookIntact() throws {
        let store = try makeInMemoryStore()
        var chapter = makeArticle(url: "https://example.com/ch1", title: "Chapter 1", sourceType: .book)
        chapter.parentGroup = "Real Book"
        try store.insertSourceIfNew(&chapter)
        try store.saveBookMetadata(groupName: "Real Book", title: "Real Book", author: nil, coverPath: nil, kind: nil)

        try store.updateSourceType(chapter.id, to: StudioSourceType.paper.rawValue)

        #expect(try store.loadBooks().titles["Real Book"] == "Real Book")
    }

    // MARK: - Unarchive by Parent Group

    @Test("unarchiveSourcesByParentGroup unarchives sources in group")
    func unarchiveByGroup() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/chapter-1", title: "Chapter 1", sourceType: .book)
        article.parentGroup = "My Book"
        try store.insertSourceIfNew(&article)

        // saveSource is called by insertSourceIfNew, which sets parentGroup and populates group_members
        try store.archiveSource(article.id)

        let activeBefore = try store.loadActiveSources()
        #expect(activeBefore.isEmpty)

        try store.unarchiveSourcesByParentGroup("My Book")

        let activeAfter = try store.loadActiveSources()
        #expect(activeAfter.count == 1)
        #expect(activeAfter[0].id == article.id)
        #expect(activeAfter[0].status == .active)
    }

    @Test("unarchiveSourcesByParentGroup does not affect sources in different group")
    func unarchiveByGroupDoesNotAffectOtherGroups() throws {
        let store = try makeInMemoryStore()
        var bookA = makeArticle(url: "https://example.com/book-a-ch1", title: "Book A Ch1", sourceType: .book)
        bookA.parentGroup = "Book A"
        try store.insertSourceIfNew(&bookA)

        var bookB = makeArticle(url: "https://example.com/book-b-ch1", title: "Book B Ch1", sourceType: .book)
        bookB.parentGroup = "Book B"
        try store.insertSourceIfNew(&bookB)

        try store.archiveSource(bookA.id)
        try store.archiveSource(bookB.id)

        try store.unarchiveSourcesByParentGroup("Book A")

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].id == bookA.id)

        // Book B should still be archived
        let all = try store.loadSources()
        let bookBSource = all.first { $0.id == bookB.id }
        #expect(bookBSource?.status == .archived)
    }

    @Test("unarchiveSourcesByParentGroup does not affect active sources")
    func unarchiveByGroupNoOpOnActive() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/active-chapter", title: "Active Chapter", sourceType: .book)
        article.parentGroup = "Active Book"
        try store.insertSourceIfNew(&article)

        // Source is already active; unarchive should be a no-op
        try store.unarchiveSourcesByParentGroup("Active Book")

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].status == .active)
    }

    @Test("unarchiveSourcesByParentGroup is no-op when group has no archived sources")
    func unarchiveByGroupNoOpForEmptyGroup() throws {
        let store = try makeInMemoryStore()

        // No sources at all in this group
        try store.unarchiveSourcesByParentGroup("Nonexistent Group")

        let active = try store.loadActiveSources()
        #expect(active.isEmpty)
    }

    // MARK: - Delete

    @Test("deleteSource removes source entirely")
    func deleteSourceRemovesEntirely() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/delete-1", title: "Delete 1")
        try store.insertSourceIfNew(&article)

        try store.deleteSource(article.id)

        let all = try store.loadSources()
        #expect(all.isEmpty)
    }

    @Test("deleteSource is no-op on non-existent ID")
    func deleteSourceNoOpNonExistent() throws {
        let store = try makeInMemoryStore()

        // Should not throw
        try store.deleteSource("non-existent-id-99999")

        let all = try store.loadSources()
        #expect(all.isEmpty)
    }

    @Test("deleteSource removes content along with source")
    func deleteSourceRemovesContent() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/delete-2", title: "Delete 2")
        try store.insertSourceIfNew(&article)
        try store.saveTranscript(article.id, "Content that should be deleted.")

        let contentBefore = try store.loadSourceContent(article.id)
        #expect(contentBefore != nil)

        try store.deleteSource(article.id)

        let all = try store.loadSources()
        #expect(all.isEmpty)

        // Content should also be gone (CASCADE or explicit delete)
        let contentAfter = try store.loadSourceContent(article.id)
        #expect(contentAfter == nil)
    }

    // MARK: - Dismiss Tracking

    @Test("dismissSource records URL")
    func dismissSourceRecordsURL() throws {
        let store = try makeInMemoryStore()
        try store.dismissSource(url: "https://example.com/dismissed", title: "Dismissed Article")

        let dismissed = try store.loadDismissedSourceURLs()
        #expect(dismissed.count == 1)
    }

    @Test("isSourceDismissed returns true for dismissed URL")
    func isSourceDismissedTrue() throws {
        let store = try makeInMemoryStore()
        try store.dismissSource(url: "https://example.com/dismissed", title: "Dismissed")

        #expect(store.isSourceDismissed(url: "https://example.com/dismissed"))
    }

    @Test("isSourceDismissed returns false for non-dismissed URL")
    func isSourceDismissedFalse() throws {
        let store = try makeInMemoryStore()

        #expect(!store.isSourceDismissed(url: "https://example.com/not-dismissed"))
    }

    @Test("loadDismissedSourceURLs returns all dismissed URLs")
    func loadDismissedSourceURLsReturnsAll() throws {
        let store = try makeInMemoryStore()
        try store.dismissSource(url: "https://example.com/a", title: "A")
        try store.dismissSource(url: "https://example.com/b", title: "B")
        try store.dismissSource(url: "https://example.com/c", title: nil)

        let dismissed = try store.loadDismissedSourceURLs()
        #expect(dismissed.count == 3)
    }

    @Test("insertSourceIfNew rejects dismissed URL")
    func insertSourceIfNewRejectsDismissed() throws {
        let store = try makeInMemoryStore()
        try store.dismissSource(url: "https://example.com/rejected", title: "Rejected")

        var article = makeArticle(url: "https://example.com/rejected", title: "Should Not Insert")
        let inserted = try store.insertSourceIfNew(&article)
        #expect(!inserted)

        let all = try store.loadSources()
        #expect(all.isEmpty)
    }

    @Test("insertSourceIfNew rejects normalized dismissed paper URL")
    func insertSourceIfNewRejectsNormalizedDismissedPaperURL() throws {
        let store = try makeInMemoryStore()
        try store.dismissSource(url: "https://arxiv.org/abs/1706.03762", title: "Attention Is All You Need")

        var paper = makeArticle(url: "https://arxiv.org/pdf/1706.03762.pdf", title: "Attention Is All You Need")
        paper.sourceType = .paper

        let inserted = try store.insertSourceIfNew(&paper)
        #expect(!inserted)
        #expect(try store.loadSources().isEmpty)
    }

    // MARK: - Integration

    @Test("full lifecycle: insert, add content, archive, unarchive — content deleted but source active")
    func fullLifecycle() throws {
        let store = try makeInMemoryStore()

        // Insert source with a parent group
        var article = makeArticle(url: "https://example.com/lifecycle", title: "Lifecycle Test", sourceType: .book)
        article.parentGroup = "Test Book"
        try store.insertSourceIfNew(&article)

        // Add content
        try store.saveTranscript(article.id, "Chapter content goes here.")
        let contentBefore = try store.loadSourceContent(article.id)
        #expect(contentBefore == "Chapter content goes here.")

        // Archive — content should be deleted
        try store.archiveSource(article.id)
        let contentAfterArchive = try store.loadSourceContent(article.id)
        #expect(contentAfterArchive == nil)

        let activeMid = try store.loadActiveSources()
        #expect(activeMid.isEmpty)

        // Unarchive by parent group
        try store.unarchiveSourcesByParentGroup("Test Book")

        let activeAfter = try store.loadActiveSources()
        #expect(activeAfter.count == 1)
        #expect(activeAfter[0].id == article.id)
        #expect(activeAfter[0].status == .active)

        // Content should still be gone (archive deletes it permanently)
        let contentAfterUnarchive = try store.loadSourceContent(article.id)
        #expect(contentAfterUnarchive == nil)
    }

    @Test("dismiss then re-insert is rejected")
    func dismissThenReinsertRejected() throws {
        let store = try makeInMemoryStore()

        // First insert the source
        var article = makeArticle(url: "https://example.com/dismiss-reinsert", title: "Original")
        let inserted = try store.insertSourceIfNew(&article)
        #expect(inserted)

        // Now dismiss and delete it
        try store.dismissSource(url: "https://example.com/dismiss-reinsert", title: "Original")
        try store.deleteSource(article.id)

        let allAfterDelete = try store.loadSources()
        #expect(allAfterDelete.isEmpty)

        // Try to re-insert the same URL — should be rejected because it is dismissed
        var retry = makeArticle(url: "https://example.com/dismiss-reinsert", title: "Retry")
        let reinserted = try store.insertSourceIfNew(&retry)
        #expect(!reinserted)

        let allAfterRetry = try store.loadSources()
        #expect(allAfterRetry.isEmpty)
    }
}

// MARK: - Reviving feed-mirrored sources

private func makeStorageService() -> StorageService {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("SourceReviveTests_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return StorageService(storeRoot: tmp)
}

/// The YouTube Liked feed is a mirror: this sync archives a video when it
/// leaves the feed, so a re-like has to be able to undo that. `insertSourceIfNew`
/// deliberately refuses to re-insert over any existing row, and every other
/// lookup in the ingest path goes through `loadActiveSources`, so without an
/// explicit revive a re-liked video is invisible to both and silently vanishes.
@Suite("Unarchive on reappearance")
struct UnarchiveMatchingURLTests {

    @Test("revives an archived row and reports its id")
    func revivesArchivedRow() async throws {
        let storage = makeStorageService()
        var article = makeArticle(url: "https://www.youtube.com/watch?v=REVIVE00001", sourceType: .video)
        #expect(try await storage.insertSourceIfNew(&article))
        try await storage.archiveSource(article.id)

        let revivedID = try await storage.unarchiveSourceMatchingURL(article.url)

        #expect(revivedID == article.id)
        let active = try await storage.loadActiveSources()
        #expect(active.contains { $0.id == article.id })
    }

    @Test("matches on normalized URL, not just the stored form")
    func matchesNormalizedURL() async throws {
        let storage = makeStorageService()
        var article = makeArticle(url: "https://www.youtube.com/watch?v=REVIVE00002", sourceType: .video)
        #expect(try await storage.insertSourceIfNew(&article))
        try await storage.archiveSource(article.id)

        // Same video, different URL spelling — the feed does not promise to hand
        // back the exact string that was stored.
        let revivedID = try await storage.unarchiveSourceMatchingURL(
            "https://youtube.com/watch?v=REVIVE00002"
        )

        #expect(revivedID == article.id)
    }

    @Test("leaves an already-active row alone")
    func ignoresActiveRow() async throws {
        let storage = makeStorageService()
        var article = makeArticle(url: "https://www.youtube.com/watch?v=REVIVE00003", sourceType: .video)
        #expect(try await storage.insertSourceIfNew(&article))

        #expect(try await storage.unarchiveSourceMatchingURL(article.url) == nil)
    }

    @Test("returns nil for a URL the library has never seen")
    func ignoresUnknownURL() async throws {
        let storage = makeStorageService()

        #expect(try await storage.unarchiveSourceMatchingURL(
            "https://www.youtube.com/watch?v=NEVERSEEN01"
        ) == nil)
    }

    @Test("refuses to revive a dismissed URL")
    func refusesDismissedURL() async throws {
        let storage = makeStorageService()
        var article = makeArticle(url: "https://www.youtube.com/watch?v=REVIVE00004", sourceType: .video)
        #expect(try await storage.insertSourceIfNew(&article))
        // Archive first, so the row is genuinely revivable and only the dismissal
        // stands in the way — otherwise this passes for the wrong reason.
        try await storage.archiveSource(article.id)
        // Dismissal outranks passive re-discovery, which is what the default
        // means: without an explicit user action behind the caller, reviving the
        // row would only feed it back to the sweep that re-archives dismissed
        // URLs. `clearingDismissal: true` is the opt-in that overrides this.
        try await storage.dismissSources([article])

        #expect(try await storage.unarchiveSourceMatchingURL(article.url) == nil)
    }

    @Test("an explicit re-like clears the dismissal and revives the row")
    func clearingDismissalRevivesDismissedRow() async throws {
        let storage = makeStorageService()
        var article = makeArticle(url: "https://www.youtube.com/watch?v=REVIVE00005", sourceType: .video)
        #expect(try await storage.insertSourceIfNew(&article))
        try await storage.archiveSource(article.id)
        try await storage.dismissSources([article])

        let revivedID = try await storage.unarchiveSourceMatchingURL(
            article.url,
            clearingDismissal: true
        )

        #expect(revivedID == article.id)
        let active = try await storage.loadActiveSources()
        #expect(active.contains { $0.id == article.id })
        // The tombstone must be gone, not merely bypassed: a surviving row would
        // re-archive the source on the next inbound CloudKit record.
        #expect(!(await storage.isSourceDismissed(url: article.url)))
    }

    @Test("clearing a dismissal unblocks the insert when no row survived")
    func clearingDismissalUnblocksInsert() async throws {
        let storage = makeStorageService()
        var article = makeArticle(url: "https://www.youtube.com/watch?v=REVIVE00006", sourceType: .video)
        // Dismissed without ever being stored: nothing to revive, and the
        // dismissal alone is what makes the insert fail.
        try await storage.dismissSources([article])
        #expect(try await storage.insertSourceIfNew(&article) == false)

        #expect(try await storage.unarchiveSourceMatchingURL(
            article.url,
            clearingDismissal: true
        ) == nil)

        #expect(!(await storage.isSourceDismissed(url: article.url)))
        #expect(try await storage.insertSourceIfNew(&article))
    }

    @Test("an explicit re-add preempts a dismissal that has not arrived yet")
    func explicitReAddPreemptsDelayedDismissal() throws {
        let store = try makeInMemoryStore()
        let url = "https://example.com/paper-awaiting-old-dismissal"

        #expect(!store.isSourceDismissed(url: url))
        let deletionKeys = try store.undismissSource(url: url)

        #expect(deletionKeys.contains(url))
        let deletion = try #require(try store.pendingSyncChanges().first {
            $0.entity == .dismissedSource && $0.logicalKey == url
        })
        #expect(deletion.operation == .delete)

        var paper = makeArticle(url: url, title: "Explicitly re-added paper", sourceType: .paper)
        #expect(try store.insertSourceIfNew(&paper))
        #expect(try store.loadActiveSources().contains { $0.id == paper.id })
    }
}

@Suite("YouTube plugin failure classification")
struct YouTubePluginFailureTests {

    @Test("a lost connection asks for a reconnect")
    func lostConnectionNeedsReconnect() {
        #expect(StudioViewModel.isYouTubeReconnectRequired(YouTubeServiceError.notSignedIn))
        #expect(StudioViewModel.isYouTubeReconnectRequired(YouTubeServiceError.authFailed("revoked")))
    }

    @Test("transient failures do not")
    func transientFailuresDoNot() {
        // These clear up on their own; prompting to reconnect would teach the
        // user to ignore the prompt that matters.
        #expect(!StudioViewModel.isYouTubeReconnectRequired(
            YouTubeServiceError.apiFailed("YouTube API quota exceeded. Try again later.")
        ))
        #expect(!StudioViewModel.isYouTubeReconnectRequired(
            URLError(.notConnectedToInternet)
        ))
    }
}
