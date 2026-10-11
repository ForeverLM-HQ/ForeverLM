import Testing
import Foundation
@testable import ForeverLM

// MARK: - Podcast Detection

@Suite("Source Type Classification")
struct SourceTypeClassificationTests {

    @Suite("AI Classification Parsing")
    struct AIClassificationParsingTests {

        @Test("LLM source classification accepts book")
        func parsesBookClassification() {
            #expect(AIService.parseSourceTypeClassification("book") == .book)
        }

        @Test("LLM source classification still accepts article and paper")
        func parsesArticleAndPaperClassification() {
            #expect(AIService.parseSourceTypeClassification("article") == .article)
            #expect(AIService.parseSourceTypeClassification("paper") == .paper)
        }
    }

    /// The product owner (2026-09-09): "codex sites should always obviously be ingested
    /// as a 'site' not as an article". The rule runs before classification on
    /// every route that makes a source from a URL — `addArticle`, browser
    /// Reading List discovery, MCP `add_source` — so what these prove is that
    /// the pages ForeverLM links are recognized by the one predicate those
    /// routes ask, and that the classifier alone would not have caught them.
    @Suite("Linked pages are never sources")
    struct LinkedPagesAreNeverSourcesTests {
        static let codexSite = "https://techbio-companies-landscape.learner-1234.chatgpt.site"

        @Test("A page ForeverLM links is recognized before any classification", arguments: [
            ("https://techbio-companies-landscape.learner-1234.chatgpt.site", LinkedPageKind.codexSite),
            ("https://techbio-companies-landscape.learner-1234.chatgpt.site/companies?tab=1#top", .codexSite),
            ("techbio-companies-landscape.learner-1234.chatgpt.site", .codexSite),
            ("  https://Techbio-Companies-Landscape.learner-1234.chatgpt.site/  ", .codexSite),
            ("https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d", .claudeArtifact),
            ("https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz/edit", .googleDoc),
        ])
        func recognizesLinkedPages(url: String, kind: LinkedPageKind) {
            #expect(StudioViewModel.linkedPageKind(forSourceURL: url) == kind)
        }

        @Test("Anything else stays a source candidate", arguments: [
            "https://chatgpt.site",
            "https://learner-1234.chatgpt.site",
            "https://openai.com/chatgpt.site/blog",
            "https://claude.ai/chat/abc",
            "https://docs.google.com/spreadsheets/d/1AbC/edit",
            "https://paulgraham.com/greatwork.html",
            "https://www.nature.com/articles/s41586-023-06600-9",
            "/Users/test/ForeverLM/Papers/aging_review.pdf",
            "",
        ])
        func leavesOtherURLsAlone(url: String) {
            #expect(StudioViewModel.linkedPageKind(forSourceURL: url) == nil)
        }

        @Test("The classifier alone would have sent a Codex site to the model as an article, which is why the rule runs first")
        func classifierDoesNotKnowCodexSites() {
            #expect(StudioViewModel.detectSourceType(url: Self.codexSite) == .unclassified)
            #expect(StudioViewModel.detectSourceType(url: Self.codexSite + "/companies") == .unclassified)
        }

        @Test("A Codex site in a browser Reading List is not discovered as an article")
        func readingListDiscoveryLeavesLinkedPagesOut() {
            let site = StudioArticle(url: Self.codexSite, title: "TechBio landscape", sourceType: .unclassified, discoveryOrigin: .brave)
            let artifact = StudioArticle(url: "https://claude.ai/code/artifact/a1b2c3d4-1e2f-4a5b-8c6d-7e8f9a0b1c2d", title: "Artifact", sourceType: .unclassified, discoveryOrigin: .safari)
            let essay = StudioArticle(url: "https://paulgraham.com/greatwork.html", title: "Great work", sourceType: .unclassified, discoveryOrigin: .brave)
            let paper = StudioArticle(url: "https://www.nature.com/articles/s41586-023-06600-9", title: "Paper", sourceType: .paper, discoveryOrigin: .chrome)
            let kept = StudioViewModel.excludingLinkedPages([site, essay, artifact, paper])
            #expect(kept.map(\.url) == [essay.url, paper.url])
        }
    }

