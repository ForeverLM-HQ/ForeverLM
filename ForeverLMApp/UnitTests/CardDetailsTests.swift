import Foundation
import Testing
@testable import ForeverLM

/// A card and its details (docs/memory-design.md, "Cards that nest"): an overview card whose answer is
/// the arc of an argument, a line a step, and a card for each step, asked at once from the overview's
/// answer ("zoom in") and on its own schedule otherwise.
@Suite("Card details")
struct CardDetailsTests {
    private typealias F = MemorySyncFixture

    // MARK: The answer, point by point

    @Test("Each line of the answer takes the detail whose point it is, numbered or bulleted; the rest follow")
    func pointsMatchLines() {
        let back = """
        1. **Mitochondria** were once free-living bacteria.
        2. Their genome shrank to a few genes.
        - The host gained energy per gene.
        """
        let details = [
            link("d2", "Their genome shrank to a few genes", order: 1),
            link("d1", "Mitochondria were once free-living bacteria.", order: 0),
            link("d9", "A point the answer does not print", order: 2),
        ]
        let layout = MemoryCardPoints.layout(back: back, details: details)
        #expect(layout.lines.map(\.detailID) == ["d1", "d2", nil])
        #expect(layout.lines.map(\.text).first == "1. **Mitochondria** were once free-living bacteria.")
        #expect(layout.unplaced.map(\.childID) == ["d9"])
        #expect(layout.hasDetails)
        #expect(!MemoryCardPoints.layout(back: back, details: []).hasDetails)
    }

    // MARK: Zooming in during a review

    @Test("Zooming in asks the detail now, then shows the overview's answer again, still to grade")
    func zoomReturnsToTheOverview() throws {
        let overview = card("overview")
        let detail = card("detail")
        var sitting = MemoryCardSitting(key: "k", kind: .today, cards: [overview, card("next")])
        let early = sitting.zoomIn(to: detail)
        #expect(!early, "nothing to zoom from before the answer shows")
        sitting.showAnswerUnanswered()
        let zoomed = sitting.zoomIn(to: detail)
        #expect(zoomed)
        #expect(sitting.current?.itemID == "detail" && !sitting.isAnswerShown)
        let deeper = sitting.zoomIn(to: card("other"))
        #expect(!deeper, "one level")
        sitting.showAnswerUnanswered()
        let answered = sitting.answer(remembered: true)
        let answer = try #require(answered)
        #expect(answer.itemID == "detail" && answer.practice, "a detail today did not deal is practice: never pushes its review out")
        #expect(sitting.current?.itemID == "overview" && sitting.isAnswerShown && sitting.zoom == nil)
        let overviewAnswer = sitting.answer(remembered: false)
        let graded = try #require(overviewAnswer)
        #expect(graded.itemID == "overview" && !graded.practice)
        #expect(sitting.current?.itemID == "next")
    }

    @Test("A detail the round deals later comes forward, counts as the round's, and is not asked twice")
    func dealtDetailComesForward() throws {
        let detail = card("detail")
        var sitting = MemoryCardSitting(key: "k", kind: .today, cards: [card("overview"), card("middle"), detail])
        sitting.showAnswerUnanswered()
        let zoomed = sitting.zoomIn(to: detail)
        #expect(zoomed)
        #expect(sitting.cards.map(\.itemID) == ["detail", "overview", "middle"])
        sitting.showAnswerUnanswered()
        let answered = sitting.answer(remembered: true)
        let answer = try #require(answered)
        #expect(!answer.practice)
    }

    @Test("Back without answering puts the detail back where the round had it, and the overview's answer shows")
    func zoomOutRestores() {
        let detail = card("detail")
        var sitting = MemoryCardSitting(key: "k", kind: .today, cards: [card("overview"), detail])
        let shown = sitting.showAnswer(attempt: "my words")
        let zoomed = sitting.zoomIn(to: detail)
        #expect(shown && zoomed)
        sitting.zoomOut()
        #expect(sitting.cards.map(\.itemID) == ["overview", "detail"])
        #expect(sitting.isAnswerShown && sitting.attempt == "my words" && sitting.zoom == nil)
        let removed = sitting.removeCurrent()
        #expect(removed != nil, "a kept card can be deleted once the zoom is closed")
    }

