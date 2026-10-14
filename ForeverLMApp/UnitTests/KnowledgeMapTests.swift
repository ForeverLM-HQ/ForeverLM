import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ForeverLM

@Suite("Map: the learner's layout")
struct KnowledgeMapLayoutTests {
    @Test("Two Macs that moved different cards both keep their moves, whichever merges first")
    func mergeKeepsBothMoves() {
        var first = KnowledgeMapLayout()
        var second = KnowledgeMapLayout()
        first.place("source:a", x: 1, y: 1, at: 10)
        second.place("source:b", x: 2, y: 2, at: 11)
        let merged = first.merged(with: second)
        #expect(merged == second.merged(with: first))
        #expect(Set(merged.placements.keys) == ["source:a", "source:b"])
    }

    @Test("The newer write of one card wins, and a removal beats an older write but loses to a newer one")
    func newerWriteWins() {
        var base = KnowledgeMapLayout()
        base.place("source:a", x: 1, y: 1, at: 10)
        var moved = base
        moved.place("source:a", x: 9, y: 9, at: 20)
        #expect(base.merged(with: moved).placements["source:a"]?.x == 9)

        var removed = base
        removed.unplace("source:a", at: 15)
        #expect(base.merged(with: removed).placements["source:a"] == nil)
        let placedAgain = removed.merged(with: moved)
        #expect(placedAgain.placements["source:a"]?.x == 9)
        #expect(placedAgain.removed["p:source:a"] == nil, "a tombstone the entry outlived is spent")
    }

    @Test("Taking a card off the map takes its arrows with it")
    func unplaceRemovesArrows() {
        var layout = KnowledgeMapLayout()
        layout.place("source:a", x: 0, y: 0, at: 1)
        layout.place("source:b", x: 0, y: 0, at: 1)
        layout.setEdge("e1", .init(from: "source:a", to: "source:b", label: "objection", at: 1))
        layout.unplace("source:b", at: 2)
        #expect(layout.edges.isEmpty)
        #expect(layout.removed["e:e1"] == 2)
    }

    @Test("The row round-trips, a later format is read as nothing, and an inbound row merges only when this Mac holds more")
    func rowCodec() {
        var layout = KnowledgeMapLayout()
        layout.place("source:a", x: 1, y: 2, at: 3)
        layout.setRegion("r1", .init(name: "PET", x: 0, y: 0, w: 100, h: 100, color: "#D4537E", at: 3))
        #expect(KnowledgeMapLayout(preferenceValue: layout.preferenceValue) == layout)
        #expect(KnowledgeMapLayout(preferenceValue: #"{"version":99}"#) == nil)

        var remote = KnowledgeMapLayout()
        remote.place("source:b", x: 5, y: 5, at: 4)
        let merged = KnowledgeMapLayout.mergedOnReceipt(incoming: remote.preferenceValue, local: layout.preferenceValue)
        #expect(merged.flatMap { KnowledgeMapLayout(preferenceValue: $0) }?.placements.count == 2)
        #expect(KnowledgeMapLayout.mergedOnReceipt(incoming: layout.merged(with: remote).preferenceValue, local: layout.preferenceValue) == nil)
    }

    @Test("PreferenceStore merges a Map row entry by entry and sends the merge back")
    func preferenceStoreMergesMapRows() {
        var local = KnowledgeMapLayout()
        local.place("source:a", x: 1, y: 1, at: 10)
        var incoming = KnowledgeMapLayout()
        incoming.place("source:b", x: 2, y: 2, at: 11)
        let key = KnowledgeMap.layoutPreferenceKey(mapID: KnowledgeMap.firstCanvasID)
        let resolved = PreferenceStore.resolvedInbound(key: key, incoming: incoming.preferenceValue, local: local.preferenceValue)
        #expect(resolved.sendBack)
        #expect(KnowledgeMapLayout(preferenceValue: resolved.value)?.placements.count == 2)
        #expect(SyncedPreferenceKeys.isSynced(key))
    }

    @Test("Undo takes back the learner's last edit, entry by entry, and Redo puts it back")
    @MainActor
    func undoAndRedo() {
        let suite = UserDefaults(suiteName: "KnowledgeMapLayoutTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            #expect(!model.canUndo && !model.canRedo)
            model.place([(ref: "source:a", x: 0, y: 0), (ref: "source:b", x: 300, y: 0)])
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            model.place([(ref: "source:a", x: 50, y: 60)])
            #expect(model.canUndo)

            model.undo()
            #expect(model.layout.placements["source:a"].map { [$0.x, $0.y] } == [0, 0], "the move is taken back")
            #expect(model.layout.placements["source:b"] != nil, "the edit before it stays")
            #expect(model.canRedo)
            model.redo()
            #expect(model.layout.placements["source:a"].map { [$0.x, $0.y] } == [50, 60])
            #expect(!model.canRedo)

            model.undo()
            model.undo()
            #expect(model.layout.placements.isEmpty, "the first placing is taken back too")
            #expect(!model.canUndo)
            #expect(KnowledgeMapRows.layout(mapID: KnowledgeMap.firstCanvasID).placements.isEmpty, "undo writes the learner's row")
        }
    }

    @Test("Writes close together are one edit, undo never takes back another entry, and an arrow comes back with its card")
    @MainActor
    func undoIsOneEditAndLocal() {
        let suite = UserDefaults(suiteName: "KnowledgeMapLayoutTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.place([(ref: "source:a", x: 0, y: 0), (ref: "source:b", x: 300, y: 0)])
            let arrow = model.addEdge(from: "source:a", to: "source:b")
            #expect(arrow != nil)
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)

            // A region moved with its cards arrives as two writes: one edit.
            model.saveRegion(id: "r1", name: "Mine", x: -50, y: -90, w: 700, h: 300, color: "#7F77DD")
            model.place([(ref: "source:a", x: 10, y: 0)])
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)

            // Taking a card off takes its arrow; another Mac then moves card b.
            model.unplace(["source:a"])
            #expect(model.layout.edges.isEmpty)
            let key = KnowledgeMap.layoutPreferenceKey(mapID: KnowledgeMap.firstCanvasID)
            var remote = KnowledgeMapRows.layout(mapID: KnowledgeMap.firstCanvasID)
            remote.place("source:b", x: 999, y: 999, at: Date().timeIntervalSince1970 + 1)
            suite.set(remote.preferenceValue, forKey: key)

            model.undo()
            #expect(model.layout.placements["source:a"].map { [$0.x, $0.y] } == [10, 0], "the card comes back")
            #expect(model.layout.edges.count == 1, "with its arrow")
            #expect(model.layout.placements["source:b"].map { [$0.x, $0.y] } == [999, 999], "the other Mac's move stays")

            model.undo()
            #expect(model.layout.regions["r1"] == nil, "the region and the move made with it go back as one")
            #expect(model.layout.placements["source:a"].map { [$0.x, $0.y] } == [0, 0])
        }
    }

    @Test("Linking a notebook's frame by its name is the app's own write, never an Undo step")
    @MainActor
    func linkingIsNotUndoable() {
        let suite = UserDefaults(suiteName: "KnowledgeMapLayoutTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let now = Date()
            let notebook = LearningGoalRecord(
                id: "nb", title: "Scaling", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: now, updatedAt: now, status: "active", items: [], kind: LearningGoalRecord.companionKind
            )
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(articles: [], ideas: [], notebooks: [notebook], chats: [], artifacts: [], firstHighlights: [:])
            model.saveRegion(id: "r1", name: "Scaling", x: 0, y: 0, w: 600, h: 300, color: "#7F77DD")
            Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05)
            model.linkNotebookRegions()
            #expect(model.layout.regions["r1"]?.notebookID == "nb")
            model.undo()
            #expect(model.layout.regions["r1"] == nil, "Undo takes back the learner's region, not the link alone")
        }
    }

    @Test("Old tombstones are dropped")
    func tombstonesPrune() {
        var layout = KnowledgeMapLayout()
        layout.removed = ["p:old": 0, "p:new": 100 * 24 * 3600]
        layout.pruneTombstones(now: 100 * 24 * 3600 + 1)
        #expect(Array(layout.removed.keys) == ["p:new"])
    }

    @Test("Cards set down in a region fill its free cells, never on a card there, and the region grows to hold them")
    func spotsInRegion() {
        typealias Arranging = KnowledgeMapArranging
        let region = Arranging.Rect(x: 0, y: 0, w: 900, h: 300)
        let card = KnowledgeMap.cardHeight
        let laid = Arranging.spots(
            heights: Array(repeating: card, count: 4), in: region, taken: [.init(x: 50, y: 60, w: KnowledgeMap.cardWidth, h: card)]
        )
        #expect(laid.spots.first == .init(x: 320, y: 60), "the first cell is taken")
        #expect(laid.spots.count == 4)
        #expect(Set(laid.spots.map(\.y)) == [60, 210], "three across, then the next row")
        #expect(laid.height == 210 + 120 + 50)
        #expect(Arranging.spots(heights: [card], in: region, taken: []).height == 300, "a region never shrinks")
    }

    @Test("A block set down in free space overlaps nothing there, and its region frames it as a drop's does")
    func blockInFreeSpace() {
        typealias Arranging = KnowledgeMapArranging
        let block = Arranging.block(heights: Array(repeating: KnowledgeMap.cardHeight, count: 5), origin: .init(x: 50, y: 60))
        #expect(block.spots.count == 5)
        // Three across and two down, 30 apart, inset 50 by 60 (and 50 below).
        #expect(block.frame == Arranging.Rect(x: 0, y: 0, w: 880, h: 380))
        let occupied = [Arranging.Rect(x: -500, y: -300, w: 1000, h: 600)]
        let origin = Arranging.freeOrigin(size: (w: 880, h: 380), near: .init(x: 0, y: 0), occupied: occupied)
        let placed = Arranging.Rect(x: origin.x, y: origin.y, w: 880, h: 380)
        #expect(!occupied[0].intersects(placed))
        #expect(origin.y == -190, "moved sideways, not down, when the right is free")
    }

    @Test("A tall clip is set down as tall as it is: no card goes on the rows it covers, in a region or a block")
    func tallCardsKeepTheirRows() {
        typealias Arranging = KnowledgeMapArranging
        // A portrait figure: its picture is 480 at a card's width, held to 420, over the foot.
        let clip = KnowledgeMap.clipHeight(aspect: 0.5)
        let card = KnowledgeMap.cardHeight
        let region = Arranging.Rect(x: 0, y: 0, w: 900, h: 300)
        let laid = Arranging.spots(heights: [clip, card, card, card], in: region, taken: [])
        #expect(
            laid.spots == [.init(x: 50, y: 60), .init(x: 320, y: 60), .init(x: 590, y: 60), .init(x: 320, y: 210)],
            "the fourth card skips the cell under the clip"
        )
        #expect(laid.height == 60 + clip + 50, "the region grows to the clip's foot")
        let taken = [Arranging.Rect(x: 50, y: 60, w: KnowledgeMap.cardWidth, h: clip)]
        let around = Arranging.spots(heights: Array(repeating: card, count: 4), in: region, taken: taken)
        #expect(
            around.spots == [.init(x: 320, y: 60), .init(x: 590, y: 60), .init(x: 320, y: 210), .init(x: 590, y: 210)],
            "nothing is set down on a placed clip"
        )
        let block = Arranging.block(heights: [card, clip, card, card], origin: .init(x: 50, y: 60))
        #expect(block.spots[3] == .init(x: 50, y: 60 + clip + 30), "the second row starts under the clip")
        #expect(block.frame.h == clip + 30 + card + 60 + 50)
    }

    @Test("Edits asked for over MCP are the learner's: placed in a region, framed, moved with their region, taken off with it")
    @MainActor
    func editsOnTheLearnersWord() {
        let suite = UserDefaults(suiteName: "KnowledgeMapLayoutTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.saveRegion(id: "r", name: "Membrane potential", x: 0, y: 0, w: 900, h: 300, color: "#7F77DD")
            model.place([(ref: "source:a", x: 50, y: 60)])
            #expect(model.place(["source:b", "source:c"], inRegion: "r"))
            #expect(model.regionID(containing: "source:b") == "r")
            #expect(model.regionID(containing: "source:c") == "r")
            #expect(!model.place(["source:d"], inRegion: "nowhere"))

            let made = model.placeBlock(["source:d", "source:e"], near: .init(x: 0, y: 0), regionName: "Sestamibi")
            #expect(made != nil)
            #expect(model.layout.regions[made!]?.name == "Sestamibi")
            #expect(model.regionID(containing: "source:d") == made, "set down in free space, inside its own region")

            let around = model.makeRegion(around: ["source:a", "source:b"], name: "Pair")
            #expect(around.map { model.layout.regions[$0] != nil } == true)
            #expect(model.makeRegion(around: ["source:zzz"], name: "None") == nil, "only cards on the plane are framed in place")

            let before = model.layout.placements["source:c"]!
            model.editRegion("r", origin: .init(x: 1000, y: 2000))
            #expect(model.layout.regions["r"]?.x == 1000)
            #expect(model.layout.placements["source:c"]?.x == before.x + 1000, "a move carries the region's cards")
            #expect(model.layout.placements["source:c"]?.y == before.y + 2000)

            #expect(model.addEdge(from: "source:a", to: "source:c", label: " measures ") != nil)
            #expect(model.layout.edges.values.first?.label == "measures")
            #expect(model.addEdge(from: "source:a", to: "source:unplaced", label: "") == nil)

            model.deleteRegion("r", takingCardsOff: true)
            #expect(model.layout.regions["r"] == nil)
            #expect(model.layout.placements["source:c"] == nil)
            #expect(model.layout.edges.isEmpty, "its card's arrow went with it")

            #expect(model.canUndo, "each is an Undo step of the learner's (these, a moment apart, are one)")
        }
    }

    @Test("Item refs parse source:, doc:, idea:, clip:, page:, canvas:, chat: and picture: and nothing else")
    func itemRefs() {
        #expect(KnowledgeMap.ItemRef("source:abc") == .init(kind: .source, id: "abc"))
        #expect(KnowledgeMap.ItemRef("idea:x")?.kind == .idea)
        #expect(KnowledgeMap.ItemRef("clip:hl_1")?.kind == .clip)
        #expect(KnowledgeMap.ItemRef("canvas:cnv-1")?.kind == .canvas)
        #expect(KnowledgeMap.ItemRef("chat:abc")?.kind == .chat)
        #expect(KnowledgeMap.ItemRef("picture:9F2A")?.kind == .picture)
        #expect(KnowledgeMap.ItemRef("picture:9F2A")?.description == "picture:9F2A")
        #expect(KnowledgeMap.ItemRef("region:r1") == nil, "a region is an arrow's end, not a card")
        #expect(KnowledgeMap.ItemRef("note:x") == nil)
        #expect(KnowledgeMap.ItemRef("source:") == nil)
    }
}

