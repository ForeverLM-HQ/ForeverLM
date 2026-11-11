// Source persistence tests: source type changes, podcasts, book metadata, imports and archiving.

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

extension SourcePersistenceTests {
    @Test("updateSourceType migrates article to paper and queues source sync")
    func updateSourceTypeMigratesArticleToPaperAndQueuesSourceSync() throws {
        let store = try TestStores.inMemory()
        var article = makeArticle(url: "https://example.com/research-note", title: "Research Note")
        article.author = "Ada Lovelace"

        try store.saveSource(article)

        try store.updateSourceType(article.id, to: StudioSourceType.paper.rawValue)

        let saved = try #require(try store.loadSources().first(where: { $0.id == article.id }))

        #expect(saved.sourceType == .paper)
        #expect(saved.url == article.url)
        #expect(saved.title == "Research Note")
        #expect(saved.author == "Ada Lovelace")
    }

    @Test("Paywall status persists and queues source sync")
    func paywallStatusPersistsAndQueuesSourceSync() throws {
        let store = try TestStores.inMemory()
        var paper = StudioArticle(
            url: "https://www.nature.com/articles/example",
            title: "Paywalled Paper",
            sourceType: .paper
        )

        try store.saveSource(paper)

        paper.state = .error
        paper.errorMessage = "paywall"
        paper.isPaywalled = true
        try store.saveSource(paper)

        let saved = try #require(try store.loadSources().first(where: { $0.id == paper.id }))

        #expect(saved.sourceType == .paper)
        #expect(saved.state == .error)
        #expect(saved.errorMessage == "paywall")
        #expect(saved.isPaywalled)
    }

    @Test("A paywall suspicion persists with the paper, queues sync, and clears when written back nil")
    func paywallSuspicionPersistsAndClears() throws {
        let store = try TestStores.inMemory()
        var paper = StudioArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/12345678/",
            title: "Suspected Paper",
            sourceType: .paper
        )
        try store.saveSource(paper)
        #expect(try #require(try store.loadSources().first(where: { $0.id == paper.id })).paywallSuspicion == nil)

        paper.paywallSuspicion = "Abstract-only page; the only full-text link says Get Access."
        try store.saveSource(paper)
        let saved = try #require(try store.loadSources().first(where: { $0.id == paper.id }))
        #expect(saved.paywallSuspicion == "Abstract-only page; the only full-text link says Get Access.")
        #expect(!saved.isPaywalled, "a suspicion is not a marker")
        #expect(saved.state == .queued, "the paper stays in the attention list")

