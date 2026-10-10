import Foundation

enum ArticleWebsiteRefreshDecision: Equatable {
    case replace
    case unchanged
    case shorterThanSavedCopy(savedWords: Int, refreshedWords: Int)
}

/// What storage holds for an article a website refresh may replace.
struct ArticleRefreshSavedCopy: Equatable, Sendable {
    /// The canonical text every reader, search and chat reads (`source_content`).
    var text: String?
    /// The extraction the canonical text was cleaned from
    /// (`article_content_preparations.raw_content`). While Source Content
    /// Cleanup has not finished for an article (queued, or failed) it is all
    /// the article holds.
    var stagedRaw: String?
}

/// The two steps of Refresh from Website that leave the Mac: the capture
/// through ForeverLM's browser profile and the Source Content Cleanup model
/// call. The app runs `live`; tests stand in for both.
struct ArticleWebsiteRefreshWork: Sendable {
    var capture: @Sendable (_ url: String, _ sourceID: String) async throws -> SourceService.StagedArticleRefresh
    var clean: @Sendable (
        _ source: AIUsageSource,
        _ rawText: String,
        _ sourceType: StudioSourceType
    ) async throws -> PreparedPaperContent

    static func live(sourceService: SourceService, aiService: AIService) -> ArticleWebsiteRefreshWork {
        ArticleWebsiteRefreshWork(
            capture: { url, sourceID in
                try await sourceService.stageArticleRefresh(url: url, sourceId: sourceID)
            },
            clean: { source, rawText, sourceType in
                try await PaperContentPreparationService(aiService: aiService).prepare(
                    source: source,
                    rawText: rawText,
                    sourceType: sourceType
                )
            }
        )
    }
}

/// The step of a website refresh that failed.
enum ArticleWebsiteRefreshStep: Equatable, Sendable {
    /// Reading the page through the browser profile.
    case capture
    /// Source Content Cleanup of what was read.
    case cleanup
    /// Reading the saved copy the capture is measured against.
    case savedCopy
    /// Installing the archived page and saving the text.
    case save
}

/// What one Refresh from Website did. The menu item shows it as a toast and
/// `refetch_source_content` answers with it, so both report the same run.
/// Every case but `refreshed` leaves the saved article and its archived page
/// exactly as they were.
enum ArticleWebsiteRefreshOutcome: Equatable {
    /// The capture replaced the saved article.
    case refreshed(savedWords: Int, words: Int, archivedPage: Bool)
    /// The website returned the saved text word for word.
    case unchanged(words: Int)
    /// The website returned less text than the saved copy, which was kept.
    case keptSavedCopy(savedWords: Int, fetchedWords: Int)
    /// The site answered with a bot check instead of the article.
    case securityCheck
    case failed(ArticleWebsiteRefreshStep, reason: String)
    /// A fetch or another refresh of this source is running.
    case alreadyRunning
    /// Refresh from Website is not offered for this source.
    case notRefreshable
    /// The source is archived or gone, or left the library while its page
    /// was being read.
    case notInLibrary

    /// The menu item's toast; nil where the menu says nothing because it
    /// does not offer the refresh then.
    var toast: String? {
        switch self {
        case .refreshed(let savedWords, let words, _):
            return savedWords > 0
                ? "Article refreshed: \(savedWords) → \(words) words"
                : "Article refreshed: \(words) words"
        case .unchanged:
            return "The website returned the same article text. Sign in in ForeverLM and try again."
        case .keptSavedCopy:
            return "The website returned less text, so the saved article was kept."
        case .securityCheck:
            return "The website showed a bot check, so the saved article was kept. Pass the check in the Reader and refresh again."
        case .failed(_, let reason):
            return "Couldn’t refresh article: \(reason)"
        case .alreadyRunning, .notRefreshable, .notInLibrary:
            return nil
        }
    }
}

extension StudioViewModel {
    /// Website refresh is deliberately narrower than generic source retry. It
    /// applies only to HTTP article identities; papers, transcripts, files, and
    /// plugin-backed sources have their own authoritative acquisition paths.
    nonisolated static func canRefreshArticleFromWebsite(_ article: StudioArticle) -> Bool {
        guard article.url.hasPrefix("http://") || article.url.hasPrefix("https://") else {
            return false
        }
        guard !PaperService.isDirectPDFURL(article.url) else { return false }
        switch article.sourceType {
        case .article, .manual, .unclassified:
            return true
        default:
            return false
        }
    }

