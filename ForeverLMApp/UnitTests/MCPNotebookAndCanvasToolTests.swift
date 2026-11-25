// The create_notebook naming and Canvas parity tool tests.

import Testing
import AppKit
import Foundation
import PDFKit
import SQLite3
@testable import ForeverLM

@Suite("create_notebook without a title")
struct MCPCreateNotebookNamingTests {
    @Test("No title makes an unnamed notebook ForeverLM names; a title or summary given is the learner's")
    func createsUnnamed() async throws {
        let tmpPath = NSTemporaryDirectory() + "MCPCreateNotebookNamingTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let suiteName = "MCPCreateNotebookNamingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activeNotebookID = ActiveNotebookPreference.notebookID
        defer { ActiveNotebookPreference.notebookID = activeNotebookID }
        let store = MCPDataStore(dbPath: tmpPath + "/knowledge.db")

        try await NotebookNamingRows.$overrideDefaults.withValue(NotebookNamingRows.DefaultsOverride(defaults: defaults)) {
            func create(title: String?, summary: String? = nil) async throws -> LearningGoalRecord {
                let text = try await store.createNotebook(
                    title: title, description: nil, summary: summary, topic: nil, endDateString: "",
                    sourceIDs: [], dailyTarget: nil, discover: false
                )
                let id = try #require(createdNotebookID(in: text))
                return try #require(try store.knowledgeStore().loadLearningGoal(id))
            }
            let unnamed = try await create(title: nil)
            #expect(unnamed.isNotebook)
            #expect(unnamed.title == "New notebook")
            #expect(NotebookNamingRows.mark(notebookID: unnamed.id) == .unnamed(title: "New notebook"))
            // Two unnamed notebooks are no duplicate: the second is numbered.
            let second = try await create(title: "  ")
            #expect(second.title == "New notebook 2")

            let named = try await create(title: "Complex I assembly")
            #expect(NotebookNamingRows.mark(notebookID: named.id) == nil)
            let described = try await create(title: nil, summary: "My own line")
            #expect(NotebookNamingRows.mark(notebookID: described.id) == nil)

            // A name given later is the learner's: ForeverLM never renames it.
            _ = try await store.updateNotebook(
                notebookID: unnamed.id, title: "Leigh syndrome", description: nil, topic: nil,
                endDateString: nil, openEnded: nil, dailyTarget: nil, discover: nil
            )
            #expect(NotebookNamingRows.mark(notebookID: unnamed.id) == nil)

            await #expect(throws: MCPError.self) {
                _ = try await store.createNotebook(
                    title: nil, description: nil, topic: nil, endDateString: "",
                    sourceIDs: [], dailyTarget: nil, discover: true
                )
            }
        }

        let createTool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "create_notebook" })
        #expect((createTool.inputSchema["required"] as? [String]) == [])
    }
}

/// The Canvas's Heptabase parity build over MCP (docs/knowledge-map-design.md,
/// "Over MCP"): the four new tools and the fields the existing ones gained, as
/// a connector sees them in the registry. What each does to a canvas is in
/// `KnowledgeMapMCPParityTests`.
@Suite("MCP Canvas parity tools")
struct MCPCanvasParityContractTests {
    private func tool(_ name: String) throws -> MCPToolDef {
        try #require(MCPToolRegistry.shared.tools.first { $0.name == name }, "\(name) is not registered")
    }

    private func properties(_ name: String) throws -> [String: Any] {
        try #require(try tool(name).inputSchema["properties"] as? [String: Any])
    }

    private func property(_ tool: String, _ field: String) throws -> [String: Any] {
        try #require(try properties(tool)[field] as? [String: Any], "\(tool) has no \(field)")
    }