    /// The product owner (2026-09-12): "convoke bio results should not be ingested as a
    /// source in foreverlm". The predicate sits beside `linkedPageKind` on the
    /// same routes; these prove it knows Convoke's endpoint and nothing else.
    @Suite("Convoke results are never sources")
    struct ConvokeResultsAreNeverSourcesTests {
        @Test("A Convoke query result is refused with the reason", arguments: [
            "https://platform.convoke.bio/mcp#foreverlm-7e5456abb77e57b4e1e45b41",
            "https://platform.convoke.bio/mcp?foreverlm_sync=fb2cc9b56d17b44f1f08d5df",
            "platform.convoke.bio/mcp",
            "  https://Platform.Convoke.bio/  ",
            "https://api.platform.convoke.bio/v1/programs",
        ])
        func refusesConvokeResults(url: String) {
            let refusal = StudioViewModel.sourceRefusal(forSourceURL: url)
            #expect(refusal?.contains("Convoke") == true, "\(url)")
            #expect(StudioViewModel.linkedPageKind(forSourceURL: url) == nil, "\(url)")
        }

        @Test("Convoke's public pages and everything else stay source candidates", arguments: [
            "https://insights.convoke.bio/unmet-needs",
            "https://www.convoke.bio/",
            "https://example.com/platform.convoke.bio",
            "https://paulgraham.com/greatwork.html",
            "/Users/test/ForeverLM/Papers/aging_review.pdf",
            "",
        ])
        func leavesOtherURLsAlone(url: String) {
            #expect(StudioViewModel.sourceRefusal(forSourceURL: url) == nil, "\(url)")
        }

        @Test("A Convoke result in a browser Reading List is not discovered as an article")
        func readingListDiscoveryLeavesConvokeOut() {
            let result = StudioArticle(url: "https://platform.convoke.bio/mcp#foreverlm-7e5456abb77e57b4e1e45b41", title: "Convoke — programs", sourceType: .unclassified, discoveryOrigin: .brave)
            let insight = StudioArticle(url: "https://insights.convoke.bio/unmet-needs", title: "Unmet Needs Index", sourceType: .unclassified, discoveryOrigin: .brave)
            #expect(StudioViewModel.excludingLinkedPages([result, insight]).map(\.url) == [insight.url])
        }
    }

    @Suite("Nature News")
    struct NatureNewsTests {
        static let newsURL = "https://www.nature.com/articles/d41586-026-02616-z?utm_source=reading-list"
        static let newsDOIURL = "https://doi.org/10.1038/d41586-026-02616-z"
        static let paperURL = "https://www.nature.com/articles/s41586-023-06600-9"

        @Test("Nature news ids are recognised from the article URL and the DOI")
        func recognisesNewsIDs() {
            #expect(PaperService.isNatureNewsURL(Self.newsURL))
            #expect(PaperService.isNatureNewsURL(Self.newsDOIURL))
            #expect(PaperService.isNatureNewsURL("https://www.nature.com/articles/d41586-026-02616-z.pdf"))
            #expect(!PaperService.isNatureNewsURL(Self.paperURL))
            #expect(!PaperService.isNatureNewsURL("https://doi.org/10.1038/s41586-025-09429-6"))
            #expect(!PaperService.isNatureNewsURL("https://www.nature.com/articles/s41598-022-08747-3"))
            #expect(!PaperService.isNatureNewsURL("https://example.com/d41586-026-02616-z"))
        }

        @Test("Nature news is an article without asking a model")
        func detectsNewsAsArticle() {
            #expect(StudioViewModel.detectSourceType(url: Self.newsURL) == .article)
            #expect(StudioViewModel.detectSourceType(url: Self.newsDOIURL) == .article)
            #expect(StudioViewModel.detectSourceType(url: Self.paperURL) == .paper)
        }

        @Test("Nature news never resolves to a PDF URL")
        func newsHasNoPDF() {
            #expect(PaperService.paperPDFURL(from: Self.newsURL) == nil)
            #expect(PaperService.paperPDFURL(from: Self.newsDOIURL) == nil)
            #expect(PaperService.paperPDFURL(from: Self.paperURL) == "https://www.nature.com/articles/s41586-023-06600-9.pdf")
        }

