// The stored content hydration and Reader page tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

// MARK: - Stored Content Hydration

/// A remote paper's row loads without its text, and the reader renders from
/// the loaded model, so opening one has to teach the model what storage holds.
@Suite("Stored Content Hydration")
@MainActor
struct StoredContentHydrationTests {
    private func storeAndViewModel() throws -> (StorageService, StudioViewModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredContentHydrationTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        return (service, StudioViewModel(storageService: service), tmp)
    }

    @Test("A paper whose text is in the store gets it on open")
    func storedPaperTextIsHydrated() async throws {
        let (service, vm, tmp) = try storeAndViewModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Canonical text only reaches `source_content` for a paper the store
        // accepts as ready, which means an attested metadata stage — the same
        // shape the live library has for a paper whose text arrived without a
        // PDF. A paper short of that stages its text as raw instead.
        var paper = makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02421-x",
            sourceType: .paper,
            state: .error
        )
        paper.author = "Chen, L."
        paper.journal = "Nature Neuroscience"
        paper.publishedYear = "2026"
        let attested = paper.completePaperMetadataFromManualEntry()
        #expect(attested)
        let text = "Addictive substances hijack the brain's reward system, driving dopamine surges."
        paper.installPreparedPaperContent(
            raw: text,
            clean: text,
            metadata: PaperContentPreparationMetadata(
                cleanerVersion: PaperContentPreparationMetadata.currentVersion,
                rawSHA256: PaperContentPreparationService.sha256(text),
                cleanSHA256: PaperContentPreparationService.sha256(text),
                preparedAt: Date()
            )
        )
        paper.state = .ready
        try await service.saveSource(paper)

        // The library loads a paper's row without its text.
        paper.content = nil
        vm.articles = [paper]
        await vm.hydrateStoredContent(for: paper.id)

        #expect(vm.articles[0].content == text)
        #expect((vm.articles[0].wordCount ?? 0) > 0)
    }

    @Test("Text already loaded is left alone, and a stored bot check is refused")
    func loadedTextWinsAndWallsAreRefused() async throws {
        let (service, vm, tmp) = try storeAndViewModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        var paper = makeArticle(url: "https://example.org/paper", sourceType: .paper, state: .error)
        paper.content = "Stored text."
        try await service.saveSource(paper)
        paper.content = "The text the reader already has."
        vm.articles = [paper]
        await vm.hydrateStoredContent(for: paper.id)
        #expect(vm.articles[0].content == "The text the reader already has.")

        var walled = makeArticle(
            url: "https://www.science.org/doi/10.1126/science.abc1234",
            sourceType: .paper,
            state: .error
        )
        walled.content = """
        www.science.org
        Verify you are human by completing the action below.
        Performance & security by Cloudflare
        """
        try await service.saveSource(walled)
        walled.content = nil
        vm.articles = [walled]
        await vm.hydrateStoredContent(for: walled.id)
        #expect(vm.articles[0].content == nil)
    }
}

// MARK: - Reader Page Identity

@Suite("Reader Page Identity")
struct ReaderPageIdentityTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("A sign-in round trip returning with added query is still the article")
    func addedQueryIsTheSameDocument() {
        let source = url("https://www.nature.com/articles/s41593-026-02421-x")
        #expect(ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://www.nature.com/articles/s41593-026-02421-x?proof=t"),
            sourceURL: source
        ))
        #expect(ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://www.nature.com/articles/s41593-026-02421-x/"),
            sourceURL: source
        ))
    }

    @Test("Another article, host, or the publisher's login is not the article")
    func otherPagesAreNotTheSameDocument() {
        let source = url("https://www.nature.com/articles/s41593-026-02421-x")
        #expect(!ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://www.nature.com/articles/s41586-023-06600-9"),
            sourceURL: source
        ))
        #expect(!ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://idp.nature.com/authorize?response_type=code"),
            sourceURL: source
        ))
        #expect(!ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("file:///Users/someone/Library/ForeverLM/Articles/a/article.html"),
            sourceURL: source
        ))
    }

    @Test("A source whose query identifies the document keeps query significant")
    func queryBearingSourceIsCompared() {
        let source = url("https://openreview.net/forum?id=abc123")
        #expect(!ArticleReaderPageIdentity.isSameDocumentIgnoringAddedQuery(
            url("https://openreview.net/forum?id=different"),
            sourceURL: source
        ))
    }
}

