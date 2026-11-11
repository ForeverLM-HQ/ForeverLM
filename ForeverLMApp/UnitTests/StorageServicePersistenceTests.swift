// StorageService persistence, analyzer statistics and unreviewed consumed source tests.

import Testing
import CloudKit
import Foundation
import SQLite3
@testable import ForeverLM

/// Helper: create a StudioArticle with sensible defaults for testing.
private func makeArticle(url: String, title: String? = nil) -> StudioArticle {
    var article = StudioArticle(url: url, title: title)
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

// MARK: - StorageService Persistence Tests

/// Creates an in-memory StorageService for unit testing.
func makeInMemoryService() throws -> StorageService {
    try StorageService(inMemory: true)
}

@Suite("Full-text analyzer statistics")
struct FullTextAnalyzerStatisticsTests {

    @Test("both spellings of a term count toward one document frequency")
    func documentFrequencyCountsBothSpellings() throws {
        let store = try TestStores.inMemory()

        try store.replaceSourceFTS(
            sourceID: "source-hyphenated",
            title: "Mitochondrial stress markers",
            author: "",
            body: "Circulating GDF-15 rises with mitochondrial dysfunction."
        )
        try store.replaceSourceFTS(
            sourceID: "source-bare",
            title: "A mystery hormone",
            author: "",
            body: "GDF15 remains poorly understood."
        )

        // The statistic a query-time rewrite cannot repair: rarity is measured on one
        // token, so `lexicalWeight` sees a rare anchor whichever spelling was typed
        // instead of a term the index appears never to have heard of.
        #expect(try store.sourceFTSDocumentFrequency(term: "gdf15") == 2)

        // The separated spelling is still there — the closed-up token is added, not
        // substituted, so a phrase query and a plain word query both still work.
        #expect(try store.sourceFTSDocumentFrequency(term: "gdf 15") == 1)
        #expect(try store.sourceFTSDocumentFrequency(term: "mitochondrial") == 1)
        #expect(try store.sourceFTSDocumentFrequency(term: "gdf16") == 0)
    }
}

@Suite("StorageService Persistence")
struct StorageServicePersistenceTests {

    @Test("paper metadata backfill preserves a concurrently attached PDF")
    func paperMetadataBackfillPreservesConcurrentAttachment() async throws {
        let svc = try makeInMemoryService()
        var original = StudioArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/39933528/",
            title: "Impact of physical activity",
            sourceType: .paper
        )
        original.author = nil
        try await svc.saveSource(original)

        var candidate = original
        candidate.author = "Marina Cefis et al."
        candidate.journal = "Cell Reports Medicine"
        candidate.publishedYear = "2025"
        candidate.doi = "10.1016/j.xcrm.2025.101968"
        let patch = PaperMetadataBackfillPatch(original: original, candidate: candidate)

        var attached = original
        attached.url = "https://pmc.ncbi.nlm.nih.gov/articles/PMC11866497/"
        attached.localFilePath = "/tmp/PMC11866497.pdf"
        attached.domain = "Local PDF"
        try await svc.saveSource(attached)

        let merged = try await svc.mergePaperMetadataBackfill(patch)

        #expect(merged?.url == attached.url)
        #expect(merged?.localFilePath == attached.localFilePath)
        #expect(merged?.domain == "Local PDF")
        #expect(merged?.author == candidate.author)
        #expect(merged?.journal == candidate.journal)
        #expect(merged?.publishedYear == candidate.publishedYear)
        #expect(merged?.doi == candidate.doi)
    }

    @Test("the full-text index stores a separated term closed up as well")
    func fullTextIndexAnalyzesSymbolSpellings() async throws {
        let svc = try makeInMemoryService()
        var hyphenated = makeArticle(url: "https://example.com/hyphenated", title: "Mitochondrial stress markers")
        try await svc.insertSourceIfNew(&hyphenated)
        var bare = makeArticle(url: "https://example.com/bare", title: "A mystery hormone")
        try await svc.insertSourceIfNew(&bare)

        // Written the way the indexer writes them, from text that names the protein only
        // in the body, each spelling it the other way.
        try await svc.replaceSourceFTS(
            sourceID: hyphenated.id,
            title: "Mitochondrial stress markers",
            author: "",
            body: "Circulating GDF-15 rises with mitochondrial dysfunction in muscle."
        )
        try await svc.replaceSourceFTS(
            sourceID: bare.id,
            title: "A mystery hormone",
            author: "",
            body: "GDF15 remains poorly understood as a signal of cellular stress."
        )

        // No embedding: this is the lexical branch alone, and the point is that it no
        // longer needs the query rewritten to reach both spellings — the index itself
        // holds `gdf15` for the hyphenated source.
        let bareQuery = await svc.searchSources(queryText: "GDF15", queryVector: nil, limit: 5)
            .map(\.sourceId)
        #expect(Set(bareQuery) == [hyphenated.id, bare.id])

        let hyphenQuery = await svc.searchSources(queryText: "GDF-15", queryVector: nil, limit: 5)
            .map(\.sourceId)
        #expect(Set(hyphenQuery) == [hyphenated.id, bare.id])

        let unrelated = await svc.searchSources(queryText: "GDF16", queryVector: nil, limit: 5)
        #expect(unrelated.isEmpty)
    }

    @Test("a full-text row written by an older analyzer is rewritten, without re-embedding")
    func staleFullTextRowsAreReanalyzed() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/stale", title: "Mitochondrial stress markers")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "Circulating GDF-15 rises with mitochondrial dysfunction.")

        // A source with no full-text row at all is the same gap an older analyzer leaves.
        #expect(await svc.sourcesNeedingFTSRebuild().map(\.id) == [article.id])

        try await svc.replaceSourceFTS(
            sourceID: article.id,
            title: "Mitochondrial stress markers",
            author: "",
            body: "Circulating GDF-15 rises with mitochondrial dysfunction."
        )

        // Writing the row stamps the analyzer that wrote it, so the gap closes.
        #expect(await svc.sourcesNeedingFTSRebuild().isEmpty)

        // And closing it did not claim the source is embedded — that gap is tracked
        // separately, so a reanalysis never spends model time.
        #expect(await svc.sourcesMissingIndex().map(\.id) == [article.id])
    }

    @Test("an indexed stamp with no vectors behind it puts the source back in the gap")
    func stampedSourceWithoutVectorsIsReindexed() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://x.com/someone/status/1", title: "A short post")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "The link to our paper.")
        try await svc.saveSourceChunkEmbeddings(
            sourceId: article.id,
            embeddings: [(chunkId: StorageService.sourceChunkEmbeddingId(sourceId: article.id, index: 0), vector: [1, 0, 0])]
        )
        try await svc.recordSourceIndexed(sourceID: article.id)
        #expect(await svc.sourcesMissingIndex().isEmpty)

        // The vectors go while the stamp and the content length stay put.
        try await svc.saveSourceChunkEmbeddings(sourceId: article.id, embeddings: [])

        #expect(await svc.sourcesMissingIndex().map(\.id) == [article.id])
    }

    @Test("archiving drops the indexed stamp, so a restored source is embedded again")
    func archiveDropsIndexedStamp() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://x.com/someone/status/2", title: "A restored post")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "Same text before and after.")
        try await svc.saveSourceChunkEmbeddings(
            sourceId: article.id,
            embeddings: [(chunkId: StorageService.sourceChunkEmbeddingId(sourceId: article.id, index: 0), vector: [0, 1, 0])]
        )
        try await svc.recordSourceIndexed(sourceID: article.id)
        #expect(await svc.sourcesMissingIndex().isEmpty)

        try await svc.archiveSource(article.id)
        try await svc.unarchiveSource(article.id)
        // Sync brings the text back byte for byte, so the length the stamp
        // recorded still matches.
        try await svc.saveTranscript(article.id, "Same text before and after.")

        #expect(await svc.sourcesMissingIndex().map(\.id) == [article.id])
        #expect(await svc.embeddedChunkSourceIds().isEmpty)
    }

    @Test("saveTranscript persists content and sets state to ready")
    func testSaveTranscriptPersists() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/episode-1", title: "Episode 1")
        try await svc.insertSourceIfNew(&article)

        try await svc.saveTranscript(article.id, "Hello world transcript content.")

        let content = await svc.loadSourceContent(article.id)
        #expect(content == "Hello world transcript content.")
    }

    @Test("updateSourceType persists type")
    func testUpdateSourceTypePersists() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/doc", title: "Doc")
        try await svc.insertSourceIfNew(&article)

        try await svc.updateSourceType(article.id, to: StudioSourceType.paper.rawValue)

        let loaded = try await svc.loadActiveSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].sourceType == .paper)
    }

    @Test("updateParentGroup persists group")
    func testUpdateParentGroupPersists() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/lecture", title: "Lecture")
        try await svc.insertSourceIfNew(&article)

        try await svc.updateParentGroup(article.id, "Physics 101")

        let loaded = try await svc.loadActiveSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].parentGroup == "Physics 101")
    }

    @Test("archiveSource cleans up content")
    func testArchiveSourceCleansUpContent() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/post", title: "Post")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "Some content here.")

        try await svc.archiveSource(article.id)

        let active = try await svc.loadActiveSources()
        #expect(active.isEmpty)
        let content = await svc.loadSourceContent(article.id)
        #expect(content == nil)
    }

    @Test("transcript survives reload")
    func testTranscriptSurvivesReload() async throws {
        let svc = try makeInMemoryService()
        var article = makeArticle(url: "https://example.com/ep2", title: "Episode 2")
        try await svc.insertSourceIfNew(&article)
        try await svc.saveTranscript(article.id, "Persistent transcript.")

        // Re-load via a different path to ensure it's from DB
        let loaded = try await svc.loadActiveSources()
        #expect(loaded.count == 1)
        let content = await svc.loadSourceContent(article.id)
        #expect(content == "Persistent transcript.")
    }

    @Test("podcast transcript upgrade reuses existing source row")
    func testPodcastTranscriptUpgradeReusesExistingSourceRow() async throws {
        let svc = try makeInMemoryService()

        var placeholder = makeArticle(url: "apple-podcast://episode/12345", title: "Show - Episode")
        placeholder.sourceType = .podcast
        placeholder.domain = "Show"
        placeholder.state = .queued
        try await svc.insertSourceIfNew(&placeholder)

        var upgraded = StudioArticle(
            url: placeholder.url,
            title: placeholder.title,
            sourceType: .podcast,
            discoveryOrigin: .applePodcasts,
            id: placeholder.id
        )
        upgraded.domain = "Show"

        let existing = await svc.sourceRecordByNormalizedURL(URLNormalizer.normalize(upgraded.url))
        #expect(existing?.id == placeholder.id)

        try await svc.saveSource(upgraded)
        try await svc.saveTranscript(upgraded.id, "Transcript body", rawTTML: "<tt></tt>")

        let loaded = try await svc.loadActiveSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == placeholder.id)
        #expect(loaded[0].sourceType == .podcast)

        let content = await svc.loadSourceContent(placeholder.id)
        #expect(content == "Transcript body")
    }

    @Test("reconciliation archives source with missing file")
    func testReconciliationArchivesMissingFile() async throws {
        let svc = try makeInMemoryService()
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-\(UUID()).pdf")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data("test".utf8))

        var article = makeArticle(url: "file://\(tempFile.path)")
        article.localFilePath = tempFile.path
        article.sourceType = .paper
        try await svc.insertSourceIfNew(&article)

        // File exists — should stay active
        var active = try await svc.loadActiveSources()
        #expect(active.count == 1)

        // Delete the file
        try FileManager.default.removeItem(at: tempFile)

        // Reconcile: article with missing local file should be archived
        let archived = try await svc.reconcileLocalFiles()
        #expect(archived == 1)

        active = try await svc.loadActiveSources()
        #expect(active.count == 0)
    }

    @Test("reconciliation preserves missing app-managed PDF path")
    func testReconciliationPreservesMissingAppManagedPDFPath() async throws {
        let svc = try makeInMemoryService()
        let article = StudioArticle(
            url: "https://example.com/paper",
            title: "Synced Paper",
            sourceType: .paper,
            localFilePath: "Papers/synced-paper.pdf"
        )
        try await svc.saveSource(article)

        let archived = try await svc.reconcileLocalFiles()

        let active = try await svc.loadActiveSources()
        #expect(archived == 0)
        #expect(active.count == 1)
        // loadActiveSources resolves app-managed relative paths to an absolute
        // path under libraryRootPath, which differs per environment (iCloud
        // container vs ~/Documents fallback). The behavior under test is that
        // reconciliation preserved the missing app-managed path instead of
        // clearing or archiving it, so compare in relative form.
        #expect(active[0].localFilePath.map(StorageService.relativeSourcePath) == "Papers/synced-paper.pdf")
    }

    @Test("reconciliation still clears missing external cache for web source")
    func testReconciliationClearsMissingExternalCacheForWebSource() async throws {
        let svc = try makeInMemoryService()
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-cache-\(UUID()).pdf")
        let article = StudioArticle(
            url: "https://example.com/paper",
            title: "Externally Cached Paper",
            sourceType: .paper,
            localFilePath: tempFile.path
        )
        try await svc.saveSource(article)

        let archived = try await svc.reconcileLocalFiles()

        let active = try await svc.loadActiveSources()
        #expect(archived == 0)
        #expect(active.count == 1)
        #expect(active[0].localFilePath == nil)
    }

    @Test("full workflow survives relaunch")
    func testFullWorkflowSurvivesRelaunch() async throws {
        let svc = try makeInMemoryService()

        // Step 1: Import videos into a course
        var v1 = makeArticle(url: "https://youtube.com/watch?v=lecture1")
        v1.sourceType = .video
        v1.parentGroup = "MIT 6.006"
        var v2 = makeArticle(url: "https://youtube.com/watch?v=lecture2")
        v2.sourceType = .video
        v2.parentGroup = "MIT 6.006"
        _ = try await svc.insertSourceIfNew(&v1)
        _ = try await svc.insertSourceIfNew(&v2)

        // Step 2: Fetch a transcript
        try await svc.saveTranscript(v1.id, "Welcome to lecture 1 on algorithms...")

        // Step 3: Organize the course
        try await svc.updateCourseSortOrder([(v2.id, 0), (v1.id, 1)])

        // Step 4: Drag an article to papers
        var paper = makeArticle(url: "https://arxiv.org/abs/1706.03762")
        _ = try await svc.insertSourceIfNew(&paper)
        try await svc.updateSourceType(paper.id, to: StudioSourceType.paper.rawValue)

        // === SIMULATE RELAUNCH ===
        let sources = try await svc.loadActiveSources()

        // Verify everything survived
        #expect(sources.count == 3)

        // Transcript persisted
        let transcript = await svc.loadSourceContent(v1.id)
        #expect(transcript == "Welcome to lecture 1 on algorithms...")

        // Course sort order persisted
        let courseSources = sources
            .filter { $0.parentGroup == "MIT 6.006" }
            .sorted { ($0.courseSortIndex ?? Int.max) < ($1.courseSortIndex ?? Int.max) }
        #expect(courseSources[0].id == v2.id)
        #expect(courseSources[1].id == v1.id)

        // Source type change persisted
        let paperSource = sources.first { $0.url == "https://arxiv.org/abs/1706.03762" }
        #expect(paperSource?.sourceType == .paper)

        // Step 5: Discovery re-running should NOT duplicate
        var rediscoveredV1 = makeArticle(url: "https://youtube.com/watch?v=lecture1")
        let inserted = try await svc.insertSourceIfNew(&rediscoveredV1)
        #expect(!inserted, "Should skip — already exists in DB")

        let sourcesAfterRediscovery = try await svc.loadActiveSources()
        #expect(sourcesAfterRediscovery.count == 3, "No duplicates")
    }

    @Test("reconciliation keeps source with existing file")
    func testReconciliationKeepsExistingFile() async throws {
        let svc = try makeInMemoryService()
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-\(UUID()).pdf")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var article = makeArticle(url: "file://\(tempFile.path)")
        article.localFilePath = tempFile.path
        article.sourceType = .paper
        try await svc.insertSourceIfNew(&article)

        let archived = try await svc.reconcileLocalFiles()
        #expect(archived == 0)

        let active = try await svc.loadActiveSources()
        #expect(active.count == 1)
        }
    }

    @Test("Meeting groups and artifacts round-trip")
    func meetingGroupsAndArtifactsRoundTrip() throws {
        let store = try TestStores.inMemory()
        try store.saveMeetingGroup(
            name: "acme",
            metadata: MeetingMetadata(
                title: "Acme Longevity Nexus",
                driveFolderURL: "https://drive.google.com/drive/folders/example",
                localFolderPath: "/tmp/Acme",
                recurrenceRule: "FREQ=WEEKLY",
                timezone: "America/Los_Angeles"
            )
        )
        var article = StudioArticle(
            url: "meeting://acme/2025-11-23",
            title: "Acme Longevity Nexus - 2025/11/23",
            sourceType: .meeting,
            discoveryOrigin: .localMeetings,
            parentGroup: "acme"
        )
        article.content = "Transcript text"
        article.wordCount = 2
        article.state = .ready
        try store.saveSource(article)
        try store.saveMeetingArtifact(MeetingArtifact(
            sourceId: article.id,
            groupId: "acme",
            kind: .transcript,
            title: "Transcript",
            localFilePath: "/tmp/Acme/transcript.txt"
        ))

        let groups = try store.loadMeetingGroups()
        #expect(groups["acme"]?.title == "Acme Longevity Nexus")
        let sources = try store.loadSources()
        #expect(sources.first?.sourceType == .meeting)
        #expect(sources.first?.parentGroup == "acme")
        let artifacts = try store.loadMeetingArtifacts(groupID: "acme")
        #expect(artifacts.count == 1)
        #expect(artifacts[0].kind == .transcript)
    }

    @Test("Merging meeting groups moves relationships and preserves an incoming import alias")
    func meetingGroupMergeIsAtomicAndDurable() throws {
        let store = try TestStores.inMemory()
        try store.saveMeetingGroup(
            name: "read-ai-weekly",
            metadata: MeetingMetadata(title: "Weekly Sync from Read AI")
        )
        try store.saveMeetingGroup(
            name: "weekly",
            metadata: MeetingMetadata(title: "Weekly Sync")
        )
        var article = StudioArticle(
            url: "meeting://read-ai-weekly/2026-08-31",
            title: "Weekly Sync — August 31",
            sourceType: .meeting,
            discoveryOrigin: .readAI,
            parentGroup: "read-ai-weekly"
        )
        article.content = "# Weekly Sync\n\n## Transcript\n\nMaterial"
        article.state = .ready
        try store.saveSource(article)
        try store.saveMeetingArtifact(MeetingArtifact(
            id: "read-ai-transcript",
            sourceId: article.id,
            groupId: "read-ai-weekly",
            kind: .transcript,
            title: "Transcript"
        ))

        try store.mergeMeetingGroup("read-ai-weekly", into: "weekly")

        let groups = try store.loadMeetingGroups()
        #expect(groups["read-ai-weekly"]?.isHidden == true)
        #expect(groups["read-ai-weekly"]?.mergedIntoGroupID == "weekly")
        #expect(groups["weekly"]?.title == "Weekly Sync")
        #expect(try store.loadSources().first(where: { $0.id == article.id })?.parentGroup == "weekly")
        #expect(try store.loadMeetingArtifacts(groupID: "read-ai-weekly").isEmpty)
        #expect(try store.loadMeetingArtifacts(groupID: "weekly").map(\.id) == ["read-ai-transcript"])

        // This is the exact title Read AI will keep supplying after the merge.
        #expect(try store.resolvedMeetingGroupID(matching: "Weekly Sync from Read AI") == "weekly")
    }

