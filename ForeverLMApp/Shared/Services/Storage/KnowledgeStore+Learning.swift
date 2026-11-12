import Foundation
import SQLite3

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
    }

    /// Split a companion goal into one or more child notebooks by moving sources (and
    /// linked open questions) out of the parent pool. Sources move — they are not copied.
    ///
    /// The children live where the parent lives: a team's Notebook splits into
    /// that team, in its zone, and a Goal's children name the Goal's Notebook.
    /// When `keepParent` is false and the parent is left with no sources, the
    /// parent is removed — but only after everything else it held (its chats,
    /// nested Goals, tasks, Docs, courses, open questions, Ideas' links,
    /// Directions and the rest, `NotebookChildren.moveAll`) has moved
    /// to the child that took the most sources (the first, on a tie), which
    /// the result names as `heirGoalID`, and its own words (synthesis notes,
    /// Instructions, research questions, summary, repository) are folded into
    /// that child by a merge's rule (`NotebookFold.folded`). A raw
    /// DELETE of the parent would leave all of that
    /// pointing at an id that was gone, or take it with the row.
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
        // (schema v2 §5.2).
        return try splitNotebookUnderGeneration2(parentID: sourceGoalID, splits: normalizedSplits, keepParent: keepParent)
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
        // survivor (schema v2 §5.2).
        let renamed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try mergeNotebooksUnderGeneration2(
            survivorID: survivorID, mergeeIDs: mergees.map(\.id), title: renamed?.isEmpty == false ? renamed : nil, mergeNotes: mergeNotes
        )
    }

    // MARK: A removed notebook's own words

    // MARK: Moving a notebook's contents

    // Each helper below runs inside the caller's transaction and republishes
    // every synced record it re-points. Ids are collected before the UPDATE:
    // the rows are what the sync queue needs, and a count alone could not
    // name them.

    private func deleteCompanionGoalItem(goalID: String, sourceID: String) throws {
        try execBind("DELETE FROM learning_goal_items WHERE goal_id = ? AND source_id = ?") { stmt in
            bind(stmt, 1, goalID)
            bind(stmt, 2, sourceID)
        }
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
    /// `linkedCourseIDs`, where a shorter present list is an explicit removal.
    /// False, and nothing written, when
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
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

}
