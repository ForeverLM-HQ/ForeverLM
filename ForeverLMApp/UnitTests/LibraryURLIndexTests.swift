// The Library URL index, navigation rail, course import banner and transcript chunking tests.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

// MARK: - Library URL index

/// The chat's web sources footer asks whether each citation is already in the
/// library, once per citation per build of its row, and a lazy transcript
/// rebuilds that row every time it scrolls back into view. Before 2026-09-07 the
/// answer was a scan of `articles` that normalized every stored URL on the main
/// thread; the 1.05 s stall the product owner reported that afternoon was that scan
/// (`ui-stall-2026-09-07T20-19-03`). It is now one set lookup against a table
/// built once per articles revision.
@Suite("Library URL index")
@MainActor
struct LibraryURLIndexTests {
    @Test("Two hundred lookups over a library cost one normalization pass")
    func lookupsShareOnePass() {
        let vm = makeViewModel()
        let paper = makeArticle(url: "/Users/someone/Library/Papers/attention.pdf", title: "Paper", sourceType: .paper)
        let page = makeArticle(url: "https://www.Example.com/story/?utm_source=x", title: "Page")
        let episode = makeArticle(url: "apple-podcast://episode/1000758651501", title: "Episode", sourceType: .podcast)
        vm.articles = [paper, page, episode]

        for index in 0..<200 {
            #expect(vm.libraryContainsSource(normalizedURL: SourceDiscovery.normalizedURL(page.url)))
            #expect(vm.libraryContainsSource(normalizedURL: SourceDiscovery.normalizedURL(episode.url)))
            #expect(vm.libraryContainsSource(normalizedURL: SourceDiscovery.normalizedURL(paper.url)))
            #expect(!vm.libraryContainsSource(normalizedURL: "example.com/not-saved-\(index)"))
        }
        // One scan for 800 answers, however many rows the transcript rebuilt.
        #expect(vm.sidebarStore.libraryURLKeysBuilds == 1)
    }

    @Test("The index follows the library through adds and removes")
    func indexFollowsTheLibrary() {
        let vm = makeViewModel()
        let first = makeArticle(url: "https://example.com/first", title: "First")
        vm.articles = [first]
        let firstKey = SourceDiscovery.normalizedURL(first.url)
        let secondKey = SourceDiscovery.normalizedURL("https://example.com/second")
        #expect(vm.libraryContainsSource(normalizedURL: firstKey))
        #expect(!vm.libraryContainsSource(normalizedURL: secondKey))

        vm.articles.append(makeArticle(url: "https://example.com/second/", title: "Second"))
        #expect(vm.libraryContainsSource(normalizedURL: secondKey))

        vm.articles.removeAll { $0.id == first.id }
        #expect(!vm.libraryContainsSource(normalizedURL: firstKey))
        #expect(vm.libraryContainsSource(normalizedURL: secondKey))
        // One rebuild per change to the library, none for the repeated reads.
        #expect(vm.sidebarStore.libraryURLKeysBuilds == 3)
    }

    /// The product owner, 2026-09-12: a reply's Web sources offered "Add to Sources" for
    /// a Nature paper already in the library. The paper had been saved from a
    /// recommendation link, `…?fromPaywallRec=false`, and the footer matched on
    /// the address alone. A citation is now also matched by the paper it names.
    @Test("A citation is recognised by the paper's DOI, whatever address the paper was saved under")
    func citationMatchesSavedPaperByDOI() {
        let vm = makeViewModel()
        var fromDOILink = makeArticle(url: "https://doi.org/10.1038/s41586-024-07000-1", title: "By DOI", sourceType: .paper)
        fromDOILink.doi = "10.1038/s41586-024-07000-1"
        var fromPDF = makeArticle(url: "/Users/someone/Library/Papers/preprint.pdf", title: "From PDF", sourceType: .paper)
        fromPDF.doi = "10.1101/2024.11.04.615786v3"
        // A publisher page whose DOI is only in its address, and a page that is not a paper.
        let fromPublisher = makeArticle(url: "https://www.nature.com/articles/s42003-022-04303-x?fromPaywallRec=false", title: "Publisher", sourceType: .paper)
        let page = makeArticle(url: "https://example.com/story", title: "Page")
        vm.articles = [fromDOILink, fromPDF, fromPublisher, page]

        // The bare publisher address a web search cites, for each saved paper.
        #expect(vm.libraryContainsSource(url: "https://www.nature.com/articles/s41586-024-07000-1"))
        #expect(vm.libraryContainsSource(url: "https://www.biorxiv.org/content/10.1101/2024.11.04.615786v1"))
        #expect(vm.libraryContainsSource(url: "https://www.nature.com/articles/s42003-022-04303-x"))
        // The address still matches on its own, DOI or not.
        #expect(vm.libraryContainsSource(url: "https://example.com/story/"))
        // An unrelated paper and an unrelated page are not in the library.
        #expect(!vm.libraryContainsSource(url: "https://www.nature.com/articles/s41586-024-07000-2"))
        #expect(!vm.libraryContainsSource(url: "https://doi.org/10.1000/other"))
        #expect(!vm.libraryContainsSource(url: "https://example.com/other"))
        // One pass built both the address and the DOI keys.
        #expect(vm.sidebarStore.libraryURLKeysBuilds == 1)
    }

