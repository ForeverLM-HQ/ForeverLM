import Foundation
import Testing
@testable import ForeverLM

/// What comes onto the Canvas from outside it (docs/knowledge-map-design.md,
/// "Dropping from the rest of the app"): the pure half, `KnowledgeMapOutside`.
@Suite("Canvas from outside: files, paste, answers, other canvases")
struct KnowledgeMapOutsideTests {
    private let height: (String) -> Double = { _ in KnowledgeMap.cardHeight }

    // MARK: A dropped file

    @Test("A file is a paper, a text source, a picture, a refusal, by its extension")
    func fileKinds() {
        #expect(KnowledgeMapOutside.fileKind(forExtension: "PDF") == .paper)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "md") == .textSource)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "markdown") == .textSource)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "txt") == .textSource)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "PNG") == .picture)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "heic") == .picture)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "docx") == .wordDocument)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "epub") == .book)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "xyz") == .unsupported)
        #expect(KnowledgeMapOutside.fileKind(forExtension: "") == .unsupported)
        #expect(KnowledgeMapOutside.refusal(forFileNamed: "a.docx", kind: .wordDocument).contains("Word"))
    }

    // MARK: A card named by an address

    @Test("A foreverlm address names a card; anything else is not one")
    func cardLinks() throws {
        let source = try #require(KnowledgeMapOutside.CardLink("foreverlm://source/src_12"))
        #expect(source == .init(kind: "source", id: "src_12"))
        #expect(KnowledgeMapOutside.CardLink("foreverlm://source/src_12?t=754") == source)
        #expect(KnowledgeMapOutside.CardLink("foreverlm://doc/abc")?.kind == "doc")
        #expect(KnowledgeMapOutside.CardLink("foreverlm://idea/abc")?.kind == "idea")
        #expect(KnowledgeMapOutside.CardLink("foreverlm://canvas/cnv-1")?.kind == "canvas")
        #expect(KnowledgeMapOutside.CardLink("foreverlm://chat/s1")?.kind == "chat")
        // The address a notebook had before the word changed.
        #expect(KnowledgeMapOutside.CardLink("foreverlm://project/n1") == .init(kind: "notebook", id: "n1"))
        #expect(KnowledgeMapOutside.CardLink("foreverlm://source/a%20b")?.id == "a b")
        #expect(KnowledgeMapOutside.CardLink("foreverlm://quiz/q1") == nil)
        #expect(KnowledgeMapOutside.CardLink("foreverlm://source/") == nil)
        #expect(KnowledgeMapOutside.CardLink("https://example.com/source/x") == nil)
        #expect(KnowledgeMapOutside.CardLink("see foreverlm://source/x") == nil)
        // The running build's own scheme names the same card.
        #expect(KnowledgeMapOutside.CardLink("foreverlm-dev://doc/abc", schemes: ["foreverlm", "foreverlm-dev"])?.id == "abc")
        #expect(KnowledgeMapOutside.CardLink("foreverlm-dev://doc/abc") == nil)
    }

