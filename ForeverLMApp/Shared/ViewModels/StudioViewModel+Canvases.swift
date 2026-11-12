import Foundation

// MARK: - Canvases in the Space
//
// The learner's canvases, listed in the Space beside their pages and sites
// (docs/knowledge-map-design.md, "Canvases in the Space"; the rows are
// `KnowledgeMapCanvases`). Each act writes the canvas's layout row through
// `KnowledgeMapRows` and reseeds `canvases` from what it wrote, so the Space
// redraws at once and the other Macs follow through sync. A canvas files in
// a space and pins through the page rows (`page.space.<id>`,
// `page.pinned.<id>`), keyed by its id as a page's are by the record's.

extension StudioViewModel {
    /// The canvases the Space lists: the learner's own, on a Mac that shows
    /// the Canvas (`BetaFeatures`), and none in a team's library, whose
    /// members each place their own. In Screen record mode only those the
    /// take may show (`isVisibleInRecordingMode`), so All, Canvases, Pinned,
    /// Recents and the canvas pickers name no other; `canvases` stays whole.
    var listedCanvases: [KnowledgeMapCanvas] {
        guard listsCanvases else { return [] }
        guard screenRecordScope != nil else { return canvases.all }
        return canvases.all.filter { isVisibleInRecordingMode($0) }
    }

    /// Whether the Space lists canvases and offers New Canvas: on a Mac
    /// that shows the Canvas, in My Library.
    var listsCanvases: Bool {
        BetaFeatures.showsCanvas && activeTeamID == nil
    }

    /// **New Canvas**: makes one — in the space the Space has lit, when it
    /// has one — and opens it in `destinationWindowState`.
    func makeAndOpenCanvas(inPageSpace spaceID: String?, notebookID: String? = nil, in destinationWindowState: StudioWindowState?) {
        let canvas = createCanvas(inPageSpace: spaceID, notebookID: notebookID)
        openCanvas(canvas.id, in: destinationWindowState)
    }

    // MARK: Each window's Canvas

    /// `window`'s Canvas model: views read their own window's through this
    /// (a view drawn outside any Studio window has none, and reads the
    /// window's in scope). Made the first time it is asked for, on the canvas
    /// this Mac had open last (`KnowledgeMapOpenCanvas`), and wired then.
    func knowledgeMap(in window: StudioWindowState?) -> KnowledgeMapModel {
        let window = window ?? activeWindowState
        return window.canvas {
            let model = KnowledgeMapModel(mapID: KnowledgeMapOpenCanvas.initialID(
                stored: KnowledgeMapOpenCanvas.storedID,
                canvases: canvases
            ))
            wireCanvasModel(model, in: window)
            return model
        }
    }

    /// Puts `model` in `window`, wired for it.
    func setKnowledgeMap(_ model: KnowledgeMapModel, in window: StudioWindowState) {
        wireCanvasModel(model, in: window)
        window.setCanvas(model)
    }

    /// Every window's Canvas model, for what must reach all of them: library
    /// content read again, a row written from outside, a canvas deleted. A
    /// window that never asked for a Canvas has none.
    var knowledgeMaps: [KnowledgeMapModel] {
        allWindowStates.compactMap(\.canvasIfMade)
    }

    /// The models showing `canvasID`: one for each window open on it.
    func knowledgeMaps(showing canvasID: String) -> [KnowledgeMapModel] {
        knowledgeMaps.filter { $0.mapID == canvasID }
    }

    /// Whether `model` is still some window's Canvas: work that awaited
    /// checks this before writing to the model it started with, which the
    /// window may have left for another canvas since.
    func isShown(_ model: KnowledgeMapModel) -> Bool {
        knowledgeMaps.contains { $0 === model }
    }

    /// The window whose Canvas `model` is, when it still is one's.
    func window(showing model: KnowledgeMapModel) -> StudioWindowState? {
        allWindowStates.first { $0.canvasIfMade === model }
    }

