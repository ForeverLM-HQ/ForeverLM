#if os(macOS)
import Foundation

// MARK: - The Atlas over MCP (docs/atlas-design.md)
//
// An Atlas is a topic laid out as a small hierarchy of concepts at levels of
// abstraction (a gist, a line, a paragraph, numbered steps), each concept
// citing passages from the learner's library that the app retrieved and
// keeps word for word. make_atlas builds one (or opens the one already made
// for the same topic and scope) and shows it in the Studio; get_atlas reads
// it, and with deepen writes one concept in depth; list_atlases and
// delete_atlas manage them. The tools answer from the app's one Studio view
// model and its storage actor, so they need the Mac and never hold the
// store gate.

extension MCPToolRegistry {
    static var atlasToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "make_atlas",
                description: "Lay a topic out as an Atlas in ForeverLM, for a learner who wants to understand it quickly at several levels of abstraction: a small hierarchy of 8 to 24 concepts (the field, its subtopics, concepts, mechanisms, methods, measures, claims and debates), each with a gist of a few words, a one-sentence line, terms a newcomer must know, how it relates to the others (prerequisite, part of, causes, measures, contrasts), whether it is established, debated or speculative, and the passages from the learner's own library that bear on it, cited by id (get_atlas gives their text). A concept no passage covers is kept and marked as not in the library. Scope it with item_ids (Canvas cards from get_knowledge_map) or a notebook_id, or leave both out for the whole library; with no topic, it is read from the cards or the notebook. The Atlas opens in the Studio's Atlas pane, where the learner can focus concepts, read them deeper, draft cards and lay them out on the Canvas. If an Atlas of the same topic and scope exists it is opened as it is and no model is called; pass rebuild true to write it again. Spends one model call on the learner's Atlas model when it builds.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "topic": ["type": "string", "description": "What to lay out, in the learner's words: a field, a mechanism, a question (\"the PINK1–Parkin axis in Parkinson's\"). Optional when item_ids or notebook_id are given."],
                        "item_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Canvas cards to make the Atlas over, as get_knowledge_map gives them: source:<source_id>, idea:<idea_id> (its evidence sources count) or doc:<doc_id> (its cited sources count). A bare source id is accepted too.",
                        ],
                        "notebook_id": ["type": "string", "description": "A notebook whose ticked sources the Atlas reads first."],
                        "rebuild": ["type": "boolean", "description": "Write the Atlas again even when one of this topic and scope exists. Defaults to false."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "get_atlas",
                description: "Read an Atlas: with no concept_id, every concept (id, name, kind, gist, line, paragraph and steps when written, parent, terms, relations, status, open questions, and evidence by passage id) and the passages they cite with their source ids, titles and exact text from the learner's library; with concept_id, that concept in full with its passages, broader and narrower concepts. deepen true (with concept_id) first writes the concept in depth (a textbook paragraph, 3 to 7 steps, more terms and evidence from a fresh search of the library), which spends one model call and is saved with the Atlas; a concept already deepened is not written again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "atlas_id": ["type": "string", "description": "The Atlas, as make_atlas or list_atlases gives it."],
                        "concept_id": ["type": "string", "description": "One concept's id (c1, c2, …)."],
                        "deepen": ["type": "boolean", "description": "Write the concept in depth before answering. Needs concept_id. Defaults to false."],
                    ],
                    "required": ["atlas_id"],
                ]
            ),
            MCPToolDef(
                name: "list_atlases",
                description: "List the Atlases made in ForeverLM, the latest first: each one's atlas_id, topic, notebook_id and Canvas item_ids it was made over, how many concepts it has, and when it was last written.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Most Atlases listed (default 50, at most 200)."],
                    ],
                    "required": [] as [String],
                ]
            ),
            MCPToolDef(
                name: "delete_atlas",
                description: "Delete an Atlas for good. It is ForeverLM's own writing and can be made again with make_atlas; cards the learner drafted from it stay.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "atlas_id": ["type": "string", "description": "The Atlas to delete."],
                    ],
                    "required": ["atlas_id"],
                ]
            ),
        ]
    }

    static let atlasToolNames: Set<String> = ["make_atlas", "get_atlas", "list_atlases", "delete_atlas"]
}

