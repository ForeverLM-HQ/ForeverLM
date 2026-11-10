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
        // survivor (schema v2 §5.2). Generation 1 goes on as build 177 does.
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
        // A merged notebook's stub stays as a row (schema v2 §5.2): a redirect, never a notebook of
        // its own.
        let live = "WHERE COALESCE(merged_into, '') = '' AND COALESCE(moved_to, '') = ''"
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
        try exec("BEGIN IMMEDIATE")
        do {
            for sessionID in sessionIDs {
                try execBind("UPDATE review_sessions SET goal_id = NULL WHERE id = ?") { statement in
                    bind(statement, 1, sessionID)
                }
                noteStoreChanged()
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
    /// links cascade with it; its file index stays, unfiled), its Schedule
    /// placements and its Directions. A merge and a split that removes
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

        try execBind("DELETE FROM scheduled_source_goals WHERE goal_id = ?") { stmt in
            bind(stmt, 1, goalID)
        }
        // The file index lost its foreign key in schema 154: its rows stay, unfiled.
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
            }
        }
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
            try queryBind("SELECT source_id, order_key FROM learning_goal_items WHERE goal_id = ? AND order_key IS NOT NULL", bind: { stmt in
                self.bind(stmt, 1, goal.id)
            }) { stmt in
                if let source = self.string(stmt, 0), let key = self.string(stmt, 1) { heldOrderKeys[source] = key }
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

    /// A new item takes `orderKey`, or a key after the pool's last, so its Entry has its place
    /// (schema v2 §3.5.8).
    func saveLearningGoalItem(_ item: LearningGoalItem, goalID: String, ignoreDuplicates: Bool = false, orderKey: String? = nil) throws {
        let insertVerb = ignoreDuplicates ? "INSERT OR IGNORE" : "INSERT"
        let key = try orderKey ?? EntryOrderKeys.appendedKey(goalID: goalID, connection: self)
        try execBind("""
            \(insertVerb) INTO learning_goal_items (id, goal_id, source_id, added_at, completed_at, origin, review_state, relevance, last_quizzed_at, quiz_count, last_score, sequence, order_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            bind(stmt, 13, key)
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

    /// Create the placement row for a source if it does not exist yet. Returns its id.
    /// Does not emit sync changes — callers do, after COMMIT.
    private func ensureScheduledSourcePlacement(sourceID: String, plannedAt: Date, now: Date) throws -> String {
        if let existing = try scheduledSourceID(forSource: sourceID) { return existing }
        // Generation 2: the row is the Placement record's, `pl:<source wire id>` on the wire id
        // (§3.5.21), so every Mac and copy names one placement per work.
        let key = try personalStateSourceKey(sourceID)
        let id = SyncIdentity.placementID(sourceID: key)
        try insertScheduledSourcePlacement(id: id, sourceID: key, plannedAt: plannedAt, now: now)
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
        ids.formUnion(try readOrConsumedSourceIDs())
        try query("SELECT source_id FROM source_activity_days") { stmt in
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
            } else if try scheduledSourceGoalCount(placementID: placementID) == 0 {
                try convertPlacementToAutomaticHistory(
                    placementID: placementID,
                    sourceID: sourceID,
                    at: now
                )
            }
            try touchLearningGoal(goalID, at: now)
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
            } else {
                try convertPlacementToAutomaticHistory(
                    placementID: placementID,
                    sourceID: sourceID,
                    at: Date()
                )
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

                var clearedReadAt: Date?
                if let readAt = entry.readAt, readAt >= dayStart, readAt < dayEnd {
                    try updateReadingState(sourceID: entry.sourceID) { $0.readAt = nil }
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

        try fillReadingStateReadAt(sourceID: sourceID, at: now)

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
        try fillReadingStateCompletedAt(sourceID: sourceID, at: completedAt)

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

        try fillReadingStateReadAt(sourceID: sourceID, at: sourceReadAt ?? recordedAt)

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

}
