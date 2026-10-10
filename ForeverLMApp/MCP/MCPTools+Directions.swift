import Foundation

// MARK: - Directions (docs/directions-design.md)
//
// Research directions over MCP, for ForeverLM's own chat and for an assistant
// connected from outside. The searching is the caller's: `find_directions`
// gathers what the learner already has and has already decided, and hands
// back the steps; `search_literature` reads the published and preprint
// record for free; `propose_directions` saves what the search kept. Nothing
// here asks a model anything or spends anything.
//
// The learner's answers — pursue, set aside, and why — are writes too
// (`update_direction`), the same the Directions list in the app makes, and
// they are the first thing the next search reads.

extension MCPDataStore {

    // MARK: find_directions

    /// The brief a direction search starts from: the home and its standing
    /// instructions, what the library already holds for it, the learner's own
    /// threads, every Direction already proposed toward it with its answer,
    /// the learner's recent answers elsewhere, and the steps to follow.
    func findDirections(homeID rawHomeID: String, focus rawFocus: String?) async throws -> String {
        let homeID = rawHomeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !homeID.isEmpty else {
            throw MCPError.invalidInput("home_id is required: the Goal (list_goals), Notebook (list_notebooks) or Idea (list_ideas) the directions are toward. If the learner's aim is none of these yet, create it first — create_idea when it has no date, create_learning_goal when it has one.")
        }
        let store = try knowledgeStore()
        guard let homeKind = try store.researchDirectionHomeKind(homeID) else {
            throw MCPError.notFound("No Goal, Notebook or Idea with id \(homeID) is in the library. Use list_goals, list_notebooks or list_ideas; if the aim is none of these yet, create it first — create_idea when it has no date, create_learning_goal when it has one.")
        }
        let focus = rawFocus.flatMap { ResearchDirection.normalizedText($0, limit: 1_000) }
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let formatter = ISO8601DateFormatter()

        var home: [String: Any] = ["kind": homeKind.rawValue, "id": homeID]
        var homeTitle = homeID
        var homeSourceIDs: [String] = []
        var instructions: [[String: Any]] = []
        var chatIDs: [String] = []
        var discoveryText: String

        switch homeKind {
        case .goal, .notebook:
            guard let record = try store.loadLearningGoal(homeID) else {
                throw MCPError.notFound("\(homeKind.noun.capitalized) \(homeID) was not found.")
            }
            homeTitle = record.title
            home["title"] = record.title
            if let topic = record.topic, topic != record.title { home["topic"] = topic }
            if homeKind == .goal {
                home["deadline"] = String(formatter.string(from: record.endAt).prefix(10))
            }
            if let description = record.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                instructions.append(["from": homeKind.noun, "title": record.title, "text": description])
            }
            if let questions = record.researchQuestions, !questions.isEmpty {
                home["research_questions"] = questions
            }
            let openGaps = (record.gaps ?? []).filter(\.isOpen).map(\.summary)
            if !openGaps.isEmpty { home["open_questions"] = openGaps }
            homeSourceIDs = record.approvedSourceIDs
            if let parentID = record.parentNotebookID, !parentID.isEmpty,
               let parent = try store.loadLearningGoal(parentID) {
                home["notebook"] = ["id": parent.id, "title": parent.title]
                if let description = parent.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                    instructions.append(["from": "notebook", "title": parent.title, "text": description])
                }
                if let questions = parent.researchQuestions, !questions.isEmpty {
                    home["notebook_research_questions"] = questions
                }
                homeSourceIDs += parent.approvedSourceIDs.filter { !homeSourceIDs.contains($0) }
            }
            chatIDs = try withDB { db in
                try query(db, "SELECT id FROM review_sessions WHERE goal_id = ? ORDER BY started_at DESC LIMIT 12", params: [homeID])
                    .compactMap { $0["id"] as? String }
            }
            discoveryText = [record.title, record.topic, focus].compactMap { $0 }.joined(separator: ". ")
        case .idea:
            guard let idea = try store.loadIdea(homeID) else {
                throw MCPError.notFound("Idea \(homeID) was not found. Use list_ideas.")
            }
            homeTitle = idea.title
            home["title"] = idea.title
            if let notes = idea.notes { home["notes"] = notes }
            homeSourceIDs = idea.linkedIDs(.source)
            chatIDs = idea.linkedIDs(.chat)
            discoveryText = [idea.title, idea.notes, focus].compactMap { $0 }.joined(separator: ". ")
        }
        if let focus { home["focus"] = focus }

        // What the home already holds, then what else the library has that
        // reads like it. A source the learner keeps from AI is never named.
        let visibleHomeSources = homeSourceIDs.filter { !excluded.contains($0) }
        var brief: [String: Any] = ["home": home]
        if !instructions.isEmpty { brief["standing_instructions"] = instructions }
        brief["sources"] = try directionSourceRows(Array(visibleHomeSources.prefix(40)))
        if visibleHomeSources.count > 40 { brief["sources_not_listed"] = visibleHomeSources.count - 40 }
        do {
            let related = try await companionDiscover(
                topic: discoveryText,
                excluding: Set(homeSourceIDs),
                sinceReferenceTimestamp: nil,
                limit: companionDiscoveryLimit,
                relativeMargin: companionRelativeMargin
            )
            brief["related_library_sources"] = try directionSourceRows(related.map(\.sourceID))
        } catch {
            // Said, not hidden: the search goes on without it, knowing.
            brief["related_library_sources_error"] = "The library's similarity search failed (\(error.localizedDescription)); use search_sources_semantic or search_sources_keyword instead."
        }

        // The learner's own threads: every open Idea (the connection angle
        // reads them), and the chats this home has.
        let ideas = try store.loadIdeas(includeArchived: false)
            .filter { $0.id != homeID }
            .prefix(40)
            .map { idea -> [String: Any] in
                var row: [String: Any] = ["idea_id": idea.id, "title": idea.title]
                if let notes = idea.notes { row["notes"] = String(notes.prefix(400)) }
                return row
            }
        brief["learner_ideas"] = Array(ideas)
        if !chatIDs.isEmpty {
            brief["chats"] = try withDB { db -> [[String: Any]] in
                let placeholders = chatIDs.map { _ in "?" }.joined(separator: ",")
                return try query(db, "SELECT id, topic, started_at FROM review_sessions WHERE id IN (\(placeholders)) ORDER BY started_at DESC", params: chatIDs)
                    .map { row in ["session_id": row["id"] as? String ?? "", "title": row["topic"] as? String ?? ""] }
            }
        }

        // What was proposed here before, answered or not, and how the
        // learner has answered elsewhere lately: the calibration.
        let existing = try store.loadResearchDirections(homeID: homeID)
        brief["directions"] = existing.map { direction -> [String: Any] in
            var row: [String: Any] = [
                "direction_id": direction.id,
                "title": direction.title,
                "angle": direction.angle.rawValue,
                "status": direction.status.rawValue,
            ]
            if let reason = direction.verdictReason { row["learner_reason"] = reason }
            return row
        }
        let elsewhere = try store.loadResearchDirections(statuses: [.pursued, .setAside])
            .filter { $0.homeID != homeID }
            .sorted { ($0.decidedAt ?? $0.updatedAt) > ($1.decidedAt ?? $1.updatedAt) }
            .prefix(12)
            .map { direction -> [String: Any] in
                var row: [String: Any] = [
                    "title": direction.title,
                    "angle": direction.angle.rawValue,
                    "status": direction.status.rawValue,
                ]
                if let reason = direction.verdictReason { row["learner_reason"] = reason }
                return row
            }
        if !elsewhere.isEmpty { brief["answers_elsewhere"] = Array(elsewhere) }

        brief["angles"] = DirectionAngle.allCases.filter { $0 != .other }.map { ["angle": $0.rawValue, "meaning": $0.meaning] }
        brief["steps"] = Prompts.directionSearchSteps(homeKind: homeKind, homeID: homeID, homeTitle: homeTitle, focus: focus)
        brief["generated_at"] = formatter.string(from: Date())
        return try jsonString(brief)
    }

    private func directionSourceRows(_ ids: [String]) throws -> [[String: Any]] {
        guard !ids.isEmpty else { return [] }
        let metadata = try sourceMetadataByID(ids)
        return ids.compactMap { id -> [String: Any]? in
            guard let row = metadata[id] else { return nil }
            var entry: [String: Any] = ["source_id": id, "title": row["title"] as? String ?? id]
            if let type = row["source_type"] as? String { entry["source_type"] = type }
            if let author = row["author"] as? String, !author.isEmpty { entry["author"] = author }
            return entry
        }
    }

    // MARK: search_literature

    /// The published record, from PubMed. Each work says whether the library
    /// already has it (by DOI), so a search never proposes as new what the
    /// learner has read.
    func searchLiterature(
        query: String,
        fromYear: Int?,
        toYear: Int?,
        preprintsOnly: Bool,
        sortString: String?,
        limit: Int
    ) async throws -> String {
        let sort: LiteratureSearch.Sort
        if let sortString, !sortString.isEmpty {
            guard let parsed = LiteratureSearch.Sort(rawValue: sortString.lowercased()) else {
                throw MCPError.invalidInput("sort must be relevance or newest; PubMed does not sort by citations.")
            }
            sort = parsed
        } else {
            sort = .relevance
        }
        let result: LiteratureSearch.Result
        do {
            result = try await LiteratureSearch.search(
                query: query,
                fromYear: fromYear,
                toYear: toYear,
                preprintsOnly: preprintsOnly,
                sort: sort,
                limit: limit
            )
        } catch let error as LiteratureSearch.SearchError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let store = try knowledgeStore()
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let works: [[String: Any]] = try result.works.map { work in
            var row: [String: Any] = ["title": work.title]
            if let authors = work.authors { row["authors"] = authors }
            if let journal = work.journal { row["journal"] = journal }
            if let year = work.year { row["year"] = year }
            if let doi = work.doi { row["doi"] = doi }
            row["url"] = work.url
            row["pmid"] = work.pmid
            if work.isReview { row["review"] = true }
            if work.isPreprint { row["preprint"] = true }
            if work.isFreeFullText { row["free_full_text"] = "https://pmc.ncbi.nlm.nih.gov/articles/\(work.pmcid ?? "")/" }
            if let abstract = work.abstract { row["abstract"] = abstract }
            if let doi = work.doi, let sourceID = try store.sourceIDByDOI(doi) {
                row["in_library"] = true
                if !excluded.contains(sourceID) { row["library_source_id"] = sourceID }
            }
            return row
        }
        return try jsonString([
            "query": result.query,
            "total_matches": result.hitCount,
            "works": works,
            "guidance": works.isEmpty
                ? "Nothing matched. Loosen the query: fewer terms, OR between synonyms, [tiab] only on the most specific term."
                : "Abstracts are PubMed's; read the paper (get_source_content when in_library, otherwise fetch_web_page on free_full_text or url) before resting a claim on it. Cite a work by its DOI.",
        ] as [String: Any])
    }

    // MARK: propose_directions

    /// Save what a search kept for one home. Refuses the whole call when a
    /// direction lacks its sentence, its reason or evidence that can be
    /// opened, so a search never half-saves; a direction the home already
    /// has, reworded or not, is skipped and named.
    func proposeDirections(
        homeID: String,
        rawDirections: [[String: Any]],
        sessionID: String?,
        hostSessionID: String?
    ) throws -> String {
        let drafts = try rawDirections.enumerated().map { offset, raw -> ResearchDirectionDraft in
            let label = "directions[\(offset)]"
            let angleString = (raw["angle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard let angle = DirectionAngle(rawValue: angleString.replacingOccurrences(of: " ", with: "_")) else {
                throw MCPError.invalidInput("\(label).angle must be one of: \(DirectionAngle.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            let rawEvidence = raw["evidence"] as? [[String: Any]] ?? []
            let evidence = rawEvidence.map { item in
                DirectionEvidence(
                    citation: item["citation"] as? String ?? "",
                    title: item["title"] as? String,
                    url: item["url"] as? String,
                    doi: item["doi"] as? String,
                    finding: item["finding"] as? String ?? ""
                )
            }
            return ResearchDirectionDraft(
                title: raw["title"] as? String ?? "",
                rationale: raw["rationale"] as? String ?? "",
                angle: angle,
                evidence: evidence,
                objection: raw["objection"] as? String,
                nextStep: raw["next_step"] as? String
            )
        }
        let store = try knowledgeStore()
        // The chat that found them: the one named, or the in-app chat this
        // call came from.
        let chatID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? hostSessionID
        let result: (saved: [ResearchDirection], duplicates: [String])
        do {
            result = try store.proposeResearchDirections(homeID: homeID, drafts: drafts, chatSessionID: chatID)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let trimmedHomeID = homeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = try store.researchDirectionHomeKind(trimmedHomeID)
        if let chatID, let kind, !result.saved.isEmpty {
            try fileDirectionSearchChat(chatID, homeKind: kind, homeID: trimmedHomeID, store: store)
        }
        var payload: [String: Any] = [
            "status": result.saved.isEmpty ? "nothing_new" : "saved",
            "saved": result.saved.map { ["direction_id": $0.id, "title": $0.title, "angle": $0.angle.rawValue] },
        ]
        if !result.duplicates.isEmpty { payload["skipped_as_already_proposed"] = result.duplicates }
        payload["guidance"] = result.saved.isEmpty
            ? "Every direction was one this \(kind?.noun ?? "home") already has. Say so, and look along an angle not yet covered if the learner wants more."
            : "They are on the \(kind?.noun ?? "home")'s Directions list now, as proposals. Answer in the chat as the steps say; when the learner picks or drops one, record it with update_direction."
        return try jsonString(payload)
    }

    /// The chat whose search found a home's Directions is filed where they
    /// are: under the Goal or Notebook when it sits loose or beside the Goal's
    /// own Notebook, and linked to the Idea. A chat the learner filed
    /// somewhere else stays there, and a chat this library does not hold is
    /// left alone.
    private func fileDirectionSearchChat(_ chatID: String, homeKind: DirectionHomeKind, homeID: String, store: KnowledgeStore) throws {
        let rows = try withDB { db in
            try query(db, "SELECT goal_id FROM review_sessions WHERE id = ? LIMIT 1", params: [chatID])
        }
        guard let row = rows.first else { return }
        switch homeKind {
        case .goal, .notebook:
            let current = (row["goal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard current != homeID else { return }
            let parent = try store.loadLearningGoal(homeID)?.parentNotebookID
            guard current == nil || current == parent else { return }
            try store.updateReviewSessionGoal(sessionID: chatID, goalID: homeID)
        case .idea:
            try store.linkIdea(homeID, kind: .chat, targetIDs: [chatID])
        }
    }

    // MARK: list_directions

    /// Directions with their evidence and answers: one home's, or every
    /// home's when none is named. Each piece of evidence says whether the
    /// library holds it now.
    func listDirections(homeID rawHomeID: String?, statusString: String?) throws -> String {
        let store = try knowledgeStore()
        var statuses: Set<DirectionStatus>?
        if let statusString, !statusString.isEmpty {
            guard let status = DirectionStatus(rawValue: statusString.lowercased()) else {
                throw MCPError.invalidInput("status must be proposed, pursued or set_aside.")
            }
            statuses = [status]
        }
        let homeID = rawHomeID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let homeID, try store.researchDirectionHomeKind(homeID) == nil {
            throw MCPError.notFound("No Goal, Notebook or Idea with id \(homeID) is in the library.")
        }
        let directions = try store.loadResearchDirections(homeID: homeID, statuses: statuses)
        let excluded = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let formatter = ISO8601DateFormatter()
        var homeTitles: [String: String?] = [:]
        func homeTitle(_ direction: ResearchDirection) throws -> String? {
            if let cached = homeTitles[direction.homeID] { return cached }
            let title: String?
            switch direction.homeKind {
            case .goal, .notebook: title = try store.loadLearningGoal(direction.homeID)?.title
            case .idea: title = try store.loadIdea(direction.homeID)?.title
            }
            homeTitles[direction.homeID] = title
            return title
        }
        var rows: [[String: Any]] = []
        for direction in directions {
            // A Direction whose home has left the library is shown nowhere.
            guard let title = try homeTitle(direction) else { continue }
            rows.append(try directionPayload(direction, homeTitle: title, store: store, excluded: excluded, formatter: formatter))
        }
        return try jsonString([
            "directions": rows,
            "count": rows.count,
            "guidance": "Pursued first, then proposals waiting for an answer, then what the learner set aside. Record an answer with update_direction; find_directions starts a new search.",
        ] as [String: Any])
    }

    private func directionPayload(
        _ direction: ResearchDirection,
        homeTitle: String,
        store: KnowledgeStore,
        excluded: Set<String>,
        formatter: ISO8601DateFormatter
    ) throws -> [String: Any] {
        var row: [String: Any] = [
            "direction_id": direction.id,
            "home": ["kind": direction.homeKind.rawValue, "id": direction.homeID, "title": homeTitle],
            "title": direction.title,
            "rationale": direction.rationale,
            "angle": direction.angle.rawValue,
            "status": direction.status.rawValue,
            "created_at": formatter.string(from: direction.createdAt),
        ]
        row["evidence"] = try direction.evidence.map { item -> [String: Any] in
            var entry: [String: Any] = ["citation": item.citation, "finding": item.finding]
            if let title = item.title { entry["title"] = title }
            if let doi = item.doi { entry["doi"] = doi }
            if let url = item.url { entry["url"] = url }
            if let sourceID = try store.librarySourceID(for: item) {
                entry["in_library"] = true
                if !excluded.contains(sourceID) { entry["library_source_id"] = sourceID }
            }
            return entry
        }
        if let objection = direction.objection { row["objection"] = objection }
        if let nextStep = direction.nextStep { row["next_step"] = nextStep }
        if let reason = direction.verdictReason { row["learner_reason"] = reason }
        if let decidedAt = direction.decidedAt { row["decided_at"] = formatter.string(from: decidedAt) }
        if let chatID = direction.chatSessionID { row["found_in_chat"] = chatID }
        return row
    }

    // MARK: update_direction

    /// The learner's answer — pursue, set aside, or back to a proposal —
    /// with their reason, or a change a deeper look made: a rewording, the
    /// objection, the next step, more evidence.
    func updateDirection(directionID rawID: String, arguments: [String: Any]) throws -> String {
        let directionID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directionID.isEmpty else {
            throw MCPError.invalidInput("direction_id is required. Use list_directions to find it.")
        }
        let store = try knowledgeStore()
        guard try store.hasResearchDirection(directionID) else {
            throw MCPError.notFound("Direction \(directionID) was not found. Use list_directions.")
        }
        var change = ResearchDirectionChange()
        if let statusString = arguments["status"] as? String, !statusString.isEmpty {
            guard let status = DirectionStatus(rawValue: statusString.lowercased()) else {
                throw MCPError.invalidInput("status must be proposed, pursued or set_aside.")
            }
            change.status = status
        }
        change.verdictReason = arguments["reason"] as? String
        change.title = arguments["title"] as? String
        change.rationale = arguments["rationale"] as? String
        change.objection = arguments["objection"] as? String
        change.nextStep = arguments["next_step"] as? String
        change.evidenceToAdd = (arguments["add_evidence"] as? [[String: Any]] ?? []).map { item in
            DirectionEvidence(
                citation: item["citation"] as? String ?? "",
                title: item["title"] as? String,
                url: item["url"] as? String,
                doi: item["doi"] as? String,
                finding: item["finding"] as? String ?? ""
            )
        }
        guard !change.isEmpty else {
            throw MCPError.invalidInput("Nothing to change: pass status (with the learner's reason), or a field to rewrite, or add_evidence.")
        }
        let direction: ResearchDirection
        do {
            direction = try store.updateResearchDirection(directionID, change: change)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        var payload: [String: Any] = [
            "status": "updated",
            "direction_id": direction.id,
            "title": direction.title,
            "direction_status": direction.status.rawValue,
        ]
        if let reason = direction.verdictReason { payload["learner_reason"] = reason }
        switch direction.status {
        case .pursued:
            payload["guidance"] = "Offer the ways to follow it: the papers its evidence names (Add to Library in the app, or import_paper_from_url when the learner asks), a Goal with a date (create_learning_goal) or an Idea to keep turning over (create_idea), and a deeper search along it."
        case .setAside:
            payload["guidance"] = "Kept as set aside, with the reason, so no later search proposes it again."
        case .proposed:
            payload["guidance"] = "Back to a proposal waiting for an answer."
        }
        return try jsonString(payload)
    }

    // MARK: delete_direction

    func deleteDirection(directionID rawID: String) throws -> String {
        let directionID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directionID.isEmpty else {
            throw MCPError.invalidInput("direction_id is required. Use list_directions to find it.")
        }
        let store = try knowledgeStore()
        guard let direction = try store.loadResearchDirection(directionID) else {
            throw MCPError.notFound("Direction \(directionID) was not found. Use list_directions.")
        }
        try store.deleteResearchDirection(directionID)
        return try jsonString([
            "status": "deleted",
            "direction_id": directionID,
            "title": direction.title,
            "guidance": "Gone for good, and a later search may propose it again. To keep a direction from coming back, set it aside instead (update_direction with status set_aside).",
        ] as [String: Any])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