    nonisolated static func articleRefreshWordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// A refresh must never turn a readable source into a shorter paywall
    /// preview, so a capture whose cleaned text has fewer words than the
    /// canonical text is refused. Equal-length text may still contain
    /// legitimate edits; byte-for-byte equality is the only no-op case.
    ///
    /// An article Source Content Cleanup has not finished holds only its
    /// staged extraction, which the capture's own extraction is measured
    /// against, raw against raw, since neither is cleaned; installing the
    /// capture then gives the article the canonical text it lacked. With
    /// neither there is nothing to lose. The row's word count is never the
    /// measure: a failed cleanup leaves it counting text that is gone.
    nonisolated static func articleWebsiteRefreshDecision(
        saved: ArticleRefreshSavedCopy,
        refreshedRaw: String,
        refreshedText: String
    ) -> ArticleWebsiteRefreshDecision {
        let savedText = saved.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !savedText.isEmpty {
            let refreshed = refreshedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if refreshed == savedText { return .unchanged }
            let savedWords = articleRefreshWordCount(savedText)
            let refreshedWords = articleRefreshWordCount(refreshed)
            return refreshedWords < savedWords
                ? .shorterThanSavedCopy(savedWords: savedWords, refreshedWords: refreshedWords)
                : .replace
        }
        let stagedRaw = saved.stagedRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stagedRaw.isEmpty {
            let savedWords = articleRefreshWordCount(stagedRaw)
            let refreshedWords = articleRefreshWordCount(refreshedRaw)
            return refreshedWords < savedWords
                ? .shorterThanSavedCopy(savedWords: savedWords, refreshedWords: refreshedWords)
                : .replace
        }
        return .replace
    }

    /// A failure's reason in words a toast or an assistant can pass on.
    nonisolated static func articleWebsiteRefreshFailureReason(_ error: Error) -> String {
        // `insufficientContent` is worded for the archive.ph route; from a
        // website it means the page had no article text in it.
        if case SourceError.insufficientContent = error {
            return "the page held no article text"
        }
        return error.localizedDescription
    }

    /// The Refresh from Website menu item and its
    /// `foreverlm://source/<id>?action=refresh-from-website` link.
    func refreshArticleFromWebsite(_ articleId: String) async {
        guard let article = articles.first(where: { $0.id == articleId }),
              Self.canRefreshArticleFromWebsite(article),
              !contentFetchInFlight.contains(articleId) else { return }
        showToast("Refreshing article…")
        if let toast = await refreshArticleFromWebsiteOutcome(articleId).toast {
            showToast(toast)
        }
    }

