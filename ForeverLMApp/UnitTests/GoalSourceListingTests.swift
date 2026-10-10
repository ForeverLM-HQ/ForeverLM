import Foundation
import Testing
@testable import ForeverLM

/// The rows behind the "11 sources" chip on a Goal row (product owner, 2026-09-19:
/// "make sure i can click sources here and they can be listed"). See
/// `GoalSourceListing` in GoalsViews.swift.
@Suite("Goal source listing")
struct GoalSourceListingTests {

    @Test("Loaded, archived and gone sources each get a row that says what they are")
    func threeKindsOfRow() {
        let archived = SourceRowSummary(id: "b", title: "Archived podcast", status: .archived, type: .podcast)
        let rows = GoalSourceListing.rows(
            sourceIDs: ["a", "b", "c"],
            activeTitle: { $0 == "a" ? "Loaded paper" : nil },
            activeType: { $0 == "a" ? .paper : nil },
            storedRow: { $0 == "b" ? archived : nil }
        )

        #expect(rows.map(\.id) == ["a", "b", "c"])
        #expect(rows[0].presence == .inLibrary(title: "Loaded paper"))
        #expect(rows[0].symbolName == StudioSourceType.paper.symbolName)
        #expect(rows[1].presence == .archived(title: "Archived podcast"))
        #expect(rows[1].symbolName == StudioSourceType.podcast.symbolName)
        #expect(rows[2].presence == .gone)
        #expect(rows[2].symbolName == "doc.text")
    }

    @Test("A pool that names an id twice lists it once, in pool order")
    func duplicatesCollapse() {
        let rows = GoalSourceListing.rows(
            sourceIDs: ["x", "y", "x"],
            activeTitle: { $0.uppercased() },
            activeType: { _ in .article },
            storedRow: { _ in nil }
        )
        #expect(rows.map(\.id) == ["x", "y"])
    }

    @Test("The heading counts in words")
    func heading() {
        #expect(GoalSourceListing.heading(count: 1) == "1 source")
        #expect(GoalSourceListing.heading(count: 11) == "11 sources")
    }
}
