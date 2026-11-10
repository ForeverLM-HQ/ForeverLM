import Foundation
import SQLite3

// The SQLite half of Teams: the `teams`, `team_members` and `notebook_tasks`
// tables, the `team_id` column every team-scoped row carries, how a record's
// zone home is derived from that column, and the copy operations that put a
// source, Notebook, Doc or chat transcript into a team's namespace.
//
// Nothing here talks to CloudKit. StorageService+Teams owns the zone, the
// share and the files; sync owns delivery. This file only has
// to be right about rows.
extension KnowledgeStore {

    // MARK: - Teams

    private static let teamColumns = """
        id, name, role, permission, zone_scope, zone_name, zone_owner_record_name,
        share_record_name, share_url, created_at, joined_at, updated_at, family_plan_code
    """

    func loadTeams() throws -> [TeamRecord] {
        var teams: [TeamRecord] = []
        try query("SELECT \(Self.teamColumns) FROM teams ORDER BY name COLLATE NOCASE, id") { stmt in
            if let team = readTeamRow(stmt) { teams.append(team) }
        }
        return teams
    }

    func loadTeam(_ id: String) throws -> TeamRecord? {
        var team: TeamRecord?
        try queryBind("SELECT \(Self.teamColumns) FROM teams WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            team = readTeamRow(stmt)
        }
        return team
    }

    func loadTeam(home: CloudKitZoneHome) throws -> TeamRecord? {
        guard let teamID = home.teamID else { return nil }
        return try loadTeam(teamID)
    }