@Suite("Unreviewed consumed sources")
struct UnreviewedConsumedSourceTests {

    /// A source with extracted text, so it clears the "worth reviewing against" bar.
    private func makeConsumableSource(
        url: String,
        title: String,
        sourceType: StudioSourceType = .article
    ) -> StudioArticle {
        var article = StudioArticle(url: url, title: title, sourceType: sourceType)
        article.normalizedURL = URLNormalizer.normalize(url)
        article.content = String(repeating: "Body text worth reviewing. ", count: 20)
        return article
    }

    @Test("Only consumed sources are offered for a first review")
    func onlyConsumedSourcesQualify() throws {
        let store = try TestStores.inMemory()

        let untouched = makeConsumableSource(url: "https://example.com/untouched", title: "Untouched")
        let read = makeConsumableSource(url: "https://example.com/read", title: "Read")
        let skimmed = makeConsumableSource(url: "https://example.com/skimmed", title: "Skimmed")
        let studied = makeConsumableSource(url: "https://example.com/studied", title: "Studied")
        for article in [untouched, read, skimmed, studied] {
            try store.saveSource(article)
        }

        try store.updateSourceReadAt(sourceID: read.id, readAt: Date(timeIntervalSinceReferenceDate: 780_000_000))
        try store.updateSourceReadingLocator(
            sourceID: skimmed.id,
            locator: ArticleReadingPositionLocator(scrollFraction: 0.05).encoded
        )
        try store.updateSourceReadingPosition(sourceID: studied.id, page: 12)

        let candidates = try store.unreviewedConsumedSources()
        #expect(Set(candidates.map(\.sourceID)) == [read.id])
    }

