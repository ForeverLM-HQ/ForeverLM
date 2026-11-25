import Foundation
import Testing
@testable import ForeverLM

// What Sapience showed (docs/knowledge-map-design.md, "What Sapience showed
// (2026-10-10): the contract"): the sizes and stored fields, the style rules, the
// default page face, the model API, a mind map's nodes, the MCP fields and the
// Markdown lines.

@Suite("Canvas: the sizes the Mac and the page share")
struct KnowledgeMapSapienceSizeTests {
    @Test("A page face is the page at the card's width, within half and two and seven tenths of it, over a foot of 70")
    func pageFaceHeight() {
        #expect(KnowledgeMap.pageFaceFootHeight == 70)
        #expect(KnowledgeMap.pageFaceHeight(aspect: nil, width: 240) == 381, "US Letter until the PDF is read: 240 / 0.7727, rounded, and the foot")
        #expect(KnowledgeMap.pageFaceHeight(aspect: 1, width: 240) == 310)
        #expect(KnowledgeMap.pageFaceHeight(aspect: 3, width: 240) == 190, "a wide page is held to half the width")
        #expect(KnowledgeMap.pageFaceHeight(aspect: 0.2, width: 240) == 718, "a tall one to two and seven tenths of it")
        #expect(KnowledgeMap.pageFaceHeight(aspect: 0, width: 240) == 381 && KnowledgeMap.pageFaceHeight(aspect: -2, width: 240) == 381, "no shape is a Letter")
        #expect(KnowledgeMap.pageFaceHeight(aspect: 0.75, width: 360) == 480 + 70)
    }

    @Test("An annotation's room: nothing for no words, a line per paragraph at least, a line for each 6.5 points of a character across the card less 28, at most 12 lines")
    func annotationHeight() {
        #expect(KnowledgeMap.annotationHeight(nil, width: 240) == 0 && KnowledgeMap.annotationHeight("", width: 240) == 0)
        #expect(KnowledgeMap.annotationHeight("Why it matters.", width: 240) == 10 + 16)
        #expect(KnowledgeMap.annotationHeight("a\nb", width: 240) == 10 + 2 * 16)
        #expect(KnowledgeMap.annotationHeight("a\n\nb", width: 240) == 10 + 3 * 16, "a blank line is a line")
        #expect(KnowledgeMap.annotationHeight(String(repeating: "x", count: 100), width: 160) == 10 + 5 * 16, "650 points across 132")
        #expect(KnowledgeMap.annotationHeight(String(repeating: "x", count: 33), width: 240) == 10 + 2 * 16, "214.5 points do not fit 212")
        #expect(KnowledgeMap.annotationHeight(String(repeating: "x", count: 32), width: 240) == 10 + 1 * 16)
        #expect(KnowledgeMap.annotationHeight(String(repeating: "x", count: 600), width: 240) == 10 + 12 * 16, "twelve lines at most")
        #expect(KnowledgeMap.annotationHeight("a\r\nb", width: 240) == 10 + 2 * 16, "a Windows line end is one break")
    }

    @Test("A mind-map node is as large as its words: 7 points a character (a root's 8.6), padded, within a width, at most four lines")
    func treeNodeSize() {
        func size(_ title: String, _ role: KnowledgeMapTreeNodeRole) -> [Double] {
            let size = KnowledgeMap.treeNodeSize(title: title, role: role)
            return [size.w, size.h]
        }
        #expect(size("ATP", .leaf) == [60, 31], "held to the least width, one line: 2 x 7 and 17")
        #expect(size("ATP", .branch) == size("ATP", .leaf), "a branch is measured as a leaf")
        #expect(size(String(repeating: "x", count: 60), .leaf) == [220, 14 + 3 * 17], "420 points of words across 196")
        #expect(size(String(repeating: "x", count: 200), .leaf) == [220, 14 + 4 * 17], "four lines at most")
        #expect(size("Why do we age?", .root) == [156, 24 + 21], "120.4 points of words fill one line, not a hair over it")
        #expect(size(String(repeating: "x", count: 28), .root) == [277, 24 + 21])
        #expect(size("", .root) == [120, 45], "an empty title is the least")
        #expect(size(String(repeating: "x", count: 100), .root) == [280, 24 + 4 * 21])
    }

    @Test("A question is a title that ends with ? or ？")
    func isQuestion() {
        #expect(KnowledgeMap.isQuestion("Does it spread?") && KnowledgeMap.isQuestion("Does it spread？ \n"))
        #expect(!KnowledgeMap.isQuestion("It spreads") && !KnowledgeMap.isQuestion("") && !KnowledgeMap.isQuestion("What? Maybe"))
    }

    @Test("Words are kept as a placement stores them: trimmed, at most 600 characters, nothing for nothing")
    func annotationFromText() {
        #expect(KnowledgeMap.annotation(from: "  why \n") == "why")
        #expect(KnowledgeMap.annotation(from: " \n ") == nil && KnowledgeMap.annotation(from: "") == nil)
        #expect(KnowledgeMap.annotation(from: String(repeating: "x", count: 700))?.count == 600)
        #expect(KnowledgeMap.annotation(from: String(repeating: "x", count: 599) + " yy")?.count == 599, "the cut leaves no trailing space")
    }
}

@Suite("Canvas: the stored fields and the style rules")
struct KnowledgeMapSapienceFieldTests {
    private static let oldRow = ##"{"edges":{"e1":{"at":4,"from":"source:a","label":"x","to":"source:b"}},"placements":{"idea:b":{"at":3,"x":300,"y":2},"source:a":{"at":3,"x":1,"y":2}},"regions":{},"removed":{},"version":1}"##

    @Test("A row from before reads with every new field empty and writes none of them back")
    func oldRowsRoundTrip() throws {
        let row = try #require(KnowledgeMapLayout(preferenceValue: Self.oldRow))
        let source = try #require(row.placements["source:a"])
        #expect(source.page == nil && source.annotation == nil && source.plain == nil && source.answered == nil)
        #expect(!source.isPlain && !source.isAnswered)
        #expect(row.edges["e1"]?.stance == nil && row.edges["e1"]?.knownStance == nil)
        #expect(row.preferenceValue == Self.oldRow)
    }

