import Foundation
import Testing
@testable import ForeverLM

/// "Find Linked Sources": the links an article carries are found deterministically off its
/// archived page and numbered into its text; a model judges which are sources; identity
/// never passes through the model.
@Suite("Article link discovery")
struct ArticleLinkDiscoveryTests {

    @Test("Article link discovery is a configurable article task")
    func taskContract() {
        #expect(AITask.articleLinkDiscovery.rawValue == "article_link_discovery")
        #expect(AITask.articleLinkDiscovery.sourceType == .article)
        #expect(AITask.advancedTasks.contains(.articleLinkDiscovery))
        #expect(AITask.articleLinkDiscovery.usesBackgroundModelDefault)
        #expect(!AITask.articleLinkDiscovery.requiresVision)
        #expect(AITask.articleLinkDiscovery.defaultPrompt == Prompts.articleLinkDiscovery)
        #expect(
            AITaskSettingsCatalog.descriptor(forRawID: "article_link_discovery")?.displayName
                == "Article Link Discovery"
        )
        #expect(AIUsageTaskLabel.text(for: "article_link_discovery") == "Find Linked Sources")
    }

    @Test("The scan is an MCP tool the chat's study surface can reach")
    func toolContract() {
        let names = MCPToolRegistry.shared.tools.map(\.name)
        #expect(names.contains("scan_article_for_linked_sources"))
        #expect(MCPToolRegistry.annotations(for: "scan_article_for_linked_sources")["openWorldHint"] as? Bool == true)
        #expect(Prompts.mcpServerInstructions.contains("scan_article_for_linked_sources"))
        // A review chat about the article is where "find all the linked sources" is said,
        // and the import is how the picked ones get added from the same chat.
        #expect(ReviewSessionManager.studySurfaceToolNames.contains("scan_article_for_linked_sources"))
        #expect(ReviewSessionManager.studySurfaceToolNames.contains("import_video_cited_paper"))
        #expect(!ReviewSessionManager.chatExcludedToolNames.contains("scan_article_for_linked_sources"))
    }

    @Test("Every web article offers a link read; papers, videos and local files do not")
    func supportedSources() {
        let article = StudioArticle(url: "https://example.substack.com/p/post", title: "A post", sourceType: .article)
        let unclassified = StudioArticle(url: "https://example.com/x", title: "A page", sourceType: .unclassified)
        let paper = StudioArticle(url: "https://doi.org/10.1000/x", title: "A paper", sourceType: .paper)
        let video = StudioArticle(url: "https://www.youtube.com/watch?v=abc", title: "A talk", sourceType: .video)
        let local = StudioArticle(url: "/Users/x/Documents/notes.html", title: "Notes", sourceType: .article)
        #expect(StudioViewModel.supportsLinkDiscovery(article))
        #expect(StudioViewModel.supportsLinkDiscovery(unclassified))
        #expect(!StudioViewModel.supportsLinkDiscovery(paper))
        #expect(!StudioViewModel.supportsLinkDiscovery(video))
        #expect(!StudioViewModel.supportsLinkDiscovery(local))
        #expect(StudioViewModel.supportsCitedSourceDiscovery(paper))
        #expect(StudioViewModel.supportsCitedSourceDiscovery(article))
        #expect(!StudioViewModel.supportsCitedSourceDiscovery(video))
    }

    // MARK: - Reading the links

    /// A Substack-shaped post: prose links, a relative link, a repeated link, and the
    /// page's plumbing (share control, image anchor, fragment, mailto, self-link).
    private let html = """
    <html><head><style>body{}</style></head><body><article>
    <h1>On mitochondria</h1>
    <p>As <a href="https://www.nature.com/articles/s41586-020-00001-1">Smith and colleagues showed</a>, \
    the effect is real. A good primer is <a href='https://www.youtube.com/watch?v=abc123'>this talk</a>.</p>
    <p>I wrote about it <a href="/p/earlier-post?utm_source=share">before</a>. \
    See also <a href="https://www.nature.com/articles/s41586-020-00001-1#Sec2">the same paper</a>.</p>
    <p><a href="#footnote-1">1</a> <a href="mailto:me@example.com">mail me</a> \
    <a href="https://example.substack.com/p/this-post">permalink</a> \
    <a href="https://substackcdn.com/image/fetch/w_1456/https://x.png"><img src="x.png"></a> \
    <a href="https://example.substack.com/p/this-post/comments">Share</a></p>
    </article></body></html>
    """

    private var pageURL: URL { URL(string: "https://example.substack.com/p/this-post")! }

    @Test("Web links are numbered in document order; the page's own plumbing is not a link")
    func readsLinksDeterministically() {
        let reading = ArticleLinkDiscoveryService.read(html: html, pageURL: pageURL)

        #expect(reading.links.map(\.url) == [
            "https://www.nature.com/articles/s41586-020-00001-1",
            "https://www.youtube.com/watch?v=abc123",
            "https://example.substack.com/p/earlier-post?utm_source=share",
            "https://example.substack.com/p/this-post/comments",
        ])
        #expect(reading.links.map(\.index) == [1, 2, 3, 4])
        #expect(reading.links[0].text == "Smith and colleagues showed")
        #expect(reading.links[1].text == "this talk")
        // The relative link resolved against the page.
        #expect(reading.links[2].url.hasPrefix("https://example.substack.com/p/earlier-post"))
    }

    @Test("A repeated address shares one marker, and the markers sit in the prose")
    func markersInText() {
        let reading = ArticleLinkDiscoveryService.read(html: html, pageURL: pageURL)

        #expect(reading.markedText.contains("Smith and colleagues showed [L1]"))
        #expect(reading.markedText.contains("this talk [L2]"))
        #expect(reading.markedText.contains("before [L3]"))
        // Second appearance of the paper, with a fragment, is the same link.
        #expect(reading.markedText.contains("the same paper [L1]"))
        #expect(!reading.markedText.contains("[L5]"))
        // Plumbing is plain words.
        #expect(reading.markedText.contains("mail me"))
        #expect(!reading.markedText.contains("mail me [L"))
        #expect(reading.markedText.contains("permalink"))
        #expect(!reading.markedText.contains("permalink [L"))
        #expect(!reading.markedText.contains("<a "))
        #expect(!reading.markedText.contains("\u{E000}"))
        #expect(reading.linkIndex.contains("[L2] https://www.youtube.com/watch?v=abc123 — \"this talk\""))
    }

    @Test("Addresses that are not web pages are refused")
    func webAddressesOnly() {
        let page = URL(string: "https://example.com/a/b")!
        #expect(ArticleLinkDiscoveryService.absoluteWebAddress("#top", relativeTo: page) == nil)
        #expect(ArticleLinkDiscoveryService.absoluteWebAddress("mailto:x@y.z", relativeTo: page) == nil)
        #expect(ArticleLinkDiscoveryService.absoluteWebAddress("javascript:void(0)", relativeTo: page) == nil)
        #expect(ArticleLinkDiscoveryService.absoluteWebAddress("", relativeTo: page) == nil)
        #expect(ArticleLinkDiscoveryService.absoluteWebAddress("/c?d=1&amp;e=2", relativeTo: page) == "https://example.com/c?d=1&e=2")
        #expect(ArticleLinkDiscoveryService.absoluteWebAddress("https://x.org/p#frag", relativeTo: nil) == "https://x.org/p")
        #expect(ArticleLinkDiscoveryService.absoluteWebAddress("/relative", relativeTo: nil) == nil)
        #expect(ArticleLinkDiscoveryService.isImageAddress("https://cdn.example.com/a.JPG"))
        #expect(ArticleLinkDiscoveryService.isImageAddress("https://substackcdn.com/image/fetch/w_1456/https://x.png"))
        #expect(!ArticleLinkDiscoveryService.isImageAddress("https://example.com/p/png-history"))
    }

    // MARK: - Reading the model's answer

    @Test("Picks decode from the object, fenced or not; an empty list is an answer, prose is not")
    func decodesReply() throws {
        let picks = try ArticleLinkDiscoveryService.decodeReply("""
        ```json
        {"sources": [{"link": 2, "title": "A talk on mitochondria", "why": "Recommended as a primer."}, {"link": 1, "title": "Smith 2020", "why": "The evidence the argument rests on."}]}
        ```
        """)
        #expect(picks.map(\.link) == [2, 1])
        #expect(picks[0].title == "A talk on mitochondria")
        #expect(try ArticleLinkDiscoveryService.decodeReply("{\"sources\": []}").isEmpty)
        #expect(throws: ArticleLinkDiscoveryService.DiscoveryError.self) {
            _ = try ArticleLinkDiscoveryService.decodeReply("The article links to a paper and a talk.")
        }
    }

    // MARK: - Candidates

    @Test("Candidates take their address and kind from the link, their words from the model")
    func candidatesFromPicks() {
        let reading = ArticleLinkDiscoveryService.read(html: html, pageURL: pageURL)
        let picks = [
            ArticleLinkDiscoveryService.Pick(link: 2, title: "A talk on mitochondria", why: "Recommended as a primer."),
            ArticleLinkDiscoveryService.Pick(link: 1, title: "https://www.nature.com/articles/s41586-020-00001-1", why: nil),
            ArticleLinkDiscoveryService.Pick(link: 3, title: nil, why: "  "),
            // A marker the reading does not have: dropped, never invented.
            ArticleLinkDiscoveryService.Pick(link: 9, title: "Ghost", why: "Not in the page."),
            // The same marker twice: one row.
            ArticleLinkDiscoveryService.Pick(link: 2, title: "Duplicate", why: nil),
        ]
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let candidates = ArticleLinkDiscoveryService.candidates(
            from: picks, reading: reading, sourceID: "src-article", now: now
        )

        #expect(candidates.count == 3)
        #expect(candidates.map(\.url) == [
            "https://www.nature.com/articles/s41586-020-00001-1",
            "https://www.youtube.com/watch?v=abc123",
            "https://example.substack.com/p/earlier-post?utm_source=share",
        ])
        #expect(candidates.map(\.kind) == [.paper, .video, .article])
        #expect(candidates.allSatisfy { $0.sourceID == "src-article" && $0.status == .pending && $0.createdAt == now })
        // The paper's DOI is read off its address, so the import dedups on it.
        #expect(candidates[0].doi == "10.1038/s41586-020-00001-1")
        // A bare address is never a title; the link's own words stand in.
        #expect(candidates[0].title == "Smith and colleagues showed")
        #expect(candidates[0].context == nil)
        #expect(candidates[1].title == "A talk on mitochondria")
        #expect(candidates[1].context == "Recommended as a primer.")
        #expect(candidates[2].title == "before")
        #expect(candidates[2].context == nil)
        #expect(candidates[1].displaySubtitle == "youtube.com · Video")
        #expect(candidates[2].displaySubtitle == "example.substack.com · Article")
    }

    @Test("A link with no words and no model title is named after its site")
    func siteAsLastResortTitle() {
        let link = ArticleLinkDiscoveryService.Link(index: 1, url: "https://www.example.org/x", text: "")
        let candidate = ArticleLinkDiscoveryService.candidate(for: link, pick: nil, sourceID: "s", now: Date())
        #expect(candidate.title == "example.org")
        #expect(candidate.kind == .article)
    }

    // MARK: - The candidate row

    @Test("A URL is a candidate's identity when it has no DOI; a title is the last resort")
    func dedupKeys() {
        let linked = VideoCitedPaper(sourceID: "s", title: "Before", url: "https://example.substack.com/p/earlier-post?utm_source=share", kind: .article)
        let sameWithoutTracking = VideoCitedPaper(sourceID: "s", title: "Earlier post", url: "https://example.substack.com/p/earlier-post", kind: .article)
        let doi = VideoCitedPaper(sourceID: "s", title: "Paper", doi: "10.1000/X", url: "https://doi.org/10.1000/x")
        let bare = VideoCitedPaper(sourceID: "s", title: "Some Paper!")
        #expect(linked.dedupKey == sameWithoutTracking.dedupKey)
        #expect(doi.dedupKey == "doi:10.1000/x")
        #expect(bare.dedupKey == "title:some paper")
    }

    @Test("Restore puts an addressable candidate back in play and leaves an addressless one unresolved")
    func restoredStatus() {
        #expect(StudioViewModel.restoredStatus(for: VideoCitedPaper(sourceID: "s", title: "t", url: "https://x.org/p", kind: .article)) == .pending)
        #expect(StudioViewModel.restoredStatus(for: VideoCitedPaper(sourceID: "s", title: "t", doi: "10.1/x")) == .pending)
        #expect(StudioViewModel.restoredStatus(for: VideoCitedPaper(sourceID: "s", title: "t")) == .unresolved)
    }

    @Test("A record written before schema 115 decodes as a paper with nothing to say")
    func decodesOlderPayload() throws {
        let json = """
        {"id":"c1","sourceID":"s1","title":"Old paper","status":"pending","createdAt":0,"updatedAt":0}
        """
        let paper = try JSONDecoder().decode(VideoCitedPaper.self, from: Data(json.utf8))
        #expect(paper.kind == .paper)
        #expect(paper.context == nil)

        let unknownKind = """
        {"id":"c2","sourceID":"s1","title":"From a newer build","status":"pending","kind":"hologram","createdAt":0,"updatedAt":0}
        """
        #expect(try JSONDecoder().decode(VideoCitedPaper.self, from: Data(unknownKind.utf8)).kind == .paper)

        let linked = VideoCitedPaper(sourceID: "s1", title: "A talk", url: "https://youtube.com/watch?v=1", kind: .video, context: "Why.")
        let roundTrip = try JSONDecoder().decode(VideoCitedPaper.self, from: JSONEncoder().encode(linked))
        #expect(roundTrip == linked)
    }

    @Test("The menu and panel name what they read")
    func copy() {
        let article = StudioArticle(url: "https://example.substack.com/p/post", title: "A post", sourceType: .article)
        let paper = StudioArticle(url: "https://doi.org/10.1000/x", title: "A paper", sourceType: .paper)
        let pending = VideoCitedPaper(sourceID: "s", title: "t", url: "https://x.org", kind: .article)
        #expect(CitedSourcesPopover.menuTitle(for: article, papers: []) == "Find Linked Sources")
        #expect(CitedSourcesPopover.menuTitle(for: article, papers: [pending]) == "Linked Sources (1 to add)")
        #expect(CitedSourcesPopover.menuTitle(for: paper, papers: []) == "Find Cited Papers")
        #expect(CitedSourcesPopover.scanTitle(for: article, hasCandidates: false) == "Find linked sources")
        #expect(CitedSourcesPopover.scanTitle(for: article, hasCandidates: true) == "Read links again")
        #expect(CitedSourcesPopover.scanTitle(for: paper, hasCandidates: true) == "Read references again")
    }
}

