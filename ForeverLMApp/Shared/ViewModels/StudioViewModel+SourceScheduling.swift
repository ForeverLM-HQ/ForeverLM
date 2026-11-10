// Scheduling sources, notebook membership and review session actions.

import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import Darwin

extension StudioViewModel {

    /// Put sources on the Schedule — the Sources sidebar's Add to Schedule and
    /// Schedule for Today. They join the active Goal or Notebook when there is
    /// one. With none they are placed untagged: the Schedule holds a source
    /// whether or not a Goal claims it. A plain goal an older build created is
    /// never joined; it stays in the library untouched, but nothing plans
    /// against it any more. Either way a source already planned keeps its day
    /// unless `day` names one.
    func scheduleSources(_ sourceIDs: [String], on day: Date? = nil) async {
        let uniqueIDs = orderedUniqueSourceIDs(expandedLearningGoalSourceIDs(sourceIDs))
        guard !uniqueIDs.isEmpty else { return }
        let plannedDay = day.map { Calendar.current.startOfDay(for: $0) }

        if let goal = activeLearningGoal, goal.isCompanion {
            if let plannedDay {
                await addSourcesToLearningGoal(goalID: goal.id, sourceIDs: uniqueIDs, plannedFor: plannedDay)
            } else {
                await addSourcesToLearningGoal(goalID: goal.id, sourceIDs: uniqueIDs)
            }
            return
        }

        let planned = Set(scheduledSources.filter { !$0.isAutomatic }.map(\.placement.sourceID))
        let placing = plannedDay == nil ? uniqueIDs.filter { !planned.contains($0) } : uniqueIDs
        await placeSourcesOnSchedule(placing, on: plannedDay ?? Calendar.current.startOfDay(for: Date()))
    }

    func scheduleGroup(_ groupName: String) async {
        await scheduleSources(learningGoalSourceIDsForGroup(groupName))
    }

    /// Place sources on `day` without tagging them to anything: a placed
    /// source moves there, an unplaced one gets a placement of its own.
    func placeSourcesOnSchedule(_ sourceIDs: [String], on day: Date) async {
        guard !sourceIDs.isEmpty else { return }
        do {
            for sourceID in sourceIDs {
                try await storage.setScheduledSourcePlannedDate(sourceID: sourceID, plannedAt: day)
            }
            scheduledSources = try await storage.loadScheduledSources()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to schedule sources: \(error.localizedDescription)")
        }
    }

    func addSourcesToLearningGoal(goalID: String, sourceIDs: [String]) async {
        let uniqueIDs = orderedUniqueSourceIDs(expandedLearningGoalSourceIDs(sourceIDs))
        guard !uniqueIDs.isEmpty else { return }
        do {
            for sourceID in uniqueIDs {
                try await storage.addSourceToGoal(sourceID: sourceID, goalID: goalID)
            }
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to add sources to schedule: \(error.localizedDescription)")
        }
    }

    func addSourcesToLearningGoal(goalID: String, sourceIDs: [String], plannedFor day: Date) async {
        let uniqueIDs = orderedUniqueSourceIDs(expandedLearningGoalSourceIDs(sourceIDs))
        guard !uniqueIDs.isEmpty else { return }
        do {
            for sourceID in uniqueIDs {
                try await storage.addSourceToGoal(sourceID: sourceID, goalID: goalID, plannedAt: day)
            }
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to add sources to schedule day: \(error.localizedDescription)")
        }
    }

    /// Add sources to a Notebook pool and schedule them on a calendar day in one step.
    /// Ensures MCP context (`learning_goal_items`) and the shared schedule tag stay aligned.
    func addSourcesToNotebookSchedule(goalID: String, sourceIDs: [String], plannedFor day: Date) async {
        let uniqueIDs = orderedUniqueSourceIDs(expandedLearningGoalSourceIDs(sourceIDs))
        guard !uniqueIDs.isEmpty else { return }
        // The notebook these join: the Notebook itself, or a Goal's Notebook,
        // whose pool takes a Goal's additions too (addCompanionSeedSources).
        let goal = notebook(id: goalID)
        let notebookID = goal?.parentNotebookID ?? goal?.id
        let heldBefore = Set(notebookID.flatMap { notebook(id: $0) }?.approvedSourceIDs ?? [])
        do {
            try await storage.addCompanionSeedSources(goalID: goalID, sourceIDs: uniqueIDs)
            for sourceID in uniqueIDs {
                try await storage.addSourceToGoal(sourceID: sourceID, goalID: goalID, plannedAt: day)
            }
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
            // What joined the notebook arrives ticked, as every add does.
            if let notebookID {
                tickArrivingNotebookSources(notebookArrivals(in: notebookID, heldBefore: heldBefore))
            }
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to schedule notebook sources: \(error.localizedDescription)")
        }
    }

