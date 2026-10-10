import Foundation

// MARK: - Building an Atlas (docs/atlas-design.md)
//
// Retrieval from the learner's library (the app keeps every passage's exact
// text), one skeleton call that lays the topic out as concepts, and, when the
// learner focuses a concept at the paragraph or steps level, one deepening
// call for it with a fresh retrieval. Both calls run on the Atlas task's
// model (`AITask.atlasWriting`, the chat's) and cite passages only by the
// ids the app gave.

enum AtlasBuildError: LocalizedError, Equatable {
    case noModel(String)
    case unknownConcept

    var errorDescription: String? {
        switch self {
        case .noModel(let message): return message
        case .unknownConcept: return "That concept is no longer in this Atlas."
        }
    }

    /// Why the Atlas task has no model, as plainly as Settings can say it.
    static func noModelConfigured() -> AtlasBuildError {
        .noModel(KeychainService.backgroundAIUnavailableMessage(for: .atlasWriting)
            ?? "No model is set up for the Atlas. Sign in and check Settings › AI Models.")
    }
}

// MARK: Retrieval

enum AtlasRetrieval {
    /// A source's stored text as retrieval reads it.
    struct SourceText: Sendable {
        var sourceID: String
        var title: String
        var year: String?
        var content: String
        /// The chunks the vector search ranked nearest the query, best first,
        /// by their position in `SourceEmbeddingText.textChunks`.
        var rankedChunks: [Int]
    }

    /// The best passages of each source, sources in the order given: the
    /// chunks the vector search ranked, then those holding most of the
    /// query's words, else the opening. Each passage is the source's own
    /// words (whitespace made single spaces), at most `characters` long,
    /// begun and ended at a sentence where one is near. Numbered p1, p2, …
    /// from `firstNumber`.
    static func passages(
        from sources: [SourceText],
        queryTerms: [String],
        perSource: Int,
        characters: Int = AtlasLimits.passageCharacters,
        firstNumber: Int = 1
    ) -> [AtlasPassage] {
        var result: [AtlasPassage] = []
        var number = firstNumber
        let terms = queryTerms.map { $0.lowercased() }.filter { $0.count > 1 }
        for source in sources {
            let chunks = SourceEmbeddingText.textChunks(from: source.content)
            guard !chunks.isEmpty, perSource > 0 else { continue }
            var picked: [Int] = []
            // Neighbouring chunks overlap by design; one of a pair is enough.
            func take(_ index: Int) {
                guard index >= 0, index < chunks.count, picked.count < perSource,
                      !picked.contains(where: { abs($0 - index) <= 1 }) else { return }
                picked.append(index)
            }
            for index in source.rankedChunks { take(index) }
            if picked.count < perSource, !terms.isEmpty {
                let scored = chunks.enumerated()
                    .map { (index: $0.offset, hits: termHits($0.element, terms: terms)) }
                    .filter { $0.hits > 0 }
                    .sorted { ($0.hits, -$0.index) > ($1.hits, -$1.index) }
                for entry in scored { take(entry.index) }
            }
            if picked.isEmpty { picked = [0] }
            for index in picked {
                let text = excerpt(chunks[index], characters: characters)
                guard !text.isEmpty else { continue }
                result.append(AtlasPassage(id: "p\(number)", sourceID: source.sourceID, title: source.title, year: source.year, text: text))
                number += 1
            }
        }
        return result
    }

    static func termHits(_ text: String, terms: [String]) -> Int {
        let lower = text.lowercased()
        return terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }

    /// A stretch of `chunk` no longer than `characters`: from the first
    /// sentence that starts in its first quarter (when the chunk opens
    /// mid-sentence), to the last sentence that ends past its middle, else
    /// to a word. Never more words than the chunk holds, never other words.
    static func excerpt(_ chunk: String, characters: Int) -> String {
        var text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let first = text.first, first.isLowercase {
            let chars = Array(text)
            let limit = min(chars.count / 4, 220)
            var index = 0
            while index + 2 < limit {
                if ".!?".contains(chars[index]), chars[index + 1] == " ", chars[index + 2].isUppercase || chars[index + 2].isNumber {
                    text = String(chars[(index + 2)...])
                    break
                }
                index += 1
            }
        }
        guard text.count > characters else { return text }
        let chars = Array(text.prefix(characters))
        var end = chars.count - 1
        while end > characters / 2 {
            if ".!?".contains(chars[end]), end + 1 == chars.count || chars[end + 1] == " " {
                return String(chars[...end])
            }
            end -= 1
        }
        let head = String(chars)
        if let space = head.lastIndex(of: " ") { return String(head[..<space]) }
        return head
    }

