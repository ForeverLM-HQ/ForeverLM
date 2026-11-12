import Foundation
import Testing
@testable import ForeverLM

// Each window has its own Canvas and its own Atlas
// (docs/knowledge-map-design.md, "Windows"): opening a canvas or changing its
// view in one window leaves the other windows as they were, two windows on
// the same canvas draw each other's writes, and what is true of the library
// reaches every window.

@MainActor
@Suite("The Canvas and the Atlas are each window's own", .serialized)
struct KnowledgeMapWindowsTests {
    /// A view model on its own defaults and store, with a second window
    /// registered beside the one it acts in: `left` is the window in scope
    /// (the key window, to the view model), `right` is the other one.
    private func withTwoWindows(
        _ body: (StudioViewModel, _ left: StudioWindowState, _ right: StudioWindowState) async throws -> Void
    ) async throws {
        let suiteName = "KnowledgeMapWindowsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeMapWindows_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let right = StudioWindowState()
        StudioWindowRegistry.shared.register(right)
        defer { StudioWindowRegistry.shared.unregister(right) }
        try await KnowledgeMapRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
            try await PageSpaceRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
                let vm = StudioViewModel(storageService: StorageService(storeRoot: root), observeCloudKitChanges: false)
                try await body(vm, vm.activeWindowState, right)
            }
        }
    }

    private func paper(_ id: String) -> StudioArticle {
        StudioArticle(url: "https://example.com/\(id)", title: "Paper \(id)", sourceType: .paper, id: id)
    }

    private func cards(_ model: KnowledgeMapModel, _ ids: [String]) {
        model.rebuildContent(articles: ids.map(paper), ideas: [], notebooks: [], chats: [], artifacts: [], firstHighlights: [:])
    }

    // MARK: Two windows on different canvases

    @Test("Opening a canvas in one window leaves the other on its own; the view model answers for the window in scope")
    func openingIsPerWindow() async throws {
        try await withTwoWindows { vm, left, right in
            let first = vm.createCanvas(named: "First"), second = vm.createCanvas(named: "Second")
            vm.openCanvas(first.id, in: left)
            let leftModel = vm.knowledgeMap(in: left)
            let leftHistory = left.canvasHistory.stack
            vm.openCanvas(second.id, in: right)

            #expect(vm.knowledgeMap(in: left) === leftModel, "the other window keeps its model")
            #expect(vm.knowledgeMap(in: left).mapID == first.id)
            #expect(vm.knowledgeMap(in: right).mapID == second.id)
            #expect(vm.knowledgeMap === leftModel, "a command acts on the window in scope")
            #expect(vm.inWindow(right) { vm.knowledgeMap } === vm.knowledgeMap(in: right))
            #expect(vm.inWindow(right) { vm.openCanvasName } == "Second")
            #expect(vm.openCanvasName == "First")
            #expect(KnowledgeMapOpenCanvas.storedID == second.id, "a new window opens on the one opened last")

            #expect(right.canvasHistory.stack.last == second.id)
            #expect(left.canvasHistory.stack == leftHistory, "each window walks its own history")
            vm.navigateCanvasHistory(.back, in: right)
            #expect(vm.knowledgeMap(in: left) === leftModel, "walking one window's history moves only it")
        }
    }

    @Test("Minimap, the Library, Focus, the tool, a selection and a popup in one window change nothing in the other")
    func viewIsPerWindow() async throws {
        try await withTwoWindows { vm, left, right in
            let first = vm.createCanvas(named: "First"), second = vm.createCanvas(named: "Second")
            vm.openCanvas(first.id, in: left)
            vm.openCanvas(second.id, in: right)
            let leftModel = vm.knowledgeMap(in: left), rightModel = vm.knowledgeMap(in: right)
            let before = (leftModel.showsMinimap, leftModel.showsLibrary)
            cards(leftModel, ["a"])
            cards(rightModel, ["a"])

            rightModel.showsMinimap = !before.0
            rightModel.showsLibrary = !before.1
            rightModel.focusMode = true
            rightModel.tool = "region"
            rightModel.place([(ref: "source:a", x: 0, y: 0)])
            rightModel.selection = ["source:a"]
            vm.inWindow(right) { vm.showKnowledgeMapPopup("source:a", near: CGRect(x: 1, y: 2, width: 3, height: 4)) }

            #expect(leftModel.showsMinimap == before.0 && leftModel.showsLibrary == before.1)
            #expect(!leftModel.focusMode && leftModel.tool == "select")
            #expect(leftModel.selection.isEmpty && leftModel.popup == nil)
            #expect(leftModel.layout.placements.isEmpty, "another canvas")
            #expect(rightModel.popup?.windowID == right.id, "drawn in the window it was asked for in")

            // The window keeps its switches when it turns to another canvas.
            vm.showCanvas(first.id, in: right)
            let turned = vm.knowledgeMap(in: right)
            #expect(turned !== rightModel && turned.mapID == first.id)
            #expect(turned.showsMinimap == !before.0 && turned.showsLibrary == !before.1)
            #expect(turned.selection.isEmpty && !turned.focusMode, "a selection and Focus end with the canvas's model")
            #expect(vm.knowledgeMap(in: left) === leftModel)
        }
    }

    @Test("A commanded act lands in its own window: a model's commands name the window it is in")
    func commandsNameTheirWindow() async throws {
        try await withTwoWindows { vm, left, right in
            let rightModel = vm.knowledgeMap(in: right)
            rightModel.send(.fit)
            #expect(rightModel.takeCommands(for: right.id).count == 1)
            let leftModel = vm.knowledgeMap(in: left)
            leftModel.send(.fit)
            #expect(rightModel.takeCommands(for: right.id).isEmpty, "the other window's model was sent nothing")
            #expect(leftModel.takeCommands(for: left.id).count == 1)
        }
    }

    @Test("A canvas renamed, trashed or deleted reaches the window open on it, whichever window is key")
    func rowWritesReachEveryWindow() async throws {
        try await withTwoWindows { vm, left, right in
            let first = vm.createCanvas(named: "First"), second = vm.createCanvas(named: "Second")
            vm.openCanvas(first.id, in: left)
            vm.openCanvas(second.id, in: right)
            let leftModel = vm.knowledgeMap(in: left)

            vm.renameCanvas(second.id, to: "Renamed")
            #expect(vm.knowledgeMap(in: right).layout.name?.text == "Renamed")

            vm.moveCanvasesToTrash([second.id])
            #expect(vm.knowledgeMap(in: right).layout.trash?.since != nil, "its Trash banner shows")
            vm.deleteCanvasesForever([second.id])
            #expect(vm.knowledgeMap(in: right).mapID == first.id, "the window open on it turns to the canvas still in use")
            #expect(vm.knowledgeMap(in: left) === leftModel, "the window on another canvas is left alone")
            #expect(vm.canvases.canvas(second.id) == nil)
        }
    }

    @Test("Each window's cards are read for its own canvas, and a library change moves every window's signature")
    func contentIsPerModel() async throws {
        try await withTwoWindows { vm, left, right in
            let first = vm.createCanvas(named: "First"), second = vm.createCanvas(named: "Second")
            vm.openCanvas(first.id, in: left)
            vm.openCanvas(second.id, in: right)
            let leftModel = vm.knowledgeMap(in: left), rightModel = vm.knowledgeMap(in: right)

            let leftBefore = vm.knowledgeMapContentSignature(for: leftModel)
            let rightBefore = vm.knowledgeMapContentSignature(for: rightModel)
            vm.articles = [paper("a")]
            #expect(vm.knowledgeMapContentSignature(for: leftModel) != leftBefore)
            #expect(vm.knowledgeMapContentSignature(for: rightModel) != rightBefore)

            await vm.refreshKnowledgeMapContent(for: rightModel)
            #expect(rightModel.nodesByRef["source:a"] != nil)
            #expect(leftModel.nodesByRef["source:a"] == nil, "its own pane reads its own cards")
            await vm.refreshKnowledgeMapContent(for: leftModel)
            #expect(leftModel.nodesByRef["source:a"] != nil)

            // A canvas's shortcut cards are the other canvases, per model.
            #expect(vm.knowledgeMapShortcutCanvases(for: leftModel).map(\.id).contains(first.id) == false)
            #expect(vm.knowledgeMapShortcutCanvases(for: rightModel).map(\.id).contains(second.id) == false)
        }
    }

    // MARK: Two windows on the same canvas

    @Test("Two windows on one canvas: each has its own model, and a write in either shows in the other")
    func sameCanvasSharesTheLayout() async throws {
        try await withTwoWindows { vm, left, right in
            let shared = vm.createCanvas(named: "Shared")
            vm.openCanvas(shared.id, in: left)
            vm.openCanvas(shared.id, in: right)
            let leftModel = vm.knowledgeMap(in: left), rightModel = vm.knowledgeMap(in: right)
            #expect(leftModel !== rightModel && leftModel.mapID == rightModel.mapID)
            #expect(vm.knowledgeMaps(showing: shared.id).count == 2)
            cards(leftModel, ["a", "b"])
            cards(rightModel, ["a", "b"])

            let rightRevision = rightModel.layoutRevision
            leftModel.place([(ref: "source:a", x: 10, y: 20)])
            #expect(rightModel.layout.placements["source:a"]?.x == 10, "the other window reads the row just written")
            #expect(rightModel.layoutRevision != rightRevision, "and pushes it to its page")

            rightModel.place([(ref: "source:b", x: 300, y: 20)])
            #expect(Set(leftModel.layout.placements.keys) == ["source:a", "source:b"])
            #expect(Set(KnowledgeMapRows.layout(mapID: shared.id).placements.keys) == ["source:a", "source:b"], "neither write overwrote the other")
            #expect(leftModel.layout == rightModel.layout)

            // The view of it stays each window's own.
            leftModel.selection = ["source:a"]
            rightModel.focusMode = true
            #expect(rightModel.selection.isEmpty && !leftModel.focusMode)
        }
    }

    @Test("Undo in one window takes back that window's edit only, and the other window draws it")
    func sameCanvasUndoIsPerWindow() async throws {
        try await withTwoWindows { vm, left, right in
            let shared = vm.createCanvas(named: "Shared")
            vm.openCanvas(shared.id, in: left)
            vm.openCanvas(shared.id, in: right)
            let leftModel = vm.knowledgeMap(in: left), rightModel = vm.knowledgeMap(in: right)
            cards(leftModel, ["a", "b"])
            cards(rightModel, ["a", "b"])
            leftModel.place([(ref: "source:a", x: 0, y: 0)])
            rightModel.place([(ref: "source:b", x: 300, y: 0)])

            #expect(rightModel.canUndo && leftModel.canUndo)
            rightModel.undo()
            #expect(Set(leftModel.layout.placements.keys) == ["source:a"], "the other window's card stays, and it sees the undo")
            #expect(Set(rightModel.layout.placements.keys) == ["source:a"])
            #expect(leftModel.canUndo, "its own step is still its own")
        }
    }

    @Test("A canvas open in another window is written through that window's model, and the window acting stays where it is")
    func actsReachTheWindowOpenOnIt() async throws {
        try await withTwoWindows { vm, left, right in
            let first = vm.createCanvas(named: "First"), second = vm.createCanvas(named: "Second")
            vm.openCanvas(first.id, in: left)
            vm.openCanvas(second.id, in: right)
            let leftModel = vm.knowledgeMap(in: left), rightModel = vm.knowledgeMap(in: right)
            cards(rightModel, ["a"])
            rightModel.place([(ref: "source:a", x: 0, y: 0)])

            #expect(vm.knowledgeMapModel(showing: second.id) === rightModel)
            #expect(vm.knowledgeMapModel(showing: first.id) === leftModel)
            #expect(vm.currentCanvasLayout(second.id) == rightModel.layout)
            #expect(vm.isShown(rightModel) && vm.window(showing: rightModel) === right)

            // Deleting the canvas the key window shows leaves the other's.
            vm.moveCanvasesToTrash([first.id])
            vm.deleteCanvasesForever([first.id])
            #expect(vm.knowledgeMap(in: right) === rightModel)
            #expect(vm.knowledgeMap(in: left).mapID == second.id)
            #expect(!vm.isShown(leftModel), "the model the window left is no window's now")
        }
    }

    // MARK: The Atlas

    private func atlas(_ id: String, topic: String) -> Atlas {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return Atlas(
            id: id,
            topic: topic,
            scope: AtlasScope(itemRefs: [], notebookID: nil),
            rootID: "c1",
            concepts: [],
            passages: [],
            createdAt: at,
            updatedAt: at,
            model: "test-model"
        )
    }

    @Test("Each window keeps its own Atlas, level and view; the view model answers for the window in scope")
    func atlasIsPerWindow() async throws {
        try await withTwoWindows { vm, left, right in
            #expect(left.atlas !== right.atlas)
            #expect(vm.atlas === left.atlas)
            #expect(vm.inWindow(right) { vm.atlas } === right.atlas)

            right.atlas.show(atlas("atlas:one", topic: "Mitophagy"))
            right.atlas.level = .steps
            right.atlas.viewMode = .ladder
            #expect(left.atlas.current == nil)
            #expect(left.atlas.level == .line && left.atlas.viewMode == .fisheye)

            left.atlas.show(atlas("atlas:two", topic: "Membrane potential"))
            #expect(right.atlas.current?.id == "atlas:one")
            #expect(vm.atlasModels.contains { $0 === left.atlas } && vm.atlasModels.contains { $0 === right.atlas })
        }
    }

    @Test("The list of Atlases reaches every window, and one deleted goes from each window showing it")
    func atlasListAndDeleteReachEveryWindow() async throws {
        try await withTwoWindows { vm, left, right in
            let kept = atlas("atlas:kept", topic: "Kept"), gone = atlas("atlas:gone", topic: "Gone")
            try await vm.storage.saveAtlasRow(try kept.row())
            try await vm.storage.saveAtlasRow(try gone.row())
            await vm.refreshAtlasListings()
            #expect(Set(left.atlas.listings.map(\.id)) == ["atlas:kept", "atlas:gone"])
            #expect(right.atlas.listings == left.atlas.listings)

            left.atlas.show(kept)
            right.atlas.show(gone)
            try await vm.deleteAtlas(id: "atlas:gone")
            #expect(right.atlas.current == nil, "gone from the window that showed it, though another is key")
            #expect(left.atlas.current?.id == "atlas:kept")
            #expect(right.atlas.listings.map(\.id) == ["atlas:kept"])
        }
    }
}