    func expandedLearningGoalSourceIDs(_ sourceIDs: [String]) -> [String] {
        sourceIDs.flatMap { sourceID -> [String] in
            if articles.contains(where: { $0.id == sourceID }) {
                return [sourceID]
            }
            let groupSourceIDs = learningGoalSourceIDsForGroup(sourceID)
            return groupSourceIDs.isEmpty ? [sourceID] : groupSourceIDs
        }
    }

    func orderedUniqueSourceIDs(_ sourceIDs: [String]) -> [String] {
        var seen = Set<String>()
        return sourceIDs.filter { seen.insert($0).inserted }
    }

    func learningGoalSourceIDsForGroup(_ groupName: String) -> [String] {
        sourceIDsForGroupInOrder(groupName)
    }

    func sourceIDsForGroupInOrder(_ groupName: String) -> [String] {
        var orderedIDs: [String] = []
        var seen = Set<String>()

        if allCourseGroupNames.contains(groupName) {
            for lecture in courseLectures(for: groupName) {
                for item in courseLectureItems(for: lecture.id) {
                    guard let sourceID = item.sourceId, !seen.contains(sourceID) else { continue }
                    orderedIDs.append(sourceID)
                    seen.insert(sourceID)
                }
            }
        }

        let ownedArticles = (articlesStore.articleIDsByParentGroup[groupName] ?? [])
            .compactMap { articlesById[$0] }
            .sorted(by: learningGoalArticleOrder)
        for article in ownedArticles where !seen.contains(article.id) {
            orderedIDs.append(article.id)
            seen.insert(article.id)
        }

        return orderedIDs
    }

    func bookChapterArticlesInOrder(for groupName: String) -> [StudioArticle] {
        sourceIDsForGroupInOrder(groupName).compactMap { articlesById[$0] }
    }

    func bookChaptersWithReadingProgress(for groupName: String) -> [StudioArticle] {
        bookChapterArticlesInOrder(for: groupName).map { articleWithCurrentReadingProgress($0) }
    }

    /// The chapter the reader should reopen for a book: the furthest chapter
    /// with saved progress, or the first chapter when nothing has been read yet.
    func resumeBookChapter(for groupName: String) -> StudioArticle? {
        let chapters = bookChaptersWithReadingProgress(for: groupName)
        guard !chapters.isEmpty else { return nil }
        return chapters.last(where: \.hasSavedReadingPosition) ?? chapters.first
    }

