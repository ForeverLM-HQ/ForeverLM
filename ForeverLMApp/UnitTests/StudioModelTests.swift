import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import ForeverLM

@Suite("Chat source cards")
struct ChatSourceCardTests {
    @Test("Paper cards use canonical metadata and reject unsafe artwork URLs")
    func paperMetadata() {
        let article = StudioArticle(
            url: "https://doi.org/10.1000/example",
            title: "Mitochondrial Psychobiology",
            sourceType: .paper,
            artworkURL: "file:///tmp/private-preview.png",
            author: "Martin Picard et al.",
            journal: "Cell Metabolism",
            publishedYear: "2025",
            id: "paper-12345678"
        )

        let card = ChatSourceCard(article: article)

        #expect(card.sourceID == article.id)
        #expect(card.title == "Mitochondrial Psychobiology")
        #expect(card.subtitle == "Paper · Martin Picard et al. · 2025")
        #expect(card.kind == "paper")
        #expect(card.glyph == "P")
        #expect(card.thumbnailURL == nil)
    }

    @Test("Video cards carry safe remote thumbnails")
    func videoArtwork() {
        let article = StudioArticle(
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "A useful lecture",
            sourceType: .video,
            artworkURL: "https://images.example.com/lecture.jpg",
            author: "Example University",
            id: "video-12345678"
        )

        let card = ChatSourceCard(article: article)

        #expect(card.subtitle == "Video · Example University")
        #expect(card.thumbnailURL == "https://images.example.com/lecture.jpg")
    }

    @Test("Book cards show their collection instead of a storage path")
    func bookCollectionMetadata() {
        var article = StudioArticle(
            url: "Books/CellBiology/Chapters/Energies.pdf",
            title: "Energies and Forces",
            sourceType: .book,
            parentGroup: "Cell Biology by the Numbers",
            id: "book-chapter-12345678"
        )
        article.domain = "/Users/example/Library/Mobile Documents/legacy/Books/Energies.pdf"

        let card = ChatSourceCard(article: article)

        #expect(card.subtitle == "Book · Cell Biology by the Numbers")
    }

    @Test("Book cards name the book, never its storage id")
    func bookIdentifierIsReplacedByTitle() {
        let article = StudioArticle(
            url: "Books/AB3BEF19/Chapters/03-glycolysis.xhtml",
            title: "3. Glycolysis",
            sourceType: .book,
            parentGroup: "AB3BEF19-9001-4D49-9FA3-8D95A508A1AE",
            id: "book-chapter-87654321"
        )

        let untitled = ChatSourceCard(article: article)
        #expect(untitled.subtitle == "Book")

        let titled = ChatSourceCard(article: article, collectionTitle: "Lehninger Principles of Biochemistry")
        #expect(titled.subtitle == "Book · Lehninger Principles of Biochemistry")
    }

    @Test("Paper cards embed the first PDF page as their thumbnail")
    func paperPDFThumbnail() async throws {
        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-source-card-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: pdfURL as CFURL))
        let context = try #require(CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.36, green: 0.14, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 72, y: 72, width: 468, height: 648))
        context.endPDFPage()
        context.closePDF()

        let article = StudioArticle(
            url: "https://doi.org/10.1000/local-paper",
            title: "Local paper",
            sourceType: .paper,
            localFilePath: pdfURL.path,
            id: "paper-local-thumbnail"
        )
        let card = await ChatSourceCard.resolved(article: article)
        let prefix = "data:image/jpeg;base64,"
        let thumbnailURL = try #require(card.thumbnailURL)

        #expect(thumbnailURL.hasPrefix(prefix))
        #expect(Data(base64Encoded: String(thumbnailURL.dropFirst(prefix.count))) != nil)
    }

    @Test("Meeting cards embed the icon stored for the session")
    func meetingStoredIconThumbnail() async throws {
        // A meeting icon is a file this app captured or drew under the content
        // root, named by a path rather than a URL. Chat used to accept only
        // `https://` artwork, so every one of those meetings cited an "M".
        let iconURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-source-card-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: iconURL) }

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for x in 0..<64 {
            for y in 0..<64 {
                bitmap.setColor(NSColor(red: 0.2, green: 0.6, blue: 0.7, alpha: 1), atX: x, y: y)
            }
        }
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: iconURL)

        let article = StudioArticle(
            url: "https://drive.google.com/file/d/meeting-recording",
            title: "ZEUS Trial Readout",
            sourceType: .meeting,
            artworkURL: iconURL.path,
            author: "Satvik Dasariraju",
            id: "meeting-stored-icon"
        )

        let card = await ChatSourceCard.resolved(article: article)
        let prefix = "data:image/jpeg;base64,"
        let thumbnailURL = try #require(card.thumbnailURL)

        #expect(thumbnailURL.hasPrefix(prefix))
        #expect(Data(base64Encoded: String(thumbnailURL.dropFirst(prefix.count))) != nil)
    }

    @Test("Artwork that names a URL never becomes a file to read")
    func rejectsFileURLArtwork() async {
        let article = StudioArticle(
            url: "https://example.com/session",
            title: "A meeting",
            sourceType: .meeting,
            artworkURL: "file:///tmp/private-preview.png",
            id: "meeting-file-url-artwork"
        )

        let card = await ChatSourceCard.resolved(article: article)

        #expect(card.thumbnailURL == nil)
    }
}

// MARK: - StudioArticle Properties

@Suite("StudioArticle Properties")
struct StudioArticlePropertyTests {

    @Test("Default init sets expected defaults")
    func defaultInit() {
        let article = StudioArticle(url: "https://example.com/post")
        #expect(article.state == .queued)
        #expect(article.sourceType == .manual)
        #expect(article.title == "https://example.com/post")
        #expect(article.domain == "example.com")
    }

    @Test("Init with title overrides default")
    func initWithTitle() {
        let article = StudioArticle(url: "https://example.com", title: "My Article")
        #expect(article.title == "My Article")
    }

    @Test("Title decodes HTML character references")
    func titleDecodesHTMLCharacterReferences() {
        var article = StudioArticle(
            url: "https://example.com",
            title: "An overview of contempor&#226;nea &amp; mem&#xF3;ria"
        )
        #expect(article.title == "An overview of contempor\u{00E2}nea & mem\u{00F3}ria")

        article.title = "Jo&atilde;o &quot;Magalh&#227;es&quot;"
        #expect(article.title == "Jo\u{00E3}o \"Magalh\u{00E3}es\"")
    }

    @Test("isPDF detects local PDF URLs")
    func isPDF() {
        let pdfArticle = StudioArticle(url: "/Users/me/Documents/paper.pdf")
        #expect(pdfArticle.isPDF)

        let webArticle = StudioArticle(url: "https://example.com/article")
        #expect(!webArticle.isPDF)
    }

    @Test("isPDF detects via localFilePath")
    func isPDFViaLocalPath() {
        var article = StudioArticle(url: "https://arxiv.org/abs/2301.07041", localFilePath: "/path/to/paper.pdf")
        #expect(article.isPDF)

        article = StudioArticle(url: "https://arxiv.org/abs/2301.07041", localFilePath: "/path/to/transcript.txt")
        #expect(!article.isPDF)
    }

    @Test("resolvedPDFPath returns localFilePath when it's a PDF")
    func resolvedPDFPathFromLocal() throws {
        let tempPDF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        let article = StudioArticle(url: "https://arxiv.org/abs/2301.07041", localFilePath: tempPDF.path)
        #expect(article.resolvedPDFPath == tempPDF.path)
    }

    @Test("resolvedPDFPath returns URL when it's a local PDF path")
    func resolvedPDFPathFromURL() throws {
        let tempPDF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data().write(to: tempPDF)
        defer { try? FileManager.default.removeItem(at: tempPDF) }
        let article = StudioArticle(url: tempPDF.path)
        #expect(article.resolvedPDFPath == tempPDF.path)
    }

    @Test("resolvedPDFPath is nil when the local PDF file is missing")
    func resolvedPDFPathNilWhenMissing() {
        let article = StudioArticle(url: "https://arxiv.org/abs/2301.07041", localFilePath: "/path/to/paper.pdf")
        #expect(article.resolvedPDFPath == nil)
    }

    @Test("cache-only PDF availability never stats an unvalidated path")
    func cachedPDFAvailabilityIsOptimisticUntilWarm() {
        let missingPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf").path
        StudioArticle.invalidateResolvedPathCache(forRawPaths: [missingPDF])
        defer { StudioArticle.invalidateResolvedPathCache(forRawPaths: [missingPDF]) }

        let article = StudioArticle(
            url: "https://example.com/paper",
            sourceType: .paper,
            localFilePath: missingPDF
        )

        // Render-time callers trust the recorded path while it is unknown.
        #expect(article.cachedHasUsablePDF)
        // The explicit background warm proves the miss without involving a view.
        StudioArticle.warmResolvedLocalPathCache(forRawPaths: [missingPDF])
        #expect(!article.cachedHasUsablePDF)
    }

    @Test("cache-only local document classification handles missing files")
    func cachedLocalDocumentClassificationDoesNotRequireFilePresence() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let chapter = StudioArticle(
            url: missingRoot.appendingPathComponent("Book_Chapters/01.html").path,
            sourceType: .book
        )
        let archive = StudioArticle(
            url: "https://example.com/article",
            sourceType: .article,
            localFilePath: missingRoot.appendingPathComponent("Articles/item/article.html").path
        )
        let remote = StudioArticle(url: "https://example.com/article", sourceType: .article)

