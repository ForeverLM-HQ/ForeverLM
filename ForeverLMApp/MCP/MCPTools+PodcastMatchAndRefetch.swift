// MCPDataStore: AI metadata extraction, podcast matches and source refetching.
import Foundation
import PDFKit

extension MCPDataStore {
    /// Run AI paper-metadata extraction for an existing paper source.
    func extractPaperMetadataForSource(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard var article = try store.loadSourceForSync(id) else { throw MCPError.notFound("Source not found: \(id)") }
        guard article.sourceType == .paper else {
            throw MCPError.invalidInput("extract_paper_metadata requires a paper source.")
        }

        var firstPageText = ""
        if let path = article.resolvedPDFPath, let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
            firstPageText = doc.page(at: 0)?.string ?? ""
        }
        if firstPageText.isEmpty {
            firstPageText = String(((try? store.loadSourceContent(id)) ?? article.content ?? "").prefix(8000))
        }
        article.prepareForPaperMetadataExtraction()
        let status: String
        do {
            status = try await extractRequiredPaperMetadataWithAI(
                article: &article,
                firstPageText: firstPageText
            )
        } catch {
            try? store.saveSource(article)
            throw error
        }
        try store.saveSource(article)
        return "Paper metadata for '\(article.title)': \(status)."
    }

    /// Run AI title/author extraction for an article source.
    func extractArticleMetadataForSource(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard var article = try store.loadSourceForSync(id) else { throw MCPError.notFound("Source not found: \(id)") }
        guard let config = KeychainService.resolveConfig(for: .articleMetadata) else {
            return "AI metadata extraction skipped: sign in with Apple in ForeverLM."
        }
        let content = (try? store.loadSourceContent(id)) ?? article.content
        guard let result = await AIService().fixArticleTitle(
            source: AIUsageSource(source: article),
            currentTitle: article.title, url: article.url, content: content, config: config
        ) else {
            return "AI could not extract metadata for '\(article.title)'."
        }
        var changed: [String] = []
        if let t = Self.nilIfBlank(result.title ?? ""), t != article.title { article.title = t; changed.append("title") }
        if let a = Self.nilIfBlank(result.author ?? "") { article.author = a; changed.append("author") }
        if let y = Self.nilIfBlank(result.year ?? "") { article.publishedYear = y; changed.append("year") }
        guard !changed.isEmpty else { return "AI found no new metadata for '\(article.title)'." }
        try store.saveSource(article)
        return "Updated \(changed.joined(separator: ", ")) for '\(article.title)'."
    }

    /// Find duplicate papers via AI and optionally archive the lower-quality copies.
    func findDuplicatePapers(archiveDuplicates: Bool) async throws -> String {
        let store = try knowledgeStore()
        let papers = try store.loadActiveSources().filter { $0.sourceType == .paper }
        guard papers.count >= 2 else { return "Not enough papers to check for duplicates." }
        guard let config = KeychainService.resolveConfig(for: .duplicateDetection) else {
            return "Duplicate detection skipped: sign in with Apple in ForeverLM."
        }
        let input = papers.map { (title: $0.title, url: $0.url) }
        let groups = await AIService().findDuplicatePapers(papers: input, config: config).filter { $0.count > 1 }
        guard !groups.isEmpty else { return "No duplicate papers found." }

        var lines: [String] = []
        var archived = 0
        for group in groups {
            let arts = group.compactMap { papers.indices.contains($0) ? papers[$0] : nil }
            guard arts.count > 1,
                  let keep = arts.max(by: { StudioViewModel.paperStorageScore($0) < StudioViewModel.paperStorageScore($1) })
            else { continue }
            let losers = arts.filter { $0.id != keep.id }
            // Each paper as the link a reply can show (Prompts.hiddenIDs).
            lines.append("• keep \(Self.sourceLink(title: keep.title, id: keep.id)); duplicate\(losers.count == 1 ? "" : "s"): " + losers.map { Self.sourceLink(title: $0.title, id: $0.id) }.joined(separator: ", "))
            if archiveDuplicates {
                for loser in losers { _ = try archiveSource(loser.id); archived += 1 }
            }
        }
        let header = archiveDuplicates
            ? "Found \(groups.count) duplicate group(s); archived \(archived) duplicate(s):"
            : "Found \(groups.count) duplicate group(s) (pass archive_duplicates=true to remove the lower-quality copies):"
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: - Podcast matching (MCP/UI parity)

    /// Search for a podcast episode matching a source and stage the match for
    /// confirmation. The match is handed to the app (`offerPodcastMatch`),
    /// whose source holds it for the reader's Confirm button and for
    /// resolve_podcast_match: it has no column, so a match this tool wrote to
    /// SQLite alone was gone by the time resolve_podcast_match read the row
    /// back, and the row was left asking to confirm nothing (2026-10-02).
    func findPodcastMatch(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard let article = try store.loadSourceForSync(id) else { throw MCPError.notFound("Source not found: \(id)") }

        let lowerURL = article.url.lowercased()
        let isYouTube = lowerURL.contains("youtube.com") || lowerURL.contains("youtu.be")
        // An Apple Podcasts episode link names its episode (`?i=`), so it is
        // looked up rather than searched for by a title that may not be Apple's.
        let linkNamesEpisode = PodcastFinderService.applePodcastsEpisodeIdentity(fromURL: article.url) != nil
        let match = linkNamesEpisode
            ? await PodcastFinderService.shared.findPodcast(forApplePodcastsURL: article.url)
            : isYouTube
            ? await PodcastFinderService.shared.findPodcast(forYouTubeURL: article.url)
            : await PodcastFinderService.shared.findPodcast(byTitle: article.title)
        guard let match else { return "No podcast match found for '\(article.title)'." }

        let offer = try await Self.offerPodcastMatchInTheApp(match, sourceID: id)
        let found = "\(match.podcastName) — \(match.episodeTitle)"
        switch offer {
        case .awaitingConfirmation, .confirmed:
            let basis = linkNamesEpisode ? " (the episode its Apple Podcasts link names)" : ""
            return "Found podcast match for '\(article.title)': \(found)\(basis). Confirm or reject with resolve_podcast_match."
        case .alreadyInLibrary(let title):
            return "Found \(found), but the library already holds it as \"\(title)\"; '\(article.title)' was marked as that duplicate."
        case .sourceGone:
            throw MCPError.notFound("Source not found in the open library: \(id)")
        }
    }

    @MainActor
    private static func offerPodcastMatchInTheApp(
        _ match: PodcastFinderService.PodcastMatch,
        sourceID: String
    ) async throws -> StudioViewModel.PodcastMatchOffer {
        let studio = try AppModelBridge.requireStudio()
        // Staged for the learner or the assistant to confirm, as the tool says.
        return await studio.offerPodcastMatch(match, for: sourceID, confirmingAtOnce: false)
    }

    /// Confirm or reject the match find_podcast_match staged, on the app's own
    /// source (`confirmPodcastMatch`, `rejectPodcastMatch`), as the reader's
    /// Confirm and Reject buttons do. Confirming fetches the transcript.
    func resolvePodcastMatch(sourceID: String, confirm: Bool) async throws -> String {
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        return try await Self.resolvePodcastMatchInTheApp(sourceID: id, confirm: confirm)
    }

    @MainActor
    private static func resolvePodcastMatchInTheApp(sourceID id: String, confirm: Bool) async throws -> String {
        let studio = try AppModelBridge.requireStudio()
        guard let article = studio.articles.first(where: { $0.id == id }) else { throw MCPError.notFound("Source not found: \(id)") }
        // A row left asking to confirm a match nobody holds — a relaunch drops
        // a staged match — can still be rejected back to the queue.
        guard let match = studio.heldPodcastMatch(for: id)?.info else {
            guard !confirm, article.statusFlag == .confirmPodcast else {
                return "No pending podcast match on \(id). Call find_podcast_match first."
            }
            await studio.rejectPodcastMatch(for: id)
            return "No match was held for '\(article.title)'; it is back in the queue, and find_podcast_match looks for its episode again."
        }
        if confirm {
            await studio.confirmPodcastMatch(for: id)
            let confirmed = studio.articles.first(where: { $0.id == id })
            if confirmed?.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return "Confirmed podcast match for '\(match.episodeTitle)', and its transcript is in: get_source_content reads it."
            }
            return "Confirmed podcast match for '\(match.episodeTitle)'. \(confirmed?.errorMessage ?? "Its transcript is being fetched; get_source_content returns it when it is done.")"
        }
        await studio.rejectPodcastMatch(for: id)
        return "Rejected podcast match; '\(article.title)' returned to queued."
    }

    // MARK: - A podcast episode's transcript from YouTube (Reader parity)

    /// The Reader's Find on YouTube: candidates from the episode's own page,
    /// the show's channel and YouTube search, best match first. Nothing is
    /// attached; `import_podcast_youtube_transcript` takes the confirmed one.
    func findPodcastOnYouTube(sourceID: String, alwaysForShow: Bool?) async throws -> String {
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        return try jsonString(try await Self.findPodcastOnYouTubeLikeTheReader(sourceID: id, alwaysForShow: alwaysForShow))
    }

    /// The Reader's Use Transcript, for a video named by its address or id.
    func importPodcastYouTubeTranscript(sourceID: String, video: String, replace: Bool) async throws -> String {
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard let videoID = Self.youtubeVideoID(fromArgument: video) else {
            throw MCPError.invalidInput("video must be a YouTube video address (youtube.com/watch?v=…, youtu.be/…) or its 11-character id.")
        }
        return try jsonString(try await Self.importPodcastYouTubeTranscriptLikeTheReader(
            sourceID: id,
            videoID: videoID,
            replace: replace
        ))
    }

    nonisolated static func youtubeVideoID(fromArgument raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count == 11,
           value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            return value
        }
        return ForeverLMCore.youtubeVideoID(from: value.contains("://") ? value : "https://" + value)
    }

    @MainActor
    private static func requirePodcastEpisode(_ sourceID: String, in studio: StudioViewModel) throws -> StudioArticle {
        guard let episode = studio.articles.first(where: { $0.id == sourceID }) else {
            throw MCPError.invalidInput("No source has id \(sourceID).")
        }
        guard episode.sourceType == .podcast else {
            throw MCPError.invalidInput("'\(episode.title)' is not a podcast episode. A YouTube video's own transcript comes from fetch_video_transcript.")
        }
        return episode
    }

    @MainActor
    private static func findPodcastOnYouTubeLikeTheReader(sourceID: String, alwaysForShow: Bool?) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let episode = try requirePodcastEpisode(sourceID, in: studio)
        guard YouTubeService.shared.isSignedIn else {
            throw MCPError.invalidInput("YouTube is not connected. The learner connects it in Plugins › YouTube (open_settings youtube); then call find_podcast_on_youtube again.")
        }
        // The Reader's checkbox names the show by the episode's domain.
        let show = episode.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alwaysForShow {
            guard !show.isEmpty else {
                throw MCPError.invalidInput("'\(episode.title)' names no show, so always_for_show has nothing to set.")
            }
            studio.setYouTubeTranscriptFallback(forPodcastShow: show, enabled: alwaysForShow)
        }
        let candidates = try await studio.findYouTubeTranscriptCandidates(for: sourceID)
        let dates = KnowledgeStore.iso8601Formatter
        var payload: [String: Any] = [
            "source_id": sourceID,
            "episode": episode.title,
            "show": StudioViewModel.podcastYouTubeShowName(for: episode),
            "has_transcript": episode.state == .ready,
            "candidates": candidates.map { candidate -> [String: Any] in
                var row: [String: Any] = [
                    "video_id": candidate.videoId,
                    "url": candidate.url,
                    "title": candidate.title,
                    "found_by": (candidate.foundBy ?? .search).rawValue,
                ]
                if let channel = candidate.channelTitle { row["channel"] = channel }
                if let published = candidate.publishedAt { row["published_at"] = dates.string(from: published) }
                if let description = candidate.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    row["description"] = String(description.prefix(400))
                }
                return row
            },
            "message": "Ranked best match first; nothing is attached yet. Show the learner the first candidate (its title, channel, date and found_by) and ask whether it is this episode, since an upload is often titled differently. Once they confirm, call import_podcast_youtube_transcript with source_id and the video's url.",
        ]
        if !show.isEmpty {
            payload["always_find_show_on_youtube"] = studio.prefersYouTubeTranscript(forPodcastShow: show)
        }
        return payload
    }

    @MainActor
    private static func importPodcastYouTubeTranscriptLikeTheReader(
        sourceID: String,
        videoID: String,
        replace: Bool
    ) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let episode = try requirePodcastEpisode(sourceID, in: studio)
        if episode.state == .ready, !replace {
            let origin = episode.publicURL.flatMap(ForeverLMCore.youtubeVideoID(from:)).map { "the YouTube video \($0)" }
                ?? "Apple Podcasts"
            throw MCPError.invalidInput("'\(episode.title)' already has its transcript, from \(origin). Pass replace true to replace it with this video's captions.")
        }
        // The formatter is told the video's own title and channel when YouTube
        // can say them; the captions themselves need no connection.
        let described = YouTubeService.shared.isSignedIn
            ? (try? await YouTubeService.shared.videos(ids: [videoID]))?.first
            : nil
        let candidate = described ?? YouTubeVideoSearchResult(
            videoId: videoID,
            title: episode.title,
            channelTitle: nil,
            description: nil,
            publishedAt: nil
        )
        let imported = try await studio.importRawYouTubeTranscript(for: sourceID, from: candidate)
        // Formatting reads the whole transcript with the learner's model,
        // minutes for a long episode, so it runs after the answer as work
        // cancel_ai_work can stop.
        let workID = MCPRunningWork.shared.startBackground(
            tool: "import_podcast_youtube_transcript",
            about: "formatting the YouTube transcript of \(episode.title)"
        ) { @MainActor in
            await studio.formatImportedYouTubeTranscript(imported)
        }
        return [
            "source_id": sourceID,
            "episode": episode.title,
            "video_url": candidate.url,
            "video_title": imported.videoTitle,
            "words": imported.wordCount,
            "work_id": workID,
            "message": "Attached the captions of \(candidate.url) to '\(episode.title)' (\(imported.wordCount) words); the episode is readable now. ForeverLM is formatting them into paragraphs and removing ad reads (work_id \(workID); cancel_ai_work stops it and the raw captions stay).",
        ]
    }

    // MARK: - Content refetch + local import (MCP/UI parity)

    /// The path `refetch_source_content` takes for a source.
    enum RefetchRoute: Equatable {
        /// A Teachable lecture: its text is its audio's transcript, made again.
        case teachableTranscript
        /// Text a Gemini Notebook kept, stored under the notebook's address.
        case geminiNotebookText
        /// A web article: the app's Refresh from Website, with its guards.
        case websiteRefresh
        /// An article-typed source whose address is a PDF file, not a page.
        case pdfAddress
        /// A podcast episode: its transcript fetched again from Apple Podcasts
        /// the way hydration fetches one. Its address is an Apple episode, or
        /// a page that is not a transcript.
        case podcastTranscript
        /// A YouTube video or a Zoom recording: its transcript fetched again
        /// from the video. Its page's text is never its transcript.
        case videoTranscript
        /// Every other type: its text fetched from its address.
        case plainFetch
    }

    nonisolated static func refetchRoute(for article: StudioArticle) -> RefetchRoute {
        // A Teachable lecture's text is its audio's transcript; the page itself
        // is the course sidebar.
        if TeachableCourseService.isLectureURL(article.url) { return .teachableTranscript }
        // A source a Gemini Notebook held only as text is stored under the
        // notebook's address, and that address fetched is Google's page.
        if GeminiNotebookService.isNotebookURL(article.url) { return .geminiNotebookText }
        // The sources fetch_video_transcript reads: a video on YouTube or a
        // Zoom recording, and a meeting session held as a Zoom recording.
        let isZoom = ZoomRecordingService.isZoomRecordingURL(article.url)
        if (article.sourceType == .video && (YouTubeTranscriptService.isYouTubeURL(article.url) || isZoom))
            || (article.sourceType == .meeting && isZoom) {
            return .videoTranscript
        }
        switch article.sourceType {
        case .article, .manual, .unclassified:
            return PaperService.isDirectPDFURL(article.url) ? .pdfAddress : .websiteRefresh
        case .podcast:
            return .podcastTranscript
        default:
            return .plainFetch
        }
    }

    /// Re-fetch a source's content and store it. A web article goes through
    /// the app's own Refresh from Website (`refreshArticleFromWebsiteOutcome`),
    /// so an assistant's refetch can no more replace a saved article with a
    /// paywall preview or a bot check than the menu item can.
    func refetchSourceContent(sourceID: String) async throws -> String {
        let store = try knowledgeStore()
        let id = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw MCPError.invalidInput("source_id is required.") }
        guard var article = try store.loadSourceForSync(id) else { throw MCPError.notFound("Source not found: \(id)") }
        let route = Self.refetchRoute(for: article)
        // A podcast's address is an Apple episode, which is not fetched over
        // http(s), or the episode's page, whose text is never its transcript.
        if route == .podcastTranscript {
            return try await Self.refetchPodcastTranscriptLikeTheApp(article)
        }
        guard article.url.hasPrefix("http") else {
            throw MCPError.invalidInput("Source has no http(s) URL to refetch.")
        }
        switch route {
        case .teachableTranscript:
            try await MainActor.run {
                let studio = try AppModelBridge.requireStudio()
                Task { await studio.fetchTeachableTranscript(for: id, forceRefresh: true) }
            }
            return "Transcribing '\(article.title)' again from its audio. This takes a few minutes; get_source_content returns the new transcript when it is done."
        case .geminiNotebookText:
            throw MCPError.invalidInput(
                "'\(article.title)' holds the text a Gemini Notebook kept for it, and its address is the notebook's, so there is no page to fetch it from again."
            )
        case .websiteRefresh:
            return try await Self.refreshArticleLikeTheMenu(article)
        case .pdfAddress:
            throw MCPError.invalidInput(
                "'\(article.title)' is addressed to a PDF file, not a web page, so there is no page to refetch: ForeverLM reads its text from the PDF."
            )
        case .videoTranscript:
            // The stored transcript stays unless the fetch brings a new one.
            return try await fetchVideoTranscript(sourceID: id, fetchAgain: true)
        case .podcastTranscript, .plainFetch:
            break
        }

        let content = try await SourceService.shared.fetchContent(from: article.url)
        article.content = content
        article.wordCount = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        if article.sourceType == .paper {
            article.prepareForPaperMetadataExtraction()
            do {
                _ = try await extractRequiredPaperMetadataWithAI(
                    article: &article,
                    firstPageText: String(content.prefix(12_000))
                )
            } catch {
                try? store.saveSource(article)
                throw error
            }
        } else {
            article.state = .ready
            article.errorMessage = nil
        }
        try store.saveSource(article)
        return "Refetched content for '\(article.title)' (\(article.wordCount ?? 0) words)."
    }

    @MainActor
    private static func refreshArticleLikeTheMenu(_ article: StudioArticle) async throws -> String {
        try await refreshArticle(article, in: AppModelBridge.requireStudio())
    }

    @MainActor
    private static func refetchPodcastTranscriptLikeTheApp(_ article: StudioArticle) throws -> String {
        try refetchPodcastTranscript(article, in: AppModelBridge.requireStudio())
    }

    /// `refetch_source_content` for a podcast: the episode's transcript fetched
    /// again from Apple Podcasts by the app's own hydration
    /// (`refetchPodcastTranscript(for:config:)`), never its page's text stored
    /// as a transcript. Formatting a long episode takes minutes, so the fetch
    /// runs after the answer as work `cancel_ai_work` can stop, and the stored
    /// transcript stays until the new one is saved. A transcript taken from
    /// YouTube is fetched again from YouTube, by its own tool.
    @MainActor
    static func refetchPodcastTranscript(
        _ article: StudioArticle,
        in studio: StudioViewModel,
        fetchAppleTranscript: (@Sendable (Int64, String) async -> StudioViewModel.PodcastTranscriptFetchOutcome)? = nil
    ) throws -> String {
        if let videoID = article.publicURL.flatMap(ForeverLMCore.youtubeVideoID(from:)) {
            throw MCPError.invalidInput(
                "'\(article.title)' holds the captions of the YouTube video \(videoID), not Apple's transcript; import_podcast_youtube_transcript with replace true fetches them again."
            )
        }
        if studio.prefersYouTubeTranscript(forPodcastShow: article.domain) {
            throw MCPError.invalidInput(
                "'\(article.domain)' is set to take its transcripts from YouTube; import_podcast_youtube_transcript attaches a video's captions to '\(article.title)'."
            )
        }
        guard studio.podcastHydrationCandidate(for: article.id, userInitiated: true) != nil else {
            throw MCPError.invalidInput(
                "'\(article.title)' has no Apple Podcasts episode ForeverLM can fetch a transcript for."
            )
        }
        let id = article.id
        let config = KeychainService.resolveConfig(for: .transcriptFormatting)
        let workID = MCPRunningWork.shared.startBackground(
            tool: "refetch_source_content",
            about: "fetching the transcript of \(article.title) again from Apple Podcasts"
        ) { @MainActor in
            if let fetchAppleTranscript {
                await studio.refetchPodcastTranscript(for: id, config: config, fetchAppleTranscript: fetchAppleTranscript)
            } else {
                await studio.refetchPodcastTranscript(for: id, config: config)
            }
        }
        return "Fetching the transcript of '\(article.title)' again from Apple Podcasts, as work \(workID). The stored transcript stays until the new one is saved; get_source_content returns the new one when the work finishes, and cancel_ai_work stops it."
    }

    /// The menu item's run for `refetch_source_content`, answered in words an
    /// assistant can pass on. A refresh that could not read the article is an
    /// error; one that read it and kept the saved copy is an answer.
    @MainActor
    static func refreshArticle(
        _ article: StudioArticle,
        in studio: StudioViewModel,
        work: ArticleWebsiteRefreshWork? = nil
    ) async throws -> String {
        let outcome = await studio.refreshArticleFromWebsiteOutcome(article.id, work: work)
        let answer = refetchAnswer(for: outcome, title: article.title)
        if answer.isError { throw MCPError.invalidInput(answer.text) }
        return answer.text
    }

    nonisolated static func refetchAnswer(
        for outcome: ArticleWebsiteRefreshOutcome,
        title: String
    ) -> (text: String, isError: Bool) {
        switch outcome {
        case .refreshed(let savedWords, let words, let archivedPage):
            let count = savedWords > 0 ? "\(savedWords) → \(words) words" : "\(words) words"
            let page = archivedPage ? ", and its page re-archived" : ""
            return ("Refreshed '\(title)' from its website through ForeverLM's browser: \(count)\(page).", false)
        case .unchanged(let words):
            return ("'\(title)' is unchanged: its website returned the saved text word for word (\(words) words), so nothing was written.", false)
        case .keptSavedCopy(let savedWords, let fetchedWords):
            return ("Kept the saved '\(title)' (\(savedWords) words): its website returned less text (\(fetchedWords) words), as a paywall preview or a sign-in wall does, and a refresh never replaces an article with less of it. If the learner has access, they can sign in to the site in ForeverLM's Reader and refetch again.", false)
        case .securityCheck:
            return ("The website showed a bot check instead of '\(title)', so the saved article was kept. The learner can open it in ForeverLM's Reader, pass the check there, and refetch again.", true)
        case .failed(.capture, let reason):
            return ("Couldn't read '\(title)' from its website: \(reason). The saved article was kept.", true)
        case .failed(.cleanup, let reason):
            return ("Source Content Cleanup failed for the refetched '\(title)': \(reason). The saved article was kept.", true)
        case .failed(.savedCopy, let reason):
            return ("Couldn't read the saved '\(title)' to measure the refetch against: \(reason). Nothing was changed.", true)
        case .failed(.save, let reason):
            return ("Couldn't save the refetched '\(title)': \(reason). The saved article and its page were kept.", true)
        case .alreadyRunning:
            return ("ForeverLM is fetching '\(title)' already; get_source_content returns its text once that finishes.", true)
        case .notRefreshable:
            return ("'\(title)' is not a web article ForeverLM can refresh from its website.", true)
        case .notInLibrary:
            return ("'\(title)' is archived or no longer in the library (unarchive_source brings back an archived one), so it was not refreshed.", true)
        }
    }
}