    func learningGoalArticleOrder(_ lhs: StudioArticle, _ rhs: StudioArticle) -> Bool {
        let lhsGroup = lhs.parentGroup ?? ""
        let rhsGroup = rhs.parentGroup ?? ""
        if lhsGroup != rhsGroup {
            return lhsGroup.localizedStandardCompare(rhsGroup) == .orderedAscending
        }
        if let lhsIndex = lhs.courseSortIndex, let rhsIndex = rhs.courseSortIndex {
            return lhsIndex < rhsIndex
        }
        if lhs.courseSortIndex != nil { return true }
        if rhs.courseSortIndex != nil { return false }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    func markScheduleSourceDone(sourceID: String) async {
        // The checkbox reflects the click immediately; the storage actor can be
        // seconds behind during a CloudKit merge, and the write plus four
        // reloads would gate any visible change.
        applyLocalScheduleCompletion(sourceID: sourceID, completedAt: Date())
        do {
            // Completion is shared across every goal the placement belongs to.
            try await storage.setScheduledSourceCompletion(sourceID: sourceID, isCompleted: true)
            reflectScheduleCompletionReadState(for: [sourceID])
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
            learningGoals = try await storage.loadLearningGoals()
            scheduledSources = try await storage.loadScheduledSources()
            sourceReviewedAt = try await storage.sourceReviewDates()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to mark schedule item done: \(error.localizedDescription)")
            await revertLocalScheduleCompletion()
        }
    }


    /// Optimistic half of mark-done: flip the completion the views read
    /// without waiting on the storage actor.
    private func applyLocalScheduleCompletion(sourceID: String, completedAt: Date?) {
        scheduledSources = scheduledSources.map { entry in
            guard entry.placement.sourceID == sourceID else { return entry }
            var placement = entry.placement
            placement.completedAt = completedAt
            return ScheduledSourceEntry(
                placement: placement,
                goalTags: entry.goalTags,
                goalIDs: entry.goalIDs,
                isAutomatic: entry.isAutomatic,
                activityDays: entry.activityDays
            )
        }
        learningGoals = learningGoals.map { goal in
            var goal = goal
            goal.items = goal.items.map { item in
                guard item.sourceID == sourceID else { return item }
                var item = item
                item.completedAt = completedAt
                return item
            }
            return goal
        }
    }

    /// A failed completion write leaves the optimistic flip wrong; storage is
    /// the truth, so read it back rather than guessing the prior state.
    private func revertLocalScheduleCompletion() async {
        if let goals = try? await storage.loadLearningGoals() {
            learningGoals = goals
        }
        if let sources = try? await storage.loadScheduledSources() {
            scheduledSources = sources
        }
    }

    /// `cascadeChildGoals` deletes a Notebook's nested Goals along with it, and
    /// belongs only to callers that have already told the learner how many
    /// Goals that is.
    func deleteLearningGoal(
        _ goalID: String,
        cascadeChildGoals: Bool = false,
        deleteLinkedChats: Bool = false
    ) async {
        let childGoalIDs = cascadeChildGoals ? goals(inNotebook: goalID).map(\.id) : []
        let deletedGoalIDs = Set([goalID] + childGoalIDs)
        // The same call deletes a Notebook and a Goal, so the toast and the log
        // line take the noun from the record itself rather than assuming one.
        let deletedKind = learningGoals.first(where: { $0.id == goalID })?.isNotebook == true ? "notebook" : "Goal"
        let linkedSessionIDs: Set<String> = Set(reviewSessionLinks.compactMap { session -> String? in
            guard let linkedGoalID = session.goalID,
                  deletedGoalIDs.contains(linkedGoalID) else {
                return nil
            }
            return session.id
        })
        do {
            try await storage.deleteLearningGoal(
                goalID,
                cascadeChildGoals: cascadeChildGoals,
                deleteLinkedChats: deleteLinkedChats
            )
            learningGoals.removeAll { $0.id == goalID || childGoalIDs.contains($0.id) }
            notebookFilesByNotebookID[goalID] = nil
            notebookFilesLastRefreshAt[goalID] = nil
            notebookChatExclusions[goalID] = nil
            notebookChatContextNotebooks[goalID] = nil
            NotebookChatSelection.forget(notebookID: goalID)
            forgetNotebookCollections(of: goalID)
            scheduledSources = try await storage.loadScheduledSources()
            closeNotebookInEveryWindow(goalID)
            if activeNotebookId == goalID {
                activeNotebookId = notebooks.first?.id
            }
            if deleteLinkedChats {
                for sessionID in linkedSessionIDs {
                    reviewSessionExchanges[sessionID] = nil
                }
                reviewTranscriptMatchIDs?.subtract(linkedSessionIDs)
            }
            // A deleted notebook follows no course any more; the courses stay.
            await reloadCourseFollowers()
            await loadReviewSessionLinks()
            showToast("Deleted the \(deletedKind).")
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to delete \(deletedKind): \(error.localizedDescription)")
        }
    }

    /// The Notebooks `goal` can be merged into: the other live Notebooks of the
    /// same library. A team's Notebook never merges into My Library or another
    /// team's, because its records live in that team's zone.
    func mergeCandidates(for goal: LearningGoalRecord) -> [LearningGoalRecord] {
        notebooks.filter { $0.id != goal.id && $0.teamID == goal.teamID }
    }

    /// Folds `notebookID` into `survivorID`: its sources, chats, Goals, tasks,
    /// docs, scheduled tasks, Planner blocks, open questions, notes and files
    /// all land on the survivor, and the merged Notebook is deleted. `title`
    /// renames the survivor when given. Returns whether the merge happened.
    @discardableResult
    func mergeNotebook(_ notebookID: String, into survivorID: String, title: String? = nil) async -> Bool {
        let mergedTitle = learningGoals.first { $0.id == notebookID }?.title ?? "the notebook"
        do {
            let result = try await storage.mergeCompanionGoals(
                notebookIDs: [survivorID, notebookID],
                title: title,
                mergeNotes: true
            )
            learningGoals = try await storage.loadLearningGoals()
            for id in [notebookID, survivorID] {
                notebookFilesByNotebookID[id] = nil
                notebookFilesLastRefreshAt[id] = nil
            }
            notebookTasksByNotebookID[notebookID] = nil
            // The merged notebook's unticked boxes go with it; its sources
            // arrive in the survivor ticked. The context notebooks its chats
            // read stay in for the survivor, which took its links, and a
            // notebook whose chats read it read the survivor.
            notebookChatExclusions[notebookID] = nil
            // Generation 2's merge job unioned the member's NotebookState
            // sets into the survivor's in the store (schema v2 §5.2).
            NotebookStateStore.reload()
            await loadNotebookTasks(notebookID: survivorID)
            scheduledSources = try await storage.loadScheduledSources()
            moveNotebookInEveryWindow(notebookID, to: survivorID)
            if activeNotebookId == notebookID {
                activeNotebookId = survivorID
            }
            await loadReviewSessionLinks()
            await loadArtifacts()
            // The survivor follows every course the merged notebooks followed.
            await reloadCourseFollowers()
            let survivorTitle = learningGoals.first { $0.id == survivorID }?.title ?? "the notebook"
            var parts: [String] = []
            if result.sourcesAdded > 0 { parts.append("\(result.sourcesAdded) source\(result.sourcesAdded == 1 ? "" : "s")") }
            if result.chatsMoved > 0 { parts.append("\(result.chatsMoved) chat\(result.chatsMoved == 1 ? "" : "s")") }
            if result.docsMoved > 0 { parts.append("\(result.docsMoved) page\(result.docsMoved == 1 ? "" : "s")") }
            if result.filesMoved > 0 { parts.append("\(result.filesMoved) file\(result.filesMoved == 1 ? "" : "s")") }
            let detail = parts.isEmpty ? "" : " Moved \(parts.joined(separator: ", "))."
            showToast("Merged \"\(mergedTitle)\" into \"\(survivorTitle)\".\(detail)")
            return true
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to merge notebook: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func deleteReviewSessionLink(_ id: String) async -> Bool {
        // Reflect the destructive action immediately. Storage is actor-isolated,
        // and a large inbound CloudKit merge can legitimately be ahead of this
        // write. Keeping the row visible until that queue drains makes the menu
        // look broken and invites repeated clicks.
        let removedSession = reviewSessionLinks.first { $0.id == id }
        let removedExchanges = reviewSessionExchanges[id]
        reviewSessionLinks.removeAll { $0.id == id }
        reviewSessionExchanges[id] = nil

        do {
            try await storage.deleteReviewSession(id)
        } catch {
            // The durable delete did not happen. Put this row back instead of
            // masking the failure with an optimistic UI that lies about state.
            if let removedSession,
               !reviewSessionLinks.contains(where: { $0.id == id }) {
                reviewSessionLinks.append(removedSession)
            }
            if let removedExchanges {
                reviewSessionExchanges[id] = removedExchanges
            }
            errorMessage = "Could not delete the chat. \(error.localizedDescription)"
            showToast(errorMessage ?? "Could not delete the chat.")
            logger.error("Failed to delete review session link: \(error.localizedDescription)")
            return false
        }
        // Its pin and its unread mark go with it, so neither outlives the
        // chat on any device.
        setChatPinned(id, pinned: false)
        ChatReadMarks.shared.forget(id)

        do {
            sourceReviewedAt = try await storage.sourceReviewDates()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
        } catch {
            // The session is already durably deleted. A derived-state refresh
            // failure must not restore it or report that deletion itself failed.
            errorMessage = "The chat was deleted, but review status could not refresh. \(error.localizedDescription)"
            showToast(errorMessage ?? "The chat was deleted, but review status could not refresh.")
            logger.error("Deleted review session link, but failed to refresh review state: \(error.localizedDescription)")
        }
        return true
    }

    /// Move a chat into a Notebook, or out of any Notebook when `goalID` is nil.
    func moveReviewSession(_ sessionID: String, toNotebook goalID: String?) async {
        // The rail reflects the move immediately; the storage actor can lag
        // behind a CloudKit merge, and the row jumping sections seconds after
        // the menu click read as the action having failed.
        let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID })
        let previous = index.map { reviewSessionLinks[$0].goalID }
        if let index { reviewSessionLinks[index].goalID = goalID }
        do {
            try await storage.updateReviewSessionGoal(sessionID: sessionID, goalID: goalID)
        } catch {
            if let previous, let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID }) {
                reviewSessionLinks[index].goalID = previous
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to move review session to notebook: \(error.localizedDescription)")
        }
    }

