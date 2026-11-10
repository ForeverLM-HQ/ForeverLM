// Part of ReviewSessionManager: session titles, source context and the source catalog.

import Foundation
import Observation
import PDFKit
import os

extension ReviewSessionManager {
    /// The attached-source catalog. Carries no source text: what the model
    /// gets up front is an index it can choose from, not the library itself.
    struct SourceContext {
        let sources: [FoundSource]
        let manifest: String
        /// Sources with text available to load, determined from stored content
        /// lengths rather than by extracting each one.
        let readableSourceIDs: Set<String>
    }

    func reviewTitle(topic: String, articles: [StudioArticle]) -> String {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTopic.isEmpty { return trimmedTopic }
        if articles.count == 1, let article = articles.first {
            return article.title
        }
        if !articles.isEmpty {
            return genericSelectedSourcesTitle
        }
        return ""
    }

    func updateSuggestedSessionTitleIfNeeded(from assistantResponse: String) async {
        guard let sessionID else { return }
        guard titleIsProvisional else { return }
        // Its own Background route (Settings › Background › Tasks), not the
        // chat's model: nobody waits on a title.
        guard let config = KeychainService.resolveConfig(for: .chatTitle) else { return }
        let userMessage = (chatMessages.first(where: { $0.role == .user })?.content)
            .map { AttachedImageReference.textOnly($0) }
        let title: String
        do {
            guard let suggested = try await AIUsageAttribution.$sessionID.withValue(sessionID, operation: {
                try await aiService.suggestReviewSessionTitle(
                    from: assistantResponse,
                    userMessage: userMessage,
                    config: config
                )
            }) else { return }
            title = suggested
        } catch {
            logger.error("Failed to generate in-app review session title: \(error.localizedDescription)")
            return
        }
        do {
            // The learner may have renamed the chat from the rail while this
            // turn was streaming. Their title wins: only the echoed opening
            // message is ever replaced by the suggestion.
            let replaced = try await storage.replaceProvisionalReviewSessionTitle(
                sessionID: sessionID,
                provisionalTitle: topic,
                title: title
            )
            if replaced {
                topic = title
            } else {
                logger.info("Kept the learner's chat title over the AI suggestion for session \(sessionID)")
            }
            titleIsProvisional = false
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update in-app review session title: \(error.localizedDescription)")
        }
    }

    /// Build the attached-source catalog: one line per source, no source text.
    ///
    /// This is everything the model knows about the pool up front. It is
    /// deliberately cheap — one content-length query, then string building over
    /// fields already in memory — because a notebook pool routinely holds
    /// hundreds of sources and this runs on session start. The previous
    /// version extracted every attached source here (PDF parsing and Vision
    /// OCR included) purely to decide which ones to stuff, which both blocked
    /// the session opening and threw away most of the work.
    ///
    /// Nothing in a manifest line may vary between turns of one conversation.
    /// The manifest rides in the cached stable prefix, so a byline that
    /// re-renders differently — a timestamp, live read-state — would cost a
    /// full cache miss on every request. See `stablePrefixAcrossTurnsForTesting`.
    /// Adopt a freshly built catalog, loading text only for sources the
    /// learner explicitly chose.
    ///
    /// `preloading` is for entry points that already carry intent — opening a
    /// chat on one source, or dropping sources into an open chat. A notebook's
    /// pool passes nothing: those sources stay catalog-only until the model
    /// asks for them.
    func applyAttachedSourceContext(
        _ context: SourceContext,
        articles: [StudioArticle],
        preloading preloadIDs: Set<String>
    ) async {
        // An idle composer can already contain explicitly dropped source text.
        // Carry that intent into the newly created session instead of resetting
        // its visible context count and making the first request catalog-only.
        let stagedPreloadIDs = sessionID == nil && !sessionActive ? loadedSourceIDs : []
        let effectivePreloadIDs = preloadIDs.union(stagedPreloadIDs)
        foundSources = context.sources
        sourceManifest = context.manifest
        fullSourceRetrievalOffsets = [:]
        // Set before loading any text: block headers are numbered against
        // this list so they line up with the catalog the model was given.
        activeSourceIDs = context.sources.map(\.id)
        activeArticles = articles

        if !effectivePreloadIDs.isEmpty {
            await refreshSourceContextBudgetFromSelectedModel()
        }
        let loaded = await loadSourceTextBlock(
            for: articles.filter { effectivePreloadIDs.contains($0.id) },
            budget: sourceContextCharacterLimit
        )
        sourceContext = loaded.text
        perSourcePromptShares = loaded.shares
        loadedSourceIDs = loaded.loadedIDs
    }