    /// A canvas's row was written outside its models (renamed, trashed,
    /// filed, placed on from another canvas): every window open on it reads
    /// the row again.
    func reloadKnowledgeMaps(showing canvasID: String) {
        for model in knowledgeMaps(showing: canvasID) { model.reloadLayout() }
    }

    /// The canvas the Canvas pane shows, when it is listed.
    var openCanvas: KnowledgeMapCanvas? {
        canvases.canvas(knowledgeMap.mapID)
    }

    /// The canvas `map` shows, when it is listed.
    func canvas(of map: KnowledgeMapModel) -> KnowledgeMapCanvas? {
        canvases.canvas(map.mapID)
    }

    /// The name a Canvas pane gives the canvas `map` shows.
    func canvasName(of map: KnowledgeMapModel) -> String {
        canvas(of: map)?.name ?? KnowledgeMap.unnamedCanvasName
    }

    /// The name the Canvas pane gives the canvas it shows: its own, or the
    /// unnamed canvas's while nothing is written to it yet.
    var openCanvasName: String {
        openCanvas?.name ?? KnowledgeMap.unnamedCanvasName
    }

    /// Opens a canvas in the window's Canvas pane. Only that window turns to
    /// it; the others keep the canvas they show.
    func openCanvas(_ canvasID: String, in destinationWindowState: StudioWindowState? = nil) {
        let window = destinationWindowState ?? activeWindowState
        // The window remembers it for ⌘[ and ⌘] (`navigateCanvasHistory`),
        // after the canvas open before it when that one is listed (a canvas
        // with no row yet is nothing to go back to).
        let shown = knowledgeMap(in: window).mapID
        let previous = canvases.canvas(shown) == nil ? nil : shown
        window.canvasHistory.visit(canvasID, from: previous)
        showCanvas(canvasID, in: window)
        openKnowledgeMap(in: window)
    }