        @Test("The URL rule overrides a model that calls Nature news a paper")
        func urlRuleWinsOverModel() {
            #expect(StudioViewModel.refinedSourceType(proposed: .paper, url: Self.newsURL) == .article)
            #expect(StudioViewModel.refinedSourceType(proposed: .article, url: Self.newsURL) == .article)
            #expect(StudioViewModel.refinedSourceType(proposed: .paper, url: Self.paperURL) == .paper)
            #expect(!StudioViewModel.looksLikeScholarlyPaper(url: Self.newsURL))
            #expect(StudioViewModel.looksLikeScholarlyPaper(url: Self.paperURL))
        }

        @Test("Converting a paper to an article drops the paper-only state and re-queues it")
        func convertPaperToArticle() {
            var source = StudioArticle(url: Self.newsURL, title: "Patient's own mitochondria injected into eyes")
            source.sourceType = .paper
            source.state = .error
            source.statusFlag = .paywall
            source.isPaywalled = true
            source.journal = "Nature"
            source.publishedYear = "2026"
            source.doi = "10.1038/d41586-026-02616-z"
            source.author = "Someone"
            source.content = "cached text"
            source.wordCount = 2

            source.convertPaperToArticle()

            #expect(source.sourceType == .article)
            #expect(source.state == .queued)
            #expect(source.errorMessage == nil)
            #expect(source.statusFlag == nil)
            #expect(!source.isPaywalled)
            #expect(!source.hasPaywallMarker)
            #expect(source.journal == nil)
            #expect(source.publishedYear == nil)
            #expect(source.doi == nil)
            #expect(source.content == nil)
            #expect(source.author == "Someone")
            #expect(source.paperAttentionReason(hasUsablePDF: false) == nil)
        }

        @Test("Converting a non-paper is a no-op")
        func convertLeavesNonPapersAlone() {
            var source = StudioArticle(url: "https://example.com/post", title: "Post")
            source.sourceType = .article
            source.state = .ready
            source.content = "body"
            source.convertPaperToArticle()
            #expect(source.state == .ready)
            #expect(source.content == "body")
        }
    }

    @Suite("Podcast Detection")
    struct PodcastDetectionTests {

        @Test("Apple Podcasts URL detected as podcast")
        func applePodcasts() {
            #expect(StudioViewModel.detectSourceType(url: "https://podcasts.apple.com/us/podcast/huberman-lab/id1545953110") == .podcast)
        }

        @Test("Spotify podcast URL detected as podcast")
        func spotifyPodcast() {
            #expect(StudioViewModel.detectSourceType(url: "https://open.spotify.com/show/79CkJF3UJTHFV8Dse3Oy0P") == .podcast)
        }

        @Test("Overcast URL detected as podcast")
        func overcast() {
            #expect(StudioViewModel.detectSourceType(url: "https://overcast.fm/+abc123") == .podcast)
        }

        @Test("Podcast show websites are not classified as podcasts")
        func showWebsitesStayUnclassified() {
            // Blog essays and episode pages on a podcaster's own domain go
            // through normal article classification; podcasts only enter via
            // the Apple Podcasts pipeline.
            #expect(StudioViewModel.detectSourceType(url: "https://www.dwarkesh.com/p/the-winning-essays") == .unclassified)
            #expect(StudioViewModel.detectSourceType(url: "https://hubermanlab.com/episode/focus") == .unclassified)
            #expect(StudioViewModel.detectSourceType(url: "https://lexfridman.com/elon-musk-4") == .unclassified)
        }

        @Test("Generic /podcast/ and /episode/ paths are not classified as podcasts")
        func genericPodcastPathsStayUnclassified() {
            #expect(StudioViewModel.detectSourceType(url: "https://example.com/podcast/my-show") == .unclassified)
            #expect(StudioViewModel.detectSourceType(url: "https://somesite.com/episode/42-deep-learning") == .unclassified)
        }

