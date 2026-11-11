import Foundation
import Testing
@testable import ForeverLM

/// Canvases in the Space (docs/knowledge-map-design.md, "Canvases in the
/// Space"): a canvas is its layout row, which carries its name, when it was
/// made and its Trash mark, merged as the placements are.
@Suite("Canvases in the Space: the rows")
struct KnowledgeMapCanvasRowTests {
    @Test("A row written before canvases had names reads as before, and encodes without the new keys")
    func olderRowsUnchanged() throws {
        var layout = KnowledgeMapLayout()
        layout.place("idea:a", x: 1, y: 2, at: 100)
        let value = layout.preferenceValue
        #expect(!value.contains("\"name\""))
        #expect(!value.contains("\"trash\""))
        #expect(!value.contains("\"created\""))
        let read = try #require(KnowledgeMapLayout(preferenceValue: value))
        #expect(read == layout)
        #expect(read.name == nil && read.created == nil && read.trash == nil)
    }

    @Test("A name, a made time and a Trash mark round-trip through the row")
    func newKeysRoundTrip() throws {
        var layout = KnowledgeMapLayout()
        layout.name = .init(text: "PINK1 and Parkin", at: 200)
        layout.created = 150
        layout.trash = .init(since: 300, at: 300)
        let read = try #require(KnowledgeMapLayout(preferenceValue: layout.preferenceValue))
        #expect(read == layout)
    }

    @Test("Two copies merge: the newer name and Trash mark win, the earlier made time stays, either way round")
    func mergeCanvasFacts() {
        var mine = KnowledgeMapLayout()
        mine.name = .init(text: "Mitophagy", at: 10)
        mine.created = 5
        mine.trash = .init(since: 20, at: 20)
        var theirs = KnowledgeMapLayout()
        theirs.name = .init(text: "Mitophagy, the steps", at: 30)
        theirs.created = 7
        theirs.trash = .init(since: nil, at: 25)

        let merged = mine.merged(with: theirs)
        #expect(merged == theirs.merged(with: mine), "commutative")
        #expect(merged.name?.text == "Mitophagy, the steps")
        #expect(merged.created == 5)
        #expect(merged.trash?.since == nil, "the later restore wins over the earlier Trash")

        // A copy that never knew the name keeps the other's.
        #expect(KnowledgeMapLayout().merged(with: mine).name == mine.name)
    }

    @Test("A canvas of a notebook: the mark round-trips, the newer write wins, unlinking is a write, and the catalogue lists it by notebook")
    func notebookMark() throws {
        var mine = KnowledgeMapLayout()
        mine.created = 5
        mine.notebook = .init(id: "nb-1", at: 10)
        let read = try #require(KnowledgeMapLayout(preferenceValue: mine.preferenceValue))
        #expect(read == mine)
        #expect(!KnowledgeMapLayout().preferenceValue.contains("\"notebook\""), "a canvas of no notebook encodes as before")

        var theirs = KnowledgeMapLayout()
        theirs.notebook = .init(id: nil, at: 20)
        let merged = mine.merged(with: theirs)
        #expect(merged == theirs.merged(with: mine), "commutative")
        #expect(merged.notebook?.id == nil, "the later unlinking wins")

        let catalogue = KnowledgeMapCanvases([
            KnowledgeMapCanvas(id: "a", layout: mine),
            KnowledgeMapCanvas(id: "b", layout: theirs),
        ])
        #expect(catalogue.inUse(inNotebook: "nb-1").map(\.id) == ["a"])
        #expect(catalogue.canvas("b")?.notebookID == nil)
    }

