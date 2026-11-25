// The transcript caching, source context, paper download and Studio state tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

@Suite("YouTube Transcript Caching")
@MainActor
struct YouTubeTranscriptCachingTests {

    @Test("opening a YouTube source treats blank content as a missing transcript")
    func blankContentAutomaticallyFetchesOnOpen() {
        var video = makeArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Blank synced video",
            sourceType: .video,
            state: .ready
        )
        video.content = " \n\t "

        #expect(!StudioViewModel.sourceHasReadableContent(video))
        #expect(StudioViewModel.shouldAutomaticallyFetchYouTubeTranscriptOnOpen(video))

        video.content = "[0:00] Transcript text"
        #expect(StudioViewModel.sourceHasReadableContent(video))
        #expect(!StudioViewModel.shouldAutomaticallyFetchYouTubeTranscriptOnOpen(video))
    }

    @Test("opening a failed YouTube source waits for an explicit retry")
    func failedTranscriptDoesNotRetryOnEveryOpen() {
        var video = makeArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Unavailable video",
            sourceType: .video,
            state: .error
        )
        video.content = ""
        video.errorMessage = "YouTube transcript unavailable."

        #expect(!StudioViewModel.shouldAutomaticallyFetchYouTubeTranscriptOnOpen(video))
    }

    @Test("a failed YouTube transcript fetch is stored, so a reload shows the error and not the queue")
    func failedTranscriptFetchIsPersisted() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMYouTubeFailureTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let service = StorageService(storeRoot: tmp)

        // A watch URL with no video id fails before any network request, so
        // the fetch takes the same failure path as a video without captions.
        let video = makeArticle(
            url: "https://www.youtube.com/watch",
            title: "Video without captions",
            sourceType: .video,
            state: .queued
        )
        try await service.saveSource(video)

        let vm = StudioViewModel(storageService: service)
        vm.articles = try await service.loadSources()

        await vm.fetchYouTubeTranscript(for: video.id)

        #expect(vm.articles[0].state == .error)
        #expect(vm.articles[0].errorMessage?.hasPrefix("YouTube transcript unavailable") == true)

        let reloaded = try await service.loadSources()
        #expect(reloaded.count == 1)
        #expect(reloaded[0].state == .error)
        #expect(reloaded[0].errorMessage?.hasPrefix("YouTube transcript unavailable") == true)
    }

    @Test("fetchYouTubeTranscript reuses persisted transcript from SQLite")
    func reusesPersistedTranscript() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMYouTubeCacheTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)

        let stored = makeArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Cached Video",
            sourceType: .video,
            state: .ready
        )
        var persisted = stored
        persisted.content = "cached transcript text"
        persisted.wordCount = 3
        try await service.saveSource(persisted)

        let vm = StudioViewModel(storageService: service)
        vm.articles = try await service.loadSources()
        #expect(vm.articles.count == 1)
        #expect(vm.articles[0].content == nil)

        await vm.fetchYouTubeTranscript(for: stored.id)

        #expect(vm.articles[0].content == "cached transcript text")
        #expect(vm.articles[0].wordCount == 3)
        #expect(vm.articles[0].state == .ready)
        #expect(vm.articles[0].errorMessage == nil)
    }

    @Test("a failed reformat keeps the transcript that was already stored")
    func failedReformatKeepsStoredTranscript() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMReformatTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)

        // A video ID that resolves to nothing, so the forced re-download fails
        // whether or not this machine is online.
        let stored = makeArticle(
            url: "https://www.youtube.com/watch?v=zzzzzzzzzzz",
            title: "Raw Captions",
            sourceType: .video,
            state: .ready
        )
        var persisted = stored
        persisted.content = "unformatted caption text"
        persisted.wordCount = 3
        try await service.saveSource(persisted)

        let vm = StudioViewModel(storageService: service)
        vm.articles = try await service.loadSources()

        await vm.reformatYouTubeTranscript(for: stored.id)

        #expect(vm.articles[0].content == "unformatted caption text")
        #expect(vm.articles[0].state == .ready)
        #expect(vm.articles[0].errorMessage == nil)
        let onDisk = await service.loadSourceContent(stored.id)
        #expect(onDisk == "unformatted caption text")
    }

    @Test("reformat ignores sources that are not YouTube videos")
    func reformatIgnoresNonYouTubeSources() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMReformatSkipTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)

        var article = makeArticle(url: "https://example.com/post", title: "Article", state: .ready)
        article.content = "body text"
        vm.articles = [article]

        await vm.reformatYouTubeTranscript(for: article.id)

        #expect(vm.articles[0].content == "body text")
        #expect(vm.articles[0].state == .ready)
    }

    @Test("fetchContent reuses persisted source content from SQLite before network fetch")
    func fetchContentUsesPersistedSourceContent() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("StudioVMContentCacheTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)

        let stored = makeArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "Cached Video",
            sourceType: .video,
            state: .queued
        )
        var persisted = stored
        persisted.content = "sqlite cached transcript"
        persisted.wordCount = 3
        try await service.saveSource(persisted)

        let vm = StudioViewModel(storageService: service)
        vm.articles = try await service.loadSources()
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .queued)

        await vm.fetchContent(for: stored.id)

        #expect(vm.articles[0].content == "sqlite cached transcript")
        #expect(vm.articles[0].wordCount == 3)
        #expect(vm.articles[0].state == .ready)
        #expect(vm.articles[0].errorMessage == nil)
    }
}