    /// The learner's canvases that are pinned and not in Trash, the newest
    /// pin first: the Space sidebar's Pinned, beside the pinned pages.
    var pinnedCanvases: [KnowledgeMapCanvas] {
        let listed = Dictionary(listedCanvases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pagePins.orderedPageIDs.compactMap { id in
            guard let canvas = listed[id], !canvas.isTrashed else { return nil }
            return canvas
        }
    }

    /// Makes `canvasID` the canvas `window` shows (the window in scope when
    /// nil), and the one a new window opens on. Another canvas gets a model
    /// of its own, so the last one's lens, selection, undo steps and a review
    /// in place stay with it and end there; the window's Minimap and Library
    /// switches stay as the learner left them in it. No other window changes.
    func showCanvas(_ canvasID: String, in window: StudioWindowState? = nil) {
        let window = window ?? activeWindowState
        KnowledgeMapOpenCanvas.remember(canvasID)
        let shown = knowledgeMap(in: window)
        guard shown.mapID != canvasID else { return }
        inWindow(window) { endKnowledgeMapReview() }
        let model = KnowledgeMapModel(mapID: canvasID)
        model.showsMinimap = shown.showsMinimap
        model.showsLibrary = shown.showsLibrary
        setKnowledgeMap(model, in: window)
    }

    /// Keeps `canvases` following a window's canvas's own writes: its last
    /// activity moves as the learner places things, and the other windows
    /// open on the same canvas draw what was written.
    func wireCanvasModel(_ model: KnowledgeMapModel, in window: StudioWindowState) {
        // A command from a toolbar, the add box or an assistant runs in the
        // window whose Canvas this is.
        let windowID = window.id
        model.activeWindowID = { windowID }
        // A paper placed for the first time shows its page, on a canvas made a
        // moment ago as on any other.
        model.pageFaceDefault = { [weak self] sourceID in self?.knowledgeMapSourceShowsPage(sourceID) == true }
        model.onLayoutWritten = { [weak self, weak model] id, layout in
            guard let self else { return }
            self.canvases = self.canvases.setting(layout, for: id)
            // A version is kept on its own once a burst of edits has settled.
            CanvasAutoVersions.shared.layoutWritten(canvasID: id, layout: layout, storage: self.storage)
            // Another window open on the same canvas reads the row just
            // written. Every write merges into the stored row
            // (`KnowledgeMapRows.update`), so two windows never overwrite
            // each other; a read publishes nothing when nothing differs.
            for other in self.knowledgeMaps(showing: id) where other !== model { other.reloadLayout() }
        }
        // A source set down inside a notebook's frame joins the notebook
        // (product owner, 2026-10-09: the notebook is its frame). Only a source the
        // notebook does not hold, in a notebook that takes new things.
        model.onSourcesSetDownInFrame = { [weak self] notebookID, sourceIDs in
            guard let self, self.importableNotebook(notebookID) != nil else { return }
            let held = Set((self.notebook(id: notebookID)?.approvedSourceIDs ?? []).map(self.canonicalSourceID))
            let joining = sourceIDs.filter { !held.contains(self.canonicalSourceID($0)) }
            guard !joining.isEmpty else { return }
            Task { await self.addSourcesToNotebookContext(joining, notebookID: notebookID) }
        }
        // A Doc, site or animation set down there joins it too, unless it is
        // the notebook's already.
        model.onDocsSetDownInFrame = { [weak self] notebookID, docIDs in
            guard let self, self.importableNotebook(notebookID) != nil else { return }
            let joining = docIDs.filter { id in
                guard let artifact = self.artifacts.first(where: { $0.id == id }) else { return false }
                return artifact.homeNotebookID != notebookID && !artifact.linkedNotebookIDs.contains(notebookID)
            }
            guard !joining.isEmpty else { return }
            Task { for id in joining { await self.addArtifact(id, toNotebook: notebookID) } }
        }
    }

    /// Makes a canvas named `name` — in the space `spaceID` when one is
    /// given — and returns it. Its row is written at once, so it is listed
    /// before anything is placed on it. No network: the row is local first
    /// and syncs after.
    @discardableResult
    func createCanvas(named name: String = KnowledgeMap.newCanvasName, inPageSpace spaceID: String? = nil, notebookID: String? = nil, now: Date = Date()) -> KnowledgeMapCanvas {
        let id = KnowledgeMap.newCanvasID()
        let stamp = now.timeIntervalSince1970
        let cleaned = KnowledgeMapCanvases.cleanedName(name) ?? KnowledgeMap.newCanvasName
        let layout = KnowledgeMapRows.update(mapID: id, now: now) { row in
            row.name = .init(text: cleaned, at: stamp)
            row.created = stamp
            if let notebookID { row.notebook = .init(id: notebookID, at: stamp) }
        }
        canvases = canvases.setting(layout, for: id)
        if let spaceID { filePages([id], inPageSpace: spaceID) }
        return KnowledgeMapCanvas(id: id, layout: layout)
    }

    /// The notebook's canvases, newest first: what its menu lists.
    func canvases(inNotebook notebookID: String) -> [KnowledgeMapCanvas] {
        listsCanvases ? canvases.inUse(inNotebook: notebookID) : []
    }

    /// Files a canvas in a notebook, or (nil) takes it out of its notebook.
    func setCanvasNotebook(_ canvasID: String, to notebookID: String?, now: Date = Date()) {
        refreshCanvasesFromRows()
        guard let canvas = canvases.canvas(canvasID), canvas.notebookID != notebookID else { return }
        writeCanvasRow(canvasID, now: now) { row, at in row.notebook = .init(id: notebookID, at: at) }
    }

    /// Renames a canvas. A name with nothing in it, the same name, or a
    /// canvas gone since changes nothing.
    func renameCanvas(_ canvasID: String, to name: String, now: Date = Date()) {
        refreshCanvasesFromRows()
        // The open canvas may have no row yet (the first canvas, before
        // anything is placed): naming it writes one.
        let current = canvases.canvas(canvasID)?.name
            ?? (canvasID == knowledgeMap.mapID ? KnowledgeMap.unnamedCanvasName : nil)
        guard let current,
              let cleaned = KnowledgeMapCanvases.cleanedName(name),
              cleaned != current else { return }
        writeCanvasRow(canvasID, now: now) { row, at in row.name = .init(text: cleaned, at: at) }
    }

    /// **Move to Trash**: the canvases leave the lists and wait in Trash,
    /// whole, until restored or deleted forever.
    func moveCanvasesToTrash(_ canvasIDs: [String], now: Date = Date()) {
        refreshCanvasesFromRows()
        let moving = canvasIDs.filter { canvases.isInUse($0) }
        guard !moving.isEmpty else { return }
        for id in moving {
            writeCanvasRow(id, now: now) { row, at in row.trash = .init(since: at, at: at) }
        }
        showToast(moving.count == 1 ? "Moved to Trash" : "Moved \(moving.count) canvases to Trash")
    }

    /// **Restore**: the canvases come back to the lists, where they were.
    func restoreCanvases(_ canvasIDs: [String], now: Date = Date()) {
        refreshCanvasesFromRows()
        for id in canvasIDs where canvases.canvas(id)?.isTrashed == true {
            writeCanvasRow(id, now: now) { row, at in row.trash = .init(since: nil, at: at) }
        }
    }

    /// **Delete Forever**: the canvases' rows go, and with them their place
    /// in a space and their pin. Only a canvas in Trash is deleted, as only
    /// a page in Trash is.
    func deleteCanvasesForever(_ canvasIDs: [String]) {
        refreshCanvasesFromRows()
        let deleting = canvasIDs.filter { canvases.canvas($0)?.isTrashed == true }
        guard !deleting.isEmpty else { return }
        // A window may be open on one of them (its Trash banner is showing).
        // Left open, its next edit would write its row back, empty and
        // unnamed: the newest canvas still in use opens there instead, or a
        // new one when none is left. Every window open on one turns to it.
        let stranded = allWindowStates.filter { window in
            window.canvasIfMade.map { deleting.contains($0.mapID) } == true
        }
        if !stranded.isEmpty {
            let next = canvases.all
                .filter { !$0.isTrashed && !deleting.contains($0.id) }
                .max { $0.updatedAt < $1.updatedAt }
            let nextID = next?.id ?? createCanvas().id
            for window in stranded { showCanvas(nextID, in: window) }
        }
        for id in deleting {
            KnowledgeMapRows.remove(mapID: id)
            canvases = canvases.setting(nil, for: id)
            setPagePinned(id, pinned: false)
            SpaceRecents.shared.forget(.canvas, id: id)
        }
        forgetPageSpaces(of: deleting)
        // Its versions on this Mac go with it.
        deleting.forEach { CanvasAutoVersions.shared.forget($0) }
        Task { [storage] in await storage.removeCanvasHistory(canvasIDs: deleting) }
    }

    /// Writes one change to a canvas's row and reseeds the list from it; every
    /// window open on the canvas re-reads its row, so its name and Trash mark
    /// follow.
    private func writeCanvasRow(_ canvasID: String, now: Date, _ change: (inout KnowledgeMapLayout, Double) -> Void) {
        let stamp = now.timeIntervalSince1970
        let layout = KnowledgeMapRows.update(mapID: canvasID, now: now) { row in change(&row, stamp) }
        canvases = canvases.setting(layout, for: canvasID)
        reloadKnowledgeMaps(showing: canvasID)
    }

    /// The rows as stored now, before an act writes over them: a canvas
    /// deleted on another Mac must not be written back from this Mac's list.
    func refreshCanvasesFromRows() {
        let stored = KnowledgeMapRows.canvases()
        if stored != canvases { canvases = stored }
    }
}
