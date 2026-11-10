import Testing
import Foundation
@testable import ForeverLM

// MARK: - Helpers

// MARK: - URL Normalization

@Suite("URL Normalization")
@MainActor
struct URLNormalizationTests {

    @Test("Empty string adds nothing")
    func emptyStringNoArticle() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "")
        #expect(vm.articles.isEmpty)
    }

    @Test("Whitespace-only string adds nothing")
    func whitespaceOnlyNoArticle() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "   \n  ")
        #expect(vm.articles.isEmpty)
    }

    @Test("URL without scheme gets https:// prepended")
    func noSchemePrependsHTTPS() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "example.com/article")
        #expect(vm.articles.count == 1)
        #expect(vm.articles[0].url == "https://example.com/article")
    }

    @Test("URL with http:// preserved as-is")
    func httpSchemePreserved() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "http://example.com/page")
        #expect(vm.articles.count == 1)
        #expect(vm.articles[0].url == "http://example.com/page")
    }
}

// MARK: - Exact URL Dedup

@Suite("Exact URL Dedup")
@MainActor
struct ExactURLDedupTests {

    @Test("Adding same URL twice sets errorMessage and does not duplicate")
    func duplicateURLRejected() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "https://example.com/post")
        try await vm.addArticle(url: "https://example.com/post")
        #expect(vm.articles.count == 1)
        #expect(vm.errorMessage != nil)
    }

    @Test("Error message contains 'already in your reading list'")
    func duplicateURLErrorText() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "https://example.com/post")
        try await vm.addArticle(url: "https://example.com/post")
        #expect(vm.errorMessage?.contains("already in your reading list") == true)
    }

    @Test("Different URLs both added successfully")
    func differentURLsBothAdded() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "https://example.com/a")
        try await vm.addArticle(url: "https://example.com/b")
        #expect(vm.articles.count == 2)
        #expect(vm.errorMessage == nil)
    }
}

// MARK: - DOI Dedup

@Suite("DOI Dedup")
@MainActor
struct DOIDedupTests {

    @Test("Two paper URLs with same DOI — second rejected")
    func sameDOIRejected() async throws {
        let vm = makeViewModel()
        // First: arXiv abstract URL → extracts DOI 10.48550/arXiv.2301.12345
        try await vm.addArticle(url: "https://arxiv.org/abs/2301.12345")
        #expect(vm.articles.count == 1)
        #expect(vm.errorMessage == nil)

        // Second: doi.org link with the same DOI
        try await vm.addArticle(url: "https://doi.org/10.48550/arXiv.2301.12345")
        #expect(vm.articles.count == 1)
        #expect(vm.errorMessage != nil)
        #expect(vm.errorMessage?.contains("already in your reading list") == true)
    }

    @Test("Paper URL with no DOI is not rejected by DOI dedup")
    func noDOINotRejected() async throws {
        let vm = makeViewModel()
        // First paper — a generic PDF with no DOI in the URL
        try await vm.addArticle(url: "https://example.com/papers/report.pdf")
        #expect(vm.articles.count == 1)

        // Second paper — different generic PDF, also no DOI
        try await vm.addArticle(url: "https://example.com/papers/other-report.pdf")
        #expect(vm.articles.count == 2)
        #expect(vm.errorMessage == nil)
    }

    @Test("Distinct PubMed records remain separate sources")
    func distinctPubMedRecordsRemainSeparate() async throws {
        let vm = makeViewModel()

        try await vm.addArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/23543062/",
            revealInReader: false
        )
        try await vm.addArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/40123456/",
            revealInReader: false
        )

        #expect(vm.articles.count == 2)
        #expect(Set(vm.articles.map(\.url)) == [
            "https://pubmed.ncbi.nlm.nih.gov/23543062/",
            "https://pubmed.ncbi.nlm.nih.gov/40123456/",
        ])
        #expect(vm.errorMessage == nil)
    }
}

// MARK: - Filename Dedup

@Suite("Filename Dedup")
@MainActor
struct FilenameDedupTests {

    @Test("Paper URL whose filename matches existing local PDF is rejected")
    func matchingFilenameRejected() async throws {
        let vm = makeViewModel()
        // Manually insert a local PDF paper whose filename is "615786.pdf"
        var localPaper = StudioArticle(
            url: "/path/to/615786.pdf",
            title: "Local Paper",
            sourceType: .paper
        )
        localPaper.domain = "local"
        vm.articles = [localPaper]

        // Try adding a remote paper URL that produces the same normalized filename.
        // "https://example.com/papers/615786v2.pdf" → paperFilename returns "615786v2.pdf"
        //   → normalizedPaperFilename strips vN → "615786.pdf" — matches.
        try await vm.addArticle(url: "https://example.com/papers/615786v2.pdf")
        #expect(vm.articles.count == 1)
        #expect(vm.errorMessage != nil)
        #expect(vm.errorMessage?.contains("already in your reading list") == true)
    }

    @Test("Paper URL whose filename matches attached local PDF is rejected")
    func matchingAttachedLocalPDFFilenameRejected() async throws {
        let vm = makeViewModel()
        var paper = StudioArticle(
            url: "https://example.com/papers/original",
            title: "Local Paper",
            sourceType: .paper,
            localFilePath: "/path/to/615786.pdf"
        )
        paper.domain = "Local PDF"
        vm.articles = [paper]

        try await vm.addArticle(url: "https://example.com/papers/615786v2.pdf")

        #expect(vm.articles.count == 1)
        #expect(vm.errorMessage?.contains("already in your reading list") == true)
    }