    @Test("An already-reviewed source is not new, however it was reviewed")
    func reviewedSourcesAreExcluded() throws {
        let store = try TestStores.inMemory()
        let article = makeConsumableSource(url: "https://example.com/reviewed", title: "Reviewed")
        try store.saveSource(article)
        try store.updateSourceReadAt(sourceID: article.id, readAt: Date(timeIntervalSinceReferenceDate: 780_000_000))

        #expect(try store.unreviewedConsumedSources().map(\.sourceID) == [article.id])

        let sessionID = UUID().uuidString
        try store.createReviewSession(id: sessionID, topic: "Review", sourceIDs: [article.id])
        // An open session does not count — only a completed one retires the source
        // from the never-reviewed bucket.
        #expect(try store.unreviewedConsumedSources().map(\.sourceID) == [article.id])

        try store.completeReviewSession(sessionID: sessionID, overallScore: 0.8, summary: "Solid")
        #expect(try store.unreviewedConsumedSources().isEmpty)
    }

    @Test("Text-less sources never enter the bucket; hidden ones do, because hiding is visual only")
    func ineligibleSourcesAreExcluded() throws {
        let store = try TestStores.inMemory()
        let readAt = Date(timeIntervalSinceReferenceDate: 780_000_000)

        let hidden = makeConsumableSource(url: "https://example.com/hidden", title: "Hidden")
        var empty = makeConsumableSource(url: "https://example.com/empty", title: "No text")
        empty.content = nil
        let visible = makeConsumableSource(url: "https://example.com/visible", title: "Visible")
        for article in [hidden, empty, visible] {
            try store.saveSource(article)
            try store.updateSourceReadAt(sourceID: article.id, readAt: readAt)
        }
        try store.setSourceHidden(hidden.id, hidden: true)

        // A hidden source left the sources list, not the learner's knowledge
        // (product owner, 2026-09-11), so it is still offered for its first review.
        #expect(Set(try store.unreviewedConsumedSources().map(\.sourceID)) == [hidden.id, visible.id])
    }