        #expect(chapter.cachedIsLocalDocument)
        #expect(archive.cachedIsLocalDocument)
        #expect(!remote.cachedIsLocalDocument)
    }

    @Test("main-thread path resolution cannot stat iCloud-backed files")
    func mainThreadPathResolutionUsesCacheOnly() async {
        let missingPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).pdf").path
        StudioArticle.invalidateResolvedPathCache(forRawPaths: [missingPDF])
        defer { StudioArticle.invalidateResolvedPathCache(forRawPaths: [missingPDF]) }
        let article = StudioArticle(
            url: "https://example.com/paper",
            sourceType: .paper,
            localFilePath: missingPDF
        )

        let resolved = await MainActor.run { article.resolvedPDFPath }

        #expect(resolved == nil)
        // A filesystem probe would have memoized this path as missing. Remaining
        // optimistic proves the main-thread access stayed cache-only.
        #expect(article.cachedHasUsablePDF)
    }

    @Test("verified attachment promotes an earlier missing-path cache entry")
    func verifiedAttachmentPromotesMissingPathCacheEntry() throws {
        let tempPDF = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        let article = StudioArticle(
            url: "https://example.com/paper",
            localFilePath: tempPDF.path
        )
        defer {
            StudioArticle.invalidateResolvedPathCache(forRawPaths: [tempPDF.path])
            try? FileManager.default.removeItem(at: tempPDF)
        }

        #expect(article.resolvedPDFPath == nil)
        try Data("%PDF-1.7".utf8).write(to: tempPDF)
        #expect(article.cachedResolvedPDFPath == nil)

        StudioArticle.recordExistingLocalPath(tempPDF.path)

        #expect(article.cachedResolvedPDFPath == tempPDF.path)
        #expect(article.resolvedPDFPath == tempPDF.path)
    }

    @Test("a reload that races a fresh attachment keeps the attached PDF path")
    func reloadPreservesFreshlyAttachedLocalFilePath() {
        let attached = StudioArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/39933528/",
            title: "Impact of physical activity",
            sourceType: .paper,
            localFilePath: "Papers/10.1016_j.xcrm.2025.101968.pdf"
        )
        var reloaded = attached
        reloaded.localFilePath = nil

        let preserved = StudioViewModel.preservingLoadedContent(
            in: [reloaded],
            preservingFrom: [attached]
        )

        #expect(preserved[0].localFilePath == "Papers/10.1016_j.xcrm.2025.101968.pdf")
    }

    @Test("a reload never replaces a path the database supplied")
    func reloadDoesNotOverrideStoredLocalFilePath() {
        let inMemory = StudioArticle(
            url: "https://example.com/paper",
            sourceType: .paper,
            localFilePath: "Papers/stale.pdf"
        )
        var reloaded = inMemory
        reloaded.localFilePath = "Papers/current.pdf"

        let preserved = StudioViewModel.preservingLoadedContent(
            in: [reloaded],
            preservingFrom: [inMemory]
        )

        #expect(preserved[0].localFilePath == "Papers/current.pdf")
    }

    @Test("resolvedPDFPath returns nil for web URL")
    func resolvedPDFPathNilForWeb() {
        let article = StudioArticle(url: "https://example.com/article")
        #expect(article.resolvedPDFPath == nil)
    }

    @Test("isWebArticle is true for HTTP URLs")
    func isWebArticle() {
        let article = StudioArticle(url: "https://paulgraham.com/greatwork.html")
        #expect(article.isWebArticle)
    }

    @Test("isWebArticle is false for local paths")
    func isWebArticleLocalPath() {
        let article = StudioArticle(url: "/Users/me/Documents/paper.pdf")
        #expect(!article.isWebArticle)
    }

    @Test("isWebArticle is false when localFilePath is set")
    func isWebArticleWithLocalFile() {
        let article = StudioArticle(url: "https://example.com/paper", localFilePath: "/path/to/file.pdf")
        #expect(!article.isWebArticle)
    }

    @Test("isWebArticle is true for archived articles with HTTP URL")
    func isWebArticleArchivedArticle() {
        let article = StudioArticle(url: "https://example.com/article", localFilePath: "/path/to/Articles/abc123/article.html")
        #expect(article.isWebArticle)
    }

    @Test("An archived article prefers its live page over the saved document")
    func prefersLivePageForArchivedArticle() {
        let article = StudioArticle(
            url: "https://example.com/article",
            localFilePath: "/path/to/Articles/abc123/article.html"
        )
        #expect(article.cachedIsArchivedArticle)
        #expect(article.cachedPrefersLiveWebPage)
    }

    @Test("A paywalled archive keeps its saved document")
    func prefersSavedDocumentWhenPaywalled() {
        var article = StudioArticle(
            url: "https://example.com/article",
            localFilePath: "/path/to/Articles/abc123/article.html"
        )
        article.isPaywalled = true
        #expect(article.cachedIsArchivedArticle)
        #expect(!article.cachedPrefersLiveWebPage)
    }

    @Test("A locally imported HTML archive keeps its saved document")
    func prefersSavedDocumentForLocalImport() {
        let article = StudioArticle(
            url: "file:///tmp/local.html",
            localFilePath: "/path/to/Articles/local-import/article.html"
        )
        #expect(article.cachedIsArchivedArticle)
        #expect(!article.cachedPrefersLiveWebPage)
    }

    @Test("A source with no archive has no live-page preference to express")
    func prefersLivePageIsFalseWithoutAnArchive() {
        let article = StudioArticle(url: "https://example.com/article")
        #expect(!article.cachedIsArchivedArticle)
        #expect(!article.cachedPrefersLiveWebPage)
    }

    @Test("Text handed in with a PDF URL is read instead of the whole PDF")
    func excerptOfRemotePDFReadsStoredText() {
        // One abstract ingested from a conference book's page (2026-09-23).
        let pdfURL = "https://nick-lane.net/wp-content/uploads/2025/10/1-s2.0-S0005272824001634-main1.pdf#what-is-a-feeling"
        var excerpt = StudioArticle(url: pdfURL, sourceType: .article)
        excerpt.content = "What is a feeling? A bioenergetic explanation"
        excerpt.state = .ready
        #expect(excerpt.readsStoredTextOverRemotePDF)

        // A loaded row carries its word count before its text is hydrated; the
        // reader must not reach for the PDF in that gap.
        var unhydrated = StudioArticle(url: pdfURL, sourceType: .article)
        unhydrated.wordCount = 336
        unhydrated.state = .ready
        #expect(unhydrated.content == nil)
        #expect(unhydrated.readsStoredTextOverRemotePDF)

        // The app's own fetch of a PDF-URL article records the file, and the
        // file is then the reading.
        var downloaded = excerpt
        downloaded.localFilePath = "/path/to/Documents/abc123/document.pdf"
        #expect(!downloaded.readsStoredTextOverRemotePDF)

        // A paper's text is an extraction of its PDF; the PDF stays the paper.
        var paper = StudioArticle(url: pdfURL, sourceType: .paper)
        paper.content = excerpt.content
        paper.state = .ready
        #expect(!paper.readsStoredTextOverRemotePDF)

        // Nothing stored yet: nothing to read in place of the PDF.
        var empty = StudioArticle(url: pdfURL, sourceType: .article)
        empty.state = .ready
        #expect(!empty.readsStoredTextOverRemotePDF)

        // An ordinary web page is not a remote PDF at all.
        var page = StudioArticle(url: "https://example.com/article", sourceType: .article)
        page.content = "Body"
        page.state = .ready
        #expect(!page.readsStoredTextOverRemotePDF)
    }

    @Test("isPaywalledPaper detects paywall flag")
    func isPaywalledPaper() {
        var article = StudioArticle(url: "https://nature.com/articles/abc", sourceType: .paper)
        article.state = .ready
        article.isPaywalled = true
        #expect(article.isPaywalledPaper)
    }

    @Test("isPaywalledPaper detects legacy paywall error marker")
    func isPaywalledPaperWithLegacyErrorMarker() {
        var article = StudioArticle(url: "https://nature.com/articles/abc", sourceType: .paper)
        article.state = .ready
        article.errorMessage = "paywall"
        #expect(article.isPaywalledPaper)
    }

    @Test("isPaywalledPaper is false for non-paper")
    func isPaywalledPaperNotPaper() {
        var article = StudioArticle(url: "https://nature.com/articles/abc", sourceType: .article)
        article.state = .ready
        article.isPaywalled = true
        #expect(!article.isPaywalledPaper)
    }

    @Test("isPaywalledPaper is false when not paywalled")
    func isPaywalledPaperNotPaywalled() {
        var article = StudioArticle(url: "https://nature.com/articles/abc", sourceType: .paper)
        article.state = .ready
        #expect(!article.isPaywalledPaper)
    }

    @Test("Paper metadata display parts always include author journal and year")
    func paperMetadataDisplayParts() {
        let article = StudioArticle(url: "/Users/me/paper.pdf", title: "Paper", sourceType: .paper)
        #expect(article.paperMetadataDisplayParts == ["Unknown authors", "Unknown venue", "Unknown year"])
    }

    @Test("Paper metadata display does not repeat a duplicated sole author")
    func paperMetadataDisplayDeduplicatesSoleAuthor() {
        var article = StudioArticle(url: "/Users/me/paper.pdf", title: "Paper", sourceType: .paper)
        article.author = "Samuel I. Gould; Samuel I. Gould"

        #expect(article.shortAuthorDisplay == "Samuel I. Gould")
    }

    @Test("Paper metadata completeness score ignores placeholder values")
    func paperMetadataCompletenessScore() {
        var article = StudioArticle(url: "/Users/me/paper.pdf", title: "Paper", sourceType: .paper)
        article.author = "Doe et al."
        article.journal = "Unknown venue"
        article.publishedYear = "2026"
        #expect(article.paperMetadataCompletenessScore == 2)
    }

    @Test("Paper is fully ingested only after metadata, cleanup, and Listen preparation")
    func paperIngestionRequiresEveryPreparationStage() {
        var article = StudioArticle(
            url: "/Users/me/paper.pdf",
            title: "Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        article.state = .ready

        #expect(!article.hasSuccessfulPaperIngestion)
        #expect(article.paperAttentionReason(hasUsablePDF: false) == .pdfNeeded)
        #expect(article.paperAttentionReason(hasUsablePDF: true) == .metadataIncomplete)
        #expect(article.paperIngestionMethod == nil)
        let attested = article.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        #expect(article.paperIngestionMethod == .llm)
        #expect(!article.hasSuccessfulPaperIngestion)
        #expect(article.paperAttentionReason(hasUsablePDF: true) == nil)

        let raw = "Header\n\nClean paper text.\n\nReferences"
        let clean = "Clean paper text."
        article.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        #expect(article.isPaperReadyForListenPreparation)
        #expect(!article.hasSuccessfulPaperIngestion)
        #expect(article.paperAttentionReason(hasUsablePDF: true) == nil)
        article.paperListenableContentReady = true
        #expect(article.hasSuccessfulPaperIngestion)
        #expect(article.paperAttentionReason(hasUsablePDF: true) == nil)
        #expect(article.paperAttentionReason(hasUsablePDF: false) == .pdfNeeded)
    }

    @Test("A paper whose cleanup is queued has finished ingestion; an error or a missing attestation has not")
    func queuedCleanupIsFinishedIngestion() {
        var article = StudioArticle(
            url: "/Users/me/paper.pdf",
            title: "Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "bioRxiv",
            publishedYear: "2024"
        )
        article.prepareForPaperMetadataExtraction()
        #expect(!article.hasFinishedPaperIngestion, "queued for metadata, not yet attested")

        let attested = article.attestPaperMetadataExtractionAfterLLM()
        #expect(attested)
        let raw = "Header\n\nPaper text.\n\nReferences"
        article.stagePaperContentCleanup(raw: raw)
        #expect(article.state == .queued)
        #expect(!article.isPaperReadyForListenPreparation)
        #expect(article.hasFinishedPaperIngestion, "the cleanup queue takes it from here")

        article.failPaperIngestionMetadata("Paper ingestion failed: something else")
        #expect(!article.hasFinishedPaperIngestion)
    }

    @Test("A paper offers Mark as Paywalled only while the AI browser's suspicion still has a PDF to wait for")
    func paperOffersPaywallMarkingOnlyWhileSuspectedAndWithoutPDF() {
        var article = StudioArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/12345678/",
            title: "Mitochondrial Aging: Is There a Mitochondrial Clock?",
            sourceType: .paper
        )
        article.state = .queued
        #expect(article.suggestedPaywallReason(hasUsablePDF: false) == nil, "no browser run has spoken")

        article.paywallSuspicion = "  Abstract-only publisher page with a Get Access button and no PDF link.  "
        #expect(article.suggestedPaywallReason(hasUsablePDF: false)
                == "Abstract-only publisher page with a Get Access button and no PDF link.")
        #expect(article.suggestedPaywallReason(hasUsablePDF: true) == nil, "a paper with a PDF has nothing to mark")

        article.paywallSuspicion = "   "
        #expect(article.suggestedPaywallReason(hasUsablePDF: false) == nil, "blank is not a reason")

        article.paywallSuspicion = "Sign-in prompt beside the article."
        article.isPaywalled = true
        #expect(article.suggestedPaywallReason(hasUsablePDF: false) == nil, "marked papers left the attention list")
        article.isPaywalled = false
        article.state = .error
        #expect(article.suggestedPaywallReason(hasUsablePDF: false) == nil, "a failed paper shows its failure instead")
        article.state = .fetching
        #expect(article.suggestedPaywallReason(hasUsablePDF: false) == nil)

        article.state = .queued
        article.convertPaperToArticle()
        #expect(article.paywallSuspicion == nil, "a page that is not a paper carries no paper suspicion")
        #expect(article.suggestedPaywallReason(hasUsablePDF: false) == nil)
    }

    @Test("A paywall suspicion rides the source payload and an older payload decodes without one")
    func paywallSuspicionRidesTheSourcePayload() throws {
        var article = StudioArticle(url: "https://doi.org/10.1000/example", title: "Paper", sourceType: .paper)
        article.paywallSuspicion = "Publisher page offers purchase only."
        let data = try JSONEncoder().encode(article)
        let decoded = try JSONDecoder().decode(StudioArticle.self, from: data)
        #expect(decoded.paywallSuspicion == "Publisher page offers purchase only.")

        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "paywallSuspicion")
        let older = try JSONDecoder().decode(StudioArticle.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.paywallSuspicion == nil)
    }

    @Test("A cleanup failure preserves successful AI metadata attestation")
    func paperCleanupFailurePreservesMetadataAttestation() {
        var article = StudioArticle(
            url: "/Users/me/paper.pdf",
            title: "Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )

        // Hoisted: `attestPaperMetadataExtractionAfterLLM` mutates, and the
        // #expect macro evaluates its argument through an immutable binding.
        let didAttest = article.attestPaperMetadataExtractionAfterLLM()
        #expect(didAttest)
        #expect(article.paperIngestionMethod == .llm)
        #expect(article.state == .queued)

        let message = StudioArticle.paperContentCleanupFailureMessage("Temporary failure.")
        article.failPaperContentCleanup(message)

        #expect(article.hasPaperIngestionAttestation)
        #expect(!article.requiresPaperMetadataAI)
        #expect(article.state == .error)
        #expect(article.errorMessage == message)
        #expect(article.isPaperContentCleanupFailure)
    }

    @Test("Empty LLM metadata cannot attest paper ingestion")
    func incompletePaperCannotCompleteIngestion() {
        var article = StudioArticle(
            url: "/Users/me/paper.pdf",
            title: "Paper",
            sourceType: .paper
        )

        let attested = article.completePaperMetadataExtractionAfterLLM()
        #expect(!attested)
        #expect(article.paperIngestionMethod == nil)
        #expect(article.state == .queued)
    }

    /// The venue is the field real documents most often simply do not have: a
    /// lab preprint posted to a company site prints no journal, no conference,
    /// and no institution line. Failing its ingestion left a readable paper in
    /// the attention list behind an error no retry could clear.
    @Test("A blank venue does not fail paper ingestion")
    func blankVenueStillAttestsPaperIngestion() {
        var article = StudioArticle(
            url: "/Users/me/binder-design.pdf",
            title: "Autonomous de novo protein binder design",
            sourceType: .paper,
            author: "Claude Science; Amir Shanehsazzadeh",
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: "2026"
        )

        #expect(article.hasAttestablePaperMetadata)
        #expect(article.missingRequiredPaperMetadataFields == ["venue"])

        let attested = article.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        #expect(article.paperIngestionMethod == .llm)
        #expect(article.state == .ready)
        #expect(article.errorMessage == nil)
        #expect(article.hasPaperIngestionAttestation)
        #expect(article.paperAttentionReason(hasUsablePDF: true) == nil)
    }

    @Test("A paper failed over a blank field is attested without another model call")
    func blankMetadataFailureHealsWithoutExtraction() {
        var article = StudioArticle(
            url: "/Users/me/binder-design.pdf",
            title: "Autonomous de novo protein binder design",
            sourceType: .paper,
            author: "Claude Science; Amir Shanehsazzadeh",
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: "2026"
        )
        let raw = "Header\n\nClean paper text.\n\nReferences"
        let clean = "Clean paper text."
        article.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        article.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["venue"])
        )
        #expect(article.canAttestPaperIngestionAfterBlankMetadataFailure)

        let didAttest = article.attestPaperIngestionAfterBlankMetadataFailure()
        #expect(didAttest)
        #expect(article.paperIngestionMethod == .llm)
        #expect(article.state == .ready)
        #expect(article.errorMessage == nil)
        #expect(article.isPaperReadyForListenPreparation)
        // Healing is a one-shot: an already-attested row is not re-promoted.
        let didReattest = article.attestPaperIngestionAfterBlankMetadataFailure()
        #expect(!didReattest)
    }

    @Test("A paper with no canonical text is not healed in place")
    func blankMetadataFailureWithoutCleanupStaysForExtraction() {
        var article = StudioArticle(
            url: "/Users/me/binder-design.pdf",
            title: "Autonomous de novo protein binder design",
            sourceType: .paper,
            author: "Claude Science; Amir Shanehsazzadeh",
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: "2026"
        )
        article.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["venue"])
        )

        #expect(!article.canAttestPaperIngestionAfterBlankMetadataFailure)
        let didAttest = article.attestPaperIngestionAfterBlankMetadataFailure()
        #expect(!didAttest)
        #expect(article.state == .error)
    }

    @Test("A cleanup failure is never healed as a blank-metadata row")
    func cleanupFailureIsNotHealedAsBlankMetadata() {
        var article = StudioArticle(
            url: "/Users/me/binder-design.pdf",
            title: "Autonomous de novo protein binder design",
            sourceType: .paper,
            author: "Claude Science; Amir Shanehsazzadeh",
            journal: StudioArticle.unknownPaperJournal,
            publishedYear: "2026"
        )
        article.failPaperIngestionMetadata(
            StudioArticle.paperContentCleanupFailureMessage("Temporary failure.")
        )

        #expect(!article.isPaperMetadataIncompleteFailure)
        #expect(!article.canAttestPaperIngestionAfterBlankMetadataFailure)
    }

    @Test("An incomplete extraction names only the fields it missed and sends the learner to them")
    func incompletePaperMetadataFailureNamesMissingFields() {
        var article = StudioArticle(
            url: "/Users/me/thesis.pdf",
            title: "Thesis",
            sourceType: .paper,
            author: "Zara Holt",
            journal: "PhD thesis, University of Edinburgh",
            publishedYear: StudioArticle.unknownPaperYear
        )

        #expect(article.missingRequiredPaperMetadataFields == ["year"])
        let message = StudioArticle.paperMetadataIncompleteMessage(
            missing: article.missingRequiredPaperMetadataFields
        )
        #expect(message.contains("could not find the year"))
        #expect(!message.contains("author"))

        article.failPaperIngestionMetadata(message)
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .editDetails)

        // Rows persisted by the build that used the blanket wording route the
        // same way instead of offering a retry that cannot succeed.
        article.failPaperIngestionMetadata(
            "Paper ingestion failed: Paper Metadata AI did not return author, venue, and year."
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .editDetails)
    }

    @Test("All three missing fields still read as a list")
    func incompletePaperMetadataListsEveryMissingField() {
        let article = StudioArticle(url: "/Users/me/paper.pdf", title: "Paper", sourceType: .paper)
        #expect(article.missingRequiredPaperMetadataFields == ["author", "venue", "year"])
        let message = StudioArticle.paperMetadataIncompleteMessage(
            missing: article.missingRequiredPaperMetadataFields
        )
        #expect(message.contains("author, venue, and year"))
        #expect(message.contains("fill them in"))
    }

    @Test("Manual metadata attests a paper the extractor could not complete")
    func manualMetadataAttestsPaperIngestion() {
        var article = StudioArticle(
            url: "/Users/me/thesis.pdf",
            title: "Thesis",
            sourceType: .paper,
            author: "Zara Holt",
            journal: "PhD thesis, University of Edinburgh",
            publishedYear: StudioArticle.unknownPaperYear
        )
        article.failPaperIngestionMetadata(
            StudioArticle.paperMetadataIncompleteMessage(missing: ["year"])
        )
        // Nothing resolved is still nothing to attest.
        var blank = article
        blank.author = nil
        blank.journal = nil
        blank.publishedYear = nil
        let didComplete = blank.completePaperMetadataFromManualEntry()
        #expect(!didComplete)

        article.publishedYear = "2025"
        let attested = article.completePaperMetadataFromManualEntry()
        #expect(attested)
        #expect(article.paperIngestionMethod == .manual)
        #expect(article.hasPaperIngestionAttestation)
        #expect(article.errorMessage == nil)
        // Cleanup has not run yet, so the paper is queued work rather than a
        // failure and rather than a finished ingestion.
        #expect(article.state == .queued)
        #expect(!article.isPaperReadyForListenPreparation)
        #expect(article.paperAttentionReason(hasUsablePDF: true) == nil)

        let raw = "Cover sheet\n\nThesis text.\n\nReferences"
        let clean = "Thesis text."
        article.installPreparedPaperContent(
            raw: raw,
            clean: clean,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(raw),
                cleanSHA256: PaperContentPreparationService.sha256(clean),
                preparedAt: Date()
            )
        )
        let attestedAfterCleanup = article.completePaperMetadataFromManualEntry()
        #expect(attestedAfterCleanup)
        #expect(article.state == .ready)
        #expect(article.isPaperReadyForListenPreparation)
    }

    @Test("A manual attestation does not displace one the extractor already made")
    func manualMetadataKeepsExistingAttestation() {
        var article = StudioArticle(
            url: "/Users/me/paper.pdf",
            title: "Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        let llmAttested = article.completePaperMetadataExtractionAfterLLM()
        #expect(llmAttested)
        let manualAttested = article.completePaperMetadataFromManualEntry()
        #expect(manualAttested)
        #expect(article.paperIngestionMethod == .llm)
    }

    @Test("Paper ingestion failure exposes its cause and retry")
    func paperIngestionFailurePresentation() {
        var article = StudioArticle(url: "/Users/me/paper.pdf", title: "Paper", sourceType: .paper)
        article.failPaperIngestionMetadata(
            "Paper ingestion failed: Paper Metadata AI (OpenAI) failed after 3 attempts: Service unavailable."
        )

        #expect(
            article.paperIngestionFailureDetail
                == "Paper Metadata AI (OpenAI) failed after 3 attempts: Service unavailable."
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .retry)
    }

    @Test("Paper ingestion failure routes to its concrete fix")
    func paperIngestionFailureRecoveryActions() {
        var article = StudioArticle(url: "/Users/me/paper.pdf", title: "Paper", sourceType: .paper)

        article.failPaperIngestionMetadata(
            "Paper ingestion failed: Paper Metadata AI is not configured."
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .configureAI)

        article.failPaperIngestionMetadata(
            StudioArticle.paperContentCleanupFailureMessage(
                "Source Content Cleanup is not configured."
            )
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .configureAI)

        article.failPaperIngestionMetadata(
            "Paper ingestion failed: Your ForeverLM AI balance is empty — top up in Settings to continue."
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .addBalance)

        // The wording since the prepaid balance was retired (2026-09-25).
        article.failPaperIngestionMetadata("Paper ingestion failed: \(KeychainService.emptyBalanceMessage)")
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .addBalance)

        // The wording from before AI Usage split off Billing, still
        // stored on older rows, and the content cleanup's pause.
        article.failPaperIngestionMetadata(
            "Paper ingestion failed: Add your OpenRouter key and choose a plan in Settings → Billing to run this."
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .addBalance)
        article.failPaperIngestionMetadata(
            StudioArticle.paperContentCleanupFailureMessage(
                PaperContentPreparationService.contentCleanupCreditsPausedMessage
            )
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .addBalance)
        // The cleanup's pause from while the key also needed a plan (until
        // 2026-10-10), still stored on older rows.
        article.failPaperIngestionMetadata(
            StudioArticle.paperContentCleanupFailureMessage(
                "Source Content Cleanup paused: add your OpenRouter key in AI Usage (the sidebar's OpenRouter button) and choose a plan in Settings → Billing to finish ingesting this source."
            )
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .addBalance)

        article.failPaperIngestionMetadata(
            "Paper ingestion failed: no readable PDF or full-text paper content was available."
        )
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .attachPDF)

        article.failPaperIngestionMetadata("PDF download failed. Try attaching the file manually.")
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: false) == .attachPDF)

        article.errorMessage = nil
        #expect(article.paperIngestionFailureDetail == "No failure details were recorded.")
        #expect(article.paperIngestionRecoveryAction(hasUsablePDF: true) == .retry)
    }

    @Test("Paper LLM attestation survives the Codable payload used by CloudKit")
    func paperIngestionAttestationRoundTrips() throws {
        var article = StudioArticle(
            url: "/Users/me/paper.pdf",
            title: "Paper",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Nature Aging",
            publishedYear: "2026"
        )
        let attested = article.completePaperMetadataExtractionAfterLLM()
        #expect(attested)
        let text = "Canonical paper text."
        article.installPreparedPaperContent(
            raw: text,
            clean: text,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(text),
                cleanSHA256: PaperContentPreparationService.sha256(text),
                preparedAt: Date()
            )
        )

        let payload = try JSONEncoder().encode(article)
        let decoded = try JSONDecoder().decode(StudioArticle.self, from: payload)

        #expect(decoded.paperIngestionMethod == .llm)
        #expect(decoded.hasPaperIngestionAttestation)
        // CloudKit carries cleanup metadata separately from StudioArticle's
        // Codable payload; the source is not fully ready until it is applied.
        #expect(!decoded.isPaperReadyForListenPreparation)
        #expect(!decoded.hasSuccessfulPaperIngestion)
    }

    @Test("Opaque group identifiers never surface as display titles")
    func opaqueGroupIdentifiersAreNotDisplayTitles() {
        #expect(StudioViewModel.looksLikeOpaqueIdentifier(
            "src_5bc5ce4e96772639db108ec3b1fa7c4be52b410807f0ffd58c2178bcc920e777"
        ))
        #expect(StudioViewModel.looksLikeOpaqueIdentifier("5bc5ce4e96772639db108ec3b1fa7c4b"))
        #expect(StudioViewModel.looksLikeOpaqueIdentifier(UUID().uuidString))
        #expect(!StudioViewModel.looksLikeOpaqueIdentifier("Molecular Biology of the Cell"))
        #expect(StudioViewModel.humanVisibleGroupTitle(
            "src_5bc5ce4e96772639db108ec3b1fa7c4be52b410807f0ffd58c2178bcc920e777"
        ) == nil)
    }

    @Test("Playlist source identity key canonicalizes YouTube URL variants")
    func playlistSourceIdentityKeyCanonicalizesYouTubeURLVariants() {
        let playlistURL = "https://www.youtube.com/watch?v=abc123&list=PL-course&index=4"
        let shortURL = "https://youtu.be/abc123?si=share-token"
        let mobileURL = "https://m.youtube.com/watch?v=abc123"

        #expect(StudioViewModel.sourceURLIdentityKey(playlistURL) == "youtube.com/watch?v=abc123")
        #expect(StudioViewModel.sourceURLIdentityKey(shortURL) == "youtube.com/watch?v=abc123")
        #expect(StudioViewModel.sourceURLIdentityKey(mobileURL) == "youtube.com/watch?v=abc123")
    }
}