// MARK: - Source Context Management

@Suite("Source Context Management")
@MainActor
struct SourceContextManagementTests {

    @Test("addSourceToContext adds article ID")
    func addSourceToContext() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.addSourceToContext(a.id)
        #expect(vm.contextSourceIds.contains(a.id))
    }

    @Test("a family kept from AI refuses ambient adds but not one the learner names")
    func keptFamilyTakesExplicitAdd() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        let before = vm.excludedKnowledgeTabs
        defer { vm.excludedKnowledgeTabs = before }
        guard let tab = StudioSidebarTab.knowledgeTab(for: a) else { return }
        vm.excludedKnowledgeTabs = [tab]

        vm.addSourceToContext(a.id)
        #expect(!vm.contextSourceIds.contains(a.id))
        vm.addSourcesToContext([a.id])
        #expect(!vm.contextSourceIds.contains(a.id))

        vm.addSourceToContext(a.id, explicit: true)
        #expect(vm.contextSourceIds.contains(a.id))
    }

    @Test("a source named in a chat opens by id even when its family is kept from AI")
    func namedSourceOpensDespiteKeptFamily() {
        let id = "named-\(UUID().uuidString)"
        let excluded: Set<String> = [id]
        #expect(KnowledgeStore.isBlockedFromOpening(id, excluded: excluded))
        ChatNamedSources.shared.grant([id])
        #expect(!KnowledgeStore.isBlockedFromOpening(id, excluded: excluded))
        ChatNamedSources.shared.revoke(id)
        #expect(KnowledgeStore.isBlockedFromOpening(id, excluded: excluded))
    }

    @Test("addSourceToContext does not duplicate")
    func addSourceNoDuplicate() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.addSourceToContext(a.id)
        vm.addSourceToContext(a.id)
        #expect(vm.contextSourceIds.filter { $0 == a.id }.count == 1)
    }

    @Test("removeSourceFromContext removes article ID")
    func removeSourceFromContext() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.contextSourceIds = [a.id]
        vm.removeSourceFromContext(a.id)
        #expect(!vm.contextSourceIds.contains(a.id))
    }

    @Test("clearSourceContext empties the array")
    func clearSourceContext() {
        let vm = makeViewModel()
        vm.contextSourceIds = ["a", "b", "c"]
        vm.clearSourceContext()
        #expect(vm.contextSourceIds.isEmpty)
    }

    @Test("contextSourceArticles resolves articles from IDs")
    func contextSourceArticles() {
        let vm = makeViewModel()
        let a1 = makeArticle(url: "https://1.com", title: "One")
        let a2 = makeArticle(url: "https://2.com", title: "Two")
        vm.articles = [a1, a2]
        vm.contextSourceIds = [a1.id, a2.id]
        let resolved = vm.contextSourceArticles
        #expect(resolved.count == 2)
        #expect(resolved[0].id == a1.id)
        #expect(resolved[1].id == a2.id)
    }

    @Test("contextSourceArticles ignores IDs not in articles")
    func contextSourceArticlesIgnoresInvalid() {
        let vm = makeViewModel()
        let a = makeArticle()
        vm.articles = [a]
        vm.contextSourceIds = [a.id, "nonexistent-id"]
        #expect(vm.contextSourceArticles.count == 1)
    }

    @Test("selected source IDs follow current display order")
    func selectedSourceIDsFollowCurrentDisplayOrder() {
        let vm = makeViewModel()
        let chapter8 = makeArticle(
            url: "Books/Test/Chapters/08.pdf",
            title: "8) Why Mitochondria Make Complexity Possible",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 8
        )
        let chapter7 = makeArticle(
            url: "Books/Test/Chapters/07.pdf",
            title: "7) Why Bacteria are Simple",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 7
        )
        let part3 = makeArticle(
            url: "Books/Test/Chapters/part-3.pdf",
            title: "Part 3 Insider Deal: The Foundations of Complexity",
            sourceType: .book,
            parentGroup: "book",
            sortIndex: 6
        )
        vm.articles = [chapter8, chapter7, part3]
        vm.sidebarTab = .books

        let ordered = vm.sourceIDsInCurrentDisplayOrder(Set([chapter8.id, chapter7.id, part3.id]))

        #expect(ordered == [part3.id, chapter7.id, chapter8.id])
    }

    @Test("addSourceToContext does not auto-fetch remote paper PDFs")
    func addRemotePaperToContextStaysPassive() {
        let vm = makeViewModel()
        let paper = makeArticle(url: "https://www.nature.com/articles/test-paper", title: "Nature paper", sourceType: .paper)
        vm.articles = [paper]

        vm.addSourceToContext(paper.id)

        #expect(vm.contextSourceIds.contains(paper.id))
        #expect(vm.articles[0].state == .queued)
        #expect(vm.articles[0].content == nil)
    }
}