    // MARK: Storage

    @Test("Links are set in order, keep when they were made, refuse cycles and unknown cards, and follow a Start Over")
    func storageSetsLinks() throws {
        let (root, store) = try F.makeStore("card-details")
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["arg", "s1", "s2", "s3"] { try F.item(store, id: id) }
        let first = try store.setCardDetails(
            parentID: "arg",
            [MemoryCardDetailSpec(childID: "s1", point: "Step one"), MemoryCardDetailSpec(childID: "s2", point: "Step two")],
            at: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        #expect(first.linked.map(\.childID) == ["s1", "s2"] && first.refused.isEmpty)
        let second = try store.setCardDetails(
            parentID: "arg",
            [
                MemoryCardDetailSpec(childID: "s2", point: "Step two"),
                MemoryCardDetailSpec(childID: "nope", point: ""),
                MemoryCardDetailSpec(childID: "arg", point: ""),
            ],
            at: Date(timeIntervalSinceReferenceDate: 900_000_000)
        )
        #expect(second.linked.map(\.childID) == ["s2"] && second.linked.first?.order == 0)
        #expect(second.linked.first?.linkedAt == 800_000_000, "a detail it had keeps when it was linked")
        #expect(second.refused == [.unknownCard("nope"), .itself("arg")])
        let cycle = try store.setCardDetails(parentID: "s2", [MemoryCardDetailSpec(childID: "arg", point: "")])
        #expect(cycle.refused == [.cycle("arg")] && cycle.linked.isEmpty)
        #expect(try store.cardOverviews(ofChildren: ["s2"])["s2"]?.map(\.parentID) == ["arg"])

        try store.moveCardLinks(from: "s2", to: "s3")
        #expect(try store.cardDetails(ofParents: ["arg"])["arg"]?.map(\.childID) == ["s3"])
        #expect(try store.cardOverviews(ofChildren: ["s2"]).isEmpty)
    }

    @Test("An overview's details go out on its record, one element each; one unlinked goes out removed; one arriving lands")
    func detailsSync() throws {
        let (root, store) = try F.makeStore("card-details-sync")
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["arg", "s1", "s2"] { try F.item(store, id: id) }
        try F.sendAll(store)
        try store.setCardDetails(parentID: "arg", [
            MemoryCardDetailSpec(childID: "s1", point: "Step one"), MemoryCardDetailSpec(childID: "s2", point: "Step two"),
        ])
        let change = try #require(try F.pending(store)["Card:arg"])
        #expect(F.changed(change) == ["details"])
        let details = try #require(F.fields(change)?["details"]?.objectValue)
        #expect(details["s1"]?["point"] == "Step one" && details["s2"]?["order"] == SyncJSON(1))
        #expect(try F.pending(store)["Card:s1"] == nil, "the detail's own record does not change")

        try F.sendAll(store)
        try store.setCardDetails(parentID: "arg", [MemoryCardDetailSpec(childID: "s2", point: "Step two")])
        let removal = try #require(try F.pending(store)["Card:arg"])
        let after = try #require(F.fields(removal)?["details"]?.objectValue)
        #expect(after["s1"]?.isNull == true, "unlinked here: removed for every device")

        try F.sendAll(store)
        try F.apply(store, [try F.record(.card, "arg", [
            "status": "kept",
            "details": ["s3": ["point": "Step three", "order": 0, "linkedAt": 1_759_000_000_000], "s2": .null],
        ])])
        let landed = try store.cardDetails(ofParents: ["arg"])["arg"] ?? []
        #expect(landed.map(\.childID) == ["s3"] && landed.first?.point == "Step three")
    }

    // MARK: Helpers

    private func link(_ child: String, _ point: String, order: Int) -> MemoryCardDetailLink {
        MemoryCardDetailLink(parentID: "p", childID: child, point: point, order: order, linkedAt: 0)
    }

    private func card(_ id: String) -> MemoryCardSitting.Card {
        MemoryCardSitting.Card(itemID: id, prompt: "Question \(id)?", back: "Answer \(id)")
    }
}
