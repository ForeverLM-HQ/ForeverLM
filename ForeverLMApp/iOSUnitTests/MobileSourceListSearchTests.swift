import Foundation
import XCTest
@testable import ForeverLM

/// The one search the phone's lists share. Every screen below Sources — a type,
/// a book, a course, a Notebook — filters through it, so what it matches is what
/// the learner can find without scrolling.
final class MobileSourceListSearchTests: XCTestCase {
    private func source(
        _ id: String,
        title: String,
        subtitle: String? = nil,
        type: String = "paper",
        author: String? = nil,
        journal: String? = nil,
        year: String? = nil,
        parentGroup: String? = nil
    ) -> MobileCloudSource {
        MobileCloudSource(
            id: id,
            title: title,
            subtitle: subtitle,
            sourceType: type,
            dateAdded: Date(timeIntervalSinceReferenceDate: 0),
            hasAudio: false,
            isArchived: false,
            author: author,
            journal: journal,
            publishedYear: year,
            parentGroup: parentGroup
        )
    }

    func testEmptyQueryIsNoFilter() {
        let sources = [source("a", title: "Alpha"), source("b", title: "Beta")]
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "").map(\.id), ["a", "b"])
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "   \n").map(\.id), ["a", "b"])
        XCTAssertTrue(MobileSourceListSearch.terms(in: " \t ").isEmpty)
    }

    func testEveryTermMustMatchInAnyOrder() {
        let sources = [
            source("warburg", title: "The Warburg effect: 80 years on"),
            source("mitoq", title: "Mitochondria-targeted antioxidant MitoQ radiosensitizes"),
            source("defender", title: "Mitochondrial Modulators: The Defender"),
        ]
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "mito").map(\.id), ["mitoq", "defender"])
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "defender mito").map(\.id), ["defender"])
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "years warburg").map(\.id), ["warburg"])
        XCTAssertTrue(MobileSourceListSearch.filter(sources, query: "warburg mito").isEmpty)
    }

    func testIgnoresCaseAndAccents() {
        let sources = [
            source("rourke", title: "Enhancing Mitochondrial Ca2+ Uptake", author: "Ting Liu; Brian O’Rourke"),
            source("muller", title: "Über die Zelle", author: "Jürgen Müller"),
        ]
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "MULLER uber").map(\.id), ["muller"])
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "müller").map(\.id), ["muller"])
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "o’rourke").map(\.id), ["rourke"])
    }

    func testMatchesTheFieldsARowShows() {
        let sources = [
            source("a", title: "A comprehensive atlas of somatic mutation rates",
                   author: "My H. Pham; Luke M. R. Harvey", journal: "Nature Genetics", year: "2026"),
            source("b", title: "Enhancing Mitochondrial Ca2+ Uptake",
                   author: "Ting Liu; Brian O’Rourke", journal: "Circulation Research", year: "2008"),
            source("c", title: "Episode 12", subtitle: "Huberman Lab", type: "podcast"),
        ]
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "harvey").map(\.id), ["a"])
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "circulation").map(\.id), ["b"])
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "2008").map(\.id), ["b"])
        XCTAssertEqual(MobileSourceListSearch.filter(sources, query: "huberman").map(\.id), ["c"])
    }

    func testMatchesTheBookOrCourseASourceBelongsTo() {
        let chapters = [
            source("ch1", title: "Replacement", type: "book", parentGroup: "book-1"),
            source("ch2", title: "Introduction", type: "book", parentGroup: "book-2"),
        ]
        let titles = ["book-1": "Mitochondria and the Future of Medicine", "book-2": "Behave"]
        let found = MobileSourceListSearch.filter(chapters, query: "future replacement") { source in
            source.parentGroup.flatMap { titles[$0] }
        }
        XCTAssertEqual(found.map(\.id), ["ch1"])
    }

    func testGroupedTypeKeepsMatchingContainersAndSurfacesMatchingMembers() {
        let sapolsky = MobileSourceGroup(
            id: "book-1",
            title: "Behave",
            subtitle: "Robert Sapolsky",
            sources: [
                source("b1c1", title: "The Behavior", type: "book", parentGroup: "book-1"),
                source("b1c2", title: "One Second Before", type: "book", parentGroup: "book-1"),
            ]
        )
        let lane = MobileSourceGroup(
            id: "book-2",
            title: "Power, Sex, Suicide",
            subtitle: "Nick Lane",
            sources: [
                source("b2c1", title: "Mitochondria and the meaning of life", type: "book", parentGroup: "book-2"),
                source("b2c2", title: "The Behaviour of Mitochondria", type: "book", parentGroup: "book-2"),
            ]
        )
        let standalone = [source("solo", title: "Behavioral Economics", type: "book")]

        // A container found by its own title stays whole; "Behaviour" and
        // "Behavioral" elsewhere are rows of their own.
        let byTitle = MobileSourceListSearch.filter(groups: [sapolsky, lane], standalone: standalone, query: "behav")
        XCTAssertEqual(byTitle.groups.map(\.id), ["book-1"])
        XCTAssertEqual(byTitle.members.map(\.id), ["b2c2", "solo"])

        // The author shown under the book counts for the book.
        let byAuthor = MobileSourceListSearch.filter(groups: [sapolsky, lane], standalone: standalone, query: "sapolsky")
        XCTAssertEqual(byAuthor.groups.map(\.id), ["book-1"])
        XCTAssertTrue(byAuthor.members.isEmpty)

        // A chapter found by its own name is a row, whichever book holds it.
        let byChapter = MobileSourceListSearch.filter(groups: [sapolsky, lane], standalone: standalone, query: "mitochondria")
        XCTAssertTrue(byChapter.groups.isEmpty)
        XCTAssertEqual(byChapter.members.map(\.id), ["b2c1", "b2c2"])

        // The book's title and author count for its chapters too.
        let byBookAndChapter = MobileSourceListSearch.filter(groups: [sapolsky, lane], standalone: standalone, query: "lane meaning")
        XCTAssertEqual(byBookAndChapter.members.map(\.id), ["b2c1"])

        // No query, no filter.
        let all = MobileSourceListSearch.filter(groups: [sapolsky, lane], standalone: standalone, query: "")
        XCTAssertEqual(all.groups.map(\.id), ["book-1", "book-2"])
        XCTAssertEqual(all.members.map(\.id), ["solo"])
    }

    func testCourseFoldersKeepOnlyMatchingItemsAndDropEmptyFolders() {
        let lectures = MobileSourceGroupSection(
            id: "lectures",
            title: "Lectures",
            systemImage: "play.rectangle",
            items: [
                MobileSourceGroupItem(source: source("l1", title: "Lecture", type: "video"), displayTitle: "1) Introduction"),
                MobileSourceGroupItem(source: source("l2", title: "Lecture", type: "video"), displayTitle: "3) Architectures"),
            ]
        )
        let materials = MobileSourceGroupSection(
            id: "materials",
            title: "Materials",
            systemImage: "doc",
            items: [MobileSourceGroupItem(source: source("m1", title: "Syllabus", type: "paper"))]
        )

        let architectures = MobileSourceListSearch.filter(sections: [lectures, materials], query: "architect")
        XCTAssertEqual(architectures.map(\.id), ["lectures"])
        XCTAssertEqual(architectures.first?.items.map(\.id), ["l2"])

        let syllabus = MobileSourceListSearch.filter(sections: [lectures, materials], query: "syllabus")
        XCTAssertEqual(syllabus.map(\.id), ["materials"])

        XCTAssertEqual(MobileSourceListSearch.filter(sections: [lectures, materials], query: "").count, 2)
        XCTAssertTrue(MobileSourceListSearch.filter(sections: [lectures, materials], query: "nothing here").isEmpty)
    }
}
