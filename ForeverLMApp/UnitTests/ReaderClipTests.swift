import Foundation
import Testing
@testable import ForeverLM

@Suite("Clips: a box cut out of a PDF page")
struct ReaderClipTests {
    private let crop = PaperFigureRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)

    @Test("A clip is a mark on one picture: its page region, addressed so any Mac draws it again from the PDF")
    func clipIsAPictureMark() throws {
        let clip = ReaderClip.highlight(
            sourceID: "paper-1", page: 4, crop: crop, title: "Figure 2B · ROS per oxygen",
            pixelWidth: 1600, pixelHeight: 960, note: "  bats lowest  "
        )
        #expect(clip.isPictureOnly)
        #expect(clip.quote.isEmpty)
        #expect(clip.pdfAnchor == nil)
        #expect(clip.note == "bats lowest")
        let reference = try #require(ReaderClip.reference(of: clip))
        #expect(reference.location == .page(4))
        #expect(reference.crop == crop)
        #expect(clip.imageAnchors[0].src.hasPrefix("foreverlm://image/paper-1/page/4?crop="))
        #expect(ReaderClip.title(of: clip) == "Figure 2B · ROS per oxygen")
        #expect(ReaderClip.page(of: clip) == 4)
        #expect(ReaderClip.aspect(of: clip) == 1600.0 / 960.0)
        // Stored as the column a web mark on pictures uses, so it reads back the same.
        #expect(ReaderImageAnchor.anchors(storedJSON: clip.geometryJSON) == clip.imageAnchors)
    }

    @Test("A passage, a web picture and a whole page are not clips")
    func otherMarksAreNotClips() {
        let now = Date()
        let passage = SourceHighlight(
            id: "h1", sourceID: "s", quote: "words", note: "", color: .default,
            anchor: ReaderTextAnchor(exact: "words"), pdfAnchor: nil, createdAt: now, updatedAt: now
        )
        let webPicture = SourceHighlight(
            id: "h2", sourceID: "s", quote: "", note: "", color: .default, anchor: ReaderTextAnchor(exact: ""),
            pdfAnchor: nil, imageAnchors: [ReaderImageAnchor(src: "https://example.com/fig.png")], createdAt: now, updatedAt: now
        )
        let wholePage = SourceHighlight(
            id: "h3", sourceID: "s", quote: "", note: "", color: .default, anchor: ReaderTextAnchor(exact: ""),
            pdfAnchor: nil, imageAnchors: [ReaderImageAnchor(src: "foreverlm://image/s/page/3")], createdAt: now, updatedAt: now
        )
        #expect(!ReaderClip.isClip(passage))
        #expect(!ReaderClip.isClip(webPicture))
        #expect(!ReaderClip.isClip(wholePage))
    }

    @Test("A drag's clip round-trips through the pasteboard and saves under its own id once")
    func transferRoundTrip() throws {
        let transfer = StudioClipTransfer(
            sourceID: "paper-1", page: 2, crop: crop, title: "Page 2", pixelWidth: 800, pixelHeight: 480, highlightID: "hl_fixed"
        )
        let decoded = try JSONDecoder().decode(StudioClipTransfer.self, from: JSONEncoder().encode(transfer))
        #expect(decoded == transfer)
        let saved = decoded.highlight()
        #expect(saved.id == "hl_fixed")
        #expect(StudioClipTransfer(clip: saved) == transfer)
    }

    // MARK: Matching a box to the figure index

    private let figure = ReaderClipFigureRegion(
        figureLabel: "Figure 2",
        caption: "Figure 2. Mitochondrial ROS per unit of oxygen across species. (A) Mice. (B) Bats.",
        rect: PaperFigureRect(x: 0.1, y: 0.1, width: 0.8, height: 0.4),
        panels: [
            .init(name: "A", rect: PaperFigureRect(x: 0.1, y: 0.1, width: 0.25, height: 0.4)),
            .init(name: "B", rect: PaperFigureRect(x: 0.37, y: 0.1, width: 0.25, height: 0.4)),
            .init(name: "C", rect: PaperFigureRect(x: 0.64, y: 0.1, width: 0.26, height: 0.4)),
        ]
    )

    @Test("A box round one panel is that panel, named with the caption's title")
    func onePanel() throws {
        let box = PaperFigureRect(x: 0.36, y: 0.09, width: 0.27, height: 0.42)
        let match = try #require(ReaderClipMatch.match(box, in: [figure]))
        #expect(match.label == "Figure 2B")
        #expect(ReaderClipMatch.title(for: match, page: 3) == "Figure 2B · Mitochondrial ROS per unit of oxygen across species")
    }

    @Test("A box round the whole figure, or round every panel, is the figure; two panels are both named")
    func wholeFigureAndRuns() throws {
        #expect(ReaderClipMatch.match(PaperFigureRect(x: 0.08, y: 0.08, width: 0.84, height: 0.44), in: [figure])?.label == "Figure 2")
        let two = PaperFigureRect(x: 0.36, y: 0.1, width: 0.55, height: 0.4)
        #expect(ReaderClipMatch.match(two, in: [figure])?.label == "Figure 2B, C")
        #expect(ReaderClipMatch.label(figure: "Figure 4", panels: ["B", "C", "D"]) == "Figure 4B–D")
        #expect(ReaderClipMatch.label(figure: "Figure 4", panels: ["DESIGN"]) == "Figure 4 · DESIGN")
    }

    @Test("A box inside one panel is that panel; a box round prose holds no figure and is named by its page")
    func insideAndOutside() {
        let inside = PaperFigureRect(x: 0.15, y: 0.2, width: 0.1, height: 0.1)
        #expect(ReaderClipMatch.match(inside, in: [figure])?.label == "Figure 2A")
        let prose = PaperFigureRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3)
        #expect(ReaderClipMatch.match(prose, in: [figure]) == nil)
        #expect(ReaderClipMatch.title(for: nil, page: 7) == "Page 7")
    }

    @Test("A click snaps to the panel under it, and a second click on that panel grows to the figure")
    func clickSnaps() {
        let first = ReaderClipMatch.snap(x: 0.45, y: 0.3, in: [figure], current: nil)
        #expect(first == figure.panels[1].rect)
        #expect(ReaderClipMatch.snap(x: 0.45, y: 0.3, in: [figure], current: first) == figure.rect)
        #expect(ReaderClipMatch.snap(x: 0.5, y: 0.8, in: [figure], current: nil) == nil)
    }

    // MARK: On the Canvas

    @Test("A clip on a shown source is a card as tall as its picture, tied to its source; one on a hidden source is not")
    func clipCards() throws {
        let paper = StudioArticle(url: "https://example.com/p", title: "Energetics of ROS", sourceType: .paper, id: "p")
        let clip = ReaderClip.highlight(sourceID: "p", page: 4, crop: crop, title: "Figure 2B", pixelWidth: 1200, pixelHeight: 600, note: "Bats lowest")
        let stray = ReaderClip.highlight(sourceID: "gone", page: 1, crop: crop, title: "Figure 1", pixelWidth: 100, pixelHeight: 100)
        let content = KnowledgeMapModel.content(
            articles: [paper], ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:], clips: [clip, stray]
        )
        let card = try #require(content.nodes.first { $0.kind == "clip" })
        #expect(content.nodes.filter { $0.kind == "clip" }.count == 1)
        #expect(card.ref == "clip:\(clip.id)")
        #expect(card.title == "Figure 2B")
        #expect(card.sub == "Energetics of ROS · p. 4")
        #expect(card.detail == ["Bats lowest"])
        #expect(card.h == KnowledgeMap.cardWidth / 2 + KnowledgeMap.clipFootHeight)
        #expect(content.links.contains { $0.kind == "clip" && $0.a == card.ref && $0.b == "source:p" })
        #expect(KnowledgeMap.ItemRef(card.ref)?.kind == .clip)
    }

    @Test("A passage the learner marked is a card of its words that names its paper; a picture mark is not a passage")
    func passageCards() throws {
        let paper = StudioArticle(url: "https://example.com/p", title: "Energetics of ROS", sourceType: .paper, id: "p")
        let words = "Bats sustain the lowest superoxide production per unit of oxygen."
        let now = Date()
        let mark = SourceHighlight(
            id: "h1", sourceID: "p", quote: words, note: "Why bats?", color: .default,
            anchor: ReaderTextAnchor(exact: words), pdfAnchor: ReaderPDFAnchor(pageIndex: 3, rects: []),
            createdAt: now, updatedAt: now
        )
        #expect(ReaderClip.isPassage(mark))
        #expect(ReaderClip.passagePage(of: mark) == 4)
        let picture = ReaderClip.highlight(sourceID: "p", page: 4, crop: crop, title: "Figure 2B", pixelWidth: 1200, pixelHeight: 600)
        #expect(!ReaderClip.isPassage(picture))

        let content = KnowledgeMapModel.content(
            articles: [paper], ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:], clips: [mark]
        )
        let card = try #require(content.nodes.first { $0.ref == "clip:h1" })
        #expect(card.quote == words)
        #expect(card.title == "p. 4 · Energetics of ROS")
        #expect(card.detail == ["Why bats?"])
        #expect(card.h == KnowledgeMap.passageHeight)
        let link = content.links.first { (link: KnowledgeMapLink) -> Bool in link.kind == "clip" && link.a == card.ref }
        #expect(link?.b == "source:p")
    }

    @Test("A clip's card stays within reason however thin or tall the box was")
    func clipHeightIsBounded() {
        #expect(KnowledgeMap.clipHeight(aspect: 20) == 70 + KnowledgeMap.clipFootHeight)
        #expect(KnowledgeMap.clipHeight(aspect: 0.1) == 420 + KnowledgeMap.clipFootHeight)
        #expect(KnowledgeMap.clipHeight(aspect: nil) == 160 + KnowledgeMap.clipFootHeight)
    }
}

