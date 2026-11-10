// KnowledgeStore: loading, deleting, saving and remapping learning goal records.
import Foundation
import SQLite3

extension KnowledgeStore {

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

}