/// Regions inside regions (docs/knowledge-map-design.md, "Regions inside
/// regions"): nothing is stored for nesting; a region drawn inside another
/// is inside it by its rect.
@Suite("Map: regions inside regions")
struct KnowledgeMapNestedRegionTests {
    private static func region(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> KnowledgeMapLayout.Region {
        .init(name: name, x: x, y: y, w: w, h: h, color: "#7F77DD", at: 1)
    }

    private static func layout() -> KnowledgeMapLayout {
        var layout = KnowledgeMapLayout()
        layout.setRegion("mootha", region("Mootha", 0, 0, 3000, 2000))
        layout.setRegion("mtdna", region("mtDNA mutations", 100, 200, 1200, 900))
        layout.setRegion("thresholds", region("Heteroplasmy thresholds", 150, 400, 500, 300))
        layout.setRegion("signalling", region("Signalling", 1500, 200, 1200, 900))
        layout.setRegion("aside", region("Aside", 5000, 0, 400, 300))
        return layout
    }

    @Test("A region's parent is the smallest region whose rect holds its rect; a region inside none has none")
    func parentIsTheSmallestEnclosingRegion() {
        let layout = Self.layout()
        #expect(layout.parentRegionID(of: "thresholds") == "mtdna", "not Mootha, which holds it too but is larger")
        #expect(layout.parentRegionID(of: "mtdna") == "mootha")
        #expect(layout.parentRegionID(of: "signalling") == "mootha")
        #expect(layout.parentRegionID(of: "mootha") == nil)
        #expect(layout.parentRegionID(of: "aside") == nil)
        #expect(layout.parentRegionID(of: "missing") == nil)
    }

    @Test("The regions inside a region are its direct children, left to right then top to bottom; the path to a region is its ancestors outermost first")
    func nestedRegionsAndPath() {
        let layout = Self.layout()
        #expect(layout.nestedRegionIDs(in: "mootha") == ["mtdna", "signalling"], "thresholds is inside mtDNA, not directly inside Mootha")
        #expect(layout.nestedRegionIDs(in: "mtdna") == ["thresholds"])
        #expect(layout.nestedRegionIDs(in: "thresholds").isEmpty)
        #expect(layout.regionPath(of: "thresholds") == ["mootha", "mtdna"])
        #expect(layout.regionPath(of: "mootha").isEmpty)
        #expect(layout.regionIDsInside("mootha") == ["mtdna", "thresholds", "signalling"], "every depth, each before the regions inside it")
        #expect(layout.regionIDsInside("aside").isEmpty)
    }

    @Test("A region drawn to the same rect as another is inside neither, and half a point over the edge still counts as inside")
    func sameRectAndSlack() {
        var layout = KnowledgeMapLayout()
        layout.setRegion("a", Self.region("A", 0, 0, 500, 400))
        layout.setRegion("b", Self.region("B", 0, 0, 500, 400))
        #expect(layout.parentRegionID(of: "a") == nil)
        #expect(layout.parentRegionID(of: "b") == nil)

        layout.setRegion("c", Self.region("C", -0.4, 10, 200, 100))
        #expect(layout.parentRegionID(of: "c") != nil, "a hair over the left edge is still inside")
        layout.setRegion("d", Self.region("D", -2, 10, 200, 100))
        #expect(layout.parentRegionID(of: "d") == nil, "two points over the edge is not")
    }
}

/// Figures only (docs/knowledge-map-design.md, "Figures only"): which of a
/// paper's figures a canvas lays out, and in what order.
@Suite("Map: a paper's figures only")
struct PaperFigureSelectionTests {
    @Test("A label naming an extended or supplementary figure is told from a main one")
    func extendedLabels() {
        for label in ["Extended Data Fig. 1", "Extended Data Figure 3", "ED Fig. 2", "Supplementary Figure 1", "Supplemental Fig. S2",
                      "Suppl. Fig. 4", "Figure S1", "Fig. S3", "Fig S12", "S4", "Appendix Figure 2"] {
            #expect(PaperFigureSelection.isExtended(label), "\(label)")
        }
        for label in ["Figure 1", "Fig. 2", "Figure 12", "Fig 3", "Figure", "Scheme 1", "Figure 5. Survival"] {
            #expect(!PaperFigureSelection.isExtended(label), "\(label)")
        }
        #expect(PaperFigureSelection.number(in: "Figure 12") == 12)
        #expect(PaperFigureSelection.number(in: "Fig. S3") == 3)
        #expect(PaperFigureSelection.number(in: "Figure") == nil)
    }

    @Test("The main figures come in number order, then by page; the extended ones follow only when asked for")
    func orderAndExtended() {
        let figures: [(label: String, page: Int)] = [
            ("Figure 3", 6), ("Extended Data Fig. 1", 14), ("Figure 1", 2), ("Figure S2", 20),
            ("Figure 2", 4), ("Figure S1", 18), ("Figure", 9),
        ]
        let main = PaperFigureSelection.ordered(figures, includeExtended: false, label: \.label, pageIndex: \.page)
        #expect(main.map(\.label) == ["Figure 1", "Figure 2", "Figure 3", "Figure"], "a label with no number goes last")
        let all = PaperFigureSelection.ordered(figures, includeExtended: true, label: \.label, pageIndex: \.page)
        #expect(all.map(\.label) == ["Figure 1", "Figure 2", "Figure 3", "Figure", "Extended Data Fig. 1", "Figure S1", "Figure S2"])
    }
}

@Suite("Map: lenses")
struct KnowledgeMapLensTests {
    private func ref(_ id: String) -> KnowledgeMap.ItemRef { .init(kind: .source, id: id) }

    @Test("A groups lens shows each known card once, in non-overlapping groups")
    func groupsLens() {
        var request = KnowledgeMapLensRequest(title: "By species", layout: .groups)
        request.groups = [
            .init(label: "Mouse", items: (0..<7).map { ref("m\($0)") }),
            .init(label: "Human", items: [ref("m1"), ref("h1"), ref("gone")]),
        ]
        let lens = KnowledgeMapLens.laidOut(request, center: (0, 0), height: { _ in KnowledgeMap.cardHeight }) { $0.id != "gone" }
        #expect(lens.positions.count == 8)
        #expect(lens.frames.map(\.label) == ["Mouse", "Human"])
        let spots = Array(lens.positions.values)
        for i in spots.indices {
            for j in spots.indices where j > i {
                let apart = abs(spots[i].x - spots[j].x) >= KnowledgeMap.cardWidth || abs(spots[i].y - spots[j].y) >= KnowledgeMap.cardHeight
                #expect(apart, "two cards in one spot")
            }
        }
    }

    @Test("An axes lens puts cards inside its frame and steps apart two on one spot")
    func axesLens() {
        var request = KnowledgeMapLensRequest(title: "Axes", layout: .axes)
        request.xAxis = .init(label: "How alive", low: "cells", high: "human")
        request.yAxis = .init(label: "How direct", low: "proxy", high: "absolute")
        request.points = [
            .init(item: ref("a"), x: 0.5, y: 0.5),
            .init(item: ref("b"), x: 0.5, y: 0.5),
            .init(item: ref("c"), x: 1, y: 0),
        ]
        let lens = KnowledgeMapLens.laidOut(request, center: (0, 0), height: { _ in KnowledgeMap.cardHeight }) { _ in true }
        let a = try! #require(lens.positions["source:a"]), b = try! #require(lens.positions["source:b"])
        #expect(abs(a.y - b.y) >= KnowledgeMap.cardHeight)
        let frame = try! #require(lens.axes?.frame)
        let c = try! #require(lens.positions["source:c"])
        #expect(c.x + KnowledgeMap.cardWidth <= frame.x + frame.w + 1)
        #expect(c.y + KnowledgeMap.cardHeight <= frame.y + frame.h + 1)
    }

    @Test("A lens gives a tall clip the room it takes: the row under it starts below it, in a group and on axes")
    func lensRoomForTallCards() {
        let clipRef = KnowledgeMap.ItemRef(kind: .clip, id: "fig2b")
        let clip = KnowledgeMap.clipHeight(aspect: 0.5)
        let height: (KnowledgeMap.ItemRef) -> Double = { $0.kind == .clip ? clip : KnowledgeMap.cardHeight }

        var groups = KnowledgeMapLensRequest(title: "Figures", layout: .groups)
        groups.groups = [.init(label: "Membrane potential", items: [clipRef] + (0..<3).map { ref("p\($0)") })]
        let grouped = KnowledgeMapLens.laidOut(groups, center: (0, 0), height: height) { _ in true }
        let top = try! #require(grouped.positions[clipRef.description])
        let below = try! #require(grouped.positions["source:p2"])
        #expect(below.y >= top.y + clip, "the second row starts under the clip")
        let frame = try! #require(grouped.frames.first)
        #expect(frame.y + frame.h >= below.y + KnowledgeMap.cardHeight, "the group frames the row under the clip")

        var axes = KnowledgeMapLensRequest(title: "Axes", layout: .axes)
        axes.points = [.init(item: clipRef, x: 0.5, y: 0.5), .init(item: ref("b"), x: 0.5, y: 0.5)]
        let plotted = KnowledgeMapLens.laidOut(axes, center: (0, 0), height: height) { _ in true }
        let a = try! #require(plotted.positions[clipRef.description]), b = try! #require(plotted.positions["source:b"])
        #expect(b.y >= a.y + clip, "a card on the clip's spot steps below the whole clip")
    }

    @Test("Keep places the lens's cards and makes its groups regions; Back to My Map keeps nothing")
    @MainActor
    func keepAndClear() throws {
        let suite = UserDefaults(suiteName: "KnowledgeMapLensTests.\(UUID().uuidString)")!
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(
                articles: [StudioArticle(url: "https://example.com/a", title: "A", sourceType: .paper, id: "a")],
                ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:]
            )
            var request = KnowledgeMapLensRequest(title: "Groups", layout: .groups)
            request.groups = [.init(label: "One", items: [ref("a")])]
            try model.apply(request)
            model.clearLens()
            #expect(model.layout.placements.isEmpty)

            try model.apply(request)
            model.keepLens()
            #expect(model.lens == nil)
            #expect(model.layout.placements["source:a"] != nil)
            #expect(model.layout.regions.values.map(\.name) == ["One"])
            #expect(KnowledgeMapRows.layout(mapID: KnowledgeMap.firstCanvasID) == model.layout, "Keep writes the learner's row")
        }
    }

    @Test("A lens that names no card on the map is refused")
    @MainActor
    func emptyLensRefused() {
        let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
        var request = KnowledgeMapLensRequest(title: "Nothing", layout: .groups)
        request.groups = [.init(label: "X", items: [ref("missing")])]
        #expect(throws: KnowledgeMapModel.LensError.noKnownItems) { try model.apply(request) }
    }

    @Test("apply_map_lens's arguments become a request; a bare id is a source")
    func toolArguments() throws {
        let request = try MCPDataStore.lensRequest(from: [
            "title": "By species",
            "layout": "groups",
            "groups": [["label": "Mouse", "item_ids": ["source:a", "b"]]],
        ])
        #expect(request.groups.first?.items == [ref("a"), ref("b")])
        #expect(request.hidesOthers)
        #expect(throws: MCPError.self) { try MCPDataStore.lensRequest(from: ["title": "x", "layout": "axes", "points": []]) }
        #expect(throws: MCPError.self) { try MCPDataStore.lensRequest(from: ["layout": "groups"]) }
    }
}

@Suite("Map: cards and summaries")
struct KnowledgeMapContentTests {
    @Test("Cards carry the source's faces, wait in their notebook on the shore, and relate through shared chats and Ideas")
    func content() {
        var paper = StudioArticle(url: "https://example.com/p", title: "In vivo imaging of membrane potential", sourceType: .paper, id: "p")
        paper.author = "Milica Momcilovic"
        paper.publishedYear = "2019"
        paper.journal = "Nature"
        let reply = StudioArticle(url: "https://example.com/r", title: "In vivo quantification", sourceType: .paper, id: "r")
        var hidden = StudioArticle(url: "https://example.com/h", title: "Hidden", sourceType: .article, id: "h")
        hidden.isHidden = true
        let now = Date()
        let notebook = LearningGoalRecord(
            id: "nb", title: "Mito Phenotyping", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now, updatedAt: now, status: "active",
            items: [LearningGoalItem(id: "i", goalID: "nb", sourceID: "p", addedAt: now)],
            kind: LearningGoalRecord.companionKind
        )
        let chat = ReviewSessionRecord(id: "c", title: "Chat", createdAt: now, status: "active", sourceIDs: ["p", "r"])
        let idea = IdeaRecord(title: "Nobody reads absolute ΔΨm in humans", links: [IdeaLink(kind: .source, targetID: "r")])
        let content = KnowledgeMapModel.content(
            articles: [paper, reply, hidden], ideas: [idea], notebooks: [notebook], chats: [chat], artifacts: [],
            firstHighlights: ["p": "the Nernst equation is only valid at equilibrium"]
        )
        #expect(content.nodes.filter { $0.kind != "chat" }.map(\.ref) == ["source:p", "source:r", "idea:\(idea.id)"])
        #expect(content.nodes.filter { $0.kind == "chat" }.map(\.ref) == ["chat:c"], "a chat is a card too (the parity build)")
        let card = content.nodes[0]
        #expect(card.sub == "Milica Momcilovic · 2019 · Nature")
        #expect(card.shore == "Mito Phenotyping")
        #expect(card.detail.contains("In Mito Phenotyping"))
        #expect(card.detail.contains("1 chat"))
        #expect(content.nodes[1].shore == "Not in a notebook")
        #expect(content.links.contains { $0.kind == "chat" && Set([$0.a, $0.b]) == ["source:p", "source:r"] })
        #expect(content.links.contains { $0.kind == "idea" && $0.b == "source:r" })
    }

    @Test("A notebook's Docs are cards too, waiting in its cluster and tied to the sources they cite; a card deck is not")
    func docsAreCards() {
        let now = Date()
        let paper = StudioArticle(url: "https://example.com/p", title: "A paper", sourceType: .paper, id: "p")
        let notebook = LearningGoalRecord(
            id: "nb", title: "🧬 Mito Phenotyping", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now, updatedAt: now, status: "active", items: [], kind: LearningGoalRecord.companionKind
        )
        let doc = ArtifactRecord(id: "d", title: "The landscape", homeNotebookID: "nb", linkedNotebookIDs: [], sourceIDs: ["p"], createdAt: now, updatedAt: now)
        let site = ArtifactRecord(id: "s", title: "Atlas", homeNotebookID: nil, linkedNotebookIDs: [], linkedURL: "https://example.com", createdAt: now, updatedAt: now)
        let deck = ArtifactRecord(id: "carddeck-p", title: "Cards", homeNotebookID: nil, linkedNotebookIDs: [], kind: .flashcards, createdAt: now, updatedAt: now)
        let archived = ArtifactRecord(id: "old", title: "Old", homeNotebookID: "nb", linkedNotebookIDs: [], archivedAt: now, createdAt: now, updatedAt: now)
        let content = KnowledgeMapModel.content(
            articles: [paper], ideas: [], notebooks: [notebook], chats: [], artifacts: [doc, site, deck, archived], firstHighlights: [:]
        )
        let docs = content.nodes.filter { $0.kind == "doc" }
        #expect(docs.map(\.ref) == ["doc:d", "doc:s"])
        #expect(docs[0].shore == "Mito Phenotyping", "a Doc waits in its home notebook, named without its emoji")
        #expect(docs[0].sub == "Page · 1 source")
        #expect(docs[1].type == "site" && docs[1].shore == "Pages")
        #expect(content.links.contains { $0.a == "doc:d" && $0.b == "source:p" && $0.kind == "doc" })
        #expect(KnowledgeMap.ItemRef("doc:d")?.kind == .doc)
    }

    @Test("The model's summaries are read by cluster key, and a key not asked for is dropped")
    func summariesParse() throws {
        let asked = [KnowledgeMapSummaries.Cluster(key: "nb:Mito", name: "Mito", titles: ["A", "B", "C"])]
        let reply = #"```json {"clusters":[{"key":"nb:Mito","short":"Measuring ΔΨm in vivo","long":"PET and SPECT tracers; disputed."},{"key":"nb:Other","short":"x","long":"y"}]} ```"#
        let summaries = try KnowledgeMapSummaries.summaries(from: reply, asked: asked)
        #expect(Array(summaries.keys) == ["nb:Mito"])
        #expect(summaries["nb:Mito"]?.fingerprint == asked[0].fingerprint)
        #expect(try KnowledgeMapSummaries.caption(from: #"{"caption":"Two regions argue."}"#) == "Two regions argue.")
        #expect(throws: KnowledgeMapSummaries.ParseError.self) { try KnowledgeMapSummaries.caption(from: "no json") }
    }