    /// The product owner, 2026-09-20: a chat linked the MitoSpace paper by its PubMed
    /// page. The library held the paper under its Cell address, so the Reader
    /// opened PubMed as a live page and offered Add to Sources for a paper
    /// already saved. A PubMed address names only its own record; the page
    /// itself declares the DOI in its head, and once the Reader has read that,
    /// the address resolves to the saved source.
    @Test("A page that declares its DOI resolves to the saved paper, and the address it redirected from does too")
    func pageDeclaredDOIResolvesToSavedPaper() async throws {
        let vm = makeViewModel()
        var paper = makeArticle(
            url: "https://www.cell.com/cell/fulltext/S0092-8674(26)01001-9",
            title: "MitoSpace",
            sourceType: .paper,
            id: "mitospace"
        )
        paper.doi = "10.1016/j.cell.2026.08.028"
        var preprint = makeArticle(url: "/Users/someone/Papers/preprint.pdf", title: "Preprint", sourceType: .paper, id: "preprint")
        preprint.doi = "10.1101/2025.01.01.000001"
        preprint.publishedDOI = "10.1038/s41586-026-00001-1"
        vm.articles = [paper, preprint]

        let pubmed = try #require(URL(string: "https://pubmed.ncbi.nlm.nih.gov/42721963/"))
        let doiLink = try #require(URL(string: "https://doi.org/10.1016/j.cell.2026.08.028"))
        #expect(vm.librarySourceID(forURL: pubmed.absoluteString) == nil)
        #expect(vm.librarySourceID(forURL: doiLink.absoluteString) == "mitospace")
        #expect(vm.librarySourceID(forURL: paper.url) == "mitospace")
        // A preprint's published DOI is a link to the journal version, not the version itself: a
        // link to it is not in the library until that version is (docs/paper-versions.md).
        #expect(vm.librarySourceID(forURL: "https://www.nature.com/articles/s41586-026-00001-1") == nil)

        // The PubMed page loads and its head says which paper it is.
        await vm.notePageDeclaredIdentity(
            pageURLs: [pubmed],
            headHTML: """
            <head><title>4D spatiotemporal landscape - PubMed</title>
            <meta name="citation_doi" content="10.1016/j.cell.2026.08.028">
            <meta name="citation_title" content="4D spatiotemporal landscape"></head>
            """
        )
        #expect(vm.librarySourceID(forURL: pubmed.absoluteString) == "mitospace")
        #expect(vm.libraryContainsSource(url: "https://pubmed.ncbi.nlm.nih.gov/42721963"))

        // A page that names no paper leaves no record and matches nothing.
        let blog = try #require(URL(string: "https://example.com/post"))
        await vm.notePageDeclaredIdentity(pageURLs: [blog], headHTML: "<head><title>Post</title></head>")
        #expect(vm.librarySourceID(forURL: blog.absoluteString) == nil)
        #expect(vm.pageDeclaredDOIs.count == 1)

        // A redirect records the page under both the address asked for and the one that answered.
        let asked = try #require(URL(string: "https://europepmc.org/abstract/MED/99"))
        let answered = try #require(URL(string: "https://europepmc.org/article/MED/99"))
        await vm.notePageDeclaredIdentity(
            pageURLs: [answered, asked],
            headHTML: #"<head><meta name="dc.identifier" content="doi:10.1101/2025.01.01.000001"></head>"#
        )
        #expect(vm.librarySourceID(forURL: asked.absoluteString) == "preprint")
        #expect(vm.librarySourceID(forURL: answered.absoluteString) == "preprint")
    }

    @Test("A web citation the library holds opens as the saved source, not as a live page")
    func webCitationOfSavedPaperOpensTheSource() async throws {
        let destination = StudioWindowState(snapshot: .init(
            centerTabGroups: ["chat*|reader|tasks|notepad|notebooks"],
            navigationRailVisible: true
        ))
        let vm = makeViewModel()
        var paper = makeArticle(url: "https://www.cell.com/cell/fulltext/S0092-8674(26)01001-9", title: "MitoSpace", sourceType: .paper, id: "mitospace")
        paper.doi = "10.1016/j.cell.2026.08.028"
        vm.articles = [paper]

        // The DOI link a chat cites, for a paper saved under its publisher's address: recognised at the click.
        let doiLink = try #require(URL(string: "https://doi.org/10.1016/j.cell.2026.08.028"))
        vm.openWebCitationInReader(doiLink, title: "MitoSpace", in: destination)
        for _ in 0..<200 where destination.readerArticleID != "mitospace" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(destination.externalReaderPage == nil)
        #expect(destination.readerArticleID == "mitospace")

        // An unknown page still opens live, untouched.
        let other = try #require(URL(string: "https://example.com/story"))
        vm.openWebCitationInReader(other, title: "Story", in: destination)
        #expect(destination.externalReaderPage?.url == other)
    }
}

