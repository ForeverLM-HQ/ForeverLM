import Foundation
import ImageIO
import OSLog
import PDFKit
import SQLite3

extension MCPDataStore {

    // MARK: - Learning Companion

    func createCompanionLearningGoal(
        title: String,
        topic: String?,
        endDateString: String,
        startDateString: String?,
        sourceIDs: [String],
        dailyTarget: Int?,
        discover: Bool,
        notebookID: String? = nil,
        artifactID: String? = nil
    ) async throws -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw MCPError.invalidInput("A goal title is required.")
        }
        // The artifact the Goal is for, refused before anything is written.
        let resolvedArtifactID: String?
        do {
            resolvedArtifactID = try KnowledgeStore.resolvedGoalArtifactID(artifactID, load: knowledgeStore().loadArtifact)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        let calendar = Calendar.current
        let startAt = try startDateString.map { try parseScheduleDate($0, calendar: calendar) } ?? calendar.startOfDay(for: Date())
        let endAt = try parseScheduleDate(endDateString, calendar: calendar)
        guard startAt < endAt else {
            throw MCPError.invalidInput("end_date must be after the start date. Each goal needs a dedicated end date.")
        }
        let seeds = sanitizedSourceIDs(sourceIDs)
        try validateSourcesExist(seeds)
        let resolvedTopic = (topic?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? trimmedTitle

        // A Goal stands on its own. When a Notebook is named it must be a real
        // top-level Notebook (not another Goal), so goals never nest under goals
        // — but naming one is optional: the learner may want to understand
        // something before there is any source pool to hang it on.
        let rawParentID = (notebookID?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        var resolvedParentID: String?
        var resolvedParentTitle: String?
        if let rawParentID {
            guard let parent = try knowledgeStore().loadLearningGoal(rawParentID), parent.isCompanion else {
                throw MCPError.invalidInput("notebook_id \(rawParentID) is not a Notebook. Use list_notebooks, or create_notebook first.")
            }
            guard parent.isNotebook else {
                throw MCPError.invalidInput("notebook_id \(rawParentID) is itself a Goal, not a Notebook. Goals cannot nest under other goals.")
            }
            resolvedParentID = parent.id
            resolvedParentTitle = parent.title
        }

        let goal = try knowledgeStore().createCompanionGoal(
            title: trimmedTitle,
            description: nil,
            topic: resolvedTopic,
            startAt: startAt,
            endAt: endAt,
            dailyTarget: max(1, dailyTarget ?? 3),
            discoveryEnabled: discover,
            seedSourceIDs: seeds,
            parentNotebookID: resolvedParentID,
            artifactID: resolvedArtifactID
        )

        var discoveredCount = 0
        var discoveryNote = ""
        if discover {
            do {
                discoveredCount = try await runCompanionDiscovery(goal: goal, excluding: Set(seeds), incremental: false)
            } catch let error as MCPError {
                discoveryNote = "\nDiscovery failed: \(error.errorDescription ?? "unavailable"). Sign in with Apple and check the configured background-task model; the Goal and its seed sources were still saved."
            }
        }

        let refreshed = try knowledgeStore().loadLearningGoal(goal.id) ?? goal
        let brief = try companionGoalDetail(refreshed)
        // Named by title: the brief below carries every id (Prompts.hiddenIDs).
        let parentLine = resolvedParentTitle.map { "Tagged to Notebook ‘\($0)’.\n" } ?? ""
        let artifactLine = resolvedArtifactID.map { id in
            "For “\((try? knowledgeStore().loadArtifact(id))?.title ?? id)”; the Goal's row opens it.\n"
        } ?? ""
        return """
        Created timebound Goal ‘\(trimmedTitle)’, ending \(isoDateOnly(endAt, calendar: calendar)).
        \(parentLine)\(artifactLine)Seeds: \(seeds.count). Discovered suggestions: \(discoveredCount) (pending your approval).\(discoveryNote)
        Approve suggestions with review_suggested_sources, then pace the approved sources across the days up to the deadline with assign_sources_to_day (this fills the visible Schedule). Use daily_quiz with goal_id \(goal.id) to study.

        \(brief)
        """
    }

    /// Update a timebound Goal in place. Every field is optional; an omitted field
    /// keeps its current value. Kept separate from `create_learning_goal` so a
    /// retargeted deadline or a re-parented Goal preserves the source pool,
    /// review history, and open questions.
    func updateLearningGoal(
        goalID: String,
        title: String?,
        description: String?,
        topic: String?,
        endDateString: String?,
        dailyTarget: Int?,
        discover: Bool?,
        notebookID: String?,
        statusString: String?,
        artifactID: String? = nil
    ) async throws -> String {
        let store = try knowledgeStore()
        let trimmedID = goalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw MCPError.invalidInput("goal_id is required. Use list_goals to find it.")
        }
        guard let goal = try store.loadLearningGoal(trimmedID), goal.isGoal else {
            throw MCPError.invalidInput("Goal \(trimmedID) was not found. Use list_goals.")
        }
        let calendar = Calendar.current

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

        var deadlineMoved = false
        let resolvedEndAt: Date
        if let endDateString, !endDateString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedEndAt = try parseScheduleDate(endDateString, calendar: calendar)
            guard calendar.startOfDay(for: Date()) < resolvedEndAt else {
                throw MCPError.invalidInput("end_date must be after today.")
            }
            guard goal.startAt < resolvedEndAt else {
                throw MCPError.invalidInput("end_date must be after the Goal's start date.")
            }
            deadlineMoved = calendar.startOfDay(for: resolvedEndAt) != calendar.startOfDay(for: goal.endAt)
        } else {
            resolvedEndAt = goal.endAt
        }

        let discoveryWasEnabled = goal.discoveryEnabled ?? false
        let resolvedDiscover = discover ?? discoveryWasEnabled

        // Only touch the settings row when a settings field was actually passed.
        // A status-only call (`{goal_id, status:"done"}`) must not rewrite the
        // title, deadline, or discovery — and must not backfill a NULL topic with
        // the title or bump updated_at on what the caller meant as a no-op edit.
        let touchesSettings = title != nil
            || description != nil
            || topic != nil
            || endDateString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || dailyTarget != nil
            || discover != nil

        if touchesSettings {
            try store.updateCompanionGoalSettings(
                goalID: goal.id,
                title: resolvedTitle,
                description: resolvedDescription,
                topic: resolvedTopic,
                endAt: resolvedEndAt,
                dailyTarget: max(1, dailyTarget ?? goal.dailyTarget ?? 3),
                discoveryEnabled: resolvedDiscover
            )
        }

        // Rescan only when discovery was just switched on or the topic changed,
        // matching update_notebook — an unrelated edit shouldn't trigger a scan.
        var discoveryNote = ""
        if touchesSettings, resolvedDiscover, let updated = try store.loadLearningGoal(goal.id),
           !discoveryWasEnabled || resolvedTopic != (goal.topic ?? goal.title) {
            do {
                let discovered = try await runCompanionDiscovery(
                    goal: updated,
                    excluding: Set(updated.items.map(\.sourceID)),
                    incremental: false
                )
                discoveryNote = "\nDiscovered suggestions: \(discovered) (pending your approval)."
            } catch let error as MCPError {
                discoveryNote = "\nDiscovery skipped: \(error.errorDescription ?? "unavailable")."
            }
        }

        // Re-parenting and status live outside updateCompanionGoalSettings so that
        // marking a Goal done never rewrites its deadline or discovery settings.
        var parentNote = ""
        if let notebookID {
            let trimmedParent = notebookID.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try store.setLearningGoalParentNotebook(
                    goalID: goal.id,
                    parentNotebookID: trimmedParent.isEmpty ? nil : trimmedParent
                )
            } catch {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            let parentTitle = trimmedParent.isEmpty ? nil : (try? store.loadLearningGoal(trimmedParent))?.title
            parentNote = trimmedParent.isEmpty
                ? "\nNo longer tagged to a Notebook."
                : parentTitle.map { "\nNow tagged to Notebook ‘\($0)’." } ?? "\nNow tagged to a Notebook."
        }

        var statusNote = ""
        if let statusString {
            let trimmedStatus = statusString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let status = LearningGoalStatus(rawValue: trimmedStatus) else {
                throw MCPError.invalidInput("status must be one of: active, done, archived.")
            }
            try store.setLearningGoalStatus(goalID: goal.id, status: status)
            statusNote = "\nStatus is now '\(status.rawValue)'."
        }

        // The artifact the Goal is for lives outside the settings row too, so
        // linking a site never touches the deadline or discovery.
        var artifactNote = ""
        if let artifactID {
            let trimmedArtifact = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try store.setLearningGoalArtifact(goalID: goal.id, artifactID: trimmedArtifact.isEmpty ? nil : trimmedArtifact)
            } catch let error as KnowledgeStoreError {
                throw MCPError.invalidInput(error.localizedDescription)
            }
            if trimmedArtifact.isEmpty {
                artifactNote = "\nNo longer for any Doc, Site or animation."
            } else {
                let title = (try? store.loadArtifact(trimmedArtifact))?.title ?? trimmedArtifact
                artifactNote = "\nNow for “\(title)”; the Goal's row opens it."
            }
        }

        let refreshed = try store.loadLearningGoal(goal.id) ?? goal
        let replanNote = deadlineMoved
            ? "\nThe deadline moved — re-pace the remaining sources against it with assign_sources_to_day."
            : ""

        return """
        Updated Goal ‘\(resolvedTitle)’.\(discoveryNote)\(parentNote)\(statusNote)\(artifactNote)\(replanNote)

        \(try companionGoalDetail(refreshed))
        """
    }

    /// One timebound Goal in full, including its planned day path.
    func getGoal(goalID: String) throws -> String {
        let store = try knowledgeStore()
        let trimmedID = goalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw MCPError.invalidInput("goal_id is required. Use list_goals to find it.")
        }
        guard let goal = try store.loadLearningGoal(trimmedID), goal.isGoal else {
            throw MCPError.invalidInput("Goal \(trimmedID) was not found. Use list_goals.")
        }
        return try companionGoalDetail(goal)
    }

    // MARK: add_goal_sources

    /// The drop of sources onto a Goal's row, over MCP (product owner, 2026-09-19:
    /// "allow me to drag sources onto goals ... and via mcp"). The sources join
    /// the Goal's approved pool at once; `addCompanionSeedSources` hands them
    /// on to the Notebook the Goal is tagged to. A Notebook is refused so the
    /// two pools are never confused — add_notebook_sources is explicit about
    /// which one it fills.
    func addGoalSources(goalID: String, sourceIDs: [String]) async throws -> String {
        let goal = try requireNotebookGoal(goalID)
        let ids = sanitizedSourceIDs(sourceIDs)
        guard !ids.isEmpty else {
            throw MCPError.invalidInput("Provide at least one source_id to put on the Goal.")
        }
        try validateSourcesExist(ids)
        let store = try knowledgeStore()
        let added: Int
        var notAdded: [NotebookFiling.Refusal] = []
        if goal.teamID != nil {
            // A team's Goal holds the team's copies (`fileSourcesInTeamPool`).
            let filing = try await fileSourcesInTeamPool(ids, in: goal)
            added = filing.filed.count
            notAdded = filing.refused
        } else {
            added = try store.addCompanionSeedSources(goalID: goal.id, sourceIDs: ids)
        }
        let refreshed = try store.loadLearningGoal(goal.id) ?? goal
        var payload: [String: Any] = [
            "goal_id": goal.id,
            "title": goal.title,
            "added": added,
            "skipped": ids.count - added - notAdded.count,
            "source_count": refreshed.approvedSourceIDs.count,
            "source_ids": refreshed.approvedSourceIDs,
            "guidance": "The sources are on the Goal's pool. Pace them onto days with assign_sources_to_day; get_goal shows the pool.",
        ]
        if !notAdded.isEmpty {
            payload["not_added"] = notAdded.map { ["source_id": $0.sourceID, "reason": $0.reason] }
        }
        if let parentID = refreshed.parentNotebookID, !parentID.isEmpty {
            payload["notebook_id"] = parentID
        }
        return try jsonString(payload)
    }

    // MARK: delete_learning_goal

    /// The Goals tab's Delete, over MCP: one Goal gone, its sources kept, its
    /// chats unlinked. A Notebook is refused here so its Goals are never
    /// deleted by mistake — delete_notebook is explicit about that cascade.
    func deleteLearningGoal(goalID rawGoalID: String) throws -> String {
        let trimmedID = rawGoalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw MCPError.invalidInput("goal_id is required. Use list_goals to find it.")
        }
        let store = try knowledgeStore()
        guard let goal = try store.loadLearningGoal(trimmedID) else {
            throw MCPError.notFound("Goal \(trimmedID) was not found. Use list_goals.")
        }
        guard !goal.isNotebook else {
            throw MCPError.invalidInput("“\(goal.title)” is a Notebook, not a Goal. delete_notebook deletes a Notebook and the Goals tagged to it; to untag one Goal from it, use update_learning_goal with notebook_id \"\".")
        }
        let chatCount = (try? store.reviewSessionIDs(linkedToAnyGoalIn: [goal.id]).count) ?? 0
        do {
            try store.deleteLearningGoal(goal.id)
        } catch {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "status": "deleted",
            "goal_id": goal.id,
            "title": goal.title,
            "chats_kept": chatCount,
            "message": "Deleted the Goal “\(goal.title)”. Its sources stay in the library\(chatCount > 0 ? ", \(chatCount) chat\(chatCount == 1 ? "" : "s") started from it stay in Chats" : "").",
        ])
    }

    func listCompanionLearningGoals(includeCompleted: Bool = false, topLevelOnly: Bool = false) throws -> String {
        let screenScope = screenRecordScope()
        let goals = try knowledgeStore().loadLearningGoals().filter {
            topLevelOnly ? $0.isNotebook : $0.isCompanion
        }.filter { goal in
            // Screen record mode (admin only): the recording Notebook and what
            // the take made. Nil scope lists everything, as before.
            screenScope.map { screenRecordAllowsGoal(goal, scope: $0) } ?? true
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let headlines = goals.compactMap { goal -> [String: Any]? in
            // Hide only what is explicitly finished. An overdue Goal still needs
            // attention, so it stays in the list.
            if (goal.isDone || goal.isArchived) && !includeCompleted { return nil }
            return companionGoalHeadline(goal, calendar: calendar, today: today)
        }
        guard !headlines.isEmpty else {
            return topLevelOnly
                ? "No Notebooks yet. Create one with create_notebook."
                : "No active Learning Companion goals. Create one with create_learning_goal."
        }
        return try jsonString(["goals": headlines, "generated_at": ISO8601DateFormatter().string(from: Date())])
    }

    /// List timebound Goals. With a `notebookID`, only the Goals tagged to that
    /// Notebook; with none, every Goal the learner has set — the ones tagged to
    /// a Notebook and the ones standing on their own alike, each carrying its
    /// `notebook_id` when it has one.
    /// The MCP twin of a row drag in the Goals tab: the listed Goals first,
    /// the rest as they read, an empty list back to deadline order. Answers
    /// the open Goals in their final order, the rows `list_goals` gives.
    func reorderGoals(goalIDs: [String]) throws -> String {
        let store = try knowledgeStore()
        let order: [String]
        do {
            order = try store.reorderLearningGoals(goalIDs: goalIDs)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription + " Use list_goals.")
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let byID = Dictionary(uniqueKeysWithValues: try store.loadLearningGoals().map { ($0.id, $0) })
        let rows = order.compactMap { byID[$0] }.map { goal -> [String: Any] in
            var headline = companionGoalHeadline(goal, calendar: calendar, today: today)
            headline["notebook_id"] = goal.parentNotebookID
            return headline
        }
        let note = goalIDs.isEmpty
            ? "Every placement is forgotten; the Goals read by deadline again."
            : "Placed \(min(goalIDs.count, order.count)) Goal\(goalIDs.count == 1 ? "" : "s") first; the rest follow in the order they already read."
        return try jsonString(["note": note, "goals": rows, "generated_at": ISO8601DateFormatter().string(from: Date())])
    }

    func listNotebookGoals(notebookID: String?, includeCompleted: Bool = false) throws -> String {
        let store = try knowledgeStore()
        let resolvedNotebookID = (notebookID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        var scopedNotebook: LearningGoalRecord?
        if let resolvedNotebookID {
            guard let notebook = try store.loadLearningGoal(resolvedNotebookID), notebook.isNotebook else {
                throw MCPError.invalidInput("notebook_id \(resolvedNotebookID) is not a Notebook. Use list_notebooks.")
            }
            scopedNotebook = notebook
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // The order the Goals tab reads: the learner's placements first,
        // then by deadline (`LearningGoalRecord.listOrder`).
        let screenScope = screenRecordScope()
        let goals = try store.loadLearningGoals().filter { goal in
            guard goal.isGoal else { return false }
            if let screenScope, !screenRecordAllowsGoal(goal, scope: screenScope) { return false }
            if let resolvedNotebookID { return goal.parentNotebookID == resolvedNotebookID }
            return true
        }.sorted(by: LearningGoalRecord.listOrder)
        let headlines = goals.compactMap { goal -> [String: Any]? in
            if (goal.isDone || goal.isArchived) && !includeCompleted { return nil }
            var headline = companionGoalHeadline(goal, calendar: calendar, today: today)
            headline["notebook_id"] = goal.parentNotebookID
            return headline
        }
        guard !headlines.isEmpty else {
            guard let scopedNotebook else {
                return "No Goals set yet. Create one with create_learning_goal (notebook_id is optional; pass it to tag the Goal to a Notebook)."
            }
            return "Notebook ‘\(scopedNotebook.title)’ has no Goals yet. Create one with create_learning_goal and notebook_id \(scopedNotebook.id)."
        }
        return try jsonString(["goals": headlines, "generated_at": ISO8601DateFormatter().string(from: Date())])
    }

    func reviewSuggestedSources(goalID: String, approve: [String], reject: [String]) throws -> String {
        let goal = try requireCompanionGoal(goalID)
        let poolByID = Dictionary(uniqueKeysWithValues: goal.items.map { ($0.sourceID, $0) })
        let approveIDs = sanitizedSourceIDs(approve)
        let rejectIDs = sanitizedSourceIDs(reject)
        let unknown = (approveIDs + rejectIDs).filter { poolByID[$0] == nil }
        guard unknown.isEmpty else {
            throw MCPError.invalidInput("These source_ids are not in \(Self.companionName(goal)): \(unknown.joined(separator: ", "))")
        }
        let store = try knowledgeStore()
        if !approveIDs.isEmpty {
            try store.setCompanionItemReviewState(goalID: goal.id, sourceIDs: approveIDs, state: .approved)
        }
        if !rejectIDs.isEmpty {
            try store.setCompanionItemReviewState(goalID: goal.id, sourceIDs: rejectIDs, state: .rejected)
        }
        let refreshed = try store.loadLearningGoal(goal.id) ?? goal
        return """
        Approved \(approveIDs.count), rejected \(rejectIDs.count) for \(Self.companionName(goal)).

        \(try companionGoalDetail(refreshed))
        """
    }

    /// Add library sources to a Learning Companion goal as approved seeds — the MCP twin
    /// of the app's own "Add sources" picker. Sources already in the goal pool
    /// (any state) are skipped. What joins a Notebook arrives ticked in its
    /// chat checkboxes (`tickArrivingNotebookSources`). A team's Notebook or
    /// Goal takes the team's copies (`fileSourcesInTeamPool`).
    func addCompanionSeedSources(goalID: String, sourceIDs: [String]) async throws -> String {
        let goal = try requireCompanionGoal(goalID)
        let ids = sanitizedSourceIDs(sourceIDs)
        guard !ids.isEmpty else {
            throw MCPError.invalidInput("Provide at least one source_id to add.")
        }
        try validateSourcesExist(ids)
        let store = try knowledgeStore()
        if goal.teamID != nil {
            // A team's Notebook or Goal holds the team's copies
            // (`fileSourcesInTeamPool`), and ticks what arrived itself.
            let filing = try await fileSourcesInTeamPool(ids, in: goal)
            let count = filing.filed.count
            var head = "Added \(count) source\(count == 1 ? "" : "s") to \(Self.companionName(goal)) as approved\(count > 0 ? ", as the team's copies" : "")."
            if !filing.alreadyIn.isEmpty { head += " Skipped \(filing.alreadyIn.count) already in the goal." }
            if let notAdded = filing.notAddedSentence { head += " " + notAdded }
            return head + "\n\n" + (try companionGoalDetail(try store.loadLearningGoal(goal.id) ?? goal))
        }
        // A Goal's additions reach its Notebook too.
        let pools = [goal.id] + (goal.parentNotebookID.map { [$0] } ?? [])
        var heldBefore: [String: Set<String>] = [:]
        for pool in pools {
            heldBefore[pool] = Set(try store.loadLearningGoal(pool)?.approvedSourceIDs ?? [])
        }
        let added = try store.addCompanionSeedSources(goalID: goal.id, sourceIDs: ids)
        let skipped = ids.count - added
        let refreshed = try store.loadLearningGoal(goal.id) ?? goal
        var arrivals: [String: [String]] = [:]
        for (pool, held) in heldBefore {
            arrivals[pool] = (try store.loadLearningGoal(pool)?.approvedSourceIDs ?? []).filter { !held.contains($0) }
        }
        await tickArrivingNotebookSources(arrivals)
        return """
        Added \(added) source\(added == 1 ? "" : "s") to \(Self.companionName(goal)) as approved.\(skipped > 0 ? " Skipped \(skipped) already in the goal." : "")

        \(try companionGoalDetail(refreshed))
        """
    }

    func dailyQuiz(goalID: String?, dateString: String?, startSession: Bool = true, hostSessionID: String? = nil) async throws -> String {
        let calendar = Calendar.current
        let now = Date()
        let day = try dateString.map { try parseScheduleDate($0, calendar: calendar) } ?? calendar.startOfDay(for: now)
        let todayISO = isoDateOnly(day, calendar: calendar)

        // No goal specified: return a menu of active companion goals.
        guard let goalID, !goalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let menu = try listCompanionLearningGoals(includeCompleted: false)
            return "No goal_id given. Pick one and call daily_quiz again with its goal_id.\n\n\(menu)"
        }

        var goal = try requireCompanionGoal(goalID)
        let endDay = calendar.startOfDay(for: goal.endAt)
        let dayDiff = calendar.dateComponents([.day], from: day, to: endDay).day ?? 0
        // Only an explicitly finished Goal gets the wrap-up brief. An overdue one
        // is still live work: keep serving it, paced as if the deadline were today.
        if goal.isDone || goal.isArchived {
            return try companionCompletionBrief(goal)
        }
        // Pacing spreads what is left over the days including today, so it
        // counts one more than the days remaining and never fewer than one.
        let pacingDays = max(1, dayDiff + 1)

        // Incremental discovery: only newly-added sources since the last pass.
        var discoveryNote = ""
        if goal.discoveryEnabled == true {
            do {
                let added = try await runCompanionDiscovery(goal: goal, excluding: Set(goal.items.map(\.sourceID)), incremental: true)
                if added > 0 {
                    goal = try requireCompanionGoal(goalID)
                    discoveryNote = "Discovered \(added) new source\(added == 1 ? "" : "s") matching this goal — pending your approval (see pending_suggestions)."
                }
            } catch let error as MCPError {
                discoveryNote = "Discovery skipped: \(error.errorDescription ?? "unavailable")."
            }
        }

        // Build the adaptive blend from approved, not-yet-completed items —
        // in screen record mode (admin only) only those the take may show.
        let screenRecordHidden = try screenRecordHiddenSourceIDs(scope: screenRecordScope())
        let approved = goal.items.filter {
            $0.isApproved && !$0.isCompleted && !screenRecordHidden.contains($0.sourceID)
        }
        let newRemaining = approved.filter { ($0.quizCount ?? 0) == 0 }
        let reviewPool = approved.filter { ($0.quizCount ?? 0) > 0 }
        let target = max(1, goal.dailyTarget ?? 3)
        let newPerDayNeeded = newRemaining.isEmpty ? 0 : Int(ceil(Double(newRemaining.count) / Double(pacingDays)))
        var newCount = min(newRemaining.count, max(newRemaining.isEmpty ? 0 : 1, newPerDayNeeded))
        newCount = min(newCount, target)
        let reviewCount = min(reviewPool.count, max(0, target - newCount))

        let newSorted = newRemaining.sorted { a, b in
            let aSeed = a.origin == LearningGoalItemOrigin.seed.rawValue
            let bSeed = b.origin == LearningGoalItemOrigin.seed.rawValue
            if aSeed != bSeed { return aSeed }
            let ar = a.relevance ?? 0, br = b.relevance ?? 0
            if ar != br { return ar > br }
            return a.addedAt < b.addedAt
        }
        let reviewSorted = reviewPool.sorted { a, b in
            let asc = a.lastScore ?? 0, bsc = b.lastScore ?? 0
            if asc != bsc { return asc < bsc }
            return (a.lastQuizzedAt ?? .distantPast) < (b.lastQuizzedAt ?? .distantPast)
        }
        let chosen = Array(newSorted.prefix(newCount)) + Array(reviewSorted.prefix(reviewCount))

        let pendingSuggestions = goal.items.filter { $0.isPendingApproval }
        let openGaps = (goal.gaps ?? []).filter { $0.isOpen }

        guard !chosen.isEmpty else {
            var lines = ["No approved sources are available to quiz for \(Self.companionName(goal)) yet."]
            if !pendingSuggestions.isEmpty {
                lines.append("There are \(pendingSuggestions.count) pending discovered suggestion(s) — approve some with review_suggested_sources.")
            } else {
                lines.append("Add seed sources with add_goal_sources or add_notebook_sources, or all items may be completed.")
            }
            if !discoveryNote.isEmpty { lines.append(discoveryNote) }
            return lines.joined(separator: "\n")
        }

        let chosenIDs = chosen.map(\.sourceID)
        let metadata = try sourceMetadataByID(chosenIDs + pendingSuggestions.map(\.sourceID))

        // Briefing mode (start_session=false): a read-only preview for an unattended
        // routine — no session is created, no items are marked served, and full source
        // content is omitted to keep it lightweight. The live review happens later.
        var sessionID: String? = nil
        var content: [String: String] = [:]
        if startSession {
            content = try sourceContentByID(chosenIDs, perSourceLimit: 6000)
            let topic = goal.topic ?? goal.title
            // In-app Chat already has a session recording this conversation; bind to
            // it rather than inserting a second, exchange-less row.
            if let hostSession = try resolvedHostSessionID(hostSessionID) {
                sessionID = hostSession
                try await mergeReviewSessionSourceIDs(sessionID: hostSession, adding: chosenIDs)
            } else if let existing = try existingCompanionSessionID(goalID: goal.id, on: day, calendar: calendar) {
                sessionID = existing
            } else {
                let id = UUID().uuidString
                try knowledgeStore().createReviewSession(
                    id: id,
                    topic: topic,
                    sourceIDs: chosenIDs,
                    startedAt: now,
                    goalID: goal.id,
                    chatKind: .review
                )
                sessionID = id
            }
            // Serving questions is not answering them: the sources are
            // recorded as reviewed when the review ends (`end_review_session`,
            // `markScheduledSourcesReviewed`) or an answer about them is
            // graded, not here, or History says "Reviewed" for a quiz nobody
            // took.
            try knowledgeStore().markCompanionServed(goalID: goal.id, sourceIDs: chosenIDs, quizDate: todayISO)
        }

        let priorSessions = try companionPriorSessions(goalID: goal.id, limit: 3)

        let items: [[String: Any]] = chosen.map { item in
            let meta = metadata[item.sourceID] ?? [:]
            var dict: [String: Any] = [
                "source_id": item.sourceID,
                "title": meta["title"] as? String ?? item.sourceID,
                "source_type": meta["source_type"] as? String ?? "unknown",
                "role": (item.quizCount ?? 0) == 0 ? "new" : "review",
            ]
            if let relevance = item.relevance { dict["relevance"] = relevance }
            if let lastScore = item.lastScore { dict["last_score"] = lastScore }
            return dict
        }
        let contextItems: [[String: Any]] = chosenIDs.compactMap { id in
            guard let text = content[id] else { return nil }
            return [
                "source_id": id,
                "title": metadata[id]?["title"] as? String ?? id,
                "content_excerpt": text,
            ]
        }
        let suggestionItems: [[String: Any]] = pendingSuggestions.prefix(10).map { item in
            let meta = metadata[item.sourceID] ?? [:]
            var dict: [String: Any] = [
                "source_id": item.sourceID,
                "title": meta["title"] as? String ?? item.sourceID,
                "source_type": meta["source_type"] as? String ?? "unknown",
            ]
            if let relevance = item.relevance { dict["relevance"] = relevance }
            return dict
        }
        let gapItems: [[String: Any]] = openGaps.map { gap in
            var dict: [String: Any] = ["summary": gap.summary, "status": gap.status]
            if let severity = gap.severity { dict["severity"] = severity }
            if let sourceID = gap.sourceID { dict["source_id"] = sourceID }
            return dict
        }
        let priorItems: [[String: Any]] = priorSessions.map { s in
            var dict: [String: Any] = [:]
            if let score = s["overall_score"] as? Double { dict["score"] = score }
            if let summary = s["summary"] as? String { dict["summary"] = summary }
            if let endedAt = s["ended_at"] as? Double { dict["ended_at"] = appleToISO(endedAt) }
            return dict
        }

        let approvedCompletedCount = goal.items.filter { $0.isApproved && $0.isCompleted }.count
        let progressDict: [String: Any] = [
            "completed_count": goal.completedCount,
            "approved_pool": approved.count + approvedCompletedCount,
            "new_remaining": newRemaining.count,
        ]
        var goalDict: [String: Any] = [
            "id": goal.id,
            "title": goal.title,
            "topic": goal.topic ?? goal.title,
            "end_date": isoDateOnly(goal.endAt, calendar: calendar),
            "progress": progressDict,
        ]
        // The same count list_goals and the Goals tab give, not
        // the pacing divisor: 0 on the day the Goal falls due.
        if let remaining = goal.daysRemaining(asOf: day, calendar: calendar) {
            goalDict["days_remaining"] = max(0, remaining)
        }
        let paceDict: [String: Any] = [
            "daily_target": target,
            "new_today": newCount,
            "review_today": reviewCount,
            "new_remaining": newRemaining.count,
            "note": "Plan is recomputed each call from days remaining, so missed days self-adjust.",
        ]
        var payload: [String: Any] = [
            "mode": startSession ? "session" : "briefing",
            "goal": goalDict,
            "date": todayISO,
            "pace": paceDict,
            "items": items,
            "prior_sessions": priorItems,
            "open_gaps": gapItems,
            "pending_suggestions": suggestionItems,
            "discovery_note": discoveryNote,
            "generated_at": ISO8601DateFormatter().string(from: now),
        ]
        if startSession, let sessionID {
            payload["session_id"] = sessionID
            payload["context"] = contextItems
            let contrastive = chosen.count > 1
                ? " Because today spans multiple sources, quiz contrastively: ask where the sources agree, contradict, or scope things differently, and make the learner reconcile them — not just recall each in isolation."
                : ""
            payload["instructions"] = "Conduct a review with these sources: start with a compact concept checklist, ask one deep question at a time, weave in review of prior gaps, then call end_review_session with this session_id, an overall_score (0.0-1.0), a summary, and any gaps you observed.\(contrastive)"
        } else {
            payload["instructions"] = "Briefing only — do NOT conduct the quiz. Summarize today's plan for this goal: what's new vs. review, the learner's open gaps, and any pending_suggestions worth approving (use review_suggested_sources). No session was started and nothing was marked done; the learner will call daily_quiz again (default start_session=true) when they sit down to do the live review."
        }
        return try jsonString(payload)
    }

    /// Rebuild the response for an exact provider retry from the queue identity
    /// persisted on the active session. This deliberately does not ask the
    /// scheduler for today's queue again: the operation already chose one.
    private func replayMCPMemoryReview(
        session: CloudKitReviewSessionPayload,
        operationID: String?,
        goalInfo: [String: Any]?,
        calendar: Calendar,
        store: KnowledgeStore
    ) throws -> String {
        let storedSourceIDs = sanitizedSourceIDs(session.sourceIDs)
        guard !storedSourceIDs.isEmpty,
              storedSourceIDs == session.sourceIDs,
              Set(storedSourceIDs).count == storedSourceIDs.count else {
            throw MCPError.invalidInput(
                "The persisted memory review queue has invalid or duplicate source identities. Start a new review with a new operation_id."
            )
        }
        let availableSourceIDs = try persistedMCPSourceIDs(storedSourceIDs)
        guard Set(storedSourceIDs).isSubset(of: availableSourceIDs) else {
            let missing = storedSourceIDs.filter { !availableSourceIDs.contains($0) }
            throw MCPError.notFound(
                "The persisted memory review queue references unavailable library source(s): \(missing.joined(separator: ", ")). ForeverLM will not replace them with a different queue on retry."
            )
        }

        let metadata = try sourceMetadataByID(storedSourceIDs)
        let content = try sourceContentByID(storedSourceIDs, perSourceLimit: 6000)
        var memoryItems: [[String: Any]] = []
        var legacyItems: [[String: Any]] = []
        var newItems: [[String: Any]] = []
        var seenCards = Set<String>()
        let storedSourceSet = Set(storedSourceIDs)

        for cardID in session.cardIDs {
            guard seenCards.insert(cardID).inserted else {
                throw MCPError.invalidInput(
                    "The persisted memory review queue contains a duplicate target identity. Start a new review with a new operation_id."
                )
            }
            if let identity = try mcpMemoryItemCardIdentity(cardID) {
                let itemID = identity.itemID
                guard let item = try store.loadMemoryItem(itemID),
                      item.status == .active else {
                    throw MCPError.notFound(
                        "The persisted memory review target \(itemID) is no longer available. ForeverLM will not substitute a different concept on retry."
                    )
                }
                guard MemoryTutorIdentity.immutableCurriculumFingerprint(item)
                    == identity.fingerprint else {
                    throw MCPError.invalidInput(
                        "The persisted memory review target \(itemID) changed after this queue was prepared. Reload the memory review before asking or grading another question."
                    )
                }
                let itemSourceIDs = Set(item.sources.map(\.sourceID))
                guard !itemSourceIDs.isEmpty,
                      itemSourceIDs.isSubset(of: storedSourceSet),
                      itemSourceIDs.isSubset(of: availableSourceIDs) else {
                    throw MCPError.invalidInput(
                        "The persisted memory review target \(itemID) no longer matches its session source anchors."
                    )
                }
                let schedule = try store.loadMemorySchedule(memoryItemID: itemID)
                    ?? MemorySchedule(memoryItemID: itemID, dueAt: session.startedAt)
                let daysOverdue = max(
                    0,
                    Int(session.startedAt.timeIntervalSince(schedule.dueAt) / 86_400)
                )
                let due = DueMemoryItem(item: item, schedule: schedule, daysOverdue: daysOverdue)
                memoryItems.append(try mcpMemoryItemPayload(
                    item: item,
                    reason: MemoryTutorQueueSelection.isStruggle(due) ? .struggle : .due,
                    daysOverdue: daysOverdue,
                    store: store
                ))
                continue
            }
            if cardID.hasPrefix("memory-item:") {
                throw MCPError.invalidInput(
                    "This active memory review predates immutable curriculum snapshots. Start a new review before asking or grading another question."
                )
            }

            let sourceID: String
            let isLegacy: Bool
            if cardID.hasPrefix("legacy-first-review-portable:") {
                let portableKey = String(cardID.dropFirst("legacy-first-review-portable:".count))
                guard !portableKey.isEmpty,
                      let resolved = try store.resolveMemorySourceID(
                        portableSourceKey: portableKey,
                        restrictToSourceIDs: storedSourceIDs
                      ) else {
                    throw MCPError.notFound(
                        "A persisted first-review source no longer resolves inside this review's source relationship."
                    )
                }
                sourceID = resolved
                isLegacy = true
            } else if cardID.hasPrefix("new-first-review-portable:") {
                let portableKey = String(cardID.dropFirst("new-first-review-portable:".count))
                guard !portableKey.isEmpty,
                      let resolved = try store.resolveMemorySourceID(
                        portableSourceKey: portableKey,
                        restrictToSourceIDs: storedSourceIDs
                      ) else {
                    throw MCPError.notFound(
                        "A persisted first-review source no longer resolves inside this review's source relationship."
                    )
                }
                sourceID = resolved
                isLegacy = false
            } else if cardID.hasPrefix("legacy-first-review:") {
                // Backwards compatibility for sessions created before portable
                // queue identities shipped. New sessions never store local IDs.
                sourceID = String(cardID.dropFirst("legacy-first-review:".count))
                isLegacy = true
            } else if cardID.hasPrefix("new-first-review:") {
                // Backwards compatibility for pre-portable queue identities.
                sourceID = String(cardID.dropFirst("new-first-review:".count))
                isLegacy = false
            } else {
                throw MCPError.invalidInput(
                    "The persisted memory review queue contains an unsupported target identity. Start a new review with a new operation_id."
                )
            }
            guard storedSourceSet.contains(sourceID),
                  availableSourceIDs.contains(sourceID),
                  content[sourceID]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let source = metadata[sourceID] else {
                throw MCPError.notFound(
                    "First-review source \(sourceID) no longer has canonical library text. ForeverLM will not ask from title or replace it on retry."
                )
            }
            let title = source["title"] as? String ?? sourceID
            let sourceType = source["source_type"] as? String ?? "source"
            if isLegacy {
                // Classification is persisted in card_ids. Current review stats
                // only enrich the response; they never reselect the source.
                let stat = try store.memoryReviewStats(
                    restrictToSourceIDs: Set([sourceID])
                ).first
                let lastReviewedAt = stat?.lastReviewedAt ?? session.startedAt
                let dueAt = stat.map { MemoryReviewScheduler.dueDate(for: $0) }
                    ?? session.startedAt
                var item: [String: Any] = [
                    "source_id": sourceID,
                    "title": title,
                    "source_type": sourceType,
                    "last_reviewed": isoDateOnly(lastReviewedAt, calendar: calendar),
                    "days_overdue": max(0, Int(session.startedAt.timeIntervalSince(dueAt) / 86_400)),
                    "review_count": stat?.reviewCount ?? 1,
                ]
                if let score = stat?.lastScore { item["last_score"] = score }
                legacyItems.append(item)
            } else {
                newItems.append([
                    "source_id": sourceID,
                    "title": title,
                    "source_type": sourceType,
                    "consumed": isoDateOnly(session.startedAt, calendar: calendar),
                    "days_since_due": 0,
                    "review_count": 0,
                ])
            }
        }

        let firstReviewSourceIDs = Set(
            legacyItems.compactMap { $0["source_id"] as? String }
                + newItems.compactMap { $0["source_id"] as? String }
        )
        if let missing = firstReviewSourceIDs.first(where: {
            content[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }) {
            throw MCPError.notFound(
                "First-review source \(missing) has no canonical text to load. ForeverLM will not ask a memory question from title or metadata alone."
            )
        }
        let contextItems: [[String: Any]] = storedSourceIDs.compactMap { id in
            guard let text = content[id] else { return nil }
            return ["source_id": id, "content_excerpt": text]
        }
        var payload: [String: Any] = [
            "date": isoDateOnly(session.startedAt, calendar: calendar),
            "mode": "session",
            "session_id": session.id,
            "due_count": memoryItems.count + legacyItems.count,
            "memory_item_count": memoryItems.count,
            "new_count": newItems.count,
            "memory_items": memoryItems,
            "items": legacyItems,
            "new_items": newItems,
            "generated_at": ISO8601DateFormatter().string(from: session.startedAt),
            "context": contextItems,
            "instructions": Self.memoryReviewSessionInstructions,
        ]
        if let operationID {
            payload["operation_id"] = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let goalInfo { payload["goal"] = goalInfo }
        return try jsonString(payload)
    }

    /// How an assistant conducts a started `memory_review`. A kept card
    /// (`ask` on its entry) is asked in its stored wording, which is the card;
    /// any other item is a target to word afresh.
    static let memoryReviewSessionInstructions = "Use `memory_items` first. Each has a stable item_id, semantic learning target, private grading rubric, bounded prior_struggles, and source evidence. An item with `ask` is a card the learner kept: ask `ask` exactly as written, grade the answer against the item's learning_target (the card's answer) and rubric, and record that wording as the attempt's prompt. For any other item, generate a fresh retrieval or application question rather than reciting a flashcard. Do not reveal the rubric, prior answer, or evidence before the learner attempts an answer. `items` and `new_items` are concept-intake reviews with no durable item yet: use their loaded source context before asking, then preserve one stable semantic_target, compact rubric, and exact evidence_excerpt. Ask one question at a time and never end automatically. Only after the learner explicitly finishes, call end_review_session with this session_id, the transcript, score, summary, and structured memory_attempts for every existing item and intake review you covered so scheduling evidence is preserved."

    private func mcpMemoryItemPayload(
        item: MemoryItem,
        reason: MemoryCompanionReason,
        daysOverdue: Int,
        store: KnowledgeStore
    ) throws -> [String: Any] {
        let struggleProjection = try store.memoryStruggleProjection(
            memoryItemID: item.id,
            limit: 3
        )
        let sources: [[String: Any]] = item.sources.map { source in
            var anchor: [String: Any] = [
                "source_id": source.sourceID,
                "excerpt": source.excerpt,
                "source_sha256": source.sourceSHA256,
            ]
            if let locator = source.locatorJSON { anchor["locator_json"] = locator }
            return anchor
        }
        var dict: [String: Any] = [
            "item_id": item.id,
            "kind": item.kind.rawValue,
            "learning_target": item.target,
            "grading_rubric_json": item.rubricJSON,
            "reason": reason.rawValue,
            "days_overdue": daysOverdue,
            "sources": sources,
        ]
        if let context = item.learnerContext,
           !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict["learner_context"] = context
        }
        // A kept card is asked as worded: its front, or the learner's own
        // rewording from the card's state row, or — once it has been
        // remembered twice — one of its rewordings, by the card review's own
        // rotation (`MemoryCardWording`), so an assistant asks what the app
        // would and records it as the attempt's prompt.
        if let card = MemoryCard(storedIn: item) {
            let state = card.stateDeckID(in: item).flatMap {
                MemoryCardStateStore.state(cardID: card.cardID, deckID: $0, defaults: cardStateDefaults)
            }
            dict["ask"] = MemoryCardWording.asked(
                card: card,
                state: state,
                attempts: try store.loadMemoryAttempts(memoryItemID: item.id)
            ).text
        }
        if let struggleProjection, !struggleProjection.evidence.isEmpty {
            dict["prior_struggles"] = struggleProjection.evidence.map { attempt in
                var evidence: [String: Any] = [
                    "attempted_at": ISO8601DateFormatter().string(from: attempt.attemptedAt),
                    "grade_state": attempt.gradeState.rawValue,
                    "prior_question": String(attempt.prompt.prefix(1_000)),
                    "prior_learner_answer": String(attempt.learnerAnswer.prefix(1_000)),
                    "missing_rubric_elements": attempt.missingRubricElements.map {
                        String($0.prefix(500))
                    },
                ]
                if let quality = attempt.retrievalQuality { evidence["retrieval_quality"] = quality }
                if let rating = attempt.scheduleRating { evidence["schedule_rating"] = rating.rawValue }
                if let score = attempt.score { evidence["score"] = score }
                if let misconception = attempt.misconception {
                    evidence["misconception"] = String(misconception.prefix(1_000))
                }
                if let feedback = attempt.feedback {
                    evidence["prior_feedback"] = String(feedback.prefix(1_000))
                }
                if let error = attempt.gradingError {
                    evidence["grading_error"] = String(error.prefix(1_000))
                }
                return evidence
            }
        }
        return dict
    }

    // MARK: - Memory Review (daily retention)

    /// Spaced-repetition retention across the library, in two buckets:
    /// **refreshes** — previously-studied sources that are fading (by recency + last
    /// recall score) — and **first reviews** — sources the learner has consumed but
    /// never reviewed, which otherwise never enter the retention loop at all and are
    /// simply forgotten. Both come from `MemoryReviewScheduler`; the day's limit is
    /// split between them so neither bucket starves the other.
    /// Independent of any deadline/goal; pass goalID to scope to one goal's sources.
    func memoryReview(
        goalID: String?,
        limit: Int?,
        startSession: Bool,
        operationID: String? = nil,
        hostSessionID: String? = nil
    ) async throws -> String {
        let calendar = Calendar.current
        let now = Date()
        let cap = max(1, min(limit ?? 5, 25))

        var restrict: Set<String>?
        var goalInfo: [String: Any]?
        let trimmedGoalID = goalID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkedGoalID = trimmedGoalID?.isEmpty == false ? trimmedGoalID : nil
        // An idempotency key is for callers with no session of their own. The
        // in-app chat's session already is that key, so its value is ignored
        // rather than rejected.
        let hostSession = try resolvedHostSessionID(hostSessionID)
        let operationSession = try hostSession != nil ? nil : deterministicMCPOperationSessionIdentity(
            operationID,
            namespace: "memory-review-v1",
            sessionPrefix: "mcp-memory-review",
            requestFields: [
                "version": 1,
                "goal_id": linkedGoalID ?? NSNull(),
                "limit": cap,
            ]
        )
        if operationSession != nil, !startSession {
            throw MCPError.invalidInput(
                "operation_id is only valid when start_session is true."
            )
        }
        if let trimmedGoalID, !trimmedGoalID.isEmpty {
            let goal = try requireCompanionGoal(trimmedGoalID)
            restrict = Set(goal.items.filter { $0.isApproved }.map(\.sourceID))
            goalInfo = ["id": goal.id, "title": goal.title, "topic": goal.topic ?? goal.title]
        }

        let store = try knowledgeStore()
        if let operationSession {
            if let conflictingID = try existingMCPOperationSessionID(
                prefix: operationSession.sessionIDPrefix
            ), conflictingID != operationSession.sessionID {
                throw MCPError.invalidInput(
                    "operation_id was already used with different memory_review arguments. Use a new operation_id."
                )
            }
            if let existing = try store.loadReviewSessionForSync(operationSession.sessionID) {
                guard existing.status == "active",
                      existing.goalID == linkedGoalID,
                      !existing.cardIDs.isEmpty else {
                    throw MCPError.invalidInput(
                        "operation_id was already used for a different or completed memory review request. Use a new operation_id."
                    )
                }
                // Provider retries replay the exact persisted queue before any
                // due/new selection is recomputed. A sync or an intervening
                // schedule change must not turn one operation into a new review.
                return try replayMCPMemoryReview(
                    session: existing,
                    operationID: operationID,
                    goalInfo: goalInfo,
                    calendar: calendar,
                    store: store
                )
            }
        }
        // Any active concept anchor is authoritative, even when its next
        // schedule is in the future. The source-indexed lookup prevents an
        // anchored source from re-entering legacy/first-review intake merely
        // because that particular concept is not in today's due slice.
        let representedSourceIDs = try store.activeMemoryItemSourceIDs(
            restrictToSourceIDs: restrict
        )
        let stats = try store.memoryReviewStats(restrictToSourceIDs: restrict)
            .filter { !representedSourceIDs.contains($0.sourceID) }
        let candidates = try store.unreviewedConsumedSources(restrictToSourceIDs: restrict)
            .filter { !representedSourceIDs.contains($0.sourceID) }
        let conceptDue = try store.dueMemoryItems(
            now: now,
            limit: cap,
            restrictToSourceIDs: restrict
        ).filter { due in
            guard let restrict else { return true }
            return !due.item.sources.isEmpty
                && due.item.sources.allSatisfy { restrict.contains($0.sourceID) }
        }

        // Existing concept memories are authoritative. The legacy source-level
        // bucket remains only for libraries whose older reviews have not yet
        // produced a concept trace; don't surface the same source in both.
        let allDue = MemoryReviewScheduler.dueItems(from: stats, now: now, limit: cap)
        let allNew = MemoryReviewScheduler.newItems(from: candidates, now: now, limit: cap)
        let recentActivity = try store.recentReviewSourceActivity(now: now)
        // Legacy reviews have durable recall history but predate concept-level
        // MemoryItems. Treat them as first-review intake, ahead of never-reviewed
        // sources, so every surface reserves the same one intake slot when the
        // concept queue fills the daily cap. Once covered, end_review_session
        // creates their canonical concept trace just like any other intake.
        let legacyIntake = allDue.map { item in
            MemoryReviewNewItem(
                sourceID: item.sourceID,
                title: item.title,
                sourceType: item.sourceType,
                consumedAt: item.lastReviewedAt,
                dueAt: item.dueAt,
                daysOverdue: item.daysOverdue
            )
        }
        let firstReviewIntake = legacyIntake + allNew
        let candidateSourceIDs = sanitizedSourceIDs(
            conceptDue.flatMap { $0.item.sources.map(\.sourceID) }
                + firstReviewIntake.map(\.sourceID)
        )
        // Memory anchors can arrive before their Source during cross-device
        // sync. Only a real, visible library row makes an anchor reviewable;
        // candidate IDs themselves are not proof that source content exists.
        let availableSourceIDs = try persistedMCPSourceIDs(candidateSourceIDs)
        let groundedConceptDue = conceptDue.filter { due in
            !due.item.sources.isEmpty
                && due.item.sources.allSatisfy { availableSourceIDs.contains($0.sourceID) }
        }
        let conceptPlan = MemoryCompanionPlan.assemble(
            dueItems: groundedConceptDue,
            firstReviews: firstReviewIntake,
            availableSourceIDs: availableSourceIDs,
            recentSourceActivity: recentActivity,
            goalID: trimmedGoalID?.isEmpty == false ? trimmedGoalID : nil,
            topic: goalInfo?["title"] as? String ?? "Daily memory refresh",
            limit: cap,
            now: now
        )
        let conceptTargets = conceptPlan?.targets.filter { $0.memoryItem != nil } ?? []
        let selectedFirstReviewIDs = Set(
            conceptPlan?.targets
                .filter { $0.reason == .firstReview }
                .map(\.sourceID) ?? []
        )
        let due = allDue.filter { selectedFirstReviewIDs.contains($0.sourceID) }
        let newItems = allNew.filter { selectedFirstReviewIDs.contains($0.sourceID) }

        guard !conceptTargets.isEmpty || !due.isEmpty || !newItems.isEmpty else {
            var payload: [String: Any] = [
                "date": isoDateOnly(now, calendar: calendar),
                "due_count": 0,
                "memory_item_count": 0,
                "new_count": 0,
                "memory_items": [] as [[String: Any]],
                "items": [] as [[String: Any]],
                "new_items": [] as [[String: Any]],
                "instructions": "Nothing is due for a memory refresh\(goalInfo == nil ? "" : " for this goal") right now — everything reviewed recently is still fresh, and nothing newly read is waiting for a first review. Check back another day.",
            ]
            if let goalInfo { payload["goal"] = goalInfo }
            return try jsonString(payload)
        }

        // First reviews lead: the material is freshest and the recall is weakest.
        let sessionSourceIDs = sanitizedSourceIDs(conceptPlan?.sourceIDs ?? [])
        let legacySourceIDs = Set(allDue.map(\.sourceID))
        let sessionCardIDs = try conceptPlan?.targets.map { target -> String in
            if let item = target.memoryItem {
                return mcpMemoryItemCardID(item)
            }
            let portableKey = try store.portableMemorySourceKey(sourceID: target.sourceID)
            return legacySourceIDs.contains(target.sourceID)
                ? "legacy-first-review-portable:\(portableKey)"
                : "new-first-review-portable:\(portableKey)"
        } ?? []
        guard !sessionCardIDs.isEmpty,
              Set(sessionCardIDs).count == sessionCardIDs.count else {
            throw MCPError.database(
                "The memory review planner produced an invalid duplicate target identity. No session was created."
            )
        }
        let goalTitle = goalInfo?["title"] as? String

        var sessionID: String?
        var content: [String: String] = [:]
        if startSession {
            content = try sourceContentByID(sessionSourceIDs, perSourceLimit: 6000)
            // A first-review question may only be derived after the assistant has
            // actually received that source's text. Fail before creating a
            // session instead of allowing a title-only question whose durable
            // curriculum would be validated only after the learner answered.
            if let missing = conceptPlan?.targets.first(where: {
                $0.reason == .firstReview
                    && content[$0.sourceID]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }) {
                throw MCPError.notFound(
                    "First-review source \(missing.sourceID) has no canonical text to load. ForeverLM will not ask a memory question from title or metadata alone."
                )
            }
            // In-app Chat already has a session recording this conversation; bind to
            // it rather than inserting a second, exchange-less row.
            if let hostSession {
                sessionID = hostSession
                try await mergeReviewSessionSourceIDs(sessionID: hostSession, adding: sessionSourceIDs)
            } else {
                let topic = goalTitle.map { "Memory refresh — \($0)" } ?? "Daily memory refresh"
                let id = operationSession?.sessionID
                    ?? "mcp-memory-review-\(UUID().uuidString)"
                // Global refreshes link to no goal; per-goal ones link so the goal's
                // history also reflects the refresh. card_ids stores the
                // exact app-owned queue identity for operation-id replay.
                try store.createReviewSession(
                    id: id,
                    topic: topic,
                    sourceIDs: sessionSourceIDs,
                    cardIDs: sessionCardIDs,
                    startedAt: now,
                    goalID: linkedGoalID,
                    chatKind: .memory
                )
                sessionID = id
            }
            // Serving questions is not answering them: the sources are
            // recorded as reviewed when the review ends (`end_review_session`,
            // `markScheduledSourcesReviewed`) or an answer about them is
            // graded, not here, or History says "Reviewed" for a quiz nobody
            // took.
        }

        let items: [[String: Any]] = due.map { item in
            var dict: [String: Any] = [
                "source_id": item.sourceID,
                "title": item.title,
                "source_type": item.sourceType,
                "last_reviewed": isoDateOnly(item.lastReviewedAt, calendar: calendar),
                "days_overdue": item.daysOverdue,
                "review_count": item.reviewCount,
            ]
            if let score = item.lastScore { dict["last_score"] = score }
            return dict
        }
        let memoryItems: [[String: Any]] = try conceptTargets.compactMap { target in
            guard let item = target.memoryItem else { return nil }
            return try mcpMemoryItemPayload(
                item: item,
                reason: target.reason,
                daysOverdue: target.daysOverdue,
                store: store
            )
        }
        let newItemPayload: [[String: Any]] = newItems.map { item in
            [
                "source_id": item.sourceID,
                "title": item.title,
                "source_type": item.sourceType,
                "consumed": isoDateOnly(item.consumedAt, calendar: calendar),
                "days_since_due": item.daysOverdue,
                "review_count": 0,
            ]
        }
        let contextItems: [[String: Any]] = sessionSourceIDs.compactMap { id in
            guard let text = content[id] else { return nil }
            return ["source_id": id, "content_excerpt": text]
        }

        var payload: [String: Any] = [
            "date": isoDateOnly(now, calendar: calendar),
            "mode": startSession ? "session" : "briefing",
            "due_count": conceptTargets.count + due.count,
            "memory_item_count": conceptTargets.count,
            "new_count": newItems.count,
            "memory_items": memoryItems,
            "items": items,
            "new_items": newItemPayload,
            "generated_at": ISO8601DateFormatter().string(from: now),
        ]
        if let goalInfo { payload["goal"] = goalInfo }
        if startSession, let sessionID {
            payload["session_id"] = sessionID
            if operationSession != nil, let operationID {
                payload["operation_id"] = operationID.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            payload["context"] = contextItems
            payload["instructions"] = Self.memoryReviewSessionInstructions
        } else {
            payload["instructions"] = "Briefing only — do NOT start the review. Summarize why the concept-level `memory_items` are due without exposing their private rubric or answer evidence. Mention first-review `new_items` and any legacy source-level `items`. When the learner is ready, call memory_review again with start_session=true."
        }
        return try jsonString(payload)
    }

    /// Chat-first daily review: merges gaps, spaced repetition, companion pacing, and
    /// in-progress reading into one plan for Review Chat — without writing to Schedule.
    func dailyReview(goalID: String?, startSession: Bool = true, hostSessionID: String? = nil) async throws -> String {
        let calendar = Calendar.current
        let now = Date()
        let todayISO = isoDateOnly(now, calendar: calendar)

        guard let goalID, !goalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let menu = try listCompanionLearningGoals(includeCompleted: false)
            return "No goal_id given. Pick one and call daily_review again with its goal_id.\n\n\(menu)"
        }

        var goal = try requireCompanionGoal(goalID)
        // Screen record mode (admin only): the plan is drawn only from the
        // goal's sources the take may show. Nil scope leaves the pool whole.
        let screenRecordHidden = try screenRecordHiddenSourceIDs(scope: screenRecordScope())
        if !screenRecordHidden.isEmpty {
            goal.items = goal.items.filter { !screenRecordHidden.contains($0.sourceID) }
        }
        let approved = Set(goal.items.filter(\.isApproved).map(\.sourceID))
        guard !approved.isEmpty else {
            return "No approved sources in \(Self.companionName(goal)) yet. Add seeds with add_companion_sources or approve discovered suggestions."
        }

        let store = try knowledgeStore()
        let stats = try store.memoryReviewStats(restrictToSourceIDs: approved)
        let memoryDue = MemoryReviewScheduler.dueItems(from: stats, now: now, limit: 50)

        var readingInProgress = Set<String>()
        for sourceID in approved {
            guard let article = try store.loadSourceForSync(sourceID) else { continue }
            // Not a bare non-nil locator: a video marked not watched keeps one.
            if article.hasSavedReadingPosition {
                readingInProgress.insert(sourceID)
            }
        }

        guard let plan = DailyReviewPlan.assemble(
            goal: goal,
            memoryDue: memoryDue,
            readingInProgressSourceIDs: readingInProgress,
            now: now
        ) else {
            return "No daily review plan could be assembled for \(Self.companionName(goal)) — all approved sources may be completed."
        }

        let metadata = try sourceMetadataByID(plan.sourceIDs)
        var sessionID: String? = nil
        var content: [String: String] = [:]
        if startSession {
            content = try sourceContentByID(plan.sourceIDs, perSourceLimit: 6000)
            // In-app Chat already has a session recording this conversation; bind to
            // it rather than inserting a second, exchange-less row.
            if let hostSession = try resolvedHostSessionID(hostSessionID) {
                sessionID = hostSession
                try await mergeReviewSessionSourceIDs(sessionID: hostSession, adding: plan.sourceIDs)
            } else {
                let id = UUID().uuidString
                try store.createReviewSession(
                    id: id,
                    topic: plan.topic,
                    sourceIDs: plan.sourceIDs,
                    startedAt: now,
                    goalID: plan.goalID,
                    chatKind: .review
                )
                sessionID = id
            }
            // Serving questions is not answering them: the sources are
            // recorded as reviewed when the review ends (`end_review_session`,
            // `markScheduledSourcesReviewed`) or an answer about them is
            // graded, not here, or History says "Reviewed" for a quiz nobody
            // took.
            try store.markCompanionServed(goalID: plan.goalID, sourceIDs: plan.sourceIDs, quizDate: todayISO)
        }

        let items: [[String: Any]] = plan.items.map { entry in
            let meta = metadata[entry.sourceID] ?? [:]
            return [
                "source_id": entry.sourceID,
                "title": meta["title"] as? String ?? entry.sourceID,
                "source_type": meta["source_type"] as? String ?? "unknown",
                "role": entry.role.rawValue,
            ]
        }
        let contextItems: [[String: Any]] = plan.sourceIDs.compactMap { id in
            guard let text = content[id] else { return nil }
            return [
                "source_id": id,
                "title": metadata[id]?["title"] as? String ?? id,
                "content_excerpt": text,
            ]
        }

        var payload: [String: Any] = [
            "mode": startSession ? "session" : "briefing",
            "goal_id": plan.goalID,
            "topic": plan.topic,
            "rationale": plan.rationale,
            "done_today": plan.doneToday,
            "date": todayISO,
            "items": items,
            "generated_at": ISO8601DateFormatter().string(from: now),
        ]
        if startSession, let sessionID {
            payload["session_id"] = sessionID
            payload["context"] = contextItems
            payload["instructions"] = "Conduct today's review as a review chat: start with a compact concept checklist informed by the rationale, ask one deep question at a time, then call end_review_session with this session_id, overall_score, summary, transcript, and any gaps observed."
        } else {
            payload["instructions"] = "Briefing only — summarize today's review focus using the rationale. Do NOT conduct the quiz or start a session. The learner will call daily_review with start_session=true (or use in-app Review Chat) when ready."
        }
        return try jsonString(payload)
    }

    // MARK: Companion helpers

    func requireCompanionGoal(_ goalID: String) throws -> LearningGoalRecord {
        let trimmed = goalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPError.invalidInput("goal_id is required.") }
        guard let goal = try knowledgeStore().loadLearningGoal(trimmed) else {
            throw MCPError.notFound("Learning Companion goal not found: \(trimmed)")
        }
        guard goal.isCompanion else {
            throw MCPError.invalidInput("Goal \(trimmed) is a Schedule, not a Learning Companion goal.")
        }
        return goal
    }

    /// Resolve only a timebound Goal, tagged to a Notebook or standing alone.
    /// Notebook-oriented tools use `requireCompanionGoal`; Goal-specific tools
    /// must not accept an open-ended Notebook and silently reinterpret it as a
    /// Goal.
    func requireNotebookGoal(_ goalID: String) throws -> LearningGoalRecord {
        let goal = try requireCompanionGoal(goalID)
        guard goal.isGoal else {
            throw MCPError.invalidInput(
                "\(goal.id) is a Notebook, not a timebound Goal. Use list_goals to find a Goal."
            )
        }
        return goal
    }

    /// Finds library sources that fit the goal and inserts them as pending suggestions.
    /// When incremental, only sources added since the goal's last discovery pass are considered.
    /// `seedSourceIDs` are the sources that steer the search, best first; nil is the goal's
    /// own (`companionDiscoverySeeds`). A caller that has just made the goal passes the
    /// order it was given, which the goal's items, all added at once, do not keep.
    @discardableResult
    func runCompanionDiscovery(
        goal: LearningGoalRecord,
        excluding: Set<String>,
        incremental: Bool,
        seedSourceIDs: [String]? = nil
    ) async throws -> Int {
        let topic = (goal.topic ?? goal.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return 0 }
        let since = incremental ? goal.lastDiscoveryAt?.timeIntervalSinceReferenceDate : nil
        let candidates = try await companionDiscover(
            topic: topic,
            seedSourceIDs: seedSourceIDs ?? companionDiscoverySeeds(goal),
            excluding: excluding,
            sinceReferenceTimestamp: since,
            limit: companionDiscoveryPool
        )
        let fitting = try await sourcesFitting(goal: goal, candidates: candidates.map(\.sourceID))
        let matches = Array(candidates.filter { fitting.contains($0.sourceID) }.prefix(companionDiscoveryLimit))
        let added = try knowledgeStore().addDiscoveredCompanionSources(goalID: goal.id, discovered: matches)
        try knowledgeStore().setCompanionDiscoveryStamp(goalID: goal.id, at: Date())
        return added
    }

    /// The sources a goal already holds that steer its discovery: its approved sources in
    /// the learner's study order (`sequence`, then when each was added, as the Notebook
    /// lists them), at most `companionDiscoverySeedLimit`, so the founding sources of a
    /// large Notebook speak for it.
    func companionDiscoverySeeds(_ goal: LearningGoalRecord) -> [String] {
        let approved = goal.items.enumerated().filter { $0.element.isApproved }
        return approved
            .sorted { lhs, rhs in
                let left = (lhs.element.sequence ?? .greatestFiniteMagnitude, lhs.element.addedAt, lhs.offset)
                let right = (rhs.element.sequence ?? .greatestFiniteMagnitude, rhs.element.addedAt, rhs.offset)
                return left < right
            }
            .prefix(companionDiscoverySeedLimit)
            .map(\.element.sourceID)
    }

    /// The library's nearest sources to the goal, best first, as the pool
    /// `sourcesFitting` judges. Two kinds of evidence, fused by rank
    /// (`SourceSearchEngine.fusedRanking`):
    /// - the topic's words, through the hybrid search the app's own search runs
    ///   (`SourceSearchEngine`), so a paper titled with the topic's own words is never
    ///   outranked by one whose single chunk happens to sit near it;
    /// - each seed's distinctive words (`SourceSearchEngine.moreLikeThis`): a Notebook
    ///   made from a paper is about that paper, whatever its title says. The seeds share
    ///   one vote, as much as the topic's, so what several of them have in common rises
    ///   and one seed's quirks are outvoted (a meeting transcript's most distinctive words
    ///   are its speakers' names).
    /// Relevance is the fused score, which orders this one pool and means nothing on its
    /// own; whether a candidate belongs is `sourcesFitting`'s call.
    func companionDiscover(
        topic: String,
        seedSourceIDs: [String] = [],
        excluding: Set<String>,
        sinceReferenceTimestamp: Double?,
        limit: Int
    ) async throws -> [(sourceID: String, relevance: Double)] {
        let embeddingProvider = sourceEmbeddingProvider ?? liveSourceEmbeddingProvider
        let queryVector = try await embeddingProvider(topic)
        let store = try knowledgeStore()

        // An incremental pass ranks within the sources added since the last one,
        // so the subset gets its own ranking rather than whatever fragment of it
        // survives a library-wide top-N.
        var restrictedTo: Set<String>?
        if let since = sinceReferenceTimestamp {
            let recent = try withDB { db -> Set<String> in
                Set(try query(db, "SELECT id FROM source_projection WHERE date_added > ?", params: [since])
                    .compactMap { $0["id"] as? String })
            }
            guard !recent.isEmpty else { return [] }
            restrictedTo = recent
        }

        let seeds = Array(sanitizedSourceIDs(seedSourceIDs).prefix(companionDiscoverySeedLimit))
        let excludedFromPool = excluding.union(seeds)
        // Over-fetch by the exclusion count so a goal already holding many of the
        // nearest sources still yields a full pool of new ones.
        let rankingLimit = min(limit + excludedFromPool.count, SourceSearchEngine.maximumCandidatePool)
        let topicHits = StorageService.searchSources(
            queryText: topic,
            queryVector: queryVector,
            limit: rankingLimit,
            threshold: EmbeddingSettings.similarityThreshold,
            restrictedTo: restrictedTo,
            using: store
        )
        var rankings: [(ids: [String], weight: Float)] = [(topicHits.map(\.sourceId), 1)]
        if !seeds.isEmpty {
            // The sources search never reads (a hidden show's episodes, a tab kept from
            // AI) stay out of the seeds' rankings as they stay out of the topic's.
            let seedRankings = try SourceSearchEngine.moreLikeThis(
                sourceIDs: seeds,
                limit: rankingLimit,
                store: store,
                restrictedTo: restrictedTo,
                excludedSources: excludedFromPool.union(try store.knowledgeSearchExcludedSourceIDs())
            ).filter { !$0.isEmpty }
            // A seed with nothing to say (no full-text row yet) gives up its share of the
            // vote rather than diluting the others'.
            for ranking in seedRankings {
                rankings.append((ranking, 1 / Float(seedRankings.count)))
            }
        }
        let fused = SourceSearchEngine.fusedRanking(rankings)
            .filter { !excludedFromPool.contains($0.id) }
            .prefix(rankingLimit)
        let active = try persistedMCPSourceIDs(fused.map(\.id))
        return Array(
            fused.lazy
                .filter { active.contains($0.id) }
                .prefix(limit)
                .map { (sourceID: $0.id, relevance: Double($0.score)) }
        )
    }

    /// The candidates a model judges to fit the goal. Library discovery asks the
    /// question Journal Watch asks of a week's feed articles — does this item's
    /// own subject serve what this Notebook is about, not merely share its field —
    /// so it asks it the same way, on the same task's model.
    func sourcesFitting(goal: LearningGoalRecord, candidates: [String]) async throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let metadata = try withDB { db -> [String: [String: Any]] in
            let placeholders = candidates.map { _ in "?" }.joined(separator: ",")
            let rows = try query(db, """
                SELECT id, title, author, journal, COALESCE(parent_group_title, parent_group) AS group_name, domain
                FROM source_projection WHERE id IN (\(placeholders))
            """, params: candidates)
            return Dictionary(
                rows.compactMap { row in (row["id"] as? String).map { ($0, row) } },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let openings = try sourceContentByID(candidates, perSourceLimit: 1_200)
        let items = candidates.compactMap { id -> JournalMatchingCandidate? in
            guard let meta = metadata[id], let title = meta["title"] as? String else { return nil }
            // Where it appeared, as a feed article names its journal or blog.
            let source = [meta["journal"], meta["group_name"], meta["domain"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return JournalMatchingCandidate(
                id: id,
                title: title,
                summary: openings[id],
                source: source,
                authors: meta["author"] as? String
            )
        }
        guard !items.isEmpty else { return [] }
        let held = Set(candidates)
        let sampleIDs = goal.items.filter { $0.isApproved && !held.contains($0.sourceID) }.prefix(12).map(\.sourceID)
        let sampleTitles = try sourceMetadataByID(Array(sampleIDs)).values.compactMap { $0["title"] as? String }
        let notebook = JournalMatchingNotebook(
            id: goal.id,
            title: goal.title,
            instructions: goal.description,
            researchQuestions: goal.researchQuestions ?? [],
            topic: goal.topic,
            sampleSourceTitles: sampleTitles
        )
        let judge = libraryFitJudge ?? Self.liveLibraryFitJudge
        do {
            return try await judge(notebook, items)
        } catch let error as MCPError {
            throw error
        } catch {
            // Said as discovery's failure, which every caller reports and moves
            // past: the Notebook or Goal it ran for is already saved.
            throw MCPError.invalidInput("the model judging which sources fit failed (\(error.localizedDescription))")
        }
    }

    static let liveLibraryFitJudge: LibraryFitJudge = { notebook, candidates in
        guard let config = KeychainService.resolveConfig(for: .journalArticleMatching) else {
            throw MCPError.invalidInput(
                KeychainService.backgroundAIUnavailableMessage(for: .journalArticleMatching)
                    ?? "No model is available to judge which sources fit. Check AI Usage."
            )
        }
        let verdicts = try await AIService().matchJournalArticles(
            notebooks: [notebook],
            candidates: candidates,
            config: config
        )
        return Set(verdicts.filter { $0.notebookID == notebook.id }.map(\.itemID))
    }

    func existingCompanionSessionID(goalID: String, on day: Date, calendar: Calendar) throws -> String? {
        try withDB { db in
            let rows = try query(db, """
                SELECT id, started_at FROM review_sessions
                WHERE goal_id = ? AND status = 'active'
                ORDER BY started_at DESC LIMIT 1
            """, params: [goalID])
            guard let row = rows.first,
                  let id = row["id"] as? String,
                  let startedAt = row["started_at"] as? Double else { return nil }
            return calendar.isDate(appleDate(startedAt), inSameDayAs: day) ? id : nil
        }
    }

    func companionPriorSessions(goalID: String, limit: Int) throws -> [[String: Any]] {
        try withDB { db in
            try query(db, """
                SELECT overall_score, summary, ended_at FROM review_sessions
                WHERE goal_id = ? AND status = 'completed'
                ORDER BY COALESCE(ended_at, started_at) DESC LIMIT ?
            """, params: [goalID, limit])
        }
    }

    func sourceMetadataByID(_ ids: [String]) throws -> [String: [String: Any]] {
        guard !ids.isEmpty else { return [:] }
        return try withDB { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try query(db, """
                SELECT id, title, source_type, COALESCE(parent_group_title, parent_group) AS parent_group, author, word_count
                FROM source_projection WHERE id IN (\(placeholders))
            """, params: ids)
            var result: [String: [String: Any]] = [:]
            for row in rows {
                if let id = row["id"] as? String { result[id] = row }
            }
            return result
        }
    }

    /// Resolve only bounded candidate IDs against the canonical library view.
    /// This is intentionally different from trusting a MemoryItem anchor: sync
    /// may deliver that relationship before the Source row it references.
    func persistedMCPSourceIDs(_ candidateIDs: [String]) throws -> Set<String> {
        let ids = sanitizedSourceIDs(candidateIDs)
        guard !ids.isEmpty else { return [] }
        return try withDB { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try query(
                db,
                """
                SELECT id
                FROM source_projection
                WHERE id IN (\(placeholders))
                  AND status = 'active'
                  AND is_collection_hidden = 0
                """,
                params: ids
            )
            return Set(rows.compactMap { $0["id"] as? String })
        }
    }

    func sourceContentByID(_ ids: [String], perSourceLimit: Int) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return try withDB { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try query(db, """
                SELECT source_id, content FROM source_content WHERE source_id IN (\(placeholders))
            """, params: ids)
            var result: [String: String] = [:]
            for row in rows {
                guard let id = row["source_id"] as? String, let content = row["content"] as? String else { continue }
                result[id] = String(content.prefix(perSourceLimit))
            }
            return result
        }
    }

    func companionGoalHeadline(_ goal: LearningGoalRecord, calendar: Calendar, today: Date) -> [String: Any] {
        let openEnded = goal.isOpenEnded
        // The same whole-days count list_goals and the Goals tab draw (`LearningGoalRecord.daysRemaining`): 0 on the day a Goal
        // falls due, negative once late. Until 2026-09-20 this added one, so
        // a Goal the rail called "due today" listed here with a day left.
        let remaining = goal.daysRemaining(asOf: today, calendar: calendar) ?? 0
        let approvedCount = goal.items.filter { $0.isApproved }.count
        let pendingCount = goal.items.filter { $0.isPendingApproval }.count
        let openGapsCount = (goal.gaps ?? []).filter { $0.isOpen }.count
        let daysRemaining = openEnded ? 0 : max(0, remaining)
        // Completion is explicit lifecycle state, never inferred from the
        // deadline: a Goal whose deadline passed with work still open is
        // *overdue*, not complete.
        let isComplete = goal.isDone
        let isOverdue = goal.isOverdue(asOf: today, calendar: calendar)
        let quizzedToday = goal.lastQuizDate == isoDateOnly(today, calendar: calendar)
        var result: [String: Any] = [:]
        result["id"] = goal.id
        result["title"] = goal.title
        if let description = goal.displayDescription {
            // A Notebook's description IS its standing Instructions; label it so
            // models treat it as guidance rather than flavour text. A Goal's
            // description stays a plain summary of the objective.
            result[goal.isNotebook ? "instructions" : "description"] = description
        }
        if let summary = goal.displaySummary {
            // The card's one-line description: display copy, not guidance.
            result["summary"] = summary
        }
        if goal.isNotebook {
            // The GitHub repository the Notebook is about; null when none, so
            // list_notebooks and get_notebook rows always answer the question.
            result["repository"] = goal.linkedRepository ?? NSNull()
        }
        if goal.isGoal {
            // The Doc, Site or animation the Goal is for; null when none, so a
            // Goal row always answers the question. A linked record that has
            // since been deleted reads as none too, the way the row draws it.
            result["artifact"] = goalArtifactPayload(goal) ?? NSNull()
        }
        result["topic"] = goal.topic ?? goal.title
        result["open_ended"] = openEnded
        if openEnded {
            result["end_date"] = NSNull()
        } else {
            result["end_date"] = isoDateOnly(goal.endAt, calendar: calendar)
        }
        if !openEnded {
            result["days_remaining"] = daysRemaining
            result["is_overdue"] = isOverdue
            if isOverdue {
                result["days_overdue"] = max(0, -remaining)
            }
        }
        result["status"] = goal.lifecycleStatus.rawValue
        result["is_complete"] = isComplete
        result["approved_sources"] = approvedCount
        result["completed_sources"] = goal.completedCount
        result["pending_suggestions"] = pendingCount
        result["open_gaps"] = openGapsCount
        result["quizzed_today"] = quizzedToday
        if goal.isNotebook, let store = try? knowledgeStore() {
            // team_id is null for a personal Notebook; a team Notebook also names
            // its team, so an assistant never has to ask which library it is in.
            for (key, value) in notebookTeamFields(goal, store: store) {
                result[key] = value
            }
        }
        return result
    }

    /// The artifact a Goal is for, as the tools answer it: its id, title and
    /// what it is (`doc`, `site`, `animation`), and its team when it lives in
    /// one. nil when the Goal names none, or names a record that is gone.
    func goalArtifactPayload(_ goal: LearningGoalRecord) -> [String: Any]? {
        guard let artifactID = goal.linkedArtifactID,
              let record = try? knowledgeStore().loadArtifact(artifactID) else { return nil }
        // The tools' word, not `ArtifactSection.noun`: the app calls a Doc a
        // Page since 2026-10-06, and the wire keeps "doc" (AGENTS.md).
        let kind: String
        switch record.section {
        case .docs: kind = "doc"
        case .sites: kind = "site"
        case .animations: kind = "animation"
        }
        var payload: [String: Any] = [
            "id": record.id,
            "title": record.title,
            "kind": kind,
        ]
        if let teamID = record.teamID { payload["team_id"] = teamID }
        return payload
    }

    /// A Notebook or Goal as an answer's sentence names it: its kind and its
    /// title, never its id, which the JSON beside the sentence carries
    /// (Prompts.hiddenIDs).
    static func companionName(_ goal: LearningGoalRecord) -> String {
        "\(goal.isGoal ? "Goal" : "Notebook") ‘\(goal.title)’"
    }

    func companionGoalDetail(_ goal: LearningGoalRecord) throws -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var payload = companionGoalHeadline(goal, calendar: calendar, today: today)
        let metadata = try sourceMetadataByID(goal.items.map(\.sourceID) + (goal.gaps ?? []).compactMap(\.sourceID))
        // Each source comes with the link a reply shows (`sourceLink`), so a
        // list of them is drawn from titles, never from these ids
        // (Prompts.hiddenIDs). A source the library no longer holds has no
        // title to link.
        func sourceEntry(_ sourceID: String) -> [String: Any] {
            guard let title = metadata[sourceID]?["title"] as? String else {
                return ["source_id": sourceID, "title": sourceID]
            }
            return ["source_id": sourceID, "title": title, "link": Self.sourceLink(title: title, id: sourceID)]
        }
        payload["seeds"] = goal.items.filter { $0.origin == LearningGoalItemOrigin.seed.rawValue }.map { item -> [String: Any] in
            sourceEntry(item.sourceID)
        }
        payload["pending_suggestions"] = goal.items.filter { $0.isPendingApproval }.map { item -> [String: Any] in
            var dict = sourceEntry(item.sourceID)
            dict["source_type"] = metadata[item.sourceID]?["source_type"] as? String ?? "unknown"
            if let relevance = item.relevance { dict["relevance"] = relevance }
            return dict
        }
        if let parentID = goal.parentNotebookID, !parentID.isEmpty {
            payload["notebook_id"] = parentID
            if let parent = try? knowledgeStore().loadLearningGoal(parentID) {
                payload["notebook_title"] = parent.title
            }
        }
        payload["open_questions"] = (goal.gaps ?? []).filter { $0.isOpen }.map { gap -> [String: Any] in
            var dict: [String: Any] = ["summary": gap.summary, "status": gap.status]
            if let sourceID = gap.sourceID {
                dict["source_id"] = sourceID
                if let title = metadata[sourceID]?["title"] as? String {
                    dict["source_link"] = Self.sourceLink(title: title, id: sourceID)
                }
            }
            return dict
        }
        if let questions = goal.researchQuestions, !questions.isEmpty {
            payload["research_questions"] = questions
        }
        if goal.isNotebook {
            // Its context notebooks, and whether the learner put each into
            // its chats (`NotebookChatContext`): linking alone reads nothing.
            let ids = goal.relatedNotebookIDs ?? []
            let store = try knowledgeStore()
            let inChat = NotebookChatSelection.contextNotebookIDs(notebookID: goal.id)
            payload["related_notebooks"] = ids.map { id -> [String: Any] in
                let related = try? store.loadLearningGoal(id)
                return [
                    "notebook_id": id,
                    "title": related?.title ?? id,
                    "source_count": related?.approvedSourceIDs.count ?? 0,
                    "in_chat": inChat.contains(id),
                ]
            }
            payload["think_first"] = ThinkFirst.notebookLevel(goal.id)?.rawValue ?? NSNull()
            payload["think_first_level"] = ThinkFirst.level(notebookID: goal.id).rawValue
        }
        return try jsonString(payload)
    }

    func companionCompletionBrief(_ goal: LearningGoalRecord) throws -> String {
        let calendar = Calendar.current
        let openGaps = (goal.gaps ?? []).filter { $0.isOpen }
        let goalDict: [String: Any] = [
            "id": goal.id,
            "title": goal.title,
            "end_date": isoDateOnly(goal.endAt, calendar: calendar),
            "status": goal.lifecycleStatus.rawValue,
        ]
        let gapList: [[String: Any]] = openGaps.map { gap in
            ["summary": gap.summary, "status": gap.status]
        }
        var payload: [String: Any] = [:]
        payload["goal"] = goalDict
        payload["message"] = goal.isArchived
            ? "This Goal is archived. Reopen it to resume daily review."
            : "This Goal is marked done. Reopen it to resume daily review, or use the open questions for a final consolidation review."
        payload["completed_sources"] = goal.completedCount
        payload["total_sources"] = goal.totalCount
        payload["open_gaps"] = gapList
        return try jsonString(payload)
    }

}
