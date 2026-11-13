import Testing
import Foundation
@testable import ForeverLM

@discardableResult
private func insert(
    _ store: KnowledgeStore,
    url: String,
    type: StudioSourceType = .paper,
    doi: String? = nil,
    publishedDOI: String? = nil
) throws -> StudioArticle {
    var article = StudioArticle(url: url, title: "Title for \(url)", sourceType: type)
    article.normalizedURL = URLNormalizer.normalize(url)
    article.doi = doi
    article.publishedDOI = publishedDOI
    try store.insertSourceIfNew(&article)
    return article
}

/// A reference line in a doc is an ordinary web link; the card over it says
/// whether the library holds the source. These pin how that question is
/// answered: the same identity rules the importers use to refuse a duplicate.
@Suite("Doc reference cards: library matching")
struct ArtifactReferenceCardTests {

    @Test("An address saved verbatim is in the library")
    func exactURL() throws {
        let store = try TestStores.inMemory()
        let saved = try insert(store, url: "https://example.com/essays/mitochondria", type: .article)
        #expect(store.activeSourceID(forReferenceURL: "https://example.com/essays/mitochondria") == saved.id)
        #expect(store.activeSourceID(forReferenceURL: "https://example.com/essays/other") == nil)
    }

    @Test("A source card's private address is answered by id, exact or by a prefix only one source has")
    func sourceAddressByID() throws {
        let store = try TestStores.inMemory()
        let saved = try insert(store, url: "https://example.com/essays/mitochondria", type: .article)
        let other = try insert(store, url: "https://example.com/essays/other", type: .article)
        #expect(store.activeSourceID(forReferenceURL: "foreverlm://source/\(saved.id)") == saved.id)
        #expect(store.activeSourceID(forReferenceURL: "https://foreverlm.invalid/source/\(saved.id)") == saved.id)
        #expect(store.activeSourceID(forReferenceURL: "foreverlm://source/\(saved.id)?book=b1") == saved.id)
        #expect(store.activeSourceID(forReferenceURL: "foreverlm://source/not-a-source-anyone-has") == nil)
        // The chat cites by the shortest prefix that names one source.
        let prefix = String(saved.id.prefix(12))
        #expect(prefix.count >= 8)
        let ambiguous = saved.id.commonPrefix(with: other.id)
        if ambiguous.count >= 8 {
            #expect(store.activeSourceID(forReferenceURL: "foreverlm://source/\(ambiguous)") == nil)
        }
        if !other.id.hasPrefix(prefix) {
            #expect(store.activeSourceID(forReferenceURL: "foreverlm://source/\(prefix)") == saved.id)
        }
        // A card names one source by id, so it is that source's card in a
        // page of any library: a team page shows a paper of My Library, and
        // a page of My Library shows a team's copy.
        #expect(store.activeSourceID(forReferenceURL: "foreverlm://source/\(saved.id)", teamID: "team-1") == saved.id)
        // A web address still asks the page's own library.
        #expect(store.activeSourceID(forReferenceURL: "https://example.com/essays/mitochondria", teamID: "team-1") == nil)
    }

