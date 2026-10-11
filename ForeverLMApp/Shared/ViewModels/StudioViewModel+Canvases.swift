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

    /// The canvas the Canvas pane shows, when it is listed.
    var openCanvas: KnowledgeMapCanvas? {
        canvases.canvas(knowledgeMap.mapID)
    }

    /// The name the Canvas pane gives the canvas it shows: its own, or the
    /// unnamed canvas's while nothing is written to it yet.
    var openCanvasName: String {
        openCanvas?.name ?? KnowledgeMap.unnamedCanvasName
    }

    /// Opens a canvas in the window's Canvas pane, making it the canvas open
    /// on this Mac (every window showing the Canvas shows it).
    func openCanvas(_ canvasID: String, in destinationWindowState: StudioWindowState? = nil) {
        // The window remembers it for ⌘[ and ⌘] (`navigateCanvasHistory`),
        // after the canvas open before it when that one is listed (a canvas
        // with no row yet is nothing to go back to).
        let previous = canvases.canvas(knowledgeMap.mapID) == nil ? nil : knowledgeMap.mapID
        (destinationWindowState ?? activeWindowState).canvasHistory.visit(canvasID, from: previous)
        showCanvas(canvasID)
        openKnowledgeMap(in: destinationWindowState)
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

    /// Makes `canvasID` the canvas open on this Mac. Another canvas gets a
    /// model of its own, so the last one's lens, selection, undo steps and a
    /// review in place stay with it and end there.
    func showCanvas(_ canvasID: String) {
        KnowledgeMapOpenCanvas.remember(canvasID)
        guard knowledgeMap.mapID != canvasID else { return }
        endKnowledgeMapReview()
        let model = KnowledgeMapModel(mapID: canvasID)
        wireCanvasModel(model)
        knowledgeMap = model
    }

    /// Keeps `canvases` following the open canvas's own writes: its last
    /// activity moves as the learner places things.
    func wireCanvasModel(_ model: KnowledgeMapModel) {
        // A paper placed for the first time shows its page, on a canvas made a
        // moment ago as on any other.
        model.pageFaceDefault = { [weak self] sourceID in self?.knowledgeMapSourceShowsPage(sourceID) == true }
        model.onLayoutWritten = { [weak self] id, layout in
            guard let self else { return }
            self.canvases = self.canvases.setting(layout, for: id)
            // A version is kept on its own once a burst of edits has settled.
            CanvasAutoVersions.shared.layoutWritten(canvasID: id, layout: layout, storage: self.storage)
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

    /// Writes one change to a canvas's row and reseeds the list from it; the
    /// open canvas re-reads its row, so its name and Trash mark follow.
    private func writeCanvasRow(_ canvasID: String, now: Date, _ change: (inout KnowledgeMapLayout, Double) -> Void) {
        let stamp = now.timeIntervalSince1970
        let layout = KnowledgeMapRows.update(mapID: canvasID, now: now) { row in change(&row, stamp) }
        canvases = canvases.setting(layout, for: canvasID)
        if knowledgeMap.mapID == canvasID { knowledgeMap.reloadLayout() }
    }

    /// The rows as stored now, before an act writes over them: a canvas
    /// deleted on another Mac must not be written back from this Mac's list.
    func refreshCanvasesFromRows() {
        let stored = KnowledgeMapRows.canvases()
        if stored != canvases { canvases = stored }
    }
}