@Suite("Paper Download Behavior")
@MainActor
struct PaperDownloadBehaviorTests {

    @Test("fetchContent does not auto-download remote paper PDFs")
    func fetchContentLeavesRemotePaperQueued() async {
        let vm = makeViewModel()
        let paper = makeArticle(url: "https://www.nature.com/articles/test-paper", title: "Nature paper", sourceType: .paper)
        vm.articles = [paper]

        await vm.fetchContent(for: paper.id)

        #expect(vm.articles[0].state == .queued)
        #expect(vm.articles[0].content == nil)
        #expect(vm.paperDownloadStep.isEmpty)
    }

    @Test("selectArticle does not auto-download remote paper PDFs")
    func selectArticleLeavesRemotePaperQueued() async {
        let vm = makeViewModel()
        let paper = makeArticle(url: "https://www.nature.com/articles/test-paper", title: "Nature paper", sourceType: .paper)
        vm.articles = [paper]

        await vm.selectArticle(paper.id)

        #expect(vm.selectedArticleId == paper.id)
        #expect(vm.contextSourceIds.isEmpty)
        #expect(vm.articles[0].state == .queued)
        #expect(vm.articles[0].content == nil)
    }

    @Test("processing local paper opens its original PDF without waiting for cleanup")
    func selectProcessingPaperOpensOriginalPDF() async throws {
        let pdfURL = try makeTempPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let vm = makeViewModel()
        var paper = makeArticle(
            url: pdfURL.path,
            title: "Paper being cleaned",
            sourceType: .paper,
            state: .fetching
        )
        paper.localFilePath = pdfURL.path
        vm.articles = [paper]
        vm.pendingPaperProcessingIds.insert(paper.id)
        vm.showReaderPanel = false

        await vm.selectArticle(paper.id)

        #expect(vm.selectedArticleId == paper.id)
        #expect(vm.showReaderPanel)
        #expect(vm.activeCenterTabs.contains(.reader))
        #expect(vm.selectedArticle?.isPDF == true)
        #expect(vm.selectedArticle?.localFilePath == pdfURL.path)
        #expect(vm.pendingPaperProcessingIds.contains(paper.id))
        #expect(vm.articles[0].state == .fetching)
    }

    @Test("selectArticle leaves existing context unchanged by default")
    func selectArticleLeavesContextUnchanged() async {
        let vm = makeViewModel()
        let first = makeArticle(url: "https://example.com/first", title: "First")
        // Content on the row keeps selectArticle from fetching
        // https://example.com for real: this test is about where the
        // selection lands, not about fetching.
        let second = makeArticle(url: "https://example.com/second", title: "Second").with(content: "Second, already read.")
        vm.articles = [first, second]
        vm.addSourceToContext(first.id)

        await vm.selectArticle(second.id)

        #expect(vm.selectedArticleId == second.id)
        #expect(vm.contextSourceIds == [first.id])
    }

    @Test("selectArticle issues a fresh reader navigation when reselecting the same source")
    func selectArticleRefreshesReaderNavigationOnReselection() async {
        let vm = makeViewModel()
        var article = makeArticle(url: "https://example.com/article", title: "Article")
        article.content = "Already loaded content"
        vm.articles = [article]

        #expect(vm.readerNavigationRevision(for: article.id) == 0)

        await vm.selectArticle(article.id)
        let firstRevision = vm.readerNavigationRevision(for: article.id)

        await vm.selectArticle(article.id)

        #expect(firstRevision == 1)
        #expect(vm.readerNavigationRevision(for: article.id) == 2)
        #expect(vm.selectedArticleId == article.id)
    }