    @Test("A paste is addresses to import, cards, or words")
    func pasteClassification() {
        let importable: (String) -> String? = { $0.hasPrefix("https://") ? $0 : nil }
        #expect(KnowledgeMapOutside.classify(pasted: "https://example.com/a", importableLink: importable) == .links(["https://example.com/a"]))
        #expect(KnowledgeMapOutside.classify(pasted: "  https://a.com/x\nhttps://b.com/y \n", importableLink: importable) == .links(["https://a.com/x", "https://b.com/y"]))
        #expect(KnowledgeMapOutside.classify(pasted: "foreverlm://doc/d1", importableLink: importable) == .cards([.init(kind: "doc", id: "d1")]))
        #expect(KnowledgeMapOutside.classify(pasted: "foreverlm://doc/d1 foreverlm://idea/i1", importableLink: importable)
            == .cards([.init(kind: "doc", id: "d1"), .init(kind: "idea", id: "i1")]))
        // One address among words is words.
        #expect(KnowledgeMapOutside.classify(pasted: "read https://a.com/x", importableLink: importable) == .words("read https://a.com/x"))
        #expect(KnowledgeMapOutside.classify(pasted: "Why does PINK1 stabilise on damaged mitochondria?", importableLink: importable)
            == .words("Why does PINK1 stabilise on damaged mitochondria?"))
        #expect(KnowledgeMapOutside.classify(pasted: "   \n ", importableLink: importable) == nil)
    }

    @Test("Pasted words are an Idea's title when short, else the first sentence with the whole text as its note")
    func ideaFromPastedText() throws {
        let short = try #require(KnowledgeMapOutside.idea(fromPasted: "  mitophagy needs PINK1 \n"))
        #expect(short.title == "mitophagy needs PINK1" && short.notes == nil)
        let long = String(repeating: "word ", count: 30) + "end. Another sentence."
        let made = try #require(KnowledgeMapOutside.idea(fromPasted: long))
        #expect(made.notes == long.trimmingCharacters(in: .whitespaces))
        #expect(made.title.count <= KnowledgeMapOutside.titleLimit + 1)
        #expect(KnowledgeMapOutside.idea(fromPasted: " \n ") == nil)
    }

    // MARK: The first sentence of an answer

    @Test("An answer's title is its first sentence in plain words")
    func firstSentence() {
        #expect(KnowledgeMapOutside.firstSentence(of: "PINK1 builds up on damaged mitochondria. Parkin then joins it.") == "PINK1 builds up on damaged mitochondria.")
        #expect(KnowledgeMapOutside.firstSentence(of: "## Mitophagy\n\nPINK1 marks the organelle.") == "Mitophagy")
        #expect(KnowledgeMapOutside.firstSentence(of: "**PINK1** is a [kinase](foreverlm://source/x). It acts early.") == "PINK1 is a kinase.")
        #expect(KnowledgeMapOutside.firstSentence(of: "- first point here\n- second") == "first point here")
        #expect(KnowledgeMapOutside.firstSentence(of: "1. Step one. Then two.") == "Step one.")
        #expect(KnowledgeMapOutside.firstSentence(of: "> A quoted line? Yes.") == "A quoted line?")
        #expect(KnowledgeMapOutside.firstSentence(of: "```\ncode\n```\nThe answer is 3.5 mM, e.g. in cells. Done.") == "code")
        #expect(KnowledgeMapOutside.firstSentence(of: "It rose to 3.5 mM, e.g. in cells. Done.") == "It rose to 3.5 mM, e.g. in cells.")
        #expect(KnowledgeMapOutside.firstSentence(of: "See Fig. 2 for the blot. Then more.") == "See Fig. 2 for the blot.")
        #expect(KnowledgeMapOutside.firstSentence(of: "![a chart](foreverlm://image/x)\n\nThe trend is up.") == "The trend is up.")
        #expect(KnowledgeMapOutside.firstSentence(of: "A claim [1] with a mark.") == "A claim with a mark.")
        #expect(KnowledgeMapOutside.firstSentence(of: "---\n\n") == "")
        #expect(KnowledgeMapOutside.firstSentence(of: "   ") == "")
    }

    @Test("A long first sentence is cut at a word to at most 120 characters and a mark")
    func firstSentenceIsCut() {
        let long = (1...60).map { "word\($0)" }.joined(separator: " ")
        let title = KnowledgeMapOutside.firstSentence(of: long)
        #expect(title.hasSuffix("…"))
        #expect(title.count <= KnowledgeMapOutside.titleLimit + 1)
        #expect(!title.dropLast().hasSuffix(" "))
        #expect(long.hasPrefix(String(title.dropLast())))
        let one = String(repeating: "x", count: 200)
        #expect(KnowledgeMapOutside.firstSentence(of: one) == String(repeating: "x", count: 120) + "…")
    }

    // MARK: Where cards go on another canvas

    @Test("A card added to an empty canvas goes to the origin; the next lands beside it, not on it")
    func arrivalOnAnEmptyCanvas() throws {
        var layout = KnowledgeMapLayout()
        let first = KnowledgeMapOutside.arrival(of: ["source:a"], on: layout, height: height)
        #expect(first.count == 1)
        #expect(first[0].x == 0 && first[0].y == 0)
        layout.place("source:a", x: first[0].x, y: first[0].y, at: 1)
        let second = KnowledgeMapOutside.arrival(of: ["source:b"], on: layout, height: height)
        #expect(second[0].x >= KnowledgeMap.cardWidth)
        #expect(second[0].y == 0)
    }

    @Test("Cards arrive right of what the canvas holds, level with its top, clear of every card and region")
    func arrivalClearsWhatIsThere() throws {
        var layout = KnowledgeMapLayout()
        layout.place("source:a", x: 100, y: 200, at: 1)
        layout.place("source:b", x: 400, y: 500, at: 1)
        layout.setRegion("r1", .init(name: "R", x: 50, y: 100, w: 900, h: 600, color: "blue", at: 1))
        let spots = KnowledgeMapOutside.arrival(of: ["idea:x", "idea:y", "idea:z"], on: layout, height: height)
        #expect(spots.count == 3)
        let taken = KnowledgeMapOutside.occupied(in: layout, height: height)
        for spot in spots {
            let card = KnowledgeMapArranging.Rect(x: spot.x, y: spot.y, w: KnowledgeMap.cardWidth, h: KnowledgeMap.cardHeight)
            #expect(!taken.contains { $0.intersects(card) })
            #expect(spot.x >= 950)
        }
        // Not on one another.
        for (i, a) in spots.enumerated() {
            for b in spots[(i + 1)...] {
                let ra = KnowledgeMapArranging.Rect(x: a.x, y: a.y, w: 240, h: 120)
                let rb = KnowledgeMapArranging.Rect(x: b.x, y: b.y, w: 240, h: 120)
                #expect(!ra.intersects(rb))
            }
        }
    }

    @Test("A card already on the canvas is left where it is; one named twice is placed once")
    func arrivalSkipsWhatIsPlaced() {
        var layout = KnowledgeMapLayout()
        layout.place("source:a", x: 0, y: 0, at: 1)
        #expect(KnowledgeMapOutside.arrival(of: ["source:a"], on: layout, height: height).isEmpty)
        let twice = KnowledgeMapOutside.arrival(of: ["source:b", "source:b", "source:a"], on: layout, height: height)
        #expect(twice.map(\.ref) == ["source:b"])
    }

    @Test("With a centre given, the card lands as near it as is free")
    func arrivalNearACentre() {
        let layout = KnowledgeMapLayout()
        let spots = KnowledgeMapOutside.arrival(of: ["idea:a"], on: layout, height: height, near: .init(x: 1000, y: 800))
        #expect(spots[0].x == 880 && spots[0].y == 740)
    }

    // MARK: Moving a selection to another canvas

    private func layoutWithRegionAndArrows() -> KnowledgeMapLayout {
        var layout = KnowledgeMapLayout()
        layout.place("source:a", x: 100, y: 100, at: 1)
        layout.place("source:b", x: 400, y: 100, at: 1)
        layout.place("source:c", x: 100, y: 400, at: 1)
        layout.place("idea:far", x: 3000, y: 3000, at: 1)
        // Fully inside the bounds of a, b and c (100..640 by 100..520).
        layout.setRegion("inner", .init(name: "Inner", x: 150, y: 240, w: 200, h: 100, color: "green", at: 1))
        // Not inside them.
        layout.setRegion("outer", .init(name: "Outer", x: 0, y: 0, w: 900, h: 700, color: "blue", at: 1))
        layout.setEdge("e1", .init(from: "source:a", to: "source:b", label: "binds", at: 1))
        layout.setEdge("e2", .init(from: "source:b", to: "idea:far", label: "far", at: 1))
        layout.setEdge("e3", .init(from: "source:a", to: "region:inner", label: "", at: 1))
        return layout
    }

    @Test("A move takes the placed cards, the regions fully inside their bounds, and the arrows between what moves")
    func movingPlan() {
        let source = layoutWithRegionAndArrows()
        let moved = KnowledgeMapOutside.moving(["source:a", "source:b", "source:c", "source:not-placed"], from: source, height: height)
        #expect(moved.refs == ["source:a", "source:b", "source:c"])
        #expect(moved.regionIDs == ["inner"])
        #expect(moved.edgeIDs == ["e1", "e3"])
        #expect(KnowledgeMapOutside.moving(["nothing"], from: source, height: height).isEmpty)
        #expect(KnowledgeMapOutside.moving([], from: source, height: height).isEmpty)
    }

    @Test("Regions nested in a region that moves move with it")
    func movingNestedRegions() {
        var source = layoutWithRegionAndArrows()
        source.setRegion("inner-2", .init(name: "Nested", x: 160, y: 250, w: 100, h: 60, color: "red", at: 1))
        let moved = KnowledgeMapOutside.moving(["source:a", "source:b", "source:c"], from: source, height: height)
        #expect(moved.regionIDs == ["inner", "inner-2"])
    }

    @Test("A move keeps relative positions at a free spot, writes everything newer, and leaves the source alone")
    func movingWrites() {
        let source = layoutWithRegionAndArrows()
        let moved = KnowledgeMapOutside.moving(["source:a", "source:b", "source:c"], from: source, height: height)
        var destination = KnowledgeMapLayout()
        destination.place("source:z", x: 0, y: 0, at: 5)
        let written = KnowledgeMapOutside.write(moved, from: source, into: &destination, height: height, at: 50)
        #expect(written == ["source:a", "source:b", "source:c"])
        let a = destination.placements["source:a"]!, b = destination.placements["source:b"]!, c = destination.placements["source:c"]!
        // Relative positions kept.
        #expect(b.x - a.x == 300 && b.y == a.y)
        #expect(c.x == a.x && c.y - a.y == 300)
        #expect(a.at == 50 && b.at == 50 && c.at == 50)
        // Clear of the card already there, to its right.
        #expect(a.x >= KnowledgeMap.cardWidth)
        let inner = destination.regions["inner"]!
        #expect(inner.x - a.x == 50 && inner.y - a.y == 140 && inner.at == 50)
        #expect(destination.edges["e1"]?.label == "binds" && destination.edges["e1"]?.at == 50)
        #expect(destination.edges["e3"]?.to == "region:inner")
        #expect(destination.edges["e2"] == nil)
        #expect(destination.regions["outer"] == nil && destination.placements["idea:far"] == nil)
        // The source is untouched by the write.
        #expect(source == layoutWithRegionAndArrows())
    }

    @Test("Moved onto an empty canvas, everything keeps its own coordinates")
    func movingToAnEmptyCanvas() {
        let source = layoutWithRegionAndArrows()
        let moved = KnowledgeMapOutside.moving(["source:a", "source:b"], from: source, height: height)
        var destination = KnowledgeMapLayout()
        KnowledgeMapOutside.write(moved, from: source, into: &destination, height: height, at: 9)
        #expect(destination.placements["source:a"]?.x == 100 && destination.placements["source:a"]?.y == 100)
        #expect(destination.placements["source:b"]?.x == 400)
    }

    @Test("A card the destination holds already stays where it is there, and an arrow already drawn is not drawn twice")
    func movingOntoWhatIsThere() {
        let source = layoutWithRegionAndArrows()
        let moved = KnowledgeMapOutside.moving(["source:a", "source:b"], from: source, height: height)
        var destination = KnowledgeMapLayout()
        destination.place("source:a", x: 7, y: 8, at: 5)
        destination.place("source:b", x: 700, y: 8, at: 5)
        destination.setEdge("mine", .init(from: "source:a", to: "source:b", label: "own", at: 5))
        KnowledgeMapOutside.write(moved, from: source, into: &destination, height: height, at: 50)
        #expect(destination.placements["source:a"]?.x == 7 && destination.placements["source:a"]?.at == 5)
        #expect(destination.edges.count == 1 && destination.edges["mine"]?.label == "own")
    }

    @Test("A moved card that was taken off the destination before is placed again")
    func movingClearsTheTombstone() {
        let source = layoutWithRegionAndArrows()
        var destination = KnowledgeMapLayout()
        destination.place("source:a", x: 1, y: 1, at: 5)
        destination.unplace("source:a", at: 6)
        let moved = KnowledgeMapOutside.moving(["source:a"], from: source, height: height)
        KnowledgeMapOutside.write(moved, from: source, into: &destination, height: height, at: 50)
        #expect(destination.placements["source:a"] != nil)
        #expect(destination.removed["p:source:a"] == nil)
    }

    @Test("Which canvases hold a card")
    func canvasesHolding() {
        var one = KnowledgeMapLayout(), two = KnowledgeMapLayout()
        one.place("source:a", x: 0, y: 0, at: 1)
        two.place("source:b", x: 0, y: 0, at: 1)
        two.place("source:a", x: 0, y: 0, at: 1)
        let layouts = ["cnv-2": two, "cnv-1": one, "cnv-3": KnowledgeMapLayout()]
        #expect(KnowledgeMapOutside.canvasIDs(holding: "source:a", in: layouts) == ["cnv-1", "cnv-2"])
        #expect(KnowledgeMapOutside.canvasIDs(holding: "source:b", in: layouts) == ["cnv-2"])
        #expect(KnowledgeMapOutside.canvasIDs(holding: "idea:q", in: layouts).isEmpty)
    }

    @Test("A drop with nothing in it is empty")
    func emptyDrop() {
        #expect(KnowledgeMapOutsideDrop().isEmpty)
        #expect(!KnowledgeMapOutsideDrop(text: "words").isEmpty)
        #expect(!KnowledgeMapOutsideDrop(chatIDs: ["s1"]).isEmpty)
        #expect(KnowledgeMapOutsideDrop(text: "").isEmpty)
    }
}

