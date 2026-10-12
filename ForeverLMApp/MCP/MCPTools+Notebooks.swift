import Foundation

// MARK: - Notebooks
//
// A Notebook is an open-ended companion learning goal (LearningGoalRecord,
// kind == companion; see `isNotebook`). Its Notebook-native materials plus
// approved library source pool form the MCP context an external assistant works
// against. get_app_context names the notebook each open window holds
// (`MCPAppWindows`), but MCP tools never inherit one implicitly: callers must
// pass notebook_id after the learner explicitly asks to work in a Notebook.

/// A Notebook's own sources, its context notebooks and the learner's two rows
/// for it, as the Notebook tools read them (`MCPDataStore.notebookChatContext`,
/// `NotebookChatContext`).
struct MCPNotebookChatContext {
    let own: [String]
    let linked: [NotebookChatContext.ContextNotebook]
    var selection: NotebookChatContext.Selection
}

extension MCPDataStore {

    // MARK: Notebook resolution

    /// Resolve the Notebook a tool call explicitly targets. What the app's
    /// windows hold is only discoverable through get_app_context and is never
    /// a mutation/read default.
    func resolveMCPNotebookGoal(notebookID: String?, store: KnowledgeStore) throws -> LearningGoalRecord {
        let raw = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            throw MCPError.invalidInput(
                "notebook_id is required. Use list_notebooks to resolve the Notebook the learner explicitly named, or get_app_context only when they explicitly asked for the Notebook open in ForeverLM."
            )
        }
        guard let goal = try store.loadLearningGoal(raw), goal.isNotebook else {
            throw MCPError.invalidInput("Notebook not found: \(raw). Use list_notebooks to see available Notebooks.")
        }
        return goal
    }

    /// Resolve where a chat is filed: a Notebook, or a Goal (product owner,
    /// 2026-09-20, on the chats about a Goal's papers: "if there is already
    /// clearly related chats then those should be linked"). The one column
    /// holds either; `list_notebooks` names the former, `list_goals` the
    /// latter. Everything that is a pool of sources — a Notebook's approved
    /// pool, a Goal's own sources — keeps going through
    /// `resolveMCPNotebookGoal`, which a Goal never passes.
    func resolveMCPChatHome(notebookID: String?, store: KnowledgeStore) throws -> LearningGoalRecord {
        let raw = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            throw MCPError.invalidInput("notebook_id is required: a Notebook from list_notebooks, or a Goal from list_goals.")
        }
        guard let goal = try store.loadLearningGoal(raw), goal.isCompanion, goal.isNotebook || goal.isGoal else {
            throw MCPError.invalidInput("Notebook or Goal not found: \(raw). Use list_notebooks for Notebooks and list_goals for Goals.")
        }
        return goal
    }

    // MARK: Tools

    func listNotebooks(includeCompleted: Bool) throws -> String {
        // Notebooks are top-level companion goals only; timebound Goals nested inside a
        // Notebook (parent_notebook_id set) are listed via list_goals, not here.
        try listCompanionLearningGoals(includeCompleted: includeCompleted, topLevelOnly: true)
    }

    /// Trims and drops empty entries; nil means "not provided" (keep current),
    /// while a provided list that ends up empty is an explicit clear.
    func sanitizedResearchQuestions(_ raw: [String]?) -> [String]? {
        guard let raw else { return nil }
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func createNotebook(
        title: String?,
        description: String?,
        summary: String? = nil,
        topic: String?,
        endDateString: String,
        sourceIDs: [String],
        dailyTarget: Int?,
        discover: Bool,
        researchQuestions: [String]? = nil,
        repository: String? = nil,
        allowDuplicate: Bool = false,
        hostSessionID: String? = nil
    ) async throws -> String {
        let givenTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnd = endDateString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEnd.isEmpty else {
            throw MCPError.invalidInput(
                "Notebooks are open-ended source pools and cannot have end_date. Create the Notebook without a deadline, then use create_learning_goal with notebook_id and end_date for the timebound outcome."
            )
        }
        // Refused before anything is created, so a bad repository never leaves
        // a half-made Notebook behind.
        let resolvedRepository = try Self.resolvedRepositoryArgument(repository)
        let store = try knowledgeStore()
        // No title: the notebook is made under the placeholder and ForeverLM
        // names it from its sources and chats (`NotebookNaming`), as New
        // notebook does in the app. A title given is the learner's.
        let isUnnamed = givenTitle.isEmpty
        let givenTopic = (topic?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        if isUnnamed, discover, givenTopic == nil {
            throw MCPError.invalidInput("discover=true needs a title or a topic to search for. Pass topic, or create the Notebook without discovery.")
        }
        let trimmedTitle = isUnnamed
            ? NotebookNaming.placeholder(existingTitles: try store.loadLearningGoals().filter(\.isNotebook).map(\.title))
            : givenTitle
        if !allowDuplicate, !isUnnamed,
           let existing = try store.loadLearningGoals().first(where: {
               $0.isNotebook && $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                   .caseInsensitiveCompare(trimmedTitle) == .orderedSame
           }) {
            throw MCPError.invalidInput(
                "A Notebook titled \"\(existing.title)\" already exists. Reuse it (add_notebook_sources or update_notebook with notebook_id \(existing.id)) instead of creating a duplicate, or pass allow_duplicate=true if a second Notebook with this title is really intended."
            )
        }
        let calendar = Calendar.current
        let startAt = calendar.startOfDay(for: Date())
        let endAt = LearningGoalRecord.openEndedEndAt
        let givenSeeds = sanitizedSourceIDs(sourceIDs)
        try validateSourcesExist(givenSeeds)
        // Made from a chat, the Notebook starts with what that chat discussed: the
        // source it was opened on and the sources its turns cite. Asked to "turn this
        // into a notebook", a chat on one paper passed no source_ids, and the Notebook
        // began empty of the very paper it was about.
        let hostChatID = try resolvedHostSessionID(hostSessionID)
        let chatSeeds = try hostChatID.map { try notebookSeedsDiscussed(inChat: $0, besides: givenSeeds) } ?? []
        let seeds = givenSeeds + chatSeeds
        let resolvedTopic = givenTopic ?? trimmedTitle
        let resolvedDescription = (description?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

        let goal = try store.createCompanionGoal(
            title: trimmedTitle,
            description: resolvedDescription,
            summary: summary,
            topic: resolvedTopic,
            startAt: startAt,
            endAt: endAt,
            dailyTarget: max(1, dailyTarget ?? 3),
            discoveryEnabled: discover,
            seedSourceIDs: seeds
        )
        if let questions = sanitizedResearchQuestions(researchQuestions), !questions.isEmpty {
            try store.setLearningGoalResearchQuestions(goalID: goal.id, questions: questions)
        }
        if let resolvedRepository, !resolvedRepository.isEmpty {
            try store.setNotebookRepository(notebookID: goal.id, repository: resolvedRepository)
        }
        // A card description given is the learner's too: ForeverLM leaves
        // such a notebook's name alone.
        if isUnnamed, NotebookSummary.normalized(summary) == nil {
            NotebookNamingRows.setMark(.unnamed(title: goal.title), notebookID: goal.id)
            await PreferenceStore.flushPendingWrites()
        }
        // Made one at a time, so its AI-drawn cover (schema v2 D53) is queued, and drawn once it is sent
        // and named. import_gemini_notebook and a split's notebooks never come through here.
        await NotebookCoverService.notebookMadeOneAtATime(goal.id, store: store)

        var discoveredCount = 0
        var discoveryNote = ""
        if discover {
            do {
                discoveredCount = try await runCompanionDiscovery(
                    goal: goal,
                    excluding: Set(seeds),
                    incremental: false,
                    seedSourceIDs: seeds
                )
            } catch let error as MCPError {
                discoveryNote = "\nDiscovery skipped: \(error.errorDescription ?? "unavailable")."
            }
        }
        // Made from a chat, the Notebook takes that chat in, and the chat's
        // window opens the Notebook with the chat still in it
        // (`ReviewSessionManager.followNotebookThisChatMade`) — rather than a
        // reply that lists what was made (product owner, 2026-10-11: "it should
        // JUST open that notebook and move the chat to there").
        if let hostChatID {
            try store.updateReviewSessionGoal(sessionID: hostChatID, goalID: goal.id)
            let fromChat = chatSeeds.isEmpty ? "" : ", \(chatSeeds.count) of them the sources this chat discussed"
            let suggestionLine = discoveredCount > 0
                ? " \(discoveredCount) more source\(discoveredCount == 1 ? "" : "s") from the library that fit wait in its Sources as suggestions for the learner to keep or drop there."
                : ""
            return """
            Created Notebook ‘\(trimmedTitle)’, filed this chat in it, and the window now shows the Notebook with this chat in it. Seeds: \(seeds.count)\(fromChat).\(suggestionLine)\(discoveryNote)
            notebook_id: \(goal.id)
            Tell the learner in one short sentence that the Notebook is open, by its title, and carry on with what they asked. Do not list its sources or the suggestions, print the Notebook's id, or name a tool. The notebook_id is for later calls only.
            """
        }
        let refreshed = try store.loadLearningGoal(goal.id) ?? goal
        return """
        Created Notebook ‘\(trimmedTitle)’, no deadline. Seeds: \(seeds.count). Discovered suggestions: \(discoveredCount).\(discoveryNote)\(isUnnamed ? "\nUnnamed: ForeverLM names it from its sources and its first chat; update_notebook with title sets a name of your own." : "")
        Pass notebook_id \(goal.id) explicitly to Notebook tools; call daily_quiz with goal_id \(goal.id) to study it.

        \(try companionGoalDetail(refreshed))
        """
    }

    /// The sources a chat discussed (`KnowledgeStore.chatDiscussedSourceIDs`) that a
    /// Notebook made from it starts with, beside the `given` ones: active and outside a
    /// hidden show or channel (`persistedMCPSourceIDs`), not already given, in the order
    /// the chat took them up, and only as many as bring the seeds to
    /// `companionDiscoverySeedLimit`.
    /// A long chat cites more sources than it is about; the first it took up say what it is.
    func notebookSeedsDiscussed(inChat sessionID: String, besides given: [String]) throws -> [String] {
        let room = companionDiscoverySeedLimit - given.count
        guard room > 0 else { return [] }
        let givenSet = Set(given)
        let discussed = try knowledgeStore().chatDiscussedSourceIDs(sessionID: sessionID)
            .filter { !givenSet.contains($0) }
        let present = try persistedMCPSourceIDs(discussed)
        return Array(discussed.filter { present.contains($0) }.prefix(room))
    }

    /// nil when the caller omitted `repository` (keep), "" when it asked to
    /// unlink, the canonical owner/repo otherwise. An entry that is not a
    /// GitHub repository is refused with the accepted forms.
    static func resolvedRepositoryArgument(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard let normalized = LearningGoalRecord.normalizedRepository(trimmed) else {
            throw MCPError.invalidInput(KnowledgeStore.repositoryFormatRefusal(trimmed))
        }
        return normalized
    }

    /// Partial update of a Notebook's settings. Omitted parameters keep their current
    /// value; pass description, summary or repository "" to clear it. This is the
    /// chat-side replacement for the removed in-app notebook editor.
    func updateNotebook(
        notebookID: String?,
        title: String?,
        description: String?,
        summary: String? = nil,
        topic: String?,
        endDateString: String?,
        openEnded: Bool?,
        dailyTarget: Int?,
        discover: Bool?,
        researchQuestions: [String]? = nil,
        relatedNotebookIDs: [String]? = nil,
        repository: String? = nil,
        status: String? = nil,
        thinkFirst: String? = nil
    ) async throws -> String {
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let trimmedEnd = endDateString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedEnd.isEmpty, openEnded != false else {
            throw MCPError.invalidInput(
                "Notebooks are always open-ended. Use update_learning_goal to change the deadline of a timebound Goal."
            )
        }
        // Refused before any other field is written, so a bad repository does
        // not leave the rest of the update half-applied.
        let resolvedRepository = try Self.resolvedRepositoryArgument(repository)
        // "library" is the Notebook following the library's level again.
        let resolvedThinkFirst: ThinkFirstLevel??
        if let thinkFirst {
            let trimmed = thinkFirst.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "library" {
                resolvedThinkFirst = .some(nil)
            } else if let level = ThinkFirstLevel(rawValue: trimmed) {
                resolvedThinkFirst = .some(level)
            } else {
                throw MCPError.invalidInput("think_first must be one of: library, \(ThinkFirstLevel.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
        } else {
            resolvedThinkFirst = nil
        }
        let resolvedStatus: LearningGoalStatus?
        if let status {
            let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed == LearningGoalStatus.active.rawValue
                    || trimmed == LearningGoalStatus.archived.rawValue else {
                throw MCPError.invalidInput("status must be one of: active, archived.")
            }
            resolvedStatus = LearningGoalStatus(rawValue: trimmed)
        } else {
            resolvedStatus = nil
        }

        let resolvedTitle: String
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPError.invalidInput("title cannot be empty. Omit it to keep the current title.")
            }
            resolvedTitle = trimmed
        } else {
            resolvedTitle = goal.title
        }

        let resolvedDescription: String?
        if let description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedDescription = trimmed.isEmpty ? nil : trimmed
        } else {
            resolvedDescription = goal.description
        }

        let resolvedTopic: String
        if let topic {
            let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedTopic = trimmed.isEmpty ? resolvedTitle : trimmed
        } else {
            resolvedTopic = goal.topic ?? resolvedTitle
        }

        let discoveryWasEnabled = goal.discoveryEnabled ?? false
        let resolvedDiscover = discover ?? discoveryWasEnabled

        try store.updateCompanionGoalSettings(
            goalID: goal.id,
            title: resolvedTitle,
            description: resolvedDescription,
            topic: resolvedTopic,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: max(1, dailyTarget ?? goal.dailyTarget ?? 3),
            discoveryEnabled: resolvedDiscover
        )

        // Omitted = keep; "" (or whitespace) clears the card description.
        if let summary {
            try store.setLearningGoalSummary(goalID: goal.id, summary: summary)
        }
        // A name or description given here is the learner's: ForeverLM
        // never renames the notebook after it (`NotebookNaming`).
        if title != nil || summary != nil, NotebookNamingRows.mark(notebookID: goal.id) != nil {
            NotebookNamingRows.setMark(nil, notebookID: goal.id)
            await PreferenceStore.flushPendingWrites()
        }

        // Omitted = keep; a provided list replaces wholesale, and a provided
        // list that trims to nothing is an explicit clear.
        if let questions = sanitizedResearchQuestions(researchQuestions) {
            try store.setLearningGoalResearchQuestions(goalID: goal.id, questions: questions)
        }
        if let relatedNotebookIDs {
            do {
                try store.setRelatedNotebooks(
                    notebookID: goal.id,
                    relatedNotebookIDs: relatedNotebookIDs
                )
            } catch {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            // Linking puts nothing into the Notebook's chats; a Notebook
            // unlinked here leaves them, its id dropped from the learner's
            // row and its sources' unticks with it (`NotebookChatContext`).
            // Only the ids this call unlinks leave the row.
            if let linked = try store.loadLearningGoal(goal.id) {
                var context = notebookChatContext(goal: linked, store: store)
                let kept = Set(linked.relatedNotebookIDs ?? [])
                context.selection = NotebookChatContext.settingContextNotebooks(
                    (goal.relatedNotebookIDs ?? []).filter { !kept.contains($0) },
                    inChat: false,
                    linked: context.linked,
                    selection: context.selection
                )
                // Generation 2: putting a notebook into context writes the link and this member's
                // tick (schema v2 D52); links made before stay unticked.
                if NotebookStateStore.isActive {
                    let before = Set(goal.relatedNotebookIDs ?? [])
                    context.selection = NotebookChatContext.puttingIn(
                        (linked.relatedNotebookIDs ?? []).filter { !before.contains($0) },
                        linked: context.linked,
                        selection: context.selection
                    )
                }
                await storeNotebookChatSelection(context, notebookID: goal.id)
            }
        }
        // Omitted = keep; "" unlinks; anything else was already validated.
        if let resolvedRepository {
            try store.setNotebookRepository(notebookID: goal.id, repository: resolvedRepository)
        }
        if let resolvedStatus {
            try store.setLearningGoalStatus(goalID: goal.id, status: resolvedStatus)
        }
        if let resolvedThinkFirst {
            ThinkFirst.setNotebookLevel(resolvedThinkFirst, notebookID: goal.id)
            await PreferenceStore.flushPendingWrites()
        }

        var discoveryNote = ""
        if resolvedDiscover, let updated = try store.loadLearningGoal(goal.id),
           !discoveryWasEnabled || resolvedTopic != (goal.topic ?? goal.title) {
            do {
                let discovered = try await runCompanionDiscovery(
                    goal: updated,
                    excluding: Set(updated.items.map(\.sourceID)),
                    incremental: false
                )
                discoveryNote = "\nDiscovered suggestions: \(discovered)."
            } catch let error as MCPError {
                discoveryNote = "\nDiscovery skipped: \(error.errorDescription ?? "unavailable")."
            }
        }

        let statusNote = resolvedStatus.map { "\nStatus is now '\($0.rawValue)'." } ?? ""
        let refreshed = try store.loadLearningGoal(goal.id) ?? goal
        return """
        Updated Notebook ‘\(resolvedTitle)’.\(discoveryNote)\(statusNote)

        \(try companionGoalDetail(refreshed))
        """
    }

    func getNotebookDetail(notebookID: String?) throws -> String {
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        // Screen record mode (admin only): a Notebook the take keeps off screen
        // reads as absent, the same answer an unknown id gets.
        if let screenScope = screenRecordScope(), !screenRecordAllowsGoal(goal, scope: screenScope) {
            throw MCPError.invalidInput("Notebook or Goal not found: \(goal.id). Use list_notebooks for Notebooks and list_goals for Goals.")
        }
        return try companionGoalDetail(goal)
    }

    func deleteNotebook(notebookID: String?, deleteChats: Bool = false) throws -> String {
        let raw = notebookID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            throw MCPError.invalidInput("notebook_id is required to delete a Notebook. Use list_notebooks first.")
        }
        let store = try knowledgeStore()
        guard let goal = try store.loadLearningGoal(raw), goal.isNotebook else {
            throw MCPError.invalidInput("Notebook not found: \(raw)")
        }
        // Counted before the cascade so the caller can report what actually
        // went, rather than the client having to have asked in advance.
        let childGoalIDs = (try? store.childGoalIDs(ofNotebook: goal.id)) ?? []
        let childGoalCount = childGoalIDs.count
        let deletedGoalIDs = Set([goal.id] + childGoalIDs)
        let linkedChatCount = (try? store.loadReviewSessionLinks().filter { session in
            session.goalID.map(deletedGoalIDs.contains) == true
        }.count) ?? 0
        do {
            try store.deleteLearningGoal(
                goal.id,
                cascadeChildGoals: true,
                deleteLinkedChats: deleteChats
            )
        } catch {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        discardNotebookWorkspaceDirectory(notebookID: goal.id)
        NotebookChatSelection.forget(notebookID: goal.id)
        NotebookCollectionRows.forget(notebookID: goal.id)
        let goalNote = childGoalCount > 0
            ? " Deleted \(childGoalCount) nested Goal\(childGoalCount == 1 ? "" : "s") with it."
            : ""
        let chatNote: String
        if linkedChatCount == 0 {
            chatNote = ""
        } else if deleteChats {
            chatNote = " Deleted \(linkedChatCount) linked chat\(linkedChatCount == 1 ? "" : "s")."
        } else {
            chatNote = " Kept \(linkedChatCount) linked chat\(linkedChatCount == 1 ? "" : "s") in the ungrouped Chats list."
        }
        return "Deleted Notebook '\(goal.title)'.\(goalNote)\(chatNote) Its workspace files were moved to the Trash; sources stay in the library."
    }

    /// The app deletes a Notebook's workspace folder through StorageService, which
    /// the MCP server has no access to — it speaks to the KnowledgeStore alone.
    /// Without this the files a Notebook owned would outlive every MCP deletion.
    private func discardNotebookWorkspaceDirectory(notebookID: String) {
        guard !notebookID.isEmpty, !notebookID.contains("/"), !notebookID.contains("..") else { return }
        let workspace = sourceContentRoot
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(notebookID, isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: workspace.path) else { return }
        #if os(macOS)
        if (try? fileManager.trashItem(at: workspace, resultingItemURL: nil)) != nil { return }
        #endif
        try? fileManager.removeItem(at: workspace)
    }

    func splitNotebook(
        notebookID: String?,
        splits: [[String: Any]],
        keepParent: Bool
    ) throws -> String {
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let parsedSplits = try parseCompanionGoalSplits(splits)
        let result = try store.splitCompanionGoal(
            sourceGoalID: goal.id,
            splits: parsedSplits,
            keepParent: keepParent
        )
        var filesMoved = 0
        if let heirID = result.heirGoalID {
            // The removed parent's folder goes to the child that took its
            // chats and Docs, by the rule a merge uses for its survivor.
            filesMoved = adoptNotebookWorkspaceDirectory(
                from: goal.id,
                into: heirID,
                mergedNotebookTitle: goal.title
            )
            if store.syncGeneration == .two {
                // Generation 2's split job handed the member's NotebookState
                // sets to the heir in the store (schema v2 §5.2).
                NotebookStateStore.reload()
            } else {
                // The parent's unticked boxes go to the heir, whose pool is part
                // of the parent's, and so do the context notebooks its chats read
                // that the heir still links to; the parent's rows go.
                NotebookChatSelection.handOver(
                    fromParent: goal.id,
                    toHeir: heirID,
                    heirPool: try store.notebookContextSourceIDs(notebookID: heirID),
                    heirLinks: try store.relatedNotebookIDsForNotebook(notebookID: heirID)
                )
                // So do its collections.
                NotebookCollectionRows.handOver(fromParent: goal.id, toHeir: heirID)
            }
        }
        let children = try result.childGoalIDs.map { id -> [String: Any] in
            let child = try store.loadLearningGoal(id)
            return [
                "notebook_id": id,
                "title": child?.title ?? id,
                "source_count": child?.items.filter(\.isApproved).count ?? 0,
            ]
        }
        var response: [String: Any] = [
            "split_from_notebook_id": goal.id,
            "parent_notebook_id": result.parentGoalID as Any,
            "child_notebooks": children,
            "guidance": "Each child notebook is now a separate MCP source context. Open questions linked to moved sources moved with them.",
        ]
        if let heirID = result.heirGoalID {
            // The parent was emptied and removed; what it held besides its
            // sources now lives in this child.
            response["parent_contents_moved_to_notebook_id"] = heirID
            response["files_moved"] = filesMoved
            response["guidance"] = "Each child notebook is now a separate MCP source context. Open questions linked to moved sources moved with them. The parent had no sources left and was deleted; its chats, Goals, tasks, Docs, courses, remaining open questions, synthesis notes, Instructions, research questions, chat source ticks, files and other records moved to \(heirID), the child that took the most sources."
        }
        return try jsonString(response)
    }

    func mergeNotebooks(
        notebookIDs: [String],
        title: String?,
        mergeNotes: Bool
    ) throws -> String {
        let store = try knowledgeStore()
        let uniqueIDs = dictUnique(notebookIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard uniqueIDs.count >= 2 else {
            throw MCPError.invalidInput("merge_notebooks requires at least two notebook_ids.")
        }
        // Titles are read while the merged Notebooks still exist: the workspace
        // folders are moved after the store merge, and the folder a name
        // collision lands in is named after the Notebook it came from.
        var mergedTitles: [String: String] = [:]
        for id in uniqueIDs.dropFirst() {
            mergedTitles[id] = try store.loadLearningGoal(id)?.title
        }
        var result = try store.mergeCompanionGoals(
            notebookIDs: uniqueIDs,
            title: title,
            mergeNotes: mergeNotes
        )
        for mergedID in result.mergedGoalIDs {
            result.filesMoved += adoptNotebookWorkspaceDirectory(
                from: mergedID,
                into: result.survivorGoalID,
                mergedNotebookTitle: mergedTitles[mergedID] ?? mergedID
            )
            // Generation 2's merge job unioned the member's NotebookState sets
            // into the survivor's in the store (schema v2 §5.2).
            guard store.syncGeneration != .two else { continue }
            // Its sources arrive in the survivor ticked and its unticked row
            // goes; the context notebooks its chats read stay in for the
            // survivor, which took its links.
            NotebookChatSelection.merged(
                mergedID,
                into: result.survivorGoalID,
                survivorLinks: try store.relatedNotebookIDsForNotebook(notebookID: result.survivorGoalID)
            )
            // The survivor joins every collection it was in.
            NotebookCollectionRows.merge(mergedID, into: result.survivorGoalID)
        }
        if store.syncGeneration == .two { NotebookStateStore.reload() }
        let survivor = try store.loadLearningGoal(result.survivorGoalID)
        return try jsonString([
            "survivor_notebook_id": result.survivorGoalID,
            "merged_notebook_ids": result.mergedGoalIDs,
            "title": survivor?.title ?? "",
            "sources_added": result.sourcesAdded,
            "open_questions_added": result.gapsAdded,
            "chats_moved": result.chatsMoved,
            "goals_moved": result.childGoalsMoved,
            "tasks_moved": result.tasksMoved,
            "docs_moved": result.docsMoved,
            "files_moved": result.filesMoved,
            "guidance": "The survivor notebook now holds the combined source pool, chats, Goals, tasks, Docs, scheduled tasks, open questions, synthesis notes and files. The merged notebook ids no longer resolve.",
        ] as [String: Any])
    }

    /// The merge counterpart of `discardNotebookWorkspaceDirectory`: the merged
    /// Notebook's files go into the survivor's folder, and the app's rule for a
    /// name both folders use is `StorageService.adoptNotebookWorkspace`.
    private func adoptNotebookWorkspaceDirectory(from mergedID: String, into survivorID: String, mergedNotebookTitle: String) -> Int {
        for id in [mergedID, survivorID] {
            guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { return 0 }
        }
        let notebooksRoot = sourceContentRoot.appendingPathComponent("Projects", isDirectory: true)
        let source = notebooksRoot.appendingPathComponent(mergedID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return 0 }
        return StorageService.adoptNotebookWorkspace(
            from: source,
            into: notebooksRoot.appendingPathComponent(survivorID, isDirectory: true),
            mergedNotebookTitle: mergedNotebookTitle
        )
    }

    func parseCompanionGoalSplits(_ raw: [[String: Any]]) throws -> [CompanionGoalSplitSpec] {
        guard !raw.isEmpty else {
            throw MCPError.invalidInput("splits must be a non-empty array.")
        }
        return try raw.map { entry in
            let title = entry["title"] as? String ?? ""
            let topic = entry["topic"] as? String
            let sourceIDs = entry["source_ids"] as? [String] ?? []
            let gapIDs = entry["gap_ids"] as? [String] ?? []
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                throw MCPError.invalidInput("Each split needs a title.")
            }
            let cleanedSources = sanitizedSourceIDs(sourceIDs)
            guard !cleanedSources.isEmpty else {
                throw MCPError.invalidInput("Split \"\(trimmedTitle)\" needs at least one source_id.")
            }
            return CompanionGoalSplitSpec(
                title: trimmedTitle,
                topic: topic,
                sourceIDs: cleanedSources,
                gapIDs: sanitizedSourceIDs(gapIDs)
            )
        }
    }

    /// Set the user's study order for a Notebook's approved pool. `sourceIDs` may be a
    /// subset: listed sources are placed first in the given order and every other
    /// approved source keeps its current relative order after them.
    func reorderNotebookSources(notebookID: String?, sourceIDs: [String]) throws -> String {
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let cleaned = sanitizedSourceIDs(sourceIDs)
        guard !cleaned.isEmpty else {
            throw MCPError.invalidInput("source_ids is required: approved source IDs in the desired study order.")
        }
        let approved = Set(goal.approvedSourceIDs)
        if let unknown = cleaned.first(where: { !approved.contains($0) }) {
            throw MCPError.invalidInput("source_id \(unknown) is not an approved source in this Notebook. Use list_notebook_sources to see valid IDs.")
        }
        try store.reorderCompanionSources(goalID: goal.id, orderedSourceIDs: cleaned)
        let refreshed = try store.loadLearningGoal(goal.id) ?? goal
        return try jsonString([
            "notebook_id": goal.id,
            "reordered": true,
            "study_order": refreshed.approvedSourceIDs,
            "guidance": "study_order is the Notebook's full approved pool in the new study order. list_notebook_sources, get_notebook_context, and the in-app pool now follow it.",
        ] as [String: Any])
    }

    /// A Notebook's own sources, its context notebooks (one per link, in link
    /// order, each with its own approved sources, none for a link this Mac has
    /// no record of) and the learner's two rows for it (`NotebookChatContext`).
    func notebookChatContext(goal: LearningGoalRecord, store: KnowledgeStore) -> MCPNotebookChatContext {
        MCPNotebookChatContext(
            own: goal.approvedSourceIDs,
            linked: NotebookChatSelection.contextNotebooks(of: goal) { id in
                guard let related = try? store.loadLearningGoal(id), related.isNotebook else { return nil }
                return related.approvedSourceIDs
            },
            selection: NotebookChatSelection.selection(notebookID: goal.id)
        )
    }

    /// Writes the Notebook's two rows as `context` holds them, each sorted,
    /// the unticked kept to its pool (`NotebookChatContext.stored`), and
    /// waits for them to reach the sync rail.
    func storeNotebookChatSelection(_ context: MCPNotebookChatContext, notebookID: String) async {
        let stored = NotebookChatContext.stored(context.selection, own: context.own, linked: context.linked)
        NotebookChatSelection.write(stored.excluded, notebookID: notebookID)
        NotebookChatSelection.writeContextNotebooks(stored.contextNotebookIDs, notebookID: notebookID)
        await PreferenceStore.flushPendingWrites()
    }

    /// Each context notebook as the tools report it, in link order: its id,
    /// title, whether the Notebook's chats read it, and its sources (those
    /// the knowledge boundary leaves visible) with how many of them a chat
    /// reads. A link this Mac has no record of is left out.
    func contextNotebookPayloads(
        _ context: MCPNotebookChatContext,
        store: KnowledgeStore,
        hidden: Set<String>
    ) throws -> [[String: Any]] {
        try context.linked.compactMap { notebook -> [String: Any]? in
            guard let record = try store.loadLearningGoal(notebook.id), record.isNotebook else { return nil }
            let visible = notebook.sourceIDs.filter { !hidden.contains($0) }
            let isIn = context.selection.contextNotebookIDs.contains(notebook.id)
            return [
                "notebook_id": notebook.id,
                "title": record.title,
                "in_chat": isIn,
                "source_count": visible.count,
                "in_chat_count": isIn ? visible.filter { !context.selection.excluded.contains($0) }.count : 0,
            ]
        }
    }

    /// Ticks or unticks a Notebook's sources for its chats — the checkboxes
    /// beside a notebook's sources — and puts its context notebooks into its
    /// chats or takes them out (`NotebookChatContext`). The learner's own
    /// synced preference, never a Notebook write, so a read-only team member
    /// may set it too. The open window picks the rows up through the
    /// `foreverLMDataDidChange` reload.
    func setNotebookSourceSelection(
        notebookID: String?,
        sourceIDs: [String],
        contextNotebookIDs: [String] = [],
        mode: String
    ) async throws -> String {
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let cleanMode = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["include", "exclude", "only", "all", "none"].contains(cleanMode) else {
            throw MCPError.invalidInput("mode must be include, exclude, only, all, or none.")
        }
        var context = notebookChatContext(goal: goal, store: store)
        let requested = sanitizedSourceIDs(sourceIDs)
        let requestedNotebooks = sanitizedSourceIDs(contextNotebookIDs)
        if ["include", "exclude", "only"].contains(cleanMode), requested.isEmpty, requestedNotebooks.isEmpty {
            throw MCPError.invalidInput("source_ids is required for mode \(cleanMode), or context_notebook_ids to put context notebooks in or out. Use mode all or none to tick or untick every source its chats draw on.")
        }
        let linkedIDs = Set(context.linked.map(\.id))
        if let unlinked = requestedNotebooks.first(where: { !linkedIDs.contains($0) }) {
            throw MCPError.invalidInput("context_notebook_id \(unlinked) is not a context notebook of this Notebook. Link it first with update_notebook related_notebook_ids; list_notebook_sources lists its context_notebooks.")
        }
        let linkedPool = Set(NotebookChatContext.linkedPool(own: context.own, linked: context.linked))
        if let outside = requested.first(where: { !linkedPool.contains($0) }) {
            throw MCPError.invalidInput("source_id \(outside) is not in this Notebook or its context notebooks. Use list_notebook_sources to see its sources, or add_notebook_sources to add one first.")
        }
        let before = NotebookChatContext.stored(context.selection, own: context.own, linked: context.linked)
        var next = context.selection
        switch cleanMode {
        case "include":
            next = NotebookChatContext.settingContextNotebooks(requestedNotebooks, inChat: true, linked: context.linked, selection: next)
            next = NotebookChatContext.settingSources(requested, inChat: true, own: context.own, linked: context.linked, selection: next)
        case "exclude":
            next = NotebookChatContext.settingSources(requested, inChat: false, own: context.own, linked: context.linked, selection: next)
            next = NotebookChatContext.settingContextNotebooks(requestedNotebooks, inChat: false, linked: context.linked, selection: next)
        case "only":
            next = NotebookChatContext.keepingOnly(
                sourceIDs: requested,
                contextNotebookIDs: requestedNotebooks,
                own: context.own,
                linked: context.linked,
                selection: next
            )
        default:
            let pool = NotebookChatContext.chatPool(own: context.own, linked: context.linked, selection: next)
            next = NotebookChatContext.settingSources(pool, inChat: cleanMode == "all", own: context.own, linked: context.linked, selection: next)
        }
        let stored = NotebookChatContext.stored(next, own: context.own, linked: context.linked)
        context.selection = NotebookChatContext.Selection(excluded: Set(stored.excluded), contextNotebookIDs: Set(stored.contextNotebookIDs))
        await storeNotebookChatSelection(context, notebookID: goal.id)
        let hidden = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let visible = NotebookChatContext.chatPool(own: context.own, linked: context.linked, selection: context.selection)
            .filter { !hidden.contains($0) }
        let inChat = NotebookChatSelection.chatSourceIDs(pool: visible, excluded: context.selection.excluded)
        return try jsonString([
            "notebook_id": goal.id,
            "updated": stored.excluded != before.excluded || stored.contextNotebookIDs != before.contextNotebookIDs,
            "source_count": visible.count,
            "in_chat_count": inChat.count,
            "in_chat_source_ids": inChat,
            "excluded_source_ids": stored.excluded,
            "context_notebooks": try contextNotebookPayloads(context, store: store, hidden: hidden),
            "guidance": "New chats in this Notebook read the in_chat sources — its own ticked sources, and those of the context notebooks in its chats — and a chat not yet sent follows too. A chat already under way keeps the sources it started with. Unticked sources stay in the Notebook, and a context notebook taken out stays linked; any chat can still read their sources on request. What the Studio makes reads only the Notebook's own ticked sources.",
        ] as [String: Any])
    }

    /// The sources the Notebook's chats read, in order: its own and those of
    /// the context notebooks the learner put in, minus the unticked — what a
    /// tool working from the notebook's chats (a review, the app context)
    /// reads when the caller names only the Notebook. What its Studio makes
    /// reads its own ticked sources alone (`NotebookSourceLoader.notebookSourceIDs`).
    func notebookChatSourceIDs(goal: LearningGoalRecord, store: KnowledgeStore) throws -> [String] {
        let context = notebookChatContext(goal: goal, store: store)
        return NotebookChatContext.chatSourceIDs(own: context.own, linked: context.linked, selection: context.selection)
    }

    /// What the Notebook's chats draw on, ticked or not: its own sources and
    /// those of the context notebooks the learner put in.
    func notebookChatPoolSourceIDs(goal: LearningGoalRecord, store: KnowledgeStore) -> [String] {
        let context = notebookChatContext(goal: goal, store: store)
        return NotebookChatContext.chatPool(own: context.own, linked: context.linked, selection: context.selection)
    }

    func listNotebookSources(notebookID: String?) throws -> String {
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let hidden = try store.knowledgeSearchExcludedSourceIDs(includeArchived: true)
        let context = notebookChatContext(goal: goal, store: store)
        let selection = context.selection
        var itemsBySourceID = Dictionary(
            goal.items.filter(\.isApproved).map { ($0.sourceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // The Notebook's own sources, then each context notebook's not listed
        // yet: a source two of them hold is listed once, under the first the
        // chats read, else the first linked.
        var rows: [(id: String, via: LearningGoalRecord?)] = context.own.map { ($0, nil) }
        var listed = Set(context.own)
        var holderBySourceID: [String: String] = [:]
        for notebook in NotebookChatContext.notebooksInChat(context.linked, selection: selection) + context.linked {
            for id in notebook.sourceIDs where holderBySourceID[id] == nil && !listed.contains(id) {
                holderBySourceID[id] = notebook.id
            }
        }
        for notebook in context.linked {
            guard let record = try store.loadLearningGoal(notebook.id), record.isNotebook else { continue }
            for item in record.items.filter(\.isApproved) where holderBySourceID[item.sourceID] == record.id {
                guard listed.insert(item.sourceID).inserted else { continue }
                rows.append((item.sourceID, record))
                itemsBySourceID[item.sourceID] = item
            }
        }
        rows = rows.filter { !hidden.contains($0.id) }
        let chatPool = Set(NotebookChatContext.chatPool(own: context.own, linked: context.linked, selection: selection))
        func readsInChat(_ id: String) -> Bool { chatPool.contains(id) && !selection.excluded.contains(id) }
        let now = Date()
        let sources: [[String: Any]] = try rows.enumerated().map { position, row in
            let id = row.id
            var payload: [String: Any]
            if let s = try store.loadSourceForSync(id) {
                payload = [
                    "id": s.id,
                    "title": s.title,
                    // What a reply shows for the source (Prompts.hiddenIDs).
                    "link": Self.sourceLink(title: s.title, id: s.id),
                    "source_type": s.sourceType.rawValue,
                    "url": s.url,
                    "is_missing_source": false,
                    "position": position,
                    "in_chat": readsInChat(id),
                ]
                if let item = itemsBySourceID[id] {
                    payload.merge(
                        notebookSourceRetentionFields(
                            item: item,
                            title: s.title,
                            sourceType: s.sourceType.rawValue,
                            now: now
                        )
                    ) { _, new in new }
                }
            } else {
                payload = [
                    "id": id,
                    "title": id,
                    "is_missing_source": true,
                    "position": position,
                    "in_chat": readsInChat(id),
                ]
                if let item = itemsBySourceID[id] {
                    payload.merge(
                        notebookSourceRetentionFields(
                            item: item,
                            title: id,
                            sourceType: "unknown",
                            now: now
                        )
                    ) { _, new in new }
                }
            }
            if let via = row.via {
                payload["via_context_notebook_id"] = via.id
                payload["via_context_notebook_title"] = via.title
            }
            return payload
        }
        return try jsonString([
            "notebook": notebookPayload(goal),
            "source_count": rows.count,
            "in_chat_count": rows.filter { readsInChat($0.id) }.count,
            "context_notebooks": try contextNotebookPayloads(context, store: store, hidden: hidden),
            "sources": sources,
            "guidance": "These are the Notebook's own sources, then those of its context notebooks (the Notebooks in related_notebook_ids), marked via_context_notebook_id; no membership was copied. A context notebook's sources reach the Notebook's chats only while the learner has put it in (context_notebooks in_chat); linking it alone does not. in_chat is true for a source a new chat in this Notebook reads: its own or a context notebook's in its chats, and not unticked by the learner. Unticked sources, and those of a context notebook out of its chats, stay where they are and can be read on request. set_notebook_source_selection changes the ticks and puts context notebooks in or out (context_notebook_ids). What the Studio makes (generate_report, generate_audio_overview, draft_cards) reads only the Notebook's own ticked sources, the rows without via_context_notebook_id. Notebook-native workspace files are included separately by get_notebook_context.",
        ] as [String: Any])
    }

    func getNotebookContext(
        notebookID: String?,
        maxSourceChars: Int?,
        includeEmergentState: Bool?,
        includeSourceContent: Bool?
    ) async throws -> String {
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        // What the Notebook's chats read: its own ticked sources and those of
        // the context notebooks the learner put in (`NotebookChatContext`).
        let context = notebookChatContext(goal: goal, store: store)
        let ids = NotebookChatContext.chatSourceIDs(own: context.own, linked: context.linked, selection: context.selection)
        let includeEmergent = includeEmergentState ?? true
        let includeContent = includeSourceContent ?? true
        let maxChars = max(1_000, min(maxSourceChars ?? 8_000, 200_000))

        var parts: [String] = []
        if includeEmergent {
            parts.append(try notebookEmergentContextMarkdown(goal: goal))
        }
        // A defining attribute, not emergent state, so it is present whatever
        // include_emergent_state says: an assistant reading this context has to
        // know which repository the Notebook is about before it reads code.
        if let repository = goal.linkedRepository {
            parts.append(Self.linkedRepositoryContextLine(repository))
        }
        let notebookMaterials = try await notebookFileStorage.notebookMaterialContext(notebookID: goal.id)
        if !notebookMaterials.isEmpty {
            parts.append(notebookMaterials)
        }
        for notebook in NotebookChatContext.notebooksInChat(context.linked, selection: context.selection) {
            guard let related = try store.loadLearningGoal(notebook.id), related.isNotebook else { continue }
            if includeEmergent {
                // The caller named only the main Notebook, so a context
                // notebook's id rides on its own line for later calls,
                // never beside its title (Prompts.hiddenIDs).
                parts.append("# Context notebook\n\nnotebook_id: \(related.id)\n\n" + (try notebookEmergentContextMarkdown(goal: related)))
            }
            let relatedMaterials = try await notebookFileStorage.notebookMaterialContext(notebookID: related.id)
            if !relatedMaterials.isEmpty {
                parts.append("## Materials from context notebook '\(related.title)'\n\n" + relatedMaterials)
            }
        }
        if let leftOut = Self.notebookContextLeftOutLine(context) {
            parts.append(leftOut)
        }

        guard includeContent else {
            if parts.isEmpty {
                return "Notebook '\(goal.title)': emergent state omitted (include_emergent_state=false)."
            }
            return parts.joined(separator: "\n\n")
        }

        guard !ids.isEmpty else {
            let emptyLine = "Notebook '\(goal.title)' has no approved sources yet. Add some with add_notebook_sources."
            if parts.isEmpty { return emptyLine }
            return parts.joined(separator: "\n\n") + "\n\n" + emptyLine
        }

        parts.append(
            try formatAppContext(
                sourceIDs: ids,
                heading: "Notebook '\(goal.title)' (\(ids.count) sources its chats read)",
                maxCharsPerSource: maxChars
            )
        )
        return parts.joined(separator: "\n\n")
    }

    /// What `get_notebook_context` leaves out and where to find it: the
    /// sources the learner unticked, and the context notebooks out of the
    /// Notebook's chats; nil when nothing is.
    static func notebookContextLeftOutLine(_ context: MCPNotebookChatContext) -> String? {
        let pool = NotebookChatContext.chatPool(own: context.own, linked: context.linked, selection: context.selection)
        let unticked = pool.filter { context.selection.excluded.contains($0) }.count
        let outOfChat = context.linked.filter { !context.selection.contextNotebookIDs.contains($0.id) && !$0.sourceIDs.isEmpty }.count
        guard unticked > 0 || outOfChat > 0 else { return nil }
        var pieces: [String] = []
        if unticked > 0 { pieces.append("\(unticked) source\(unticked == 1 ? "" : "s") the learner unticked") }
        if outOfChat > 0 { pieces.append("\(outOfChat) context notebook\(outOfChat == 1 ? "" : "s") out of its chats") }
        return "Left out, as the Notebook's chats leave them out: \(pieces.joined(separator: " and ")). list_notebook_sources lists them; get_source_content reads one on request."
    }

    func listNotebookFiles(notebookID: String?) async throws -> String {
        let store = try knowledgeStore()
        let notebook = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let records = try await notebookFileStorage.loadNotebookFiles(notebookID: notebook.id)
        return try jsonString([
            "notebook": notebookPayload(notebook),
            "file_count": records.count,
            "files": records.map { record in
                [
                    "path": record.notebookRelativePath,
                    "name": record.name,
                    "content_type": record.contentType ?? NSNull(),
                    "size_bytes": record.sizeBytes,
                    "modified_at": ISO8601DateFormatter().string(from: record.modifiedAt),
                    "editable_markdown": record.isMarkdownDocument,
                ] as [String: Any]
            },
            "guidance": "Use read_notebook_markdown_file and write_notebook_markdown_file for files where editable_markdown is true. Other formats remain read-only Notebook context.",
        ] as [String: Any])
    }

    func readNotebookMarkdownFile(
        notebookID: String?,
        relativePath: String
    ) async throws -> String {
        let store = try knowledgeStore()
        let notebook = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let snapshot = try await notebookFileStorage.notebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: relativePath
        )
        return try jsonString([
            "notebook_id": notebook.id,
            "path": snapshot.record.notebookRelativePath,
            "markdown": snapshot.markdown,
            "revision": snapshot.revision,
            "size_bytes": snapshot.record.sizeBytes,
            "guidance": "Pass revision unchanged as expected_revision when replacing this file.",
        ] as [String: Any])
    }

    func writeNotebookMarkdownFile(
        notebookID: String?,
        relativePath: String,
        markdown: String,
        expectedRevision: String?
    ) async throws -> String {
        let store = try knowledgeStore()
        let notebook = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let normalizedRevision = expectedRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = try await notebookFileStorage.writeNotebookMarkdownFile(
            notebookID: notebook.id,
            relativePath: relativePath,
            markdown: markdown,
            expectedRevision: normalizedRevision?.isEmpty == false ? normalizedRevision : nil
        )
        return try jsonString([
            "notebook_id": notebook.id,
            "path": snapshot.record.notebookRelativePath,
            "revision": snapshot.revision,
            "size_bytes": snapshot.record.sizeBytes,
            "message": "Saved Markdown artifact in Notebook '\(notebook.title)'.",
        ] as [String: Any])
    }

    /// Every workspace file is standing Notebook-native context, not an optional
    /// global-source excerpt. Include the workspace even in a lightweight
    /// `include_source_content=false` snapshot so external MCP assistants see
    /// the same Notebook definition as the in-app chat.
    func notebookMaterialContextMarkdown(notebookID: String, store: KnowledgeStore) throws -> String {
        let records = try store.loadNotebookFiles(notebookID: notebookID)
        guard !records.isEmpty else { return "" }

        let fileManager = FileManager.default
        for record in records {
            let url = sourceContentRoot.appendingPathComponent(record.relativePath)
            if fileManager.fileExists(atPath: url.path) {
                let values = try? url.resourceValues(
                    forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
                )
                if values?.isUbiquitousItem == true,
                   values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try fileManager.startDownloadingUbiquitousItem(at: url)
                    throw MCPError.invalidInput(
                        "Notebook file “\(record.notebookRelativePath)” is downloading from iCloud. Call get_notebook_context again when the download finishes."
                    )
                }
                continue
            }
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fileManager.fileExists(atPath: placeholder.path) {
                try fileManager.startDownloadingUbiquitousItem(at: placeholder)
                throw MCPError.invalidInput(
                    "Notebook file “\(record.notebookRelativePath)” is downloading from iCloud. Call get_notebook_context again when the download finishes."
                )
            }
            throw MCPError.invalidInput(
                "Notebook file “\(record.notebookRelativePath)” is unavailable on this device."
            )
        }

        do {
            return try StorageService.renderNotebookMaterialContext(
                records: records,
                rootURL: sourceContentRoot,
                maxCharacters: StorageService.notebookMaterialContextCharacterLimit
            )
        } catch {
            throw MCPError.invalidInput("Could not read the Notebook files. \(error.localizedDescription)")
        }
    }

    // MARK: - Open questions (LearningGoalGap)

    func listOpenQuestions(notebookID: String?, includeResolved: Bool?, status: String?) throws -> String {
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let gaps = try store.loadLearningGoalGaps(goalID: goal.id)
        let statusFilter = (status?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let filtered = gaps.filter { gap in
            if let statusFilter, gap.status != statusFilter { return false }
            if includeResolved == true { return true }
            return gap.isOpen
        }
        return try jsonString([
            "notebook": notebookPayload(goal),
            "open_question_count": filtered.count,
            "open_questions": filtered.map(openQuestionPayload),
            "guidance": "Open questions are the emergent research spine for this Notebook. Create or update them here, or let end_review_session write them after a review.",
        ] as [String: Any])
    }

    func createOpenQuestion(
        notebookID: String?,
        summary: String,
        sourceID: String?,
        severity: Double?,
        status: String?
    ) throws -> String {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else {
            throw MCPError.invalidInput("summary is required.")
        }
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let linkedSourceID = try validatedNotebookSourceID(sourceID, goal: goal)

        let resolvedStatus: String
        if let status {
            resolvedStatus = try requireOpenQuestionStatus(status)
        } else {
            resolvedStatus = "open"
        }
        if let severity, !(0...1).contains(severity) {
            throw MCPError.invalidInput("severity must be between 0 and 1.")
        }

        let now = Date()
        let gap = LearningGoalGap(
            id: UUID().uuidString,
            goalID: goal.id,
            summary: trimmedSummary,
            sourceID: linkedSourceID,
            status: resolvedStatus,
            severity: severity,
            firstSeenAt: now,
            lastSeenAt: now,
            resolvedAt: resolvedStatus == "resolved" ? now : nil,
            sessionID: nil
        )
        try store.upsertCompanionGaps(goalID: goal.id, gaps: [gap])
        return try jsonString([
            "notebook_id": goal.id,
            "created": true,
            "open_question": openQuestionPayload(gap),
        ] as [String: Any])
    }

    func updateOpenQuestion(
        notebookID: String?,
        questionID: String,
        summary: String?,
        sourceID: String?,
        severity: Double?,
        status: String?,
        clearSourceID: Bool
    ) throws -> String {
        let trimmedID = questionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw MCPError.invalidInput("question_id is required.")
        }
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let gaps = try store.loadLearningGoalGaps(goalID: goal.id)
        guard var gap = gaps.first(where: { $0.id == trimmedID }) else {
            throw MCPError.invalidInput("Open question not found: \(trimmedID). Use list_open_questions first.")
        }

        if let summary {
            let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSummary.isEmpty else {
                throw MCPError.invalidInput("summary cannot be empty.")
            }
            gap.summary = trimmedSummary
        }
        if clearSourceID {
            gap.sourceID = nil
        } else if sourceID != nil {
            gap.sourceID = try validatedNotebookSourceID(sourceID, goal: goal)
        }
        if let severity {
            guard (0...1).contains(severity) else {
                throw MCPError.invalidInput("severity must be between 0 and 1.")
            }
            gap.severity = severity
        }
        if let status {
            let resolvedStatus = try requireOpenQuestionStatus(status)
            gap.status = resolvedStatus
            if resolvedStatus == "resolved" {
                gap.resolvedAt = gap.resolvedAt ?? Date()
            } else {
                gap.resolvedAt = nil
            }
        }
        gap.lastSeenAt = Date()

        try store.upsertCompanionGaps(goalID: goal.id, gaps: [gap])
        return try jsonString([
            "notebook_id": goal.id,
            "updated": true,
            "open_question": openQuestionPayload(gap),
        ] as [String: Any])
    }

    // MARK: - Emergent notebook state helpers

    func derivedSourceUnderstandingState(for item: LearningGoalItem) -> String {
        item.derivedUnderstandingState.rawValue
    }

    func notebookSourceRetentionFields(
        item: LearningGoalItem,
        title: String,
        sourceType: String,
        now: Date
    ) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "understanding_state": derivedSourceUnderstandingState(for: item),
            "review_due": isNotebookSourceReviewDue(item: item, title: title, sourceType: sourceType, now: now),
        ]
        if let lastQuizzedAt = item.lastQuizzedAt {
            payload["last_quizzed_at"] = iso.string(from: lastQuizzedAt)
        }
        if let quizCount = item.quizCount { payload["quiz_count"] = quizCount }
        if let lastScore = item.lastScore { payload["last_score"] = lastScore }
        if let completedAt = item.completedAt {
            payload["completed_at"] = iso.string(from: completedAt)
        }
        return payload
    }

    func isNotebookSourceReviewDue(
        item: LearningGoalItem,
        title: String,
        sourceType: String,
        now: Date
    ) -> Bool {
        guard let lastQuizzedAt = item.lastQuizzedAt,
              let reviewCount = item.quizCount,
              reviewCount > 0 else {
            return false
        }
        let stat = MemoryReviewStat(
            sourceID: item.sourceID,
            title: title,
            sourceType: sourceType,
            lastReviewedAt: lastQuizzedAt,
            lastScore: item.lastScore,
            reviewCount: reviewCount
        )
        return now >= MemoryReviewScheduler.dueDate(for: stat)
    }

    func openQuestionPayload(_ gap: LearningGoalGap) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "question_id": gap.id,
            "summary": gap.summary,
            "status": gap.status,
            "first_seen_at": iso.string(from: gap.firstSeenAt),
            "last_seen_at": iso.string(from: gap.lastSeenAt),
        ]
        if let sourceID = gap.sourceID { payload["source_id"] = sourceID }
        if let severity = gap.severity { payload["severity"] = severity }
        if let resolvedAt = gap.resolvedAt { payload["resolved_at"] = iso.string(from: resolvedAt) }
        if let sessionID = gap.sessionID { payload["session_id"] = sessionID }
        return payload
    }

    func notebookEmergentContextMarkdown(goal: LearningGoalRecord) throws -> String {
        let now = Date()
        var lines: [String] = [
            "# Notebook '\(goal.title)'",
        ]

        // Instructions lead, exactly as they do in the in-app chat's cached
        // prompt head: they are the learner's standing guidance, and an external
        // assistant reading this context owes them the same obedience.
        lines.append("")
        lines.append("## Instructions")
        if let instructions = goal.displayDescription {
            lines.append("The learner's standing instructions for this Notebook - follow them for the whole conversation:")
            lines.append(instructions)
        } else {
            lines.append("(none set - the learner can add standing guidance with update_notebook instructions, or in the Notebook view)")
        }

        // Then the defining questions: they are what the Notebook exists to
        // answer, and everything below (notes, gaps, sources) serves them.
        let questions = goal.researchQuestions ?? []
        lines.append("")
        lines.append("## Key research questions (\(questions.count))")
        if questions.isEmpty {
            lines.append("(none set - define them with update_notebook research_questions, or in the Notebook view)")
        } else {
            for (index, question) in questions.enumerated() {
                lines.append("\(index + 1). \(question)")
            }
        }

        lines.append("")
        lines.append("## Synthesis notes")
        let notes = goal.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lines.append(notes.isEmpty ? "(none yet - use update_notebook_notes or append_notebook_notes)" : notes)

        let openGaps = (goal.gaps ?? []).filter(\.isOpen)
        lines.append("")
        lines.append("## Open questions (\(openGaps.count))")
        if openGaps.isEmpty {
            lines.append("(none yet - use create_open_question or end_review_session after a review)")
        } else {
            // A question's source is shown as the link a reply can carry
            // (`sourceLink`), never as its id (Prompts.hiddenIDs).
            let gapSourceTitles = try sourceMetadataByID(openGaps.compactMap(\.sourceID))
            for gap in openGaps {
                var line = "- [\(gap.status)] \(gap.summary) (question_id: \(gap.id))"
                if let sourceID = gap.sourceID {
                    let title = gapSourceTitles[sourceID]?["title"] as? String
                    line += " - source: " + (title.map { Self.sourceLink(title: $0, id: sourceID) } ?? sourceID)
                }
                if let severity = gap.severity { line += String(format: " - severity: %.2f", severity) }
                lines.append(line)
            }
        }

        let approvedItems = goal.items.filter(\.isApproved)
        lines.append("")
        lines.append("## Source understanding (\(approvedItems.count) approved)")
        if approvedItems.isEmpty {
            lines.append("(no approved sources yet)")
        } else {
            let metadata = try sourceMetadataByID(approvedItems.map(\.sourceID))
            for item in approvedItems {
                let meta = metadata[item.sourceID] ?? [:]
                let title = meta["title"] as? String ?? item.sourceID
                let sourceType = meta["source_type"] as? String ?? "unknown"
                let state = derivedSourceUnderstandingState(for: item)
                let shown = (meta["title"] as? String).map { Self.sourceLink(title: $0, id: item.sourceID) } ?? item.sourceID
                var line = "- \(shown): \(state)"
                if let lastScore = item.lastScore {
                    line += String(format: " - last score %.0f%%", lastScore * 100)
                }
                if isNotebookSourceReviewDue(item: item, title: title, sourceType: sourceType, now: now) {
                    line += " - review due"
                }
                lines.append(line)
            }
        }

        let priorSessions = try companionPriorSessions(goalID: goal.id, limit: 3)
        lines.append("")
        lines.append("## Recent reviews (\(priorSessions.count))")
        if priorSessions.isEmpty {
            lines.append("(none yet)")
        } else {
            for session in priorSessions {
                let summary = session["summary"] as? String ?? "(no summary)"
                if let endedAt = session["ended_at"] as? Double {
                    let when = appleToISO(endedAt)
                    if let score = session["overall_score"] as? Double {
                        lines.append("- \(when): \(String(format: "%.0f%%", score * 100)) - \(summary)")
                    } else {
                        lines.append("- \(when): \(summary)")
                    }
                } else {
                    lines.append("- \(summary)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    func validatedNotebookSourceID(_ raw: String?, goal: LearningGoalRecord) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pool = Set(goal.items.map(\.sourceID))
        guard pool.contains(trimmed) else {
            throw MCPError.invalidInput("source_id \(trimmed) is not in this Notebook. Use list_notebook_sources to see valid IDs.")
        }
        return trimmed
    }

    func normalizedOpenQuestionStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    func requireOpenQuestionStatus(_ raw: String) throws -> String {
        let status = normalizedOpenQuestionStatus(raw) ?? ""
        guard ["open", "improving", "resolved"].contains(status) else {
            throw MCPError.invalidInput("status must be one of: open, improving, resolved.")
        }
        return status
    }

    /// Update (or append to) a Notebook's synthesis notes markdown.
    /// The Internal Review also writes here.
    func updateNotebookNotes(notebookID: String?, markdown: String, append: Bool) throws -> String {
        let clean = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw MCPError.invalidInput("markdown is required.")
        }
        let store = try knowledgeStore()
        let goal = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        let updated: String
        if append {
            let existing = goal.notes ?? ""
            let sep = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n"
            updated = existing + sep + clean
        } else {
            updated = clean
        }
        try store.setLearningGoalNotes(goalID: goal.id, notes: updated)
        return "Updated notes for Notebook '\(goal.title)' - now \(updated.count) characters."
    }

    // MARK: Payload helper

    /// The sentence an assistant reads when a Notebook is about a repository:
    /// which one, how to read it, and that nothing from it lives here.
    static func linkedRepositoryContextLine(_ repository: String) -> String {
        "Linked GitHub repository: \(repository). Read it live with the GitHub tools (read_github_file, search_github_code, list_github_files, list_github_issues, get_github_pull_request, list_github_commits, …), passing repository \"\(repository)\"; nothing from it is stored here."
    }

    func notebookPayload(_ goal: LearningGoalRecord) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": goal.id,
            "title": goal.title,
            "topic": goal.topic ?? goal.title,
            "source_count": goal.approvedSourceIDs.count,
            "updated_at": iso.string(from: goal.updatedAt),
            "open_ended": goal.isOpenEnded,
            // null when the Notebook is not about a repository, so a reader
            // never has to guess whether the key was simply forgotten.
            "repository": goal.linkedRepository ?? NSNull(),
        ]
        if let instructions = goal.displayDescription {
            payload["instructions"] = instructions
        }
        if goal.isOpenEnded {
            payload["deadline"] = NSNull()
        } else {
            payload["deadline"] = iso.string(from: goal.endAt)
        }
        if let questions = goal.researchQuestions, !questions.isEmpty {
            payload["research_questions"] = questions
        }
        payload["related_notebook_ids"] = goal.relatedNotebookIDs ?? []
        if let store = try? knowledgeStore() {
            for (key, value) in notebookTeamFields(goal, store: store) {
                payload[key] = value
            }
        }
        return payload
    }

    // MARK: File MIME helper (used by MCPTools+Sources for content extraction)

    static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "apng", "png": return "image/png"
        case "avif": return "image/avif"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "jpeg", "jpg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        default: return nil
        }
    }
}