    @Test("selectArticle can replace context when requested explicitly")
    func selectArticleExplicitlyReplacesContext() async {
        let vm = makeViewModel()
        let first = makeArticle(url: "https://example.com/first", title: "First")
        let second = makeArticle(url: "https://example.com/second", title: "Second").with(content: "Second, already read.")
        vm.articles = [first, second]
        vm.addSourceToContext(first.id)

        await vm.selectArticle(second.id, updateContext: true)

        #expect(vm.selectedArticleId == second.id)
        #expect(vm.contextSourceIds == [second.id])
    }

    @Test("paper download result carries metadata completeness")
    func paperDownloadResultCarriesMetadataCompleteness() {
        let result = StudioViewModel.PaperDownloadResult(
            success: true,
            lastError: nil,
            metadataComplete: false,
            debugLog: ["downloaded"]
        )

        #expect(result.success)
        #expect(result.metadataComplete == false)
    }
}

// MARK: - Chat Messages

// MARK: - Source Type and Metadata

@Suite("Source Type and Metadata")
@MainActor
struct SourceTypeMetadataTests {

    @Test("Moving a source between tabs via sourceType change")
    func moveSourceBetweenTabs() {
        let vm = makeViewModel()
        let article = makeArticle(url: "https://example.com/post", title: "A Post", sourceType: .article)
        vm.articles = [article]

        // Initially on articles tab
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.count == 1)
        vm.sidebarTab = .papers
        #expect(vm.activeTabArticles.count == 0)

        // Change source type to paper
        if let idx = vm.articles.firstIndex(where: { $0.id == article.id }) {
            vm.articles[idx].sourceType = .paper
        }

        vm.sidebarTab = .papers
        #expect(vm.activeTabArticles.count == 1)
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.count == 0)
    }

    @Test("Paper metadata fields")
    func paperMetadataFields() {
        var article = makeArticle(url: "https://nature.com/article", sourceType: .paper)
        #expect(article.author == nil)
        #expect(article.journal == nil)
        #expect(article.publishedYear == nil)

        article.author = "Smith et al."
        article.journal = "Nature"
        article.publishedYear = "2024"

        #expect(article.author == "Smith et al.")
        #expect(article.journal == "Nature")
        #expect(article.publishedYear == "2024")
    }

    @Test("Manual sourceType appears under articles tab")
    func manualSourceTypeUnderArticles() {
        let vm = makeViewModel()
        let a = makeArticle(sourceType: .manual)
        vm.articles = [a]
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.count == 1)
    }

    @Test("Podcast sourceType appears under podcasts tab")
    func podcastSourceType() {
        let vm = makeViewModel()
        let a = makeArticle(url: "https://pod.com/ep1", sourceType: .podcast)
        vm.articles = [a]
        vm.sidebarTab = .podcasts
        #expect(vm.activeTabArticles.count == 1)
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.count == 0)
    }

    @Test("Book sourceType appears under books tab")
    func bookSourceType() {
        let vm = makeViewModel()
        let a = makeArticle(url: "/path/to/chapter.pdf", sourceType: .book)
        vm.articles = [a]
        vm.sidebarTab = .books
        #expect(vm.activeTabArticles.count == 1)
    }
}

// MARK: - Search State

@Suite("Search State")
@MainActor
struct SearchStateTests {

    @Test("sourceSearchQuery default is empty")
    func sourceSearchQueryDefault() {
        let vm = makeViewModel()
        #expect(vm.sourceSearchQuery == "")
    }

    @Test("sourceSearchQuery can be set")
    func sourceSearchQuerySet() {
        let vm = makeViewModel()
        vm.sourceSearchQuery = "transformers"
        #expect(vm.sourceSearchQuery == "transformers")
    }

    @Test("sourceSearchResults default is empty")
    func sourceSearchResultsDefault() {
        let vm = makeViewModel()
        #expect(vm.sourceSearchResults.isEmpty)
    }

    @Test("hasSearchedSources default is false")
    func hasSearchedSourcesDefault() {
        let vm = makeViewModel()
        #expect(!vm.hasSearchedSources)
    }

    @Test("isSearchingSources default is false")
    func isSearchingSourcesDefault() {
        let vm = makeViewModel()
        #expect(!vm.isSearchingSources)
    }

    @Test("isSearchingSources can be toggled")
    func isSearchingSourcesToggle() {
        let vm = makeViewModel()
        vm.isSearchingSources = true
        #expect(vm.isSearchingSources)
        vm.isSearchingSources = false
        #expect(!vm.isSearchingSources)
    }
}

// MARK: - Panel Visibility

@Suite("Panel Visibility")
@MainActor
struct PanelVisibilityTests {