    @Test("Restricting to a Notebook's sources scopes the bucket")
    func restrictScopesResults() throws {
        let store = try TestStores.inMemory()
        let readAt = Date(timeIntervalSinceReferenceDate: 780_000_000)

        let inNotebook = makeConsumableSource(url: "https://example.com/in", title: "In notebook")
        let outsideNotebook = makeConsumableSource(url: "https://example.com/out", title: "Outside")
        for article in [inNotebook, outsideNotebook] {
            try store.saveSource(article)
            try store.updateSourceReadAt(sourceID: article.id, readAt: readAt)
        }

        let scoped = try store.unreviewedConsumedSources(restrictToSourceIDs: [inNotebook.id])
        #expect(scoped.map(\.sourceID) == [inNotebook.id])
    }

    @Test("An unheard podcast episode is not offered; a completed one is")
    func podcastsNeedAnExplicitReadMark() throws {
        let store = try TestStores.inMemory()
        let unheard = makeConsumableSource(
            url: "https://example.com/ep-1",
            title: "Episode 1",
            sourceType: .podcast
        )
        let heard = makeConsumableSource(
            url: "https://example.com/ep-2",
            title: "Episode 2",
            sourceType: .podcast
        )
        try store.saveSource(unheard)
        try store.saveSource(heard)
        try store.updateSourceReadAt(sourceID: heard.id, readAt: Date(timeIntervalSinceReferenceDate: 780_000_000))

        #expect(try store.unreviewedConsumedSources().map(\.sourceID) == [heard.id])
    }