// MARK: - Reader Remote PDF Abandonment

/// A publisher that refuses the PDF leaves the reader with either text
/// ForeverLM already holds or the publisher's own page. Both beat a lock
/// screen, and this decides which the reader shows.
@Suite("Reader Remote PDF Abandonment")
@MainActor
struct ReaderRemotePDFAbandonmentTests {
    private func paper() -> StudioArticle {
        makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02421-x",
            title: "Mitochondrial calcium influx-driven bioenergetics",
            sourceType: .paper,
            state: .error
        )
    }

    @Test("A paper with no PDF and a publisher page gives up on the PDF")
    func paperWithPublisherPageQualifies() {
        let vm = makeViewModel()
        let article = paper()
        vm.articles = [article]
        #expect(vm.readerShouldAbandonRemotePDF(article.id))
    }

    @Test("A paper whose text is stored gives up even with no page to show")
    func paperWithStoredTextQualifies() {
        let vm = makeViewModel()
        var direct = makeArticle(
            url: "https://example.org/paper.pdf",
            sourceType: .paper,
            state: .ready
        )
        direct.content = paperBodyText
        vm.articles = [direct]
        #expect(vm.readerShouldAbandonRemotePDF(direct.id))
    }

    @Test("The publisher's preview stored as a paper's text is not text to show")
    func previewTextIsNotReadableText() {
        let vm = makeViewModel()
        var withPage = paper()
        withPage.content = publisherPreviewText
        var direct = makeArticle(url: "https://example.org/paper.pdf", sourceType: .paper, state: .ready)
        direct.content = publisherPreviewText
        vm.articles = [withPage, direct]

        #expect(!StudioViewModel.sourceHoldsReadableText(withPage))
        #expect(StudioViewModel.sourceHoldsReadableText(paper().with(content: paperBodyText)))
        // The page is still there to show, and it is where signing in happens.
        #expect(vm.readerShouldAbandonRemotePDF(withPage.id))
        // No page and no text worth showing: the failure view, where a PDF is attached.
        #expect(!vm.readerShouldAbandonRemotePDF(direct.id))
    }

    @Test("A paper with its own PDF, a non-paper, and one already given up on do not")
    func otherSourcesDoNotQualify() {
        let vm = makeViewModel()
        var withPDF = paper()
        withPDF.localFilePath = "/Users/someone/Library/ForeverLM/Papers/s41593.pdf"
        let articleType = makeArticle(url: "https://example.org/post", state: .error)
        let bare = makeArticle(url: "https://example.org/paper.pdf", sourceType: .paper, state: .error)
        let given = paper()
        vm.articles = [withPDF, articleType, bare, given]
        vm.abandonRemotePDFInReader(given.id)

        #expect(!vm.readerShouldAbandonRemotePDF(withPDF.id))
        #expect(!vm.readerShouldAbandonRemotePDF(articleType.id))
        // No text and no page: the failure view, where attaching a PDF lives.
        #expect(!vm.readerShouldAbandonRemotePDF(bare.id))
        #expect(!vm.readerShouldAbandonRemotePDF(given.id))
        #expect(vm.readerAbandonedRemotePDF(given.id))
    }
}

// MARK: - Stored Publisher Preview Repair