    @Test("A notebook goes to the renderer with its sources and Docs, and the model reads its description, questions, notes and highlights")
    func notebookContent() {
        let now = Date()
        let a = StudioArticle(url: "https://example.com/a", title: "Heartbeats", sourceType: .paper, id: "a")
        let b = StudioArticle(url: "https://example.com/b", title: "Bats", sourceType: .article, id: "b")
        var notebook = LearningGoalRecord(
            id: "nb", title: "🧬 Lifespan Scaling Laws", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now, updatedAt: now, status: "active",
            items: [
                LearningGoalItem(id: "i1", goalID: "nb", sourceID: "a", addedAt: now),
                LearningGoalItem(id: "i2", goalID: "nb", sourceID: "b", addedAt: now),
                LearningGoalItem(id: "i3", goalID: "nb", sourceID: "gone", addedAt: now),
            ],
            kind: LearningGoalRecord.companionKind
        )
        notebook.summary = "Why bigger animals live longer."
        notebook.researchQuestions = ["Is the rate of living a cause?"]
        notebook.notes = "Quarter-power scaling holds across mammals."
        let doc = ArtifactRecord(id: "d", title: "Scaling notes", homeNotebookID: "nb", linkedNotebookIDs: [], sourceIDs: ["a"], createdAt: now, updatedAt: now)
        let content = KnowledgeMapModel.content(
            articles: [a, b], ideas: [], notebooks: [notebook], chats: [], artifacts: [doc], firstHighlights: [:]
        )
        let sent = try! #require(content.notebooks.first)
        #expect(sent.title == "Lifespan Scaling Laws", "named without its emoji")
        #expect(sent.summary == "Why bigger animals live longer.")
        #expect(sent.refs == ["source:a", "source:b", "doc:d"], "a source the Canvas has no card for is left out")

        let context = KnowledgeMapModel.notebookContext(notebook, firstHighlights: ["b": "bats outlive mice tenfold"])
        #expect(context.contains("Why bigger animals live longer."))
        #expect(context.contains("- Is the rate of living a cause?"))
        #expect(context.contains("Quarter-power scaling"))
        #expect(context.contains("- bats outlive mice tenfold"))
        var bare = notebook
        bare.summary = nil; bare.researchQuestions = nil; bare.notes = nil
        #expect(KnowledgeMapModel.notebookContext(bare, firstHighlights: [:]).isEmpty)
    }

    @Test("Takeaways are kept for a notebook's cluster only, at most four, and its context is part of what it was written from")
    func takeawaysParse() throws {
        let frame = KnowledgeMapSummaries.Cluster(key: "r:nb", name: "Lifespan", titles: ["A", "B", "C"], context: "Description: why")
        let plain = KnowledgeMapSummaries.Cluster(key: "r:plain", name: "Mine", titles: ["A", "B", "C"])
        #expect(frame.fingerprint != KnowledgeMapSummaries.Cluster(key: "r:nb", name: "Lifespan", titles: ["A", "B", "C"]).fingerprint)
        #expect(plain.fingerprint == "Mine" + "\u{1F}" + "A\u{1E}B\u{1E}C", "a region's fingerprint is unchanged, so its summary is not written again")
        let reply = #"{"clusters":[{"key":"r:nb","short":"s","long":"l","takeaways":["one"," two ","","three","four","five"]},{"key":"r:plain","short":"s","long":"l","takeaways":["invented"]}]}"#
        let summaries = try KnowledgeMapSummaries.summaries(from: reply, asked: [frame, plain])
        #expect(summaries["r:nb"]?.takeaways == ["one", "two", "three", "four"])
        #expect(summaries["r:plain"]?.takeaways == nil)
        #expect(KnowledgeMapSummaries.clustersMessage([frame]).contains(#""notebook":"Description: why""#))
        #expect(!KnowledgeMapSummaries.clustersMessage([plain]).contains("notebook"))
    }

    @Test("A region named as one notebook becomes its frame, and the frame's summary covers the notebook's unplaced cards")
    @MainActor
    func notebookFrames() {
        let suite = UserDefaults(suiteName: "KnowledgeMapContentTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let now = Date()
            let sources = (0..<4).map { StudioArticle(url: "https://example.com/\($0)", title: "Paper \($0)", sourceType: .paper, id: "s\($0)") }
            func notebook(_ id: String, _ title: String, _ items: [String]) -> LearningGoalRecord {
                LearningGoalRecord(
                    id: id, title: title, startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
                    createdAt: now, updatedAt: now, status: "active",
                    items: items.map { LearningGoalItem(id: id + $0, goalID: id, sourceID: $0, addedAt: now) },
                    kind: LearningGoalRecord.companionKind
                )
            }
            var scaling = notebook("nb", "Lifespan Scaling Laws", ["s0", "s1", "s2", "s3"])
            scaling.summary = "Why bigger animals live longer."
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(
                articles: sources, ideas: [],
                notebooks: [scaling, notebook("x", "Twins", []), notebook("y", "twins", [])],
                chats: [], artifacts: [], firstHighlights: [:]
            )
            model.saveRegion(id: "r1", name: "lifespan scaling laws ", x: -50, y: -90, w: 900, h: 400, color: "#7F77DD")
            model.saveRegion(id: "r2", name: "Twins", x: 2000, y: 0, w: 600, h: 400, color: "#7F77DD")
            model.saveRegion(id: "r3", name: "Mine", x: 4000, y: 0, w: 600, h: 400, color: "#7F77DD")
            model.place([(ref: "source:s0", x: 0, y: 0), (ref: "source:s1", x: 270, y: 0)])
            model.linkNotebookRegions()
            #expect(model.layout.regions["r1"]?.notebookID == "nb", "matched by name, ignoring case and spaces")
            #expect(model.layout.regions["r2"]?.notebookID == nil, "two notebooks of one name link neither")
            #expect(model.layout.regions["r3"]?.notebookID == nil)
            #expect(model.notebook(ofRegion: "r1")?.title == "Lifespan Scaling Laws")

            let cluster = model.clusters().first { $0.key == "r:r1" }
            #expect(cluster?.name == "Lifespan Scaling Laws")
            #expect(cluster.map { Set($0.titles) } == ["Paper 0", "Paper 1", "Paper 2", "Paper 3"], "its unplaced cards are drawn in it, so they are summarised")
            #expect(cluster?.context.contains("Why bigger animals live longer.") == true)

            // A frame the renderer made from a notebook drop keeps its notebook.
            model.saveRegion(id: "r4", name: "Lifespan Scaling Laws", x: 6000, y: 0, w: 600, h: 400, color: "#7F77DD", notebookID: "nb")
            #expect(model.layout.regions["r4"]?.notebookID == "nb")
            #expect(KnowledgeMapRows.layout(mapID: KnowledgeMap.firstCanvasID).regions["r1"]?.notebookID == "nb", "the link is written to the learner's row")
        }
    }

    @Test("A notebook's frame holds only its ticked sources: an unticked one is not drawn in it and, placed there, leaves it once")
    @MainActor
    func framesFollowTicks() {
        let suite = UserDefaults(suiteName: "KnowledgeMapContentTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let now = Date()
            let sources = (0..<5).map { StudioArticle(url: "https://example.com/\($0)", title: "Chapter \($0)", sourceType: .paper, id: "s\($0)") }
            let scaling = LearningGoalRecord(
                id: "nb", title: "Lifespan Scaling Laws", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
                createdAt: now, updatedAt: now, status: "active",
                items: ["s0", "s1", "s2", "s3"].map { LearningGoalItem(id: "nb" + $0, goalID: "nb", sourceID: $0, addedAt: now) },
                kind: LearningGoalRecord.companionKind
            )
            let unticked: [String: Set<String>] = ["nb": ["s2", "s3"]]
            let model = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            model.rebuildContent(articles: sources, ideas: [], notebooks: [scaling], chats: [], artifacts: [], firstHighlights: [:], unticked: unticked)
            #expect(model.content.notebooks.first?.refs == ["source:s0", "source:s1"], "an unticked source is not drawn in the frame")

            model.saveRegion(id: "frame", name: "Lifespan Scaling Laws", x: -50, y: -90, w: 900, h: 400, color: "#7F77DD", notebookID: "nb")
            model.place([
                (ref: "source:s0", x: 0, y: 0),
                (ref: "source:s2", x: 270, y: 0), // unticked, in its frame
                (ref: "source:s3", x: 3000, y: 0), // unticked, set down elsewhere
                (ref: "source:s4", x: 540, y: 0), // another notebook's, in this frame
            ])
            model.takeUntickedOffFrames(unticked)
            #expect(model.layout.placements["source:s2"] == nil, "taken off its notebook's frame")
            #expect(model.layout.placements["source:s3"] != nil, "a card outside the frame stays where the learner put it")
            #expect(model.layout.placements["source:s0"] != nil)
            #expect(model.layout.placements["source:s4"] != nil, "only the notebook's own unticked sources leave")

            // Set down in the frame again with the ticks unchanged, it stays.
            model.place([(ref: "source:s2", x: 270, y: 0)])
            model.takeUntickedOffFrames(unticked)
            #expect(model.layout.placements["source:s2"] != nil)
            // Unticking another one takes that one off too.
            model.place([(ref: "source:s1", x: 0, y: 150)])
            model.takeUntickedOffFrames(["nb": ["s1", "s2", "s3"]])
            #expect(model.layout.placements["source:s1"] == nil)
        }
    }

    @Test("Canvas Summaries is a task of its own: in Settings' list, counted as background work")
    func taskIsConfigurable() {
        #expect(AITaskSettingsCatalog.version >= 33)
        let task = AITask.mapSummaries
        #expect(task.rawValue == "map_summaries")
        #expect(task.displayName == "Canvas Summaries")
        #expect(task.isBackgroundWork)
        #expect(task.defaultPrompt == Prompts.mapSummaries)
        #expect(AIUsageTaskLabel.text(for: "map_summaries") == "Summarize Canvas")
    }
}

@Suite("Map: extending to another display")
struct KnowledgeMapDisplaysTests {
    typealias Displays = KnowledgeMapDisplays

    /// Where a world point draws on the desk (global points, y up) in a view
    /// at `frame` with `camera`.
    private func desk(_ x: Double, _ y: Double, camera: Displays.Camera, frame: CGRect) -> (x: Double, y: Double) {
        let localX = x * camera.scale + camera.ox
        let localY = y * camera.scale + camera.oy
        return (Double(frame.minX) + localX, Double(frame.maxY) - localY)
    }

    /// The world point a view shows at a local point (y down from its top).
    private func world(localX: Double, localY: Double, camera: Displays.Camera) -> (x: Double, y: Double) {
        ((localX - camera.ox) / camera.scale, (localY - camera.oy) / camera.scale)
    }

    @Test("The other display's side follows the arrangement: beside on one axis, else the axis its centre is further along")
    func sideFollowsArrangement() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(Displays.side(of: CGRect(x: 1512, y: -200, width: 2560, height: 1440), from: main) == .right)
        #expect(Displays.side(of: CGRect(x: -1920, y: 0, width: 1920, height: 1080), from: main) == .left)
        #expect(Displays.side(of: CGRect(x: -300, y: 982, width: 2560, height: 1440), from: main) == .above)
        #expect(Displays.side(of: CGRect(x: 200, y: -1080, width: 1920, height: 1080), from: main) == .below)
        // Diagonal: right of and above, but much further right than up.
        #expect(Displays.side(of: CGRect(x: 1512, y: 982, width: 2560, height: 300), from: main) == .right)
    }

    @Test("The extension goes to the nearest other display, and there is none with one display")
    func otherScreen() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let near = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let far = CGRect(x: 3432, y: 0, width: 1920, height: 1080)
        #expect(Displays.otherScreen(from: main, among: [far, main, near]) == near)
        #expect(Displays.otherScreen(from: main, among: [main]) == nil)
    }

    @Test("Display to the right: same zoom, the origin moved by the first viewport's width, so its left edge continues the first view's right edge")
    func rightContinuesTheRightEdge() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let secondary = CGRect(x: 1512, y: -300, width: 2560, height: 1415)
        let camera = Displays.Camera(scale: 0.5, ox: 120, oy: -40)
        let follow = Displays.secondaryCamera(following: camera, side: .right, primary: primary, secondary: secondary)
        #expect(follow.scale == camera.scale)
        #expect(follow.ox == camera.ox - 1512)
        // The world point on the first view's right edge is on the second's left edge…
        let edge = world(localX: 1512, localY: 300, camera: camera)
        #expect(abs(edge.x * follow.scale + follow.ox) < 1e-9)
        // …at the same height on the desk.
        let a = desk(edge.x, edge.y, camera: camera, frame: primary)
        let b = desk(edge.x, edge.y, camera: follow, frame: secondary)
        #expect(abs(a.y - b.y) < 1e-9)
    }

    @Test("Display to the left: the second view's right edge meets the first view's left edge, using the second view's width")
    func leftUsesTheSecondWidth() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let camera = Displays.Camera(scale: 1.2, ox: -300, oy: 50)
        let follow = Displays.secondaryCamera(following: camera, side: .left, primary: primary, secondary: secondary)
        let edge = world(localX: 0, localY: 100, camera: camera)
        #expect(abs((edge.x * follow.scale + follow.ox) - 1920) < 1e-9)
        #expect(abs(desk(edge.x, edge.y, camera: camera, frame: primary).y - desk(edge.x, edge.y, camera: follow, frame: secondary).y) < 1e-9)
    }

    @Test("Displays stacked: below moves the origin up by the first view's height, above down by the second's, and columns line up across")
    func stackedDisplays() {
        let primary = CGRect(x: 100, y: 0, width: 1512, height: 900)
        let camera = Displays.Camera(scale: 0.25, ox: 10, oy: 20)

        let below = CGRect(x: -200, y: -1080, width: 1920, height: 1055)
        let under = Displays.secondaryCamera(following: camera, side: .below, primary: primary, secondary: below)
        let bottom = world(localX: 700, localY: 900, camera: camera)
        #expect(abs(bottom.y * under.scale + under.oy) < 1e-9)
        #expect(abs(desk(bottom.x, bottom.y, camera: camera, frame: primary).x - desk(bottom.x, bottom.y, camera: under, frame: below).x) < 1e-9)

        let above = CGRect(x: 0, y: 900, width: 2560, height: 1415)
        let over = Displays.secondaryCamera(following: camera, side: .above, primary: primary, secondary: above)
        let top = world(localX: 700, localY: 0, camera: camera)
        #expect(abs((top.y * over.scale + over.oy) - 1415) < 1e-9)
        #expect(abs(desk(top.x, top.y, camera: camera, frame: primary).x - desk(top.x, top.y, camera: over, frame: above).x) < 1e-9)
    }

    @Test("Either window can lead: following back from the second window gives the first camera exactly")
    func roundTrip() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let frames: [Displays.Side: CGRect] = [
            .right: CGRect(x: 1600, y: -120, width: 2560, height: 1415),
            .left: CGRect(x: -1920, y: 30, width: 1920, height: 1055),
            .above: CGRect(x: -400, y: 982, width: 2560, height: 1415),
            .below: CGRect(x: 300, y: -1080, width: 1920, height: 1055),
        ]
        let camera = Displays.Camera(scale: 0.375, ox: -812.5, oy: 233.25)
        for side in Displays.Side.allCases {
            let secondary = frames[side]!
            let follow = Displays.secondaryCamera(following: camera, side: side, primary: primary, secondary: secondary)
            #expect(Displays.primaryCamera(following: follow, side: side, primary: primary, secondary: secondary) == camera)
            #expect(side.opposite.opposite == side)
        }
    }

    @Test("The desk between the two views is the gap a dragged card skips, and never negative")
    func gapBetweenViews() {
        let primary = CGRect(x: 100, y: 100, width: 1200, height: 800)
        #expect(Displays.gap(side: .right, primary: primary, secondary: CGRect(x: 1512, y: 0, width: 1920, height: 1080)) == 212)
        #expect(Displays.gap(side: .left, primary: primary, secondary: CGRect(x: -1920, y: 0, width: 1920, height: 1080)) == 100)
        #expect(Displays.gap(side: .above, primary: primary, secondary: CGRect(x: 0, y: 982, width: 1920, height: 1080)) == 82)
        #expect(Displays.gap(side: .below, primary: primary, secondary: CGRect(x: 0, y: -1080, width: 1920, height: 1055)) == 125)
        #expect(Displays.gap(side: .right, primary: primary, secondary: CGRect(x: 1000, y: 0, width: 1920, height: 1080)) == 0)
    }
}

@Suite("Map: a topic's concepts in context")
struct KnowledgeMapConceptLensTests {
    private func concept(_ label: String, _ ids: [String] = []) -> KnowledgeMapLensRequest.Concept {
        .init(label: label, note: "What \(label) is.", items: ids.map { KnowledgeMap.ItemRef(kind: .source, id: $0) })
    }