    @Test("The new fields round-trip, and a stance this build does not know is kept and not drawn")
    func newFieldsRoundTrip() throws {
        let row = ##"{"edges":{"e1":{"at":4,"from":"source:a","label":"x","stance":"supports","to":"idea:b"},"e2":{"at":4,"from":"idea:b","label":"","stance":"refutes","to":"source:a"}},"placements":{"idea:b":{"answered":true,"at":3,"plain":true,"x":300,"y":2},"source:a":{"annotation":"Why it is here","at":3,"page":3,"x":1,"y":2}},"regions":{},"removed":{},"version":1}"##
        let decoded = try #require(KnowledgeMapLayout(preferenceValue: row))
        #expect(decoded.placements["source:a"]?.page == 3 && decoded.placements["source:a"]?.annotation == "Why it is here")
        #expect(decoded.placements["idea:b"]?.isPlain == true && decoded.placements["idea:b"]?.isAnswered == true)
        #expect(decoded.edges["e1"]?.knownStance == .supports)
        #expect(decoded.edges["e2"]?.stance == "refutes" && decoded.edges["e2"]?.knownStance == nil)
        #expect(decoded.preferenceValue == row)
    }

    @Test("Each entry merges newer-wins as a whole, so the newer card keeps its words and page, or loses them with the rest")
    func mergeIsPerEntry() {
        var base = KnowledgeMapLayout()
        base.place("source:s", x: 0, y: 0, at: 1)
        base.setEdge("e", .init(from: "source:s", to: "source:s2", label: "", at: 1))
        var written = base
        var placement = written.placements["source:s"]!
        placement.page = 4; placement.annotation = "The cleanest measurement"; placement.at = 10
        written.setPlacement("source:s", placement)
        written.edges["e"]?.stance = "supports"; written.edges["e"]?.at = 10

        var movedLater = base
        movedLater.place("source:s", x: 9, y: 9, at: 20)
        let merged = written.merged(with: movedLater)
        #expect(merged == movedLater.merged(with: written), "whichever Mac merges first")
        #expect(merged.placements["source:s"]?.x == 9 && merged.placements["source:s"]?.annotation == nil, "the newer entry wins whole")
        #expect(merged.edges["e"]?.stance == "supports", "the arrow's own entry is its own")

        var movedEarlier = base
        movedEarlier.place("source:s", x: 9, y: 9, at: 5)
        let kept = written.merged(with: movedEarlier)
        #expect(kept.placements["source:s"]?.page == 4 && kept.placements["source:s"]?.annotation == "The cleanest measurement")
    }

    @Test("Style edits keep, clear or set the new fields, held to what each kind of card can carry")
    func styleRules() {
        let spot = KnowledgeMapLayout.Placement(x: 0, y: 0, at: 1)
        // A source: a page of at least 1, words trimmed and held to 600; no marks of an Idea's.
        let source = spot.styled(by: .init(ref: "source:s", page: .set(0), annotation: .set("  Why it is here \n"), plain: .set(true), answered: .set(true)))
        #expect(source.page == 1 && source.annotation == "Why it is here")
        #expect(source.plain == nil && source.answered == nil)
        let long = source.styled(by: .init(ref: "source:s", annotation: .set(String(repeating: "x", count: 900))))
        #expect(long.annotation?.count == 600)
        #expect(long.styled(by: .init(ref: "source:s", page: .clear, annotation: .set("   "))).page == nil)
        #expect(long.styled(by: .init(ref: "source:s", annotation: .set("   "))).annotation == nil, "empty words are nothing")
        #expect(long.styled(by: .init(ref: "source:s", annotation: .clear)).annotation == nil)
        #expect(long.styled(by: .init(ref: "source:s", w: .set(300))).annotation == long.annotation, "a field left out is left")

        // An Idea: its own note holds its words and it has no page; it may be plain and, as a question, answered.
        let idea = spot.styled(by: .init(ref: "idea:i", page: .set(3), annotation: .set("words"), plain: .set(true), answered: .set(true)))
        #expect(idea.page == nil && idea.annotation == nil)
        #expect(idea.plain == true && idea.answered == true)
        let notes = idea.styled(by: .init(ref: "idea:i", plain: .set(false), answered: .clear))
        #expect(notes.plain == nil && notes.answered == nil, "false is stored as nothing")

        // Any other card takes words and no page.
        for ref in ["doc:d", "clip:c", "page:s:3", "canvas:cnv-x", "chat:c", "picture:p"] {
            let card = spot.styled(by: .init(ref: ref, page: .set(2), annotation: .set("why"), plain: .set(true)))
            #expect(card.annotation == "why" && card.page == nil && card.plain == nil, "\(ref)")
        }
        #expect(KnowledgeMapPlacementStyle(ref: "source:s").isKeep)
        for change in [
            KnowledgeMapPlacementStyle(ref: "x", page: .set(1)), .init(ref: "x", annotation: .clear),
            .init(ref: "x", plain: .set(true)), .init(ref: "x", answered: .set(true)),
        ] {
            #expect(!change.isKeep)
        }
    }

    @Test("A style for cards set down names the four fields too, and page 0 asks for the usual card")
    func cardStyle() {
        var style = KnowledgeMapCardStyle()
        #expect(style.isEmpty)
        style.page = 0
        #expect(!style.isEmpty && style.edit(for: "source:s").page == .clear)
        style.page = 5
        style.annotation = "why"; style.plain = true; style.answered = false
        let edit = style.edit(for: "idea:i")
        #expect(edit.page == .set(5) && edit.annotation == .set("why") && edit.plain == .set(true) && edit.answered == .set(false))
        #expect(edit.w == .keep && edit.color == .keep)
    }

    @Test("A relation names a stance only when it is one")
    func relationStance() {
        #expect(KnowledgeMapEdgeStance(relation: "supports") == .supports && KnowledgeMapEdgeStance(relation: " Contradicts ") == .contradicts)
        #expect(KnowledgeMapEdgeStance(relation: "extends") == nil && KnowledgeMapEdgeStance(relation: nil) == nil)
    }

    @Test("A card the PDF was read for carries its page count, shape and a tick when read; a PDF not found, nothing")
    func nodeFields() throws {
        var read = StudioArticle(url: "https://example.com/r", title: "Read", sourceType: .paper, id: "r")
        read.readAt = Date()
        let unread = StudioArticle(url: "https://example.com/u", title: "Unread", sourceType: .paper, id: "u")
        let content = KnowledgeMapModel.content(
            articles: [read, unread], ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:],
            pageFaces: ["r": KnowledgeMapPageFace(pageCount: 12, aspect: 0.7), "u": KnowledgeMapPageFace(pageCount: 0, aspect: nil)]
        )
        let first = try #require(content.nodes.first { $0.ref == "source:r" })
        #expect(first.pages == 12 && first.aspect == 0.7 && first.read == true)
        let second = try #require(content.nodes.first { $0.ref == "source:u" })
        #expect(second.pages == nil && second.aspect == nil && second.read == nil)
        let sent = String(decoding: try JSONEncoder().encode(second), as: UTF8.self)
        #expect(!sent.contains("\"pages\"") && !sent.contains("\"aspect\"") && !sent.contains("\"read\""), "what is default is not sent")
        #expect(String(decoding: try JSONEncoder().encode(first), as: UTF8.self).contains("\"pages\":12"))
    }
}