    @Test("Tracking parameters do not hide a saved article")
    func normalizedURL() throws {
        let store = try TestStores.inMemory()
        let saved = try insert(store, url: "https://example.com/essays/mitochondria", type: .article)
        #expect(
            store.activeSourceID(forReferenceURL: "https://example.com/essays/mitochondria?utm_source=newsletter")
                == saved.id
        )
    }

    @Test("A paper is found through its DOI whichever address the reference uses")
    func doiAcrossAddresses() throws {
        let store = try TestStores.inMemory()
        let saved = try insert(
            store,
            url: "https://doi.org/10.1038/s41586-021-03819-2",
            doi: "10.1038/s41586-021-03819-2"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://www.nature.com/articles/s41586-021-03819-2") == saved.id)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1038/S41586-021-03819-2") == saved.id)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1038/s41586-021-03819-3") == nil)
    }

    @Test("A preprint's version suffix is not part of its identity")
    func doiVersionSuffix() throws {
        let store = try TestStores.inMemory()
        let versioned = try insert(
            store,
            url: "https://www.biorxiv.org/content/10.1101/2022.07.20.500902v1",
            doi: "10.1101/2022.07.20.500902v1"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1101/2022.07.20.500902") == versioned.id)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1101/2022.07.20.500902v3") == versioned.id)
        // The reverse: the library holds the bare DOI, the reference names a version.
        let bare = try insert(
            store,
            url: "https://www.biorxiv.org/content/10.1101/2023.01.01.100000",
            doi: "10.1101/2023.01.01.100000"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://www.biorxiv.org/content/10.1101/2023.01.01.100000v2") == bare.id)
    }

    @Test("A v after a letter is part of the DOI: two Oxford papers of one year stay two papers")
    func doiLetterBeforeV() throws {
        let store = try TestStores.inMemory()
        // 2015 Oxford DOIs carry the year letter v. Saved under a publisher address, so only the
        // DOI can match them.
        let ensembl = try insert(
            store,
            url: "https://academic.oup.com/nar/article/44/D1/D710/2503080",
            doi: "10.1093/nar/gkv1157"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1093/nar/gkv1344") == nil)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1093/NAR/GKV1157") == ensembl.id)
        let pfam = try insert(
            store,
            url: "https://academic.oup.com/nar/article/44/D1/D279/2503120",
            doi: "10.1093/nar/gkv1344"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1093/nar/gkv1344") == pfam.id)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1093/nar/gkv1157") == ensembl.id)
    }

    @Test("Research Square and preprints.org versions are one preprint, with or without the version")
    func doiPreprintServerVersions() throws {
        let store = try TestStores.inMemory()
        let researchSquare = try insert(
            store,
            url: "https://www.researchsquare.com/article/rs-4356493/v1",
            doi: "10.21203/rs.3.rs-4356493/v1"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.21203/rs.3.rs-4356493/v2") == researchSquare.id)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.21203/rs.3.rs-4356493") == researchSquare.id)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.21203/rs.3.rs-4356494/v1") == nil)
        let preprint = try insert(
            store,
            url: "https://www.preprints.org/manuscript/202608.1166/v1",
            doi: "10.20944/preprints202608.1166.v1"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.20944/preprints202608.1166.v2") == preprint.id)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.20944/preprints202608.1166") == preprint.id)
    }

    @Test("The journal version of a saved preprint is the saved preprint")
    func publishedDOI() throws {
        let store = try TestStores.inMemory()
        let preprint = try insert(
            store,
            url: "https://www.biorxiv.org/content/10.1101/2024.11.04.615786v3",
            doi: "10.1101/2024.11.04.615786v3",
            publishedDOI: "10.1038/s41586-025-01000-1"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1038/s41586-025-01000-1") == preprint.id)
    }

    @Test("An arXiv paper matches its abstract and PDF addresses, but not a longer identifier")
    func arxivIdentifier() throws {
        let store = try TestStores.inMemory()
        let saved = try insert(store, url: "https://arxiv.org/abs/1706.03762")
        #expect(store.activeSourceID(forReferenceURL: "https://arxiv.org/pdf/1706.03762v5") == saved.id)
        #expect(store.activeSourceID(forReferenceURL: "https://arxiv.org/abs/1706.03762v2") == saved.id)
        #expect(store.activeSourceID(forReferenceURL: "https://arxiv.org/abs/1706.0376") == nil)
    }

    @Test("An arXiv paper imported as a PDF is found through arXiv's DataCite DOI")
    func arxivDataCiteDOI() throws {
        let store = try TestStores.inMemory()
        // A PDF import records the DOI and a local path, never the arXiv address.
        let imported = try insert(
            store,
            url: "/Users/learner/Library/Application Support/ForeverLM/Content/Papers/arxiv_org_html_2603_17380v1.pdf",
            doi: "10.48550/arxiv.2603.17380"
        )
        #expect(store.activeSourceID(forReferenceURL: "https://arxiv.org/abs/2603.17380") == imported.id)
        #expect(store.activeSourceID(forReferenceURL: "https://arxiv.org/pdf/2603.17380v1") == imported.id)
        // And the other way round: the library has the arXiv address, the reference the DOI.
        let byAddress = try insert(store, url: "https://arxiv.org/abs/1706.03762")
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.48550/arXiv.1706.03762") == byAddress.id)
        #expect(KnowledgeStore.arxivID(fromDOI: "10.48550/arXiv.1706.03762") == "1706.03762")
        #expect(KnowledgeStore.arxivID(fromDOI: "10.1038/s41586-021-03819-2") == nil)
    }

    @Test("A Nature paper's PDF hosted on another site is the saved paper")
    func natureArticleIDOffHost() throws {
        let store = try TestStores.inMemory()
        // Imported from the PDF: the library's file path is its address, and
        // the DOI is what the record knows about where it came from.
        let saved = try insert(store, url: "Papers/10.1038_s41467-025-66778-6.pdf", doi: "10.1038/s41467-025-66778-6")
        // insitro hosts its own Nature Communications paper under Nature's file name.
        #expect(
            store.activeSourceID(forReferenceURL: "https://www.insitro.com/wp-content/uploads/2026/02/s41467-025-66778-6.pdf")
                == saved.id
        )
        #expect(store.activeSourceID(forReferenceURL: "https://mirror.example/papers/S41467-025-66778-6?download=1") == saved.id)
        // A neighbouring id, and an id that is only part of a file name, are not this paper.
        #expect(store.activeSourceID(forReferenceURL: "https://www.insitro.com/wp-content/uploads/2026/02/s41467-025-66778-7.pdf") == nil)
        #expect(store.activeSourceID(forReferenceURL: "https://mirror.example/s41467-025-66778-6-supplement.pdf") == nil)
    }

    @Test("A Springer or BMC paper with the same id shape is matched by its own DOI only")
    func springerNatureIDSuffixIsPublisherAgnostic() throws {
        let store = try TestStores.inMemory()
        let bmc = try insert(store, url: "Papers/10.1186_s13059-024-03200-1.pdf", doi: "10.1186/s13059-024-03200-1")
        #expect(store.activeSourceID(forReferenceURL: "https://lab.example/pdfs/s13059-024-03200-1.pdf") == bmc.id)
        #expect(store.activeSourceID(forReferenceURL: "https://lab.example/pdfs/s41467-024-03200-1.pdf") == nil)
    }

    /// A team Doc's cards ask the team library and nothing else (teams-design
    /// decision 13): a paper a member holds privately is not in the team's
    /// library, and the team's copy is not in My Library's answer.
    @Test("A team Doc's card asks the team library, a My Library Doc's asks My Library")
    func libraryScope() throws {
        let store = try TestStores.inMemory()
        let now = Date()
        let team = TeamRecord(
            id: "team-1",
            name: "Nexus",
            role: .owner,
            permission: .readWrite,
            zoneScope: .privateScope,
            zoneName: TeamRecord.zoneName(forTeamID: "team-1"),
            zoneOwnerRecordName: nil,
            shareRecordName: nil,
            shareURL: nil,
            createdAt: now,
            joinedAt: now,
            updatedAt: now
        )
        try store.saveTeam(team)
        let url = "https://www.nature.com/articles/s41586-021-03819-2"
        let own = try insert(store, url: url, doi: "10.1038/s41586-021-03819-2")
        let privateOnly = try insert(store, url: "https://doi.org/10.1016/j.cell.2024.01.001", doi: "10.1016/j.cell.2024.01.001")

        // Held privately only: My Library says yes, the team says no.
        #expect(store.activeSourceID(forReferenceURL: url) == own.id)
        #expect(store.activeSourceID(forReferenceURL: url, teamID: team.id) == nil)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1038/s41586-021-03819-2", teamID: team.id) == nil)

        // Shared with the team: the team answers with its copy, by address and by DOI,
        // and My Library still answers with the member's own row.
        let copyID = try store.copySourceIntoTeam(sourceID: own.id, teamID: team.id) { _ in nil }
        #expect(copyID != own.id)
        #expect(store.activeSourceID(forReferenceURL: url, teamID: team.id) == copyID)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1038/S41586-021-03819-2", teamID: team.id) == copyID)
        #expect(store.activeSourceID(forReferenceURL: url) == own.id)

        // Another team is another library.
        #expect(store.activeSourceID(forReferenceURL: url, teamID: "team-2") == nil)
        #expect(store.activeSourceID(forReferenceURL: privateOnly.url, teamID: team.id) == nil)
    }

    @Test("An archived source is not in the library")
    func archivedSource() throws {
        let store = try TestStores.inMemory()
        let saved = try insert(store, url: "https://doi.org/10.1038/s41586-021-03819-2", doi: "10.1038/s41586-021-03819-2")
        try store.archiveSource(saved.id)
        #expect(store.activeSourceID(forReferenceURL: "https://doi.org/10.1038/s41586-021-03819-2") == nil)
    }

    @Test("The editor's status contract carries state and source id")
    func statusJSON() throws {
        let statuses: [String: ArtifactReferenceStatus] = [
            "https://doi.org/10.1038/x": .inLibrary(sourceID: "src_1"),
            "https://example.com/y": .absent,
            "https://example.com/z": .failed("Could not add"),
        ]
        let data = try JSONEncoder().encode(statuses)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        #expect(decoded?["https://doi.org/10.1038/x"]?["state"] as? String == "inLibrary")
        #expect(decoded?["https://doi.org/10.1038/x"]?["sourceID"] as? String == "src_1")
        #expect(decoded?["https://example.com/y"]?["state"] as? String == "absent")
        #expect(decoded?["https://example.com/z"]?["message"] as? String == "Could not add")
        // A status without a picture resolved yet carries no picture keys at
        // all, and one with a picture carries the three the tile reads.
        #expect(decoded?["https://example.com/y"]?["kind"] == nil)
        #expect(decoded?["https://example.com/y"]?["thumbnailURL"] == nil)
        var pictured = ArtifactReferenceStatus.inLibrary(sourceID: "src_2")
        pictured.kind = "paper"
        pictured.thumbnailURL = "data:image/jpeg;base64,AAAA"
        pictured.iconURL = "https://example.com/favicon.ico"
        let picturedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pictured)) as? [String: Any]
        #expect(picturedJSON?["kind"] as? String == "paper")
        #expect(picturedJSON?["thumbnailURL"] as? String == "data:image/jpeg;base64,AAAA")
        #expect(picturedJSON?["iconURL"] as? String == "https://example.com/favicon.ico")
        #expect(pictured != .inLibrary(sourceID: "src_2"))

        // A team Doc's request states ride the same contract: the request id
        // in sourceID, who asked in message.
        let request = ShareRequestRecord(id: "req-9", teamID: "team-1", url: "https://example.com/z", requestedByDisplayName: "Ada")
        let requested = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ArtifactReferenceStatus.requested(request))) as? [String: Any]
        #expect(requested?["state"] as? String == "requested")
        #expect(requested?["sourceID"] as? String == "req-9")
        #expect(requested?["message"] as? String == "Requested by Ada")
        #expect(ArtifactReferenceStatus.fulfillable(request).state == .fulfillable)
        #expect(ArtifactReferenceStatus.requestable("Paywalled").message == "Paywalled")
    }
}

