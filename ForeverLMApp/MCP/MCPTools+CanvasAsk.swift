#if os(macOS)
import Foundation

// MARK: - Ask the Canvas over MCP (WP-B1, docs/sensemaking-design.md)
//
// `ask_canvas` asks what the inspector's Ask asks — Bridge, Connect or Gaps —
// of cards on the learner's Canvas, and shows the answer there as proposals
// drawn dotted. There is no tool that keeps a proposal: keeping one places a
// source, draws an arrow or writes an Idea, and the arrangement is the
// learner's alone (docs/knowledge-map-design.md, "Product invariants").

extension MCPToolRegistry {
    static var canvasAskToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "ask_canvas",
                description: "Ask the learner's Canvas about cards on it, as the Ask in its inspector does. tool bridge finds sources in their library that connect the cards; connect proposes typed arrows between cards placed on the canvas (supports, contradicts, explains, causes, measures, extends, example or same_question, each with a short label); gaps names research questions the cards leave open. One call to the learner's chat model, grounded in passages from their library. The answer is drawn dotted on the Canvas beside the cards (the Canvas opens beside the chat if it is not showing) and returned here: each proposal with its why in ForeverLM's words and the passages it rests on. No tool keeps a proposal: keeping one places the source, draws the arrow or writes the question as an Idea, which is the learner's own act on their Canvas (the ✓ on a proposal, or Keep All); dismissing one tells the next ask of that tool not to offer it again. A new ask replaces the proposals showing. Refused while a lens shows (clear_map_lens first). Stop a running ask with cancel_ai_work.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "tool": [
                            "type": "string",
                            "enum": CanvasAskTool.overMCP.map(\.rawValue),
                            "description": "bridge: library sources that connect the cards. connect: arrows between the cards placed on the canvas (needs two). gaps: questions the cards leave open.",
                        ],
                        "item_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "minItems": 1,
                            "maxItems": CanvasAskService.maximumCards,
                            "description": "The cards to ask about, 1 to 24, by item_id as get_knowledge_map gives them: source:<source_id>, doc:<doc_id> or idea:<idea_id>. A bare source, Doc or Idea id is accepted too.",
                        ],
                    ],
                    "required": ["tool", "item_ids"],
                ]
            ),
        ]
    }

    static let canvasAskToolNames: Set<String> = ["ask_canvas"]
}

extension MCPDataStore {
    func executeCanvasAskTool(name: String, arguments: [String: Any]) async throws -> String? {
        guard name == "ask_canvas" else { return nil }
        let request = try Self.canvasAskRequest(from: arguments)
        return try jsonString(try await Self.askCanvas(tool: request.tool, itemIDs: request.itemIDs))
    }

    /// ask_canvas's arguments: the tool and 1 to 24 ids, as given.
    static func canvasAskRequest(from arguments: [String: Any]) throws -> (tool: CanvasAskTool, itemIDs: [String]) {
        guard let raw = (arguments["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let tool = CanvasAskTool(rawValue: raw), CanvasAskTool.overMCP.contains(tool) else {
            throw MCPError.invalidInput("ask_canvas needs tool: bridge, connect or gaps.")
        }
        var seen: Set<String> = []
        let itemIDs = (arguments["item_ids"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !itemIDs.isEmpty, itemIDs.count <= CanvasAskService.maximumCards else {
            throw MCPError.invalidInput("ask_canvas needs 1 to \(CanvasAskService.maximumCards) item_ids, as get_knowledge_map gives them.")
        }
        return (tool, itemIDs)
    }

    /// A card as the Canvas knows it: a bare id is a source when the Canvas
    /// has that source, else a Doc, else an Idea.
    @MainActor
    static func canvasAskRef(_ raw: String, in map: KnowledgeMapModel) -> String {
        let ref = KnowledgeMap.ItemRef(raw) ?? KnowledgeMap.ItemRef(kind: .source, id: raw)
        if map.nodesByRef[ref.description] != nil { return ref.description }
        for kind in [KnowledgeMap.ItemKind.doc, .idea] {
            let other = KnowledgeMap.ItemRef(kind: kind, id: ref.id).description
            if map.nodesByRef[other] != nil { return other }
        }
        return ref.description
    }

    @MainActor
    static func askCanvas(tool: CanvasAskTool, itemIDs: [String]) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        if studio.knowledgeMap.content.nodes.isEmpty {
            await studio.refreshKnowledgeMapContent()
        }
        let map = studio.knowledgeMap
        let refs = itemIDs.map { canvasAskRef($0, in: map) }
        let unknown = refs.filter { map.nodesByRef[$0] == nil }
        let unknownNote = unknown.isEmpty ? "" : " Not on the canvas: \(unknown.prefix(20).joined(separator: ", "))."
        let task: Task<CanvasAskService.Result, Error>
        do {
            task = try studio.beginCanvasAsk(tool, refs: refs.filter { map.nodesByRef[$0] != nil })
        } catch StudioViewModel.CanvasAskRefusal.lensShowing {
            throw MCPError.invalidInput("A lens is showing on the learner's Canvas, and proposals never show with one. Call clear_map_lens first, or ask the learner to press Back to My Canvas.")
        } catch {
            let message = error.localizedDescription
            throw MCPError.invalidInput((message.hasSuffix(".") ? message : message + ".") + unknownNote)
        }
        if !studio.knowledgeMapIsOnScreen {
            studio.openCenterTabBeside(.knowledgeMap)
        }
        let result: CanvasAskService.Result
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if task.isCancelled || error is CancellationError {
                throw MCPError.invalidInput("The ask was stopped before ForeverLM answered; nothing was proposed.")
            }
            throw error
        }

        func card(_ ref: String) -> [String: Any] {
            ["item_id": ref, "title": map.title(of: ref)]
        }
        let passages = Dictionary(result.context.passages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let proposals: [[String: Any]] = result.answers.map { answer in
            let proposal = answer.proposal
            var entry: [String: Any] = ["proposal_id": proposal.id, "kind": proposal.kind.rawValue]
            switch proposal.kind {
            case .source:
                if let ref = proposal.ref { entry["source"] = card(ref) }
            case .edge:
                if let from = proposal.from { entry["from"] = card(from) }
                if let to = proposal.to { entry["to"] = card(to) }
                if let label = proposal.label { entry["label"] = label }
                if let relation = proposal.relation { entry["relation"] = relation }
            case .question:
                if let text = proposal.text { entry["question"] = text }
            }
            if let why = proposal.why { entry["why"] = why }
            if !proposal.near.isEmpty { entry["near"] = proposal.near.map(card) }
            // The passages it rests on, in the library's own words.
            let grounds: [[String: Any]] = answer.cites.compactMap { id in
                guard let passage = passages[id] else { return nil }
                return ["item_id": passage.ref, "title": map.title(of: passage.ref), "excerpt": passage.text]
            }
            if !grounds.isEmpty { entry["grounds"] = grounds }
            return entry
        }
        var output: [String: Any] = [
            "tool": tool.rawValue,
            "asked": result.set.anchor.map(card),
            "proposals": proposals,
            "shown_on_canvas": !proposals.isEmpty && map.proposals?.id == result.set.id,
            "note": proposals.isEmpty
                ? "ForeverLM found nothing to propose for these cards; the Canvas is unchanged."
                : "Drawn dotted on the learner's Canvas beside the asked cards, with Keep All and Dismiss All. Keeping a proposal is the learner's act; no tool keeps one.",
        ]
        if !unknown.isEmpty { output["not_on_canvas"] = Array(unknown.prefix(50)) }
        return output
    }
}
#endif
