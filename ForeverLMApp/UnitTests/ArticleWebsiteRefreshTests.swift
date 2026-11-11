import Foundation
import Testing
@testable import ForeverLM

@Suite("Article Website Refresh")
struct ArticleWebsiteRefreshTests {
    @Test("Offers refresh only for HTTP article identities")
    func refreshEligibility() {
        for type in [StudioSourceType.article, .manual, .unclassified] {
            let article = StudioArticle(
                url: "https://example.com/member-post",
                title: "Member post",
                sourceType: type
            )
            #expect(StudioViewModel.canRefreshArticleFromWebsite(article))
        }

        let paper = StudioArticle(
            url: "https://example.com/paper",
            title: "Paper",
            sourceType: .paper
        )
        let xPost = StudioArticle(
            url: "https://x.com/example/status/123",
            title: "Post",
            sourceType: .xPost
        )
        let local = StudioArticle(
            url: "/tmp/article.html",
            title: "Local article",
            sourceType: .article
        )
        let directPDF = StudioArticle(
            url: "https://example.com/paper.pdf",
            title: "PDF",
            sourceType: .unclassified
        )

        #expect(!StudioViewModel.canRefreshArticleFromWebsite(paper))
        #expect(!StudioViewModel.canRefreshArticleFromWebsite(xPost))
        #expect(!StudioViewModel.canRefreshArticleFromWebsite(local))
        #expect(!StudioViewModel.canRefreshArticleFromWebsite(directPDF))
    }

    @Test("Keeps the saved article when the website returns the same preview")
    func unchangedPreviewIsNotReplaced() {
        let text = "The public preview contains the opening paragraph."
        #expect(StudioViewModel.articleWebsiteRefreshDecision(
            saved: ArticleRefreshSavedCopy(text: text, stagedRaw: "Header\n\(text)"),
            refreshedRaw: "Header\n\(text)",
            refreshedText: "\n\(text)\n"
        ) == .unchanged)
    }

    @Test("Keeps the saved article when a refresh is shorter")
    func shorterCaptureIsNotReplaced() {
        #expect(StudioViewModel.articleWebsiteRefreshDecision(
            saved: ArticleRefreshSavedCopy(text: "one two three four five six", stagedRaw: nil),
            refreshedRaw: "one two three and a long footer of site chrome",
            refreshedText: "one two three"
        ) == .shorterThanSavedCopy(savedWords: 6, refreshedWords: 3))
    }

    @Test("Accepts a fuller authenticated capture")
    func fullerCaptureReplacesPreview() {
        #expect(StudioViewModel.articleWebsiteRefreshDecision(
            saved: ArticleRefreshSavedCopy(text: "one two three", stagedRaw: nil),
            refreshedRaw: "one two three four five six",
            refreshedText: "one two three four five six"
        ) == .replace)
    }

    @Test("With nothing saved there is nothing to lose")
    func nothingSavedIsReplaced() {
        for saved in [
            ArticleRefreshSavedCopy(text: nil, stagedRaw: nil),
            ArticleRefreshSavedCopy(text: "  \n", stagedRaw: ""),
        ] {
            #expect(StudioViewModel.articleWebsiteRefreshDecision(
                saved: saved,
                refreshedRaw: "one",
                refreshedText: "one"
            ) == .replace)
        }
    }

    @Test("An article cleanup has not finished is measured raw against raw")
    func stagedExtractionIsMeasuredRawAgainstRaw() {
        let saved = ArticleRefreshSavedCopy(text: nil, stagedRaw: "one two three four five six")
        // A preview: its extraction is shorter than the one waiting for cleanup.
        #expect(StudioViewModel.articleWebsiteRefreshDecision(
            saved: saved,
            refreshedRaw: "one two three",
            refreshedText: "one two three"
        ) == .shorterThanSavedCopy(savedWords: 6, refreshedWords: 3))
        // The same page: cleanup trimmed it, which is no reason to refuse it.
        #expect(StudioViewModel.articleWebsiteRefreshDecision(
            saved: saved,
            refreshedRaw: "one two three four five six",
            refreshedText: "one two"
        ) == .replace)
    }

    @Test("The same extraction as the staged one still gives the article its text")
    func stagedExtractionEqualToCaptureIsInstalled() {
        let raw = "one two three four five six"
        #expect(StudioViewModel.articleWebsiteRefreshDecision(
            saved: ArticleRefreshSavedCopy(text: nil, stagedRaw: raw),
            refreshedRaw: raw,
            refreshedText: "one two three four"
        ) == .replace)
    }

    @Test("Canonical text, not the extraction behind it, is what a refresh may not shrink")
    func canonicalTextIsTheMeasure() {
        #expect(StudioViewModel.articleWebsiteRefreshDecision(
            saved: ArticleRefreshSavedCopy(
                text: "one two three",
                stagedRaw: "one two three and ten more words of menus and footers here"
            ),
            refreshedRaw: "one two three four five",
            refreshedText: "one two three four"
        ) == .replace)
    }

    @Test("Each outcome's toast")
    func outcomeToasts() {
        #expect(ArticleWebsiteRefreshOutcome.refreshed(savedWords: 120, words: 4_000, archivedPage: true).toast
            == "Article refreshed: 120 → 4000 words")
        #expect(ArticleWebsiteRefreshOutcome.refreshed(savedWords: 0, words: 4_000, archivedPage: false).toast
            == "Article refreshed: 4000 words")
        #expect(ArticleWebsiteRefreshOutcome.keptSavedCopy(savedWords: 4_000, fetchedWords: 120).toast
            == "The website returned less text, so the saved article was kept.")
        #expect(ArticleWebsiteRefreshOutcome.securityCheck.toast?.contains("bot check") == true)
        #expect(ArticleWebsiteRefreshOutcome.failed(.cleanup, reason: "The model timed out").toast
            == "Couldn’t refresh article: The model timed out")
        #expect(ArticleWebsiteRefreshOutcome.alreadyRunning.toast == nil)
        #expect(ArticleWebsiteRefreshOutcome.notRefreshable.toast == nil)
        #expect(ArticleWebsiteRefreshOutcome.notInLibrary.toast == nil)
    }

    @Test("A page with no text says so rather than naming archive.ph")
    func emptyPageReason() {
        #expect(StudioViewModel.articleWebsiteRefreshFailureReason(SourceError.insufficientContent)
            == "the page held no article text")
        #expect(StudioViewModel.articleWebsiteRefreshFailureReason(SourceError.fetchFailed)
            == SourceError.fetchFailed.localizedDescription)
    }
}