    // MARK: - Measured depth

    @Test("A mostly-played episode is offered even though nothing marked it read")
    func substantialListeningQualifiesWithoutReadAt() throws {
        let store = try TestStores.inMemory()
        let abandoned = makeConsumableSource(
            url: "https://example.com/ep-abandoned",
            title: "Abandoned after the intro",
            sourceType: .podcast
        )
        let mostlyPlayed = makeConsumableSource(
            url: "https://example.com/ep-mostly",
            title: "Played nearly to the end",
            sourceType: .podcast
        )
        try store.saveSource(abandoned)
        try store.saveSource(mostlyPlayed)

        let day = Date(timeIntervalSinceReferenceDate: 780_000_000)
        _ = try store.recordScheduledSourceActivity(
            sourceID: abandoned.id,
            on: day,
            kind: .listening,
            fraction: 0.14
        )
        _ = try store.recordScheduledSourceActivity(
            sourceID: mostlyPlayed.id,
            on: day,
            kind: .listening,
            fraction: 0.78
        )

        // Neither ever reached read_at; only measured depth separates them.
        let offered = try store.unreviewedConsumedSources()
        #expect(offered.map(\.sourceID) == [mostlyPlayed.id])
        // Dated by when it was actually listened to, never by date_added — an
        // auto-ingested backlog must not look consumed the day it was imported.
        #expect(offered.first?.consumedAt == day)
    }