    private func pinkParkin() -> KnowledgeMapLensRequest {
        var request = KnowledgeMapLensRequest(title: "PINK1–Parkin axis", layout: .concepts)
        request.concepts = [
            concept("Mitophagy", ["m1", "m2"]),
            concept("PINK1 builds up", ["p1", "p2", "p3", "p4"]),
            concept("Parkin recruited", ["k1"]),
            concept("Ubiquitin marks", []),
        ]
        request.conceptLinks = [
            .init(from: "PINK1 builds up", to: "Parkin recruited", label: "phosphorylates"),
            .init(from: "parkin recruited", to: "Ubiquitin marks", label: "builds"),
            .init(from: "Ubiquitin marks", to: "Mitophagy", label: "signals"),
        ]
        return request
    }

    @Test("Concepts run left to right in the order their links run, whatever order they were listed in")
    func columnsFollowLinks() {
        let lens = KnowledgeMapLens.laidOut(pinkParkin(), center: (0, 0), height: { _ in KnowledgeMap.cardHeight }) { _ in true }
        let x = Dictionary(uniqueKeysWithValues: lens.frames.map { ($0.label, $0.x) })
        #expect(x["PINK1 builds up"]! < x["Parkin recruited"]!)
        #expect(x["Parkin recruited"]! < x["Ubiquitin marks"]!)
        #expect(x["Ubiquitin marks"]! < x["Mitophagy"]!)
        #expect(lens.links.count == 3, "labels match whatever their case")
        #expect(lens.links.map(\.label) == ["phosphorylates", "builds", "signals"])
        #expect(lens.frames.first { $0.label == "Mitophagy" }?.note == "What Mitophagy is.")
    }

    @Test("Each paper sits inside its concept's frame, below its name; a concept with no papers still shows")
    func papersInsideTheirConcept() {
        let lens = KnowledgeMapLens.laidOut(pinkParkin(), center: (0, 0), height: { _ in KnowledgeMap.cardHeight }) { _ in true }
        #expect(lens.positions.count == 7)
        let pink = lens.frames.first { $0.label == "PINK1 builds up" }!
        for id in ["p1", "p2", "p3", "p4"] {
            let spot = lens.positions["source:\(id)"]!
            #expect(spot.x >= pink.x && spot.x + KnowledgeMap.cardWidth <= pink.x + pink.w)
            #expect(spot.y >= pink.y + KnowledgeMapLens.conceptHeader - 1 && spot.y + KnowledgeMap.cardHeight <= pink.y + pink.h)
        }
        let empty = lens.frames.first { $0.label == "Ubiquitin marks" }!
        #expect(empty.h == KnowledgeMapLens.conceptHeader)
    }

    @Test("Concepts in one column stack without overlapping, and a loop neither hangs nor moves a concept right forever")
    func branchesAndLoops() {
        var request = KnowledgeMapLensRequest(title: "Branch", layout: .concepts)
        request.concepts = [concept("A", ["a"]), concept("B", ["b1", "b2"]), concept("C", ["c"])]
        request.conceptLinks = [.init(from: "A", to: "B", label: ""), .init(from: "A", to: "C", label: ""), .init(from: "C", to: "A", label: "feeds back")]
        let lens = KnowledgeMapLens.laidOut(request, center: (0, 0), height: { _ in KnowledgeMap.cardHeight }) { _ in true }
        let b = lens.frames.first { $0.label == "B" }!, c = lens.frames.first { $0.label == "C" }!, a = lens.frames.first { $0.label == "A" }!
        #expect(a.x < b.x && b.x + b.w / 2 == c.x + c.w / 2, "B and C share the column after A")
        #expect(b.y + b.h <= c.y || c.y + c.h <= b.y)
        #expect(lens.links.count == 3, "the loop's link is still drawn")
        #expect(KnowledgeMapLens.conceptColumns(count: 3, links: [(0, 1), (1, 2), (2, 0)]) == [0, 1, 2])
    }

    @Test("A card the library no longer holds is dropped, a card named twice shows under its first concept, and a repeated concept is merged")
    func unknownAndRepeated() {
        var request = KnowledgeMapLensRequest(title: "Dupes", layout: .concepts)
        request.concepts = [concept("A", ["x", "gone"]), concept("B", ["x", "y"]), concept("a", ["z"])]
        let lens = KnowledgeMapLens.laidOut(request, center: (0, 0), height: { _ in KnowledgeMap.cardHeight }) { $0.id != "gone" }
        #expect(lens.frames.map(\.label) == ["A", "B"])
        #expect(Set(lens.positions.keys) == ["source:x", "source:y"])
        let a = lens.frames[0]
        #expect(lens.positions["source:x"]!.x >= a.x && lens.positions["source:x"]!.x < a.x + a.w)
        #expect(request.items.count == 5)
    }
}

// MARK: - The Heptabase parity build (2026-10-09): the model and the stored fields

/// docs/knowledge-map-design.md, "Heptabase parity build (2026-10-09): the
/// contract": what a placement, a region and an arrow carry, and how a row
/// from before reads.
@Suite("Map: the parity build's stored fields")
struct KnowledgeMapParityFieldsTests {
    private static let oldRow = ##"{"edges":{"e1":{"at":4,"from":"source:a","label":"x","to":"source:b"}},"placements":{"source:a":{"at":3,"x":1,"y":2},"source:b":{"at":3,"x":300,"y":2}},"regions":{"r1":{"at":5,"color":"#7F77DD","h":200,"name":"A","w":300,"x":0,"y":0}},"removed":{},"version":1}"##

    @Test("A row from before the parity build reads with every new field empty, and writes none of them back")
    func oldRowsRoundTrip() throws {
        let row = try #require(KnowledgeMapLayout(preferenceValue: Self.oldRow))
        let spot = try #require(row.placements["source:a"])
        #expect(spot.w == nil && spot.h == nil && spot.folded == nil && spot.color == nil && !spot.isFolded)
        let region = try #require(row.regions["r1"])
        #expect(region.locked == nil && region.layout == nil && !region.isLocked && !region.isTree)
        let edge = try #require(row.edges["e1"])
        #expect(edge.route == nil && edge.dashed == nil && edge.heads == nil && edge.color == nil && edge.tree == nil)
        #expect(!edge.isTree && !edge.isDashed)
        #expect(row.preferenceValue == Self.oldRow, "sorted keys, and no new key for an empty field")
    }

    @Test("The new fields decode, round-trip, and an arrow may end at a region")
    func newFieldsRoundTrip() throws {
        let styled = ##"{"edges":{"e1":{"at":4,"color":"#1D9E75","dashed":true,"from":"region:r1","heads":"both","label":"","route":"elbow","to":"source:a","tree":false}},"placements":{"source:a":{"at":3,"color":"#D4537E","folded":true,"h":90,"w":360,"x":1,"y":2}},"regions":{"r1":{"at":5,"color":"#7F77DD","h":200,"layout":"tree","locked":true,"name":"A","w":300,"x":0,"y":0}},"removed":{},"version":1}"##
        let row = try #require(KnowledgeMapLayout(preferenceValue: styled))
        #expect(row.placements["source:a"]?.w == 360 && row.placements["source:a"]?.h == 90)
        #expect(row.placements["source:a"]?.isFolded == true && row.placements["source:a"]?.color == "#D4537E")
        #expect(row.regions["r1"]?.isLocked == true && row.regions["r1"]?.isTree == true)
        #expect(row.edges["e1"]?.route == "elbow" && row.edges["e1"]?.heads == "both" && row.edges["e1"]?.isDashed == true)
        #expect(row.edges["e1"]?.color == "#1D9E75" && row.edges["e1"]?.isTree == false)
        #expect(KnowledgeMapLayout(preferenceValue: row.preferenceValue) == row)
        #expect(row.edgesTouching(region: "r1") == ["e1"])
        #expect(row.edgesTouching(region: "r2").isEmpty)
    }

    @Test("Each entry merges newer-wins as a whole, so a restyled card and a moved card keep the newer write")
    func mergeIsNewerWinsPerEntry() {
        var base = KnowledgeMapLayout()
        base.place("source:a", x: 0, y: 0, at: 1)
        base.setRegion("r", .init(name: "R", x: 0, y: 0, w: 500, h: 400, color: "#7F77DD", at: 1))
        base.setEdge("e", .init(from: "source:a", to: "region:r", label: "", at: 1))

        var restyled = base
        var placement = restyled.placements["source:a"]!
        placement.w = 400; placement.color = "#D4537E"; placement.at = 10
        restyled.setPlacement("source:a", placement)
        var locked = restyled
        locked.regions["r"]?.locked = true; locked.regions["r"]?.layout = "tree"; locked.regions["r"]?.at = 10
        var dashed = locked
        dashed.edges["e"]?.dashed = true; dashed.edges["e"]?.route = "straight"; dashed.edges["e"]?.at = 10

        var moved = base
        moved.place("source:a", x: 9, y: 9, at: 5)
        let merged = moved.merged(with: dashed)
        #expect(merged == dashed.merged(with: moved), "whichever Mac merges first")
        #expect(merged.placements["source:a"]?.w == 400, "the newer write, the restyle, wins the entry")
        #expect(merged.regions["r"]?.isLocked == true && merged.regions["r"]?.isTree == true)
        #expect(merged.edges["e"]?.route == "straight")

        var movedLater = base
        movedLater.place("source:a", x: 9, y: 9, at: 20)
        #expect(movedLater.merged(with: dashed).placements["source:a"]?.x == 9, "a later move wins the whole entry")
    }

    @Test("Moving a card keeps its size, fold and colour; taking it off forgets them")
    func placeKeepsStyle() {
        var layout = KnowledgeMapLayout()
        layout.place("idea:a", x: 0, y: 0, at: 1)
        var placement = layout.placements["idea:a"]!
        placement.w = 400; placement.h = 90; placement.folded = true; placement.color = "#1D9E75"
        layout.setPlacement("idea:a", placement)
        layout.place("idea:a", x: 50, y: 60, at: 2)
        #expect(layout.placements["idea:a"]?.x == 50 && layout.placements["idea:a"]?.w == 400)
        #expect(layout.placements["idea:a"]?.folded == true && layout.placements["idea:a"]?.color == "#1D9E75")
        layout.unplace("idea:a", at: 3)
        layout.place("idea:a", x: 0, y: 0, at: 4)
        #expect(layout.placements["idea:a"]?.w == nil && layout.placements["idea:a"]?.color == nil)
    }

    @Test("An arrow to a region survives its cards leaving and goes with the region")
    func regionArrows() {
        var layout = KnowledgeMapLayout()
        layout.place("source:in", x: 100, y: 100, at: 1)
        layout.place("source:out", x: 2000, y: 100, at: 1)
        layout.setRegion("r", .init(name: "R", x: 0, y: 0, w: 600, h: 400, color: "#7F77DD", at: 1))
        layout.setEdge("toRegion", .init(from: "source:out", to: "region:r", label: "", at: 1))
        layout.setEdge("cards", .init(from: "source:out", to: "source:in", label: "", at: 1))
        layout.unplace("source:in", at: 2)
        #expect(layout.edges["toRegion"] != nil, "its cards leaving does not end the arrow to its region")
        #expect(layout.edges["cards"] == nil, "an arrow to a card that left goes, as before")
        layout.removeRegion("r", at: 3)
        #expect(layout.edges.isEmpty)
        #expect(layout.removed["e:toRegion"] == 3, "tombstoned, so another Mac's copy goes too")
    }

    @Test("A branch's parent and children read from the tree edges, children top to bottom as they sit")
    func treeHelpers() {
        var layout = KnowledgeMapLayout()
        for (ref, y) in [("idea:root", 0.0), ("idea:b", 300.0), ("idea:a", 100.0), ("idea:c", 500.0)] {
            layout.place(ref, x: 0, y: y, at: 1)
        }
        layout.setEdge("e1", .init(from: "idea:root", to: "idea:b", label: "", at: 1, tree: true))
        layout.setEdge("e2", .init(from: "idea:root", to: "idea:a", label: "", at: 2, tree: true))
        layout.setEdge("e3", .init(from: "idea:root", to: "idea:c", label: "", at: 3))
        #expect(layout.treeChildren(of: "idea:root") == ["idea:a", "idea:b"], "by where they sit; a plain arrow is no branch")
        #expect(layout.treeParent(of: "idea:a") == "idea:root")
        #expect(layout.treeParent(of: "idea:c") == nil)
        #expect(layout.treeParent(of: "idea:root") == nil)
        #expect(layout.treeChildren(of: "idea:a").isEmpty)
        layout.setEdge("e4", .init(from: "region:r", to: "idea:c", label: "", at: 4, tree: true))
        #expect(layout.treeParent(of: "idea:c") == nil, "a region is never a branch's parent")
    }

    @Test("Display switches: the minimap is this Mac's and survives a new model; Focus is never stored")
    @MainActor
    func displaySwitches() {
        let suite = UserDefaults(suiteName: "KnowledgeMapParityFieldsTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: "cnv-x")
            #expect(!model.showsMinimap && !model.focusMode)
            let revision = model.displayRevision
            model.showsMinimap = true
            model.focusMode = true
            #expect(model.displayRevision == revision + 2)
            #expect(suite.bool(forKey: "knowledgeMap.minimap.v1"))
            #expect(suite.object(forKey: "knowledgeMap.focus.v1") == nil)
            let again = KnowledgeMapModel(mapID: "cnv-y")
            #expect(again.showsMinimap && !again.focusMode)
            model.showsMinimap = false
            #expect(!suite.bool(forKey: "knowledgeMap.minimap.v1"))
        }
    }

    @Test("The viewport carries the camera's zoom and whether nothing is in view")
    func viewportScale() {
        var view = KnowledgeMapViewport()
        #expect(view.scale == 1 && !view.empty)
        var other = view
        other.scale = 0.4
        #expect(view != other)
        other = view
        other.empty = true
        #expect(view != other)
    }

    @Test("Chats, other canvases and pictures are cards: their names, what they hold and where they wait")
    func newKindsAreCards() {
        let now = Date()
        let notebook = LearningGoalRecord(
            id: "nb", title: "Mito Phenotyping", startAt: now, endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: now, updatedAt: now, status: "active", items: [], kind: LearningGoalRecord.companionKind
        )
        var chat = ReviewSessionRecord(id: "c1", title: "The PINK1 question", createdAt: now, status: "active", sourceIDs: [], goalID: "nb")
        chat.summary = "Why PINK1 builds up on depolarised mitochondria.\nMore lines."
        let plain = ReviewSessionRecord(id: "c2", title: "  ", createdAt: now, status: "completed", sourceIDs: [])
        let hidden = ReviewSessionRecord(id: "c3", title: "Hidden", createdAt: now, status: "active", sourceIDs: [], hiddenAt: now)
        let team = ReviewSessionRecord(id: "c4", title: "Shared", createdAt: now, status: "completed", sourceIDs: [], teamID: "t")
        let link = ReviewSessionRecord(id: "c5", title: "A link", url: "https://example.com/chat", createdAt: now, status: "external_link", sourceIDs: [])
        let canvas = KnowledgeMapCanvas(id: "cnv-1", name: "Parkinson's", createdAt: now, updatedAt: now, notebookID: "nb", cardCount: 12, regionCount: 1)
        let trashed = KnowledgeMapCanvas(id: "cnv-2", name: "Old", createdAt: now, updatedAt: now, trashedAt: now)
        let picture = KnowledgeMapPictureCard(imageID: "AAAA", title: "Electron transport chain", aspect: 0.5, path: "/tmp/a.png")
        let nodes = KnowledgeMapModel.shortcutNodes(
            chats: [chat, plain, hidden, team, link], canvases: [canvas, trashed], pictures: [picture],
            notebookTitles: [notebook.id: NotebookTitle(notebook.title).text]
        )
        #expect(nodes.map(\.ref) == ["chat:c1", "chat:c2", "canvas:cnv-1", "picture:AAAA"])
        // The library's content carries them after the Ideas.
        let content = KnowledgeMapModel.content(
            articles: [], ideas: [], notebooks: [notebook], chats: [chat, plain, hidden, team, link], artifacts: [],
            firstHighlights: [:], canvases: [canvas, trashed], pictures: [picture]
        )
        #expect(content.nodes == nodes)
        let first = nodes[0]
        #expect(first.kind == "chat" && first.type == "chat" && first.title == "The PINK1 question")
        #expect(first.sub == "Why PINK1 builds up on depolarised mitochondria." && first.shore == "Mito Phenotyping")
        #expect(nodes[1].title == "Untitled chat" && nodes[1].shore == "Chats")
        #expect(!nodes[1].sub.isEmpty, "a chat with no summary says the day it began")
        let shortcut = nodes[2]
        #expect(shortcut.kind == "canvas" && shortcut.type == "canvas" && shortcut.title == "Parkinson's")
        #expect(shortcut.sub == "12 cards · 1 region" && shortcut.shore == "Mito Phenotyping")
        let card = nodes[3]
        #expect(card.kind == "picture" && card.type == "picture" && card.title == "Electron transport chain")
        #expect(card.h == KnowledgeMap.pictureHeight(aspect: 0.5) && card.h == 420, "as tall as its picture at the card's width, held to 420")
        #expect(KnowledgeMap.pictureHeight(aspect: 8) == 70 && KnowledgeMap.pictureHeight(aspect: nil) == 160)
    }

