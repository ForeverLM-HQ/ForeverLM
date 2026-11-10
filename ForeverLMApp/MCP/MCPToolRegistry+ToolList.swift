// MCPToolRegistry: the tool list, every tool's name, description and schema, gathered from the per-topic definition files.
import Foundation

extension MCPToolRegistry {

    // MARK: - Tool List

    var tools: [MCPToolDef] {
        let definitions: [MCPToolDef] = [
            Self.libraryToolDefs,
            Self.integrationsToolDefs,
            Self.notebooksToolDefs,
            Self.pagesToolDefs,
            Self.planningToolDefs,
            Self.reviewToolDefs,
            Self.sourceImportToolDefs,
            Self.coursesAndWalkthroughsToolDefs,
            Self.sourceToolsToolDefs,
            MCPDataStore.imageToolDefs,
            Self.settingsParityToolDefs,
            Self.runningWorkToolDefs,
            Self.mnemonicReadingToolDefs,
            Self.knowledgeMapToolDefs,
            Self.canvasCatalogToolDefs,
            Self.spaceListToolDefs,
            Self.canvasAskToolDefs,
            Self.sourceLevelsToolDefs,
            Self.canvasMemoryToolDefs,
            Self.atlasToolDefs,
            Self.notesGraphToolDefs,
            Self.paperReferenceToolDefs,
        ].flatMap { $0 }
        return definitions.map(Self.addSpendApprovalArgument)
    }

    /// Every assistant-started paid operation has a $3 default ceiling. A
    /// larger ceiling is deliberately part of the tool call, rather than a
    /// preference an assistant can silently inherit from an earlier run.
    private static func addSpendApprovalArgument(to tool: MCPToolDef) -> MCPToolDef {
        guard paidWorkToolNames.contains(tool.name),
              var properties = tool.inputSchema["properties"] as? [String: Any] else { return tool }
        properties["approved_spend_usd"] = [
            "type": "number",
            "minimum": 0.01,
            "description": "Maximum USD the learner has approved for this one operation. Omit for the $3 default ceiling. Pass more than 3 only after showing the learner the estimate or published maximum and receiving explicit approval. The operation stops after the request that reaches the ceiling and starts no further paid request; completed work is kept.",
        ]
        var schema = tool.inputSchema
        schema["properties"] = properties
        return MCPToolDef(
            name: tool.name,
            description: tool.description + " Paid assistant work has a $3 per-operation ceiling by default. To continue beyond it, show the learner the estimate, obtain explicit approval, and pass that total as approved_spend_usd.",
            inputSchema: schema
        )
    }
}