    @Test("Depth keeps the furthest point reached, not the latest sample")
    func depthMergesWithMax() throws {
        let store = try TestStores.inMemory()
        let episode = makeConsumableSource(
            url: "https://example.com/ep-merge",
            title: "Merged depth",
            sourceType: .podcast
        )
        try store.saveSource(episode)
        let day = Date(timeIntervalSinceReferenceDate: 780_000_000)

        for fraction in [0.2, 0.65, 0.4] {
            _ = try store.recordScheduledSourceActivity(
                sourceID: episode.id,
                on: day,
                kind: .listening,
                fraction: fraction
            )
        }

        let days = try store.loadSourceActivityDays(sourceID: episode.id)
        #expect(days.count == 1)
        // Scrubbing back to 0.4 must not retract the 0.65 already reached.
        #expect(days[0].maxFraction == 0.65)
        #expect(try store.unreviewedConsumedSources().map(\.sourceID) == [episode.id])
    }

    @Test("Finishing a source records full depth whatever sampling last saw")
    func completionRecordsFullDepth() throws {
        let store = try TestStores.inMemory()
        let episode = makeConsumableSource(
            url: "https://example.com/ep-complete",
            title: "Completed",
            sourceType: .podcast
        )
        try store.saveSource(episode)
        let day = Date(timeIntervalSinceReferenceDate: 780_000_000)

        _ = try store.recordScheduledSourceActivity(
            sourceID: episode.id,
            on: day,
            kind: .listening,
            fraction: 0.42
        )
        try store.recordScheduledSourceCompletion(
            sourceID: episode.id,
            on: day,
            kind: .listening
        )

        let days = try store.loadSourceActivityDays(sourceID: episode.id)
        #expect(days[0].completedKinds == [.listening])
        #expect(days[0].maxFraction == 1)
        #expect(days[0].effectiveFraction == 1)
    }