/// A card whose source is not in the library shows a link preview: the page's
/// icon, resolved from its head. These pin the parsing, which is the part of the
/// preview that does not need the network.
@Suite("Doc reference cards: link preview parsing")
struct ReferenceLinkPreviewParsingTests {

    private let page = URL(string: "https://journal.example.org/articles/s41586")!

    @Test("An apple-touch-icon wins over a favicon, and relative addresses resolve against the page")
    func touchIconFirst() {
        let head = """
        <html><head>
        <link rel="icon" type="image/png" sizes="32x32" href="/static/favicon-32.png">
        <link rel="apple-touch-icon" sizes="180x180" href="/static/touch-icon.png">
        <meta property="og:image" content="https://cdn.example.org/cover.jpg">
        </head><body></body></html>
        """
        #expect(
            ReferenceLinkPreviews.iconURL(inHead: head, baseURL: page)
                == "https://journal.example.org/static/touch-icon.png"
        )
    }

    @Test("A shortcut icon, single-quoted or unquoted, is still the icon")
    func shortcutIcon() {
        let head = "<link href='favicon.ico' rel='shortcut icon'><link rel=stylesheet href=/site.css>"
        #expect(
            ReferenceLinkPreviews.iconURL(inHead: head, baseURL: page)
                == "https://journal.example.org/articles/favicon.ico"
        )
    }

    @Test("A stylesheet or a preload is not an icon, and a head without one has none")
    func noIcon() {
        let head = "<link rel=\"stylesheet\" href=\"/a.css\"><link rel=\"preload\" as=\"image\" href=\"/hero.jpg\">"
        #expect(ReferenceLinkPreviews.iconURL(inHead: head, baseURL: page) == nil)
    }

    @Test("Only a web address reaches the tile")
    func addresses() {
        #expect(ReferenceLinkPreviews.resolveAddress("//cdn.example.org/i.png", baseURL: page) == "https://cdn.example.org/i.png")
        #expect(ReferenceLinkPreviews.resolveAddress("../icons/i.png", baseURL: page) == "https://journal.example.org/icons/i.png")
        #expect(ReferenceLinkPreviews.resolveAddress("data:image/svg+xml;base64,AAAA", baseURL: page) == nil)
        #expect(ReferenceLinkPreviews.resolveAddress("javascript:alert(1)", baseURL: page) == nil)
        #expect(ReferenceLinkPreviews.resolveAddress("   ", baseURL: page) == nil)
        #expect(ReferenceLinkPreviews.resolveAddress("/i.png", baseURL: nil) == nil)
    }
}

