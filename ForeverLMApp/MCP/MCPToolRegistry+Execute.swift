// MCPToolRegistry: the dispatcher that runs one tool call.
import Foundation
import OSLog

extension MCPToolRegistry {
    func executeTool(name: String, arguments: [String: Any], hostSessionID: String? = nil, access: MCPAccessContext = .internalFullAccess) async -> String {
        let hostSessionID = hostSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? hostSessionID : nil
        do {
            // The Settings-parity tools (`MCPTools+AppSettings.swift`) dispatch
            // themselves, so this switch does not grow a case per pane control.
            if let result = try await store.executeSettingsParityTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeRunningWorkTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeMnemonicReadingTool(name: name, arguments: arguments) {
                return result
            }
            // Ahead of the Canvas edits, whose names include save and restore.
            if let result = try await store.executeCanvasVersionTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeKnowledgeMapTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeCanvasCatalogTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeSpaceListTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executePaperReferenceTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeCanvasAskTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeSourceLevelsTool(name: name, arguments: arguments) {
                return result
            }
            // Memory on the Canvas.
            if let result = try await store.executeCanvasMemoryTool(name: name, arguments: arguments) {
                return result
            }
            if let result = try await store.executeAtlasTool(name: name, arguments: arguments) {
                return result
            }
            // A source's draft deck of cards to check is the learner's own
            // memory state, never a Doc (list_docs leaves it out): every tool
            // that takes a doc_id refuses one and names the card tools.
            // The working memory is kept in the background, never as a Doc
            // (`WorkingMemoryRecords`): the working-note tools read and change it.
            if let docID = (arguments["doc_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if MemoryCard.isDraftDeckID(docID) {
                    throw MCPError.invalidInput(MCPDataStore.cardDeckIsNoDocMessage(docID: docID, tool: name))
                }
                if WorkingMemoryRecords.contains(docID) {
                    throw MCPError.invalidInput(MCPDataStore.workingMemoryIsNoDocMessage(docID: docID, tool: name))
                }
            }
            // Notes as a graph: linked references, blocks and daily notes.
            if let result = try await store.executeNotesGraphTool(name: name, arguments: arguments) {
                return result
            }
            // Every other tool belongs to one topic's dispatcher, which returns nil for a name it does not run.
            if let result = try await executeLibraryTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            if let result = try await executeIntegrationsTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            if let result = try await executeNotebooksTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            if let result = try await executePagesTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            if let result = try await executePlanningTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            if let result = try await executeReviewTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            if let result = try await executeSourceImportTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            if let result = try await executeCoursesAndWalkthroughsTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            if let result = try await executeSourceToolsTool(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) {
                return result
            }
            return "Unknown tool: \(name)"
        } catch {
            logger.error("Tool \(name) failed: \(error.localizedDescription)")
            return "Error: \(error.localizedDescription)"
        }
    }
}
