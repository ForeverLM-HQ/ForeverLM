import Foundation
import SQLite3

// Assignments: something to learn that one member of a team — a parent, in a
// family — gives another. An assignment is an ordinary Notebook task in the
// team's one Assignments Notebook (`TeamContentIdentity.assignmentsNotebookID`),
// assigned to the member and pointing at the team's copy of a source or Doc,
// so it travels, reads and edits exactly like every other task on the board.
// What makes it an assignment is only that it finishes itself: reading the
// source to the end, or reviewing it, marks the learner's open tasks for it
// done, and the parent sees that on the board. Nothing else of the learner's
// progress leaves their library (docs/teams-design.md, decision 7).
// docs/family-design.md.
extension KnowledgeStore {

    static let assignmentsNotebookTitle = "Assignments"

    /// The team's Assignments Notebook, created on first use. The fixed id
    /// makes a second device's creation the same record.
    @discardableResult
    func ensureAssignmentsNotebook(teamID: String) throws -> LearningGoalRecord {
        let id = TeamContentIdentity.assignmentsNotebookID(teamID: teamID)
        if let existing = try loadLearningGoal(id) { return existing }
        let now = Date()
        return try createCompanionGoal(
            title: Self.assignmentsNotebookTitle,
            topic: "",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: [],
            teamID: teamID,
            id: id
        )
    }

    /// A source's title as the library shows it, for naming its assignment.
    func assignableSourceTitle(_ sourceID: String) throws -> String? {
        var title: String?
        try queryBind("SELECT title FROM source_projection WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            title = string(stmt, 0)
        }
        return title
    }

    /// The open task that already assigns this source or Doc to this member
    /// in the team's Assignments Notebook, so assigning twice updates it.
    func openAssignment(
        teamID: String,
        assigneeRecordName: String,
        sourceID: String?,
        artifactID: String?
    ) throws -> NotebookTaskRecord? {
        let notebookID = TeamContentIdentity.assignmentsNotebookID(teamID: teamID)
        return try loadNotebookTasks(notebookID: notebookID).first { task in
            task.status != .done
                && task.assigneeRecordName == assigneeRecordName
                && (sourceID == nil || task.sourceID == sourceID)
                && (artifactID == nil || task.artifactID == artifactID)
        }
    }

    /// Mark done every open task assigned to this account whose source is the
    /// one just finished — the row itself, or any team's copy of it, since a
    /// learner who reads their own copy of an assigned paper has done the
    /// assignment. Only teams this account may edit are touched: a read-only
    /// member cannot write the team's board, and the sync queue would refuse
    /// it. Transaction-free, like the completion helpers that call it, so the
    /// task and the completion commit together. Returns the tasks it closed.
    @discardableResult
    func completeAssignedTasks(forSourceID sourceID: String, at date: Date) throws -> [String] {
        let candidates = try assignedTaskSources(forSourceID: sourceID)
        guard !candidates.isEmpty else { return [] }

        var closed: [String] = []
        for candidate in candidates {
            try queryBind("""
                SELECT pt.id FROM notebook_tasks pt
                JOIN team_members m
                  ON m.team_id = pt.team_id AND m.is_current_user = 1
                 AND m.user_record_name = pt.assignee_record_name
                WHERE pt.team_id = ? AND pt.source_id = ? AND pt.status <> 'done'
            """, bind: { stmt in
                bind(stmt, 1, candidate.teamID)
                bind(stmt, 2, candidate.sourceID)
            }) { stmt in
                if let id = self.string(stmt, 0), !closed.contains(id) { closed.append(id) }
            }
        }
        for taskID in closed {
            try execBind("""
                UPDATE notebook_tasks
                SET status = 'done', completed_at = ?, updated_at = ?
                WHERE id = ?
            """) { stmt in
                sqlite3_bind_double(stmt, 1, date.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 2, date.timeIntervalSinceReferenceDate)
                bind(stmt, 3, taskID)
            }
            noteStoreChanged()
        }
        return closed
    }

