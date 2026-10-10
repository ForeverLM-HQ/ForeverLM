#if os(macOS)
import Foundation

// MARK: - Canvases in the Space over MCP (2026-10-07)
//
// The learner makes as many canvases as they like, each an item in their
// Space beside their pages and sites (docs/knowledge-map-design.md,
// "Canvases in the Space"). One is open on the Mac at a time, and it is the
// one get_knowledge_map reads and every other Canvas tool acts on; these
// tools list the canvases, make one, open one, and rename, file, pin, trash
// or delete one, each on the learner's word, as the Space's own menus do. A
// canvas is the learner's layout row, so they need the Mac.

extension MCPToolRegistry {
    static var canvasCatalogToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "list_canvases",
                description: "List the learner's canvases: each a zoomable plane for what they think, an item in their Space beside their pages and sites, listed under Canvases. Returns each canvas's canvas_id, name, created_at, last_activity_at, the space it is filed in (space_id and name) if any, whether it is pinned in the Space sidebar, whether it is in Trash, and whether it is the one open on the Mac; and open_canvas, the canvas open now, which get_knowledge_map reads and apply_map_lens, focus_map and the Canvas edit tools act on. Each canvas that belongs to a notebook also has its notebook_id; pass notebook_id to list only that notebook's canvases. Pass include_trash to list the canvases in Trash too. Call it before open_canvas or update_canvas when the learner names a canvas.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "include_trash": [
                            "type": "boolean",
                            "description": "Also list the canvases in Trash. Defaults to false.",
                        ],
                        "notebook_id": ["type": "string", "description": "List only the canvases of this notebook (list_notebooks)."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "create_canvas",
                description: "Make a new canvas in the learner's Space, on their word (\"start a canvas for the PINK1 work\"): named as they say, filed in one of their spaces when they name one (space_id from list_spaces), and opened on the Mac unless open is false, so the Canvas tools then act on it. Pass notebook_id (list_notebooks) to make it a canvas of that notebook: it is listed in the notebook's menu, and any note written on it by build_canvas is linked to the notebook; with frame_notebook true the notebook's sources are drawn on it in a frame, ready to arrange. It starts empty otherwise: nothing is placed on it until the learner places it, or asks you to (build_canvas lays out a whole picture in one call). Returns the canvas.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "The canvas's name. Defaults to Untitled canvas."],
                        "space_id": ["type": "string", "description": "Optional space ID from list_spaces to file the canvas in."],
                        "open": ["type": "boolean", "description": "Open it on the Mac, where the Canvas tools act on it. Defaults to true."],
                        "notebook_id": ["type": "string", "description": "Optional notebook ID from list_notebooks: the canvas belongs to this notebook."],
                        "frame_notebook": ["type": "boolean", "description": "With notebook_id: draw the notebook's sources on the canvas in a frame. Defaults to false. Needs the canvas open."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "open_canvas",
                description: "Open one of the learner's canvases on the Mac, by canvas_id from list_canvases: it becomes the canvas get_knowledge_map reads and apply_map_lens, focus_map and the Canvas edit tools act on, and it shows beside the chat. A lens showing on the canvas open before is put away with it. A canvas in Trash opens too, marked as in Trash.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "canvas_id": ["type": "string", "description": "Canvas ID from list_canvases."],
                    ],
                    "required": ["canvas_id"],
                ]
            ),
            MCPToolDef(
                name: "update_canvas",
                description: "Change one of the learner's canvases on their word, as its menu in the Space does: rename it (name), file it in one of their spaces (space_id from list_spaces) or take it out of every space (space_id \"\"), file it in a notebook (notebook_id) or take it out of its notebook (notebook_id \"\"), pin or unpin it in the Space sidebar (pinned), or move it to Trash or restore it (in_trash). Pass only what changes. Nothing placed on it moves. Returns the canvas as it is now.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "canvas_id": ["type": "string", "description": "Canvas ID from list_canvases."],
                        "name": ["type": "string", "description": "Its new name."],
                        "space_id": ["type": "string", "description": "A space ID from list_spaces to move it into, or \"\" to take it out of every space."],
                        "notebook_id": ["type": "string", "description": "A notebook ID from list_notebooks to make it that notebook's canvas, or \"\" to take it out of its notebook."],
                        "pinned": ["type": "boolean", "description": "Pin it in the Space sidebar (true) or unpin it (false)."],
                        "in_trash": ["type": "boolean", "description": "Move it to Trash (true) or restore it from Trash (false)."],
                    ],
                    "required": ["canvas_id"],
                ]
            ),
            MCPToolDef(
                name: "delete_canvas",
                description: "Delete a canvas forever, on the learner's explicit word: what is placed on it, its regions and its arrows go, on every device, with its place in a space and its pin. Only a canvas already in Trash can be deleted (update_canvas with in_trash true first), as in the Space. The sources, Docs and Ideas that were on it are untouched. This cannot be undone.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "canvas_id": ["type": "string", "description": "Canvas ID from list_canvases, of a canvas in Trash."],
                    ],
                    "required": ["canvas_id"],
                ]
            ),
        ] + canvasVersionToolDefs
    }

    static let canvasCatalogToolNames: Set<String> = [
        "list_canvases", "create_canvas", "open_canvas", "update_canvas", "delete_canvas",
        "list_canvas_versions",
    ]
}