    @Test("Every layout row lists one canvas; one never named is the first canvas, Canvas")
    func catalogueFromRows() throws {
        var first = KnowledgeMapLayout()
        first.place("idea:a", x: 0, y: 0, at: 1_000)
        first.place("idea:b", x: 0, y: 0, at: 2_000)
        var made = KnowledgeMapLayout()
        made.name = .init(text: "  Aging clocks ", at: 3_000)
        made.created = 3_000
        var trashed = KnowledgeMapLayout()
        trashed.name = .init(text: "Old", at: 500)
        trashed.created = 500
        trashed.trash = .init(since: 4_000, at: 4_000)

        let canvases = KnowledgeMapCanvases(rows: [
            KnowledgeMap.layoutPreferenceKey(mapID: KnowledgeMap.firstCanvasID): first.preferenceValue,
            KnowledgeMap.layoutPreferenceKey(mapID: "cnv-made"): made.preferenceValue,
            KnowledgeMap.layoutPreferenceKey(mapID: "cnv-old"): trashed.preferenceValue,
            "map.layout.": made.preferenceValue,
            "map.layout.cnv-junk": "not json",
            "pageSpace.psp-1": "Aging",
        ])
        #expect(canvases.all.map(\.id) == ["cnv-made", KnowledgeMap.firstCanvasID, "cnv-old"], "newest made first")
        let firstCanvas = try #require(canvases.canvas(KnowledgeMap.firstCanvasID))
        #expect(firstCanvas.name == KnowledgeMap.unnamedCanvasName)
        #expect(firstCanvas.createdAt == Date(timeIntervalSince1970: 1_000), "made when it was first written")
        #expect(firstCanvas.updatedAt == Date(timeIntervalSince1970: 2_000))
        #expect(canvases.canvas("cnv-made")?.name == "Aging clocks")
        #expect(canvases.canvas("cnv-old")?.isTrashed == true)
        #expect(canvases.inUse.map(\.id) == ["cnv-made", KnowledgeMap.firstCanvasID])
        #expect(canvases.isInUse("cnv-made"))
        #expect(!canvases.isInUse("cnv-old"))
        #expect(!canvases.isInUse("cnv-none"))
        #expect(canvases.mostRecentlyActive?.id == "cnv-made")
    }

    @Test("A launch opens the canvas this Mac had open while it is in use, else the one last active, else the first")
    func initialCanvas() {
        var made = KnowledgeMapLayout()
        made.name = .init(text: "Made", at: 50)
        made.created = 50
        var trashed = KnowledgeMapLayout()
        trashed.created = 60
        trashed.trash = .init(since: 70, at: 70)
        let canvases = KnowledgeMapCanvases([
            KnowledgeMapCanvas(id: "cnv-made", layout: made),
            KnowledgeMapCanvas(id: "cnv-old", layout: trashed),
        ])
        #expect(KnowledgeMapOpenCanvas.initialID(stored: "cnv-made", canvases: canvases) == "cnv-made")
        #expect(KnowledgeMapOpenCanvas.initialID(stored: "cnv-old", canvases: canvases) == "cnv-made", "a canvas in Trash is not reopened")
        #expect(KnowledgeMapOpenCanvas.initialID(stored: "cnv-gone", canvases: canvases) == "cnv-made")
        #expect(KnowledgeMapOpenCanvas.initialID(stored: nil, canvases: KnowledgeMapCanvases()) == KnowledgeMap.firstCanvasID)
    }

    @Test("A canvas is a Space place the window remembers, and the Space lists it there or in its space")
    func spacePlace() {
        #expect(SpaceDestination(key: SpaceDestination.canvases.key) == .canvases)
        let canvas = KnowledgeMapCanvas(id: "cnv-1", name: "Aging", createdAt: Date(), updatedAt: Date())
        let spaces = PageSpaces(names: ["psp-1": "Aging"], memberships: ["cnv-1": "psp-1"])
        #expect(SpaceDestination.listing(canvas, within: .space("psp-1"), spaces: spaces) == .space("psp-1"))
        #expect(SpaceDestination.listing(canvas, within: .all, spaces: spaces) == .canvases)
        let trashed = KnowledgeMapCanvas(id: "cnv-1", name: "Aging", createdAt: Date(), updatedAt: Date(), trashedAt: Date())
        #expect(SpaceDestination.listing(trashed, within: .space("psp-1"), spaces: spaces) == .trash)
    }
}