    @Test("A canvas holds no shortcut to itself, and a picture is as tall as its shape")
    @MainActor
    func rebuildSkipsTheOpenCanvas() {
        let suite = UserDefaults(suiteName: "KnowledgeMapParityFieldsTests.\(UUID().uuidString)")!
        KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let model = KnowledgeMapModel(mapID: "cnv-1")
            let now = Date()
            let here = KnowledgeMapCanvas(id: "cnv-1", name: "Here", createdAt: now, updatedAt: now)
            let there = KnowledgeMapCanvas(id: "cnv-2", name: "There", createdAt: now, updatedAt: now)
            let picture = KnowledgeMapPictureCard(imageID: "BBBB", title: "Wide", aspect: 2, path: nil)
            model.rebuildContent(
                articles: [], ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:],
                canvases: [here, there], pictures: [picture]
            )
            #expect(model.content.nodes.map(\.ref) == ["canvas:cnv-2", "picture:BBBB"])
            #expect(model.cardHeight(of: "picture:BBBB") == KnowledgeMap.pictureHeight(aspect: 2))
            #expect(model.cardHeight(of: "canvas:cnv-2") == KnowledgeMap.cardHeight)
        }
    }
}

/// The model's writes for a card's look, an arrow's look and a region's lock,
/// fit, grow and layout: each an Undo step, none a write for nothing.
@Suite("Map: card, arrow and region edits (the parity build)")
@MainActor
struct KnowledgeMapParityModelTests {
    private func withModel(_ body: (KnowledgeMapModel) throws -> Void) rethrows {
        let suite = UserDefaults(suiteName: "KnowledgeMapParityModelTests.\(UUID().uuidString)")!
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            try body(KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID))
        }
    }

    private func apart() { Thread.sleep(forTimeInterval: KnowledgeMapModel.editBurst + 0.05) }

    @Test("Style edits keep, clear or set each field, are bounded, skip cards not placed, and are one Undo step that gives the old look back")
    func placementStyle() {
        withModel { model in
            model.place([(ref: "idea:a", x: 0, y: 0), (ref: "idea:b", x: 300, y: 0)])
            apart()
            let changed = model.setPlacementStyle([
                .init(ref: "idea:a", w: .set(5000), h: .set(10), folded: .set(true), color: .set("#d4537e")),
                .init(ref: "idea:b", w: .set(360)),
                .init(ref: "idea:ghost", w: .set(360)),
            ])
            #expect(changed == 2)
            let a = model.layout.placements["idea:a"]!
            #expect(a.w == 720 && a.h == 40, "held to what a card may be")
            #expect(a.folded == true && a.color == "#D4537E")
            #expect(model.layout.placements["idea:b"]?.w == 360)
            #expect(model.cardWidth(of: "idea:a") == 720 && model.cardHeight(of: "idea:a") == KnowledgeMap.foldedCardHeight)
            #expect(model.cardHeight(of: "idea:b") == KnowledgeMap.cardHeight && model.cardWidth(of: "idea:b") == 360)
            apart()
            #expect(model.setPlacementStyle([.init(ref: "idea:a", w: .keep, h: .keep, folded: .keep, color: .keep)]) == 0)
            #expect(model.setPlacementStyle([.init(ref: "idea:a", w: .set(720))]) == 0, "the same value is no write")

            #expect(model.setCardFolded(["idea:a"], false) == 1)
            #expect(model.layout.placements["idea:a"]?.folded == nil, "unfolded is stored as nothing")
            #expect(model.setCardColor(["idea:a", "idea:b"], nil) == 1)
            #expect(model.layout.placements["idea:a"]?.color == nil)
            #expect(model.fitCardsToContent(["idea:a", "idea:b"]) == 2)
            #expect(model.layout.placements["idea:a"]?.w == nil && model.layout.placements["idea:a"]?.h == nil)
            #expect(model.layout.placements["idea:b"]?.w == nil)

            model.undo()
            #expect(model.layout.placements["idea:a"]?.w == 720 && model.layout.placements["idea:b"]?.w == 360, "the burst of three is one step")
            model.undo()
            #expect(model.layout.placements["idea:a"]?.w == nil && model.layout.placements["idea:b"]?.w == nil, "the restyle is taken back")
            #expect(model.layout.placements["idea:b"]?.x == 300, "and the card is where it was")
        }
    }

    @Test("A card the learner sized is held by its own middle, and a region grows to hold a card that was made wider")
    func sizedCards() {
        withModel { model in
            model.saveRegion(id: "r", name: "R", x: 0, y: 0, w: 500, h: 400, color: "#7F77DD")
            model.place([(ref: "idea:a", x: 300, y: 100), (ref: "idea:t", x: 50, y: 50)])
            #expect(model.regionID(containing: "idea:a") == "r", "its usual middle, x 420, is inside")
            #expect(model.setCardSize("idea:a", w: 400, h: nil))
            #expect(model.regionID(containing: "idea:a") == "r", "its middle is now x 500, on the edge: still inside")
            #expect(model.layout.regions["r"]!.w == 300 + 400 + 24, "the region grew to hold it, with 24 to spare")
            #expect(!model.setCardSize("idea:ghost", w: 400, h: nil))
            #expect(!model.setCardSize("idea:a", w: nil, h: nil))
            #expect(model.cardWidth(of: "idea:a") == 400)
            // A tall card is held by the middle of its height.
            #expect(model.regionID(containing: "idea:t") == "r")
            #expect(model.setCardSize("idea:t", w: nil, h: 1000))
            #expect(model.regionID(containing: "idea:t") == nil, "its middle, y 550, is under the region")
            #expect(model.cardHeight(of: "idea:t") == 1000)
        }
    }

    @Test("Arrows end at cards or regions; a card is not joined to its own region; the look is stored sparsely")
    func arrowsAndRegions() throws {
        try withModel { model in
            model.saveRegion(id: "r", name: "R", x: 0, y: 0, w: 600, h: 400, color: "#7F77DD")
            model.saveRegion(id: "inner", name: "Inner", x: 20, y: 20, w: 200, h: 150, color: "#1D9E75")
            model.place([(ref: "source:in", x: 100, y: 100), (ref: "source:out", x: 2000, y: 100)])
            #expect(model.addEdge(from: "source:in", to: "region:r", label: "") == nil, "a card in a region is not joined to it")
            #expect(model.addEdge(from: "region:r", to: "source:in", label: "") == nil)
            #expect(model.addEdge(from: "region:inner", to: "region:r", label: "") == nil, "nor a region to the one around it")
            #expect(model.addEdge(from: "region:r", to: "region:r", label: "") == nil)
            #expect(model.addEdge(from: "source:out", to: "region:nowhere", label: "") == nil)
            #expect(model.addEdge(from: "source:out", to: "source:unplaced", label: "") == nil)
            #expect(model.addEdge(from: "source:out", to: "region:r", label: "", route: "zigzag") == nil)
            let id = try #require(model.addEdge(from: "source:out", to: "region:r", label: " enters ", route: "elbow", dashed: true, heads: "both", color: "#1d9e75"))
            let edge = model.layout.edges[id]!
            #expect(edge.label == "enters" && edge.route == "elbow" && edge.dashed == true && edge.heads == "both" && edge.color == "#1D9E75")
            #expect(model.addEdge(from: "source:out", to: "region:r", label: "again") == id, "the arrow already drawn is the one returned")
            #expect(model.layout.edges[id]?.route == "elbow", "and keeps its look")

            apart()
            #expect(model.updateEdgeStyle(id, route: "curve", dashed: false, heads: "end", color: ""))
            #expect(model.layout.edges[id]!.route == nil && model.layout.edges[id]!.dashed == nil && model.layout.edges[id]!.heads == nil && model.layout.edges[id]!.color == nil)
            #expect(!model.updateEdgeStyle(id, route: "curve"), "nothing changes")
            #expect(!model.updateEdgeStyle(id, route: "wavy"))
            #expect(!model.updateEdgeStyle("nope", route: "straight"))
            #expect(model.updateEdgeStyle(id, route: "straight", label: " via "))
            #expect(model.layout.edges[id]?.route == "straight" && model.layout.edges[id]?.label == "via")

            apart()
            model.unplace(["source:in"])
            #expect(model.layout.edges[id] != nil, "the arrow to the region outlives its cards")
            apart()
            model.deleteRegion("r")
            #expect(model.layout.edges[id] == nil, "and goes with the region")
            model.undo()
            #expect(model.layout.regions["r"] != nil && model.layout.edges[id] != nil, "Undo brings both back")
        }
    }

    @Test("Deleting a region with its cards takes everything inside it, regions inside it too, in one Undo step; Keep Cards takes only the frame")
    func deleteRegionWithEverythingInside() {
        withModel { model in
            model.saveRegion(id: "r", name: "Framing", x: 0, y: 0, w: 1000, h: 800, color: "#7F77DD")
            model.saveRegion(id: "inner", name: "Physics", x: 20, y: 20, w: 400, h: 300, color: "#1D9E75")
            model.saveRegion(id: "beside", name: "Beside", x: 2000, y: 0, w: 400, h: 300, color: "#1D9E75")
            model.place([(ref: "idea:a", x: 60, y: 60), (ref: "source:b", x: 600, y: 500), (ref: "source:out", x: 2050, y: 50)])
            model.selectedRegionID = "inner"

            apart()
            model.deleteRegion("r", takingCardsOff: true)
            #expect(model.layout.regions["r"] == nil && model.layout.regions["inner"] == nil, "the region inside it goes too")
            #expect(model.layout.placements["idea:a"] == nil && model.layout.placements["source:b"] == nil)
            #expect(model.layout.regions["beside"] != nil && model.layout.placements["source:out"] != nil, "what is outside it stays")
            #expect(model.selectedRegionID == nil, "a region that went is not left selected")

            model.undo()
            #expect(model.layout.regions["r"] != nil && model.layout.regions["inner"] != nil)
            #expect(model.layout.placements["idea:a"] != nil && model.layout.placements["source:b"] != nil, "one Undo brings it all back")

            apart()
            model.deleteRegion("r")
            #expect(model.layout.regions["r"] == nil)
            #expect(model.layout.regions["inner"] != nil && model.layout.placements["idea:a"] != nil, "Keep Cards leaves what was inside")
        }
    }

    @Test("A branch joins two cards, a card has one parent, and a tree has no loop")
    func branchRules() throws {
        try withModel { model in
            model.saveRegion(id: "r", name: "R", x: 0, y: 0, w: 900, h: 400, color: "#7F77DD")
            model.place([(ref: "idea:a", x: 50, y: 60), (ref: "idea:b", x: 350, y: 60), (ref: "idea:c", x: 650, y: 60), (ref: "idea:z", x: 5000, y: 0)])
            #expect(model.addEdge(from: "idea:a", to: "idea:b", label: "", tree: true) != nil)
            #expect(model.addEdge(from: "idea:b", to: "idea:c", label: "", tree: true) != nil)
            #expect(model.addEdge(from: "idea:c", to: "idea:a", label: "", tree: true) == nil, "a loop")
            #expect(model.addEdge(from: "idea:z", to: "idea:c", label: "", tree: true) == nil, "c has a parent")
            #expect(model.addEdge(from: "idea:z", to: "region:r", label: "", tree: true) == nil, "a branch joins cards")
            #expect(model.addEdge(from: "idea:c", to: "idea:a", label: "") != nil, "a plain arrow may close a loop")
            #expect(model.treeParent(of: "idea:b") == "idea:a" && model.treeChildren(of: "idea:b") == ["idea:c"])
            let plain = model.layout.edges.first { $0.value.from == "idea:c" && $0.value.to == "idea:a" }!.key
            #expect(!model.updateEdgeStyle(plain, tree: true), "making it a branch would close the loop")
            let spare = try #require(model.addEdge(from: "idea:z", to: "idea:a", label: ""))
            #expect(model.updateEdgeStyle(spare, tree: true), "a root may gain a parent")
            #expect(!model.updateEdgeStyle(spare, tree: true), "already one")
            #expect(model.updateEdgeStyle(spare, tree: false) && model.layout.edges[spare]?.tree == nil)
        }
    }

    @Test("Lock, fit to content and grow to hold change a region in one step each, and fit never goes below 200 by 120")
    func regionGeometry() {
        withModel { model in
            model.saveRegion(id: "r", name: "R", x: 0, y: 0, w: 2000, h: 1000, color: "#7F77DD")
            model.place([(ref: "source:a", x: 500, y: 400), (ref: "source:b", x: 800, y: 500)])
            #expect(model.setRegionLocked("r", true) && model.layout.regions["r"]?.isLocked == true)
            #expect(!model.setRegionLocked("r", true))
            #expect(model.setRegionLocked("r", false) && model.layout.regions["r"]?.locked == nil)
            #expect(!model.setRegionLocked("nope", true))

            #expect(model.fitRegionToContent("r"))
            let fitted = model.layout.regions["r"]!
            #expect(fitted.x == 450 && fitted.y == 340, "50 left of the first card, 60 above it for the name")
            #expect(fitted.w == 540 + 100 && fitted.h == 220 + 60 + 50)
            #expect(!model.fitRegionToContent("r"), "already fitted")

            model.saveRegion(id: "empty", name: "Empty", x: 3000, y: 0, w: 900, h: 400, color: "#1D9E75")
            #expect(model.fitRegionToContent("empty"))
            #expect(model.layout.regions["empty"]?.w == 200 && model.layout.regions["empty"]?.h == 120 && model.layout.regions["empty"]?.x == 3000)

            model.saveRegion(id: "small", name: "Small", x: 0, y: 2000, w: 300, h: 200, color: "#D85A30")
            model.place([(ref: "source:c", x: 400, y: 2300)])
            #expect(model.growRegion("small", toHold: ["source:c", "source:ghost"]))
            let grown = model.layout.regions["small"]!
            #expect(grown.x == 0 && grown.y == 2000, "a region only grows right and down here, never moves")
            #expect(grown.w == 400 + 240 + 24 && grown.h == 2300 + 120 + 24 - 2000, "the card's far edges, and 24 more")
            #expect(!model.growRegion("small", toHold: ["source:c"]), "already holds it")
        }
    }

    @Test("A region the renderer moves or resizes keeps its lock, its layout and its fold")
    func renderedRegionKeepsItsMarks() {
        withModel { model in
            model.saveRegion(id: "r", name: "R", x: 0, y: 0, w: 900, h: 400, color: "#7F77DD")
            model.setRegionLocked("r", true)
            model.setRegionLayout("r", "tree")
            model.setRegionCollapsed("r", true)
            model.saveRegion(id: "r", name: "R", x: 40, y: 50, w: 1000, h: 500, color: "#7F77DD")
            let region = model.layout.regions["r"]
            #expect(region?.x == 40 && region?.w == 1000)
            #expect(region?.isLocked == true && region?.isTree == true && region?.isCollapsed == true)
        }
    }

    @Test("Turning a region into a tree lays its cards out once from the tree edges; turning it free leaves them; arrows come back as arrows")
    func treeRegion() {
        withModel { model in
            model.saveRegion(id: "r", name: "Ideas", x: 0, y: 0, w: 2000, h: 1000, color: "#7F77DD")
            model.place([(ref: "idea:root", x: 700, y: 500), (ref: "idea:k1", x: 100, y: 100), (ref: "idea:k2", x: 100, y: 800)])
            #expect(model.addEdge(from: "idea:root", to: "idea:k1", label: "", tree: true) != nil)
            #expect(model.addEdge(from: "idea:root", to: "idea:k2", label: "", tree: true) != nil)
            #expect(model.treeChildren(of: "idea:root") == ["idea:k1", "idea:k2"])
            #expect(!model.setRegionLayout("r", "radial"))
            #expect(model.setRegionLayout("r", "tree"))
            let region = model.layout.regions["r"]!
            #expect(region.isTree)
            let spot = { (ref: String) in model.layout.placements[ref].map { [$0.x, $0.y] } }
            #expect(spot("idea:root") == [50, 132])
            #expect(spot("idea:k1") == [350, 60], "60 right of the parent's right edge")
            #expect(spot("idea:k2") == [350, 204], "24 under its sibling")
            #expect(region.w == 540 + 100 && region.h == 264 + 60 + 50, "fitted round the tree")
            #expect(!model.setRegionLayout("r", "tree"))

            #expect(model.turnTreeIntoArrows(regionID: "r") == 2)
            #expect(model.layout.regions["r"]?.layout == nil)
            #expect(model.layout.edges.values.allSatisfy { !$0.isTree } && model.layout.edges.count == 2, "plain arrows now")
            #expect(spot("idea:k1") == [350, 60], "the cards keep the spots the tree gave them")
            #expect(model.turnTreeIntoArrows(regionID: "r") == 0)

            // Branches again, a tree, and then free: the cards stay where the tree put them.
            for (key, edge) in model.layout.edges { #expect(model.updateEdgeStyle(key, tree: true), "\(edge.from) to \(edge.to)") }
            #expect(model.setRegionLayout("r", "tree") && model.setRegionLayout("r", "free"))
            #expect(model.layout.regions["r"]?.layout == nil && spot("idea:k1") == [350, 60] && spot("idea:k2") == [350, 204])
        }
    }

    @Test("placeTree sets a mind map down in a region of its own, branches drawn, in one write")
    func placeTree() throws {
        try withModel { model in
            model.place([(ref: "idea:r", x: 0, y: 0), (ref: "idea:a", x: 0, y: 0), (ref: "idea:b", x: 0, y: 0)])
            let made = model.placeTree(
                root: "idea:r", children: ["idea:r": ["idea:a", "idea:b"]],
                near: .init(x: 0, y: 0), regionName: "Mind map"
            )
            let result = try #require(made)
            #expect(result.edgeIDs.count == 2)
            let region = model.layout.regions[result.regionID]!
            #expect(region.isTree && region.name == "Mind map")
            #expect(model.treeChildren(of: "idea:r") == ["idea:a", "idea:b"])
            for ref in ["idea:r", "idea:a", "idea:b"] {
                #expect(model.regionID(containing: ref) == result.regionID, "\(ref) sits inside the region")
            }
            let r = model.layout.placements["idea:r"]!, a = model.layout.placements["idea:a"]!, b = model.layout.placements["idea:b"]!
            #expect(a.x == r.x + 300 && b.x == r.x + 300 && b.y == a.y + 144)
            #expect(model.placeTree(root: "idea:r", children: [:], near: .init(x: 0, y: 0), regionName: "x") != nil)
        }
    }

    @Test("Tidy Up lays a selection out in reading order from its top left, by each card's own size, in one step")
    func tidyUp() {
        withModel { model in
            model.place([
                (ref: "idea:d", x: 700, y: 330), (ref: "idea:a", x: 500, y: 400),
                (ref: "idea:b", x: 90, y: 360), (ref: "idea:c", x: 100, y: 100),
            ])
            apart()
            model.setCardSize("idea:b", w: nil, h: 200)
            apart()
            // Reading order: c (top row), then b, d, a by where they sit (b and d and a are one row).
            #expect(model.tidyUp(["idea:a", "idea:b", "idea:c", "idea:d"], as: .row) == 4)
            let row = ["idea:c", "idea:b", "idea:d", "idea:a"].map { model.layout.placements[$0]! }
            let tops: [Double] = [100, 100, 100, 100]
            let lefts: [Double] = [90, 360, 630, 900]
            #expect(row.map(\.y) == tops, "tops level at the selection's top")
            #expect(row.map(\.x) == lefts, "the selection's left stays; each 240 wide and 30 apart")
            apart()
            #expect(model.tidyUp(["idea:a", "idea:b", "idea:c", "idea:d"], as: .row) == 0, "already tidy: no write")

            #expect(model.tidyUp(["idea:a", "idea:b", "idea:c", "idea:d"], as: .column) == 3)
            let columnY: [Double] = ["idea:c", "idea:b", "idea:d", "idea:a"].map { model.layout.placements[$0]!.y }
            #expect(model.layout.placements["idea:c"]?.x == 90)
            #expect(columnY == [100, 250, 480, 630], "b is 200 tall, and d goes under all of it")
            apart()

            #expect(model.tidyUp(["idea:a", "idea:b", "idea:c", "idea:d"], as: .grid) > 0)
            // Four cards: three across (4 * 1.5 is 6, its root 2.4 rounded up), rows as tall as their tallest.
            let p = { (ref: String) in model.layout.placements[ref]! }
            let gridX: [Double] = [p("idea:c").x, p("idea:b").x, p("idea:d").x, p("idea:a").x]
            let gridY: [Double] = [p("idea:c").y, p("idea:b").y, p("idea:d").y, p("idea:a").y]
            #expect(gridX == [90, 360, 630, 90])
            #expect(gridY == [100, 100, 100, 330], "the second row starts under b, the tallest of the first")
            #expect(model.tidyUp(["idea:a"], as: .row) == 0, "one card is nothing to tidy")
            model.undo()
            #expect(p("idea:b").x == 90, "a tidy is one step: the column comes back")
            #expect(p("idea:b").y == 250)
        }
    }

    @Test("A tidy that pushes a card past its region's edge grows the region, unless it is locked")
    func tidyGrowsRegions() {
        withModel { model in
            model.saveRegion(id: "r", name: "R", x: 0, y: 0, w: 500, h: 400, color: "#7F77DD")
            model.saveRegion(id: "locked", name: "L", x: 2000, y: 0, w: 500, h: 400, color: "#1D9E75")
            model.setRegionLocked("locked", true)
            model.place([(ref: "idea:a", x: 50, y: 60), (ref: "idea:b", x: 50, y: 200), (ref: "idea:c", x: 2050, y: 60), (ref: "idea:d", x: 2050, y: 200)])
            #expect(model.tidyUp(["idea:a", "idea:b"], as: .row) == 1)
            #expect(model.layout.placements["idea:b"]?.x == 320)
            let r = model.layout.regions["r"]!
            #expect(r.x + r.w >= 320 + 240 + 24, "the card at 320 reaches 560, and the region holds it with 24 to spare")
            #expect(model.tidyUp(["idea:c", "idea:d"], as: .row) == 1)
            #expect(model.layout.regions["locked"]?.w == 500, "a locked region is not resized by hand or by a tidy")
        }
    }

    @Test("Align moves each card to the selection's bounds on one edge or middle, by its own size")
    func align() {
        withModel { model in
            model.place([(ref: "idea:a", x: 100, y: 100), (ref: "idea:b", x: 500, y: 300), (ref: "idea:c", x: 300, y: 600)])
            model.setPlacementStyle([.init(ref: "idea:b", w: .set(400), h: .set(200))])
            apart()
            let all = ["idea:a", "idea:b", "idea:c"]
            @MainActor func xs() -> [Double] { all.map { model.layout.placements[$0]!.x } }
            @MainActor func ys() -> [Double] { all.map { model.layout.placements[$0]!.y } }
            /// One alignment, its result read, and taken back.
            @MainActor func aligned(_ edge: KnowledgeMapAlignment, moves: Int) -> ([Double], [Double]) {
                #expect(model.align(all, edge) == moves, "\(edge)")
                let result = (xs(), ys())
                apart()
                model.undo()
                apart()
                return result
            }
            // The selection spans x 100...900 (b is the widest, to 900) and y 100...720 (c's bottom).
            #expect(aligned(.left, moves: 2).0 == [100, 100, 100])
            let right = aligned(.right, moves: 2).0
            #expect(zip(right, [240.0, 400, 240]).map { $0 + $1 } == [900, 900, 900], "by each card's own width")
            #expect(aligned(.top, moves: 2).1 == [100, 100, 100])
            #expect(aligned(.bottom, moves: 2).1 == [600, 520, 600], "720 less each card's own height")
            #expect(aligned(.centerX, moves: 3).0 == [380, 300, 380], "the middle of 100 and 900 is 500")
            #expect(aligned(.centerY, moves: 3).1 == [350, 310, 350], "the middle of 100 and 720 is 410")
            #expect(xs() == [100, 500, 300] && ys() == [100, 300, 600], "each taken back")
            #expect(model.align(["idea:a"], .left) == 0)
        }
    }

    @Test("A row laid across a card moves that card down out from under it, in the same Undo step")
    func arrangeMakesRoom() {
        withModel { model in
            model.place([(ref: "idea:a", x: 0, y: 0), (ref: "idea:b", x: 0, y: 400), (ref: "idea:c", x: 300, y: 0), (ref: "idea:d", x: 300, y: 900)])
            apart()
            #expect(model.arrange(["idea:a", "idea:b"], as: .row, align: nil) == 1)
            let b = model.layout.placements["idea:b"]!, c = model.layout.placements["idea:c"]!
            #expect(b.x == 270 && b.y == 0, "b joins a's row, over where c was")
            #expect(c.x == 300 && c.y == model.cardHeight(of: "idea:b") + 30, "c goes under the row, a gap below it")
            #expect(model.layout.placements["idea:d"]?.y == 900, "a card the row does not cover stays")
            #expect(!model.lint().contains { $0.kind == .overlap })
            apart()
            model.undo()
            #expect(model.layout.placements["idea:c"]?.y == 0 && model.layout.placements["idea:b"]?.y == 400, "one Undo puts both back")
        }
    }

    @Test("A row of a region's cards keeps to the region, which grows to hold it; cards from two regions leave them be")
    func arrangeKeepsToItsRegion() {
        withModel { model in
            model.saveRegion(id: "r", name: "Home", x: 0, y: 0, w: 600, h: 700, color: "#7F77DD")
            model.saveRegion(id: "s", name: "Other", x: 2000, y: 0, w: 600, h: 400, color: "#1D9E75")
            model.place([(ref: "idea:a", x: 50, y: 60), (ref: "idea:b", x: 50, y: 260), (ref: "idea:c", x: 50, y: 460), (ref: "idea:d", x: 2050, y: 60)])
            apart()
            #expect(model.arrange(["idea:a", "idea:b", "idea:c"], as: .row, align: nil) == 2)
            let home = model.layout.regions["r"]!
            let right = model.layout.placements["idea:c"]!.x + model.cardWidth(of: "idea:c")
            #expect(home.x + home.w >= right, "Home grows to hold the row's last card")
            let bottom = model.layout.placements["idea:a"]!.y + model.cardHeight(of: "idea:a")
            #expect(home.y + home.h <= bottom + 60, "the row is all of Home's cards, so Home fits it rather than keeping the column's height")
            #expect(model.layout.regions["s"]?.w == 600, "a region the row never touched is left alone")
            apart()
            model.undo()
            #expect(model.layout.regions["r"]?.w == 600)
            let before = model.layout.regions
            #expect(model.arrange(["idea:a", "idea:d"], as: .row, align: nil) == 1)
            #expect(model.layout.regions["s"] == before["s"], "cards from two regions grow neither for the other's card")
        }
    }

    @Test("The nearest free spot is the asked-for one when it is clear, else the closest clear one, never on a card")
    func nearestFreeOrigin() {
        typealias A = KnowledgeMapArranging
        let clear = A.nearestFreeOrigin(size: (240, 120), near: .init(x: 500, y: 500), occupied: [])
        #expect(clear == .init(x: 380, y: 440))
        let card = A.Rect(x: 380, y: 440, w: 240, h: 120)
        let moved = A.nearestFreeOrigin(size: (240, 120), near: .init(x: 500, y: 500), occupied: [card])
        let landed = A.Rect(x: moved.x, y: moved.y, w: 240, h: 120)
        #expect(!landed.intersects(card) && moved != .init(x: 380, y: 440))
        #expect(hypot(moved.x - 380, moved.y - 440) <= 200, "close by: \(moved)")
    }

    @Test("arrange does a tidy and an alignment as one write")
    func arrangeBoth() {
        withModel { model in
            model.place([(ref: "idea:a", x: 100, y: 100), (ref: "idea:b", x: 500, y: 300)])
            model.setPlacementStyle([.init(ref: "idea:a", h: .set(300))])
            apart()
            #expect(model.arrange(["idea:a", "idea:b"], as: .row, align: .bottom) == 1, "a stays; b goes right and down")
            #expect(model.layout.placements["idea:a"]?.x == 100 && model.layout.placements["idea:b"]?.x == 370)
            #expect(model.layout.placements["idea:a"]?.y == 100 && model.layout.placements["idea:b"]?.y == 280, "b's bottom meets a's")
            apart()
            model.undo()
            #expect(model.layout.placements["idea:b"]?.x == 500 && model.layout.placements["idea:b"]?.y == 300)
        }
    }

    @Test("Lint finds overlapping cards, a card half outside its region, an arrow across a card, and an empty region")
    func lint() {
        withModel { model in
            model.saveRegion(id: "r", name: "Frame", x: 0, y: 0, w: 400, h: 300, color: "#7F77DD")
            model.saveRegion(id: "gap", name: "Nothing here", x: 3000, y: 0, w: 300, h: 200, color: "#1D9E75")
            model.saveRegion(id: "nb", name: "A notebook", x: 3000, y: 500, w: 300, h: 200, color: "#1D9E75", notebookID: "n1")
            model.saveRegion(id: "outer", name: "Outer", x: 4000, y: 0, w: 900, h: 600, color: "#D85A30")
            model.saveRegion(id: "innermost", name: "Inner", x: 4100, y: 100, w: 300, h: 200, color: "#D85A30")
            model.place([
                (ref: "source:x", x: 250, y: 100),
                (ref: "source:p", x: 50, y: 60), (ref: "source:q", x: 100, y: 100),
                (ref: "source:l", x: 0, y: 1000), (ref: "source:m", x: 300, y: 1000), (ref: "source:n", x: 600, y: 1000),
                (ref: "source:o", x: 0, y: 1600), (ref: "source:mid", x: 300, y: 1600), (ref: "source:r", x: 600, y: 1600),
                (ref: "source:k", x: 4150, y: 140),
            ])
            model.addEdge(from: "source:l", to: "source:n", label: "", route: "straight")
            model.addEdge(from: "source:l", to: "source:m", label: "")
            // A default arrow is drawn bent round the card between its ends.
            model.addEdge(from: "source:o", to: "source:r", label: "")
            let issues = model.lint()
            func of(_ kind: KnowledgeMapLintIssue.Kind) -> [KnowledgeMapLintIssue] { issues.filter { $0.kind == kind } }
            #expect(of(.overlap).map(\.refs) == [["source:p", "source:q"], ["source:p", "source:x"], ["source:q", "source:x"]], "p, q and x are all over one another")
            #expect(!of(.overlap).contains { $0.refs.contains("source:l") || $0.refs.contains("source:m") || $0.refs.contains("source:n") || $0.refs.contains("source:mid") })
            #expect(of(.cardOutsideRegion).contains { $0.refs == ["source:x"] && $0.regionID == "r" }, "x's middle is in Frame but its edge is not")
            #expect(!of(.cardOutsideRegion).contains { $0.refs == ["source:p"] })
            let across = of(.arrowOverCard)
            #expect(across.map(\.refs) == [["source:m"]] && across[0].edgeID != nil, "the straight arrow from l to n crosses m; l to m crosses nothing; o to r bends round mid")
            #expect(of(.emptyRegion).map(\.regionID) == ["gap"], "a notebook's frame and a region holding a region are not empty")
            #expect(of(.emptyRegion)[0].message.contains("Nothing here"))
            #expect(issues.allSatisfy { !$0.message.isEmpty && !$0.message.contains("\n") })
        }
    }

    @Test("A default arrow is judged by the curve the Canvas draws: clear of the card it bends round, across one no bend clears")
    func lintJudgesTheDrawnCurve() {
        typealias Rect = KnowledgeMapArranging.Rect
        let a = Rect(x: 0, y: 0, w: 240, h: 120), b = Rect(x: 600, y: 0, w: 240, h: 120)
        let between = (ref: "m", rect: Rect(x: 300, y: 0, w: 240, h: 120))
        let route = KnowledgeMapLint.curveRoute(from: a, to: b, others: [between])
        let apex = KnowledgeMapLint.point(on: route, at: 0.5)
        #expect(apex.y < 0 - 6 || apex.y > 120 + 6, "the curve passes above or below m")
        let clear = KnowledgeMapLint.curveRoute(from: a, to: b, others: [])
        #expect(abs(KnowledgeMapLint.point(on: clear, at: 0.5).y - 60) < 40, "with nothing between, the gentle bend")
        // A wall no bend clears: the route crossing the fewest is drawn, and reported.
        let wall = (ref: "wall", rect: Rect(x: 300, y: -3000, w: 240, h: 6000))
        let blocked = KnowledgeMapLint.curveRoute(from: a, to: b, others: [wall])
        let samples = (1..<40).map { KnowledgeMapLint.point(on: blocked, at: Double($0) / 40) }
        #expect(samples.contains { $0.x > 300 && $0.x < 540 }, "it still runs across the wall")
        // A region's name is gone round as a card is.
        let region = KnowledgeMapLayout.Region(name: "Between", x: 280, y: 90, w: 300, h: 400, color: "#7F77DD", at: 0)
        let name = (ref: "region:between", rect: KnowledgeMapLint.headerRect(region))
        #expect(name.rect.maxY <= region.y && name.rect.y < 60 && name.rect.maxY > 60, "the name sits above the frame, across the cards' middles")
        let round = KnowledgeMapLint.curveRoute(from: a, to: b, others: [name])
        let mid = KnowledgeMapLint.point(on: round, at: 0.5)
        #expect(mid.y < name.rect.y - 6 || mid.y > name.rect.maxY + 6, "the arrow bends clear of the region's name")
    }

    @Test("A card in a region folded up is not drawn, so it overlaps nothing; an arrow's own ends are never crossed")
    func lintLeavesOutWhatIsNotDrawn() {
        withModel { model in
            model.saveRegion(id: "folded", name: "Folded", x: 0, y: 0, w: 800, h: 400, color: "#7F77DD")
            model.place([(ref: "source:a", x: 50, y: 60), (ref: "source:b", x: 60, y: 70)])
            #expect(model.lint().contains { $0.kind == .overlap })
            model.setRegionCollapsed("folded", true)
            #expect(!model.lint().contains { $0.kind == .overlap }, "folded up: not drawn")
            #expect(!model.lint().contains { $0.kind == .emptyRegion }, "and not empty: its cards are still placed")
        }
    }
}