/// A link a footnote cites gets a card when the pointer rests on the
/// footnote's number, drawn like a Sources sidebar row: title and a metadata
/// line. For a source the library does not hold, both come from the page's own
/// head.
@Suite("Doc footnote cards: what a card says")
struct ArtifactFootnoteCardSummaryTests {

    private let page = URL(string: "https://www.journal.example.org/articles/s41586")!

    @Test("A scholarly page reads as a paper: title, first author et al. · venue · year")
    func scholarlyHead() {
        let head = """
        <html><head>
        <title>The source of cell-free mitochondrial DNA in trauma | Springer</title>
        <meta name="citation_title" content="The source of cell-free mitochondrial DNA in trauma and potential therapeutic strategies">
        <meta name="citation_author" content="Kabilan Thurairajah">
        <meta name="citation_author" content="Gabrielle Daisy Briggs">
        <meta name="citation_author" content="Zsolt J. Balogh">
        <meta name="citation_journal_title" content="European Journal of Trauma and Emergency Surgery">
        <meta name="citation_publication_date" content="2018/04/01">
        <meta property="og:site_name" content="SpringerLink">
        </head><body></body></html>
        """
        let summary = ReferenceLinkPreviews.summary(inHead: head, url: page)
        #expect(summary.title == "The source of cell-free mitochondrial DNA in trauma and potential therapeutic strategies")
        #expect(summary.detail == "Kabilan Thurairajah et al. · European Journal of Trauma and Emergency Surgery · 2018")
    }

