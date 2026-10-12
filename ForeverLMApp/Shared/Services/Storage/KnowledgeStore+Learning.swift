import Foundation
import SQLite3
import OSLog
import CloudKit

extension KnowledgeStore {

    // MARK: - Learning Companion

    /// Create a proactive daily-quiz goal (kind='companion'). Seed sources are inserted
    /// as approved; discovery and the daily blend are computed later from current state.
    func createCompanionGoal(
        title: String,
        description: String? = nil,
        summary: String? = nil,
        topic: String,
        startAt: Date,
        endAt: Date,
        dailyTarget: Int,
        discoveryEnabled: Bool,
        seedSourceIDs: [String],
        parentNotebookID: String? = nil,
        teamID: String? = nil,
        artifactID: String? = nil,
        id requestedID: String? = nil
    ) throws -> LearningGoalRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw KnowledgeStoreError.invalidData("Learning goal title is required.")
        }
        // The artifact a Goal is for, checked before anything is written so a
        // typo'd id refuses the whole creation rather than half of it.
        let resolvedArtifactID = try Self.resolvedGoalArtifactID(artifactID, load: loadArtifact)
        guard startAt < endAt else {
            throw KnowledgeStoreError.invalidData("Learning goal end date must be after the start date.")
        }
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDescription = trimmedDescription?.isEmpty == false ? trimmedDescription : nil
        let resolvedSummary = Self.normalizedSummary(summary)
        let trimmedParentID = parentNotebookID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedParentID = trimmedParentID?.isEmpty == false ? trimmedParentID : nil
        var resolvedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedTeamID?.isEmpty == true { resolvedTeamID = nil }
        if let resolvedParentID {
            guard let parent = try loadLearningGoal(resolvedParentID), parent.isNotebook else {
                throw KnowledgeStoreError.invalidData("Notebook not found: \(resolvedParentID)")
            }
            // A Goal lives where its Notebook lives.
            resolvedTeamID = parent.teamID
        }
        if let resolvedTeamID {
            guard let team = try loadTeam(resolvedTeamID) else {
                throw KnowledgeStoreError.invalidData("Team not found: \(resolvedTeamID)")
            }
            guard team.canEdit else {
                throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
            }
        }
        // A caller that needs the same record on every device (a team's
        // Assignments Notebook) names the id; everything else gets a new one.
        let id = requestedID ?? UUID().uuidString
        let now = Date()
        let uniqueSourceIDs = Array(dictUnique(seedSourceIDs))

        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind, description, topic, discovery_enabled, daily_target, parent_notebook_id, team_id, summary, artifact_id)
                VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { stmt in
                bind(stmt, 1, id)
                bind(stmt, 2, trimmedTitle)
                sqlite3_bind_double(stmt, 3, startAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 4, endAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 5, now.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 6, now.timeIntervalSinceReferenceDate)
                bind(stmt, 7, LearningGoalRecord.companionKind)
                bind(stmt, 8, resolvedDescription)
                bind(stmt, 9, trimmedTopic)
                sqlite3_bind_int64(stmt, 10, discoveryEnabled ? 1 : 0)
                sqlite3_bind_int64(stmt, 11, Int64(max(1, dailyTarget)))
                bind(stmt, 12, resolvedParentID)
                bind(stmt, 13, resolvedTeamID)
                bind(stmt, 14, resolvedSummary)
                bind(stmt, 15, resolvedArtifactID)
            }
            for sourceID in uniqueSourceIDs {
                try insertLearningGoalItem(
                    goalID: id,
                    sourceID: sourceID,
                    addedAt: now,
                    origin: LearningGoalItemOrigin.seed.rawValue,
                    reviewState: LearningGoalItemReviewState.approved.rawValue
                )
            }
            try keepNotebookRowsForGeneration2(goalIDs: [id])
            try markRecordChanged(entity: .learningGoal, logicalKey: id)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        // A Goal's approved sources are always part of its parent Notebook's source
        // pool as well. Keep that ownership invariant in storage so every caller
        // (app, MCP, tests, and future importers) gets the same behavior.
        if let resolvedParentID, !uniqueSourceIDs.isEmpty {
            _ = try addCompanionSeedSources(goalID: resolvedParentID, sourceIDs: uniqueSourceIDs)
        }

        guard let goal = try loadLearningGoal(id) else {
            throw KnowledgeStoreError.invalidData("Companion goal could not be loaded after creation.")
        }
        return goal
    }

    /// Update a companion goal's user-editable settings (title, topic, deadline, daily
    /// target, discovery). Items, gaps, and quiz state are untouched.
    func updateCompanionGoalSettings(
        goalID: String,
        title: String,
        description: String? = nil,
        topic: String,
        endAt: Date,
        dailyTarget: Int,
        discoveryEnabled: Bool
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw KnowledgeStoreError.invalidData("Learning goal title is required.")
        }
        guard let goal = try loadLearningGoal(goalID), goal.isCompanion else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }
        guard goal.startAt < endAt else {
            throw KnowledgeStoreError.invalidData("Learning goal end date must be after the start date.")
        }
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDescription = trimmedDescription?.isEmpty == false ? trimmedDescription : nil
        try execBind("""
            UPDATE learning_goals
            SET title = ?, description = ?, topic = ?, end_at = ?, daily_target = ?, discovery_enabled = ?, updated_at = ?
            WHERE id = ?
        """) { stmt in
            bind(stmt, 1, trimmedTitle)
            bind(stmt, 2, resolvedDescription)
            bind(stmt, 3, trimmedTopic.isEmpty ? trimmedTitle : trimmedTopic)
            sqlite3_bind_double(stmt, 4, endAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 5, Int64(max(1, dailyTarget)))
            sqlite3_bind_int64(stmt, 6, discoveryEnabled ? 1 : 0)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 8, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
    }

    /// The shared placement for a source, if it has one. Global by design:
    /// `scheduled_sources.source_id` is UNIQUE, so a source sits on the calendar
    /// once regardless of how many goals tag it.
    ///
    /// Under generation 2 the placement is kept on the source's wire id, so a
    /// team copy finds the personal copy's (§3.5.21).
    func scheduledPlacement(forSource sourceID: String) throws -> ScheduledSource? {
        var placement: ScheduledSource?
        let keys = try personalStateSourceKeys(sourceID)
        try queryBind("""
            SELECT id, source_id, planned_at, added_at, completed_at, created_at, updated_at
            FROM scheduled_sources
            WHERE source_id IN (\(Array(repeating: "?", count: keys.count).joined(separator: ", ")))
        """, bind: { stmt in
            for (offset, key) in keys.enumerated() { bind(stmt, offset + 1, key) }
        }) { stmt in
            placement = self.readScheduledSourceRow(stmt)
        }
        return placement
    }

    /// This goal's shared placements, keyed by source ID.
    func scheduledPlacementsByGoal(goalID: String) throws -> [String: ScheduledSource] {
        var result: [String: ScheduledSource] = [:]
        for entry in try loadScheduledSources(goalID: goalID) {
            result[entry.placement.sourceID] = entry.placement
        }
        return result
    }

    /// Set a Notebook's or Goal's lifecycle state (`active` / `done` / `archived`).
    /// Kept separate from `updateCompanionGoalSettings` so marking a Goal done
    /// never rewrites its title, topic, deadline, or discovery settings.
    func setLearningGoalStatus(goalID: String, status: LearningGoalStatus) throws {
        guard let goal = try loadLearningGoal(goalID), goal.isCompanion else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }
        try execBind("""
            UPDATE learning_goals SET status = ?, updated_at = ? WHERE id = ?
        """) { stmt in
            bind(stmt, 1, status.rawValue)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
    }

    /// Move a Goal's deadline and nothing else — the Goals tab's **Change
    /// deadline** (product owner, 2026-09-20: "pls let me change the timeline for
    /// each goal"). `update_learning_goal`'s `end_date` arrives through
    /// `updateCompanionGoalSettings`, which rewrites the settings row whole;
    /// this touches `end_at` alone. A Notebook has no deadline to move, and an
    /// end before the start is refused, as it is there.
    func setLearningGoalDeadline(goalID: String, endAt: Date) throws {
        guard let goal = try loadLearningGoal(goalID), goal.isGoal else {
            throw KnowledgeStoreError.invalidData("Timebound Goal not found: \(goalID)")
        }
        guard goal.startAt < endAt else {
            throw KnowledgeStoreError.invalidData("Learning goal end date must be after the start date.")
        }
        let now = Date()
        try execBind("UPDATE learning_goals SET end_at = ?, updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, endAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: now)
    }

    /// Tag a Goal to a Notebook, move it to another one, or untag it entirely
    /// by passing nil. A Goal's identity is its deadline, not its Notebook, so
    /// standing alone is an ordinary state and not a broken one. A top-level
    /// Notebook is still never accepted as the Goal being tagged.
    func setLearningGoalParentNotebook(goalID: String, parentNotebookID: String?) throws {
        guard let goal = try loadLearningGoal(goalID), goal.isGoal else {
            throw KnowledgeStoreError.invalidData("Timebound Goal not found: \(goalID)")
        }
        let trimmed = (parentNotebookID?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        guard let trimmed else {
            // Untag. The sources the Goal already holds are its own and stay;
            // only the Notebook it pointed at is cleared.
            try clearLearningGoalParentNotebook(goalID: goal.id)
            return
        }
        guard trimmed != goalID else {
            throw KnowledgeStoreError.invalidData("A Goal cannot be its own Notebook.")
        }
        guard let parent = try loadLearningGoal(trimmed), parent.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(trimmed)")
        }
        // Seed the destination first. If the subsequent relationship write fails,
        // the Notebook merely has an extra reusable source; the inverse ordering
        // could persist a Goal whose sources are absent from its parent.
        if !goal.approvedSourceIDs.isEmpty {
            _ = try addCompanionSeedSources(goalID: parent.id, sourceIDs: goal.approvedSourceIDs)
        }
        try execBind("""
            UPDATE learning_goals SET parent_notebook_id = ?, updated_at = ? WHERE id = ?
        """) { stmt in
            bind(stmt, 1, parent.id)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
    }

    /// Clear a Goal's Notebook tag, leaving the Goal and everything it holds in
    /// place. Separate from the tagging path above so the untag never reaches
    /// the seed-sources write that moving to a Notebook performs.
    func clearLearningGoalParentNotebook(goalID: String) throws {
        try execBind("""
            UPDATE learning_goals SET parent_notebook_id = NULL, updated_at = ? WHERE id = ?
        """) { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSinceReferenceDate)
            bind(stmt, 2, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
    }

    /// Split a companion goal into one or more child notebooks by moving sources (and
    /// linked open questions) out of the parent pool. Sources move — they are not copied.
    ///
    /// The children live where the parent lives: a team's Notebook splits into
    /// that team, in its zone, and a Goal's children name the Goal's Notebook.
    /// When `keepParent` is false and the parent is left with no sources, the
    /// parent is removed — but only after everything else it held (its chats,
    /// nested Goals, tasks, Docs, courses, open questions, Ideas' links,
    /// Directions and the rest, `moveNotebookContentsInTransaction`) has moved
    /// to the child that took the most sources (the first, on a tie), which
    /// the result names as `heirGoalID`, and its own words (synthesis notes,
    /// Instructions, research questions, summary, repository) are folded into
    /// that child by a merge's rule (`foldNotebookWordsInTransaction`). Before
    /// 2026-10-02 the parent went by a raw DELETE and all of that was left
    /// pointing at an id that was gone, or went with the row.
    func splitCompanionGoal(
        sourceGoalID: String,
        splits: [CompanionGoalSplitSpec],
        keepParent: Bool = true
    ) throws -> CompanionGoalSplitResult {
        guard !splits.isEmpty else {
            throw KnowledgeStoreError.invalidData("At least one split is required.")
        }
        guard let parent = try loadLearningGoal(sourceGoalID), parent.isCompanion else {
            throw KnowledgeStoreError.invalidData("Companion goal not found: \(sourceGoalID)")
        }
        if let teamID = parent.teamID {
            guard let team = try loadTeam(teamID) else {
                throw KnowledgeStoreError.invalidData("Team not found: \(teamID)")
            }
            guard team.canEdit else {
                throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
            }
        }

        let parentItemsBySourceID = Dictionary(uniqueKeysWithValues: parent.items.map { ($0.sourceID, $0) })
        let parentSourceIDs = Set(parentItemsBySourceID.keys)
        let parentGaps = try loadLearningGoalGaps(goalID: sourceGoalID)
        let parentGapIDs = Set(parentGaps.map(\.id))

        var assignedSources = Set<String>()
        var assignedGaps = Set<String>()
        var normalizedSplits: [CompanionGoalSplitSpec] = []

        for split in splits {
            let title = split.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw KnowledgeStoreError.invalidData("Each split needs a non-empty title.")
            }
            let sourceIDs = dictUnique(split.sourceIDs.filter { !$0.isEmpty })
            guard !sourceIDs.isEmpty else {
                throw KnowledgeStoreError.invalidData("Split \"\(title)\" must include at least one source_id.")
            }
            for sourceID in sourceIDs {
                guard parentSourceIDs.contains(sourceID) else {
                    throw KnowledgeStoreError.invalidData("source_id \(sourceID) is not in notebook \(sourceGoalID).")
                }
                guard assignedSources.insert(sourceID).inserted else {
                    throw KnowledgeStoreError.invalidData("source_id \(sourceID) appears in more than one split.")
                }
            }
            let gapIDs = dictUnique(split.gapIDs.filter { !$0.isEmpty })
            for gapID in gapIDs {
                guard parentGapIDs.contains(gapID) else {
                    throw KnowledgeStoreError.invalidData("gap_id \(gapID) is not in notebook \(sourceGoalID).")
                }
                guard assignedGaps.insert(gapID).inserted else {
                    throw KnowledgeStoreError.invalidData("gap_id \(gapID) appears in more than one split.")
                }
            }
            let topic = split.topic?.trimmingCharacters(in: .whitespacesAndNewlines)
            normalizedSplits.append(
                CompanionGoalSplitSpec(
                    title: title,
                    topic: topic?.isEmpty == false ? topic : nil,
                    sourceIDs: sourceIDs,
                    gapIDs: gapIDs
                )
            )
        }

        // Generation 2: the split job, which keeps an emptied parent as a stub leading to its heir
        // (schema v2 §5.2). Generation 1 goes on as build 177 does.
        if syncGeneration == .two {
            return try splitNotebookUnderGeneration2(parentID: sourceGoalID, splits: normalizedSplits, keepParent: keepParent)
        }

        let now = Date()
        var childGoalIDs: [String] = []
        var sourcesTaken: [String: Int] = [:]
        var shouldDeleteParent = false
        var heirGoalID: String?

        try exec("BEGIN IMMEDIATE")
        do {
            for split in normalizedSplits {
                let childID = UUID().uuidString
                let childTopic = split.topic ?? split.title
                try execBind("""
                    INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind, topic, discovery_enabled, daily_target, parent_notebook_id, team_id)
                    VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    bind(stmt, 1, childID)
                    bind(stmt, 2, split.title)
                    sqlite3_bind_double(stmt, 3, parent.startAt.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(stmt, 4, parent.endAt.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(stmt, 5, now.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(stmt, 6, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 7, LearningGoalRecord.companionKind)
                    bind(stmt, 8, childTopic)
                    sqlite3_bind_int64(stmt, 9, (parent.discoveryEnabled ?? false) ? 1 : 0)
                    sqlite3_bind_int64(stmt, 10, Int64(max(1, parent.dailyTarget ?? 3)))
                    // Where the parent lives: its Notebook (for a Goal) and its
                    // team, whose zone `markRecordChanged` files the child in.
                    bind(stmt, 11, parent.parentNotebookID)
                    bind(stmt, 12, parent.teamID)
                }

                let splitSourceSet = Set(split.sourceIDs)
                for sourceID in split.sourceIDs {
                    guard let item = parentItemsBySourceID[sourceID] else { continue }
                    try deleteCompanionGoalItem(goalID: sourceGoalID, sourceID: sourceID)
                    let moved = reassignedCompanionGoalItem(item, goalID: childID)
                    try saveLearningGoalItem(moved, goalID: childID)
                    sourcesTaken[childID, default: 0] += 1
                }

                var gapIDsToMove = Set(split.gapIDs)
                for gap in parentGaps where gapIDsToMove.contains(gap.id)
                    || (gap.sourceID.map { splitSourceSet.contains($0) } ?? false) {
                    gapIDsToMove.insert(gap.id)
                }
                for gapID in gapIDsToMove {
                    try execBind("""
                        UPDATE learning_goal_gaps
                        SET goal_id = ?
                        WHERE id = ? AND goal_id = ?
                    """) { stmt in
                        bind(stmt, 1, childID)
                        bind(stmt, 2, gapID)
                        bind(stmt, 3, sourceGoalID)
                    }
                }

                try touchLearningGoal(childID, at: now)
                childGoalIDs.append(childID)
            }

            // The child records are queued before anything is moved onto
            // them, so the heir is a record the sync queue already knows.
            for childID in childGoalIDs {
                try markRecordChanged(entity: .learningGoal, logicalKey: childID, at: now)
            }

            let remainingSources = try learningGoalSourceIDSet(goalID: sourceGoalID)
            shouldDeleteParent = !keepParent && remainingSources.isEmpty
            if shouldDeleteParent {
                // The heir is the child that took the most sources. `max(by:)`
                // replaces its pick only on a strictly larger count, so of
                // equals the first split listed wins.
                let heir = childGoalIDs.max { (sourcesTaken[$0] ?? 0) < (sourcesTaken[$1] ?? 0) }
                guard let heir else {
                    throw KnowledgeStoreError.invalidData("Split produced no child to take the parent's place.")
                }
                heirGoalID = heir
                _ = try moveNotebookContentsInTransaction(from: sourceGoalID, to: heir, at: now)
                // The parent's own words are columns of the row about to go:
                // its notes, Instructions, research questions, summary and
                // repository fold into the heir by the merge rule (the heir,
                // new, has none of its own) before the row is deleted.
                guard let heirRecord = try loadLearningGoal(heir) else {
                    throw KnowledgeStoreError.invalidData("Split child not found: \(heir)")
                }
                try foldNotebookWordsInTransaction(into: heirRecord, from: [parent], at: now)
                try touchLearningGoal(heir, at: now)
                try markRecordChanged(entity: .learningGoal, logicalKey: heir, at: now)
                // The ordinary delete of the emptied row: its placements, its
                // Directions and its CloudKit tombstone, in this transaction.
                try deleteLearningGoalRowInTransaction(sourceGoalID, at: now)
            } else {
                try touchLearningGoal(sourceGoalID, at: now)
                try markRecordChanged(entity: .learningGoal, logicalKey: sourceGoalID, at: now)
            }
            try keepNotebookRowsForGeneration2(goalIDs: childGoalIDs + (shouldDeleteParent ? [] : [sourceGoalID]))
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return CompanionGoalSplitResult(
            parentGoalID: shouldDeleteParent ? nil : sourceGoalID,
            childGoalIDs: childGoalIDs,
            heirGoalID: heirGoalID
        )
    }

    /// Merge Notebooks into the first notebook ID (survivor). Everything the other
    /// Notebooks hold follows: the source pools are unioned, the chats, nested
    /// Goals, tasks, Docs, scheduled tasks, Schedule placements, Planner blocks
    /// and bouts, memory items, journal matches and related-Notebook links are
    /// re-pointed at the survivor, open questions are deduped by summary,
    /// research questions unioned and synthesis notes concatenated. The merged
    /// Notebooks are then deleted. Notebook files live on disk; the caller moves
    /// the workspace folder, because the store only indexes it.
    ///
    /// Every Notebook must be in the same library — My Library or one team —
    /// because a team's records live in its own CloudKit zone, and a merge is
    /// never the way a record changes zone.
    func mergeCompanionGoals(
        notebookIDs: [String],
        title: String? = nil,
        mergeNotes: Bool = true
    ) throws -> CompanionGoalMergeResult {
        let uniqueIDs = dictUnique(notebookIDs.filter { !$0.isEmpty })
        guard uniqueIDs.count >= 2 else {
            throw KnowledgeStoreError.invalidData("merge_notebooks requires at least two distinct notebook_ids.")
        }

        var goals: [LearningGoalRecord] = []
        for id in uniqueIDs {
            guard let goal = try loadLearningGoal(id), goal.isCompanion else {
                throw KnowledgeStoreError.invalidData("Companion goal not found: \(id)")
            }
            guard goal.isNotebook else {
                throw KnowledgeStoreError.invalidData(
                    "\"\(goal.title)\" is a Goal inside a Notebook, not a Notebook. Merge the Notebook it belongs to."
                )
            }
            goals.append(goal)
        }

        let survivorID = uniqueIDs[0]
        guard let survivor = goals.first else {
            throw KnowledgeStoreError.invalidData("Survivor notebook could not be loaded.")
        }
        let mergees = Array(goals.dropFirst())
        if let stranger = mergees.first(where: { $0.teamID != survivor.teamID }) {
            throw KnowledgeStoreError.invalidData(
                "\"\(stranger.title)\" and \"\(survivor.title)\" are in different libraries. Move them into the same library before merging."
            )
        }
        // Generation 2: the merge job, which keeps each merged notebook as a stub leading to the
        // survivor (schema v2 §5.2). Generation 1 goes on as build 177 does.
        if syncGeneration == .two {
            let renamed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return try mergeNotebooksUnderGeneration2(
                survivorID: survivorID, mergeeIDs: mergees.map(\.id), title: renamed?.isEmpty == false ? renamed : nil, mergeNotes: mergeNotes
            )
        }
        let now = Date()

        var moved = NotebookContentsMove()

        try exec("BEGIN IMMEDIATE")
        do {
            for mergee in mergees {
                moved.add(try moveNotebookContentsInTransaction(from: mergee.id, to: survivorID, at: now))

                // The ordinary delete of the emptied row: what is left of its
                // pool (a source or open question the survivor already had),
                // its placements, its Directions and its CloudKit tombstone.
                // Until 2026-10-02 this was a raw DELETE that skipped the
                // Directions and left Ideas' links on the merged id.
                try deleteLearningGoalRowInTransaction(mergee.id, at: now)
            }

            let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = (resolvedTitle?.isEmpty == false ? resolvedTitle : nil) ?? survivor.title
            try foldNotebookWordsInTransaction(
                into: survivor,
                from: mergees,
                title: finalTitle,
                mergeNotes: mergeNotes,
                at: now
            )
            try touchLearningGoal(survivorID, at: now)
            try markRecordChanged(entity: .learningGoal, logicalKey: survivorID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }

        return CompanionGoalMergeResult(
            survivorGoalID: survivorID,
            mergedGoalIDs: mergees.map(\.id),
            sourcesAdded: moved.sourcesAdded,
            gapsAdded: moved.gapsAdded,
            chatsMoved: moved.chatsMoved,
            childGoalsMoved: moved.childGoalsMoved,
            tasksMoved: moved.tasksMoved,
            docsMoved: moved.docsMoved
        )
    }

    // MARK: A removed notebook's own words

    /// Writes the words of the notebooks in `folded` onto `target`, the
    /// notebook that takes their place, inside the caller's transaction: what
    /// a merge does for its survivor, and what a split that removes its
    /// parent does for the heir. These are columns of the removed notebook's
    /// own row, which `moveNotebookContentsInTransaction` (what points at a
    /// notebook by id) never carries and the row's delete would take with it.
    ///
    /// - The target's own words win: a folded notebook only fills a field the
    ///   target left blank (its standing Instructions `description`, its
    ///   summary, its repository).
    /// - Research questions are unioned, trimmed, case-insensitively, the
    ///   target's first.
    /// - Synthesis notes are concatenated, each under `## <title>` of the
    ///   notebook that wrote them, the target's first; `mergeNotes` false
    ///   keeps only the target's.
    ///
    /// `title` renames the target (nil keeps its own). The caller touches the
    /// target and marks it changed. `target` and `folded` are the records as
    /// they were read; nothing else in a merge or a split writes these
    /// columns.
    private func foldNotebookWordsInTransaction(
        into target: LearningGoalRecord,
        from folded: [LearningGoalRecord],
        title: String? = nil,
        mergeNotes: Bool = true,
        at now: Date
    ) throws {
        func isBlank(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        var notesSections: [String] = []
        if mergeNotes {
            for notebook in [target] + folded {
                guard let notes = notebook.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !notes.isEmpty else { continue }
                notesSections.append("## \(notebook.title)\n\n\(notes)")
            }
        }
        var researchQuestions = target.researchQuestions ?? []
        var description = target.description
        var summary = target.summary
        var repository = target.repository
        for notebook in folded {
            for question in notebook.researchQuestions ?? [] {
                let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !researchQuestions.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                    continue
                }
                researchQuestions.append(trimmed)
            }
            if isBlank(description), !isBlank(notebook.description) { description = notebook.description }
            if isBlank(summary), !isBlank(notebook.summary) { summary = notebook.summary }
            if isBlank(repository), !isBlank(notebook.repository) { repository = notebook.repository }
        }

        let notes = notesSections.isEmpty ? target.notes : notesSections.joined(separator: "\n\n")
        let researchQuestionsJSON: String? = researchQuestions.isEmpty
            ? target.researchQuestions.map { _ in "[]" }
            : jsonString(from: researchQuestions)
        try execBind("""
            UPDATE learning_goals
            SET title = ?, notes = ?, description = ?, summary = ?, repository = ?,
                research_questions = ?, updated_at = ?
            WHERE id = ?
        """) { stmt in
            bind(stmt, 1, title ?? target.title)
            bind(stmt, 2, notes)
            bind(stmt, 3, description)
            bind(stmt, 4, summary)
            bind(stmt, 5, repository)
            bind(stmt, 6, researchQuestionsJSON)
            sqlite3_bind_double(stmt, 7, now.timeIntervalSinceReferenceDate)
            bind(stmt, 8, target.id)
        }
        try keepNotebookRowsForGeneration2(goalIDs: [target.id])
    }

    // MARK: Moving a notebook's contents

    /// What one notebook handed another: the counts a merge reports.
    struct NotebookContentsMove: Equatable, Sendable {
        var sourcesAdded = 0
        var gapsAdded = 0
        var chatsMoved = 0
        var childGoalsMoved = 0
        var tasksMoved = 0
        var docsMoved = 0

        mutating func add(_ other: NotebookContentsMove) {
            sourcesAdded += other.sourcesAdded
            gapsAdded += other.gapsAdded
            chatsMoved += other.chatsMoved
            childGoalsMoved += other.childGoalsMoved
            tasksMoved += other.tasksMoved
            docsMoved += other.docsMoved
        }
    }

    /// Moves everything that belongs to the notebook `fromID` into the
    /// notebook `toID`, inside the caller's transaction: what a merge does to
    /// each merged Notebook, and what a split that removes its parent does to
    /// the parent. The one list of what a notebook holds by id, so merging
    /// and splitting can never strand a different set of records:
    ///
    /// - its pool: sources (a source both hold is kept once, its better
    ///   review state kept), open questions (one whose summary the target
    ///   already has stays behind and goes with the row) and course links;
    /// - chats (`review_sessions.goal_id`), nested Goals
    ///   (`parent_notebook_id`), tasks, Docs (home and links), courses' home,
    ///   scheduled tasks, Schedule placements' tags, Planner blocks and bouts,
    ///   Memory items, journal verdicts, related-Notebook links both ways,
    ///   Ideas' links and Directions.
    ///
    /// Every synced record it re-points is queued for CloudKit in the same
    /// transaction, so another device learns the move as it would an edit.
    /// Both notebooks are in one library (a merge refuses otherwise, and a
    /// split's children take the parent's team), so no record changes zone.
    /// The caller then removes the emptied row through
    /// `deleteLearningGoalRowInTransaction`, the ordinary delete, which finds
    /// nothing of this left to clear.
    @discardableResult
    func moveNotebookContentsInTransaction(from fromID: String, to toID: String, at now: Date) throws -> NotebookContentsMove {
        guard fromID != toID else {
            throw KnowledgeStoreError.invalidData("A notebook cannot move its contents into itself.")
        }
        guard let target = try loadLearningGoal(toID), target.isCompanion else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(toID)")
        }
        var moved = NotebookContentsMove()
        moved.sourcesAdded = try movePoolItems(from: fromID, to: toID)
        moved.gapsAdded = try moveOpenQuestions(from: fromID, to: toID)
        try execBind("""
            INSERT OR IGNORE INTO notebook_course_links (goal_id, course_id)
            SELECT ?, course_id
            FROM notebook_course_links
            WHERE goal_id = ?
        """) { stmt in
            bind(stmt, 1, toID)
            bind(stmt, 2, fromID)
        }
        moved.chatsMoved = try moveReviewSessions(fromGoal: fromID, toGoal: toID, at: now)
        moved.childGoalsMoved = try moveChildGoals(fromNotebook: fromID, toNotebook: toID, at: now)
        moved.tasksMoved = try moveNotebookTasks(fromNotebook: fromID, toNotebook: toID, teamID: target.teamID, at: now)
        moved.docsMoved = try moveArtifactNotebookLinks(fromNotebook: fromID, toNotebook: toID, at: now)
        try moveScheduledTasks(fromNotebook: fromID, toNotebook: toID, at: now)
        try moveSchedulePlacementGoals(fromGoal: fromID, toGoal: toID, at: now)
        try movePlannerRecords(fromNotebook: fromID, toNotebook: toID, at: now)
        try moveMemoryItems(fromGoal: fromID, toGoal: toID, at: now)
        try moveJournalWatchRecords(fromNotebook: fromID, toNotebook: toID)
        try moveRelatedNotebookLinks(fromNotebook: fromID, toNotebook: toID, at: now)
        try moveIdeaLinks(fromNotebook: fromID, toNotebook: toID, kind: target.isGoal ? .goal : .notebook, at: now)
        try moveResearchDirections(
            fromHome: fromID,
            toHome: toID,
            homeKind: target.isGoal ? .goal : .notebook,
            at: now
        )
        try keepNotebookRowsForGeneration2(goalIDs: [toID])
        return moved
    }

    // Each helper below runs inside the caller's transaction and republishes
    // every synced record it re-points. Ids are collected before the UPDATE:
    // the rows are what the sync queue needs, and a count alone could not
    // name them.

    /// The pool rows: a source only the old notebook held moves; a source both
    /// hold is kept once, with the better review state of the two.
    private func movePoolItems(from fromID: String, to toID: String) throws -> Int {
        var targetItems = Dictionary(
            try loadLearningGoalItems(goalID: toID).map { ($0.sourceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var added = 0
        for item in try loadLearningGoalItems(goalID: fromID) {
            try deleteCompanionGoalItem(goalID: fromID, sourceID: item.sourceID)
            let kept: LearningGoalItem
            if let existing = targetItems[item.sourceID] {
                kept = reassignedCompanionGoalItem(preferredCompanionGoalItem(existing, item), goalID: toID)
                try deleteCompanionGoalItem(goalID: toID, sourceID: item.sourceID)
            } else {
                kept = reassignedCompanionGoalItem(item, goalID: toID)
                added += 1
            }
            try saveLearningGoalItem(kept, goalID: toID)
            targetItems[item.sourceID] = kept
        }
        return added
    }

    /// Open questions, deduped by summary: one the target already asks stays
    /// on the old row and goes with it.
    private func moveOpenQuestions(from fromID: String, to toID: String) throws -> Int {
        var summaries = Set(try loadLearningGoalGaps(goalID: toID).map { normalizedCompanionGapSummary($0.summary) })
        var moved = 0
        for gap in try loadLearningGoalGaps(goalID: fromID) {
            guard summaries.insert(normalizedCompanionGapSummary(gap.summary)).inserted else { continue }
            try execBind("UPDATE learning_goal_gaps SET goal_id = ? WHERE id = ? AND goal_id = ?") { stmt in
                bind(stmt, 1, toID)
                bind(stmt, 2, gap.id)
                bind(stmt, 3, fromID)
            }
            moved += 1
        }
        return moved
    }

    private func idsWhere(_ sql: String, _ value: String) throws -> [String] {
        var ids: [String] = []
        try queryBind(sql, bind: { stmt in bind(stmt, 1, value) }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    private func moveReviewSessions(fromGoal mergeeID: String, toGoal survivorID: String, at now: Date) throws -> Int {
        let sessionIDs = try idsWhere("SELECT id FROM review_sessions WHERE goal_id = ? ORDER BY id", mergeeID)
        guard !sessionIDs.isEmpty else { return 0 }
        try execBind("UPDATE review_sessions SET goal_id = ? WHERE goal_id = ?") { stmt in
            bind(stmt, 1, survivorID)
            bind(stmt, 2, mergeeID)
        }
        for sessionID in sessionIDs {
            try markRecordChanged(entity: .reviewSession, logicalKey: sessionID, at: now)
        }
        return sessionIDs.count
    }

    private func moveChildGoals(fromNotebook mergeeID: String, toNotebook survivorID: String, at now: Date) throws -> Int {
        let childIDs = try childGoalIDs(ofNotebook: mergeeID)
        guard !childIDs.isEmpty else { return 0 }
        try execBind("""
            UPDATE learning_goals SET parent_notebook_id = ?, updated_at = ? WHERE parent_notebook_id = ?
        """) { stmt in
            bind(stmt, 1, survivorID)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, mergeeID)
        }
        for childID in childIDs {
            try markRecordChanged(entity: .learningGoal, logicalKey: childID, at: now)
        }
        return childIDs.count
    }

    private func moveNotebookTasks(
        fromNotebook mergeeID: String,
        toNotebook survivorID: String,
        teamID: String?,
        at now: Date
    ) throws -> Int {
        let taskIDs = try idsWhere("SELECT id FROM notebook_tasks WHERE notebook_id = ? ORDER BY id", mergeeID)
        guard !taskIDs.isEmpty else { return 0 }
        try execBind("""
            UPDATE notebook_tasks SET notebook_id = ?, team_id = ?, updated_at = ? WHERE notebook_id = ?
        """) { stmt in
            bind(stmt, 1, survivorID)
            bind(stmt, 2, teamID)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSinceReferenceDate)
            bind(stmt, 4, mergeeID)
        }
        for taskID in taskIDs {
            try markRecordChanged(entity: .notebookTask, logicalKey: taskID, at: now)
        }
        return taskIDs.count
    }

    /// A Doc filed under the merged Notebook is filed under the survivor; a Doc
    /// linked to it is linked to the survivor, once, whichever way it got there.
    private func moveArtifactNotebookLinks(fromNotebook mergeeID: String, toNotebook survivorID: String, at now: Date) throws -> Int {
        var artifactIDs: [String] = []
        try queryBind("""
            SELECT id FROM global_artifacts WHERE home_notebook_id = ?
            UNION
            SELECT artifact_id FROM global_artifact_notebook_links WHERE notebook_id = ?
            """, bind: { stmt in
                bind(stmt, 1, mergeeID)
                bind(stmt, 2, mergeeID)
            }) { stmt in
                if let id = self.string(stmt, 0) { artifactIDs.append(id) }
            }
        guard !artifactIDs.isEmpty else { return 0 }
        try execBind("UPDATE global_artifacts SET home_notebook_id = ? WHERE home_notebook_id = ?") { stmt in
            bind(stmt, 1, survivorID)
            bind(stmt, 2, mergeeID)
        }
        try execBind("""
            INSERT OR IGNORE INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at)
            SELECT artifact_id, ?, linked_at FROM global_artifact_notebook_links WHERE notebook_id = ?
        """) { stmt in
            bind(stmt, 1, survivorID)
            bind(stmt, 2, mergeeID)
        }
        try execBind("DELETE FROM global_artifact_notebook_links WHERE notebook_id = ?") { stmt in
            bind(stmt, 1, mergeeID)
        }
        for artifactID in artifactIDs {
            try execBind("UPDATE global_artifacts SET updated_at = ? WHERE id = ?") { stmt in
                sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
                bind(stmt, 2, artifactID)
            }
            try markRecordChanged(entity: .artifact, logicalKey: artifactID, at: now)
        }
        return artifactIDs.count
    }

    private func moveScheduledTasks(fromNotebook mergeeID: String, toNotebook survivorID: String, at now: Date) throws {
        let taskIDs = try idsWhere("SELECT id FROM scheduled_tasks WHERE notebook_id = ? ORDER BY id", mergeeID)
        guard !taskIDs.isEmpty else { return }
        try execBind("UPDATE scheduled_tasks SET notebook_id = ?, updated_at = ? WHERE notebook_id = ?") { stmt in
            bind(stmt, 1, survivorID)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, mergeeID)
        }
        for taskID in taskIDs {
            try markRecordChanged(entity: .scheduledTask, logicalKey: taskID, at: now)
        }
    }

    /// A Schedule placement tagged with the merged Notebook is tagged with the
    /// survivor instead; one already tagged with both simply loses the old tag.
    private func moveSchedulePlacementGoals(fromGoal mergeeID: String, toGoal survivorID: String, at now: Date) throws {
        let placementIDs = try idsWhere(
            "SELECT scheduled_source_id FROM scheduled_source_goals WHERE goal_id = ? ORDER BY scheduled_source_id",
            mergeeID
        )
        guard !placementIDs.isEmpty else { return }
        try execBind("""
            INSERT OR IGNORE INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at)
            SELECT scheduled_source_id, ?, added_at FROM scheduled_source_goals WHERE goal_id = ?
        """) { stmt in
            bind(stmt, 1, survivorID)
            bind(stmt, 2, mergeeID)
        }
        try execBind("DELETE FROM scheduled_source_goals WHERE goal_id = ?") { stmt in
            bind(stmt, 1, mergeeID)
        }
        for placementID in placementIDs {
            try markRecordChanged(entity: .scheduledSource, logicalKey: placementID, at: now)
        }
    }

    /// Planner blocks and bouts travel inside their day's plan record, so the
    /// day is what gets republished.
    private func movePlannerRecords(fromNotebook mergeeID: String, toNotebook survivorID: String, at now: Date) throws {
        var dayPlanIDs = Set<String>()
        try queryBind("""
            SELECT day_plan_id FROM time_blocks WHERE notebook_id = ? OR goal_id = ?
            UNION
            SELECT day_plan_id FROM learning_bouts WHERE notebook_id = ?
            """, bind: { stmt in
                bind(stmt, 1, mergeeID)
                bind(stmt, 2, mergeeID)
                bind(stmt, 3, mergeeID)
            }) { stmt in
                if let id = self.string(stmt, 0) { dayPlanIDs.insert(id) }
            }
        guard !dayPlanIDs.isEmpty else { return }
        try execBind("""
            UPDATE time_blocks
            SET notebook_id = CASE WHEN notebook_id = ?1 THEN ?2 ELSE notebook_id END,
                goal_id = CASE WHEN goal_id = ?1 THEN ?2 ELSE goal_id END,
                updated_at = ?3
            WHERE notebook_id = ?1 OR goal_id = ?1
        """) { stmt in
            bind(stmt, 1, mergeeID)
            bind(stmt, 2, survivorID)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSinceReferenceDate)
        }
        try execBind("UPDATE learning_bouts SET notebook_id = ?, updated_at = ? WHERE notebook_id = ?") { stmt in
            bind(stmt, 1, survivorID)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, mergeeID)
        }
        for dayPlanID in dayPlanIDs.sorted() {
            try touchDayPlan(dayPlanID, at: now)
            try markRecordChanged(entity: .dayPlan, logicalKey: dayPlanID, at: now)
        }
    }

    private func moveMemoryItems(fromGoal mergeeID: String, toGoal survivorID: String, at now: Date) throws {
        let itemIDs = try idsWhere("SELECT id FROM memory_items WHERE goal_id = ? ORDER BY id", mergeeID)
        guard !itemIDs.isEmpty else { return }
        try execBind("UPDATE memory_items SET goal_id = ?, updated_at = ? WHERE goal_id = ?") { stmt in
            bind(stmt, 1, survivorID)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, mergeeID)
        }
        for itemID in itemIDs {
            try markRecordChanged(entity: .memoryItem, logicalKey: itemID, at: now)
        }
    }

    /// Journal verdicts are keyed by article and Notebook, so a verdict both
    /// Notebooks already hold keeps the survivor's. The watch exclusion is the
    /// survivor's own setting and is not inherited.
    private func moveJournalWatchRecords(fromNotebook mergeeID: String, toNotebook survivorID: String) throws {
        try execBind("""
            INSERT OR IGNORE INTO journal_article_matches
                (item_url, notebook_id, reason, matched_at, state, decided_at, source_id)
            SELECT item_url, ?, reason, matched_at, state, decided_at, source_id
            FROM journal_article_matches WHERE notebook_id = ?
        """) { stmt in
            bind(stmt, 1, survivorID)
            bind(stmt, 2, mergeeID)
        }
        try execBind("DELETE FROM journal_article_matches WHERE notebook_id = ?") { stmt in
            bind(stmt, 1, mergeeID)
        }
        try execBind("DELETE FROM journal_watch_excluded_notebooks WHERE notebook_id = ?") { stmt in
            bind(stmt, 1, mergeeID)
        }
    }

    /// Links are directional. What the merged Notebook drew context from, the
    /// survivor now draws from; whoever drew context from the merged Notebook
    /// now draws it from the survivor — and is republished, since the link is
    /// carried in the referring Notebook's own record. A Notebook never links to
    /// itself, so the pair that would collapse onto the survivor is dropped.
    private func moveRelatedNotebookLinks(fromNotebook mergeeID: String, toNotebook survivorID: String, at now: Date) throws {
        try execBind("""
            INSERT OR IGNORE INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at)
            SELECT ?1, related_notebook_id, linked_at
            FROM notebook_related_notebook_links
            WHERE notebook_id = ?2 AND related_notebook_id <> ?1
        """) { stmt in
            bind(stmt, 1, survivorID)
            bind(stmt, 2, mergeeID)
        }
        let referrerIDs = try idsWhere("""
            SELECT DISTINCT notebook_id FROM notebook_related_notebook_links
            WHERE related_notebook_id = ? ORDER BY notebook_id
            """, mergeeID)
        guard !referrerIDs.isEmpty else { return }
        try execBind("""
            INSERT OR IGNORE INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at)
            SELECT notebook_id, ?1, linked_at
            FROM notebook_related_notebook_links
            WHERE related_notebook_id = ?2 AND notebook_id <> ?1
        """) { stmt in
            bind(stmt, 1, survivorID)
            bind(stmt, 2, mergeeID)
        }
        try execBind("DELETE FROM notebook_related_notebook_links WHERE related_notebook_id = ?") { stmt in
            bind(stmt, 1, mergeeID)
        }
        for referrerID in referrerIDs where referrerID != survivorID {
            try touchLearningGoal(referrerID, at: now)
            try markRecordChanged(entity: .learningGoal, logicalKey: referrerID, at: now)
        }
    }

    /// An Idea linked to the old notebook is linked to the new one, once, with
    /// the link's date kept and the kind the new notebook is. The link rides
    /// inside the Idea's own record, so the Idea is what gets republished, with
    /// a newer `updated_at` so the other devices take it (`saveIdeaRecord`).
    private func moveIdeaLinks(fromNotebook fromID: String, toNotebook toID: String, kind: IdeaLinkKind, at now: Date) throws {
        let notebookKinds = [IdeaLinkKind.notebook.rawValue, IdeaLinkKind.goal.rawValue]
        var ideaIDs: [String] = []
        try queryBind("""
            SELECT DISTINCT idea_id FROM idea_links
            WHERE target_id = ? AND kind IN (?, ?)
            ORDER BY idea_id
            """, bind: { stmt in
                bind(stmt, 1, fromID)
                bind(stmt, 2, notebookKinds[0])
                bind(stmt, 3, notebookKinds[1])
            }) { stmt in
                if let id = self.string(stmt, 0) { ideaIDs.append(id) }
            }
        guard !ideaIDs.isEmpty else { return }
        try execBind("""
            INSERT OR IGNORE INTO idea_links (idea_id, kind, target_id, added_at)
            SELECT idea_id, ?1, ?2, MIN(added_at)
            FROM idea_links
            WHERE target_id = ?3 AND kind IN (?4, ?5)
            GROUP BY idea_id
        """) { stmt in
            bind(stmt, 1, kind.rawValue)
            bind(stmt, 2, toID)
            bind(stmt, 3, fromID)
            bind(stmt, 4, notebookKinds[0])
            bind(stmt, 5, notebookKinds[1])
        }
        try execBind("DELETE FROM idea_links WHERE target_id = ? AND kind IN (?, ?)") { stmt in
            bind(stmt, 1, fromID)
            bind(stmt, 2, notebookKinds[0])
            bind(stmt, 3, notebookKinds[1])
        }
        for ideaID in ideaIDs {
            try execBind("UPDATE ideas SET updated_at = MAX(updated_at, ?) WHERE id = ?") { stmt in
                sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
                bind(stmt, 2, ideaID)
            }
            try markRecordChanged(entity: .idea, logicalKey: ideaID, at: now)
        }
    }

    /// What was proposed toward the old notebook is proposed toward the new
    /// one: the Directions are re-homed, verdicts and all, never deleted.
    private func moveResearchDirections(
        fromHome fromID: String,
        toHome toID: String,
        homeKind: DirectionHomeKind,
        at now: Date
    ) throws {
        let directionIDs = try idsWhere("SELECT id FROM research_directions WHERE home_id = ? ORDER BY id", fromID)
        guard !directionIDs.isEmpty else { return }
        try execBind("""
            UPDATE research_directions
            SET home_id = ?, home_kind = ?, updated_at = MAX(updated_at, ?)
            WHERE home_id = ?
        """) { stmt in
            bind(stmt, 1, toID)
            bind(stmt, 2, homeKind.rawValue)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSinceReferenceDate)
            bind(stmt, 4, fromID)
        }
        for directionID in directionIDs {
            try markRecordChanged(entity: .researchDirection, logicalKey: directionID, at: now)
        }
    }

    private func deleteCompanionGoalItem(goalID: String, sourceID: String) throws {
        try execBind("DELETE FROM learning_goal_items WHERE goal_id = ? AND source_id = ?") { stmt in
            bind(stmt, 1, goalID)
            bind(stmt, 2, sourceID)
        }
    }

    private func normalizedCompanionGapSummary(_ summary: String) -> String {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func reassignedCompanionGoalItem(_ item: LearningGoalItem, goalID: String) -> LearningGoalItem {
        LearningGoalItem(
            id: UUID().uuidString,
            goalID: goalID,
            sourceID: item.sourceID,
            addedAt: item.addedAt,
            completedAt: item.completedAt,
            origin: item.origin,
            reviewState: item.reviewState,
            relevance: item.relevance,
            lastQuizzedAt: item.lastQuizzedAt,
            quizCount: item.quizCount,
            lastScore: item.lastScore,
            sequence: item.sequence
        )
    }

    private func preferredCompanionGoalItem(_ left: LearningGoalItem, _ right: LearningGoalItem) -> LearningGoalItem {
        func score(_ item: LearningGoalItem) -> Int {
            var value = 0
            if item.isApproved { value += 100 }
            if item.isCompleted { value += 50 }
            value += min(item.quizCount ?? 0, 20) * 5
            if let lastScore = item.lastScore { value += Int(lastScore * 10) }
            if item.lastQuizzedAt != nil { value += 2 }
            return value
        }

        let winner = score(left) >= score(right) ? left : right
        let loser = winner.sourceID == left.sourceID && winner.id == left.id ? right : left
        let maxRelevance = max(left.relevance ?? 0, right.relevance ?? 0)
        let maxQuizCount = max(left.quizCount ?? 0, right.quizCount ?? 0)
        return LearningGoalItem(
            id: winner.id,
            goalID: winner.goalID,
            sourceID: winner.sourceID,
            addedAt: min(left.addedAt, right.addedAt),
            completedAt: [left.completedAt, right.completedAt].compactMap { $0 }.max(),
            origin: winner.origin ?? loser.origin,
            reviewState: winner.isApproved ? winner.reviewState : (left.isApproved ? left.reviewState : right.reviewState),
            relevance: maxRelevance > 0 ? maxRelevance : nil,
            lastQuizzedAt: [left.lastQuizzedAt, right.lastQuizzedAt].compactMap { $0 }.max(),
            quizCount: maxQuizCount > 0 ? maxQuizCount : nil,
            lastScore: [left.lastScore, right.lastScore].compactMap { $0 }.max(),
            sequence: [left.sequence, right.sequence].compactMap { $0 }.min()
        )
    }

    /// Insert newly discovered sources as pending suggestions. Skips sources already in
    /// the pool (any state, including rejected tombstones). Returns count actually added.
    @discardableResult
    func addDiscoveredCompanionSources(goalID: String, discovered: [(sourceID: String, relevance: Double)]) throws -> Int {
        guard !discovered.isEmpty else { return 0 }
        let existing = try learningGoalSourceIDSet(goalID: goalID)
        let now = Date()
        var added = 0
        try exec("BEGIN IMMEDIATE")
        do {
            for entry in discovered where !existing.contains(entry.sourceID) {
                try insertLearningGoalItem(
                    goalID: goalID,
                    sourceID: entry.sourceID,
                    addedAt: now,
                    origin: LearningGoalItemOrigin.discovered.rawValue,
                    reviewState: LearningGoalItemReviewState.pending.rawValue,
                    relevance: entry.relevance
                )
                added += 1
            }
            try touchLearningGoal(goalID, at: now)
            try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return added
    }

    /// Add user-picked library sources to a companion goal as approved seeds — the
    /// post-creation twin of `createCompanionGoal`'s seeding. New sources are inserted
    /// approved; sources already present as a rejected/pending tombstone are re-approved
    /// (an explicit add must override a prior removal, otherwise re-adding a removed
    /// source silently does nothing and it never reappears). Returns count added or
    /// restored.
    @discardableResult
    func addCompanionSeedSources(goalID: String, sourceIDs: [String]) throws -> Int {
        guard !sourceIDs.isEmpty else { return 0 }
        guard let goal = try loadLearningGoal(goalID), goal.isCompanion else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        let added: Int
        do {
            added = try addCompanionSeedSourcesInCurrentTransaction(
                goalID: goalID,
                sourceIDs: sourceIDs,
                addedAt: now,
                restoreExisting: true
            )
            try touchLearningGoal(goalID, at: now)
            try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        if let parentNotebookID = goal.parentNotebookID {
            _ = try addCompanionSeedSources(goalID: parentNotebookID, sourceIDs: sourceIDs)
        }
        return added
    }

    /// Row-level implementation shared by explicit Notebook adds and course-link
    /// propagation. The caller owns the transaction and CloudKit bookkeeping.
    ///
    /// Explicit user adds restore a pending/rejected tombstone. Automatic course
    /// propagation does not: removing a source from a Notebook remains respected,
    /// while genuinely new course sources still flow in.
    @discardableResult
    func addCompanionSeedSourcesInCurrentTransaction(
        goalID: String,
        sourceIDs: [String],
        addedAt: Date,
        restoreExisting: Bool
    ) throws -> Int {
        let uniqueSourceIDs = Array(dictUnique(sourceIDs))
        guard !uniqueSourceIDs.isEmpty else { return 0 }

        var existingSourceIDs = Set<String>()
        var existingReviewStates: [String: String] = [:]
        try queryBind(
            "SELECT source_id, review_state FROM learning_goal_items WHERE goal_id = ?",
            bind: { stmt in self.bind(stmt, 1, goalID) }
        ) { stmt in
            guard let sourceID = self.string(stmt, 0) else { return }
            existingSourceIDs.insert(sourceID)
            if let reviewState = self.string(stmt, 1) {
                existingReviewStates[sourceID] = reviewState
            }
        }

        let approved = LearningGoalItemReviewState.approved.rawValue
        var added = 0
        for sourceID in uniqueSourceIDs {
            if existingSourceIDs.contains(sourceID) {
                guard restoreExisting, existingReviewStates[sourceID] != approved else { continue }
                try execBind(
                    "UPDATE learning_goal_items SET review_state = ? WHERE goal_id = ? AND source_id = ?"
                ) { stmt in
                    self.bind(stmt, 1, approved)
                    self.bind(stmt, 2, goalID)
                    self.bind(stmt, 3, sourceID)
                }
                added += 1
                continue
            }

            try insertLearningGoalItem(
                goalID: goalID,
                sourceID: sourceID,
                addedAt: addedAt,
                origin: LearningGoalItemOrigin.seed.rawValue,
                reviewState: approved
            )
            added += 1
        }
        return added
    }

    /// Persist a course subscription on a top-level Notebook and add the course's
    /// current sources as explicit approved seeds. Future course writes use the
    /// same relationship to materialize newly attached sources automatically.
    @discardableResult
    func linkCourseToNotebook(goalID: String, courseID: String, sourceIDs: [String]) throws -> Int {
        let trimmedCourseID = courseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCourseID.isEmpty else {
            throw KnowledgeStoreError.invalidData("Course is required.")
        }
        guard let goal = try loadLearningGoal(goalID), goal.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(goalID)")
        }

        let currentSourceIDs = try sourceIDsForCourse(trimmedCourseID)
        let resolvedSourceIDs = Array(dictUnique(sourceIDs + currentSourceIDs))
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        let added: Int
        do {
            try execBind("""
                INSERT OR IGNORE INTO notebook_course_links (goal_id, course_id)
                VALUES (?, ?)
            """) { stmt in
                bind(stmt, 1, goalID)
                bind(stmt, 2, trimmedCourseID)
            }
            added = try addCompanionSeedSourcesInCurrentTransaction(
                goalID: goalID,
                sourceIDs: resolvedSourceIDs,
                addedAt: now,
                restoreExisting: true
            )
            try touchLearningGoal(goalID, at: now)
            try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return added
    }

    /// Ends a Notebook's subscription to a course (`linkCourseToNotebook`), so
    /// later lectures no longer join it. The sources it already holds are the
    /// caller's to remove (`removeCompanionSources`). Syncs as the Notebook's
    /// `linkedCourseIDs`, where a shorter present list is an explicit removal
    /// (`mergeLearningGoalServerConflict`). False, and nothing written, when
    /// the Notebook did not follow the course. The course itself is untouched:
    /// it lives in no notebook, only follows a link.
    @discardableResult
    func unlinkCourseFromNotebook(goalID: String, courseID: String) throws -> Bool {
        let trimmedCourseID = courseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCourseID.isEmpty,
              try linkedCourseIDsForNotebook(goalID: goalID).contains(trimmedCourseID) else { return false }
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM notebook_course_links WHERE goal_id = ? AND course_id = ?") { stmt in
                bind(stmt, 1, goalID)
                bind(stmt, 2, trimmedCourseID)
            }
            try touchLearningGoal(goalID, at: now)
            try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return true
    }

    func linkedCourseIDsForNotebook(goalID: String) throws -> [String] {
        var courseIDs: [String] = []
        try queryBind("""
            SELECT course_id
            FROM notebook_course_links
            WHERE goal_id = ?
            ORDER BY course_id COLLATE NOCASE, course_id
        """, bind: { stmt in
            bind(stmt, 1, goalID)
        }) { stmt in
            if let courseID = self.string(stmt, 0) {
                courseIDs.append(courseID)
            }
        }
        return courseIDs
    }

    func sourceBelongsToLinkedCourse(goalID: String, sourceID: String) throws -> Bool {
        var belongs = false
        try queryBind("""
            SELECT 1
            FROM notebook_course_links pcl
            WHERE pcl.goal_id = ?
              AND (
                    EXISTS (
                        SELECT 1
                        FROM course_lectures cl
                        JOIN course_lecture_items cli ON cli.lecture_id = cl.id
                        WHERE cl.course_id = pcl.course_id
                          AND cli.source_id = ?
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM group_members gm
                        WHERE gm.group_id = pcl.course_id
                          AND gm.source_id = ?
                    )
              )
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, goalID)
            bind(stmt, 2, sourceID)
            bind(stmt, 3, sourceID)
        }) { _ in
            belongs = true
        }
        return belongs
    }

    func replaceNotebookCourseLinksInCurrentTransaction(goalID: String, courseIDs: [String]) throws {
        try execBind("DELETE FROM notebook_course_links WHERE goal_id = ?") { stmt in
            bind(stmt, 1, goalID)
        }
        let normalizedCourseIDs = courseIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for courseID in dictUnique(normalizedCourseIDs) where !courseID.isEmpty {
            try execBind("""
                INSERT OR IGNORE INTO notebook_course_links (goal_id, course_id)
                VALUES (?, ?)
            """) { stmt in
                bind(stmt, 1, goalID)
                bind(stmt, 2, courseID)
            }
        }
    }

    /// Add newly attached course sources to every subscribing Notebook. The caller
    /// owns the surrounding transaction so course membership, Notebook membership,
    /// and both entities' CloudKit change rows commit atomically.
    @discardableResult
    func addSourcesToNotebooksLinkedToCourseInCurrentTransaction(
        courseID: String,
        sourceIDs: [String],
        addedAt: Date = Date()
    ) throws -> Int {
        let uniqueSourceIDs = Array(dictUnique(sourceIDs))
        guard !uniqueSourceIDs.isEmpty else { return 0 }

        var notebookIDs: [String] = []
        try queryBind("""
            SELECT pcl.goal_id
            FROM notebook_course_links pcl
            JOIN learning_goals lg ON lg.id = pcl.goal_id
            WHERE pcl.course_id = ?
              AND lg.kind = ?
              AND lg.parent_notebook_id IS NULL
            ORDER BY pcl.goal_id
        """, bind: { stmt in
            bind(stmt, 1, courseID)
            bind(stmt, 2, LearningGoalRecord.companionKind)
        }) { stmt in
            if let notebookID = self.string(stmt, 0) {
                notebookIDs.append(notebookID)
            }
        }

        var totalAdded = 0
        for notebookID in notebookIDs {
            let added = try addCompanionSeedSourcesInCurrentTransaction(
                goalID: notebookID,
                sourceIDs: uniqueSourceIDs,
                addedAt: addedAt,
                restoreExisting: false
            )
            guard added > 0 else { continue }
            totalAdded += added
            try touchLearningGoal(notebookID, at: addedAt)
            try markRecordChanged(entity: .learningGoal, logicalKey: notebookID)
        }
        return totalAdded
    }

    /// Approve or reject pending discovered sources.
    func setCompanionItemReviewState(goalID: String, sourceIDs: [String], state: LearningGoalItemReviewState) throws {
        guard !sourceIDs.isEmpty else { return }
        guard let goal = try loadLearningGoal(goalID), goal.isCompanion else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }
        let existingSourceIDs = Set(goal.items.map(\.sourceID))
        let matchedSourceIDs = dictUnique(sourceIDs).filter { existingSourceIDs.contains($0) }
        guard !matchedSourceIDs.isEmpty else { return }
        let now = Date()
        for sourceID in matchedSourceIDs {
            try execBind("UPDATE learning_goal_items SET review_state = ? WHERE goal_id = ? AND source_id = ?") { stmt in
                bind(stmt, 1, state.rawValue)
                bind(stmt, 2, goalID)
                bind(stmt, 3, sourceID)
            }
        }
        try touchLearningGoal(goalID, at: now)
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
        if state == .approved, let parentNotebookID = goal.parentNotebookID {
            _ = try addCompanionSeedSources(goalID: parentNotebookID, sourceIDs: matchedSourceIDs)
        }
    }

    /// Remove sources from a companion goal's pool. Ordinary manually-added seeds
    /// are deleted outright. Auto-discovered sources and sources supplied by a
    /// linked course are tombstoned as `rejected`, preventing discovery or a later
    /// course refresh from silently reversing the learner's explicit removal. An
    /// explicit re-add (including re-dropping the course) restores either kind.
    func removeCompanionSources(goalID: String, sourceIDs: [String]) throws {
        guard !sourceIDs.isEmpty else { return }
        var originBySource: [String: String?] = [:]
        try queryBind(
            "SELECT source_id, origin FROM learning_goal_items WHERE goal_id = ?",
            bind: { stmt in self.bind(stmt, 1, goalID) }
        ) { stmt in
            if let sid = self.string(stmt, 0) {
                originBySource[sid] = self.string(stmt, 1)
            }
        }
        let discovered = LearningGoalItemOrigin.discovered.rawValue
        let rejected = LearningGoalItemReviewState.rejected.rawValue
        var linkedCourseSourceIDs = Set<String>()
        for sourceID in sourceIDs {
            if try sourceBelongsToLinkedCourse(goalID: goalID, sourceID: sourceID) {
                linkedCourseSourceIDs.insert(sourceID)
            }
        }
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            for sourceID in dictUnique(sourceIDs) {
                guard let origin = originBySource[sourceID] else { continue }
                if origin == discovered || linkedCourseSourceIDs.contains(sourceID) {
                    try execBind("UPDATE learning_goal_items SET review_state = ? WHERE goal_id = ? AND source_id = ?") { stmt in
                        self.bind(stmt, 1, rejected)
                        self.bind(stmt, 2, goalID)
                        self.bind(stmt, 3, sourceID)
                    }
                } else {
                    try deleteCompanionGoalItem(goalID: goalID, sourceID: sourceID)
                }
            }
            try touchLearningGoal(goalID, at: now)
            try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Set the user-defined study order of a Notebook's approved pool. `orderedSourceIDs`
    /// may be a subset: listed sources are sequenced first in the given order, and every
    /// other approved source keeps its current relative order after them. Pending and
    /// rejected items are untouched. Every approved item gets an explicit sequence so
    /// the resulting order is total and stable.
    func reorderCompanionSources(goalID: String, orderedSourceIDs: [String]) throws {
        let requested = dictUnique(orderedSourceIDs)
        guard requested.count == orderedSourceIDs.count else {
            throw KnowledgeStoreError.invalidData("Notebook reorder contained duplicate sources.")
        }
        guard !requested.isEmpty else { return }

        // Current approved pool in display order (sequence, then added_at).
        let approvedInOrder = try loadLearningGoalItems(goalID: goalID)
            .filter(\.isApproved)
            .map(\.sourceID)
        let approvedSet = Set(approvedInOrder)
        if let unknown = requested.first(where: { !approvedSet.contains($0) }) {
            throw KnowledgeStoreError.invalidData("Source \(unknown) is not an approved source in this Notebook.")
        }

        let requestedSet = Set(requested)
        let newOrder = requested + approvedInOrder.filter { !requestedSet.contains($0) }

        try exec("BEGIN IMMEDIATE")
        do {
            for (index, sourceID) in newOrder.enumerated() {
                try execBind("""
                    UPDATE learning_goal_items
                    SET sequence = ?
                    WHERE goal_id = ? AND source_id = ?
                """) { stmt in
                    sqlite3_bind_double(stmt, 1, Double(index))
                    bind(stmt, 2, goalID)
                    bind(stmt, 3, sourceID)
                }
            }
            // Generation 2 moves only the keys the new order puts out of place, so a reorder
            // sends one Entry (schema v2 §5.2).
            try keepNotebookRowsForGeneration2(goalIDs: [goalID])
            try touchLearningGoal(goalID)
            try markRecordChanged(entity: .learningGoal, logicalKey: goalID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Record that a set of sources were quizzed today: bump quiz_count, stamp
    /// last_quizzed_at, store last_score, and set the goal's last_quiz_date.
    func recordCompanionQuiz(goalID: String, sourceIDs: [String], score: Double?, quizDate: String) throws {
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try recordCompanionQuizRows(
                goalID: goalID,
                sourceIDs: sourceIDs,
                score: score,
                quizDate: quizDate,
                recordedAt: now
            )
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Transaction-free row helper used by the review-completion correctness
    /// boundary. Callers must already own the surrounding SQLite transaction.
    func recordCompanionQuizRows(
        goalID: String,
        sourceIDs: [String],
        score: Double?,
        quizDate: String,
        recordedAt: Date
    ) throws {
        for sourceID in sourceIDs {
            try execBind("""
                UPDATE learning_goal_items
                SET quiz_count = COALESCE(quiz_count, 0) + 1,
                    last_quizzed_at = ?,
                    last_score = COALESCE(?, last_score)
                WHERE goal_id = ? AND source_id = ?
            """) { stmt in
                sqlite3_bind_double(stmt, 1, recordedAt.timeIntervalSinceReferenceDate)
                if let score { sqlite3_bind_double(stmt, 2, score) } else { sqlite3_bind_null(stmt, 2) }
                bind(stmt, 3, goalID)
                bind(stmt, 4, sourceID)
            }
        }
        try execBind("UPDATE learning_goals SET last_quiz_date = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, quizDate)
            sqlite3_bind_double(stmt, 2, recordedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        guard sqlite3_changes(db) > 0 else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }
        try markTutorStateChanged(entity: .learningGoal, logicalKey: goalID, at: recordedAt)
    }

    /// Mark items as served in today's quiz (sets last_quizzed_at + the goal's
    /// last_quiz_date) without bumping counts or scores, which happen at end of session.
    func markCompanionServed(goalID: String, sourceIDs: [String], quizDate: String) throws {
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            for sourceID in sourceIDs {
                try execBind("UPDATE learning_goal_items SET last_quizzed_at = ? WHERE goal_id = ? AND source_id = ?") { stmt in
                    sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 2, goalID)
                    bind(stmt, 3, sourceID)
                }
            }
            try execBind("UPDATE learning_goals SET last_quiz_date = ?, updated_at = ? WHERE id = ?") { stmt in
                bind(stmt, 1, quizDate)
                sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                bind(stmt, 3, goalID)
            }
            try markTutorStateChanged(entity: .learningGoal, logicalKey: goalID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Stamp the last incremental-discovery pass time.
    func setCompanionDiscoveryStamp(goalID: String, at date: Date = Date()) throws {
        try execBind("UPDATE learning_goals SET last_discovery_at = ?, updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, date.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try markTutorStateChanged(entity: .learningGoal, logicalKey: goalID, at: date)
    }

    /// Upsert gaps for a companion goal. Each input gap with a matching id replaces the
    /// stored one; gaps without an id are inserted with a fresh UUID.
    func upsertCompanionGaps(goalID: String, gaps: [LearningGoalGap]) throws {
        guard !gaps.isEmpty else { return }
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            for gap in gaps {
                let id = gap.id.isEmpty ? UUID().uuidString : gap.id
                let stored = LearningGoalGap(
                    id: id,
                    goalID: goalID,
                    summary: gap.summary,
                    sourceID: gap.sourceID,
                    status: gap.status,
                    severity: gap.severity,
                    firstSeenAt: gap.firstSeenAt,
                    lastSeenAt: gap.lastSeenAt,
                    resolvedAt: gap.status == "resolved" ? (gap.resolvedAt ?? now) : gap.resolvedAt,
                    sessionID: gap.sessionID
                )
                try saveLearningGoalGap(stored, goalID: goalID)
            }
            try touchLearningGoal(goalID, at: now)
            try markTutorStateChanged(entity: .learningGoal, logicalKey: goalID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func learningGoalSourceIDSet(goalID: String) throws -> Set<String> {
        var ids = Set<String>()
        try queryBind("SELECT source_id FROM learning_goal_items WHERE goal_id = ?", bind: { stmt in
            bind(stmt, 1, goalID)
        }) { stmt in
            if let sourceID = self.string(stmt, 0) { ids.insert(sourceID) }
        }
        return ids
    }

    func loadLearningGoals() throws -> [LearningGoalRecord] {
        var goals: [LearningGoalRecord] = []
        // Under generation 2 a merged notebook's stub stays as a row (schema v2 §5.2): a redirect,
        // never a notebook of its own. Generation 1 never names the column, which a store held below
        // 154 does not have.
        let live = syncGeneration == .two ? "WHERE COALESCE(merged_into, '') = '' AND COALESCE(moved_to, '') = ''" : ""
        try query("""
            SELECT id, title, start_at, end_at, created_at, updated_at, status,
                   kind, topic, discovery_enabled, daily_target, last_quiz_date, last_discovery_at, notes, description, parent_notebook_id, research_questions, team_id, summary, repository, artifact_id, sort_order
            FROM learning_goals
            \(live)
            ORDER BY start_at DESC, created_at DESC
        """) { stmt in
            guard let goal = readLearningGoalRow(stmt) else { return }
            goals.append(goal)
        }
        return goals
    }

    func loadLearningGoal(_ id: String) throws -> LearningGoalRecord? {
        var goal: LearningGoalRecord?
        try queryBind("""
            SELECT id, title, start_at, end_at, created_at, updated_at, status,
                   kind, topic, discovery_enabled, daily_target, last_quiz_date, last_discovery_at, notes, description, parent_notebook_id, research_questions, team_id, summary, repository, artifact_id, sort_order
            FROM learning_goals
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            goal = readLearningGoalRow(stmt)
        }
        return goal
    }

    /// Goals nested in a Notebook go with it when `cascadeChildGoals` is set.
    /// Without it a Notebook still holding Goals is refused: `parent_notebook_id`
    /// carries no FK cascade, so those Goals would survive pointing at a row
    /// that no longer exists, and every surface filters Goals by their Notebook.
    /// The refusal is the floor for callers that cannot warn the learner first
    /// (sync, MCP); the UI passes `true` after naming the count in its dialog.
    func deleteLearningGoal(
        _ goalID: String,
        cascadeChildGoals: Bool = false,
        deleteLinkedChats: Bool = false
    ) throws {
        try requireSpaceDeletion(.notebook, goalID)
        var deletedGoalIDs = [goalID]
        let deletingNotebook = try loadLearningGoal(goalID)?.isNotebook == true
        if let record = try loadLearningGoal(goalID), record.isNotebook {
            let childGoalIDs = try childGoalIDs(ofNotebook: goalID)
            if !childGoalIDs.isEmpty {
                guard cascadeChildGoals else {
                    throw KnowledgeStoreError.invalidData(
                        "Notebook \"\(record.title)\" contains \(childGoalIDs.count) Goal\(childGoalIDs.count == 1 ? "" : "s"). Move or delete those Goals before deleting the Notebook."
                    )
                }
                deletedGoalIDs.append(contentsOf: childGoalIDs)
            }

            // Related-Notebook links are directional. Deleting the destination
            // must republish every surviving Notebook that referenced it so no
            // other device retains a dangling context relationship.
            try removeIncomingRelatedNotebookLinks(
                toNotebookIDs: deletedGoalIDs,
                excludingNotebookIDs: Set(deletedGoalIDs)
            )

            // Chats are independently synced records, so deleting their Notebook
            // must settle that relationship explicitly. Keeping them clears the
            // Notebook link and places them in the ordinary Chats list; deleting
            // them uses the normal session deletion path so transcript-dependent
            // MemoryAttempts receive their own CloudKit tombstones as well.
            let linkedSessionIDs = try reviewSessionIDs(linkedToAnyGoalIn: deletedGoalIDs)
            if deleteLinkedChats {
                for sessionID in linkedSessionIDs {
                    try deleteReviewSession(sessionID)
                }
            } else {
                try clearReviewSessionGoals(sessionIDs: linkedSessionIDs)
            }

            if !childGoalIDs.isEmpty {
                // Each child is a full goal deletion of its own: schedule
                // placements and sync tombstones have to be settled per row.
                for childGoalID in childGoalIDs {
                    try deleteLearningGoalRow(childGoalID)
                }
            }
        }
        if !deletingNotebook {
            // A chat started from a Goal outlives it in the ordinary Chats
            // list, the way a Notebook's chats are kept: the link is cleared so
            // no device is left pointing at a Goal that is gone.
            try clearReviewSessionGoals(sessionIDs: reviewSessionIDs(linkedToAnyGoalIn: [goalID]))
        }
        try deleteLearningGoalRow(goalID)
        if deletingNotebook {
            try removeNotebookFromArtifacts(goalID)
            // A scheduled task outlives the Notebook it filed chats under, the
            // same way a Schedule placement outlives a Goal that tagged it.
            // Its future runs simply land in the general Chats section rather
            // than disappearing along with the folder.
            for deletedGoalID in deletedGoalIDs {
                try detachScheduledTasksFromNotebook(deletedGoalID)
            }
        }
    }

    private func removeIncomingRelatedNotebookLinks(
        toNotebookIDs deletedIDs: [String],
        excludingNotebookIDs: Set<String>
    ) throws {
        guard !deletedIDs.isEmpty else { return }
        let placeholders = deletedIDs.map { _ in "?" }.joined(separator: ",")
        var referringIDs: [String] = []
        try queryBind("""
            SELECT DISTINCT notebook_id
            FROM notebook_related_notebook_links
            WHERE related_notebook_id IN (\(placeholders))
            ORDER BY notebook_id
        """, bind: { stmt in
            for (index, id) in deletedIDs.enumerated() { bind(stmt, index + 1, id) }
        }) { stmt in
            if let id = self.string(stmt, 0), !excludingNotebookIDs.contains(id) {
                referringIDs.append(id)
            }
        }
        guard !referringIDs.isEmpty else { return }

        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                DELETE FROM notebook_related_notebook_links
                WHERE related_notebook_id IN (\(placeholders))
            """) { stmt in
                for (index, id) in deletedIDs.enumerated() { bind(stmt, index + 1, id) }
            }
            for notebookID in referringIDs {
                try touchLearningGoal(notebookID, at: now)
                try markRecordChanged(entity: .learningGoal, logicalKey: notebookID, at: now)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func reviewSessionIDs(linkedToAnyGoalIn goalIDs: [String]) throws -> [String] {
        let goalIDSet = Set(goalIDs)
        var sessionIDs: [String] = []
        try query("SELECT id, goal_id FROM review_sessions ORDER BY id") { statement in
            guard let sessionID = self.string(statement, 0),
                  let linkedGoalID = self.string(statement, 1),
                  goalIDSet.contains(linkedGoalID) else {
                return
            }
            sessionIDs.append(sessionID)
        }
        return sessionIDs
    }

    private func clearReviewSessionGoals(sessionIDs: [String]) throws {
        guard !sessionIDs.isEmpty else { return }
        let changedAt = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            for sessionID in sessionIDs {
                try execBind("UPDATE review_sessions SET goal_id = NULL WHERE id = ?") { statement in
                    bind(statement, 1, sessionID)
                }
                try markRecordChanged(
                    entity: .reviewSession,
                    logicalKey: sessionID,
                    at: changedAt
                )
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Identifiers of the Goals nested in a Notebook, in no particular order.
    func childGoalIDs(ofNotebook notebookID: String) throws -> [String] {
        var ids: [String] = []
        try queryBind(
            "SELECT id FROM learning_goals WHERE parent_notebook_id = ?",
            bind: { stmt in bind(stmt, 1, notebookID) }
        ) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Whether this id names a Notebook or Goal that was deleted here and is
    /// still carrying its CloudKit tombstone. Deliberately narrow: a tombstone
    /// whose row is somehow back is not treated as deleted, so the check can
    /// never strand a live record.
    private func isDeletedLearningGoalID(_ goalID: String) throws -> Bool {
        guard try loadSyncMetadata(entity: .learningGoal, logicalKey: goalID)?.isDeleted == true else {
            return false
        }
        var exists = false
        try queryBind(
            "SELECT 1 FROM learning_goals WHERE id = ? LIMIT 1",
            bind: { stmt in bind(stmt, 1, goalID) }
        ) { _ in exists = true }
        return !exists
    }

    /// Drops one `learning_goals` row and everything hanging off it, with no
    /// regard for nesting. Always reach it through `deleteLearningGoal`.
    private func deleteLearningGoalRow(_ goalID: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try deleteLearningGoalRowInTransaction(goalID, at: Date())
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The body of `deleteLearningGoalRow`, inside the caller's transaction:
    /// the row (its pool, open questions, course links and outgoing related
    /// links cascade with it; its file index goes with it under generation 1
    /// and stays, unfiled, under generation 2), its Schedule placements, its
    /// Directions and its CloudKit tombstone. A merge and a split that removes
    /// its parent reach it after `moveNotebookContentsInTransaction`, so the
    /// emptied notebook leaves the library the way any deleted one does.
    private func deleteLearningGoalRowInTransaction(_ goalID: String, at now: Date) throws {
        // Placements tagged with this goal, collected before we drop the membership rows.
        var affectedPlacements: [String] = []
        try queryBind("SELECT scheduled_source_id FROM scheduled_source_goals WHERE goal_id = ?", bind: { stmt in
            bind(stmt, 1, goalID)
        }) { stmt in
            if let placementID = self.string(stmt, 0) { affectedPlacements.append(placementID) }
        }

        var orphaned: [String] = []
        try execBind("DELETE FROM scheduled_source_goals WHERE goal_id = ?") { stmt in
            bind(stmt, 1, goalID)
        }
        // The file index lost its foreign key in schema 154: generation 1
        // removes it here as the cascade did; generation 2 leaves it unfiled.
        try releaseFilesOfDeletedNotebook(goalID)
        // Cascades learning_goal_items (companion) via FK on learning_goals.
        try execBind("DELETE FROM learning_goals WHERE id = ?") { stmt in
            bind(stmt, 1, goalID)
        }
        for placementID in affectedPlacements
        where try scheduledSourceGoalCount(placementID: placementID) == 0 {
            if try scheduledSourceHasActivity(placementID: placementID) {
                var sourceID: String?
                try queryBind(
                    "SELECT source_id FROM scheduled_sources WHERE id = ? LIMIT 1",
                    bind: { stmt in bind(stmt, 1, placementID) }
                ) { stmt in sourceID = self.string(stmt, 0) }
                if let sourceID {
                    try convertPlacementToAutomaticHistory(
                        placementID: placementID,
                        sourceID: sourceID,
                        at: now
                    )
                }
            } else {
                try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
                    bind(stmt, 1, placementID)
                }
                orphaned.append(placementID)
            }
        }
        // Tombstones belong in the same transaction as the rows they
        // describe. Written after the COMMIT, any throw in this sequence —
        // or a quit between the two writes — left the goal deleted locally
        // with its CloudKit record intact and nothing to refuse it: the
        // next fetch applied the server copy and the Notebook was back.
        let orphanSet = Set(orphaned)
        for placementID in affectedPlacements where !orphanSet.contains(placementID) {
            try markRecordChanged(entity: .scheduledSource, logicalKey: placementID, at: now)
        }
        for placementID in orphaned {
            try markRecordDeleted(entity: .scheduledSource, logicalKey: placementID)
        }
        try markRecordDeleted(entity: .learningGoal, logicalKey: goalID)
        // What was proposed toward the Goal or Notebook goes with it
        // (docs/directions-design.md).
        try deleteResearchDirectionRowsInTransaction(homeID: goalID, at: now)
    }

    func saveLearningGoalRecord(_ goal: LearningGoalRecord) throws {
        try saveLearningGoalRecord(goal, replacingLinkedCourseIDs: nil)
    }

    /// `replacingLinkedCourseIDs == nil` means the caller has no opinion (local
    /// record saves and payloads from older devices), so existing relationships
    /// survive. A non-nil array is the authoritative synced relationship set.
    private func saveLearningGoalRecord(
        _ goal: LearningGoalRecord,
        replacingLinkedCourseIDs: [String]?
    ) throws {
        // The upsert below inserts as readily as it updates, so a save built
        // from a stale in-memory copy — a view that outlived its Notebook, an
        // inbound merge adopting a server record this device already deleted —
        // re-creates the row, and `markRecordChanged` at the end of the
        // transaction then republishes it everywhere. A tombstone with no
        // surviving row is a committed deletion: nothing may write that id back.
        // Goal ids are fresh UUIDs, so this never blocks a legitimate re-create.
        if try isDeletedLearningGoalID(goal.id) { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status, kind, description, topic, discovery_enabled, daily_target, last_quiz_date, last_discovery_at, notes, parent_notebook_id, research_questions, team_id, summary, repository, artifact_id, sort_order)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    summary = excluded.summary,
                    start_at = excluded.start_at,
                    end_at = excluded.end_at,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    status = excluded.status,
                    kind = excluded.kind,
                    description = excluded.description,
                    topic = excluded.topic,
                    discovery_enabled = excluded.discovery_enabled,
                    daily_target = excluded.daily_target,
                    last_quiz_date = excluded.last_quiz_date,
                    last_discovery_at = excluded.last_discovery_at,
                    notes = excluded.notes,
                    parent_notebook_id = excluded.parent_notebook_id,
                    research_questions = COALESCE(excluded.research_questions, learning_goals.research_questions),
                    -- Same tri-state as research_questions: NULL is an older
                    -- payload with no opinion, '' an explicit unlink that wins.
                    repository = COALESCE(excluded.repository, learning_goals.repository),
                    artifact_id = COALESCE(excluded.artifact_id, learning_goals.artifact_id),
                    -- NULL is an older client with no opinion on where the
                    -- Goal sits; a placement made here stays.
                    sort_order = COALESCE(excluded.sort_order, learning_goals.sort_order),
                    -- A team Notebook stays the team's even when an older
                    -- client's payload does not know the field.
                    team_id = COALESCE(excluded.team_id, learning_goals.team_id)
            """) { stmt in
                bind(stmt, 1, goal.id)
                bind(stmt, 2, goal.title)
                sqlite3_bind_double(stmt, 3, goal.startAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 4, goal.endAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 5, goal.createdAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 6, goal.updatedAt.timeIntervalSinceReferenceDate)
                bind(stmt, 7, goal.status)
                bind(stmt, 8, goal.kind)
                bind(stmt, 9, goal.description)
                bind(stmt, 10, goal.topic)
                if let discoveryEnabled = goal.discoveryEnabled { sqlite3_bind_int64(stmt, 11, discoveryEnabled ? 1 : 0) } else { sqlite3_bind_null(stmt, 11) }
                bind(stmt, 12, goal.dailyTarget)
                bind(stmt, 13, goal.lastQuizDate)
                if let lastDiscoveryAt = goal.lastDiscoveryAt { sqlite3_bind_double(stmt, 14, lastDiscoveryAt.timeIntervalSinceReferenceDate) } else { sqlite3_bind_null(stmt, 14) }
                bind(stmt, 15, goal.notes)
                bind(stmt, 16, goal.parentNotebookID)
                // NULL from a payload that predates research questions (old
                // build, old record) means "no opinion" — the COALESCE above
                // keeps the local list instead of wiping it, the same hazard
                // the arc guard below documents. An intentional clear arrives
                // as "[]", which is non-NULL and wins.
                bind(stmt, 17, goal.researchQuestions.map(Self.encodeResearchQuestions))
                bind(stmt, 18, goal.teamID)
                bind(stmt, 19, goal.summary)
                bind(stmt, 20, goal.repository)
                bind(stmt, 21, goal.artifactID)
                if let sortOrder = goal.sortOrder { sqlite3_bind_int64(stmt, 22, Int64(sortOrder)) } else { sqlite3_bind_null(stmt, 22) }
            }
            // Generation 2 keeps each item's order key across the rewrite, so an unchanged item
            // re-sends nothing (schema v2 §3.5.8).
            var heldOrderKeys: [String: String] = [:]
            if syncGeneration == .two {
                try queryBind("SELECT source_id, order_key FROM learning_goal_items WHERE goal_id = ? AND order_key IS NOT NULL", bind: { stmt in
                    self.bind(stmt, 1, goal.id)
                }) { stmt in
                    if let source = self.string(stmt, 0), let key = self.string(stmt, 1) { heldOrderKeys[source] = key }
                }
            }
            try execBind("DELETE FROM learning_goal_items WHERE goal_id = ?") { stmt in
                bind(stmt, 1, goal.id)
            }
            for item in goal.items {
                guard try !isArchivedSource(item.sourceID) else { continue }
                try saveLearningGoalItem(item, goalID: goal.id, orderKey: heldOrderKeys[item.sourceID])
            }
            try execBind("DELETE FROM learning_goal_gaps WHERE goal_id = ?") { stmt in
                bind(stmt, 1, goal.id)
            }
            for gap in goal.gaps ?? [] {
                try saveLearningGoalGap(gap, goalID: goal.id)
            }
            if let replacingLinkedCourseIDs {
                try replaceNotebookCourseLinksInCurrentTransaction(
                    goalID: goal.id,
                    courseIDs: goal.isNotebook ? replacingLinkedCourseIDs : []
                )
            }
            if let relatedNotebookIDs = goal.relatedNotebookIDs {
                try replaceRelatedNotebookLinksInCurrentTransaction(
                    notebookID: goal.id,
                    relatedNotebookIDs: goal.isNotebook ? relatedNotebookIDs : [],
                    linkedAt: goal.updatedAt
                )
            }
            // CloudKit can deliver the course and Notebook in either order. Once
            // both sides exist locally, materialize any course sources missing
            // from the Notebook without reviving user-removed tombstones.
            if goal.isNotebook {
                for courseID in try linkedCourseIDsForNotebook(goalID: goal.id) {
                    _ = try addCompanionSeedSourcesInCurrentTransaction(
                        goalID: goal.id,
                        sourceIDs: try sourceIDsForCourse(courseID),
                        addedAt: goal.updatedAt,
                        restoreExisting: false
                    )
                }
            }
            try keepNotebookRowsForGeneration2(goalIDs: [goal.id])
            try markRecordChanged(entity: .learningGoal, logicalKey: goal.id)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Missing sources are allowed because CloudKit can deliver a Learning
    /// Goal before its Source. A source already known to be archived is not:
    /// accepting that relationship would restore Notebook context the learner
    /// removed, and a later Source delivery cannot make it usable again.
    private func isArchivedSource(_ sourceID: String) throws -> Bool {
        var archived = false
        try queryBind(
            "SELECT status = 'archived' FROM sources WHERE id = ? LIMIT 1",
            bind: { stmt in bind(stmt, 1, sourceID) }
        ) { stmt in
            archived = sqlite3_column_int(stmt, 0) != 0
        }
        return archived
    }

    /// An upsert, never a replace: a replace fires only an insert trigger and would re-date every
    /// column of the open question under generation 2 (schema v2 §6.6 step 1); it writes the same row.
    func saveLearningGoalGap(_ gap: LearningGoalGap, goalID: String) throws {
        try execBind("""
            INSERT INTO learning_goal_gaps (id, goal_id, summary, source_id, status, severity, first_seen_at, last_seen_at, resolved_at, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                goal_id = excluded.goal_id, summary = excluded.summary, source_id = excluded.source_id,
                status = excluded.status, severity = excluded.severity, first_seen_at = excluded.first_seen_at,
                last_seen_at = excluded.last_seen_at, resolved_at = excluded.resolved_at, session_id = excluded.session_id
        """) { stmt in
            bind(stmt, 1, gap.id)
            bind(stmt, 2, goalID)
            bind(stmt, 3, gap.summary)
            bind(stmt, 4, gap.sourceID)
            bind(stmt, 5, gap.status)
            if let severity = gap.severity { sqlite3_bind_double(stmt, 6, severity) } else { sqlite3_bind_null(stmt, 6) }
            sqlite3_bind_double(stmt, 7, gap.firstSeenAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 8, gap.lastSeenAt.timeIntervalSinceReferenceDate)
            if let resolvedAt = gap.resolvedAt { sqlite3_bind_double(stmt, 9, resolvedAt.timeIntervalSinceReferenceDate) } else { sqlite3_bind_null(stmt, 9) }
            bind(stmt, 10, gap.sessionID)
        }
    }

    func saveLearningGoalRecord(_ payload: CloudKitLearningGoalPayload) throws {
        let mappedGoal = try remappedLearningGoalRecord(payload)
        try saveLearningGoalRecord(
            mappedGoal,
            replacingLinkedCourseIDs: payload.linkedCourseIDs
        )
    }

    /// Merge the monotonic learning evidence from both sides of a CloudKit
    /// `serverRecordChanged`. `preferLocalEditorial` chooses the ordinary
    /// user-editable scalar winner; completions, quiz history, gap identities,
    /// and relationship membership are never allowed to move backward.
    ///
    /// Returns whether the merged local payload differs from the server payload
    /// and therefore must be republished after adopting the server change tag.
    func mergeLearningGoalServerConflict(
        _ payload: CloudKitLearningGoalPayload,
        preferLocalEditorial: Bool
    ) throws -> Bool {
        let incoming = try remappedLearningGoalRecord(payload)
        guard let local = try loadLearningGoal(incoming.id) else {
            try saveLearningGoalRecord(
                incoming,
                replacingLinkedCourseIDs: payload.linkedCourseIDs
            )
            return false
        }
        let merged = mergedLearningGoal(
            local: local,
            incoming: incoming,
            preferLocalEditorial: preferLocalEditorial
        )
        let localLinkedCourseIDs = Set(try linkedCourseIDsForNotebook(goalID: incoming.id))
        let incomingLinkedCourseIDs = Set(payload.linkedCourseIDs ?? [])
        let mergedLinkedCourseIDs: [String]
        if preferLocalEditorial || payload.linkedCourseIDs == nil {
            // nil is an old payload with no opinion; a true explicit removal is
            // the present empty array and follows the editorial LWW winner.
            mergedLinkedCourseIDs = Array(localLinkedCourseIDs).sorted()
        } else {
            mergedLinkedCourseIDs = Array(incomingLinkedCourseIDs).sorted()
        }
        let differsFromServer = merged != incoming
            || Set(mergedLinkedCourseIDs) != incomingLinkedCourseIDs
        try saveLearningGoalRecord(
            merged,
            replacingLinkedCourseIDs: mergedLinkedCourseIDs
        )
        return differsFromServer
    }

    private func remappedLearningGoalRecord(
        _ payload: CloudKitLearningGoalPayload
    ) throws -> LearningGoalRecord {
        let mappedItems = try payload.goal.items.map { item in
            LearningGoalItem(
                id: item.id,
                goalID: item.goalID,
                sourceID: try resolveSourceID(item.sourceID, identities: payload.sourceIdentities),
                addedAt: item.addedAt,
                completedAt: item.completedAt,
                origin: item.origin,
                reviewState: item.reviewState,
                relevance: item.relevance,
                lastQuizzedAt: item.lastQuizzedAt,
                quizCount: item.quizCount,
                lastScore: item.lastScore,
                sequence: item.sequence
            )
        }
        var itemOrder: [String] = []
        var itemsBySourceID: [String: LearningGoalItem] = [:]
        for item in mappedItems {
            if var existing = itemsBySourceID[item.sourceID] {
                existing.addedAt = min(existing.addedAt, item.addedAt)
                switch (existing.completedAt, item.completedAt) {
                case let (left?, right?):
                    existing.completedAt = max(left, right)
                case (nil, let right?):
                    existing.completedAt = right
                default:
                    break
                }
                let existingQuizDate = existing.lastQuizzedAt
                let incomingQuizDate = item.lastQuizzedAt
                existing.lastQuizzedAt = maxOptionalDate(
                    existingQuizDate,
                    incomingQuizDate
                )
                existing.quizCount = maxOptionalInt(existing.quizCount, item.quizCount)
                switch (existingQuizDate, incomingQuizDate) {
                case let (left?, right?) where right > left:
                    existing.lastScore = item.lastScore ?? existing.lastScore
                case let (left?, right?) where left > right:
                    existing.lastScore = existing.lastScore ?? item.lastScore
                default:
                    existing.lastScore = maxOptionalDouble(
                        existing.lastScore,
                        item.lastScore
                    )
                }
                itemsBySourceID[item.sourceID] = existing
            } else {
                itemOrder.append(item.sourceID)
                itemsBySourceID[item.sourceID] = item
            }
        }
        let uniqueItems = itemOrder.compactMap { itemsBySourceID[$0] }
        let mappedGaps = try payload.goal.gaps?.map { gap in
            LearningGoalGap(
                id: gap.id,
                goalID: gap.goalID,
                summary: gap.summary,
                sourceID: try gap.sourceID.map {
                    try resolveSourceID($0, identities: payload.sourceIdentities)
                },
                status: gap.status,
                severity: gap.severity,
                firstSeenAt: gap.firstSeenAt,
                lastSeenAt: gap.lastSeenAt,
                resolvedAt: gap.resolvedAt,
                sessionID: gap.sessionID
            )
        }
        let mappedGoal = LearningGoalRecord(
            id: payload.goal.id,
            title: payload.goal.title,
            startAt: payload.goal.startAt,
            endAt: payload.goal.endAt,
            createdAt: payload.goal.createdAt,
            updatedAt: payload.goal.updatedAt,
            status: payload.goal.status,
            items: uniqueItems,
            kind: payload.goal.kind,
            description: payload.goal.description,
            summary: payload.goal.summary,
            topic: payload.goal.topic,
            discoveryEnabled: payload.goal.discoveryEnabled,
            dailyTarget: payload.goal.dailyTarget,
            lastQuizDate: payload.goal.lastQuizDate,
            lastDiscoveryAt: payload.goal.lastDiscoveryAt,
            gaps: mappedGaps,
            notes: payload.goal.notes,
            parentNotebookID: payload.goal.parentNotebookID,
            researchQuestions: payload.goal.researchQuestions,
            relatedNotebookIDs: payload.goal.relatedNotebookIDs,
            repository: payload.goal.repository,
            artifactID: payload.goal.artifactID,
            sortOrder: payload.goal.sortOrder
        )
        return mappedGoal
    }

    private func mergedLearningGoal(
        local: LearningGoalRecord,
        incoming: LearningGoalRecord,
        preferLocalEditorial: Bool
    ) -> LearningGoalRecord {
        let editorial = preferLocalEditorial ? local : incoming
        let items = mergedLearningGoalItems(
            local: local.items,
            incoming: incoming.items,
            goalID: incoming.id,
            preferLocalEditorial: preferLocalEditorial
        )
        let gaps = mergedLearningGoalGaps(
            local: local.gaps ?? [],
            incoming: incoming.gaps ?? [],
            goalID: incoming.id,
            preferLocalEditorial: preferLocalEditorial
        )
        return LearningGoalRecord(
            id: incoming.id,
            title: editorial.title,
            startAt: editorial.startAt,
            endAt: editorial.endAt,
            createdAt: min(local.createdAt, incoming.createdAt),
            updatedAt: max(local.updatedAt, incoming.updatedAt),
            status: editorial.status,
            items: items,
            kind: editorial.kind,
            description: editorial.description,
            summary: editorial.summary,
            topic: editorial.topic,
            discoveryEnabled: editorial.discoveryEnabled,
            dailyTarget: editorial.dailyTarget,
            lastQuizDate: maxOptionalString(local.lastQuizDate, incoming.lastQuizDate),
            lastDiscoveryAt: maxOptionalDate(local.lastDiscoveryAt, incoming.lastDiscoveryAt),
            gaps: gaps.isEmpty && local.gaps == nil && incoming.gaps == nil ? nil : gaps,
            notes: editorial.notes,
            parentNotebookID: editorial.parentNotebookID,
            researchQuestions: editorial.researchQuestions,
            relatedNotebookIDs: editorial.relatedNotebookIDs ?? local.relatedNotebookIDs,
            repository: editorial.repository ?? local.repository,
            artifactID: editorial.artifactID ?? local.artifactID,
            sortOrder: editorial.sortOrder ?? local.sortOrder
        )
    }

    private func mergedLearningGoalItems(
        local: [LearningGoalItem],
        incoming: [LearningGoalItem],
        goalID: String,
        preferLocalEditorial: Bool
    ) -> [LearningGoalItem] {
        let localBySource = Dictionary(local.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingBySource = Dictionary(incoming.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let retainedSourceIDs = preferLocalEditorial
            ? Set(localBySource.keys)
            : Set(incomingBySource.keys)
        return retainedSourceIDs.sorted().compactMap { sourceID in
            switch (localBySource[sourceID], incomingBySource[sourceID]) {
            case let (left?, right?):
                let editorial = preferLocalEditorial ? left : right
                let lastScore: Double?
                switch (left.lastQuizzedAt, right.lastQuizzedAt) {
                case let (leftDate?, rightDate?) where leftDate > rightDate:
                    lastScore = left.lastScore ?? right.lastScore
                case let (leftDate?, rightDate?) where rightDate > leftDate:
                    lastScore = right.lastScore ?? left.lastScore
                default:
                    lastScore = maxOptionalDouble(left.lastScore, right.lastScore)
                }
                return LearningGoalItem(
                    id: editorial.id,
                    goalID: goalID,
                    sourceID: sourceID,
                    addedAt: min(left.addedAt, right.addedAt),
                    completedAt: maxOptionalDate(left.completedAt, right.completedAt),
                    origin: editorial.origin,
                    reviewState: editorial.reviewState,
                    relevance: editorial.relevance,
                    lastQuizzedAt: maxOptionalDate(left.lastQuizzedAt, right.lastQuizzedAt),
                    quizCount: maxOptionalInt(left.quizCount, right.quizCount),
                    lastScore: lastScore,
                    sequence: editorial.sequence
                )
            case let (left?, nil):
                return LearningGoalItem(
                    id: left.id,
                    goalID: goalID,
                    sourceID: left.sourceID,
                    addedAt: left.addedAt,
                    completedAt: left.completedAt,
                    origin: left.origin,
                    reviewState: left.reviewState,
                    relevance: left.relevance,
                    lastQuizzedAt: left.lastQuizzedAt,
                    quizCount: left.quizCount,
                    lastScore: left.lastScore,
                    sequence: left.sequence
                )
            case let (nil, right?):
                return LearningGoalItem(
                    id: right.id,
                    goalID: goalID,
                    sourceID: right.sourceID,
                    addedAt: right.addedAt,
                    completedAt: right.completedAt,
                    origin: right.origin,
                    reviewState: right.reviewState,
                    relevance: right.relevance,
                    lastQuizzedAt: right.lastQuizzedAt,
                    quizCount: right.quizCount,
                    lastScore: right.lastScore,
                    sequence: right.sequence
                )
            case (nil, nil):
                return nil
            }
        }
    }

    private func mergedLearningGoalGaps(
        local: [LearningGoalGap],
        incoming: [LearningGoalGap],
        goalID: String,
        preferLocalEditorial: Bool
    ) -> [LearningGoalGap] {
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(localByID.keys).union(incomingByID.keys).sorted().compactMap { gapID in
            switch (localByID[gapID], incomingByID[gapID]) {
            case let (left?, right?):
                let editorial: LearningGoalGap
                if left.lastSeenAt > right.lastSeenAt {
                    editorial = left
                } else if right.lastSeenAt > left.lastSeenAt {
                    editorial = right
                } else {
                    editorial = preferLocalEditorial ? left : right
                }
                let resolvedAt = maxOptionalDate(left.resolvedAt, right.resolvedAt)
                let status = mergedGapStatus(left.status, right.status, resolvedAt: resolvedAt)
                return LearningGoalGap(
                    id: gapID,
                    goalID: goalID,
                    summary: editorial.summary,
                    sourceID: editorial.sourceID ?? left.sourceID ?? right.sourceID,
                    status: status,
                    severity: maxOptionalDouble(left.severity, right.severity),
                    firstSeenAt: min(left.firstSeenAt, right.firstSeenAt),
                    lastSeenAt: max(left.lastSeenAt, right.lastSeenAt),
                    resolvedAt: resolvedAt,
                    sessionID: editorial.sessionID ?? left.sessionID ?? right.sessionID
                )
            case let (left?, nil):
                return LearningGoalGap(
                    id: left.id,
                    goalID: goalID,
                    summary: left.summary,
                    sourceID: left.sourceID,
                    status: left.status,
                    severity: left.severity,
                    firstSeenAt: left.firstSeenAt,
                    lastSeenAt: left.lastSeenAt,
                    resolvedAt: left.resolvedAt,
                    sessionID: left.sessionID
                )
            case let (nil, right?):
                return LearningGoalGap(
                    id: right.id,
                    goalID: goalID,
                    summary: right.summary,
                    sourceID: right.sourceID,
                    status: right.status,
                    severity: right.severity,
                    firstSeenAt: right.firstSeenAt,
                    lastSeenAt: right.lastSeenAt,
                    resolvedAt: right.resolvedAt,
                    sessionID: right.sessionID
                )
            case (nil, nil):
                return nil
            }
        }
    }

    private func mergedGapStatus(
        _ left: String,
        _ right: String,
        resolvedAt: Date?
    ) -> String {
        if resolvedAt != nil || left == "resolved" || right == "resolved" {
            return "resolved"
        }
        if left == "improving" || right == "improving" {
            return "improving"
        }
        return left < right ? right : left
    }

    private func maxOptionalDate(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func maxOptionalDouble(_ left: Double?, _ right: Double?) -> Double? {
        switch (left, right) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func maxOptionalInt(_ left: Int?, _ right: Int?) -> Int? {
        switch (left, right) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private func maxOptionalString(_ left: String?, _ right: String?) -> String? {
        switch (left, right) {
        case let (left?, right?): return max(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    func loadLearningGoalForSync(_ goalID: String) throws -> CloudKitLearningGoalPayload? {
        guard let goal = try loadLearningGoal(goalID) else { return nil }
        let relationshipSourceIDs = dictUnique(
            goal.items.map(\.sourceID) + (goal.gaps ?? []).compactMap(\.sourceID)
        )
        return CloudKitLearningGoalPayload(
            goal: goal,
            sourceIdentities: try sourceIdentities(for: relationshipSourceIDs),
            linkedCourseIDs: try linkedCourseIDsForNotebook(goalID: goalID)
        )
    }

    func loadAllLearningGoalIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM learning_goals") { stmt in
            if let id = self.string(stmt, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    func readLearningGoalRow(_ stmt: OpaquePointer?) -> LearningGoalRecord? {
        guard let id = string(stmt, 0),
              let title = string(stmt, 1),
              let status = string(stmt, 6) else { return nil }
        let discoveryEnabled: Bool? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : (sqlite3_column_int64(stmt, 9) != 0)
        let dailyTarget: Int? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 10))
        let lastDiscoveryAt: Date? = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 12))
        var goal = LearningGoalRecord(
            id: id,
            title: title,
            startAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
            endAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5)),
            status: status,
            items: (try? loadLearningGoalItems(goalID: id)) ?? [],
            kind: string(stmt, 7),
            description: string(stmt, 14),
            topic: string(stmt, 8),
            discoveryEnabled: discoveryEnabled,
            dailyTarget: dailyTarget,
            lastQuizDate: string(stmt, 11),
            lastDiscoveryAt: lastDiscoveryAt,
            gaps: (try? loadLearningGoalGaps(goalID: id)) ?? [],
            notes: string(stmt, 13),
            parentNotebookID: string(stmt, 15),
            researchQuestions: Self.decodeResearchQuestions(string(stmt, 16)),
            relatedNotebookIDs: (try? relatedNotebookIDsForNotebook(notebookID: id)) ?? [],
            teamID: string(stmt, 17)
        )
        goal.summary = string(stmt, 18)
        goal.repository = string(stmt, 19)
        goal.artifactID = string(stmt, 20)
        goal.sortOrder = sqlite3_column_type(stmt, 21) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 21))
        return goal
    }

    func relatedNotebookIDsForNotebook(notebookID: String) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT related_notebook_id
            FROM notebook_related_notebook_links
            WHERE notebook_id = ?
            ORDER BY linked_at, related_notebook_id
        """, bind: { stmt in
            bind(stmt, 1, notebookID)
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Direct Notebook sources followed by each directly related Notebook's
    /// sources: the linked pool, every source a box beside the Notebook's
    /// sources can stand for (`NotebookChatContext.linkedPool`). Its chats
    /// read a related Notebook's only while the learner has put it in
    /// (`NotebookChatContext.chatPool`). Links are intentionally one hop: a
    /// Notebook controls its own context boundary and does not silently
    /// inherit a remote graph.
    func notebookContextSourceIDs(notebookID: String) throws -> [String] {
        guard let notebook = try loadLearningGoal(notebookID), notebook.isNotebook else { return [] }
        var ids = notebook.approvedSourceIDs
        for relatedID in notebook.relatedNotebookIDs ?? [] {
            guard let related = try loadLearningGoal(relatedID), related.isNotebook else { continue }
            ids.append(contentsOf: related.approvedSourceIDs)
        }
        return dictUnique(ids)
    }

    /// Replace a Notebook's directional context links. Notebooks stay flat and
    /// their source memberships remain independent.
    func setRelatedNotebooks(notebookID: String, relatedNotebookIDs: [String]) throws {
        guard let notebook = try loadLearningGoal(notebookID), notebook.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(notebookID)")
        }
        let ids = dictUnique(relatedNotebookIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        guard ids.count <= 50 else {
            throw KnowledgeStoreError.invalidData("A Notebook can link at most 50 related Notebooks.")
        }
        guard !ids.contains(notebookID) else {
            throw KnowledgeStoreError.invalidData("A Notebook cannot link to itself.")
        }
        for id in ids {
            guard let related = try loadLearningGoal(id), related.isNotebook else {
                throw KnowledgeStoreError.invalidData("Related Notebook not found: \(id)")
            }
        }

        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            try replaceRelatedNotebookLinksInCurrentTransaction(
                notebookID: notebookID,
                relatedNotebookIDs: ids,
                linkedAt: now
            )
            try touchLearningGoal(notebookID, at: now)
            try markRecordChanged(entity: .learningGoal, logicalKey: notebookID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Each link is stamped a millisecond after the one before it, so the
    /// order the caller gave (`ORDER BY linked_at` in
    /// `relatedNotebookIDsForNotebook`) is the order read back: a notebook's
    /// context notebooks are listed, and read into its chats, in link order,
    /// the same on every device the record reaches. One stamp for all fell
    /// back to the ids' order.
    private func replaceRelatedNotebookLinksInCurrentTransaction(
        notebookID: String,
        relatedNotebookIDs: [String],
        linkedAt: Date
    ) throws {
        try execBind("DELETE FROM notebook_related_notebook_links WHERE notebook_id = ?") { stmt in
            bind(stmt, 1, notebookID)
        }
        let ids = dictUnique(relatedNotebookIDs).filter { $0 != notebookID }
        for (index, relatedID) in ids.enumerated() {
            try execBind("""
                INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at)
                VALUES (?, ?, ?)
            """) { stmt in
                bind(stmt, 1, notebookID)
                bind(stmt, 2, relatedID)
                sqlite3_bind_double(stmt, 3, linkedAt.timeIntervalSinceReferenceDate + Double(index) / 1_000)
            }
        }
    }

    /// research_questions column codec: a JSON string array, kept nil (never
    /// "[]") for never-set so sync can tell no-opinion from explicitly empty.
    static func decodeResearchQuestions(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    static func encodeResearchQuestions(_ questions: [String]) -> String {
        guard let data = try? JSONEncoder().encode(questions),
              let encoded = String(data: data, encoding: .utf8) else { return "[]" }
        return encoded
    }

    func loadLearningGoalGaps(goalID: String) throws -> [LearningGoalGap] {
        var gaps: [LearningGoalGap] = []
        try queryBind("""
            SELECT id, goal_id, summary, source_id, status, severity, first_seen_at, last_seen_at, resolved_at, session_id
            FROM learning_goal_gaps
            WHERE goal_id = ?
            ORDER BY first_seen_at ASC
        """, bind: { stmt in
            bind(stmt, 1, goalID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let goalID = self.string(stmt, 1),
                  let summary = self.string(stmt, 2),
                  let status = self.string(stmt, 4) else { return }
            gaps.append(
                LearningGoalGap(
                    id: id,
                    goalID: goalID,
                    summary: summary,
                    sourceID: self.string(stmt, 3),
                    status: status,
                    severity: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5),
                    firstSeenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6)),
                    lastSeenAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7)),
                    resolvedAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
                    sessionID: self.string(stmt, 9)
                )
            )
        }
        return gaps
    }

    func loadLearningGoalItems(goalID: String) throws -> [LearningGoalItem] {
        var items: [LearningGoalItem] = []
        try queryBind("""
            SELECT id, goal_id, source_id, added_at, completed_at, origin, review_state, relevance, last_quizzed_at, quiz_count, last_score, sequence
            FROM learning_goal_items
            WHERE goal_id = ?
            ORDER BY (sequence IS NULL) ASC, sequence ASC, added_at ASC, source_id ASC
        """, bind: { stmt in
            bind(stmt, 1, goalID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let goalID = self.string(stmt, 1),
                  let sourceID = self.string(stmt, 2) else { return }
            items.append(
                LearningGoalItem(
                    id: id,
                    goalID: goalID,
                    sourceID: sourceID,
                    addedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                    completedAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                    origin: self.string(stmt, 5),
                    reviewState: self.string(stmt, 6),
                    relevance: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7),
                    lastQuizzedAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
                    quizCount: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 9)),
                    lastScore: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 10),
                    sequence: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 11)
                )
            )
        }
        return items
    }

    func insertLearningGoalItem(
        goalID: String,
        sourceID: String,
        addedAt: Date = Date(),
        origin: String? = nil,
        reviewState: String? = nil,
        relevance: Double? = nil
    ) throws {
        let item = LearningGoalItem(
            id: UUID().uuidString,
            goalID: goalID,
            sourceID: sourceID,
            addedAt: addedAt,
            completedAt: nil,
            origin: origin,
            reviewState: reviewState,
            relevance: relevance
        )
        try saveLearningGoalItem(item, goalID: goalID, ignoreDuplicates: true)
    }

    /// Under generation 2 a new item takes `orderKey`, or a key after the pool's last, so its Entry
    /// has its place (schema v2 §3.5.8); generation 1 writes no key.
    func saveLearningGoalItem(_ item: LearningGoalItem, goalID: String, ignoreDuplicates: Bool = false, orderKey: String? = nil) throws {
        let insertVerb = ignoreDuplicates ? "INSERT OR IGNORE" : "INSERT"
        // Generation 1 never names the column, which a store held below 154 does not have.
        let key = syncGeneration == .two ? try orderKey ?? EntryOrderKeys.appendedKey(goalID: goalID, connection: self) : nil
        let keyColumn = syncGeneration == .two ? ", order_key" : ""
        let keyValue = syncGeneration == .two ? ", ?" : ""
        try execBind("""
            \(insertVerb) INTO learning_goal_items (id, goal_id, source_id, added_at, completed_at, origin, review_state, relevance, last_quizzed_at, quiz_count, last_score, sequence\(keyColumn))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?\(keyValue))
        """) { stmt in
            bind(stmt, 1, item.id)
            bind(stmt, 2, goalID)
            bind(stmt, 3, item.sourceID)
            sqlite3_bind_double(stmt, 4, item.addedAt.timeIntervalSinceReferenceDate)
            if let completedAt = item.completedAt {
                sqlite3_bind_double(stmt, 5, completedAt.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            bind(stmt, 6, item.origin)
            bind(stmt, 7, item.reviewState)
            if let relevance = item.relevance { sqlite3_bind_double(stmt, 8, relevance) } else { sqlite3_bind_null(stmt, 8) }
            if let lastQuizzedAt = item.lastQuizzedAt { sqlite3_bind_double(stmt, 9, lastQuizzedAt.timeIntervalSinceReferenceDate) } else { sqlite3_bind_null(stmt, 9) }
            if let quizCount = item.quizCount { sqlite3_bind_int64(stmt, 10, Int64(quizCount)) } else { sqlite3_bind_null(stmt, 10) }
            if let lastScore = item.lastScore { sqlite3_bind_double(stmt, 11, lastScore) } else { sqlite3_bind_null(stmt, 11) }
            if let sequence = item.sequence { sqlite3_bind_double(stmt, 12, sequence) } else { sqlite3_bind_null(stmt, 12) }
            if syncGeneration == .two { bind(stmt, 13, key) }
        }
    }

    func learningGoalItemPlannedDate(_ date: Date, order: Int) -> Date {
        let day = Calendar.current.startOfDay(for: date)
        return day.addingTimeInterval(Double(min(max(order, 0), 86_399)))
    }

    func touchLearningGoal(_ goalID: String, at date: Date = Date()) throws {
        try execBind("UPDATE learning_goals SET updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSinceReferenceDate)
            bind(stmt, 2, goalID)
        }
    }

    /// Rename a Notebook or Goal without rewriting any of its semantic settings.
    /// In particular, a display-name edit must not silently change the discovery topic.
    func setLearningGoalTitle(goalID: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KnowledgeStoreError.invalidData("Learning goal title is required.")
        }
        guard let goal = try loadLearningGoal(goalID), goal.isCompanion else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }

        let now = Date()
        try execBind("UPDATE learning_goals SET title = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, trimmed)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: now)
    }

    /// Replace the short user-authored Notebook instructions stored in the
    /// existing description column. Nil or whitespace clears the value.
    func setLearningGoalDescription(goalID: String, description: String?) throws {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed?.isEmpty == false ? trimmed : nil
        let now = Date()
        try execBind("UPDATE learning_goals SET description = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, resolved)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: now)
    }

    /// Replace a Notebook's short description — the gallery card copy. Nil or
    /// whitespace clears it. Single-line by design: newlines collapse to spaces
    /// so the card never grows past its two lines.
    func setLearningGoalSummary(goalID: String, summary: String?) throws {
        guard let goal = try loadLearningGoal(goalID), goal.isCompanion else {
            throw KnowledgeStoreError.invalidData("Learning Companion goal not found: \(goalID)")
        }
        let now = Date()
        try execBind("UPDATE learning_goals SET summary = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, Self.normalizedSummary(summary))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: now)
    }

    /// The stored form of a Notebook summary: whitespace runs (including line
    /// breaks) collapsed to one space, trimmed, capped, nil when empty. The
    /// rule lives in Portable so the phone writes the identical form.
    static func normalizedSummary(_ raw: String?) -> String? {
        NotebookSummary.normalized(raw)
    }

    /// Link a Notebook to the GitHub repository it is about, or unlink it. The
    /// value is whatever the learner typed — `owner/repo`, `owner/repo.git`, or
    /// a github.com URL — and is stored in canonical `owner/repo` form; nil or
    /// whitespace unlinks. An entry that does not name a repository is refused
    /// with the accepted forms, and nothing changes. An unlink is stored as ''
    /// rather than NULL so it travels as an explicit clear (the sync upsert's
    /// COALESCE keeps the local value only for NULL, an older device's no-opinion).
    func setNotebookRepository(notebookID: String, repository: String?) throws {
        guard let notebook = try loadLearningGoal(notebookID), notebook.isNotebook else {
            throw KnowledgeStoreError.invalidData("Notebook not found: \(notebookID)")
        }
        let trimmed = repository?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stored: String
        if trimmed.isEmpty {
            stored = ""
        } else if let normalized = LearningGoalRecord.normalizedRepository(trimmed) {
            stored = normalized
        } else {
            throw KnowledgeStoreError.invalidData(Self.repositoryFormatRefusal(trimmed))
        }
        let now = Date()
        try execBind("UPDATE learning_goals SET repository = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, stored)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, notebookID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: notebookID, at: now)
    }

    /// Link a Goal to the artifact it is for — the Doc, Site or animation
    /// that is its deliverable — or unlink it with nil or whitespace. The
    /// artifact must be a record in this library; an id that names none is
    /// refused and nothing changes. An unlink is stored as '' rather than
    /// NULL so it travels as an explicit clear (the sync upsert's COALESCE
    /// keeps the local value only for NULL, an older device's no-opinion).
    /// A Notebook is refused: an open-ended pool is not *for* one artifact,
    /// its artifacts are linked the other way round, from the record.
    func setLearningGoalArtifact(goalID: String, artifactID: String?) throws {
        guard let goal = try loadLearningGoal(goalID), goal.isGoal else {
            throw KnowledgeStoreError.invalidData("Timebound Goal not found: \(goalID)")
        }
        let stored = try Self.resolvedGoalArtifactID(artifactID, load: loadArtifact) ?? ""
        let now = Date()
        try execBind("UPDATE learning_goals SET artifact_id = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, stored)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goal.id)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goal.id, at: now)
    }

    /// Put the learner's Goals in an order (product owner, 2026-09-20: "allow me to
    /// reshuffle these"). The listed Goals come first, in the order given;
    /// every other open Goal follows in the order it already reads
    /// (`LearningGoalRecord.listOrder`), so a subset — one band of the tab,
    /// or the three the assistant was asked about — places itself without
    /// scrambling the rest. An empty list clears every placement, and the
    /// list reads by deadline again. Each id must name a timebound Goal in
    /// this store; a Notebook, a finished Goal or an unknown id refuses the
    /// whole call and nothing changes. Only a row whose placement actually
    /// moves is written and published, so putting a list back as it was
    /// costs nothing over sync. Returns the ids in their final order.
    @discardableResult
    func reorderLearningGoals(goalIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        let listed = goalIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let goals = try loadLearningGoals().filter { $0.isGoal }
        let byID = Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0) })
        for id in listed {
            guard let goal = byID[id] else {
                throw KnowledgeStoreError.invalidData("Timebound Goal not found: \(id)")
            }
            guard !(goal.isDone || goal.isArchived) else {
                throw KnowledgeStoreError.invalidData("\(goal.title) is finished; only an open Goal can be placed.")
            }
        }
        let listedSet = Set(listed)
        let rest = goals
            .filter { !listedSet.contains($0.id) && !($0.isDone || $0.isArchived) }
            .map { goal -> LearningGoalRecord in
                // A cleared list forgets every placement, so the order
                // answered is the one the list reads afterwards: by deadline.
                guard listed.isEmpty else { return goal }
                var unplaced = goal
                unplaced.sortOrder = nil
                return unplaced
            }
            .sorted(by: LearningGoalRecord.listOrder)
            .map(\.id)
        let order = listed + rest
        // Placements are the index in the final order; a cleared list is
        // NULL on every open row, which reads by deadline.
        let placements: [(id: String, position: Int?)] = listed.isEmpty
            ? rest.map { ($0, nil) }
            : order.enumerated().map { ($0.element, $0.offset) }
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            for (id, position) in placements where byID[id]?.sortOrder != position {
                try execBind("UPDATE learning_goals SET sort_order = ?, updated_at = ? WHERE id = ?") { stmt in
                    if let position { sqlite3_bind_int64(stmt, 1, Int64(position)) } else { sqlite3_bind_null(stmt, 1) }
                    sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 3, id)
                }
                try markRecordChanged(entity: .learningGoal, logicalKey: id, at: now)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return order
    }

    /// The artifact id a Goal may store: nil for nil or whitespace (no link),
    /// the trimmed id when `load` finds the record, and a refusal naming the
    /// id otherwise. Shared by creation and the setter so both refuse in the
    /// same words.
    static func resolvedGoalArtifactID(
        _ raw: String?,
        load: (String) throws -> ArtifactRecord?
    ) throws -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard try load(trimmed) != nil else {
            throw KnowledgeStoreError.invalidData(goalArtifactRefusal(trimmed))
        }
        return trimmed
    }

    /// The one sentence every surface shows for an artifact id that names no
    /// Doc, Site or animation in the library.
    static func goalArtifactRefusal(_ raw: String) -> String {
        "No Doc, Site or animation with id \(raw). Use list_docs or list_animations to find one."
    }

    /// The one sentence every surface shows for an entry that is not a GitHub
    /// repository, so the app, MCP and the phone refuse in the same words.
    static func repositoryFormatRefusal(_ raw: String) -> String {
        "\"\(raw)\" is not a GitHub repository. Use owner/repo, owner/repo.git, or a github.com URL such as https://github.com/owner/repo."
    }

    /// Replace a Notebook's (learning goal's) synthesis notes markdown.
    /// The Internal Review writes here.
    func setLearningGoalNotes(goalID: String, notes: String) throws {
        let now = Date()
        try execBind("UPDATE learning_goals SET notes = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, notes)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: now)
    }

    /// Replaces the Notebook's defining research questions. An empty list is
    /// stored as "[]" (an explicit clear, distinct from never-set NULL) so the
    /// sync upsert's COALESCE guard lets it propagate.
    func setLearningGoalResearchQuestions(goalID: String, questions: [String]) throws {
        let now = Date()
        try execBind("UPDATE learning_goals SET research_questions = ?, updated_at = ? WHERE id = ?") { stmt in
            bind(stmt, 1, Self.encodeResearchQuestions(questions))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, goalID)
        }
        try keepNotebookRowsForGeneration2(goalIDs: [goalID])
        try markRecordChanged(entity: .learningGoal, logicalKey: goalID, at: now)
    }

    func dictUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    func replaceReviewSessionSources(
        sessionID: String,
        sourceIDs: [String],
        allowMissingSources: Bool = false
    ) throws {
        // A memory review's material may be a chat (docs/memory-design.md,
        // "Chats as evidence"), which is review material under its own session
        // id without being a `sources` row. The record's `source_ids` keeps the
        // whole list; the junction, whose foreign key points at `sources`,
        // notebooks only the ids that are sources — the same tolerance an
        // inbound sync record gets for a Source that has not landed yet.
        let notebookOnlyExistingSources = allowMissingSources
            || MemoryReviewSession.isMemorySession(sessionID)
        try execBind("DELETE FROM review_session_sources WHERE session_id = ?", { stmt in
            bind(stmt, 1, sessionID)
        })
        for sourceID in sourceIDs {
            if notebookOnlyExistingSources {
                try execBind("""
                    INSERT OR IGNORE INTO review_session_sources (session_id, source_id)
                    SELECT ?, id FROM sources WHERE id = ?
                """) { stmt in
                    bind(stmt, 1, sessionID)
                    bind(stmt, 2, sourceID)
                }
            } else {
                try execBind("INSERT OR IGNORE INTO review_session_sources (session_id, source_id) VALUES (?, ?)", { stmt in
                    bind(stmt, 1, sessionID)
                    bind(stmt, 2, sourceID)
                })
            }
        }
    }

    /// Complete the junction projection for sessions that arrived before this
    /// Source. The canonical `source_ids` JSON intentionally retained the
    /// relationship while its foreign-key target was unavailable.
    func restoreDeferredReviewSessionSourceLinks(sourceID: String) throws {
        try execBind("""
            INSERT OR IGNORE INTO review_session_sources (session_id, source_id)
            SELECT fs.id, ?
            FROM review_sessions fs,
                 json_each(
                     CASE WHEN json_valid(fs.source_ids)
                          THEN fs.source_ids ELSE '[]' END
                 ) relationship
            WHERE relationship.type = 'text'
              AND relationship.value = ?
        """) { stmt in
            bind(stmt, 1, sourceID)
            bind(stmt, 2, sourceID)
        }
    }

    func reviewSessionSourceIDsBySessionID() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        try query("""
            SELECT session_id, source_id
            FROM review_session_sources
            ORDER BY session_id, source_id
        """) { stmt in
            guard let sessionID = self.string(stmt, 0),
                  let sourceID = self.string(stmt, 1) else { return }
            result[sessionID, default: []].append(sourceID)
        }
        return result
    }

    func loadReviewExchanges(sessionID: String) throws -> [CloudKitReviewExchangePayload] {
        var exchanges: [CloudKitReviewExchangePayload] = []
        try queryBind("""
            SELECT id, session_id, sequence_number, question, user_answer, evaluation, score, source_refs, knowledge_note, answered_at, context_content,
                   idea_coverage, question_verdict, operation, steer,
                   rating, rating_reason, rating_field, rated_at
            FROM review_exchanges
            WHERE session_id = ?
            ORDER BY sequence_number ASC
        """, bind: { stmt in
            bind(stmt, 1, sessionID)
        }) { stmt in
            guard let id = self.string(stmt, 0),
                  let sessionID = self.string(stmt, 1),
                  let question = self.string(stmt, 3) else { return }
            exchanges.append(
                CloudKitReviewExchangePayload(
                    id: id,
                    sessionID: sessionID,
                    sequenceNumber: Int(sqlite3_column_int(stmt, 2)),
                    question: question,
                    userAnswer: self.string(stmt, 4),
                    evaluation: self.string(stmt, 5),
                    score: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6),
                    sourceRefs: self.decodeStringArray(json: self.string(stmt, 7)) ?? [],
                    knowledgeNote: self.string(stmt, 8),
                    answeredAt: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 9)),
                    contextContent: self.string(stmt, 10),
                    ideaCoverage: self.string(stmt, 11),
                    questionVerdict: self.string(stmt, 12),
                    operation: self.string(stmt, 13),
                    steer: self.string(stmt, 14),
                    rating: self.string(stmt, 15),
                    ratingReason: self.string(stmt, 16),
                    ratingField: self.string(stmt, 17),
                    ratedAt: sqlite3_column_type(stmt, 18) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 18))
                )
            )
        }
        return exchanges
    }

    // MARK: - Shared Schedule Placements

    /// A source's calendar placement (one per source). nil if the source is not scheduled.
    func scheduledSourceID(forSource sourceID: String) throws -> String? {
        var id: String?
        let keys = try personalStateSourceKeys(sourceID)
        try queryBind("SELECT id FROM scheduled_sources WHERE source_id IN (\(Array(repeating: "?", count: keys.count).joined(separator: ", "))) LIMIT 1", bind: { stmt in
            for (offset, key) in keys.enumerated() { bind(stmt, offset + 1, key) }
        }) { stmt in
            id = self.string(stmt, 0)
        }
        return id
    }

    func scheduledSourceGoalCount(placementID: String) throws -> Int {
        var count = 0
        try queryBind("SELECT COUNT(*) FROM scheduled_source_goals WHERE scheduled_source_id = ?", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Every Goal and Notebook a source's placement is tagged with.
    func scheduledSourceGoalIDs(sourceID: String) throws -> [String] {
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return [] }
        var ids: [String] = []
        try queryBind("SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = ? ORDER BY added_at ASC", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            if let goalID = self.string(stmt, 0) { ids.append(goalID) }
        }
        return ids
    }

    /// Next free order-offset for a placement landing on `day`, so same-day placements stay distinct.
    func nextScheduledSourceOrder(day: Date, excludingSourceID sourceID: String) throws -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(24 * 60 * 60)
        var existing: [Date] = []
        try queryBind("""
            SELECT planned_at FROM scheduled_sources
            WHERE source_id != ? AND planned_at >= ? AND planned_at < ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_double(stmt, 2, dayStart.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 3, dayEnd.timeIntervalSinceReferenceDate)
        }) { stmt in
            existing.append(Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0)))
        }
        guard let maxOffset = existing.map({ Int($0.timeIntervalSince(dayStart).rounded(.down)) }).max() else { return 0 }
        return min(maxOffset + 1, 86_399)
    }

    /// The source_id a placement row currently belongs to, if that row exists.
    private func scheduledSourcePlacementOwner(placementID: String) throws -> String? {
        var owner: String?
        try queryBind("SELECT source_id FROM scheduled_sources WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            owner = self.string(stmt, 0)
        }
        return owner
    }

    private func sourceRowExists(_ sourceID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM sources WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { _ in
            found = true
        }
        return found
    }

    /// Create the placement row for a source if it does not exist yet. Returns its id.
    /// Does not emit sync changes — callers do, after COMMIT.
    private func ensureScheduledSourcePlacement(sourceID: String, plannedAt: Date, now: Date) throws -> String {
        if let existing = try scheduledSourceID(forSource: sourceID) { return existing }
        if syncGeneration == .two {
            // Generation 2: the row is the Placement record's, `pl:<source wire id>` on the wire id
            // (§3.5.21), so every Mac and copy names one placement per work.
            let key = try personalStateSourceKey(sourceID)
            let id = SyncIdentity.placementID(sourceID: key)
            try insertScheduledSourcePlacement(id: id, sourceID: key, plannedAt: plannedAt, now: now)
            return id
        }
        let portableSourceKey = try portableMemorySourceKey(sourceID: sourceID)
        let id = MemoryTutorIdentity.scheduledSourcePlacementID(
            portableSourceKey: portableSourceKey
        )

        // The id is a digest of the *portable* key — the paper's DOI or normalized
        // URL — while the guard above asks by source_id. Re-importing a paper gives
        // it a new source row and leaves the old placement behind, so the two
        // disagree and the INSERT below used to fail the whole call with
        // `UNIQUE constraint failed: scheduled_sources.id`. On 2026-09-18 that made
        // get_source_content unable to read a paper that had just been unarchived,
        // with 11 such orphaned placements in the production store.
        if let owner = try scheduledSourcePlacementOwner(placementID: id) {
            // Adopt an orphan: its source is gone, and this one is the same paper.
            // A placement whose source is still here belongs to that source; reuse
            // the row rather than taking it away from a live sibling.
            if try !sourceRowExists(owner) {
                try execBind("UPDATE scheduled_sources SET source_id = ?, updated_at = ? WHERE id = ?") { stmt in
                    bind(stmt, 1, sourceID)
                    sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 3, id)
                }
            }
            return id
        }

        try insertScheduledSourcePlacement(id: id, sourceID: sourceID, plannedAt: plannedAt, now: now)
        return id
    }

    private func insertScheduledSourcePlacement(id: String, sourceID: String, plannedAt: Date, now: Date) throws {
        let plannedDay = Calendar.current.startOfDay(for: plannedAt)
        let order = try nextScheduledSourceOrder(day: plannedDay, excludingSourceID: sourceID)
        let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
        try execBind("""
            INSERT INTO scheduled_sources (id, source_id, planned_at, added_at, completed_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, NULL, ?, ?)
        """) { stmt in
            bind(stmt, 1, id)
            bind(stmt, 2, sourceID)
            sqlite3_bind_double(stmt, 3, encoded.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 5, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 6, now.timeIntervalSinceReferenceDate)
        }
    }

    func sourceActivityMask(_ kinds: Set<SourceActivityKind>) -> Int64 {
        kinds.reduce(into: Int64(0)) { mask, kind in
            guard let index = SourceActivityKind.allCases.firstIndex(of: kind) else { return }
            mask |= Int64(1) << Int64(index)
        }
    }

    private func sourceActivityKinds(mask: Int64) -> Set<SourceActivityKind> {
        Set(SourceActivityKind.allCases.enumerated().compactMap { index, kind in
            (mask & (Int64(1) << Int64(index))) == 0 ? nil : kind
        })
    }

    private func readSourceActivityDay(_ stmt: OpaquePointer?) -> SourceActivityDay? {
        guard let id = string(stmt, 0), let sourceID = string(stmt, 1) else { return nil }
        return SourceActivityDay(
            id: id,
            sourceID: sourceID,
            dayStart: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
            firstActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            lastActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
            kinds: sourceActivityKinds(mask: sqlite3_column_int64(stmt, 5)),
            completedKinds: sourceActivityKinds(mask: sqlite3_column_int64(stmt, 6)),
            maxFraction: SourceActivityDay.clampFraction(sqlite3_column_double(stmt, 7)),
            engagedSeconds: SourceActivityDay.clampSeconds(sqlite3_column_double(stmt, 8))
        )
    }

    /// The learner's consumption history, newest day first: what was read,
    /// listened to, watched, discussed, or reviewed on each day, joined to the
    /// source it happened on.
    ///
    /// Reads `source_activity_days` directly rather than going through
    /// placements: every activity row belongs here regardless of whether the
    /// source was ever planned, and a plan with no activity is not history.
    /// Archived and hidden sources keep their rows — the day still happened.
    /// `since` keeps to days starting at or after it (the History pane reads
    /// the same window of days as the log it lays these beside).
    func loadSourceConsumptionHistory(limit: Int = 500, since: Date? = nil) throws -> [SourceConsumptionEntry] {
        var rows: [SourceConsumptionEntry] = []
        let boundedLimit = min(max(limit, 1), 5_000)
        try queryBind("""
            SELECT sad.id, sad.source_id, sad.day_start, sad.first_activity_at, sad.last_activity_at,
                   sad.kinds, sad.completed_kinds, sad.max_fraction,
                   sp.title, sp.source_type, sp.domain,
                   COALESCE(sp.parent_group_title, sp.parent_group) AS group_title,
                   sp.status, sad.engaged_seconds
            FROM source_activity_days sad
            LEFT JOIN source_projection sp ON sp.id = sad.source_id
            WHERE sad.day_start >= ?
            ORDER BY sad.day_start DESC, sad.last_activity_at DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, since?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude)
            sqlite3_bind_int(stmt, 2, Int32(boundedLimit))
        }) { stmt in
            guard let id = self.string(stmt, 0), let sourceID = self.string(stmt, 1) else { return }
            rows.append(
                SourceConsumptionEntry(
                    id: id,
                    sourceID: sourceID,
                    dayStart: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
                    firstActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                    lastActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                    kinds: self.sourceActivityKinds(mask: sqlite3_column_int64(stmt, 5)),
                    completedKinds: self.sourceActivityKinds(mask: sqlite3_column_int64(stmt, 6)),
                    maxFraction: SourceActivityDay.clampFraction(sqlite3_column_double(stmt, 7)),
                    title: self.string(stmt, 8),
                    sourceType: self.string(stmt, 9),
                    domain: self.string(stmt, 10),
                    groupTitle: self.string(stmt, 11),
                    isArchived: self.string(stmt, 12) == "archived",
                    engagedSeconds: SourceActivityDay.clampSeconds(sqlite3_column_double(stmt, 13))
                )
            )
        }
        return rows
    }

    /// The sources the learner spent real time with since `since`, newest
    /// first: what "Read next" measures the rest of the library against.
    /// A source whose days add up to less than a glance
    /// (`DayPlan.activityGlanceMinutes`) is left out unless something on it
    /// was finished, so a paper opened and closed does not steer the picks.
    /// Rows from before schema 94 carry no measured seconds; their activity
    /// span stands in, as it does on the History pane.
    func recentReadingSourceIDs(since: Date, limit: Int) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT source_id
            FROM source_activity_days
            WHERE day_start >= ?
            GROUP BY source_id
            HAVING SUM(CASE WHEN engaged_seconds > 0 THEN engaged_seconds
                            ELSE MAX(0, last_activity_at - first_activity_at) END) >= ?
                OR MAX(completed_kinds) > 0
            ORDER BY MAX(last_activity_at) DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, Double(DayPlan.activityGlanceMinutes * 60))
            sqlite3_bind_int(stmt, 3, Int32(max(limit, 1)))
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Every source the learner has already been into: any recorded activity
    /// day, a `read_at` stamp, or a consumed mark. "Read next" offers only
    /// sources outside this set.
    func touchedSourceIDs() throws -> Set<String> {
        var ids = Set<String>()
        if keepsReadingStates {
            ids.formUnion(try readOrConsumedSourceIDs())
            try query("SELECT source_id FROM source_activity_days") { stmt in
                if let id = self.string(stmt, 0) { ids.insert(id) }
            }
            return ids
        }
        try query("""
            SELECT id FROM sources WHERE read_at IS NOT NULL OR is_consumed = 1
            UNION
            SELECT source_id FROM source_activity_days
        """) { stmt in
            if let id = self.string(stmt, 0) { ids.insert(id) }
        }
        return ids
    }

    func loadSourceActivityDays(sourceID: String? = nil) throws -> [SourceActivityDay] {
        var rows: [SourceActivityDay] = []
        if let sourceID {
            try queryBind("""
                SELECT id, source_id, day_start, first_activity_at, last_activity_at,
                       kinds, completed_kinds, max_fraction, engaged_seconds
                FROM source_activity_days
                WHERE source_id = ?
                ORDER BY day_start ASC
            """, bind: { stmt in
                bind(stmt, 1, sourceID)
            }) { stmt in
                if let row = self.readSourceActivityDay(stmt) { rows.append(row) }
            }
        } else {
            try query("""
                SELECT id, source_id, day_start, first_activity_at, last_activity_at,
                       kinds, completed_kinds, max_fraction, engaged_seconds
                FROM source_activity_days
                ORDER BY day_start ASC
            """) { stmt in
                if let row = self.readSourceActivityDay(stmt) { rows.append(row) }
            }
        }
        return rows
    }

    private func sourceActivityDayCount(sourceID: String) throws -> Int {
        var count = 0
        try queryBind("SELECT COUNT(*) FROM source_activity_days WHERE source_id = ?", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    private func scheduledSourceHasActivity(placementID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM source_activity_days WHERE scheduled_source_id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { _ in found = true }
        return found
    }

    private func scheduledSourceIsAutomatic(placementID: String) throws -> Bool {
        var automatic = false
        try queryBind(
            "SELECT is_automatic FROM scheduled_sources WHERE id = ? LIMIT 1",
            bind: { stmt in bind(stmt, 1, placementID) }
        ) { stmt in
            automatic = sqlite3_column_int(stmt, 0) != 0
        }
        return automatic
    }

    private func setScheduledSourceAutomatic(
        placementID: String,
        isAutomatic: Bool
    ) throws {
        try execBind(
            "UPDATE scheduled_sources SET is_automatic = ? WHERE id = ?",
            { stmt in
                sqlite3_bind_int(stmt, 1, isAutomatic ? 1 : 0)
                bind(stmt, 2, placementID)
            }
        )
    }

    private func convertPlacementToAutomaticHistory(
        placementID: String,
        sourceID: String,
        at changedAt: Date
    ) throws {
        var latestActivityAt: Date?
        try queryBind("""
            SELECT last_activity_at FROM source_activity_days
            WHERE scheduled_source_id = ?
            ORDER BY last_activity_at DESC LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            latestActivityAt = Date(
                timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0)
            )
        }
        guard let latestActivityAt else { return }
        let latestDay = Calendar.current.startOfDay(for: latestActivityAt)
        let order = try nextScheduledSourceOrder(
            day: latestDay,
            excludingSourceID: sourceID
        )
        let plannedAt = learningGoalItemPlannedDate(latestDay, order: order)
        try execBind("""
            UPDATE scheduled_sources
            SET planned_at = ?, updated_at = ?, is_automatic = 1
            WHERE id = ?
        """) { stmt in
            sqlite3_bind_double(stmt, 1, plannedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, changedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 3, placementID)
        }
    }

    @discardableResult
    private func recordSourceActivityDayRows(
        placementID: String,
        sourceID: String,
        kind: SourceActivityKind,
        occurredAt: Date,
        completed: Bool,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) throws -> Bool {
        let dayStart = Calendar.current.startOfDay(for: occurredAt)
        let portableSourceKey = try portableMemorySourceKey(sourceID: sourceID)
        let activityID = MemoryTutorIdentity.sourceActivityDayID(
            portableSourceKey: portableSourceKey,
            dayStart: dayStart
        )
        // Another copy of the work (a team copy) may hold the day's id; the day's row becomes this copy's.
        try adoptSourceActivityDayRow(id: activityID, sourceID: sourceID, dayStart: dayStart.timeIntervalSinceReferenceDate)
        var existed = false
        try queryBind("""
            SELECT 1 FROM source_activity_days
            WHERE source_id = ? AND day_start = ? LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_double(stmt, 2, dayStart.timeIntervalSinceReferenceDate)
        }) { _ in existed = true }
        let kindMask = sourceActivityMask([kind])
        let completedMask = completed ? kindMask : 0
        // Engaged seconds accrue: each heartbeat or playback tick adds its
        // slice to the day's total. The cross-device merge in
        // `replaceSourceActivityDays` takes MAX instead, so a synced total is
        // never added to itself.
        try execBind("""
            INSERT INTO source_activity_days (
                id, scheduled_source_id, source_id, day_start,
                first_activity_at, last_activity_at, kinds, completed_kinds, max_fraction,
                engaged_seconds
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, day_start) DO UPDATE SET
                scheduled_source_id = excluded.scheduled_source_id,
                first_activity_at = MIN(source_activity_days.first_activity_at, excluded.first_activity_at),
                last_activity_at = MAX(source_activity_days.last_activity_at, excluded.last_activity_at),
                kinds = source_activity_days.kinds | excluded.kinds,
                completed_kinds = source_activity_days.completed_kinds | excluded.completed_kinds,
                max_fraction = MAX(source_activity_days.max_fraction, excluded.max_fraction),
                engaged_seconds = MIN(86400, source_activity_days.engaged_seconds + excluded.engaged_seconds)
        """) { stmt in
            bind(stmt, 1, activityID)
            bind(stmt, 2, placementID)
            bind(stmt, 3, sourceID)
            sqlite3_bind_double(stmt, 4, dayStart.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 5, occurredAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 6, occurredAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 7, kindMask)
            sqlite3_bind_int64(stmt, 8, completedMask)
            sqlite3_bind_double(stmt, 9, SourceActivityDay.clampFraction(fraction ?? 0))
            sqlite3_bind_double(stmt, 10, SourceActivityDay.clampSeconds(engagedSeconds))
        }
        // Generation 2: the same slice in this Mac's own activity log (§3.5.24).
        try recordOwnSourceActivity(
            sourceID: sourceID, kind: kind, completed: completed, fraction: fraction, engagedSeconds: engagedSeconds, at: occurredAt
        )
        return !existed
    }

    /// Put learner activity on the calendar without requiring a manual plan. A
    /// source keeps its explicit goal-backed plan, while its per-day activity is
    /// recorded independently. A placement created only by automatic activity
    /// follows the most recent activity day so the main Schedule opens on what
    /// the learner is actually doing now.
    @discardableResult
    func recordScheduledSourceActivity(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) throws -> Bool {
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            let inserted = try recordScheduledSourceActivityRows(
                sourceID: sourceID,
                on: day,
                kind: kind,
                recordedAt: now,
                fraction: fraction,
                engagedSeconds: engagedSeconds
            )
            try exec("COMMIT")
            return inserted
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Transaction-free form used when creating a review session and its
    /// initial calendar entries must either all commit or all roll back.
    @discardableResult
    func recordScheduledSourceActivityRows(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind,
        recordedAt: Date,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) throws -> Bool {
        let existingPlacementID = try scheduledSourceID(forSource: sourceID)
        let placementID = try ensureScheduledSourcePlacement(
            sourceID: sourceID,
            plannedAt: day,
            now: recordedAt
        )
        if existingPlacementID == nil {
            try setScheduledSourceAutomatic(placementID: placementID, isAutomatic: true)
        }
        let inserted = try recordSourceActivityDayRows(
            placementID: placementID,
            sourceID: sourceID,
            kind: kind,
            occurredAt: day,
            completed: false,
            fraction: fraction,
            engagedSeconds: engagedSeconds
        )
        // An automatic entry follows the most recent activity day. A play
        // recorded after the fact (Apple Podcasts' history) can be older than
        // a day already logged, and then leaves the entry where it is.
        let plannedDay = Calendar.current.startOfDay(for: day)
        let latestDay = try latestSourceActivityDayStart(sourceID: sourceID) ?? plannedDay
        if try scheduledSourceIsAutomatic(placementID: placementID), latestDay <= plannedDay {
            let order = try nextScheduledSourceOrder(day: plannedDay, excludingSourceID: sourceID)
            let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
            try execBind("UPDATE scheduled_sources SET planned_at = ?, updated_at = ? WHERE id = ?") { stmt in
                sqlite3_bind_double(stmt, 1, encoded.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 2, recordedAt.timeIntervalSinceReferenceDate)
                bind(stmt, 3, placementID)
            }
        }
        try markRecordChanged(
            entity: .scheduledSource,
            logicalKey: placementID,
            at: recordedAt
        )
        return inserted
    }

    /// The start of the latest day `sourceID` has activity on, if any.
    private func latestSourceActivityDayStart(sourceID: String) throws -> Date? {
        var latest: Date?
        try queryBind("SELECT MAX(day_start) FROM source_activity_days WHERE source_id = ?", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
            latest = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return latest
    }

    // MARK: - Listening heard in Apple Podcasts

    /// Records plays Apple Podcasts saw as the learner's listening, the way the
    /// in-app player records its own: the source's activity day on the local
    /// day of the play, with the automatic Schedule entry every activity day
    /// hangs from, and a minute on that day's log at the moment of the play.
    /// "What did I listen to last week" is then one question with one answer,
    /// whichever app played the episode.
    ///
    /// Only an episode the library holds, active and not hidden (the source,
    /// the episode or its show), is recorded; a listen names no source until
    /// discovery has imported it. Any play counts, however short: Apple keeps
    /// the moment of the last play and not how much of the episode it covered,
    /// and an episode sampled on Tuesday was still heard on Tuesday. Nothing
    /// is claimed beyond that moment: no engaged seconds, no depth, no
    /// completion.
    ///
    /// Idempotent: a play already on the source's day (from an earlier sync
    /// pass, or listening in ForeverLM later that day) is skipped, so a pass
    /// that finds nothing new reads and never takes the write lock. Returns the
    /// ids of the sources whose play was recorded now.
    @discardableResult
    func recordExternalListening(_ listens: [ExternalListen], now: Date = Date()) throws -> [String] {
        var pending: [(sourceID: String, listen: ExternalListen)] = []
        for listen in listens {
            guard let sourceID = try visiblePodcastSourceID(for: listen),
                  try !externalListenIsRecorded(sourceID: sourceID, playedAt: listen.playedAt) else { continue }
            pending.append((sourceID, listen))
        }
        guard !pending.isEmpty else { return [] }

        var recorded: [String] = []
        try exec("BEGIN IMMEDIATE")
        do {
            for (sourceID, listen) in pending {
                // Read again under the lock: the same episode twice in a batch,
                // or a heartbeat that landed in between, is already there.
                guard try !externalListenIsRecorded(sourceID: sourceID, playedAt: listen.playedAt) else { continue }
                try recordScheduledSourceActivityRows(
                    sourceID: sourceID,
                    on: listen.playedAt,
                    kind: .listening,
                    recordedAt: now
                )
                try recordDayActivitySpanRows(
                    kind: .listening,
                    targetID: sourceID,
                    title: listen.title,
                    from: listen.playedAt,
                    to: listen.playedAt.addingTimeInterval(60),
                    now: now
                )
                recorded.append(sourceID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return recorded
    }

    /// Whether the source's day already holds listening at or after `playedAt`.
    private func externalListenIsRecorded(sourceID: String, playedAt: Date) throws -> Bool {
        let dayStart = Calendar.current.startOfDay(for: playedAt)
        var found = false
        try queryBind("""
            SELECT 1 FROM source_activity_days
            WHERE source_id = ? AND day_start = ?
              AND (kinds & ?) != 0
              AND last_activity_at >= ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_double(stmt, 2, dayStart.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 3, sourceActivityMask([.listening]))
            // A second of slack: the stored stamp is the play's own, read back.
            sqlite3_bind_double(stmt, 4, playedAt.timeIntervalSinceReferenceDate - 1)
        }) { _ in found = true }
        return found
    }

    /// The learner's own library source a listen names, found by the keys the
    /// import that made it dedups on (`insertSourceIfNew`): work keys, the
    /// normalized URL (with the older spelling of a track-id URL), then show
    /// and title for an episode with no public track id. Every lookup is on an
    /// index, never the source projection, since a sync pass asks once per
    /// play in the window. Nil unless that source is active and shown: not
    /// hidden itself, not a hidden episode, and not in a hidden show unless
    /// the episode was let back in.
    private func visiblePodcastSourceID(for listen: ExternalListen) throws -> String? {
        var probe = StudioArticle(url: listen.url, title: listen.title, sourceType: .podcast)
        probe.domain = listen.showName
        var match = try sourceID(forWorkKeys: workKeys(for: probe, hashingFile: false), teamID: nil)
        if match == nil {
            var normalizedURLs = [URLNormalizer.normalize(listen.url)]
            if let trackID = Self.extractTrackIdFromURL(listen.url) {
                // How rows imported before the canonical form normalized.
                normalizedURLs.append("episode/\(trackID)")
            }
            let marks = Array(repeating: "?", count: normalizedURLs.count).joined(separator: ", ")
            try queryBind("""
                SELECT s.id FROM podcasts p JOIN sources s ON s.id = p.source_id
                WHERE p.normalized_url IN (\(marks)) AND s.team_id IS NULL
                ORDER BY s.status = 'active' DESC, s.id
                LIMIT 1
            """, bind: { stmt in
                for (index, url) in normalizedURLs.enumerated() { bind(stmt, index + 1, url) }
            }) { stmt in match = string(stmt, 0) }
        }
        if match == nil, Self.extractTrackIdFromURL(listen.url) == nil {
            match = sourceExistsByPodcastShowAndTitle(probe)?.id
        }
        guard let sourceID = match else { return nil }
        var visible = false
        try queryBind("""
            SELECT 1
            FROM sources s
            LEFT JOIN podcasts p ON p.source_id = s.id
            WHERE s.id = ?
              AND s.status = 'active'
              AND NOT EXISTS (SELECT 1 FROM hidden_sources h WHERE h.source_id IN (s.id, s.wire_key))
              AND NOT EXISTS (SELECT 1 FROM pending_hidden_sources h WHERE h.source_id IN (s.id, s.wire_key))
              AND NOT EXISTS (SELECT 1 FROM hidden_podcast_episodes h WHERE h.source_id IN (s.id, s.wire_key))
              AND (
                    EXISTS (SELECT 1 FROM visible_podcast_episode_overrides v WHERE v.source_id IN (s.id, s.wire_key))
                 OR NOT EXISTS (
                        SELECT 1 FROM hidden_podcast_shows h
                        WHERE h.show_name = p.domain OR h.show_name = p.show_name
                    )
              )
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { _ in visible = true }
        return visible ? sourceID : nil
    }

    /// Tag a source's shared placement with a goal, creating the placement if needed.
    /// When `plannedAt` is given, the placement is (re)scheduled to that day.
    func addSourceToGoal(sourceID: String, goalID: String, plannedAt: Date? = nil) throws {
        let now = Date()
        var placementID = ""
        try exec("BEGIN IMMEDIATE")
        do {
            placementID = try ensureScheduledSourcePlacement(sourceID: sourceID, plannedAt: plannedAt ?? now, now: now)
            try setScheduledSourceAutomatic(placementID: placementID, isAutomatic: false)
            if let plannedAt {
                let plannedDay = Calendar.current.startOfDay(for: plannedAt)
                let order = try nextScheduledSourceOrder(day: plannedDay, excludingSourceID: sourceID)
                let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
                try execBind("UPDATE scheduled_sources SET planned_at = ?, updated_at = ? WHERE id = ?") { stmt in
                    sqlite3_bind_double(stmt, 1, encoded.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 3, placementID)
                }
            }
            try execBind("INSERT OR IGNORE INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at) VALUES (?, ?, ?)") { stmt in
                bind(stmt, 1, placementID)
                bind(stmt, 2, goalID)
                sqlite3_bind_double(stmt, 3, now.timeIntervalSinceReferenceDate)
            }
            try touchLearningGoal(goalID, at: now)
            try markRecordChanged(entity: .scheduledSource, logicalKey: placementID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Untag a source from a goal. If that leaves the placement with no goals,
    /// remove it only when it has no activity history; otherwise retain it as an
    /// automatic Schedule entry on its latest activity day.
    func removeSourceFromGoal(sourceID: String, goalID: String) throws {
        let now = Date()
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return }
        var deletedPlacement = false
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ? AND goal_id = ?") { stmt in
                bind(stmt, 1, placementID)
                bind(stmt, 2, goalID)
            }
            if try scheduledSourceGoalCount(placementID: placementID) == 0,
               try sourceActivityDayCount(sourceID: sourceID) == 0 {
                try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
                    bind(stmt, 1, placementID)
                }
                deletedPlacement = true
            } else if try scheduledSourceGoalCount(placementID: placementID) == 0 {
                try convertPlacementToAutomaticHistory(
                    placementID: placementID,
                    sourceID: sourceID,
                    at: now
                )
            }
            try touchLearningGoal(goalID, at: now)
            if deletedPlacement {
                try markRecordDeleted(entity: .scheduledSource, logicalKey: placementID)
            } else {
                try markRecordChanged(entity: .scheduledSource, logicalKey: placementID, at: now)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Remove a source's explicit plan and every goal tag. Activity history is
    /// retained, so an interacted-with source falls back to its automatic entry
    /// on the latest activity day instead of disappearing from the Schedule.
    func removeScheduledSource(sourceID: String) throws {
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?") { stmt in
                bind(stmt, 1, placementID)
            }
            if try sourceActivityDayCount(sourceID: sourceID) == 0 {
                try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
                    bind(stmt, 1, placementID)
                }
                try markRecordDeleted(entity: .scheduledSource, logicalKey: placementID)
            } else {
                try convertPlacementToAutomaticHistory(
                    placementID: placementID,
                    sourceID: sourceID,
                    at: Date()
                )
                try markRecordChanged(entity: .scheduledSource, logicalKey: placementID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Take sources off the Schedule. Scoped to a Goal or Notebook only that tag
    /// comes off (`removeSourceFromGoal`); on the whole Schedule the placement
    /// and all its tags go (`removeScheduledSource`). Activity history survives
    /// either way. `StorageService.removeSourcesFromSchedule` and the MCP
    /// Schedule tools both remove through here.
    func removeSourcesFromSchedule(goalID: String?, sourceIDs: [String]) throws {
        for sourceID in sourceIDs {
            if let goalID {
                try removeSourceFromGoal(sourceID: sourceID, goalID: goalID)
            } else {
                try removeScheduledSource(sourceID: sourceID)
            }
        }
    }

    /// What `forgetAutomaticSourceActivity` took back for one source.
    struct ForgottenSourceActivity: Equatable, Sendable {
        let sourceID: String
        let placementID: String
        /// The activity days that went, with what each had recorded.
        let days: [SourceActivityDay]
        /// Whether the entry had been checked off, by a review or a finish.
        let wasCompleted: Bool
        /// The read stamp that went with it, when that day set one.
        let clearedReadAt: Date?
        /// Assignments the entry's completion had closed, reopened.
        let reopenedTaskIDs: [String]
    }

    /// Takes back activity the app recorded on a source that did not happen:
    /// a review marked by a chat that reviewed nothing (2026-09-28, when a
    /// chat saved with `mark_reviewed` false marked the seven sources a later
    /// call linked reviewed). It undoes what recording the activity wrote —
    /// the source's automatic Schedule entry (the placement no one planned,
    /// `is_automatic` 1) with every activity day under it, the read stamp when
    /// it falls on `day`, and the assignments the entry's completion closed
    /// (`reopenAssignedTasks`). The placement's deletion is what reaches the
    /// other Macs: applying it deletes the activity days under it there, which
    /// a saved record never could, because inbound activity days are unioned
    /// with the local ones. The read stamp travels as the source's own change.
    ///
    /// All or nothing: when any source has no entry, has a plan instead (a
    /// day someone chose, or a Goal's tag — `unschedule_sources` and
    /// `set_source_completion` are for those), or holds activity on a day
    /// other than `day`, nothing is written for any of them. Activity on
    /// another day is history this call was not asked to forget, and deleting
    /// the entry would take it too.
    @discardableResult
    func forgetAutomaticSourceActivity(
        sourceIDs rawSourceIDs: [String],
        on day: Date,
        now: Date = Date()
    ) throws -> [ForgottenSourceActivity] {
        let sourceIDs = rawSourceIDs.reduce(into: [String]()) { result, raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !result.contains(id) { result.append(id) }
        }
        guard !sourceIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("At least one source is required to forget its activity.")
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let dayLabel = DayPlan.dateString(for: dayStart)

        try exec("BEGIN IMMEDIATE")
        do {
            var entries: [(sourceID: String, placementID: String, days: [SourceActivityDay], completedAt: Date?, readAt: Date?)] = []
            var refusals: [String] = []
            for sourceID in sourceIDs {
                guard let placementID = try scheduledSourceID(forSource: sourceID) else {
                    refusals.append("\(sourceID) has no recorded activity")
                    continue
                }
                guard try scheduledSourceIsAutomatic(placementID: placementID),
                      try scheduledSourceGoalCount(placementID: placementID) == 0 else {
                    refusals.append("\(sourceID) is on the Schedule as a plan, not an automatic entry: take it off with unschedule_sources, or reopen it with set_source_completion")
                    continue
                }
                let days = try loadSourceActivityDays(sourceID: sourceID)
                let elsewhere = days.filter { !calendar.isDate($0.dayStart, inSameDayAs: dayStart) }
                guard elsewhere.isEmpty else {
                    let otherDays = elsewhere.map { DayPlan.dateString(for: $0.dayStart) }.joined(separator: ", ")
                    refusals.append("\(sourceID) also has activity on \(otherDays), which forgetting \(dayLabel) would take with it")
                    continue
                }
                let completedAt = try loadScheduledSourceRow(id: placementID)?.completedAt
                let readAt = try loadSourceProgress(sourceID: sourceID)?.readAt
                entries.append((sourceID: sourceID, placementID: placementID, days: days, completedAt: completedAt, readAt: readAt))
            }
            guard refusals.isEmpty else {
                throw KnowledgeStoreError.invalidData("Nothing was forgotten: \(refusals.joined(separator: "; ")).")
            }

            var forgotten: [ForgottenSourceActivity] = []
            for entry in entries {
                try execBind("DELETE FROM source_activity_days WHERE source_id = ? OR scheduled_source_id = ?") { stmt in
                    bind(stmt, 1, entry.sourceID)
                    bind(stmt, 2, entry.placementID)
                }
                try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
                    bind(stmt, 1, entry.placementID)
                }
                try markRecordDeleted(entity: .scheduledSource, logicalKey: entry.placementID, at: now)

                var clearedReadAt: Date?
                if let readAt = entry.readAt, readAt >= dayStart, readAt < dayEnd {
                    if keepsReadingStates {
                        try updateReadingState(sourceID: entry.sourceID) { $0.readAt = nil }
                    } else {
                        try execBind("UPDATE sources SET read_at = NULL WHERE id = ?") { stmt in
                            bind(stmt, 1, entry.sourceID)
                        }
                        try markSourceProgressChanged(sourceID: entry.sourceID, at: now)
                    }
                    clearedReadAt = readAt
                }
                var reopened: [String] = []
                if let completedAt = entry.completedAt {
                    reopened = try reopenAssignedTasks(forSourceID: entry.sourceID, completedAt: completedAt, at: now)
                }
                forgotten.append(ForgottenSourceActivity(
                    sourceID: entry.sourceID,
                    placementID: entry.placementID,
                    days: entry.days,
                    wasCompleted: entry.completedAt != nil,
                    clearedReadAt: clearedReadAt,
                    reopenedTaskIDs: reopened
                ))
            }
            try exec("COMMIT")
            return forgotten
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Move a source's shared placement to a different day and optionally place
    /// it immediately before another source on that day. Creates the placement
    /// if missing. Every changed order timestamp is sync-published in the same
    /// transaction so another device reconstructs the exact row order.
    func setScheduledSourcePlannedDate(
        sourceID: String,
        plannedAt: Date,
        beforeSourceID: String? = nil
    ) throws {
        let now = Date()
        let plannedDay = Calendar.current.startOfDay(for: plannedAt)
        let dayEnd = plannedDay.addingTimeInterval(24 * 60 * 60)
        var placementID = ""
        try exec("BEGIN IMMEDIATE")
        do {
            placementID = try ensureScheduledSourcePlacement(sourceID: sourceID, plannedAt: plannedAt, now: now)

            var ordered: [(placementID: String, sourceID: String)] = []
            try queryBind("""
                SELECT id, source_id
                FROM scheduled_sources
                WHERE source_id != ? AND planned_at >= ? AND planned_at < ?
                ORDER BY planned_at ASC, added_at ASC, id ASC
            """, bind: { stmt in
                bind(stmt, 1, sourceID)
                sqlite3_bind_double(stmt, 2, plannedDay.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 3, dayEnd.timeIntervalSinceReferenceDate)
            }) { stmt in
                guard let id = self.string(stmt, 0), let idSource = self.string(stmt, 1) else { return }
                ordered.append((id, idSource))
            }

            let destination = beforeSourceID.flatMap { target in
                ordered.firstIndex(where: { $0.sourceID == target })
            } ?? ordered.endIndex
            ordered.insert((placementID, sourceID), at: destination)

            for (order, row) in ordered.enumerated() {
                let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
                try execBind("""
                    UPDATE scheduled_sources
                    SET planned_at = ?, updated_at = ?,
                        is_automatic = CASE WHEN id = ? THEN 0 ELSE is_automatic END
                    WHERE id = ?
                """) { stmt in
                    sqlite3_bind_double(stmt, 1, encoded.timeIntervalSinceReferenceDate)
                    sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                    bind(stmt, 3, placementID)
                    bind(stmt, 4, row.placementID)
                }
                try markRecordChanged(entity: .scheduledSource, logicalKey: row.placementID, at: now)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Shared completion: reviewing once flips the placement done for every goal it's tagged with.
    /// Completing also marks the source itself read; reopening never clears an existing read date.
    func markScheduledSourceDone(sourceID: String) throws {
        let now = Date()
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return }
        try execBind("UPDATE scheduled_sources SET completed_at = COALESCE(completed_at, ?), updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, placementID)
        }
        try markTutorStateChanged(entity: .scheduledSource, logicalKey: placementID, at: now)

        if keepsReadingStates {
            try fillReadingStateReadAt(sourceID: sourceID, at: now)
        } else {
            try execBind("UPDATE sources SET read_at = ? WHERE id = ? AND read_at IS NULL") { stmt in
                sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
                bind(stmt, 2, sourceID)
            }
            if sqlite3_changes(db) > 0 {
                try markRecordChanged(entity: .source, logicalKey: sourceID, at: now)
            }
        }

        try mirrorPlacementCompletion(placementID: placementID, sourceID: sourceID, completedAt: now, now: now)
        try completeAssignedTasks(forSourceID: sourceID, at: now)
    }

    func reopenScheduledSource(sourceID: String) throws {
        let now = Date()
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return }
        try execBind("UPDATE scheduled_sources SET completed_at = NULL, updated_at = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
            bind(stmt, 2, placementID)
        }
        try markRecordChanged(entity: .scheduledSource, logicalKey: placementID, at: now)

        // Deliberately NOT mirrored back onto learning_goal_items. Reopening a
        // Schedule row means "put this back on my calendar", not "erase the record
        // that I ever studied it" — and an item's completion can also have come
        // from another device or an older build, which has nothing to do with
        // this placement. Clearing it here would destroy that. It would also never
        // converge: the CloudKit inbound merge resolves item `completedAt` with
        // `max(left, right)` and only fills nil from non-nil, so a date→NULL
        // transition is never propagated and the other device would re-complete it.
    }

    /// Mirror a placement's completion onto `learning_goal_items.completed_at` for
    /// every goal the placement is tagged with.
    ///
    /// The two tables record the same fact for different consumers: the Schedule
    /// reads `scheduled_sources`, while `LearningGoalRecord.completedCount` — and
    /// so Notebook goal cards, MCP `completed_sources`, and DailyReviewPlan's
    /// `!isCompleted` filter — reads `learning_goal_items`. Only the placement was
    /// ever written by the review path, so item completion stayed NULL forever and
    /// every companion goal reported 0% done. Keeping them in step here means
    /// `learning_goal_items` is a durable record of the work even if the placement
    /// is later removed from the calendar.
    private func mirrorPlacementCompletion(
        placementID: String,
        sourceID: String,
        completedAt: Date,
        now: Date
    ) throws {
        var goalIDs: [String] = []
        try queryBind("SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = ?", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            if let goalID = self.string(stmt, 0) { goalIDs.append(goalID) }
        }
        guard !goalIDs.isEmpty else { return }
        // Generation 2: an item's completion travels as its source's (`ReadingState.completedAt`, §10).
        if keepsReadingStates { try fillReadingStateCompletedAt(sourceID: sourceID, at: completedAt) }

        for goalID in goalIDs {
            // COALESCE so re-marking an already-complete item keeps the original
            // completion date rather than sliding it forward.
            try execBind("""
                UPDATE learning_goal_items
                SET completed_at = COALESCE(completed_at, ?)
                WHERE goal_id = ? AND source_id = ?
            """) { stmt in
                sqlite3_bind_double(stmt, 1, completedAt.timeIntervalSinceReferenceDate)
                bind(stmt, 2, goalID)
                bind(stmt, 3, sourceID)
            }
            guard sqlite3_changes(db) > 0 else { continue }
            try touchLearningGoal(goalID, at: now)
            try markTutorStateChanged(entity: .learningGoal, logicalKey: goalID, at: now)
        }
    }

    func setScheduledSourceCompletion(sourceID: String, isCompleted: Bool) throws {
        if isCompleted {
            try markScheduledSourceDone(sourceID: sourceID)
        } else {
            try reopenScheduledSource(sourceID: sourceID)
        }
    }

    /// Record a completed review on the Schedule. A source that has no placement yet
    /// is placed on `day` first, so a source attached to a chat and reviewed there
    /// lands on that day already checked off instead of leaving no trace. A source
    /// that is already scheduled keeps the day the learner planned it for — reviewing
    /// checks it off in place rather than pulling it forward to today.
    func recordScheduledSourceReview(sourceID: String, on day: Date) throws {
        try recordScheduledSourceCompletion(sourceID: sourceID, on: day, kind: .review)
    }

    func recordScheduledSourceCompletion(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind
    ) throws {
        try recordScheduledSourceCompletions(sourceIDs: [sourceID], on: day, kind: kind)
    }

    /// Records a learner's externally completed reading, listening, or watching
    /// as one atomic library operation. A chapter range must never be half logged
    /// because a later source is invalid or a write fails.
    func recordScheduledSourceCompletions(
        sourceIDs rawSourceIDs: [String],
        on day: Date,
        kind: SourceActivityKind
    ) throws {
        let sourceIDs = rawSourceIDs.reduce(into: [String]()) { result, raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !result.contains(id) { result.append(id) }
        }
        guard !sourceIDs.isEmpty else {
            throw KnowledgeStoreError.invalidData("At least one source is required to record completed activity.")
        }
        let now = Date()
        let sourceReadAt: Date?
        switch kind {
        case .reading, .listening, .watching:
            sourceReadAt = day
        case .chat, .review:
            sourceReadAt = nil
        }
        try exec("BEGIN IMMEDIATE")
        do {
            for sourceID in sourceIDs {
                try recordScheduledSourceReviewRows(
                    sourceID: sourceID,
                    on: day,
                    kind: kind,
                    sourceReadAt: sourceReadAt,
                    recordedAt: now
                )
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Transaction-free row helper used when review completion, transcript,
    /// memory evidence, Schedule state, and Notebook state must commit together.
    func recordScheduledSourceReviewRows(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind = .review,
        sourceReadAt: Date? = nil,
        recordedAt: Date
    ) throws {
        let existingPlacementID = try scheduledSourceID(forSource: sourceID)
        let placementID = try ensureScheduledSourcePlacement(
            sourceID: sourceID,
            plannedAt: day,
            now: recordedAt
        )
        if existingPlacementID == nil {
            try setScheduledSourceAutomatic(placementID: placementID, isAutomatic: true)
        }
        _ = try recordSourceActivityDayRows(
            placementID: placementID,
            sourceID: sourceID,
            kind: kind,
            occurredAt: day,
            completed: true,
            fraction: 1
        )
        if try scheduledSourceIsAutomatic(placementID: placementID) {
            let plannedDay = Calendar.current.startOfDay(for: day)
            let order = try nextScheduledSourceOrder(day: plannedDay, excludingSourceID: sourceID)
            let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
            try execBind("UPDATE scheduled_sources SET planned_at = ?, updated_at = ? WHERE id = ?") { stmt in
                sqlite3_bind_double(stmt, 1, encoded.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 2, recordedAt.timeIntervalSinceReferenceDate)
                bind(stmt, 3, placementID)
            }
        }
        try execBind("""
            UPDATE scheduled_sources
            SET completed_at = COALESCE(completed_at, ?), updated_at = ?
            WHERE id = ?
        """) { stmt in
            sqlite3_bind_double(stmt, 1, recordedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, recordedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 3, placementID)
        }
        try markTutorStateChanged(
            entity: .scheduledSource,
            logicalKey: placementID,
            at: recordedAt
        )

        if keepsReadingStates {
            try fillReadingStateReadAt(sourceID: sourceID, at: sourceReadAt ?? recordedAt)
        } else {
            try execBind("UPDATE sources SET read_at = ? WHERE id = ? AND read_at IS NULL") { stmt in
                sqlite3_bind_double(stmt, 1, (sourceReadAt ?? recordedAt).timeIntervalSinceReferenceDate)
                bind(stmt, 2, sourceID)
            }
            if sqlite3_changes(db) > 0 {
                try markRecordChanged(entity: .source, logicalKey: sourceID, at: recordedAt)
            }
        }

        try mirrorPlacementCompletion(
            placementID: placementID,
            sourceID: sourceID,
            completedAt: recordedAt,
            now: recordedAt
        )
        // A review (or a finished reading, listening or watching) completes
        // the source's assignments in the same transaction
        // (docs/family-design.md).
        try completeAssignedTasks(forSourceID: sourceID, at: recordedAt)
    }

    func readScheduledSourceRow(_ stmt: OpaquePointer?) -> ScheduledSource? {
        guard let id = string(stmt, 0), let sourceID = string(stmt, 1) else { return nil }
        return ScheduledSource(
            id: id,
            sourceID: sourceID,
            plannedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
            addedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            completedAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 6))
        )
    }

    /// Visible Goal tags for placements, keyed by placement id. Top-level Notebooks
    /// stay out of chips; every timebound Goal, standing alone or in a Notebook,
    /// is shown, as are the plain goals older builds created.
    func loadGoalTagsByPlacement() throws -> [String: [GoalTag]] {
        var result: [String: [GoalTag]] = [:]
        try queryBind("""
            SELECT ssg.scheduled_source_id, g.id, g.title
            FROM scheduled_source_goals ssg
            JOIN learning_goals g ON g.id = ssg.goal_id
            WHERE (g.kind IS NULL OR g.kind != 'companion'
                   OR TRIM(COALESCE(g.parent_notebook_id, '')) != ''
                   OR g.end_at < ?)
            ORDER BY g.created_at ASC
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, LearningGoalRecord.openEndedThreshold.timeIntervalSinceReferenceDate)
        }) { stmt in
            guard let placementID = self.string(stmt, 0),
                  let goalID = self.string(stmt, 1),
                  let title = self.string(stmt, 2) else { return }
            result[placementID, default: []].append(GoalTag(id: goalID, title: title))
        }
        return result
    }

    /// Full goal membership per placement, keyed by placement id. Includes companion
    /// Notebooks (unlike `loadGoalTagsByPlacement`), so a Notebook's own schedule can be
    /// scoped to the placements tagged with it.
    func loadGoalMembershipByPlacement() throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        try query("SELECT scheduled_source_id, goal_id FROM scheduled_source_goals") { stmt in
            guard let placementID = self.string(stmt, 0),
                  let goalID = self.string(stmt, 1) else { return }
            result[placementID, default: []].insert(goalID)
        }
        return result
    }

    /// Load the whole Schedule, or the placements tagged with one Goal or Notebook.
    func loadScheduledSources(goalID: String? = nil) throws -> [ScheduledSourceEntry] {
        var placements: [ScheduledSource] = []
        if let goalID {
            try queryBind("""
                SELECT ss.id, ss.source_id, ss.planned_at, ss.added_at, ss.completed_at, ss.created_at, ss.updated_at
                FROM scheduled_sources ss
                JOIN scheduled_source_goals ssg ON ssg.scheduled_source_id = ss.id
                WHERE ssg.goal_id = ?
                ORDER BY ss.planned_at ASC
            """, bind: { stmt in
                bind(stmt, 1, goalID)
            }) { stmt in
                if let row = self.readScheduledSourceRow(stmt) { placements.append(row) }
            }
        } else {
            try query("""
                SELECT id, source_id, planned_at, added_at, completed_at, created_at, updated_at
                FROM scheduled_sources
                ORDER BY planned_at ASC
            """) { stmt in
                if let row = self.readScheduledSourceRow(stmt) { placements.append(row) }
            }
        }
        let tagsByPlacement = try loadGoalTagsByPlacement()
        let membershipByPlacement = try loadGoalMembershipByPlacement()
        let activityBySource = Dictionary(
            grouping: try loadSourceActivityDays(),
            by: \.sourceID
        )
        var automaticPlacementIDs: Set<String> = []
        try query("SELECT id FROM scheduled_sources WHERE is_automatic = 1") { stmt in
            if let id = self.string(stmt, 0) { automaticPlacementIDs.insert(id) }
        }
        return placements.map {
            ScheduledSourceEntry(
                placement: $0,
                goalTags: tagsByPlacement[$0.id] ?? [],
                goalIDs: membershipByPlacement[$0.id] ?? [],
                isAutomatic: automaticPlacementIDs.contains($0.id),
                activityDays: activityBySource[$0.sourceID] ?? []
            )
        }
    }

    // MARK: - Shared Schedule Placement sync

    func loadScheduledSourceForSync(_ id: String) throws -> CloudKitScheduledSourcePayload? {
        var placement: ScheduledSource?
        var storedIdentity: CloudKitSourceIdentityPayload?
        try queryBind("""
            SELECT id, source_id, planned_at, added_at, completed_at, created_at, updated_at,
                   source_url, source_normalized_url, source_doi, source_published_doi
            FROM scheduled_sources WHERE id = ? LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            placement = self.readScheduledSourceRow(stmt)
            guard let sourceID = self.string(stmt, 1) else { return }
            let url = self.string(stmt, 7)
            let normalizedURL = self.string(stmt, 8)
            let doi = self.string(stmt, 9)
            let publishedDOI = self.string(stmt, 10)
            if url != nil || normalizedURL != nil || doi != nil || publishedDOI != nil {
                storedIdentity = CloudKitSourceIdentityPayload(
                    sourceID: sourceID,
                    url: url,
                    normalizedURL: normalizedURL,
                    doi: doi,
                    publishedDOI: publishedDOI
                )
            }
        }
        guard let placement else { return nil }
        var goalIDs: [String] = []
        try queryBind("SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = ? ORDER BY added_at ASC", bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            if let goalID = self.string(stmt, 0) { goalIDs.append(goalID) }
        }
        let identity = try sourceIdentities(for: [placement.sourceID]).first
            ?? storedIdentity
        let isAutomatic = try scheduledSourceIsAutomatic(placementID: id)
        return CloudKitScheduledSourcePayload(
            placement: placement,
            goalIDs: goalIDs,
            sourceIdentity: identity,
            activityDays: try loadSourceActivityDays(sourceID: placement.sourceID),
            isAutomatic: isAutomatic
        )
    }

    func loadAllScheduledSourceIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM scheduled_sources") { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    func scheduledSourceUpdatedAt(_ id: String) throws -> Date? {
        var date: Date?
        try queryBind("SELECT updated_at FROM scheduled_sources WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return date
    }

    func hasScheduledSource(_ id: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM scheduled_sources WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, id)
        }) { _ in
            found = true
        }
        return found
    }

    func saveScheduledSourceRecord(
        _ payload: CloudKitScheduledSourcePayload
    ) throws -> (logicalKey: String, requiresRepublish: Bool) {
        try saveScheduledSourceRecord(payload, mergingServerConflict: false)
    }

    /// Resolve a CloudKit `serverRecordChanged` without allowing a stale whole
    /// record to erase monotonic tutor state. This is deliberately separate from
    /// ordinary inbound application: a normal, authoritative record may remove a
    /// goal tag, while two concurrently edited snapshots must retain the union of
    /// their memberships and any completion either side has observed.
    func mergeScheduledSourceServerConflict(
        _ payload: CloudKitScheduledSourcePayload,
        preferLocalEditorial: Bool
    ) throws -> (logicalKey: String, requiresRepublish: Bool) {
        try saveScheduledSourceRecord(
            payload,
            mergingServerConflict: true,
            preferLocalEditorial: preferLocalEditorial
        )
    }

    private func saveScheduledSourceRecord(
        _ payload: CloudKitScheduledSourcePayload,
        mergingServerConflict: Bool,
        preferLocalEditorial: Bool = false
    ) throws -> (logicalKey: String, requiresRepublish: Bool) {
        let resolvedSourceID = try resolveSourceID(payload.placement.sourceID, identities: [payload.sourceIdentity].compactMap { $0 })
        let portableSourceKey: String
        if let identity = payload.sourceIdentity {
            portableSourceKey = MemoryTutorIdentity.portableSourceKey(
                sourceID: identity.sourceID,
                normalizedURL: normalizedScheduledIdentityURL(identity),
                doi: normalizedScheduledIdentityDOI(identity.doi),
                publishedDOI: normalizedScheduledIdentityDOI(identity.publishedDOI)
            )
        } else {
            portableSourceKey = try portableMemorySourceKey(sourceID: resolvedSourceID)
        }
        let canonicalPlacementID = MemoryTutorIdentity.scheduledSourcePlacementID(
            portableSourceKey: portableSourceKey
        )
        var requiresRepublish = payload.placement.id != canonicalPlacementID
        try exec("BEGIN IMMEDIATE")
        do {
            let existingPlacementID = try scheduledSourceID(forSource: resolvedSourceID)
            let existingPlacement = try existingPlacementID.flatMap {
                try loadScheduledSourceRow(id: $0)
            }
            let existingGoalIDs = try existingPlacementID.map {
                try scheduledSourceMembershipIDs(placementID: $0)
            } ?? []
            let existingIsAutomatic = try existingPlacementID.map {
                try scheduledSourceIsAutomatic(placementID: $0)
            } ?? false
            let existingActivityDays = try loadSourceActivityDays(sourceID: resolvedSourceID)
            let incomingActivityDays = payload.activityDays.map {
                SourceActivityDay(
                    id: $0.id,
                    sourceID: resolvedSourceID,
                    dayStart: $0.dayStart,
                    firstActivityAt: $0.firstActivityAt,
                    lastActivityAt: $0.lastActivityAt,
                    kinds: $0.kinds,
                    completedKinds: $0.completedKinds,
                    maxFraction: $0.maxFraction,
                    engagedSeconds: $0.engagedSeconds
                )
            }
            let mergedActivityDays = mergedSourceActivityDays(
                existingActivityDays,
                incomingActivityDays,
                sourceID: resolvedSourceID,
                portableSourceKey: portableSourceKey
            )
            if mergedActivityDays != incomingActivityDays.sorted(by: { $0.dayStart < $1.dayStart }) {
                requiresRepublish = true
            }

            // Any non-canonical ID is a pre-v2 alias. Alias convergence is a
            // commutative merge regardless of which record arrived first. The
            // same merge is also required for a true CloudKit save conflict so
            // stale offline state cannot clear completion or relationships.
            let isAliasMerge = existingPlacement != nil && (
                existingPlacementID != canonicalPlacementID
                    || payload.placement.id != canonicalPlacementID
                    || existingPlacementID != payload.placement.id
            )
            let mergesExisting = existingPlacement != nil
                && (mergingServerConflict || isAliasMerge)
            let incomingPlacement = ScheduledSource(
                id: canonicalPlacementID,
                sourceID: resolvedSourceID,
                plannedAt: payload.placement.plannedAt,
                addedAt: payload.placement.addedAt,
                completedAt: payload.placement.completedAt,
                createdAt: payload.placement.createdAt,
                updatedAt: payload.placement.updatedAt
            )
            let storedPlacement: ScheduledSource
            let storedGoalIDs: [String]
            let storedIsAutomatic: Bool
            if mergesExisting, let existingPlacement {
                if isAliasMerge {
                    storedPlacement = mergedScheduledSource(
                        existing: existingPlacement,
                        incoming: incomingPlacement,
                        canonicalID: canonicalPlacementID,
                        resolvedSourceID: resolvedSourceID
                    )
                    // Pre-v2 aliases are two record identities for one logical
                    // placement and cannot express which alias removed a tag.
                    // Preserve both sets during the one-time canonical merge.
                    storedGoalIDs = Array(Set(existingGoalIDs).union(payload.goalIDs)).sorted()
                } else {
                    storedPlacement = mergedScheduledSourceConflict(
                        existing: existingPlacement,
                        incoming: incomingPlacement,
                        preferLocalEditorial: preferLocalEditorial,
                        canonicalID: canonicalPlacementID,
                        resolvedSourceID: resolvedSourceID
                    )
                    // A true same-record conflict can represent an explicit tag
                    // removal. Relationships follow the editorial LWW side while
                    // completion remains monotonic below.
                    storedGoalIDs = Array(Set(
                        preferLocalEditorial ? existingGoalIDs : payload.goalIDs
                    )).sorted()
                }
                if storedPlacement != incomingPlacement
                    || Set(storedGoalIDs) != Set(payload.goalIDs) {
                    requiresRepublish = true
                }
                // An explicit plan wins a save conflict with automatic activity;
                // a background event must never move a learner-chosen date.
                storedIsAutomatic = existingIsAutomatic && payload.isAutomatic
                if storedIsAutomatic != payload.isAutomatic { requiresRepublish = true }
            } else {
                storedPlacement = incomingPlacement
                storedGoalIDs = Array(Set(payload.goalIDs)).sorted()
                storedIsAutomatic = payload.isAutomatic
            }

            if let existingPlacementID, existingPlacementID != canonicalPlacementID {
                requiresRepublish = true
                try execBind(
                    "DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?",
                    { statement in bind(statement, 1, existingPlacementID) }
                )
                try execBind(
                    "DELETE FROM scheduled_sources WHERE id = ?",
                    { statement in bind(statement, 1, existingPlacementID) }
                )
                if existingPlacementID != payload.placement.id {
                    // This is a pre-v2 random placement already published by
                    // this device. Even during inbound sync suppression, enqueue
                    // its tombstone so CloudKit cannot later redeliver it and
                    // race the portable deterministic record again.
                    try enqueueCascadingRecordDeletion(
                        entity: .scheduledSource,
                        logicalKey: existingPlacementID,
                        at: payload.placement.updatedAt
                    )
                }
            }
            try execBind("""
                INSERT INTO scheduled_sources (
                    id, source_id, source_url, source_normalized_url,
                    source_doi, source_published_doi,
                    planned_at, added_at, completed_at, created_at, updated_at,
                    is_automatic
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_id = excluded.source_id,
                    source_url = COALESCE(excluded.source_url, scheduled_sources.source_url),
                    source_normalized_url = COALESCE(
                        excluded.source_normalized_url,
                        scheduled_sources.source_normalized_url
                    ),
                    source_doi = COALESCE(excluded.source_doi, scheduled_sources.source_doi),
                    source_published_doi = COALESCE(
                        excluded.source_published_doi,
                        scheduled_sources.source_published_doi
                    ),
                    planned_at = excluded.planned_at,
                    added_at = excluded.added_at,
                    completed_at = excluded.completed_at,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    is_automatic = excluded.is_automatic
            """) { stmt in
                bind(stmt, 1, canonicalPlacementID)
                bind(stmt, 2, resolvedSourceID)
                bind(stmt, 3, payload.sourceIdentity?.url)
                bind(stmt, 4, payload.sourceIdentity.flatMap(normalizedScheduledIdentityURL))
                bind(stmt, 5, normalizedScheduledIdentityDOI(payload.sourceIdentity?.doi))
                bind(stmt, 6, normalizedScheduledIdentityDOI(payload.sourceIdentity?.publishedDOI))
                sqlite3_bind_double(stmt, 7, storedPlacement.plannedAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 8, storedPlacement.addedAt.timeIntervalSinceReferenceDate)
                if let completedAt = storedPlacement.completedAt {
                    sqlite3_bind_double(stmt, 9, completedAt.timeIntervalSinceReferenceDate)
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
                sqlite3_bind_double(stmt, 10, storedPlacement.createdAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 11, storedPlacement.updatedAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_int(stmt, 12, storedIsAutomatic ? 1 : 0)
            }
            try execBind("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?") { stmt in
                bind(stmt, 1, canonicalPlacementID)
            }
            for goalID in storedGoalIDs {
                try execBind("INSERT OR IGNORE INTO scheduled_source_goals (scheduled_source_id, goal_id, added_at) VALUES (?, ?, ?)") { stmt in
                    bind(stmt, 1, canonicalPlacementID)
                    bind(stmt, 2, goalID)
                    sqlite3_bind_double(stmt, 3, storedPlacement.addedAt.timeIntervalSinceReferenceDate)
                }
            }
            try replaceSourceActivityDays(
                mergedActivityDays,
                placementID: canonicalPlacementID,
                sourceID: resolvedSourceID
            )
            try exec("COMMIT")
            return (canonicalPlacementID, requiresRepublish)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func mergedSourceActivityDays(
        _ existing: [SourceActivityDay],
        _ incoming: [SourceActivityDay],
        sourceID: String,
        portableSourceKey: String
    ) -> [SourceActivityDay] {
        var byDay: [Date: SourceActivityDay] = [:]
        for candidate in existing + incoming {
            let dayStart = candidate.dayStart
            let canonical = SourceActivityDay(
                id: MemoryTutorIdentity.sourceActivityDayID(
                    portableSourceKey: portableSourceKey,
                    dayStart: dayStart
                ),
                sourceID: sourceID,
                dayStart: dayStart,
                firstActivityAt: candidate.firstActivityAt,
                lastActivityAt: candidate.lastActivityAt,
                kinds: candidate.kinds,
                completedKinds: candidate.completedKinds,
                maxFraction: candidate.maxFraction,
                engagedSeconds: candidate.engagedSeconds
            )
            if let current = byDay[dayStart] {
                byDay[dayStart] = SourceActivityDay(
                    id: canonical.id,
                    sourceID: sourceID,
                    dayStart: dayStart,
                    firstActivityAt: min(current.firstActivityAt, canonical.firstActivityAt),
                    lastActivityAt: max(current.lastActivityAt, canonical.lastActivityAt),
                    kinds: current.kinds.union(canonical.kinds),
                    completedKinds: current.completedKinds.union(canonical.completedKinds),
                    maxFraction: max(current.maxFraction, canonical.maxFraction),
                    // Two records of one day are the same sitting seen twice,
                    // so the longer one stands; adding would double it.
                    engagedSeconds: max(current.engagedSeconds, canonical.engagedSeconds)
                )
            } else {
                byDay[dayStart] = canonical
            }
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private func replaceSourceActivityDays(
        _ activityDays: [SourceActivityDay],
        placementID: String,
        sourceID: String
    ) throws {
        try execBind("DELETE FROM source_activity_days WHERE source_id = ?") { stmt in
            bind(stmt, 1, sourceID)
        }
        for day in activityDays {
            // The id is derived from the source's portable identity and the day,
            // so a duplicate source row that shares that identity can already
            // hold it under its own source_id; the DELETE above only cleared
            // this source's rows. A plain INSERT then failed the primary key,
            // the inbound placement save rolled back, and its CloudKit record
            // retried on every flush. Fold the two into one row instead.
            // Engaged seconds merge by MAX here: this is another device's total
            // for the same day, not a fresh slice, so adding would count the
            // synced total twice on every flush.
            try execBind("""
                INSERT INTO source_activity_days (
                    id, scheduled_source_id, source_id, day_start,
                    first_activity_at, last_activity_at, kinds, completed_kinds, max_fraction,
                    engaged_seconds
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    scheduled_source_id = excluded.scheduled_source_id,
                    source_id = excluded.source_id,
                    day_start = excluded.day_start,
                    first_activity_at = MIN(source_activity_days.first_activity_at, excluded.first_activity_at),
                    last_activity_at = MAX(source_activity_days.last_activity_at, excluded.last_activity_at),
                    kinds = source_activity_days.kinds | excluded.kinds,
                    completed_kinds = source_activity_days.completed_kinds | excluded.completed_kinds,
                    max_fraction = MAX(source_activity_days.max_fraction, excluded.max_fraction),
                    engaged_seconds = MAX(source_activity_days.engaged_seconds, excluded.engaged_seconds)
            """) { stmt in
                bind(stmt, 1, day.id)
                bind(stmt, 2, placementID)
                bind(stmt, 3, sourceID)
                sqlite3_bind_double(stmt, 4, day.dayStart.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 5, day.firstActivityAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 6, day.lastActivityAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_int64(stmt, 7, sourceActivityMask(day.kinds))
                sqlite3_bind_int64(stmt, 8, sourceActivityMask(day.completedKinds))
                sqlite3_bind_double(stmt, 9, SourceActivityDay.clampFraction(day.maxFraction))
                sqlite3_bind_double(stmt, 10, SourceActivityDay.clampSeconds(day.engagedSeconds))
            }
        }
    }

    private func loadScheduledSourceRow(id: String) throws -> ScheduledSource? {
        var placement: ScheduledSource?
        try queryBind("""
            SELECT id, source_id, planned_at, added_at, completed_at, created_at, updated_at
            FROM scheduled_sources
            WHERE id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, id)
        }) { statement in
            placement = self.readScheduledSourceRow(statement)
        }
        return placement
    }

    private func scheduledSourceMembershipIDs(placementID: String) throws -> [String] {
        var goalIDs: [String] = []
        try queryBind(
            "SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = ? ORDER BY goal_id",
            bind: { statement in bind(statement, 1, placementID) }
        ) { statement in
            if let goalID = self.string(statement, 0) {
                goalIDs.append(goalID)
            }
        }
        return goalIDs
    }

    private func normalizedScheduledIdentityURL(
        _ identity: CloudKitSourceIdentityPayload
    ) -> String? {
        if let normalized = identity.normalizedURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !normalized.isEmpty {
            return normalized
        }
        guard let url = identity.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { return nil }
        return URLNormalizer.normalize(url)
    }

    private func normalizedScheduledIdentityDOI(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !value.isEmpty else { return nil }
        return value
    }

    /// Repair a ScheduledSource that arrived before its Source. Portable identity
    /// columns make this
    /// targeted and indexed; no per-source full Schedule scan is permitted.
    @discardableResult
    func reconcileScheduledSourcePlacements(forSourceID sourceID: String) throws -> Int {
        guard let identity = try sourceIdentities(for: [sourceID]).first else { return 0 }
        let normalizedURL = normalizedScheduledIdentityURL(identity)
        let doi = normalizedScheduledIdentityDOI(identity.doi)
        let publishedDOI = normalizedScheduledIdentityDOI(identity.publishedDOI)
        let portableKey = MemoryTutorIdentity.portableSourceKey(
            sourceID: sourceID,
            normalizedURL: normalizedURL,
            doi: doi,
            publishedDOI: publishedDOI
        )
        let canonicalID = MemoryTutorIdentity.scheduledSourcePlacementID(
            portableSourceKey: portableKey
        )
        var candidateIDs = Set<String>()
        func collect(_ sql: String, _ value: String) throws {
            try queryBind(sql, bind: { statement in
                bind(statement, 1, value)
            }) { statement in
                if let id = self.string(statement, 0) { candidateIDs.insert(id) }
            }
        }
        try collect(
            "SELECT id FROM scheduled_sources INDEXED BY idx_scheduled_sources_source WHERE source_id = ?",
            sourceID
        )
        if let normalizedURL {
            try collect(
                """
                    SELECT id
                    FROM scheduled_sources INDEXED BY idx_scheduled_sources_identity_url
                    WHERE source_normalized_url = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = scheduled_sources.source_id
                      )
                """,
                normalizedURL
            )
        }
        for value in Set([doi, publishedDOI].compactMap { $0 }) {
            try collect(
                """
                    SELECT id
                    FROM scheduled_sources INDEXED BY idx_scheduled_sources_identity_doi
                    WHERE source_doi = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = scheduled_sources.source_id
                      )
                """,
                value
            )
            try collect(
                """
                    SELECT id
                    FROM scheduled_sources INDEXED BY idx_scheduled_sources_identity_published_doi
                    WHERE source_published_doi = ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = scheduled_sources.source_id
                      )
                """,
                value
            )
        }
        guard !candidateIDs.isEmpty else { return 0 }

        // A portable identity can legitimately be shared by two extant local
        // sources. Exact relationships remain authoritative; never let a later
        // duplicate Source save steal a canonical placement or absorb an orphan
        // while that canonical ID already belongs to another valid source.
        if let canonical = try loadScheduledSourceRow(id: canonicalID),
           canonical.sourceID != sourceID,
           try sourceExists(canonical.sourceID) {
            return 0
        }

        var rows: [ScheduledSource] = []
        var goalIDs = Set<String>()
        var activityRows: [SourceActivityDay] = []
        var isAutomatic = true
        for id in candidateIDs.sorted() {
            if let row = try loadScheduledSourceRow(id: id) { rows.append(row) }
            goalIDs.formUnion(try scheduledSourceMembershipIDs(placementID: id))
            let candidateIsAutomatic = try scheduledSourceIsAutomatic(placementID: id)
            isAutomatic = isAutomatic && candidateIsAutomatic
            try queryBind("""
                SELECT id, source_id, day_start, first_activity_at, last_activity_at,
                       kinds, completed_kinds, max_fraction, engaged_seconds
                FROM source_activity_days
                WHERE scheduled_source_id = ?
            """, bind: { statement in
                bind(statement, 1, id)
            }) { statement in
                if let activity = self.readSourceActivityDay(statement) {
                    activityRows.append(activity)
                }
            }
        }
        guard var merged = rows.first else { return 0 }
        merged = ScheduledSource(
            id: canonicalID,
            sourceID: sourceID,
            plannedAt: merged.plannedAt,
            addedAt: merged.addedAt,
            completedAt: merged.completedAt,
            createdAt: merged.createdAt,
            updatedAt: merged.updatedAt
        )
        for row in rows.dropFirst() {
            merged = mergedScheduledSource(
                existing: merged,
                incoming: row,
                canonicalID: canonicalID,
                resolvedSourceID: sourceID
            )
        }
        let repairedCount = rows.filter {
            $0.id != canonicalID || $0.sourceID != sourceID
        }.count

        for id in candidateIDs {
            try execBind(
                "DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?",
                { statement in bind(statement, 1, id) }
            )
            try execBind(
                "DELETE FROM source_activity_days WHERE scheduled_source_id = ?",
                { statement in bind(statement, 1, id) }
            )
        }
        for id in candidateIDs {
            try execBind(
                "DELETE FROM scheduled_sources WHERE id = ?",
                { statement in bind(statement, 1, id) }
            )
        }
        try execBind("""
            INSERT INTO scheduled_sources (
                id, source_id, source_url, source_normalized_url,
                source_doi, source_published_doi,
                planned_at, added_at, completed_at, created_at, updated_at,
                is_automatic
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            bind(statement, 1, canonicalID)
            bind(statement, 2, sourceID)
            bind(statement, 3, identity.url)
            bind(statement, 4, normalizedURL)
            bind(statement, 5, doi)
            bind(statement, 6, publishedDOI)
            sqlite3_bind_double(statement, 7, merged.plannedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 8, merged.addedAt.timeIntervalSinceReferenceDate)
            bind(statement, 9, merged.completedAt?.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 10, merged.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 11, merged.updatedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(statement, 12, isAutomatic ? 1 : 0)
        }
        for goalID in goalIDs.sorted() {
            try execBind("""
                INSERT OR IGNORE INTO scheduled_source_goals (
                    scheduled_source_id, goal_id, added_at
                ) VALUES (?, ?, ?)
            """) { statement in
                bind(statement, 1, canonicalID)
                bind(statement, 2, goalID)
                sqlite3_bind_double(statement, 3, merged.addedAt.timeIntervalSinceReferenceDate)
            }
        }
        let mergedActivities = mergedSourceActivityDays(
            activityRows,
            [],
            sourceID: sourceID,
            portableSourceKey: portableKey
        )
        try replaceSourceActivityDays(
            mergedActivities,
            placementID: canonicalID,
            sourceID: sourceID
        )
        for aliasID in candidateIDs where aliasID != canonicalID {
            try enqueueCascadingRecordDeletion(
                entity: .scheduledSource,
                logicalKey: aliasID,
                at: merged.updatedAt
            )
        }
        if repairedCount > 0 {
            try upsertSyncSave(
                entity: .scheduledSource,
                logicalKey: canonicalID,
                at: max(Date(), merged.updatedAt),
                tutorOnly: true
            )
        }
        return repairedCount
    }

    /// The alias merge is intentionally commutative. `updatedAt` owns the
    /// editable planned day; equal timestamps break toward the earlier planned
    /// value so opposite CloudKit delivery orders still produce identical rows.
    /// All other dates are monotonic high/low-water marks.
    private func mergedScheduledSource(
        existing: ScheduledSource,
        incoming: ScheduledSource,
        canonicalID: String,
        resolvedSourceID: String
    ) -> ScheduledSource {
        let plannedAt: Date
        if existing.updatedAt > incoming.updatedAt {
            plannedAt = existing.plannedAt
        } else if incoming.updatedAt > existing.updatedAt {
            plannedAt = incoming.plannedAt
        } else {
            plannedAt = min(existing.plannedAt, incoming.plannedAt)
        }
        let completedAt: Date?
        switch (existing.completedAt, incoming.completedAt) {
        case let (left?, right?):
            completedAt = max(left, right)
        case let (left?, nil):
            completedAt = left
        case let (nil, right?):
            completedAt = right
        case (nil, nil):
            completedAt = nil
        }
        return ScheduledSource(
            id: canonicalID,
            sourceID: resolvedSourceID,
            plannedAt: plannedAt,
            addedAt: min(existing.addedAt, incoming.addedAt),
            completedAt: completedAt,
            createdAt: min(existing.createdAt, incoming.createdAt),
            updatedAt: max(existing.updatedAt, incoming.updatedAt)
        )
    }

    private func mergedScheduledSourceConflict(
        existing: ScheduledSource,
        incoming: ScheduledSource,
        preferLocalEditorial: Bool,
        canonicalID: String,
        resolvedSourceID: String
    ) -> ScheduledSource {
        let editorial = preferLocalEditorial ? existing : incoming
        return ScheduledSource(
            id: canonicalID,
            sourceID: resolvedSourceID,
            plannedAt: editorial.plannedAt,
            addedAt: min(existing.addedAt, incoming.addedAt),
            completedAt: maxOptionalDate(existing.completedAt, incoming.completedAt),
            createdAt: min(existing.createdAt, incoming.createdAt),
            updatedAt: max(existing.updatedAt, incoming.updatedAt)
        )
    }

    func deleteScheduledSourceRecord(id: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM scheduled_source_goals WHERE scheduled_source_id = ?") { stmt in
                bind(stmt, 1, id)
            }
            try execBind("DELETE FROM source_activity_days WHERE scheduled_source_id = ?") { stmt in
                bind(stmt, 1, id)
            }
            try execBind("DELETE FROM scheduled_sources WHERE id = ?") { stmt in
                bind(stmt, 1, id)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