@Suite("Paper Metadata")
struct PaperMetadataTests {

    @Test("Duplicate merge copies richer metadata into local paper")
    @MainActor func duplicateMergeKeepsRicherMetadata() {
        var local = StudioArticle(
            url: "/Users/me/paper.pdf",
            title: "Mitochondria as signaling organelles",
            sourceType: .paper,
            localFilePath: "/Users/me/paper.pdf"
        )
        let web = StudioArticle(
            url: "https://link.springer.com/article/10.1186/1741-7007-12-34",
            title: "Mitochondria as signaling organelles | BMC Biology | Springer Nature Link",
            sourceType: .paper,
            author: "Chandel",
            journal: "BMC Biology",
            publishedYear: "2014"
        )

        let changed = StudioViewModel.mergePaperMetadata(from: web, into: &local)
        #expect(changed)
        #expect(local.author == "Chandel")
        #expect(local.journal == "BMC Biology")
        #expect(local.publishedYear == "2014")
    }
}

// MARK: - StudioArticleState

@Suite("StudioArticleState")
struct StudioArticleStateTests {

    @Test("All states have valid raw values")
    func allStatesHaveRawValues() {
        let states: [StudioArticleState] = [.queued, .fetching, .ready, .error]
        for state in states {
            #expect(!state.rawValue.isEmpty)
        }
    }

    @Test("States are Codable round-trip")
    func codableRoundTrip() throws {
        let states: [StudioArticleState] = [.queued, .fetching, .ready, .error]
        for state in states {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(StudioArticleState.self, from: data)
            #expect(decoded == state)
        }
    }
}

// MARK: - StudioSourceType

@Suite("StudioSourceType")
struct StudioSourceTypeTests {

    @Test("All source types have valid raw values")
    func allTypesHaveRawValues() {
        let types: [StudioSourceType] = [.article, .paper, .podcast, .book, .course, .meeting, .video, .manual]
        for type in types {
            #expect(!type.rawValue.isEmpty)
        }
    }

    @Test("Source types are Codable round-trip")
    func codableRoundTrip() throws {
        let types: [StudioSourceType] = [.article, .paper, .podcast, .book, .course, .meeting, .video, .manual]
        for type in types {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(StudioSourceType.self, from: data)
            #expect(decoded == type)
        }
    }
}

// MARK: - DiscoveryOrigin

@Suite("DiscoveryOrigin")
struct DiscoveryOriginTests {

    @Test("All origins are Codable round-trip")
    func codableRoundTrip() throws {
        let origins: [DiscoveryOrigin] = [.safari, .chrome, .brave, .applePodcasts, .localBooks, .localCourses, .localMeetings, .googleDriveMeetings, .localPapers, .youtubePlaylist, .manual]
        for origin in origins {
            let data = try JSONEncoder().encode(origin)
            let decoded = try JSONDecoder().decode(DiscoveryOrigin.self, from: data)
            #expect(decoded == origin)
        }
    }
}

// MARK: - ReviewSessionOrigin

@Suite("ReviewSessionOrigin")
struct ReviewSessionOriginTests {

    @Test("Mobile session prefixes map to distinct origins")
    func sessionPrefixes() {
        #expect(ReviewSessionOrigin.infer(from: "ios-123") == .iPhone)
        #expect(ReviewSessionOrigin.infer(from: "ios-live-123") == .iPhone)
        #expect(ReviewSessionOrigin.infer(from: "carplay-live-123") == .carPlay)
        #expect(ReviewSessionOrigin.infer(from: "session-123") == .other)
    }
}

// MARK: - Google Drive meeting folders

@Suite("Google Drive meeting folders")
struct GoogleDriveMeetingFolderTests {
    @Test("Folder refresh requires the read-only Drive scope")
    func folderReadScope() {
        let perFile = GoogleDriveService.scopeSet(from: GoogleDriveService.pickerScope)
        #expect(!perFile.contains(GoogleDriveService.folderReadScope))

        let readOnly = GoogleDriveService.scopeSet(
            from: "openid  \(GoogleDriveService.folderReadScope)\nemail"
        )
        #expect(readOnly.contains(GoogleDriveService.folderReadScope))
        #expect(readOnly.count == 3)
    }

    @Test("Folder identity accepts canonical, query, and bare IDs")
    func folderIdentity() throws {
        #expect(try StudioViewModel.googleDriveFolderID(
            from: "https://drive.google.com/drive/folders/folder-123?usp=sharing"
        ) == "folder-123")
        #expect(try StudioViewModel.googleDriveFolderID(
            from: "https://drive.google.com/open?id=folder-456"
        ) == "folder-456")
        #expect(try StudioViewModel.googleDriveFolderID(from: "folder-789") == "folder-789")
    }

    @Test("Drive URLs retain their owning Google account")
    func accountTaggedURLs() throws {
        let tagged = GoogleDriveService.taggedURL(
            "https://drive.google.com/drive/folders/folder-123?usp=sharing",
            accountID: "permission-26"
        )
        #expect(GoogleDriveService.accountID(from: tagged) == "permission-26")
        #expect(try StudioViewModel.googleDriveFolderID(from: tagged) == "folder-123")
        #expect(tagged.contains("usp=sharing"))
        #expect(GoogleDriveService.accountID(
            from: "https://drive.google.com/drive/folders/legacy-folder"
        ) == nil)
    }

    @Test("Connected account registry round-trips and replaces one account only")
    func accountRegistry() {
        let first = GoogleDriveAccount(id: "one", email: "one@example.com", displayName: "One")
        let updated = GoogleDriveAccount(id: "one", email: "new-one@example.com", displayName: "One")
        let second = GoogleDriveAccount(id: "two", email: "two@example.com", displayName: "Two")
        let merged = GoogleDriveService.mergingAccount(updated, into: [first, second])
        #expect(merged.count == 2)
        #expect(merged.first(where: { $0.id == "one" })?.email == "new-one@example.com")
        #expect(GoogleDriveService.decodeAccounts(GoogleDriveService.encodeAccounts(merged)) == merged)
        #expect(GoogleDriveService.removingAccount(id: "one", from: merged) == [second])
    }

    @Test("Non-folder links are rejected")
    func rejectsNonFolderLinks() {
        #expect(throws: (any Error).self) {
            try StudioViewModel.googleDriveFolderID(from: "https://drive.google.com/file/d/file-123/view")
        }
    }

    @Test("Meet transcript and note names classify without brackets")
    func meetArtifactClassification() {
        #expect(StudioViewModel.meetingArtifactKind(
            fileName: "Nexus - 2026-08-23 - Transcript",
            mimeType: "application/vnd.google-apps.document"
        ) == .transcript)
        #expect(StudioViewModel.meetingArtifactKind(
            fileName: "Nexus - 2026-08-23 - Notes by Gemini",
            mimeType: "application/vnd.google-apps.document"
        ) == .notes)
        #expect(StudioViewModel.meetingArtifactKind(
            fileName: "Nexus - 2026-08-23 - Recording.mp4",
            mimeType: "video/mp4"
        ) == .recording)
        #expect(StudioViewModel.meetingArtifactKind(
            fileName: "Nexus - 2026-08-23 - Chat.sbv",
            mimeType: "text/plain"
        ) == .chat)
    }

    @Test("Drive shortcuts use their target identity and MIME type")
    func driveShortcutTarget() {
        let shortcut = GoogleDriveFile(
            id: "shortcut-1",
            name: "Nexus - Recording.mp4",
            mimeType: "application/vnd.google-apps.shortcut",
            modifiedAt: nil,
            webViewLink: "https://drive.google.com/open?id=shortcut-1",
            shortcutTargetID: "recording-1",
            shortcutTargetMimeType: "video/mp4"
        )
        #expect(shortcut.resourceID == "recording-1")
        #expect(shortcut.effectiveMimeType == "video/mp4")
        #expect(shortcut.webURL == "https://drive.google.com/file/d/recording-1/view")
    }

    @Test("Drive file links carry their account without changing file identity")
    func driveFileAccountIdentity() {
        let file = GoogleDriveFile(
            id: "recording-1",
            name: "Nexus - Recording.mp4",
            mimeType: "video/mp4",
            modifiedAt: nil,
            webViewLink: "https://drive.google.com/file/d/recording-1/view?usp=sharing",
            shortcutTargetID: nil,
            shortcutTargetMimeType: nil,
            accountID: "permission-26"
        )
        #expect(GoogleDriveService.fileID(from: file.webURL) == "recording-1")
        #expect(GoogleDriveService.accountID(from: file.webURL) == "permission-26")
        #expect(file.webURL.contains("usp=sharing"))
    }
}

// MARK: - StudioSidebarTab

@Suite("StudioSidebarTab")
struct StudioSidebarTabTests {

    @Test("All tabs have display names")
    func displayNames() {
        for tab in StudioSidebarTab.allCases {
            #expect(!tab.rawValue.isEmpty)
        }
    }

    @Test("All tabs have SF Symbol icons (except X which uses custom shape)")
    func icons() {
        for tab in StudioSidebarTab.allCases where tab != .xPosts {
            #expect(!tab.icon.isEmpty)
        }
    }

    @Test("Tab count is 7")
    func tabCount() {
        // articles, papers, books, meetings, podcasts, videos, xPosts. Courses
        // left for the rail on 2026-09-27 (courses-design.md).
        #expect(StudioSidebarTab.allCases.count == 7)
        // Zoom's brand mark did not go away with its tab; it moved onto the row,
        // where it says which provider a session came from.
        #expect(MeetingProvider.zoom.iconAsset == "ZoomIcon")
        #expect(MeetingProvider.zoom.displayName == "Zoom")
        #expect(StudioSidebarTab.meetings.rawValue == "Meetings")
        #expect(StudioSidebarTab.meetings.iconAsset == "MeetingsIcon")
        #expect(StudioSidebarTab.meetings.sourceType == .meeting)
    }

    @Test("Old Google Drive and Read AI tabs restore as Meetings")
    func mergedMeetingTabsMigrate() {
        #expect(StudioSidebarTab.fromPersistedRawValue("Google Drive") == .meetings)
        #expect(StudioSidebarTab.fromPersistedRawValue("Read AI") == .meetings)
        // The pre-split value, which the split itself stranded: while the two
        // plugin tabs existed nothing answered to "Meetings" and the saved
        // tab was silently dropped.
        #expect(StudioSidebarTab.fromPersistedRawValue("Meetings") == .meetings)
        #expect(StudioSidebarTab.fromPersistedRawValue("Videos") == .videos)
        #expect(StudioSidebarTab.fromPersistedRawValue("Nonsense") == nil)
    }

    @Test("A saved order naming both old meeting tabs yields one Meetings tab")
    func mergedMeetingTabsDeduplicate() {
        let persisted = ["Articles", "Google Drive", "Read AI"]
            .compactMap(StudioSidebarTab.fromPersistedRawValue)
        #expect(persisted == [.articles, .meetings, .meetings])
        let order = StudioSidebarTab.reconciledOrder(persisted)
        #expect(order.filter { $0 == .meetings }.count == 1)
        #expect(Set(order) == Set(StudioSidebarTab.allCases))
        #expect(order.count == StudioSidebarTab.allCases.count)
    }

    @Test("Every meeting origin maps to exactly one provider, and all of them are visible")
    func meetingOriginsHaveExactlyOneProvider() {
        // A meeting whose origin matched no tab was invisible everywhere, which
        // is what stranded locally imported folders while Google Drive and Read
        // AI were separate tabs. One tab makes that structurally impossible:
        // every origin resolves to a provider, and provider no longer decides
        // whether a session is allowed to appear.
        for origin: DiscoveryOrigin? in [.localMeetings, .googleDriveMeetings, .readAI, .zoom, nil, .manual, .plugin] {
            let provider = MeetingProvider.forOrigin(origin)
            #expect(MeetingProvider.allCases.contains(provider))
            #expect(StudioSidebarTab.knowledgeTab(sourceType: .meeting, url: "") == .meetings)
        }
    }