/// Builds before 70 could store a publisher's preview as a paper's text. The
/// repair drops it so the paper asks for its PDF again and the reader shows the
/// publisher's page.
@Suite("Stored Publisher Preview Repair")
@MainActor
struct StoredPublisherPreviewRepairTests {
    /// A paper the page already supplied metadata and text for, taken through
    /// the stages storage requires of a `ready` paper.
    private func paper(content: String) -> StudioArticle {
        var paper = makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02421-x",
            title: "Mitochondrial calcium influx-driven bioenergetics",
            sourceType: .paper,
            state: .ready
        )
        paper.author = "Jun Gao; Xin Pan"
        paper.journal = "Nature Neuroscience"
        markPaperFullyReady(&paper, content: content)
        return paper
    }

    @Test("A paper without a PDF drops stored preview text and asks for the PDF again")
    func previewTextIsDiscarded() async throws {
        let vm = makeViewModel()
        let stored = paper(content: publisherPreviewText)
        try await vm.storage.saveSource(stored)
        #expect(await vm.storage.loadSourceContent(stored.id) != nil)
        vm.articles = [stored]

        #expect(await vm.discardStoredPublisherWallTextIfNeeded(for: stored.id))
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].wordCount == nil)
        #expect(vm.articles[0].state == .queued)
        #expect(await vm.storage.loadSourceContent(stored.id) == nil)
        // A second pass finds nothing to drop.
        #expect(!(await vm.discardStoredPublisherWallTextIfNeeded(for: stored.id)))
    }

    @Test("A paper's full text is kept")
    func fullTextIsKept() async throws {
        let vm = makeViewModel()
        let full = paper(content: paperBodyText)
        try await vm.storage.saveSource(full)
        vm.articles = [full]

        #expect(!(await vm.discardStoredPublisherWallTextIfNeeded(for: full.id)))
        #expect(vm.articles[0].content == paperBodyText)
        #expect(vm.articles[0].state == .ready)
        #expect(await vm.storage.loadSourceContent(full.id) != nil)
    }

    @Test("A paper whose PDF is on disk keeps whatever text it has")
    func pdfBackedPaperIsLeftAlone() async throws {
        let vm = makeViewModel()
        let pdfURL = try makeReadableTempPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        var withPDF = paper(content: publisherPreviewText)
        withPDF.localFilePath = pdfURL.path
        StudioArticle.recordExistingLocalPath(pdfURL.path)
        try await vm.storage.saveSource(withPDF)
        vm.articles = [withPDF]

        #expect(!(await vm.discardStoredPublisherWallTextIfNeeded(for: withPDF.id)))
        #expect(vm.articles[0].content == publisherPreviewText)
        #expect(StudioViewModel.sourceHoldsReadableText(withPDF))
    }
}

// MARK: - Discovered Paper Promotion

/// Source discovery promotes an existing article to a paper when it finds the
/// same link typed as a paper. An article whose own URL already reads as a
/// paper's was typed on more than the URL, so that promotion is not offered.
@Suite("Discovered Paper Promotion")
struct DiscoveredPaperPromotionTests {
    @Test("An article at a paper-shaped URL keeps its type when discovery finds the same link as a paper")
    func reclassifiedArticleIsNotPromoted() {
        let newsAndViews = makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02264-6",
            title: "Mitochondrial stress response drives microglial senescence",
            sourceType: .article,
            state: .ready
        )
        let candidate = makeArticle(
            url: "https://www.nature.com/articles/s41593-026-02264-6",
            sourceType: .paper
        )
        let updates = StudioViewModel.paperPromotionUpdates(from: [candidate], existingArticles: [newsAndViews])
        #expect(updates.isEmpty)
    }

    @Test("An article at an ordinary URL, and an unclassified source, are still promoted")
    func plainArticleAndUnclassifiedArePromoted() {
        let blog = makeArticle(url: "https://example.org/posts/a-study", sourceType: .article, state: .ready)
        let blogCandidate = makeArticle(url: "https://example.org/posts/a-study", sourceType: .paper)
        let unclassified = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            sourceType: .unclassified
        )
        let unclassifiedCandidate = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            sourceType: .paper
        )
        let updates = StudioViewModel.paperPromotionUpdates(
            from: [blogCandidate, unclassifiedCandidate],
            existingArticles: [blog, unclassified]
        )
        #expect(updates.map { $0.article.id }.sorted() == [blog.id, unclassified.id].sorted())
        #expect(updates.allSatisfy { $0.article.sourceType == .paper })
    }
}

// MARK: - Rendered Reader Page Adoption

