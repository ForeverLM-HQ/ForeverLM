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

/// Result of the off-main existence / iCloud-stub check for a local document in `fetchContent`.
private enum LocalDocumentFileCheck: Sendable {
    case exists(path: String)
    case downloadingFromICloud
    case missing
}

extension StudioViewModel {

    // MARK: - Content Fetching

    func requiresExplicitPaperDownload(_ article: StudioArticle) -> Bool {
        article.sourceType == .paper
            && article.resolvedPDFPath == nil
            && article.url.hasPrefix("http")
    }

    func fetchContent(for articleId: String) async {
        guard !contentFetchInFlight.contains(articleId) else { return }
        contentFetchInFlight.insert(articleId)
        defer { contentFetchInFlight.remove(articleId) }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }

        if let existingContent = articles[idx].content,
           SourceService.googleDocsResource(from: URL(string: articles[idx].url) ?? URL(fileURLWithPath: "/")) != nil,
           SourceService.isGoogleDocsInterfaceContent(existingContent) {
            articles[idx].content = nil
            articles[idx].wordCount = 0
            articles[idx].state = .queued
            articles[idx].errorMessage = nil
            await storage.clearSourceDerivedData(articleId)
            // Re-resolve by id after the await: a concurrent refresh may have
            // reordered `articles`, so the captured index could now point at a
            // different source (or be out of bounds).
            guard let clearedIdx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            try? await storage.saveSource(articles[clearedIdx])
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }

        // Rows poisoned before the ingestion guards existed still hold a bot-check
        // page as their body. Drop it rather than treat it as content: a stored
        // wall is indistinguishable from a finished source everywhere downstream,
        // so nothing else will ever notice it, and re-fetching is the same work
        // this source would have done had it never been poisoned.
        if let existingContent = articles[idx].content,
           SourceDiscovery.isSecurityVerificationContent(
               text: existingContent,
               title: articles[idx].title,
               url: articles[idx].url
           ) {
            articles[idx].content = nil
            articles[idx].wordCount = 0
            articles[idx].state = .queued
            articles[idx].errorMessage = nil
            await storage.clearSourceDerivedData(articleId)
            guard let clearedIdx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            try? await storage.saveSource(articles[clearedIdx])
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }

        if let existingContent = articles[idx].content?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existingContent.isEmpty,
           articles[idx].state == .queued || articles[idx].state == .fetching || articles[idx].state == .error {
            articles[idx].wordCount = existingContent.split(separator: " ").count
            if articles[idx].sourceType == .paper {
                if articles[idx].hasPaperIngestionAttestation {
                    articles[idx].state = .ready
                    articles[idx].errorMessage = nil
                } else {
                    articles[idx].prepareForPaperMetadataExtraction()
                }
            } else {
                articles[idx].state = .ready
                articles[idx].errorMessage = nil
            }
            let savedArticle = articles[idx]
            let shouldEnqueuePaperMetadata = savedArticle.sourceType == .paper
                && savedArticle.requiresPaperMetadataAI
            try? await storage.saveSource(savedArticle)
            if shouldEnqueuePaperMetadata {
                enqueueAutoMetadataExtraction([articleId])
            }
            queueSourceEmbeddingRefreshIfReady(articleId)
            return
        }

        // Content is on its way the moment we enter fetchContent, so mark the
        // source as fetching before the first async suspension below. Otherwise
        // the reader briefly renders the empty "No content" prompt during the
        // cache load, even though content is about to appear.
        //   - YouTube auto-fetches a transcript when none is cached.
        //   - Meetings, imported videos, courses, and Slack threads keep their
        //     transcript in the database and load it from the cache load just below.
        var markedFetchingForCacheLoad = false
        if articles[idx].content == nil, !articles[idx].cachedIsLocalDocument {
            let type = articles[idx].sourceType
            let isCachedTranscript = type == .meeting || type == .video || type == .course
            if isCachedTranscript || YouTubeTranscriptService.isYouTubeURL(articles[idx].url) {
                articles[idx].state = .fetching
                articles[idx].errorMessage = nil
                markedFetchingForCacheLoad = true
            }
        }

