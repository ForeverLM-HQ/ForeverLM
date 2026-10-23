import Foundation
import NaturalLanguage
import os

/// Best-effort AI metadata helpers (duplicate detection, classification, title
/// fixing) return nil/empty on provider failure by design — they must never block
/// or mask the primary workflow. This logger makes those systemic failures (e.g. a
/// revoked API key or provider outage) observable instead of silently disappearing.
private let logger = Logger(subsystem: "com.foreverlm", category: "AIKnowledge")

/// On-device text embedding via Apple's `NLContextualEmbedding` — a transformer with
/// a subword tokenizer. No API key and no network. Fails loudly (no fallback) so
/// embedding gaps surface instead of silently degrading semantic search.
///
/// Replaces `NLEmbedding.sentenceEmbedding`, which had a fixed word vocabulary and so
/// could not represent domain terms at all: "GDF15" was out-of-vocabulary and scored
/// closer to nonsense strings than to "growth differentiation factor 15". The subword
/// tokenizer here gives such terms a real representation.
///
/// The model produces one vector per token, so a passage vector is the mean of its
/// token vectors, L2-normalized (making cosine similarity a plain dot product).
///
/// `.english` is not an English-only restriction and must not be "fixed" into a
/// per-source detected language. Apple groups these models by script, and the one
/// `.english` selects (5C45D94E…) is a single multilingual model covering 20
/// Latin-script languages — cs, da, de, en, es, fi, fr, hr, hu, id, it, nb, nl,
/// pl, pt, ro, sk, sv, tr, vi. Measured 2026-08-19: embedding the same Dutch
/// sentence with `language: .english` and with `.dutch` returns bit-identical
/// vectors, so the argument is inert across this group, and Dutch text lands 0.89
/// cosine from its English translation against 0.71 for unrelated English — the
/// index is already cross-lingual, and an English query finds a Dutch source.
///
/// Passing a detected language would therefore change nothing for those 20, and
/// would actively break the index for the rest: Cyrillic and CJK resolve to
/// *different* models whose vectors share no space with these. One index requires
/// one model. Supporting non-Latin scripts means per-model vector partitions and
/// scoped comparison, not a different argument here.
enum AppleTextEmbedder {
    private static let lock = NSLock()
    private static var cachedModel: NLContextualEmbedding?

    /// Load once and reuse. `load()` maps the model into memory; doing it per call
    /// would dominate the ~42ms embed cost.
    private static func model() async throws -> NLContextualEmbedding {
        if let cached = lock.withLock({ cachedModel }) {
            return cached
        }

        guard let embedding = NLContextualEmbedding(language: .english) else {
            throw AIError.apiError("Apple contextual embedding model is unavailable for English on this device.")
        }

        // Assets ship out-of-band and may need a one-time download.
        if !embedding.hasAvailableAssets {
            _ = try await embedding.requestAssets()
        }
        try embedding.load()

        lock.withLock { cachedModel = embedding }
        return embedding
    }

    static func embed(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AIError.apiError("Apple on-device embedding requires non-empty text.")
        }
        let embedding = try await model()

        // NLContextualEmbedding is not documented as thread-safe, and it is cheap to
        // serialize relative to the model run itself.
        return try lock.withLock {
            let result = try embedding.embeddingResult(for: trimmed, language: .english)
            let dimension = embedding.dimension
            var sum = [Double](repeating: 0, count: dimension)
            var tokenCount = 0
            result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
                for index in 0..<min(dimension, vector.count) {
                    sum[index] += vector[index]
                }
                tokenCount += 1
                return true
            }
            guard tokenCount > 0 else {
                throw AIError.apiError("Apple on-device embedding produced no tokens for the given text.")
            }

            var norm: Double = 0
            for index in 0..<dimension {
                sum[index] /= Double(tokenCount)
                norm += sum[index] * sum[index]
            }
            norm = norm.squareRoot()
            guard norm > 0 else {
                throw AIError.apiError("Apple on-device embedding produced a zero vector for the given text.")
            }
            return sum.map { Float($0 / norm) }
        }
    }
}

extension AIService {

    // MARK: - Podcast YouTube Matching

    private struct PodcastYouTubeSearchQueryResponse: Decodable {
        let queries: [String]
    }

    private struct PodcastYouTubeRankingResponse: Decodable {
        let rankedVideoIDs: [String]

        enum CodingKeys: String, CodingKey {
            case rankedVideoIDs = "ranked_video_ids"
        }
    }

    /// Read episode metadata semantically instead of trying to peel human-written
    /// title prefixes and suffixes apart with an expanding set of string rules.
    func podcastYouTubeSearchQueries(
        episodeTitle: String,
        showName: String,
        author: String?,
        config: AITaskConfig
    ) async throws -> [String] {
        let response = try await call(
            config: config,
            system: AITask.podcastYouTubeMatching.effectivePrompt ?? Prompts.podcastYouTubeMatching,
            user: """
            Action: search_queries

            Apple episode title: \(episodeTitle)
            Podcast show: \(showName)
            Author or creator: \(author ?? "Unknown")
            """,
            maxTokens: 256,
            temperature: 0.0,
            allowsReasoningInflation: false,
            jsonMode: true,
            sourceTitle: episodeTitle
        )
        return try Self.decodePodcastYouTubeSearchQueries(response)
    }

    /// Rank discovery candidates, but leave source identity to the learner's
    /// explicit confirmation in the Reader. `foundBy` says, per video id, where
    /// the candidate was found (`PodcastYouTubeCandidateOrigin`).
    func rankPodcastYouTubeCandidates(
        episodeTitle: String,
        showName: String,
        author: String?,
        candidates: [YouTubeVideoSearchResult],
        foundBy: [String: String] = [:],
        config: AITaskConfig
    ) async throws -> [String] {
        guard !candidates.isEmpty else { return [] }
        let dateFormatter = ISO8601DateFormatter()
        let candidateLines = candidates.map { candidate in
            let description = candidate.description?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(1_000) ?? ""
            let origin = foundBy[candidate.videoId].map { "\n  found_by: \($0)" } ?? ""
            return """
            - video_id: \(candidate.videoId)
              title: \(candidate.title)
              channel: \(candidate.channelTitle ?? "Unknown")
              published_at: \(candidate.publishedAt.map(dateFormatter.string(from:)) ?? "Unknown")\(origin)
              description: \(description)
            """
        }.joined(separator: "\n")

        let response = try await call(
            config: config,
            system: AITask.podcastYouTubeMatching.effectivePrompt ?? Prompts.podcastYouTubeMatching,
            user: """
            Action: rank_candidates

            Apple episode title: \(episodeTitle)
            Podcast show: \(showName)
            Author or creator: \(author ?? "Unknown")

            YouTube candidates:
            \(candidateLines)
            """,
            maxTokens: 512,
            temperature: 0.0,
            allowsReasoningInflation: false,
            jsonMode: true,
            sourceTitle: episodeTitle
        )
        return try Self.decodePodcastYouTubeRanking(
            response,
            expectedVideoIDs: candidates.map(\.videoId)
        )
    }

    nonisolated static func decodePodcastYouTubeSearchQueries(_ response: String) throws -> [String] {
        let parsed: PodcastYouTubeSearchQueryResponse = try decodePodcastYouTubeJSON(response)
        var seen = Set<String>()
        let queries = parsed.queries.compactMap { raw -> String? in
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.count <= 200,
                  seen.insert(query.lowercased()).inserted else { return nil }
            return query
        }
        guard !queries.isEmpty, queries.count <= 3 else { throw AIError.invalidResponse }
        return queries
    }

    nonisolated static func decodePodcastYouTubeRanking(
        _ response: String,
        expectedVideoIDs: [String]
    ) throws -> [String] {
        let parsed: PodcastYouTubeRankingResponse = try decodePodcastYouTubeJSON(response)
        guard parsed.rankedVideoIDs.count == expectedVideoIDs.count,
              Set(parsed.rankedVideoIDs) == Set(expectedVideoIDs) else {
            throw AIError.invalidResponse
        }
        return parsed.rankedVideoIDs
    }