    @Test("Paper URL with non-matching filename is not rejected")
    func nonMatchingFilenameNotRejected() async throws {
        let vm = makeViewModel()
        var localPaper = StudioArticle(
            url: "/path/to/615786.pdf",
            title: "Local Paper",
            sourceType: .paper
        )
        localPaper.domain = "local"
        vm.articles = [localPaper]

        // Different filename — should pass filename dedup
        try await vm.addArticle(url: "https://example.com/papers/999999.pdf")
        #expect(vm.articles.count == 2)
        #expect(vm.errorMessage == nil)
    }
}

// MARK: - Successful Addition

@Suite("Successful Addition")
@MainActor
struct SuccessfulAdditionTests {

    @Test("Article appears at index 0 of articles array")
    func insertedAtFront() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "https://example.com/first")
        try await vm.addArticle(url: "https://example.com/second")
        #expect(vm.articles[0].url == "https://example.com/second")
    }

    @Test("urlInput is cleared after add")
    func urlInputCleared() async throws {
        let vm = makeViewModel()
        vm.urlInput = "https://example.com/page"
        try await vm.addArticle(url: "https://example.com/page")
        #expect(vm.urlInput == "")
    }

    @Test("Source type is detected — YouTube URL becomes .video")
    func youtubeDetectedAsVideo() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(vm.articles.count == 1)
        #expect(vm.articles[0].sourceType == .video)
    }

    @Test("selectedArticleId set for first article added")
    func selectedArticleIdSetForFirst() async throws {
        let vm = makeViewModel()
        #expect(vm.selectedArticleId == nil)
        try await vm.addArticle(url: "https://example.com/first")
        #expect(vm.selectedArticleId == vm.articles[0].id)
    }

    @Test("A pasted paper URL opens in the reader")
    func pastedPaperOpensInReader() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "https://arxiv.org/abs/2301.12345")

        #expect(vm.sidebarTab == .papers)
        #expect(vm.selectedArticleId == vm.articles[0].id)
    }

    /// Adding a paper cited by the video you are watching. The sources panel goes to Papers
    /// so the paper is visible where it landed, but the reader stays on the talk — following
    /// the citation is a separate decision, made by clicking the new row.
    @Test("A paper added without reveal switches to Papers and leaves the reader alone")
    func paperAddedWithoutRevealKeepsReader() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "https://www.youtube.com/watch?v=abc123")
        let videoID = vm.articles[0].id
        #expect(vm.selectedArticleId == videoID)

        try await vm.addArticle(url: "https://arxiv.org/abs/2301.12345", revealInReader: false)

        #expect(vm.sidebarTab == .papers)
        #expect(vm.selectedArticleId == videoID)
    }

    @Test("A paper added on the Papers tab is processing on first publication")
    func paperAddedOnPapersTabIsImmediatelyProcessing() async throws {
        let vm = makeViewModel()
        vm.sidebarTab = .papers
        vm.searchText = "pubmed"

        try await vm.addArticle(
            url: "https://pubmed.ncbi.nlm.nih.gov/40747960/",
            revealInReader: false,
            waitForInitialPaperProcessing: false
        )

        let paper = try #require(vm.articles.first)
        #expect(vm.pendingPaperProcessingIds.contains(paper.id))
        #expect(vm.processingPaperIDs.contains(paper.id))
        #expect(!vm.papersNeedingPDFAttention.contains(where: { $0.id == paper.id }))
        // Adding into the already-selected tab must not reset/recreate its List.
        #expect(vm.searchText == "pubmed")
    }

    @Test("Domain extracted from URL")
    func domainExtracted() async throws {
        let vm = makeViewModel()
        try await vm.addArticle(url: "https://news.ycombinator.com/item?id=12345")
        #expect(vm.articles[0].domain.contains("news.ycombinator.com"))
    }
}

// MARK: - Automatic Paper Queue Presentation

@Suite("Automatic Paper Queue Presentation")
@MainActor
struct AutomaticPaperQueuePresentationTests {

    @Test("Waiting automatic work stays in Processing instead of asking for attention")
    func queuedAutomaticPaperWorkStaysInProcessing() {
        let vm = makeViewModel()
        var metadataPaper = StudioArticle(
            url: "https://example.com/full-text-paper",
            title: "Complete-looking metadata",
            sourceType: .paper,
            author: "Ada Researcher",
            journal: "Journal of Queues",
            publishedYear: "2026"
        )
        metadataPaper.content = "Readable full-text paper content."
        let pdfPaper = StudioArticle(
            url: "https://example.com/paper-without-pdf",
            title: "Waiting for PDF",
            sourceType: .paper
        )
        vm.articles = [metadataPaper, pdfPaper]
        vm.sidebarTab = .papers

        // This is the screenshot's exact ambiguity: complete-looking display
        // fields do not constitute the durable ingestion attestation.
        #expect(metadataPaper.paperAttentionReason(hasUsablePDF: true) == .metadataIncomplete)

        // Hold both serial drains so the assertions exercise the waiting state
        // without starting network or AI work.
        vm.isDrainingAutoPaperFetchQueue = true
        vm.isDrainingAutoExtractMetadataQueue = true
        vm.enqueueAutoPaperFetch(
            [pdfPaper.id],
            dedupKeysWithPDF: [],
            unavailableRecordedPDFIDs: []
        )
        vm.enqueueAutoMetadataExtraction([metadataPaper.id])

        #expect(vm.queuedPaperPDFResolutionIds == [pdfPaper.id])
        #expect(vm.queuedPaperMetadataExtractionIds == [metadataPaper.id])
        #expect(vm.processingPaperIDs == [pdfPaper.id, metadataPaper.id])
        #expect(vm.paperProcessingStepLabel(for: pdfPaper) == "Waiting to find PDF…")
        #expect(vm.paperProcessingStepLabel(for: metadataPaper) == "Waiting to extract metadata…")
        #expect(vm.papersNeedingPDFAttention.isEmpty)
    }
}