        if articles[idx].content == nil && !articles[idx].cachedIsLocalDocument,
           let cachedContent = await storage.loadSourceContent(articleId),
           !cachedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Re-resolve by id after the await before touching `articles` again.
            guard let cachedIdx = articles.firstIndex(where: { $0.id == articleId }) else { return }
            if SourceService.googleDocsResource(from: URL(string: articles[cachedIdx].url) ?? URL(fileURLWithPath: "/")) != nil,
               SourceService.isGoogleDocsInterfaceContent(cachedContent) {
                await storage.clearSourceDerivedData(articleId)
            } else if articles[cachedIdx].sourceType == .podcast,
                      Self.isWebPageAddress(articles[cachedIdx].url) {
                // A podcast filed under a web page holds the page's text: show
                // notes, not a transcript. It never becomes the episode's content.
                await storage.clearSourceDerivedData(articleId)
            } else if SourceDiscovery.isSecurityVerificationContent(
                text: cachedContent,
                title: articles[cachedIdx].title,
                url: articles[cachedIdx].url
            ) {
                await storage.clearSourceDerivedData(articleId)
            } else {
                articles[cachedIdx].content = cachedContent
                articles[cachedIdx].wordCount = cachedContent.split(separator: " ").count
                if articles[cachedIdx].state == .queued || articles[cachedIdx].state == .fetching || articles[cachedIdx].state == .error {
                    if articles[cachedIdx].sourceType == .paper {
                        if articles[cachedIdx].hasPaperIngestionAttestation {
                            articles[cachedIdx].state = .ready
                        } else {
                            articles[cachedIdx].prepareForPaperMetadataExtraction()
                        }
                    } else {
                        articles[cachedIdx].state = .ready
                    }
                }
                if articles[cachedIdx].sourceType != .paper || articles[cachedIdx].state == .ready {
                    articles[cachedIdx].errorMessage = nil
                }
                let savedArticle = articles[cachedIdx]
                let shouldEnqueuePaperMetadata = savedArticle.sourceType == .paper
                    && savedArticle.requiresPaperMetadataAI
                try? await storage.saveSource(savedArticle)
                if shouldEnqueuePaperMetadata {
                    enqueueAutoMetadataExtraction([articleId])
                }
                return
            }
        }

        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }

        if articles[idx].content != nil {
            isFetchingContent = false
            return
        }

        if articles[idx].cachedIsLocalDocument {
            // Existence and iCloud-stub checks are synchronous filesystem stats
            // (possibly against evicted iCloud files) — run them off the main actor.
            //
            // Resolve through `locateSourceFile`, the same multi-root lookup the
            // "needs PDF" flows reach via `resolvedPDFPath`. A single-root
            // `fileExists` disagrees with them whenever the file sits under a
            // content root that isn't the current one — an iCloud conflict fork,
            // or the local fallback root the app falls back to when the container
            // entitlement is missing — and this branch acts on the disagreement.
            // Two-step like `existingResolvedLocalPath`: books and courses keep the
            // file path in `url` rather than `localFilePath`.
            let storedPath = articles[idx].localFilePath
            let fallbackPath = articles[idx].url
            let localFile: LocalDocumentFileCheck = await Task.detached(priority: .userInitiated) {
                let candidate = storedPath.flatMap { StorageService.locateSourceFile($0) }
                    ?? StorageService.locateSourceFile(fallbackPath)
                guard let located = candidate else { return .missing }
                if FileManager.default.fileExists(atPath: located) { return .exists(path: located) }
                // `locateSourceFile` matched this candidate on its `.icloud`
                // placeholder: the file is known, just not downloaded yet.
                let fileURL = URL(fileURLWithPath: located)
                let stub = fileURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(fileURL.lastPathComponent).icloud")
                try? FileManager.default.startDownloadingUbiquitousItem(at: stub)
                return .downloadingFromICloud
            }.value
            guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }

            switch localFile {
            case .exists(let localPath):
                // For EPUB chapter files, load the content into the article (as plain text for AI use)
                if articles[idx].cachedIsEPUBChapter && articles[idx].content == nil {
                    if let content = await Self.loadEPUBChapterContent(path: localPath),
                       let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                        articles[idx2].content = content
                    }
                }
                guard let latestIndex = articles.firstIndex(where: { $0.id == articleId }) else { return }
                if articles[latestIndex].sourceType == .paper {
                    if articles[latestIndex].hasPaperIngestionAttestation {
                        articles[latestIndex].state = .ready
                        articles[latestIndex].errorMessage = nil
                    } else {
                        articles[latestIndex].prepareForPaperMetadataExtraction()
                    }
                } else {
                    articles[latestIndex].state = .ready
                }
                let savedArticle = articles[latestIndex]
                let shouldExtractPaperMetadata = savedArticle.sourceType == .paper
                    && savedArticle.requiresPaperMetadataAI
                try? await storage.saveSource(savedArticle)
                if shouldExtractPaperMetadata {
                    _ = await extractPaperMetadataWithAI(id: articleId, showToasts: false)
                }
                queueSourceEmbeddingRefreshIfReady(articleId)
                isFetchingContent = false
                return
            case .downloadingFromICloud:
                articles[idx].state = .error
                articles[idx].errorMessage = "Downloading from iCloud… Try again in a moment."
                isFetchingContent = false
                return
            case .missing:
                // A stat that cannot find the file is a *read* failure, and a read
                // failure must never destroy the stored path: the file may be under
                // a root this launch cannot see, or mid-eviction, and clearing the
                // column orphans a PDF that is still on disk. Nothing is gained by
                // clearing it either — `resolvedPDFPath` already reports a source
                // whose file is absent as needing a PDF, so re-download flows see
                // this paper with the path left intact, and an attachment that was
                // only unreachable recovers on its own once the file resolves again.
                if articles[idx].sourceType == .paper,
                   articles[idx].url.hasPrefix("http"),
                   articles[idx].localFilePath != nil {
                    articles[idx].state = .queued
                    articles[idx].errorMessage = nil
                    try? await storage.saveSource(articles[idx])
                    enqueueAutoPaperFetch(articleId)
                } else {
                    articles[idx].state = .error
                    articles[idx].errorMessage = "File not found."
                    isFetchingContent = false
                    return
                }
            }
        }
        // Already in-flight elsewhere — but not when this call itself just marked
        // the source .fetching for the cache load above; bailing here would strand
        // cache-miss transcripts (and YouTube auto-fetch) in a permanent spinner.
        guard articles[idx].state != .fetching || markedFetchingForCacheLoad else { return }

        // LLM reclassification: journal domains (Nature, Science, etc.) host both research
        // papers and editorial content (news, commentary). The URL-based detector can't
        // distinguish them, so ask the LLM before committing to the paper PDF path.
        //
        // Note this predicate is `requiresExplicitPaperDownload`, which returns
        // just below: every source classified here is one `fetchContent` is about
        // to walk away from, so nothing re-enters to record a result and the same
        // call would otherwise repeat on every sweep, forever. One attempt per
        // source per session is enough to correct a misfiled news item.
        if articles[idx].sourceType == .paper && articles[idx].resolvedPDFPath == nil
            && articles[idx].url.hasPrefix("http"),
           !sourceClassificationAttemptedIDs.contains(articleId),
           let classifyConfig = KeychainService.resolveConfig(for: .sourceClassification) {
            sourceClassificationAttemptedIDs.insert(articleId)
            let classified = await aiService.classifySourceType(
                source: AIUsageSource(source: articles[idx]),
                url: articles[idx].url,
                title: articles[idx].title,
                contentPreview: "",
                config: classifyConfig
            )
            if let classified,
               classified != .paper,
               let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                if classified == .book,
                   Self.looksLikeScholarlyPaper(url: articles[idx2].url) {
                    logger.info("Blocked LLM book classification for scholarly source: \(self.articles[idx2].title)")
                } else {
                    let previousType = articles[idx2].sourceType
                    Self.applyClassifiedSourceType(classified, to: &articles[idx2])
                    if await persistSource(articles[idx2], context: "Save source classification", showErrorToast: false),
                       articles[idx2].sourceType == .book {
                        await persistWholeBookMetadataIfNeeded(for: articles[idx2])
                    }
                    if articles[idx2].sourceType != previousType {
                        logger.info("LLM reclassified \(self.articles[idx2].title) from \(previousType.rawValue) to \(self.articles[idx2].sourceType.rawValue)")
                    }
                }
            }
        }

        // Re-resolve index after potential reclassification
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }

        // Remote papers stay passive until the user explicitly requests a PDF
        // download from the reader or a paper-specific action.
        if requiresExplicitPaperDownload(articles[idx]) {
            return
        }

        // Re-resolve index after potential mutations above
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }

        // Podcast episodes: transcript content is stored in the DB. A row a
        // named feed filed under the episode's web page hydrates too; it is
        // first resolved to the public episode Apple transcribes.
        if articles[idx].sourceType == .podcast,
           Self.podcastRowCanHydrate(url: articles[idx].url, showName: articles[idx].domain) {
            isFetchingContent = true
            articles[idx].state = .fetching
            articles[idx].errorMessage = nil

            // Check if content already exists in DB. Text under a web-page
            // address is the page, never a transcript, so it is not content.
            if !Self.isWebPageAddress(articles[idx].url),
               let existingContent = await storage.loadSourceContent(articleId), !existingContent.isEmpty {
                if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                    articles[idx2].content = existingContent
                    articles[idx2].wordCount = existingContent.split(separator: " ").count
                    articles[idx2].state = .ready
                    articles[idx2].errorMessage = nil
                    try? await storage.saveSource(articles[idx2])
                    queueSourceEmbeddingRefreshIfReady(articleId)
                }
                isFetchingContent = false
                return
            }

            if let candidate = podcastHydrationCandidate(for: articleId) {
                let storage = self.storage
                let homeDir = realHomeDirectory
                // Resolved once from Settings and threaded down, so every
                // transcript call uses the model the user picked.
                let config = KeychainService.resolveConfig(for: .transcriptFormatting)
                let result = await Task.detached(priority: .utility) {
                    await Self.hydratePodcastTranscript(
                        candidate,
                        storage: storage,
                        homeDir: homeDir,
                        config: config
                    )
                }.value
                await applyPodcastHydrationResult(result)
            } else if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx2].state = .error
                articles[idx2].errorMessage = Self.noPodcastTranscriptMessage
                try? await storage.saveSource(articles[idx2])
            }
            isFetchingContent = false
            return
        }

        // Podcast web URLs must NEVER be web-scraped. Route to Apple Podcasts matching.
        if articles[idx].sourceType == .podcast && articles[idx].url.hasPrefix("http") {
            // Clear any accidentally web-scraped content (show notes, not a transcript)
            if articles[idx].content != nil {
                articles[idx].content = nil
                articles[idx].wordCount = 0
            }
            await findAndOfferPodcast(for: articleId)
            isFetchingContent = false
            return
        }

        // YouTube URLs: fetch transcript directly
        if YouTubeTranscriptService.isYouTubeURL(articles[idx].url) {
            await fetchYouTubeTranscript(for: articleId)
            isFetchingContent = false
            return
        }

        // Teachable lectures: the transcript is the lecture's audio. Scraping
        // the page would store the course sidebar as the source's text.
        if TeachableCourseService.isLectureURL(articles[idx].url) {
            await fetchTeachableTranscript(for: articleId)
            isFetchingContent = false
            return
        }

        // Zoom recording links: resolve via the Zoom recording pipeline — never
        // web-scrape the player page (it renders nothing useful and may be a
        // passcode gate).
        if ZoomRecordingService.isZoomRecordingURL(articles[idx].url) {
            // Opening a session is not asking for the recording to be
            // downloaded: Zoom's transcript is asked for, and waited for.
            await fetchZoomTranscript(for: articleId, request: .automatic)
            isFetchingContent = false
            return
        }

        if articles[idx].sourceType == .book
            && (articles[idx].url.lowercased().hasSuffix(".pdf") || articles[idx].remotePDFURL != nil) {
            isFetchingContent = true
            articles[idx].state = .fetching
            if await downloadRemoteBookPDF(for: articleId) {
                isFetchingContent = false
                return
            }
            if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx2].state = .error
                articles[idx2].errorMessage = "Book PDF download failed. Try importing the file manually."
                try? await storage.saveSource(articles[idx2])
            }
            isFetchingContent = false
            return
        }

        // PDF URLs must never be web-scraped — they need to be downloaded as binary files.
        // A course handout/assignment is a document, not an academic paper: preserve its
        // source type and skip the paper-metadata AI pipeline.
        if PaperService.isDirectPDFURL(articles[idx].url) && articles[idx].url.hasPrefix("http") {
            isFetchingContent = true
            articles[idx].state = .fetching
            let downloaded: Bool
            if articles[idx].sourceType == .paper {
                downloaded = await downloadPaperPDF(for: articleId).success
            } else {
                downloaded = await downloadDocumentPDF(for: articleId)
            }
            if downloaded {
                isFetchingContent = false
                return
            }
            if let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                articles[idx2].state = .error
                articles[idx2].errorMessage = "PDF download failed. Try attaching the file manually."
                if articles[idx2].sourceType == .paper {
                    PaperIngestionDiagnostics.recordFailure(
                        sourceID: articleId,
                        title: articles[idx2].title,
                        message: articles[idx2].errorMessage ?? "PDF download failed."
                    )
                }
                try? await storage.saveSource(articles[idx2])
            }
            isFetchingContent = false
            return
        }

        isFetchingContent = true
        articles[idx].state = .fetching
        articles[idx].errorMessage = nil

        do {
            var content: String
            var pageTitle: String?
            var pageAuthor: String?
            var titleEvidence: PaperService.WebArticleTitleEvidence?
            // The reader document the fetch archived. It becomes the source's
            // path only once the page has passed the bot-check guard below:
            // the archive is written before the text is judged, so for a
            // blocked source it holds the wall, and a wall on record as the
            // document would keep the reader from ever replacing it.
            var archivedLocalPath: String?
            // X posts archive too: their capture is the only copy that survives
            // an offline Mac, a Screen Time block, or a logged-out webview.
            let isWebArticleType = articles[idx].sourceType == .article
                || articles[idx].sourceType == .manual
                || articles[idx].sourceType == .unclassified
                || articles[idx].sourceType == .xPost
            do {
                if isWebArticleType {
                    // Archive web articles locally with images for offline reading
                    let archived = try await sourceService.fetchAndArchiveWebContent(
                        url: articles[idx].url,
                        sourceId: articles[idx].id,
                        // A bookmarked post already holds the authenticated
                        // API's full text; a public capture must never replace
                        // it with a shorter copy.
                        existingText: articles[idx].content
                    )
                    content = archived.plainText
                    pageTitle = archived.pageTitle
                    pageAuthor = archived.pageAuthor
                    titleEvidence = archived.titleEvidence
                    archivedLocalPath = archived.localHTMLPath
                } else {
                    content = try await sourceService.fetchContent(from: articles[idx].url)
                }
            } catch {
                // If primary URL failed and we have a podcast web fallback, try that
                if let webURL = articles[idx].podcastWebPageURL, !webURL.isEmpty {
                    logger.info("Primary URL failed, trying podcast web page: \(webURL)")
                    content = try await sourceService.fetchContent(from: webURL)
                } else {
                    throw error
                }
            }
            if SourceDiscovery.isSecurityVerificationContent(
                text: content,
                title: pageTitle ?? articles[idx].title,
                url: articles[idx].url
            ) {
                await recordSecurityChallengeBlock(articleId: articleId)
                isFetchingContent = false
                return
            }
            if let archivedLocalPath,
               let archivedIdx = articles.firstIndex(where: { $0.id == articleId }) {
                articles[archivedIdx].localFilePath = archivedLocalPath
            }

            guard await installFetchedWebContent(
                articleId: articleId,
                content: content,
                pageTitle: pageTitle,
                pageAuthor: pageAuthor,
                titleEvidence: titleEvidence
            ) else {
                isFetchingContent = false
                return
            }
        } catch {
            let url = articles[idx].url
            logger.error("Failed to fetch content for \(url): \(error.localizedDescription)")

            // A post that arrived from X bookmark sync already carries its text.
            // Failing to capture the surrounding thread — X unreachable, the
            // post deleted, the account gone private — costs the thread, not
            // the post, so the row stays readable instead of turning red.
            if articles[idx].sourceType == .xPost,
               !(articles[idx].content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                articles[idx].state = .ready
                articles[idx].errorMessage = nil
                isFetchingContent = false
                queueSourceEmbeddingRefreshIfReady(articleId)
                return
            }

            // Auto-remove items whose content can't be decoded (e.g. non-UTF-8 video pages)
            // Never remove PDF URLs — they should be downloaded, not web-scraped.
            if let sourceErr = error as? SourceError, sourceErr == .decodingFailed {
                if url.lowercased().hasSuffix(".pdf") {
                    articles[idx].state = .error
                    articles[idx].errorMessage = "PDF download failed. Try attaching the file manually."
                    if articles[idx].sourceType == .paper {
                        PaperIngestionDiagnostics.recordFailure(
                            sourceID: articleId,
                            title: articles[idx].title,
                            message: articles[idx].errorMessage ?? "PDF download failed."
                        )
                    }
                    await persistSource(articles[idx], context: "Save paper error state")
                } else {
                    try? await storage.archiveSource(articleId)
                    articles.remove(at: idx)
                    if selectedArticleId == articleId { selectedArticleId = nil }
                }
            } else {
                articles[idx].state = .error
                articles[idx].errorMessage = error.localizedDescription
                if SourceService.googleDocsResource(from: URL(string: url) ?? URL(fileURLWithPath: "/")) != nil {
                    try? await storage.saveSource(articles[idx])
                }
            }
        }

        isFetchingContent = false

        queueSourceEmbeddingRefreshIfReady(articleId)
    }


    /// Everything that turns fetched web text into a finished source: metadata
    /// from the page, the one-time paper/article classification, Source Content
    /// Cleanup, the canonical save, and the title/author fill. Shared by the
    /// ingestion fetch and by the reader adopting a page it has on screen, so
    /// the two routes cannot drift apart in what a "ready" article means.
    ///
    /// Returns false when the source was left in a state that must not be
    /// treated as finished (cleanup failed, the save failed, or the source
    /// disappeared mid-way); the caller then skips the embedding refresh.
    private func installFetchedWebContent(
        articleId: String,
        content: String,
        pageTitle: String?,
        pageAuthor: String?,
        titleEvidence: PaperService.WebArticleTitleEvidence? = nil
    ) async -> Bool {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return false }

        articles[idx].content = content
        articles[idx].wordCount = content.split(separator: " ").count

        Self.applyWebArticleMetadataIfNeeded(
            to: &articles[idx],
            pageTitle: pageTitle,
            pageAuthor: pageAuthor,
            content: content
        )

        // LLM-based source classification: if this is still unclassified or article type,
        // ask the LLM whether it's actually a paper.
        if articles[idx].sourceType == .article || articles[idx].sourceType == .unclassified,
           !sourceClassificationAttemptedIDs.contains(articleId),
           let classifyConfig = KeychainService.resolveConfig(for: .sourceClassification) {
            // An article that the model confirms as an article has no type
            // transition to persist. Without an explicit attempted marker,
            // every content retry asks the identical 300–400 token question
            // again — the fixed-prompt loop observed in OpenRouter activity.
            sourceClassificationAttemptedIDs.insert(articleId)
            let classified = await aiService.classifySourceType(
                source: AIUsageSource(source: articles[idx]),
                url: articles[idx].url,
                title: articles[idx].title,
                contentPreview: content,
                config: classifyConfig
            )
            if let classified, classified != articles[idx].sourceType {
                Self.applyClassifiedSourceType(classified, to: &articles[idx])
                logger.info("LLM classified \(self.articles[idx].title) as \(self.articles[idx].sourceType.rawValue)")
            } else if articles[idx].sourceType == .unclassified {
                // LLM confirmed it's an article (or failed) — promote from unclassified
                articles[idx].sourceType = .article
            }
        }

        // Papers must have a local PDF to be considered ready — HTML content alone is not enough
        if articles[idx].sourceType == .paper && !articles[idx].isPDF {
            articles[idx].state = .error
            articles[idx].errorMessage = "PDF not available. Attach the PDF manually."
            PaperIngestionDiagnostics.recordFailure(
                sourceID: articleId,
                title: articles[idx].title,
                message: articles[idx].errorMessage ?? "PDF not available."
            )
        } else if articles[idx].sourceType == .paper {
            articles[idx].prepareForPaperMetadataExtraction()
        } else if articles[idx].sourceType == .article
                    || articles[idx].sourceType == .manual
                    || articles[idx].sourceType == .unclassified {
            do {
                let prepared = try await PaperContentPreparationService(aiService: aiService).prepare(
                    source: AIUsageSource(source: articles[idx]),
                    rawText: content,
                    sourceType: .article
                )
                articles[idx].installPreparedArticleContent(
                    raw: prepared.raw,
                    clean: prepared.clean,
                    metadata: prepared.metadata,
                    wordCount: prepared.wordCount
                )
                articles[idx].state = .ready
                articles[idx].errorMessage = nil
            } catch {
                let failureMessage = PaperContentPreparationService.articleIngestionFailureMessage(for: error)
                let shouldRetryAutomatically =
                    AITransientErrorClassifier.shouldRetryAutomatically(error)
                let rawSHA256 = await Self.contentSHA256OffMain(content)
                guard let failureIndex = articles.firstIndex(where: { $0.id == articleId }) else {
                    return false
                }
                var failedArticle = articles[failureIndex]
                failedArticle.state = shouldRetryAutomatically ? .queued : .error
                failedArticle.errorMessage = shouldRetryAutomatically ? nil : failureMessage
                failedArticle.stageArticleContentCleanup(raw: content, rawSHA256: rawSHA256)
                try? await storage.saveSource(failedArticle)
                failedArticle.discardPersistedArticleContentHandoff()
                if let currentIndex = articles.firstIndex(where: { $0.id == articleId }) {
                    articles[currentIndex] = failedArticle
                }
                return false
            }
        } else {
            articles[idx].state = .ready
        }
        if articles[idx].sourceType == .paper {
            let savedPaper = articles[idx]
            let shouldExtractPaperMetadata = savedPaper.requiresPaperMetadataAI
                && savedPaper.isPDF
            await persistSource(savedPaper, context: "Save paper content state")
            if shouldExtractPaperMetadata {
                _ = await extractPaperMetadataWithAI(id: articleId, showToasts: false)
            }
        } else {
            var savedArticle = articles[idx]
            do {
                try await storage.saveSource(savedArticle)
            } catch {
                articles[idx].state = .error
                articles[idx].errorMessage = "Could not save canonical source content: \(error.localizedDescription)"
                showToast(articles[idx].errorMessage ?? "Could not save canonical source content")
                return false
            }
            savedArticle.discardPersistedArticleContentHandoff()
            articles[idx] = savedArticle
            if articles[idx].sourceType == .book {
                await persistWholeBookMetadataIfNeeded(for: articles[idx])
            }
        }

        // Name and credit the article. The page's own metadata is site chrome
        // as often as it is the headline — "Waypoint Bio" on every post of that
        // site, "… — Amplify Partners" on another's — so the article-metadata
        // model reads every title the page offered beside the opening text
        // (`PaperService.WebArticleTitleEvidence`) and states the headline. Its
        // answer replaces a title the page supplied, never one a person typed.
        if articles[idx].sourceType == .article || articles[idx].sourceType == .unclassified,
           let metaConfig = KeychainService.resolveConfig(for: .articleMetadata) {
            let current = articles[idx]
            let titleIsPageSupplied = Self.articleTitleIsPageSupplied(
                current.title,
                pageTitle: pageTitle,
                evidence: titleEvidence,
                domain: current.domain,
                url: current.url
            )
            let needsAuthor = current.author == nil || current.author?.isEmpty == true
            let needsYear = current.publishedYear == nil || current.publishedYear?.isEmpty == true
            if titleIsPageSupplied || needsAuthor || needsYear {
                let result = await aiService.fixArticleTitle(
                    source: AIUsageSource(source: current),
                    currentTitle: current.title,
                    url: current.url,
                    content: current.content,
                    evidence: titleEvidence,
                    config: metaConfig
                )
                if let result,
                   let idx2 = articles.firstIndex(where: { $0.id == articleId }) {
                    var updated = articles[idx2]
                    if titleIsPageSupplied, let title = result.title, !title.isEmpty {
                        updated.title = title
                    }
                    if needsAuthor, let author = result.author, !author.isEmpty {
                        updated.author = author
                    }
                    if needsYear, let year = result.year, !year.isEmpty {
                        updated.publishedYear = year
                    }
                    if updated.title != articles[idx2].title
                        || updated.author != articles[idx2].author
                        || updated.publishedYear != articles[idx2].publishedYear {
                        articles[idx2] = updated
                        try? await storage.saveSource(updated)
                    }
                }
            }
        }
        return true
    }

    /// Put text the database already holds for a source into the in-memory
    /// model, without fetching anything.
    ///
    /// The reader renders from `articles`, and a remote paper's row is loaded
    /// without its text, so opening one showed no text even when the store had
    /// it. Nothing is persisted here: this only teaches the loaded model what
    /// storage already knows. A stored bot-check page is refused rather than
    /// shown as the paper — the same guard the fetch applies.
    func hydrateStoredContent(for articleId: String) async {
        guard let article = articles.first(where: { $0.id == articleId }),
              !Self.sourceHasReadableContent(article) else { return }
        guard let stored = await storage.loadSourceContent(articleId),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !SourceDiscovery.isSecurityVerificationContent(
            text: stored,
            title: article.title,
            url: article.url
        ) else { return }
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              !Self.sourceHasReadableContent(articles[idx]) else { return }
        articles[idx].content = stored
        if articles[idx].wordCount == nil {
            articles[idx].wordCount = stored.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
    }

    // MARK: - Content the reader has on screen

    /// Shown for a source whose fetch was answered by a publisher bot check.
    static let securityChallengeFailureMessage =
        "Blocked by a publisher security check. Retry, or attach the PDF manually."

    /// Park a source whose fetch returned a bot-check interstitial instead of the
    /// document.
    ///
    /// The wall renders as an ordinary page with ordinary text, so the extractors
    /// cannot tell it from a document and used to store it: a few hundred
    /// characters of Cloudflare boilerplate became the source's body, the paper
    /// went `.ready` on it, and from then on search, chat, and Listen read the
    /// wall instead of the paper — silently, because a `.ready` source with
    /// content looks finished from every angle. Nothing is stored here, and the
    /// source goes to the actionable error state so it surfaces in Papers Needing
    /// Attention with a Retry instead of hiding as done.
    func recordSecurityChallengeBlock(articleId: String) async {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else { return }
        articles[idx].content = nil
        articles[idx].wordCount = 0
        articles[idx].state = .error
        articles[idx].errorMessage = Self.securityChallengeFailureMessage
        // The fetch archives the page before its text is judged, so the
        // reader document on disk for a blocked web article is the wall. A
        // wall on record would count as the source's local document and keep
        // the reader's own page from ever standing in for the fetch.
        if articles[idx].cachedIsArchivedArticle {
            articles[idx].localFilePath = nil
        }
        let blocked = articles[idx]
        await sourceService.discardArticleArchive(sourceID: articleId)
        if blocked.sourceType == .paper {
            PaperIngestionDiagnostics.recordFailure(
                sourceID: articleId,
                title: blocked.title,
                message: Self.securityChallengeFailureMessage
            )
        }
        try? await storage.saveSource(blocked)
        logger.info("Security check blocked content for \(blocked.title)")
    }


    /// Whether the text a source holds is text worth showing. For anything but
    /// a paper that is any text at all. A paper without a PDF is held to
    /// `PaperService.looksLikePaperFullText`: builds before 70 could store the
    /// publisher's preview — abstract, figure titles and Extended Data legends —
    /// as a paper's text, and a reader showing that text hid the publisher's
    /// page, which is where the learner signs in and where the paper is.
    nonisolated static func sourceHoldsReadableText(_ article: StudioArticle) -> Bool {
        guard let content = article.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return false }
        guard article.sourceType == .paper, !article.isPDF else { return true }
        return PaperService.looksLikePaperFullText(content)
    }

    /// Whether a page the reader has rendered may become this source's saved
    /// content.
    ///
    /// A web article with nothing stored yet qualifies on its own: the page the
    /// learner is reading is the article. A paper never does on its own. A
    /// paper is a PDF, and the page a publisher shows is taken for the paper
    /// only when the learner asks for it (`learnerAsked`) — the reader's
    /// **Save Paper from Page** — for a paper with no PDF on record: a
    /// publisher that lets a subscriber read online but never hands out the
    /// PDF shows the paper only in a browsing session, so the reader is the one
    /// place its text can be had, and the page is then printed to the PDF the
    /// paper needs. The paywall marker keeps such a paper eligible — it
    /// records that no PDF could be found, which is exactly this case.
    /// Podcasts, videos, Zoom recordings, Google Docs and direct PDF links are
    /// never web-scraped; a source that already reads from a local document has
    /// its content; and a fetch in `.fetching` is about to answer for itself.
    static func canAdoptRenderedReaderPage(_ article: StudioArticle, learnerAsked: Bool = false) -> Bool {
        let isPaper = article.sourceType == .paper
        guard article.sourceType == .article
                || article.sourceType == .manual
                || article.sourceType == .unclassified
                || (isPaper && learnerAsked) else { return false }
        guard article.url.hasPrefix("http://") || article.url.hasPrefix("https://") else { return false }
        // An archived article is normally its own document. One on record for
        // a source parked as blocked is the bot check the fetch archived
        // before judging the text (builds before 99 kept it), and the page
        // the reader has is what replaces it.
        let holdsOnlyTheWall = article.cachedIsArchivedArticle
            && article.state == .error
            && article.errorMessage == securityChallengeFailureMessage
        guard !sourceHoldsReadableText(article),
              article.state != .fetching,
              !article.cachedIsLocalDocument || holdsOnlyTheWall,
              isPaper || !article.isPaywalled else { return false }
        guard let url = URL(string: article.url) else { return false }
        if PaperService.isDirectPDFURL(article.url) { return false }
        if YouTubeTranscriptService.isYouTubeURL(article.url) { return false }
        if ZoomRecordingService.isZoomRecordingURL(article.url) { return false }
        if SourceService.googleDocsResource(from: url) != nil { return false }
        return true
    }

    /// Whether this paper's reader should stop waiting on a PDF the publisher
    /// refuses and show what it does have instead.
    ///
    /// A paper with text already stored has something better than a lock
    /// screen to show — that text — and a paper with a landing page has a page
    /// the learner may be able to read, and sign in on. A paper with neither
    /// keeps the failure view, which is where attaching a PDF lives.
    func readerShouldAbandonRemotePDF(_ articleId: String) -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }) else { return false }
        guard article.sourceType == .paper,
              article.cachedResolvedPDFPath == nil,
              !readerAbandonedRemotePDFSourceIDs.contains(articleId) else { return false }
        let hasPublisherPage = article.remotePDFURL != nil
            && URL(string: article.url) != article.remotePDFURL
        return Self.sourceHoldsReadableText(article) || hasPublisherPage
    }

    /// Stop offering this paper's remote PDF in the reader for the rest of the
    /// session, so the routing shows the text or the publisher's page.
    func abandonRemotePDFInReader(_ articleId: String) {
        readerAbandonedRemotePDFSourceIDs.insert(articleId)
    }

    /// Whether this source's reader has given up on its remote PDF.
    func readerAbandonedRemotePDF(_ articleId: String) -> Bool {
        readerAbandonedRemotePDFSourceIDs.contains(articleId)
    }

    /// Whether the reader showing this source should offer its page as content
    /// on its own, without the learner asking. Never true for a paper.
    func readerPageCanSupplySourceContent(_ articleId: String) -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }) else { return false }
        return Self.canAdoptRenderedReaderPage(article)
            && !contentFetchInFlight.contains(articleId)
            && !resolvingPaperPDFIds.contains(articleId)
    }

    /// Whether the reader should offer **Save Paper from Page** for this
    /// source: a paper with no PDF on record, whose page the reader can show.
    func readerCanSavePaperFromPage(_ articleId: String) -> Bool {
        guard let article = articles.first(where: { $0.id == articleId }),
              article.sourceType == .paper else { return false }
        return Self.canAdoptRenderedReaderPage(article, learnerAsked: true)
            && !contentFetchInFlight.contains(articleId)
            && !resolvingPaperPDFIds.contains(articleId)
    }

    /// Whether a fetch for this source is still running. Opening a source with
    /// no content starts one, so the reader's page usually finishes while the
    /// hidden fetch is still at the publisher's door; the reader waits for that
    /// fetch to answer before offering what it has, because a fetch that
    /// succeeds makes the offer unnecessary and one that fails makes it the
    /// only copy.
    func sourceFetchIsInFlight(_ articleId: String) -> Bool {
        if contentFetchInFlight.contains(articleId) { return true }
        if resolvingPaperPDFIds.contains(articleId) { return true }
        return articles.first(where: { $0.id == articleId })?.state == .fetching
    }

    /// Save the page the reader has finished rendering as the source's content.
    ///
    /// The ingestion fetch reads a page from a hidden web view, and a publisher
    /// bot check answers that view with its interstitial, so the source is
    /// parked as blocked. The reader's own web view is a real browsing session:
    /// the check clears there and the article is on screen, next to a row that
    /// still says it is blocked. This takes the document that view has and runs
    /// it through the same archive and cleanup the fetch would have, so the row
    /// finishes because the learner could read it.
    ///
    /// A wall is not adopted. The check's own page finishes a navigation too,
    /// and clearing it navigates again, so a rejected snapshot costs nothing:
    /// the next finished load offers the real page.
    ///
    /// A paper is only ever adopted when the learner asked (`learnerAsked`,
    /// the reader's **Save Paper from Page**), and then the page has to be the
    /// paper, not the publisher's access wall — the abstract, the reference
    /// list and a purchase panel that a reader without access is shown. Its
    /// text goes through the paper pipeline (Source Content Cleanup and
    /// metadata extraction) rather than the article one, and no reader document
    /// is archived; the caller prints the page to the paper's PDF.
    /// What `adoptRenderedReaderPage` did with the page.
    enum RenderedReaderPageAdoption: Equatable {
        /// Why a page was turned down. The reader reports these to a learner
        /// who asked; the automatic route stays quiet.
        enum Refusal: Equatable {
            /// The source does not take its content from a page, a fetch is
            /// already answering for it, or the page was empty.
            case ineligible
            /// The page is a bot check or the publisher's access wall: the
            /// paper is not on it, and signing in is what changes that.
            case accessWall
            /// The page is shorter than a paper's body: the abstract and the
            /// front matter a publisher shows a reader without access.
            case tooShort
            /// Archiving or storing the page failed.
            case failed
        }

        case notAdopted(Refusal)
        case adoptedArticle
        /// The page's text is now the paper's text. `needsPDF` says the paper
        /// still has no file; a paper is a PDF, so the reader answers that by
        /// asking the publisher once more with its session and then printing
        /// the page it has.
        case adoptedPaperText(needsPDF: Bool)
    }

    @discardableResult
    func adoptRenderedReaderPage(
        articleId: String,
        html: String,
        pageTitle: String?,
        visibleText: String,
        learnerAsked: Bool = false
    ) async -> RenderedReaderPageAdoption {
        guard let idx = articles.firstIndex(where: { $0.id == articleId }),
              Self.canAdoptRenderedReaderPage(articles[idx], learnerAsked: learnerAsked),
              !contentFetchInFlight.contains(articleId) else { return .notAdopted(.ineligible) }
        let sourceURL = articles[idx].url
        let knownTitle = articles[idx].title
        if SourceDiscovery.isSecurityVerificationContent(
            text: visibleText,
            title: pageTitle ?? knownTitle,
            url: sourceURL
        ) {
            return .notAdopted(.accessWall)
        }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notAdopted(.ineligible) }
        let isPaper = articles[idx].sourceType == .paper
        // The wall is judged on what the page shows, before the chrome filter
        // has a chance to strip the purchase panel as site furniture.
        if isPaper, PaperService.looksLikePublisherAccessWall(text: visibleText) {
            logger.info("The page open for \(knownTitle) is the publisher's access wall; the paper's text is not on it")
            return .notAdopted(.accessWall)
        }

        contentFetchInFlight.insert(articleId)
        defer { contentFetchInFlight.remove(articleId) }

        let previousState = articles[idx].state
        let previousError = articles[idx].errorMessage
        isFetchingContent = true
        articles[idx].state = .fetching
        articles[idx].errorMessage = nil

        func restore() {
            guard let current = articles.firstIndex(where: { $0.id == articleId }) else { return }
            articles[current].state = previousState
            articles[current].errorMessage = previousError
            isFetchingContent = false
        }

        let archived: SourceService.ArchivedArticle
        do {
            archived = try await sourceService.archiveRenderedWebContent(
                html: html,
                url: sourceURL,
                sourceId: articleId,
                archiveToDisk: !isPaper
            )
        } catch {
            logger.info("Rendered page for \(knownTitle) was not archived: \(error.localizedDescription)")
            restore()
            return .notAdopted(.failed)
        }
        guard let idx = articles.firstIndex(where: { $0.id == articleId }) else {
            isFetchingContent = false
            return .notAdopted(.failed)
        }
        if SourceDiscovery.isSecurityVerificationContent(
            text: archived.plainText,
            title: archived.pageTitle ?? pageTitle ?? knownTitle,
            url: sourceURL
        ) {
            restore()
            return .notAdopted(.accessWall)
        }
        if isPaper {
            guard PaperService.looksLikePaperFullText(archived.plainText) else {
                logger.info("The page open for \(knownTitle) is too short to be the paper; nothing stored")
                restore()
                return .notAdopted(.tooShort)
            }
            logger.info("Adopted the reader's rendered page as the full text of paper \(knownTitle)")
            let ready = await installRecoveredPaperText(for: articleId, raw: archived.plainText)
            if !ready, articles.first(where: { $0.id == articleId })?.state == .fetching {
                // Nothing was stored and no state of its own was recorded.
                restore()
                return .notAdopted(.failed)
            }
            isFetchingContent = false
            queueSourceEmbeddingRefreshIfReady(articleId)
            showToast("Saved the paper's text from the page you're reading")
            return .adoptedPaperText(needsPDF: !paperHasLocalPDF(articleId))
        }
        if let localPath = archived.localHTMLPath {
            articles[idx].localFilePath = localPath
        }
        logger.info("Adopted the reader's rendered page as content for \(knownTitle)")
        guard await installFetchedWebContent(
            articleId: articleId,
            content: archived.plainText,
            pageTitle: archived.pageTitle ?? pageTitle,
            pageAuthor: archived.pageAuthor,
            titleEvidence: archived.titleEvidence
        ) else {
            isFetchingContent = false
            return .notAdopted(.failed)
        }
        isFetchingContent = false
        queueSourceEmbeddingRefreshIfReady(articleId)
        showToast("Saved the article from the page you're reading")
        return .adoptedArticle
    }


    // MARK: - Book Cover Paths

    /// Pre-warm the in-memory and disk thumbnail cache for a book cover image.
    func prewarmBookCoverThumbnail(coverPath: String) {
        Task.detached(priority: .utility) {
            Self.prewarmBookCoverThumbnailOffMain(coverPath: coverPath)
        }
    }
}