    private nonisolated static func decodePodcastYouTubeJSON<T: Decodable>(
        _ response: String
    ) throws -> T {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw AIError.invalidResponse
        }
        return decoded
    }

    // MARK: - Lecture-Note Matching

    /// Use an LLM to match YouTube lecture titles to PDF note filenames.
    /// Returns an array of (lectureTitle, noteFilename) pairs.
    func matchLecturesToNotes(
        lectureTitles: [String],
        noteFilenames: [String],
        config: AITaskConfig
    ) async throws -> [(lecture: String, note: String)] {
        let systemPrompt = AITask.lectureNoteMatching.effectivePrompt ?? Prompts.lectureNoteMatching

        let userPrompt = """
        Match these lecture titles to note filenames:

        LECTURES:
        \(lectureTitles.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))

        NOTES:
        \(noteFilenames.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))
        """

        let response = try await call(
            config: config,
            system: systemPrompt,
            user: userPrompt,
            maxTokens: 2000,
            temperature: 0.0,
            jsonMode: true
        )

        // Parse JSON array from response (handle markdown code fences)
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonString.hasPrefix("```") {
            // Strip ```json ... ```
            let lines = jsonString.components(separatedBy: "\n")
            let stripped = lines.dropFirst().dropLast().joined(separator: "\n")
            jsonString = stripped
        }

        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            logger.warning("matchLecturesToNotes: could not parse JSON pairs from AI response; skipping lecture-note matching")
            return []
        }

        return parsed.compactMap { dict in
            guard let lecture = dict["lecture"], let note = dict["note"] else { return nil }
            return (lecture: lecture, note: note)
        }
    }

    struct BookChapterBoundary: Codable, Sendable, Equatable {
        let id: Int
        let title: String
        let pageIndex: Int
        /// First PDF page outside this chapter. The final chapter uses this to
        /// stop before back matter instead of swallowing the rest of the book.
        let endPageIndexExclusive: Int
    }

    struct BookChapterBoundaryResponse: Codable {
        let chapters: [BookChapterBoundary]
    }

    /// Ask the configured LLM to choose the actual chapter starts from PDF outline and page-start entries.
    /// The returned IDs/page indices are validated against the supplied candidates before use.
    func selectBookChapterBoundaries(
        source: AIUsageSource,
        bookTitle: String,
        pageCount: Int,
        outlineEntries: [(title: String, pageIndex: Int, depth: Int)],
        tocEntries: [(title: String, printedPage: Int?, text: String)] = [],
        chapterHeadingEntries: [(title: String, pageIndex: Int)] = [],
        pageEntries: [(pageIndex: Int, text: String)] = [],
        frontMatterPages: [(pageIndex: Int, text: String)] = [],
        config: AITaskConfig
    ) async throws -> [BookChapterBoundary] {
        let systemPrompt = AITask.bookChapterSplitting.effectivePrompt ?? Prompts.bookChapterSplitting
        var candidateLookup: [Int: BookChapterCandidate] = [:]
        var nextID = 1
        let outlineCandidates = outlineEntries.map { entry in
            let id = nextID
            nextID += 1
            candidateLookup[id] = BookChapterCandidate(title: entry.title, fixedPageIndex: entry.pageIndex)
            return [
                "id": id,
                "source": "outline",
                "title": entry.title,
                "pageIndex": entry.pageIndex,
                "depth": entry.depth,
            ] as [String: Any]
        }
        let tocCandidates = tocEntries.map { entry in
            let id = nextID
            nextID += 1
            candidateLookup[id] = BookChapterCandidate(title: entry.title, fixedPageIndex: nil)
            var candidate = [
                "id": id,
                "source": "tableOfContents",
                "title": entry.title,
                "text": entry.text,
            ] as [String: Any]
            if let printedPage = entry.printedPage {
                candidate["printedPage"] = printedPage
            }
            return candidate
        }
        let chapterHeadingCandidates = chapterHeadingEntries.map { entry in
            let id = nextID
            nextID += 1
            candidateLookup[id] = BookChapterCandidate(title: entry.title, fixedPageIndex: entry.pageIndex)
            return [
                "id": id,
                "source": "chapterHeading",
                "title": entry.title,
                "pageIndex": entry.pageIndex,
            ] as [String: Any]
        }
        let pageCandidates = pageEntries.map { entry in
            let id = nextID
            nextID += 1
            let title = "PDF page \(entry.pageIndex + 1)"
            candidateLookup[id] = BookChapterCandidate(title: title, fixedPageIndex: entry.pageIndex)
            return [
                "id": id,
                "source": "pageStart",
                "title": title,
                "pageIndex": entry.pageIndex,
                "text": entry.text,
            ] as [String: Any]
        }
        let frontMatter = frontMatterPages.map { entry in
            [
                "pageIndex": entry.pageIndex,
                "text": entry.text,
            ] as [String: Any]
        }
        guard !outlineCandidates.isEmpty || !tocCandidates.isEmpty || !chapterHeadingCandidates.isEmpty || !pageCandidates.isEmpty else { return [] }

        let candidatePayload = [
            "outlineEntries": outlineCandidates,
            "tableOfContentsEntries": tocCandidates,
            "chapterHeadingSightings": chapterHeadingCandidates,
            "pageStarts": pageCandidates,
            "frontMatterPages": frontMatter,
        ]
        let candidateData = try JSONSerialization.data(withJSONObject: candidatePayload, options: [.prettyPrinted, .sortedKeys])
        let candidateJSON = String(data: candidateData, encoding: .utf8) ?? "{}"

        let userPrompt = """
        Book title: \(bookTitle)
        PDF page count: \(pageCount)

        Candidate entries:
        \(candidateJSON)

        Return chapter starts using only candidate ids from the input.
        - Prefer tableOfContentsEntries to understand the intended chapter list.
        - TOC printed page numbers may not match zero-based PDF pageIndex values. Infer any offset from outline entries, chapterHeadingSightings, pageStarts, and frontMatterPages.
        - For tableOfContentsEntries, return the TOC candidate id with the adjusted zero-based PDF pageIndex where that chapter actually begins.
        - For outline, chapterHeading, and pageStart candidates, preserve that candidate's pageIndex.
        - If a chapter heading appears mid-page, the chapter begins on that PDF pageIndex.
        - Return `endPageIndexExclusive` for every chapter. It is normally the next chapter start. For the final chapter, use pageStarts to stop before glossary, resources, notes, references, bibliography, acknowledgements, author biography, or index back matter; use the PDF page count only when no back matter follows.
        - Do not return table-of-contents pages as chapter starts unless the chapter's real content starts there.
        """

        // A reply this check refuses is not an answer: kept out of the
        // response cache and handed to the next backup model. Checked only
        // after the call, a refused reply was cached, so every retry of the
        // import got the same broken chapter list back.
        let candidates = candidateLookup
        let response = try await call(
            config: config,
            system: systemPrompt,
            user: userPrompt,
            maxTokens: 4000,
            temperature: 0.0,
            jsonMode: true,
            validateResponse: { reply in
                _ = try Self.validatedBookChapterBoundaries(reply, candidates: candidates, pageCount: pageCount)
            },
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.validatedBookChapterBoundaries(response, candidates: candidates, pageCount: pageCount)
    }

    /// A candidate the chapter splitter may return: an outline, chapter-heading
    /// or page-start entry fixes its page; a table-of-contents entry's page is
    /// the model's to place.
    struct BookChapterCandidate: Sendable {
        let title: String
        let fixedPageIndex: Int?
    }

    /// The chapter list in a splitter reply, or an error when it names an
    /// unknown candidate, moves a fixed page, runs out of order, or leaves a
    /// gap or overlap.
    static func validatedBookChapterBoundaries(
        _ response: String,
        candidates candidateLookup: [Int: BookChapterCandidate],
        pageCount: Int
    ) throws -> [BookChapterBoundary] {
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            jsonString = lines.dropFirst().dropLast().joined(separator: "\n")
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw AIError.invalidResponse
        }

        let parsed: BookChapterBoundaryResponse
        do {
            parsed = try JSONDecoder().decode(BookChapterBoundaryResponse.self, from: data)
        } catch {
            throw AIError.apiError("Book chapter splitter returned invalid JSON.")
        }

        var lastPageIndex = -1
        var lastEndPageIndex = -1
        var validated: [BookChapterBoundary] = []
        for chapter in parsed.chapters {
            guard let candidate = candidateLookup[chapter.id] else {
                throw AIError.apiError("Book chapter splitter returned an unknown candidate id: \(chapter.id).")
            }
            let pageMatchesCandidate = candidate.fixedPageIndex.map { chapter.pageIndex == $0 } ?? true
            guard pageMatchesCandidate,
                  chapter.pageIndex >= 0,
                  chapter.pageIndex < pageCount,
                  chapter.pageIndex > lastPageIndex,
                  chapter.endPageIndexExclusive > chapter.pageIndex,
                  chapter.endPageIndexExclusive <= pageCount,
                  chapter.pageIndex >= lastEndPageIndex else {
                throw AIError.apiError("Book chapter splitter returned invalid page order.")
            }
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            validated.append(BookChapterBoundary(
                id: chapter.id,
                title: title.isEmpty ? candidate.title : title,
                pageIndex: chapter.pageIndex,
                endPageIndexExclusive: chapter.endPageIndexExclusive
            ))
            lastPageIndex = chapter.pageIndex
            lastEndPageIndex = chapter.endPageIndexExclusive
        }

        for index in validated.indices.dropLast() {
            guard validated[index].endPageIndexExclusive == validated[index + 1].pageIndex else {
                throw AIError.apiError("Book chapter splitter returned a gap or overlap between chapters.")
            }
        }

        return validated
    }

    struct EPUBChapterSelection: Sendable, Equatable {
        let chapters: [EPUBParser.ChapterSpan]
        /// The model's names for the parts the file no longer holds, in reading order.
        let missingChapters: [String]
    }

    private struct EPUBChapterSelectionResponse: Codable {
        struct Chapter: Codable {
            let title: String
            let firstDocument: Int
            let lastDocument: Int
        }
        let chapters: [Chapter]
        let missingChapters: [String]?
    }

    /// Ask the configured LLM which of an EPUB's documents make up each
    /// chapter, what each is called, and which chapters the file has lost.
    /// The code only unpacks and lists the book; reading its shape is the
    /// model's job. The answer is checked against the inventory before use.
    func selectEPUBChapters(
        source: AIUsageSource,
        bookTitle: String,
        inventory: EPUBParser.Inventory,
        config: AITaskConfig
    ) async throws -> EPUBChapterSelection {
        let documents = inventory.documents.map { document in
            [
                "index": document.index,
                "file": document.file,
                "inSpine": document.inSpine,
                "headings": document.headings,
                "opening": document.opening,
                "words": document.wordCount,
            ] as [String: Any]
        }
        let tableOfContents = inventory.tableOfContents.map { item in
            var entry = ["title": item.title, "file": item.file] as [String: Any]
            if let documentIndex = item.documentIndex { entry["document"] = documentIndex }
            return entry
        }
        let payload = [
            "documents": documents,
            "tableOfContents": tableOfContents,
            "missingFiles": inventory.missingFiles,
        ] as [String: Any]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"

        let userPrompt = """
        Book title: \(bookTitle)
        Archive entries that could not be read: \(inventory.unreadableEntryCount)

        Inventory:
        \(payloadJSON)
        """

        let response = try await call(
            config: config,
            system: Prompts.epubChapterSelection,
            user: userPrompt,
            maxTokens: 6000,
            temperature: 0.0,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )

        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonString.hasPrefix("```") {
            let lines = jsonString.components(separatedBy: "\n")
            jsonString = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(EPUBChapterSelectionResponse.self, from: data) else {
            throw AIError.apiError("Book chapter splitter returned invalid JSON for the EPUB.")
        }

        var lastDocument = -1
        var chapters: [EPUBParser.ChapterSpan] = []
        for chapter in parsed.chapters {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  chapter.firstDocument > lastDocument,
                  chapter.firstDocument <= chapter.lastDocument,
                  chapter.lastDocument < inventory.documents.count else {
                throw AIError.apiError("Book chapter splitter returned EPUB chapters out of order or outside the book.")
            }
            chapters.append(EPUBParser.ChapterSpan(
                title: title,
                firstDocument: chapter.firstDocument,
                lastDocument: chapter.lastDocument
            ))
            lastDocument = chapter.lastDocument
        }
        let missing = (parsed.missingChapters ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return EPUBChapterSelection(chapters: chapters, missingChapters: missing)
    }

    // MARK: - Text Embedding

    /// Embed text for semantic source search using Apple's on-device contextual model.
    /// No API key and no network. Fails loudly (no fallback) so embedding gaps surface
    /// instead of silently degrading search. `async` so cross-actor callers await it;
    /// the CPU-bound embedding runs on this actor's executor, off the main actor.
    func embedText(_ text: String) async throws -> [Float] {
        return try await AppleTextEmbedder.embed(text)
    }

    // MARK: - Course Organization

    /// Extract the papers explicitly named in one bounded chunk of course material.
    /// The model reads meaning (which names form one citation); the lecture-ingest
    /// caller separately verifies any returned URL or DOI against the literal text
    /// before either can become paper identity.
    func discoverLecturePaperCitations(
        materialTitle: String,
        lectureContext: String,
        content: String,
        config: AITaskConfig
    ) async throws -> [SlideCitationService.ExtractedCitation] {
        let system = AITask.lecturePaperDiscovery.effectivePrompt
            ?? Prompts.lecturePaperDiscovery
        let user = """
        \(lectureContext)

        Material: \(materialTitle)

        MATERIAL CONTENT:
        \(content)
        """
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 3_000,
            temperature: 0
        )
        return try SlideCitationService.decodeReply(response).citations
    }

    /// Extract explicitly mentioned papers from one bounded chunk of a meeting
    /// transcript or its notes. Paper identity remains deterministic downstream:
    /// model-returned URLs and DOIs are accepted only when literally present.
    func discoverMeetingPaperCitations(
        meetingTitle: String,
        content: String,
        config: AITaskConfig
    ) async throws -> [SlideCitationService.ExtractedCitation] {
        let system = AITask.meetingPaperDiscovery.effectivePrompt
            ?? Prompts.meetingPaperDiscovery
        let user = """
        Meeting: \(meetingTitle)

        MEETING TRANSCRIPT AND NOTES:
        \(content)
        """
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 3_000,
            temperature: 0
        )
        return try SlideCitationService.decodeReply(response).citations
    }

    /// Read one bounded chunk of a paper's reference list for the papers it cites.
    /// Identity stays deterministic downstream: a DOI or URL the model returns is
    /// accepted only when it is literally present in the reference text.
    func extractPaperReferences(
        paperTitle: String,
        content: String,
        config: AITaskConfig
    ) async throws -> [SlideCitationService.ExtractedCitation] {
        let system = AITask.paperReferenceExtraction.effectivePrompt
            ?? Prompts.paperReferenceExtraction
        let user = """
        Citing paper: \(paperTitle)

        REFERENCE LIST TEXT:
        \(content)
        """
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 8_000,
            temperature: 0
        )
        return try SlideCitationService.decodeReply(response).citations
    }

    /// Read one bounded chunk of an article, its links numbered into the text, for the
    /// links the article uses as sources. Identity stays deterministic downstream: the
    /// model names markers, and the caller maps each marker back to the URL it stands for.
    func discoverArticleLinkedSources(
        articleTitle: String,
        markedText: String,
        linkIndex: String,
        config: AITaskConfig
    ) async throws -> [ArticleLinkDiscoveryService.Pick] {
        let system = AITask.articleLinkDiscovery.effectivePrompt
            ?? Prompts.articleLinkDiscovery
        let user = """
        Article: \(articleTitle)

        ARTICLE TEXT WITH LINK MARKERS:
        \(markedText)

        LINKS:
        \(linkIndex)
        """
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 8_000,
            temperature: 0
        )
        return try ArticleLinkDiscoveryService.decodeReply(response)
    }

    /// Ask an LLM to suggest a logical learning order for course items.
    /// Returns an ordered list of article IDs.
    func organizeCourse(items: [(id: String, title: String)], courseName: String, config: AITaskConfig) async throws -> [String] {
        let numbered = items.enumerated().map { "\($0.offset + 1). [\($0.element.id)] \($0.element.title)" }.joined(separator: "\n")

        let system = AITask.courseOrdering.effectivePrompt ?? Prompts.courseOrdering

        let userMessage = """
        Course: \(courseName)

        Items:
        \(numbered)

        Return a JSON array of the IDs (the bracketed strings) in optimal learning order.
        """

        let response = try await call(config: config, system: system, user: userMessage, maxTokens: 2000)

        // Extract JSON array from response
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]") else {
            throw AIError.invalidResponse
        }
        let jsonStr = String(response[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let ids = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw AIError.invalidResponse
        }
        return ids
    }

    /// Ask an LLM to clean playlist video titles for course lecture display.
    /// Returns a map from item ID to cleaned title. An empty string means the
    /// lecture should display as just its concise number prefix, e.g. "2)".
    func cleanCourseLectureTitles(
        courseName: String,
        titles: [(id: String, position: Int, title: String)],
        config: AITaskConfig
    ) async throws -> [String: String] {
        guard !titles.isEmpty else { return [:] }

        let rows = titles.map { item in
            """
            {"id":"\(Self.jsonEscaped(item.id))","position":\(item.position),"title":"\(Self.jsonEscaped(item.title))"}
            """
        }.joined(separator: ",\n")

        let userMessage = """
        Course: \(courseName)

        Items:
        [
        \(rows)
        ]
        """

        let response = try await call(
            config: config,
            system: Prompts.courseLectureTitleCleanup,
            user: userMessage,
            maxTokens: min(4000, max(500, titles.count * 40)),
            temperature: 0.0
        )

        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else {
            throw AIError.invalidResponse
        }
        let jsonString = String(response[start...end])
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }

        var result: [String: String] = [:]
        for (id, value) in object {
            if value is NSNull {
                result[id] = ""
            } else if let title = value as? String {
                result[id] = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    /// One action item as the model read it; the app assigns the id.
    struct MeetingActionItemDraft: Sendable, Equatable {
        let text: String
        let owner: String?
        let due: String?
    }

    /// The action items in one meeting session's transcript, in transcript
    /// order. Empty when the session asked nothing of anyone. Throws on a
    /// reply that is not the JSON the prompt asks for; nothing is guessed.
    func extractMeetingActionItems(
        seriesTitle: String,
        sessionTitle: String,
        transcript: String,
        config: AITaskConfig
    ) async throws -> [MeetingActionItemDraft] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let userMessage = """
        Series: \(seriesTitle)
        Session: \(sessionTitle)

        Transcript:
        \(String(trimmed.prefix(60_000)))
        """
        let response = try await call(
            config: config,
            system: Prompts.meetingActionItems,
            user: userMessage,
            maxTokens: 1500,
            temperature: 0.0,
            sourceTitle: sessionTitle
        )
        return try Self.parseMeetingActionItems(response)
    }

    /// Pure, so the shape the prompt promises can be pinned by a test.
    static func parseMeetingActionItems(_ response: String) throws -> [MeetingActionItemDraft] {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") else {
            throw AIError.invalidResponse
        }
        guard let data = String(response[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [Any] else {
            throw AIError.invalidResponse
        }
        return items.prefix(12).compactMap { raw -> MeetingActionItemDraft? in
            guard let entry = raw as? [String: Any] else { return nil }
            let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            let owner = (entry["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let due = (entry["due"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MeetingActionItemDraft(
                text: String(text.prefix(200)),
                owner: (owner?.isEmpty ?? true) ? nil : owner,
                due: (due?.isEmpty ?? true) ? nil : due
            )
        }
    }

    struct MeetingSessionDetails: Sendable {
        /// Meeting topic with series name, date and file-kind markers removed.
        /// Empty when the files carry no topic beyond the series and the date.
        let title: String
        /// Presenter(s) as written, or nil when nobody is named.
        let presenter: String?
    }

    /// Evaluate one natural-language automatic-audio rule against source
    /// metadata in bounded batches. Returned IDs are validated against the
    /// supplied candidates; malformed or invented identities fail the whole
    /// check instead of broadening the filter.
    func matchingAutomaticAudioSourceIDs(
        constraint: String,
        candidates: [SourceAudioAutomation.FilterCandidate],
        config: AITaskConfig
    ) async throws -> Set<String> {
        let rule = constraint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return Set(candidates.map(\.id)) }
        guard !candidates.isEmpty else { return [] }

        var matches = Set<String>()
        let batchSize = 180
        for start in stride(from: 0, to: candidates.count, by: batchSize) {
            let end = min(start + batchSize, candidates.count)
            let batch = Array(candidates[start..<end])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(batch)
            guard let json = String(data: data, encoding: .utf8) else {
                throw AIError.invalidResponse
            }
            let response = try await call(
                config: config,
                system: Prompts.automaticAudioFiltering,
                user: "Rule: \(rule)\n\nSources:\n\(json)",
                maxTokens: min(8_000, max(300, batch.count * 24)),
                temperature: 0,
                jsonMode: true
            )
            guard let first = response.firstIndex(of: "{"),
                  let last = response.lastIndex(of: "}"),
                  let responseData = String(response[first...last]).data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: responseData)
                    as? [String: Any],
                  let ids = object["matching_ids"] as? [String] else {
                throw AIError.invalidResponse
            }
            let allowed = Set(batch.map(\.id))
            guard ids.allSatisfy(allowed.contains) else { throw AIError.invalidResponse }
            matches.formUnion(ids)
        }
        return matches
    }

    /// Ask an LLM for the topic and presenter of each meeting session, given the
    /// names of the files that recorded it. One call covers every session in an
    /// import — meeting file names come in too many hand-rolled shapes for
    /// pattern matching to keep up with.
    func extractMeetingSessionDetails(
        seriesTitle: String,
        sessions: [(id: String, fileNames: [String], notesExcerpt: String?)],
        config: AITaskConfig
    ) async throws -> [String: MeetingSessionDetails] {
        guard !sessions.isEmpty else { return [:] }

        let rows = sessions.map { session -> String in
            let files = session.fileNames
                .map { "\"\(Self.jsonEscaped($0))\"" }
                .joined(separator: ",")
            let notes = session.notesExcerpt.map {
                ",\"notes\":\"\(Self.jsonEscaped(String($0.prefix(400))))\""
            } ?? ""
            return "{\"id\":\"\(Self.jsonEscaped(session.id))\",\"files\":[\(files)]\(notes)}"
        }.joined(separator: ",\n")

        let userMessage = """
        Series: \(seriesTitle)

        Sessions:
        [
        \(rows)
        ]
        """

        let response = try await call(
            config: config,
            system: Prompts.meetingSessionDetails,
            user: userMessage,
            maxTokens: min(8000, max(600, sessions.count * 80)),
            temperature: 0.0
        )

        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else {
            throw AIError.invalidResponse
        }
        let jsonString = String(response[start...end])
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }

        var result: [String: MeetingSessionDetails] = [:]
        for (id, value) in object {
            guard let entry = value as? [String: Any] else { continue }
            let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let presenter = (entry["presenter"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            result[id] = MeetingSessionDetails(
                title: title,
                presenter: (presenter?.isEmpty ?? true) ? nil : presenter
            )
        }
        return result
    }

    struct CoursePlaylistMetadata: Sendable {
        /// The course's subject title without institution, code, or term.
        let title: String?
        /// Catalog code as written, e.g. "CS229" or "6.S184".
        let courseCode: String?
        /// University or organization offering the course.
        let institution: String?
        /// Instructor name(s) as written.
        let instructors: String?
    }

    /// Ask an LLM for course metadata from an imported playlist's title,
    /// channel, and lecture titles. Everything it returns is optional — a
    /// personal playlist legitimately has no code, institution, or instructor.
    func extractCourseMetadata(
        playlistTitle: String,
        channelName: String?,
        lectureTitles: [String],
        config: AITaskConfig
    ) async throws -> CoursePlaylistMetadata {
        let titles = lectureTitles.prefix(12)
            .map { "- \(String($0.prefix(120)))" }
            .joined(separator: "\n")
        let userMessage = """
        Playlist: \(playlistTitle)
        Channel: \(channelName ?? "unknown")

        Lectures:
        \(titles)
        """

        let system = AITask.courseMetadata.effectivePrompt ?? Prompts.courseMetadata
        let response = try await call(
            config: config,
            system: system,
            user: userMessage,
            maxTokens: 300,
            temperature: 0.0
        )

        guard let details = Self.parseCourseMetadataExtraction(response) else {
            throw AIError.invalidResponse
        }
        return details
    }

    /// Parse the JSON object the course-metadata prompt returns. Blank,
    /// "null", and "unknown" strings count as absent.
    static func parseCourseMetadataExtraction(_ response: String) -> CoursePlaylistMetadata? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start < end,
              let data = String(response[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func field(_ key: String) -> String? {
            guard let raw = object[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            guard !trimmed.isEmpty, lowered != "null", lowered != "unknown", lowered != "n/a" else {
                return nil
            }
            return String(trimmed.prefix(120))
        }

        return CoursePlaylistMetadata(
            title: field("title"),
            courseCode: field("course_code"),
            institution: field("institution"),
            instructors: field("instructors")
        )
    }

    static func jsonEscaped(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else { return string }
        let arrayElement = String(json.dropFirst().dropLast())
        guard arrayElement.hasPrefix("\""), arrayElement.hasSuffix("\"") else {
            return arrayElement
        }
        return String(arrayElement.dropFirst().dropLast())
    }

    // MARK: - Paper Duplicate Detection

    /// Check if a new paper (by URL + title) is a duplicate of any existing paper.
    /// Uses Haiku for fast, cheap semantic matching.
    /// Returns the title of the matched existing paper, or nil if no duplicate found.
    func checkPaperDuplicate(
        newURL: String,
        newTitle: String,
        existingPapers: [(title: String, url: String)],
        config: AITaskConfig
    ) async -> String? {
        guard !existingPapers.isEmpty else { return nil }

        // Build a numbered list of existing papers
        let paperList = existingPapers.enumerated().map { (i, p) in
            "\(i + 1). \(p.title)"
        }.joined(separator: "\n")

        let system = AITask.duplicateDetection.effectivePrompt ?? Prompts.duplicateDetection

        let user = """
        New paper:
        Title: \(newTitle)
        URL: \(newURL)

        Existing papers:
        \(paperList)
        """

        do {
            let response = try await call(
                config: config,
                system: system,
                user: user,
                maxTokens: 256,
                temperature: 0.0,
                allowsReasoningInflation: false,
                sourceTitle: newTitle
            )
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "none" { return nil }
            // Parse the number
            if let num = Int(trimmed.filter(\.isNumber)), num >= 1, num <= existingPapers.count {
                return existingPapers[num - 1].title
            }
            return nil
        } catch {
            // Don't block adding a paper if the LLM check fails, but surface the
            // failure so a revoked key / provider outage doesn't silently disable
            // duplicate detection.
            logger.error("checkPaperDuplicate: duplicate detection skipped after AI call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Classify a source as article vs paper vs book using a lightweight LLM call.
    /// Returns nil on failure or an unrecognized response.
    func classifySourceType(
        source: AIUsageSource,
        url: String,
        title: String,
        contentPreview: String,
        config: AITaskConfig
    ) async -> StudioSourceType? {
        let system = AITask.sourceClassification.effectivePrompt ?? Prompts.sourceClassification

        let preview = String(contentPreview.prefix(500))
        let user = """
        URL: \(url)
        Title: \(title)
        Content preview: \(preview)
        """

        do {
            let response = try await call(
                config: config,
                system: system,
                user: user,
                maxTokens: 256,
                temperature: 0.0,
                allowsReasoningInflation: false,
                sourceTitle: source.title,
                subjectID: source.id,
                subjectType: source.type,
                activityID: AIUsageAttribution.activityID ?? UUID().uuidString
            )
            return Self.parseSourceTypeClassification(response)
        } catch {
            logger.error("classifySourceType: source classification skipped after AI call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func parseSourceTypeClassification(_ response: String) -> StudioSourceType? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "paper" { return .paper }
        if trimmed == "article" { return .article }
        if trimmed == "book" { return .book }
        return nil
    }

    /// Batch classify sources as article vs paper using a single LLM call.
    /// Input: array of (index, url, title). Returns set of indices that are papers.
    func batchClassifySourceTypes(
        items: [(index: Int, url: String, title: String)],
        config: AITaskConfig
    ) async -> Set<Int> {
        let classifications = await batchClassifySourceTypeMap(items: items, config: config)
        return Set(classifications.compactMap { index, type in type == .paper ? index : nil })
    }

    /// Batch classify sources as article vs paper vs book using a single LLM call.
    /// Input: array of (index, url, title). Returns classified source type keyed by original index.
    func batchClassifySourceTypeMap(
        items: [(index: Int, url: String, title: String)],
        config: AITaskConfig
    ) async -> [Int: StudioSourceType] {
        guard !items.isEmpty else { return [:] }

        let system = Prompts.batchSourceClassification

        let itemList = items.enumerated()
            .map { offset, item in "\(offset + 1). \(item.url) — \(item.title)" }
            .joined(separator: "\n")

        do {
            let sourceTitle = items.count == 1
                ? items[0].title
                : "\(items[0].title) + \(items.count - 1) more"
            let response = try await call(
                config: config,
                system: system,
                user: itemList,
                maxTokens: items.count * 15,
                temperature: 0.0,
                sourceTitle: sourceTitle
            )

            var classifications: [Int: StudioSourceType] = [:]
            for line in response.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let sourceType = Self.parseSourceTypeClassification(String(trimmed.split(separator: " ").last ?? "")) else {
                    continue
                }
                // Extract the number from "N paper" or "N. paper"
                let digits = trimmed.prefix(while: { $0.isNumber || $0 == "." || $0 == " " })
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                if let num = Int(digits), num >= 1, num <= items.count {
                    classifications[items[num - 1].index] = sourceType
                }
            }
            return classifications
        } catch {
            logger.error("batchClassifySourceTypeMap: batch source classification skipped after AI call failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Batch duplicate detection: given a list of papers, return groups of indices that
    /// refer to the same work. Uses Haiku for cheap/fast evaluation.
    /// Returns array of duplicate groups — each group is an array of indices (0-based)
    /// into the input array where all entries are the same paper.
    func findDuplicatePapers(
        papers: [(title: String, url: String)],
        config: AITaskConfig
    ) async -> [[Int]] {
        guard papers.count >= 2 else { return [] }

        let paperList = papers.enumerated().map { (i, p) in
            "\(i + 1). \(p.title) [\(p.url.prefix(80))]"
        }.joined(separator: "\n")

        let system = Prompts.batchDuplicateDetection

        let user = """
        Papers:
        \(paperList)
        """

        do {
            let response = try await call(
                config: config,
                system: system,
                user: user,
                maxTokens: 200,
                sourceTitle: "\(papers[0].title) + \(papers.count - 1) more"
            )
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "none" { return [] }

            // Parse lines like "1,3" or "2,5"
            var groups: [[Int]] = []
            for line in trimmed.components(separatedBy: .newlines) {
                let nums = line.components(separatedBy: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { $0 >= 1 && $0 <= papers.count }
                    .map { $0 - 1 }  // convert to 0-based
                if nums.count >= 2 {
                    groups.append(nums)
                }
            }
            return groups
        } catch {
            logger.error("findDuplicatePapers: batch duplicate detection skipped after AI call failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Fix Article Title (LLM)

    struct FixedTitleResult {
        let title: String?
        let author: String?
        let year: String?
    }

    /// Use an LLM to determine the proper title, author(s), and year for an article or paper.
    ///
    /// `evidence` is what the page said about its own title — its `<title>`,
    /// `og:title`, site name, first `<h1>` and JSON-LD headline — when the
    /// caller has the page. The model reads those beside the opening text and
    /// states the headline the author gave, so a title the page dressed in its
    /// site name ("Waypoint Bio: Immune Engineering — Amplify Partners") or in
    /// a section label ("Writings - The Missing Dimension in Pooled Screens")
    /// comes back as the article's own. Callers without the page pass nothing
    /// and the model works from the URL, the current title and the text.
    func fixArticleTitle(
        source: AIUsageSource,
        currentTitle: String,
        url: String,
        content: String?,
        evidence: PaperService.WebArticleTitleEvidence? = nil,
        config: AITaskConfig
    ) async -> FixedTitleResult? {
        let system = AITask.articleMetadata.effectivePrompt ?? Prompts.articleMetadata
        let userMsg = Self.articleMetadataRequest(
            currentTitle: currentTitle,
            url: url,
            evidence: evidence,
            content: content
        )

        do {
            let response = try await call(
                config: config,
                system: system,
                user: userMsg,
                maxTokens: 200,
                temperature: 0.0,
                sourceTitle: source.title,
                subjectID: source.id,
                subjectType: source.type,
                activityID: AIUsageAttribution.activityID ?? UUID().uuidString
            )
            guard let result = Self.parseArticleMetadataResponse(response, url: url) else {
                logger.warning("fixArticleTitle: no parseable fields from AI response; title fixing skipped: \(response, privacy: .public)")
                return nil
            }
            return result
        } catch {
            logger.error("fixArticleTitle: title fixing skipped after AI call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The user turn of the article-metadata call: the address, the title the
    /// library holds now, every title the page offered (when known), and the
    /// opening of the text. Each candidate is labelled with where on the page
    /// it came from, because that is what tells a reader which of them is the
    /// headline and which is the website around it.
    static func articleMetadataRequest(
        currentTitle: String,
        url: String,
        evidence: PaperService.WebArticleTitleEvidence?,
        content: String?
    ) -> String {
        var lines = ["URL: \(url)", "Current title in the library: \(currentTitle)"]
        if let evidence, !evidence.isEmpty || evidence.structuredAuthor != nil {
            lines.append("")
            lines.append("What the page says about itself:")
            lines.append("- <title>: \(evidence.documentTitle ?? "(none)")")
            lines.append("- og:title: \(evidence.socialTitle ?? "(none)")")
            lines.append("- Site name: \(evidence.siteName ?? "(none)")")
            lines.append("- First <h1>: \(evidence.headline ?? "(none)")")
            lines.append("- JSON-LD headline: \(evidence.structuredHeadline ?? "(none)")")
            if let author = evidence.structuredAuthor {
                lines.append("- JSON-LD author: \(author)")
            }
        }
        if let content, !content.isEmpty {
            lines.append("")
            lines.append("Opening of the text:")
            lines.append(String(content.prefix(2000)))
        }
        return lines.joined(separator: "\n")
    }

    /// Read the three-line answer. A title is accepted only when it names
    /// something: not blank, not "?", not the page's host, not longer than a
    /// title can be. Quotation marks a model wraps its answer in are removed.
    static func parseArticleMetadataResponse(_ response: String, url: String) -> FixedTitleResult? {
        var title: String?
        var author: String?
        var year: String?

        for line in response.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TITLE:") {
                let val = trimmed.dropFirst("TITLE:".count).trimmingCharacters(in: .whitespaces)
                if val != "?" && !val.isEmpty { title = val }
            } else if trimmed.hasPrefix("AUTHOR:") {
                let val = trimmed.dropFirst("AUTHOR:".count).trimmingCharacters(in: .whitespaces)
                if val != "?" && !val.isEmpty { author = val }
            } else if trimmed.hasPrefix("YEAR:") {
                let val = trimmed.dropFirst("YEAR:".count).trimmingCharacters(in: .whitespaces)
                if val != "?" && !val.isEmpty { year = val }
            }
        }

        if let candidate = title {
            let unquoted = candidate
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019} "))
            let host = URL(string: url)?.host?.lowercased()
            let bareHost = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            let lower = unquoted.lowercased()
            if unquoted.isEmpty || unquoted.count >= 300 || lower == "?" || lower == host || lower == bareHost {
                title = nil
            } else {
                title = unquoted
            }
        }

        guard title != nil || author != nil || year != nil else { return nil }
        return FixedTitleResult(title: title, author: author, year: year)
    }

    /// Normalize author-name capitalization with the configured metadata model.
    func normalizeAuthorCapitalization(
        _ author: String,
        source: AIUsageSource,
        config: AITaskConfig
    ) async throws -> String {
        let cacheKey = "\(config.provider.rawValue)|\(config.model)|\(author)"
        if let cached = normalizedAuthorCache[cacheKey] {
            return cached
        }

        let system = """
        You normalize bibliographic author metadata. Return the same author or author list with normal human name capitalization.
        Preserve initials, separators, accents, apostrophes, hyphens, suffixes, organization acronyms, and the original author order.
        Do not add, remove, abbreviate, expand, or reorder authors.

        Respond with exactly one line:
        AUTHOR: <normalized author string>
        """

        let user = "AUTHOR: \(author)"
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 200,
            temperature: 0.0,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )

        let value = response
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("AUTHOR:") else { return nil }
                return trimmed.dropFirst("AUTHOR:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first
        guard let value, !value.isEmpty, value != "?" else {
            throw AIError.invalidResponse
        }
        normalizedAuthorCache[cacheKey] = value
        return value
    }

    // MARK: - Book Metadata Extraction

    struct BookMetadataResult {
        let title: String?
        let subtitle: String?
        let author: String?
        let edition: String?

        static func validated(title: String?, subtitle: String?, author: String?, edition: String?) -> BookMetadataResult {
            let cleanSubtitle = cleanField(subtitle)
            let cleanEdition = cleanEdition(edition)
            return BookMetadataResult(
                title: cleanTitle(title, subtitle: cleanSubtitle, edition: cleanEdition),
                subtitle: cleanSubtitle,
                author: cleanAuthor(author),
                edition: cleanEdition
            )
        }

        static func cleanField(_ raw: String?) -> String? {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value != "?" else { return nil }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            return value.isEmpty ? nil : value
        }

        static func cleanTitle(_ raw: String?, subtitle: String?, edition: String?) -> String? {
            cleanField(raw)
        }

        static func removeRedundantSuffix(_ redundantValue: String, from title: String) -> String {
            title
        }

        static func cleanAuthor(_ raw: String?) -> String? {
            cleanField(raw)
        }

        static func cleanEdition(_ raw: String?) -> String? {
            cleanField(raw)
        }
    }

    /// Extract book title/subtitle/author/edition from file metadata and front matter using an LLM.
    func extractBookMetadata(
        source: AIUsageSource,
        filename: String,
        title: String?,
        author: String?,
        firstPagesText: String,
        config: AITaskConfig
    ) async -> BookMetadataResult? {
        let system = AITask.bookAuthor.effectivePrompt ?? Prompts.bookAuthor
        let user = """
        Filename: \(filename)
        Title metadata: \(title ?? "?")
        Author metadata: \(author ?? "?")

        Front matter text:
        \(String(firstPagesText.prefix(3500)))
        """

        do {
            let response = try await call(
                config: config,
                system: system,
                user: user,
                maxTokens: 240,
                temperature: 0.0,
                sourceTitle: source.title,
                subjectID: source.id,
                subjectType: source.type,
                activityID: AIUsageAttribution.activityID ?? UUID().uuidString
            )
            var extractedTitle: String?
            var subtitle: String?
            var extractedAuthor: String?
            var edition: String?

            for line in response.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("TITLE:") {
                    let value = trimmed.dropFirst("TITLE:".count).trimmingCharacters(in: .whitespaces)
                    if value != "?" { extractedTitle = value }
                } else if trimmed.hasPrefix("SUBTITLE:") {
                    let value = trimmed.dropFirst("SUBTITLE:".count).trimmingCharacters(in: .whitespaces)
                    if value != "?" { subtitle = value }
                } else if trimmed.hasPrefix("AUTHOR:") {
                    let value = trimmed.dropFirst("AUTHOR:".count).trimmingCharacters(in: .whitespaces)
                    if value != "?" { extractedAuthor = value }
                } else if trimmed.hasPrefix("EDITION:") {
                    let value = trimmed.dropFirst("EDITION:".count).trimmingCharacters(in: .whitespaces)
                    if value != "?" { edition = value }
                }
            }

            let result = BookMetadataResult.validated(
                title: extractedTitle,
                subtitle: subtitle,
                author: extractedAuthor,
                edition: edition
            )
            guard result.title != nil || result.subtitle != nil || result.author != nil || result.edition != nil else {
                logger.warning("extractBookMetadata: AI response had no usable metadata fields; book metadata extraction skipped")
                return nil
            }
            return result
        } catch {
            logger.error("extractBookMetadata: book metadata extraction skipped after AI call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Extract the author(s) of a book from its title/filename using an LLM.
    func extractBookAuthor(
        source: AIUsageSource,
        bookTitle: String,
        config: AITaskConfig
    ) async -> String? {
        await extractBookMetadata(
            source: source,
            filename: bookTitle,
            title: bookTitle,
            author: nil,
            firstPagesText: "",
            config: config
        )?.author
    }

    // MARK: - Paper Metadata Extraction (LLM)

    struct PaperMetadataResult {
        let title: String?
        let author: String?
        let journal: String?
        let year: String?
        let doi: String?

        /// Validate and clean extracted metadata fields.
        static func validated(title: String?, author: String?, journal: String?, year: String?, doi: String?) -> PaperMetadataResult {
            PaperMetadataResult(
                title: Self.cleanTitle(title),
                author: Self.cleanAuthor(author),
                journal: Self.cleanJournal(journal),
                year: Self.cleanYear(year),
                doi: Self.cleanDOI(doi)
            )
        }

        static func cleanTitle(_ raw: String?) -> String? {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }

        static func cleanAuthor(_ raw: String?) -> String? {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value != "?" else { return nil }
            return value
        }

        static func cleanJournal(_ raw: String?) -> String? {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }

        static func cleanYear(_ raw: String?) -> String? {
            guard let y = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !y.isEmpty else { return nil }
            // Extract exactly a 4-digit year (19xx or 20xx)
            let pattern = #"((?:19|20)\d{2})"#
            guard let match = y.range(of: pattern, options: .regularExpression) else { return nil }
            return String(y[match])
        }

        static func cleanDOI(_ raw: String?) -> String? {
            guard let d = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
            // Must start with "10."
            guard d.hasPrefix("10.") else { return nil }
            // Strip URL prefix if present
            var cleaned = d
            if let range = cleaned.range(of: "doi.org/") {
                cleaned = String(cleaned[range.upperBound...])
            }
            // Strip trailing punctuation
            while cleaned.last == "." || cleaned.last == "," || cleaned.last == ";" {
                cleaned = String(cleaned.dropLast())
            }
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// The first request's output ceiling. A reasoning model can spend all of
    /// it thinking before the five lines; callers raise it with
    /// `paperMetadataRaisedMaxTokens(after:)` and ask again.
    static let paperMetadataMaxTokens = 4096

    /// The ceiling for the request after one that stopped at `ceiling`, or nil
    /// once the largest has been tried. Ceilings are free unless used.
    static func paperMetadataRaisedMaxTokens(after ceiling: Int) -> Int? {
        let steps = [paperMetadataMaxTokens, 16_384, 32_768]
        return steps.first { $0 > ceiling }
    }

    /// Extract paper metadata from the first page of a PDF using an LLM.
    /// This is the source of truth when a PDF is available.
    func extractPaperMetadata(
        source: AIUsageSource,
        url: String,
        title: String,
        firstPageText: String,
        characterLimit: Int = 6000,
        maxTokens: Int = AIService.paperMetadataMaxTokens,
        config: AITaskConfig
    ) async throws -> PaperMetadataResult {
        let system = AITask.paperMetadata.effectivePrompt ?? Prompts.paperMetadata

        // The budget covers front matter, not one page: a repository cover sheet
        // can consume most of it before the real title page starts.
        let frontMatter = String(firstPageText.prefix(characterLimit))
        let user = "URL: \(url)\nTitle: \(title)\n\nFront matter text:\n\(frontMatter)"
        // What the title and authors may be copied from. The title on record is
        // the page's own for a web-page paper whose text does not repeat it.
        let given = "\(title)\n\(frontMatter)"

        let response = try await call(
            config: config,
            system: system,
            user: user,
            // GPT-5-class models count hidden reasoning against the same output
            // ceiling. The unified one-shot transport does not pass through the
            // legacy OpenAI adapter that inflates this budget, so the old 600
            // tokens could be exhausted before any of the five required lines.
            maxTokens: maxTokens,
            temperature: 0.0,
            allowsReasoningInflation: false,
            // A reply that is not five field lines, or whose title or authors
            // carry a word the model was not given, is not kept: the backups
            // answer, and Retry asks a model again instead of replaying it.
            validateResponse: { _ = try AIService.paperMetadata(fromReply: $0, given: given) },
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.paperMetadata(fromReply: response, given: given)
    }

    /// The labels a Paper Metadata reply answers, one line each.
    static let paperMetadataReplyLabels = ["TITLE", "AUTHOR", "JOURNAL", "YEAR", "DOI"]

    /// The fields read from a Paper Metadata reply, one `FIELD: value` line
    /// each, with `?` for a field the document does not print.
    ///
    /// A reply that leaves a label out has not said the document lacks that
    /// field, so it is refused rather than read as a blank. On 2026-10-12 a
    /// small model wrote "AUTHORS:" for "AUTHOR:"; the line was skipped, and
    /// the import reported that the paper printed no author over five names
    /// on its first page. Labels are read in any case, and "AUTHORS" is the
    /// plural of the one label that asks for a list.
    static func paperMetadata(fromReply response: String) throws -> PaperMetadataResult {
        var fields: [String: String] = [:]
        for line in response.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            var label = trimmed[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            if label == "AUTHORS" { label = "AUTHOR" }
            guard paperMetadataReplyLabels.contains(label) else { continue }
            fields[label] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let missing = paperMetadataReplyLabels.filter { fields[$0] == nil }
        guard missing.count < paperMetadataReplyLabels.count else {
            throw AIError.invalidResponse
        }
        guard missing.isEmpty else {
            throw AIError.apiError(
                "The Paper Metadata reply left out \(missing.joined(separator: ", ")), so it was refused."
            )
        }

        func answer(_ label: String) -> String? {
            guard let value = fields[label], !value.isEmpty, value != "?" else { return nil }
            return value
        }
        return PaperMetadataResult.validated(
            title: answer("TITLE"),
            author: answer("AUTHOR"),
            journal: answer("JOURNAL"),
            year: answer("YEAR"),
            doi: answer("DOI").flatMap { $0.hasPrefix("10.") ? $0 : nil }
        )
    }

    /// `paperMetadata(fromReply:)`, refused when the title or the authors
    /// carry a word that `given`, the text the model was given, does not print.
    ///
    /// Title and authors are copied off the page, so the model decides which
    /// words they are and the app checks that each one is there, as Source
    /// Content Cleanup checks that every passage it deletes occurs. On
    /// 2026-10-12 a 2.6B model read "ANCIENT MICROSPHERES: ABIOGENIC,
    /// PROTOBIOGENIC, OR BIOGENIC?" and answered "Ancient Microscopes:
    /// Abiogenic, Protobionic, or Biogenic?"; that reply now goes to the backups.
    static func paperMetadata(fromReply response: String, given: String) throws -> PaperMetadataResult {
        let result = try paperMetadata(fromReply: response)
        let unprinted = [result.title, result.author]
            .compactMap { $0 }
            .flatMap { wordsNotPrinted(in: $0, given: given) }
        guard unprinted.isEmpty else {
            let words = unprinted.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            throw AIError.apiError(
                "The Paper Metadata reply has words the document does not print (\(words)), so it was refused."
            )
        }
        return result
    }

    /// The words of `value` that `given` does not print, in order.
    ///
    /// Both sides are compared by their letters and digits alone, transliterated
    /// to lowercase ASCII, so case, accents, ligatures, punctuation and line
    /// breaks are no difference; the search runs over `given`'s letters run
    /// together, so a word hyphenated across a line ("PROTO-" /
    /// "BIOGENIC") still occurs. PDF text can lose a non-ASCII glyph its font
    /// cannot map ("α-Ketoglutarate" read as "-Ketoglutarate",
    /// `RegisteredPaperTitle`), so a word also occurs when it does without its
    /// non-ASCII characters, and a word of nothing else is not checked. It
    /// loses an f-ligature the same way ("arti cial intelligence", "cell-type-
    /// speci c" in Nature PDFs), so a word also occurs without its ligated letters.
    static func wordsNotPrinted(in value: String, given: String) -> [String] {
        let printed = printedLetters(given)
        return value
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .compactMap { word -> String? in
                let ascii = printedLetters(String(String.UnicodeScalarView(word.unicodeScalars.filter(\.isASCII))))
                guard !ascii.isEmpty else { return nil }
                let readings = [printedLetters(String(word)), ascii] + lostLigatureReadings.map { ligatures in
                    ligatures.reduce(ascii) { $0.replacingOccurrences(of: $1, with: "") }
                }
                if readings.contains(where: { !$0.isEmpty && printed.contains($0) }) { return nil }
                return String(word)
            }
    }

    /// The letters a lost ligature glyph takes with it, longest first. A lost
    /// "ﬃ" can take all three letters, or leave its first "f" when the font
    /// set it as "f" + "ﬁ".
    private static let lostLigatureReadings: [[String]] = [
        ["ffi", "ffl", "ff", "fi", "fl"],
        ["fi", "fl"]
    ]

    private static let printedLettersTransform = StringTransform(rawValue: "Any-Latin; Latin-ASCII; Any-Lower")

    /// `text`'s letters and digits, transliterated to lowercase ASCII and run together.
    private static func printedLetters(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        // A transform ID Foundation does not know returns nil; this one is fixed
        // and covered by the paper metadata tests.
        let latin = compatible.applyingTransform(printedLettersTransform, reverse: false) ?? compatible.lowercased()
        return String(String.UnicodeScalarView(latin.unicodeScalars.filter {
            $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil)
        }))
    }

    struct PaperContentBlock: Sendable, Equatable {
        let id: String
        let text: String
    }

    struct PaperContentTextDeletion: Codable, Sendable, Equatable, Hashable {
        let blockID: String
        let exactText: String
        let occurrence: Int
    }

    struct PaperContentDeletionPlan: Codable, Sendable, Equatable {
        let removeBlocks: [String]
        let relocations: [PaperSpeechRelocation]
        let keepInPlaceBoxHeadingIDs: [String]
        let removeText: [PaperContentTextDeletion]

        static let empty = PaperContentDeletionPlan(
            removeBlocks: [],
            relocations: [],
            keepInPlaceBoxHeadingIDs: [],
            removeText: []
        )

        init(
            removeBlocks: [String],
            relocations: [PaperSpeechRelocation] = [],
            keepInPlaceBoxHeadingIDs: [String] = [],
            removeText: [PaperContentTextDeletion]
        ) {
            self.removeBlocks = removeBlocks
            self.relocations = relocations
            self.keepInPlaceBoxHeadingIDs = keepInPlaceBoxHeadingIDs
            self.removeText = removeText
        }

        private enum CodingKeys: String, CodingKey {
            case removeBlocks
            case relocations
            case keepInPlaceBoxHeadingIDs
            case removeText
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            removeBlocks = try container.decodeIfPresent([String].self, forKey: .removeBlocks) ?? []
            relocations = try container.decodeIfPresent([PaperSpeechRelocation].self, forKey: .relocations) ?? []
            keepInPlaceBoxHeadingIDs = try container.decodeIfPresent(
                [String].self,
                forKey: .keepInPlaceBoxHeadingIDs
            ) ?? []
            removeText = try container.decodeIfPresent([PaperContentTextDeletion].self, forKey: .removeText) ?? []
        }

        func merging(_ other: PaperContentDeletionPlan) -> PaperContentDeletionPlan {
            PaperContentDeletionPlan(
                removeBlocks: removeBlocks + other.removeBlocks,
                relocations: relocations + other.relocations,
                keepInPlaceBoxHeadingIDs: keepInPlaceBoxHeadingIDs
                    + other.keepInPlaceBoxHeadingIDs,
                removeText: removeText + other.removeText
            )
        }
    }

    struct PaperSpeechAdaptation: Codable, Sendable, Equatable {
        let blockIDs: [String]
        let spokenText: String?
    }

    /// A boxed sidebar extracted in physical page order can land in the middle
    /// of the main column's sentence. The model may defer that exact contiguous
    /// block range until after the interrupted main-text paragraph finishes;
    /// reconstruction moves authoritative blocks without rewriting them.
    struct PaperSpeechRelocation: Codable, Sendable, Equatable, Hashable {
        let blockIDs: [String]
        let insertAfterBlockID: String
        let resumeAtBlockID: String?

        init(
            blockIDs: [String],
            insertAfterBlockID: String,
            resumeAtBlockID: String? = nil
        ) {
            self.blockIDs = blockIDs
            self.insertAfterBlockID = insertAfterBlockID
            self.resumeAtBlockID = resumeAtBlockID
        }
    }

    struct PaperSpeechAdaptationPlan: Codable, Sendable, Equatable {
        let adaptations: [PaperSpeechAdaptation]
        let relocations: [PaperSpeechRelocation]
        let removeText: [PaperContentTextDeletion]

        static let empty = PaperSpeechAdaptationPlan(
            adaptations: [],
            relocations: [],
            removeText: []
        )

        init(
            adaptations: [PaperSpeechAdaptation],
            relocations: [PaperSpeechRelocation] = [],
            removeText: [PaperContentTextDeletion] = []
        ) {
            self.adaptations = adaptations
            self.relocations = relocations
            self.removeText = removeText
        }

        private enum CodingKeys: String, CodingKey {
            case adaptations
            case relocations
            case removeText
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            adaptations = try container.decodeIfPresent([PaperSpeechAdaptation].self, forKey: .adaptations) ?? []
            relocations = try container.decodeIfPresent([PaperSpeechRelocation].self, forKey: .relocations) ?? []
            removeText = try container.decodeIfPresent([PaperContentTextDeletion].self, forKey: .removeText) ?? []
        }

        func merging(_ other: PaperSpeechAdaptationPlan) -> PaperSpeechAdaptationPlan {
            PaperSpeechAdaptationPlan(
                adaptations: adaptations + other.adaptations,
                relocations: relocations + other.relocations,
                removeText: removeText + other.removeText
            )
        }
    }

    static let paperContentDeletionMaxTokens = 32_768

    struct PaperContentDeletionRequest: Sendable {
        let system: String
        let user: String

        /// Match the one-shot budgeter's system + one user message accounting.
        var inputCharacterCount: Int { system.count + user.count + 16 }
    }

    static func paperContentDeletionTaggedBlock(_ block: PaperContentBlock) -> String {
        "{\"id\":\"\(block.id)\",\"text\":\"\(Self.jsonEscaped(block.text))\"}"
    }

    static func paperContentDeletionUsageTitle(
        sourceTitle: String,
        chunkIndex: Int,
        chunkCount: Int
    ) -> String {
        chunkCount == 1
            ? sourceTitle
            : "Chunk \(chunkIndex + 1)/\(chunkCount) · \(sourceTitle)"
    }

    static func paperContentDeletionRequest(
        system: String,
        sourceTitle: String,
        sourceType: StudioSourceType,
        blocks: [PaperContentBlock],
        chunkIndex: Int,
        chunkCount: Int
    ) -> PaperContentDeletionRequest {
        let taggedBlocks = blocks.map(Self.paperContentDeletionTaggedBlock)
            .joined(separator: ",\n")
        let documentContext: String
        if chunkCount == 1 {
            documentContext = """
            This is the complete extracted source. Inspect every supplied block and return one cleanup plan for the entire document. Use only the supplied block IDs.
            """
        } else {
            documentContext = """
            The complete source exceeds this model's context window. This is Chunk \(chunkIndex + 1)/\(chunkCount). Clean every supplied block in this part, use only supplied block IDs, and do not propose relocations that cross this chunk boundary.
            """
        }
        let user = """
        SOURCE TYPE:
        \(sourceType == .paper ? "academic paper" : "web article")

        AUTHORITATIVE SOURCE TITLE:
        \(sourceTitle)

        DOCUMENT CONTEXT:
        \(documentContext)

        BLOCKS JSON:
        [
        \(taggedBlocks)
        ]
        """
        return PaperContentDeletionRequest(system: system, user: user)
    }

    /// Ask a cheap text model for an exact deletion/forward-relocation plan
    /// rather than rewritten source text. Reconstruction remains deterministic,
    /// so the model cannot paraphrase, truncate, or invent paper/article prose.
    func paperContentDeletionPlan(
        source: AIUsageSource,
        sourceType: StudioSourceType = .paper,
        blocks: [PaperContentBlock],
        config: AITaskConfig,
        system: String,
        chunkIndex: Int = 0,
        chunkCount: Int = 1
    ) async throws -> PaperContentDeletionPlan {
        let authoritativeTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authoritativeTitle.isEmpty, !blocks.isEmpty else {
            throw AIError.invalidResponse
        }

        guard chunkIndex >= 0, chunkCount > 0, chunkIndex < chunkCount else {
            throw AIError.invalidResponse
        }
        let request = Self.paperContentDeletionRequest(
            system: system,
            sourceTitle: authoritativeTitle,
            sourceType: sourceType,
            blocks: blocks,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount
        )
        let usageTitle = Self.paperContentDeletionUsageTitle(
            sourceTitle: source.title,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount
        )
        let response = try await call(
            config: config,
            system: request.system,
            user: request.user,
            // A deletion diff stays much smaller than returning cleaned prose,
            // while leaving room for inline citation hunks in dense papers.
            // This is only a ceiling; OpenRouter bills actual output. A fixed
            // ceiling prevents citation-dense papers from being truncated by
            // the old block-count-derived 768-token cap.
            // Output ceilings are free unless used. A few citation-dense model
            // responses legitimately exceed 8k even though the deletion diff
            // is still far smaller than rewritten prose; reserve enough room
            // to finish their JSON instead of stranding the source.
            maxTokens: Self.paperContentDeletionMaxTokens,
            temperature: 0,
            allowsReasoningInflation: false,
            disablesReasoning: true,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: usageTitle,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.validatedPaperContentDeletionPlan(
            response,
            blocks: blocks
        )
    }

    /// One maximal run of consecutive blocks a cleanup plan deletes in full,
    /// with the kept block on either side of it for position.
    struct PaperContentDeletionAuditRun: Sendable, Equatable {
        let keptBefore: PaperContentBlock?
        let removed: [PaperContentBlock]
        let keptAfter: PaperContentBlock?
    }

    struct PaperContentDeletionAudit: Codable, Sendable, Equatable {
        let keepBlocks: [String]
    }

    static func paperContentDeletionAuditSerializedRun(_ run: PaperContentDeletionAuditRun) -> String {
        func tagged(_ block: PaperContentBlock?) -> String {
            block.map(Self.paperContentDeletionTaggedBlock) ?? "null"
        }
        return """
        {"keptBefore":\(tagged(run.keptBefore)),"delete":[
        \(run.removed.map(Self.paperContentDeletionTaggedBlock).joined(separator: ",\n"))
        ],"keptAfter":\(tagged(run.keptAfter))}
        """
    }

    static func paperContentDeletionAuditRequest(
        sourceTitle: String,
        sourceType: StudioSourceType,
        runs: [PaperContentDeletionAuditRun],
        chunkIndex: Int,
        chunkCount: Int
    ) -> PaperContentDeletionRequest {
        let serializedRuns = runs.map(Self.paperContentDeletionAuditSerializedRun)
            .joined(separator: ",\n")
        let documentContext = chunkCount == 1
            ? "These are all of the whole-block deletions the cleanup proposed for this source."
            : "The proposed deletions exceed this model's context window. This is Part \(chunkIndex + 1)/\(chunkCount); judge every block supplied here."
        let user = """
        SOURCE TYPE:
        \(sourceType == .paper ? "academic paper" : "web article")

        AUTHORITATIVE SOURCE TITLE:
        \(sourceTitle)

        DOCUMENT CONTEXT:
        \(documentContext) keptBefore and keptAfter are context only and are never deleted; null means the run touches the start or end of the source.

        RUNS JSON:
        [
        \(serializedRuns)
        ]
        """
        return PaperContentDeletionRequest(system: Prompts.paperContentDeletionAudit, user: user)
    }

    /// Ask the cleanup model which proposed whole-block deletions are really
    /// source content. It sees only the deletions, so the answer can restore
    /// blocks and never remove one: a wrong reply leaves noise in, not a hole.
    func paperContentDeletionAudit(
        source: AIUsageSource,
        sourceType: StudioSourceType,
        runs: [PaperContentDeletionAuditRun],
        config: AITaskConfig,
        chunkIndex: Int,
        chunkCount: Int
    ) async throws -> Set<String> {
        let authoritativeTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authoritativeTitle.isEmpty, !runs.isEmpty,
              chunkIndex >= 0, chunkCount > 0, chunkIndex < chunkCount else {
            throw AIError.invalidResponse
        }
        let request = Self.paperContentDeletionAuditRequest(
            sourceTitle: authoritativeTitle,
            sourceType: sourceType,
            runs: runs,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount
        )
        let usageTitle = "Deletion check · " + Self.paperContentDeletionUsageTitle(
            sourceTitle: source.title,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount
        )
        let response = try await call(
            config: config,
            system: request.system,
            user: request.user,
            // A methods section swept up with the references can be hundreds
            // of lines, each an ID in the reply. Only a ceiling.
            maxTokens: Self.paperContentDeletionMaxTokens,
            temperature: 0,
            allowsReasoningInflation: false,
            disablesReasoning: true,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: usageTitle,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.validatedPaperContentDeletionAudit(response, runs: runs)
    }

    /// Only IDs the audit was shown as deletions can be restored. A context
    /// block was never deleted, so naming one changes nothing.
    nonisolated static func validatedPaperContentDeletionAudit(
        _ response: String,
        runs: [PaperContentDeletionAuditRun]
    ) throws -> Set<String> {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            json = String(trimmed[firstBrace...lastBrace])
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8),
              let audit = try? JSONDecoder().decode(PaperContentDeletionAudit.self, from: data) else {
            throw AIError.apiError("Source Content Cleanup returned an invalid deletion check.")
        }
        let proposedIDs = Set(runs.flatMap { $0.removed.map(\.id) })
        return Set(audit.keepBlocks).intersection(proposedIDs)
    }

    struct ArticleChromeRegionPlan: Codable, Sendable, Equatable {
        let removeRegions: [String]
    }

    /// Ask which of a page's structural regions are the surrounding website.
    ///
    /// The model never sees or returns page markup — only an outline of region
    /// IDs with text previews, and a list of IDs to drop. Deleting the matching
    /// character ranges stays in the app, so a wrong or malformed answer can
    /// remove regions but can never rewrite an article.
    func articleChromeRegionPlan(
        source: AIUsageSource,
        pageURL: URL,
        articleTitle: String?,
        regions: [ArticleChromeFilter.Region],
        config: AITaskConfig,
        system: String
    ) async throws -> Set<String> {
        guard !regions.isEmpty else { return [] }
        let title = (articleTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let user = """
        PAGE URL:
        \(pageURL.absoluteString)

        ARTICLE TITLE:
        \(title.isEmpty ? "unknown" : title)

        REGIONS JSON:
        \(ArticleChromeFilter.outlineJSON(for: regions))
        """
        let response = try await call(
            config: config,
            system: system,
            user: user,
            // The answer is a list of region IDs, not page content.
            maxTokens: 4_096,
            temperature: 0,
            allowsReasoningInflation: false,
            disablesReasoning: true,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.validatedArticleChromeRegionPlan(response, regions: regions)
    }

    /// Accept only IDs the model was actually shown. An unknown ID names no
    /// range, so keeping it could never do anything but hide a misread.
    nonisolated static func validatedArticleChromeRegionPlan(
        _ response: String,
        regions: [ArticleChromeFilter.Region]
    ) throws -> Set<String> {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            json = String(trimmed[firstBrace...lastBrace])
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(ArticleChromeRegionPlan.self, from: data) else {
            throw AIError.apiError("Article chrome filtering returned an invalid region plan.")
        }
        let allowedIDs = Set(regions.map(\.id))
        return Set(plan.removeRegions.filter { allowedIDs.contains($0) })
    }

    /// Ask the configured narration model to identify visual/nonlinear source
    /// structures. The response names authoritative blocks; reconstruction and
    /// all untouched prose remain deterministic in the app.
    func paperSpeechAdaptationPlan(
        source: AIUsageSource,
        blocks: [PaperContentBlock],
        config: AITaskConfig,
        chunkIndex: Int,
        chunkCount: Int
    ) async throws -> PaperSpeechAdaptationPlan {
        let authoritativeTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authoritativeTitle.isEmpty, !blocks.isEmpty else {
            throw AIError.invalidResponse
        }

        let system = AITask.paperTextToSpeechPreparation.effectivePrompt
            ?? Prompts.paperTextToSpeechPreparation
        let taggedBlocks = blocks.map { block in
            "{\"id\":\"\(block.id)\",\"text\":\"\(Self.jsonEscaped(block.text))\"}"
        }.joined(separator: ",\n")
        let user = """
        SOURCE TYPE:
        \(source.type)

        AUTHORITATIVE SOURCE TITLE:
        \(authoritativeTitle)

        CHUNK CONTEXT:
        Chunk \(chunkIndex + 1) of \(chunkCount). Block IDs are globally unique. Adaptations may use only IDs supplied below and may not cross chunk boundaries.

        BLOCKS JSON:
        [
        \(taggedBlocks)
        ]
        """
        let response = try await call(
            config: config,
            system: system,
            user: user,
            // Large ordering windows are required to see a sidebar and the
            // paragraph continuation that follows it. Citation-dense papers can
            // also require many small verbatim deletion hunks, so 4k could
            // truncate an otherwise valid JSON plan. This is only a ceiling;
            // OpenRouter meters the output actually produced.
            // Large tables can require many short spoken adaptations. Reserve
            // a generous ceiling so the JSON closes; billing remains based on
            // actual output rather than this maximum.
            maxTokens: 32_768,
            temperature: 0,
            allowsReasoningInflation: false,
            allowsResponseCache: false,
            jsonMode: true,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        return try Self.validatedPaperSpeechAdaptationPlan(response, blocks: blocks)
    }

    nonisolated static func validatedPaperSpeechAdaptationPlan(
        _ response: String,
        blocks: [PaperContentBlock]
    ) throws -> PaperSpeechAdaptationPlan {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            json = String(trimmed[firstBrace...lastBrace])
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(PaperSpeechAdaptationPlan.self, from: data) else {
            throw AIError.apiError("Text-to-Speech Preparation returned an invalid adaptation plan.")
        }

        let indexByID = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) })
        var adaptedIDs = Set<String>()
        var accepted: [PaperSpeechAdaptation] = []
        for adaptation in plan.adaptations {
            guard !adaptation.blockIDs.isEmpty,
                  adaptation.blockIDs.allSatisfy({ indexByID[$0] != nil }),
                  Set(adaptation.blockIDs).count == adaptation.blockIDs.count,
                  adaptation.blockIDs.allSatisfy({ !adaptedIDs.contains($0) }) else {
                continue
            }
            let indices = adaptation.blockIDs.compactMap { indexByID[$0] }
            guard indices == indices.sorted(),
                  zip(indices, indices.dropFirst()).allSatisfy({ pair in
                      pair.1 == pair.0 + 1
                  }) else {
                continue
            }

            let spoken = adaptation.spokenText?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard spoken == nil || (spoken!.count <= 1_200 && spoken!.rangeOfCharacter(from: .alphanumerics) != nil) else {
                continue
            }
            let normalized = PaperSpeechAdaptation(
                blockIDs: adaptation.blockIDs,
                spokenText: spoken?.isEmpty == false ? spoken : nil
            )
            accepted.append(normalized)
            adaptedIDs.formUnion(adaptation.blockIDs)
        }

        var relocatedIDs = Set<String>()
        var relocationCandidates: [PaperSpeechRelocation] = []
        for relocation in plan.relocations {
            guard !relocation.blockIDs.isEmpty,
                  relocation.blockIDs.allSatisfy({ indexByID[$0] != nil }),
                  Set(relocation.blockIDs).count == relocation.blockIDs.count,
                  relocation.blockIDs.allSatisfy({
                      !adaptedIDs.contains($0) && !relocatedIDs.contains($0)
                  }),
                  let anchorIndex = indexByID[relocation.insertAfterBlockID],
                  !adaptedIDs.contains(relocation.insertAfterBlockID),
                  !relocation.blockIDs.contains(relocation.insertAfterBlockID) else {
                continue
            }
            let indices = relocation.blockIDs.compactMap { indexByID[$0] }
            guard indices == indices.sorted(),
                  zip(indices, indices.dropFirst()).allSatisfy({ pair in
                      pair.1 == pair.0 + 1
                  }),
                  let finalMovedIndex = indices.last,
                  anchorIndex > finalMovedIndex else {
                continue
            }
            relocationCandidates.append(relocation)
            relocatedIDs.formUnion(relocation.blockIDs)
        }
        let acceptedRelocations = relocationCandidates.filter {
            !relocatedIDs.contains($0.insertAfterBlockID)
        }
        let blockText = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) })
        var acceptedText = Set<PaperContentTextDeletion>()
        var acceptedRanges: [String: [Range<String.Index>]] = [:]
        for deletion in plan.removeText {
            guard indexByID[deletion.blockID] != nil,
                  !adaptedIDs.contains(deletion.blockID),
                  !deletion.exactText.isEmpty,
                  deletion.exactText.count <= 160,
                  deletion.occurrence > 0,
                  let text = blockText[deletion.blockID],
                  let range = Self.range(
                      of: deletion.exactText,
                      occurrence: deletion.occurrence,
                      in: text
                  ),
                  !(acceptedRanges[deletion.blockID] ?? []).contains(where: { $0.overlaps(range) }) else {
                continue
            }
            acceptedText.insert(deletion)
            acceptedRanges[deletion.blockID, default: []].append(range)
        }
        accepted.sort {
            (indexByID[$0.blockIDs[0]] ?? .max) < (indexByID[$1.blockIDs[0]] ?? .max)
        }
        return PaperSpeechAdaptationPlan(
            adaptations: accepted,
            relocations: acceptedRelocations.sorted {
                    (indexByID[$0.blockIDs[0]] ?? .max) < (indexByID[$1.blockIDs[0]] ?? .max)
                },
            removeText: acceptedText.sorted {
                if $0.blockID != $1.blockID { return $0.blockID < $1.blockID }
                if $0.occurrence != $1.occurrence { return $0.occurrence < $1.occurrence }
                return $0.exactText < $1.exactText
            }
        )
    }

    /// The model's reply was not a deletion plan at all. The reply is sampled, so
    /// asking again usually gets one; the cleanup does that before it fails.
    nonisolated static let invalidPaperContentDeletionPlanMessage =
        "Source Content Cleanup returned an invalid deletion plan."

    nonisolated static func validatedPaperContentDeletionPlan(
        _ response: String,
        blocks: [PaperContentBlock]
    ) throws -> PaperContentDeletionPlan {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some low-cost routes occasionally wrap otherwise valid JSON despite
        // jsonMode. Extracting the outer object is safe: every deletion is still
        // validated against the exact blocks below.
        let json: String
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            json = String(trimmed[firstBrace...lastBrace])
        } else {
            json = trimmed
        }
        let allowedIDs = Set(blocks.map(\.id))
        guard let data = json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(PaperContentDeletionPlan.self, from: data) else {
            throw AIError.apiError(invalidPaperContentDeletionPlanMessage)
        }

        let boxHeadingIDs = Set(
            blocks.compactMap { block in
                Self.isCanonicalBoxHeading(block.text) ? block.id : nil
            }
        )
        // Unknown IDs cannot name authoritative input, so retaining them would
        // never be useful. Explicit Box headings are code-owned structure: a
        // cleanup response may classify or relocate them, but never delete or
        // edit the heading itself.
        let removedBlocks = Set(
            plan.removeBlocks.filter {
                allowedIDs.contains($0) && !boxHeadingIDs.contains($0)
            }
        )
        let blockText = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.text) })
        var acceptedText = Set<PaperContentTextDeletion>()
        var acceptedRanges: [String: [Range<String.Index>]] = [:]
        for deletion in plan.removeText {
            guard allowedIDs.contains(deletion.blockID),
                  !removedBlocks.contains(deletion.blockID),
                  !boxHeadingIDs.contains(deletion.blockID),
                  !deletion.exactText.isEmpty,
                  deletion.exactText.count <= 160,
                  deletion.occurrence > 0,
                  let text = blockText[deletion.blockID],
                  let range = Self.range(
                    of: deletion.exactText,
                    occurrence: deletion.occurrence,
                    in: text
                  ),
                  !(acceptedRanges[deletion.blockID] ?? []).contains(where: { $0.overlaps(range) }) else {
                continue
            }
            acceptedText.insert(deletion)
            acceptedRanges[deletion.blockID, default: []].append(range)
        }
        let normalized = PaperContentDeletionPlan(
            removeBlocks: removedBlocks.sorted(),
            relocations: Self.validatedForwardRelocations(
                plan.relocations,
                blocks: blocks,
                excludedBlockIDs: removedBlocks
            ),
            keepInPlaceBoxHeadingIDs: Set(
                plan.keepInPlaceBoxHeadingIDs.filter(boxHeadingIDs.contains)
            ).sorted(),
            removeText: acceptedText.sorted {
                if $0.blockID != $1.blockID { return $0.blockID < $1.blockID }
                if $0.occurrence != $1.occurrence { return $0.occurrence < $1.occurrence }
                return $0.exactText < $1.exactText
            }
        )
        let ignoredCount = plan.removeText.count - normalized.removeText.count
        if ignoredCount > 0
            || plan.removeBlocks.count != normalized.removeBlocks.count
            || plan.relocations.count != normalized.relocations.count
            || plan.keepInPlaceBoxHeadingIDs.count
                != normalized.keepInPlaceBoxHeadingIDs.count {
            logger.warning(
                "Source Content Cleanup normalized duplicate or unsafe plan entries"
            )
        }
        return normalized
    }

    private nonisolated static func validatedForwardRelocations(
        _ relocations: [PaperSpeechRelocation],
        blocks: [PaperContentBlock],
        excludedBlockIDs: Set<String>
    ) -> [PaperSpeechRelocation] {
        let indexByID = Dictionary(
            uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) }
        )
        var relocatedIDs = Set<String>()
        var candidates: [PaperSpeechRelocation] = []
        for proposed in relocations {
            let relocation: PaperSpeechRelocation
            if let resumeAtBlockID = proposed.resumeAtBlockID {
                guard proposed.blockIDs.count == 1,
                      let startID = proposed.blockIDs.first,
                      let startIndex = indexByID[startID],
                      Self.isCanonicalBoxHeading(blocks[startIndex].text),
                      let resumeIndex = indexByID[resumeAtBlockID],
                      resumeIndex > startIndex else { continue }
                relocation = PaperSpeechRelocation(
                    blockIDs: blocks[startIndex..<resumeIndex].map(\.id),
                    insertAfterBlockID: proposed.insertAfterBlockID
                )
            } else {
                relocation = PaperSpeechRelocation(
                    blockIDs: proposed.blockIDs,
                    insertAfterBlockID: proposed.insertAfterBlockID
                )
            }
            guard !relocation.blockIDs.isEmpty,
                  relocation.blockIDs.allSatisfy({
                      indexByID[$0] != nil
                          && !relocatedIDs.contains($0)
                  }),
                  relocation.blockIDs.contains(where: { !excludedBlockIDs.contains($0) }),
                  Set(relocation.blockIDs).count == relocation.blockIDs.count,
                  let anchorIndex = indexByID[relocation.insertAfterBlockID],
                  !excludedBlockIDs.contains(relocation.insertAfterBlockID),
                  !relocation.blockIDs.contains(relocation.insertAfterBlockID) else {
                continue
            }
            let indices = relocation.blockIDs.compactMap { indexByID[$0] }
            guard indices == indices.sorted(),
                  zip(indices, indices.dropFirst()).allSatisfy({ $0.1 == $0.0 + 1 }),
                  let finalMovedIndex = indices.last,
                  anchorIndex > finalMovedIndex else { continue }
            candidates.append(relocation)
            relocatedIDs.formUnion(relocation.blockIDs)
        }
        return candidates
            .filter { !relocatedIDs.contains($0.insertAfterBlockID) }
            .sorted {
                let leftStart = indexByID[$0.blockIDs[0]] ?? .max
                let rightStart = indexByID[$1.blockIDs[0]] ?? .max
                if leftStart != rightStart { return leftStart < rightStart }
                return $0.blockIDs.count > $1.blockIDs.count
            }
    }

    private nonisolated static func isCanonicalBoxHeading(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lowercased().hasPrefix("box ") else { return false }
        var remainder = normalized.dropFirst(4)
        guard remainder.first?.isNumber == true else { return false }
        while remainder.first?.isNumber == true { remainder.removeFirst() }
        remainder = remainder.drop(while: { $0.isWhitespace })
        guard let separator = remainder.first else { return false }
        return "|:—–-".contains(separator)
    }

    private nonisolated static func range(
        of needle: String,
        occurrence: Int,
        in text: String
    ) -> Range<String.Index>? {
        var searchStart = text.startIndex
        for current in 1...occurrence {
            guard let range = text.range(of: needle, range: searchStart..<text.endIndex) else {
                return nil
            }
            if current == occurrence { return range }
            searchStart = range.upperBound
        }
        return nil
    }

    /// Decide whether an attached PDF title candidate is strong evidence of the wrong selected paper.
    func shouldWarnForPDFAttachment(
        source: AIUsageSource,
        selectedPaperTitle: String,
        pdfTitleCandidate: String,
        config: AITaskConfig
    ) async throws -> Bool {
        let system = AITask.paperAttachmentCheck.effectivePrompt ?? Prompts.paperAttachmentCheck
        let user = """
        Selected paper title:
        \(selectedPaperTitle)

        PDF title candidate:
        \(pdfTitleCandidate)
        """

        // This classifier returns one word. Do not apply the shared 4,096-token
        // reasoning floor: OpenRouter reserves affordability against max_tokens
        // and can reject this tiny check when the account could comfortably fund
        // the answer but not that unnecessarily large ceiling.
        let response = try await call(
            config: config,
            system: system,
            user: user,
            maxTokens: 512,
            temperature: 0.0,
            allowsReasoningInflation: false,
            sourceTitle: source.title,
            subjectID: source.id,
            subjectType: source.type,
            activityID: AIUsageAttribution.activityID ?? UUID().uuidString
        )
        let decision = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if decision == "WARN" { return true }
        if decision == "ALLOW" { return false }
        throw AIError.invalidResponse
    }
}