    /// One Refresh from Website, for the menu item and `refetch_source_content`
    /// alike (MCP/UI parity). The page is read through the authenticated
    /// ForeverLM browser profile into a staging folder, and a bot check is
    /// refused there. What passes runs the ordinary configurable Source
    /// Content Cleanup task, and its text is measured against the saved copy:
    /// less text, or the same text, is refused too. Only an accepted capture
    /// writes, its text and archived page together or neither, keeping the
    /// source's identity and every relationship.
    func refreshArticleFromWebsiteOutcome(
        _ articleId: String,
        work: ArticleWebsiteRefreshWork? = nil
    ) async -> ArticleWebsiteRefreshOutcome {
        guard let initial = await sourceForWebsiteRefresh(articleId) else { return .notInLibrary }
        guard Self.canRefreshArticleFromWebsite(initial) else { return .notRefreshable }
        guard !contentFetchInFlight.contains(articleId) else { return .alreadyRunning }
        contentFetchInFlight.insert(articleId)
        defer { contentFetchInFlight.remove(articleId) }
        let work = work ?? .live(sourceService: sourceService, aiService: aiService)

        let capture: SourceService.StagedArticleRefresh
        do {
            capture = try await work.capture(initial.url, articleId)
        } catch {
            return .failed(.capture, reason: Self.articleWebsiteRefreshFailureReason(error))
        }

        // Until the capture has passed every check below, nothing may write:
        // it lives in its staging folder, and each refusal discards it.
        if SourceDiscovery.isSecurityVerificationContent(
            text: capture.article.plainText,
            title: capture.article.pageTitle ?? initial.title,
            url: initial.url
        ) {
            await sourceService.discardStagedArticleRefresh(capture)
            return .securityCheck
        }

        let prepared: PreparedPaperContent
        do {
            prepared = try await work.clean(
                AIUsageSource(source: initial),
                capture.article.plainText,
                initial.sourceType
            )
        } catch {
            await sourceService.discardStagedArticleRefresh(capture)
            return .failed(.cleanup, reason: Self.articleWebsiteRefreshFailureReason(error))
        }

        let saved: ArticleRefreshSavedCopy
        do {
            saved = try await storage.savedArticleCopy(articleId)
        } catch {
            await sourceService.discardStagedArticleRefresh(capture)
            return .failed(.savedCopy, reason: error.localizedDescription)
        }
        switch Self.articleWebsiteRefreshDecision(
            saved: saved,
            refreshedRaw: prepared.raw,
            refreshedText: prepared.clean
        ) {
        case .unchanged:
            await sourceService.discardStagedArticleRefresh(capture)
            return .unchanged(words: prepared.wordCount)
        case .shorterThanSavedCopy(let savedWords, let refreshedWords):
            await sourceService.discardStagedArticleRefresh(capture)
            return .keptSavedCopy(savedWords: savedWords, fetchedWords: refreshedWords)
        case .replace:
            break
        }

        guard var updated = await sourceForWebsiteRefresh(articleId) else {
            await sourceService.discardStagedArticleRefresh(capture)
            return .notInLibrary
        }
        Self.applyWebArticleMetadataIfNeeded(
            to: &updated,
            pageTitle: capture.article.pageTitle,
            pageAuthor: capture.article.pageAuthor,
            content: prepared.clean
        )
        updated.installPreparedArticleContent(
            raw: prepared.raw,
            clean: prepared.clean,
            metadata: prepared.metadata,
            wordCount: prepared.wordCount
        )
        updated.state = .ready
        updated.errorMessage = nil
        updated.isPaywalled = false

        let archive: SourceService.InstalledArticleRefreshArchive?
        do {
            archive = try await sourceService.installStagedArticleRefreshArchive(
                capture,
                sourceId: articleId
            )
        } catch {
            await sourceService.discardStagedArticleRefresh(capture)
            return .failed(.save, reason: error.localizedDescription)
        }
        if let archive {
            updated.localFilePath = archive.finalHTMLPath
        }

        do {
            try await storage.saveSource(updated, syncImmediately: true)
        } catch {
            if let archive {
                await sourceService.rollbackInstalledArticleRefreshArchive(archive, staged: capture)
            } else {
                await sourceService.discardStagedArticleRefresh(capture)
            }
            return .failed(.save, reason: error.localizedDescription)
        }

        if let archive {
            await sourceService.commitInstalledArticleRefreshArchive(archive, sourceId: articleId)
        } else {
            await sourceService.commitStagedArticleRefresh(capture)
        }

        updated.discardPersistedArticleContentHandoff()
        if let index = articles.firstIndex(where: { $0.id == articleId }) {
            articles[index] = updated
        }
        queueSourceEmbeddingRefreshIfReady(articleId)
        return .refreshed(
            savedWords: Self.articleRefreshWordCount(saved.text ?? ""),
            words: prepared.wordCount,
            archivedPage: archive != nil
        )
    }

    /// The source a website refresh works on: the loaded row, or storage's
    /// while the loaded library has not caught up with it (a source an
    /// assistant has just added, or one another device synced for a Job). An
    /// archived source is not refreshed.
    private func sourceForWebsiteRefresh(_ articleId: String) async -> StudioArticle? {
        if let loaded = articles.first(where: { $0.id == articleId }) { return loaded }
        guard let stored = try? await storage.loadSourceWithoutContent(articleId),
              stored.status == .active else { return nil }
        return stored
    }
}
