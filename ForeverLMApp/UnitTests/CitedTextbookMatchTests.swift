import Foundation
import Testing
@testable import ForeverLM

/// A textbook cited on a slide is the book on the shelf, not a paper the catalogs lack.
@Suite("Cited textbook match")
struct CitedTextbookMatchTests {
    private typealias Book = CitedTextbookMatch.Book

    private let bioenergetics = Book(
        id: "book-bioenergetics",
        title: "Bioenergetics",
        subtitle: "Bioenergetics 4, Fourth Edition (2013) 434pp. 978-0-12-388425-1",
        edition: "Fourth Edition",
        author: "David G. Nicholls & Stuart J. Ferguson",
        openingChapterID: "chapter-1"
    )

    private let alberts = Book(
        id: "book-mboc",
        title: "Molecular Biology of the Cell",
        edition: "Seventh Edition",
        author: "Bruce Alberts, Rebecca Heald, Alexander Johnson, David Morgan, Martin Raff, Keith Roberts & Peter Walter",
        openingChapterID: "mboc-1"
    )

    /// The row the scan stored on 2026-09-27: the corner attribution with no title.
    private func attribution(authors: String?, journal: String, year: String? = nil) -> VideoCitedPaper {
        VideoCitedPaper(
            sourceID: "lecture-14",
            title: VideoCitedPaper.attributionLabel(authors: authors, journal: journal, year: year),
            authors: authors,
            year: year,
            journal: journal,
            status: .unresolved
        )
    }

    @Test("The course's textbook is matched by its printed name")
    func courseTextbookMatchesByName() {
        let match = CitedTextbookMatch.book(
            for: attribution(authors: "Nicholls; Ferguson", journal: "Bioenergetics"),
            courseTextbooks: [bioenergetics],
            libraryBooks: [alberts]
        )
        #expect(match == bioenergetics)
    }

    @Test("An edition tacked onto the name is still the book")
    func editionSuffixIsDropped() {
        for printed in ["Bioenergetics 4", "Bioenergetics, 4th ed.", "Bioenergetics Fourth Edition"] {
            let match = CitedTextbookMatch.book(
                for: attribution(authors: "Nicholls;Ferguson", journal: printed),
                courseTextbooks: [bioenergetics],
                libraryBooks: []
            )
            #expect(match == bioenergetics, "\(printed)")
        }
        #expect(CitedTextbookMatch.nameKey("Bioenergetics 4") == "bioenergetics")
        #expect(CitedTextbookMatch.nameKey("Molecular Biology of the Cell, 7th Edition") == "molecular biology of the cell")
    }

    @Test("A course textbook needs no author when the slide printed none")
    func courseTextbookMatchesTitleAlone() {
        let candidate = VideoCitedPaper(sourceID: "lecture-14", title: "Bioenergetics", status: .unresolved)
        #expect(CitedTextbookMatch.book(for: candidate, courseTextbooks: [bioenergetics], libraryBooks: []) == bioenergetics)
        #expect(CitedTextbookMatch.book(for: candidate, courseTextbooks: [], libraryBooks: [bioenergetics]) == nil)
    }

    @Test("Any book in the library matches when name and author both agree")
    func libraryBookNeedsAuthor() {
        let named = attribution(authors: "Alberts", journal: "Molecular Biology of the Cell")
        #expect(CitedTextbookMatch.book(for: named, courseTextbooks: [], libraryBooks: [alberts]) == alberts)
        // The second author on the cover counts too.
        let coauthor = attribution(authors: "Heald", journal: "Molecular Biology of the Cell")
        #expect(CitedTextbookMatch.book(for: coauthor, courseTextbooks: [], libraryBooks: [alberts]) == alberts)
    }

    @Test("A printed author that is not the book's refuses the match")
    func wrongAuthorRefuses() {
        let other = attribution(authors: "Lehninger", journal: "Bioenergetics")
        #expect(CitedTextbookMatch.book(for: other, courseTextbooks: [bioenergetics], libraryBooks: []) == nil)
        #expect(CitedTextbookMatch.book(for: other, courseTextbooks: [], libraryBooks: [bioenergetics]) == nil)
    }

    @Test("A paper is never taken for a book")
    func papersAreNotBooks() {
        let kim = attribution(authors: "Kim", journal: "Am J Physiol", year: "2006")
        #expect(CitedTextbookMatch.book(for: kim, courseTextbooks: [bioenergetics], libraryBooks: [alberts]) == nil)

        var resolved = attribution(authors: "Nicholls", journal: "Bioenergetics")
        resolved.doi = "10.1000/example"
        resolved.url = "https://doi.org/10.1000/example"
        resolved.status = .pending
        #expect(CitedTextbookMatch.book(for: resolved, courseTextbooks: [bioenergetics], libraryBooks: []) == nil)

        var linked = attribution(authors: "Nicholls", journal: "Bioenergetics")
        linked.kind = .article
        #expect(CitedTextbookMatch.book(for: linked, courseTextbooks: [bioenergetics], libraryBooks: []) == nil)
    }

    @Test("The held row keeps what was read and points at the book's opening chapter")
    func heldRowPointsAtTheBook() {
        let read = attribution(authors: "Nicholls; Ferguson", journal: "Bioenergetics 4")
        let held = CitedTextbookMatch.held(read, in: bioenergetics)
        #expect(held.status == .imported)
        #expect(held.importedSourceID == "chapter-1")
        #expect(held.title == read.title)
        #expect(held.dedupKey == read.dedupKey)
    }

    @Test("Cover author lines split into surnames")
    func coverAuthorsSplit() {
        #expect(CitedTextbookMatch.bookAuthorSurnames("David G. Nicholls & Stuart J. Ferguson") == ["Nicholls", "Ferguson"])
        #expect(CitedTextbookMatch.bookAuthorSurnames("Erwin Schrodinger and Roger Penrose") == ["Schrodinger", "Penrose"])
        #expect(CitedTextbookMatch.bookAuthorSurnames(nil).isEmpty)
    }
}

/// What a slide has to print for the read to count as a citation.
@Suite("Slide citation keep rule")
struct SlideCitationKeepRuleTests {
    @Test("A DOI printed on its own is a citation")
    func printedDOIIsEnough() {
        #expect(SlideCitationService.readsAsCitation(
            title: nil, authors: nil, year: nil, journal: nil,
            doi: "10.1016/j.redox.2018.101065", locator: nil
        ))
        #expect(!SlideCitationService.readsAsCitation(
            title: nil, authors: nil, year: "2019", journal: "Redox Biology", doi: nil, locator: nil
        ))
        #expect(SlideCitationService.readsAsCitation(
            title: nil, authors: "Kowaltowski", year: "2019", journal: nil, doi: nil, locator: nil
        ))
    }

    @Test("A printed DOI is read out of a doi.org link, a prefix, or an encoded address bar")
    func printedDOINormalizes() {
        let expected = "10.1016/j.redox.2018.101065"
        #expect(SlideCitationService.printedDOI("https://dx.doi.org/10.1016%2Fj.redox.2018.101065") == expected)
        #expect(SlideCitationService.printedDOI("https://doi.org/10.1016/j.redox.2018.101065?via=slide") == expected)
        #expect(SlideCitationService.printedDOI("doi: 10.1016/j.redox.2018.101065.") == expected)
        #expect(SlideCitationService.printedDOI(expected) == expected)
        #expect(SlideCitationService.printedDOI("Redox Biology 21 (2019) 101065") == nil)
        #expect(SlideCitationService.printedDOI("   ") == nil)
        #expect(SlideCitationService.printedDOI(nil) == nil)
    }
}