// MARK: - A whole refresh against a store of its own

/// How many times a stand-in step ran.
private actor StepCalls {
    private(set) var captures = 0
    private(set) var cleanups = 0
    func captured() { captures += 1 }
    func cleaned() { cleanups += 1 }
}

private struct StandInCleanupFailure: LocalizedError {
    var errorDescription: String? { "The cleanup model timed out" }
}

private func words(_ count: Int, _ stem: String = "word") -> String {
    (1...count).map { "\(stem)\($0)" }.joined(separator: " ")
}

private func preparation(raw: String, clean: String) -> PaperContentPreparationMetadata {
    PaperContentPreparationMetadata(
        cleanerVersion: PaperContentPreparationMetadata.currentVersion,
        rawSHA256: PaperContentPreparationService.sha256(raw),
        cleanSHA256: PaperContentPreparationService.sha256(clean),
        preparedAt: Date()
    )
}

/// The capture reads `page` (titled `pageTitle`) through no browser at all,
/// and the cleanup returns `clean(raw)` without a model.
private func standInWork(
    page: String,
    pageTitle: String? = "The Essay",
    calls: StepCalls,
    clean: @escaping @Sendable (String) throws -> String = { $0 }
) -> ArticleWebsiteRefreshWork {
    ArticleWebsiteRefreshWork(
        capture: { url, sourceID in
            await calls.captured()
            return SourceService.StagedArticleRefresh(
                textOnly: SourceService.ArchivedArticle(
                    plainText: page,
                    localHTMLPath: nil,
                    pageTitle: pageTitle,
                    pageAuthor: nil
                ),
                url: url,
                sourceID: sourceID
            )
        },
        clean: { _, raw, _ in
            await calls.cleaned()
            let text = try clean(raw)
            return PreparedPaperContent(raw: raw, clean: text, metadata: preparation(raw: raw, clean: text))
        }
    )
}

@MainActor
private func makeRefreshViewModel() -> (StudioViewModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArticleWebsiteRefresh_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false), root)
}

