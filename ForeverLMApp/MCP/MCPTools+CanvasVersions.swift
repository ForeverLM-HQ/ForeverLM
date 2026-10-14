#if os(macOS)
import Foundation

// MARK: - A canvas's versions over MCP (2026-10-09)
//
// `list_canvas_versions`, `save_canvas_version` and `restore_canvas_version`:
// the canvas menu's Versions… and Save Version… (docs/knowledge-map-design.md,
// "Versions, export and publishing"). A version is a snapshot of a canvas's
// layout row that the learner saved by name or ForeverLM kept after a burst
// of edits, in `.appdata/CanvasHistory` beside knowledge.db
// (`KnowledgeMapVersionHistory`), so all three are this Mac's and the hosted
// gateway lists them as desktop-only. Saving and restoring change nothing
// until the learner asks, and a restore goes through the model as one edit
// that `undo_canvas` takes back, after keeping what the canvas held.

extension MCPToolRegistry {
    static var canvasVersionToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "list_canvas_versions",
                description: "List the versions of one of the learner's canvases kept on this Mac, newest first: each a snapshot of the canvas's layout (what is placed where, its regions and its arrows) that the learner saved by name (Save Version…, Cmd-Opt-S) or that ForeverLM kept on its own after a burst of edits, at most one every ten minutes. Returns each version's version_id, name, kind (manual or auto), saved_at, and how many cards, regions and arrows it holds, then the same counts for the canvas now (current) and how many cards, regions and arrows differ between it and the newest version. A canvas keeps at most 30 versions, the oldest automatic ones going first. Versions are this Mac's only: another Mac, the iPhone and the web keep none. Defaults to the canvas open on the Mac; pass canvas_id (list_canvases) for another. restore_canvas_version puts one back.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "canvas_id": ["type": "string", "description": "Canvas ID from list_canvases. Defaults to the canvas open on the Mac."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "save_canvas_version",
                description: "Keep one of the learner's canvases as it is now as a named version, on their word (\"save a version before you rearrange this\"), as Save Version… in the canvas menu does. Nothing on the canvas changes. name is what the learner would call it; without one the date names it. The version stays on this Mac and is listed by list_canvas_versions, and restore_canvas_version puts it back. A canvas keeps at most 30 versions, the oldest automatic ones going first, so the learner's own are the last to go. Defaults to the canvas open on the Mac; pass canvas_id (list_canvases) for another. Returns the version.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "The version's name, on one line of at most 80 characters. Defaults to the date."],
                        "canvas_id": ["type": "string", "description": "Canvas ID from list_canvases. Defaults to the canvas open on the Mac."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "restore_canvas_version",
                description: "Put one of a canvas's versions back, on the learner's explicit word, as Restore in the canvas's Versions… does: its cards, regions and arrows become the version's, written as one edit that undo_canvas takes back. A card, region or arrow the canvas holds now and the version lacks is taken off (the sources, pages and Ideas themselves are untouched), and one the version holds is put back where it was; the canvas's name, Trash mark and notebook stay as they are. What the canvas held before is kept as an automatic version first, so a restore can be undone from list_canvas_versions too. The canvas is opened on the Mac, since Undo lives there. Get version_id from list_canvas_versions. Returns the version, whether anything changed, and the version kept before the restore.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "version_id": ["type": "string", "description": "Version ID from list_canvas_versions."],
                        "canvas_id": ["type": "string", "description": "Canvas ID from list_canvases. Defaults to the canvas open on the Mac."],
                    ],
                    "required": ["version_id"],
                ]
            ),
        ]
    }

    /// The tools that list a canvas's versions and keep or restore one.
    static let canvasVersionToolNames: Set<String> = [
        "list_canvas_versions", "save_canvas_version", "restore_canvas_version",
    ]
}