    func loadSourceContext(from articles: [StudioArticle]) async -> SourceContext {
        guard !articles.isEmpty else {
            return SourceContext(sources: [], manifest: "", readableSourceIDs: [])
        }

        let sources = articles.map { article in
            FoundSource(
                id: article.id,
                title: article.title,
                sourceType: article.sourceType.rawValue,
                wordCount: article.wordCount
            )
        }

        let storedLengths = await storage.sourceContentLengths(for: articles.map(\.id))

        // A source is readable if it has stored text, or a local file or
        // in-memory content we could extract from on demand. The file is
        // deliberately not opened: proving readability by extraction is the
        // per-source PDF/OCR work this path exists to stop doing.
        let readableSourceIDs = Set(
            articles
                .filter { Self.hasLoadableText($0, storedLength: storedLengths[$0.id]) }
                .map(\.id)
        )

        let inventoryLines = articles.enumerated().map { index, article in
            manifestLine(index: index + 1, article: article, storedLength: storedLengths[article.id])
        }
        var inventory = """
        Attached sources (\(articles.count)):
        \(inventoryLines.joined(separator: "\n"))
        """
        let outline = await courseOutline(forSourceIDs: articles.map(\.id))
        if !outline.isEmpty {
            inventory += "\n\n" + outline
        }

        return SourceContext(
            sources: sources,
            manifest: inventory,
            readableSourceIDs: readableSourceIDs
        )
    }