/// The geometry the pure functions give (docs/knowledge-map-design.md, "Heptabase parity build": tree layout).
@Suite("Map: tidy, align and tree geometry (the parity build)")
struct KnowledgeMapParityGeometryTests {
    typealias Arranging = KnowledgeMapArranging

    @Test("A tree: the root at the left, children 60 right of the parent, siblings 24 apart, a parent centred on its children's span")
    func treeShape() {
        let tree = Arranging.tree(
            root: "r", children: ["r": ["a", "b"], "a": ["a1", "a2"]],
            heights: [:], widths: [:]
        )
        #expect(tree.spots["r"] == .init(x: 0, y: 180))
        #expect(tree.spots["a"] == .init(x: 300, y: 72) && tree.spots["b"] == .init(x: 300, y: 288))
        #expect(tree.spots["a1"] == .init(x: 600, y: 0) && tree.spots["a2"] == .init(x: 600, y: 144))
        #expect(tree.bounds == Arranging.Rect(x: 0, y: 0, w: 840, h: 408))
        // a is centred on a1 and a2's span (0 to 264); the root on a's top to b's bottom (72 to 408).
        #expect(tree.spots["a"]!.y + 60 == 132 && tree.spots["r"]!.y + 60 == 240)
    }

    @Test("Each card is placed by its own width and height, and the tree starts at the origin it is given")
    func treeSizes() {
        let tree = Arranging.tree(
            root: "r", children: ["r": ["a", "b"]],
            heights: ["r": 50, "a": 300, "b": 100], widths: ["r": 100, "a": 500, "b": 240],
            origin: .init(x: 1000, y: 2000)
        )
        #expect(tree.spots["a"] == .init(x: 1160, y: 2000), "160 right of the root: its 100 and the 60 gap")
        #expect(tree.spots["b"]?.x == 1160)
        #expect(tree.spots["b"]?.y == 2324, "under a's 300 and the gap, from 2000")
        // The root is centred on a's top (2000) to b's bottom (2424).
        #expect(tree.spots["r"] == .init(x: 1000, y: 2212 - 25))
        #expect(tree.bounds.x == 1000 && tree.bounds.y == 2000 && tree.bounds.w == 100 + 60 + 500 && tree.bounds.h == 424)
    }