// TEMPORARY LIVE-ARCHIVE HARNESS — removed before commit.
@Suite("Article link discovery — live archive harness")
struct ArticleLinkDiscoveryLiveArchiveHarness {
    @Test("Reads the links of a real archived page named by FOREVERLM_LINK_ARCHIVE")
    func readsRealArchive() throws {
        guard let path = ProcessInfo.processInfo.environment["FOREVERLM_LINK_ARCHIVE"], !path.isEmpty else { return }
        let html = try String(contentsOfFile: path, encoding: .utf8)
        let pageURL = URL(string: ProcessInfo.processInfo.environment["FOREVERLM_LINK_PAGE_URL"] ?? "")
        let reading = ArticleLinkDiscoveryService.read(html: html, pageURL: pageURL)
        print("HARNESS links=\(reading.links.count) textChars=\(reading.markedText.count)")
        for link in reading.links {
            let kind = VideoCitedPaper.Kind(sourceType: StudioViewModel.detectSourceType(url: link.url))
            print("HARNESS [L\(link.index)] \(kind.rawValue) \(link.url) — \"\(link.text.prefix(60))\"")
        }
        let markers = reading.markedText.components(separatedBy: "[L").count - 1
        print("HARNESS markersInText=\(markers)")
        let sample = reading.markedText.components(separatedBy: "\n").filter { $0.contains("[L") }.prefix(6)
        for line in sample { print("HARNESS TEXT: \(line.prefix(220))") }
        #expect(!reading.links.isEmpty)
    }
}