    /// The four-digit year in a source's published-year field, if it has one.
    static func year(_ raw: String?) -> String? {
        guard let raw, let range = raw.range(of: #"(1[5-9]|20)\d{2}"#, options: .regularExpression) else { return nil }
        return String(raw[range])
    }
}

extension StorageService {
    // MARK: Atlases (KnowledgeStore+Sensemaking.swift), off the main actor

    func loadAtlasRows(limit: Int = 200) throws -> [AtlasRow] {
        try notebookFilesKnowledgeStore().atlasRows(limit: limit)
    }

    func loadAtlasRow(id: String) throws -> AtlasRow? {
        try notebookFilesKnowledgeStore().atlasRow(id: id)
    }

    func saveAtlasRow(_ row: AtlasRow) throws {
        try notebookFilesKnowledgeStore().saveAtlasRow(row)
    }

    func deleteAtlasRow(id: String) throws {
        try notebookFilesKnowledgeStore().deleteAtlasRow(id: id)
    }

    /// Each source's chunks nearest `queryVector`, best first, at most
    /// `perSource` each: one pass of the shared vector index over just these
    /// sources. The knowledge policy's exclusions apply as in every search.
    func atlasRankedChunks(queryVector: [Float], sourceIDs: [String], perSource: Int) throws -> [String: [Int]] {
        guard !sourceIDs.isEmpty, perSource > 0 else { return [:] }
        let store = try notebookFilesKnowledgeStore()
        let hits = Self.searchChunkVectors(
            queryVector: queryVector,
            topK: max(sourceIDs.count * perSource * 4, 40),
            threshold: -1,
            restrictedTo: Set(sourceIDs),
            using: store
        )
        var ranked: [String: [Int]] = [:]
        for hit in hits.sorted(by: { $0.score > $1.score }) {
            guard let index = Self.sourceChunkIndex(fromSourceChunkEmbeddingId: hit.chunkId),
                  ranked[hit.sourceId, default: []].count < perSource else { continue }
            ranked[hit.sourceId, default: []].append(index)
        }
        return ranked
    }
}

// MARK: The builder

@MainActor
enum AtlasBuilder {
    /// What a build reads.
    struct Request: Equatable, Sendable {
        /// What to search for and lay out.
        var topic: String
        /// The learner named the topic, or it is their region, Idea or
        /// notebook name; false when it was read from card titles, and the
        /// model names it.
        var topicIsLearners: Bool
        var scope: AtlasScope
        /// The sources the scope holds, searched first.
        var scopeSourceIDs: [String]
        /// The learner's own words for the topic: Idea sentences, region
        /// names, the notebook's name.
        var learnerTerms: [String]
    }

    enum Stage: Equatable, Sendable {
        case reading
        case writing
    }

    /// Reads the library and writes a new Atlas; with `replacing`, writes it
    /// again under that Atlas's id (Rebuild). Nothing is saved here.
    static func build(
        _ request: Request,
        replacing previous: Atlas? = nil,
        studio: StudioViewModel,
        stage: (Stage) -> Void = { _ in }
    ) async throws -> Atlas {
        guard let config = KeychainService.resolveConfig(for: .atlasWriting) else {
            throw AtlasBuildError.noModelConfigured()
        }
        stage(.reading)
        let passages = try await retrieve(
            query: request.topic,
            scopeSourceIDs: request.scopeSourceIDs,
            sourceLimit: AtlasLimits.buildSources,
            perSource: AtlasLimits.passagesPerSource,
            studio: studio
        )
        try Task.checkCancellation()
        stage(.writing)
        let skeleton = try await studio.aiService.atlasSkeleton(
            topic: request.topic,
            topicIsLearners: request.topicIsLearners,
            learnerTerms: request.learnerTerms,
            passages: passages,
            config: config,
            subjectID: previous?.id ?? "atlas"
        )
        try Task.checkCancellation()
        let now = Date()
        let topic = request.topicIsLearners ? request.topic : (skeleton.topic ?? request.topic)
        // Only the passages a concept cites are kept with the Atlas.
        let cited = Set(skeleton.concepts.flatMap { $0.evidence.map(\.passageID) })
        return Atlas(
            id: previous?.id ?? "atlas:" + UUID().uuidString.lowercased(),
            topic: topic,
            scope: request.scope,
            rootID: skeleton.rootID,
            concepts: skeleton.concepts,
            passages: passages.filter { cited.contains($0.id) },
            createdAt: previous?.createdAt ?? now,
            updatedAt: now,
            model: config.model
        )
    }

