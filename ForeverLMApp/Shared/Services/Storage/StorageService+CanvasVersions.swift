import Foundation

// MARK: - Where this Mac keeps its canvases' versions

extension KnowledgeStore {
    /// This Mac's versions of its canvases, in `.appdata/CanvasHistory` beside
    /// the database and `PageHistory` (`KnowledgeMapVersionHistory`); nil for a
    /// store held in memory.
    var canvasVersionHistory: KnowledgeMapVersionHistory? {
        guard dbPath != ":memory:" else { return nil }
        return KnowledgeMapVersionHistory(
            rootDirectory: URL(fileURLWithPath: dbPath)
                .deletingLastPathComponent()
                .appendingPathComponent(KnowledgeMapVersionHistory.folderName, isDirectory: true)
        )
    }
}

// MARK: - Versions of a canvas, from its menu and over MCP

extension StorageService {
    private func canvasVersionHistory() throws -> KnowledgeMapVersionHistory {
        guard let history = try notebookFilesKnowledgeStore().canvasVersionHistory else {
            throw CocoaError(.fileNoSuchFile)
        }
        return history
    }

    /// The canvas's versions on this Mac, newest first.
    func canvasVersions(canvasID: String) throws -> [KnowledgeMapVersion] {
        try canvasVersionHistory().versions(of: canvasID)
    }

    /// The layout a version kept.
    func canvasVersionLayout(canvasID: String, version: KnowledgeMapVersion) throws -> KnowledgeMapLayout {
        try canvasVersionHistory().layout(of: version, canvasID: canvasID)
    }

    /// **Save Version…**, and the version kept before a restore: `layout` as a
    /// version, whatever the policy says.
    @discardableResult
    func keepCanvasVersion(
        canvasID: String,
        layout: KnowledgeMapLayout,
        name: String?,
        kind: KnowledgeMapVersion.Kind,
        at date: Date = Date()
    ) throws -> KnowledgeMapVersion {
        try canvasVersionHistory().keep(layout, canvasID: canvasID, name: name, kind: kind, at: date)
    }

    /// The canvas kept as a version unless the newest version already holds
    /// it: what is kept before a restore. Nil when nothing was kept.
    @discardableResult
    func keepCanvasVersionIfChanged(
        canvasID: String,
        layout: KnowledgeMapLayout,
        name: String?,
        kind: KnowledgeMapVersion.Kind,
        at date: Date = Date()
    ) throws -> KnowledgeMapVersion? {
        try canvasVersionHistory().keepIfChanged(layout, canvasID: canvasID, name: name, kind: kind, at: date)
    }

    /// A version kept on the app's own word, once a burst of edits has settled
    /// and the policy says so (`KnowledgeMapVersionPolicy`). Nil when none was
    /// due. Never throws: a canvas's edit does not wait on a version.
    @discardableResult
    func keepAutomaticCanvasVersionIfDue(canvasID: String, layout: KnowledgeMapLayout, now: Date = Date()) -> KnowledgeMapVersion? {
        guard let history = try? canvasVersionHistory() else { return nil }
        return history.keepAutomaticallyIfDue(layout, canvasID: canvasID, now: now)
    }

    func deleteCanvasVersion(canvasID: String, version: KnowledgeMapVersion) throws {
        try canvasVersionHistory().delete(version, canvasID: canvasID)
    }

    /// The canvases are gone for good, and their versions go with them.
    func removeCanvasHistory(canvasIDs: [String]) {
        guard let history = try? canvasVersionHistory() else { return }
        for id in canvasIDs { history.removeHistory(of: id) }
    }
}