        @Test("URL with /scrape/ path detected as podcast")
        func scrapePath() {
            #expect(StudioViewModel.detectSourceType(url: "https://example.com/scrape/some-transcript") == .podcast)
        }

        @Test(".ttml file detected as podcast")
        func ttmlFile() {
            #expect(StudioViewModel.detectSourceType(url: "https://cdn.example.com/transcript.ttml") == .podcast)
        }

        @Test("Podcast platform domain with www prefix detected as podcast")
        func podcastDomainWithWWW() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.overcast.fm/+abc123") == .podcast)
        }
    }

    // MARK: - X/Twitter Detection

    @Suite("X/Twitter Detection")
    struct XTwitterDetectionTests {

        @Test("x.com post detected as xPost")
        func xDotComPost() {
            #expect(StudioViewModel.detectSourceType(url: "https://x.com/elonmusk/status/1234567890") == .xPost)
        }

        @Test("twitter.com post detected as xPost")
        func twitterPost() {
            #expect(StudioViewModel.detectSourceType(url: "https://twitter.com/naval/status/9876543210") == .xPost)
        }

        @Test("www.twitter.com post detected as xPost")
        func wwwTwitterPost() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.twitter.com/someuser/status/111") == .xPost)
        }

        @Test("mobile.twitter.com post detected as xPost")
        func mobileTwitterPost() {
            #expect(StudioViewModel.detectSourceType(url: "https://mobile.twitter.com/user/status/222") == .xPost)
        }

        @Test("X video post detected as video, not xPost")
        func xVideoPost() {
            #expect(StudioViewModel.detectSourceType(url: "https://x.com/user/status/123/video/1") == .video)
        }

        @Test("X videos path detected as video")
        func xVideosPath() {
            #expect(StudioViewModel.detectSourceType(url: "https://x.com/user/status/456/videos/1") == .video)
        }

        @Test("nfx.com is not confused with x.com")
        func nfxNotX() {
            // Not an X post; generic web URLs stay unclassified until LLM classification runs.
            #expect(StudioViewModel.detectSourceType(url: "https://nfx.com/post/network-effects") == .unclassified)
        }
    }

    // MARK: - Video Detection

    @Suite("Video Detection")
    struct VideoDetectionTests {

        @Test("YouTube watch URL detected as video")
        func youtubeWatch() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .video)
        }

        @Test("YouTube short URL detected as video")
        func youtubeShort() {
            #expect(StudioViewModel.detectSourceType(url: "https://youtu.be/dQw4w9WgXcQ") == .video)
        }

        @Test("Vimeo URL detected as video")
        func vimeo() {
            #expect(StudioViewModel.detectSourceType(url: "https://vimeo.com/123456789") == .video)
        }

        @Test("Loom URL detected as video")
        func loom() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.loom.com/share/abc123") == .video)
        }

        @Test("Zoom recording detected as meeting")
        func zoomRecording() {
            #expect(StudioViewModel.detectSourceType(url: "https://zoom.us/rec/share/abc123") == .meeting)
        }

        @Test("read.ai URL detected as video")
        func readAI() {
            #expect(StudioViewModel.detectSourceType(url: "https://read.ai/meetings/some-meeting-id") == .video)
        }

        @Test("Riverside URL detected as video")
        func riverside() {
            #expect(StudioViewModel.detectSourceType(url: "https://riverside.fm/studio/abc123") == .video)
        }
    }

    // MARK: - Paper Detection

    @Suite("Paper Detection")
    struct PaperDetectionTests {

        @Test("DOI URL detected as paper")
        func doiURL() {
            #expect(StudioViewModel.detectSourceType(url: "https://doi.org/10.1234/some.paper") == .paper)
        }

        @Test("arXiv abstract detected as paper")
        func arxivAbstract() {
            #expect(StudioViewModel.detectSourceType(url: "https://arxiv.org/abs/2301.00001") == .paper)
        }

        @Test("arXiv PDF detected as paper")
        func arxivPDF() {
            #expect(StudioViewModel.detectSourceType(url: "https://arxiv.org/pdf/2301.00001") == .paper)
        }

        @Test("bioRxiv detected as paper")
        func biorxiv() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.biorxiv.org/content/10.1101/2023.01.01.123456v1") == .paper)
        }

        @Test("medRxiv detected as paper")
        func medrxiv() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.medrxiv.org/content/10.1101/2023.05.05.555555v1") == .paper)
        }

        @Test("Nature article detected as paper")
        func natureArticle() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.nature.com/articles/s41586-023-06600-9") == .paper)
        }

        @Test("ScienceDirect PII article detected as paper")
        func scienceDirectPIIArticle() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.sciencedirect.com/science/article/pii/S1568163724001284") == .paper)
        }

        @Test("PubMed Central article detected as paper")
        func pubMedCentralArticle() {
            #expect(StudioViewModel.detectSourceType(url: "https://pmc.ncbi.nlm.nih.gov/articles/PMC12007350/") == .paper)
            #expect(StudioViewModel.detectSourceType(url: "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12007350/") == .paper)
        }

        @Test("PubMed article detected as paper")
        func pubMedArticle() {
            #expect(StudioViewModel.detectSourceType(url: "https://pubmed.ncbi.nlm.nih.gov/40123456/") == .paper)
        }

        @Test("Nature DOI resolves to article PDF URL")
        func natureDOIResolvesToPDF() {
            #expect(PaperService.paperPDFURL(from: "https://doi.org/10.1038/s41586-025-09429-6") == "https://www.nature.com/articles/s41586-025-09429-6.pdf")
        }

        @Test("bioRxiv DOI resolves to full PDF URL")
        func biorxivDOIResolvesToPDF() {
            #expect(PaperService.paperPDFURL(from: "https://doi.org/10.1101/2021.10.04.463034") == "https://www.biorxiv.org/content/10.1101/2021.10.04.463034.full.pdf")
        }

        @Test("New bioRxiv DOI prefix resolves to full PDF URL")
        func newBiorxivDOIPrefixResolvesToPDF() {
            #expect(PaperService.paperPDFURL(from: "https://doi.org/10.64898/2026.05.11.724149") == "https://www.biorxiv.org/content/10.64898/2026.05.11.724149.full.pdf")
        }

        @Test("bioRxiv early PDF path extracts DOI")
        func biorxivEarlyPDFExtractsDOI() {
            #expect(PaperService.extractDOI(from: "https://www.biorxiv.org/content/biorxiv/early/2026/05/13/2026.05.11.724149.full.pdf") == "10.64898/2026.05.11.724149")
        }

        @Test("A Nature article id is read from a PDF file name off nature.com, but is not a DOI")
        func springerNatureArticleIDFromMirroredPDF() {
            let mirrored = "https://www.insitro.com/wp-content/uploads/2026/02/s41467-025-66778-6.pdf"
            #expect(PaperService.extractSpringerNatureArticleID(from: mirrored) == "s41467-025-66778-6")
            #expect(PaperService.extractSpringerNatureArticleID(from: "https://www.nature.com/articles/s41586-021-03819-2") == "s41586-021-03819-2")
            #expect(PaperService.extractSpringerNatureArticleID(from: "https://mirror.example/S41467-018-06500-X.pdf?dl=1") == "s41467-018-06500-x")
            #expect(PaperService.extractSpringerNatureArticleID(from: "https://www.nature.com/articles/d41586-026-02616-z") == nil)
            #expect(PaperService.extractSpringerNatureArticleID(from: "https://mirror.example/s41467-025-66778-6-supplement.pdf") == nil)
            #expect(PaperService.extractSpringerNatureArticleID(from: "https://example.com/papers/attention.pdf") == nil)
            // The prefix is the host's to know; a bare id off nature.com yields no DOI.
            #expect(PaperService.extractDOI(from: mirrored) == nil)
        }

        @Test("OpenReview forum detected as paper")
        func openreviewForum() {
            #expect(StudioViewModel.detectSourceType(url: "https://openreview.net/forum?id=abc123") == .paper)
        }

        @Test("Generic PDF in /papers/ path detected as paper")
        func pdfInPapersPath() {
            #expect(StudioViewModel.detectSourceType(url: "https://example.com/papers/attention-is-all-you-need.pdf") == .paper)
        }

        @Test("Generic PDF without special path detected as paper")
        func genericPDF() {
            #expect(StudioViewModel.detectSourceType(url: "https://example.com/docs/whitepaper.pdf") == .paper)
        }

        @Test("DOI for Nature (10.1038) detected as paper")
        func doiNature() {
            #expect(StudioViewModel.detectSourceType(url: "https://doi.org/10.1038/s41586-023-06600-9") == .paper)
        }

        @Test("DOI for bioRxiv (10.1101) detected as paper")
        func doiBiorxiv() {
            #expect(StudioViewModel.detectSourceType(url: "https://doi.org/10.1101/2023.01.01.123456") == .paper)
        }

        @Test("DOI for arXiv (10.48550) detected as paper")
        func doiArxiv() {
            #expect(StudioViewModel.detectSourceType(url: "https://doi.org/10.48550/arXiv.2301.00001") == .paper)
        }

        @Test("Cell.com fulltext detected as paper")
        func cellFulltext() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.cell.com/cell/fulltext/S0092-8674(23)00001-1") == .paper)
        }

        @Test("Cell Press journal fulltext with tracking detected as paper")
        func cellPressJournalFulltextWithTracking() {
            let url = "https://www.cell.com/molecular-cell/fulltext/S1097-2765(26)00310-2?utm_source=li&utm_medium=organic&utm_campaign=hl"
            #expect(StudioViewModel.detectSourceType(url: url) == .paper)
            #expect(PaperService.paperPDFURL(from: url) == "https://www.cell.com/action/showPdf?pii=S1097-2765(26)00310-2")
        }

        @Test("NEJM DOI landing page detected as paper")
        func nejmFulltext() {
            #expect(StudioViewModel.detectSourceType(url: "https://www.nejm.org/doi/full/10.1056/NEJMoa2307817") == .paper)
        }
    }

    // MARK: - Book and Course Detection

    @Suite("Book and Course Detection")
    struct BookAndCourseDetectionTests {

        @Test("Local file under the app's Books folder is typed as book")
        func localBookFile() {
            #expect(StudioViewModel.detectSourceType(url: "/Users/x/ForeverLM/Books/deep-learning/chapter3.pdf") == .book)
        }

        @Test("Local file under the app's Courses folder is typed as course")
        func localCourseFile() {
            #expect(StudioViewModel.detectSourceType(url: "/Users/x/ForeverLM/Courses/cs231n/lecture-1.pdf") == .course)
        }

        @Test("External /books/ URL is NOT force-typed as book (falls through to LLM)")
        func externalBooksPathNotForced() {
            // A web URL with /books/ in the path is a direct PDF, so it defaults to
            // paper; it must not be force-typed as a book from the path substring.
            #expect(StudioViewModel.detectSourceType(url: "https://example.com/books/deep-learning.pdf") == .paper)
        }

        @Test("External /courses/ URL stays unclassified until LLM classification")
        func externalCoursesPathUnclassified() {
            #expect(StudioViewModel.detectSourceType(url: "https://example.com/courses/cs231n/lecture-1") == .unclassified)
        }
    }

    // MARK: - PDF Classification

    @Suite("PDF Classification")
    struct PDFClassificationTests {

        @Test("Local PDF under Books folder classified as book")
        func localBooksPathBook() {
            #expect(StudioViewModel.detectSourceType(url: "/Users/x/ForeverLM/Books/foo/chapter3.pdf") == .book)
        }

        @Test("Web PDF classified as paper by default")
        func webPDFPaper() {
            #expect(StudioViewModel.detectSourceType(url: "https://cdn.example.com/papers/submission.pdf") == .paper)
        }

        @Test("PDF with no special path classified as paper (default)")
        func defaultPDFIsPaper() {
            #expect(StudioViewModel.detectSourceType(url: "https://cdn.example.com/upload/document.pdf") == .paper)
        }
    }

    // MARK: - Edge Cases

    @Suite("Edge Cases")
    struct EdgeCaseTests {

        @Test("Empty URL falls through to unclassified")
        func emptyURL() {
            #expect(StudioViewModel.detectSourceType(url: "") == .unclassified)
        }

        @Test("Generic blog URL stays unclassified until LLM classification")
        func genericBlog() {
            #expect(StudioViewModel.detectSourceType(url: "https://blog.example.com/some-post") == .unclassified)
        }

        @Test("Substack URL stays unclassified until LLM classification")
        func substack() {
            #expect(StudioViewModel.detectSourceType(url: "https://danluu.substack.com/p/some-article") == .unclassified)
        }

        @Test("Case insensitivity: uppercase YouTube still detected as video")
        func uppercaseYouTube() {
            #expect(StudioViewModel.detectSourceType(url: "https://WWW.YOUTUBE.COM/watch?v=abc123") == .video)
        }

        @Test("Case insensitivity: mixed case TTML suffix detected as podcast")
        func mixedCaseTTML() {
            #expect(StudioViewModel.detectSourceType(url: "https://example.com/Transcript.TTML") == .podcast)
        }

        @Test("URL with no scheme parsed correctly for domain matching")
        func noScheme() {
            // URLComponents may fail to parse without a scheme, falling through to unclassified
            #expect(StudioViewModel.detectSourceType(url: "example.com/some-page") == .unclassified)
        }

        @Test("Wikipedia URL stays unclassified until LLM classification")
        func wikipedia() {
            #expect(StudioViewModel.detectSourceType(url: "https://en.wikipedia.org/wiki/Transformer_(deep_learning_architecture)") == .unclassified)
        }
    }
}