/// The view model's acts on canvases: each writes the canvas's row, and the
/// list follows at once.
@MainActor
@Suite("Canvases in the Space: the acts")
struct KnowledgeMapCanvasActTests {
    private func withCanvasDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "KnowledgeMapCanvasActTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
            try PageSpaceRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
                try body(defaults)
            }
        }
    }

    @Test("New Canvas writes a named row at once, filed in the space asked for, and opening it gives it a model of its own")
    func createAndOpen() throws {
        try withCanvasDefaults { defaults in
            let vm = makeViewModel()
            let space = try #require(vm.createPageSpace(named: "Aging"))
            let canvas = vm.createCanvas(named: "Clocks", inPageSpace: space.id)
            #expect(canvas.id.hasPrefix(KnowledgeMap.canvasIDPrefix))
            #expect(vm.canvases.canvas(canvas.id)?.name == "Clocks")
            #expect(defaults.string(forKey: KnowledgeMap.layoutPreferenceKey(mapID: canvas.id)) != nil, "listed before anything is placed")
            #expect(vm.pageSpace(ofPage: canvas.id) == space)

            let before = vm.knowledgeMap
            vm.showCanvas(canvas.id)
            #expect(vm.knowledgeMap.mapID == canvas.id)
            #expect(vm.knowledgeMap !== before)
            #expect(KnowledgeMapOpenCanvas.storedID == canvas.id, "a relaunch reopens it")
            vm.showCanvas(canvas.id)
            #expect(vm.knowledgeMap.mapID == canvas.id, "opening the open canvas keeps its model")

            // A placement on the open canvas moves its last activity in the list.
            vm.knowledgeMap.place([(ref: "idea:a", x: 0, y: 0)])
            #expect(vm.canvases.canvas(canvas.id)?.updatedAt ?? .distantPast >= canvas.updatedAt)
        }
    }

    @Test("Rename, Trash, Restore and Delete Forever write the row, and only a canvas in Trash is deleted")
    func lifecycle() throws {
        try withCanvasDefaults { defaults in
            let vm = makeViewModel()
            let canvas = vm.createCanvas(named: "Draft")
            vm.renameCanvas(canvas.id, to: "  Mitophagy  ")
            #expect(vm.canvases.canvas(canvas.id)?.name == "Mitophagy")
            vm.renameCanvas(canvas.id, to: "   ")
            #expect(vm.canvases.canvas(canvas.id)?.name == "Mitophagy", "a blank name changes nothing")

            vm.setPagePinned(canvas.id, pinned: true)
            vm.deleteCanvasesForever([canvas.id])
            #expect(vm.canvases.canvas(canvas.id) != nil, "a canvas not in Trash is not deleted")

            vm.moveCanvasesToTrash([canvas.id])
            #expect(vm.canvases.canvas(canvas.id)?.isTrashed == true)
            vm.restoreCanvases([canvas.id])
            #expect(vm.canvases.canvas(canvas.id)?.isTrashed == false)

            vm.moveCanvasesToTrash([canvas.id])
            vm.deleteCanvasesForever([canvas.id])
            #expect(vm.canvases.canvas(canvas.id) == nil)
            #expect(defaults.object(forKey: KnowledgeMap.layoutPreferenceKey(mapID: canvas.id)) == nil)
            #expect(!vm.isPagePinned(canvas.id), "its pin goes with it")
        }
    }

    @Test("Naming the open canvas before anything is on it writes its row")
    func nameUnwrittenCanvas() throws {
        try withCanvasDefaults { _ in
            let vm = makeViewModel()
            vm.showCanvas(KnowledgeMap.firstCanvasID)
            #expect(vm.canvases.canvas(KnowledgeMap.firstCanvasID) == nil)
            vm.renameCanvas(KnowledgeMap.firstCanvasID, to: "Everything")
            #expect(vm.canvases.canvas(KnowledgeMap.firstCanvasID)?.name == "Everything")
        }
    }
}