extension MCPDataStore {
    func executeCanvasCatalogTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "list_canvases":
            return try jsonString(try await Self.listCanvases(
                includeTrash: arguments["include_trash"] as? Bool ?? false,
                notebookID: Self.nilIfBlank(arguments["notebook_id"] as? String ?? "")
            ))
        case "create_canvas":
            return try jsonString(try await Self.createCanvas(
                name: Self.nilIfBlank(arguments["name"] as? String ?? ""),
                spaceID: Self.nilIfBlank(arguments["space_id"] as? String ?? ""),
                open: arguments["open"] as? Bool ?? true,
                notebookID: Self.nilIfBlank(arguments["notebook_id"] as? String ?? ""),
                frameNotebook: arguments["frame_notebook"] as? Bool ?? false
            ))
        case "open_canvas":
            return try jsonString(try await Self.openCanvas(id: try Self.canvasID(arguments)))
        case "update_canvas":
            return try jsonString(try await Self.updateCanvas(id: try Self.canvasID(arguments), arguments: arguments))
        case "delete_canvas":
            return try jsonString(try await Self.deleteCanvas(id: try Self.canvasID(arguments)))
        default:
            return nil
        }
    }

    private static func canvasID(_ arguments: [String: Any]) throws -> String {
        guard let id = nilIfBlank(arguments["canvas_id"] as? String ?? "") else {
            throw MCPError.invalidInput("canvas_id is required: list_canvases gives each canvas's id.")
        }
        return id
    }

    /// One canvas as the tools answer it.
    @MainActor
    static func canvasEntry(_ canvas: KnowledgeMapCanvas, in studio: StudioViewModel) -> [String: Any] {
        var entry: [String: Any] = [
            "canvas_id": canvas.id,
            "name": canvas.name,
            "created_at": iso8601String(canvas.createdAt),
            "last_activity_at": iso8601String(canvas.updatedAt),
            "in_trash": canvas.isTrashed,
            "pinned": studio.isPagePinned(canvas.id),
            "open": studio.knowledgeMap.mapID == canvas.id,
        ]
        if let notebookID = canvas.notebookID {
            entry["notebook_id"] = notebookID
            if let notebook = studio.notebook(id: notebookID) { entry["notebook"] = NotebookTitle(notebook.title).text }
        }
        if let space = studio.pageSpace(ofPage: canvas.id) {
            entry["space"] = ["space_id": space.id, "name": space.name]
        }
        return entry
    }

    /// A canvas the rows hold, read fresh, or why not.
    @MainActor
    private static func existingCanvas(_ id: String, in studio: StudioViewModel) throws -> KnowledgeMapCanvas {
        studio.refreshCanvasesFromRows()
        guard let canvas = studio.canvases.canvas(id) else {
            throw MCPError.notFound("No canvas has canvas_id \(id); list_canvases lists them.")
        }
        return canvas
    }

    @MainActor
    static func listCanvases(includeTrash: Bool, notebookID: String?) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        studio.refreshCanvasesFromRows()
        let canvases = studio.canvases.all.filter { (includeTrash || !$0.isTrashed) && (notebookID == nil || $0.notebookID == notebookID) }
        return [
            "canvases": canvases.map { canvasEntry($0, in: studio) },
            "count": canvases.count,
            // The canvas the Canvas tools act on, named even before anything
            // is written to it.
            "open_canvas": ["canvas_id": studio.knowledgeMap.mapID, "name": studio.openCanvasName],
        ]
    }

    @MainActor
    static func createCanvas(name: String?, spaceID: String?, open: Bool, notebookID: String?, frameNotebook: Bool) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        if let notebookID {
            guard let notebook = studio.notebook(id: notebookID), notebook.isNotebook else {
                throw MCPError.notFound("No Notebook has the id \(notebookID); list_notebooks gives them.")
            }
        }
        if let spaceID {
            studio.refreshPageSpacesFromRows()
            guard studio.pageSpaces.space(spaceID) != nil else {
                throw MCPError.notFound("No space has space_id \(spaceID); list_spaces lists them.")
            }
        }
        let canvas = studio.createCanvas(named: name ?? KnowledgeMap.newCanvasName, inPageSpace: spaceID, notebookID: notebookID)
        if open { showCanvasBesideChat(canvas.id, in: studio) }
        var note: String?
        if frameNotebook, let notebookID {
            if open {
                _ = try await editCanvas("create_canvas_region", arguments: ["notebook_id": notebookID])
            } else {
                note = "frame_notebook needs the canvas open; open_canvas it and create_canvas_region with notebook_id."
            }
        }
        if let note {
            return ["canvas": canvasEntry(studio.canvases.canvas(canvas.id) ?? canvas, in: studio), "note": note]
        }
        return ["canvas": canvasEntry(studio.canvases.canvas(canvas.id) ?? canvas, in: studio)]
    }

    @MainActor
    static func openCanvas(id: String) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let canvas = try existingCanvas(id, in: studio)
        showCanvasBesideChat(canvas.id, in: studio)
        return ["canvas": canvasEntry(canvas, in: studio)]
    }

    /// Makes the canvas the open one and shows the Canvas beside the chat
    /// when no window shows it, as a lens does.
    @MainActor
    private static func showCanvasBesideChat(_ id: String, in studio: StudioViewModel) {
        studio.showCanvas(id)
        if !studio.knowledgeMapIsOnScreen {
            studio.openCenterTabBeside(.knowledgeMap)
        }
    }

    @MainActor
    static func updateCanvas(id: String, arguments: [String: Any]) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        _ = try existingCanvas(id, in: studio)
        let name = (arguments["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let name, KnowledgeMapCanvases.cleanedName(name) == nil {
            throw MCPError.invalidInput("name has nothing in it.")
        }
        let spaceID = (arguments["space_id"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let spaceID, !spaceID.isEmpty {
            studio.refreshPageSpacesFromRows()
            guard studio.pageSpaces.space(spaceID) != nil else {
                throw MCPError.notFound("No space has space_id \(spaceID); list_spaces lists them.")
            }
        }
        if let inTrash = arguments["in_trash"] as? Bool {
            if inTrash { studio.moveCanvasesToTrash([id]) } else { studio.restoreCanvases([id]) }
        }
        if let raw = (arguments["notebook_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if raw.isEmpty {
                studio.setCanvasNotebook(id, to: nil)
            } else {
                guard let notebook = studio.notebook(id: raw), notebook.isNotebook else {
                    throw MCPError.notFound("No Notebook has the id \(raw); list_notebooks gives them.")
                }
                studio.setCanvasNotebook(id, to: notebook.id)
            }
        }
        if let name { studio.renameCanvas(id, to: name) }
        if let spaceID { studio.filePages([id], inPageSpace: spaceID.isEmpty ? nil : spaceID) }
        if let pinned = arguments["pinned"] as? Bool { studio.setPagePinned(id, pinned: pinned) }
        return ["canvas": canvasEntry(try existingCanvas(id, in: studio), in: studio)]
    }

    @MainActor
    static func deleteCanvas(id: String) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let canvas = try existingCanvas(id, in: studio)
        guard canvas.isTrashed else {
            throw MCPError.invalidInput("\(canvas.name) is not in Trash. Move it there first (update_canvas with in_trash true); only a canvas in Trash is deleted forever.")
        }
        studio.deleteCanvasesForever([id])
        return ["deleted": true, "canvas_id": id, "name": canvas.name]
    }
}
#endif