/// An article holding `text` as its canonical text, saved and loaded the way
/// the library holds one. `paywalledWithError` gives it the paywall marker and
/// an error, as a saved preview has.
@MainActor
private func seedReadyArticle(
    text: String,
    paywalledWithError: Bool = false,
    in vm: StudioViewModel
) async throws -> StudioArticle {
    var article = StudioArticle(
        url: "https://example.com/essays/\(UUID().uuidString)",
        title: "The Essay",
        sourceType: .article
    )
    let raw = "The Essay\n\n\(text)\n\nSubscribe to our newsletter"
    article.installPreparedArticleContent(raw: raw, clean: text, metadata: preparation(raw: raw, clean: text))
    article.state = .ready
    if paywalledWithError {
        article.state = .error
        article.errorMessage = "Access denied (paywall or bot protection)"
        article.isPaywalled = true
    }
    try await vm.storage.saveSource(article)
    article.discardPersistedArticleContentHandoff()
    vm.articles.append(article)
    return article
}

/// An article whose Source Content Cleanup failed at ingestion: its
/// extraction staged, no canonical text, and the row still counting the
/// extraction's words.
@MainActor
private func seedArticleWhoseCleanupFailed(raw: String, in vm: StudioViewModel) async throws -> StudioArticle {
    var article = StudioArticle(
        url: "https://example.com/essays/\(UUID().uuidString)",
        title: "The Essay",
        sourceType: .article
    )
    article.wordCount = 900
    article.state = .error
    article.errorMessage = "Article ingestion failed during Source Content Cleanup: The model timed out"
    article.stageArticleContentCleanup(raw: raw)
    try await vm.storage.saveSource(article)
    article.discardPersistedArticleContentHandoff()
    vm.articles.append(article)
    return article
}

@Suite("Article Website Refresh run")
@MainActor
struct ArticleWebsiteRefreshRunTests {
    @Test("A bot check page never reaches storage, and nothing is cleaned")
    func botCheckIsRefused() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = words(40)
        let article = try await seedReadyArticle(text: saved, in: vm)
        let calls = StepCalls()

        let outcome = await vm.refreshArticleFromWebsiteOutcome(article.id, work: standInWork(
            page: "www.example.com needs to review the security of your connection before proceeding. Verify you are human by completing the action below.",
            pageTitle: "Just a moment...",
            calls: calls
        ))