    @Test("update_canvas_card and arrange_on_canvas edit the Canvas on the learner's word, off the store gate, and take what the contract names")
    func editTools() throws {
        for name in ["update_canvas_card", "arrange_on_canvas"] {
            #expect(MCPToolRegistry.canvasEditToolNames.contains(name))
            #expect(!MCPToolRegistry.knowledgeMapToolNames.subtracting(MCPToolRegistry.canvasEditToolNames).contains(name))
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name))
            #expect(MCPToolRegistry.isToolAllowed(name, scope: .full) && !MCPToolRegistry.isToolAllowed(name, scope: .ingest))
            #expect(try tool(name).description.contains("Undo"), "\(name) says its edit is one Undo step")
            #expect(try tool(name).description.contains("on the learner's word"))
            // A mutating tool keeps its blank arguments as sent.
            #expect(MCPToolRegistry.normalizedArguments(toolName: name, arguments: ["color": ""])["color"] as? String == "")
            #expect(try tool(name).inputSchema["required"] as? [String] == ["item_ids"])
        }
        let card = try properties("update_canvas_card")
        #expect(Set(card.keys) == ["item_ids", "color", "folded", "w", "h", "fit_to_content", "page", "annotation", "plain", "answered"])
        #expect((card["item_ids"] as? [String: Any])?["maxItems"] as? Int == 200)
        #expect(try property("update_canvas_card", "w")["type"] as? String == "number")
        #expect(try property("update_canvas_card", "folded")["type"] as? String == "boolean")
        let arrange = try properties("arrange_on_canvas")
        #expect(Set(arrange.keys) == ["item_ids", "arrangement", "align"])
        #expect((arrange["arrangement"] as? [String: Any])?["enum"] as? [String] == ["row", "column", "grid"])
        #expect((arrange["align"] as? [String: Any])?["enum"] as? [String] == ["left", "center", "right", "top", "middle", "bottom"])
        #expect((arrange["item_ids"] as? [String: Any])?["minItems"] as? Int == 2)
    }

    @Test("lint_canvas and screenshot_canvas only look: read-only, off the gate, in the Canvas's reads and not its edits")
    func lookingTools() throws {
        for name in ["lint_canvas", "screenshot_canvas"] {
            #expect(MCPToolRegistry.knowledgeMapToolNames.contains(name))
            #expect(!MCPToolRegistry.canvasEditToolNames.contains(name))
            #expect(MCPToolRegistry.storeGateExemptToolNames.contains(name))
            #expect(try tool(name).inputSchema["required"] as? [String] == [])
            // A read-only tool drops a blank argument a model filled in.
            #expect(MCPToolRegistry.normalizedArguments(toolName: name, arguments: ["limit": "", "scale": " "]).isEmpty)
        }
        #expect(Set(try properties("lint_canvas").keys) == ["limit"])
        let lint = try tool("lint_canvas").description
        for kind in ["overlap", "card_outside_region", "arrow_over_card", "empty_region"] { #expect(lint.contains(kind)) }
        #expect(Set(try properties("screenshot_canvas").keys) == ["scale", "item_ids"])
        let shot = try tool("screenshot_canvas").description
        #expect(shot.contains("Exports/") && shot.contains("file_path") && shot.contains("width") && shot.contains("4 MB"))
        #expect(shot.contains("showing on the Mac"), "it says it needs the Canvas on screen")
    }

    @Test("place_on_canvas takes a look for the cards it sets down, and canvas_region a lock")
    func placeAndCreate() throws {
        let place = try properties("place_on_canvas")
        for field in ["color", "folded", "w", "h"] { #expect(place[field] != nil, "place_on_canvas lacks \(field)") }
        #expect(try property("canvas_region", "locked")["type"] as? String == "boolean")
        #expect(try tool("place_on_canvas").inputSchema["required"] as? [String] == ["item_ids"])
        // The new kinds are named where cards are.
        for name in ["place_on_canvas", "take_off_canvas", "canvas_region", "focus_map", "apply_map_lens"] {
            let text = String(describing: try tool(name).inputSchema)
            #expect(text.contains("canvas:<canvas_id>") && text.contains("chat:<session_id>") && text.contains("picture:<image_id>"), "\(name)")
        }
    }

    @Test("canvas_region creates, updates and deletes, and an update takes a lock, a layout, a fit and a grow")
    func regionFields() throws {
        let region = try properties("canvas_region")
        #expect((region["action"] as? [String: Any])?["enum"] as? [String] == ["create", "update", "delete"])
        #expect(region["take_cards_off"] != nil && region["item_ids"] != nil)
        #expect(region["locked"] != nil && region["fit_to_content"] != nil)
        #expect((region["layout"] as? [String: Any])?["enum"] as? [String] == ["free", "tree"])
        #expect((region["grow_to_hold"] as? [String: Any])?["type"] as? String == "array")
        #expect(try tool("canvas_region").inputSchema["required"] as? [String] == ["action"])
        let description = try tool("canvas_region").description
        #expect(description.contains("locked") && description.contains("mind map") && description.contains("200 by 120"))
    }

    @Test("Arrows take a route, dashes, heads, a colour and a branch, and end at regions; an update needs no label")
    func arrowFields() throws {
        let arrow = try properties("canvas_arrow")
        #expect((arrow["action"] as? [String: Any])?["enum"] as? [String] == ["draw", "update", "delete"])
        #expect((arrow["route"] as? [String: Any])?["enum"] as? [String] == ["curve", "straight", "elbow"])
        #expect((arrow["heads"] as? [String: Any])?["enum"] as? [String] == ["end", "both", "none"])
        for field in ["dashed", "color", "tree", "label", "edge_id"] { #expect(arrow[field] != nil, "canvas_arrow lacks \(field)") }
        #expect(try tool("canvas_arrow").inputSchema["required"] as? [String] == ["action"], "a style change needs no label")
        #expect(String(describing: try tool("canvas_arrow").inputSchema).contains("region:<region_id>"), "it names region ends")
        #expect(try tool("canvas_arrow").description.contains("survives its cards leaving"))
    }

    @Test("build_canvas takes mind maps as trees, arrows with a look, and the new kinds by item_id")
    func buildCanvasFields() throws {
        let trees = try property("build_canvas", "trees")
        #expect(trees["type"] as? String == "array")
        let item = try #require(trees["items"] as? [String: Any])
        #expect(item["required"] as? [String] == ["name", "root"])
        let root = try #require((item["properties"] as? [String: Any])?["root"] as? [String: Any])
        #expect(root["required"] as? [String] == ["title"])
        let rootFields = try #require(root["properties"] as? [String: Any])
        #expect(Set(rootFields.keys) == ["key", "title", "text", "children"])
        let arrows = try #require(try property("build_canvas", "arrows")["items"] as? [String: Any])
        let arrowFields = try #require(arrows["properties"] as? [String: Any])
        for field in ["route", "dashed", "heads", "color"] { #expect(arrowFields[field] != nil) }
        let description = try tool("build_canvas").description
        #expect(description.contains("mind map") && description.contains("canvas:<id>") && description.contains("picture:<image_id>"))
        #expect(try tool("build_canvas").inputSchema["required"] as? [String] == [])
    }

    @Test("get_knowledge_map says what it now reports")
    func readsMore() throws {
        let description = try tool("get_knowledge_map").description
        for word in ["rect", "folded", "locked", "tree", "route", "heads", "region:<region_id>", "canvas:<canvas_id>", "chat:<session_id>", "picture:<image_id>"] {
            #expect(description.contains(word), "get_knowledge_map does not mention \(word)")
        }
    }

    @Test("No Canvas tool publishes a schema the Claude API refuses: no top-level anyOf, oneOf or allOf")
    func noTopLevelAlternatives() throws {
        let canvasTools = MCPToolRegistry.knowledgeMapToolNames
        #expect(canvasTools.count >= 18)
        for name in canvasTools {
            let schema = try tool(name).inputSchema
            #expect(schema["type"] as? String == "object", "\(name)")
            for forbidden in ["anyOf", "oneOf", "allOf", "not", "enum"] { #expect(schema[forbidden] == nil, "\(name) has a top-level \(forbidden)") }
        }
    }

    @Test("The published catalogue carries the four new tools and the fields the old ones gained")
    func catalogue() throws {
        let data = try Data(contentsOf: MCPToolContractTests.catalogueURL)
        let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let names = Set(entries.compactMap { $0["name"] as? String })
        for name in ["update_canvas_card", "arrange_on_canvas", "lint_canvas", "screenshot_canvas"] { #expect(names.contains(name), "\(name)") }
    }
}