    @Test("External chapter range completion is atomic and records listening for every chapter")
    func externalChapterCompletionIsAtomic() throws {
        let store = try TestStores.inMemory()
        let chapters = (1...4).map { number in
            makeConsumableSource(
                url: "https://example.com/book/chapter-\(number)",
                title: "Chapter \(number)",
                sourceType: .book
            )
        }
        for chapter in chapters { try store.saveSource(chapter) }
        let day = Date(timeIntervalSinceReferenceDate: 780_500_000)

        try store.recordScheduledSourceCompletions(
            sourceIDs: chapters.map(\.id),
            on: day,
            kind: .listening
        )

        let schedule = try store.loadScheduledSources()
        #expect(schedule.count == 4)
        #expect(Set(schedule.map(\.placement.sourceID)) == Set(chapters.map(\.id)))
        #expect(schedule.allSatisfy { $0.placement.completedAt != nil && $0.isAutomatic })
        #expect(schedule.allSatisfy {
            $0.activityDays.count == 1
                && $0.activityDays[0].completedKinds == [.listening]
                && $0.activityDays[0].maxFraction == 1
        })
        #expect(try store.loadSources().allSatisfy { $0.readAt == day })

        let rollbackStore = try TestStores.inMemory()
        try rollbackStore.saveSource(chapters[0])
        #expect(throws: (any Error).self) {
            try rollbackStore.recordScheduledSourceCompletions(
                sourceIDs: [chapters[0].id, "missing-source"],
                on: day,
                kind: .listening
            )
        }
        #expect(try rollbackStore.loadScheduledSources().isEmpty)
        #expect(try rollbackStore.loadSources().first?.readAt == nil)
    }

    @Test("Merely opening a source still proves nothing")
    func openingWithoutDepthIsNotConsumption() throws {
        let store = try TestStores.inMemory()
        let opened = makeConsumableSource(url: "https://example.com/opened", title: "Opened")
        try store.saveSource(opened)

        // The reader logs activity on open; with no measured depth that must
        // stay exactly as weak a signal as it was before v66.
        _ = try store.recordScheduledSourceActivity(
            sourceID: opened.id,
            on: Date(timeIntervalSinceReferenceDate: 780_000_000),
            kind: .reading
        )

        let days = try store.loadSourceActivityDays(sourceID: opened.id)
        #expect(days[0].kinds == [.reading])
        #expect(days[0].hasMeasuredDepth == false)
        #expect(try store.unreviewedConsumedSources().isEmpty)
    }
}

/// Bulk activity history for the scale regression, written straight to SQLite so
/// the fixture cost stays out of the measured upgrade.