    @Test("reader starts docked and closed until a source is opened")
    func readerStartsDockedAndClosed() async {
        let vm = makeViewModel()
        #expect(!vm.showReaderPanel)
        #expect(!vm.readerPoppedOut)

        await vm.selectArticle("any-source-id")
        #expect(vm.showReaderPanel)
    }

    @Test("showReaderPanel toggle")
    func showReaderPanelToggle() {
        let vm = makeViewModel()
        let original = vm.showReaderPanel
        vm.showReaderPanel = !original
        #expect(vm.showReaderPanel == !original)
    }

    @Test("showSearchPanel toggle")
    func showSearchPanelToggle() {
        let vm = makeViewModel()
        let original = vm.showSearchPanel
        vm.showSearchPanel = !original
        #expect(vm.showSearchPanel == !original)
    }

    @Test("readerPoppedOut flag")
    func readerPoppedOut() {
        let vm = makeViewModel()
        vm.readerPoppedOut = true
        #expect(vm.readerPoppedOut)
        vm.readerPoppedOut = false
        #expect(!vm.readerPoppedOut)
    }

}

// MARK: - Derived State

@Suite("Derived State")
@MainActor
struct DerivedStateTests {

    @Test("selectedArticle resolves from selectedArticleId")
    func selectedArticleResolves() {
        let vm = makeViewModel()
        let a = makeArticle(url: "https://sel.com", title: "Selected")
        vm.articles = [a]
        vm.selectedArticleId = a.id
        #expect(vm.selectedArticle?.title == "Selected")
    }

    @Test("selectedArticle is nil when no ID set")
    func selectedArticleNilNoId() {
        let vm = makeViewModel()
        vm.selectedArticleId = nil
        #expect(vm.selectedArticle == nil)
    }

    @Test("totalFilteredCount matches filtered items")
    func totalFilteredCount() {
        let vm = makeViewModel()
        var arts: [StudioArticle] = []
        for i in 0..<25 {
            arts.append(makeArticle(url: "https://example.com/\(i)", title: "Art \(i)", sourceType: .article))
        }
        vm.articles = arts
        vm.sidebarTab = .articles
        #expect(vm.totalFilteredCount == 25)
    }

    @Test("tabItemLabel returns lowercase tab name")
    func tabItemLabel() {
        let vm = makeViewModel()
        vm.sidebarTab = .articles
        #expect(vm.tabItemLabel == "articles")
        vm.sidebarTab = .papers
        #expect(vm.tabItemLabel == "papers")
    }

    @Test("tabItemLabel preserves brand casing")
    func tabItemLabelBrandCasing() {
        let vm = makeViewModel()
        vm.sidebarTab = .videos
        #expect(vm.tabItemLabel == "videos from YouTube")
        vm.sidebarTab = .xPosts
        #expect(vm.tabItemLabel == "X posts")
    }