    /// The courses the attached lectures belong to, with the quizzes written
    /// for them (`CourseChatOutline`), so a chat about a lecture links the
    /// lecture's quiz instead of improvising one and names the next lecture
    /// from the course rather than a library search. Built with the catalog,
    /// never per turn. A failed read leaves the catalog as it was: the chat
    /// still works from its sources, and the log says why the outline is
    /// missing.
    private func courseOutline(forSourceIDs sourceIDs: [String]) async -> String {
        do {
            guard let material = try await storage.courseChatOutlineMaterial(forSourceIDs: sourceIDs) else { return "" }
            return CourseChatOutline.text(attachedSourceIDs: sourceIDs, material: material)
        } catch {
            logger.error("Could not read the course outline for a chat's sources: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// One catalog line.
    ///
    /// This is the only signal the model has when deciding what is worth
    /// loading, so it carries whatever identifying metadata the source
    /// actually has. A bare title is a poor basis for that choice — "Chapter
    /// 47" or "Episode 219" tells it nothing.
    private func manifestLine(index: Int, article: StudioArticle, storedLength: Int?) -> String {
        var line = "\(index). \(article.title)"
        if let byline = manifestByline(for: article) {
            line += " — \(byline)"
        }
        let facts = [
            article.sourceType.rawValue,
            "id: \(article.id)",
            manifestSizeDescription(article: article, storedLength: storedLength)
        ] + manifestDateFacts(for: article)
        line += " (\(facts.joined(separator: ", ")))"
        if let note = Self.thinCaptureNote(for: article, storedLength: storedLength) {
            line += " — \(note)"
        }
        return line
    }

    /// A web article whose saved text is a stub: a page its scripts write
    /// (a Substack app link), a paywall, a bot check saved as the article. The
    /// tutor is told so, and told how to mend it, instead of answering that the
    /// passage "isn't loaded" and asking the learner for a PDF (product owner,
    /// 2026-10-07, a chat about a page whose article held 15 words of
    /// navigation). `refetch_source_content` is Refresh from Website; it
    /// replaces the text only when the site returns at least as much. Under the
    /// words a page may have and still be read again in a browser
    /// (`SourceService.scriptRenderedPageWordThreshold`), by characters, since
    /// the count outlives the text.
    nonisolated static func thinCaptureNote(for article: StudioArticle, storedLength: Int?) -> String? {
        guard let storedLength, storedLength > 0,
              storedLength < SourceService.scriptRenderedPageWordThreshold * 6,
              StudioViewModel.canRefreshArticleFromWebsite(article) else { return nil }
        return "saved text is only about \(max(1, storedLength / 6)) words, probably a failed capture: call refetch_source_content for this id before answering a question about it, and say that you did"
    }

    private func manifestDateFacts(for article: StudioArticle) -> [String] {
        guard article.sourceType == .meeting else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return ["occurred: \(formatter.string(from: article.dateAdded))"]
    }

    private func manifestByline(for article: StudioArticle) -> String? {
        // A book or course chapter is only identifiable through its parent:
        // "All Cells Use Proteins as Catalysts" means little alone, and naming
        // the book is what tells the model it can pull a single chapter
        // instead of eight hundred thousand characters of textbook.
        if let parent = article.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parent.isEmpty {
            return "in \(parent)"
        }

        var parts: [String] = []
        if let author = article.shortAuthorDisplay?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty {
            parts.append(author)
        }

        // Podcast show names and article publishers live in `domain`; the
        // projection view never maps them onto `author` or `journal`.
        let journal = article.journal?.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = article.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if let journal, !journal.isEmpty {
            parts.append(journal)
        } else if !domain.isEmpty {
            parts.append(domain)
        }

        if let year = article.publishedYear?.trimmingCharacters(in: .whitespacesAndNewlines),
           !year.isEmpty {
            parts.append(year)
        }

        let byline = parts.joined(separator: ", ")
        return byline.isEmpty ? nil : byline
    }

    /// Size the model can budget against when deciding what to pull in.
    ///
    /// Prefers stored content length over `wordCount`: word counts are absent
    /// for most papers and every course despite the text being present, so a
    /// model budgeting on them would systematically skip the largest sources —
    /// exactly the ones where the choice matters.
    private func manifestSizeDescription(article: StudioArticle, storedLength: Int?) -> String {
        if let storedLength, storedLength > 0 {
            return "~\(Self.approximateSizeLabel(characters: storedLength))"
        }
        // A word count outlives the text it counted — archiving deletes the
        // content row and leaves the count behind — so it is only trustworthy
        // once we know there is something to load. Checked in this order, a
        // revived source advertises "no text available" instead of nine
        // thousand words the model cannot read.
        guard Self.hasLoadableText(article, storedLength: storedLength) else {
            return "no text available"
        }
        if let words = article.wordCount, words > 0 {
            return "~\(words) words"
        }
        return "size unknown until loaded"
    }

    private static func approximateSizeLabel(characters: Int) -> String {
        if characters >= 1_000_000 { return "\(characters / 1_000_000)M chars" }
        if characters >= 1_000 { return "\(characters / 1_000)k chars" }
        return "\(characters) chars"
    }

    /// Assemble verbatim text for sources that have earned a place in the
    /// prompt — dropped in by the learner, or asked for by the model.
    ///
    /// Pool sources never come through here on their own. That is the whole
    /// point of the split: attaching a notebook's sources makes them *available*,
    /// not resident.
    func loadSourceTextBlock(for articles: [StudioArticle], budget: Int) async -> LoadedSourceText {
        guard !articles.isEmpty, budget > 0 else { return .empty }

        var parts: [String] = []
        var shares: [ChatContextBreakdown.SourceShare] = []
        var loadedIDs: Set<String> = []
        var remaining = budget

        for article in articles {
            guard remaining > 0 else { break }
            let content = await sourceContent(for: article)
            guard !content.isEmpty else { continue }

            let header = manifestNumberedHeader(for: article)
            let available = max(0, remaining - header.count)
            guard available > 0 else { break }

            let truncationNote = "\n\n[Source text truncated to fit the chat context budget. Call retrieve_sources for a focused passage from the rest of this source.]"
            let willTruncate = content.count > available
            let availableForText = willTruncate ? max(0, available - truncationNote.count) : available
            let part = header
                + String(content.prefix(availableForText))
                + (willTruncate ? truncationNote : "")

            parts.append(part)
            shares.append(ChatContextBreakdown.SourceShare(
                id: article.id,
                title: article.title,
                characters: part.count
            ))
            loadedIDs.insert(article.id)
            remaining -= part.count + Self.sourceBlockSeparator.count
        }

        return LoadedSourceText(
            text: parts.joined(separator: Self.sourceBlockSeparator),
            shares: shares,
            loadedIDs: loadedIDs
        )
    }

    /// Header tying a loaded block back to its catalog line, so the model can
    /// match "Source 17" in the text against entry 17 in `<attached_sources>`.
    private func manifestNumberedHeader(for article: StudioArticle) -> String {
        let descriptor = "\(article.sourceType.rawValue), id: \(article.id)"
        guard let index = activeSourceIDs.firstIndex(of: article.id) else {
            return "## \(article.title) (\(descriptor))\n\n"
        }
        return "## Source \(index + 1): \(article.title) (\(descriptor))\n\n"
    }
}