    /// One concept written in depth with a fresh retrieval for it; the
    /// passages it cites join the pool. Nothing is saved here.
    static func deepen(_ atlas: Atlas, conceptID: String, studio: StudioViewModel) async throws -> Atlas {
        guard let concept = atlas.concept(conceptID) else { throw AtlasBuildError.unknownConcept }
        guard let config = KeychainService.resolveConfig(for: .atlasWriting) else {
            throw AtlasBuildError.noModelConfigured()
        }
        let scopeSourceIDs = await scopeSourceIDs(for: atlas.scope, studio: studio)
        let fresh = try await retrieve(
            query: "\(concept.name) \(atlas.topic)",
            scopeSourceIDs: scopeSourceIDs,
            sourceLimit: AtlasLimits.deepenSources,
            perSource: AtlasLimits.passagesPerSource,
            studio: studio
        )
        try Task.checkCancellation()
        let offered = atlas.numbering(fresh)
        let known = atlas.evidencePassages(of: conceptID).map(\.passage)
        let deepening = try await studio.aiService.atlasDeepening(
            atlas: atlas,
            concept: concept,
            passages: known + offered,
            config: config
        )
        try Task.checkCancellation()
        return atlas.merging(deepening, into: conceptID, offered: offered, at: Date())
    }

    /// The sources a scope holds: the Canvas cards' sources (an Idea's
    /// evidence, a Doc's cited sources, a clip's paper) and a notebook's
    /// ticked ones.
    static func scopeSourceIDs(for scope: AtlasScope, studio: StudioViewModel) async -> [String] {
        var ids: [String] = []
        var seen: Set<String> = []
        func add(_ id: String) {
            let id = studio.canonicalSourceID(id)
            if seen.insert(id).inserted { ids.append(id) }
        }
        for raw in scope.itemRefs {
            guard let ref = KnowledgeMap.ItemRef(raw) else { continue }
            switch ref.kind {
            case .source:
                add(ref.id)
            case .idea:
                if let idea = studio.ideas.first(where: { $0.id == ref.id }) {
                    for link in idea.links where link.kind == .source { add(link.targetID) }
                }
            case .doc:
                if let artifact = studio.artifacts.first(where: { $0.id == ref.id }) {
                    artifact.sourceIDs.forEach(add)
                }
            case .clip:
                // A clip is cut from a page of a paper; that paper is what
                // the scope holds.
                if let clip = studio.knowledgeMap.clips[ref.id] { add(clip.sourceID) }
            case .page:
                // A page is a page of a paper; that paper is what the scope holds.
                if let parts = ref.pageParts { add(parts.sourceID) }
            case .chat:
                // A chat is about the sources it was held over.
                studio.reviewSessionLinks.first { $0.id == ref.id }?.sourceIDs.forEach(add)
            case .canvas, .picture:
                // A shortcut to another canvas and a picture hold no source.
                break
            }
        }
        if let notebookID = scope.notebookID, let notebook = studio.notebook(id: notebookID) {
            notebook.approvedSourceIDs.forEach(add)
        }
        return ids
    }