    @Test("Read AI, Google Drive, Zoom and local imports are distinct providers")
    func meetingProvidersAreDistinct() {
        #expect(MeetingProvider.forOrigin(.readAI) == .readAI)
        #expect(MeetingProvider.forOrigin(.googleDriveMeetings) == .googleDrive)
        #expect(MeetingProvider.forOrigin(.zoom) == .zoom)
        // A folder imported from disk is its own provider now. It used to be
        // filed under Google Drive because the split tabs left it nowhere else
        // to go, which claimed a Drive connection that did not exist.
        #expect(MeetingProvider.forOrigin(.localMeetings) == .localFolder)
        #expect(MeetingProvider.forOrigin(nil) == .localFolder)
        #expect(Set(MeetingProvider.allCases.map(\.displayName)).count == MeetingProvider.allCases.count)
        #expect(MeetingProvider.forPluginLabel("read ai") == .readAI)
        #expect(MeetingProvider.forPluginLabel("ZOOM") == .zoom)
        #expect(MeetingProvider.forPluginLabel("Unknown meeting bot") == nil)
        // The guide's worked example registers as "Read AI Meetings", and an
        // assistant following the recipe picks a name like it. The brand as
        // the leading word(s) is the claim; exact equality left that plugin
        // unrecognised and its meetings filed under Local Folder.
        #expect(MeetingProvider.forPluginLabel("Read AI Meetings") == .readAI)
        #expect(MeetingProvider.forPluginLabel("ReadAI sync") == .readAI)
        #expect(MeetingProvider.forPluginLabel("Zoom Recordings") == .zoom)
        #expect(MeetingProvider.forPluginLabel("Zoomer") == nil)
        #expect(MeetingProvider.forPluginLabel("Read") == nil)
        #expect(MeetingProvider.forPluginLabel("Meetings from Read AI") == nil)
        #expect(MeetingProvider.googleDrive.matches(connectorLabel: "Google Drive") == false)
        #expect(MeetingProvider.readAI.pluginDiscoveryOrigin == .readAI)
        #expect(MeetingProvider.zoom.pluginDiscoveryOrigin == .zoom)
    }

    @Test("Providers for a set of origins are de-duplicated and stably ordered")
    func meetingProviderOrdering() {
        let mixed: [DiscoveryOrigin?] = [.readAI, .googleDriveMeetings, .readAI, .zoom, nil]
        // A series fed by Drive and Read AI wears both marks in one row. The
        // split tabs listed that same series twice, once under each tab.
        #expect(MeetingProvider.providers(for: mixed) == [.googleDrive, .readAI, .zoom, .localFolder])
        let single: [DiscoveryOrigin?] = [.readAI]
        #expect(MeetingProvider.providers(for: single) == [.readAI])
    }

    @Test("Local Folder is a mark only when no branded provider stands beside it")
    func meetingProviderMarksDropLocalFolderNextToABrand() {
        // A standup whose Zoom transcripts sit beside a recording added from
        // this Mac wore a Zoom mark and a disk icon; the disk read as a second
        // service the series was synced with. Only the brand is drawn.
        #expect(MeetingProvider.marks(for: [.zoom, .localFolder]) == [.zoom])
        #expect(MeetingProvider.marks(for: [.googleDrive, .readAI, .localFolder]) == [.googleDrive, .readAI])
        // With nothing else to say, Local Folder still says where it came from.
        #expect(MeetingProvider.marks(for: [.localFolder]) == [.localFolder])
        #expect(MeetingProvider.marks(for: []) == [])
    }

    @Test("Only Meetings holds meeting sources")
    func onlyMeetingsTabHoldsMeetings() {
        let holders = StudioSidebarTab.allCases.filter { $0.sourceType == .meeting }
        #expect(holders == [.meetings])
    }

    @Test("Custom plugin tabs are classified for Settings")
    func pluginBackedTabs() {
        let plugins = StudioSidebarTab.allCases.filter(\.isPluginBacked)
        // Meetings is deliberately absent: it is a source family over several
        // providers, not one plugin. The Read AI and Zoom cards in Settings
        // come from `MeetingProvider.isPlugin` instead of from the tab list —
        // folding Zoom in would otherwise have cost it its card, the way folding
        // Read AI in nearly cost it one. Slack, the last plugin-backed tab,
        // went away with saved Slack threads: Slack is read live and files
        // nothing, so no tab is plugin-backed today.
        #expect(plugins.isEmpty)
        #expect(!plugins.contains(.meetings))
        #expect(!plugins.contains(.videos))
        #expect(!plugins.contains(.xPosts))
        #expect(MeetingProvider.allCases.filter(\.isPlugin) == [.readAI, .zoom])
    }

    @Test("Tabs that need an integration set up first are classified for pin defaults")
    func integrationBackedTabs() {
        let integrations = StudioSidebarTab.allCases.filter(\.requiresIntegrationSetup)
        #expect(integrations == [.meetings, .xPosts])
        // First-party ingestion from this Mac claims no connected account, and
        // both are Getting Started steps.
        #expect(!StudioSidebarTab.podcasts.requiresIntegrationSetup)
        #expect(!StudioSidebarTab.videos.requiresIntegrationSetup)
        #expect(!StudioSidebarTab.articles.requiresIntegrationSetup)
    }

    @Test("Knowledge families distinguish plugin content from tab presentation")
    func knowledgeFamilies() {
        #expect(StudioSidebarTab.knowledgeTab(sourceType: .article, url: "https://example.com") == .articles)
        // Every meeting is one family for AI discovery, whatever provider it
        // came from — so excluding meetings is one preference, not two.
        #expect(StudioSidebarTab.knowledgeTab(sourceType: .meeting, url: "") == .meetings)
        // Including a recording still stored as a video by an older build or by
        // Web Studio, which can only record the broad type.
        #expect(StudioSidebarTab.knowledgeTab(sourceType: .video, url: "https://example.zoom.us/rec/share/abc") == .meetings)
        #expect(StudioSidebarTab.knowledgeTab(sourceType: .video, url: "https://youtube.com/watch?v=abc") == .videos)
    }

    @Test("Knowledge exclusions persist independently of pinned tabs")
    func knowledgeExclusionPreference() throws {
        let suiteName = "StudioSidebarTabTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([StudioSidebarTab.videos.rawValue, StudioSidebarTab.meetings.rawValue], forKey: StudioSidebarTab.knowledgeExclusionPreferenceKey)
        #expect(StudioSidebarTab.excludedKnowledgeTabs(in: defaults) == [.videos, .meetings])
        // A library that excluded any of the three old provider tabs still
        // excludes meetings after the merge.
        defaults.set(["Read AI"], forKey: StudioSidebarTab.knowledgeExclusionPreferenceKey)
        #expect(StudioSidebarTab.excludedKnowledgeTabs(in: defaults) == [.meetings])
        defaults.set(["Zoom"], forKey: StudioSidebarTab.knowledgeExclusionPreferenceKey)
        #expect(StudioSidebarTab.excludedKnowledgeTabs(in: defaults) == [.meetings])
        #expect(defaults.stringArray(forKey: "studio.hiddenTabs") == nil)
    }
}

// MARK: - Meeting folder images

@Suite("Meeting folder images")
struct MeetingFolderImageTests {

    @Test("Only prefixed keys become folder images, and the group ID is the map key")
    func scansPrefixedKeys() throws {
        let suiteName = "MeetingFolderImageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let groupID = "785B6DF8-7FB1-4574-B551-46B8A622C880"
        defaults.set("https://example.com/logo.png", forKey: MeetingMetadata.folderImagePreferenceKey(for: groupID))
        // An empty value is a cleared choice, not an image of zero length.
        defaults.set("", forKey: MeetingMetadata.folderImagePreferenceKey(for: "cleared-group"))
        defaults.set("https://example.com/other.png", forKey: "someOtherPreference")

        let images = StudioViewModel.meetingFolderImageURLsFromDefaults(defaults)
        #expect(images == [groupID: "https://example.com/logo.png"])
    }

    @Test("A web address is stored verbatim and a local path becomes a file URL")
    func normalizesPathsButNotURLs() {
        let web = "https://example.com/logo.png?format=300w"
        #expect(StudioViewModel.normalizedMeetingFolderImageURL(web) == web)

        let fromPath = StudioViewModel.normalizedMeetingFolderImageURL("/tmp/logo.png")
        #expect(fromPath == "file:///tmp/logo.png")

        let fromTilde = StudioViewModel.normalizedMeetingFolderImageURL("~/logo.png")
        #expect(fromTilde.hasPrefix("file:///"))
        #expect(fromTilde.hasSuffix("/logo.png"))
        #expect(!fromTilde.contains("~"))
    }

    @Test("Folders sharing a logo stand together, alphabetically within")
    func sortsByLogoThenTitle() {
        let lbf = "https://example.com/fellowship.png"
        let images = [
            "aging": lbf,
            "biostasis": lbf,
            "replacement": lbf,
            "nexus": "https://example.com/nova.png",
            "member-drive": "https://example.com/member.png",
            "stanford": "https://example.com/stanford.png",
            "unbadged": nil,
        ]
        let titles = [
            "aging": "Aging Biology Study Group",
            "biostasis": "Biostasis Working Group",
            "replacement": "Replacement Working Group Sync",
            "nexus": "Nova Lab Nexus",
            "member-drive": "Nova Nexus - Member Drive",
            "stanford": "Stanford AI+Biomedicine Seminar",
            "unbadged": "Cryo Journal Club",
        ]

        let sorted = StudioViewModel.meetingGroupNamesSortedByFolderImage(
            titles.keys.shuffled(),
            imageURL: { images[$0] ?? nil },
            displayName: { titles[$0] ?? $0 }
        )

        // Each logo's run sits where its own first title falls, so the three
        // Fellowship folders lead as one block and "Cryo Journal Club" does not
        // land in the middle of them.
        #expect(sorted == [
            "aging",
            "biostasis",
            "replacement",
            "unbadged",
            "nexus",
            "member-drive",
            "stanford",
        ])
    }
}

@Suite("Meeting icons")
struct MeetingIconTests {

    /// Three rows in the shape of OpenRouter's `GET /api/v1/images/models`
    /// (checked 2026-09-27), plus the two kinds the catalog leaves out.
    private static let imageDirectory = Data("""
    {"data":[
      {"id":"openai/gpt-image-1-mini","name":"OpenAI: GPT Image 1 Mini","created":1782264713,
       "description":"Cheaper sibling of [GPT Image 1](/openai/gpt-image-1).",
       "architecture":{"input_modalities":["text","image"],"output_modalities":["image"]},
       "supported_parameters":{"aspect_ratio":{"type":"enum","values":["1:1","3:2","2:3","auto"]},
         "quality":{"type":"enum","values":["auto","low","medium","high"]},
         "n":{"type":"range","min":1,"max":10},"input_references":{"type":"range","min":0,"max":16}}},
      {"id":"recraft/recraft-v4.1-flash","name":"Recraft: Recraft V4.1 Flash","created":1790177946,
       "architecture":{"input_modalities":["text"],"output_modalities":["image"]},
       "supported_parameters":{"aspect_ratio":{"type":"enum","values":["1:1","4:3","3:4","16:9","9:16","auto"]},
         "n":{"type":"range","min":1,"max":6}}},
      {"id":"meta/muse-image","name":"Meta: Muse Image","created":1787764532,
       "architecture":{"input_modalities":["text","image"],"output_modalities":["image"]},
       "supported_parameters":{}},
      {"id":"recraft/recraft-v4-vector","name":"Recraft: Recraft V4 Vector","created":1778707333,
       "supported_parameters":{"output_format":{"type":"enum","values":["svg"]}}},
      {"id":"recraft/recraft-v4-styles","name":"Recraft: Recraft V4 Styles","created":1787742458,
       "supported_parameters":{"input_references":{"type":"range","min":1,"max":10}}}
    ]}
    """.utf8)

    @Test("OpenRouter's image directory becomes the catalog, newest first, without models the app cannot use")
    func directoryParses() throws {
        let models = try ImageGenerationCatalog.models(fromDirectory: Self.imageDirectory)
        // SVG-only and needs-a-picture models are left out.
        #expect(models.map(\.id) == ["recraft/recraft-v4.1-flash", "meta/muse-image", "openai/gpt-image-1-mini"])
        let mini = try #require(models.first { $0.id == "openai/gpt-image-1-mini" })
        #expect(mini.name == "GPT Image 1 Mini")
        #expect(mini.maker == "OpenAI")
        #expect(mini.detail == "Cheaper sibling of GPT Image 1.")
        #expect(mini.revisesPictures)
        #expect(mini.qualities.contains("medium"))
        let flash = try #require(models.first { $0.id == "recraft/recraft-v4.1-flash" })
        #expect(!flash.revisesPictures)
    }

    @Test("A stored choice resolves against the directory, and the old maker ids keep their model")
    func catalogResolves() throws {
        let models = try ImageGenerationCatalog.models(fromDirectory: Self.imageDirectory)
        // The ids stored while pictures went to OpenAI's and Google's own
        // APIs name the same models on OpenRouter.
        #expect(ImageGenerationCatalog.canonicalID("gpt-image-1-mini") == "openai/gpt-image-1-mini")
        #expect(ImageGenerationCatalog.canonicalID("gemini-3-pro-image") == "google/gemini-3-pro-image")
        #expect(ImageGenerationCatalog.canonicalID("recraft/recraft-v4") == "recraft/recraft-v4")
        #expect(ImageGenerationCatalog.resolvedModel(id: "gpt-image-1-mini", in: models).id == "openai/gpt-image-1-mini")
        #expect(ImageGenerationCatalog.resolvedModel(id: nil, in: models).id == ImageGenerationCatalog.defaultModelID)
        // A model OpenRouter stopped listing falls back to the default.
        #expect(ImageGenerationCatalog.resolvedModel(id: "dall-e-2", in: models).id == ImageGenerationCatalog.defaultModelID)
        // Before the directory arrives the choice is an unresolved stand-in,
        // never another model.
        let pending = ImageGenerationCatalog.resolvedModel(id: "gemini-3-pro-image", in: [])
        #expect(pending.id == "google/gemini-3-pro-image")
        #expect(!pending.isResolved)
    }