/// The reader's own web view clears publisher bot checks that the hidden
/// ingestion fetch does not, so a source parked as blocked can take its
/// content from the page the learner is reading.
@Suite("Rendered Reader Page Adoption")
@MainActor
struct RenderedReaderPageAdoptionTests {
    private static let blockedMessage = StudioViewModel.securityChallengeFailureMessage

    private func blockedArticle() -> StudioArticle {
        var article = makeArticle(
            url: "https://www.science.org/content/blog-post/reaction-alzheimer-s-fraud",
            title: "A Reaction to Alzheimer's Fraud",
            state: .error
        )
        article.errorMessage = Self.blockedMessage
        return article
    }

    private func removeArchive(for article: StudioArticle) {
        let directory = (StorageService.libraryRootPath as NSString)
            .appendingPathComponent("Articles/\(article.id)")
        try? FileManager.default.removeItem(atPath: directory)
    }

    @Test("A blocked or unfetched web article can take its content from the reader's page")
    func webArticleWithoutContentQualifies() {
        #expect(StudioViewModel.canAdoptRenderedReaderPage(blockedArticle()))
        let queued = makeArticle(url: "https://example.org/post", state: .queued)
        #expect(StudioViewModel.canAdoptRenderedReaderPage(queued))
        let unclassified = makeArticle(url: "https://example.org/post", sourceType: .unclassified, state: .queued)
        #expect(StudioViewModel.canAdoptRenderedReaderPage(unclassified))
    }