        paper.paywallSuspicion = nil
        paper.isPaywalled = true
        try store.saveSource(paper)
        let marked = try #require(try store.loadSources().first(where: { $0.id == paper.id }))
        #expect(marked.paywallSuspicion == nil)
        #expect(marked.isPaywalled)
    }

    @Test("Remote paper keeps original URL when local PDF is attached")
    func remotePaperKeepsOriginalURLWhenLocalPDFAttached() throws {
        let store = try TestStores.inMemory()
        let remoteURL = "https://www.nature.com/articles/35016601"
        var paper = StudioArticle(
            url: remoteURL,
            title: "Limitations of serial cloning in mammals",
            sourceType: .paper
        )

        try store.saveSource(paper)

        paper.localFilePath = "Papers/10.1038_35016601.pdf"
        paper.domain = "Local PDF"
        paper.author = "Teruhiko Wakayama et al."
        paper.journal = "Nature"
        paper.publishedYear = "2000"
        paper.doi = "10.1038/35016601"
        installPreparedPaperText(on: &paper)
        let attested = paper.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        try store.saveSource(paper)

        let loaded = try store.loadSources()
        let saved = try #require(loaded.first(where: { $0.id == paper.id }))
        var rediscovered = StudioArticle(
            url: remoteURL,
            title: "Limitations of serial cloning in mammals",
            sourceType: .paper
        )
        rediscovered.doi = "10.1038/35016601"

        #expect(saved.url == remoteURL)
        #expect(saved.localFilePath?.hasSuffix("Papers/10.1038_35016601.pdf") == true)
        #expect(try store.insertSourceIfNew(&rediscovered) == false)
        #expect(try store.loadSources().count == 1)
    }

    @Test("Video cited papers are stored with their video")
    func videoCitedPapersAreQueuedForSync() throws {
        let store = try TestStores.inMemory()
        let video = makeArticle(url: "https://youtube.com/watch?v=cited", title: "Talk")
        try store.saveSource(video)

        let paper = VideoCitedPaper(
            sourceID: video.id,
            title: "Mitochondrial transplantation in vivo",
            doi: "10.1000/mito",
            slideTimeSeconds: 412
        )
        try store.saveVideoCitedPaper(paper)

        #expect(try store.loadVideoCitedPaper(id: paper.id)?.sourceID == video.id)
        #expect(try store.loadVideoCitedPapers(forSourceID: video.id).count == 1)
    }

    @Test("A linked source keeps its kind and context through the store")
    func linkedSourceCandidateRoundTrip() throws {
        let store = try TestStores.inMemory()
        let article = makeArticle(url: "https://example.substack.com/p/post", title: "A post")
        try store.saveSource(article)

        let linked = VideoCitedPaper(
            sourceID: article.id,
            title: "A talk on mitochondria",
            url: "https://www.youtube.com/watch?v=abc123",
            kind: .video,
            context: "Recommended as a primer."
        )
        try store.saveVideoCitedPaper(linked)

        let loaded = try store.loadVideoCitedPaper(id: linked.id)
        #expect(loaded?.kind == .video)
        #expect(loaded?.context == "Recommended as a primer.")
        #expect(loaded?.url == linked.url)
    }

    @Test("A hidden podcast show is stored by its name")
    func hiddenPodcastShowsAreQueuedForSync() throws {
        let store = try TestStores.inMemory()

        try store.setPodcastShowHidden("Example Show", hidden: true)

        #expect(try store.loadHiddenPodcastShows() == ["Example Show"])
    }

    @Test("Hidden podcast show marks matching episodes hidden")
    func hiddenPodcastShowMarksMatchingEpisodesHidden() throws {
        let store = try TestStores.inMemory()
        var podcast = StudioArticle(
            url: "apple-podcast://episode/1001",
            title: "Episode 1001",
            sourceType: .podcast
        )
        podcast.domain = "Example Show"

        try store.saveSource(podcast)
        try store.setPodcastShowHidden("Example Show", hidden: true)

        let hidden = try #require(store.loadSources().first(where: { $0.id == podcast.id }))
        #expect(hidden.isHidden == true)

        try store.setPodcastEpisodeVisibleOverride(podcast.id, visible: true)

        let visible = try #require(store.loadSources().first(where: { $0.id == podcast.id }))
        #expect(visible.isHidden == false)
    }

    @Test("Unhiding a show reveals the episodes hidden after it and keeps the ones hidden before")
    func unhidingAShowRevealsEpisodesHiddenAfterIt() throws {
        let store = try TestStores.inMemory()
        var chosen = StudioArticle(url: "apple-podcast://episode/2001", title: "Skipped on purpose", sourceType: .podcast)
        chosen.domain = "Example Show"
        var consequence = StudioArticle(url: "apple-podcast://episode/2002", title: "Hidden with the show", sourceType: .podcast)
        consequence.domain = "Example Show"
        var untouched = StudioArticle(url: "apple-podcast://episode/2003", title: "Never hidden itself", sourceType: .podcast)
        untouched.domain = "Example Show"
        for article in [chosen, consequence, untouched] { try store.saveSource(article) }

        // The learner hid one episode, then the whole show; another device then
        // mirrored the show's state onto an episode of its own accord.
        try store.setPodcastEpisodeHidden(chosen.id, hidden: true)
        usleep(5_000)
        try store.setPodcastShowHidden("Example Show", hidden: true)
        usleep(5_000)
        try store.setPodcastEpisodeHidden(consequence.id, hidden: true)

        let revealed = try store.setPodcastShowHidden("Example Show", hidden: false)

        #expect(revealed == [consequence.id])
        let hiddenIDs = try store.loadHiddenPodcastEpisodeIDs()
        #expect(hiddenIDs.contains(chosen.id))
        #expect(!hiddenIDs.contains(consequence.id))
        #expect(!hiddenIDs.contains(untouched.id))
        let sources = try store.loadSources()
        #expect(sources.first { $0.id == chosen.id }?.isHidden == true)
        #expect(sources.first { $0.id == consequence.id }?.isHidden == false)
        // The revealed episode's hidden record is withdrawn from sync too.
    }

    @Test("Private podcast dedup recognizes local UUID changes")
    func privatePodcastDedupRecognizesLocalUUIDChanges() throws {
        let store = try TestStores.inMemory()
        let playedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var first = StudioArticle(
            url: "apple-podcast://episode/local/first-local-id",
            title: "Private Feed Episode",
            sourceType: .podcast
        )
        first.domain = "Private Feed"
        first.dateAdded = playedAt

        try store.saveSource(first)

        var rediscovered = StudioArticle(
            url: "apple-podcast://episode/private/stable-feed-hash",
            title: first.title,
            sourceType: .podcast
        )
        rediscovered.domain = first.domain
        rediscovered.dateAdded = playedAt

        #expect(try store.insertSourceIfNew(&rediscovered) == false)
        #expect(try store.loadSources().count == 1)
    }

    @Test("Hidden YouTube channels hide videos and allow overrides")
    func hiddenYouTubeChannelVisibilityAndSync() throws {
        let store = try TestStores.inMemory()
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=hidden-channel",
            title: "Channel video",
            sourceType: .video
        )
        video.domain = "Example Channel"
        try store.saveSource(video)

        try store.setYouTubeChannelHidden("Example Channel", hidden: true)

        let hidden = try #require(store.loadSources().first(where: { $0.id == video.id }))
        #expect(hidden.isHidden)
        #expect(try store.loadHiddenYouTubeChannels() == ["Example Channel"])

        try store.setYouTubeVideoVisibleOverride(video.id, visible: true)
        let visible = try #require(store.loadSources().first(where: { $0.id == video.id }))
        #expect(!visible.isHidden)

        try store.setYouTubeChannelHidden("Example Channel", hidden: false)
        #expect(try store.loadHiddenYouTubeChannels().isEmpty)
    }

    @Test("Projection repair stays visible to concurrent library readers")
    func projectionRepairIsAtomicForConcurrentReaders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceProjectionAtomicRepairTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try KnowledgeStore(storeDirectory: root)
        let article = makeArticle(
            url: "https://example.com/projection-repair",
            title: "Projection Repair"
        )
        try writer.saveSource(article)

        // Open the second connection before making the definition stale, matching
        // the app's storage and CloudKit connections during startup.
        let reader = try KnowledgeStore(storeDirectory: root)
        let expected = KnowledgeStore.sourceProjectionViewSQL(
            sourceColumnNames: try writer.tableColumnNames("sources")
        )
        let stale = expected.replacingOccurrences(
            of: "CREATE VIEW source_projection AS",
            with: "CREATE VIEW source_projection AS\n            -- stale test definition"
        )
        try writer.execForTesting("BEGIN IMMEDIATE")
        try writer.execForTesting("DROP VIEW source_projection")
        try writer.execForTesting(stale)
        try writer.execForTesting("COMMIT")

        let didDrop = DispatchSemaphore(value: 0)
        let mayCreate = DispatchSemaphore(value: 0)
        let didFinish = DispatchSemaphore(value: 0)
        writer.afterSourceProjectionDropForTesting = {
            didDrop.signal()
            _ = mayCreate.wait(timeout: .now() + 5)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { didFinish.signal() }
            try? writer.reconcileSourceProjectionView()
        }

        let reachedDrop = didDrop.wait(timeout: .now() + 5)
        #expect(reachedDrop == .success)
        if reachedDrop == .success {
            // While the writer has dropped the view inside its uncommitted
            // transaction, another connection must still load the intact library.
            let visibleSources = try reader.loadSourcesWithoutContent()
            #expect(visibleSources.contains { $0.id == article.id })
        }

        mayCreate.signal()
        #expect(didFinish.wait(timeout: .now() + 5) == .success)

        let repairedSources = try reader.loadSourcesWithoutContent()
        #expect(repairedSources.contains { $0.id == article.id })
        var repairedDefinition: String?
        try reader.query("SELECT sql FROM sqlite_master WHERE type = 'view' AND name = 'source_projection'") { stmt in
            repairedDefinition = reader.string(stmt, 0)
        }
        #expect(
            repairedDefinition?.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        var rewroteHealthyView = false
        writer.afterSourceProjectionDropForTesting = {
            rewroteHealthyView = true
        }
        try writer.reconcileSourceProjectionView()
        #expect(!rewroteHealthyView)

        // A view left absent by an older build's interrupted non-transactional
        // repair is also restored without touching any source rows.
        writer.afterSourceProjectionDropForTesting = nil
        try writer.execForTesting("DROP VIEW source_projection")
        try writer.reconcileSourceProjectionView()
        #expect(try reader.loadSourcesWithoutContent().contains { $0.id == article.id })
    }

    @Test("A source filed into two groups still projects exactly one row")
    func sourceInTwoGroupsNotebooksOneRow() throws {
        let store = try TestStores.inMemory()
        let article = makeArticle(url: "https://example.com/two-groups", title: "Two Groups")
        try store.saveSource(article)

        // `group_members` is keyed `(source_id, group_id)`, so a second
        // membership is representable however it got written. It used to fan
        // `source_projection` out into two rows, and callers that key rows by
        // source id trap the process on the duplicate rather than degrade.
        try store.updateParentGroup(article.id, "aaa-group")
        try store.execForTesting(
            "INSERT INTO group_members (source_id, group_id) VALUES ('\(article.id)', 'zzz-group')"
        )

        var projectedRows = 0
        var projectedGroup: String?
        try store.query("SELECT parent_group FROM source_projection WHERE id = '\(article.id)'") { stmt in
            projectedRows += 1
            projectedGroup = store.string(stmt, 0)
        }
        #expect(projectedRows == 1)
        // The surviving membership is the lowest group id — deterministic, and
        // the row the `(source_id, group_id)` primary key already made SQLite
        // emit first, so a first-row-wins caller sees no folder move.
        #expect(projectedGroup == "aaa-group")

        #expect(try store.loadActiveSources().filter { $0.id == article.id }.count == 1)
    }

    @Test("Dismissing a source archives matching active source")
    func dismissingSourceArchivesMatchingActiveSource() throws {
        let store = try TestStores.inMemory()
        let article = makeArticle(url: "https://example.com/dismiss-me", title: "Dismiss Me")

        try store.saveSource(article)
        try store.dismissSource(url: article.url, title: article.title)

        let active = try store.loadActiveSources()
        let all = try store.loadSourcesWithoutContent()

        #expect(active.isEmpty)
        #expect(all.first?.status == .archived)
    }

    @Test("Book metadata keeps ID and title separate")
    func bookMetadataKeepsIDAndTitleSeparate() throws {
        let store = try TestStores.inMemory()
        let uuid = "91dd38ad-7356-5d08-b691-a44493dff38a"

        try store.saveBookMetadata(groupName: uuid, title: uuid, coverPath: "Books/Immune/cover.jpg")

        let books = try store.loadBooks()

        #expect(books.titles[uuid] == uuid)
        #expect(books.titles["Immune"] == nil)
    }

    @Test("Single book metadata save persists author")
    func singleBookMetadataSavePersistsAuthor() throws {
        let store = try TestStores.inMemory()
        let uuid = "91dd38ad-7356-5d08-b691-a44493dff38a"

        try store.saveBookMetadata(
            groupName: uuid,
            title: "Immune",
            subtitle: "A Journey into the Mysterious System That Keeps You Alive",
            author: "Philipp Dettmer",
            edition: "First Edition",
            coverPath: "Books/Immune/cover.jpg"
        )

        let books = try store.loadBooks()
        #expect(books.titles[uuid] == "Immune")
        #expect(books.subtitles[uuid] == "A Journey into the Mysterious System That Keeps You Alive")
        #expect(books.authors[uuid] == "Philipp Dettmer")
        #expect(books.editions[uuid] == "First Edition")
        #expect(try store.scalarText("SELECT cover_path FROM books WHERE id = ?", [.text(uuid)]) == "Books/Immune/cover.jpg")
    }

    @Test("Remote book payload applies to a book table with only the base columns")
    func remoteBookPayloadAppliesToBaseColumnBookTable() throws {
        let store = try TestStores.inMemory()
        let uuid = "2113A94E-BCC1-4670-9AAC-8E38EE9D7234"
        try store.execForTesting("DROP VIEW IF EXISTS source_projection")
        try store.execForTesting("DROP TABLE books")
        try store.execForTesting("""
            CREATE TABLE books (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                author TEXT,
                cover_path TEXT,
                kind TEXT
            )
        """)

        try store.saveBookRecord(
            CloudKitBookPayload(
                id: uuid,
                title: "An Introduction to Systems Biology",
                subtitle: "Design Principles of Biological Circuits",
                author: "Uri Alon",
                edition: "Second Edition",
                coverPath: "Books/SystemsBiology/cover.jpg"
            )
        )

        let books = try store.loadBooks()

        #expect(books.titles[uuid] == "An Introduction to Systems Biology")
        #expect(books.authors[uuid] == "Uri Alon")
        #expect(books.coverPaths[uuid]?.hasSuffix("Books/SystemsBiology/cover.jpg") == true)
        #expect(books.subtitles[uuid] == nil)
        #expect(books.editions[uuid] == nil)
    }

    @Test("A book record keeps the title it was written with")
    func remoteBookPayloadPreservesPayloadTitle() throws {
        let store = try TestStores.inMemory()
        let uuid = "91dd38ad-7356-5d08-b691-a44493dff38a"

        try store.saveBookRecord(
            CloudKitBookPayload(
                id: uuid,
                title: uuid,
                subtitle: "An Elegant Tour",
                author: "Philipp Dettmer",
                edition: "Second Edition",
                coverPath: "Books/Immune/cover.jpg"
            )
        )

        let books = try store.loadBooks()
        #expect(books.titles[uuid] == uuid)
        #expect(books.subtitles[uuid] == "An Elegant Tour")
        #expect(books.editions[uuid] == "Second Edition")
    }

    @Test("Book subtitle and edition round-trip through single-field saves")
    func bookSubtitleAndEditionRoundTripThroughFieldSaves() throws {
        let store = try TestStores.inMemory()
        let uuid = "91dd38ad-7356-5d08-b691-a44493dff38a"
        try store.saveBookMetadata(groupName: uuid, title: "Tidal Notes", coverPath: nil)

        try store.setBookField(.subtitle, of: uuid, to: "A Field Guide to the Shore")
        try store.setBookField(.author, of: uuid, to: "Zara Holt")
        try store.setBookField(.edition, of: uuid, to: "First Edition")

        let books = try store.loadBooks()

        #expect(books.titles[uuid] == "Tidal Notes")
        #expect(books.subtitles[uuid] == "A Field Guide to the Shore")
        #expect(books.authors[uuid] == "Zara Holt")
        #expect(books.editions[uuid] == "First Edition")
    }

    /// The regression the whole-table book save had: a book that arrived by
    /// sync before the view model reloaded was deleted, and the deletion
    /// synced, when the learner edited any other book.
    @Test("Editing one book's field leaves a book memory never loaded, and queues no deletion")
    func editingOneBookFieldLeavesOtherBooksAndQueuesNoDeletion() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveBookMetadata(groupName: "book-edited", title: "Tidal Notes", author: "Zara Holt", coverPath: nil, kind: "Field Guide")
        // Arrived by sync: in the database, not in any view model's memory.
        try store.saveBookRecord(
            CloudKitBookPayload(
                id: "book-synced",
                title: "Salt Marsh Ledger",
                subtitle: "Notes from Acme Lab",
                author: "Ines Varga",
                edition: "Second Edition",
                coverPath: nil
            )
        )

        try store.setBookField(.edition, of: "book-edited", to: "Third Edition")
        try store.setBookField(.kind, of: "book-edited", to: "")

        let books = try store.loadBooks()
        #expect(books.titles["book-synced"] == "Salt Marsh Ledger")
        #expect(books.subtitles["book-synced"] == "Notes from Acme Lab")
        #expect(books.authors["book-synced"] == "Ines Varga")
        #expect(books.editions["book-synced"] == "Second Edition")
        // The edited book changed only in the field written; a cleared field is nil.
        #expect(books.titles["book-edited"] == "Tidal Notes")
        #expect(books.authors["book-edited"] == "Zara Holt")
        #expect(books.editions["book-edited"] == "Third Edition")
        #expect(books.kinds["book-edited"] == nil)
    }

    @Test("Setting a field of a book with no row throws and writes nothing")
    func settingFieldOfMissingBookThrows() throws {
        let store = try KnowledgeStore(inMemory: true)

        #expect(throws: KnowledgeStoreError.self) {
            try store.setBookField(.author, of: "no-such-book", to: "Zara Holt")
        }
        #expect(try store.loadBooks().titles.isEmpty)
    }

    @Test("insertSourceIfNew skips existing active source")
    func testInsertSourceIfNewSkipsExistingActiveSource() throws {
        let store = try TestStores.inMemory()
        var article1 = makeArticle(url: "https://example.com/post-1", title: "Original Title")
        let inserted1 = try store.insertSourceIfNew(&article1)
        #expect(inserted1)

        var article2 = makeArticle(url: "https://example.com/post-1", title: "New Title")
        let inserted2 = try store.insertSourceIfNew(&article2)
        #expect(!inserted2)

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].title == "Original Title")
    }

    @Test("saving grouped source replaces stale group membership")
    func savingGroupedSourceReplacesStaleGroupMembership() throws {
        let store = try TestStores.inMemory()
        let oldGroup = "Immune"
        let newGroup = "91dd38ad-7356-5d08-b691-a44493dff38a"
        var chapter = StudioArticle(
            url: "Books/Immune/Chapters/01 What Is the Immune System?.pdf",
            title: "Immune - 1) What Is the Immune System?",
            sourceType: .book,
            localFilePath: "Books/Immune/Chapters/01 What Is the Immune System?.pdf"
        )

        chapter.parentGroup = oldGroup
        try store.saveSource(chapter)
        chapter.parentGroup = newGroup
        try store.saveSource(chapter)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active.first?.parentGroup == newGroup)
    }

    @Test("book chapter lookup finds archived source by local file path")
    func bookChapterLookupFindsArchivedSourceByLocalFilePath() throws {
        let store = try TestStores.inMemory()
        let relativePath = "Books/Test Book/Chapters/ForeverLMCombinedChapters/01 Introduction.xhtml"
        var chapter = StudioArticle(
            url: relativePath,
            title: "Introduction",
            sourceType: .book,
            localFilePath: relativePath
        )
        chapter.parentGroup = "book-test"
        try store.insertSourceIfNew(&chapter)
        try store.archiveSource(chapter.id)

        let absolutePath = "/Users/other/Library/Mobile Documents/iCloud~com~foreverlm/Documents/ForeverLM/\(relativePath)"
        #expect(store.sourceExistsByURL(absolutePath)?.id == chapter.id)
        #expect(store.sourceExistsByNormalizedURL(URLNormalizer.normalize(absolutePath))?.id == chapter.id)
        #expect(store.sourceExistsByBookLocalFilePath(absolutePath)?.id == chapter.id)
        #expect(store.sourceExistsByBookLocalFilePath(absolutePath)?.status == .archived)
    }

    @Test("a team's copy of a paper does not stand in for the learner's own row")
    func teamCopyDoesNotBlockOwnImport() throws {
        let store = try TestStores.inMemory()
        let url = "https://pmc.ncbi.nlm.nih.gov/articles/PMC2924931/"
        // A team's copy has a team-scoped id, as sharing makes it; a paper's own id is minted from its
        // address, so a copy left on that id would be the learner's own row.
        var teamCopy = StudioArticle(
            url: url, title: "Mitochondrial uncoupling and lifespan", sourceType: .paper,
            id: TeamContentIdentity.sourceID(teamID: "team-1", url: url)
        )
        teamCopy.teamID = "team-1"
        try store.insertSourceIfNew(&teamCopy)

        #expect(store.sourceExistsByURL(url) == nil)
        #expect(store.sourceExistsByNormalizedURL(URLNormalizer.normalize(url)) == nil)

        var own = StudioArticle(url: url, title: "Mitochondrial uncoupling and lifespan", sourceType: .paper)
        try store.insertSourceIfNew(&own)
        #expect(store.sourceExistsByURL(url)?.id == own.id)
        #expect(own.id != teamCopy.id)
    }

    @Test("Paper identity merge archives the duplicate and preserves relationships")
    func paperIdentityMergePreservesRelationships() throws {
        let store = try TestStores.inMemory()
        var canonical = StudioArticle(
            url: "https://www.nature.com/articles/s42255-024-01200-x",
            title: "Recommendations for mitochondria transfer and transplantation nomenclature and characterization",
            sourceType: .paper,
            id: "canonical-paper"
        )
        canonical.state = .queued
        canonical.doi = "10.1038/s42255-024-01200-x"
        var duplicate = StudioArticle(
            url: "/Users/other/Papers/10.1038_s42255-024-01200-x.pdf",
            title: canonical.title,
            sourceType: .paper,
            localFilePath: "Papers/10.1038_s42255-024-01200-x.pdf",
            id: "duplicate-paper"
        )
        duplicate.state = .queued
        duplicate.doi = canonical.doi
        try store.saveSource(canonical)
        try store.saveSource(duplicate)

        let goalID = "mitochondria-notebook"
        let now = Date(timeIntervalSinceReferenceDate: 100)
        try store.saveLearningGoalRecord(
            LearningGoalRecord(
                id: goalID,
                title: "Mitochondria",
                startAt: now,
                endAt: Date(timeIntervalSinceReferenceDate: 200),
                createdAt: now,
                updatedAt: now,
                status: LearningGoalStatus.active.rawValue,
                items: [
                    LearningGoalItem(
                        id: "canonical-item",
                        goalID: goalID,
                        sourceID: canonical.id,
                        addedAt: now,
                        reviewState: LearningGoalItemReviewState.rejected.rawValue
                    ),
                    LearningGoalItem(
                        id: "duplicate-item",
                        goalID: goalID,
                        sourceID: duplicate.id,
                        addedAt: now,
                        reviewState: LearningGoalItemReviewState.approved.rawValue
                    ),
                ],
                kind: "companion"
            )
        )
        try store.createReviewSession(
            id: "duplicate-review",
            topic: "Review",
            sourceIDs: [canonical.id, duplicate.id]
        )

        try store.archivePaperIdentityDuplicate(
            duplicate.id,
            replacingWith: canonical.id
        )

        #expect(try store.loadActiveSources().map(\.id) == [canonical.id])
        let storedDuplicate = try store.loadSources().first { $0.id == duplicate.id }
        #expect(storedDuplicate?.status == .archived)
        let goalItems = try store.loadLearningGoalItems(goalID: goalID)
        #expect(goalItems.count == 1)
        #expect(goalItems.first?.sourceID == canonical.id)
        #expect(goalItems.first?.reviewState == LearningGoalItemReviewState.approved.rawValue)
        #expect(try store.reviewSessionSourceIDsBySessionID()["duplicate-review"] == [canonical.id])
    }

    @Test("insertSourceIfNew skips archived source")
    func testInsertSourceIfNewSkipsArchivedSource() throws {
        let store = try TestStores.inMemory()
        var article = makeArticle(url: "https://example.com/post-1", title: "Original")
        try store.insertSourceIfNew(&article)

        try store.archiveSource(article.id)

        var fresh = makeArticle(url: "https://example.com/post-1", title: "Refreshed")
        let inserted = try store.insertSourceIfNew(&fresh)
        #expect(!inserted, "Archived sources should not be re-inserted")
    }

    @Test("archiveSource cascades to content")
    func testArchiveCascadesContent() throws {
        let store = try TestStores.inMemory()
        var article = makeArticle(url: "https://example.com/post-1", title: "Post")
        article.content = "Full text content of the article."
        try store.insertSourceIfNew(&article)

        // Verify content exists
        let contentBefore = try store.loadSourceContent(article.id)
        #expect(contentBefore != nil)

        try store.archiveSource(article.id)

        let contentAfter = try store.loadSourceContent(article.id)
        #expect(contentAfter == nil)
    }

    @Test("archiveSource does not delete other sources")
    func testArchiveDoesNotDeleteOtherSources() throws {
        let store = try TestStores.inMemory()
        var article1 = makeArticle(url: "https://example.com/post-1", title: "Post 1")
        var article2 = makeArticle(url: "https://example.com/post-2", title: "Post 2")
        try store.insertSourceIfNew(&article1)
        try store.insertSourceIfNew(&article2)

        try store.archiveSource(article1.id)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].title == "Post 2")

        // The archived source still exists in the DB
        let all = try store.loadSources()
        #expect(all.count == 2)
    }

    @Test("normalized URL prevents duplicates")
    func testNormalizedURLPreventsDuplicates() throws {
        let store = try TestStores.inMemory()
        // Two URLs that normalize to the same value (trailing slash difference)
        var article1 = makeArticle(url: "https://example.com/post", title: "Without Slash")
        var article2 = makeArticle(url: "https://example.com/post/", title: "With Slash")

        // Verify they normalize to the same thing
        #expect(article1.normalizedURL == article2.normalizedURL)

        let inserted1 = try store.insertSourceIfNew(&article1)
        let inserted2 = try store.insertSourceIfNew(&article2)
        #expect(inserted1)
        #expect(!inserted2)

        let all = try store.loadSources()
        #expect(all.count == 1)
    }

    @Test("YouTube URL variants do not create duplicate video sources")
    func youtubeURLVariantsDoNotCreateDuplicateVideoSources() throws {
        let store = try TestStores.inMemory()
        var original = StudioArticle(
            url: "https://youtu.be/abc123",
            title: "Original",
            sourceType: .video
        )
        var duplicate = StudioArticle(
            url: "https://www.youtube.com/watch?v=abc123&list=PL-course",
            title: "Playlist Variant",
            sourceType: .video
        )

        #expect(try store.insertSourceIfNew(&original))
        #expect(!(try store.insertSourceIfNew(&duplicate)))

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].id == original.id)
    }

    @Test("YouTube video title is preserved before persistence")
    func youtubeVideoTitleIsPreservedBeforePersistence() throws {
        let store = try TestStores.inMemory()
        var article = StudioArticle(
            url: "https://www.youtube.com/watch?v=abc123",
            title: "My Lecture - YouTube",
            sourceType: .video
        )

        #expect(try store.insertSourceIfNew(&article))
        #expect(article.title == "My Lecture - YouTube")

        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].title == "My Lecture - YouTube")
    }

    @Test("loadActiveSources excludes archived")
    func testLoadActiveSourcesExcludesArchived() throws {
        let store = try TestStores.inMemory()
        var article1 = makeArticle(url: "https://example.com/post-1", title: "Post 1")
        var article2 = makeArticle(url: "https://example.com/post-2", title: "Post 2")
        try store.insertSourceIfNew(&article1)
        try store.insertSourceIfNew(&article2)

        try store.archiveSource(article1.id)

        let active = try store.loadActiveSources()
        #expect(active.count == 1)
        #expect(active[0].title == "Post 2")
    }
}