    @Test("An ordinary page reads as a page: its own title, the site's name and the year it declares")
    func pageHead() {
        let head = """
        <head>
        <meta property="og:title" content="OrsoBio Announces Positive Topline Phase 1b/2a Data &amp; Next Steps">
        <meta property="og:site_name" content="OrsoBio">
        <meta property="article:published_time" content="2026-03-12T14:00:00Z">
        <title>OrsoBio Announces Positive Topline Phase 1b/2a Data - OrsoBio</title>
        </head>
        """
        let summary = ReferenceLinkPreviews.summary(inHead: head, url: URL(string: "https://orsobio.com/press-release/x/"))
        #expect(summary.title == "OrsoBio Announces Positive Topline Phase 1b/2a Data & Next Steps")
        #expect(summary.detail == "OrsoBio · 2026")
    }

    @Test("A page with only a <title> stands on it and the host, without the site suffix")
    func bareTitle() {
        let head = "<head><title>Our pipeline | Mission Therapeutics</title></head>"
        let summary = ReferenceLinkPreviews.summary(inHead: head, url: URL(string: "https://www.missiontherapeutics.com/pipeline/"))
        #expect(summary.title == "Our pipeline")
        #expect(summary.detail == "missiontherapeutics.com")
    }

    @Test("A head with nothing to say leaves the card on the words that cite it")
    func emptyHead() {
        let summary = ReferenceLinkPreviews.summary(inHead: "<head></head>", url: nil)
        #expect(summary.title == nil)
        #expect(summary.detail == nil)
    }