@Suite("Pages of a PDF on the Canvas: one card per rendered page, left to right, foldable")
@MainActor
struct CanvasPageCardTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "CanvasPageCardTests.\(UUID().uuidString)")!
    }

    private func paper(_ id: String = "p") -> StudioArticle {
        StudioArticle(url: "https://example.com/\(id)", title: "Energetics of ROS", sourceType: .paper, id: id)
    }

    @Test("A page card is named by its source and page; a source id with colons keeps its colons")
    func pageRefs() throws {
        let ref = KnowledgeMap.pageRef(sourceID: "paper-1", page: 7)
        #expect(ref == "page:paper-1:7")
        let parts = try #require(KnowledgeMap.ItemRef(ref)?.pageParts)
        #expect(parts.sourceID == "paper-1" && parts.page == 7)
        let colonRef = KnowledgeMap.pageRef(sourceID: "zoom:abc:123", page: 2)
        let colonParts = try #require(KnowledgeMap.ItemRef(colonRef)?.pageParts)
        #expect(colonParts.sourceID == "zoom:abc:123" && colonParts.page == 2)
        #expect(KnowledgeMap.ItemRef("page:paper-1:0")?.pageParts == nil)
        #expect(KnowledgeMap.ItemRef("page:paper-1")?.pageParts == nil)
        #expect(KnowledgeMap.ItemRef("source:p")?.pageParts == nil)
    }

    @Test("A page range reads one page, a run, a list and all, clamped to the document")
    func pageRanges() {
        #expect(KnowledgeMap.pageRange(nil, pageCount: 4) == [1, 2, 3, 4])
        #expect(KnowledgeMap.pageRange("all", pageCount: 3) == [1, 2, 3])
        #expect(KnowledgeMap.pageRange("3", pageCount: 9) == [3])
        #expect(KnowledgeMap.pageRange("2-4", pageCount: 9) == [2, 3, 4])
        #expect(KnowledgeMap.pageRange("1,4,7-9", pageCount: 9) == [1, 4, 7, 8, 9])
        #expect(KnowledgeMap.pageRange("4-2", pageCount: 9) == [2, 3, 4])
        #expect(KnowledgeMap.pageRange("7-20", pageCount: 9) == [7, 8, 9], "past the end is left off")
        #expect(KnowledgeMap.pageRange("2,2,2-3", pageCount: 9) == [2, 3], "each page once, in the order named")
        #expect(KnowledgeMap.pageRange("12", pageCount: 9) == nil)
        #expect(KnowledgeMap.pageRange("abc", pageCount: 9) == nil)
        #expect(KnowledgeMap.pageRange("1-2-3", pageCount: 9) == nil)
        #expect(KnowledgeMap.pageRange("1", pageCount: 0) == nil)
    }

    @Test("A page card is as tall as its page at the card's width, within reason, over its foot")
    func pageHeights() {
        let letter = KnowledgeMap.pageHeight(aspect: 8.5 / 11)
        #expect(abs(letter - (KnowledgeMap.cardWidth * 11 / 8.5 + KnowledgeMap.clipFootHeight)) < 0.001)
        #expect(KnowledgeMap.pageHeight(aspect: nil) == KnowledgeMap.defaultPageHeight)
        #expect(KnowledgeMap.pageHeight(aspect: 0.01) == 640 + KnowledgeMap.clipFootHeight)
        #expect(KnowledgeMap.pageHeight(aspect: 40) == 120 + KnowledgeMap.clipFootHeight)
    }

    @Test("A page placed on a canvas is a card that names its paper; a page of a paper not in the library is none")
    func pageCardsInContent() throws {
        let aspect = 8.5 / 11
        let content = KnowledgeMapModel.content(
            articles: [paper()], ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:],
            pages: [
                KnowledgeMapPageCard(ref: KnowledgeMap.pageRef(sourceID: "p", page: 3), aspect: aspect),
                KnowledgeMapPageCard(ref: KnowledgeMap.pageRef(sourceID: "gone", page: 1), aspect: aspect),
            ]
        )
        let cards = content.nodes.filter { $0.kind == "page" }
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.ref == "page:p:3")
        #expect(card.title == "Page 3")
        #expect(card.sub == "Energetics of ROS")
        #expect(card.h == KnowledgeMap.pageHeight(aspect: aspect))
        #expect(content.links.contains { $0.kind == "clip" && $0.a == card.ref && $0.b == "source:p" })
    }

    @Test("Laying a paper's pages out sets them in one row, left to right, level, inside a region named for it, as one undo step")
    func layOutPagesInARow() throws {
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            let aspects = [1: 0.77, 2: 0.77, 3: 1.4, 4: 0.77]
            let laid = try #require(model.layOutPages(sourceID: "p", pages: [1, 2, 3, 4], aspects: aspects, regionName: "Energetics of ROS"))
            #expect(laid.refs == (1...4).map { "page:p:\($0)" })
            let spots = try laid.refs.map { try #require(model.layout.placements[$0]) }
            #expect(Set(spots.map(\.y)).count == 1, "every page is level")
            #expect(zip(spots, spots.dropFirst()).allSatisfy { $0.x + KnowledgeMap.cardWidth < $1.x }, "left to right, none over another")
            let region = try #require(model.layout.regions[laid.regionID])
            #expect(region.name == "Energetics of ROS")
            #expect(region.collapsed == nil)
            for (ref, spot) in zip(laid.refs, spots) {
                #expect(spot.x >= region.x && spot.x + KnowledgeMap.cardWidth <= region.x + region.w)
                #expect(spot.y >= region.y && spot.y + model.cardHeight(of: ref) <= region.y + region.h, "the region holds the tall page too")
            }
            #expect(model.cardHeight(of: "page:p:3") == KnowledgeMap.pageHeight(aspect: 1.4))
            model.undo()
            #expect(model.layout.placements.isEmpty && model.layout.regions.isEmpty)
        }
    }

    @Test("Pages already on the canvas stay where they are; only the others are set down")
    func layOutPagesTwice() throws {
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            let first = try #require(model.layOutPages(sourceID: "p", pages: [1, 2], aspects: [:], regionName: "A paper"))
            let before = try #require(model.layout.placements["page:p:1"])
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            #expect(model.layOutPages(sourceID: "p", pages: [1, 2], aspects: [:], regionName: "A paper") == nil)
            let more = try #require(model.layOutPages(sourceID: "p", pages: [2, 3], aspects: [:], regionName: "A paper"))
            #expect(more.refs == ["page:p:3"])
            #expect(model.layout.placements["page:p:1"] == before)
            #expect(model.layout.regions[more.regionID] != nil && more.regionID != first.regionID)
        }
    }

    @Test("A region folds up and opens again, keeps its cards where they are, and a move or resize never unfolds it")
    func foldingARegion() throws {
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite())) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            let laid = try #require(model.layOutPages(sourceID: "p", pages: [1, 2, 3], aspects: [:], regionName: "A paper", collapsed: true))
            #expect(model.layout.regions[laid.regionID]?.isCollapsed == true)
            let spots = laid.refs.map { model.layout.placements[$0] }
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            // The renderer reports a move as the region's new rect; the fold stays.
            let region = try #require(model.layout.regions[laid.regionID])
            model.saveRegion(id: laid.regionID, name: region.name, x: region.x + 10, y: region.y, w: region.w, h: region.h, color: region.color)
            #expect(model.layout.regions[laid.regionID]?.isCollapsed == true)
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            model.setRegionCollapsed(laid.regionID, false)
            #expect(model.layout.regions[laid.regionID]?.collapsed == nil)
            #expect(laid.refs.map { model.layout.placements[$0] } == spots, "folding moves nothing")
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            model.setRegionCollapsed(laid.regionID, true)
            model.undo()
            #expect(model.layout.regions[laid.regionID]?.isCollapsed == false, "folding is one undo step")
        }
    }

    @Test("A region from before folding existed reads as open, and the fold merges like the rest of the region")
    func foldIsPartOfTheRegionRow() throws {
        let old = ##"{"version":1,"placements":{},"edges":{},"removed":{},"regions":{"r1":{"name":"A","x":0,"y":0,"w":300,"h":200,"color":"#7F77DD","at":5}}}"##
        let row = try #require(KnowledgeMapLayout(preferenceValue: old))
        #expect(row.regions["r1"]?.collapsed == nil)
        var folded = row
        folded.regions["r1"]?.collapsed = true
        folded.regions["r1"]?.at = 9
        #expect(row.merged(with: folded).regions["r1"]?.isCollapsed == true, "the newer write, the fold, wins")
        var reopened = folded
        reopened.regions["r1"]?.collapsed = nil
        reopened.regions["r1"]?.at = 12
        #expect(folded.merged(with: reopened).regions["r1"]?.isCollapsed == false)
        let decoded = try #require(KnowledgeMapLayout(preferenceValue: folded.preferenceValue))
        #expect(decoded == folded)
    }

    @Test("get_knowledge_map and the region tools say a region is folded, and build_canvas takes pdf_pages")
    func mcpContract() throws {
        func tool(_ name: String) throws -> MCPToolDef { try #require(MCPToolRegistry.shared.tools.first { $0.name == name }) }
        let build = try tool("build_canvas")
        let properties = try #require(build.inputSchema["properties"] as? [String: Any])
        let pdf = try #require(properties["pdf_pages"] as? [String: Any])
        let item = try #require(pdf["items"] as? [String: Any])
        let fields = try #require(item["properties"] as? [String: Any])
        #expect(Set(fields.keys) == ["source_id", "pages", "collapsed", "color"])
        let update = try tool("update_canvas_region")
        let updateProperties = try #require(update.inputSchema["properties"] as? [String: Any])
        #expect(updateProperties["collapsed"] != nil)
        #expect(try tool("get_knowledge_map").description.contains("page:<source_id>:<n>"))
    }
}