extension MCPDataStore {
    func executeAtlasTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "make_atlas":
            return try jsonString(try await Self.makeAtlas(arguments))
        case "get_atlas":
            return try jsonString(try await Self.getAtlas(arguments))
        case "list_atlases":
            let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 50, 1), 200)
            return try jsonString(try await Self.listAtlases(limit: limit))
        case "delete_atlas":
            return try jsonString(try await Self.deleteAtlas(arguments))
        default:
            return nil
        }
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A card as the Canvas names it: a bare id is a source when the library
    /// holds one, else a Doc, else an Idea.
    @MainActor
    private static func atlasItemRef(_ raw: String, studio: StudioViewModel) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = KnowledgeMap.ItemRef(text) {
            return ref.kind == .source ? KnowledgeMap.ItemRef(kind: .source, id: studio.canonicalSourceID(ref.id)).description : ref.description
        }
        let sourceID = studio.canonicalSourceID(text)
        if studio.articlesById[sourceID] != nil { return KnowledgeMap.ItemRef(kind: .source, id: sourceID).description }
        if studio.artifacts.contains(where: { $0.id == text }) { return KnowledgeMap.ItemRef(kind: .doc, id: text).description }
        if studio.ideas.contains(where: { $0.id == text }) { return KnowledgeMap.ItemRef(kind: .idea, id: text).description }
        return KnowledgeMap.ItemRef(kind: .source, id: sourceID).description
    }

    @MainActor
    static func makeAtlas(_ arguments: [String: Any]) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let topic = trimmed(arguments["topic"])
        let refs = (arguments["item_ids"] as? [String] ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { atlasItemRef($0, studio: studio) }
        let notebookID = trimmed(arguments["notebook_id"])
        guard topic != nil || !refs.isEmpty || notebookID != nil else {
            throw MCPError.invalidInput("make_atlas needs a topic, item_ids or a notebook_id.")
        }
        if let notebookID, studio.notebook(id: notebookID) == nil {
            throw MCPError.notFound("No notebook has the id \(notebookID). list_notebooks gives the ids.")
        }
        if !studio.atlasIsOnScreen {
            studio.revealAtlasPane()
        }
        await MCPToolActivityReporter.current?.report("Reading the library and writing the concepts")
        let made: (atlas: Atlas, existing: Bool)
        do {
            made = try await studio.makeAtlas(
                topic: topic,
                itemRefs: refs,
                notebookID: notebookID,
                rebuild: arguments["rebuild"] as? Bool ?? false
            )
        } catch AtlasRequestError.nothingToLayOut {
            throw MCPError.invalidInput("None of the item_ids is a card ForeverLM can read a topic from; pass a topic.")
        }
        var result = atlasSummary(made.atlas)
        result["opened_existing"] = made.existing
        result["note"] = made.existing
            ? "An Atlas of this topic and scope already existed; it is open in the Atlas pane as it was. Pass rebuild true to write it again."
            : "The Atlas is open in the learner's Atlas pane. get_atlas gives every concept's passages; get_atlas with concept_id and deepen true writes one concept in depth."
        return result
    }

    @MainActor
    static func getAtlas(_ arguments: [String: Any]) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        guard let atlasID = trimmed(arguments["atlas_id"]) else {
            throw MCPError.invalidInput("get_atlas needs atlas_id.")
        }
        let conceptID = trimmed(arguments["concept_id"])
        let deepen = arguments["deepen"] as? Bool ?? false
        if deepen, conceptID == nil {
            throw MCPError.invalidInput("deepen needs a concept_id: one concept is written in depth at a time.")
        }
        var atlas = try await loadAtlas(atlasID, studio: studio)
        if let conceptID, atlas.concept(conceptID) == nil {
            throw MCPError.notFound("The Atlas has no concept \(conceptID). Its concepts are \(atlas.concepts.map(\.id).joined(separator: ", ")).")
        }
        if deepen, let conceptID, atlas.concept(conceptID)?.deepened == false {
            await MCPToolActivityReporter.current?.report("Writing \(atlas.concept(conceptID)?.name ?? "the concept") in depth")
            atlas = try await studio.deepenAtlasConcept(atlasID: atlasID, conceptID: conceptID)
        }
        if let conceptID, let concept = atlas.concept(conceptID) {
            var entry = conceptDetail(concept, in: atlas)
            entry["atlas_id"] = atlas.id
            entry["topic"] = atlas.topic
            entry["broader"] = atlas.ancestors(of: conceptID).map { ["concept_id": $0.id, "name": $0.name] }
            entry["narrower"] = atlas.children(of: conceptID).map { ["concept_id": $0.id, "name": $0.name, "line": $0.line] }
            entry["passages"] = atlas.evidencePassages(of: conceptID).map { passageEntry($0.passage) }
            return entry
        }
        var result = atlasSummary(atlas)
        result["concepts"] = atlas.concepts.map { conceptDetail($0, in: atlas) }
        result["passages"] = atlas.passages.map(passageEntry)
        return result
    }

    @MainActor
    static func listAtlases(limit: Int) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        let rows = try await studio.storage.loadAtlasRows(limit: limit)
        let formatter = KnowledgeStore.iso8601Formatter
        let atlases: [[String: Any]] = rows.map { row in
            let listing = AtlasListing(row: row)
            var entry: [String: Any] = [
                "atlas_id": listing.id,
                "topic": listing.topic,
                "notebook_id": listing.notebookID ?? NSNull(),
                "item_ids": listing.scope.itemRefs,
                "updated_at": formatter.string(from: listing.updatedAt),
            ]
            if let atlas = try? Atlas(row: row) {
                entry["concept_count"] = atlas.concepts.count
            }
            return entry
        }
        return ["atlases": atlases, "count": atlases.count]
    }

    @MainActor
    static func deleteAtlas(_ arguments: [String: Any]) async throws -> [String: Any] {
        let studio = try AppModelBridge.requireStudio()
        guard let atlasID = trimmed(arguments["atlas_id"]) else {
            throw MCPError.invalidInput("delete_atlas needs atlas_id.")
        }
        guard let row = try await studio.storage.loadAtlasRow(id: atlasID) else {
            throw MCPError.notFound("No Atlas has the id \(atlasID). list_atlases gives the ids.")
        }
        try await studio.deleteAtlas(id: atlasID)
        return ["deleted": true, "atlas_id": atlasID, "topic": row.topic]
    }

    // MARK: Answers

    @MainActor
    private static func loadAtlas(_ id: String, studio: StudioViewModel) async throws -> Atlas {
        if let current = studio.atlas.current, current.id == id { return current }
        guard let row = try await studio.storage.loadAtlasRow(id: id) else {
            throw MCPError.notFound("No Atlas has the id \(id). list_atlases gives the ids.")
        }
        return try Atlas(row: row)
    }

    static func atlasSummary(_ atlas: Atlas) -> [String: Any] {
        [
            "atlas_id": atlas.id,
            "topic": atlas.topic,
            "root_concept_id": atlas.rootID,
            "notebook_id": atlas.scope.notebookID ?? NSNull(),
            "item_ids": atlas.scope.itemRefs,
            "concept_count": atlas.concepts.count,
            "concepts_in_library": atlas.groundedConceptCount,
            "concepts": atlas.concepts.map { concept -> [String: Any] in
                [
                    "concept_id": concept.id,
                    "name": concept.name,
                    "kind": concept.kind.rawValue,
                    "gist": concept.gist,
                    "line": concept.line,
                    "parent_id": concept.parentID ?? NSNull(),
                    "status": concept.status.rawValue,
                    "source_ids": atlas.evidenceSourceIDs(of: concept.id),
                ]
            },
            "source_ids": atlas.evidenceSourceIDs,
            "updated_at": KnowledgeStore.iso8601Formatter.string(from: atlas.updatedAt),
        ]
    }

    static func conceptDetail(_ concept: AtlasConcept, in atlas: Atlas) -> [String: Any] {
        var entry: [String: Any] = [
            "concept_id": concept.id,
            "name": concept.name,
            "kind": concept.kind.rawValue,
            "gist": concept.gist,
            "line": concept.line,
            "parent_id": concept.parentID ?? NSNull(),
            "status": concept.status.rawValue,
            "terms": concept.terms.map { ["term": $0.term, "definition": $0.definition] },
            "relations": concept.relations.map { relation -> [String: Any] in
                var item: [String: Any] = [
                    "to": relation.to,
                    "to_name": atlas.concept(relation.to)?.name ?? relation.to,
                    "kind": relation.kind.rawValue,
                ]
                if let label = relation.label { item["label"] = label }
                return item
            },
            "evidence": concept.evidence.map { ["passage_id": $0.passageID, "stance": $0.stance.rawValue] },
            "open_questions": concept.openQuestions,
            "deepened": concept.deepened,
            "source_ids": atlas.evidenceSourceIDs(of: concept.id),
        ]
        if let paragraph = concept.paragraph { entry["paragraph"] = paragraph }
        if let steps = concept.steps { entry["steps"] = steps }
        return entry
    }

    static func passageEntry(_ passage: AtlasPassage) -> [String: Any] {
        var entry: [String: Any] = [
            "passage_id": passage.id,
            "source_id": passage.sourceID,
            "title": passage.title,
            "text": passage.text,
        ]
        if let year = passage.year { entry["year"] = year }
        return entry
    }
}
#endif