@Suite("Canvas: papers as pages, words under cards, and a mind map's nodes (the model)")
@MainActor
struct KnowledgeMapSapienceModelTests {
    private func withModel(
        papers: [String] = ["p1", "p2", "p3", "p4"],
        ideas: [(id: String, title: String)] = [("i", "An idea"), ("q", "Does it spread?")],
        _ body: (KnowledgeMapModel) throws -> Void
    ) rethrows {
        let suite = UserDefaults(suiteName: "KnowledgeMapSapienceModelTests.\(UUID().uuidString)")!
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(
                articles: papers.map { StudioArticle(url: "https://example.com/\($0)", title: "Paper \($0)", sourceType: .paper, id: $0) },
                ideas: ideas.map { IdeaRecord(id: $0.id, title: $0.title) },
                notebooks: [], chats: [], artifacts: [], firstHighlights: [:]
            )
            try body(model)
        }
    }

    private func apart() { Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05) }

    // MARK: The default page face

    @Test("A paper placed for the first time shows its page; a card already placed, an Idea and a Doc do not change")
    func defaultPageFace() {
        withModel { model in
            model.pageFaceDefault = { $0.hasPrefix("p") }
            model.place([(ref: "source:p1", x: 0, y: 0), (ref: "idea:i", x: 300, y: 0), (ref: "doc:d", x: 600, y: 0), (ref: "source:other", x: 900, y: 0)])
            #expect(model.layout.placements["source:p1"]?.page == 1)
            #expect(model.layout.placements["idea:i"]?.page == nil && model.layout.placements["doc:d"]?.page == nil)
            #expect(model.layout.placements["source:other"]?.page == nil, "the hook says no")
            apart()
            #expect(model.setCardPage(["source:p1"], nil) == 1, "Show as Card")
            apart()
            model.place([(ref: "source:p1", x: 50, y: 50)])
            #expect(model.layout.placements["source:p1"]?.page == nil, "a card already placed keeps its face")
            apart()
            model.unplace(["source:p1"])
            apart()
            model.place([(ref: "source:p1", x: 50, y: 50)])
            #expect(model.layout.placements["source:p1"]?.page == 1, "taken off and placed again it is new")
            apart()
            #expect(model.setCardPage(["source:other"], 1) == 1, "Show Page")
            #expect(model.layout.placements["source:other"]?.page == 1)
        }
    }

    @Test("Undo, Redo, Restore and the app's own writes never add a page, and without the hook nothing is given one")
    func defaultNeverOnUndoRedoRestoreOrOwnWrites() {
        withModel { model in
            model.place([(ref: "source:p1", x: 0, y: 0)])
            #expect(model.layout.placements["source:p1"]?.page == nil, "no hook, no page")
            model.pageFaceDefault = { _ in true }
            apart()
            model.unplace(["source:p1"])
            apart()
            model.undo()
            #expect(model.layout.placements["source:p1"] != nil && model.layout.placements["source:p1"]?.page == nil, "Undo brings it back as it was")
            model.undo()
            model.redo()
            #expect(model.layout.placements["source:p1"]?.page == nil, "and Redo")
            model.undo()
            model.redo()
            model.redo()
            #expect(model.layout.placements["source:p1"] == nil)

            model.updateLayout(undoable: false) { layout, at in layout.place("source:p2", x: 0, y: 0, at: at) }
            #expect(model.layout.placements["source:p2"]?.page == nil, "the app's own write")

            var snapshot = KnowledgeMapLayout()
            snapshot.place("source:p3", x: 0, y: 0, at: 1)
            #expect(model.restoreLayoutSnapshot(snapshot))
            #expect(model.layout.placements["source:p3"] != nil && model.layout.placements["source:p3"]?.page == nil, "Restore")

            apart()
            model.place([(ref: "source:p4", x: 400, y: 0)])
            #expect(model.layout.placements["source:p4"]?.page == 1, "the learner's own write still does")
            apart()
            model.undo()
            #expect(model.layout.placements["source:p4"] == nil, "which one Undo takes back, page and all")
        }
    }

    @Test("A write that asks for the usual card, or another page, is not given the default, and the cells are laid out for the page")
    func defaultOptOutAndCells() {
        withModel { model in
            model.pageFaceDefault = { _ in true }
            model.saveRegion(id: "r", name: "Papers", x: 0, y: 0, w: 1200, h: 300, color: "#7F77DD")
            apart()
            model.place(["source:p1"], inRegion: "r", style: KnowledgeMapCardStyle(page: 0))
            #expect(model.layout.placements["source:p1"]?.page == nil, "face card")
            apart()
            model.place(["source:p2"], inRegion: "r", style: KnowledgeMapCardStyle(page: 3))
            #expect(model.layout.placements["source:p2"]?.page == 3)

            apart()
            _ = model.placeBlock(["source:p3", "source:p4", "idea:i", "idea:q"], near: .init(x: 5000, y: 5000))
            let top = ["source:p3", "source:p4", "idea:i"].compactMap { model.layout.placements[$0]?.y }
            let low = model.layout.placements["idea:q"]?.y ?? 0
            // A block of four is three across and two down; the first row is as tall as its tallest, the page.
            #expect(top.count == 3 && Set(top).count == 1)
            #expect(low - top[0] == KnowledgeMap.pageFaceHeight(aspect: nil, width: 240) + KnowledgeMapArranging.gap, "set down for a page's height")
            #expect(model.layout.placements["source:p3"]?.page == 1 && model.layout.placements["idea:i"]?.page == nil)
        }
    }

    // MARK: The model API

    @Test("A page turns within the PDF once this Mac knows how long it is, and a card that is not a page face does not turn")
    func pages() {
        withModel { model in
            model.place([(ref: "source:p1", x: 0, y: 0), (ref: "idea:i", x: 300, y: 0)])
            apart()
            #expect(!model.turnCardPage("source:p1", by: 1), "not a page face yet")
            #expect(model.setCardPage(["source:p1", "idea:i", "source:ghost"], 9) == 1, "a source that is placed, only")
            #expect(model.layout.placements["source:p1"]?.page == 9, "the PDF's length is not known yet")
            model.pageFaces["p1"] = KnowledgeMapPageFace(pageCount: 5, aspect: 0.75)
            apart()
            #expect(model.setCardPage(["source:p1"], 12) == 1)
            #expect(model.layout.placements["source:p1"]?.page == 5, "a page past the end is the last")
            #expect(!model.turnCardPage("source:p1", by: 1))
            apart()
            #expect(model.turnCardPage("source:p1", by: -2) && model.layout.placements["source:p1"]?.page == 3)
            apart()
            #expect(model.turnCardPage("source:p1", by: -9) && model.layout.placements["source:p1"]?.page == 1)
            #expect(!model.turnCardPage("source:p1", by: -1), "already at the first")
            #expect(!model.turnCardPage("idea:i", by: 1))
            apart()
            model.undo()
            #expect(model.layout.placements["source:p1"]?.page == 3, "a turn is one step")
        }
    }

    @Test("A card is as tall as its page, its words, its own height and its fold say, and a page the PDF has not been read for is the usual card")
    func heights() {
        withModel { model in
            model.place([(ref: "source:p1", x: 0, y: 0), (ref: "source:p2", x: 400, y: 0)])
            apart()
            model.setCardPage(["source:p1", "source:p2"], 3)
            #expect(model.cardHeight(of: "source:p1") == KnowledgeMap.cardHeight, "the PDF is not read: the usual card")
            model.pageFaces["p1"] = KnowledgeMapPageFace(pageCount: 12, aspect: 0.75)
            model.pageFaces["p2"] = KnowledgeMapPageFace(pageCount: 0, aspect: nil)
            #expect(model.cardHeight(of: "source:p1") == 390 && model.cardHeight(of: "source:p2") == KnowledgeMap.cardHeight)
            apart()
            #expect(model.setCardAnnotation("source:p1", "  Why it is here.  "))
            #expect(model.layout.placements["source:p1"]?.annotation == "Why it is here.")
            #expect(model.cardHeight(of: "source:p1") == 390 + 26 && model.naturalCardHeight(of: "source:p1") == 416)
            apart()
            #expect(model.setCardSize("source:p1", w: 360, h: nil))
            #expect(model.cardWidth(of: "source:p1") == 360)
            #expect(model.cardHeight(of: "source:p1") == KnowledgeMap.pageFaceHeight(aspect: 0.75, width: 360) + 26)
            apart()
            #expect(model.setCardSize("source:p1", w: nil, h: 200))
            #expect(model.cardHeight(of: "source:p1") == 200, "the learner's own height holds the words too")
            apart()
            model.setCardFolded(["source:p1"], true)
            #expect(model.cardHeight(of: "source:p1") == KnowledgeMap.foldedCardHeight)
        }
    }

    @Test("Words go under any card but an Idea, one Undo step with the region that grows to hold the taller card; an empty text takes them off")
    func annotations() {
        withModel { model in
            model.saveRegion(id: "r", name: "R", x: 0, y: 0, w: 500, h: 300, color: "#7F77DD")
            model.place([(ref: "source:p1", x: 100, y: 100), (ref: "idea:i", x: 300, y: 100), (ref: "source:ghost", x: 10, y: 10)])
            apart()
            #expect(!model.setCardAnnotation("idea:i", "words"), "an Idea's own note holds its words")
            #expect(!model.setCardAnnotation("source:p2", "words"), "not placed")
            #expect(!model.setCardAnnotation("source:p1", nil), "none to take off")
            #expect(model.setCardAnnotation("source:p1", String(repeating: "x", count: 600)))
            #expect(model.layout.placements["source:p1"]?.annotation?.count == 600)
            // 120 and the room for twelve lines: 100 + 322 and 24 more.
            #expect(model.cardHeight(of: "source:p1") == 120 + 202)
            #expect(model.layout.regions["r"]?.h == Double(100 + 322 + 24), "the region grew to hold the card")
            model.undo()
            #expect(model.layout.placements["source:p1"]?.annotation == nil && model.layout.regions["r"]?.h == 300, "words and region are one step")
            model.redo()
            apart()
            #expect(model.setCardAnnotation("source:p1", "  "))
            #expect(model.layout.placements["source:p1"]?.annotation == nil)
        }
    }

    @Test("An Idea may be plain words, and a question may be answered: only Ideas, only questions, one step each, off stored as nothing")
    func plainAndAnswered() {
        withModel { model in
            model.place([(ref: "idea:i", x: 0, y: 0), (ref: "idea:q", x: 300, y: 0), (ref: "source:p1", x: 600, y: 0)])
            apart()
            #expect(model.setCardPlain(["idea:i", "idea:q", "source:p1", "idea:ghost"], true) == 2)
            #expect(model.layout.placements["idea:i"]?.plain == true && model.layout.placements["source:p1"]?.plain == nil)
            apart()
            #expect(model.setCardPlain(["idea:i"], true) == 0, "already so")
            #expect(model.setCardPlain(["idea:i"], false) == 1)
            #expect(model.layout.placements["idea:i"]?.plain == nil, "false is nothing")
            apart()
            #expect(model.setCardAnswered(["idea:i", "idea:q", "source:p1"], true) == 1, "only the question")
            #expect(model.layout.placements["idea:q"]?.answered == true && model.layout.placements["idea:i"]?.answered == nil)
            apart()
            model.undo()
            #expect(model.layout.placements["idea:q"]?.answered == nil)
            model.redo()
            #expect(model.layout.placements["idea:q"]?.answered == true, "Redo carries the mark")
            apart()
            #expect(model.setCardAnswered(["idea:q"], false) == 1 && model.layout.placements["idea:q"]?.answered == nil)
        }
    }

    @Test("An arrow's stance is one of two, kept off by an empty string, drawn with the arrow, and one Undo step")
    func stance() {
        withModel { model in
            model.place([(ref: "idea:i", x: 0, y: 0), (ref: "idea:q", x: 400, y: 0)])
            apart()
            let made = model.addEdge(from: "idea:i", to: "idea:q", label: "claims", stance: "contradicts")
            guard let id = made else {
                Issue.record("The arrow was not drawn")
                return
            }
            #expect(model.layout.edges[id]?.knownStance == .contradicts)
            #expect(model.addEdge(from: "idea:q", to: "idea:i", label: "", stance: "maybe") == nil, "not a stance")
            apart()
            #expect(model.setEdgeStance(id, nil) && model.layout.edges[id]?.stance == nil)
            apart()
            #expect(model.setEdgeStance(id, .supports) && model.layout.edges[id]?.stance == "supports")
            #expect(!model.setEdgeStance(id, .supports), "no change")
            #expect(!model.updateEdgeStyle(id, stance: "refutes"), "not a stance")
            #expect(!model.setEdgeStance("nope", .supports))
            apart()
            #expect(model.updateEdgeStyle(id, color: "#378ADD") && model.layout.edges[id]?.stance == "supports", "a colour leaves the stance")
            apart()
            model.undo()
            #expect(model.layout.edges[id]?.stance == "supports" && model.layout.edges[id]?.color == nil)
            model.undo()
            #expect(model.layout.edges[id]?.stance == nil, "the stance is taken back by Undo")
        }
    }

    // MARK: A mind map's nodes

    private func mindMap(_ model: KnowledgeMapModel) {
        model.saveRegion(id: "t", name: "Mind map", x: 0, y: 0, w: 1000, h: 600, color: "#7F77DD")
        model.updateLayout(undoable: false) { layout, at in
            var region = layout.regions["t"]!
            region.layout = KnowledgeMapLayout.treeLayout
            region.at = at
            layout.setRegion("t", region)
        }
        model.place([(ref: "idea:i", x: 100, y: 100), (ref: "idea:q", x: 400, y: 100), (ref: "idea:leaf", x: 400, y: 300)])
        _ = model.addEdge(from: "idea:i", to: "idea:q", label: "", tree: true)
        _ = model.addEdge(from: "idea:q", to: "idea:leaf", label: "", tree: true)
    }

    @Test("A node is an Idea of no size of its own whose stored spot, at a usual card's middle, is in a tree region: root, branch or leaf by its branches")
    func nodeRoles() {
        withModel(ideas: [("i", "Why do we age?"), ("q", "Does it spread?"), ("leaf", "ATP"), ("lone", "Alone")]) { model in
            mindMap(model)
            #expect(model.isMindMapNode("idea:i") == .root)
            #expect(model.isMindMapNode("idea:q") == .branch)
            #expect(model.isMindMapNode("idea:leaf") == .leaf)
            #expect(model.isMindMapNode("idea:nope") == nil, "not placed")
            #expect(model.isMindMapNode("source:p1") == nil)

            // A card is held by the middle of a usual card at its spot: 120 and 60 from it.
            model.place([(ref: "idea:lone", x: 850, y: 100)])
            #expect(model.isMindMapNode("idea:lone") == .root, "its middle, at 970, is inside the region")
            model.place([(ref: "idea:lone", x: 900, y: 100)])
            #expect(model.isMindMapNode("idea:lone") == nil, "at 1020 it is outside, however narrow the node would be")
            model.place([(ref: "idea:lone", x: 100, y: 450)])
            #expect(model.isMindMapNode("idea:lone") == .root, "inside, with no branch to it")

            apart()
            model.setCardSize("idea:lone", w: 200, h: nil)
            #expect(model.isMindMapNode("idea:lone") == nil, "a size of its own makes it a card")
            apart()
            model.fitCardsToContent(["idea:lone"])
            model.setCardFolded(["idea:lone"], true)
            #expect(model.isMindMapNode("idea:lone") == nil, "and so does a fold")
            model.updateLayout(undoable: false) { layout, at in
                var region = layout.regions["t"]!
                region.layout = nil
                region.at = at
                layout.setRegion("t", region)
            }
            #expect(model.isMindMapNode("idea:i") == nil, "a free region has no nodes")
        }
    }

    @Test("A node is as wide and tall as its words; a card is what it was")
    func nodeSizes() {
        withModel(ideas: [("i", "Why do we age?"), ("q", "Does it spread?"), ("leaf", "ATP")]) { model in
            mindMap(model)
            let root = KnowledgeMap.treeNodeSize(title: "Why do we age?", role: .root)
            let branch = KnowledgeMap.treeNodeSize(title: "Does it spread?", role: .branch)
            let leaf = KnowledgeMap.treeNodeSize(title: "ATP", role: .leaf)
            #expect(model.cardWidth(of: "idea:i") == root.w && model.cardHeight(of: "idea:i") == root.h && root.h == 45)
            #expect(model.cardWidth(of: "idea:q") == branch.w && model.cardHeight(of: "idea:q") == branch.h)
            #expect(model.cardWidth(of: "idea:leaf") == leaf.w && model.cardHeight(of: "idea:leaf") == leaf.h)
            #expect(model.naturalCardHeight(of: "idea:leaf") == leaf.h)
            model.place([(ref: "source:p1", x: 100, y: 450)])
            #expect(model.cardWidth(of: "source:p1") == KnowledgeMap.cardWidth && model.cardHeight(of: "source:p1") == KnowledgeMap.cardHeight, "a source in a tree stays a card")
            apart()
            model.setCardSize("idea:leaf", w: 300, h: 90)
            #expect(model.cardWidth(of: "idea:leaf") == 300 && model.cardHeight(of: "idea:leaf") == 90)
        }
    }

    @Test("A mind map set down is laid out and framed by its nodes' sizes, from the Ideas the map holds or the titles it was given")
    func placeTreeByWords() throws {
        try withModel(ideas: [("r", "Why do we age?"), ("a", "Telomeres"), ("b", "Hi")]) { model in
            let made = try #require(model.placeTree(
                root: "idea:r", children: ["idea:r": ["idea:a", "idea:b"]], near: .init(x: 0, y: 0), regionName: "Ageing"
            ))
            let root = model.layout.placements["idea:r"]!, a = model.layout.placements["idea:a"]!, b = model.layout.placements["idea:b"]!
            #expect(model.isMindMapNode("idea:r") == .root && model.isMindMapNode("idea:a") == .leaf, "the region is a tree and the cards in it nodes")
            #expect(a.x == root.x + KnowledgeMap.treeNodeSize(title: "Why do we age?", role: .root).w + 60)
            #expect(b.x == a.x, "one column")
            #expect(b.y == a.y + KnowledgeMap.treeNodeSize(title: "Telomeres", role: .leaf).h + 24, "siblings 24 apart by their own heights")
            for ref in ["idea:r", "idea:a", "idea:b"] { #expect(model.regionID(containing: ref) == made.regionID, "\(ref) is held by its region") }
            let size = model.treeFrameSize(root: "idea:r", children: ["idea:r": ["idea:a", "idea:b"]])
            let region = try #require(model.layout.regions[made.regionID])
            #expect(region.w == size.w && region.h == size.h)
        }
        try withModel(papers: [], ideas: []) { model in
            // Ideas the map does not hold yet, named by the call that makes them.
            let titles = ["idea:x": "Why do we age?", "idea:y": "Telomeres"]
            _ = try #require(model.placeTree(root: "idea:x", children: ["idea:x": ["idea:y"]], near: .init(x: 0, y: 0), regionName: "Tree", titles: titles))
            #expect(model.layout.placements["idea:y"]!.x - model.layout.placements["idea:x"]!.x == 156 + 60)
            #expect(model.isMindMapNode("idea:y") == .leaf)
        }
        try withModel(papers: [], ideas: []) { model in
            // With no words known, a card is a card, as before.
            _ = try #require(model.placeTree(root: "idea:x", children: ["idea:x": ["idea:y"]], near: .init(x: 0, y: 0), regionName: "Tree"))
            #expect(model.layout.placements["idea:y"]!.x - model.layout.placements["idea:x"]!.x == 300)
        }
    }

    @Test("A node a tree's frame would leave with its usual middle outside is still held: the frame grows to it")
    func frameHoldsEveryMiddle() throws {
        try withModel(ideas: [("r", "Why do we age?"), ("a", "AB")]) { model in
            let made = try #require(model.placeTree(root: "idea:r", children: ["idea:r": ["idea:a"]], near: .init(x: 0, y: 0), regionName: "Short"))
            // "AB" is 60 wide: its spot's usual middle is 60 further right than the node's own.
            #expect(model.regionID(containing: "idea:a") == made.regionID)
            #expect(model.isMindMapNode("idea:a") == .leaf)
            let region = try #require(model.layout.regions[made.regionID])
            let spot = try #require(model.layout.placements["idea:a"])
            #expect(spot.x + 120 <= region.x + region.w && spot.y + 60 <= region.y + region.h)
        }
    }
}