    /// Up to `sourceLimit` sources for `query` (the scope's first, ranked,
    /// then the rest of the scope, then the whole library), and their best
    /// passages, read from the stored text. The knowledge policy's
    /// exclusions (kept from AI, hidden, off screen while recording) apply.
    static func retrieve(
        query: String,
        scopeSourceIDs: [String],
        sourceLimit: Int,
        perSource: Int,
        studio: StudioViewModel
    ) async throws -> [AtlasPassage] {
        let storage = studio.storage
        let terms = SourceSearchEngine.searchTerms(for: query)
        var vector: [Float]?
        do {
            vector = try await studio.aiService.embedText(query)
        } catch {
            // The lexical and metadata branches still find the topic's words,
            // as the Sources search does when an embedding fails.
            studio.logger.error("Atlas query embedding failed; searching without the semantic branch: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        var chosen: [String] = []
        var seen: Set<String> = []
        func take(_ ids: [String]) {
            for id in ids where chosen.count < sourceLimit && studio.articlesById[id] != nil && seen.insert(id).inserted {
                chosen.append(id)
            }
        }
        if !scopeSourceIDs.isEmpty {
            let hits = await storage.searchSources(
                queryText: query,
                queryVector: vector,
                limit: max(sourceLimit * 2, 30),
                restrictedTo: Set(scopeSourceIDs)
            )
            take(hits.map(\.sourceId))
            let excluded = try await storage.knowledgeSearchExcludedSourceIDs(includeArchived: true)
            take(scopeSourceIDs.filter { !excluded.contains($0) })
        }
        if chosen.count < sourceLimit {
            let hits = await storage.searchSources(queryText: query, queryVector: vector, limit: sourceLimit * 3)
            take(hits.map(\.sourceId))
        }
        try Task.checkCancellation()
        guard !chosen.isEmpty else { return [] }
        var ranked: [String: [Int]] = [:]
        if let vector {
            ranked = try await storage.atlasRankedChunks(queryVector: vector, sourceIDs: chosen, perSource: perSource + 1)
        }
        var texts: [AtlasRetrieval.SourceText] = []
        for id in chosen {
            try Task.checkCancellation()
            guard let article = studio.articlesById[id],
                  let content = await storage.loadSourceContent(id),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            texts.append(.init(
                sourceID: id,
                title: article.title,
                year: AtlasRetrieval.year(article.publishedYear),
                content: content,
                rankedChunks: ranked[id] ?? []
            ))
        }
        let sources = texts
        return await Task.detached(priority: .userInitiated) {
            AtlasRetrieval.passages(from: sources, queryTerms: terms, perSource: perSource)
        }.value
    }
}

// MARK: - The calls

extension AIService {
    struct AtlasSkeleton: Sendable {
        var topic: String?
        var rootID: String
        var concepts: [AtlasConcept]
    }

    static func atlasPassagesJSON(_ passages: [AtlasPassage]) -> [[String: Any]] {
        passages.map { passage in
            let source = passage.year.map { "\(passage.title) (\($0))" } ?? passage.title
            return ["id": passage.id, "source": source, "text": passage.text]
        }
    }

    static func atlasJSONString(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The skeleton: the topic's concepts at the gist and line levels, the
    /// paragraphs of the root and its children, terms, relations and
    /// evidence by passage id. A reply that is not an Atlas is refused, so
    /// it is never cached and a backup model may answer instead.
    func atlasSkeleton(
        topic: String,
        topicIsLearners: Bool,
        learnerTerms: [String],
        passages: [AtlasPassage],
        config: AITaskConfig,
        subjectID: String
    ) async throws -> AtlasSkeleton {
        let system = AITask.atlasWriting.effectivePrompt ?? Prompts.atlasWriter
        var message: [String: Any] = [
            "topic": topic,
            "topic_named_by": topicIsLearners ? "the learner" : "ForeverLM, from the titles of the learner's cards: name the topic yourself",
            "passages": Self.atlasPassagesJSON(passages),
        ]
        if !learnerTerms.isEmpty { message["learner_terms"] = learnerTerms }
        let ids = Set(passages.map(\.id))
        let response = try await call(
            config: config,
            system: system,
            user: Self.atlasJSONString(message),
            maxTokens: 9_000,
            temperature: 0.3,
            jsonMode: true,
            validateResponse: { reply in _ = try AtlasResponse.skeleton(from: reply, passageIDs: ids) },
            sourceTitle: "Atlas: \(topic)",
            subjectID: subjectID
        )
        let parsed = try AtlasResponse.skeleton(from: response, passageIDs: ids)
        return AtlasSkeleton(topic: parsed.topic, rootID: parsed.rootID, concepts: parsed.concepts)
    }

    /// One concept in depth: a paragraph, numbered steps, more terms, more
    /// evidence and open questions, citing only `passages`.
    func atlasDeepening(
        atlas: Atlas,
        concept: AtlasConcept,
        passages: [AtlasPassage],
        config: AITaskConfig
    ) async throws -> AtlasDeepening {
        // The task's own prompt (and a learner's override of it in Settings)
        // is the skeleton's; a deepening answers a different shape.
        let system = Prompts.atlasDeepener
        let neighbours = atlas.neighbourhood(of: concept.id)
        var focus: [String: Any] = [
            "id": concept.id,
            "name": concept.name,
            "kind": concept.kind.rawValue,
            "line": concept.line,
            "status": concept.status.rawValue,
            "terms": concept.terms.map { ["term": $0.term, "definition": $0.definition] },
        ]
        if let paragraph = concept.paragraph { focus["paragraph"] = paragraph }
        let message: [String: Any] = [
            "topic": atlas.topic,
            "concept": focus,
            "above": neighbours.broader.map(\.name),
            "below": neighbours.narrower.map { ["name": $0.name, "line": $0.line] },
            "know_first": neighbours.knowFirst.map(\.name),
            "beside": neighbours.related.map { ["name": $0.concept.name, "relation": $0.phrase] },
            "passages": Self.atlasPassagesJSON(passages),
        ]
        let ids = Set(passages.map(\.id))
        let existing = concept.terms
        let response = try await call(
            config: config,
            system: system,
            user: Self.atlasJSONString(message),
            maxTokens: 3_000,
            temperature: 0.3,
            jsonMode: true,
            validateResponse: { reply in _ = try AtlasResponse.deepening(from: reply, passageIDs: ids, existingTerms: existing) },
            sourceTitle: "Atlas: \(atlas.topic)",
            subjectID: atlas.id
        )
        return try AtlasResponse.deepening(from: response, passageIDs: ids, existingTerms: existing)
    }
}
