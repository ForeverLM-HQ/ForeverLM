#if os(macOS)
import Foundation

// MARK: - Memory on the Canvas over MCP (docs/knowledge-map-design.md, "Memory on the Canvas")
//
// Two tools on the learner's Canvas, which lives in the Mac's one Studio view
// model, so both need the Mac (desktop-only on the gateway):
//
// - `get_canvas_memory` reads how the kept cards behind each card on the
//   Canvas stand — the Memory layer's marks — and per region, with the arrows
//   by edge_id for the tool below. Reads only.
// - `make_cards_from_canvas` is the Canvas's Make Cards: one or two cards from
//   each of the learner's Ideas and arrows, standing on passages of their
//   sources, into Memory's To Check. Spends on the learner's Card Drafting
//   model.

extension MCPToolRegistry {
    static var canvasMemoryToolDefs: [MCPToolDef] {
        let itemIDs: [String: Any] = [
            "type": "array",
            "items": ["type": "string"],
            "description": "Cards on the Canvas by item_id as get_knowledge_map gives them: idea:<idea_id>, source:<source_id> or doc:<doc_id>. A bare id is tried as a source, then a Doc, then an Idea.",
        ]
        return [
            MCPToolDef(
                name: "make_cards_from_canvas",
                description: "Draft Memory cards from what the learner made sense of on their Canvas, as the Canvas's Make Cards does: one or two cards from each of their Ideas (item_ids idea:<id>) and each arrow they drew (edge_ids, as get_canvas_memory lists them), in the learner's own wording where possible, an arrow's cards asking how or why one end leads to the other. Each card stands on a passage of the sources behind it (an Idea's evidence, the sources of an arrow's two ends), quoted word for word: a card whose quote its source does not print is reported under not_grounded and never offered. The cards wait in Memory's To Check, where the learner keeps, edits or skips them; nothing is kept without the learner. An Idea with no evidence gives no card (ideas_without_evidence). Sources named with no Idea or arrow are not drafted here: they come back under source_ids_for_draft_cards, for draft_cards. One model call for every eight Ideas and arrows, on the learner's Card Drafting model. Returns drafted, not_grounded, already_drafted (the same Idea drafted before), the sources whose decks gained cards, and why anything was left out.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "item_ids": itemIDs,
                        "edge_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Arrows the learner drew, by the edge_id get_canvas_memory lists under arrows.",
                        ],
                    ],
                    "required": ["item_ids"],
                ]
            ),
            MCPToolDef(
                name: "get_canvas_memory",
                description: "Read how the learner's Memory cards stand behind the cards on their Canvas: for each card drawn on the Canvas (or the item_ids given), the kept cards anchored to its sources (a source its own, an Idea its evidence's, a Doc its citations') with cards, due (cards whose answer counts now: due, or kept and never answered), fading (overdue by more than two days), solid (scheduled ahead), dusty (mostly fading, or untouched for a month) and last_reviewed_at; the same for each region; the arrows the learner drew, by edge_id, for make_cards_from_canvas; and whether the Canvas's Memory layer shows and a review in place runs. Reads only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "item_ids": itemIDs,
                    ],
                    "required": [] as [String],
                ]
            ),
        ]
    }

    static let canvasMemoryToolNames: Set<String> = ["make_cards_from_canvas", "get_canvas_memory"]
}