@Suite("Canvas: the new fields over MCP")
@MainActor
struct KnowledgeMapSapienceMCPTests {
    typealias Store = MCPDataStore

    private func withMap(_ body: (KnowledgeMapModel) async throws -> Void) async rethrows {
        let suite = UserDefaults(suiteName: "KnowledgeMapSapienceMCPTests.\(UUID().uuidString)")!
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let map = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            map.rebuildContent(
                articles: ["p", "s2"].map { StudioArticle(url: "https://example.com/\($0)", title: "Paper \($0)", sourceType: .paper, id: $0) },
                ideas: [("a", "An idea"), ("q", "Does it spread?"), ("c", "A claim")].map { IdeaRecord(id: $0.0, title: $0.1) },
                notebooks: [], chats: [], artifacts: [], firstHighlights: [:]
            )
            try await body(map)
        }
    }

    private func apart() { Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05) }

    private func cards(_ result: [String: Any], _ key: String = "cards") -> [[String: Any]] { result[key] as? [[String: Any]] ?? [] }

    private func refusal(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch MCPError.invalidInput(let message) {
            return message
        } catch MCPError.notFound(let message) {
            return message
        } catch {
            return "unexpected: \(error)"
        }
    }

    @Test("update_canvas_card shows a source as a page, clamps it, takes it off with 0, and says so in the cards it returns")
    func updateCardPage() async throws {
        try await withMap { map in
            map.place([(ref: "source:p", x: 0, y: 0), (ref: "source:s2", x: 300, y: 0)])
            apart()
            let shown = try Store.updateCanvasCard(["item_ids": ["source:p"], "page": 3], map: map)
            #expect(shown["updated"] as? Int == 1)
            #expect(cards(shown)[0]["page"] as? Int == 3 && cards(shown)[0]["pages"] == nil, "how long the PDF is is not known yet")
            map.pageFaces["p"] = KnowledgeMapPageFace(pageCount: 5, aspect: 0.75)
            apart()
            let clamped = try Store.updateCanvasCard(["item_ids": ["source:p"], "page": 12], map: map)
            #expect(cards(clamped)[0]["page"] as? Int == 5 && cards(clamped)[0]["pages"] as? Int == 5)
            let rect = cards(clamped)[0]["rect"] as? [String: Double]
            #expect(rect?["h"] == 390, "as tall as the page it shows")
            apart()
            let card = try Store.updateCanvasCard(["item_ids": ["source:p"], "page": 0], map: map)
            #expect(cards(card)[0]["page"] == nil && cards(card)[0]["pages"] == nil && map.layout.placements["source:p"]?.page == nil)
            map.undo()
            #expect(map.layout.placements["source:p"]?.page == 5, "one step")

            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["source:p"], "page": -1], map: map) }?.contains("page is a page number") == true)
            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["source:p"], "page": 1.5], map: map) }?.contains("page is a page number") == true)
            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["source:p"], "page": "three"], map: map) }?.contains("page is a page number") == true)
            map.place([(ref: "idea:a", x: 600, y: 0)])
            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["source:p", "idea:a"], "page": 2], map: map) }?.contains("not a source") == true)
        }
    }

    @Test("update_canvas_card writes the learner's words under a card, refuses them for an Idea and past 600 characters, and an empty string takes them off")
    func updateCardAnnotation() async throws {
        try await withMap { map in
            map.place([(ref: "source:p", x: 0, y: 0), (ref: "idea:a", x: 300, y: 0)])
            apart()
            let written = try Store.updateCanvasCard(["item_ids": ["source:p"], "annotation": "  The cleanest measurement.  "], map: map)
            let card = cards(written)[0]
            #expect(card["annotation"] as? String == "The cleanest measurement.")
            #expect((card["rect"] as? [String: Double])?["h"] == Double(120 + 26), "room for one line under the card")
            apart()
            let off = try Store.updateCanvasCard(["item_ids": ["source:p"], "annotation": ""], map: map)
            #expect(cards(off)[0]["annotation"] == nil && map.layout.placements["source:p"]?.annotation == nil)

            let idea = refusal { try Store.updateCanvasCard(["item_ids": ["idea:a"], "annotation": "why"], map: map) }
            #expect(idea?.contains("holds its words") == true && idea?.contains("An idea") == true)
            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["source:p"], "annotation": String(repeating: "x", count: 601)], map: map) }?.contains("at most 600") == true)
            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["source:p"], "annotation": 5], map: map) }?.contains("annotation is text") == true)
            #expect(map.layout.placements["source:p"]?.annotation == nil, "a refusal writes nothing")
        }
    }

    @Test("update_canvas_card draws Ideas as words and marks questions answered; get_knowledge_map's card says question and answered")
    func updateCardPlainAnswered() async throws {
        try await withMap { map in
            map.place([(ref: "idea:a", x: 0, y: 0), (ref: "idea:q", x: 300, y: 0), (ref: "source:p", x: 600, y: 0)])
            apart()
            let plain = try Store.updateCanvasCard(["item_ids": ["idea:a", "idea:q"], "plain": true], map: map)
            #expect(cards(plain).allSatisfy { ($0["plain"] as? Bool) == true })
            #expect(cards(plain).map { $0["question"] as? Bool } == [nil, true], "the Idea that is not a question does not say so")
            apart()
            let answered = try Store.updateCanvasCard(["item_ids": ["idea:q"], "answered": true], map: map)
            #expect(cards(answered)[0]["answered"] as? Bool == true && cards(answered)[0]["question"] as? Bool == true)
            #expect(Store.card("idea:q", in: map)["answered"] as? Bool == true)
            apart()
            let open = try Store.updateCanvasCard(["item_ids": ["idea:q"], "answered": false, "plain": false], map: map)
            #expect(cards(open)[0]["answered"] == nil && cards(open)[0]["plain"] == nil && cards(open)[0]["question"] as? Bool == true)
            #expect(Store.card("idea:a", in: map)["question"] == nil && Store.card("source:p", in: map)["question"] == nil)

            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["source:p"], "plain": true], map: map) }?.contains("not an Idea") == true)
            let notQuestion = refusal { try Store.updateCanvasCard(["item_ids": ["idea:a"], "answered": true], map: map) }
            #expect(notQuestion?.contains("ends with ?") == true && notQuestion?.contains("An idea") == true)
            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["idea:a"]], map: map) }?.contains("or page, annotation, plain or answered") == true)
        }
    }

    @Test("place_on_canvas sets a paper down as its page unless face says card, shows another source as a page for face page, and writes the words it is given in the one step")
    func placeFaceAndAnnotations() async throws {
        try await withMap { map in
            // A paper with its PDF on the Mac is a page; the other paper has none.
            map.pageFaceDefault = { $0 == "p" }
            map.pageFaces["p"] = KnowledgeMapPageFace(pageCount: 5, aspect: nil)
            let first = try Store.placeOnCanvas(["item_ids": ["source:p", "source:s2", "idea:a"]], map: map)
            #expect(map.layout.placements["source:p"]?.page == 1 && map.layout.placements["source:s2"]?.page == nil)
            #expect(cards(first, "placed").first { $0["item_id"] as? String == "source:p" }?["page"] as? Int == 1)
            map.undo()
            #expect(map.layout.placements.isEmpty, "all of it one step")
            apart()

            _ = try Store.placeOnCanvas(["item_ids": ["source:p"], "face": "card"], map: map)
            #expect(map.layout.placements["source:p"]?.page == nil)
            apart()
            _ = try Store.placeOnCanvas(["item_ids": ["source:p"], "face": "page"], map: map)
            #expect(map.layout.placements["source:p"]?.page == 1, "a card moved is shown as its page when asked")
            map.undo()
            map.undo()
            apart()
            _ = try Store.placeOnCanvas(["item_ids": ["source:s2"], "face": "page"], map: map)
            #expect(map.layout.placements["source:s2"]?.page == 1)
            map.undo()
            apart()

            let words = try Store.placeOnCanvas([
                "item_ids": ["source:p", "source:s2", "idea:c"], "new_region": "Surveys",
                "annotations": ["source:p": "Start here. A broad survey.", "source:s2": ""],
            ], map: map)
            let placed = cards(words, "placed")
            let paper = try #require(placed.first { $0["item_id"] as? String == "source:p" })
            #expect(paper["annotation"] as? String == "Start here. A broad survey.")
            #expect((paper["rect"] as? [String: Double])?["h"] == Double(381 + 26))
            #expect(placed.first { $0["item_id"] as? String == "source:s2" }?["annotation"] == nil, "empty words write nothing")
            let spots = placed.compactMap { ($0["rect"] as? [String: Double]) }
            #expect(spots.count == 3)
            map.undo()
            #expect(map.layout.placements.isEmpty && map.layout.regions.isEmpty, "the cards, their words and the region are one step")

            #expect(refusal { try Store.placeOnCanvas(["item_ids": ["source:p"], "face": "poster"], map: map) }?.contains("face is page or card") == true)
            let idea = refusal { try Store.placeOnCanvas(["item_ids": ["idea:c"], "annotations": ["idea:c": "why"]], map: map) }
            #expect(idea?.contains("holds its words") == true)
            #expect(refusal { try Store.placeOnCanvas(["item_ids": ["source:p"], "annotations": ["source:s2": "why"]], map: map) }?.contains("does not set down") == true)
            #expect(refusal { try Store.placeOnCanvas(["item_ids": ["source:p"], "annotations": ["source:ghost": "why"]], map: map) }?.contains("not in the library") == true)
            #expect(refusal { try Store.placeOnCanvas(["item_ids": ["source:p"], "annotations": "why"], map: map) }?.contains("object") == true)
            #expect(refusal { try Store.placeOnCanvas(["item_ids": ["source:p"], "annotations": ["source:p": String(repeating: "x", count: 700)]], map: map) }?.contains("at most 600") == true)
            #expect(map.layout.placements.isEmpty, "a refusal writes nothing")
        }
    }

    @Test("Arrows take a stance when drawn and when changed, report it, and refuse any other word")
    func arrowStance() async throws {
        try await withMap { map in
            map.place([(ref: "idea:a", x: 0, y: 0), (ref: "idea:c", x: 400, y: 0)])
            apart()
            let drawn = try Store.drawCanvasArrow(["from": "idea:a", "to": "idea:c", "label": "because", "stance": "Supports"], map: map)
            #expect(drawn["stance"] as? String == "supports" && drawn["label"] as? String == "because")
            let id = try #require(drawn["edge_id"] as? String)
            #expect(map.layout.edges[id]?.stance == "supports")
            apart()
            let against = try Store.changeCanvasArrow(["edge_id": id, "stance": "contradicts"], map: map, deleting: false)
            #expect(against["stance"] as? String == "contradicts" && against["changed"] as? Bool == true)
            apart()
            let cleared = try Store.changeCanvasArrow(["edge_id": id, "stance": ""], map: map, deleting: false)
            #expect(cleared["stance"] == nil && map.layout.edges[id]?.stance == nil)
            #expect(Store.arrowEntry(id, in: map)["stance"] == nil, "none is left out")

            #expect(refusal { try Store.drawCanvasArrow(["from": "idea:c", "to": "idea:a", "stance": "refutes"], map: map) }?.contains("stance is supports or contradicts") == true)
            #expect(refusal { try Store.changeCanvasArrow(["edge_id": id, "stance": "maybe"], map: map, deleting: false) }?.contains("stance is supports or contradicts") == true)
            #expect(refusal { try Store.changeCanvasArrow(["edge_id": id], map: map, deleting: false) }?.contains("or stance") == true)
        }
    }

    @Test("The tools publish the new fields, and the Canvas tools that edit take them on the learner's word")
    func registry() throws {
        func properties(_ name: String) throws -> [String: Any] {
            let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == name }, "\(name)")
            return try #require(tool.inputSchema["properties"] as? [String: Any])
        }
        func tool(_ name: String) throws -> MCPToolDef { try #require(MCPToolRegistry.shared.tools.first { $0.name == name }) }
        let card = try properties("update_canvas_card")
        #expect(Set(card.keys) == ["item_ids", "color", "folded", "w", "h", "fit_to_content", "page", "annotation", "plain", "answered"])
        #expect((card["page"] as? [String: Any])?["type"] as? String == "integer")
        #expect((card["annotation"] as? [String: Any])?["type"] as? String == "string")
        #expect((card["plain"] as? [String: Any])?["type"] as? String == "boolean")
        #expect((card["answered"] as? [String: Any])?["type"] as? String == "boolean")

        let place = try properties("place_on_canvas")
        #expect((place["annotations"] as? [String: Any])?["type"] as? String == "object")
        #expect((place["face"] as? [String: Any])?["enum"] as? [String] == ["page", "card"])
        #expect(try tool("place_on_canvas").inputSchema["required"] as? [String] == ["item_ids"])

        let build = try properties("build_canvas")
        #expect((build["annotations"] as? [String: Any])?["type"] as? String == "object")
        let arrowItems = try #require((build["arrows"] as? [String: Any])?["items"] as? [String: Any])
        #expect(((arrowItems["properties"] as? [String: Any])?["stance"] as? [String: Any])?["enum"] as? [String] == ["supports", "contradicts"])
        #expect(try tool("build_canvas").inputSchema["required"] as? [String] == [])
        #expect(((try properties("canvas_arrow"))["stance"] as? [String: Any])?["type"] as? String == "string")
        #expect(try tool("canvas_arrow").inputSchema["required"] as? [String] == ["action"])

        let reading = try tool("get_knowledge_map").description
        for word in ["page", "pages", "annotation", "plain", "question", "answered", "stance"] { #expect(reading.contains(word), "\(word)") }
        for name in ["update_canvas_card", "place_on_canvas", "build_canvas", "canvas_arrow"] {
            #expect(MCPToolRegistry.canvasEditToolNames.contains(name), "\(name)")
            #expect(try tool(name).description.contains("Undo"), "\(name)")
        }
        for name in ["update_canvas_card", "place_on_canvas", "canvas_arrow"] {
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name), "\(name)")
        }
        // An annotation that is cleared with an empty string reaches the tool as sent.
        #expect(MCPToolRegistry.normalizedArguments(toolName: "update_canvas_card", arguments: ["annotation": ""])["annotation"] as? String == "")
        #expect(MCPToolRegistry.normalizedArguments(toolName: "canvas_arrow", arguments: ["action": "update", "stance": ""])["stance"] as? String == "")
    }
}