    /// Reopen the tasks `completeAssignedTasks` closed for this source at
    /// exactly `completedAt`, for a completion that is being taken back
    /// (`forgetAutomaticSourceActivity`). The moment is the link: the review
    /// path stamps its placement and the tasks it finishes with one time, so
    /// a task the learner finished some other way is left done. Its earlier
    /// status is not recorded, so it returns to To do. Transaction-free, like
    /// its twin. Returns the tasks it reopened.
    @discardableResult
    func reopenAssignedTasks(forSourceID sourceID: String, completedAt: Date, at date: Date) throws -> [String] {
        let candidates = try assignedTaskSources(forSourceID: sourceID)
        guard !candidates.isEmpty else { return [] }

        var reopened: [String] = []
        for candidate in candidates {
            try queryBind("""
                SELECT pt.id FROM notebook_tasks pt
                JOIN team_members m
                  ON m.team_id = pt.team_id AND m.is_current_user = 1
                 AND m.user_record_name = pt.assignee_record_name
                WHERE pt.team_id = ? AND pt.source_id = ? AND pt.status = 'done'
                  AND ABS(pt.completed_at - ?) < 0.001
            """, bind: { stmt in
                bind(stmt, 1, candidate.teamID)
                bind(stmt, 2, candidate.sourceID)
                sqlite3_bind_double(stmt, 3, completedAt.timeIntervalSinceReferenceDate)
            }) { stmt in
                if let id = self.string(stmt, 0), !reopened.contains(id) { reopened.append(id) }
            }
        }
        for taskID in reopened {
            try execBind("""
                UPDATE notebook_tasks
                SET status = 'todo', completed_at = NULL, updated_at = ?
                WHERE id = ?
            """) { stmt in
                sqlite3_bind_double(stmt, 1, date.timeIntervalSinceReferenceDate)
                bind(stmt, 2, taskID)
            }
            noteStoreChanged()
        }
        return reopened
    }

    /// Where an assignment for this source can sit: the row itself and any
    /// team's copy of it, in every team this account may edit. A read-only
    /// member cannot write the team's board, and the sync queue would refuse
    /// it.
    private func assignedTaskSources(forSourceID sourceID: String) throws -> [(teamID: String, sourceID: String)] {
        var url: String?
        try queryBind("SELECT url FROM source_projection WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            url = string(stmt, 0)
        }

        var teamIDs: [String] = []
        try query("""
            SELECT t.id FROM teams t
            WHERE t.permission = 'readWrite'
              AND EXISTS (SELECT 1 FROM team_members m WHERE m.team_id = t.id AND m.is_current_user = 1)
        """) { stmt in
            if let teamID = self.string(stmt, 0) { teamIDs.append(teamID) }
        }
        var candidates: [(teamID: String, sourceID: String)] = []
        for teamID in teamIDs {
            candidates.append((teamID, sourceID))
            if let url, !url.isEmpty {
                candidates.append((teamID, try teamSourceCopyID(teamID: teamID, url: url)))
            }
        }
        return candidates
    }

    /// Every task assigned to this account, in every team, open ones first by
    /// due date. Finished ones are included for `recentlyDoneSince`, so a
    /// learner sees what they just finished leave the list rather than vanish.
    func loadAssignedToMe(recentlyDoneSince: Date? = nil) throws -> [AssignedTask] {
        let columns = Self.notebookTaskColumns
            .split(separator: ",")
            .map { "pt." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ", ")
        var result: [AssignedTask] = []
        try queryBind("""
            SELECT \(columns), t.name,
                   (SELECT title FROM source_projection WHERE id = pt.source_id),
                   (SELECT source_type FROM source_projection WHERE id = pt.source_id),
                   (SELECT title FROM global_artifacts WHERE id = pt.artifact_id)
            FROM notebook_tasks pt
            JOIN teams t ON t.id = pt.team_id
            JOIN team_members m
              ON m.team_id = pt.team_id AND m.is_current_user = 1
             AND m.user_record_name = pt.assignee_record_name
            WHERE pt.status <> 'done' OR (? IS NOT NULL AND pt.completed_at >= ?)
            ORDER BY pt.status = 'done', pt.due_at IS NULL, pt.due_at, pt.created_at, pt.id
        """, bind: { stmt in
            if let recentlyDoneSince {
                sqlite3_bind_double(stmt, 1, recentlyDoneSince.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 2, recentlyDoneSince.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 1)
                sqlite3_bind_null(stmt, 2)
            }
        }) { stmt in
            guard let task = self.readNotebookTaskRow(stmt), let teamName = self.string(stmt, 17) else { return }
            result.append(AssignedTask(
                task: task,
                teamName: teamName,
                sourceTitle: self.string(stmt, 18),
                sourceType: self.string(stmt, 19).flatMap(StudioSourceType.init(rawValue:)),
                artifactTitle: self.string(stmt, 20)
            ))
        }
        return result
    }
}

/// A task assigned to this account, with what the Today panel needs to draw
/// it without another query: the team it came from and what it points at.
struct AssignedTask: Identifiable, Equatable, Sendable {
    let task: NotebookTaskRecord
    let teamName: String
    let sourceTitle: String?
    let sourceType: StudioSourceType?
    let artifactTitle: String?

    var id: String { task.id }
    var teamID: String? { task.teamID }
    var isDone: Bool { task.status == .done }
}