    @Test("No two cards of a big, uneven tree overlap, and a card reached twice or a loop is laid once")
    func treeNeverOverlaps() {
        var children: [String: [String]] = [:]
        var heights: [String: Double] = [:]
        var count = 0
        func grow(_ id: String, _ depth: Int) {
            heights[id] = [120, 80, 300, 40][count % 4]
            count += 1
            guard depth < 4 else { return }
            let kids = (0..<((count % 3) + 1)).map { "\(id).\($0)" }
            children[id] = kids
            for kid in kids { grow(kid, depth + 1) }
        }
        grow("root", 0)
        children["root.0"] = (children["root.0"] ?? []) + ["root"]
        children["root.0.0"] = (children["root.0.0"] ?? []) + ["root.0"]
        let tree = Arranging.tree(root: "root", children: children, heights: heights, widths: [:])
        #expect(tree.spots.count == heights.count)
        let rects = tree.spots.map { Arranging.Rect(x: $1.x, y: $1.y, w: 240, h: heights[$0] ?? 120) }
        for i in rects.indices {
            for j in rects.indices where j > i { #expect(!rects[i].intersects(rects[j])) }
        }
        #expect(rects.allSatisfy { tree.bounds.holds($0) })
    }

    @Test("A forest stacks its trees 24 apart")
    func forestStacks() {
        let forest = Arranging.forest(
            roots: ["r1", "r2"], children: ["r1": ["a"], "r2": ["b", "r1"]],
            heights: [:], widths: [:], origin: .init(x: 10, y: 20)
        )
        #expect(forest.spots["r1"]?.x == 10 && forest.spots["r2"]?.x == 10)
        // r1 and a: a at the top (20), r1 centred on it; then 24 and r2's tree, which does not take r1 again.
        #expect(forest.spots["a"]?.y == 20 && forest.spots["r1"]?.y == 20)
        #expect(forest.spots["r2"] != nil && forest.spots["b"] != nil && forest.spots.count == 4)
        #expect(forest.spots["b"]!.y >= 20 + 120 + 24)
    }

    @Test("Reading order reads rows from the top, each row left to right, two cards at about one height being one row")
    func reading() {
        let cards: [Arranging.PlacedRect] = [
            ("d", .init(x: 500, y: 130, w: 240, h: 120)),
            ("a", .init(x: 0, y: 100, w: 240, h: 120)),
            ("c", .init(x: 0, y: 400, w: 240, h: 120)),
            ("b", .init(x: 300, y: 150, w: 240, h: 120)),
        ]
        #expect(Arranging.readingOrder(cards).map(\.ref) == ["a", "b", "d", "c"])
    }

    @Test("Columns are as wide as their widest card; grid and column heights follow each card")
    func columnWidths() {
        let lefts = Arranging.columnLefts(widths: [240, 500, 240, 240], cols: 2)
        #expect(lefts.lefts == [0, 270])
        #expect(lefts.width == 270 + 500)
        #expect(Arranging.columnLefts(widths: [240, 240, 240], cols: 3).width == 240 * 3 + 60)
        let block = Arranging.block(heights: [120, 120], widths: [400, 240], origin: .init(x: 0, y: 0))
        #expect(block.spots[1].x == 400 + 30)
        let row = Arranging.row(heights: [120, 120, 120], widths: [400, 240, 240], origin: .init(x: 0, y: 0))
        #expect(row.spots.map(\.x) == [0, 430, 700])
        #expect(Arranging.block(heights: [120], origin: .init(x: 0, y: 0)).frame == Arranging.block(heights: [120], widths: nil, origin: .init(x: 0, y: 0)).frame)
    }
}

// MARK: - The parity build over MCP, at the Canvas model

/// What the new and changed tools do to a canvas, called as the tools call
/// them (`MCPDataStore.updateCanvasCard` and the rest, which answer from the
/// open canvas's model): the arguments, the refusals, the answers and the
/// writes. The schemas and the tool lists are in `MCPCanvasParityContractTests`.
@Suite("Map: the parity build's MCP tools")
@MainActor
struct KnowledgeMapMCPParityTests {
    typealias Store = MCPDataStore