@Suite("Scholarly paper guardrails")
struct ScholarlyPaperGuardrailTests {
    @Test("Ground-truth paper identifiers (PDF, DOI, arXiv) are scholarly papers")
    func paperIdentifiersDetected() {
        #expect(StudioViewModel.looksLikeScholarlyPaper(url: "/tmp/paper.pdf"))
        #expect(StudioViewModel.looksLikeScholarlyPaper(url: "https://doi.org/10.1234/some.paper"))
        #expect(StudioViewModel.looksLikeScholarlyPaper(url: "https://arxiv.org/abs/2602.05993"))
    }

    @Test("A .book proposal on a paper URL is corrected to paper")
    func bookProposalOnPaperURLBecomesPaper() {
        #expect(
            StudioViewModel.refinedSourceType(proposed: .book, url: "https://arxiv.org/abs/2602.05993") == .paper
        )
    }

    @Test("Title alone no longer forces paper — the LLM classification is trusted")
    func paperyTitleNoLongerCoercesToPaper() {
        // Previously a journal-style title or an arXiv-ID-looking title would flip
        // a .book to .paper. That fuzzy title heuristic was removed; without a
        // ground-truth URL/DOI signal, the classifier's decision stands.
        #expect(!StudioViewModel.looksLikeScholarlyPaper(url: "https://example.com/some-page"))
        #expect(
            StudioViewModel.refinedSourceType(proposed: .book, url: "https://example.com/some-page") == .book
        )
    }

    @Test("Local book files stay books")
    func realBookFilesStayBooks() {
        #expect(
            StudioViewModel.refinedSourceType(
                proposed: .book,
                url: "/Users/x/ForeverLM/Books/raschka/llm-from-scratch.pdf"
            ) == .book
        )
        #expect(
            StudioViewModel.refinedSourceType(
                proposed: .book,
                url: "/Users/x/ForeverLM/Books/alon/systems-biology.pdf"
            ) == .book
        )
    }
}

// MARK: - Meeting Session Keys

@Suite("Meeting Session Keys")
struct MeetingSessionKeyTests {

    @Test("Session key embeds a date that meetingDate can parse")
    func sessionKeyEmbedsParseableDate() throws {
        let date = try #require(DateComponents(calendar: .current, year: 2026, month: 6, day: 10).date)
        let key = StudioViewModel.readAISessionKey(
            title: "[EF] Aging Biology Study Group",
            date: date,
            includeTime: false
        )
        #expect(key.contains("[EF] Aging Biology Study Group"))
        #expect(key.contains("2026/06/10"))
    }
}