extension MCPDataStore {
    func executeCanvasVersionTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "list_canvas_versions":
            return try jsonString(try await Self.listCanvasVersions(canvasID: Self.nilIfBlank(arguments["canvas_id"] as? String ?? "")))
        case "save_canvas_version":
            return try jsonString(try await Self.saveCanvasVersion(
                canvasID: Self.nilIfBlank(arguments["canvas_id"] as? String ?? ""),
                name: arguments["name"] as? String ?? ""
            ))
        case "restore_canvas_version":
            guard let versionID = Self.nilIfBlank(arguments["version_id"] as? String ?? "") else {
                throw MCPError.invalidInput("version_id is required: list_canvas_versions gives each version's id.")
            }
            return try jsonString(try await Self.restoreCanvasVersion(
                canvasID: Self.nilIfBlank(arguments["canvas_id"] as? String ?? ""),
                versionID: versionID
            ))
        default:
            return nil
        }
    }

    /// The canvas a call names, or the open one, with its name.
    @MainActor
    private static func versionedCanvas(_ raw: String?, in studio: StudioViewModel) throws -> (id: String, name: String) {
        let id = raw ?? studio.knowledgeMap.mapID
        studio.refreshCanvasesFromRows()
        guard studio.canvases.canvas(id) != nil || id == studio.knowledgeMap.mapID else {
            throw MCPError.notFound("No canvas has canvas_id \(id); list_canvases lists them.")
        }
        return (id, studio.canvasDisplayName(id))
    }

    private static func versionRow(_ version: KnowledgeMapVersion) -> [String: Any] {
        [
            "version_id": version.id,
            "name": version.name,
            "kind": version.kind.rawValue,
            "saved_at": iso8601String(version.at),
            "cards": version.cards,
            "regions": version.regions,
            "arrows": version.arrows,
            "summary": version.summary,
        ]
    }

    @MainActor
    static func listCanvasVersions(canvasID: String?) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let canvas = try versionedCanvas(canvasID, in: studio)
        let versions = try await studio.canvasVersions(of: canvas.id)
        let layout = studio.currentCanvasLayout(canvas.id)
        var newestLayout: KnowledgeMapLayout?
        if let newest = versions.first {
            newestLayout = try await studio.storage.canvasVersionLayout(canvasID: canvas.id, version: newest)
        }
        return [
            "canvas": ["canvas_id": canvas.id, "name": canvas.name],
            "version_count": versions.count,
            "versions": versions.map(versionRow),
            "current": [
                "cards": layout.placements.count,
                "regions": layout.regions.count,
                "arrows": layout.edges.count,
                "changed_since_newest_version": KnowledgeMapVersionPolicy.changedEntries(from: newestLayout, to: layout),
            ] as [String: Any],
            "guidance": versions.isEmpty
                ? "This Mac keeps no version of this canvas yet. ForeverLM keeps one on its own after a burst of edits (at most one every ten minutes); save_canvas_version keeps one now under a name, on the learner's word."
                : "Each version is the canvas's layout as it stood when it was kept, on this Mac only. kind manual is one the learner named; auto is one ForeverLM kept on its own, or before a restore. restore_canvas_version puts one back as an edit undo_canvas takes back, after keeping what the canvas holds now; only on the learner's word.",
        ]
    }

    @MainActor
    static func saveCanvasVersion(canvasID: String?, name: String) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let canvas = try versionedCanvas(canvasID, in: studio)
        let version = try await studio.saveCanvasVersion(canvasID: canvas.id, name: name)
        return [
            "canvas": ["canvas_id": canvas.id, "name": canvas.name],
            "version": versionRow(version),
            "message": "Kept ‘\(canvas.name)’ as ‘\(version.name)’ on this Mac. restore_canvas_version with version_id \(version.id) puts the canvas back as it is now.",
        ]
    }

    @MainActor
    static func restoreCanvasVersion(canvasID: String?, versionID: String) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let canvas = try versionedCanvas(canvasID, in: studio)
        // A lens on the open canvas waits for the learner, as every other edit does.
        if canvas.id == studio.knowledgeMap.mapID, studio.knowledgeMap.lens != nil {
            throw MCPError.invalidInput("A lens shows on the Canvas: keep it (keep_map_lens) or clear it (clear_map_lens) first, as the learner's own edits wait for it.")
        }
        let before = try await studio.canvasVersions(of: canvas.id)
        guard let version = before.first(where: { $0.id == versionID }) else {
            throw MCPError.notFound("Version not found: \(versionID). list_canvas_versions lists the versions of ‘\(canvas.name)’ this Mac keeps.")
        }
        let changed = try await studio.restoreCanvasVersion(version, canvasID: canvas.id)
        if !studio.knowledgeMapIsOnScreen { studio.openCenterTabBeside(.knowledgeMap) }
        let known = Set(before.map(\.id))
        let kept = try await studio.canvasVersions(of: canvas.id).first { !known.contains($0.id) && $0.kind == .auto }
        var payload: [String: Any] = [
            "canvas": ["canvas_id": canvas.id, "name": canvas.name],
            "restored": changed,
            "version": versionRow(version),
            "kept_before_restore": kept.map { versionRow($0) } ?? NSNull(),
        ]
        guard changed else {
            payload["message"] = "‘\(canvas.name)’ already is ‘\(version.name)’; nothing changed."
            return payload
        }
        var message = "Put ‘\(canvas.name)’ back as ‘\(version.name)’. It is one edit: undo_canvas takes it back"
        if let kept { message += ", and what the canvas held before is kept as the version \(kept.id)" }
        payload["message"] = message + "."
        return payload
    }
}
#endif