    @Test("A retired stored choice is replaced by the default, then a Suggested pick, then any listed model")
    func catalogReplacement() throws {
        let models = try ImageGenerationCatalog.models(fromDirectory: Self.imageDirectory)
        #expect(ImageGenerationCatalog.replacement(in: models)?.id == ImageGenerationCatalog.defaultModelID)
        let withoutDefault = models.filter { $0.id != ImageGenerationCatalog.defaultModelID }
        let suggested = ImageGenerationCatalog.suggestedModelIDs.first { id in withoutDefault.contains { $0.id == id } }
        #expect(ImageGenerationCatalog.replacement(in: withoutDefault)?.id == suggested ?? withoutDefault.first?.id)
        #expect(ImageGenerationCatalog.replacement(in: []) == nil)
        // What Settings shows for a retired choice is what gets stored.
        #expect(ImageGenerationCatalog.resolvedModel(id: "inclusionai/ming-image-0.1-design", in: withoutDefault).id
            == ImageGenerationCatalog.replacement(in: withoutDefault)?.id)
    }

    @Test("An endpoints record gives the output price in the unit OpenRouter bills it by")
    func endpointPrices() {
        func price(_ lines: String) -> ImageGenerationPrice? {
            ImageGenerationCatalog.price(fromEndpoints: Data(#"{"endpoints":[{"pricing":[\#(lines)]}]}"#.utf8))
        }
        #expect(price(#"{"billable":"output_image","unit":"image","cost_usd":0.04}"#) == .perImage(0.04))
        #expect(price(#"{"billable":"input_text","unit":"token","cost_usd":0.000002},{"billable":"output_image","unit":"token","cost_usd":0.000008}"#)
                == .perMillionTokens(8))
        #expect(price(#"{"billable":"output_image","unit":"image","cost_usd":0.2,"variant":"4k"},{"billable":"output_image","unit":"image","cost_usd":0.05}"#)
                == .perImage(0.05))
        #expect(price(#"{"billable":"input_image","unit":"image","cost_usd":0.01}"#) == nil)
        #expect(ImageGenerationPrice.perImage(0.0336).label == "$0.0336 a picture")
        #expect(ImageGenerationPrice.perMillionTokens(8).label == "$8 / 1M image tokens")
        #expect(ImageGenerationPrice.perMillionTokens(0).label == "Free")
        // A call whose response reported no charge is priced from the same
        // figure: by the picture, or by the image tokens it drew.
        #expect(ImageGenerationPrice.perImage(0.04).cost(pictures: 1, imageTokens: nil) == 0.04)
        #expect(abs((ImageGenerationPrice.perMillionTokens(8).cost(pictures: 1, imageTokens: 1_600) ?? 0) - 0.0128) < 1e-9)
        #expect(ImageGenerationPrice.perMillionTokens(8).cost(pictures: 1, imageTokens: nil) == nil)
        #expect(ImageGenerationPrice.perMillionTokens(0).cost(pictures: 1, imageTokens: 900) == 0)
        // A model whose endpoint record lists no price keeps the general
        // directory's published image-output rate.
        let directory = Data(#"{"data":[{"id":"krea/krea-2-large","pricing":{"prompt":"0","image_output":"0.0000143712574850299"}},{"id":"x/unpriced","pricing":{"prompt":"0"}}]}"#.utf8)
        let fallback = ImageGenerationCatalog.tokenPrices(fromDirectory: directory)
        if case .perMillionTokens(let usd)? = fallback["krea/krea-2-large"] {
            #expect(abs(usd - 14.3712574850299) < 0.000_001)
        } else {
            Issue.record("Krea's directory rate was not read")
        }
        #expect(fallback["x/unpriced"] == nil)
    }

    @Test("A request carries only the fields its model lists")
    func requestCarriesListedFields() throws {
        let models = try ImageGenerationCatalog.models(fromDirectory: Self.imageDirectory)
        let mini = try #require(models.first { $0.id == "openai/gpt-image-1-mini" })
        let body = try ManagedImageGeneration.requestBody(prompt: "a cell", model: mini, shape: .landscape, quality: .medium, reference: nil)
        #expect(body["model"] as? String == "openai/gpt-image-1-mini")
        #expect(body["aspect_ratio"] as? String == "3:2")
        #expect(body["quality"] as? String == "medium")
        #expect(body["n"] as? Int == 1)
        #expect(body["resolution"] == nil)

        // No 3:2 on Recraft: the nearest ratio it lists, and no quality field.
        let flash = try #require(models.first { $0.id == "recraft/recraft-v4.1-flash" })
        let recraft = try ManagedImageGeneration.requestBody(prompt: "a cell", model: flash, shape: .landscape, quality: .high, reference: nil)
        #expect(recraft["aspect_ratio"] as? String == "4:3")
        #expect(recraft["quality"] == nil)

        // A model that lists nothing gets the prompt alone.
        let muse = try #require(models.first { $0.id == "meta/muse-image" })
        let bare = try ManagedImageGeneration.requestBody(prompt: "a cell", model: muse, shape: .portrait, quality: .low, reference: nil)
        #expect(Set(bare.keys) == ["model", "prompt"])
        #expect(ManagedImageGeneration.preferredResolution(among: ["2K", "4K"]) == "2K")
        #expect(ManagedImageGeneration.preferredResolution(among: ["512", "1K", "2K"]) == "1K")
    }

    @Test("An icon prompt carries the topic, bans lettering, and never draws a person")
    func promptShape() {
        let prompt = ImageGenerationCatalog.iconPrompt(
            topic: "Mitochondrial Transplantation",
            presenter: "Robin Vale",
            groupTitle: "Meeting Notes & Recordings - Nexus",
            style: .emblem
        )
        #expect(prompt.contains("Mitochondrial Transplantation"))
        #expect(prompt.contains("Meeting Notes & Recordings - Nexus"))
        // The presenter disambiguates the subject; it must never become a face.
        #expect(prompt.contains("Robin Vale"))
        #expect(prompt.contains("never depict a person"))
        // Lettering is illegible at 42 points and misspelt at any size.
        #expect(prompt.lowercased().contains("no text"))

        // A session whose topic could not be read still gets a drawable prompt.
        let untitled = ImageGenerationCatalog.iconPrompt(
            topic: "   ",
            presenter: nil,
            groupTitle: "Journal Club",
            style: .lineArt
        )
        #expect(untitled.contains("Journal Club"))
    }

    @Test("A stored icon path is a file to open, not a URL to fetch")
    func distinguishesStoredIconsFromRemoteArtwork() {
        // Podcast covers and YouTube stills stay on the network path.
        #expect(MeetingIconService.localArtworkPath(for: "https://example.com/cover.jpg") == nil)
        #expect(MeetingIconService.localArtworkPath(for: nil) == nil)
        #expect(MeetingIconService.localArtworkPath(for: "  ") == nil)

        let relative = MeetingIconService.relativePath(sourceID: "session-1")
        #expect(relative == "Meetings/session-1/icon.jpg")
        let resolved = MeetingIconService.localArtworkPath(for: relative)
        #expect(resolved?.hasPrefix("/") == true)
        #expect(resolved?.hasSuffix("Meetings/session-1/icon.jpg") == true)
    }

    @Test("A Drive thumbnail link is asked for at the size we store")
    func rewritesThumbnailSize() {
        #expect(
            GoogleDriveService.thumbnailLink("https://lh3.googleusercontent.com/drive-storage/abc=s220", size: 512)
                == "https://lh3.googleusercontent.com/drive-storage/abc=s512"
        )
        // A link in any other shape is used exactly as Drive gave it.
        let unusual = "https://lh3.googleusercontent.com/drive-storage/abc=s220-c"
        #expect(GoogleDriveService.thumbnailLink(unusual, size: 512) == unusual)
        let plain = "https://lh3.googleusercontent.com/drive-storage/abc"
        #expect(GoogleDriveService.thumbnailLink(plain, size: 512) == plain)
    }

    @Test("A drawn icon and a caught frame are told apart by where they are stored")
    func iconProvenanceLivesInThePath() {
        let captured = MeetingIconService.relativePath(sourceID: "s1")
        let drawn = MeetingIconService.relativePath(sourceID: "s1", drawn: true)
        #expect(captured == "Meetings/s1/icon.jpg")
        #expect(drawn == "Meetings/s1/icon-drawn.jpg")
        #expect(MeetingIconService.isDrawnIconPath(drawn))
        // Icons written before the distinction existed were all frames, so the
        // bare name has to keep meaning "captured".
        #expect(!MeetingIconService.isDrawnIconPath(captured))
        #expect(!MeetingIconService.isDrawnIconPath(nil))
        #expect(!MeetingIconService.isDrawnIconPath("https://example.com/icon-drawn.jpg.png"))
    }

    @Test("Always Draw treats a clipped frame as unfinished; Prefer a Thumbnail does not")
    func alwaysDrawCountsFramesAsMissing() {
        func meeting(_ artwork: String?) -> StudioArticle {
            var article = StudioArticle(url: "meeting://g/1", title: "Journal Club", sourceType: .meeting)
            article.artworkURL = artwork
            return article
        }
        let framed = meeting(MeetingIconService.relativePath(sourceID: "s1"))
        let drawn = meeting(MeetingIconService.relativePath(sourceID: "s1", drawn: true))
        let bare = meeting(nil)
        let onDisk: (String) -> Bool = { _ in true }

        // The frames are the reason someone picks Always Draw, so the setting
        // has to see them as work left to do.
        #expect(!StudioViewModel.hasSatisfactoryIcon(framed, source: .alwaysDraw, iconIsOnDisk: onDisk))
        #expect(StudioViewModel.hasSatisfactoryIcon(framed, source: .preferThumbnail, iconIsOnDisk: onDisk))

        // A picture already paid for satisfies either preference.
        #expect(StudioViewModel.hasSatisfactoryIcon(drawn, source: .alwaysDraw, iconIsOnDisk: onDisk))
        #expect(StudioViewModel.hasSatisfactoryIcon(drawn, source: .preferThumbnail, iconIsOnDisk: onDisk))

        #expect(!StudioViewModel.hasSatisfactoryIcon(bare, source: .alwaysDraw, iconIsOnDisk: onDisk))
        #expect(!StudioViewModel.hasSatisfactoryIcon(bare, source: .preferThumbnail, iconIsOnDisk: onDisk))

        // Artwork this app did not write is nobody's business to redraw.
        let remote = meeting("https://example.com/cover.jpg")
        #expect(StudioViewModel.hasSatisfactoryIcon(remote, source: .alwaysDraw, iconIsOnDisk: onDisk))
    }

    @Test("A path to an icon this Mac was never sent counts as missing")
    func pathWithoutBytesIsNotAnIcon() {
        func meeting(_ artwork: String?) -> StudioArticle {
            var article = StudioArticle(url: "meeting://g/1", title: "Journal Club", sourceType: .meeting)
            article.artworkURL = artwork
            return article
        }
        let absent: (String) -> Bool = { _ in false }

        // `artwork_url` is an ordinary synced column and the JPEG travels as a
        // record asset, so a Mac routinely holds one without the other. Counting
        // the path as an icon is what left 87 meetings on the fallback glyph with
        // a Settings button that said there was nothing to do.
        let framed = meeting(MeetingIconService.relativePath(sourceID: "s1"))
        let drawn = meeting(MeetingIconService.relativePath(sourceID: "s1", drawn: true))
        #expect(!StudioViewModel.hasSatisfactoryIcon(framed, source: .preferThumbnail, iconIsOnDisk: absent))
        #expect(!StudioViewModel.hasSatisfactoryIcon(framed, source: .alwaysDraw, iconIsOnDisk: absent))
        #expect(!StudioViewModel.hasSatisfactoryIcon(drawn, source: .preferThumbnail, iconIsOnDisk: absent))
        #expect(!StudioViewModel.hasSatisfactoryIcon(drawn, source: .alwaysDraw, iconIsOnDisk: absent))

        // A remote cover is fetched over the network by the row itself, so
        // whether anything sits under the content root says nothing about it.
        let remote = meeting("https://example.com/cover.jpg")
        #expect(StudioViewModel.hasSatisfactoryIcon(remote, source: .preferThumbnail, iconIsOnDisk: absent))
    }

    @Test("A run reports what it drew separately from what it found")
    func summaryNamesTheBilledWork() {
        let mixed = StudioViewModel.iconRunSummary(
            counts: [.driveThumbnail: 12, .recordingFrame: 3, .generated: 5],
            attempted: 20
        )
        #expect(mixed.contains("15 from recordings"))
        #expect(mixed.contains("5 drawn"))

        // Nothing drawn is worth saying plainly; so is nothing at all.
        let free = StudioViewModel.iconRunSummary(counts: [.driveThumbnail: 2], attempted: 2)
        #expect(!free.contains("drawn"))
        #expect(StudioViewModel.iconRunSummary(counts: [:], attempted: 4).contains("No icons"))
    }
}

// MARK: - OpenRouter maker icons