    /// A canvas on a row of its own, whose library holds the Ideas `ids` (`idea:<id>`).
    private func withMap(_ ids: [String] = ["a", "b", "c", "d", "x"], _ body: (KnowledgeMapModel) async throws -> Void) async rethrows {
        let suite = UserDefaults(suiteName: "KnowledgeMapMCPParityTests.\(UUID().uuidString)")!
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: suite)) {
            let map = KnowledgeMapModel(mapID: KnowledgeMap.firstCanvasID)
            map.rebuildContent(
                articles: [], ideas: ids.map { IdeaRecord(id: $0, title: "Idea \($0)") },
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

    @Test("update_canvas_card tints, folds and sizes the cards that are placed, lists the rest, and is one Undo step")
    func updateCard() async throws {
        try await withMap { map in
            map.place([(ref: "idea:a", x: 0, y: 0), (ref: "idea:b", x: 300, y: 0)])
            apart()
            let result = try Store.updateCanvasCard(
                ["item_ids": ["idea:a", "idea:b", "idea:c", "idea:ghost"], "color": "#d4537e", "folded": true, "w": 400], map: map
            )
            #expect(result["updated"] as? Int == 2)
            let placed = cards(result)
            #expect(placed.count == 2)
            #expect(placed.allSatisfy { ($0["color"] as? String) == "#D4537E" && ($0["folded"] as? Bool) == true && ($0["w"] as? Double) == 400 })
            let rect = placed[0]["rect"] as? [String: Double]
            #expect(rect?["w"] == 400 && rect?["h"] == KnowledgeMap.foldedCardHeight, "the size it is drawn at: its own width, a title line tall")
            #expect(cards(result, "not_on_canvas").map { $0["item_id"] as? String } == ["idea:c"])
            #expect(result["not_in_library"] as? [String] == ["idea:ghost"])

            apart()
            let fitted = try Store.updateCanvasCard(["item_ids": ["idea:a"], "fit_to_content": true, "folded": false, "color": ""], map: map)
            let card = cards(fitted)[0]
            #expect(card["w"] == nil && card["folded"] == nil && card["color"] == nil, "what was given is gone")
            #expect((card["rect"] as? [String: Double])?["w"] == KnowledgeMap.cardWidth)
            map.undo()
            #expect(map.layout.placements["idea:a"]?.w == 400 && map.layout.placements["idea:a"]?.folded == true, "one step takes it back")
        }
    }

    @Test("update_canvas_card refuses what cannot be done, in words")
    func updateCardRefusals() async throws {
        try await withMap { map in
            map.place([(ref: "idea:a", x: 0, y: 0)])
            @MainActor func ask(_ arguments: [String: Any]) -> String? {
                var call: [String: Any] = ["item_ids": ["idea:a"]]
                call.merge(arguments) { $1 }
                return refusal { try Store.updateCanvasCard(call, map: map) }
            }
            #expect(ask([:])?.contains("needs color, folded, w, h or fit_to_content") == true)
            #expect(ask(["fit_to_content": true, "w": 300])?.contains("do not pass w or h") == true)
            #expect(ask(["w": 5000])?.contains("160 to 720") == true)
            #expect(ask(["h": 10])?.contains("40 to 2000") == true)
            #expect(ask(["w": true])?.contains("160 to 720") == true, "a boolean is not a number")
            #expect(ask(["color": "red"])?.contains("#RRGGBB") == true)
            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["idea:c"], "color": "#D4537E"], map: map) }?.contains("place_on_canvas") == true)
            #expect(refusal { try Store.updateCanvasCard(["item_ids": ["idea:ghost"], "color": "#D4537E"], map: map) }?.contains("idea:ghost") == true)
        }
    }

    @Test("A card made wider than its region grows the region; a wider card is set down wider by place_on_canvas")
    func sizesGrowRegionsAndPlacing() async throws {
        try await withMap { map in
            map.saveRegion(id: "r", name: "R", x: 0, y: 0, w: 500, h: 400, color: "#7F77DD")
            map.place([(ref: "idea:a", x: 300, y: 100)])
            _ = try Store.updateCanvasCard(["item_ids": ["idea:a"], "w": 400], map: map)
            #expect(map.layout.regions["r"]?.w == 724)
            let placed = try Store.placeOnCanvas(["item_ids": ["idea:b", "idea:c"], "w": 400, "h": 200, "color": "#1d9e75", "folded": false, "new_region": "Wide"], map: map)
            let two = cards(placed, "placed")
            #expect(two.map { $0["w"] as? Double } == [400, 400] && two.map { $0["h"] as? Double } == [200, 200])
            #expect(two.allSatisfy { ($0["color"] as? String) == "#1D9E75" && $0["folded"] == nil })
            let left = two.compactMap { ($0["rect"] as? [String: Double]) }
            #expect(left.count == 2)
            #expect(abs(left[1]["x"]! - left[0]["x"]!) == 430, "set down by their own width, 30 apart")
            #expect(refusal { try Store.placeOnCanvas(["item_ids": ["idea:d"], "h": 20], map: map) }?.contains("40 to 2000") == true)
        }
    }

    @Test("arrange_on_canvas tidies and aligns in one write, refuses a bad ask, and leaves a locked region's cards")
    func arrange() async throws {
        try await withMap { map in
            map.place([(ref: "idea:a", x: 100, y: 100), (ref: "idea:b", x: 500, y: 330), (ref: "idea:c", x: 300, y: 700)])
            apart()
            let result = try Store.arrangeOnCanvas(["item_ids": ["idea:a", "idea:b", "idea:c"], "arrangement": "column", "align": "center"], map: map)
            #expect(result["moved"] as? Int == 2)
            let x = cards(result).map { ($0["rect"] as? [String: Double])?["x"] }
            #expect(x == [100, 100, 100], "a column keeps the left, and centring equal widths changes nothing")
            let y = cards(result).map { ($0["rect"] as? [String: Double])?["y"] }
            #expect(y == [100, 250, 400])
            apart()
            map.undo()
            #expect(map.layout.placements["idea:b"]?.x == 500 && map.layout.placements["idea:c"]?.y == 700, "one step")

            #expect(refusal { try Store.arrangeOnCanvas(["item_ids": ["idea:a", "idea:b"]], map: map) }?.contains("arrangement") == true)
            #expect(refusal { try Store.arrangeOnCanvas(["item_ids": ["idea:a", "idea:b"], "arrangement": "spiral"], map: map) }?.contains("row, column or grid") == true)
            #expect(refusal { try Store.arrangeOnCanvas(["item_ids": ["idea:a", "idea:b"], "align": "diagonal"], map: map) }?.contains("middle") == true)
            #expect(refusal { try Store.arrangeOnCanvas(["item_ids": ["idea:a", "idea:d"], "arrangement": "row"], map: map) }?.contains("at least two") == true)

            map.saveRegion(id: "r", name: "Kept", x: 0, y: 0, w: 900, h: 400, color: "#7F77DD")
            map.setRegionLocked("r", true)
            let held = refusal { try Store.arrangeOnCanvas(["item_ids": ["idea:a", "idea:b"], "arrangement": "row"], map: map) }
            #expect(held?.contains("locked region") == true && held?.contains("Idea a") == true)
            map.setRegionLocked("r", false)
            #expect(try Store.arrangeOnCanvas(["item_ids": ["idea:a", "idea:b"], "arrangement": "row"], map: map)["moved"] as? Int == 1)
        }
    }

    @Test("lint_canvas reports the issues with their kinds and ids, counts them, and says ok when there are none")
    func lint() async throws {
        try await withMap { map in
            let clean = Store.lintCanvas([:], map: map)
            #expect(clean["ok"] as? Bool == true && clean["issue_count"] as? Int == 0 && (clean["issues"] as? [Any])?.isEmpty == true)
            map.place([(ref: "idea:a", x: 0, y: 0), (ref: "idea:b", x: 100, y: 50), (ref: "idea:c", x: 600, y: 0)])
            map.saveRegion(id: "empty", name: "Nothing", x: 3000, y: 0, w: 300, h: 200, color: "#1D9E75")
            let result = Store.lintCanvas([:], map: map)
            #expect(result["ok"] as? Bool == false && result["issue_count"] as? Int == 2)
            let issues = result["issues"] as? [[String: Any]] ?? []
            #expect(issues.map { $0["kind"] as? String } == ["overlap", "empty_region"])
            #expect(issues[0]["item_ids"] as? [String] == ["idea:a", "idea:b"])
            #expect(issues[1]["region_id"] as? String == "empty")
            #expect((issues[0]["message"] as? String)?.contains("Idea a") == true)
            #expect((result["by_kind"] as? [String: Int]) == ["overlap": 1, "empty_region": 1])
            let capped = Store.lintCanvas(["limit": 1], map: map)
            #expect((capped["issues"] as? [Any])?.count == 1 && capped["truncated"] as? Bool == true && capped["issue_count"] as? Int == 2)
        }
    }

    @Test("Arrows take a look and end at regions; the refusals say why; a branch is drawn and turned back")
    func arrows() async throws {
        try await withMap { map in
            map.saveRegion(id: "r", name: "Frame", x: 0, y: 0, w: 600, h: 400, color: "#7F77DD")
            map.place([(ref: "idea:a", x: 50, y: 60), (ref: "idea:b", x: 2000, y: 0), (ref: "idea:c", x: 2400, y: 0), (ref: "idea:x", x: 3000, y: 0)])
            let drawn = try Store.drawCanvasArrow(
                ["from": "idea:x", "to": "region:Frame", "label": " feeds ", "route": "elbow", "dashed": true, "heads": "both", "color": "#d4537e"], map: map
            )
            let to = drawn["to"] as? [String: Any]
            #expect(to?["kind"] as? String == "region" && to?["region_id"] as? String == "r" && to?["item_id"] as? String == "region:r")
            #expect(drawn["label"] as? String == "feeds" && drawn["route"] as? String == "elbow" && drawn["dashed"] as? Bool == true)
            #expect(drawn["heads"] as? String == "both" && drawn["color"] as? String == "#D4537E" && drawn["tree"] == nil)
            let edgeID = try #require(drawn["edge_id"] as? String)

            #expect(refusal { try Store.drawCanvasArrow(["from": "idea:a", "to": "region:r"], map: map) }?.contains("inside") == true)
            #expect(refusal { try Store.drawCanvasArrow(["from": "idea:b", "to": "idea:b"], map: map) }?.contains("two different") == true)
            #expect(refusal { try Store.drawCanvasArrow(["from": "idea:b", "to": "idea:d"], map: map) }?.contains("not on the Canvas") == true)
            #expect(refusal { try Store.drawCanvasArrow(["from": "idea:b", "to": "idea:c", "route": "zigzag"], map: map) }?.contains("curve, straight or elbow") == true)
            #expect(refusal { try Store.drawCanvasArrow(["from": "idea:b", "to": "region:Nowhere"], map: map) } != nil)

            let branch = try Store.drawCanvasArrow(["from": "idea:b", "to": "idea:c", "tree": true], map: map)
            #expect(branch["tree"] as? Bool == true)
            #expect(refusal { try Store.drawCanvasArrow(["from": "idea:x", "to": "idea:c", "tree": true], map: map) }?.contains("has a parent") == true)
            #expect(refusal { try Store.drawCanvasArrow(["from": "idea:c", "to": "idea:b", "tree": true], map: map) }?.contains("loop") == true)

            apart()
            let changed = try Store.changeCanvasArrow(["from": "idea:b", "to": "idea:c", "tree": false, "label": "then"], map: map, deleting: false)
            #expect(changed["tree"] == nil && changed["label"] as? String == "then" && changed["changed"] as? Bool == true)
            let again = try Store.changeCanvasArrow(["edge_id": edgeID, "route": "elbow"], map: map, deleting: false)
            #expect(again["changed"] as? Bool == false, "already so")
            let cleared = try Store.changeCanvasArrow(["edge_id": edgeID, "route": "curve", "dashed": false, "heads": "end", "color": ""], map: map, deleting: false)
            #expect(cleared["route"] == nil && cleared["dashed"] == nil && cleared["heads"] == nil && cleared["color"] == nil, "the defaults are left out")
            #expect(refusal { try Store.changeCanvasArrow(["edge_id": edgeID], map: map, deleting: false) }?.contains("needs label, route") == true)
            #expect(refusal { try Store.changeCanvasArrow(["from": "idea:x", "to": "region:Frame", "label": "x"], map: map, deleting: false) } == nil, "named by its ends, a region among them")
            #expect(refusal { try Store.changeCanvasArrow(["edge_id": "nope", "label": "x"], map: map, deleting: false) } != nil)
            let gone = try Store.changeCanvasArrow(["from": "idea:x", "to": "region:r"], map: map, deleting: true)
            #expect(gone["deleted"] as? String == edgeID && map.layout.edges[edgeID] == nil)
        }
    }

    @Test("Regions take a lock, a layout, a fit and a grow; a locked region refuses geometry unless the call unlocks it")
    func regions() async throws {
        try await withMap { map in
            let notebooks: Store.NotebookLookup = { id in id == "nb" ? ("nb", "Mito Phenotyping") : nil }
            let made = try Store.createCanvasRegion(["name": "Mine", "locked": true], map: map, notebook: notebooks)
            let region = made["region"] as? [String: Any]
            let id = try #require(region?["region_id"] as? String)
            #expect(region?["locked"] as? Bool == true)
            let frame = try Store.createCanvasRegion(["notebook_id": "nb"], map: map, notebook: notebooks)
            #expect((frame["region"] as? [String: Any])?["name"] as? String == "Mito Phenotyping")
            #expect(try Store.createCanvasRegion(["notebook_id": "nb"], map: map, notebook: notebooks)["created"] as? Bool == false, "framed once")
            #expect(refusal { try Store.createCanvasRegion(["notebook_id": "zz"], map: map, notebook: notebooks) }?.contains("No Notebook") == true)

            let locked = refusal { try Store.updateCanvasRegion(["region": id, "w": 800], map: map, notebook: notebooks) }
            #expect(locked?.contains("is locked") == true)
            #expect(refusal { try Store.updateCanvasRegion(["region": id, "fit_to_content": true], map: map, notebook: notebooks) }?.contains("is locked") == true)
            let unlocked = try Store.updateCanvasRegion(["region": id, "w": 800, "locked": false], map: map, notebook: notebooks)
            #expect((unlocked["region"] as? [String: Any])?["locked"] == nil)
            #expect(map.layout.regions[id]?.w == 800)
            #expect(try Store.updateCanvasRegion(["region": id, "name": "Renamed", "locked": true], map: map, notebook: notebooks)["region"] != nil, "naming a locked region is allowed")
            #expect(map.layout.regions[id]?.name == "Renamed" && map.layout.regions[id]?.isLocked == true)
            _ = try Store.updateCanvasRegion(["region": id, "locked": false], map: map, notebook: notebooks)

            map.place([(ref: "idea:a", x: map.layout.regions[id]!.x + 100, y: map.layout.regions[id]!.y + 100), (ref: "idea:b", x: map.layout.regions[id]!.x + 400, y: map.layout.regions[id]!.y + 300)])
            let fitted = try Store.updateCanvasRegion(["region": id, "fit_to_content": true], map: map, notebook: notebooks)
            let rect = (fitted["region"] as? [String: Any])?["rect"] as? [String: Double]
            #expect(rect?["w"] == 640 && rect?["h"] == 430, "the cards' bounds, 50 each side and below and 60 above")
            #expect(refusal { try Store.updateCanvasRegion(["region": id, "layout": "radial"], map: map, notebook: notebooks) }?.contains("free or tree") == true)
            #expect(refusal { try Store.updateCanvasRegion(["region": id, "grow_to_hold": ["idea:ghost"]], map: map, notebook: notebooks) }?.contains("None of grow_to_hold") == true)

            map.place([(ref: "idea:c", x: 5000, y: 5000)])
            let before = map.layout.regions[id]!
            _ = try Store.updateCanvasRegion(["region": id, "grow_to_hold": ["idea:c"]], map: map, notebook: notebooks)
            let after = map.layout.regions[id]!
            #expect(after.x == before.x && after.y == before.y && after.x + after.w >= 5240 + 24 && after.y + after.h >= 5120 + 24, "grown to hold it, never moved")

            _ = try Store.drawCanvasArrow(["from": "idea:a", "to": "idea:b", "tree": true], map: map)
            let tree = try Store.updateCanvasRegion(["region": id, "layout": "tree"], map: map, notebook: notebooks)
            #expect((tree["region"] as? [String: Any])?["layout"] as? String == "tree")
            let free = try Store.updateCanvasRegion(["region": id, "layout": "free"], map: map, notebook: notebooks)
            #expect((free["region"] as? [String: Any])?["layout"] == nil)
        }
    }

    @Test("get_knowledge_map's cards say where they are, what they were given and what they stand for")
    func cardEntries() async throws {
        try await withMap { map in
            map.place([(ref: "idea:a", x: 10, y: 20)])
            _ = try Store.updateCanvasCard(["item_ids": ["idea:a"], "w": 300, "color": "#378ADD"], map: map)
            let placed = Store.card("idea:a", in: map)
            #expect(placed["kind"] as? String == "idea" && placed["w"] as? Double == 300 && placed["color"] as? String == "#378ADD")
            let rect = placed["rect"] as? [String: Double]
            #expect(rect?["x"] == 10 && rect?["y"] == 20 && rect?["w"] == 300 && rect?["h"] == KnowledgeMap.cardHeight)
            #expect(Store.card("idea:b", in: map)["rect"] == nil, "a card not placed has no rect")
            #expect(Store.card("canvas:cnv-9", in: map)["canvas_id"] as? String == "cnv-9")
            #expect(Store.card("chat:s1", in: map)["session_id"] as? String == "s1")
            #expect(Store.card("picture:ABCD", in: map)["image_id"] as? String == "ABCD")
            #expect(Store.endEntry("region:zzz", in: map)["kind"] as? String == "region")
        }
    }

    @Test("A mind map in build_canvas is read whole before anything is written: depth first, children in order")
    func treeSpecs() throws {
        let leaves: [[String: Any]] = [["title": "A1"], ["title": "A2", "key": "second-leaf"]]
        let first: [String: Any] = ["title": "A", "text": "first", "children": leaves]
        let second: [String: Any] = ["title": "B"]
        let root: [String: Any] = ["key": "root", "title": " The question ", "text": "  ", "children": [first, second]]
        let tree: [String: Any] = ["name": "Why PINK1?", "color": "#1d9e75", "root": root]
        let specs = try Store.treeSpecs(from: [tree])
        #expect(specs.count == 1 && specs[0].name == "Why PINK1?" && specs[0].color == "#1D9E75")
        let notes = specs[0].notes
        #expect(notes.map(\.title) == ["The question", "A", "A1", "A2", "B"], "depth first, in the order given")
        #expect(notes.map(\.parent) == [nil, 0, 1, 1, 0])
        #expect(notes[0].key == "root" && notes[0].text == nil && notes[1].text == "first" && notes[3].key == "second-leaf" && notes[2].key == nil)

        let noName: [String: Any] = ["root": ["title": "x"] as [String: Any]]
        let noRoot: [String: Any] = ["name": "T"]
        let noTitle: [String: Any] = ["name": "T", "root": ["title": "x", "children": [["text": "no title"]]] as [String: Any]]
        let badColor: [String: Any] = ["name": "T", "color": "teal", "root": ["title": "x"] as [String: Any]]
        #expect(refusal { try Store.treeSpecs(from: [noName]) }?.contains("needs a name") == true)
        #expect(refusal { try Store.treeSpecs(from: [noRoot]) }?.contains("needs a root") == true)
        #expect(refusal { try Store.treeSpecs(from: [noTitle]) }?.contains("needs a title") == true)
        #expect(refusal { try Store.treeSpecs(from: [badColor]) }?.contains("#RRGGBB") == true)
        let many: [[String: Any]] = (0..<Store.maximumTreeNotes).map { ["title": "n\($0)"] }
        let big: [String: Any] = ["name": "T", "root": ["title": "r", "children": many] as [String: Any]]
        #expect(refusal { try Store.treeSpecs(from: [big]) }?.contains("At most 120") == true)
    }

    private func png(_ width: Int, _ height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test("screenshot_canvas draws through the pane's exporter, saves a PNG and answers with its path and size; it refuses cleanly with no pane")
    func screenshot() async throws {
        try await withMap { map in
            map.place([(ref: "idea:a", x: 0, y: 0)])
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ForeverLM-screenshot-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            @MainActor func shoot(_ arguments: [String: Any], onScreen: Bool = true) async -> (Store.MediaToolResult?, String?) {
                do {
                    return (try await Store.canvasScreenshot(arguments, map: map, canvasName: "Parkinson’s: PINK1 / Parkin", isOnScreen: onScreen, exportsFolder: folder), nil)
                } catch MCPError.invalidInput(let message) {
                    return (nil, message)
                } catch MCPError.notFound(let message) {
                    return (nil, message)
                } catch {
                    return (nil, "unexpected \(error)")
                }
            }
            let notShown = await shoot([:], onScreen: false)
            #expect(notShown.1?.contains("not showing on the Mac") == true && notShown.0 == nil)
            #expect(await shoot(["scale": 9]).1?.contains("0.1 to 4") == true)
            #expect(await shoot(["item_ids": ["idea:b"]]).1?.contains("None of those cards is on the Canvas") == true)

            var asked: (Double, [String]?)?
            map.imageExporter = { scale, refs in
                asked = (scale, refs)
                return self.png(40, 30)
            }
            let whole = await shoot([:])
            let text = try #require(whole.0?.text)
            let answer = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(asked?.0 == 1 && asked?.1 == nil, "the whole plane at its own size")
            #expect(answer["width"] as? Int == 40 && answer["height"] as? Int == 30 && answer["attached"] as? Bool == true)
            let path = try #require(answer["file_path"] as? String)
            #expect(path.hasPrefix(folder.path) && path.hasSuffix(".png") && path.contains("Canvas-Parkinson-s-PINK1-Parkin-"))
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(whole.0?.images.count == 1 && whole.0?.images.first?.mimeType == "image/png" && whole.0?.isError == false)

            let part = await shoot(["scale": 2.5, "item_ids": ["idea:a", "idea:b"]])
            #expect(asked?.0 == 2.5 && asked?.1 == ["idea:a"], "only the cards on the Canvas, at the scale asked")
            #expect(part.0 != nil)

            map.imageExporter = { _, _ in Data("not a picture".utf8) }
            #expect(await shoot([:]).1?.contains("not a picture") == true)
            map.imageExporter = { _, _ in throw MCPError.invalidInput("the page is gone") }
            #expect(await shoot([:]).1?.contains("the page is gone") == true)
        }
    }
}

