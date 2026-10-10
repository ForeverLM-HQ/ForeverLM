import Foundation
import Testing
@testable import ForeverLM

/// The iPhone's Add sources sheet (docs/notebooks-design.md, "iPhone"): the
/// links it takes from a paste — at most ten, each once, in order, by the
/// Mac's rule for a link — and the honest name scanned pages and photos are
/// filed under.
@Suite("Add sources on the phone")
struct MobileNotebookAddSourcesTests {

    // MARK: - Links pasted together

    @Test("A link is what the Mac's field takes: an http(s) address with a dotted host, or a DOI")
    func linkIsTheMacsRule() {
        #expect(MobileNotebookPastedLinks.link(in: "https://www.nature.com/articles/s41586-024-07000-0")
            == "https://www.nature.com/articles/s41586-024-07000-0")
        #expect(MobileNotebookPastedLinks.link(in: "http://example.org") == "http://example.org")
        #expect(MobileNotebookPastedLinks.link(in: "10.1038/nature12373") == "https://doi.org/10.1038/nature12373")
        #expect(MobileNotebookPastedLinks.link(in: "doi:10.1126/science.abc1234")
            == "https://doi.org/10.1126/science.abc1234")
        #expect(MobileNotebookPastedLinks.link(in: "DOI:10.1126/science.abc1234")
            == "https://doi.org/10.1126/science.abc1234")
        // Not links: no scheme, no dotted host, another scheme, words.
        #expect(MobileNotebookPastedLinks.link(in: "www.example.com") == nil)
        #expect(MobileNotebookPastedLinks.link(in: "https://localhost/page") == nil)
        #expect(MobileNotebookPastedLinks.link(in: "ftp://example.com/file") == nil)
        #expect(MobileNotebookPastedLinks.link(in: "mitochondria") == nil)
        #expect(MobileNotebookPastedLinks.link(in: "10.5") == nil)
        #expect(MobileNotebookPastedLinks.link(in: "doi:11.1/x") == nil)
        // Every field's agreement with the Mac's own rule, address by address.
        for token in ["https://a.com", "10.1/x", "doi:10.1/x", "https://localhost", "word", "https://a.com/x y"] {
            #expect(MobileNotebookPastedLinks.link(in: token) == StudioViewModel.importableLink(in: token))
        }
    }

    @Test("Words are a search, not links")
    func wordsAreNoLinks() {
        #expect(MobileNotebookPastedLinks.read("oxidative phosphorylation") == .none)
        #expect(MobileNotebookPastedLinks.read("") == .none)
        #expect(MobileNotebookPastedLinks.read("https://") == .none)
    }

    @Test("Links apart by new lines, spaces or commas are each taken, in the order pasted")
    func linksApartAreTaken() {
        let pasted = """
        https://a.example.com/one
        https://b.example.com/two https://c.example.com/three,https://d.example.com/four, 10.1038/nature12373
        """
        #expect(MobileNotebookPastedLinks.read(pasted).links == [
            "https://a.example.com/one",
            "https://b.example.com/two",
            "https://c.example.com/three",
            "https://d.example.com/four",
            "https://doi.org/10.1038/nature12373",
        ])
    }

    @Test("A paste that lost its line breaks still gives each link")
    func runTogetherLinksAreSplit() {
        #expect(MobileNotebookPastedLinks.read("https://a.example.com/onehttps://b.example.com/two").links == [
            "https://a.example.com/one",
            "https://b.example.com/two",
        ])
        #expect(MobileNotebookPastedLinks.read("[Paper](https://a.example.com/paper)").links == [
            "https://a.example.com/paper",
        ])
    }

    @Test("A comma or an address inside an address keeps it whole")
    func addressesInsideStayWhole() {
        #expect(MobileNotebookPastedLinks.read("https://maps.example.com/@52.37,4.89,12z").links == [
            "https://maps.example.com/@52.37,4.89,12z",
        ])
        #expect(MobileNotebookPastedLinks.read("https://out.example.com/r?url=https://a.example.com/x").links == [
            "https://out.example.com/r?url=https://a.example.com/x",
        ])
        #expect(MobileNotebookPastedLinks.read("https://archive.example.org/web/2024/https://a.example.com").links == [
            "https://archive.example.org/web/2024/https://a.example.com",
        ])
    }

    @Test("Quotes, brackets and the sentence mark around a link are not part of it")
    func wrappingIsTakenOff() {
        let pasted = "See <https://a.example.com/x>, (https://b.example.com/y). \u{201C}https://c.example.com/z\u{201D}"
        #expect(MobileNotebookPastedLinks.read(pasted).links == [
            "https://a.example.com/x",
            "https://b.example.com/y",
            "https://c.example.com/z",
        ])
        // A bracket the address opened is its own.
        #expect(MobileNotebookPastedLinks.read("https://en.wikipedia.org/wiki/Cell_(biology).").links == [
            "https://en.wikipedia.org/wiki/Cell_(biology)",
        ])
    }

    @Test("A link pasted twice is added once, and two spellings of one source are one link")
    func duplicatesAreOne() {
        #expect(MobileNotebookPastedLinks.read("https://a.example.com/x https://a.example.com/x").links == [
            "https://a.example.com/x",
        ])
        let sameSource: (String) -> String = { link in
            link.lowercased()
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "www.", with: "")
        }
        #expect(MobileNotebookPastedLinks.read(
            "https://www.a.example.com/x https://a.example.com/x https://b.example.com/y",
            sameSource: sameSource
        ).links == ["https://www.a.example.com/x", "https://b.example.com/y"])
    }

    @Test("One paste adds the first ten distinct links and counts the ones left out")
    func tenAtMost() {
        let links = (1...14).map { "https://site\($0).example.com/page" }
        let pasted = (links + [links[0], links[3]]).joined(separator: "\n")
        let reading = MobileNotebookPastedLinks.read(pasted)
        #expect(reading.links == Array(links.prefix(10)))
        #expect(reading.leftOut == 4)
        #expect(MobileNotebookPastedLinks.read(links.prefix(10).joined(separator: " ")).leftOut == 0)
    }

    @Test("The add button says the Mac's Add link for one, and counts more")
    func addTitle() {
        #expect(MobileNotebookPastedLinks.addTitle(count: 1) == "Add link")
        #expect(MobileNotebookPastedLinks.addTitle(count: 3) == "Add 3 links")
    }

    // MARK: - Pages captured on the phone

    @Test("Scanned pages and photos are named for what they are and when they came in")
    func pagesTitle() {
        let date = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03 04:00 UTC
        let utc = TimeZone(identifier: "UTC")!
        let scan = MobileCapturedPages.title(
            kind: .scan,
            madeAt: date,
            locale: Locale(identifier: "en_GB"),
            timeZone: utc
        )
        #expect(scan.hasPrefix("Scan · "))
        #expect(scan.contains("2026"))
        #expect(scan.contains("October"))
        #expect(scan.contains("4:00"))
        let photos = MobileCapturedPages.title(
            kind: .photos,
            madeAt: date,
            locale: Locale(identifier: "en_US"),
            timeZone: utc
        )
        #expect(photos.hasPrefix("Photos · October 3, 2026"))
    }

    @Test("A title becomes a file name a path can hold")
    func fileName() {
        #expect(MobileCapturedPages.fileName(forTitle: "Scan · 3 October 2026 at 03:20")
            == "Scan · 3 October 2026 at 03.20.pdf")
        #expect(MobileCapturedPages.fileName(forTitle: "Photos · 10/3/2026, 3:20\u{202F}AM")
            == "Photos · 10-3-2026, 3.20 AM.pdf")
    }

    @Test("A page count reads as words")
    func countLine() {
        #expect(MobileCapturedPages.countLine(1) == "1 page")
        #expect(MobileCapturedPages.countLine(4) == "4 pages")
    }
}
