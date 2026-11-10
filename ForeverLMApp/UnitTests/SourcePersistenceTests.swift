import Testing
import CloudKit
import Foundation
import SQLite3
@testable import ForeverLM

/// Creates an in-memory KnowledgeStore for unit testing.
private func makeInMemoryStore() throws -> KnowledgeStore {
    try KnowledgeStore(inMemory: true)
}

/// Helper: create a StudioArticle with sensible defaults for testing.
private func makeArticle(url: String, title: String? = nil) -> StudioArticle {
    var article = StudioArticle(url: url, title: title)
    article.normalizedURL = URLNormalizer.normalize(url)
    return article
}

func installPreparedPaperText(
    _ text: String = "Durable canonical paper text.",
    on paper: inout StudioArticle
) {
    let hash = PaperContentPreparationService.sha256(text)
    paper.installPreparedPaperContent(
        raw: text,
        clean: text,
        metadata: PaperContentPreparationMetadata(
            cleanerVersion: PaperContentPreparationMetadata.currentVersion,
            rawSHA256: hash,
            cleanSHA256: hash,
            preparedAt: Date()
        )
    )
}

@Suite("Source Persistence")
struct SourcePersistenceTests {

    @Test("Paper figure index persists portable page relationships and invalidates with the PDF")
    func paperFigureIndexLifecycle() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/visual-paper",
            title: "Visual Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        paper.localFilePath = "Papers/visual-paper.pdf"
        installPreparedPaperText(on: &paper)
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)
        paper.state = .ready
        try store.saveSource(paper)

        #expect(try store.paperFigureIndexQueueCount() == 1)
        let candidate = try #require(try store.nextPaperFigureIndexCandidate())
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.pdfPath == "Papers/visual-paper.pdf")

        let figure = PaperFigureRecord(
            id: PaperFigureIndexContract.figureID(
                sourceID: paper.id,
                figureLabel: "Figure 2",
                pageIndex: 2
            ),
            sourceID: paper.id,
            figureLabel: "Figure 2",
            pageIndex: 2,
            caption: "Figure 2 | The treatment arm separates from control.",
            analysis: nil
        )
        try store.replacePaperFigureIndex(
            sourceID: paper.id,
            pdfPath: candidate.pdfPath,
            pageCount: 12,
            figures: [figure],
            indexVersion: candidate.targetVersion
        )

        #expect(try store.paperFigureIndexQueueCount() == 0)
        let stored = try #require(try store.paperFigures(sourceID: paper.id).first)
        #expect(stored == figure)
        #expect(stored.pageNumber == 3)

        // Metadata-only saves keep a current derived index. Re-extracting the
        // PDF body is explicit evidence that the same path may hold new bytes.
        var renamed = try #require(try store.loadSources().first { $0.id == paper.id })
        renamed.title = "Visual Paper (renamed)"
        try store.saveSource(renamed)
        #expect(try store.paperFigureIndexQueueCount() == 0)

        installPreparedPaperText("Fresh extraction from a replaced PDF.", on: &renamed)
        try store.saveSource(renamed)
        #expect(try store.paperFigureIndexQueueCount() == 1)

        try store.updateSourceType(paper.id, to: StudioSourceType.article.rawValue)
        #expect(try store.paperFigureIndexQueueCount() == 0)
        #expect(try store.paperFigures(sourceID: paper.id).isEmpty)
    }

    @Test("A figure index is current only for the PDF the paper has now")
    func paperFigureIndexCurrencyFollowsThePDF() throws {
        // A supplement joined to a paper moves it to a new file. Its index,
        // built from the old file, no longer names every figure, so the
        // figure tools must read it again rather than take it as stored.
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/supplemented-paper",
            title: "Supplemented Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        paper.localFilePath = "Papers/supplemented-paper.pdf"
        installPreparedPaperText(on: &paper)
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)
        paper.state = .ready
        try store.saveSource(paper)
        let candidate = try #require(try store.nextPaperFigureIndexCandidate())
        try store.replacePaperFigureIndex(
            sourceID: paper.id,
            pdfPath: candidate.pdfPath,
            pageCount: 8,
            figures: [],
            indexVersion: PaperFigureIndexContract.currentVersion
        )
        #expect(try store.paperFigureIndexIsCurrent(sourceID: paper.id))

        var joined = try #require(try store.loadSources().first { $0.id == paper.id })
        joined.localFilePath = "Papers/supplemented-paper-with-supplement.pdf"
        try store.saveSource(joined)
        #expect(try !store.paperFigureIndexIsCurrent(sourceID: paper.id))
    }

    @Test("Paper figure preparation selects only the explicitly requested source")
    func paperFigurePreparationSelectsRequestedSource() throws {
        let store = try makeInMemoryStore()
        var first = StudioArticle(
            url: "https://example.com/first-visual-paper",
            title: "First Visual Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        first.localFilePath = "Papers/first-visual-paper.pdf"
        installPreparedPaperText(on: &first)
        let completedFirstMetadata = first.completePaperMetadataExtractionAfterLLM()
        #expect(completedFirstMetadata)
        first.state = .ready
        try store.saveSource(first)

        var requested = StudioArticle(
            url: "https://example.com/requested-visual-paper",
            title: "Requested Visual Paper",
            sourceType: .paper,
            author: "Grace Researcher",
            journal: "Science",
            publishedYear: "2025"
        )
        requested.localFilePath = "Papers/requested-visual-paper.pdf"
        installPreparedPaperText(on: &requested)
        let completedRequestedMetadata = requested.completePaperMetadataExtractionAfterLLM()
        #expect(completedRequestedMetadata)
        requested.state = .ready
        try store.saveSource(requested)

        #expect(try store.paperFigureIndexQueueCount() == 2)
        let oldest = try #require(try store.nextPaperFigureIndexCandidate())
        #expect(oldest.sourceID == first.id)

        let selected = try #require(
            try store.paperFigureIndexCandidate(sourceID: requested.id)
        )
        #expect(selected.sourceID == requested.id)
        #expect(selected.pdfPath == "Papers/requested-visual-paper.pdf")
        #expect(try store.paperFigureIndexQueueCount() == 2)
    }

    @Test("Ready sources require durable readable text")
    func readySourcesRequireDurableReadableText() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/textless-paper",
            title: "Textless Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        let completedMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(completedMetadata)

        #expect(throws: (any Error).self) {
            try store.saveSource(paper)
        }

        let raw = "Textless Paper\n\nA durable result."
        paper.installPreparedPaperContent(
            raw: raw,
            clean: raw,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(raw),
                preparedAt: Date()
            )
        )
        try store.saveSource(paper)
        #expect(try store.loadSourceContent(paper.id) == raw)
    }

    @Test("A review request, not a save, prepares and persists a versioned guide")
    func reviewRequestPreparesAndPersistsReviewGuide() throws {
        let store = try makeInMemoryStore()
        let raw = "Publisher header\n\nCanonical source text about a causal mechanism.\n\nReferences\nNoise"
        let clean = "Canonical source text about a causal mechanism."
        var paper = StudioArticle(
            url: "https://example.com/review-paper",
            title: "Review Guide Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        // Saving a reviewable paper schedules nothing on its own.
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        #expect(try store.sourceReviewGuideCandidate(sourceID: paper.id) == nil)

        // A review starting is what creates the work.
        try store.ensureSourceReviewGuidePreparation(sourceID: paper.id)
        #expect(try store.sourceReviewGuideQueueCount() == 1)
        let candidate = try #require(try store.sourceReviewGuideCandidate(sourceID: paper.id))
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.title == paper.title)
        #expect(candidate.content == clean)
        #expect(!candidate.content.contains("Publisher header"))
        #expect(!candidate.content.contains("References"))
        #expect(try store.sourceReviewGuideCandidate(sourceID: paper.id)?.sourceID == paper.id)

        try store.applySourceReviewGuide(
            candidate: candidate,
            guide: "Question: Explain the mechanism.\nStrong answer: Cause produces effect."
        )

        let prepared = try #require(try store.loadSourceReviewGuide(paper.id))
        #expect(prepared.generatorVersion == SourceReviewGuide.currentVersion)
        #expect(prepared.sourceSHA256 == candidate.sourceSHA256)
        #expect(prepared.guide.contains("Strong answer"))
        #expect(try store.sourceReviewGuideQueueCount() == 0)

        // Metadata-only saves retain the prepared guide; a canonical text change
        // invalidates it, and the replacement waits for the next review request.
        try store.saveSource(paper)
        #expect(try store.loadSourceReviewGuide(paper.id) != nil)
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        let changedRaw = "Header\n\nChanged canonical source text.\n\nFooter"
        let changedClean = "Changed canonical source text."
        paper.installPreparedPaperContent(
            raw: changedRaw,
            clean: changedClean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(changedRaw),
                cleanSHA256: PaperContentPreparationService.sha256(changedClean),
                preparedAt: Date()
            )
        )
        try store.saveSource(paper)
        #expect(try store.loadSourceReviewGuide(paper.id) == nil)
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        try store.ensureSourceReviewGuidePreparation(sourceID: paper.id)
        #expect(try store.sourceReviewGuideCandidate(sourceID: paper.id)?.content == changedClean)
    }

    @Test("A guide from an earlier generator keeps its paper out of the preparation queue")
    func earlierGeneratorGuideIsNotRegenerated() throws {
        let store = try makeInMemoryStore()
        let raw = "Publisher header\n\nCanonical text about an earlier generator.\n\nReferences\nNoise"
        let clean = "Canonical text about an earlier generator."
        var paper = StudioArticle(
            url: "https://example.com/earlier-generator-paper",
            title: "Earlier Generator Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        // Stand in for a guide generated before the current version shipped.
        try store.execForTesting("""
            INSERT INTO source_review_guides
                (source_id, source_sha256, guide, generator_version, generated_at)
            VALUES ('\(paper.id)', '\(PaperContentPreparationService.sha256(clean))',
                    'Earlier generator questions', \(SourceReviewGuide.currentVersion - 1), 1)
        """)

        // A review request must not treat the version gap as missing work.
        try store.ensureSourceReviewGuidePreparation(sourceID: paper.id)
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        let readable = try #require(try store.loadSourceReviewGuide(paper.id))
        #expect(readable.guide == "Earlier generator questions")
        #expect(readable.generatorVersion == SourceReviewGuide.currentVersion - 1)
    }

    @Test("A cleanup that re-read the paper's PDF commits the complete extraction as its raw text")
    func cleanupCommitsFreshPDFExtraction() throws {
        let store = try makeInMemoryStore()
        // An older build stopped PDF extraction at 50,000 characters, mid-word.
        let capped = "Useful mechanism and resu"
        var paper = StudioArticle(
            url: "https://example.com/capped-paper",
            title: "Capped Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Cell",
            publishedYear: "2026"
        )
        paper.localFilePath = "Papers/capped-paper.pdf"
        paper.installPreparedPaperContent(
            raw: capped,
            clean: capped,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(capped),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        let stored = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(stored.localFilePath == "Papers/capped-paper.pdf")
        #expect(stored.storedTextSHA256 == stored.rawSHA256)

        let complete = "Useful mechanism and result.\nSTAR★METHODS\nKEY RESOURCES TABLE\nNocodazole MedChemExpress Cat#HY-13520"
        let candidate = stored.replacingRaw(with: complete)
        #expect(candidate.raw == complete)
        #expect(candidate.rawSHA256 == PaperContentPreparationService.sha256(complete))
        #expect(candidate.storedTextSHA256 == stored.rawSHA256)
        #expect(candidate.localFilePath == stored.localFilePath)

        let prepared = PreparedPaperContent(
            raw: candidate.raw,
            clean: complete,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: candidate.rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(complete),
                preparedAt: Date()
            )
        )

        // A change to the stored row while the cleanup ran still aborts the write.
        var edited = paper
        let editedRaw = "Useful mechanism and resu (edited)"
        edited.installPreparedPaperContent(
            raw: editedRaw,
            clean: editedRaw,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(editedRaw),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        try store.saveSource(edited)
        #expect(throws: (any Error).self) {
            try store.applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)
        }
        #expect(try store.loadPaperContentPreparation(paper.id)?.raw == editedRaw)

        let restaged = try #require(try store.nextCanonicalContentCleanupCandidate())
        let fresh = restaged.replacingRaw(with: complete)
        try store.applyCanonicalContentCleanup(candidate: fresh, prepared: prepared)

        #expect(try store.loadPaperContentPreparation(paper.id)?.raw == complete)
        #expect(try store.loadSourceContent(paper.id) == complete)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    /// The Illustrated AlphaFold (2026-10-06): its raw text stopped mid-word at
    /// the retired 50,000-character cap while `article.html` held the rest, and
    /// cleaner v19 had cleaned the prefix again.
    @Test("An article cleanup cleans its archived page's complete text when the stored text stops short of it")
    func articleCleanupCompletesCappedTextFromArchivedPage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivedArticleCompletion_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageURL = directory.appendingPathComponent("article.html")
        let paragraphs = (1...12).map { "<p>Paragraph \($0) explains step \($0) of the architecture in plain words for the reader.</p>" }
        let pageHTML = "<html><body><h1>The Illustrated Model</h1>" + paragraphs.joined()
            + "<h2>Discussion</h2><p>The discussion closes the article with what the model leaves open.</p></body></html>"
        try pageHTML.write(to: pageURL, atomically: true, encoding: .utf8)
        let complete = SourceService.readableTextFromHTML(pageHTML)
        // An older build kept only the first characters, cut mid-word.
        let cut = try #require(complete.range(of: "Paragraph 4 expl"))
        let capped = String(complete[..<cut.upperBound])

        let store = try makeInMemoryStore()
        var article = StudioArticle(
            url: "https://example.com/the-illustrated-model",
            title: "The Illustrated Model",
            sourceType: .article
        )
        article.localFilePath = pageURL.path
        article.installPreparedArticleContent(
            raw: capped,
            clean: capped,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(capped),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        article.state = .ready
        try store.saveSource(article)

        let stored = try #require(try store.nextCanonicalContentCleanupCandidate())
        #expect(stored.raw == capped)
        #expect(stored.localFilePath == pageURL.path)

        let working = await CanonicalContentCleanupService.withCompleteExtraction(stored)
        #expect(working.raw == complete)
        #expect(working.raw.hasSuffix("what the model leaves open."))
        #expect(working.storedTextSHA256 == stored.rawSHA256)

        let prepared = PreparedPaperContent(
            raw: working.raw,
            clean: working.raw,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: working.rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(working.raw),
                preparedAt: Date()
            )
        )
        try store.applyCanonicalContentCleanup(candidate: working, prepared: prepared)

        #expect(try store.loadArticleContentPreparation(article.id)?.raw == complete)
        #expect(try store.loadSourceContent(article.id) == complete)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)
    }

    @Test("An article cleanup keeps stored text that is whole, or fuller than its archived page")
    func articleCleanupKeepsWholeStoredText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivedArticleCompletion_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageURL = directory.appendingPathComponent("article.html")
        let paragraphs = (1...12).map { "Paragraph \($0) explains step \($0) of the argument in plain words." }
        // The page now shows a paywall's preview; the stored text came from an
        // archived copy of the whole article.
        let previewHTML = "<html><body>" + paragraphs.prefix(3).map { "<p>\($0)</p>" }.joined()
            + "<p>" + Array(repeating: "Subscribe to keep reading this post and get access to the full archive.", count: 6).joined(separator: " ")
            + "</p></body></html>"
        try previewHTML.write(to: pageURL, atomically: true, encoding: .utf8)
        let whole = paragraphs.joined(separator: "\n\n")

        for stored in [whole, SourceService.readableTextFromHTML(previewHTML)] {
            let candidate = CanonicalContentCleanupCandidate(
                sourceID: UUID().uuidString,
                title: "The Argument",
                sourceType: .article,
                raw: stored,
                rawSHA256: PaperContentPreparationService.sha256(stored),
                isPendingIngestion: false,
                localFilePath: pageURL.path
            )
            let working = await CanonicalContentCleanupService.withCompleteExtraction(candidate)
            #expect(working.raw == stored)
            #expect(working.storedRawSHA256 == nil)
        }
    }

    @Test("Stored article text stops short of its page only when the page continues the same text")
    func storedArticleTextStopsShortOnlyOfItsContinuation() {
        let words = (1...300).map { "word\($0)" }
        let page = words.joined(separator: " ") + "."
        let stopsShort = CanonicalContentCleanupService.storedArticleText(_:stopsShortOf:)

        // A prefix cut mid-word, as the retired cap cut it.
        #expect(stopsShort(words[..<150].joined(separator: " ") + " word15", page))
        #expect(!stopsShort(page, page))
        // A page that only adds a sign-off after the same last words.
        #expect(!stopsShort(page, page + " Thanks for reading, share this post with a friend."))
        // An older extraction's list items and superscripts line up with today's.
        let older = "Tokens\nPDE Predicted distance error between tokens, capturing the accuracy of predicted difference"
        let newer = "## Tokens\n\n- PDE Predicted distance error between tokens, capturing the accuracy of predicted differences^(3) between all pairs of tokens.\n"
            + words[..<60].joined(separator: " ")
        #expect(stopsShort(older, newer))
        // The page's next word has to continue the stored text's last one.
        #expect(!stopsShort(older, newer.replacingOccurrences(of: "differences", with: "outcomes")))
        // A page telling the text in another order (Research Square): the
        // stored text's closing notice recurs in the page, but above nearly
        // all of what the stored text says.
        let body = words.joined(separator: " ")
        let notice = "Journal Publication published 16 Mar 2026 Read the published version in Nature Communications Version 1 posted You are reading this latest preprint version"
        #expect(!stopsShort(body + "\n" + notice, "Download PDF " + notice + "\n" + body))
    }

    // MARK: - Text past a U+0000 (schema 134)

    /// A paper as PDFKit hands it back when a glyph has no Unicode mapping:
    /// U+0000 where a minus sign or an "fi" ligature was printed. On
    /// 2026-09-23 the text before the first one was all SQLite kept.
    private static let extractionWithUnmappedGlyphs =
        "Abstract.\u{000C}A t-statistic t=\u{0000}43.49 confirms the scienti\u{0000}c claim.\nMethods and results follow."

    private static func paperForTextFidelity(url: String) -> StudioArticle {
        StudioArticle(
            url: url,
            title: "Text Fidelity Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "bioRxiv",
            publishedYear: "2024"
        )
    }

    @Test("Text holding U+0000 is stored and read back whole, so its hash still names it")
    func textPastNULRoundTripsThroughStorage() throws {
        let store = try makeInMemoryStore()
        let raw = Self.extractionWithUnmappedGlyphs
        let clean = "A t-statistic t=\u{0000}43.49 confirms the scienti\u{0000}c claim.\nMethods and results follow."
        var paper = Self.paperForTextFidelity(url: "https://example.com/nul-round-trip")
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        let paperMetadataCompleted = paper.completePaperMetadataExtractionAfterLLM()
        #expect(paperMetadataCompleted)
        try store.saveSource(paper)

        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.raw == raw)
        #expect(PaperContentPreparationService.sha256(preparation.raw) == preparation.metadata.rawSHA256)
        let stored = try #require(try store.loadSourceContent(paper.id))
        #expect(stored == clean)
        #expect(PaperContentPreparationService.sha256(stored) == preparation.metadata.cleanSHA256)
        #expect(stored.hasSuffix("Methods and results follow."), "nothing after the first U+0000 is lost")
        var byteLength = 0
        try store.query("SELECT length(CAST(raw_content AS BLOB)) FROM paper_content_preparations") { stmt in
            byteLength = Int(sqlite3_column_int64(stmt, 0))
        }
        #expect(byteLength == raw.utf8.count)
    }

    @Test("A cleanup commit keeps a fresh PDF extraction past its first U+0000, and word count agrees with the stored text")
    func cleanupCommitKeepsExtractionPastNUL() throws {
        let store = try makeInMemoryStore()
        // What the stored row held: the extraction cut at its first U+0000.
        let stub = "Abstract.\u{000C}A t-statistic t="
        var paper = Self.paperForTextFidelity(url: "https://example.com/nul-cleanup")
        paper.localFilePath = "Papers/nul-cleanup.pdf"
        paper.installPreparedPaperContent(
            raw: stub,
            clean: stub,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(stub),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        let paperMetadataCompleted = paper.completePaperMetadataExtractionAfterLLM()
        #expect(paperMetadataCompleted)
        try store.saveSource(paper)

        let stored = try #require(try store.nextCanonicalContentCleanupCandidate())
        let complete = Self.extractionWithUnmappedGlyphs
        let candidate = stored.replacingRaw(with: complete)
        let clean = String(complete.dropFirst("Abstract.\u{000C}".count))
        let prepared = PreparedPaperContent(
            raw: candidate.raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: candidate.rawSHA256,
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        try store.applyCanonicalContentCleanup(candidate: candidate, prepared: prepared)

        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.raw == complete)
        #expect(PaperContentPreparationService.sha256(preparation.raw) == preparation.metadata.rawSHA256)
        let storedClean = try #require(try store.loadSourceContent(paper.id))
        #expect(storedClean == clean)
        let reloaded = try #require(try store.loadSources().first { $0.id == paper.id })
        #expect(reloaded.wordCount == storedClean.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
    }

    @Test("A preparation whose hash does not name its raw text is refused, and nothing is written")
    func mismatchedPreparationIsRefused() throws {
        let store = try makeInMemoryStore()
        let full = Self.extractionWithUnmappedGlyphs
        var paper = Self.paperForTextFidelity(url: "https://example.com/nul-mismatch")
        paper.installPreparedPaperContent(
            raw: "Abstract.",
            clean: "Abstract.",
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(full),
                cleanSHA256: PaperContentPreparationService.sha256("Abstract."),
                preparedAt: Date()
            )
        )
        let paperMetadataCompleted = paper.completePaperMetadataExtractionAfterLLM()
        #expect(paperMetadataCompleted)
        #expect(throws: KnowledgeStoreError.self) { try store.saveSource(paper) }
        #expect(try store.loadPaperContentPreparation(paper.id) == nil)
        #expect(try store.loadSourceContent(paper.id) == nil)
    }

    @Test("PDF extraction marks an unmapped glyph U+FFFD instead of emitting U+0000")
    func unmappedGlyphBecomesReplacementCharacter() {
        #expect(
            PDFTextExtractor.markingUnmappedGlyphs("t=\u{0000}43.49 scienti\u{0000}c")
                == "t=\u{FFFD}43.49 scienti\u{FFFD}c"
        )
        let plain = "No unmapped glyphs here.\u{000C}Page two."
        #expect(PDFTextExtractor.markingUnmappedGlyphs(plain) == plain)
    }

    @Test("Paper review waits for cleanup and receives only the cleaned derivative")
    func paperReviewWaitsForCanonicalCleanup() throws {
        let store = try makeInMemoryStore()
        let raw = "Publisher footer\n\nUseful mechanism and result.\n\nReferences\nCitation noise"
        var paper = StudioArticle(
            url: "https://example.com/pending-cleanup-paper",
            title: "Pending Cleanup Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        // Model a legacy ready paper whose raw extraction is still its readable
        // snapshot. The version-0 preparation is what durably schedules cleanup;
        // current writes may not claim a paper is ready with unattested text.
        paper.installPreparedPaperContent(
            raw: raw,
            clean: raw,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: 0,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: nil,
                preparedAt: nil
            )
        )
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)
        try store.saveSource(paper)

        #expect(try store.canonicalContentCleanupQueueCount() == 1)
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        #expect(try store.sourceReviewGuideCandidate(sourceID: paper.id) == nil)

        let cleanup = try #require(try store.nextCanonicalContentCleanupCandidate())
        let clean = "Useful mechanism and result."
        try store.applyCanonicalContentCleanup(
            candidate: cleanup,
            prepared: PreparedPaperContent(
                raw: cleanup.raw,
                clean: clean,
                metadata: PaperContentPreparationMetadata(
                    cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                    rawSHA256: cleanup.rawSHA256,
                    cleanSHA256: PaperContentPreparationService.sha256(clean),
                    preparedAt: Date()
                )
            )
        )

        #expect(try store.canonicalContentCleanupQueueCount() == 0)
        // Cleanup finishing still schedules nothing; the cleaned derivative is
        // only prepared once a review asks for it.
        #expect(try store.sourceReviewGuideQueueCount() == 0)
        try store.ensureSourceReviewGuidePreparation(sourceID: paper.id)
        let review = try #require(try store.sourceReviewGuideCandidate(sourceID: paper.id))
        #expect(review.content == clean)
        #expect(!review.content.contains("Publisher footer"))
        #expect(!review.content.contains("References"))
    }

    @Test("insertSourceIfNew inserts a new source")
    func testInsertSourceIfNewInsertsNewSource() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/post-1", title: "Post 1")
        let inserted = try store.insertSourceIfNew(&article)
        #expect(inserted)
        let all = try store.loadSources()
        #expect(all.count == 1)
        #expect(all[0].title == "Post 1")
    }

    @Test("Article read status round-trips through SQLite")
    func articleReadStatusRoundTrips() throws {
        let store = try makeInMemoryStore()
        var article = makeArticle(url: "https://example.com/read-test", title: "Read Test")
        article.sourceType = .article
        try store.saveSource(article)

        let readAt = Date(timeIntervalSinceReferenceDate: 780_000_000)
        try store.updateSourceReadAt(sourceID: article.id, readAt: readAt)

        let loaded = try store.loadSources()
        #expect(loaded.count == 1)
        #expect(loaded[0].readAt == readAt)
        #expect(loaded[0].isRead)

        try store.updateSourceReadAt(sourceID: article.id, readAt: nil)
        let cleared = try store.loadSources()
        #expect(cleared[0].readAt == nil)
        #expect(!cleared[0].isRead)
    }

    @Test("Hidden source attribute round-trips for every source type")
    func hiddenSourceRoundTripsForEverySourceType() throws {
        let store = try makeInMemoryStore()
        let sourceTypes: [StudioSourceType] = [
            .article, .paper, .podcast, .book, .course, .meeting, .video, .xPost, .manual, .unclassified
        ]

        for sourceType in sourceTypes {
            let article = StudioArticle(
                url: "https://example.com/\(sourceType.rawValue)",
                title: "\(sourceType.rawValue) source",
                sourceType: sourceType
            )
            try store.saveSource(article)
            try store.setSourceHidden(article.id, hidden: true)
        }

        let loaded = try store.loadSources()
        let hiddenTypes = Set(loaded.filter(\.isHidden).map(\.sourceType))

        #expect(hiddenTypes == Set(sourceTypes))
    }

    @Test("Saving source metadata preserves existing hidden source state")
    func saveSourcePreservesExistingHiddenState() throws {
        let store = try makeInMemoryStore()
        let article = makeArticle(url: "https://example.com/hidden", title: "Hidden")

        try store.saveSource(article)
        try store.setSourceHidden(article.id, hidden: true)
        try store.saveSource(article)

        let loaded = try store.loadSources()
        #expect(loaded.first?.isHidden == true)
    }

    @Test("Video playlist metadata persists")
    func videoPlaylistMetadataPersistsAndQueuesSync() throws {
        let store = try makeInMemoryStore()
        let metadata = VideoPlaylistMetadata(
            title: "Quantum Biology Conference",
            playlistURL: "https://www.youtube.com/playlist?list=PL-quantum-bio",
            lastRefreshedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            isHidden: true
        )

        try store.saveVideoPlaylistGroup(id: "playlist-1", metadata: metadata)

        #expect(try store.loadVideoPlaylistGroups()["playlist-1"] == metadata)
    }

    @Test("Unchanged YouTube feed metadata does not queue source sync")
    func unchangedYouTubeFeedMetadataDoesNotQueueSync() throws {
        let store = try makeInMemoryStore()
        let playlistID = "liked-feed"
        try store.saveVideoPlaylistGroup(
            id: playlistID,
            metadata: VideoPlaylistMetadata(
                title: "Liked videos",
                playlistURL: YouTubeService.likedVideosPlaylistURL
            )
        )
        let likedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let publishedAt = Date(timeIntervalSinceReferenceDate: 500)
        var video = StudioArticle(
            url: "https://www.youtube.com/watch?v=unchanged",
            title: "Unchanged",
            sourceType: .video,
            discoveryOrigin: .youtubePlaylist,
            parentGroup: playlistID
        )
        video.courseSortIndex = 0
        video.likedAt = likedAt
        video.videoPublishedAt = publishedAt
        try store.saveSource(video)

        #expect(try !store.updateCourseSortIndex(video.id, 0))
        #expect(try !store.updateVideoFeedDates(
            sourceID: video.id,
            likedAt: likedAt,
            videoPublishedAt: publishedAt
        ))

        #expect(try store.updateCourseSortIndex(video.id, 1))
        #expect(try store.updateVideoFeedDates(
            sourceID: video.id,
            likedAt: likedAt.addingTimeInterval(1),
            videoPublishedAt: publishedAt
        ))
    }

    @Test("AI-extracted paper metadata persists and queues source sync")
    func aiExtractedPaperMetadataPersistsAndQueuesSourceSync() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "Papers/example.pdf",
            title: "Unresolved Paper",
            sourceType: .paper,
            localFilePath: "Papers/example.pdf"
        )

        try store.saveSource(paper)

        paper.title = "Attention Is All You Need"
        paper.author = "Ashish Vaswani et al."
        paper.journal = "NeurIPS"
        paper.publishedYear = "2017"
        paper.doi = "10.5555/example"
        installPreparedPaperText(on: &paper)
        let attested = paper.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        try store.saveSource(paper)

        let loaded = try store.loadSources()
        let saved = try #require(loaded.first(where: { $0.id == paper.id }))

        #expect(saved.title == "Attention Is All You Need")
        #expect(saved.author == "Ashish Vaswani et al.")
        #expect(saved.journal == "NeurIPS")
        #expect(saved.publishedYear == "2017")
        #expect(saved.doi == "10.5555/example")
        #expect(saved.paperIngestionMethod == .llm)
        #expect(saved.isPaperReadyForListenPreparation)
        #expect(!saved.hasSuccessfulPaperIngestion)
    }

    @Test("Ready paper persistence requires a durable LLM attestation")
    func readyPaperPersistenceRequiresLLMAttestation() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "Papers/unattested.pdf",
            title: "Unattested Paper",
            sourceType: .paper,
            localFilePath: "Papers/unattested.pdf",
            author: "A. Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        // Complete-looking metadata is not proof that the mandatory model call ran.
        paper.state = .ready

        #expect(throws: (any Error).self) {
            try store.saveSource(paper)
        }
        #expect(try store.loadSources().isEmpty)
    }

    @Test("Paper is fully prepared only after durable Listen content commits")
    func paperFullReadinessRequiresListenableContent() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "Papers/listen-ready.pdf",
            title: "Listen-ready Paper",
            sourceType: .paper,
            localFilePath: "Papers/listen-ready.pdf",
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        let canonical = "Durable canonical paper text."
        installPreparedPaperText(canonical, on: &paper)
        let metadataAttested = paper.completePaperMetadataExtractionAfterLLM()
        #expect(metadataAttested)
        try store.saveSource(paper)

        var loaded = try #require(try store.loadSources().first)
        #expect(loaded.isPaperReadyForListenPreparation)
        #expect(!loaded.hasSuccessfulPaperIngestion)

        let sourceHash = PaperContentPreparationService.sha256(canonical)
        try store.applySourceListenableContent(
            candidate: SourceListenableContentCandidate(
                sourceID: paper.id,
                title: paper.title,
                sourceType: .paper,
                canonicalText: canonical,
                sourceSHA256: sourceHash
            ),
            text: "Durable narration text.",
            preparationSignature: PaperNarrationFilter.preparationContractPrefix + "test"
        )

        loaded = try #require(try store.loadSources().first)
        #expect(loaded.hasSuccessfulPaperIngestion)
    }

    /// Listen narrates the source's text, so a bibliographic gate must not
    /// withhold it. Unsigned editorials fail that gate permanently, and gating
    /// narration on `.ready` left iOS listing them, offering Listen, and only
    /// then reporting that the source was still preparing.
    @Test("A failed metadata gate still queues Listen preparation")
    func unattestedPaperQueuesListenableContentPreparation() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var paper = StudioArticle(
            url: "Papers/unsigned-editorial.pdf",
            title: "Anti-aging interventions need less hype",
            sourceType: .paper,
            localFilePath: "Papers/unsigned-editorial.pdf",
            journal: "Nature Medicine",
            publishedYear: "2026"
        )
        let canonical = "An unsigned editorial with a full body of readable text."
        installPreparedPaperText(canonical, on: &paper)
        paper.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["author"])
        )
        try store.saveSource(paper)

        let candidate = try #require(try store.sourceListenableContentCandidates(limit: 10).first)
        #expect(candidate.sourceID == paper.id)
        #expect(candidate.canonicalText == canonical)

        let loaded = try #require(try store.loadSources().first)
        // The metadata failure is untouched: the paper still needs attention.
        #expect(loaded.state == .error)
        #expect(!loaded.hasSuccessfulPaperIngestion)
    }

    /// The content handoff is discarded from memory after every successful
    /// ingest, so a later save legitimately carries no text. Treating that as
    /// evidence the source lost its text dropped the queued narration — and for
    /// a paper that re-enters metadata extraction on every launch, nothing ever
    /// put it back.
    @Test("A save without in-memory text keeps queued Listen preparation")
    func savingWithoutInMemoryTextKeepsQueuedListenablePreparation() throws {
        let store = try makeInMemoryStore()
        // Listen is queued ahead of a listener only for automatic-audio kinds.
        store.automaticAudioSourceTypes = { ["paper"] }
        var paper = StudioArticle(
            url: "Papers/unsigned-editorial.pdf",
            title: "Anti-aging interventions need less hype",
            sourceType: .paper,
            localFilePath: "Papers/unsigned-editorial.pdf",
            journal: "Nature Medicine",
            publishedYear: "2026"
        )
        installPreparedPaperText("Canonical text that outlives the handoff.", on: &paper)
        paper.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["author"])
        )
        try store.saveSource(paper)
        #expect(try store.sourceListenableContentQueueCount() == 1)

        paper.discardPersistedPaperContentFromMemory()
        // A metadata retry parks the paper back in `queued` before the model runs.
        paper.prepareForPaperMetadataExtraction()
        try store.saveSource(paper)
        #expect(try store.sourceListenableContentQueueCount() == 1)

        // Archiving is what genuinely retires the work.
        paper.status = .archived
        try store.saveSource(paper)
        #expect(try store.sourceListenableContentQueueCount() == 0)
    }

    @Test("Paper persistence trims authors without parsing human-written names")
    func paperPersistencePreservesAuthorMeaning() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/single-author-paper",
            title: "Single Author Paper",
            sourceType: .paper
        )
        paper.author = "  Samuel I. Gould; samuel i. gould  "

        try store.saveSource(paper)

        let saved = try #require(try store.loadSources().first(where: { $0.id == paper.id }))
        #expect(saved.author == "Samuel I. Gould; samuel i. gould")
    }

    @Test("Queued paper extraction is retained raw but hidden from downstream source content")
    func queuedPaperStagesRawContent() throws {
        let store = try makeInMemoryStore()
        var paper = StudioArticle(
            url: "https://example.com/queued-paper",
            title: "Queued Paper",
            sourceType: .paper
        )
        paper.content = "Publisher header\n\nSubstantive extracted paper text"
        paper.prepareForPaperMetadataExtraction()

        try store.saveSource(paper)

        #expect(try store.loadSourceContent(paper.id) == nil)
        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.raw == paper.content)
        #expect(preparation.metadata.cleanerVersion == 0)
        #expect(preparation.metadata.cleanSHA256 == nil)
    }

    @Test("Ready paper persists clean canonical text and raw extraction separately")
    func preparedPaperPersistsRawAndCleanContent() throws {
        let store = try makeInMemoryStore()
        let raw = "Journal furniture\n\nCanonical Paper\n\nAbstract body\n\nReferences\n1. Noise"
        let clean = "Canonical Paper\n\nAbstract body"
        var paper = StudioArticle(
            url: "https://example.com/prepared-paper",
            title: "Canonical Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature",
            publishedYear: "2026"
        )
        paper.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        // Called outside the macro: `#expect` captures its expression in a
        // closure, which cannot call a mutating member on `paper`.
        let didCompleteMetadata = paper.completePaperMetadataExtractionAfterLLM()
        #expect(didCompleteMetadata)

        try store.saveSource(paper)

        #expect(try store.loadSourceContent(paper.id) == clean)
        let preparation = try #require(try store.loadPaperContentPreparation(paper.id))
        #expect(preparation.raw == raw)
        #expect(preparation.metadata.cleanSHA256 == PaperContentPreparationService.sha256(clean))
    }

    @Test("Ready article persists clean canonical text and raw extraction separately")
    func preparedArticlePersistsRawAndCleanContent() throws {
        let store = try makeInMemoryStore()
        let raw = "Site navigation\n\nCanonical Article\n\nSubstantive body\n\nRelated stories"
        let clean = "Canonical Article\n\nSubstantive body"
        var article = StudioArticle(
            url: "https://example.com/prepared-article",
            title: "Canonical Article",
            sourceType: .article
        )
        article.installPreparedArticleContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        article.state = .ready

        try store.saveSource(article)

        #expect(try store.loadSourceContent(article.id) == clean)
        let preparation = try #require(try store.loadArticleContentPreparation(article.id))
        #expect(preparation.raw == raw)
        #expect(preparation.metadata.cleanerVersion == PaperContentPreparationMetadata.currentVersion)
        #expect(try store.canonicalContentCleanupQueueCount() == 0)

        try store.ensureSourceReviewGuidePreparation(sourceID: article.id)
        let review = try #require(try store.sourceReviewGuideCandidate(sourceID: article.id))
        #expect(review.sourceType == .article)
        #expect(review.title == article.title)
        #expect(review.content == clean)
        #expect(!review.content.contains("Site navigation"))
        #expect(!review.content.contains("Related stories"))
    }
}