    func renameReviewSession(_ sessionID: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID })
        let previous = index.map { reviewSessionLinks[$0].title }
        if let index { reviewSessionLinks[index].title = trimmed }
        do {
            try await storage.updateReviewSessionTitle(sessionID: sessionID, title: trimmed)
        } catch {
            if let previous, let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID }) {
                reviewSessionLinks[index].title = previous
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to rename review session: \(error.localizedDescription)")
        }
    }

    /// Hide a chat from the sidebar, or show it again. Hide is the learner's
    /// view, where Delete is the record's fate (product owner, 2026-09-12: "please
    /// allow me to hide chats as well"): nothing about the chat moves — not
    /// its transcript, its Notebook, its team copies or its place in search
    /// over MCP. The view is the account's, not one Mac's (product owner,
    /// 2026-09-13: hidden items "should be consistent across multiple
    /// macbooks"), so the hide syncs as a record of its own and every Mac
    /// folds the same chats. An open chat stays open; only its row leaves,
    /// and the Hidden fold under Chats lists it again with Show.
    func setReviewSessionHidden(_ sessionID: String, hidden: Bool) async {
        // The row leaves with the click; the write follows. Waiting on the
        // storage actor first left the row visible for as long as a CloudKit
        // merge kept the actor busy.
        let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID })
        let previous = index.map { reviewSessionLinks[$0].hiddenAt }
        if let index {
            if hidden {
                if reviewSessionLinks[index].hiddenAt == nil { reviewSessionLinks[index].hiddenAt = Date() }
            } else {
                reviewSessionLinks[index].hiddenAt = nil
            }
        }
        let title = index.map { reviewSessionLinks[$0].title }.flatMap { $0.isEmpty ? nil : $0 } ?? "chat"
        showToast(
            hidden ? "Hid \(title)" : "Unhid \(title)",
            undo: hidden ? { [weak self] in await self?.setReviewSessionHidden(sessionID, hidden: false) } : nil
        )
        do {
            let hiddenAt = try await storage.setReviewSessionHidden(sessionID: sessionID, hidden: hidden)
            if let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID }) {
                reviewSessionLinks[index].hiddenAt = hidden ? (hiddenAt ?? reviewSessionLinks[index].hiddenAt) : nil
            }
        } catch {
            if let previous, let index = reviewSessionLinks.firstIndex(where: { $0.id == sessionID }) {
                reviewSessionLinks[index].hiddenAt = previous
            }
            errorMessage = error.localizedDescription
            logger.error("Failed to update hidden chat: \(error.localizedDescription)")
        }
    }

    func updateReviewSessionSources(_ sessionID: String, sourceIDs: [String]) async {
        do {
            try await storage.updateReviewSessionSources(sessionID: sessionID, sourceIDs: sourceIDs)
            reviewSessionLinks = try await storage.loadReviewSessionLinks()
            sourceReviewedAt = try await storage.sourceReviewDates()
            learningGoalLinkedSourceIds = try await storage.sourceIdsWithReviewSession()
            learningGoalEligibleSourceIds = try await storage.sourceIdsWithLinkedChatSession()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to update review session sources: \(error.localizedDescription)")
        }
    }

    /// Open the Review Sessions panel filtered to a specific source.
    func showReviewSessionsForSource(_ sourceID: String) {
        reviewSessionFilter = .source(sourceID)
        isChatTabActive = true
        revealReviewSessionSidebar()
        Task { await loadReviewSessionLinks() }
    }

    /// Open the Review Sessions panel filtered to an entire parent group
    /// (a book or course), so sessions linked to any of its items are shown.
    func showReviewSessionsForGroup(_ groupName: String) {
        reviewSessionFilter = .group(groupName)
        isChatTabActive = true
        revealReviewSessionSidebar()
        Task { await loadReviewSessionLinks() }
    }

}
