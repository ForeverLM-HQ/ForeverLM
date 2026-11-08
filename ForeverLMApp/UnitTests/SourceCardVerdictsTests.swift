import Foundation
import Testing
@testable import ForeverLM

@Suite("Sources and their cards")
struct SourceCardVerdictsTests {
    private func row(_ id: String, _ state: SourceCardState, daysAgo: Double = 0, title: String? = nil) -> SourceCardRow {
        SourceCardRow(
            id: id,
            title: title ?? id,
            sourceType: .article,
            dateAdded: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            state: state
        )
    }

    @Test("A source's state says kept cards first, then drafts waiting, then retired ones, else none")
    func stateFromWhatTheLibraryHolds() {
        #expect(SourceCardState(keptCards: 3, hasDrafts: true, isAnchored: true) == .cards(3))
        #expect(SourceCardState(keptCards: 0, hasDrafts: true, isAnchored: true) == .toCheck)
        #expect(SourceCardState(keptCards: 0, hasDrafts: false, isAnchored: true) == .retired)
        #expect(SourceCardState(keptCards: 0, hasDrafts: false, isAnchored: false) == .none)
    }

    @Test("A row says how many cards it has and offers Make Cards, or Make More Cards once it has some")
    func labelsAndVerdictTitles() {
        #expect(SourceCardState.none.label == nil)
        #expect(SourceCardState.toCheck.label == "To check")
        #expect(SourceCardState.cards(1).label == "1 card")
        #expect(SourceCardState.cards(12).label == "12 cards")
        #expect(SourceCardState.retired.label == "Retired")
        #expect(SourceCardState.none.makeCardsTitle == "Write Card")
        for state in [SourceCardState.toCheck, .cards(2), .retired] {
            #expect(state.makeCardsTitle == "Write Another Card")
        }
    }

    @Test("The sources with no card come first, the newest first within each")
    func coverageOrder() {
        let coverage = SourceCardCoverage(rows: [
            row("old-kept", .cards(2), daysAgo: 1),
            row("old-none", .none, daysAgo: 30),
            row("new-none", .none, daysAgo: 2),
            row("new-kept", .cards(1), daysAgo: 0),
        ])
        #expect(coverage.rows.map(\.id) == ["new-none", "old-none", "new-kept", "old-kept"])
        #expect(coverage.withoutCards.map(\.id) == ["new-none", "old-none"])
        #expect(coverage.counts.withoutCards == 2)
        #expect(coverage.counts.all == 4)
        #expect(coverage.state(of: "new-kept") == .cards(1))
        #expect(coverage.state(of: "unknown") == .none)
    }

    @Test("No Cards lists what has no card, All lists everything, and a search narrows by title")
    func filtering() {
        let rows = SourceCardCoverage(rows: [
            row("a", .none, title: "Mitochondria and aging"),
            row("b", .cards(3), title: "Mitochondrial dynamics"),
            row("c", .toCheck, title: "Sleep and memory"),
        ]).rows
        #expect(SourceCardList.filter(rows, scope: .withoutCards).map(\.id) == ["a"])
        #expect(Set(SourceCardList.filter(rows, scope: .all).map(\.id)) == ["a", "b", "c"])
        #expect(Set(SourceCardList.filter(rows, scope: .all, query: "  MITOCHONDRI ").map(\.id)) == ["a", "b"])
        #expect(SourceCardList.filter(rows, scope: .withoutCards, query: "sleep").isEmpty)
        #expect(SourceCardList.filter(rows, scope: .all, query: "zzz").isEmpty)
    }

    @Test("A notebook's sources narrow the list, and a source just removed leaves it at once")
    func narrowingAndRemoval() {
        let rows = SourceCardCoverage(rows: [row("a", .none), row("b", .none), row("c", .none)]).rows
        #expect(SourceCardList.filter(rows, scope: .withoutCards, allowed: ["a", "c"]).map(\.id) == ["a", "c"])
        #expect(SourceCardList.filter(rows, scope: .withoutCards, removed: ["b"]).map(\.id) == ["a", "c"])
        #expect(SourceCardList.filter(rows, scope: .all, allowed: ["a", "b"], removed: ["a"]).map(\.id) == ["b"])
        #expect(SourceCardList.filter(rows, scope: .all, allowed: []).isEmpty)
    }

    @Test("A coverage answers each listed source's state from a set, and whether no card covers it")
    func statesByID() {
        let coverage = SourceCardCoverage(rows: [row("a", .none), row("b", .cards(2)), row("c", .toCheck)])
        #expect(coverage.statesByID == ["a": .none, "b": .cards(2), "c": .toCheck])
        #expect(coverage.isWithoutCards("a"))
        #expect(!coverage.isWithoutCards("b"))
        #expect(!coverage.isWithoutCards("c"))
        #expect(!coverage.isWithoutCards("not-listed"), "a source that cannot have cards is not without cards")
        #expect(!coverage.isEmpty)
        #expect(SourceCardCoverage().isEmpty)
    }

    @Test("The list of sources is the Library's: Memory keeps Review, To Check and All Cards, and the pill is No Cards")
    func theLibraryHoldsTheList() {
        #expect(MemoryPaneSection.allCases == [.review, .toCheck, .allCards])
        #expect(MemoryPaneSection.allCases.map(\.title) == ["Review", "To Check", "All Cards"])
        #expect(SourceCardScope.withoutCards.title == "No Cards")
        #expect(SourceCardList.batchSize == 10)
    }
}
