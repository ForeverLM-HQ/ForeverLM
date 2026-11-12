import Foundation

// MARK: - Named versions of a canvas
//
// Heptabase's version history of a whiteboard (docs/knowledge-map-design.md,
// "Versions, export and publishing"): the learner names a version
// (**Save Version…**, ⌥⇧⌘S), the app keeps one on its own after a burst of
// edits, and **Versions…** lists them with Restore and Delete. A version is a
// snapshot of the canvas's layout row, kept on this Mac only
// (`KnowledgeMapVersionHistory`). The same calls answer the MCP tools
// `list_canvas_versions`, `save_canvas_version` and `restore_canvas_version`.

extension StudioViewModel {
    /// The layout a canvas has now: the model of a window open on it, else
    /// its row.
    func currentCanvasLayout(_ canvasID: String) -> KnowledgeMapLayout {
        knowledgeMapModel(showing: canvasID)?.layout ?? KnowledgeMapRows.layout(mapID: canvasID)
    }

    /// The canvas's versions on this Mac, newest first.
    func canvasVersions(of canvasID: String) async throws -> [KnowledgeMapVersion] {
        try await storage.canvasVersions(canvasID: canvasID)
    }

    /// **Save Version…**: the canvas as it is now, kept under the learner's
    /// name (the date when they give none).
    @discardableResult
    func saveCanvasVersion(canvasID: String, name: String) async throws -> KnowledgeMapVersion {
        let version = try await storage.keepCanvasVersion(
            canvasID: canvasID,
            layout: currentCanvasLayout(canvasID),
            name: name,
            kind: .manual
        )
        showToast("Saved version “\(version.name)”")
        return version
    }

    /// **Restore** a version, as one edit that Undo takes back. The canvas as
    /// it is now is kept first as an automatic version (unless the newest
    /// version already holds it), so a restore is undone from the same list
    /// after Undo is gone. A canvas no window is open on opens in this one,
    /// since Undo lives in its model; one open in another window is restored
    /// through that window's model, and this window stays as it is. False
    /// when the canvas already held exactly what the version holds.
    @discardableResult
    func restoreCanvasVersion(_ version: KnowledgeMapVersion, canvasID: String) async throws -> Bool {
        let snapshot = try await storage.canvasVersionLayout(canvasID: canvasID, version: version)
        let window = activeWindowState
        let snapshotModel = knowledgeMapModel(showing: canvasID)
        if snapshotModel == nil { showCanvas(canvasID, in: window) }
        let model = snapshotModel ?? knowledgeMap(in: window)
        try await storage.keepCanvasVersionIfChanged(
            canvasID: canvasID,
            layout: model.layout,
            name: "Before restoring \(version.name)",
            kind: .auto
        )
        guard model.restoreLayoutSnapshot(snapshot) else {
            showToast("The canvas already is “\(version.name)”")
            return false
        }
        // The toast's Undo takes back the restore, and only while it is the
        // newest step: an edit made since would otherwise be what it undid.
        let restored = model.newestUndoStep
        showToast("Restored “\(version.name)”", undo: { [weak self] in
            if model.newestUndoStep == restored {
                model.undo()
            } else {
                self?.showToast("Edits were made since the restore: ⌘Z takes them back first")
            }
        })
        return true
    }

    /// One version, gone from the list.
    func deleteCanvasVersion(_ version: KnowledgeMapVersion, canvasID: String) async throws {
        try await storage.deleteCanvasVersion(canvasID: canvasID, version: version)
    }
}

/// Keeps a version on the app's own word once a burst of edits to a canvas
/// has settled (`KnowledgeMapVersionPolicy`): each write of the open canvas
/// starts the wait over, and the version is the layout the burst left.
@MainActor
final class CanvasAutoVersions {
    static let shared = CanvasAutoVersions()

    private var waiting: [String: Task<Void, Never>] = [:]

    private init() {}

    /// Notes that `layout` was just written for `canvasID`.
    func layoutWritten(canvasID: String, layout: KnowledgeMapLayout, storage: StorageService) {
        waiting[canvasID]?.cancel()
        let delay = KnowledgeMapVersionPolicy.settleDelay
        waiting[canvasID] = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await storage.keepAutomaticCanvasVersionIfDue(canvasID: canvasID, layout: layout)
            self?.waiting[canvasID] = nil
        }
    }

    /// The canvas is gone: nothing more to keep.
    func forget(_ canvasID: String) {
        waiting[canvasID]?.cancel()
        waiting[canvasID] = nil
    }

    /// Every wait over, as a test leaves its canvases.
    func forgetAll() {
        waiting.values.forEach { $0.cancel() }
        waiting.removeAll()
    }
}
