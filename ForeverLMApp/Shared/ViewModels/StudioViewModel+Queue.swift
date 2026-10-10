import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    // MARK: - Queue Management

    /// Load the full queue from persisted state.
    ///
    /// Startup is intentionally read-only and avoids filesystem discovery. New
    /// browser Reading List items are picked up by explicit refresh or by the
    /// change-triggered watcher after launch.

    /// Start the auto-refresh timer (called once from the view layer).
    /// Safe to call multiple times — only the first call starts the timer.
    func startAutoRefreshIfNeeded() {
        // Auto-refresh disabled — discovery is manual-only (refresh button).
        // Prevents main-actor-blocking filesystem scans every 5 minutes.
    }

    /// Run the full Studio bootstrap only once per app session.
    /// Subsequent tab switches should reuse the existing queue state and rely on
    /// manual refresh or the background auto-refresh timer for updates.
    func ensureInitialQueueLoaded() async {
        guard !hasCompletedInitialQueueLoad else { return }
        await loadQueue()
    }

    /// Lightweight snapshot for surfaces like Getting Started that only need to
    /// know what sources already exist, without triggering full discovery/startup work.
    func loadPersistedSourcesSnapshot() async -> [StudioArticle] {
        (try? await storage.loadSources()) ?? articles
    }

    func computeMergeResult(
        discoveredArticles: [StudioArticle],
        dismissedURLs: Set<String>
    ) async -> MergeComputationResult {
        let existingSnapshot = Self.makeMergeExistingSnapshot(from: articles)
        let discoveredSnapshot = Self.makeMergeDiscoveredSnapshot(from: discoveredArticles)
        return await Task.detached(priority: .userInitiated) {
            Self.computeMergeResultOffMain(
                discovered: discoveredSnapshot,
                dismissedURLs: dismissedURLs,
                existing: existingSnapshot
            )
        }.value
    }

    nonisolated static func makeMergeExistingSnapshot(from articles: [StudioArticle]) -> MergeExistingSnapshot {
        let paperTitles = articles
            .filter { $0.sourceType == .paper }
            .map { normalizedPaperTitle($0.title) }
            .filter { !$0.isEmpty }
        return MergeExistingSnapshot(
            urls: Set(articles.map { article in
                article.url.hasPrefix("/") ? article.url : SourceDiscovery.normalizedURL(article.url)
            }),
            relativeURLs: Set(articles.map { StorageService.relativeSourcePath($0.url) }),
            localPaths: Set(articles.compactMap(\.localFilePath)),
            podcastWebURLs: Set(articles.compactMap(\.podcastWebPageURL)),
            paperTitles: Set(paperTitles),
            localPaperFilenames: Set(
                articles
                    .filter { $0.sourceType == .paper && $0.url.hasPrefix("/") && $0.isPDF }
                    .map { normalizedPaperFilename(($0.url as NSString).lastPathComponent) }
            ),
            paperPublisherKeys: Set(
                articles
                    .filter { $0.sourceType == .paper }
                    .compactMap { paperPublisherIdentityKey(for: $0.url) }
            )
        )
    }

    nonisolated static func makeMergeDiscoveredSnapshot(from discoveredArticles: [StudioArticle]) -> [MergeDiscoveredSnapshot] {
        discoveredArticles.enumerated().map { index, article in
            let normalizedURL = article.url.hasPrefix("/") ? article.url : SourceDiscovery.normalizedURL(article.url)
            let normalizedPaperTitle = article.sourceType == .paper ? normalizedPaperTitle(article.title) : ""
            let normalizedPaperFilename =
                article.sourceType == .paper && article.url.hasPrefix("http")
                ? normalizedPaperFilename(paperFilename(from: article.url))
                : nil
            return MergeDiscoveredSnapshot(
                index: index,
                url: article.url,
                normalizedURL: normalizedURL,
                relativeURL: StorageService.relativeSourcePath(article.url),
                sourceType: article.sourceType.rawValue,
                title: article.title,
                normalizedPaperTitle: normalizedPaperTitle,
                localFilePath: article.localFilePath,
                podcastWebPageURL: article.podcastWebPageURL,
                normalizedPaperFilename: normalizedPaperFilename,
                paperPublisherKey: article.sourceType == .paper ? paperPublisherIdentityKey(for: article.url) : nil
            )
        }
    }

    nonisolated static func computeMergeResultOffMain(
        discovered: [MergeDiscoveredSnapshot],
        dismissedURLs: Set<String>,
        existing: MergeExistingSnapshot
    ) -> MergeComputationResult {
        var newArticleIndexes: [Int] = []
        var discoveredByURLIndexes: [String: Int] = [:]

        for item in discovered {
            discoveredByURLIndexes[item.normalizedURL] = discoveredByURLIndexes[item.normalizedURL] ?? item.index

            if dismissedURLs.contains(item.url) { continue }
            if let webURL = item.podcastWebPageURL, dismissedURLs.contains(webURL) { continue }
            if existing.urls.contains(item.normalizedURL) { continue }
            if existing.relativeURLs.contains(item.relativeURL) { continue }
            if existing.localPaths.contains(item.url) || (item.localFilePath.map(existing.localPaths.contains) ?? false) { continue }

            if item.sourceType == StudioSourceType.paper.rawValue {
                if let publisherKey = item.paperPublisherKey,
                   existing.paperPublisherKeys.contains(publisherKey) {
                    continue
                }
                if let filename = item.normalizedPaperFilename, existing.localPaperFilenames.contains(filename) { continue }
                let normalizedTitle = item.normalizedPaperTitle
                if !normalizedTitle.isEmpty && existing.paperTitles.contains(normalizedTitle) { continue }
            }

            if item.sourceType == StudioSourceType.podcast.rawValue {
                if existing.podcastWebURLs.contains(item.url) { continue }
                if let webURL = item.podcastWebPageURL,
                   existing.urls.contains(SourceDiscovery.normalizedURL(webURL)) {
                    continue
                }
            }

            newArticleIndexes.append(item.index)
        }

        return MergeComputationResult(
            newArticleIndexes: newArticleIndexes,
            discoveredByURLIndexes: discoveredByURLIndexes
        )
    }

    struct LoadedArticleContentSnapshot {
        let content: String
        let wordCount: Int?
        let state: StudioArticleState
        let errorMessage: String?
    }

    func preservingLoadedContent(
        in reloadedArticles: [StudioArticle],
        preservingFrom previousArticles: [StudioArticle]
    ) -> [StudioArticle] {
        Self.preservingLoadedContent(in: reloadedArticles, preservingFrom: previousArticles)
    }

    /// Pure merge over value types — safe to run off the main actor. The CloudKit
    /// remote-refresh path calls this from a detached task so a large library
    /// never pays the merge cost on the main thread.
    nonisolated static func preservingLoadedContent(
        in reloadedArticles: [StudioArticle],
        preservingFrom previousArticles: [StudioArticle]
    ) -> [StudioArticle] {
        let loadedContentByID = previousArticles.reduce(into: [String: LoadedArticleContentSnapshot]()) { result, article in
            guard let content = article.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            result[article.id] = LoadedArticleContentSnapshot(
                content: content,
                wordCount: article.wordCount,
                state: article.state,
                errorMessage: article.errorMessage
            )
        }

        // Keep real paper metadata that we already hold in memory when a reloaded
        // row only carries a placeholder/nil. A reload whose SQLite read raced
        // ahead of a just-committed AI extraction would otherwise visibly revert
        // freshly enriched author/venue/year (e.g. "Tomusiak et al" → "Unknown
        // authors"). Only ever upgrade away from a placeholder, never downgrade.
        let inMemoryByID = Dictionary(previousArticles.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })

        guard !loadedContentByID.isEmpty || !inMemoryByID.isEmpty else { return reloadedArticles }

        return reloadedArticles.map { article in
            var preserved = article

            if let loaded = loadedContentByID[article.id] {
                preserved.content = loaded.content
                // Word count belongs to the exact content snapshot. Preferring
                // the reloaded row's count while retaining newer in-memory text
                // produces an internally inconsistent source after refresh.
                preserved.wordCount = loaded.wordCount ?? loaded.content.split(separator: " ").count
                preserved.state = loaded.state == .ready ? .ready : article.state
                preserved.errorMessage = loaded.errorMessage
            }

            // `.fetching` is deliberately transient for resumable source work: the
            // durable row stays queued so a terminated app will pick it up on the
            // next launch. A background CloudKit/discovery reload can therefore
            // carry the older queued value while the in-memory worker is still
            // active. Keep the newer runtime state or the sidebar claims every
            // episode is queued even though one is using the serial transcript
            // slot right now.
            if let inMemory = inMemoryByID[article.id],
               inMemory.state == .fetching,
               preserved.state == .queued {
                preserved.state = .fetching
                preserved.errorMessage = inMemory.errorMessage
            }

            // Same rule for an attached local file: a reload that raced ahead of a
            // just-committed attachment carries no path, and adopting that nil is
            // what makes a paper the user just downloaded snap back into "needs
            // attention" while its freshly enriched byline stays on screen. Only
            // ever fill in a missing path, never replace one the reload supplied,
            // so a genuine detach (which clears memory first) still wins.
            if preserved.localFilePath == nil,
               let inMemoryPath = inMemoryByID[article.id]?.localFilePath {
                preserved.localFilePath = inMemoryPath
            }

            if preserved.sourceType == .paper, let inMemory = inMemoryByID[article.id] {
                if preserved.paperAuthorNeedsEnrichment, !inMemory.paperAuthorNeedsEnrichment {
                    preserved.author = inMemory.author
                }
                if preserved.paperJournalNeedsEnrichment, !inMemory.paperJournalNeedsEnrichment {
                    preserved.journal = inMemory.journal
                }
                if preserved.paperYearNeedsEnrichment, !inMemory.paperYearNeedsEnrichment {
                    preserved.publishedYear = inMemory.publishedYear
                }
            }

            return preserved
        }
    }

    func loadQueue() async {
        guard !isLoadingQueue else { return }
        isLoadingQueue = true
        defer { isLoadingQueue = false }
        let articlesSnapshot = articles
        var didLoadSources = false

        // ── Fast SQLite reads — run in parallel, no spinner ──────────────
        async let booksResult = storage.loadBooks()
        async let courseResult = storage.loadCourseMetadata()
        async let courseTeamIDsResult = storage.loadCourseTeamIDs()
        async let courseFollowersResult = storage.loadCourseFollowers()
        async let videoPlaylistResult = storage.loadVideoPlaylistMetadata()
        async let courseLecturesResult = storage.loadCourseLectures()
        async let courseLectureItemsResult = storage.loadCourseLectureItems()
        async let courseArtworkResult = storage.loadCourseArtworkURLs()
        async let meetingResult = storage.loadMeetingMetadata()
        async let meetingArtifactsResult = storage.loadMeetingArtifacts()
        async let sourcesResult = storage.loadLibrarySources(teamID: activeTeamID)
        async let learningGoalsResult = storage.loadLearningGoals()
        async let sourceReviewDatesResult = storage.sourceReviewDates()
        async let hiddenPodcastShowsResult = storage.loadHiddenPodcastShows()
        async let hiddenPodcastEpisodeIDsResult = storage.loadHiddenPodcastEpisodeIDs()
        async let visiblePodcastEpisodeOverrideIDsResult = storage.loadVisiblePodcastEpisodeOverrideIDs()
        async let hiddenYouTubeChannelsResult = storage.loadHiddenYouTubeChannels()
        async let visibleYouTubeVideoOverrideIDsResult = storage.loadVisibleYouTubeVideoOverrideIDs()

        do {
            let books = try await booksResult
            bookTitles = books.titles
            bookSubtitles = books.subtitles
            bookCoverPaths = books.coverPaths
            bookAuthors = books.authors
            bookEditions = books.editions
            bookKinds = books.kinds
        } catch {
            logger.error("Failed to load books: \(error.localizedDescription)")
        }
        do {
            courseMetadata = try await courseResult
        } catch {
            logger.error("Failed to load course metadata: \(error.localizedDescription)")
        }
        do {
            courseTeamIDs = try await courseTeamIDsResult
        } catch {
            logger.error("Failed to load course teams: \(error.localizedDescription)")
        }
        do {
            courseFollowerNotebookIDs = try await courseFollowersResult
        } catch {
            logger.error("Failed to load the notebooks following courses: \(error.localizedDescription)")
        }
        do {
            videoPlaylistMetadata = try await videoPlaylistResult
        } catch {
            logger.error("Failed to load video playlist metadata: \(error.localizedDescription)")
        }
        do {
            applyCourseOutline(
                lectures: try await courseLecturesResult,
                items: try await courseLectureItemsResult
            )
            courseCoverArtworkURLs = try await courseArtworkResult
        } catch {
            logger.error("Failed to load course lectures: \(error.localizedDescription)")
        }
        await refreshCourseQuizzes()
        do {
            meetingMetadata = try await meetingResult
            applyMeetingArtifacts(try await meetingArtifactsResult)
        } catch {
            logger.error("Failed to load meetings: \(error.localizedDescription)")
        }
        do {
            let library = try await sourcesResult
            articlesStore.teamCopyAliases = library.teamCopyAliases
            articles = preservingLoadedContent(in: library.sources, preservingFrom: articlesSnapshot)
            // Team notebooks' copies are marked on the rows the aliases name.
            refreshNotebookSidebarIndex()
            seedReadingProgressFromArticles()
            libraryLoadErrorMessage = nil
            didLoadSources = true
        } catch {
            logger.error("Failed to load sources: \(error.localizedDescription)")
            libraryLoadErrorMessage = "ForeverLM couldn't open your library. \(error.localizedDescription)"
        }
        do {
            hiddenPodcastShows = try await hiddenPodcastShowsResult
        } catch {
            logger.error("Failed to load hidden podcast shows: \(error.localizedDescription)")
        }
        do {
            hiddenPodcastEpisodeIDs = try await hiddenPodcastEpisodeIDsResult
        } catch {
            logger.error("Failed to load hidden podcast episodes: \(error.localizedDescription)")
        }
        do {
            visiblePodcastEpisodeOverrideIDs = try await visiblePodcastEpisodeOverrideIDsResult
        } catch {
            logger.error("Failed to load visible podcast episode overrides: \(error.localizedDescription)")
        }
        do {
            let storedChannels = try await hiddenYouTubeChannelsResult
            let legacyChannels = Set(
                UserDefaults.standard.stringArray(forKey: "youtube.hiddenChannels") ?? []
            )
            for channelName in legacyChannels.subtracting(storedChannels) {
                try await storage.setYouTubeChannelHidden(channelName, hidden: true)
            }
            hiddenYouTubeChannels = storedChannels.union(legacyChannels)
            if !legacyChannels.isEmpty {
                PreferenceStore.remove(forKey: "youtube.hiddenChannels")
            }
        } catch {
            logger.error("Failed to load hidden YouTube channels: \(error.localizedDescription)")
        }
        do {
            visibleYouTubeVideoOverrideIDs = try await visibleYouTubeVideoOverrideIDsResult
        } catch {
            logger.error("Failed to load visible YouTube video overrides: \(error.localizedDescription)")
        }
        do {
            reviewSessionLinks = try await storage.loadReviewSessionLinks()
        } catch {
            logger.error("Failed to load review session links: \(error.localizedDescription)")
        }
        do {
            learningGoals = try await learningGoalsResult
            if activeNotebookId == nil || !notebooks.contains(where: { $0.id == activeNotebookId }) {
                activeNotebookId = notebooks.first?.id
            }
        } catch {
            logger.error("Failed to load schedule: \(error.localizedDescription)")
        }
        do {
            sourceReviewedAt = try await sourceReviewDatesResult
        } catch {
            logger.error("Failed to load source review dates: \(error.localizedDescription)")
        }

        // Resolve local file paths off the main actor before revealing the list.
        // `resolvedLocalPath`/`resolvedPDFPath` do synchronous FileManager existence
        // checks (against iCloud-backed files), and the sidebar — including the
        // always-evaluated Papers tab badge — reads them once per source per render.
        // Warming the memoization cache here turns the first Library render into a
        // cache hit instead of a main-actor stat storm that beachballed in
        // proportion to library size. Raw path strings are Sendable; StudioArticle
        // is not, so we snapshot the strings on-main and resolve them off-main.
        let rawPathsToWarm: [String] = articles.flatMap { article -> [String] in
            var paths: [String] = [article.url]
            if let localFilePath = article.localFilePath { paths.append(localFilePath) }
            return paths
        }
        _ = await Task.detached(priority: .userInitiated) {
            StudioArticle.warmResolvedLocalPathCache(forRawPaths: rawPathsToWarm)
        }.value

        guard didLoadSources else { return }
        await loadTeams()
        hasCompletedInitialQueueLoad = true
        // Before sync starts, with the library already on screen: a source
        // another Mac has repaired would otherwise arrive as new text here, and
        // the Listen text, review guide and ideas this Mac made from the old
        // text would no longer match it. Repaired here first, both Macs hold the
        // same text and keep what they made. A no-op once the queue is empty.
        await runDeferredStoredSoftHyphenRepair()
        // The Mac's sync is the generation-2 coordinator's, started after the activation finished.
        MacSyncSession.startIfEnabled(storage: storage) { [viewModel = self, storage] coordinator in
            StudioJobWork(viewModel: viewModel, storage: storage, coordinator: coordinator)
        }
        // The library is loaded, so an integration tab Studio unpinned can be
        // judged against real evidence: pin back the ones this learner actually
        // uses before correcting a selection that landed on an unpinned tab.
        pinIntegrationTabsInUse()
        if hiddenTabs.contains(sidebarTab), let first = visibleTabs.first {
            switchTab(to: first)
        }
        startYouTubeAutoImport()
        startReviewGuidePrebuild()

        // ── Cheap cached-state work only; discovery is manual or change-triggered. ──
        Task(priority: .utility) { [weak self] in
            guard let self else { return }

            await self.convergePaperIdentityDuplicates()
            await self.drainPendingWebCourseImports()
            await self.drainPendingWebBookImports()
            await self.runDeferredZoomMeetingAdoption()
            // Zoom sessions still waiting for their transcript are asked
            // about now and every quarter hour from here.
            self.startZoomTranscriptChecks()
            await self.runDeferredSourceSyncRepair()
            await self.runDeferredSourceTextReferenceRepair()
            await self.runDeferredPaperFigureMarkdownRepair()
            await self.runDeferredPaperFigureImageSweep()
            await self.runDeferredMemoryScheduleRebuild()
            self.scheduleBookCoverPathPopulation()

            do {
                self.learningGoalLinkedSourceIds = try await self.storage.sourceIdsWithReviewSession()
                self.learningGoalEligibleSourceIds = try await self.storage.sourceIdsWithLinkedChatSession()
            } catch {
                self.logger.error("Failed to load schedule chat state: \(error.localizedDescription)")
            }

            // Once the UI has settled, quietly resolve PDFs for any papers still
            // needing attention so the user never has to press the bulk button.
            // Deferred + serialized off the launch path to keep startup fast.
            try? await Task.sleep(for: .seconds(3))
            self.autoFetchNewlyAddedPapers()
            self.autoFetchUnfetchedSources()
            Task(priority: .utility) { [weak self] in
                await self?.processPendingPodcastTranscripts()
            }

            // Once the PDF sweep has had a moment to start, attest any paper that
            // still needs the mandatory metadata model call. This also heals the
            // existing incomplete backlog migrated into an explicit error state.
            try? await Task.sleep(for: .seconds(6))
            self.autoExtractMissingPaperMetadata()

            // Fill any embedding-coverage gap in the background so semantic search
            // sees every source. Runs after the UI has settled and paper text has had
            // a chance to be recovered; the indexer itself yields between batches.
            try? await Task.sleep(for: .seconds(4))
            await self.runCanonicalContentCleanup()
            self.kickSourceEmbeddingIndexing()
        }

    }

    func refreshScopeLabel(for tab: StudioSidebarTab?) -> String {
        guard let tab else { return "all sources" }
        return tab.itemNoun
    }

    func syncCloudKitInBackground() {
        cloudKitBackgroundSyncTask?.cancel()
        cloudKitBackgroundSyncTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.storage.syncCloudKitNowAndWaitForDrain()
        }
    }

    /// Pull cross-device changes when the user returns to the Mac. CloudKit push
    /// remains the fast path, but activation repairs a missed or delayed push so
    /// iPhone reading/listening activity cannot remain absent from the open app.
    /// Keep this separate from the outbound-drain task above: an activation must
    /// never cancel a local save that is already on its way to CloudKit.
    func syncCloudKitOnActivation() {
        guard hasCompletedInitialQueueLoad, !isLoadingQueue,
              cloudKitEventSyncTask == nil else { return }
        let now = Date()
        if let lastCloudKitEventSyncAt,
           now.timeIntervalSince(lastCloudKitEventSyncAt) < 30 {
            return
        }
        lastCloudKitEventSyncAt = now
        cloudKitEventSyncTask = Task { [weak self] in
            guard let self else { return }
            await self.storage.syncCloudKitNow()
            guard !Task.isCancelled else { return }
            self.cloudKitEventSyncTask = nil
        }
    }

    /// Fetch og:image for articles that have no artworkURL.
    /// Runs in background, batched to avoid flooding the network.
    func backfillMissingArtwork(onlyIds: Set<String>? = nil) async {
        // Fix invalid artwork URLs: strip relative paths (e.g. /static/...) that slipped
        // in from external sources. They can't load and block the backfill from retrying.
        let invalidArtworkIDs = articles.compactMap { article -> String? in
            guard let art = article.artworkURL, !art.hasPrefix("http") else { return nil }
            return article.id
        }

        for articleID in invalidArtworkIDs {
            guard let idx = articles.firstIndex(where: { $0.id == articleID }) else { continue }
            articles[idx].artworkURL = nil
        }

        // Backfill YouTube video thumbnails (deterministic URL from video ID, no fetch needed)
        for i in articles.indices {
            guard articles[i].artworkURL == nil,
                  let thumb = articles[i].youtubeThumbnailURL else { continue }
            guard onlyIds.map({ $0.contains(articles[i].id) }) ?? true else { continue }
            articles[i].artworkURL = thumb
        }

        let snapshot = articles
        let candidates = snapshot.compactMap { article -> ArtworkBackfillCandidate? in
            guard onlyIds.map({ $0.contains(article.id) }) ?? true else { return nil }
            guard shouldBackfillArtwork(for: article) else { return nil }
            guard let url = URL(string: article.url) else { return nil }
            return ArtworkBackfillCandidate(id: article.id, url: url)
        }
        guard !candidates.isEmpty else { return }

        let results = await Self.fetchArtworkBackfillResults(for: Array(candidates.prefix(20)))
        for result in results {
            guard let idx = articles.firstIndex(where: { $0.id == result.id }) else { continue }
            guard articles[idx].artworkURL != result.artworkURL else { continue }
            articles[idx].artworkURL = result.artworkURL
        }
    }

    func backfillArtworkIfNeeded(_ articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        guard articles[idx].artworkURL == nil else { return }

        // An X post's picture is its author's. It is not in the page metadata
        // the og:image path below reads — x.com answers an HTTP client with a
        // login wall — so it comes from X's own endpoints instead.
        if articles[idx].sourceType == .xPost {
            await backfillXPostArtwork()
            return
        }

        // YouTube thumbnails are deterministic — no fetch needed
        if let thumb = articles[idx].youtubeThumbnailURL {
            articles[idx].artworkURL = thumb
            return
        }

        guard shouldBackfillArtwork(for: articles[idx]) else { return }
        guard !artworkBackfillInFlight.contains(articleId) else { return }
        guard let url = URL(string: articles[idx].url) else { return }

        artworkBackfillInFlight.insert(articleId)
        defer { artworkBackfillInFlight.remove(articleId) }

        guard let imageURL = await Self.fetchArtworkURL(for: url) else { return }
        guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
        guard articles[idx2].artworkURL != imageURL else { return }

        articles[idx2].artworkURL = imageURL
    }

    /// Classify sources with `source_type = 'unclassified'` as article, paper, or book via LLM.
    /// After classification, the source type is updated to a concrete type — the
    /// `unclassified` state is transient and should not persist long.
    func classifyUnclassifiedSources() async {
        guard let config = KeychainService.resolveConfig(for: .sourceClassification) else { return }

        let candidates: [(index: Int, url: String, title: String)] = articles.indices.compactMap { idx in
            let a = articles[idx]
            guard a.sourceType == .unclassified, a.url.hasPrefix("http") else { return nil }
            return (index: idx, url: a.url, title: a.title)
        }
        guard !candidates.isEmpty else { return }

        logger.info("Classifying \(candidates.count) unclassified source(s)")

        let classifications = await aiService.batchClassifySourceTypeMap(items: candidates, config: config)

        for candidate in candidates {
            let idx = candidate.index
            guard idx < articles.count else { continue }
            if let classified = classifications[idx] {
                Self.applyClassifiedSourceType(classified, to: &articles[idx])
                logger.info("Classified as \(self.articles[idx].sourceType.rawValue): \(self.articles[idx].title)")
            } else if articles[idx].sourceType == .unclassified {
                articles[idx].sourceType = .article
            }
        }

        let classified = candidates.compactMap { $0.index < articles.count ? articles[$0.index] : nil }
        try? await storage.saveSourcesBatchOnly(classified)
        for source in classified where source.sourceType == .book {
            await persistWholeBookMetadataIfNeeded(for: source)
        }
        let paperCount = classified.filter { $0.sourceType == .paper }.count
        let bookCount = classified.filter { $0.sourceType == .book }.count
        logger.info("Classified \(candidates.count) source(s): \(paperCount) paper(s), \(bookCount) book(s), \(candidates.count - paperCount - bookCount) article(s)")
        await repairMisclassifiedBookSources()
    }

    /// Reclassify books that are clearly scholarly papers (e.g. arXiv preprints
    /// mislabeled by LLM or book import).
    ///
    /// Runs only after a classification batch — never on launch. As a launch
    /// sweep it was both a rule violation (startup stays read-only) and a false
    /// comfort: it scans in-memory `articles`, so archived sources were never
    /// reachable and stayed mislabeled regardless.
    func repairMisclassifiedBookSources() async {
        var repaired: [StudioArticle] = []
        for idx in articles.indices {
            guard articles[idx].sourceType == .book else { continue }
            guard Self.looksLikeScholarlyPaper(url: articles[idx].url) else { continue }

            articles[idx].sourceType = .paper
            articles[idx].prepareForPaperMetadataExtraction()
            if articles[idx].parentGroup == articles[idx].id {
                articles[idx].parentGroup = nil
            }
            repaired.append(articles[idx])
            logger.info("Reclassified mislabeled book as paper: \(self.articles[idx].title)")
        }
        guard !repaired.isEmpty else { return }
        try? await storage.saveSourcesBatchOnly(repaired)
        syncCloudKitInBackground()
    }

    /// Classify newly discovered web sources before first persistence, so the
    /// initial CloudKit record already has the correct article/paper/book type.
    func classifyDiscoveredSourceTypesBeforePersistence(_ discovered: inout [StudioArticle]) async {
        await Self.classifyDiscoveredSourceTypesBeforePersistence(&discovered)
    }

    nonisolated static func classifyDiscoveredSourceTypesBeforePersistence(_ discovered: inout [StudioArticle]) async {
        guard let config = KeychainService.resolveConfig(for: .sourceClassification) else { return }

        let candidates: [(index: Int, url: String, title: String)] = discovered.indices.compactMap { idx in
            let source = discovered[idx]
            guard source.url.hasPrefix("http"),
                  source.sourceType == .unclassified || source.sourceType == .article || source.sourceType == .paper else {
                return nil
            }
            return (index: idx, url: source.url, title: source.title)
        }
        guard !candidates.isEmpty else { return }

        let aiService = AIService()
        let classifications = await aiService.batchClassifySourceTypeMap(items: candidates, config: config)
        for candidate in candidates {
            if let classified = classifications[candidate.index] {
                Self.applyClassifiedSourceType(classified, to: &discovered[candidate.index])
            } else if discovered[candidate.index].sourceType == .unclassified {
                discovered[candidate.index].sourceType = .article
            }
        }

        let classifiedSources = candidates.compactMap { $0.index < discovered.count ? discovered[$0.index] : nil }
        let paperCount = classifiedSources.filter { $0.sourceType == .paper }.count
        let bookCount = classifiedSources.filter { $0.sourceType == .book }.count
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Studio")
        logger.info("Pre-classified \(candidates.count) discovered source(s): \(paperCount) paper(s), \(bookCount) book(s), \(candidates.count - paperCount - bookCount) article(s)")
    }

    nonisolated static func normalizeWholeBookSource(_ source: inout StudioArticle) {
        guard source.sourceType == .book else { return }
        let parentGroup = source.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        if parentGroup?.isEmpty != false {
            source.parentGroup = source.id
        }
    }

    func persistWholeBookMetadataIfNeeded(for source: StudioArticle) async {
        guard source.sourceType == .book,
              let groupName = source.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupName.isEmpty else { return }
        bookTitles[groupName] = source.title
        if let author = source.author {
            bookAuthors[groupName] = author
        }
        do {
            try await storage.saveBookMetadata(
                groupName: groupName,
                title: source.title,
                author: source.author,
                coverPath: nil,
                kind: bookKinds[groupName]
            )
        } catch {
            logger.error("Failed to save book metadata for classified source \(source.id): \(error.localizedDescription)")
        }
    }

    func normalizedAuthorFromMetadata(_ author: String, source: StudioArticle) async -> String? {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let task: AITask = source.sourceType == .paper ? .paperMetadata : .articleMetadata
        guard let config = KeychainService.resolveConfig(for: task) else {
            logger.warning("Skipping author capitalization normalization because \(task.displayName) has no API key configured")
            return nil
        }

        do {
            return try await aiService.normalizeAuthorCapitalization(
                trimmed,
                source: AIUsageSource(source: source),
                config: config
            )
        } catch {
            logger.warning("Author capitalization normalization failed for \(source.sourceType.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func applyMetadataAuthor(_ author: String, toArticleAt index: Int) async -> Bool {
        guard articles.indices.contains(index),
              let normalized = await normalizedAuthorFromMetadata(author, source: articles[index]) else {
            return false
        }
        articles[index].author = normalized
        return true
    }

    /// Local-copy variant used by `backfillPaperMetadata`, which mutates a working
    /// copy across awaits rather than indexing into `articles` (avoids stale-index
    /// writes when a concurrent refresh reorders the array).
    func applyMetadataAuthor(_ author: String, to article: inout StudioArticle) async -> Bool {
        guard let normalized = await normalizedAuthorFromMetadata(author, source: article) else {
            return false
        }
        article.author = normalized
        return true
    }

    /// Fetch metadata (authors, journal, year) for papers that don't have it yet.
    ///
    /// Two paths:
    /// - **Have PDF (Path B):** `extractPaperMetadataWithAI` reads the first page
    ///   as source of truth before this runs; deterministic scholarly metadata
    ///   sources fill any remaining blanks here.
    /// - **No PDF (Path A):** Use Crossref/bioRxiv/arXiv APIs for provisional metadata.
    ///   This metadata gets overwritten when a PDF is attached later.
    func backfillPaperMetadata(
        onlyIds: Set<String>? = nil,
        resolvesPublishedVersionIdentity: Bool = true
    ) async {
        let candidates = articles.indices.filter { idx in
            (onlyIds == nil || onlyIds!.contains(articles[idx].id))
            && articles[idx].sourceType == .paper
            && (articles[idx].paperAuthorNeedsEnrichment
                || articles[idx].paperJournalNeedsEnrichment
                || articles[idx].paperYearNeedsEnrichment
                || Self.titleNeedsResolution(articles[idx].title, domain: articles[idx].domain, url: articles[idx].url))
        }
        guard !candidates.isEmpty else { return }
        // Capture ids up front; the await-heavy loop below can let concurrent
        // main-actor work reorder/replace `articles`, invalidating raw indices.
        let candidateIds = candidates.map { articles[$0].id }

        logger.info("Backfilling metadata for \(candidates.count) papers")
        var savedCount = 0

        for articleId in candidateIds {
            guard let liveIdx = articles.firstIndex(where: { $0.id == articleId }) else { continue }
            // Operate on a local copy across the await-heavy body so a concurrent
            // reorder of `articles` can't land these writes on the wrong source.
            // The final write is a field-level compare-and-swap patch, never this
            // whole snapshot: PDF attachment may change URL/localFilePath/state
            // while the scholarly metadata requests below are suspended.
            let original = articles[liveIdx]
            var article = original
            var didUpdate = false
            let titleWasUnresolved = Self.titleNeedsResolution(
                original.title,
                domain: original.domain,
                url: original.url
            )
            // ── Read the PDF first page if available ──
            let firstPageText = await Self.firstPageTextOffMain(for: article)
            let hasPDF = !firstPageText.isEmpty

            if hasPDF {
                // Also extract DOI from text if LLM missed it
                if article.doi == nil, let extractedDOI = Self.extractDOIFromText(firstPageText) {
                    article.doi = extractedDOI; didUpdate = true
                }

                // If the PDF path is now available but AI extraction is unavailable or
                // incomplete, still use deterministic scholarly metadata sources for
                // any remaining blanks. This keeps manual PDF attachment from getting
                // stuck at Unknown authors/venue/year.
                var resolvedTitle = article.title
                var resolvedDOI = article.doi ?? PaperService.extractDOI(from: article.url)

                if let pageMeta = await PaperService.fetchPaperPageMetadata(at: article.url) {
                    if let t = pageMeta.title, !t.isEmpty,
                       Self.titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
                        article.title = t
                        resolvedTitle = t
                        didUpdate = true
                    }
                    if resolvedDOI == nil, let doi = pageMeta.doi, !doi.isEmpty {
                        article.doi = doi
                        resolvedDOI = doi
                        didUpdate = true
                    }
                    if article.paperAuthorNeedsEnrichment, let a = pageMeta.authorsDisplay, !a.isEmpty {
                        didUpdate = await applyMetadataAuthor(a, to: &article) || didUpdate
                    }
                    if article.paperJournalNeedsEnrichment, let j = pageMeta.journal, !j.isEmpty {
                        article.journal = j
                        didUpdate = true
                    }
                    if article.paperYearNeedsEnrichment, let y = pageMeta.year, !y.isEmpty {
                        article.publishedYear = y
                        didUpdate = true
                    }
                }

                let canLookupByTitle = !Self.titleNeedsResolution(
                    resolvedTitle,
                    domain: article.domain,
                    url: article.url
                )
                if article.paperAuthorNeedsEnrichment
                    || article.paperJournalNeedsEnrichment
                    || article.paperYearNeedsEnrichment {
                    if resolvedDOI != nil || canLookupByTitle,
                       let meta = await PaperService.fetchPaperMetadata(
                           url: article.url,
                           title: resolvedTitle,
                           doi: resolvedDOI
                       ) {
                        if let t = meta.title, !t.isEmpty,
                           Self.titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
                            article.title = t
                            resolvedTitle = t
                            didUpdate = true
                        }
                        if article.doi == nil, let doi = meta.doi, !doi.isEmpty {
                            article.doi = doi
                            resolvedDOI = doi
                            didUpdate = true
                        }
                        if article.paperAuthorNeedsEnrichment, let a = meta.authorsDisplay, !a.isEmpty {
                            didUpdate = await applyMetadataAuthor(a, to: &article) || didUpdate
                        }
                        if article.paperJournalNeedsEnrichment, let j = meta.journal, !j.isEmpty {
                            article.journal = j; didUpdate = true
                        }
                        if article.paperYearNeedsEnrichment, let y = meta.year, !y.isEmpty {
                            article.publishedYear = y; didUpdate = true
                        }
                    }
                }
            } else {
                // ── Path A: No PDF — use APIs for provisional metadata ──
                var resolvedTitle = article.title
                var resolvedDOI = article.doi ?? PaperService.extractDOI(from: article.url)

                if let pageMeta = await PaperService.fetchPaperPageMetadata(at: article.url) {
                    if let t = pageMeta.title, !t.isEmpty,
                       Self.titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
                        article.title = t
                        resolvedTitle = t
                        didUpdate = true
                    }
                    if resolvedDOI == nil, let doi = pageMeta.doi, !doi.isEmpty {
                        article.doi = doi
                        resolvedDOI = doi
                        didUpdate = true
                    }
                    if article.paperAuthorNeedsEnrichment, let a = pageMeta.authorsDisplay, !a.isEmpty {
                        didUpdate = await applyMetadataAuthor(a, to: &article) || didUpdate
                    }
                    if article.paperJournalNeedsEnrichment, let j = pageMeta.journal, !j.isEmpty {
                        article.journal = j
                        didUpdate = true
                    }
                    if article.paperYearNeedsEnrichment, let y = pageMeta.year, !y.isEmpty {
                        article.publishedYear = y
                        didUpdate = true
                    }
                }

                if resolvedDOI == nil, let urlDOI = PaperService.extractDOI(from: article.url) {
                    article.doi = urlDOI
                    resolvedDOI = urlDOI
                    didUpdate = true
                }

                let canLookupByTitle = !Self.titleNeedsResolution(
                    resolvedTitle,
                    domain: article.domain,
                    url: article.url
                )
                if resolvedDOI != nil || canLookupByTitle {
                    if let meta = await PaperService.fetchPaperMetadata(
                        url: article.url,
                        title: resolvedTitle,
                        doi: resolvedDOI
                    ) {
                        if let t = meta.title, !t.isEmpty,
                           Self.titleNeedsResolution(article.title, domain: article.domain, url: article.url) {
                            article.title = t
                            resolvedTitle = t
                            didUpdate = true
                        }
                        if article.doi == nil, let doi = meta.doi, !doi.isEmpty {
                            article.doi = doi
                            resolvedDOI = doi
                            didUpdate = true
                        }
                        if article.paperAuthorNeedsEnrichment, let a = meta.authorsDisplay, !a.isEmpty {
                            didUpdate = await applyMetadataAuthor(a, to: &article) || didUpdate
                        }
                        if article.paperJournalNeedsEnrichment, let j = meta.journal, !j.isEmpty {
                            article.journal = j; didUpdate = true
                        }
                        if article.paperYearNeedsEnrichment, let y = meta.year, !y.isEmpty {
                            article.publishedYear = y; didUpdate = true
                        }
                    }
                }
            }

            // ── Placeholders for anything still missing ──
            if article.paperAuthorNeedsEnrichment {
                article.author = StudioArticle.unknownPaperAuthor; didUpdate = true
            }
            if article.paperJournalNeedsEnrichment {
                article.journal = StudioArticle.unknownPaperJournal; didUpdate = true
            }
            if article.paperYearNeedsEnrichment {
                article.publishedYear = StudioArticle.unknownPaperYear; didUpdate = true
            }

            if didUpdate {
                let patch = PaperMetadataBackfillPatch(original: original, candidate: article)
                do {
                    if try await storage.mergePaperMetadataBackfill(patch) != nil {
                        if let writeIdx = articles.firstIndex(where: { $0.id == articleId }) {
                            var current = articles[writeIdx]
                            if patch.apply(to: &current) {
                                articles[writeIdx] = current
                            }
                        }
                        savedCount += 1
                    }
                } catch {
                    logger.error("Failed to merge backfilled paper metadata for \(articleId): \(error.localizedDescription)")
                    showToast("Paper metadata save failed: \(error.localizedDescription)")
                }
            }

            // ── The identity checks that could not run before this point ──
            // Both need the real title, which is what this pass just resolved.
            // Attaching a PDF folds equivalent rows together, but that happens
            // before extraction, when the row is still named after its file; a
            // paper whose only shared identity is its title therefore slipped
            // past and sat next to its twin in the library.
            var shouldMerge = titleWasUnresolved
                && !Self.titleNeedsResolution(
                    article.title,
                    domain: article.domain,
                    url: article.url
                )
            // A preprint may also have been published since it was posted, which
            // is an identity no local comparison can see.
            if resolvesPublishedVersionIdentity,
               PaperService.isPreprintPaper(url: article.url, journal: article.journal),
               await resolvePublishedVersionsForPreprints(onlyIds: [articleId]) > 0 {
                shouldMerge = true
            }
            if shouldMerge {
                await mergePaperIntoBestEquivalent(articleId)
            }
        }
        if savedCount > 0 {
            logger.info("Backfilled paper metadata for \(savedCount) papers")
        }
    }

    /// A YouTube video's thumbnail comes from its id, with no fetch; any other
    /// video (Vimeo, Loom, a talk on a conference site) has only its page's
    /// og:image, as an article does, and without it the row drew a bare play
    /// icon.
    func shouldBackfillArtwork(for article: StudioArticle) -> Bool {
        article.artworkURL == nil
        && article.url.hasPrefix("http")
        && (article.sourceType == .article || article.sourceType == .manual || article.sourceType == .paper || article.sourceType == .unclassified
            || (article.sourceType == .video && article.youtubeThumbnailURL == nil))
    }

    nonisolated private static func fetchArtworkBackfillResults(
        for candidates: [ArtworkBackfillCandidate]
    ) async -> [ArtworkBackfillResult] {
        var results: [ArtworkBackfillResult] = []
        results.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let imageURL = await fetchArtworkURL(for: candidate.url) {
                results.append(ArtworkBackfillResult(id: candidate.id, artworkURL: imageURL))
            }
        }

        return results
    }

    nonisolated private static func fetchArtworkURL(for url: URL) async -> String? {
        do {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            let head = String(data: data.prefix(32_768), encoding: .utf8) ?? ""
            return Self.extractOGImage(from: head, baseURL: url)
        } catch {
            return nil
        }
    }

    /// Extract og:image or twitter:image content from an HTML <head> snippet,
    /// each tag read on its own in either attribute order (`HTMLTagAttributes`).
    nonisolated static func extractOGImage(from html: String, baseURL: URL? = nil) -> String? {
        let metas = HTMLTagAttributes.tags(named: "meta", in: html)
        for (attribute, value) in [("property", "og:image"), ("name", "twitter:image"), ("property", "twitter:image")] {
            for tag in metas where tag[attribute]?.lowercased() == value {
                guard let rawURL = tag["content"], !rawURL.isEmpty else { continue }
                if let resolved = resolveArtworkURL(rawURL, baseURL: baseURL) {
                    return resolved
                }
            }
        }
        return nil
    }

    nonisolated private static func resolveArtworkURL(_ rawURL: String, baseURL: URL?) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absolute = URL(string: trimmed), let scheme = absolute.scheme, scheme.hasPrefix("http") {
            return absolute.absoluteString
        }

        if trimmed.hasPrefix("//"), let baseURL {
            return "\(baseURL.scheme ?? "https"):\(trimmed)"
        }

        guard let baseURL,
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let scheme = resolved.scheme, scheme.hasPrefix("http") else {
            return nil
        }
        return resolved.absoluteString
    }

    #if canImport(PDFKit)
    /// Off-main PDF-DOI dedup scan: opens each candidate PDF and returns the title
    /// of the first whose DOI matches the target. Runs in a detached task so
    /// `addArticle` never opens PDFs on the main actor.
    nonisolated static func firstPaperTitleMatchingPDFDOI(
        normalizedTargetDOI: String,
        candidates: [(title: String, path: String)]
    ) -> String? {
        for candidate in candidates {
            if let doi = extractDOIFromPDF(at: candidate.path),
               normalizeDOI(doi) == normalizedTargetDOI {
                return candidate.title
            }
        }
        return nil
    }
    #endif

    /// The address `addArticle` files a typed or pasted link under: trimmed,
    /// given https:// when it names no scheme (a local path keeps its slash),
    /// and a Teachable lecture's navigation query dropped — a lecture is
    /// identified by its course and lecture path. Nil for blank text.
    nonisolated static func normalizedSourceAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        if !normalized.hasPrefix("http://") && !normalized.hasPrefix("https://") && !normalized.hasPrefix("/") {
            normalized = "https://\(normalized)"
        }
        if TeachableCourseService.isLectureURL(normalized), let lectureURL = URL(string: normalized) {
            normalized = TeachableCourseService.canonicalLectureURL(lectureURL).absoluteString
        }
        return normalized
    }

    /// Adds a source from a URL.
    ///
    /// `revealInReader` decides whether the new source takes the reader over. Pasting a URL
    /// into the sources panel means "show me this". Adding a paper cited by the video you are
    /// watching does not — swapping the video out on that click loses your place in the talk
    /// the citation came from, which is the one thing the click was not asking for.
    /// `waitForInitialPaperProcessing` lets a caller keep its own progress UI active until the
    /// newly inserted paper leaves the initial PDF-resolution and metadata pipeline. Normal URL
    /// entry stays optimistic and runs that work in the background.
    /// `reviveArchivedSourceIfNeeded` is reserved for an explicit user re-add. Passive discovery
    /// must leave dismissal tombstones alone, but a newer Add to Library click may restore the
    /// archived row and its already-downloaded paper file.
    /// A supplied Zoom passcode is handed to the transcript flow, which saves it
    /// in Keychain rather than source metadata before the recording page needs it.
    func addArticle(
        url: String,
        revealInReader: Bool = true,
        zoomPasscode: String? = nil,
        waitForInitialPaperProcessing: Bool = false,
        reviveArchivedSourceIfNeeded: Bool = false
    ) async throws {
        guard let normalized = Self.normalizedSourceAddress(url) else { return }

        // A page ForeverLM links rather than scrapes is never a source, on this
        // route or any other: the source bar, a browser pane's Add to Sources, a
        // chat or reader link, a journal suggestion, a reference card all come
        // through here. It lands where its kind belongs — a Codex site, Claude
        // artifact or ForeverLM site in Sites, a Google Doc in Docs — before any
        // classification could make an article of it. Callers that look for the
        // new row in `articles` afterwards read why there is none from
        // `errorMessage`, the channel a duplicate already reports through.
        if let kind = Self.linkedPageKind(forSourceURL: normalized) {
            _ = try await linkPage(urlString: normalized, homeNotebookID: nil, linkedNotebookIDs: [])
            urlInput = ""
            errorMessage = "That is a \(kind.label): it is linked in \(kind.section.title), not added as a source."
            return
        }
        // Some addresses are never sources at all (Convoke query results,
        // the product owner 2026-09-12); the reason reaches the caller the way a
        // duplicate does, and the typed URL stays for the learner to see.
        if let refusal = Self.sourceRefusal(forSourceURL: normalized) {
            errorMessage = refusal
            return
        }
        // A Gemini Notebook is a whole notebook, not a page: read as an
        // article it would be Google's sign-in. Its sources, chats and notes
        // come in as a Notebook instead (`importGeminiNotebook`).
        if GeminiNotebookService.isNotebookURL(normalized) {
            await importGeminiNotebook(url: normalized, revealNotebook: revealInReader)
            return
        }

        // Check for duplicates — exact URL match
        guard !articles.contains(where: { $0.url == normalized }) else {
            errorMessage = "This URL is already in your reading list."
            return
        }

        // An explicit Add to Sources click supersedes an older removal on any
        // device. Record that intent before insertion even when this Mac has not
        // received the old dismissal yet; otherwise its delayed CloudKit record
        // can arrive during PDF cleanup and silently archive the new paper.
        if reviveArchivedSourceIfNeeded {
            try await storage.prepareExplicitSourceReAdd(normalized)
        }

        // For paper URLs, run multi-layer duplicate detection:
        // 1) DOI-based: extract DOI from the new URL and compare against all
        //    existing papers. A saved preprint's published DOI does not count:
        //    the journal version arriving second is a new version, not a copy
        // 2) Filename-based: predicted filename vs local PDF filenames
        // 3) Title-based: normalized title vs existing paper titles
        let detectedTypeEarly = Self.detectSourceType(url: normalized)
        if detectedTypeEarly == .paper && normalized.hasPrefix("http") {
            // DOI-based dedup. The cheap URL-DOI comparison runs on main; the
            // PDF-DOI scan (which opens a PDFDocument per existing paper) is
            // snapshotted and run off the main actor to avoid a launch beachball.
            if let newDOI = PaperService.extractDOI(from: normalized) {
                let normalizedNewDOI = Self.normalizeDOI(newDOI)
                var pdfCandidates: [(title: String, path: String)] = []
                for article in articles where article.sourceType == .paper {
                    // A saved preprint that has since been published carries the
                    // journal DOI the user is pasting now. That is not a
                    // duplicate: the journal version is its own paper, kept
                    // beside the preprint (`paperVersionKind`), so only a paper
                    // that holds this very DOI stops the add.
                    if let existingDOI = PaperService.extractDOI(from: article.url) {
                        if Self.normalizeDOI(existingDOI) == normalizedNewDOI {
                            let existingTitle = article.title.isEmpty ? article.domain : article.title
                            errorMessage = "This paper is already in your reading list: \"\(existingTitle)\""
                            return
                        }
                        // A non-matching URL DOI is authoritative; skip the PDF scan.
                        continue
                    }
                    #if canImport(PDFKit)
                    if let path = article.localFilePath ?? (article.url.hasPrefix("/") ? article.url : nil) {
                        pdfCandidates.append((title: article.title.isEmpty ? article.domain : article.title, path: path))
                    }
                    #endif
                }
                #if canImport(PDFKit)
                if !pdfCandidates.isEmpty {
                    let matchedTitle = await Task.detached(priority: .userInitiated) {
                        Self.firstPaperTitleMatchingPDFDOI(normalizedTargetDOI: normalizedNewDOI, candidates: pdfCandidates)
                    }.value
                    if let matchedTitle {
                        errorMessage = "This paper is already in your reading list: \"\(matchedTitle)\""
                        return
                    }
                }
                #endif
            }

            // Filename-based dedup
            let proposedFilename = Self.normalizedPaperFilename(Self.paperFilename(from: normalized))
            let localPDFFilenames = Set(
                articles
                    .filter { $0.sourceType == .paper && $0.isPDF }
                    .compactMap { article -> String? in
                        if let localFilePath = article.localFilePath {
                            return (localFilePath as NSString).lastPathComponent
                        }
                        return article.url.hasPrefix("/") ? (article.url as NSString).lastPathComponent : nil
                    }
                    .map(Self.normalizedPaperFilename)
            )
            if localPDFFilenames.contains(proposedFilename) {
                errorMessage = "This paper is already in your reading list as a local PDF."
                return
            }
            // The LLM-based semantic dedup that used to run here now runs in the
            // background after the optimistic insert below, so a slow AI round-trip
            // no longer delays the paper (and its "Downloading PDF…" status) from
            // appearing. See the paper post-insert block near the end of addArticle.
        }

        // A YouTube playlist is a course: pasting a playlist URL on any tab
        // imports it as a lecture series and lands on the Courses tab. Playlist
        // groups in Videos remain unsupported. The plugin's specially named
        // ForeverLM playlist is discovered through OAuth instead.
        if YouTubePlaylistService.isPlaylistURL(normalized) {
            await importYouTubePlaylist(url: normalized)
            return
        }

        // Detect source type from URL
        let detectedType = Self.detectSourceType(url: normalized)
        let domain = URL(string: normalized)?.host ?? normalized

        // Podcast URLs must never be stored directly — only local transcripts are valid.
        // Search for the matching Apple Podcasts episode instead.
        if detectedType == .podcast && normalized.hasPrefix("http") {

            var article = StudioArticle(url: normalized, title: domain, sourceType: .podcast, discoveryOrigin: .manual)
            article.domain = domain
            guard try await storage.insertSourceIfNew(&article) else {
                errorMessage = "This podcast is already in your library or was previously removed."
                return
            }
            articles.insert(article, at: 0)
            urlInput = ""
            if revealInReader, selectedArticleId == nil { selectedArticleId = article.id }
            let articleId = article.id
            Task { await self.findAndOfferPodcast(for: articleId) }
            return
        }

        let origin: DiscoveryOrigin = .manual
        // For direct PDF URLs, use a cleaned filename as initial title instead of the raw domain
        let initialTitle = Self.titleFromPDFURL(normalized) ?? domain
        var article = StudioArticle(url: normalized, title: initialTitle, sourceType: detectedType, discoveryOrigin: origin)
        article.domain = domain
        article.artworkURL = article.youtubeThumbnailURL
        if detectedType == .paper {
            article.doi = PaperService.extractDOI(from: normalized)
        }
        // A Zoom recording is typed `.meeting` by `detectSourceType`, and every
        // meeting reaches its tab through a series — so give it one before the
        // insert rather than leaving a session no list can show.
        await assignZoomMeetingSeries(to: &article, explicit: true)

        var inserted = try await storage.insertSourceIfNew(&article)
        if !inserted, reviveArchivedSourceIfNeeded {
            if let revivedID = try await storage.unarchiveSourceMatchingURL(
                normalized,
                clearingDismissal: true
            ), let revived = try await storage.loadPersistedSources(ids: [revivedID]).first {
                // Claim the row for Processing before publishing it. Publishing first
                // briefly places the same stable row ID in Papers Needing Attention,
                // then moves it into Processing; macOS List can retain both AppKit
                // cells during that cross-section move, producing a white flash and
                // an apparent duplicate even though SQLite contains one source.
                if revived.sourceType == .paper,
                   !waitForInitialPaperProcessing {
                    pendingPaperProcessingIds.insert(revivedID)
                }
                articles.removeAll { $0.id == revivedID }
                articles.insert(revived, at: 0)
                urlInput = ""
                errorMessage = nil

                if revived.sourceType == .paper {
                    if sidebarTab != .papers {
                        switchTab(to: .papers)
                    }
                    if revealInReader {
                        selectedArticleId = revivedID
                        selectedArticleIds = [revivedID]
                    }
                    if waitForInitialPaperProcessing {
                        _ = await autoResolveNewPaperPDF(for: revivedID)
                        await backfillPaperMetadata(onlyIds: [revivedID])
                    } else {
                        Task {
                            enqueueAutoPaperFetch(revivedID)
                            await backfillPaperMetadata(onlyIds: [revivedID])
                        }
                    }
                } else {
                    if revealInReader, selectedArticleId == nil {
                        selectedArticleId = revivedID
                    }
                    autoFetchUnfetchedSources()
                }
                return
            }

            // A dismissal can outlive a source row. Clearing that tombstone is
            // still meaningful, so retry the insert once before reporting that
            // the source already exists.
            inserted = try await storage.insertSourceIfNew(&article)
        }
        guard inserted else {
            errorMessage = "This source is already in your library or was previously removed."
            return
        }
        // Like local-PDF import's `attachingPDFIds`, this marker must precede
        // the first observable insertion. Otherwise the row is first rendered in
        // Papers Needing Attention and immediately relocated to Processing. A
        // dynamic macOS List can momentarily draw both locations for that one ID.
        if detectedType == .paper,
           normalized.hasPrefix("http"),
           !waitForInitialPaperProcessing {
            pendingPaperProcessingIds.insert(article.id)
        }
        articles.insert(article, at: 0)
        urlInput = ""

        // The tab switch happens either way: a paper that just landed in the library should
        // be findable where papers live, and switching tabs no longer disturbs the reader.
        if detectedType == .paper {
            if sidebarTab != .papers {
                switchTab(to: .papers)
            }
            if revealInReader {
                selectedArticleId = article.id
                // Paired with the line above: switching to Papers re-selects whatever the
                // reader already held, and leaving that would highlight one paper in the
                // list while the reader shows another.
                selectedArticleIds = [article.id]
            }
        } else if revealInReader, selectedArticleId == nil {
            selectedArticleId = article.id
        }

        // YouTube URL → fetch transcript directly. The user pasted this exact
        // video, so it formats even when its channel is hidden.
        if YouTubeTranscriptService.isYouTubeURL(normalized) {
            let articleId = article.id
            Task { await refreshYouTubeMetadata(for: articleId) }
            Task { await fetchYouTubeTranscript(for: articleId, userInitiated: true) }
        }

        // Teachable lecture → download its audio and transcribe it. The course
        // as a whole is `importTeachableCourse` (`import_teachable_course`).
        if TeachableCourseService.isLectureURL(normalized) {
            let articleId = article.id
            Task { await fetchTeachableTranscript(for: articleId) }
        }

        // One-off Zoom recording link → fetch Zoom's transcript (or transcribe
        // the recording locally). Passcode-protected recordings surface an
        // error that points at the "Enter Zoom Passcode…" context-menu action.
        // The row is a meeting session by now, so pin Meetings the way any
        // learner-initiated arrival does; a Read AI push still must not.
        if ZoomRecordingService.isZoomRecordingURL(normalized) {
            let articleId = article.id
            let suppliedPasscode = zoomPasscode?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                // The session waits for Zoom's transcript rather than the
                // recording being downloaded at once; the check asks again.
                await fetchZoomTranscript(
                    for: articleId,
                    passcode: suppliedPasscode?.isEmpty == false ? suppliedPasscode : nil,
                    request: .automatic
                )
            }
        }

        // Papers get provisional metadata immediately, then one automatic attempt
        // to obtain the PDF so the user doesn't have to click "papers needing
        // attention" for every new paper. The bulk button remains available for
        // retries; this runs once per newly added paper.
        if detectedType == .paper && normalized.hasPrefix("http") {
            let articleId = article.id

            if waitForInitialPaperProcessing {
                // Reader toolbars own a visible in-progress state. Run this paper's
                // one-shot pipeline inline so their completion checkmark cannot race
                // ahead of the Processing row in the library.
                _ = await autoResolveNewPaperPDF(for: articleId)
                await backfillPaperMetadata(onlyIds: [articleId])
            } else {
                // Enqueue the PDF fetch *before* the metadata backfill so the
                // "Downloading PDF…" status appears instantly instead of waiting on a
                // scholarly-metadata network lookup that the download doesn't depend on.
                Task {
                    enqueueAutoPaperFetch(articleId)
                    await backfillPaperMetadata(onlyIds: [articleId])
                }
            }

            // Do not run fuzzy duplicate detection here. A similarity judgment is
            // not a stable source identity, and letting one undo this explicit add
            // can delete a distinct paper after the toolbar has reported success.
            // The deterministic URL, DOI, and filename checks above remain the
            // ingestion gate; the user-invoked duplicate review remains available
            // for ambiguous titles. A preprint arriving before its journal version
            // is the one relationship no local check can see, so the metadata
            // backfill resolves that DOI from the catalogs and merges on the
            // identifier it gets back — never on a similarity score.
        }
    }

    /// Search for an Apple Podcasts episode matching a source.
    func findAndOfferPodcast(for articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        let urlString = articles[idx].url
        let title = articles[idx].title

        articles[idx].state = .fetching

        // Search for matching podcast on Apple Podcasts. An Apple Podcasts
        // episode link names its episode, so it is looked up, not searched for.
        let match: PodcastFinderService.PodcastMatch?
        let linkNamesEpisode = PodcastFinderService.applePodcastsEpisodeIdentity(fromURL: urlString) != nil
        if linkNamesEpisode {
            match = await PodcastFinderService.shared.findPodcast(forApplePodcastsURL: urlString)
        } else if YouTubeTranscriptService.isYouTubeURL(urlString) {
            match = await PodcastFinderService.shared.findPodcast(forYouTubeURL: urlString)
        } else {
            // For web URLs (simplecast, podcast landing pages, etc.), search by article title
            match = await PodcastFinderService.shared.findPodcast(byTitle: title)
        }

        guard let match else {
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx2].state = .error
            articles[idx2].errorMessage = "No matching podcast found on Apple Podcasts."
            try? await storage.saveSource(articles[idx2])
            return
        }
        // The link named this episode: there is nothing to confirm.
        await offerPodcastMatch(match, for: articleId, confirmingAtOnce: linkNamesEpisode)
    }

    /// An episode staged for a source's confirmation (`stagedPodcastMatches`).
    struct StagedPodcastMatch: Equatable {
        let info: PodcastMatchInfo
        let trackId: Int64?
        /// The show's picture as Apple lists it. A match read back off the
        /// row has none: the row keeps only `PodcastMatchInfo`.
        var artworkURL: String? = nil
    }

    /// The episode a source is waiting to have confirmed: the one staged for
    /// it, else the one its row holds.
    func heldPodcastMatch(for articleId: String) -> StagedPodcastMatch? {
        if let staged = stagedPodcastMatches[articleId] { return staged }
        guard let article = articles.first(where: { $0.id == articleId }),
              let info = article.podcastMatch else { return nil }
        return StagedPodcastMatch(info: info, trackId: article.podcastMatchTrackId)
    }

    enum PodcastMatchOffer: Equatable {
        case awaitingConfirmation
        case confirmed
        case alreadyInLibrary(title: String)
        case sourceGone
    }

    /// Holds a found episode on the source for the learner to confirm, or
    /// confirms it at once when nothing is in doubt. The match lives only
    /// here, on the article the reader's Confirm button reads — SQLite has no
    /// column for it — so `find_podcast_match` offers its match through this
    /// too, and `resolve_podcast_match` finds it where the learner would.
    @discardableResult
    func offerPodcastMatch(
        _ match: PodcastFinderService.PodcastMatch,
        for articleId: String,
        confirmingAtOnce: Bool
    ) async -> PodcastMatchOffer {
        // Check if this podcast episode already exists as another source
        let matchURL = match.applePodcastsURL
        let matchTitle = match.episodeTitle
        if let existing = articles.first(where: { $0.id != articleId && (
            $0.url == matchURL ||
            $0.podcastMatch?.applePodcastsURL == matchURL ||
            stagedPodcastMatches[$0.id]?.info.applePodcastsURL == matchURL ||
            $0.title == matchTitle
        )}) {
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return .sourceGone }
            articles[idx2].state = .error
            articles[idx2].errorMessage = "Already in your sources: \"\(existing.title)\""
            try? await storage.saveSource(articles[idx2])
            logger.info("Skipping duplicate podcast: \(matchTitle)")
            return .alreadyInLibrary(title: existing.title)
        }

        // Store the match for user confirmation — don't proceed until approved
        guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return .sourceGone }
        let info = PodcastMatchInfo(
            podcastName: match.podcastName,
            episodeTitle: match.episodeTitle,
            applePodcastsURL: match.applePodcastsURL
        )
        stagedPodcastMatches[articleId] = StagedPodcastMatch(
            info: info,
            trackId: match.storeTrackId,
            artworkURL: match.artworkURL
        )
        articles[idx2].podcastMatch = info
        articles[idx2].podcastMatchTrackId = match.storeTrackId
        articles[idx2].state = .error
        articles[idx2].statusFlag = .confirmPodcast
        try? await storage.saveSource(articles[idx2])
        if confirmingAtOnce {
            await confirmPodcastMatch(for: articleId)
            return .confirmed
        }
        logger.info("Awaiting user confirmation for podcast match: \(match.podcastName) — \(match.episodeTitle)")
        return .awaitingConfirmation
    }

    /// User confirmed the podcast match — proceed with transcript fetch.
    func confirmPodcastMatch(for articleId: String) async {
        guard articles.contains(where: { $0.id == articleId }) else { return }
        guard let held = heldPodcastMatch(for: articleId) else { return }
        stagedPodcastMatches[articleId] = nil
        guard await placeConfirmedPodcastEpisode(articleId, held: held) else { return }

        // Try to automatically fetch the transcript using the store track ID
        if let trackId = held.trackId {
            guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx].state = .fetching
            articles[idx].podcastMatchTrackId = nil
            try? await storage.saveSource(articles[idx])
            logger.info("Auto-fetching transcript for track ID \(trackId)")

            // The user just confirmed this specific episode, so it earns a
            // formatted transcript even if its show is hidden.
            if let candidate = podcastHydrationCandidate(for: articleId, userInitiated: true) {
                let storage = self.storage
                let aiService = self.aiService
                let homeDir = realHomeDirectory
                // Resolved once from Settings and threaded down, so every
                // transcript call uses the model the user picked.
                let config = KeychainService.resolveConfig(for: .transcriptFormatting)
                let result = await Task.detached(priority: .utility) {
                    await Self.hydratePodcastTranscript(
                        candidate,
                        storage: storage,
                        aiService: aiService,
                        homeDir: homeDir,
                        config: config
                    )
                }.value
                await applyPodcastHydrationResult(result)
                return
            }

            if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx2].state = .error
                articles[idx2].errorMessage = Self.noPodcastTranscriptMessage
                try? await storage.saveSource(articles[idx2])
            }
            return
        }

        // No track ID available — show "needs transcript" state
        guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
        articles[idx2].state = .error
        articles[idx2].statusFlag = .needsTranscript
        articles[idx2].podcastMatchTrackId = nil
        try? await storage.saveSource(articles[idx2])
    }

    /// What a confirmed match makes of its row before its transcript is
    /// fetched: the show's episode, named and drawn as the show's, at the
    /// Apple address its transcript lives under.
    ///
    /// The row is listed, searched and hidden under the show's name and
    /// drawn with its picture, not filed under the host its link was on
    /// ("podcasts.apple.com", no picture).
    ///
    /// A row filed under the episode's web page may hold that page's text:
    /// show notes, not what was said. Text under an Apple address is taken for
    /// the finished transcript (`hydratePodcastTranscript`), so the address
    /// must not change without the text going too. On 2026-10-02 three
    /// episodes an assistant had added over MCP with their pages as content
    /// were confirmed here and went ready on 45 to 525 words of show notes,
    /// no transcript ever fetched. The store moves such a row and drops what
    /// came from the page in one transaction, keeping the page as the
    /// episode's web page, as it does for a row the public-episode resolver
    /// places. A video matched to its episode keeps its text: its captions
    /// are what was said.
    ///
    /// False when the row is gone or could not be moved; a row whose episode
    /// another source already is says so, as `offerPodcastMatch` does.
    func placeConfirmedPodcastEpisode(_ articleId: String, held: StagedPodcastMatch) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        let match = held.info
        let textIsTranscript = articles[idx].sourceType == .video
        articles[idx].title = match.episodeTitle
        articles[idx].sourceType = .podcast
        articles[idx].errorMessage = nil
        let showName = match.podcastName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !showName.isEmpty {
            articles[idx].domain = showName
        }
        if articles[idx].artworkURL?.isEmpty != false,
           let artwork = held.artworkURL, !artwork.isEmpty {
            articles[idx].artworkURL = artwork
        }

        guard let trackId = held.trackId else { return true }
        let episodeURL = SourceDiscovery.podcastEpisodePlaceholderURL(trackId: trackId)
        let page = articles[idx].url
        guard Self.isWebPageAddress(page), !textIsTranscript else {
            articles[idx].url = episodeURL
            articles[idx].normalizedURL = URLNormalizer.normalize(episodeURL)
            return true
        }
        let webPageURL = articles[idx].podcastWebPageURL
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? page
        do {
            // An article confirmed as an episode (find_podcast_match takes any
            // source) has no podcast row yet for the store to move: it is
            // filed as the show's episode first, still at its page.
            try await storage.saveSource(articles[idx])
            try await storage.rebindPodcastEpisodeIdentity(
                articleId,
                toPublicURL: episodeURL,
                webPageURL: webPageURL
            )
        } catch KnowledgeStoreError.duplicateSourceIdentity(let existingSourceID) {
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return false }
            let existingTitle = articles.first(where: { $0.id == existingSourceID })?.title
                ?? articles[idx2].title
            articles[idx2].state = .error
            articles[idx2].errorMessage = "Already in your sources: \"\(existingTitle)\""
            try? await storage.saveSource(articles[idx2])
            return false
        } catch {
            logger.warning("Could not move podcast row \(articleId, privacy: .public) to episode \(trackId): \(error.localizedDescription, privacy: .public)")
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return false }
            articles[idx2].state = .error
            articles[idx2].errorMessage = Self.retryablePodcastTranscriptMessage
            try? await storage.saveSource(articles[idx2])
            return false
        }
        // Storage holds the episode's address and no page text; the
        // in-memory row must agree before the save that follows, or it
        // writes the page and its text back.
        guard let moved = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        articles[moved].url = episodeURL
        articles[moved].normalizedURL = URLNormalizer.normalize(episodeURL)
        articles[moved].podcastWebPageURL = webPageURL
        articles[moved].content = nil
        articles[moved].wordCount = 0
        // An article's saved copy of its page is the page too, and a local
        // document is read before the podcast's transcript is looked for.
        if articles[moved].cachedIsArchivedArticle {
            articles[moved].localFilePath = nil
        }
        return true
    }

    /// User rejected the podcast match — clear it.
    func rejectPodcastMatch(for articleId: String) async {
        stagedPodcastMatches[articleId] = nil
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        articles[idx].podcastMatch = nil
        articles[idx].podcastMatchTrackId = nil
        articles[idx].state = .queued
        articles[idx].errorMessage = nil
        try? await storage.saveSource(articles[idx])
    }

    func removeArticle(id: String) async {
        await removeSelected([id])
    }

    /// Mark a source as paywalled so the recovery UI appears.
    func markPaywalled(_ article: StudioArticle) async {
        await markPaywalled(articleId: article.id, evidence: nil, showEvidenceToast: false)
    }

    func markPaywalled(articleId: String, evidence: String?, showEvidenceToast: Bool) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        var updated = articles[idx]
        updated.state = updated.sourceType == .paper ? .error : .ready
        updated.statusFlag = .paywall
        updated.isPaywalled = true
        // The question the suspicion asked is answered.
        updated.paywallSuspicion = nil
        if await persistSource(updated, context: "Save paywall status", syncImmediately: true) {
            if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx2] = updated
            }
            if showEvidenceToast, let evidence, !evidence.isEmpty {
                showToast("Marked paywalled: \(evidence)")
            } else {
                showToast(updated.sourceType == .paper ? "Marked paper as paywalled" : "Marked as paywalled")
            }
        }
    }

    /// Keep what the AI browser saw when it thought a paper was paywalled but
    /// could not prove it. Nothing else about the paper changes: it stays in
    /// "Papers that need attention", where its row now offers Mark as
    /// Paywalled with this reason behind it. Quiet on purpose — the batch
    /// summary and the row speak for it. A paper already marked has nothing
    /// to suspect.
    func recordPaywallSuspicion(articleId: String, reason: String) async {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = articles.firstIndex(where: { $0.id == articleId }),
              articles[idx].sourceType == .paper,
              !articles[idx].hasPaywallMarker,
              articles[idx].paywallSuspicion != trimmed else { return }
        var updated = articles[idx]
        updated.paywallSuspicion = trimmed
        if await persistSource(updated, context: "Save paywall suspicion") {
            if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx2].paywallSuspicion = trimmed
            }
        }
    }

    /// Clear a manually or automatically assigned paywall marker.
    func clearPaywalledStatus(for articleId: String) async {
        await clearPaywalledStatus(for: [articleId])
    }

    /// Clear paywall markers for one or more sources.
    func clearPaywalledStatus(for articleIds: [String]) async {
        let ids = Array(Set(articleIds))
        guard !ids.isEmpty else { return }

        var clearedCount = 0
        for id in ids {
            guard let idx = articles.firstIndex(where: { $0.id == id }) else { continue }
            var updated = articles[idx]
            guard updated.hasPaywallMarker else { continue }

            updated.isPaywalled = false
            // The learner has ruled; the browser's hunch does not get a rerun.
            updated.paywallSuspicion = nil
            if updated.statusFlag == .paywall {
                updated.errorMessage = nil
                // Attestation is metadata only — author, venue, year. A paper can
                // carry all three and still hold no body text at all, which is how
                // paywalled papers used to come back as `ready` and then fail at
                // the point of use, in the car. Readable text is the precondition
                // for `ready`; without it the source belongs in the queue.
                let hasText = await storage.hasReadableSourceContent(updated.id)
                updated.state = updated.sourceType == .paper
                    && !(updated.hasPaperIngestionAttestation && hasText)
                    ? .queued
                    : .ready
            }

            if await persistSource(updated, context: "Remove paywall status", syncImmediately: true) {
                if let idx2 = articles.firstIndex(where: { $0.id == id }) {
                    articles[idx2] = updated
                }
                clearedCount += 1
            }
        }

        if clearedCount > 0 {
            showToast(clearedCount == 1 ? "Removed paywalled status" : "Removed paywalled status from \(clearedCount) sources")
        }
    }

    func loadPodcastRawTTML(for sourceId: String) async -> String? {
        try? await storage.loadPodcastRawTTML(sourceId)
    }

    func shouldSearchForPaperAlternative(_ article: StudioArticle) -> Bool {
        guard article.sourceType == .paper else { return false }
        guard article.url.hasPrefix("http") else { return false }
        if PaperService.extractPMCID(from: article.url) != nil { return false }
        return true
    }

    /// Try each open-access copy of the paper in turn, swapping its address
    /// onto the row for `downloadPaperPDF`. Every file is held to `identity`,
    /// the paper as it stood before the first swap: a copy that is some other
    /// paper is turned away and the next is tried. When none attaches, the row
    /// is put back, and with `markFailure` its message names each file that
    /// was turned away. Without it the caller owns the row's state (a
    /// paywalled row's `errorMessage` is its paywall flag) and reads the files
    /// from `identity`.
    @discardableResult
    func adoptOpenAccessAlternativeIfAvailable(
        for articleId: String,
        userInitiated: Bool = true,
        markFailure: Bool = true,
        forceMetadataExtractionForMissingAuthor: Bool = false,
        identity: PaperPDFIdentityGate? = nil
    ) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return false }
        let article = articles[idx]
        guard shouldSearchForPaperAlternative(article) else { return false }
        let alternatives = await PaperService.findOpenAccessAlternatives(
            url: article.url,
            title: article.title,
            doi: article.doi
        )
        guard !alternatives.isEmpty else { return false }

        let original = article
        let oldURL = article.url
        let gate = identity ?? PaperPDFIdentityGate(article: original)
        for (attempt, alternative) in alternatives.enumerated() {
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return true }
            articles[idx2] = original
            // What an earlier candidate saved goes too (`SourceEdits`).
            if attempt > 0 { articles[idx2].edits.noteAll() }
            articles[idx2].url = alternative.replacementURL
            articles[idx2].domain = alternative.sourceName
            articles[idx2].content = nil
            articles[idx2].wordCount = nil
            articles[idx2].localFilePath = nil
            articles[idx2].isPaywalled = false
            articles[idx2].errorMessage = nil
            if userInitiated {
                articles[idx2].state = .fetching
                await storage.clearSourceDerivedData(articleId)
                try? await storage.saveSource(articles[idx2], syncImmediately: true)
            }
            logger.info("Trying paper OA candidate: \(oldURL) → \(alternative.replacementURL)")

            let result = await downloadPaperPDF(
                for: articleId,
                userInitiated: userInitiated,
                forceMetadataExtractionForMissingAuthor: forceMetadataExtractionForMissingAuthor,
                identity: gate
            )
            if result.success {
                if !userInitiated,
                   let idx3 = articles.firstIndex(where: { $0.id == articleId }),
                   articles[idx3].resolvedPDFPath != nil {
                    await storage.clearSourceDerivedData(articleId)
                }
                if let idx3 = articles.firstIndex(where: { $0.id == articleId }),
                   Self.titleNeedsResolution(articles[idx3].title, domain: articles[idx3].domain, url: articles[idx3].url) {
                    await extractPaperTitle(for: articleId)
                }
                return true
            }
            logger.info("Paper OA candidate was not downloadable or was another paper; continuing to the next candidate")
        }

        guard let idx3 = articles.firstIndex(where: { $0.id == articleId }) else { return true }
        articles[idx3] = original
        // The candidates' saves left their own address and state on the row; putting the original
        // back changes them again, and a save writes only what its copy changed (`SourceEdits`).
        articles[idx3].edits.noteAll()
        if markFailure {
            articles[idx3].state = .error
            articles[idx3].errorMessage = Self.openAccessFailureMessage(turnedAway: gate.rejections)
            try? await storage.saveSource(articles[idx3])
        }
        return true
    }

    /// What a paper whose open-access copies all failed says on its row. Each
    /// file turned away as some other paper is named, so the learner sees why
    /// a PDF that was found was not used.
    nonisolated static func openAccessFailureMessage(turnedAway rejections: [PaperPDFIdentityMismatchError]) -> String {
        guard !rejections.isEmpty else {
            return "Found open-access copies, but none returned a readable PDF. Attach the PDF manually."
        }
        let named = rejections.compactMap(\.errorDescription).map { $0.hasSuffix(".") ? $0 : $0 + "." }
        return (["Found open-access copies, but none of the PDFs found was this paper."] + named + ["Attach the PDF manually."])
            .joined(separator: " ")
    }

    /// Attempt to fetch article content from archive.ph and transition out of paywall state.
    func fetchFromArchive(articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        let urlString = articles[idx].url
        articles[idx].state = .fetching
        do {
            let content = try await SourceService.shared.fetchArchiveContent(for: urlString)
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx2].content = content
            articles[idx2].wordCount = content.split(separator: " ").count
            if articles[idx2].sourceType == .paper {
                articles[idx2].prepareForPaperMetadataExtraction()
            } else {
                articles[idx2].state = .ready
                articles[idx2].errorMessage = nil
            }
            let updated = articles[idx2]
            let needsPaperMetadata = updated.sourceType == .paper
            try? await storage.saveSource(updated, syncImmediately: true)
            if needsPaperMetadata {
                _ = await extractPaperMetadataWithAI(id: articleId, showToasts: true)
            }
        } catch {
            guard let idx2 = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[idx2].state = articles[idx2].sourceType == .paper ? .error : .ready
            articles[idx2].statusFlag = .paywall
            articles[idx2].isPaywalled = true
            try? await storage.saveSource(articles[idx2], syncImmediately: true)
        }
    }

    /// Remove all episodes from a specific podcast show, and stop importing it.
    ///
    /// The block is the point. Removal alone tombstones the episodes that exist
    /// right now, so the show returns the moment the learner plays another
    /// episode of it — which is exactly what happens with a show they remove
    /// *because* it was never study material. Undo puts both back.
    func removeAllFromPodcast(_ podcastName: String) async {
        let trimmed = podcastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !hasPendingDeletion(forDeletionKey: Self.podcastShowRemovalKey(trimmed)) else { return }
        let removed = articles.filter { $0.sourceType == .podcast && $0.domain == trimmed }
        let removedIDs = Set(removed.map(\.id))
        let wasHidden = hiddenPodcastShows.contains(trimmed)
        let wasBlocked = isPodcastShowBlocked(trimmed)
        let priorSelectedArticleID = selectedArticleId
        let priorSelectedArticleIDs = selectedArticleIds

        do {
            try await storage.setPodcastShowHidden(trimmed, hidden: true)
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to remove podcast show: \(error.localizedDescription)")
            return
        }
        hiddenPodcastShows.insert(trimmed)
        blockPodcastShow(trimmed, silently: true)
        visiblePodcastEpisodeOverrideIDs.subtract(removedIDs)
        deselectSourcesInEveryWindow(removedIDs)
        if selectedArticle?.sourceType == .podcast && selectedArticle?.domain == trimmed {
            selectedArticleId = articles.first(where: {
                $0.domain != trimmed && !isSourceHidden($0)
            })?.id
            currentCardIndex = 0
        }

        deferDeletion(
            message: "Removed “\(trimmed)” — new episodes won’t be imported",
            sourceIDs: removedIDs,
            deletionKey: Self.podcastShowRemovalKey(trimmed),
            gracePeriod: deletionGracePeriod,
            undo: { [weak self] in
                guard let self else { return }
                do {
                    try await self.storage.setPodcastShowHidden(trimmed, hidden: wasHidden)
                    if wasHidden {
                        self.hiddenPodcastShows.insert(trimmed)
                    } else {
                        self.hiddenPodcastShows.remove(trimmed)
                    }
                    if !wasBlocked {
                        self.unblockPodcastShow(trimmed, silently: true)
                    }
                    self.selectedArticleId = priorSelectedArticleID
                    self.selectedArticleIds = priorSelectedArticleIDs
                } catch {
                    self.logger.error("Failed to undo podcast removal: \(error.localizedDescription)")
                    self.showToast("Undo failed for “\(trimmed)”: \(error.localizedDescription)")
                }
            },
            commit: { [weak self] in
                guard let self else { return }
                do {
                    try await self.storage.dismissSources(removed)
                    for id in removedIDs {
                        try await self.storage.archiveSource(id)
                    }
                    try await self.storage.setPodcastShowHidden(trimmed, hidden: false)
                    self.hiddenPodcastShows.remove(trimmed)
                    self.articles.removeAll { removedIDs.contains($0.id) }
                } catch {
                    try? await self.storage.setPodcastShowHidden(trimmed, hidden: wasHidden)
                    if wasHidden {
                        self.hiddenPodcastShows.insert(trimmed)
                    } else {
                        self.hiddenPodcastShows.remove(trimmed)
                    }
                    self.logger.error("Failed to finalize podcast removal: \(error.localizedDescription)")
                    self.showToast("Removing “\(trimmed)” failed: \(error.localizedDescription)")
                }
            }
        )
    }

    /// Permanently remove a show selected from Hidden Items, with the same Undo
    /// grace period as a removal initiated from the main podcast list.
    func removeHiddenPodcastShow(_ podcastName: String) async {
        await removeAllFromPodcast(podcastName)
    }

    /// Shows the learner hid, less one whose removal is inside its Undo window
    /// — that show is being removed, not kept. See `isSourceBeingRemoved`.
    var hiddenPodcastShowNames: [String] {
        hiddenPodcastShows
            .filter { !hasPendingDeletion(forDeletionKey: Self.podcastShowRemovalKey($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var hasHiddenPodcastItems: Bool {
        !hiddenPodcastShows.isEmpty || !hiddenPodcastEpisodeIDs.isEmpty
    }

    var hiddenPodcastEpisodeArticles: [StudioArticle] {
        articles
            .filter { $0.sourceType == .podcast && hiddenPodcastEpisodeIDs.contains($0.id) && !hiddenPodcastShows.contains($0.domain) }
            .sorted(by: podcastEpisodeMenuOrder)
    }

    func hiddenPodcastEpisodes(forShow showName: String) -> [StudioArticle] {
        articles
            .filter { $0.sourceType == .podcast && $0.domain == showName && isPodcastArticleHidden($0) }
            .sorted(by: podcastEpisodeMenuOrder)
    }

    func isPodcastArticleHidden(_ article: StudioArticle) -> Bool {
        guard article.sourceType == .podcast else { return false }
        if hiddenPodcastEpisodeIDs.contains(article.id) {
            return true
        }
        return hiddenPodcastShows.contains(article.domain) && !visiblePodcastEpisodeOverrideIDs.contains(article.id)
    }

    /// A source whose whole feed the learner hid: a podcast episode of a hidden
    /// show, or a YouTube video of a hidden channel, with no visible override
    /// of its own. Unlike a source hidden by itself, these leave knowledge too
    /// (product owner, 2026-09-11): a hidden show stays out of chat, search and
    /// reviews, and unhiding one episode brings that episode back into both.
    /// Mirrors `is_collection_hidden` on `source_projection`.
    func isSourceCollectionHidden(_ article: StudioArticle) -> Bool {
        if article.sourceType == .podcast {
            return hiddenPodcastShows.contains(article.domain)
                && !visiblePodcastEpisodeOverrideIDs.contains(article.id)
        }
        if article.sourceType == .video,
           let channel = videoChannelName(for: article) {
            return isYouTubeChannelHidden(channel)
                && !visibleYouTubeVideoOverrideIDs.contains(article.id)
        }
        return false
    }

    func isSourceHidden(_ article: StudioArticle) -> Bool {
        if article.isHidden { return true }
        if article.sourceType == .podcast {
            return isPodcastArticleHidden(article)
        }
        if article.sourceType == .video,
           let channel = videoChannelName(for: article) {
            return isYouTubeChannelHidden(channel)
                && !visibleYouTubeVideoOverrideIDs.contains(article.id)
        }
        return false
    }

    var hiddenYouTubeChannelNames: [String] {
        hiddenYouTubeChannels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func isYouTubeChannelHidden(_ channelName: String) -> Bool {
        let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return hiddenYouTubeChannels.contains {
            $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    func hiddenYouTubeVideos(forChannel channelName: String) -> [StudioArticle] {
        articles
            .filter {
                $0.sourceType == .video
                    && $0.isYouTubeURL
                    && videoChannelName(for: $0)?.localizedCaseInsensitiveCompare(channelName) == .orderedSame
                    && isSourceHidden($0)
            }
            .sorted(by: sourceHiddenMenuOrder)
    }

    func setYouTubeChannelHidden(_ channelName: String, hidden: Bool) async {
        let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try await storage.setYouTubeChannelHidden(trimmed, hidden: hidden)
            hiddenYouTubeChannels = Set(hiddenYouTubeChannels.filter {
                $0.localizedCaseInsensitiveCompare(trimmed) != .orderedSame
            })
            if hidden {
                hiddenYouTubeChannels.insert(trimmed)
                let hiddenIDs = Set(articles.filter {
                    videoChannelName(for: $0)?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
                }.map(\.id))
                visibleYouTubeVideoOverrideIDs.subtract(hiddenIDs)
                deselectSourcesInEveryWindow(hiddenIDs)
                if let selectedArticleId, hiddenIDs.contains(selectedArticleId) {
                    self.selectedArticleId = nil
                    currentCardIndex = 0
                }
            }
            try await reloadArticlesAfterVisibilityChange()
            showToast(
                hidden ? "Hid \(trimmed)" : "Unhid \(trimmed)",
                undo: hidden ? { [weak self] in await self?.setYouTubeChannelHidden(trimmed, hidden: false) } : nil
            )
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update hidden YouTube channel: \(error.localizedDescription)")
        }
    }

    /// Sources the learner hid in `tab`. One inside its removal's Undo window
    /// is hidden too, but it is being removed rather than kept, so it is not
    /// listed here. See `isSourceBeingRemoved`.
    func hiddenSourceArticles(for tab: StudioSidebarTab) -> [StudioArticle] {
        articles
            .filter {
                guard $0.isHidden,
                      !isSourceBeingRemoved($0.id),
                      sourceBelongsToTab($0, tab: tab) else { return false }
                if tab == .videos,
                   $0.isYouTubeURL,
                   let channelName = videoChannelName(for: $0),
                   isYouTubeChannelHidden(channelName) {
                    return false
                }
                return true
            }
            .sorted(by: sourceHiddenMenuOrder)
    }

    func hasHiddenSourceItems(for tab: StudioSidebarTab) -> Bool {
        !hiddenSourceArticles(for: tab).isEmpty
    }

    var hiddenBookGroupNames: [String] {
        allBookGroupNames
            .filter { isBookHidden($0) && !hasPendingDeletion(forDeletionKey: Self.bookRemovalKey($0)) }
            .sorted { bookDisplayName($0).localizedStandardCompare(bookDisplayName($1)) == .orderedAscending }
    }

    var hiddenBookChapterArticles: [StudioArticle] {
        hiddenSourceArticles(for: .books)
            .filter { article in
                guard let groupName = article.parentGroup else { return true }
                return !isBookHidden(groupName)
            }
    }

    var hasHiddenBookItems: Bool {
        !hiddenBookGroupNames.isEmpty || !hiddenBookChapterArticles.isEmpty
    }

    func isBookHidden(_ groupName: String) -> Bool {
        let sources = bookSourceArticles(for: groupName)
        return !sources.isEmpty && sources.allSatisfy { isSourceHidden($0) }
    }

    func sourceBelongsToTab(_ article: StudioArticle, tab: StudioSidebarTab) -> Bool {
        // An explainer belongs to no tab as a row of its own; it is folded
        // under the source it explains. `sidebarTab(listing:)` resolves that.
        // An audio overview's carrier belongs to its notebook's Studio.
        guard !GeneratedExplainer.isSpokenScriptURL(article.url) else { return false }
        switch tab {
        case .articles:
            return article.sourceType == .article || article.sourceType == .manual || article.sourceType == .unclassified
        case .papers:
            return article.sourceType == .paper
        case .books:
            return article.sourceType == .book
        case .meetings:
            return article.sourceType == .meeting
        case .podcasts:
            return article.sourceType == .podcast
        case .videos:
            // A course's lecture videos too: they are listed in both places
            // (courses-design.md).
            return article.sourceType == .video
                && !ZoomRecordingService.isZoomRecordingURL(article.url)
        case .xPosts:
            return article.sourceType == .xPost
        }
    }

    func sourceHiddenMenuOrder(_ lhs: StudioArticle, _ rhs: StudioArticle) -> Bool {
        if lhs.sourceType != rhs.sourceType {
            return lhs.sourceType.rawValue.localizedStandardCompare(rhs.sourceType.rawValue) == .orderedAscending
        }
        if lhs.dateAdded != rhs.dateAdded {
            return lhs.dateAdded > rhs.dateAdded
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    func podcastEpisodeMenuOrder(_ lhs: StudioArticle, _ rhs: StudioArticle) -> Bool {
        if lhs.domain != rhs.domain {
            return lhs.domain.localizedStandardCompare(rhs.domain) == .orderedAscending
        }
        if lhs.dateAdded != rhs.dateAdded {
            return lhs.dateAdded > rhs.dateAdded
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    func setPodcastShowHidden(_ podcastName: String, hidden: Bool) async {
        let trimmed = podcastName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !hidden,
           await undoPendingDeletion(forDeletionKey: Self.podcastShowRemovalKey(trimmed)) {
            guard hiddenPodcastShows.contains(trimmed) else { return }
        }

        do {
            let revealed = try await storage.setPodcastShowHidden(trimmed, hidden: hidden)
            if hidden {
                hiddenPodcastShows.insert(trimmed)
                visiblePodcastEpisodeOverrideIDs.subtract(articles.filter { $0.sourceType == .podcast && $0.domain == trimmed }.map(\.id))
                deselectSourcesInEveryWindow(articles.filter { $0.sourceType == .podcast && $0.domain == trimmed }.map(\.id))
                if selectedArticle?.sourceType == .podcast && selectedArticle?.domain == trimmed {
                    selectedArticleId = nil
                    currentCardIndex = 0
                }
            } else {
                hiddenPodcastShows.remove(trimmed)
                let revealedIDs = Set(revealed)
                hiddenPodcastEpisodeIDs.subtract(revealedIDs)
                for index in articles.indices where revealedIDs.contains(articles[index].id) {
                    articles[index].isHidden = false
                }
            }
            showToast(
                hidden ? "Hid \(trimmed)"
                    : revealed.isEmpty ? "Unhid \(trimmed)"
                    : "Unhid \(trimmed) and \(revealed.count) of its episodes",
                undo: hidden ? { [weak self] in await self?.setPodcastShowHidden(trimmed, hidden: false) } : nil
            )
            if !hidden {
                Task(priority: .utility) { [weak self] in
                    await self?.processPendingPodcastTranscripts()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update hidden podcast show: \(error.localizedDescription)")
        }
    }

    /// Unhides several episodes at once, with one toast and one transcript
    /// pass: Hidden Items' "Show all" for a show whose episodes were hidden one
    /// by one. Episodes that are not hidden podcast episodes are skipped.
    func revealPodcastEpisodes(_ sourceIDs: [String]) async {
        var revealed: [String] = []
        for sourceID in sourceIDs {
            guard articles.contains(where: { $0.id == sourceID && $0.sourceType == .podcast }) else { continue }
            do {
                try await storage.setPodcastEpisodeHidden(sourceID, hidden: false)
                revealed.append(sourceID)
            } catch {
                errorMessage = error.localizedDescription
                logger.error("Failed to unhide podcast episode: \(error.localizedDescription)")
            }
        }
        guard !revealed.isEmpty else { return }
        let revealedIDs = Set(revealed)
        hiddenPodcastEpisodeIDs.subtract(revealedIDs)
        for index in articles.indices where revealedIDs.contains(articles[index].id) {
            articles[index].isHidden = false
        }
        showToast(revealed.count == 1 ? "Unhid 1 episode" : "Unhid \(revealed.count) episodes")
        Task(priority: .utility) { [weak self] in
            await self?.processPendingPodcastTranscripts()
        }
    }

    func setPodcastEpisodeHidden(_ sourceID: String, hidden: Bool) async {
        guard let article = articles.first(where: { $0.id == sourceID && $0.sourceType == .podcast }) else { return }
        if !hidden, await undoPendingDeletion(forSourceID: sourceID) {
            guard articles.first(where: { $0.id == sourceID })?.isHidden == true else { return }
        }

        do {
            try await storage.setPodcastEpisodeHidden(sourceID, hidden: hidden)
            if let index = articles.firstIndex(where: { $0.id == sourceID }) {
                articles[index].isHidden = hidden
            }
            if hidden {
                hiddenPodcastEpisodeIDs.insert(sourceID)
                visiblePodcastEpisodeOverrideIDs.remove(sourceID)
                deselectSourcesInEveryWindow([sourceID])
                if selectedArticleId == sourceID {
                    selectedArticleId = nil
                    currentCardIndex = 0
                }
            } else {
                hiddenPodcastEpisodeIDs.remove(sourceID)
            }
            showToast(hidden ? "Hid \(article.title)" : "Unhid \(article.title)")
            if !hidden {
                Task(priority: .utility) { [weak self] in
                    await self?.processPendingPodcastTranscripts()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update hidden podcast episode: \(error.localizedDescription)")
        }
    }

    func setArticleRead(_ sourceID: String, read: Bool, showsToast: Bool = true) async {
        guard let index = articles.firstIndex(where: { $0.id == sourceID }) else { return }
        let article = articles[index]
        // This is a main-actor workflow. The cached predicate avoids resolving an
        // iCloud-backed path here just to decide whether a visible row is trackable.
        guard article.cachedSupportsReadTracking, article.isRead != read else { return }

        let readAt: Date? = read ? Date() : nil
        do {
            try await storage.updateSourceReadAt(sourceID: sourceID, readAt: readAt)
            if let updatedIndex = articles.firstIndex(where: { $0.id == sourceID }) {
                articles[updatedIndex].readAt = readAt
            }
            if showsToast {
                showToast(read ? "Marked as read" : "Marked as unread")
            }

            if read {
                await recordReadOnTodaysSchedule(sourceID)
                // Finishing a source is when its ideas are extracted, once
                // (docs/memory-design.md), and its cards drafted in the
                // background, both within the daily background AI limit.
                // Best effort: the day close extracts and drafts what this
                // missed.
                sourcesWereFinished([sourceID])
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update read status for \(sourceID): \(error.localizedDescription)")
        }
    }

    /// Reading a source in the app puts it on that day's Schedule, already checked
    /// off, so the calendar is an honest record of what the learner went through
    /// rather than only of what they planned in advance.
    ///
    /// It lands complete because reading *is* the work — leaving it pending would
    /// grow a to-do list out of things already done. Review pressure comes from the
    /// retention queue instead, which tracks read-but-never-reviewed separately.
    /// A source already planned for another day keeps that day and is checked off
    /// in place (`recordScheduledSourceReview`), so reading ahead never rewrites the
    /// plan. Marking something *unread* deliberately does not reopen the placement:
    /// completion is also written by the review path, and clearing it here would
    /// erase a real review.
    ///
    /// Only in-app reading reaches this. Reading-list discovery may initialize
    /// `read_at` when it first inserts a source, so importing a year of
    /// already-read links cannot backfill a year of Schedule days.
    private func recordReadOnTodaysSchedule(_ sourceID: String) async {
        do {
            try await storage.recordScheduledSourceCompletion(
                sourceID: sourceID,
                on: Date(),
                kind: .reading
            )
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
        } catch {
            // Never surface this: the read itself succeeded, and failing to place it
            // on the calendar is not something the learner can act on mid-article.
            logger.error("Failed to add read source to the schedule: \(error.localizedDescription)")
        }
    }

    /// Refresh the small pieces of published state affected after the speech
    /// service has durably completed a source. Storage work stays on its actor;
    /// the main actor only publishes the returned Schedule snapshot and date.
    func reflectListeningCompletion(_ sourceID: String) async {
        await reflectExternalActivityCompletion([sourceID])
    }

    func reflectExternalActivityCompletion(_ sourceIDs: [String], at completedAt: Date = Date()) async {
        do {
            let refreshedSchedule = try await storage.loadScheduledSources()
            let completedIDs = Set(sourceIDs)
            for index in articles.indices where completedIDs.contains(articles[index].id) && articles[index].readAt == nil {
                articles[index].readAt = completedAt
            }
            scheduledSources = refreshedSchedule
        } catch {
            logger.error("Failed to refresh external source completion: \(error.localizedDescription)")
        }
    }

    /// The explicit UI path for material completed outside ForeverLM. The
    /// storage actor commits the whole selection together, then the main actor
    /// publishes only the refreshed lightweight state.
    func recordExternalSourceCompletions(
        sourceIDs: [String],
        kind: SourceActivityKind,
        on day: Date = Date()
    ) async {
        do {
            try await storage.recordScheduledSourceCompletions(
                sourceIDs: sourceIDs,
                on: day,
                kind: kind
            )
            learningGoals = try await storage.loadLearningGoals()
            await reflectExternalActivityCompletion(sourceIDs, at: day)
            // Read, heard or watched to the end, if elsewhere: a deliberate
            // finish, whose cards are drafted in the background.
            if kind == .reading || kind == .listening || kind == .watching {
                sourcesWereFinished(sourceIDs)
            }
            let label: String
            switch kind {
            case .reading: label = "read"
            case .listening: label = "listened"
            case .watching: label = "watched"
            case .chat: label = "chatted"
            case .review: label = "reviewed"
            }
            showToast(sourceIDs.count == 1 ? "Logged as \(label)" : "Logged \(sourceIDs.count) sources as \(label)")
        } catch {
            errorMessage = "Could not log completed activity: \(error.localizedDescription)"
        }
    }

    /// Reader and player surfaces call this at the moment a learner starts a
    /// source. The storage operation is idempotent, so reopening a reader does
    /// not move a prior plan or create duplicate calendar rows.
    func recordSourceActivityOnSchedule(
        _ sourceID: String,
        kind: SourceActivityKind = .reading,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) async {
        do {
            let inserted = try await storage.recordScheduledSourceActivity(
                sourceID: sourceID,
                on: Date(),
                kind: kind,
                fraction: fraction,
                engagedSeconds: engagedSeconds
            )
            if inserted {
                scheduledSources = try await storage.loadScheduledSources()
            }
        } catch {
            logger.error("Failed to log source activity on the schedule: \(error.localizedDescription)")
        }
        await logDayActivity(for: sourceID, kind: kind)
    }

    /// The Planner's log: the minute this source was seen being read, heard
    /// or watched, drawn beside the day's plan. Chat and review activity on a
    /// source is logged by the chat itself, as a chat, so it is skipped here.
    /// Failures are logged and swallowed: the log is a by-product of reading,
    /// never a reason the reader stops.
    func logDayActivity(for sourceID: String, kind: SourceActivityKind) async {
        let activityKind: DayActivityKind
        switch kind {
        case .reading: activityKind = .reading
        case .listening: activityKind = .listening
        case .watching: activityKind = .watching
        case .chat, .review: return
        }
        let title = articlesById[sourceID].map { displayTitle(for: $0) } ?? ""
        do {
            try await storage.recordDayActivity(kind: activityKind, targetID: sourceID, title: title)
        } catch {
            logger.error("Failed to log \(activityKind.rawValue) in the day's log: \(error.localizedDescription)")
        }
    }

    /// How long a source must stay on screen before opening it counts as activity.
    /// Below this the reader was a glance — a wrong click, a title check, a link
    /// followed and abandoned — and putting it on the Schedule buries the real
    /// day's work under things the learner never read.
    static let readerEngagementDwell: Duration = .seconds(30)

    /// How often the open reader is checked for time to book to the ledger.
    static let readerEngagementHeartbeat: Duration = .seconds(30)

    /// Engaged seconds are written in batches this long, so a reading session
    /// is not a CloudKit save every half minute. Whatever is pending when the
    /// reader closes is written then.
    static let readerEngagementFlushSeconds: Double = 120

    /// How long the reader may go without a key, click, scroll, or pointer move
    /// before its time stops counting. Long enough to read a dense PDF page
    /// without touching anything; short enough that a paper left open in the
    /// frontmost app all afternoon is not booked as an afternoon of reading.
    /// On 2026-09-20 a paper that was open but never read logged 37 engaged
    /// minutes that way and was quizzed the next morning.
    static let readerEngagementIdleGrace: TimeInterval = 180

    /// Whether time in the open reader counts right now: the app has to be the
    /// one in front, and the learner has to have touched the Mac within
    /// `readerEngagementIdleGrace`. Still not eye contact, but a reader nobody
    /// touches stops accruing within minutes.
    static func readerIsEngaged() -> Bool {
        #if canImport(AppKit)
        // Any HID input, system-wide: the app being frontmost already says it
        // was this app's input.
        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
        return readerIsEngaged(appIsActive: NSApplication.shared.isActive, secondsSinceInput: secondsSinceInput)
        #else
        return true
        #endif
    }

    static func readerIsEngaged(appIsActive: Bool, secondsSinceInput: TimeInterval) -> Bool {
        guard appIsActive else { return false }
        guard secondsSinceInput.isFinite else { return false }
        return secondsSinceInput <= readerEngagementIdleGrace
    }

    /// Time the heartbeat counted for a source but has not yet written.
    /// Exposed so a test, or the automatic read mark, can see a sitting's time
    /// before the flush; the heartbeat adds to it through the same door.
    func noteReaderEngagedTime(_ sourceID: String, seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        readerEngagedPendingSeconds[sourceID, default: 0] += seconds
    }

    /// Book the pending seconds for a source to the ledger.
    func flushReaderEngagedTime(_ sourceID: String, kind: SourceActivityKind) async {
        guard let pending = readerEngagedPendingSeconds.removeValue(forKey: sourceID), pending > 0 else { return }
        await recordSourceActivityOnSchedule(sourceID, kind: kind, engagedSeconds: pending)
    }

    /// Progress must beat the position the reader restored to by this much before
    /// it counts as the learner moving. Restoring a saved position replays as an
    /// ordinary scroll callback, so without a baseline every reopen of a
    /// half-read article would re-log it as fresh activity.
    static let readerEngagementDepthEpsilon = 0.01

    /// Called by every reader surface as a source appears, and deliberately does
    /// *not* put it on the Schedule. The placement is earned instead — either by
    /// `readerEngagementDwell` with the source still open, or by the learner
    /// moving the reading position themselves (`noteReaderDepth`).
    ///
    /// Runs as the reader's `.task(id:)`, so closing the reader or switching
    /// sources cancels the wait and the glance leaves no trace.
    func beginReaderEngagement(
        _ sourceID: String,
        kind: SourceActivityKind = .reading
    ) async {
        // The saved position doubles as the starting depth. It has to come from
        // the source as well as the in-memory store: the store is empty on a cold
        // launch, and without the durable value every reopen would read as a jump
        // from zero straight to wherever the reader restored to.
        let savedLocator = readingPositionLocator(for: sourceID)
            ?? articles.first { $0.id == sourceID }?.readingPositionLocator
        readerOpenDepthBaselines[sourceID] = SourceProgressDepth.fraction(locator: savedLocator) ?? 0
        do {
            try await Task.sleep(for: Self.readerEngagementDwell)
        } catch {
            return // Reader closed or moved to another source: a glance, not activity.
        }
        guard !Task.isCancelled else { return }
        // The dwell itself is the first slice of engaged time.
        await recordSourceActivityOnSchedule(
            sourceID,
            kind: kind,
            engagedSeconds: Double(Self.readerEngagementDwell.components.seconds)
        )

        // Then the heartbeat: while the reader stays open and the app is in
        // front, time accrues to the day's ledger in batches. Cancellation —
        // the reader closing or switching sources — ends the loop, and what
        // was counted since the last batch is written on the way out, from a
        // task the cancellation cannot reach.
        var lastTick = Date()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.readerEngagementHeartbeat)
            } catch {
                break
            }
            let now = Date()
            let elapsed = now.timeIntervalSince(lastTick)
            lastTick = now
            guard Self.readerIsEngaged() else { continue }
            let heartbeat = Double(Self.readerEngagementHeartbeat.components.seconds)
            noteReaderEngagedTime(sourceID, seconds: min(max(0, elapsed), 2 * heartbeat))
            // The ledger is written in batches; the Planner's log follows the
            // clock, so every engaged heartbeat lands there (a write only when
            // the minute moved).
            await logDayActivity(for: sourceID, kind: kind)
            if (readerEngagedPendingSeconds[sourceID] ?? 0) >= Self.readerEngagementFlushSeconds {
                await flushReaderEngagedTime(sourceID, kind: kind)
            }
        }
        Task { [weak self] in
            await self?.flushReaderEngagedTime(sourceID, kind: kind)
        }
    }

    /// A reading position the learner moved themselves. This is the strongest
    /// cheap evidence a source is actually being consumed, so it both earns the
    /// Schedule placement and feeds `source_activity_days.max_fraction` — the
    /// depth the Schedule reads back to decide whether a row is genuinely done
    /// rather than merely opened.
    ///
    /// Synchronous and debounced: the position funnels call it from every scroll
    /// and page turn, while the ledger only needs where the learner settled.
    func noteReaderDepth(
        _ sourceID: String,
        fraction: Double,
        kind: SourceActivityKind = .reading
    ) {
        let depth = min(max(fraction, 0), 1)
        let baseline = readerOpenDepthBaselines[sourceID] ?? 0
        guard depth > baseline + Self.readerEngagementDepthEpsilon else { return }
        readerOpenDepthBaselines[sourceID] = depth

        readerDepthWriteTasks[sourceID]?.cancel()
        readerDepthWriteTasks[sourceID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return // Superseded by a newer position for this source.
            }
            guard !Task.isCancelled, let self else { return }
            await self.recordSourceActivityOnSchedule(sourceID, kind: kind, fraction: depth)
        }
    }

    func automaticActivityKind(for article: StudioArticle) -> SourceActivityKind {
        switch article.sourceType {
        case .podcast: return .listening
        case .video: return .watching
        default: return .reading
        }
    }

    /// Called only after a user-driven scroll reaches the end of the article's
    /// content. Programmatic position restoration and external pages do not call
    /// this, so reopening a source or following one of its links cannot silently
    /// change its status.
    ///
    /// Reaching the end is a position, and a position only becomes a read once
    /// enough time went with it (docs/memory-design.md, "The engagement
    /// ledger"): the time already booked for the source plus this sitting's
    /// unflushed heartbeat has to reach the ledger's floor for a complete read
    /// of a source this long. A scroll straight to the footer leaves the source
    /// unread, and the ledger still holds the depth it reached.
    func markArticleReadAfterReachingEnd(_ sourceID: String) async {
        guard let article = articles.first(where: { $0.id == sourceID }),
              article.cachedSupportsReadTracking,
              !article.isRead,
              automaticReadCompletionInFlightIDs.insert(sourceID).inserted else {
            return
        }

        defer { automaticReadCompletionInFlightIDs.remove(sourceID) }
        let booked = (try? await storage.sourceEngagedSeconds(sourceID: sourceID)) ?? 0
        let engaged = booked + (readerEngagedPendingSeconds[sourceID] ?? 0)
        let floor = SourceConsumption.timeFloor(
            expectedSeconds: SourceConsumption.expectedSeconds(wordCount: article.wordCount),
            level: .complete
        )
        guard engaged >= floor else {
            logger.info(
                "Reached the end of \(sourceID, privacy: .public) after \(Int(engaged))s; the read mark needs \(Int(floor))s"
            )
            return
        }
        await setArticleRead(sourceID, read: true)
    }

    /// Storage already marks a source read when its schedule placement completes;
    /// mirror that durable state in memory.
    func reflectScheduleCompletionReadState(for sourceIDs: [String]) {
        let now = Date()
        for sourceID in sourceIDs {
            guard let index = articles.firstIndex(where: { $0.id == sourceID }),
                  articles[index].readAt == nil else { continue }
            articles[index].readAt = now
        }
    }

    func setSourceHidden(_ sourceID: String, hidden: Bool) async {
        guard let index = articles.firstIndex(where: { $0.id == sourceID }) else { return }
        if !hidden, await undoPendingDeletion(forSourceID: sourceID) {
            guard articles.first(where: { $0.id == sourceID })?.isHidden == true else { return }
        }
        let title = articles[index].title

        // The row disappears with the click; the write follows. Waiting on the
        // storage actor first left the row visible for as long as a CloudKit
        // merge kept the actor busy.
        articles[index].isHidden = hidden
        if hidden {
            deselectSourcesInEveryWindow([sourceID])
            if selectedArticleId == sourceID {
                selectedArticleId = nil
                currentCardIndex = 0
            }
        }
        showToast(
            hidden ? "Hid \(title)" : "Unhid \(title)",
            undo: hidden ? { [weak self] in await self?.setSourceHidden(sourceID, hidden: false) } : nil
        )
        do {
            try await storage.setSourceHidden(sourceID, hidden: hidden)
        } catch {
            if let index = articles.firstIndex(where: { $0.id == sourceID }) {
                articles[index].isHidden = !hidden
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to update hidden source: \(error.localizedDescription)")
        }
    }

    /// Hide several sources as one gesture: every row leaves with the click,
    /// one toast reports the lot, and a failed write brings them all back.
    /// Podcast episodes, papers, articles, videos — any source the sidebar
    /// lists on its own row. A book's chapters go through `setBookHidden`.
    func hideSources(_ ids: [String]) async {
        let present = ids.filter { id in articles.contains(where: { $0.id == id }) }
        guard present.count > 1 else {
            if let id = present.first { await setSourceHidden(id, hidden: true) }
            return
        }
        for id in present {
            if let index = articles.firstIndex(where: { $0.id == id }) {
                articles[index].isHidden = true
            }
        }
        deselectSourcesInEveryWindow(present)
        if let selectedArticleId, present.contains(selectedArticleId) {
            self.selectedArticleId = nil
            currentCardIndex = 0
        }
        showToast("Hid \(present.count) sources", undo: { [weak self] in await self?.unhideSources(present) })
        var written: [String] = []
        do {
            for id in present {
                try await storage.setSourceHidden(id, hidden: true)
                written.append(id)
            }
        } catch {
            for id in present where !written.contains(id) {
                if let index = articles.firstIndex(where: { $0.id == id }) {
                    articles[index].isHidden = false
                }
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to hide \(present.count) sources: \(error.localizedDescription)")
        }
    }

    /// The Undo of `hideSources`: every row comes back with the click, one
    /// toast reports the lot, and a failed write hides the unwritten ones again.
    func unhideSources(_ ids: [String]) async {
        let present = ids.filter { id in articles.contains(where: { $0.id == id }) }
        guard present.count > 1 else {
            if let id = present.first { await setSourceHidden(id, hidden: false) }
            return
        }
        for id in present {
            if let index = articles.firstIndex(where: { $0.id == id }) {
                articles[index].isHidden = false
            }
        }
        showToast("Unhid \(present.count) sources")
        var written: [String] = []
        do {
            for id in present {
                try await storage.setSourceHidden(id, hidden: false)
                written.append(id)
            }
        } catch {
            for id in present where !written.contains(id) {
                if let index = articles.firstIndex(where: { $0.id == id }) {
                    articles[index].isHidden = true
                }
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to unhide \(present.count) sources: \(error.localizedDescription)")
        }
    }

    func setBookHidden(_ groupName: String, hidden: Bool) async {
        let ids = bookSourceArticles(for: groupName).map(\.id)
        guard !ids.isEmpty else { return }
        if !hidden,
           await undoPendingDeletion(forDeletionKey: Self.bookRemovalKey(groupName)) {
            guard ids.contains(where: { id in
                articles.first(where: { $0.id == id })?.isHidden == true
            }) else {
                return
            }
        }
        let title = bookDisplayName(groupName)

        // All chapters flip together, before the per-chapter writes: the book
        // vanishing one row at a time as each write drained looked broken.
        for id in ids {
            if let index = articles.firstIndex(where: { $0.id == id }) {
                articles[index].isHidden = hidden
            }
        }
        if hidden {
            deselectSourcesInEveryWindow(ids)
            if let selectedArticleId, ids.contains(selectedArticleId) {
                self.selectedArticleId = nil
                currentCardIndex = 0
            }
        }
        showToast(
            hidden ? "Hid \(title)" : "Unhid \(title)",
            undo: hidden ? { [weak self] in await self?.setBookHidden(groupName, hidden: false) } : nil
        )
        do {
            for id in ids {
                try await storage.setSourceHidden(id, hidden: hidden)
            }
        } catch {
            for id in ids {
                if let index = articles.firstIndex(where: { $0.id == id }) {
                    articles[index].isHidden = !hidden
                }
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to update hidden book: \(error.localizedDescription)")
        }
    }

    func setPodcastEpisodeVisibleOverride(_ sourceID: String, visible: Bool) async {
        guard let article = articles.first(where: { $0.id == sourceID && $0.sourceType == .podcast }) else { return }

        do {
            try await storage.setPodcastEpisodeVisibleOverride(sourceID, visible: visible)
            if visible, let index = articles.firstIndex(where: { $0.id == sourceID }) {
                articles[index].isHidden = false
            }
            if visible {
                visiblePodcastEpisodeOverrideIDs.insert(sourceID)
                hiddenPodcastEpisodeIDs.remove(sourceID)
            } else {
                visiblePodcastEpisodeOverrideIDs.remove(sourceID)
            }
            showToast(visible ? "Showing \(article.title)" : "Hid \(article.title)")
            if visible {
                Task(priority: .utility) { [weak self] in
                    await self?.processPendingPodcastTranscripts()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update visible podcast episode override: \(error.localizedDescription)")
        }
    }

    func setYouTubeVideoVisibleOverride(_ sourceID: String, visible: Bool) async {
        guard let article = articles.first(where: {
            $0.id == sourceID && $0.sourceType == .video && $0.isYouTubeURL
        }) else { return }

        do {
            try await storage.setYouTubeVideoVisibleOverride(sourceID, visible: visible)
            if visible {
                visibleYouTubeVideoOverrideIDs.insert(sourceID)
            } else {
                visibleYouTubeVideoOverrideIDs.remove(sourceID)
            }
            try await reloadArticlesAfterVisibilityChange()
            showToast(visible ? "Showing \(article.title)" : "Hid \(article.title)")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update visible YouTube video override: \(error.localizedDescription)")
        }
    }

    private func reloadArticlesAfterVisibilityChange() async throws {
        let reloaded = try await storage.loadLibrarySources(teamID: activeTeamID).sources
        let current = articles
        articles = await Task.detached(priority: .userInitiated) {
            StudioViewModel.preservingLoadedContent(in: reloaded, preservingFrom: current)
        }.value
        invalidateFilteredSidebarCache()
    }
}
