import Foundation

// MCP twins of the Mac's assignment and family plan controls
// (docs/family-design.md): Assign to ▸ on a source or Doc, the Today panel's
// Assigned section, and the Family plan section of a team's Members settings.
extension MCPDataStore {

    // MARK: - Assignments

    func assignToMember(
        teamID rawTeamID: String?,
        member rawMember: String?,
        sourceIDs: [String]?,
        docID rawDocID: String?,
        dueDate: String?,
        notes: String?
    ) async throws -> String {
        let team = try await requireTeamRecord(rawTeamID)
        guard team.canEdit else {
            throw MCPError.invalidInput("Team ‘\(team.name)’ is read-only for this account, so nothing can be assigned in it.")
        }
        let members = try await notebookFileStorage.loadTeamMembers(teamID: team.id)
        let member = try resolveFamilyMember(rawMember, members: members, teamName: team.name)
        let sources = (sourceIDs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let docID = rawDocID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sources.isEmpty || docID?.isEmpty == false else {
            throw MCPError.invalidInput("Pass source_ids, doc_id, or both: the things to assign.")
        }
        let store = try knowledgeStore()
        for sourceID in sources {
            guard try store.sourceExists(sourceID) else {
                throw MCPError.notFound("No source with id \(sourceID). Use list_sources or search_sources_semantic.")
            }
        }
        if let docID, !docID.isEmpty, try store.loadArtifact(docID) == nil {
            throw MCPError.notFound("No Doc with id \(docID). Use list_docs.")
        }
        let dueAt = try dueDate.flatMap { raw -> Date? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : try parseScheduleDate(trimmed, calendar: .current, field: "due_date")
        }

        var tasks: [NotebookTaskRecord] = []
        do {
            for sourceID in sources {
                tasks.append(try await notebookFileStorage.assign(
                    sourceID: sourceID, to: member.userRecordName, inTeam: team.id, dueAt: dueAt, notes: notes ?? ""
                ))
            }
            if let docID, !docID.isEmpty {
                tasks.append(try await notebookFileStorage.assign(
                    artifactID: docID, to: member.userRecordName, inTeam: team.id, dueAt: dueAt, notes: notes ?? ""
                ))
            }
        } catch let error as StorageService.AssignmentError {
            throw MCPError.invalidInput(error.localizedDescription)
        } catch let error as KnowledgeStoreError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "team_id": team.id,
            "notebook_id": TeamContentIdentity.assignmentsNotebookID(teamID: team.id),
            "assignee": ["user_record_name": member.userRecordName, "display_name": member.displayName],
            "tasks": tasks.map(notebookTaskPayload),
            "message": "Assigned \(tasks.count == 1 ? "1 item" : "\(tasks.count) items") to \(member.displayName) in ‘\(team.name)’. Each is a task on the team's Assignments board, pointing at the team's copy; it is marked done when \(member.displayName) finishes reading it or reviews it.",
        ] as [String: Any])
    }

    func listAssignments(teamID rawTeamID: String?, mine: Bool?, includeDone: Bool?) async throws -> String {
        let showDone = includeDone ?? false
        if mine ?? (rawTeamID == nil) {
            let since = showDone ? Date.distantPast : nil
            let assigned = try await notebookFileStorage.loadAssignedToMe(recentlyDoneSince: since)
            return try jsonString([
                "assigned_to_me": assigned.map { entry -> [String: Any] in
                    var payload = notebookTaskPayload(entry.task)
                    payload["team_name"] = entry.teamName
                    payload["source_title"] = entry.sourceTitle.map { $0 as Any } ?? NSNull()
                    payload["doc_title"] = entry.artifactTitle.map { $0 as Any } ?? NSNull()
                    return payload
                },
                "guidance": "These are what other members assigned to this account. Open a source with get_source_content; reading it to the end or reviewing it marks the task done, and update_notebook_task can mark it done by hand.",
            ] as [String: Any])
        }
        let team = try await requireTeamRecord(rawTeamID)
        let notebookID = TeamContentIdentity.assignmentsNotebookID(teamID: team.id)
        let tasks = try await notebookFileStorage.loadNotebookTasks(notebookID: notebookID)
            .filter { showDone || $0.status != .done }
        return try jsonString([
            "team_id": team.id,
            "notebook_id": notebookID,
            "assignments": tasks.map(notebookTaskPayload),
        ] as [String: Any])
    }
}
