// Part of ReviewSessionManager: tool call parsing and source retrieval.

import Foundation
import PDFKit

extension ReviewSessionManager {
    /// Why a source is in a retrieval result: the model asked for it (or the
    /// ranker chose it for a query-only call), or ForeverLM added it because it
    /// outranks something the model named.
    private enum RetrievalProvenance {
        case requested
        case crossCheck
    }

    /// A source chosen for retrieval, carrying the evidence that chose it.
    private struct RetrievalCandidate {
        let article: StudioArticle
        /// The chunk the semantic branch matched, when it contributed. Chunk
        /// ids are positional over a deterministic splitter, so this lets the
        /// excerpt centre on the passage that actually answered the query
        /// rather than re-deriving it from keyword counts.
        let bestChunkID: String?
        var provenance: RetrievalProvenance = .requested
    }

    struct RetrievalToolCall: Equatable {
        let sourceIDs: [String]
        let query: String
        let reason: String
        let maxSources: Int
        let wantsFullText: Bool
        /// Character cursor for paged full-source reads. Nil continues from
        /// the last page this session read for the selected source.
        let cursor: Int?
    }

    func parseRetrievalToolCall(_ response: String) -> RetrievalToolCall? {
        guard let object = toolCallObject(from: response),
              object["tool"] as? String == "retrieve_sources" else {
            return nil
        }
        let call = retrievalToolCall(fromArguments: object)
        guard !call.sourceIDs.isEmpty || !call.query.isEmpty else { return nil }
        return call
    }

