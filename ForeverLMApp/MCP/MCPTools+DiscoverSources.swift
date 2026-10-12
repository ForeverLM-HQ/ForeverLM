import Foundation

// MARK: - discover_sources
//
// A notebook's Discover over MCP (docs/notebooks-design.md): the sources a
// Notebook is missing, from one web search with the Notebook as context
// (`WebSourceDiscovery`, paid, on the chat's model). Papers are not searched
// here: `search_literature` is PubMed, free, and the in-app Papers tab is the
// same search. Nothing is imported here: the assistant shows the learner the
// candidates and imports the ones they pick through the ordinary import tools,
// so every address takes the library's one route in. Self-gated: the Notebook
// and its sources are read in one shared stretch, the search holds nothing,
// and the marks are read in a second shared stretch.

extension MCPDataStore {

    func discoverSources(
        notebookID: String?,
        query rawQuery: String?,
        count rawCount: Int?,
        sourceIDs rawSourceIDs: [String]?,
        services injected: SourceDiscoveryServices? = nil
    ) async throws -> String {
        let services = injected ?? .live(aiService: AIService(), storage: notebookFileStorage)
        let range = WebSourceDiscovery.countRange
        let count = rawCount ?? WebSourceDiscovery.defaultCount
        guard range.contains(count) else {
            throw MCPError.invalidInput("count must be \(range.lowerBound) to \(range.upperBound).")
        }

        // The Notebook and what it works from, before anything is spent.
        let (notebook, context) = try await withStoreGate(.shared) { () -> (LearningGoalRecord, NotebookDiscoveryContext) in
            let store = try knowledgeStore()
            let notebook = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
            guard !notebook.isArchived else {
                throw MCPError.invalidInput("Notebook \"\(notebook.title)\" is archived. Restore it with update_notebook before searching for its sources.")
            }
            let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
            let ids: [String]
            if let rawSourceIDs {
                let wanted = sanitizedSourceIDs(rawSourceIDs)
                let missing = try wanted.filter { id in try store.loadSourceForSync(id) == nil || excluded.contains(id) }
                guard missing.isEmpty else {
                    throw MCPError.invalidInput("Unknown source_ids: \(missing.joined(separator: ", ")). Use list_notebook_sources for the Notebook's sources.")
                }
                ids = wanted
            } else {
                // The Notebook's own ticked sources, as the notebook's Discover
                // names them (`discoverySourceIDs`): what its Studio works
                // from, never a context notebook's.
                ids = NotebookChatSelection.chatSourceIDs(
                    pool: notebook.approvedSourceIDs,
                    excluded: NotebookChatSelection.excluded(notebookID: notebook.id)
                ).filter { !excluded.contains($0) }
            }
            let lines = try ids.compactMap { id -> String? in
                guard let source = try store.loadSourceForSync(id) else { return nil }
                return WebSourceDiscovery.contextLine(
                    title: source.title,
                    author: source.author,
                    kind: StudioViewModel.discoveryKindWord(source.sourceType),
                    year: source.publishedYear
                )
            }
            let context = NotebookDiscoveryContext(
                title: notebook.title,
                instructions: notebook.description,
                researchQuestions: notebook.researchQuestions ?? [],
                sources: lines
            )
            return (notebook, context)
        }

        let dependencies = services.web
        guard let config = await MainActor.run(body: { services.resolveConfig() }) else {
            throw MCPError.invalidInput(
                KeychainService.backgroundAIUnavailableMessage(for: .sourceDiscovery)
                    ?? "Source Discovery has no model it can run on. Check the Chat model in Settings › AI Models."
            )
        }
        if let refusal = await WebSourceDiscovery.webSearchRefusal(config: config, dependencies: dependencies) {
            throw MCPError.invalidInput(
                "\(refusal.localizedDescription) Nothing was spent; search_literature searches PubMed for free."
            )
        }
        let result: WebSourceDiscoveryResult
        do {
            result = try await WebSourceDiscovery.run(
                query: rawQuery ?? "",
                context: context,
                count: count,
                config: config,
                dependencies: dependencies
            )
        } catch let error as WebSourceDiscoveryError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        try Task.checkCancellation()

        let candidates: [[String: Any]] = try await withStoreGate(.shared) {
            let store = try knowledgeStore()
            let marks = try discoveryMarks(store: store, notebook: notebook)
            return result.candidates.map { candidate in
                var row: [String: Any] = [
                    "title": candidate.title,
                    "url": candidate.url,
                    "kind": candidate.kind.rawValue,
                    "site": candidate.site,
                ]
                if !candidate.why.isEmpty { row["why"] = candidate.why }
                if let published = candidate.published { row["published"] = published }
                if let doi = candidate.doi { row["doi"] = doi }
                row.merge(marks(candidate.url)) { _, new in new }
                return row
            }
        }
        var payload: [String: Any] = [
            "notebook_id": notebook.id,
            "notebook_title": notebook.title,
            "query": result.query,
            "summary": result.summary,
            "candidates": candidates,
            "left_out": result.leftOut,
            "guidance": Self.discoverGuidance(empty: candidates.isEmpty),
        ]
        if result.notSources > 0 { payload["not_sources"] = result.notSources }
        return try jsonString(payload)
    }

    /// `in_library`, `library_source_id` and `in_notebook` for an address, in
    /// the Notebook's own library (a team Notebook's is the team's): by the
    /// address, the DOI or arXiv id in it, as a reference card is matched.
    /// A source the knowledge boundary hides counts as not held.
    private func discoveryMarks(
        store: KnowledgeStore,
        notebook: LearningGoalRecord
    ) throws -> (String) -> [String: Any] {
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let members = Set(notebook.approvedSourceIDs)
        let teamID = notebook.teamID
        return { url in
            guard let sourceID = store.activeSourceID(forReferenceURL: url, teamID: teamID),
                  !excluded.contains(sourceID) else {
                return ["in_library": false, "in_notebook": false]
            }
            return [
                "in_library": true,
                "library_source_id": sourceID,
                "in_notebook": members.contains(sourceID),
            ]
        }
    }

    static func discoverGuidance(empty: Bool) -> String {
        if empty {
            return "Nothing to offer. Try other words, or search_literature for papers."
        }
        return "Nothing was imported. Show the learner the candidates (title, kind, site, why) and import only the ones they pick: import_paper_from_url for a paper (it needs its PDF; one behind a paywall lands as PDF needed and is never read off its page), add_sources for the rest; then add_notebook_sources with the Notebook's id and the returned source ids. A candidate in_library needs only add_notebook_sources with its library_source_id; one in_notebook is there already."
    }
}