@Suite("Canvas from outside: a drop or a paste")
struct KnowledgeMapOutsideDropTests {
    private let importable: (String) -> String? = { $0.hasPrefix("https://") ? $0 : nil }

    @Test("Pasted text fills the field it is: addresses, cards or words")
    func addingPastedText() {
        var links = KnowledgeMapOutsideDrop()
        links.add(pastedText: "https://a.com/x", schemes: ["foreverlm"], importableLink: importable)
        #expect(links.links == ["https://a.com/x"] && links.cardRefs.isEmpty && links.text == nil)
        var cards = KnowledgeMapOutsideDrop()
        cards.add(pastedText: "foreverlm://idea/i1 foreverlm://notebook/n1", schemes: ["foreverlm"], importableLink: importable)
        #expect(cards.cardRefs == ["idea:i1", "notebook:n1"])
        var words = KnowledgeMapOutsideDrop()
        words.add(pastedText: "a few words", schemes: ["foreverlm"], importableLink: importable)
        #expect(words.text == "a few words" && words.links.isEmpty)
        var nothing = KnowledgeMapOutsideDrop()
        nothing.add(pastedText: "  ", schemes: ["foreverlm"], importableLink: importable)
        #expect(nothing.isEmpty)
    }

    @Test("A notebook named by a pasted address is taken out of the cards")
    func takingNotebooks() {
        var drop = KnowledgeMapOutsideDrop(cardRefs: ["source:s1", "notebook:n1", "notebook:n2"])
        #expect(drop.takeNotebookIDs() == ["n1", "n2"])
        #expect(drop.cardRefs == ["source:s1"])
    }
}

@Suite("Canvas from outside: the answer's menu")
struct KnowledgeMapOutsideAnswerMenuTests {
    @Test("A reply's ⋯ offers Add to Canvas after Save to Note, only when the Canvas is offered, and a topic card never")
    func addToCanvasInTheReplyMenu() {
        let offered = ReviewChatReplyMenu.items(
            timeLine: nil, savedDocID: .some(nil), offersAddToCanvas: true,
            offersDiscussInNewChat: false, offersMoreDetails: false, asideActionsOnly: false
        )
        #expect(offered == [.saveToNote, .addToCanvas, .branch])
        let withheld = ReviewChatReplyMenu.items(
            timeLine: nil, savedDocID: .some(nil),
            offersDiscussInNewChat: false, offersMoreDetails: false, asideActionsOnly: false
        )
        #expect(withheld == [.saveToNote, .branch])
        let topicCard = ReviewChatReplyMenu.items(
            timeLine: nil, savedDocID: nil, offersAddToCanvas: true,
            offersDiscussInNewChat: false, offersMoreDetails: true, asideActionsOnly: true
        )
        #expect(topicCard == [.moreDetails])
        #expect(ReviewChatReplyMenu.Item.addToCanvas.title == "Add to Canvas")
    }
}