@Suite("OpenRouter maker icons")
struct OpenRouterMakerIconTests {
    @Test("A maker's page yields the icon its header draws, hosted or favicon")
    func iconFromPage() {
        // The tag shapes openrouter.ai served on 2026-09-28: a hosting
        // provider's icon first, then the maker's own.
        let page = #"""
        <div><img width="256" height="256" alt="Favicon for novita" src="/images/icons/Novita.png"/>
        <img width="256" height="256" alt="Favicon for black-forest-labs" class="h-full w-full object-cover" src="https://t0.gstatic.com/faviconV2?client=SOCIAL&amp;type=FAVICON&amp;fallback_opts=TYPE,SIZE,URL&amp;url=https://bfl.ai&amp;size=256" loading="lazy" decoding="async"/></div>
        """#
        #expect(OpenRouterMakerIcon.iconURL(inPage: page, maker: "black-forest-labs")?.absoluteString
            == "https://t0.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://bfl.ai&size=256")
        #expect(OpenRouterMakerIcon.iconURL(inPage: page, maker: "novita")?.absoluteString
            == "https://openrouter.ai/images/icons/Novita.png")
        #expect(OpenRouterMakerIcon.iconURL(inPage: page, maker: "recraft") == nil)
    }

    @Test("Only an https icon on a plain maker slug is ever fetched")
    func refusesOtherAddresses() {
        #expect(OpenRouterMakerIcon.iconURL(inPage: #"<img alt="Favicon for x" src="http://example.com/x.png">"#, maker: "x") == nil)
        #expect(OpenRouterMakerIcon.iconURL(inPage: #"<img src="data:image/png;base64,AA" alt="Favicon for x">"#, maker: "x") == nil)
        #expect(OpenRouterMakerIcon.pageURL(forMaker: "x-ai")?.absoluteString == "https://openrouter.ai/x-ai")
        for slug in ["", "..", "../keys", "a/b", "x?y", "Meta"] {
            #expect(OpenRouterMakerIcon.pageURL(forMaker: slug) == nil, "\(slug)")
        }
    }
}

// MARK: - PodcastDiscoveryStatus

@Suite("PodcastDiscoveryStatus")
struct PodcastDiscoveryStatusTests {

    @Test("Equatable works for simple cases")
    func equatable() {
        #expect(PodcastDiscoveryStatus.ok == .ok)
        #expect(PodcastDiscoveryStatus.unsupportedPlatform == .unsupportedPlatform)
        #expect(PodcastDiscoveryStatus.appNotInstalled == .appNotInstalled)
        #expect(PodcastDiscoveryStatus.permissionDenied == .permissionDenied)
        #expect(PodcastDiscoveryStatus.noEpisodesFound == .noEpisodesFound)
    }

    @Test("Equatable works for schemaChanged with details")
    func schemaChangedEquatable() {
        let a = PodcastDiscoveryStatus.schemaChanged(details: "missing column")
        let b = PodcastDiscoveryStatus.schemaChanged(details: "missing column")
        let c = PodcastDiscoveryStatus.schemaChanged(details: "different detail")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Equatable works for open failures with details")
    func openFailedEquatable() {
        let a = PodcastDiscoveryStatus.openFailed(details: "temporarily unavailable")
        let b = PodcastDiscoveryStatus.openFailed(details: "temporarily unavailable")
        let c = PodcastDiscoveryStatus.openFailed(details: "different failure")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Different statuses are not equal")
    func differentStatuses() {
        #expect(PodcastDiscoveryStatus.ok != .appNotInstalled)
        #expect(PodcastDiscoveryStatus.permissionDenied != .noEpisodesFound)
    }

    @Test("A non-permission SQLite open failure is not reported as access denial")
    func nonPermissionOpenFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastOpenFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = SourceDiscovery.openPodcastsDB(at: directory.path)
        guard case .openFailed = result.status else {
            Issue.record("Expected a non-permission open failure, got \(result.status)")
            return
        }
    }
}

// MARK: - CourseProgress

@Suite("CourseProgress")
struct CourseProgressTests {
    private func video(finished: Bool = false, started: Bool = false) -> CourseProgress.Item {
        CourseProgress.Item(isLectureVideo: true, isFinished: finished, isStarted: started)
    }

    private func material(finished: Bool = false, started: Bool = false) -> CourseProgress.Item {
        CourseProgress.Item(isLectureVideo: false, isFinished: finished, isStarted: started)
    }

    @Test("Lecture videos alone decide completion while the course has any")
    func videosDecideCompletion() {
        let progress = CourseProgress(items: [video(finished: true), video(finished: true), material()])
        #expect(progress.total == 2)
        #expect(progress.isComplete)
        #expect(progress.summary == "All 2 lectures finished")
    }

    @Test("A course without videos counts every lecture item")
    func readingOnlyCourse() {
        let progress = CourseProgress(items: [material(finished: true), material(), material()])
        #expect(progress.total == 3)
        #expect(!progress.isComplete)
        #expect(progress.summary == "1 of 3 items finished")
    }

    @Test("A begun lecture starts the course before any lecture is finished")
    func startedWithoutFinishing() {
        let progress = CourseProgress(items: [video(started: true), video()])
        #expect(progress.isStarted)
        #expect(progress.finished == 0)
        #expect(progress.fractionFinished == 0)
        #expect(progress.summary == "0 of 2 lectures finished")
    }

    @Test("An untouched or empty course is neither started nor complete")
    func untouchedAndEmpty() {
        let untouched = CourseProgress(items: [video(), video()])
        #expect(!untouched.isStarted)
        #expect(!untouched.isComplete)
        let empty = CourseProgress(items: [])
        #expect(!empty.isStarted)
        #expect(!empty.isComplete)
        #expect(empty.fractionFinished == 0)
    }
}

// MARK: - VideoWatchProgress

@Suite("VideoWatchProgress")
struct VideoWatchProgressTests {

    @Test("Round trip through the encoded locator string")
    func roundTrip() {
        let progress = VideoWatchProgress(positionSeconds: 421.6, watchedSeconds: 900.2, durationSeconds: 3600.4)
        let decoded = VideoWatchProgress(encoded: progress.encoded)
        #expect(decoded == progress)
        #expect(decoded?.positionSeconds == 422)
        #expect(decoded?.watchedSeconds == 900)
        #expect(decoded?.durationSeconds == 3600)
    }

    @Test("Watched high-water never trails the position")
    func watchedFloor() {
        let progress = VideoWatchProgress(positionSeconds: 500, watchedSeconds: 100, durationSeconds: nil)
        #expect(progress.watchedSeconds == 500)
    }

    @Test("Rejects non-video locators and garbage")
    func rejectsForeignLocators() {
        let epubLocator = #"{"relativePath":"ch3.xhtml","scrollFraction":0.42}"#
        #expect(VideoWatchProgress(encoded: epubLocator) == nil)
        #expect(VideoWatchProgress(encoded: "not json") == nil)
        #expect(VideoWatchProgress(encoded: nil) == nil)
        #expect(VideoWatchProgress(encoded: "") == nil)
    }

    @Test("Invalid durations are dropped, fraction needs a duration")
    func durationValidation() {
        #expect(VideoWatchProgress(positionSeconds: 10, watchedSeconds: 10, durationSeconds: 0).durationSeconds == nil)
        #expect(VideoWatchProgress(positionSeconds: 10, watchedSeconds: 10, durationSeconds: -5).durationSeconds == nil)
        #expect(VideoWatchProgress(positionSeconds: 10, watchedSeconds: 10, durationSeconds: .infinity).durationSeconds == nil)
        #expect(VideoWatchProgress(positionSeconds: 10, watchedSeconds: 10, durationSeconds: nil).fractionWatched == nil)
    }

    @Test("Fraction is clamped to 1 even when watched overshoots the duration")
    func fractionClamped() {
        let progress = VideoWatchProgress(positionSeconds: 3700, watchedSeconds: 3700, durationSeconds: 3600)
        #expect(progress.fractionWatched == 1)
    }

    @Test("Essentially watched at 95% or within the final 30 seconds")
    func essentiallyWatched() {
        #expect(VideoWatchProgress(positionSeconds: 3420, watchedSeconds: 3420, durationSeconds: 3600).isEssentiallyWatched)
        #expect(VideoWatchProgress(positionSeconds: 580, watchedSeconds: 580, durationSeconds: 600).isEssentiallyWatched)
        #expect(!VideoWatchProgress(positionSeconds: 1800, watchedSeconds: 1800, durationSeconds: 3600).isEssentiallyWatched)
        #expect(!VideoWatchProgress(positionSeconds: 5000, watchedSeconds: 5000, durationSeconds: nil).isEssentiallyWatched)
    }

    @Test("Display label: percentage, Watched, minute fallback, nil when trivial")
    func displayLabels() {
        #expect(VideoWatchProgress(positionSeconds: 1512, watchedSeconds: 1512, durationSeconds: 3600).displayLabel == "42% watched")
        #expect(VideoWatchProgress(positionSeconds: 3550, watchedSeconds: 3550, durationSeconds: 3600).displayLabel == "Watched")
        #expect(VideoWatchProgress(positionSeconds: 300, watchedSeconds: 300, durationSeconds: nil).displayLabel == "5 min watched")
        #expect(VideoWatchProgress(positionSeconds: 10, watchedSeconds: 10, durationSeconds: 3600).displayLabel == nil)
        #expect(VideoWatchProgress(positionSeconds: 30, watchedSeconds: 30, durationSeconds: nil).displayLabel == nil)
    }

    @Test("Percentage label never reads 100% without the Watched state")
    func percentCap() {
        // 94.9% — under the essentially-watched threshold but rounds to 95;
        // the cap keeps the label under 100 regardless.
        let progress = VideoWatchProgress(positionSeconds: 3000, watchedSeconds: 3416, durationSeconds: 3600)
        #expect(progress.displayLabel == "95% watched")
    }

    @Test("Resume skips trivial head starts and essentially finished videos")
    func resumePolicy() {
        #expect(VideoWatchProgress(positionSeconds: 20, watchedSeconds: 20, durationSeconds: 3600).resumeSeconds == nil)
        #expect(VideoWatchProgress(positionSeconds: 3580, watchedSeconds: 3580, durationSeconds: 3600).resumeSeconds == nil)
        #expect(VideoWatchProgress(positionSeconds: 3550, watchedSeconds: 3550, durationSeconds: 3600).resumeSeconds == nil)
        #expect(VideoWatchProgress(positionSeconds: 1800, watchedSeconds: 1800, durationSeconds: 3600).resumeSeconds == 1800)
        #expect(VideoWatchProgress(positionSeconds: 240, watchedSeconds: 240, durationSeconds: nil).resumeSeconds == 240)
    }

    // MARK: Mark as Watched / Mark as Not Watched (product owner, 2026-09-27)

    private static let markTime = Date(timeIntervalSinceReferenceDate: 812_345_678)

    @Test("Progress without an epoch encodes exactly as it always did")
    func legacyEncodingUnchanged() {
        #expect(
            VideoWatchProgress(positionSeconds: 300, watchedSeconds: 600, durationSeconds: 900).encoded
                == #"{"durationSeconds":900,"positionSeconds":300,"watchedSeconds":600}"#
        )
        #expect(VideoWatchProgress(encoded: #"{"positionSeconds":421,"watchedSeconds":900}"#)?.unwatchedAt == nil)
    }

    @Test("Mark as Not Watched clears the watching, keeps the length and stamps an epoch")
    func notWatchedClearsWatching() throws {
        let watched = VideoWatchProgress(positionSeconds: 3500, watchedSeconds: 3550, durationSeconds: 3600)
        #expect(watched.displayLabel == "Watched")

        let reset = VideoWatchProgress.notWatched(from: watched, at: Self.markTime.addingTimeInterval(0.4))
        #expect(reset.positionSeconds == 0)
        #expect(reset.watchedSeconds == 0)
        #expect(reset.durationSeconds == 3600)
        #expect(reset.unwatchedAt == Self.markTime)
        #expect(!reset.isEssentiallyWatched)
        #expect(!reset.recordsWatching)
        #expect(reset.displayLabel == nil)
        #expect(reset.resumeSeconds == nil)
        let encoded = try #require(reset.encoded)
        #expect(encoded == #"{"durationSeconds":3600,"positionSeconds":0,"unwatchedAt":812345678,"watchedSeconds":0}"#)
        #expect(VideoWatchProgress(encoded: encoded) == reset)
    }

    @Test("Each Mark as Not Watched is a later epoch, even within one second or on a slow clock")
    func notWatchedEpochsOnlyMoveForward() throws {
        let first = VideoWatchProgress.notWatched(from: nil, at: Self.markTime)
        let sameSecond = VideoWatchProgress.notWatched(from: first, at: Self.markTime.addingTimeInterval(0.3))
        let slowClock = VideoWatchProgress.notWatched(from: first, at: Self.markTime.addingTimeInterval(-3600))
        #expect(try #require(sameSecond.unwatchedAt) > (try #require(first.unwatchedAt)))
        #expect(slowClock.unwatchedAt == Self.markTime.addingTimeInterval(1))
    }

    @Test("A video under half a minute marked not watched does not read Watched")
    func shortVideoNotWatchedBeforeWatching() {
        let short = VideoWatchProgress(positionSeconds: 20, watchedSeconds: 20, durationSeconds: 25)
        #expect(short.isEssentiallyWatched)
        #expect(!VideoWatchProgress.notWatched(from: short, at: Self.markTime).isEssentiallyWatched)
    }

    @Test("Mark as Watched needs the length and finishes the video")
    func markedWatchedNeedsLength() throws {
        #expect(VideoWatchProgress(positionSeconds: 300, watchedSeconds: 300, durationSeconds: nil).markedWatched() == nil)
        let partial = VideoWatchProgress(positionSeconds: 1200, watchedSeconds: 1500, durationSeconds: 3600, unwatchedAt: Self.markTime)
        let finished = try #require(partial.markedWatched())
        #expect(finished.watchedSeconds == 3600)
        #expect(finished.displayLabel == "Watched")
        #expect(finished.resumeSeconds == nil)
        #expect(finished.unwatchedAt == Self.markTime)
    }

    @Test("Only a video marked not watched with nothing played since is no saved position")
    func unwatchedMarkerIsNoPosition() throws {
        let reset = VideoWatchProgress.notWatched(
            from: VideoWatchProgress(positionSeconds: 3500, watchedSeconds: 3550, durationSeconds: 3600),
            at: Self.markTime
        )
        var video = StudioArticle(url: "https://www.youtube.com/watch?v=marker", title: "Lecture", sourceType: .video)
        video.readingPositionLocator = reset.encoded
        #expect(VideoWatchProgress.isUnwatchedMarker(video.readingPositionLocator))
        #expect(!video.hasSavedReadingPosition)

        video.readingPositionLocator = reset.advanced(to: 120, durationSeconds: nil).encoded
        #expect(!VideoWatchProgress.isUnwatchedMarker(video.readingPositionLocator))
        #expect(video.hasSavedReadingPosition)

        video.readingPositionLocator = #"{"relativePath":"ch3.xhtml","scrollFraction":0.42}"#
        #expect(video.hasSavedReadingPosition)
    }

    @Test("A reader's tracker gives way to a mark made while the video is open")
    func trackerContinuesOverMarks() throws {
        let live = VideoWatchProgress(positionSeconds: 1800, watchedSeconds: 3550, durationSeconds: 3600)
        let reset = VideoWatchProgress.notWatched(from: live, at: Self.markTime)
        #expect(VideoWatchProgress.continuing(live, over: reset) == reset)

        let rewatching = reset.advanced(to: 200, durationSeconds: nil)
        let finished = try #require(reset.markedWatched())
        let lifted = try #require(VideoWatchProgress.continuing(rewatching, over: finished))
        #expect(lifted.positionSeconds == 200)
        #expect(lifted.watchedSeconds == 3600)
        #expect(VideoWatchProgress.continuing(nil, over: live) == live)
    }

    @Test("The progress store takes a marked video out of In progress and redraws its course")
    @MainActor
    func progressStoreFollowsNotWatched() throws {
        let store = StudioReadingProgressStore()
        let watched = VideoWatchProgress(positionSeconds: 3500, watchedSeconds: 3550, durationSeconds: 3600)
        store.setLocator(try #require(watched.encoded), for: "lecture")
        #expect(store.hasProgress(for: "lecture"))
        let finishedRevision = store.finishedVideoRevision

        let reset = VideoWatchProgress.notWatched(from: watched, at: Self.markTime)
        store.setLocator(try #require(reset.encoded), for: "lecture")
        #expect(!store.hasProgress(for: "lecture"))
        #expect(store.videoWatchProgress(for: "lecture", fallbackLocator: nil)?.isEssentiallyWatched == false)
        // Leaving watched moves the observed revision too, so a course's
        // completion mark redraws without waiting for the next playhead write.
        #expect(store.finishedVideoRevision == finishedRevision + 1)

        store.setLocator(try #require(reset.advanced(to: 90, durationSeconds: nil).encoded), for: "lecture")
        #expect(store.hasProgress(for: "lecture"))
    }

    @Test("Only videos and YouTube course lectures offer the watched marks")
    func watchedMarksAreForVideos() {
        #expect(StudioArticle(url: "https://www.youtube.com/watch?v=a", title: "V", sourceType: .video).offersWatchedMarks)
        #expect(StudioArticle(url: "https://www.youtube.com/watch?v=b", title: "L", sourceType: .course).offersWatchedMarks)
        #expect(!StudioArticle(url: "https://example.com/lecture.pdf", title: "PDF", sourceType: .course).offersWatchedMarks)
        #expect(!StudioArticle(url: "https://www.youtube.com/watch?v=c", title: "M", sourceType: .meeting).offersWatchedMarks)
        #expect(!StudioArticle(url: "https://example.com/a", title: "A", sourceType: .article).offersWatchedMarks)
    }

    @Test("Watch URL gains a t parameter, replacing any stale one")
    func resumeURL() throws {
        let plain = try #require(URL(string: "https://www.youtube.com/watch?v=abc123"))
        let resumed = YouTubeWatchPageView.loadURL(for: plain, resumeSeconds: 421)
        #expect(resumed.absoluteString == "https://www.youtube.com/watch?v=abc123&t=421s")

        let stale = try #require(URL(string: "https://www.youtube.com/watch?v=abc123&t=9s"))
        let replaced = YouTubeWatchPageView.loadURL(for: stale, resumeSeconds: 421)
        #expect(replaced.absoluteString == "https://www.youtube.com/watch?v=abc123&t=421s")

        let short = try #require(URL(string: "https://youtu.be/abc123"))
        let shortResumed = YouTubeWatchPageView.loadURL(for: short, resumeSeconds: 90)
        #expect(shortResumed.absoluteString == "https://youtu.be/abc123?t=90s")

        #expect(YouTubeWatchPageView.loadURL(for: plain, resumeSeconds: nil) == plain)
        #expect(YouTubeWatchPageView.loadURL(for: plain, resumeSeconds: 0.4) == plain)
    }
}

// MARK: - ArticleReadingPositionLocator

@Suite("ArticleReadingPositionLocator")
struct ArticleReadingPositionLocatorTests {

    @Test("Round trip through the encoded locator string")
    func roundTrip() {
        let locator = ArticleReadingPositionLocator(scrollFraction: 0.42137)
        let decoded = ArticleReadingPositionLocator(encoded: locator.encoded)
        #expect(decoded == locator)
        #expect(decoded?.webScrollFraction == 0.4214)
    }

    @Test("Fraction is clamped to 0...1 and rounded for stable encoding")
    func clampingAndRounding() {
        #expect(ArticleReadingPositionLocator(scrollFraction: -0.5).webScrollFraction == 0)
        #expect(ArticleReadingPositionLocator(scrollFraction: 1.7).webScrollFraction == 1)
        let first = ArticleReadingPositionLocator(scrollFraction: 0.12341).encoded
        let second = ArticleReadingPositionLocator(scrollFraction: 0.12344).encoded
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("Rejects non-article locators and garbage")
    func rejectsForeignLocators() {
        let epubLocator = #"{"relativePath":"ch3.xhtml","scrollFraction":0.42}"#
        let videoLocator = #"{"positionSeconds":421,"watchedSeconds":900,"durationSeconds":3600}"#
        #expect(ArticleReadingPositionLocator(encoded: epubLocator) == nil)
        #expect(ArticleReadingPositionLocator(encoded: videoLocator) == nil)
        #expect(ArticleReadingPositionLocator(encoded: "not json") == nil)
        #expect(ArticleReadingPositionLocator(encoded: nil) == nil)
        #expect(ArticleReadingPositionLocator(encoded: "") == nil)
    }

    @Test("Other locator types never decode an article locator")
    func foreignTypesRejectArticleLocator() {
        let articleLocator = ArticleReadingPositionLocator(scrollFraction: 0.42).encoded
        #expect(EPUBReadingPositionLocator(encoded: articleLocator) == nil)
        #expect(VideoWatchProgress(encoded: articleLocator) == nil)
    }
}

// MARK: - SourceProgressDepth

@Suite("SourceProgressDepth")
struct SourceProgressDepthTests {

    @Test("A web scroll position is the article's depth")
    func webScrollFraction() throws {
        let locator = try #require(ArticleReadingPositionLocator(scrollFraction: 0.62).encoded)
        #expect(SourceProgressDepth.fraction(locator: locator) == 0.62)
    }

    @Test("A video's watched share is its depth, and an unknown duration yields none")
    func videoWatchedFraction() throws {
        let watched = VideoWatchProgress(positionSeconds: 300, watchedSeconds: 450, durationSeconds: 900)
        #expect(SourceProgressDepth.fraction(locator: try #require(watched.encoded)) == 0.5)

        let unknownDuration = VideoWatchProgress(positionSeconds: 300, watchedSeconds: 450, durationSeconds: nil)
        #expect(SourceProgressDepth.fraction(locator: try #require(unknownDuration.encoded)) == nil)
    }

    @Test("A book chapter's locator measures that chapter, which is its own source")
    func chapterScrollFraction() throws {
        let locator = try #require(
            EPUBReadingPositionLocator(relativePath: "ch3.xhtml", scrollFraction: 0.4).encoded
        )
        #expect(SourceProgressDepth.fraction(locator: locator) == 0.4)
    }

    @Test("Nothing readable yields no depth rather than a zero")
    func unreadableLocators() {
        #expect(SourceProgressDepth.fraction(locator: nil) == nil)
        #expect(SourceProgressDepth.fraction(locator: "") == nil)
        #expect(SourceProgressDepth.fraction(locator: "not json") == nil)
    }

    @Test("The last PDF page is a full read, whatever it contains")
    func pageDepth() {
        #expect(SourceProgressDepth.fraction(pageIndex: 0, pageCount: 11) == 0)
        #expect(SourceProgressDepth.fraction(pageIndex: 5, pageCount: 11) == 0.5)
        #expect(SourceProgressDepth.fraction(pageIndex: 10, pageCount: 11) == 1)
        // A one-page document is finished the moment it is on screen.
        #expect(SourceProgressDepth.fraction(pageIndex: 0, pageCount: 1) == 1)
        #expect(SourceProgressDepth.fraction(pageIndex: 0, pageCount: 0) == nil)
        #expect(SourceProgressDepth.fraction(pageIndex: -1, pageCount: 10) == nil)
    }
}

// MARK: - SourceConsumption

@Suite("SourceConsumption")
struct SourceConsumptionTests {

    private let added = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func signals(
        readAt: Date? = nil,
        page: Int? = nil,
        locator: String? = nil,
        maxFraction: Double = 0,
        deepestActivityAt: Date? = nil
    ) -> SourceConsumptionSignals {
        SourceConsumptionSignals(
            readAt: readAt,
            readingPositionPage: page,
            readingPositionLocator: locator,
            dateAdded: added,
            maxFraction: maxFraction,
            deepestActivityAt: deepestActivityAt
        )
    }

    @Test("A source that was merely added is not consumed")
    func bareSourceIsNotConsumed() {
        #expect(SourceConsumption.consumedAt(signals()) == nil)
        #expect(SourceConsumption.isConsumed(signals()) == false)
    }

    @Test("An explicit read date is consumption, and is the reported date")
    func readAtWins() {
        let read = added.addingTimeInterval(86_400 * 3)
        #expect(SourceConsumption.consumedAt(signals(readAt: read)) == read)
    }

    @Test("Reader position never guesses consumption")
    func positionsDoNotImplyConsumption() {
        #expect(SourceConsumption.consumedAt(signals(page: 0)) == nil)
        #expect(SourceConsumption.consumedAt(signals(page: 1)) == nil)
        #expect(SourceConsumption.consumedAt(signals(page: 40)) == nil)
        let skimmed = ArticleReadingPositionLocator(scrollFraction: 0.1).encoded
        let articleRead = ArticleReadingPositionLocator(scrollFraction: 0.62).encoded
        #expect(SourceConsumption.consumedAt(signals(locator: skimmed)) == nil)
        #expect(SourceConsumption.consumedAt(signals(locator: articleRead)) == nil)
        let opened = EPUBReadingPositionLocator(relativePath: "ch3.xhtml", scrollFraction: 0.05).encoded
        let epubRead = EPUBReadingPositionLocator(relativePath: "ch3.xhtml", scrollFraction: 0.8).encoded
        #expect(SourceConsumption.consumedAt(signals(locator: opened)) == nil)
        #expect(SourceConsumption.consumedAt(signals(locator: epubRead)) == nil)
        let sampled = VideoWatchProgress(positionSeconds: 60, watchedSeconds: 120, durationSeconds: 3600).encoded
        let watched = VideoWatchProgress(positionSeconds: 60, watchedSeconds: 1900, durationSeconds: 3600).encoded
        #expect(SourceConsumption.consumedAt(signals(locator: sampled)) == nil)
        #expect(SourceConsumption.consumedAt(signals(locator: watched)) == nil)
    }

    @Test("A podcast qualifies only by being marked read — transcripts save no position")
    func podcastsNeedAnExplicitReadMark() {
        // The transcript readers persist neither page nor locator, so an unheard
        // episode has nothing but date_added and must not enter review.
        #expect(SourceConsumption.consumedAt(signals()) == nil)
        let completed = added.addingTimeInterval(86_400)
        #expect(SourceConsumption.consumedAt(signals(readAt: completed)) == completed)
    }

    @Test("Unrecognized locator payloads are not evidence of consumption")
    func garbageLocator() {
        #expect(SourceConsumption.consumedAt(signals(locator: "not json")) == nil)
        #expect(SourceConsumption.consumedAt(signals(locator: "")) == nil)
        #expect(SourceConsumption.consumedAt(signals(locator: #"{"unrelated":1}"#)) == nil)
    }

    // MARK: - Measured depth

    @Test("Measured depth grades consumption instead of guessing a boolean")
    func depthGradesConfidence() {
        #expect(SourceConsumption.confidence(signals()) == SourceConsumptionConfidence.none)
        #expect(SourceConsumption.confidence(signals(maxFraction: 0.1)) == .none)
        #expect(SourceConsumption.confidence(signals(maxFraction: 0.25)) == .partial)
        #expect(SourceConsumption.confidence(signals(maxFraction: 0.59)) == .partial)
        #expect(SourceConsumption.confidence(signals(maxFraction: 0.6)) == .substantial)
        #expect(SourceConsumption.confidence(signals(maxFraction: 0.89)) == .substantial)
        #expect(SourceConsumption.confidence(signals(maxFraction: 0.9)) == .complete)
        #expect(SourceConsumption.confidence(signals(maxFraction: 1)) == .complete)
    }

    @Test("An explicit read date outranks any measured depth")
    func readAtOutranksDepth() {
        let read = added.addingTimeInterval(86_400)
        let deep = added.addingTimeInterval(3_600)
        let s = signals(readAt: read, maxFraction: 0.3, deepestActivityAt: deep)
        #expect(SourceConsumption.confidence(s) == .complete)
        #expect(SourceConsumption.consumedAt(s) == read)
    }

    @Test("A mostly-played source is consumed, dated by when it was reached")
    func substantialDepthIsConsumed() {
        let reached = added.addingTimeInterval(86_400 * 2)
        let s = signals(maxFraction: 0.72, deepestActivityAt: reached)
        // The default threshold is unchanged, so nothing silently widens.
        #expect(SourceConsumption.consumedAt(s) == nil)
        #expect(SourceConsumption.consumedAt(s, minimumConfidence: .substantial) == reached)
        // Never date depth-only evidence by date_added: an auto-ingested backlog
        // would otherwise look consumed the day it was imported.
        #expect(SourceConsumption.consumedAt(s, minimumConfidence: .substantial) != added)
    }

    @Test("A barely-started source stays out of review at every sane threshold")
    func shallowDepthIsNotConsumed() {
        let s = signals(maxFraction: 0.12, deepestActivityAt: added.addingTimeInterval(60))
        #expect(SourceConsumption.consumedAt(s, minimumConfidence: .substantial) == nil)
        #expect(SourceConsumption.consumedAt(s, minimumConfidence: .partial) == nil)
    }

    @Test("Depth-only evidence with no activity date cannot fabricate one")
    func depthWithoutDateIsNotConsumed() {
        let s = signals(maxFraction: 0.95)
        #expect(SourceConsumption.confidence(s) == .complete)
        #expect(SourceConsumption.consumedAt(s) == nil)
    }

    @Test("A nonsense fraction can never reach the schedule")
    func fractionsAreClamped() {
        // Non-finite input is treated as unmeasured, deliberately not as
        // complete: garbage must never promote a source to fully consumed.
        #expect(SourceActivityDay.clampFraction(.nan) == 0)
        #expect(SourceActivityDay.clampFraction(.infinity) == 0)
        #expect(SourceActivityDay.clampFraction(-.infinity) == 0)
        #expect(SourceActivityDay.clampFraction(-3) == 0)
        #expect(SourceActivityDay.clampFraction(4.2) == 1)
        #expect(SourceConsumption.confidence(signals(maxFraction: .nan)) == .none)
        #expect(SourceConsumption.confidence(signals(maxFraction: .infinity)) == .none)
        #expect(SourceConsumption.confidence(signals(maxFraction: 12)) == .complete)
    }

    // MARK: - The engagement ledger

    private func ledger(
        maxFraction: Double,
        engagedSeconds: Double?,
        wordCount: Int? = nil,
        chatDiscussedAt: Date? = nil,
        annotationCount: Int = 0,
        readAt: Date? = nil
    ) -> SourceConsumptionSignals {
        var signals = signals(readAt: readAt, maxFraction: maxFraction, deepestActivityAt: added.addingTimeInterval(86_400))
        signals.engagedSeconds = engagedSeconds
        signals.expectedSeconds = SourceConsumption.expectedSeconds(wordCount: wordCount)
        signals.chatDiscussedAt = chatDiscussedAt
        signals.annotationCount = annotationCount
        return signals
    }

    @Test("Expected time is the word count at a reading pace; the floor is a share of it, never under thirty seconds")
    func timeFloors() {
        #expect(SourceConsumption.expectedSeconds(wordCount: nil) == nil)
        #expect(SourceConsumption.expectedSeconds(wordCount: 0) == nil)
        #expect(SourceConsumption.expectedSeconds(wordCount: 2_500) == 600)
        // Unknown length: two minutes for either level.
        #expect(SourceConsumption.timeFloor(expectedSeconds: nil, level: .complete) == 120)
        #expect(SourceConsumption.timeFloor(expectedSeconds: nil, level: .substantial) == 120)
        // A known length: half for complete, a third for substantial.
        #expect(SourceConsumption.timeFloor(expectedSeconds: 600, level: .complete) == 300)
        #expect(SourceConsumption.timeFloor(expectedSeconds: 600, level: .substantial) == 200)
        // A fifty-word post still needs a pause on it.
        #expect(SourceConsumption.timeFloor(expectedSeconds: 12, level: .complete) == 30)
        // Partial and none are never time-gated.
        #expect(SourceConsumption.timeFloor(expectedSeconds: 600, level: .partial) == 0)
    }

    @Test("A position only counts once enough time went with it")
    func depthIsTimeGated() {
        // No time evidence at all: depth stands, as it did before the ledger.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 1.0, engagedSeconds: nil)) == .complete)
        // Measured time short of every floor: the reading did not happen.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 1.0, engagedSeconds: 0)) == .partial)
        #expect(SourceConsumption.confidence(ledger(maxFraction: 1.0, engagedSeconds: 40, wordCount: 3_000)) == .partial)
        // Enough for substantial but not for complete: the level falls one rung.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 1.0, engagedSeconds: 300, wordCount: 3_000)) == .substantial)
        // Enough time: the position stands.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 1.0, engagedSeconds: 400, wordCount: 3_000)) == .complete)
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0.7, engagedSeconds: 250, wordCount: 3_000)) == .substantial)
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0.7, engagedSeconds: 200, wordCount: 3_000)) == .partial)
        // Unknown length: the two-minute floor.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0.7, engagedSeconds: 119)) == .partial)
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0.7, engagedSeconds: 120)) == .substantial)
        // Shallow depth is partial whatever the time.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0.3, engagedSeconds: 5_000)) == .partial)
        // An explicit read date is the learner's own statement and is never gated.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0.1, engagedSeconds: 0, readAt: added)) == .complete)
    }

    @Test("A chat the learner wrote in is consumption, dated by the conversation")
    func chatDiscussionLifts() {
        let talked = added.addingTimeInterval(10 * 86_400)
        let nothingRead = ledger(maxFraction: 0, engagedSeconds: 0, chatDiscussedAt: talked)
        #expect(SourceConsumption.confidence(nothingRead) == .substantial)
        #expect(SourceConsumption.consumedAt(nothingRead, minimumConfidence: .substantial) == talked)
        // A skim plus a chat is substantial, not complete: the chat says they
        // engaged, not that they finished.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 1.0, engagedSeconds: 10, chatDiscussedAt: talked)) == .substantial)
        // A full read that was also discussed stays complete and is re-dated to the chat.
        let both = ledger(maxFraction: 1.0, engagedSeconds: 900, chatDiscussedAt: talked)
        #expect(SourceConsumption.confidence(both) == .complete)
        #expect(SourceConsumption.consumedAt(both) == talked)
        // A chat older than the reading does not move the date back.
        let earlier = ledger(maxFraction: 1.0, engagedSeconds: 900, chatDiscussedAt: added.addingTimeInterval(-5 * 86_400))
        #expect(SourceConsumption.consumedAt(earlier) == added.addingTimeInterval(86_400))
    }

    @Test("An annotation lifts the level by one")
    func annotationLifts() {
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0.4, engagedSeconds: 600, annotationCount: 1)) == .substantial)
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0.7, engagedSeconds: 600, annotationCount: 3)) == .complete)
        #expect(SourceConsumption.confidence(ledger(maxFraction: 1.0, engagedSeconds: 600, annotationCount: 1)) == .complete)
        // A skim with a highlight is a partial read lifted to substantial, no further.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 1.0, engagedSeconds: 0, annotationCount: 1)) == .substantial)
        // A highlight on a source with no measured depth is worth a partial.
        #expect(SourceConsumption.confidence(ledger(maxFraction: 0, engagedSeconds: 0, annotationCount: 1)) == .partial)
    }

    @Test("A day's time is its measured seconds, or its activity span before the column existed")
    func activityDayEngagedTime() throws {
        let first = added
        let last = added.addingTimeInterval(420)
        let measured = SourceActivityDay(
            id: "m", sourceID: "s", dayStart: first, firstActivityAt: first, lastActivityAt: last,
            kinds: [.reading], completedKinds: [], maxFraction: 0.5, engagedSeconds: 90
        )
        #expect(measured.engagedTime == 90)
        let legacy = SourceActivityDay(
            id: "l", sourceID: "s", dayStart: first, firstActivityAt: first, lastActivityAt: last,
            kinds: [.reading], completedKinds: [], maxFraction: 0.5
        )
        #expect(legacy.engagedTime == 420)
        #expect(SourceActivityDay.engagedSeconds(in: [measured, legacy]) == 510)
        #expect(SourceActivityDay.clampSeconds(.nan) == 0)
        #expect(SourceActivityDay.clampSeconds(-4) == 0)
        #expect(SourceActivityDay.clampSeconds(100_000) == 86_400)

        // A payload from before the column decodes with no time, and a full
        // one round-trips.
        let withoutColumn = """
        {"id":"p","sourceID":"s","dayStart":0,"firstActivityAt":0,"lastActivityAt":60,"kinds":["reading"],"completedKinds":[],"maxFraction":0.4}
        """
        let decoded = try JSONDecoder().decode(SourceActivityDay.self, from: Data(withoutColumn.utf8))
        #expect(decoded.engagedSeconds == 0)
        #expect(decoded.engagedTime == 60)
        let roundTrip = try JSONDecoder().decode(SourceActivityDay.self, from: JSONEncoder().encode(measured))
        #expect(roundTrip.engagedSeconds == 90)
    }

    @Test("The ledger line reads as the learner would say it")
    func ledgerLine() {
        #expect(MemoryReviewLedger().line() == "Yesterday and today: nothing recorded")
        var ledger = MemoryReviewLedger(sourceCount: 1, engagedSeconds: 45)
        #expect(ledger.line() == "Yesterday and today: 1 source · under a minute")
        ledger = MemoryReviewLedger(sourceCount: 9, engagedSeconds: 7_800, chatDiscussedCount: 3, listenedCount: 2)
        #expect(ledger.line() == "Yesterday and today: 9 sources · 2h 10m · 3 discussed in chats · 2 listened")
        #expect(MemoryReviewLedger.durationLabel(seconds: 3_600) == "1h")
        #expect(MemoryReviewLedger.durationLabel(seconds: 0) == "no time recorded")
    }
}

// MARK: - SourceActivityDay depth

@Suite("SourceActivityDay depth")
struct SourceActivityDayDepthTests {

    private let day = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func activity(maxFraction: Double, completed: Set<SourceActivityKind> = []) -> SourceActivityDay {
        SourceActivityDay(
            id: "activity-1",
            sourceID: "source-1",
            dayStart: day,
            firstActivityAt: day,
            lastActivityAt: day,
            kinds: [.listening],
            completedKinds: completed,
            maxFraction: maxFraction
        )
    }

    @Test("A completed day is full depth even when sampling stopped short")
    func completionImpliesFullDepth() {
        let partiallySampled = activity(maxFraction: 0.4, completed: [.listening])
        #expect(partiallySampled.effectiveFraction == 1)
        #expect(partiallySampled.hasMeasuredDepth)
    }

    @Test("An unmeasured day reports no depth rather than zero depth")
    func unmeasuredIsNotZeroDepth() {
        let opened = activity(maxFraction: 0)
        #expect(opened.effectiveFraction == 0)
        #expect(opened.hasMeasuredDepth == false)
    }

    @Test("A pre-v66 payload without maxFraction still decodes")
    func decodesLegacyPayload() throws {
        let legacy = """
        {
          "id": "activity-1",
          "sourceID": "source-1",
          "dayStart": 700000000,
          "firstActivityAt": 700000000,
          "lastActivityAt": 700000000,
          "kinds": ["listening"],
          "completedKinds": []
        }
        """
        let decoded = try JSONDecoder().decode(
            SourceActivityDay.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.maxFraction == 0)
        #expect(decoded.kinds == [.listening])
    }

    @Test("Depth survives an encode/decode round trip")
    func roundTripsDepth() throws {
        let original = activity(maxFraction: 0.63)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SourceActivityDay.self, from: data)
        #expect(decoded == original)
        #expect(decoded.maxFraction == 0.63)
    }

    private func activity(
        id: String,
        dayOffset: Double,
        kinds: Set<SourceActivityKind>,
        maxFraction: Double,
        completed: Set<SourceActivityKind> = []
    ) -> SourceActivityDay {
        let dayStart = day.addingTimeInterval(dayOffset * 86_400)
        return SourceActivityDay(
            id: id,
            sourceID: "source-1",
            dayStart: dayStart,
            firstActivityAt: dayStart,
            lastActivityAt: dayStart.addingTimeInterval(3_600),
            kinds: kinds,
            completedKinds: completed,
            maxFraction: maxFraction
        )
    }

    @Test("The deepest day supplies both the fraction and the date it was reached")
    func deepestPointPicksItsOwnDay() {
        let days = [
            activity(id: "a", dayOffset: 0, kinds: [.listening], maxFraction: 0.2),
            activity(id: "b", dayOffset: 1, kinds: [.listening], maxFraction: 0.7),
            activity(id: "c", dayOffset: 2, kinds: [.listening], maxFraction: 0.4),
        ]
        let deepest = SourceActivityDay.deepestPoint(in: days)
        #expect(deepest?.fraction == 0.7)
        #expect(deepest?.reachedAt == days[1].lastActivityAt)
        #expect(SourceActivityDay.deepestPoint(in: []) == nil)
    }

    @Test("A completed day outranks a deeper-sampled unfinished one")
    func deepestPointPrefersCompletion() {
        let days = [
            activity(id: "a", dayOffset: 0, kinds: [.reading], maxFraction: 0.95),
            activity(
                id: "b",
                dayOffset: 1,
                kinds: [.listening],
                maxFraction: 0.4,
                completed: [.listening]
            ),
        ]
        let deepest = SourceActivityDay.deepestPoint(in: days)
        #expect(deepest?.fraction == 1)
        #expect(deepest?.reachedAt == days[1].lastActivityAt)
    }

    @Test("Only reading, listening and watching count as consuming the source")
    func lastConsumedAtIgnoresTalkingAboutIt() {
        let days = [
            activity(id: "a", dayOffset: 0, kinds: [.listening], maxFraction: 0.5),
            activity(id: "b", dayOffset: 3, kinds: [.chat, .review], maxFraction: 0),
        ]
        #expect(SourceActivityDay.lastConsumedAt(in: days) == days[0].lastActivityAt)
        #expect(SourceActivityDay.lastConsumedAt(in: [days[1]]) == nil)
    }

    @Test("A day that mixes chat with reading still dates the consumption")
    func lastConsumedAtAcceptsMixedDays() {
        let mixed = activity(
            id: "a",
            dayOffset: 0,
            kinds: [.chat, .reading],
            maxFraction: 0.3
        )
        #expect(SourceActivityDay.lastConsumedAt(in: [mixed]) == mixed.lastActivityAt)
    }

    @Test("Depth from activity days alone qualifies a source with no read date")
    func depthOnlyConsumptionQualifiesForIntake() {
        let days = [activity(id: "a", dayOffset: 0, kinds: [.listening], maxFraction: 0.7)]
        let deepest = SourceActivityDay.deepestPoint(in: days)
        let signals = SourceConsumptionSignals(
            readAt: nil,
            readingPositionPage: nil,
            readingPositionLocator: nil,
            dateAdded: day.addingTimeInterval(-30 * 86_400),
            maxFraction: deepest?.fraction ?? 0,
            deepestActivityAt: deepest?.reachedAt
        )
        #expect(SourceConsumption.confidence(signals) == .substantial)
        #expect(
            SourceConsumption.consumedAt(signals, minimumConfidence: .substantial)
                == days[0].lastActivityAt
        )
        // Never dated by when it was added: an auto-ingested backlog would all
        // look consumed on import day.
        #expect(
            SourceConsumption.consumedAt(signals, minimumConfidence: .substantial)
                != signals.dateAdded
        )
    }

    @Test("A hostile payload fraction is clamped on the way in")
    func clampsDecodedFraction() throws {
        let hostile = """
        {
          "id": "activity-1",
          "sourceID": "source-1",
          "dayStart": 700000000,
          "firstActivityAt": 700000000,
          "lastActivityAt": 700000000,
          "kinds": ["listening"],
          "completedKinds": [],
          "maxFraction": 8.5
        }
        """
        let decoded = try JSONDecoder().decode(
            SourceActivityDay.self,
            from: Data(hostile.utf8)
        )
        #expect(decoded.maxFraction == 1)
    }
}

// MARK: - MemoryReviewScheduler — never-reviewed bucket

@Suite("MemoryReviewScheduler never-reviewed bucket")
struct MemoryReviewNewItemTests {

    private let now = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func candidate(_ id: String, daysAgo: Double) -> MemoryReviewNewCandidate {
        MemoryReviewNewCandidate(
            sourceID: id,
            title: "Source \(id)",
            sourceType: "article",
            consumedAt: now.addingTimeInterval(-daysAgo * 86_400)
        )
    }

    @Test("A source consumed today is not yet due for its first review")
    func notDueSameDay() {
        let items = MemoryReviewScheduler.newItems(from: [candidate("a", daysAgo: 0)], now: now, limit: 10)
        #expect(items.isEmpty)
    }

    @Test("A source consumed yesterday is due, longest-waiting first")
    func dueAfterDelay() {
        let items = MemoryReviewScheduler.newItems(
            from: [candidate("a", daysAgo: 1), candidate("b", daysAgo: 9), candidate("c", daysAgo: 0.5)],
            now: now,
            limit: 10
        )
        #expect(items.map(\.sourceID) == ["b", "a"])
        #expect(items[0].daysOverdue == 8)
        #expect(items[1].daysOverdue == 0)
    }

    @Test("Limit caps the batch")
    func limitCaps() {
        let candidates = (1...10).map { candidate("s\($0)", daysAgo: Double($0) + 1) }
        #expect(MemoryReviewScheduler.newItems(from: candidates, now: now, limit: 3).count == 3)
        #expect(MemoryReviewScheduler.newItems(from: candidates, now: now, limit: 0).isEmpty)
    }

    private func split(due: Int, new: Int, limit: Int) -> [Int] {
        let result = MemoryReviewScheduler.splitDailyLimit(dueCount: due, newCount: new, limit: limit)
        return [result.due, result.new]
    }

    @Test("Each bucket is guaranteed half the day when both are full")
    func splitIsEven() {
        #expect(split(due: 20, new: 20, limit: 6) == [3, 3])
        // Odd limits favour refreshes by one, the larger backlog in practice.
        #expect(split(due: 20, new: 20, limit: 5) == [3, 2])
    }

    @Test("A bucket that cannot fill its half hands the slack to the other")
    func splitReallocatesSlack() {
        // A long refresh backlog with nothing newly read: refreshes take the day.
        #expect(split(due: 20, new: 0, limit: 5) == [5, 0])
        // A burst of reading with nothing fading: first reviews take the day.
        #expect(split(due: 0, new: 20, limit: 5) == [0, 5])
        // Partial: new has 1, so refreshes absorb the rest rather than idling.
        #expect(split(due: 20, new: 1, limit: 5) == [4, 1])
    }

    @Test("Neither bucket starves the other when both have a backlog")
    func neitherStarves() {
        let split = MemoryReviewScheduler.splitDailyLimit(dueCount: 50, newCount: 50, limit: 5)
        #expect(split.due > 0)
        #expect(split.new > 0)
        #expect(split.due + split.new == 5)
    }

    @Test("Nothing available yields nothing")
    func emptyInputs() {
        #expect(split(due: 0, new: 0, limit: 5) == [0, 0])
        #expect(split(due: 9, new: 9, limit: 0) == [0, 0])
    }
}

@Suite("Meeting plugin notice")
struct MeetingPluginNoticeTests {
    private let readAIOnly: (MeetingProvider) -> Bool = { $0 == .readAI }

    @Test("Read AI meetings with no plugin hand over the setup prompt, or the setup page without an MCP address")
    func noPluginOffersThePrompt() {
        let notice = MeetingPluginNotice.resolve(
            providersInUse: [.readAI],
            expectsSync: readAIOnly,
            plugins: [],
            hasMCPAddress: true
        )
        #expect(notice?.provider == .readAI)
        #expect(notice?.action == .copySetupPrompt)
        #expect(notice?.actionTitle == "Copy Setup Prompt")
        #expect(notice?.message.hasPrefix("Read AI meetings aren't syncing") == true)
        // Nothing was ever connected here for ForeverLM to reconnect.
        #expect(notice?.message.localizedCaseInsensitiveContains("reconnect") == false)
        #expect(notice?.message.localizedCaseInsensitiveContains("disconnected") == false)

        let withoutMCP = MeetingPluginNotice.resolve(
            providersInUse: [.readAI],
            expectsSync: readAIOnly,
            plugins: [],
            hasMCPAddress: false
        )
        #expect(withoutMCP?.action == .openBuildYourOwn)
        #expect(withoutMCP?.actionTitle == "Set Up…")
    }

    @Test("A healthy plugin whose name leads with the brand silences the notice")
    func brandedHealthyPluginIsRecognised() {
        let notice = MeetingPluginNotice.resolve(
            providersInUse: [.readAI],
            expectsSync: readAIOnly,
            plugins: [.init(name: "Read AI Meetings", trouble: nil)],
            hasMCPAddress: true
        )
        #expect(notice == nil)
    }

    @Test("A troubled plugin's notice repeats what it reported and points at its status")
    func troubledPluginShowsItsReport() {
        let notice = MeetingPluginNotice.resolve(
            providersInUse: [.readAI],
            expectsSync: readAIOnly,
            plugins: [.init(name: "Read AI Meetings", trouble: "needs to sign in again — Read AI: refresh rejected (401). Run login --reconnect")],
            hasMCPAddress: true
        )
        #expect(notice?.action == .showPluginStatus)
        #expect(notice?.actionTitle == "Details")
        #expect(notice?.message == "Read AI Meetings needs to sign in again — Read AI: refresh rejected (401). Run login --reconnect")
    }

    @Test("One healthy plugin for a provider outweighs an abandoned one")
    func healthyPluginOutweighsAbandoned() {
        let notice = MeetingPluginNotice.resolve(
            providersInUse: [.readAI],
            expectsSync: readAIOnly,
            plugins: [
                .init(name: "Read AI (old laptop)", trouble: "last checked in 3 weeks ago — its schedule may have stopped"),
                .init(name: "Read AI Meetings", trouble: nil),
            ],
            hasMCPAddress: true
        )
        #expect(notice == nil)
    }

    @Test("Providers that don't expect a plugin raise nothing")
    func nothingWithoutExpectation() {
        let notice = MeetingPluginNotice.resolve(
            providersInUse: [.googleDrive, .zoom, .localFolder],
            expectsSync: readAIOnly,
            plugins: [],
            hasMCPAddress: true
        )
        #expect(notice == nil)
    }
}

@Suite("User plugin setup prompt")
struct UserPluginSetupPromptTests {
    @Test("The generic prompt asks for a build and leaves the blank")
    func genericPromptAsksForABuild() {
        let url = "https://abc123.foreverlm.com"
        let generic = UserPluginSetupPrompt.text(mcpURL: url)
        #expect(generic.hasPrefix("Build me a plugin that syncs [WHAT — e.g. my Readwise highlights] into ForeverLM"))
        #expect(generic.contains("\n\nForeverLM exposes an MCP server (Streamable HTTP) at my personal URL:\n\(url)\n\n"))
        #expect(generic.contains("POST \(url)/oauth/register"))
        // Meetings carry their own date and series; the recipe has to say so
        // or a plugin dates every meeting by its push.
        #expect(generic.contains("occurred_at"))
        #expect(generic.contains("parent_group"))
        // A moved personal URL is asked of this Mac's ForeverLM, not copied by
        // hand, and a forgotten registration is never reused.
        #expect(generic.contains("GET http://127.0.0.1:\(ForeverLMRuntimeIdentity.mcpLoopbackPort)/mcp-url"))
        #expect(generic.contains("502, 503 or 504"))
        #expect(generic.contains("invalid_client"))
        #expect(generic.contains("never reuses the old client_id"))
        #expect(!generic.contains("stopped arriving"))
        #expect(!generic.contains("Notes for"))
    }

    @Test("The Meetings tab's prompt asks for the existing plugin to be found and reconnected before another is built")
    func meetingsPromptReconnectsBeforeBuilding() {
        let url = "https://abc123.foreverlm.com"
        let readAI = UserPluginSetupPrompt.text(mcpURL: url, for: .readAI)
        #expect(readAI.hasPrefix("My Read AI meetings have stopped arriving in ForeverLM."))
        #expect(readAI.contains("start by finding it rather than building a new one"))
        #expect(readAI.contains("Reconnect only the half that dropped, keep its existing ForeverLM registration"))
        #expect(readAI.contains("Only if no plugin is left, build me one that syncs my Read AI meetings into ForeverLM"))
        #expect(!readAI.contains("[WHAT"))
        // The contract still follows in full, with the provider's notes.
        #expect(readAI.contains("\n\nForeverLM exposes an MCP server (Streamable HTTP) at my personal URL:\n\(url)\n\n"))
        #expect(readAI.contains("POST \(url)/oauth/register"))
        #expect(readAI.contains("\"client_name\" that starts with \"Read AI\""))
        #expect(readAI.contains("occurred_at from the meeting's start time"))
        #expect(readAI.contains("parent_group set to the series name"))
        #expect(readAI.contains("report_connector_status"))
    }
}

@Suite("User plugin attention summary")
struct UserPluginAttentionSummaryTests {
    private func plugin(
        state: MCPOAuthProvider.UserPluginHealthState?,
        detail: String? = nil,
        lastSeenAt: Date? = Date()
    ) -> MCPOAuthProvider.UserPluginSummary {
        MCPOAuthProvider.UserPluginSummary(
            id: "client-1",
            name: "Read AI Meetings",
            logoURI: nil,
            lastSeenAt: lastSeenAt,
            lastSuccessfulSyncAt: nil,
            reportedState: state,
            statusDetail: detail
        )
    }

    @Test("A healthy plugin has nothing to say")
    func healthyIsSilent() {
        #expect(plugin(state: .healthy).attentionSummary == nil)
        #expect(plugin(state: nil, lastSeenAt: nil).attentionSummary == nil)
    }

    @Test("A broken sign-in repeats the plugin's own detail, which names the fix")
    func reconnectCarriesTheDetail() {
        let summary = plugin(state: .needsReconnect, detail: "Read AI: refresh rejected (401). Run login --reconnect").attentionSummary
        #expect(summary == "needs to sign in again — Read AI: refresh rejected (401). Run login --reconnect")
        #expect(plugin(state: .needsReconnect).attentionSummary == "needs to sign in again — run its login to get the latest")
    }

    @Test("A failed run and a silent schedule are named for what they are, not as a reconnect")
    func errorAndStaleAreNamed() {
        #expect(plugin(state: .error).attentionSummary == "failed on its last run")
        let stale = plugin(state: .healthy, lastSeenAt: Date().addingTimeInterval(-3 * 24 * 60 * 60)).attentionSummary
        #expect(stale?.hasPrefix("last checked in") == true)
        #expect(stale?.contains("schedule may have stopped") == true)
        #expect(stale?.localizedCaseInsensitiveContains("reconnect") == false)
    }
}