    /// Map raw retrieval arguments (from either the text protocol or a native
    /// tool call) to a validated retrieval request. Never fails: an empty call
    /// retrieves the first attached sources, which produces a graceful result.
    func retrievalToolCall(fromArguments object: [String: Any]) -> RetrievalToolCall {
        let sourceIDs = (object["source_ids"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let query = (object["query"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = (object["reason"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxSources = min(
            sourceRetrievalMaxSources,
            max(1, object["max_sources"] as? Int ?? sourceRetrievalDefaultMaxSources)
        )
        let mode = (object["mode"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let wantsFullText = mode == "full"
            || object["full_text"] as? Bool == true
            || object["include_full_text"] as? Bool == true
        let cursor = (object["cursor"] as? Int).map { max(0, $0) }

        return RetrievalToolCall(
            sourceIDs: sourceIDs,
            query: query,
            reason: reason,
            maxSources: wantsFullText ? 1 : maxSources,
            wantsFullText: wantsFullText,
            cursor: cursor
        )
    }

    func toolCallObject(from response: String) -> [String: Any]? {
        Self.toolCallObjectStatic(from: response)
    }

    static func toolCallObjectStatic(from response: String) -> [String: Any]? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let startTag = "<flm_tool_call>"
        let endTag = "</flm_tool_call>"
        guard let start = trimmed.range(of: startTag) else { return nil }
        // A block whose closing tag never arrived — a cut-off stream, a model
        // that forgot it — still usually carries a complete JSON object. Let the
        // balanced scan below decide where the object ends rather than refusing
        // the call over the missing tag.
        let bodyEnd = trimmed
            .range(of: endTag, range: start.upperBound..<trimmed.endIndex)?
            .lowerBound ?? trimmed.endIndex
        return toolCallObject(fromBlockBody: String(trimmed[start.upperBound..<bodyEnd]))
    }

    /// Read the JSON object out of an `<flm_tool_call>` body, tolerating the
    /// near-misses models actually emit: a stray closing brace after the object,
    /// a markdown fence, prose on either side of it.
    ///
    /// Strictness here is not free. A rejected call runs nothing, and the reply
    /// that carried it renders with the block stripped — so the learner is left
    /// looking at a bare "I'll pull that up" and the work never happens. When the
    /// first balanced `{…}` parses, that is the call the model meant; trailing
    /// junk is the model's typo, not the learner's problem.
    nonisolated static func toolCallObject(fromBlockBody body: String) -> [String: Any]? {
        if let object = decodedJSONObject(body) { return object }
        guard let balanced = firstBalancedJSONObject(in: body) else { return nil }
        return decodedJSONObject(balanced)
    }

    nonisolated private static func decodedJSONObject(_ json: String) -> [String: Any]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The first `{…}` in the text whose braces balance. Braces inside JSON
    /// strings (and escapes within them) are not structure, so they are skipped.
    nonisolated private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var insideString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if insideString {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    insideString = false
                }
            } else {
                switch character {
                case "\"":
                    insideString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Text the model pulled in, plus which sources it came from.
    ///
    /// The source IDs matter beyond bookkeeping: they are what moves the
    /// composer's "in context" count, which is the learner's only signal that
    /// the model actually read something before answering.
    struct RetrievalResult {
        let text: String
        let loadedIDs: Set<String>
        let shares: [ChatContextBreakdown.SourceShare]

        static func failure(_ text: String) -> RetrievalResult {
            RetrievalResult(text: text, loadedIDs: [], shares: [])
        }
    }

    func retrieveSourceContext(for call: RetrievalToolCall) async -> RetrievalResult {
        let activeIDSet = Set(activeSourceIDs)
        let requestedIDs = call.sourceIDs.filter { activeIDSet.contains($0) }
        // Ids outside the catalog used to vanish: named alone, they fell
        // through to a ranking of the catalog, so the model got passages from
        // sources it never asked for. The answer now names them and the route
        // that does read them.
        let outsideIDs = call.sourceIDs.filter { !activeIDSet.contains($0) }
        let outsideNote = outsideIDs.isEmpty ? "" : """
        Not in this chat's catalog, so not read: \(outsideIDs.joined(separator: ", ")). \(Self.outsideCatalogReadingRule)
        """
        if !outsideIDs.isEmpty, requestedIDs.isEmpty {
            return .failure(outsideNote)
        }
        let queryForScoring = call.query.isEmpty ? call.reason : call.query
        let candidates: [RetrievalCandidate]
        if requestedIDs.isEmpty {
            candidates = await rankedArticlesForRetrieval(query: call.query, maxSources: call.maxSources)
        } else {
            let requestedSet = Set(requestedIDs)
            // An explicit source identity decides which record to read, but
            // the query still decides where inside it. The old path discarded
            // the query here, so every focused retry returned the same prefix.
            //
            // That same ranking now also audits the choice. A model picking from
            // the catalog sees titles and little else, so a chapter whose title
            // does not imply its contents is invisible to it — and naming ids
            // used to bypass the ranker outright, which made the guess final.
            // The ranker runs over the whole pool regardless, and anything that
            // outranks a named source comes back as a short lead.
            let ranking: [SourceSearchHit]
            if call.wantsFullText {
                // A paged start-to-finish read is a deliberate choice of one
                // source. Ranking has no say in it, and a lead would only eat
                // into the page budget.
                ranking = []
            } else {
                ranking = await rankedPoolForRetrieval(
                    query: queryForScoring,
                    pool: activeIDSet
                )
            }
            let bestChunkIDs = Dictionary(
                ranking.compactMap { hit in hit.bestChunkId.map { (hit.sourceId, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            let requested = activeArticles
                .filter { requestedSet.contains($0.id) }
                .prefix(call.maxSources)
                .map { RetrievalCandidate(article: $0, bestChunkID: bestChunkIDs[$0.id]) }
            candidates = Array(requested) + (await crossCheckCandidates(
                ranking: ranking,
                requested: Set(requested.map(\.article.id)),
                bestChunkIDs: bestChunkIDs
            ))
        }

        guard !candidates.isEmpty else {
            return .failure("""
            Source retrieval failed.
            Reason: \(call.reason.isEmpty ? "No reason provided." : call.reason)
            Query: \(call.query.isEmpty ? "(none)" : call.query)
            No requested source IDs matched the attached source catalog.
            """)
        }

        var parts: [String] = []
        var loadedIDs: Set<String> = []
        var shares: [ChatContextBreakdown.SourceShare] = []
        // Full-source reads use bounded pages. A single 64k result was clipped
        // by the tool-result budget anyway and offered no way to request the
        // omitted suffix; 16k pages make every continuation useful.
        let retrievalLimit = sourceRetrievalCharacterLimit
        // Leads are reserved for up front, so the requested reads keep their
        // depth and the trailing prefix() below cannot clip the audit away.
        let crossCheckCount = candidates.filter { $0.provenance == .crossCheck }.count
        let requestedCount = candidates.count - crossCheckCount
        let requestedShare = max(
            0,
            retrievalLimit - crossCheckCount * sourceCrossCheckCharacterLimit
        ) / max(requestedCount, 1)
        var remainingCharacters = retrievalLimit

        for candidate in candidates {
            guard remainingCharacters > 0 else { break }
            // Stop reads no further sources; the turn ends at its next round.
            guard !Task.isCancelled else { break }
            let article = candidate.article
            let content = await sourceContent(for: article)
            let header: String
            switch candidate.provenance {
            case .requested:
                header = """
                ## \(article.title) (\(article.sourceType.rawValue), id: \(article.id))
                Retrieval reason: \(call.reason.isEmpty ? "Tutor requested this source." : call.reason)
                Query: \(call.query.isEmpty ? "(none)" : call.query)

                """
            case .crossCheck:
                header = """
                ## \(article.title) (\(article.sourceType.rawValue), id: \(article.id))
                Added by ForeverLM: you did not ask for this source, but it ranks above one you did for this query. This is a short lead, not a full read — call retrieve_sources with this id before relying on it, and never conclude from a lead that the material is absent.
                Query: \(call.query.isEmpty ? "(none)" : call.query)

                """
            }

            let body: String
            if content.isEmpty {
                // Stated plainly so the model can tell the learner this source
                // is in the pool but unreadable, rather than answering around
                // a gap it was never told about.
                body = "[This source has no extracted text, so nothing can be read from it. It is in the pool by title only — say so rather than describing what it might contain.]"
            } else if call.wantsFullText {
                let available = max(0, remainingCharacters - header.count)
                guard available > 0 else { break }
                let start = min(
                    call.cursor ?? fullSourceRetrievalOffsets[article.id] ?? 0,
                    content.count
                )
                let page = Self.fullSourcePage(
                    content: content,
                    cursor: start,
                    limit: available,
                    sourceID: article.id
                )
                body = page.text
                if let next = page.nextCursor {
                    fullSourceRetrievalOffsets[article.id] = next
                } else {
                    fullSourceRetrievalOffsets.removeValue(forKey: article.id)
                }
            } else {
                // The cap covers the header as well as the excerpt. A share
                // measured on the body alone does not sum to the limit, and the
                // overflow comes out of whatever is read last — which is the
                // audit, the one thing here that cannot defend its own budget.
                let perSourceCap = candidate.provenance == .crossCheck
                    ? sourceCrossCheckCharacterLimit
                    : requestedShare
                let available = max(0, min(remainingCharacters, perSourceCap) - header.count)
                guard available > 0 else { break }
                // Transcript and book sources can be millions of characters.
                // Exact-query scanning and deterministic chunking are linear in
                // that text, so neither belongs on this @MainActor manager.
                body = await Task.detached(priority: .userInitiated) {
                    Self.focusedExcerpt(
                        from: content,
                        query: queryForScoring,
                        limit: available,
                        bestChunkID: candidate.bestChunkID
                    )
                }.value
            }

            let part = header + body
            parts.append(part)
            // Only count a source as loaded when real text came back; an
            // empty-content placeholder would otherwise inflate the "in
            // context" count with sources the model still cannot read.
            if !content.isEmpty {
                loadedIDs.insert(article.id)
                shares.append(ChatContextBreakdown.SourceShare(
                    id: article.id,
                    title: article.title,
                    characters: part.count
                ))
            }
            remainingCharacters -= part.count + Self.sourceBlockSeparator.count
        }

        guard !parts.isEmpty else {
            return .failure("Source retrieval returned no readable excerpts.")
        }
        let read = String(parts.joined(separator: Self.sourceBlockSeparator).prefix(retrievalLimit))
        return RetrievalResult(
            text: outsideNote.isEmpty ? read : outsideNote + Self.sourceBlockSeparator + read,
            loadedIDs: loadedIDs,
            shares: shares
        )
    }

    struct FullSourcePage {
        let text: String
        let nextCursor: Int?
    }

    /// Return one progress-bearing page of a complete source read. Cursor
    /// values count Swift characters, the same unit as every prompt budget in
    /// this type, so a page boundary cannot corrupt source text.
    nonisolated static func fullSourcePage(
        content: String,
        cursor: Int,
        limit: Int,
        sourceID: String
    ) -> FullSourcePage {
        let start = min(max(0, cursor), content.count)
        // Reserve room for progress and continuation metadata. The normal
        // limit is 16k; this keeps the complete result strictly below it.
        let bodyCapacity = max(0, limit - 512)
        let body = String(content.dropFirst(start).prefix(bodyCapacity))
        let end = start + body.count
        let progress = "Full-source page: characters \(start)-\(end) of \(content.count).\n\n"

        if end < content.count {
            let continuation = """

            [More source text remains. Continue retrieve_sources with mode \"full\", source_ids [\"\(sourceID)\"], and next_cursor \(end) as cursor. This page is complete; do not retry cursor \(start).]
            """
            return FullSourcePage(text: progress + body + continuation, nextCursor: end)
        }

        return FullSourcePage(
            text: progress + body + "\n\n[End of source reached. The complete source read is finished.]",
            nextCursor: nil
        )
    }

    /// Rank every attached source against the query.
    ///
    /// One search answers both questions a named-source retrieval raises: which
    /// chunk to centre on inside each record the model chose, and what the
    /// model failed to choose. The whole pool is ranked rather than just the
    /// named subset, because the second question cannot be asked of a set that
    /// already excludes the answer.
    ///
    /// Identity stays deterministic. Ranking selects passages and raises leads;
    /// it never rewrites which record an id refers to.
    private func rankedPoolForRetrieval(
        query: String,
        pool: Set<String>
    ) async -> [SourceSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !pool.isEmpty else { return [] }
        let queryVector: [Float]
        do {
            queryVector = try await AppleTextEmbedder.embed(trimmed)
        } catch {
            logger.error("Embedding the retrieval query failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return await storage.searchSources(
            queryText: trimmed,
            queryVector: queryVector,
            limit: pool.count,
            restrictedTo: pool
        )
    }

    /// Sources the ranker placed above one the model named.
    ///
    /// These are leads, not reads: a bounded excerpt each, labelled as such, so
    /// the model can decide whether to retrieve one properly. Anything with no
    /// readable text is dropped rather than spending a lead slot on a
    /// placeholder saying so.
    private func crossCheckCandidates(
        ranking: [SourceSearchHit],
        requested: Set<String>,
        bestChunkIDs: [String: String]
    ) async -> [RetrievalCandidate] {
        let selected = Self.crossCheckSelection(
            rankedIDs: ranking.map(\.sourceId),
            requested: requested,
            limit: sourceCrossCheckMaxSources
        )
        guard !selected.isEmpty else { return [] }
        let articlesByID = Dictionary(
            activeArticles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let articles = selected.compactMap { articlesByID[$0] }
        let readable = await readableSourceIDs(among: articles)
        return articles
            .filter { readable.contains($0.id) }
            .map {
                RetrievalCandidate(
                    article: $0,
                    bestChunkID: bestChunkIDs[$0.id],
                    provenance: .crossCheck
                )
            }
    }

    /// Ids the ranker placed above the worst-ranked source the model named.
    ///
    /// The bar is deliberately the model's *worst* pick rather than its best: a
    /// source outranking one the model chose to spend budget on is a source the
    /// ranker would have read instead, and that is the miss worth surfacing. A
    /// model that named the top of the ranking clears the bar outright and
    /// nothing is added, so choosing well costs nothing.
    nonisolated static func crossCheckSelection(
        rankedIDs: [String],
        requested: Set<String>,
        limit: Int
    ) -> [String] {
        guard !rankedIDs.isEmpty, !requested.isEmpty, limit > 0 else { return [] }
        let namedRanks = rankedIDs.enumerated()
            .filter { requested.contains($0.element) }
            .map(\.offset)
        // A named source the ranker cannot score for this query is no evidence
        // the model chose well, so the whole ranking stays eligible.
        let bar = namedRanks.count == requested.count
            ? (namedRanks.max() ?? 0)
            : rankedIDs.count
        return rankedIDs
            .prefix(bar)
            .filter { !requested.contains($0) }
            .prefix(limit)
            .map { $0 }
    }

    func appendRetrievedSourceContext(_ retrieved: String) {
        let combined = sourceContext.isEmpty
            ? retrieved
            : sourceContext + Self.sourceBlockSeparator + retrieved
        // Trim from the tail, not the head. Keeping the suffix would shift every
        // byte of the already-cached source block and cost a full cache miss on
        // every remaining turn; keeping the prefix preserves the cached head and
        // drops only the newest excerpt.
        // A cut says so, in the text itself: otherwise the excerpt the model just
        // asked for vanishes and it answers as though it had read it. The note
        // sits past the limit and is cut off again by the next append's prefix,
        // so it is always the last thing in the block and never accumulates.
        sourceContext = combined.count > sourceContextCharacterLimit
            ? String(combined.prefix(sourceContextCharacterLimit)) + Self.sourceBudgetReachedNote
            : combined
    }

    static let sourceBudgetReachedNote =
        "\n\n[The source text held in this chat is full, so the newest excerpt was not added. Answer from the text already loaded and the catalog, and tell the learner when something you need is not available here.]"

    /// Fold a retrieval result into the session's context. Paged full-source
    /// reads append too: replacing the block on every page used to discard the
    /// earlier pages before the model could synthesize across them.
    func adoptRetrievedSourceContext(_ retrieved: RetrievalResult) {
        appendRetrievedSourceContext(retrieved.text)
        perSourcePromptShares.append(contentsOf: retrieved.shares)
        loadedSourceIDs.formUnion(retrieved.loadedIDs)
        Task { await persistLoadedSourceIDs() }
    }

    /// Rank the attached sources against a query, using the app's hybrid
    /// search scoped to this chat's pool.
    ///
    /// The previous ranking loaded and lowercased the **full text of every
    /// attached source on every call** — for a Notebook pool, dozens of document
    /// loads including PDF extraction and Vision OCR, enough to stall the main
    /// actor outright. It then scored by substring presence, so a source naming
    /// a term four hundred times ranked exactly level with one naming it once,
    /// and a title match outweighed the body 8:1. This reads no source text at
    /// all: one SQLite pass plus a matrix multiply over the pool's chunk
    /// vectors, fused with BM25 so a rare token — a gene symbol, an acronym —
    /// still retrieves by exact match, which a 512-dim pooled vector cannot do.
    private func rankedArticlesForRetrieval(query: String, maxSources: Int) async -> [RetrievalCandidate] {
        let attachedIDs = Set(activeSourceIDs)
        guard !attachedIDs.isEmpty, maxSources > 0 else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attachmentOrderedCandidates(limit: maxSources) }

        // Semantic retrieval is one algorithm. If its model is unavailable, do
        // not silently substitute keyword scoring; preserve attachment order and
        // let the configured chat model work from the selected source text.
        let queryVector: [Float]
        do {
            queryVector = try await AppleTextEmbedder.embed(trimmed)
        } catch {
            logger.error("Embedding the source query failed, keeping attachment order: \(error.localizedDescription, privacy: .public)")
            return attachmentOrderedCandidates(limit: maxSources)
        }

        // Over-fetch, so sources with no readable text can be pushed below
        // readable ones without leaving the caller short of candidates.
        let hits = await storage.searchSources(
            queryText: trimmed,
            queryVector: queryVector,
            limit: max(maxSources * 3, maxSources),
            restrictedTo: attachedIDs
        )

        let articlesByID = Dictionary(
            activeArticles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ranked = hits.compactMap { hit -> RetrievalCandidate? in
            guard let article = articlesByID[hit.sourceId] else { return nil }
            return RetrievalCandidate(article: article, bestChunkID: hit.bestChunkId)
        }
        guard !ranked.isEmpty else { return attachmentOrderedCandidates(limit: maxSources) }

        // A source with no recoverable text still carries one title-only
        // embedding chunk so it stays findable by name — and that chunk is a
        // pure title vector, which can outrank a source whose text is present
        // and genuinely answers the question. Readable sources therefore go
        // first, so an unreadable one never takes a slot from one that can be
        // read. They are ordered down rather than dropped: a source that is in
        // the pool but has no extracted text is something the learner needs to
        // hear about, not something to quietly omit.
        let readable = await readableSourceIDs(among: ranked.map(\.article))
        let withText = ranked.filter { readable.contains($0.article.id) }
        let withoutText = ranked.filter { !readable.contains($0.article.id) }
        return Array((withText + withoutText).prefix(maxSources))
    }

    /// Fallback ordering when there is nothing to rank against — an empty
    /// query, or a search that matched none of the attached sources.
    private func attachmentOrderedCandidates(limit: Int) -> [RetrievalCandidate] {
        activeArticles.prefix(limit).map { RetrievalCandidate(article: $0, bestChunkID: nil) }
    }

    /// Which of these sources have text available to load.
    ///
    /// Decided from stored content lengths and recorded file paths, never by
    /// opening anything — this runs on every retrieval, and extraction here is
    /// exactly the blocking work the ranking rewrite exists to remove.
    func readableSourceIDs(among articles: [StudioArticle]) async -> Set<String> {
        let lengths = await storage.sourceContentLengths(for: articles.map(\.id))
        return Set(
            articles
                .filter { Self.hasLoadableText($0, storedLength: lengths[$0.id]) }
                .map(\.id)
        )
    }

    nonisolated static func hasLoadableText(_ article: StudioArticle, storedLength: Int?) -> Bool {
        (storedLength ?? 0) > 0
            || article.localFilePath?.isEmpty == false
            || article.content?.isEmpty == false
    }

    func sourceContent(for article: StudioArticle) async -> String {
        await Self.chatReadableText(for: article, storage: storage)
    }

    /// A source's text as a chat reads it. A side chat opened over words in
    /// the Reader reads the same text, so it answers from what a chat on the
    /// source would have been given.
    static func chatReadableText(for article: StudioArticle, storage: StorageService) async -> String {
        let persistedContent = await storage.loadSourceContent(article.id)
        if let trimmedPersisted = persistedContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedPersisted.isEmpty {
            // A video's slide block names each frame's file. The model reads
            // this text to pick a slide, not to draw one, so the file paths
            // give way to the tool call that shows the slide (see
            // `SlideFrameExtraction.assistantFacingContent`). A PDF's page
            // boundaries become `[page N]` lines, so a citation can name the
            // page a passage sits on.
            return PDFPageMarkers.labeled(SlideFrameExtraction.assistantFacingContent(trimmedPersisted))
        }
        // A paper without canonical content is not ready for chat. Never reopen
        // its PDF or use an in-memory raw extraction as a silent fallback.
        if article.sourceType == .paper { return "" }
        // Reading a local file can mean OCR over every page of a long PDF,
        // with no point at which it looks for a cancel. A stopped caller stops
        // waiting for it and gets no text; the read finishes on its own.
        if let localContent = try? await CancellableWait.run({ await Self.localSourceContent(for: article) }) {
            return PDFPageMarkers.labeled(localContent)
        }
        return (article.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Derive a source's text from its local file. Runs off the main actor
    /// (nonisolated) because it resolves paths (synchronous filesystem I/O), opens
    /// PDFs, reads files, and runs per-page Vision OCR — none of which may block the
    /// main actor.
    private nonisolated static func localSourceContent(for article: StudioArticle) async -> String? {
        guard let path = article.resolvedLocalPath else { return nil }
        let resolvedURL = URL(fileURLWithPath: path)
        let ext = resolvedURL.pathExtension.lowercased()

        do {
            let text: String?
            switch ext {
            case "pdf":
                guard let pdfDocument = PDFDocument(url: resolvedURL) else {
                    throw SourceError.pdfReadFailed
                }
                // A book chapter's pages of its book's file.
                let pages = article.bookPages ?? 0..<pdfDocument.pageCount
                guard pages.upperBound <= pdfDocument.pageCount else { throw SourceError.pdfReadFailed }
                text = PDFTextExtractor.textWithFigureReferences(from: pdfDocument, pages: pages)
            case "ttml":
                text = try SourceService.extractTextFromTTMLContent(String(contentsOf: resolvedURL, encoding: .utf8))
            case "html", "htm", "xhtml":
                // A file, or a chapter of an EPUB book kept as one file.
                guard let raw = EPUBBookFiles.text(atPath: resolvedURL.path) else { throw SourceError.fileNotFound }
                text = EPUBParser.stripHTML(raw)
            default:
                text = try String(contentsOf: resolvedURL, encoding: .utf8)
            }

            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return nil }
            return trimmed
        } catch {
            return nil
        }
    }

    /// Cut a source down to the part that answers the query.
    ///
    /// When the semantic branch named the matching chunk, the excerpt is built
    /// around it: chunk ids are positional over a deterministic splitter, so
    /// the passage that actually matched is recoverable exactly. That matters
    /// most for the conceptual questions the keyword fallback handles worst —
    /// "what mechanism links these two?" shares few literal terms with the
    /// paragraph that answers it, and term-frequency scoring will reliably pick
    /// the wrong window.
    nonisolated static func focusedExcerpt(
        from content: String,
        query: String,
        limit: Int,
        bestChunkID: String? = nil
    ) -> String {
        guard content.count > limit else { return content }

        // An exact lexical hit is stronger evidence than a vector-near chunk,
        // especially for identifiers, acronyms, drug names, and quoted phrases.
        // It also keeps focused retrieval correct while the durable search index
        // is missing, stale, or still catching up. The Reader searches the
        // canonical transcript bytes directly; Chat must preserve that same
        // minimum recall contract instead of silently returning the prefix.
        let exactExcerpt = exactQueryExcerpt(from: content, query: query, limit: limit)
        if let exactExcerpt, exactExcerpt.isStrongAnchor {
            return exactExcerpt.text
        }

        if let bestChunkID,
           let excerpt = excerptAroundChunk(bestChunkID, in: content, limit: limit) {
            return excerpt
        }

        if let exactExcerpt {
            return exactExcerpt.text
        }

        let note = "\n\n[No exact or semantic passage match was available, so this result contains only the beginning of the source. It does not establish that the query is absent from the omitted text. Try another focused query, or use mode \"full\" for a complete start-to-finish read.]"
        let budget = max(0, limit - note.count)
        return String(content.prefix(budget)) + note
    }

    private struct LexicalNeedle {
        let value: String
        let queryOrder: Int
        let isIdentifierLike: Bool
    }

    private struct LexicalMatch {
        let startOffset: Int
        let endOffset: Int
    }

    private struct ExactQueryExcerpt {
        let text: String
        /// Identifier-like units and short explicit queries are stronger than
        /// vector proximity. Ordinary multi-word conceptual queries still let
        /// the semantic chunk lead when one is available.
        let isStrongAnchor: Bool
    }

    /// Select a bounded passage around a literal term from the retrieval query.
    ///
    /// Dashes are ignored inside a lexical unit, so common orthographic variants
    /// such as `ABC-123` and `ABC123` share one deterministic form. Other
    /// punctuation remains a boundary; a slash-separated list is therefore a
    /// list of alternatives, not one impossible concatenated phrase.
    private nonisolated static func exactQueryExcerpt(
        from content: String,
        query: String,
        limit: Int
    ) -> ExactQueryExcerpt? {
        let needles = lexicalNeedles(in: query)
        guard !needles.isEmpty else { return nil }

        let needleValues = Set(needles.map(\.value))
        var matchesByNeedle: [String: [LexicalMatch]] = [:]
        scanLexicalUnits(in: content) { value, _, start, end in
            guard needleValues.contains(value) else { return }
            matchesByNeedle[value, default: []].append(LexicalMatch(
                startOffset: start,
                endOffset: end
            ))
        }

        let matchedNeedles = needles.filter { matchesByNeedle[$0.value]?.isEmpty == false }
        guard !matchedNeedles.isEmpty else { return nil }

        // Mixed letter/number identifiers and multi-capital acronyms are exact
        // anchors rather than prose vocabulary. Otherwise prefer the least
        // frequent matching unit, then the longer and later query unit. This
        // avoids centring "what does Picard say about SS31" on a common question
        // word while remaining language-agnostic and deterministic.
        let selected = matchedNeedles.max { lhs, rhs in
            let lhsCount = matchesByNeedle[lhs.value]?.count ?? .max
            let rhsCount = matchesByNeedle[rhs.value]?.count ?? .max
            if lhs.isIdentifierLike != rhs.isIdentifierLike {
                return !lhs.isIdentifierLike && rhs.isIdentifierLike
            }
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return lhs.queryOrder < rhs.queryOrder
        }
        guard let selected, let matches = matchesByNeedle[selected.value],
              let first = matches.first, let last = matches.last else { return nil }

        let note = "\n\n[Focused passage selected around an exact query match; the rest of this source was not included.]"
        let bodyBudget = max(0, limit - note.count)
        guard bodyBudget > 0 else { return nil }

        // Keep a compact run of repeated mentions together when it fits (a
        // transcript discussion often names the same term several times), but
        // never let far-apart occurrences turn a focused lookup into a giant
        // slice spanning unrelated material.
        let matchedSpan = last.endOffset - first.startOffset
        let anchorStart: Int
        let anchorEnd: Int
        if matchedSpan <= bodyBudget * 2 / 3 {
            anchorStart = first.startOffset
            anchorEnd = last.endOffset
        } else {
            anchorStart = first.startOffset
            anchorEnd = first.endOffset
        }

        let leadingContext = max(0, (bodyBudget - (anchorEnd - anchorStart)) / 3)
        var startOffset = max(0, anchorStart - leadingContext)
        let contentCount = content.count
        let endOffset = min(contentCount, startOffset + bodyBudget)
        if endOffset - startOffset < bodyBudget {
            startOffset = max(0, endOffset - bodyBudget)
        }

        let start = content.index(content.startIndex, offsetBy: startOffset)
        let end = content.index(content.startIndex, offsetBy: endOffset)
        return ExactQueryExcerpt(
            text: String(content[start..<end]) + note,
            isStrongAnchor: selected.isIdentifierLike || needles.count <= 2
        )
    }

    /// Canonical query units plus the small amount of signal needed to
    /// distinguish an identifier from ordinary prose. This is lexical search,
    /// not identity or meaning inference: record identity never depends on it.
    private nonisolated static func lexicalNeedles(in query: String) -> [LexicalNeedle] {
        var result: [LexicalNeedle] = []
        var seen = Set<String>()
        var order = 0
        scanLexicalUnits(in: query) { value, original, _, _ in
            defer { order += 1 }
            guard value.count >= 2, seen.insert(value).inserted else { return }

            let uppercaseCount = original.filter(\.isUppercase).count
            let hasLetter = value.contains(where: \.isLetter)
            let hasNumber = value.contains(where: \.isNumber)
            result.append(LexicalNeedle(
                value: value,
                queryOrder: order,
                isIdentifierLike: (hasLetter && hasNumber) || uppercaseCount >= 2
            ))
        }
        return result
    }

    /// Enumerate canonical lexical units without copying or lowercasing the
    /// complete source. Offsets use Swift Character units, matching every
    /// context budget and cursor in this manager.
    private nonisolated static func scanLexicalUnits(
        in text: String,
        visit: (_ value: String, _ original: String, _ startOffset: Int, _ endOffset: Int) -> Void
    ) {
        var unit = ""
        var unitStart = 0
        var offset = 0

        func finishUnit(at endOffset: Int) {
            guard !unit.isEmpty else { return }
            visit(canonicalLexicalValue(unit), unit, unitStart, endOffset)
            unit.removeAll(keepingCapacity: true)
        }

        for character in text {
            if character.isLetter || character.isNumber {
                if unit.isEmpty { unitStart = offset }
                unit.append(character)
            } else if isDash(character), !unit.isEmpty {
                // Join both sides: `SS-31` and `SS31` are the same lexical unit.
            } else {
                finishUnit(at: offset)
            }
            offset += 1
        }
        finishUnit(at: offset)
    }

    private nonisolated static func canonicalLexicalValue(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private nonisolated static func isDash(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty && character.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .dashPunctuation
        }
    }

    /// Build an excerpt centred on a semantically matched chunk, expanding
    /// outward into its neighbours until the budget is spent.
    ///
    /// The surrounding chunks matter: a matched passage delivered as a bare
    /// window frequently starts mid-argument, and the model has no way to tell
    /// that from a complete thought.
    ///
    /// Returns nil when the chunk cannot be located — the indexer resolves a
    /// source's text through its own path, so a source whose text has changed
    /// since indexing can yield an index past the end. That is a miss, not an
    /// error: the caller falls back to keyword excerpting.
    private nonisolated static func excerptAroundChunk(_ chunkID: String, in content: String, limit: Int) -> String? {
        guard let index = Self.chunkIndex(fromChunkID: chunkID) else { return nil }
        let chunks = SourceEmbeddingText.textChunks(from: content)
        guard chunks.indices.contains(index) else { return nil }

        let note = "\n\n[Excerpt centred on the passage matching the query; the rest of this source was not included.]"
        let budget = max(0, limit - note.count)
        guard budget > 0 else { return nil }

        let separatorCost = 2
        var lower = index
        var upper = index
        var length = chunks[index].count

        var expanded = true
        while expanded {
            expanded = false
            if lower > 0, length + chunks[lower - 1].count + separatorCost <= budget {
                lower -= 1
                length += chunks[lower].count + separatorCost
                expanded = true
            }
            if upper < chunks.count - 1, length + chunks[upper + 1].count + separatorCost <= budget {
                upper += 1
                length += chunks[upper].count + separatorCost
                expanded = true
            }
        }

        let excerpt = String(chunks[lower...upper].joined(separator: "\n\n").prefix(budget))
        let isPartial = lower > 0 || upper < chunks.count - 1
        return isPartial ? excerpt + note : excerpt
    }

    /// Recover the positional index from a `<sourceID>::chunk::NNNN` id.
    private nonisolated static func chunkIndex(fromChunkID chunkID: String) -> Int? {
        guard let range = chunkID.range(of: "::chunk::", options: .backwards) else { return nil }
        return Int(chunkID[range.upperBound...])
    }
}