    private func readTeamRow(_ stmt: OpaquePointer?) -> TeamRecord? {
        guard let id = string(stmt, 0),
              let name = string(stmt, 1),
              let role = string(stmt, 2).flatMap(TeamRole.init(rawValue:)),
              let permission = string(stmt, 3).flatMap(TeamPermission.init(rawValue:)),
              let scope = string(stmt, 4).flatMap(CloudKitZoneHome.Scope.init(rawValue:)),
              let zoneName = string(stmt, 5) else { return nil }
        return TeamRecord(
            id: id,
            name: name,
            role: role,
            permission: permission,
            zoneScope: scope,
            zoneName: zoneName,
            zoneOwnerRecordName: string(stmt, 6),
            shareRecordName: string(stmt, 7),
            shareURL: string(stmt, 8),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 9)),
            joinedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 10)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 11)),
            familyPlanCode: string(stmt, 12)
        )
    }

    /// Upsert the local team row. The owner's own devices also publish the
    /// team's record into its zone so members learn the name; a member never
    /// republishes what arrived from the owner.
    func saveTeam(_ team: TeamRecord, publish: Bool = true) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try upsertTeamRow(team)
            if publish, team.role == .owner {
                noteStoreChanged()
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func upsertTeamRow(_ team: TeamRecord) throws {
        try execBind("""
            INSERT INTO teams (\(Self.teamColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                role = excluded.role,
                permission = excluded.permission,
                zone_scope = excluded.zone_scope,
                zone_name = excluded.zone_name,
                zone_owner_record_name = excluded.zone_owner_record_name,
                share_record_name = COALESCE(excluded.share_record_name, teams.share_record_name),
                share_url = COALESCE(excluded.share_url, teams.share_url),
                created_at = excluded.created_at,
                joined_at = excluded.joined_at,
                updated_at = excluded.updated_at,
                family_plan_code = excluded.family_plan_code
        """) { stmt in
            bind(stmt, 1, team.id)
            bind(stmt, 2, team.name)
            bind(stmt, 3, team.role.rawValue)
            bind(stmt, 4, team.permission.rawValue)
            bind(stmt, 5, team.zoneScope.rawValue)
            bind(stmt, 6, team.zoneName)
            bind(stmt, 7, team.zoneOwnerRecordName)
            bind(stmt, 8, team.shareRecordName)
            bind(stmt, 9, team.shareURL)
            sqlite3_bind_double(stmt, 10, team.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 11, team.joinedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 12, team.updatedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 13, team.familyPlanCode)
        }
    }

    func renameTeam(_ teamID: String, name: String, at date: Date = Date()) throws {
        guard var team = try loadTeam(teamID) else {
            throw KnowledgeStoreError.invalidData("Team \(teamID) does not exist.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KnowledgeStoreError.invalidData("A team needs a name.")
        }
        team.name = trimmed
        team.updatedAt = date
        try saveTeam(team)
    }

    private func ids(_ sql: String, _ key: String) throws -> [String] {
        var result: [String] = []
        try queryBind(sql, bind: { stmt in bind(stmt, 1, key) }) { stmt in
            if let id = self.string(stmt, 0) { result.append(id) }
        }
        return result
    }

    private func singleString(_ sql: String, key: String) throws -> String? {
        var value: String?
        try queryBind(sql, bind: { stmt in bind(stmt, 1, key) }) { stmt in
            value = self.string(stmt, 0)
        }
        return value
    }

    /// A record arrived from a team zone: whatever its payload said, it is
    /// that team's. The zone is the authority, so a client that omitted the
    /// field (or an older one that never knew it) still files correctly.
    func stampTeam(entity: CloudKitSyncEntity, logicalKey: String, teamID: String) throws {
        let table: String
        switch entity {
        case .source: table = "sources"
        case .learningGoal: table = "learning_goals"
        case .artifact: table = "global_artifacts"
        case .reviewSession: table = "review_sessions"
        case .notebookTask: table = "notebook_tasks"
        case .shareRequest: table = "share_requests"
        case .course: table = "courses"
        default: return
        }
        try execBind("UPDATE \(table) SET team_id = ? WHERE id = ? AND team_id IS NOT ?") { stmt in
            bind(stmt, 1, teamID)
            bind(stmt, 2, logicalKey)
            bind(stmt, 3, teamID)
        }
    }

    // MARK: - Per-member state on team copies

    // MARK: - Members

    func loadTeamMembers(teamID: String) throws -> [TeamMemberRecord] {
        var members: [TeamMemberRecord] = []
        try queryBind("""
            SELECT user_record_name, display_name, email, role, permission, acceptance_status, is_current_user, updated_at
            FROM team_members
            WHERE team_id = ?
            ORDER BY role, display_name COLLATE NOCASE, user_record_name
        """, bind: { stmt in bind(stmt, 1, teamID) }) { stmt in
            guard let userRecordName = self.string(stmt, 0),
                  let displayName = self.string(stmt, 1),
                  let role = self.string(stmt, 3).flatMap(TeamRole.init(rawValue:)),
                  let permission = self.string(stmt, 4).flatMap(TeamPermission.init(rawValue:)),
                  let acceptance = self.string(stmt, 5) else { return }
            members.append(TeamMemberRecord(
                userRecordName: userRecordName,
                teamID: teamID,
                displayName: displayName,
                email: self.string(stmt, 2),
                role: role,
                permission: permission,
                acceptanceStatus: acceptance,
                isCurrentUser: sqlite3_column_int(stmt, 6) != 0,
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7))
            ))
        }
        return members
    }

    func replaceTeamMembers(teamID: String, members: [TeamMemberRecord]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM team_members WHERE team_id = ?") { stmt in bind(stmt, 1, teamID) }
            for member in members {
                try execBind("""
                    INSERT INTO team_members
                        (team_id, user_record_name, display_name, email, role, permission, acceptance_status, is_current_user, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { stmt in
                    bind(stmt, 1, teamID)
                    bind(stmt, 2, member.userRecordName)
                    bind(stmt, 3, member.displayName)
                    bind(stmt, 4, member.email)
                    bind(stmt, 5, member.role.rawValue)
                    bind(stmt, 6, member.permission.rawValue)
                    bind(stmt, 7, member.acceptanceStatus)
                    sqlite3_bind_int(stmt, 8, member.isCurrentUser ? 1 : 0)
                    sqlite3_bind_double(stmt, 9, member.updatedAt.timeIntervalSinceReferenceDate)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Notebook tasks

    static let notebookTaskColumns = """
        id, notebook_id, team_id, title, notes, status, assignee_record_name, assignee_display_name,
        due_at, source_id, artifact_id, sort_order, created_by_record_name, created_by_display_name,
        created_at, updated_at, completed_at
    """

    func loadNotebookTasks(notebookID: String) throws -> [NotebookTaskRecord] {
        var tasks: [NotebookTaskRecord] = []
        try queryBind("""
            SELECT \(Self.notebookTaskColumns) FROM notebook_tasks
            WHERE notebook_id = ?
            ORDER BY sort_order, created_at, id
        """, bind: { stmt in bind(stmt, 1, notebookID) }) { stmt in
            if let task = readNotebookTaskRow(stmt) { tasks.append(task) }
        }
        return tasks
    }

    func loadNotebookTasks(teamID: String) throws -> [NotebookTaskRecord] {
        var tasks: [NotebookTaskRecord] = []
        try queryBind("""
            SELECT \(Self.notebookTaskColumns) FROM notebook_tasks
            WHERE team_id = ?
            ORDER BY notebook_id, sort_order, created_at, id
        """, bind: { stmt in bind(stmt, 1, teamID) }) { stmt in
            if let task = readNotebookTaskRow(stmt) { tasks.append(task) }
        }
        return tasks
    }

    func loadNotebookTask(_ id: String) throws -> NotebookTaskRecord? {
        var task: NotebookTaskRecord?
        try queryBind("SELECT \(Self.notebookTaskColumns) FROM notebook_tasks WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            task = readNotebookTaskRow(stmt)
        }
        return task
    }

    func readNotebookTaskRow(_ stmt: OpaquePointer?) -> NotebookTaskRecord? {
        guard let id = string(stmt, 0),
              let notebookID = string(stmt, 1),
              let title = string(stmt, 3),
              let status = string(stmt, 5).flatMap(NotebookTaskStatus.init(rawValue:)) else { return nil }
        func date(_ idx: Int32) -> Date? {
            sqlite3_column_type(stmt, idx) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, idx))
        }
        return NotebookTaskRecord(
            id: id,
            notebookID: notebookID,
            teamID: string(stmt, 2),
            title: title,
            notes: string(stmt, 4) ?? "",
            status: status,
            assigneeRecordName: string(stmt, 6),
            assigneeDisplayName: string(stmt, 7),
            dueAt: date(8),
            sourceID: string(stmt, 9),
            artifactID: string(stmt, 10),
            sortOrder: sqlite3_column_double(stmt, 11),
            createdByRecordName: string(stmt, 12),
            createdByDisplayName: string(stmt, 13),
            createdAt: date(14) ?? Date(),
            updatedAt: date(15) ?? Date(),
            completedAt: date(16)
        )
    }

    /// Upsert a task row without touching the sync queue. The inbound apply
    /// path uses this; local edits go through `saveNotebookTask`.
    func saveNotebookTaskRecord(_ task: NotebookTaskRecord) throws {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw KnowledgeStoreError.invalidData("A task needs a title.")
        }
        try execBind("""
            INSERT INTO notebook_tasks (\(Self.notebookTaskColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                notebook_id = excluded.notebook_id,
                team_id = excluded.team_id,
                title = excluded.title,
                notes = excluded.notes,
                status = excluded.status,
                assignee_record_name = excluded.assignee_record_name,
                assignee_display_name = excluded.assignee_display_name,
                due_at = excluded.due_at,
                source_id = excluded.source_id,
                artifact_id = excluded.artifact_id,
                sort_order = excluded.sort_order,
                created_by_record_name = excluded.created_by_record_name,
                created_by_display_name = excluded.created_by_display_name,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                completed_at = excluded.completed_at
        """) { stmt in
            bind(stmt, 1, task.id)
            bind(stmt, 2, task.notebookID)
            bind(stmt, 3, task.teamID)
            bind(stmt, 4, title)
            bind(stmt, 5, task.notes)
            bind(stmt, 6, task.status.rawValue)
            bind(stmt, 7, task.assigneeRecordName)
            bind(stmt, 8, task.assigneeDisplayName)
            bind(stmt, 9, task.dueAt.map(\.timeIntervalSinceReferenceDate))
            bind(stmt, 10, task.sourceID)
            bind(stmt, 11, task.artifactID)
            sqlite3_bind_double(stmt, 12, task.sortOrder)
            bind(stmt, 13, task.createdByRecordName)
            bind(stmt, 14, task.createdByDisplayName)
            sqlite3_bind_double(stmt, 15, task.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 16, task.updatedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 17, task.completedAt.map(\.timeIntervalSinceReferenceDate))
        }
    }

    /// Save a locally edited task. The task takes its Notebook's team so it
    /// travels in the same zone as the board it belongs to.
    func saveNotebookTask(_ input: NotebookTaskRecord) throws {
        var task = input
        guard let notebook = try loadLearningGoal(task.notebookID) else {
            throw KnowledgeStoreError.invalidData("Notebook \(task.notebookID) does not exist.")
        }
        task.teamID = notebook.teamID
        if task.status == .done, task.completedAt == nil {
            task.completedAt = task.updatedAt
        } else if task.status != .done {
            task.completedAt = nil
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try saveNotebookTaskRecord(task)
            try keepTaskRowsForGeneration2(notebookIDs: [task.notebookID], taskIDs: [task.id])
            noteStoreChanged()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func deleteNotebookTask(_ id: String, at date: Date = Date()) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM notebook_tasks WHERE id = ?") { stmt in bind(stmt, 1, id) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func deleteNotebookTasks(notebookID: String) throws {
        for task in try loadNotebookTasks(notebookID: notebookID) {
            try deleteNotebookTask(task.id)
        }
    }

    // MARK: - Share requests

    private static let shareRequestColumns = """
        id, team_id, url, title, artifact_id, requested_by_record_name, requested_by_display_name,
        status, resolved_by_record_name, resolved_by_display_name, fulfilled_source_id,
        created_at, updated_at, resolved_at
    """

    func loadShareRequests(teamID: String, status: ShareRequestStatus? = nil) throws -> [ShareRequestRecord] {
        var requests: [ShareRequestRecord] = []
        let sql = """
            SELECT \(Self.shareRequestColumns) FROM share_requests
            WHERE team_id = ? \(status == nil ? "" : "AND status = ?")
            ORDER BY created_at DESC, id
        """
        try queryBind(sql, bind: { stmt in
            bind(stmt, 1, teamID)
            if let status { bind(stmt, 2, status.rawValue) }
        }) { stmt in
            if let request = readShareRequestRow(stmt) { requests.append(request) }
        }
        return requests
    }

    /// Every open request across every team on this Mac, newest first.
    func loadOpenShareRequests() throws -> [ShareRequestRecord] {
        var requests: [ShareRequestRecord] = []
        try queryBind("""
            SELECT \(Self.shareRequestColumns) FROM share_requests
            WHERE status = ?
            ORDER BY created_at DESC, id
        """, bind: { stmt in bind(stmt, 1, ShareRequestStatus.open.rawValue) }) { stmt in
            if let request = readShareRequestRow(stmt) { requests.append(request) }
        }
        return requests
    }

    /// The open request for an address in a team, if one stands. Matched on the
    /// address as written, which is how a card asks.
    func openShareRequest(teamID: String, url: String) throws -> ShareRequestRecord? {
        var request: ShareRequestRecord?
        try queryBind("""
            SELECT \(Self.shareRequestColumns) FROM share_requests
            WHERE team_id = ? AND url = ? AND status = ?
            ORDER BY created_at DESC LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, teamID)
            bind(stmt, 2, url)
            bind(stmt, 3, ShareRequestStatus.open.rawValue)
        }) { stmt in
            request = readShareRequestRow(stmt)
        }
        return request
    }

    func loadShareRequest(_ id: String) throws -> ShareRequestRecord? {
        var request: ShareRequestRecord?
        try queryBind("SELECT \(Self.shareRequestColumns) FROM share_requests WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            request = readShareRequestRow(stmt)
        }
        return request
    }

    private func readShareRequestRow(_ stmt: OpaquePointer?) -> ShareRequestRecord? {
        guard let id = string(stmt, 0),
              let teamID = string(stmt, 1),
              let url = string(stmt, 2),
              let status = string(stmt, 7).flatMap(ShareRequestStatus.init(rawValue:)) else { return nil }
        func date(_ idx: Int32) -> Date? {
            sqlite3_column_type(stmt, idx) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, idx))
        }
        return ShareRequestRecord(
            id: id,
            teamID: teamID,
            url: url,
            title: string(stmt, 3),
            artifactID: string(stmt, 4),
            requestedByRecordName: string(stmt, 5),
            requestedByDisplayName: string(stmt, 6),
            status: status,
            resolvedByRecordName: string(stmt, 8),
            resolvedByDisplayName: string(stmt, 9),
            fulfilledSourceID: string(stmt, 10),
            createdAt: date(11) ?? Date(),
            updatedAt: date(12) ?? Date(),
            resolvedAt: date(13)
        )
    }

    /// Upsert a request row without touching the sync queue. The inbound apply
    /// path uses this; local changes go through `saveShareRequest`.
    func saveShareRequestRecord(_ request: ShareRequestRecord) throws {
        let url = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw KnowledgeStoreError.invalidData("A share request needs the source's address.")
        }
        try execBind("""
            INSERT INTO share_requests (\(Self.shareRequestColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                team_id = excluded.team_id,
                url = excluded.url,
                title = excluded.title,
                artifact_id = excluded.artifact_id,
                requested_by_record_name = excluded.requested_by_record_name,
                requested_by_display_name = excluded.requested_by_display_name,
                status = excluded.status,
                resolved_by_record_name = excluded.resolved_by_record_name,
                resolved_by_display_name = excluded.resolved_by_display_name,
                fulfilled_source_id = excluded.fulfilled_source_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                resolved_at = excluded.resolved_at
        """) { stmt in
            bind(stmt, 1, request.id)
            bind(stmt, 2, request.teamID)
            bind(stmt, 3, url)
            bind(stmt, 4, request.title)
            bind(stmt, 5, request.artifactID)
            bind(stmt, 6, request.requestedByRecordName)
            bind(stmt, 7, request.requestedByDisplayName)
            bind(stmt, 8, request.status.rawValue)
            bind(stmt, 9, request.resolvedByRecordName)
            bind(stmt, 10, request.resolvedByDisplayName)
            bind(stmt, 11, request.fulfilledSourceID)
            sqlite3_bind_double(stmt, 12, request.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 13, request.updatedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 14, request.resolvedAt.map(\.timeIntervalSinceReferenceDate))
        }
    }

    /// Save a locally made or answered request and queue it for the team zone.
    func saveShareRequest(_ request: ShareRequestRecord) throws {
        guard try loadTeam(request.teamID) != nil else {
            throw KnowledgeStoreError.invalidData("Team \(request.teamID) does not exist.")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try saveShareRequestRecord(request)
            try keepTaskRowsForGeneration2(notebookIDs: [], taskIDs: [request.id])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func deleteShareRequest(_ id: String, at date: Date = Date()) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM share_requests WHERE id = ?") { stmt in bind(stmt, 1, id) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Copies into a team

    /// The id `teamID`'s copy of the source at `url` goes by. That is
    /// `TeamContentIdentity.sourceID` for every copy made since, but a copy
    /// whose stored address was rewritten after it was made (the chapter-folder
    /// rename of 2026-09-17) keeps the id it was made under — every member's
    /// references to it name that id — so a copy already at this address wins.
    /// Sharing the source again then updates that copy rather than adding a
    /// second one beside it.
    func teamSourceCopyID(teamID: String, url: String) throws -> String {
        let keyed = TeamContentIdentity.sourceID(teamID: teamID, url: url)
        if try sourceExists(keyed) { return keyed }
        return activeSourceID(matchingAddress: url, teamID: teamID) ?? keyed
    }

    /// Every team copy that came from a given original, by kind, so a menu can
    /// tick the teams an item is already in.
    func teamIDsHoldingSource(url: String) throws -> Set<String> {
        var result = Set<String>()
        for team in try loadTeams() {
            let copyID = try teamSourceCopyID(teamID: team.id, url: url)
            if try sourceExists(copyID) { result.insert(team.id) }
        }
        return result
    }

    /// Where a team's copy of a source files inside a team's course: the
    /// course, the source's place in it and the lecture it is matched with.
    struct TeamCourseMembership: Equatable {
        let courseID: String
        let sortIndex: Int?
        let lectureGroupID: String?
    }

    /// The team course a team's source row already files under, if any.
    private func teamCourseMembership(sourceID: String, teamID: String) throws -> TeamCourseMembership? {
        var membership: TeamCourseMembership?
        try queryBind("""
            SELECT gm.group_id, gm.sort_index, gm.lecture_group_id
            FROM group_members gm
            JOIN courses c ON c.id = gm.group_id
            WHERE gm.source_id = ? AND c.team_id = ?
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, sourceID)
            self.bind(stmt, 2, teamID)
        }) { stmt in
            guard let courseID = self.string(stmt, 0) else { return }
            membership = TeamCourseMembership(
                courseID: courseID,
                sortIndex: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 1)),
                lectureGroupID: self.string(stmt, 2)
            )
        }
        return membership
    }

    /// Copy one source into a team. `fileCopy` receives the original's stored
    /// relative file path and returns the team copy's path (or nil to drop the
    /// file); the caller owns the bytes, this method owns the rows. Returns the
    /// team copy's id, which is stable per team and URL, so sharing the same
    /// paper twice updates one row.
    ///
    /// The original's own grouping (a book, a playlist, a course of the
    /// learner's) never travels. A course share passes `courseGroup` to file
    /// the copy under the team's course; without one, a copy the team already
    /// files under one of its courses stays there, so sharing a course's
    /// source again on its own does not take it out of the course.
    @discardableResult
    func copySourceIntoTeam(
        sourceID: String,
        teamID: String,
        courseGroup: TeamCourseMembership? = nil,
        fileCopy: (String) throws -> String?
    ) throws -> String {
        guard let team = try loadTeam(teamID) else {
            throw KnowledgeStoreError.invalidData("Team \(teamID) does not exist.")
        }
        guard team.canEdit else {
            throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
        }
        guard let original = try loadSourceForSync(sourceID) else {
            throw KnowledgeStoreError.invalidData("Source \(sourceID) does not exist.")
        }
        if original.teamID == teamID { return original.id }
        let copyID = try teamSourceCopyID(teamID: teamID, url: original.url)
        let membership = try courseGroup ?? teamCourseMembership(sourceID: copyID, teamID: teamID)
        try saveSource(try teamCopy(of: original, id: copyID, teamID: teamID, membership: membership, fileCopy: fileCopy))
        return copyID
    }

    /// The editable teams whose copy of `sourceID` still waits for the text the source now has. A
    /// copy is the source as it stood when it was copied (`teamCopy`), so a source filed in a team's
    /// notebook the moment it was added (an MCP `add_source` without `content`, a link dropped on the
    /// notebook) is copied before its fetch lands, and the copy has no text. Once the source is
    /// ready with text, each copy that is not ready yet is one this returns; a copy that is ready is
    /// left as its team has it. Empty when the library holds no team, so a save pays one lookup.
    func teamCopiesAwaitingText(ofSource sourceID: String) throws -> [String] {
        guard try scalarInteger("SELECT EXISTS(SELECT 1 FROM teams)") == 1,
              let original = try loadSourceWithoutContent(sourceID),
              original.teamID == nil, original.state == .ready else { return [] }
        var waiting: [String] = []
        for team in try loadTeams() where team.canEdit {
            let copyID = try teamSourceCopyID(teamID: team.id, url: original.url)
            guard copyID != sourceID, let copy = try loadSourceWithoutContent(copyID),
                  copy.teamID == team.id, copy.state != .ready else { continue }
            waiting.append(team.id)
        }
        guard !waiting.isEmpty else { return [] }
        // Only text that would make the copy ready refreshes it (`teamCopy` queues a copy without
        // text), so a ready source with no text never re-copies itself on every save.
        let text = try loadSourceForSync(sourceID)?.content ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : waiting
    }

    /// A team's or a space's copy of `original` under `copyID`, as `copySourceIntoTeam` makes it: the
    /// original's grouping never travels, a course membership files it under the team's course, the
    /// text and a paper's prepared content come along, and a copy whose text never reached disk is
    /// queued, never ready.
    func teamCopy(of original: StudioArticle, id copyID: String, teamID: String, membership: TeamCourseMembership?,
                  fileCopy: (String) throws -> String?) throws -> StudioArticle {
        var copy = StudioArticle(
            url: original.url,
            title: original.title,
            sourceType: original.sourceType,
            artworkURL: original.artworkURL,
            discoveryOrigin: original.discoveryOrigin,
            parentGroup: membership?.courseID,
            localFilePath: nil,
            publicURL: original.publicURL,
            author: original.author,
            journal: original.journal,
            publishedYear: original.publishedYear,
            id: copyID
        )
        copy.courseSortIndex = membership?.sortIndex
        copy.lectureGroupId = membership?.lectureGroupID
        copy.teamID = teamID
        copy.domain = original.domain
        copy.dateAdded = Date()
        copy.content = original.content
        copy.wordCount = original.wordCount
        copy.state = original.state
        copy.errorMessage = original.errorMessage
        copy.doi = original.doi
        copy.publishedDOI = original.publishedDOI
        copy.isPaywalled = original.isPaywalled
        copy.paywallSuspicion = original.paywallSuspicion
        copy.normalizedURL = original.normalizedURL
        copy.adoptPaperIngestionAttestation(from: original)
        copy.podcastWebPageURL = original.podcastWebPageURL
        copy.videoPublishedAt = original.videoPublishedAt
        copy.connectorLabel = original.connectorLabel
        copy.status = .active
        copy.archivedAt = nil
        if let path = original.localFilePath, !path.isEmpty {
            copy.localFilePath = try fileCopy(path)
        }
        if original.sourceType == .paper,
           let content = original.content,
           let preparation = try loadPaperContentPreparation(original.id) {
            copy.installPreparedPaperContent(
                raw: preparation.raw,
                clean: content,
                metadata: preparation.metadata,
                wordCount: original.wordCount
            )
        }
        if copy.state == .ready, copy.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            // Text that never made it to disk cannot make the copy ready.
            copy.state = .queued
        }
        return copy
    }

    /// Copy a Notebook into a team: the row, its nested Goals, optionally its
    /// sources (each copied with `fileCopy`) and its Docs (through
    /// `artifactCopy`, which the caller implements because a Doc body is a
    /// file). Membership is rebuilt against the team copies of the sources.
    /// The Notebook's chats travel as read-only transcripts filed under the
    /// team copy (`includeChats`); memory reviews and graded reviews stay
    /// behind because they are the learner's assessment, not the material.
    /// Returns the team Notebook's id.
    @discardableResult
    func copyNotebookIntoTeam(
        notebookID: String,
        teamID: String,
        includeSources: Bool,
        includeDocs: Bool,
        includeChats: Bool = true,
        fileCopy: (String) throws -> String?,
        artifactCopy: (String, String) throws -> String?
    ) throws -> String {
        guard let team = try loadTeam(teamID) else {
            throw KnowledgeStoreError.invalidData("Team \(teamID) does not exist.")
        }
        guard team.canEdit else {
            throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
        }
        guard let original = try loadLearningGoal(notebookID) else {
            throw KnowledgeStoreError.invalidData("Notebook \(notebookID) does not exist.")
        }
        if original.teamID == teamID { return original.id }
        let copyID = TeamContentIdentity.notebookID(teamID: teamID, originalNotebookID: notebookID)
        let now = Date()

        var items: [LearningGoalItem] = []
        if includeSources {
            // Only the notebook's sources travel, the rule the follow-on
            // (`propagateNotebookSourcesToTeams`) keeps: a suggestion still
            // awaiting the learner's verdict is theirs to decide on first, and
            // a source they removed is not copied into the team at all. The
            // copy used to take every item and leave its approval behind, and
            // since nil reads as approved, both reached the team as sources.
            for item in original.items where item.isApproved {
                guard try sourceExists(item.sourceID) else { continue }
                let teamSourceID = try copySourceIntoTeam(sourceID: item.sourceID, teamID: teamID, fileCopy: fileCopy)
                items.append(LearningGoalItem(
                    id: TeamContentIdentity.notebookID(teamID: teamID, originalNotebookID: item.id),
                    goalID: copyID,
                    sourceID: teamSourceID,
                    addedAt: item.addedAt,
                    origin: item.origin,
                    reviewState: item.reviewState,
                    relevance: item.relevance,
                    sequence: item.sequence
                ))
            }
        }

        let copy = LearningGoalRecord(
            id: copyID,
            title: original.title,
            startAt: original.startAt,
            endAt: original.endAt,
            createdAt: now,
            updatedAt: now,
            status: LearningGoalStatus.active.rawValue,
            items: items,
            kind: original.kind,
            description: original.description,
            summary: original.summary,
            topic: original.topic,
            discoveryEnabled: false,
            dailyTarget: original.dailyTarget,
            notes: original.notes,
            parentNotebookID: original.parentNotebookID.map {
                TeamContentIdentity.notebookID(teamID: teamID, originalNotebookID: $0)
            },
            researchQuestions: original.researchQuestions,
            relatedNotebookIDs: [],
            repository: original.repository,
            teamID: teamID
        )
        try saveLearningGoalRecord(copy)

        // Nested Goals follow their Notebook.
        for child in try loadLearningGoals() where child.parentNotebookID == notebookID && child.teamID == nil {
            _ = try copyNotebookIntoTeam(
                notebookID: child.id,
                teamID: teamID,
                includeSources: includeSources,
                includeDocs: false,
                includeChats: includeChats,
                fileCopy: fileCopy,
                artifactCopy: artifactCopy
            )
        }

        if includeDocs {
            // An audio overview stays in its author's library: its script and
            // audio live on a carrier source there, so a team copy would play
            // nothing (as `teamNotebooksAwaitingDoc` keeps it from following).
            // A source's draft deck of cards to check is the member's own
            // memory state and never enters a team record (the listing leaves
            // it out; this holds for one an older build linked to a Notebook).
            for artifact in try loadArtifacts(notebookID: notebookID) where artifact.teamID == nil {
                guard try !isAudioOverview(artifact), !artifact.isCardDeck else { continue }
                _ = try artifactCopy(artifact.id, copyID)
            }
        }

        // Chats come after sources so their source refs can land on the team's copies.
        if includeChats {
            for sessionID in try teamShareableChatIDs(notebookID: notebookID) {
                _ = try snapshotChatIntoTeam(sessionID: sessionID, teamID: teamID, notebookID: copyID)
            }
        }
        return copyID
    }

    /// The sources an artifact carries, made good in a team: each id in
    /// `sourceIDs` is mapped to the team's copy of that source, copying it in
    /// (file included, through `fileCopy`) when the team does not hold it yet.
    /// A team record never points into someone's own library, so an id that
    /// cannot be made good is left out of the mapping and reported in
    /// `failed` rather than failing the caller: the artifact still travels,
    /// short one source (docs/teams-design.md, decision 16). An id already
    /// the team's own is kept as it is.
    func carrySourcesIntoTeam(
        _ sourceIDs: [String],
        teamID: String,
        fileCopy: (String) throws -> String?
    ) -> (sourceIDs: [String], carried: CarriedTeamSources) {
        var mapped: [String] = []
        var carried = CarriedTeamSources()
        for sourceID in sourceIDs where !sourceID.isEmpty {
            do {
                guard let source = try loadSourceWithoutContent(sourceID) else {
                    carried.failed.append(.init(originalID: sourceID, reason: "No source with this id is in the library."))
                    continue
                }
                if source.teamID == teamID {
                    mapped.append(sourceID)
                    continue
                }
                let teamSourceID = try teamSourceCopyID(teamID: teamID, url: source.url)
                if try !sourceExists(teamSourceID) {
                    let copyID = try copySourceIntoTeam(sourceID: sourceID, teamID: teamID, fileCopy: fileCopy)
                    carried.linked.append(.init(originalID: sourceID, teamCopyID: copyID, title: source.title, url: source.url))
                }
                mapped.append(teamSourceID)
            } catch {
                carried.failed.append(.init(originalID: sourceID, reason: error.localizedDescription))
            }
        }
        return (Array(Set(mapped)).sorted(), carried)
    }

    /// Copy a course into a team (docs/teams-design.md, decision 21): the
    /// course, its lectures and their items, its quizzes and the page units
    /// its readings name, each under a team-scoped id, so every member can
    /// take it with their own progress. Every source the course points at is
    /// copied into the team first, file included (through `fileCopy`), so a
    /// teammate's copy never names a row only this library holds: the lecture
    /// items and the chapters their readings read, the course's own material
    /// (filed under the team's course), and whatever a quiz question or its
    /// picture is about. A source that cannot be copied is reported in
    /// `failed` and the items that needed it are left out; the course still
    /// travels. What the learner did with the course — lectures watched,
    /// quiz scores and passes, the course hidden, its focus — is theirs and
    /// stays behind, so the team's copy starts at the beginning for everyone.
    ///
    /// Sharing the course again rewrites the one copy with the original's
    /// outline and quizzes as they are now, refreshing the sources; a quiz a
    /// teammate wrote on the team's copy is kept beside them.
    @discardableResult
    func copyCourseIntoTeam(
        courseID: String,
        teamID: String,
        fileCopy: (String) throws -> String?
    ) throws -> CourseTeamCopy {
        guard let team = try loadTeam(teamID) else {
            throw KnowledgeStoreError.invalidData("Team \(teamID) does not exist.")
        }
        guard team.canEdit else {
            throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
        }
        guard let original = try loadCourseForSync(courseID) else {
            throw KnowledgeStoreError.invalidData("Course \(courseID) does not exist.")
        }
        if try singleString("SELECT team_id FROM courses WHERE id = ?", key: courseID) == teamID {
            return CourseTeamCopy(id: courseID, carriedSources: CarriedTeamSources(), itemsLeftOut: 0)
        }
        let copyID = TeamContentIdentity.courseID(teamID: teamID, originalCourseID: courseID)
        func partID(_ part: String, _ id: String) -> String {
            TeamContentIdentity.coursePartID(teamID: teamID, part: part, originalID: id)
        }

        // The course's own material files under the team's course, where it
        // stood in the original.
        var memberships: [String: TeamCourseMembership] = [:]
        try queryBind(
            "SELECT source_id, sort_index, lecture_group_id FROM group_members WHERE group_id = ?",
            bind: { stmt in self.bind(stmt, 1, courseID) }
        ) { stmt in
            guard let sourceID = self.string(stmt, 0) else { return }
            memberships[sourceID] = TeamCourseMembership(
                courseID: copyID,
                sortIndex: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 1)),
                lectureGroupID: self.string(stmt, 2)
            )
        }

        // Every source the course names, in path order, each once.
        let units = original.sourceUnits ?? []
        var sourceIDs: [String] = []
        var noted = Set<String>()
        func note(_ id: String?) {
            guard let id, !id.isEmpty, noted.insert(id).inserted else { return }
            sourceIDs.append(id)
        }
        original.lectureItems.forEach { note($0.sourceId) }
        units.forEach { note($0.sourceId) }
        try sourceIDsForCourse(courseID).forEach { note($0) }
        for quiz in original.quizzes ?? [] {
            for question in quiz.questions {
                note(question.sourceID)
                note(question.picture?.reference?.sourceID)
            }
        }

        var sourceMap: [String: String] = [:]
        // An archived source is out of the course's path here, so it stays
        // out of the team's rather than coming back to life there.
        var archivedSourceIDs = Set<String>()
        var carried = CarriedTeamSources()
        for sourceID in sourceIDs {
            do {
                guard let source = try loadSourceWithoutContent(sourceID) else {
                    carried.failed.append(.init(originalID: sourceID, reason: "No source with this id is in the library."))
                    continue
                }
                guard source.status != .archived else {
                    archivedSourceIDs.insert(sourceID)
                    continue
                }
                let teamSourceID = try teamSourceCopyID(teamID: teamID, url: source.url)
                let teamHeldIt = try source.teamID == teamID || sourceExists(teamSourceID)
                // A lecture video matched with notes names the video's row;
                // the team's copy names the team's row of it.
                let membership = try memberships[sourceID].map { membership in
                    TeamCourseMembership(
                        courseID: membership.courseID,
                        sortIndex: membership.sortIndex,
                        lectureGroupID: try membership.lectureGroupID
                            .flatMap { try loadSourceWithoutContent($0) }
                            .map { try teamSourceCopyID(teamID: teamID, url: $0.url) }
                    )
                }
                let teamCopyID = try copySourceIntoTeam(
                    sourceID: sourceID,
                    teamID: teamID,
                    courseGroup: membership,
                    fileCopy: fileCopy
                )
                sourceMap[sourceID] = teamCopyID
                if !teamHeldIt {
                    carried.linked.append(.init(originalID: sourceID, teamCopyID: teamCopyID, title: source.title, url: source.url))
                }
            } catch {
                carried.failed.append(.init(originalID: sourceID, reason: error.localizedDescription))
            }
        }

        // Page units, on the team's rows.
        var unitMap: [String: String] = [:]
        let unitsByID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for unit in units {
            guard let teamSourceID = sourceMap[unit.sourceId] else { continue }
            unitMap[unit.id] = try copySourceUnitIntoTeam(unit, teamSourceID: teamSourceID, teamID: teamID)
        }

        var lectureMap: [String: String] = [:]
        var lectures: [CourseSession] = []
        for lecture in original.lectures {
            let lectureID = partID("lecture", lecture.id)
            lectureMap[lecture.id] = lectureID
            lectures.append(CourseSession(
                id: lectureID,
                courseName: copyID,
                number: lecture.number,
                title: lecture.title,
                createdAt: lecture.createdAt
            ))
        }

        var items: [CourseLectureItem] = []
        var itemKeys = Set<String>()
        var itemsLeftOut = 0
        for item in original.lectureItems {
            guard let lectureID = lectureMap[item.lectureId] else { continue }
            let unitSourceID = item.sourceUnitId.flatMap { unitsByID[$0]?.sourceId }
            if [item.sourceId, unitSourceID].contains(where: { id in id.map { archivedSourceIDs.contains($0) } ?? false }) {
                continue
            }
            let sourceID = item.sourceId.flatMap { sourceMap[$0] }
            let unitID = item.sourceUnitId.flatMap { unitMap[$0] }
            if (item.sourceId != nil && sourceID == nil) || (item.sourceUnitId != nil && unitID == nil) {
                itemsLeftOut += 1
                continue
            }
            // Two originals the team holds as one row are one item.
            guard itemKeys.insert("\(lectureID)|\(sourceID ?? "")|\(unitID ?? "")").inserted else { continue }
            let itemID: String
            let pages = item.sourceUnitId.flatMap { unitsByID[$0] }.flatMap { TextbookReading.pages(fromLocator: $0.locator) }
            if item.role == .reading, let originalSourceID = item.sourceId, let sourceID,
               item.id == TextbookReading.itemID(lectureID: item.lectureId, sourceID: originalSourceID, pages: pages) {
                itemID = TextbookReading.itemID(lectureID: lectureID, sourceID: sourceID, pages: pages)
            } else {
                itemID = partID("item", item.id)
            }
            items.append(CourseLectureItem(
                id: itemID,
                lectureId: lectureID,
                sourceId: sourceID,
                sourceUnitId: unitID,
                role: item.role,
                label: item.label,
                sortIndex: item.sortIndex,
                createdAt: item.createdAt
            ))
        }

        // Quizzes. One the ladder names by what it is gets the name its rule
        // gives the team's course and lectures — the course page finds a
        // lecture's practice quiz by that name — and its questions the ids
        // their rule gives the team's sources.
        func teamQuizID(_ quiz: CourseQuiz) -> String {
            let lectureIDs = quiz.lectureIDs.compactMap { lectureMap[$0] }
            switch quiz.kind {
            case .practice:
                if let first = quiz.lectureIDs.first, let teamLecture = lectureMap[first],
                   quiz.id == CourseQuizPlanning.practiceID(courseID: courseID, lectureID: first) {
                    return CourseQuizPlanning.practiceID(courseID: copyID, lectureID: teamLecture)
                }
            case .checkpoint:
                if lectureIDs.count == quiz.lectureIDs.count,
                   quiz.id == CourseQuizPlanning.checkpointID(courseID: courseID, lectureIDs: quiz.lectureIDs) {
                    return CourseQuizPlanning.checkpointID(courseID: copyID, lectureIDs: lectureIDs)
                }
            case .test:
                if quiz.id == CourseQuizPlanning.testID(courseID: courseID) {
                    return CourseQuizPlanning.testID(courseID: copyID)
                }
            }
            return partID("quiz", quiz.id)
        }
        let now = Date()
        var quizzes: [CourseQuiz] = []
        if let originalQuizzes = original.quizzes {
            for quiz in originalQuizzes {
                let questions = quiz.questions.map { question -> CourseQuizQuestion in
                    let sourceID = question.sourceID.flatMap { sourceMap[$0] }
                    let questionID = question.id == CourseQuizPlanning.questionID(sourceID: question.sourceID, question: question.question)
                        ? CourseQuizPlanning.questionID(sourceID: sourceID, question: question.question)
                        : question.id
                    var picture: CourseQuizPicture?
                    if let given = question.picture, let reference = given.reference {
                        if let teamSourceID = sourceMap[reference.sourceID] {
                            picture = CourseQuizPicture(
                                reference: SourceImageReference(sourceID: teamSourceID, location: reference.location, crop: reference.crop),
                                caption: given.caption,
                                placement: given.placement
                            )
                        }
                    } else if let given = question.picture, given.storedImageID != nil || given.isAwaitingDrawing {
                        // A picture in the image store is named by its own id,
                        // not a source's, and travels to the team with the
                        // course record (`courseQuizPicturesAsset`); a brief
                        // is words. Both are the same in the team's copy.
                        picture = given
                    }
                    return CourseQuizQuestion(
                        id: questionID,
                        sourceID: sourceID,
                        firstLine: question.firstLine,
                        lastLine: question.lastLine,
                        startSeconds: question.startSeconds,
                        question: question.question,
                        answer: question.answer,
                        keyPoints: question.keyPoints,
                        quote: question.quote,
                        levelName: question.levelName,
                        picture: picture,
                        page: question.page
                    )
                }
                quizzes.append(CourseQuiz(
                    id: teamQuizID(quiz),
                    courseID: copyID,
                    kind: quiz.kind,
                    title: quiz.title,
                    lectureIDs: quiz.lectureIDs.compactMap { lectureMap[$0] },
                    afterLectureID: quiz.afterLectureID.flatMap { lectureMap[$0] },
                    questions: questions,
                    author: quiz.author,
                    createdAt: quiz.createdAt,
                    updatedAt: now,
                    symbol: quiz.symbol,
                    artwork: quiz.artwork
                ))
            }
        }
        // A quiz a teammate wrote on the team's copy stays.
        let copiedQuizIDs = Set(quizzes.map(\.id))
        quizzes += try loadCourseQuizzes(courseID: copyID).filter { !copiedQuizIDs.contains($0.id) }

        // The row carries the team from its first write, so the record is
        // homed in the team's zone from its first save. Then the metadata,
        // the outline and the quizzes. The copy is not hidden and awaits no playlist import on
        // the team's side: both are about the original.
        try execBind("""
            INSERT INTO courses (id, title, team_id) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET team_id = excluded.team_id
        """) { stmt in
            bind(stmt, 1, copyID)
            bind(stmt, 2, original.title ?? original.name)
            bind(stmt, 3, teamID)
        }
        try saveCourseGroup(name: copyID, metadata: CourseMetadata(
            courseCode: original.courseCode,
            title: original.title ?? original.name,
            institution: original.institution,
            instructors: original.instructors,
            playlistURL: original.playlistURL
        ))
        try saveCourseOutline(courseName: copyID, lectures: lectures, items: items)
        try replaceCourseQuizzesFromSync(courseID: copyID, quizzes: quizzes)
        return CourseTeamCopy(id: copyID, carriedSources: carried, itemsLeftOut: itemsLeftOut)
    }

    /// A page unit — the pages of a chapter a reading names — on a team's copy
    /// of its source. One the team's row already has for those pages is
    /// reused, since (source, kind, locator) is unique; otherwise a unit
    /// named by its pages is named by the same rule over the team's row, and
    /// any other takes a team-scoped id. Returns the team unit's id.
    func copySourceUnitIntoTeam(_ unit: SourceUnit, teamSourceID: String, teamID: String) throws -> String {
        var existingID: String?
        try queryBind(
            "SELECT id FROM source_units WHERE source_id = ? AND kind = ? AND locator = ? LIMIT 1",
            bind: { stmt in
                self.bind(stmt, 1, teamSourceID)
                self.bind(stmt, 2, unit.kind)
                self.bind(stmt, 3, unit.locator)
            }
        ) { stmt in existingID = self.string(stmt, 0) }
        if let existingID { return existingID }
        let unitID: String
        if unit.kind == TextbookReading.unitKind,
           let pages = TextbookReading.pages(fromLocator: unit.locator),
           unit.id == TextbookReading.unitID(sourceID: unit.sourceId, pages: pages) {
            unitID = TextbookReading.unitID(sourceID: teamSourceID, pages: pages)
        } else {
            unitID = TeamContentIdentity.coursePartID(teamID: teamID, part: "unit", originalID: unit.id)
        }
        try saveSourceUnit(SourceUnit(
            id: unitID,
            sourceId: teamSourceID,
            kind: unit.kind,
            locator: unit.locator,
            title: unit.title
        ))
        return unitID
    }

    /// A lecture item as a course files it (docs/teams-design.md, decision
    /// 21). A course of My Library files any row as it is. A team's course
    /// names only the team's rows, so a row from elsewhere — a member's own
    /// source dropped on the team's course, a playlist refreshed into it — is
    /// filed as the team's copy of it, with its page unit moved onto that
    /// copy; a row the team holds no copy of is refused.
    /// `StorageService.courseLibrarySourceIDs` copies such a row into the team
    /// first, file included, so only a caller writing straight to the store
    /// meets the refusal. A row this store does not have yet (a team's source
    /// still in a later CloudKit page) is left to the foreign key.
    func lectureItemFiledInCourse(_ item: CourseLectureItem, courseID: String) throws -> CourseLectureItem {
        guard let teamID = try courseTeamID(courseID) else { return item }
        var filed = item
        if let sourceID = item.sourceId {
            filed.sourceId = try sourceIDFiledInTeam(sourceID, teamID: teamID)
        }
        if let unitID = item.sourceUnitId, let unit = try loadSourceUnits(ids: [unitID]).first {
            let teamSourceID = try sourceIDFiledInTeam(unit.sourceId, teamID: teamID)
            if teamSourceID != unit.sourceId {
                filed.sourceUnitId = try copySourceUnitIntoTeam(unit, teamSourceID: teamSourceID, teamID: teamID)
            }
        }
        return filed
    }

    private func sourceIDFiledInTeam(_ sourceID: String, teamID: String) throws -> String {
        guard let source = try loadSourceWithoutContent(sourceID), source.teamID != teamID else { return sourceID }
        let copyID = try teamSourceCopyID(teamID: teamID, url: source.url)
        guard try sourceExists(copyID) else {
            throw KnowledgeStoreError.invalidData(
                "“\(source.title)” is not in the team that holds this course; share it with the team first."
            )
        }
        return copyID
    }

    /// The teams that hold a copy of a course of My Library.
    func teamsHoldingCourse(_ courseID: String) throws -> [TeamRecord] {
        try loadTeams().filter { team in
            try singleString(
                "SELECT team_id FROM courses WHERE id = ?",
                key: TeamContentIdentity.courseID(teamID: team.id, originalCourseID: courseID)
            ) == team.id
        }
    }

    /// The row half of copying a Doc into a team; the caller has already put
    /// the body at the copy's path. The sources the record is about travel
    /// with it (`carrySourcesIntoTeam`, files through `fileCopy`), and the
    /// copy's `sourceIDs` name the team's copies, so an animation's "sources
    /// it explains" and a site's source cards resolve in the team library.
    /// Returns the team Doc's id and what travelled.
    @discardableResult
    func copyArtifactRowIntoTeam(
        artifactID: String,
        teamID: String,
        linkedTeamNotebookIDs: [String],
        fileCopy: (String) throws -> String?
    ) throws -> ArtifactTeamCopy {
        guard let team = try loadTeam(teamID) else {
            throw KnowledgeStoreError.invalidData("Team \(teamID) does not exist.")
        }
        guard team.canEdit else {
            throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
        }
        guard let original = try loadArtifact(artifactID) else {
            throw KnowledgeStoreError.invalidData("Page \(artifactID) does not exist.")
        }
        if original.teamID == teamID { return ArtifactTeamCopy(id: original.id, carriedSources: CarriedTeamSources()) }
        let copyID = try teamArtifactCopyID(teamID: teamID, original: original)
        let now = Date()
        let existing = try loadArtifact(copyID)
        let sources = carrySourcesIntoTeam(original.sourceIDs, teamID: teamID, fileCopy: fileCopy)
        let copy = ArtifactRecord(
            id: copyID,
            title: original.title,
            homeNotebookID: linkedTeamNotebookIDs.first ?? existing?.homeNotebookID,
            linkedNotebookIDs: Array(Set(linkedTeamNotebookIDs + (existing?.linkedNotebookIDs ?? []))).sorted(),
            isDraft: original.isDraft,
            // A copy is what the original is. A Markdown Doc's copy is a Doc
            // holding its text. A page's copy is the same page — address and
            // kind kept, so it lists under the team's Sites or Animations and
            // opens the page — with the entry page's text copy riding along
            // for chat and search. Until 2026-09-19 a page copied as a Doc
            // with no address: teammates got "The atlas opens on
            // Interventions." three times over, and never the atlas.
            // A site kept in the library is served from its own record's
            // folder, so the copy's address names the copy.
            linkedURL: LinkedPage.localSiteID(fromURLString: original.linkedURL) == nil
                ? original.linkedURL
                : LinkedPage.localSiteURL(artifactID: copyID).absoluteString,
            teamID: teamID,
            archivedAt: original.archivedAt,
            kind: original.kind,
            sourceIDs: sources.sourceIDs,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try saveArtifactRecord(copy)
        return ArtifactTeamCopy(id: copyID, carriedSources: sources.carried)
    }

    /// Share a chat with a team as a read-only transcript. The copy keeps the
    /// questions, answers and the tutor's replies; the learner's scores,
    /// ratings, grading and the reader passages they were looking at are
    /// stripped, because those are about the person, not the conversation.
    /// Sources are mapped to the team's copies where they exist and dropped
    /// otherwise, so a team record never points into someone's own library.
    @discardableResult
    func snapshotChatIntoTeam(sessionID: String, teamID: String, notebookID: String?) throws -> String {
        guard let team = try loadTeam(teamID) else {
            throw KnowledgeStoreError.invalidData("Team \(teamID) does not exist.")
        }
        guard team.canEdit else {
            throw KnowledgeStoreError.invalidData("\(team.name) is read-only for you.")
        }
        guard let original = try loadReviewSessionForSync(sessionID) else {
            throw KnowledgeStoreError.invalidData("Chat \(sessionID) does not exist.")
        }
        if original.teamID == teamID { return original.id }
        let copyID = TeamContentIdentity.chatSnapshotID(teamID: teamID, originalSessionID: sessionID)

        func teamSourceID(_ sourceID: String) throws -> String? {
            guard let source = try loadSourceWithoutContent(sourceID) else { return nil }
            if source.teamID == teamID { return source.id }
            let copy = try teamSourceCopyID(teamID: teamID, url: source.url)
            return try sourceExists(copy) ? copy : nil
        }
        let sourceIDs = try original.sourceIDs.compactMap(teamSourceID)
        let exchanges = try original.exchanges.map { exchange in
            CloudKitReviewExchangePayload(
                id: TeamContentIdentity.chatSnapshotID(teamID: teamID, originalSessionID: exchange.id),
                sessionID: copyID,
                sequenceNumber: exchange.sequenceNumber,
                question: exchange.question,
                userAnswer: exchange.userAnswer,
                evaluation: exchange.evaluation,
                score: nil,
                sourceRefs: try exchange.sourceRefs.compactMap(teamSourceID),
                knowledgeNote: exchange.knowledgeNote,
                answeredAt: exchange.answeredAt,
                contextContent: nil
            )
        }
        // A live chat has no end; the transcript is dated by its last turn so a
        // refresh after every message does not move the date for nothing.
        let lastTurnAt = original.exchanges.compactMap(\.answeredAt).max()
        let snapshot = CloudKitReviewSessionPayload(
            id: copyID,
            topic: original.topic,
            startedAt: original.startedAt,
            endedAt: original.endedAt ?? lastTurnAt ?? Date(),
            status: "completed",
            overallScore: nil,
            summary: original.summary,
            sourceIDs: sourceIDs,
            cardIDs: [],
            exchangeCount: exchanges.count,
            modelProvider: original.modelProvider,
            modelID: original.modelID,
            goalID: notebookID,
            exchanges: exchanges,
            sourceIdentities: try sourceIdentities(for: sourceIDs),
            docLinks: [],
            kind: ReviewSessionKind.chat.rawValue,
            briefing: nil,
            teamID: teamID
        )
        try saveReviewSessionRecord(snapshot)
        try stampTeam(entity: .reviewSession, logicalKey: copyID, teamID: teamID)
        noteStoreChanged()
        return copyID
    }

    // MARK: - Additions follow a shared Notebook

    /// The editable teams that hold a copy of a Notebook in My Library. A copy's
    /// id is a function of the team and the original, so holding is one row
    /// lookup per team, and a copy the team deleted ends the follow-on with no
    /// bookkeeping of its own. A read-only team cannot take additions.
    func teamsHoldingNotebook(_ notebookID: String) throws -> [TeamRecord] {
        try teamsHoldingNotebookCopy(notebookID, among: loadTeams().filter(\.canEdit))
    }

    /// Every team holding a copy of a Notebook in My Library, read-only ones
    /// included: who has a notebook, for its Share… (docs/teams-design.md,
    /// decision 22).
    func teamsHoldingNotebookCopy(_ notebookID: String) throws -> [TeamRecord] {
        try teamsHoldingNotebookCopy(notebookID, among: loadTeams())
    }

    private func teamsHoldingNotebookCopy(_ notebookID: String, among teams: [TeamRecord]) throws -> [TeamRecord] {
        guard !teams.isEmpty else { return [] }
        return try teams.filter { team in
            try loadLearningGoal(TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: notebookID)) != nil
        }
    }

    /// The id a team's copy of an artifact has, or would take. The keyed id
    /// first (`TeamContentIdentity.artifactCopyID`: by address for a page, by
    /// record for a Markdown Doc). A team may instead hold a page under an id
    /// of its own: until build 114 a site or animation published straight
    /// into a team Notebook was made as a team record under a random id, with
    /// no entry in the publisher's library. That row is the page's copy, so a
    /// share updates it rather than filing a second entry at the same
    /// address. Every reader of a team copy — the share, "who holds this",
    /// the Doc a shared Notebook still owes, the open-in-team route — asks
    /// here, never `artifactCopyID` directly.
    func teamArtifactCopyID(teamID: String, original: ArtifactRecord) throws -> String {
        let keyed = TeamContentIdentity.artifactCopyID(teamID: teamID, original: original)
        guard let rawURL = original.linkedURL else { return keyed }
        let all = try loadArtifacts()
        if all.contains(where: { $0.id == keyed }) { return keyed }
        let address = URLNormalizer.normalize(rawURL)
        let held = all.first { row in
            row.teamID == teamID && row.id != original.id
                && row.linkedURL.map(URLNormalizer.normalize) == address
        }
        return held?.id ?? keyed
    }

    /// The artifacts My Library lists (docs/teams-design.md, decision 18):
    /// every personal record, and every team record this account can see —
    /// a Doc a teammate wrote, a page published into a team Notebook, a copy a
    /// teammate shared — except a team's copy of a personal original, which is
    /// the original seen once more: the keyed copy id
    /// (`TeamContentIdentity.artifactCopyID`) for every team, and a team row at
    /// a personal page's address (the adopted copy of decision 17). The product owner
    /// (2026-09-19): "artifacts that are shared with my team or part of a team
    /// that i'm a part of should STILL be shown under my personal library!"
    /// A team library still shows only its own rows (`loadScopedArtifacts`).
    func loadMyLibraryArtifacts() throws -> [ArtifactRecord] {
        let all = try loadArtifacts()
        let personal = all.filter { $0.teamID == nil }
        let teamRows = all.filter { $0.teamID != nil }
        guard !teamRows.isEmpty else { return personal }
        let teams = try loadTeams()
        var copyIDs = Set<String>()
        var personalAddresses = Set<String>()
        for original in personal {
            for team in teams {
                copyIDs.insert(TeamContentIdentity.artifactCopyID(teamID: team.id, original: original))
            }
            if let raw = original.linkedURL { personalAddresses.insert(URLNormalizer.normalize(raw)) }
        }
        let shown = teamRows.filter { row in
            if copyIDs.contains(row.id) { return false }
            if let raw = row.linkedURL, personalAddresses.contains(URLNormalizer.normalize(raw)) { return false }
            return true
        }
        return (personal + shown).sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// The teams each My Library artifact is in, in one pass, for the
    /// Docs tab's team filter: a team's own record is in its team; a
    /// personal original is in every team holding its copy — the keyed copy
    /// id, or a team row at the page's address (decision 17), the same two
    /// routes `loadMyLibraryArtifacts` folds away. An artifact in no team has
    /// no entry.
    func teamIDsByMyLibraryArtifact() throws -> [String: Set<String>] {
        let all = try loadArtifacts()
        let teamRows = all.filter { $0.teamID != nil }
        guard !teamRows.isEmpty else { return [:] }
        let teamIDs = try loadTeams().map(\.id)
        let rowTeam = Dictionary(teamRows.map { ($0.id, $0.teamID!) }, uniquingKeysWith: { first, _ in first })
        var addressTeams: [String: Set<String>] = [:]
        for row in teamRows {
            if let raw = row.linkedURL { addressTeams[URLNormalizer.normalize(raw), default: []].insert(row.teamID!) }
        }
        var result: [String: Set<String>] = [:]
        for row in teamRows { result[row.id, default: []].insert(row.teamID!) }
        for original in all where original.teamID == nil {
            var held = Set<String>()
            for teamID in teamIDs where rowTeam[TeamContentIdentity.artifactCopyID(teamID: teamID, original: original)] == teamID {
                held.insert(teamID)
            }
            if let raw = original.linkedURL { held.formUnion(addressTeams[URLNormalizer.normalize(raw)] ?? []) }
            if !held.isEmpty { result[original.id] = held }
        }
        return result
    }

    /// Every team holding a copy of a Doc in My Library, read-only teams
    /// included: this names where a Doc has gone, not where additions may go.
    func teamsHoldingArtifact(_ artifactID: String) throws -> [TeamRecord] {
        let teams = try loadTeams()
        guard !teams.isEmpty, let original = try loadArtifact(artifactID) else { return [] }
        return try teams.filter { team in
            try loadArtifact(teamArtifactCopyID(teamID: team.id, original: original)) != nil
        }
    }

    /// Sources just added to a Notebook follow it into every team holding the
    /// Notebook: each is copied unless the team already has it, and joins the
    /// team copy's membership. Only approved items travel; a suggestion still
    /// awaiting the learner's verdict is theirs to decide on first. A nested
    /// Goal passes the addition up to its Notebook, as `addCompanionSeedSources`
    /// does for the originals. Returns the ids of the teams whose copy changed.
    @discardableResult
    func propagateNotebookSourcesToTeams(
        notebookID: String,
        sourceIDs: [String],
        fileCopy: (_ relativePath: String, _ teamID: String) throws -> String?
    ) throws -> Set<String> {
        let wanted = Set(sourceIDs)
        guard !wanted.isEmpty,
              let original = try loadLearningGoal(notebookID),
              original.teamID == nil else { return [] }
        var changed = Set<String>()
        for team in try teamsHoldingNotebook(notebookID) {
            let copyID = TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: notebookID)
            guard let copy = try loadLearningGoal(copyID) else { continue }
            let held = Set(copy.items.map(\.sourceID))
            var added = false
            for item in original.items where wanted.contains(item.sourceID) {
                guard item.reviewState == nil
                        || item.reviewState == LearningGoalItemReviewState.approved.rawValue,
                      let source = try loadSourceWithoutContent(item.sourceID) else { continue }
                let teamSourceID = try teamSourceCopyID(teamID: team.id, url: source.url)
                if try !sourceExists(teamSourceID) {
                    _ = try copySourceIntoTeam(sourceID: item.sourceID, teamID: team.id) { path in
                        try fileCopy(path, team.id)
                    }
                }
                guard !held.contains(teamSourceID) else { continue }
                try saveLearningGoalItem(LearningGoalItem(
                    id: TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: item.id),
                    goalID: copyID,
                    sourceID: teamSourceID,
                    addedAt: item.addedAt,
                    origin: item.origin,
                    relevance: item.relevance,
                    sequence: item.sequence
                ), goalID: copyID, ignoreDuplicates: true)
                added = true
            }
            if added {
                try touchLearningGoal(copyID)
                changed.insert(team.id)
            }
        }
        if let parentNotebookID = original.parentNotebookID {
            changed.formUnion(try propagateNotebookSourcesToTeams(
                notebookID: parentNotebookID,
                sourceIDs: sourceIDs,
                fileCopy: fileCopy
            ))
        }
        return changed
    }

    /// A Goal newly nested under a shared Notebook follows it into each team
    /// holding the Notebook, sources and chats included, the way the Notebook's
    /// Goals did when it was shared. Returns the ids of the teams that gained it.
    @discardableResult
    func propagateNestedGoalToTeams(
        goalID: String,
        fileCopy: (_ relativePath: String, _ teamID: String) throws -> String?
    ) throws -> Set<String> {
        guard let goal = try loadLearningGoal(goalID),
              goal.teamID == nil,
              let parentNotebookID = goal.parentNotebookID else { return [] }
        var changed = Set<String>()
        for team in try teamsHoldingNotebook(parentNotebookID) {
            let copyID = TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: goalID)
            guard try loadLearningGoal(copyID) == nil else { continue }
            _ = try copyNotebookIntoTeam(
                notebookID: goalID,
                teamID: team.id,
                includeSources: true,
                includeDocs: false,
                includeChats: true,
                fileCopy: { path in try fileCopy(path, team.id) },
                artifactCopy: { _, _ in nil }
            )
            changed.insert(team.id)
        }
        return changed
    }

    /// Where a Doc filed under shared Notebooks still has to go: each editable
    /// team holding one of its Notebooks whose copy of the Doc is missing or not
    /// yet filed under that team Notebook, with the team Notebook ids to file it
    /// beneath. The caller copies the body and the row (`shareArtifact`).
    func teamNotebooksAwaitingDoc(artifactID: String) throws -> [(team: TeamRecord, teamNotebookIDs: [String])] {
        guard let artifact = try loadArtifact(artifactID), artifact.teamID == nil else { return [] }
        // A Google Doc follows its Notebook: its text copy is the document. A
        // ForeverLM site, a Claude artifact, a Codex site or an animation is a
        // page under its publisher's access policy, which filing under a
        // Notebook does not extend; a Site reaches the team by being published
        // into the team's Notebook, or by Share with Team, which copies the
        // page itself and opens a ForeverLM site to the roster. None of those
        // follow on their own.
        if artifact.isAnimation { return [] }
        // An audio overview's script and audio live on a carrier source in
        // its author's library; a copy in the team would play nothing.
        if try isAudioOverview(artifact) { return [] }
        // A source's draft deck of cards to check is the member's own memory
        // state (docs/teams-design.md rule 7), whatever a Notebook links it to.
        if artifact.isCardDeck { return [] }
        if let rawURL = artifact.linkedURL, LinkedPage.kind(ofURLString: rawURL) != .googleDoc { return [] }
        var pending: [String: (team: TeamRecord, teamNotebookIDs: [String])] = [:]
        for notebookID in artifact.linkedNotebookIDs {
            guard try loadLearningGoal(notebookID)?.teamID == nil else { continue }
            for team in try teamsHoldingNotebook(notebookID) {
                let teamNotebookID = TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: notebookID)
                let copyID = try teamArtifactCopyID(teamID: team.id, original: artifact)
                if let copy = try loadArtifact(copyID), copy.linkedNotebookIDs.contains(teamNotebookID) { continue }
                var entry = pending[team.id] ?? (team: team, teamNotebookIDs: [])
                if !entry.teamNotebookIDs.contains(teamNotebookID) {
                    entry.teamNotebookIDs.append(teamNotebookID)
                }
                pending[team.id] = entry
            }
        }
        return pending.keys.sorted().compactMap { pending[$0] }
    }

    /// The learner's own chats filed under a Notebook that a team share carries:
    /// conversations with something said in them. A memory review, a graded
    /// review and a chat nobody wrote in are not shared; the first two are the
    /// learner's assessment (decision 7 in docs/teams-design.md).
    func teamShareableChatIDs(notebookID: String) throws -> [String] {
        try teamShareableChats(where: "goal_id = ?", bind: notebookID).map(\.id)
    }

    /// The Notebook a chat would follow into teams, or nil when the chat is not
    /// one a team share carries.
    func teamShareableChatNotebookID(sessionID: String) throws -> String? {
        try teamShareableChats(where: "id = ?", bind: sessionID).first?.notebookID
    }

    private func teamShareableChats(where clause: String, bind value: String) throws -> [(id: String, notebookID: String)] {
        var rows: [(id: String, notebookID: String)] = []
        try queryBind("""
            SELECT id, goal_id, kind, overall_score, card_ids
            FROM review_sessions
            WHERE \(clause)
              AND goal_id IS NOT NULL AND goal_id <> ''
              AND team_id IS NULL
              AND exchange_count > 0
              AND status IN ('active', 'completed')
            ORDER BY started_at ASC
        """, bind: { stmt in
            bind(stmt, 1, value)
        }) { stmt in
            guard let id = self.string(stmt, 0), let notebookID = self.string(stmt, 1) else { return }
            let kind = self.string(stmt, 2)
            guard kind == nil || kind == ReviewSessionKind.chat.rawValue else { return }
            guard sqlite3_column_type(stmt, 3) == SQLITE_NULL else { return }
            guard (self.decodeStringArray(json: self.string(stmt, 4)) ?? []).isEmpty else { return }
            guard !MemoryReviewSession.isMemorySession(id) else { return }
            rows.append((id: id, notebookID: notebookID))
        }
        return rows
    }

    /// A chat under a shared Notebook keeps its team transcripts current: the
    /// snapshot is rewritten for every team holding the Notebook. Run after
    /// anything that changes the conversation or where it is filed. Returns the
    /// ids of the teams whose transcript was rewritten.
    @discardableResult
    func propagateChatToTeams(sessionID: String) throws -> Set<String> {
        guard let notebookID = try teamShareableChatNotebookID(sessionID: sessionID) else { return [] }
        var changed = Set<String>()
        for team in try teamsHoldingNotebook(notebookID) {
            let teamNotebookID = TeamContentIdentity.notebookID(teamID: team.id, originalNotebookID: notebookID)
            _ = try snapshotChatIntoTeam(sessionID: sessionID, teamID: team.id, notebookID: teamNotebookID)
            changed.insert(team.id)
        }
        return changed
    }
}