    @Test("resumeBookChapter opens the first chapter when nothing has been read")
    func resumeBookChapterStartsAtFirstChapter() {
        let vm = makeViewModel()
        let ch1 = makeArticle(url: "/books/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "My Book", sortIndex: 1)
        let ch2 = makeArticle(url: "/books/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "My Book", sortIndex: 2)
        vm.articles = [ch1, ch2]

        #expect(vm.resumeBookChapter(for: "My Book")?.id == ch1.id)
    }

    @Test("resumeBookChapter opens the furthest chapter with saved progress")
    func resumeBookChapterUsesSavedProgress() {
        let vm = makeViewModel()
        var ch1 = makeArticle(url: "/books/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "My Book", sortIndex: 1)
        let ch2 = makeArticle(url: "/books/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "My Book", sortIndex: 2)
        var ch3 = makeArticle(url: "/books/ch3.pdf", title: "Chapter 3", sourceType: .book, parentGroup: "My Book", sortIndex: 3)
        ch1.readingPositionPage = 12
        ch3.readingPositionPage = 4
        vm.articles = [ch1, ch2, ch3]
        vm.seedReadingProgressFromArticles()

        #expect(vm.resumeBookChapter(for: "My Book")?.id == ch3.id)
    }

    @Test("resumeBookChapter prefers in-memory reading progress over stale article state")
    func resumeBookChapterUsesReadingProgressStore() {
        let vm = makeViewModel()
        let ch1 = makeArticle(url: "/books/ch1.pdf", title: "Chapter 1", sourceType: .book, parentGroup: "My Book", sortIndex: 1)
        let ch2 = makeArticle(url: "/books/ch2.pdf", title: "Chapter 2", sourceType: .book, parentGroup: "My Book", sortIndex: 2)
        vm.articles = [ch1, ch2]
        vm.updateReadingPosition(for: ch2.id, page: 7)

        #expect(vm.resumeBookChapter(for: "My Book")?.id == ch2.id)
        #expect(vm.resumeBookChapter(for: "My Book")?.readingPositionPage == 7)
    }
}

// MARK: - Error and Loading State

@Suite("Error and Loading State")
@MainActor
struct ErrorLoadingStateTests {

    @Test("errorMessage can be set and cleared")
    func errorMessage() {
        let vm = makeViewModel()
        #expect(vm.errorMessage == nil)
        vm.errorMessage = "Something went wrong"
        #expect(vm.errorMessage == "Something went wrong")
        vm.errorMessage = nil
        #expect(vm.errorMessage == nil)
    }

    @Test("isLoadingQueue defaults to false")
    func isLoadingQueueDefault() {
        let vm = makeViewModel()
        #expect(!vm.isLoadingQueue)
    }

    @Test("isGenerating defaults to false")
    func isGeneratingDefault() {
        let vm = makeViewModel()
        #expect(!vm.isGenerating)
    }

    @Test("isFetchingContent defaults to false")
    func isFetchingContentDefault() {
        let vm = makeViewModel()
        #expect(!vm.isFetchingContent)
    }

    @Test("missing paper PDF resolver defaults to idle")
    func missingPaperPDFResolverDefault() {
        let vm = makeViewModel()
        #expect(!vm.isResolvingMissingPaperPDFs)
    }

    @Test("missing paper PDF resolver stays idle without candidates")
    func missingPaperPDFResolverNoCandidates() {
        let vm = makeViewModel()
        vm.downloadMissingPaperPDFs()

        #expect(!vm.isResolvingMissingPaperPDFs)
        #expect(vm.toastMessage == "No papers need PDF attention")
    }

    @Test("stopping a paper batch does nothing when none is running")
    func stopPaperPDFResolutionWhenIdle() {
        let vm = makeViewModel()
        vm.stopPaperPDFResolution()

        #expect(!vm.isStoppingPaperPDFResolution)
    }

    @Test("a cancelled paywall recheck skips its remaining papers")
    func paywallRecheckStopsBeforeNextPaper() async {
        let vm = makeViewModel()
        // Stand in for a batch that is already running: the loop checks the stop
        // flag before each paper, so a pass started here does no paper work.
        vm.isResolvingMissingPaperPDFs = true
        vm.paperPDFResolutionKind = .paywallRecheck
        vm.stopPaperPDFResolution()
        #expect(vm.isStoppingPaperPDFResolution)

        await vm.runPaywalledPaperRecheck(for: ["paper-1", "paper-2"])

        #expect(vm.toastMessage?.contains("stopped after 0 of 2 papers") == true)
        #expect(!vm.isResolvingMissingPaperPDFs)
        #expect(vm.paperPDFResolutionKind == nil)
        #expect(!vm.isStoppingPaperPDFResolution)
        #expect(vm.paperDownloadStep.isEmpty)
    }

    @Test("toastMessage can be set")
    func toastMessage() {
        let vm = makeViewModel()
        #expect(vm.toastMessage == nil)
        vm.toastMessage = "PDF downloaded"
        #expect(vm.toastMessage == "PDF downloaded")
    }

    @Test("A short confirmation keeps the original three seconds")
    func shortToastKeepsFloor() {
        #expect(StudioViewModel.toastDuration(for: "Copied source ID") == .seconds(3))
    }

    /// The case that prompted the dwell change: a provider refusal names the model
    /// and the setting to change, and three seconds is not long enough to find the
    /// second sentence, let alone act on it.
    @Test("A provider refusal stays up long enough to read")
    func errorToastStaysReadable() {
        let message = """
        Couldn't read slides: deepseek/deepseek-v4-flash can't read images, and slides \
        are read from the image itself.

        Pick a vision-capable model under Settings → AI Models → Background → \
        Advanced → Slide Citation Extraction.

        The provider said: No endpoints found that support image input
        """
        #expect(StudioViewModel.toastDuration(for: message) > .seconds(12))
    }

    @Test("Dwell is capped so nothing sits on screen indefinitely")
    func longToastIsCapped() {
        let message = String(repeating: "diagnostic detail ", count: 200)
        #expect(StudioViewModel.toastDuration(for: message) == .seconds(20))
    }

    @Test("Dismissing clears the message")
    func dismissToastClearsMessage() {
        let vm = makeViewModel()
        vm.showToast("Something went wrong")
        #expect(vm.toastMessage == "Something went wrong")

        vm.dismissToast()
        #expect(vm.toastMessage == nil)
    }

    @Test("Every notice waits in the bell's Recent list, newest first, Undo offered once")
    func noticesGoToTheBell() async {
        let vm = makeViewModel()
        var undone = 0
        vm.showToast("Added to Library")
        vm.showToast("Hid Paper", undo: { undone += 1 })
        #expect(vm.recentNotices.map(\.message) == ["Hid Paper", "Added to Library"])
        #expect(vm.unreadNoticeCount == 2)

        vm.markNoticesRead()
        #expect(vm.unreadNoticeCount == 0)

        let hid = vm.recentNotices[0].id
        await vm.undoNotice(hid)
        await vm.undoNotice(hid)
        #expect(undone == 1, "Undo runs once")
        #expect(vm.recentNotices.first(where: { $0.id == hid })?.undo == nil)

        for index in 0..<(StudioViewModel.recentNoticeLimit + 5) { vm.showToast("Notice \(index)") }
        #expect(vm.recentNotices.count == StudioViewModel.recentNoticeLimit)

        vm.clearNotices()
        #expect(vm.recentNotices.isEmpty)
        #expect(vm.toastMessage == nil)
    }

    @Test("A plain toast offers no Undo, and dismissing drops a pending one")
    func toastUndoFollowsTheMessage() async {
        let vm = makeViewModel()
        vm.showToast("Link copied")
        #expect(vm.toastUndo == nil)
        await vm.undoToast()
        #expect(vm.toastMessage == "Link copied", "Undo with nothing to undo leaves the toast alone")

        var undone = false
        vm.showToast("Hid Paper", undo: { undone = true })
        #expect(vm.toastUndo != nil)
        vm.dismissToast()
        #expect(vm.toastUndo == nil)
        await vm.undoToast()
        #expect(!undone, "A dismissed toast's Undo is gone with it")

        vm.showToast("Hid Paper", undo: { undone = true })
        await vm.undoToast()
        #expect(undone)
        #expect(vm.toastMessage == nil)
    }

    /// Three seconds reads "Hid <title>" but leaves no time to regret it.
    @Test("A toast offering Undo stays up at least six seconds")
    func undoableToastDwellsLonger() {
        #expect(StudioViewModel.toastDuration(for: "Hid Paper") == .seconds(3))
        #expect(StudioViewModel.toastDuration(for: "Hid Paper", undoable: true) == .seconds(6))
        let long = String(repeating: "diagnostic detail ", count: 200)
        #expect(StudioViewModel.toastDuration(for: long, undoable: true) == .seconds(20))
    }

    /// A toast the pointer is resting on must not vanish mid-sentence, so hovering
    /// cancels the pending dismissal outright rather than shortening it.
    @Test("Hovering holds the toast open")
    func hoverHoldsToastOpen() {
        let vm = makeViewModel()
        vm.showToast("Something went wrong")

        vm.setToastHovered(true)
        #expect(vm.toastDismissTask == nil)
        #expect(vm.toastMessage == "Something went wrong")

        vm.setToastHovered(false)
        #expect(vm.toastDismissTask != nil)
    }
}

// MARK: - URL Input

@Suite("URL Input")
@MainActor
struct URLInputTests {

    @Test("urlInput defaults to empty")
    func urlInputDefault() {
        let vm = makeViewModel()
        #expect(vm.urlInput == "")
    }

    @Test("urlInput can be set")
    func urlInputSet() {
        let vm = makeViewModel()
        vm.urlInput = "https://new-article.com"
        #expect(vm.urlInput == "https://new-article.com")
    }
}

// MARK: - Source Type Conversion

@Suite("Source Type Conversion")
@MainActor
struct SourceTypeConversionTests {
    @Test("Changing sourceType updates article in array")
    func changeSourceType() async {
        let vm = makeViewModel()
        var article = StudioArticle(url: "https://example.com/post", title: "A Post", sourceType: .article)
        article.normalizedURL = URLNormalizer.normalize(article.url)
        vm.articles = [article]

        vm.moveArticle(id:article.id, to: .paper)
        #expect(vm.articles[0].sourceType == .paper)
    }

    @Test("Changing sourceType to paper shows under papers tab")
    func convertedPaperInPapersTab() async {
        let vm = makeViewModel()
        var article = StudioArticle(url: "https://example.com/post", title: "A Post", sourceType: .article)
        article.normalizedURL = URLNormalizer.normalize(article.url)
        vm.articles = [article]

        vm.moveArticle(id:article.id, to: .paper)
        vm.sidebarTab = .papers
        #expect(vm.activeTabArticles.contains(where: { $0.id == article.id }))
    }

    @Test("Changing sourceType to article shows under articles tab")
    func convertedArticleInArticlesTab() async {
        let vm = makeViewModel()
        var paper = StudioArticle(url: "https://example.com/paper", title: "A Paper", sourceType: .paper)
        paper.normalizedURL = URLNormalizer.normalize(paper.url)
        vm.articles = [paper]

        vm.moveArticle(id:paper.id, to: .article)
        vm.sidebarTab = .articles
        #expect(vm.activeTabArticles.contains(where: { $0.id == paper.id }))
    }
}

@Suite("Initial content fetch")
struct InitialContentFetchTests {

    private func queuedArticle(id: String = "a1", url: String = "https://example.com/a") -> StudioArticle {
        var article = StudioArticle(url: url, title: "An article", sourceType: .article, id: id)
        article.state = .queued
        return article
    }

    /// The gap this exists to close: a source nobody opened was never fetched,
    /// never embedded, and so invisible to search and the assistant while still
    /// sitting in the library looking like part of the knowledge base.
    @Test("a queued web source with no content is picked up")
    func queuedWebSourceIsCandidate() {
        #expect(StudioViewModel.sourceNeedsInitialContentFetch(queuedArticle(), alreadyAttempted: []))
    }

    @Test("a source that already has content or has been fetched is left alone")
    func fetchedSourcesAreNotCandidates() {
        var ready = queuedArticle()
        ready.state = .ready
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(ready, alreadyAttempted: []))

        var withContent = queuedArticle()
        withContent.content = "already here"
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(withContent, alreadyAttempted: []))

        // A failed fetch sets .error, which drops it from the candidate set for
        // good rather than retrying forever.
        var failed = queuedArticle()
        failed.state = .error
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(failed, alreadyAttempted: []))
    }

    @Test("a Figshare source failed by the old empty WAF response is repaired")
    func failedFigshareSourceIsCandidate() {
        var failed = queuedArticle(
            id: "figshare",
            url: "https://plus.figshare.com/collections/Human_Biofluid_Image_Inventory/8260588/1"
        )
        failed.title = "plus.figshare.com"
        failed.state = .error

        #expect(StudioViewModel.sourceNeedsInitialContentFetch(failed, alreadyAttempted: []))
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(failed, alreadyAttempted: ["figshare"]))
    }