        #expect(outcome == .securityCheck)
        #expect(await calls.cleanups == 0)
        let stored = try await vm.storage.savedArticleCopy(article.id)
        #expect(stored.text == saved)
        #expect(!vm.contentFetchInFlight.contains(article.id))
    }

    @Test("A shorter capture keeps the saved article and its extraction")
    func shorterCaptureIsKept() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = words(40)
        let article = try await seedReadyArticle(text: saved, in: vm)
        let before = try await vm.storage.savedArticleCopy(article.id)

        let outcome = await vm.refreshArticleFromWebsiteOutcome(
            article.id,
            work: standInWork(page: words(10), calls: StepCalls())
        )

        #expect(outcome == .keptSavedCopy(savedWords: 40, fetchedWords: 10))
        #expect(try await vm.storage.savedArticleCopy(article.id) == before)
        #expect(vm.articles.first?.content == saved)
    }

    @Test("A failed cleanup leaves the saved article's text and state as they were")
    func failedCleanupKeepsSavedArticle() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = words(40)
        let article = try await seedReadyArticle(text: saved, in: vm)
        let before = try await vm.storage.savedArticleCopy(article.id)

        let outcome = await vm.refreshArticleFromWebsiteOutcome(article.id, work: standInWork(
            page: words(60),
            calls: StepCalls(),
            clean: { _ in throw StandInCleanupFailure() }
        ))

        #expect(outcome == .failed(.cleanup, reason: "The cleanup model timed out"))
        #expect(try await vm.storage.savedArticleCopy(article.id) == before)
        let row = try #require(try await vm.storage.loadSourceWithoutContent(article.id))
        #expect(row.state == .ready)
        #expect(row.errorMessage == nil)
    }

    @Test("A fuller capture replaces a saved preview and clears its error and paywall marker")
    func fullerCaptureReplaces() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let article = try await seedReadyArticle(text: words(10), paywalledWithError: true, in: vm)
        let full = words(40)

        let outcome = await vm.refreshArticleFromWebsiteOutcome(
            article.id,
            work: standInWork(page: full, calls: StepCalls())
        )

        #expect(outcome == .refreshed(savedWords: 10, words: 40, archivedPage: false))
        #expect(try await vm.storage.savedArticleCopy(article.id) == ArticleRefreshSavedCopy(text: full, stagedRaw: full))
        let row = try #require(try await vm.storage.loadSourceWithoutContent(article.id))
        #expect(row.state == .ready)
        #expect(row.errorMessage == nil)
        #expect(!row.isPaywalled)
        #expect(vm.articles.first?.content == full)
    }

    @Test("The same text again writes nothing")
    func sameTextIsUnchanged() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = words(40)
        let article = try await seedReadyArticle(text: saved, in: vm)
        let before = try await vm.storage.savedArticleCopy(article.id)

        let outcome = await vm.refreshArticleFromWebsiteOutcome(
            article.id,
            work: standInWork(page: "Menu\n\(saved)", calls: StepCalls(), clean: { _ in saved })
        )

        #expect(outcome == .unchanged(words: 40))
        #expect(try await vm.storage.savedArticleCopy(article.id) == before)
    }

    @Test("An article whose cleanup failed is refreshed although its row still counts the old words")
    func failedIngestionIsRefreshed() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = words(50)
        let article = try await seedArticleWhoseCleanupFailed(raw: raw, in: vm)
        let clean = words(45)

        let outcome = await vm.refreshArticleFromWebsiteOutcome(
            article.id,
            work: standInWork(page: raw, calls: StepCalls(), clean: { _ in clean })
        )

        #expect(outcome == .refreshed(savedWords: 0, words: 45, archivedPage: false))
        #expect(try await vm.storage.savedArticleCopy(article.id).text == clean)
        let row = try #require(try await vm.storage.loadSourceWithoutContent(article.id))
        #expect(row.state == .ready)
    }

    @Test("A preview never replaces the extraction an unfinished cleanup is waiting on")
    func stagedExtractionIsKept() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = words(50)
        let article = try await seedArticleWhoseCleanupFailed(raw: raw, in: vm)

        let outcome = await vm.refreshArticleFromWebsiteOutcome(
            article.id,
            work: standInWork(page: words(10), calls: StepCalls())
        )

        #expect(outcome == .keptSavedCopy(savedWords: 50, fetchedWords: 10))
        #expect(try await vm.storage.savedArticleCopy(article.id) == ArticleRefreshSavedCopy(text: nil, stagedRaw: raw))
        let row = try #require(try await vm.storage.loadSourceWithoutContent(article.id))
        #expect(row.state == .error)
    }

    @Test("A source already being fetched is not captured again")
    func runningFetchIsLeftAlone() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let article = try await seedReadyArticle(text: words(40), in: vm)
        let calls = StepCalls()
        vm.contentFetchInFlight.insert(article.id)

        let outcome = await vm.refreshArticleFromWebsiteOutcome(
            article.id,
            work: standInWork(page: words(80), calls: calls)
        )

        #expect(outcome == .alreadyRunning)
        #expect(await calls.captures == 0)
    }

    @Test("A source the loaded library has not caught up with is refreshed from storage; an archived one is not")
    func sourceNotLoadedYet() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let unloaded = try await seedReadyArticle(text: words(10), in: vm)
        let archived = try await seedReadyArticle(text: words(10), in: vm)
        try await vm.storage.archiveSource(archived.id)
        vm.articles = []

        let refreshed = await vm.refreshArticleFromWebsiteOutcome(
            unloaded.id,
            work: standInWork(page: words(40), calls: StepCalls())
        )
        let calls = StepCalls()
        let refused = await vm.refreshArticleFromWebsiteOutcome(
            archived.id,
            work: standInWork(page: words(40), calls: calls)
        )

        #expect(refreshed == .refreshed(savedWords: 10, words: 40, archivedPage: false))
        #expect(try await vm.storage.savedArticleCopy(unloaded.id).text == words(40))
        #expect(refused == .notInLibrary)
        #expect(await calls.captures == 0)
    }
}

// MARK: - refetch_source_content

/// The Apple episodes a podcast refetch asked for.
private actor PodcastRefetchCalls {
    var trackIDs: [Int64] = []
    func record(_ trackID: Int64) { trackIDs.append(trackID) }
}