@Suite("Navigation rail chat list truncation")
struct NavigationRailChatListTruncationTests {
    @Test("A fresh list shows one page of twenty and no more")
    func freshListShowsOnePage() {
        #expect(StudioNavigationRail.chatListPageSize == 20)
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: nil, requiredIndex: nil) == 20)
        #expect(StudioNavigationRail.visibleChatCount(total: 4, revealed: nil, requiredIndex: nil) == 4)
        #expect(StudioNavigationRail.visibleChatCount(total: 0, revealed: nil, requiredIndex: nil) == 0)
    }

    @Test("Scrolling to the end reveals a page at a time and never past the end")
    func scrollingRevealsPages() {
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: 40, requiredIndex: nil) == 40)
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: 60, requiredIndex: nil) == 45)
        // A stale revealed count below a page never shrinks the list.
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: 3, requiredIndex: nil) == 20)
    }

    @Test("The open chat stays visible wherever it sits")
    func openChatStaysVisible() {
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: nil, requiredIndex: 27) == 28)
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: nil, requiredIndex: 2) == 20)
        #expect(StudioNavigationRail.visibleChatCount(total: 45, revealed: 40, requiredIndex: 44) == 45)
    }
}

@Suite("Course import banner")
@MainActor
struct CourseImportBannerTests {
    @Test("Hiding the banner keeps it hidden through the import's later phases")
    func hideLastsForTheWholeImport() {
        let vm = makeViewModel()
        vm.playlistImportStatus = "Importing “Thermodynamics”…"
        #expect(vm.visiblePlaylistImportStatus == "Importing “Thermodynamics”…")

        vm.playlistImportBannerHidden = true
        #expect(vm.visiblePlaylistImportStatus == nil)

        // The next phase of the same import must not bring the banner back.
        vm.playlistImportStatus = "Fetching lecture transcripts…"
        #expect(vm.visiblePlaylistImportStatus == nil)
        vm.playlistImportStatus = nil
        #expect(vm.visiblePlaylistImportStatus == nil)
    }

    @Test("A hide is not a setting: an unhidden import shows its banner")
    func unhiddenImportShows() {
        let vm = makeViewModel()
        vm.playlistImportBannerHidden = false
        vm.playlistImportStatus = "Adding course…"
        #expect(vm.visiblePlaylistImportStatus == "Adding course…")
    }
}

@Suite("Readable transcript chunking")
@MainActor
struct ReadableTranscriptChunkingTests {
    @Test("A long caption stream is cut into a handful of chunks, each ending at the last sentence before the limit")
    func chunksFillToTheLimit() {
        let vm = makeViewModel()
        let sentence = "[0:12] the pump moves three sodium ions out and two potassium ions in. "
        let raw = String(repeating: sentence, count: 800)
        let chunks = vm.chunkTranscriptForReadableFormatting(raw)

        // ~56,800 characters at 12,000 a chunk: five chunks, not one per sentence.
        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.count <= 12_000 })
        #expect(chunks.dropLast().allSatisfy { $0.count > 11_000 })
        #expect(chunks.dropLast().allSatisfy { $0.hasSuffix(".") })
        let rawWords = raw.split(whereSeparator: \.isWhitespace).count
        let chunkWords = chunks.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        #expect(chunkWords == rawWords)
    }

    @Test("A stream without punctuation still fills each chunk to a word boundary")
    func unpunctuatedStreamBreaksAtWords() {
        let vm = makeViewModel()
        let raw = String(repeating: "sodium calcium exchanger ", count: 2_000)
        let chunks = vm.chunkTranscriptForReadableFormatting(raw)

        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.count <= 12_000 && !$0.isEmpty })
        #expect(chunks.dropLast().allSatisfy { $0.count > 11_000 })
        #expect(chunks.allSatisfy { $0.hasSuffix("exchanger") || $0.hasSuffix("sodium") || $0.hasSuffix("calcium") })
    }

    @Test("A short transcript is one chunk")
    func shortTranscriptIsOneChunk() {
        let vm = makeViewModel()
        let raw = "[0:00] one short lecture."
        #expect(vm.chunkTranscriptForReadableFormatting(raw) == [raw])
    }
}