    /// Papers have their own sweep, which understands PDF resolution, paywalls,
    /// and duplicate detection. The generic content path understands none of
    /// that, so it must not race it.
    @Test("papers are left to their own sweep")
    func papersAreExcluded() {
        var paper = queuedArticle(id: "p1", url: "https://example.com/p.pdf")
        paper.sourceType = .paper
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(paper, alreadyAttempted: []))
    }

    @Test("remote course PDFs are proactively fetched as course materials")
    func coursePDFsAreCandidates() {
        var material = queuedArticle(
            id: "assignment",
            url: "https://example.com/assignment.pdf"
        )
        material.sourceType = .course
        #expect(StudioViewModel.sourceNeedsInitialContentFetch(material, alreadyAttempted: []))
    }

    @Test("local documents have nothing to fetch")
    func localDocumentsAreExcluded() {
        let local = queuedArticle(id: "l1", url: "/Users/someone/Documents/note.md")
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(local, alreadyAttempted: []))
    }

    /// The per-session guard is what keeps a source that fails or hangs from
    /// being retried on every sweep for the rest of the session.
    @Test("a source already attempted this session is not retried")
    func attemptedSourcesAreSkipped() {
        let article = queuedArticle()
        #expect(!StudioViewModel.sourceNeedsInitialContentFetch(article, alreadyAttempted: ["a1"]))
    }
}