    @Test("A saved paper's line is the sidebar row's, without Unknown placeholders")
    func libraryPaperDetail() {
        let paper = StudioArticle(
            url: "https://doi.org/10.1038/x",
            title: "A paper",
            sourceType: .paper,
            author: "Ada Lovelace; Charles Babbage; Alan Turing",
            journal: "Nature",
            publishedYear: "2024"
        )
        #expect(ReferenceCardArtwork.libraryDetail(for: paper) == "Ada Lovelace et al. · Nature · 2024")

        // No author, venue or year: the row's "Unknown …" placeholders stay
        // out, and the card falls back to the address's domain instead.
        let bare = StudioArticle(url: "https://doi.org/10.1038/y", title: "Another", sourceType: .paper)
        #expect(ReferenceCardArtwork.libraryDetail(for: bare) == nil)
        var preprint = StudioArticle(url: "https://www.biorxiv.org/content/10.1101/2024.01.01.000001v1", title: "Preprint", sourceType: .paper)
        preprint.publishedYear = "2024"
        #expect(ReferenceCardArtwork.libraryDetail(for: preprint) == "bioRxiv · 2024")
    }

    @Test("A saved article's line is its author and site")
    func libraryArticleDetail() {
        var article = StudioArticle(url: "https://orsobio.com/our-pipeline/", title: "Pipeline", sourceType: .article, author: "OrsoBio")
        article.domain = "orsobio.com"
        #expect(ReferenceCardArtwork.libraryDetail(for: article) == "OrsoBio · orsobio.com")
        var quiet = StudioArticle(url: "https://example.com/a", title: "Quiet", sourceType: .article)
        quiet.domain = ""
        #expect(ReferenceCardArtwork.libraryDetail(for: quiet) == nil)
    }

    @Test("A book chapter's stored folder path is never its line")
    func libraryChapterDetailSkipsPath() {
        var chapter = StudioArticle(
            url: "/Users/learner/Books/SystemsBiology/Chapters/06.xhtml",
            title: "6) Cells: Decisions, Decisions",
            sourceType: .book
        )
        chapter.domain = "/Users/learner/Library/Mobile Documents/Books/SystemsBiology/Chapters"
        #expect(chapter.displayDomain == nil)
        #expect(ReferenceCardArtwork.libraryDetail(for: chapter) == nil)
        #expect(StudioArticle.displayDomain(" bigbiology.substack.com ") == "bigbiology.substack.com")
        #expect(StudioArticle.displayDomain("file:///Users/learner/Books") == nil)
    }

    @Test("A book chapter's card draws its book's cover, not a page of the chapter")
    func chapterCardWearsBookCover() {
        let coverPaths = ["book-1": "/Users/learner/Books/LifeWorks/cover.jpg"]
        var chapter = StudioArticle(url: "/Users/learner/Books/LifeWorks/LifeWorks.pdf", title: "How Life Works", sourceType: .book)
        chapter.parentGroup = "book-1"
        #expect(ReferenceCardArtwork.bookCoverPath(for: chapter, coverPaths: coverPaths) == "/Users/learner/Books/LifeWorks/cover.jpg")

        // A book without a cover keeps the chapter's own picture.
        chapter.parentGroup = "book-2"
        #expect(ReferenceCardArtwork.bookCoverPath(for: chapter, coverPaths: coverPaths) == nil)

        // Only a chapter is drawn as its book: a course lesson grouped under
        // the same key is not.
        var lesson = StudioArticle(url: "foreverlm://course/c1/lesson/1", title: "Lesson 1", sourceType: .course)
        lesson.parentGroup = "book-1"
        #expect(ReferenceCardArtwork.bookCoverPath(for: lesson, coverPaths: coverPaths) == nil)
    }

    @Test("The editor's status contract carries the card's title and detail")
    func statusJSON() throws {
        var status = ArtifactReferenceStatus.inLibrary(sourceID: "src_1")
        status.title = "A paper"
        status.detail = "Ada Lovelace et al. · Nature · 2024"
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
        #expect(json?["title"] as? String == "A paper")
        #expect(json?["detail"] as? String == "Ada Lovelace et al. · Nature · 2024")
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ArtifactReferenceStatus.absent)) as? [String: Any]
        #expect(plain?["title"] == nil)
        #expect(plain?["detail"] == nil)
    }
}