@Suite("Canvas: what a copy as Markdown writes of the new fields")
struct KnowledgeMapSapienceMarkdownTests {
    private func node(_ ref: String, _ title: String, sub: String = "") -> KnowledgeMapNode {
        let kind = KnowledgeMapMarkdown.kind(of: ref)
        return KnowledgeMapNode(ref: ref, kind: kind, type: kind, title: title, sub: sub, detail: [], shore: "")
    }

    private func sample() -> (layout: KnowledgeMapLayout, nodes: [String: KnowledgeMapNode]) {
        var layout = KnowledgeMapLayout()
        layout.place("idea:q1", x: 0, y: 0, at: 1)
        layout.place("idea:q2", x: 300, y: 0, at: 1)
        layout.place("idea:n", x: 600, y: 0, at: 1)
        layout.place("source:p", x: 900, y: 0, at: 1)
        layout.placements["idea:q2"]?.answered = true
        layout.placements["idea:n"]?.plain = true
        layout.placements["source:p"]?.annotation = "First sentence. Second\nline"
        layout.setEdge("e1", .init(from: "idea:n", to: "source:p", label: "cites", at: 1, stance: "supports"))
        layout.setEdge("e2", .init(from: "idea:q1", to: "idea:n", label: "", at: 1, stance: "contradicts"))
        layout.setEdge("e3", .init(from: "idea:q1", to: "idea:q2", label: "", at: 1))
        let nodes = [
            node("idea:q1", "Does it spread?"), node("idea:q2", "Did it work？", sub: "Yes, in mice."),
            node("idea:n", "A claim"), node("source:p", "Paper P", sub: "Smith · 2020"),
        ]
        return (layout, Dictionary(nodes.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    @Test("A question starts with a box, ticked once answered; the learner's words are an indented line; an arrow ends with its stance")
    func markdown() {
        let (layout, nodes) = sample()
        let text = KnowledgeMapMarkdown.render(layout: layout, nodes: nodes)
        #expect(text == [
            "- ☐ **Does it spread?**",
            "- ☑ **Did it work？**",
            "  Yes, in mice.",
            "- **A claim**",
            "- [Paper P](foreverlm://source/p) — Smith · 2020",
            "  First sentence. Second  ",
            "  line",
            "",
            "## Connections",
            "",
            "- Does it spread? → Did it work？",
            "- Does it spread? → A claim (contradicts)",
            "- A claim → Paper P: cites (supports)",
            "",
        ].joined(separator: "\n"))
    }

    @Test("A clip keeps its own note above the words about it, and a picture takes words too; an Idea's annotation is never written")
    func wordsUnderOtherCards() {
        var layout = KnowledgeMapLayout()
        layout.place("clip:h", x: 0, y: 0, at: 1)
        layout.place("picture:ab12cd34-0000-4000-8000-0123456789ab", x: 300, y: 0, at: 1)
        layout.place("idea:i", x: 600, y: 0, at: 1)
        layout.placements["clip:h"]?.annotation = "Why it is here"
        layout.placements["picture:ab12cd34-0000-4000-8000-0123456789ab"]?.annotation = "The spindle"
        layout.placements["idea:i"]?.annotation = "stale words"
        let clip = KnowledgeMapNode(ref: "clip:h", kind: "clip", type: "clip", title: "Figure 2", sub: "Paper · p. 4", detail: ["My note"], shore: "", src: "source:s")
        let nodes = [clip, node("picture:ab12cd34-0000-4000-8000-0123456789ab", "Spindle"), node("idea:i", "An idea")]
        let text = KnowledgeMapMarkdown.render(layout: layout, nodes: Dictionary(nodes.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first }))
        #expect(text == [
            "- [Figure 2](foreverlm://source/s?page=4) (Paper, p. 4)",
            "  My note  ",
            "  Why it is here",
            "- ![Spindle](foreverlm://image/generated/ab12cd34-0000-4000-8000-0123456789ab)",
            "  The spindle",
            "- **An idea**",
            "",
        ].joined(separator: "\n"))
    }

    @Test("The published page follows the outline: the box, the words and the stance")
    func html() {
        let (layout, nodes) = sample()
        let outline = KnowledgeMapMarkdown.outline(layout: layout, nodes: nodes)
        let page = outline.html
        #expect(page.contains("<li>☐ <strong>Does it spread?</strong></li>"))
        #expect(page.contains("<li>☑ <strong>Did it work？</strong><br>\n<span class=\"note\">Yes, in mice.</span></li>"))
        #expect(page.contains("First sentence. Second<br>\nline</span>"))
        #expect(page.contains("A claim → Paper P: cites <span class=\"detail\">(supports)</span>"))
        #expect(outline.connections.contains { $0.stance == .contradicts } && outline.connections.contains { $0.stance == nil })
    }
}