@Suite("refetch_source_content")
@MainActor
struct RefetchSourceContentTests {
    @Test("Web articles take the menu item's path; the other branches stay as they were")
    func routes() {
        func route(_ url: String, _ type: StudioSourceType) -> MCPDataStore.RefetchRoute {
            MCPDataStore.refetchRoute(for: StudioArticle(url: url, title: "Source", sourceType: type))
        }
        for type in [StudioSourceType.article, .manual, .unclassified] {
            #expect(route("https://example.com/essay", type) == .websiteRefresh)
            #expect(route("https://example.com/handout.pdf?download=1", type) == .pdfAddress)
        }
        #expect(route("https://school.teachable.com/courses/biology/lectures/123", .article) == .teachableTranscript)
        #expect(route(
            GeminiNotebookService.sourceAddress(notebookID: UUID().uuidString, sourceID: "pasted"),
            .article
        ) == .geminiNotebookText)
        for type in [StudioSourceType.paper, .xPost, .video] {
            #expect(route("https://example.com/item", type) == .plainFetch)
        }
        // A video's text is its transcript, never its page: YouTube and Zoom
        // recordings are fetched again the way fetch_video_transcript fetches.
        #expect(route("https://www.youtube.com/watch?v=dQw4w9WgXcQ", .video) == .videoTranscript)
        #expect(route("https://zoom.us/rec/share/abc", .video) == .videoTranscript)
        #expect(route("https://zoom.us/rec/share/abc", .meeting) == .videoTranscript)
        #expect(route("https://www.youtube.com/watch?v=dQw4w9WgXcQ", .article) == .websiteRefresh)
        // A podcast's text is its transcript, never its page: both an Apple
        // episode and a row filed under the episode's page are hydrated again.
        #expect(route("apple-podcast://episode/1000745466204", .podcast) == .podcastTranscript)
        #expect(route("https://example.com/episodes/12", .podcast) == .podcastTranscript)
    }

    private static let episodeTTML = "<tt><body><div><p begin='0' end='1' ttm:agent='SPEAKER_1'>The whole episode from its first word to its last one.</p><p begin='1' end='2' ttm:agent='SPEAKER_2'>And the guest's answer, which the cut transcript never had.</p></div></body></tt>"

    /// A ready episode holding `transcript` and no TTML, saved and loaded the
    /// way the library holds one.
    private func seedReadyEpisode(
        id: String,
        trackID: Int64,
        transcript: String,
        publicURL: String? = nil,
        in vm: StudioViewModel
    ) async throws -> StudioArticle {
        var episode = StudioArticle(url: "apple-podcast://episode/\(trackID)", title: "Episode \(id)", sourceType: .podcast, id: id)
        episode.domain = "A Show"
        episode.publicURL = publicURL
        try await vm.storage.saveSource(episode)
        try await vm.storage.saveTranscript(id, transcript)
        let loaded = try #require(try await vm.storage.loadPersistedSources(ids: [id]).first)
        vm.articles.append(loaded)
        return loaded
    }

    @Test("A podcast is fetched again from Apple Podcasts as the app hydrates one, and a failed fetch keeps what it has")
    func podcastRefetchHydratesAgain() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let ttml = Self.episodeTTML
        let whole = try SourceService.extractTextFromTTMLContent(ttml)
        let cut = "[SPEAKER_1]\nThe whole episode from its first word"
        let episode = try await seedReadyEpisode(id: "refetched", trackID: 1_000_745_466_204, transcript: cut, in: vm)

        let outcome = await vm.refetchPodcastTranscript(for: episode.id, config: nil) { trackID, _ in
            trackID == 1_000_745_466_204 ? .available(ttml) : .failed
        }

        guard case .ready(let content, _) = outcome else {
            Issue.record("expected a transcript, got \(String(describing: outcome))")
            return
        }
        #expect(content == whole)
        #expect(await vm.storage.loadSourceContent(episode.id) == whole)
        #expect(vm.articles.first { $0.id == episode.id }?.content == whole)
        #expect(try await vm.storage.loadPodcastRawTTML(episode.id) == ttml)

        // Apple has no transcript for this one now: the stored one stays, and
        // the episode stays ready rather than turning into an error.
        let keptText = "[SPEAKER_1]\nA transcript that must stay as it is."
        let kept = try await seedReadyEpisode(id: "kept", trackID: 1_000_745_902_096, transcript: keptText, in: vm)
        let failed = await vm.refetchPodcastTranscript(for: kept.id, config: nil) { _, _ in .unavailable }
        guard case .failed = failed else {
            Issue.record("expected a failure, got \(String(describing: failed))")
            return
        }
        #expect(await vm.storage.loadSourceContent(kept.id) == keptText)
        let row = try #require(vm.articles.first { $0.id == kept.id })
        #expect(row.state == .ready)
        #expect(row.errorMessage == nil)
    }

    @Test("The tool refetches a podcast in the background and refuses a transcript taken from YouTube")
    func podcastRefetchThroughTheTool() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let captions = try await seedReadyEpisode(
            id: "captions",
            trackID: 1_000_787_449_271,
            transcript: "Captions from a video of the episode.",
            publicURL: "https://www.youtube.com/watch?v=abcdefghijk",
            in: vm
        )
        #expect(throws: MCPError.self) {
            try MCPDataStore.refetchPodcastTranscript(captions, in: vm)
        }

        let text = "[SPEAKER_1]\nA transcript the tool asks for again."
        let episode = try await seedReadyEpisode(id: "apple", trackID: 1_000_744_989_426, transcript: text, in: vm)
        let calls = PodcastRefetchCalls()
        let answer = try MCPDataStore.refetchPodcastTranscript(episode, in: vm) { trackID, _ in
            await calls.record(trackID)
            return .unavailable
        }
        #expect(answer.contains("again from Apple Podcasts"))
        #expect(answer.contains("cancel_ai_work"))

        // The work runs after the answer; Apple says it has no transcript, so
        // the stored one stays.
        var waited = 0
        while await calls.trackIDs.isEmpty || vm.contentFetchInFlight.contains(episode.id), waited < 200 {
            try await Task.sleep(for: .milliseconds(25))
            waited += 1
        }
        #expect(await calls.trackIDs == [1_000_744_989_426])
        #expect(!vm.contentFetchInFlight.contains(episode.id))
        #expect(await vm.storage.loadSourceContent(episode.id) == text)
        #expect(vm.articles.first { $0.id == episode.id }?.state == .ready)
    }

    @Test("A kept article is an answer; a refresh that could not read the page is an error")
    func answers() {
        let kept = MCPDataStore.refetchAnswer(
            for: .keptSavedCopy(savedWords: 4_000, fetchedWords: 120),
            title: "The Essay"
        )
        #expect(!kept.isError)
        #expect(kept.text.contains("4000 words") && kept.text.contains("120 words"))

        let refreshed = MCPDataStore.refetchAnswer(
            for: .refreshed(savedWords: 120, words: 4_000, archivedPage: true),
            title: "The Essay"
        )
        #expect(!refreshed.isError)
        #expect(refreshed.text.contains("120 → 4000 words"))

        #expect(!MCPDataStore.refetchAnswer(for: .unchanged(words: 4_000), title: "The Essay").isError)

        let check = MCPDataStore.refetchAnswer(for: .securityCheck, title: "The Essay")
        #expect(check.isError)
        #expect(check.text.contains("bot check") && check.text.contains("kept"))

        for step in [ArticleWebsiteRefreshStep.capture, .cleanup, .savedCopy, .save] {
            let failed = MCPDataStore.refetchAnswer(for: .failed(step, reason: "it broke"), title: "The Essay")
            #expect(failed.isError)
            #expect(failed.text.contains("it broke"))
        }
        for outcome in [ArticleWebsiteRefreshOutcome.alreadyRunning, .notRefreshable, .notInLibrary] {
            #expect(MCPDataStore.refetchAnswer(for: outcome, title: "The Essay").isError)
        }
    }

    @Test("The tool runs the menu item's refresh: a preview is kept, a bot check refused")
    func toolRunsTheMenuRefresh() async throws {
        let (vm, root) = makeRefreshViewModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = words(40)
        let article = try await seedReadyArticle(text: saved, in: vm)

        let answer = try await MCPDataStore.refreshArticle(
            article,
            in: vm,
            work: standInWork(page: words(10), calls: StepCalls())
        )
        #expect(answer.contains("Kept the saved 'The Essay'"))

        await #expect(throws: MCPError.self) {
            try await MCPDataStore.refreshArticle(article, in: vm, work: standInWork(
                page: "Checking your browser before accessing example.com.",
                pageTitle: "Just a moment...",
                calls: StepCalls()
            ))
        }
        #expect(try await vm.storage.savedArticleCopy(article.id).text == saved)
    }
}