@Suite("Paper metadata ingestion candidates")
struct PaperMetadataIngestionCandidateTests {
    @Test("Paper content without an LLM attestation is queued for metadata extraction")
    func unattestedPaperContentIsCandidate() {
        var paper = StudioArticle(
            url: "https://example.com/paper",
            title: "A Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026",
            id: "paper-candidate"
        )
        paper.content = "The first page of the scholarly paper, including its abstract."

        #expect(
            StudioViewModel.paperNeedsAutoMetadataExtraction(
                paper,
                alreadyAttempted: []
            )
        )
        #expect(
            !StudioViewModel.paperNeedsAutoMetadataExtraction(
                paper,
                alreadyAttempted: [paper.id]
            )
        )

        let attested = paper.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        #expect(
            !StudioViewModel.paperNeedsAutoMetadataExtraction(
                paper,
                alreadyAttempted: []
            )
        )
    }

    @Test("A title without paper content cannot enter the LLM ingestion queue")
    func titleAloneIsNotPaperContent() {
        let paper = StudioArticle(
            url: "https://example.com/paper",
            title: "A Very Informative Paper Title",
            sourceType: .paper,
            id: "title-only-paper"
        )

        #expect(
            !StudioViewModel.paperNeedsAutoMetadataExtraction(
                paper,
                alreadyAttempted: []
            )
        )
    }
}