    @Test("A paper with no PDF on record takes its text from the reader's page only when the learner asks")
    func paperWithoutPDFQualifiesWhenAsked() {
        let paper = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            sourceType: .paper,
            state: .error
        )
        // A paper is a PDF: the page is never taken for it on the app's own
        // initiative, only through Save Paper from Page.
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(paper))
        #expect(StudioViewModel.canAdoptRenderedReaderPage(paper, learnerAsked: true))

        // The marker says no PDF could be found, which is exactly the case
        // the reader's page answers.
        var paywalled = paper
        paywalled.isPaywalled = true
        #expect(StudioViewModel.canAdoptRenderedReaderPage(paywalled, learnerAsked: true))

        var withText = paper
        withText.content = paperBodyText
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(withText, learnerAsked: true))

        // The publisher's preview stored as the paper's text does not stand in
        // the page's way: the page is what replaces it.
        var withPreview = paper
        withPreview.content = publisherPreviewText
        #expect(StudioViewModel.canAdoptRenderedReaderPage(withPreview, learnerAsked: true))

        // Asking does not make a web article's rules any looser.
        var paywalledArticle = blockedArticle()
        paywalledArticle.isPaywalled = true
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(paywalledArticle, learnerAsked: true))
    }

    @Test("The reader offers Save Paper from Page for a paper without a PDF, and for nothing else")
    func readerOffersSavePaperFromPage() throws {
        let vm = makeViewModel()
        let paper = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            sourceType: .paper,
            state: .error
        )
        let pdfURL = try makeReadableTempPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        var withPDF = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06601-0",
            sourceType: .paper,
            state: .ready
        )
        withPDF.localFilePath = pdfURL.path
        StudioArticle.recordExistingLocalPath(pdfURL.path)
        let article = blockedArticle()
        vm.articles = [paper, withPDF, article]

        #expect(vm.readerCanSavePaperFromPage(paper.id))
        #expect(!vm.readerCanSavePaperFromPage(withPDF.id))
        #expect(!vm.readerCanSavePaperFromPage(article.id))
        // The automatic route never offers a paper's page.
        #expect(!vm.readerPageCanSupplySourceContent(paper.id))
        #expect(vm.readerPageCanSupplySourceContent(article.id))
    }

    @Test("Sources with content, papers with a PDF, PDFs, videos, paywalls and fetches in flight do not")
    func otherSourcesDoNotQualify() {
        var ready = blockedArticle()
        ready.content = "Stored body"
        ready.state = .ready
        ready.errorMessage = nil
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(ready))

        var paperWithPDF = makeArticle(
            url: "https://www.science.org/doi/10.1126/science.abc1234",
            sourceType: .paper,
            state: .ready
        )
        paperWithPDF.localFilePath = "/Users/someone/Library/ForeverLM/Papers/science.abc1234.pdf"
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(paperWithPDF))

        let pdf = makeArticle(url: "https://example.org/paper.pdf", state: .error)
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(pdf))

        let youtube = makeArticle(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", state: .queued)
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(youtube))

        var paywalled = blockedArticle()
        paywalled.isPaywalled = true
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(paywalled))

        var fetching = blockedArticle()
        fetching.state = .fetching
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(fetching))

        let local = makeArticle(url: "/Users/someone/Documents/notes.pdf", state: .queued)
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(local))
    }

    @Test("A bot-check page is not adopted, and the source stays blocked")
    func wallIsNotAdopted() async {
        let vm = makeViewModel()
        let article = blockedArticle()
        vm.articles = [article]
        defer { removeArchive(for: article) }

        await vm.adoptRenderedReaderPage(
            articleId: article.id,
            html: """
            <html><head><title>Just a moment...</title></head>
            <body><p>www.science.org</p><p>Verify you are human by completing the action below.</p>
            <p>Performance &amp; security by Cloudflare</p></body></html>
            """,
            pageTitle: "Just a moment...",
            visibleText: "www.science.org\nVerify you are human by completing the action below.\nPerformance & security by Cloudflare"
        )

        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .error)
        #expect(vm.articles[0].errorMessage == Self.blockedMessage)
        #expect(vm.articles[0].localFilePath == nil)
    }

    @Test("The rendered article is archived, stored, and the block is lifted")
    func renderedPageBecomesContent() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedReaderPageAdoptionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        let article = blockedArticle()
        try await service.saveSource(article)
        vm.articles = [article]
        defer { removeArchive(for: article) }

        let paragraph = String(
            repeating: "Amyloid has been the prime suspect in the pathology of Alzheimer's for decades. ",
            count: 12
        )
        let html = """
        <html><head><title>A Reaction to Alzheimer's Fraud | Science</title></head>
        <body><nav>Home Commentary Blogs</nav>
        <article><h1>A Reaction to Alzheimer's Fraud</h1><p>\(paragraph)</p><p>\(paragraph)</p></article>
        </body></html>
        """

        await vm.adoptRenderedReaderPage(
            articleId: article.id,
            html: html,
            pageTitle: "A Reaction to Alzheimer's Fraud | Science",
            visibleText: paragraph
        )

        let adopted = vm.articles[0]
        // With Source Content Cleanup configured the clean text is the content;
        // without it (this test host) the raw text is staged for cleanup and
        // the body stays empty until then. Either way the block is gone and
        // the archive is on disk.
        if let content = adopted.content {
            #expect(content.contains("prime suspect"))
        }
        #expect(adopted.state != .fetching)
        #expect(adopted.errorMessage != Self.blockedMessage)
        let archivePath = try #require(adopted.localFilePath)
        #expect(archivePath.hasSuffix("article.html"))
        let absoluteArchivePath = StorageService.absoluteSourcePath(archivePath)
        let archivedHTML = try String(contentsOfFile: absoluteArchivePath, encoding: .utf8)
        #expect(archivedHTML.contains("prime suspect"))

        let persisted = try await service.loadSources().first { $0.id == article.id }
        #expect(persisted?.errorMessage != Self.blockedMessage)
        #expect(persisted?.localFilePath == adopted.localFilePath)
    }

    @Test("A blocked source whose only document is the archived wall still takes the reader's page")
    func blockedSourceWithArchivedWallQualifies() {
        // Builds before 99 archived the bot check's page before judging its
        // text, so a blocked row carried the wall as its reader document.
        var article = blockedArticle()
        article.localFilePath = "Articles/\(article.id)/article.html"
        #expect(article.cachedIsArchivedArticle)
        #expect(StudioViewModel.canAdoptRenderedReaderPage(article))

        // The same archive on a row that is not blocked is the row's document.
        var queued = article
        queued.state = .queued
        queued.errorMessage = nil
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(queued))
        var otherError = article
        otherError.errorMessage = "Could not fetch content"
        #expect(!StudioViewModel.canAdoptRenderedReaderPage(otherError))
    }

    @Test("Parking a source as blocked drops the wall the fetch archived")
    func blockDropsArchivedWall() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedReaderPageAdoptionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        var article = makeArticle(
            url: "https://www.linkedin.com/pulse/wrong-benchmark-ai-drug-discovery-chris-gibson-xa1lc/",
            title: "The Wrong Benchmark for AI Drug Discovery",
            state: .fetching
        )
        let relativePath = "Articles/\(article.id)/article.html"
        let absolutePath = StorageService.absoluteSourcePath(relativePath)
        try FileManager.default.createDirectory(
            atPath: (absolutePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "<html><body>Performing security verification</body></html>"
            .write(toFile: absolutePath, atomically: true, encoding: .utf8)
        defer { removeArchive(for: article) }
        article.localFilePath = relativePath
        try await service.saveSource(article)
        vm.articles = [article]

        await vm.recordSecurityChallengeBlock(articleId: article.id)

        let blocked = vm.articles[0]
        #expect(blocked.state == .error)
        #expect(blocked.errorMessage == Self.blockedMessage)
        #expect(blocked.localFilePath == nil)
        #expect(!FileManager.default.fileExists(atPath: absolutePath))
        #expect(StudioViewModel.canAdoptRenderedReaderPage(blocked))
        let persisted = try await service.loadSources().first { $0.id == article.id }
        #expect(persisted?.localFilePath == nil)
        #expect(persisted?.errorMessage == Self.blockedMessage)
    }

    private func paperWithoutPDF() -> StudioArticle {
        var paper = makeArticle(
            url: "https://www.nature.com/articles/s41586-023-06600-9",
            title: "Structure of the complex in its closed state",
            sourceType: .paper,
            state: .error
        )
        paper.isPaywalled = true
        paper.errorMessage = "PDF download failed: access denied"
        return paper
    }

    private static let paperParagraph = String(
        repeating: "The complex adopts a closed conformation upon binding its substrate, "
            + "and the resulting rearrangement propagates through the linker domain "
            + "to the catalytic site, where two conserved residues coordinate the metal ion. ",
        count: 6
    )

    @Test("A publisher's access wall is not adopted as a paper's text")
    func accessWallIsNotAdoptedForPaper() async {
        let vm = makeViewModel()
        let paper = paperWithoutPDF()
        vm.articles = [paper]

        let references = (1...40).map {
            "\($0). Author, A. & Author, B. A reference title of ordinary length for a journal. J. Sci. 12, 345–678 (2020)."
        }.joined(separator: "\n")
        let wall = """
        Abstract
        We report a finding of some consequence, described here in the few hundred words a landing page shows.
        Access options
        Access through your institution
        Buy this article
        Prices may be subject to local taxes which are calculated during checkout
        References
        \(references)
        """

        let adoption = await vm.adoptRenderedReaderPage(
            articleId: paper.id,
            html: "<html><head><title>Structure of the complex | Nature</title></head><body><main>\(wall)</main></body></html>",
            pageTitle: "Structure of the complex | Nature",
            visibleText: wall,
            learnerAsked: true
        )

        #expect(adoption == .notAdopted(.accessWall))
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .error)
        #expect(vm.articles[0].errorMessage == "PDF download failed: access denied")
        #expect(vm.articles[0].isPaywalled)
        #expect(vm.articles[0].localFilePath == nil)
    }

    @Test("A page too short to be the paper is not adopted")
    func shortPageIsNotAdoptedForPaper() async {
        let vm = makeViewModel()
        let paper = paperWithoutPDF()
        vm.articles = [paper]

        let abstract = "We report a finding of some consequence, described here in the few hundred words a landing page shows."
        let adoption = await vm.adoptRenderedReaderPage(
            articleId: paper.id,
            html: "<html><body><article><h1>Structure of the complex</h1><p>\(abstract)</p></article></body></html>",
            pageTitle: "Structure of the complex | Nature",
            visibleText: abstract,
            learnerAsked: true
        )

        #expect(adoption == .notAdopted(.tooShort))
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .error)
        #expect(vm.articles[0].localFilePath == nil)
    }

    @Test("A paper's full text from the reader's page is stored, with no PDF claimed")
    func paperFullTextBecomesContent() async throws {
        // Adoption hands the text to Paper Metadata extraction. Unpinned, the
        // hosted test reads the developer's own sign-in: signed in, it bills a
        // real model call on this made-up page, the model finds no author,
        // venue or year, and the paper waits in `.error` for Edit Details
        // with its text behind the metadata gate, so this test failed on
        // every run from a signed-in Dev host. Signed out, extraction stops
        // before any request and the page's text stays on the source.
        let savedSignIn = ManagedAI.signedInOverrideForTesting
        ManagedAI.signedInOverrideForTesting = false
        defer { ManagedAI.signedInOverrideForTesting = savedSignIn }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedReaderPageAdoptionTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let service = StorageService(storeRoot: tmp)
        let vm = StudioViewModel(storageService: service)
        let paper = paperWithoutPDF()
        try await service.saveSource(paper)
        vm.articles = [paper]
        defer { removeArchive(for: paper) }

        let body = (1...6).map { _ in "<p>\(Self.paperParagraph)</p>" }.joined()
        let html = """
        <html><head><title>Structure of the complex in its closed state | Nature</title></head>
        <body><nav>Nature Log in Subscribe</nav>
        <article><h1>Structure of the complex in its closed state</h1>\(body)</article>
        </body></html>
        """

        // Without the learner asking, the page is not the paper's.
        let unasked = await vm.adoptRenderedReaderPage(
            articleId: paper.id,
            html: html,
            pageTitle: "Structure of the complex in its closed state | Nature",
            visibleText: String(repeating: Self.paperParagraph, count: 6)
        )
        #expect(unasked == .notAdopted(.ineligible))
        #expect(vm.articles[0].content == nil)
        #expect(vm.articles[0].state == .error)

        let adoption = await vm.adoptRenderedReaderPage(
            articleId: paper.id,
            html: html,
            pageTitle: "Structure of the complex in its closed state | Nature",
            visibleText: String(repeating: Self.paperParagraph, count: 6),
            learnerAsked: true
        )
        #expect(adoption == .adoptedPaperText(needsPDF: true))

        let adopted = vm.articles[0]
        #expect(adopted.sourceType == .paper)
        #expect(adopted.state != .fetching)
        #expect(adopted.errorMessage != "PDF download failed: access denied")
        // The text is in the library — in memory until the cleanup save, and
        // in storage after it — the PDF is still missing, and no reader
        // document was archived in its place.
        let storedContent = await service.loadSourceContent(paper.id)
        #expect((adopted.content ?? storedContent ?? "").contains("closed conformation"))
        #expect(adopted.isPaywalled)
        #expect(adopted.localFilePath == nil)
        let persistedRaw = try #require(await service.loadRawPaperContent(paper.id))
        #expect(persistedRaw.contains("closed conformation"))
        let archiveDirectory = (StorageService.libraryRootPath as NSString)
            .appendingPathComponent("Articles/\(paper.id)")
        #expect(!FileManager.default.fileExists(atPath: archiveDirectory))
    }

    @Test("A page arriving for a source that already has content is ignored")
    func readySourceKeepsItsContent() async {
        let vm = makeViewModel()
        var article = blockedArticle()
        article.content = "The body the fetch stored."
        article.state = .ready
        article.errorMessage = nil
        vm.articles = [article]

        await vm.adoptRenderedReaderPage(
            articleId: article.id,
            html: "<html><body><article><p>A different rendering of the page.</p></article></body></html>",
            pageTitle: "Different",
            visibleText: "A different rendering of the page."
        )

        #expect(vm.articles[0].content == "The body the fetch stored.")
        #expect(vm.articles[0].localFilePath == nil)
    }
}