extension MCPDataStore {
    func executeCanvasMemoryTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "make_cards_from_canvas":
            return try jsonString(try await Self.makeCardsFromCanvas(
                itemIDs: arguments["item_ids"] as? [String] ?? [],
                edgeIDs: arguments["edge_ids"] as? [String] ?? []
            ))
        case "get_canvas_memory":
            return try jsonString(try await Self.canvasMemorySnapshot(itemIDs: arguments["item_ids"] as? [String]))
        default:
            return nil
        }
    }

    // MARK: Main-actor work

    @MainActor
    private static func canvasMemoryStudio() async throws -> StudioViewModel {
        let studio = try AppModelBridge.requireStudio()
        if studio.knowledgeMap.content.nodes.isEmpty {
            await studio.refreshKnowledgeMapContent()
        }
        return studio
    }

    /// A ref as the Canvas knows it: a bare id is a source when the Canvas
    /// has that source, else a Doc, else an Idea. Nil for one it does not hold.
    @MainActor
    private static func canvasRef(_ raw: String, in map: KnowledgeMapModel) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let ref = KnowledgeMap.ItemRef(trimmed) {
            return map.nodesByRef[ref.description] != nil ? ref.description : nil
        }
        for kind in [KnowledgeMap.ItemKind.source, .doc, .idea] {
            let ref = KnowledgeMap.ItemRef(kind: kind, id: trimmed).description
            if map.nodesByRef[ref] != nil { return ref }
        }
        return nil
    }

    @MainActor
    static func makeCardsFromCanvas(itemIDs: [String], edgeIDs: [String]) async throws -> [String: Any] {
        let studio = try await canvasMemoryStudio()
        let map = studio.knowledgeMap
        var unknown: [String] = []
        var refs: [String] = []
        for raw in itemIDs {
            if let ref = canvasRef(raw, in: map) {
                if !refs.contains(ref) { refs.append(ref) }
            } else {
                unknown.append(raw)
            }
        }
        let edges = edgeIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let unknownEdges = edges.filter { map.layout.edges[$0] == nil }
        guard unknown.isEmpty, unknownEdges.isEmpty else {
            var parts: [String] = []
            if !unknown.isEmpty { parts.append("no card on the Canvas answers to \(unknown.prefix(20).joined(separator: ", "))") }
            if !unknownEdges.isEmpty { parts.append("no arrow answers to \(unknownEdges.prefix(20).joined(separator: ", "))") }
            throw MCPError.invalidInput("Nothing was drafted: \(parts.joined(separator: "; ")). get_knowledge_map lists the cards and get_canvas_memory the arrows by edge_id.")
        }
        guard !refs.isEmpty || !edges.isEmpty else {
            throw MCPError.invalidInput("Pass item_ids (idea:<id> for the learner's Ideas) or edge_ids for the arrows to draft cards from.")
        }
        guard !map.memory.isMakingCards else {
            throw MCPError.invalidInput("Cards are being drafted from the Canvas already; call again once that finishes.")
        }
        let result: KnowledgeMapCardsResult
        do {
            result = try await studio.makeKnowledgeMapCards(refs: refs, edgeIDs: edges, presentingSourceSheet: false)
        } catch let error as CardDraftingError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        var payload: [String: Any] = [
            "ideas_without_evidence": result.ideasWithoutEvidence,
            "arrows_without_sources": result.arrowsWithoutSources,
        ]
        guard let report = result.report else {
            payload["status"] = result.sourceIDsForSourceMakeCards.isEmpty ? "nothing_to_draft" : "sources_only"
            payload["drafted"] = 0
            payload["source_ids_for_draft_cards"] = result.sourceIDsForSourceMakeCards
            payload["message"] = result.sourceIDsForSourceMakeCards.isEmpty
                ? "Nothing was drafted: none of these is an Idea with evidence or an arrow whose two ends have sources. Link a source to an Idea first (link_idea)."
                : "Nothing was drafted here: these are sources with no Idea or arrow. Draft their cards with draft_cards and these source_ids."
            return payload
        }
        payload["status"] = report.drafted > 0 ? "drafted" : "nothing_new"
        payload["drafted"] = report.drafted
        payload["not_grounded"] = report.notGrounded
        payload["already_drafted"] = report.alreadyDrafted
        payload["source_ids"] = report.sourceIDs
        if report.anchorsWithoutPassages > 0 { payload["without_passages"] = report.anchorsWithoutPassages }
        if !report.refused.isEmpty { payload["refused"] = Array(report.refused.prefix(20)) }
        if !report.failures.isEmpty { payload["failures"] = report.failures }
        payload["message"] = report.drafted > 0
            ? "\(report.summary). They wait in Memory's To Check for the learner to keep, edit or skip; list_cards lists them."
            : report.nothingDraftedMessage
        return payload
    }

    @MainActor
    static func canvasMemorySnapshot(itemIDs: [String]?) async throws -> [String: Any] {
        let studio = try await canvasMemoryStudio()
        let map = studio.knowledgeMap
        let layout = map.layout
        // The cards drawn: placed ones, the evidence hanging under placed
        // Ideas, and the cards a notebook's frame draws unplaced.
        var drawn: [String] = []
        var seen = Set<String>()
        func add(_ ref: String) {
            if map.nodesByRef[ref] != nil, seen.insert(ref).inserted { drawn.append(ref) }
        }
        var regionCards: [String: [String]] = [:]
        if let itemIDs, !itemIDs.isEmpty {
            for raw in itemIDs {
                if let ref = canvasRef(raw, in: map) { add(ref) }
            }
        } else {
            for ref in layout.placements.keys.sorted() {
                add(ref)
                if KnowledgeMap.ItemRef(ref)?.kind == .idea { map.evidence(of: ref).forEach(add) }
            }
            for id in layout.regions.keys.sorted() {
                guard let notebook = map.notebook(ofRegion: id) else { continue }
                notebook.refs.filter { layout.placements[$0] == nil }.forEach(add)
            }
        }
        for ref in layout.placements.keys where map.nodesByRef[ref] != nil {
            if let region = map.regionID(containing: ref) { regionCards[region, default: []].append(ref) }
        }
        for id in layout.regions.keys {
            guard let notebook = map.notebook(ofRegion: id) else { continue }
            regionCards[id, default: []] += notebook.refs.filter { layout.placements[$0] == nil }
        }
        // Every card's sources in one pass over the Canvas's links.
        let behind = CanvasMemoryMarks.refSources(content: map.content) { studio.canonicalSourceID($0) }
        var groups: [String: Set<String>] = [:]
        for ref in drawn { groups[ref] = behind[ref] ?? [] }
        for (id, refs) in regionCards {
            groups["region:" + id] = refs.reduce(into: Set<String>()) { $0.formUnion(behind[$1] ?? []) }
        }
        let marks = try await studio.storage.canvasMemoryMarks(for: groups.filter { !$0.value.isEmpty })
        let formatter = KnowledgeStore.iso8601Formatter
        func entry(_ mark: KnowledgeMapMemoryMark) -> [String: Any] {
            var entry: [String: Any] = [
                "cards": mark.cards,
                "due": mark.due,
                "fading": mark.fading,
                "solid": mark.solid,
                "dusty": mark.dusty,
            ]
            if let last = mark.lastReviewedAt { entry["last_reviewed_at"] = formatter.string(from: last) }
            return entry
        }
        let cards: [[String: Any]] = drawn.compactMap { ref in
            guard let mark = marks[ref] else { return nil }
            var card = entry(mark)
            card["item_id"] = ref
            card["title"] = map.title(of: ref)
            return card
        }
        let regions: [[String: Any]] = layout.regions
            .sorted { ($0.value.y, $0.value.x) < ($1.value.y, $1.value.x) }
            .compactMap { id, region in
                guard let mark = marks["region:" + id] else { return nil }
                var entry = entry(mark)
                entry["region_id"] = id
                entry["name"] = map.notebook(ofRegion: id)?.title ?? (region.name.isEmpty ? "Untitled region" : region.name)
                return entry
            }
        let arrows: [[String: Any]] = layout.edges
            .sorted { ($0.value.from, $0.value.to, $0.key) < ($1.value.from, $1.value.to, $1.key) }
            .map { id, edge in
                var arrow: [String: Any] = [
                    "edge_id": id,
                    "from": ["item_id": edge.from, "title": map.title(of: edge.from)],
                    "to": ["item_id": edge.to, "title": map.title(of: edge.to)],
                ]
                if !edge.label.isEmpty { arrow["label"] = edge.label }
                return arrow
            }
        var payload: [String: Any] = [
            "memory_layer_shown": map.memory.isShown,
            "cards_with_memory": cards,
            "cards_without_memory": drawn.count - cards.count,
            "regions": regions,
            "arrows": arrows,
            "read_at": formatter.string(from: Date()),
        ]
        if let review = map.memory.review {
            let sitting = review.session.sitting
            payload["review_in_place"] = [
                "card": sitting.cardNumber,
                "of": sitting.cardCount,
                "kind": review.kind.rawValue,
            ] as [String: Any]
        }
        return payload
    }
}
#endif
