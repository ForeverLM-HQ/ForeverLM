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
        let team = try await requireFamilyTeam(rawTeamID)
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
        let team = try await requireFamilyTeam(rawTeamID)
        let notebookID = TeamContentIdentity.assignmentsNotebookID(teamID: team.id)
        let tasks = try await notebookFileStorage.loadNotebookTasks(notebookID: notebookID)
            .filter { showDone || $0.status != .done }
        return try jsonString([
            "team_id": team.id,
            "notebook_id": notebookID,
            "assignments": tasks.map(notebookTaskPayload),
        ] as [String: Any])
    }

    // MARK: - Family plan

    func getFamilyPlan() async throws -> String {
        let teams = try await notebookFileStorage.loadTeams()
        let status = try await FamilyPlanClient.status()
        var teamEntries: [[String: Any]] = []
        for team in teams {
            let members = try await notebookFileStorage.loadTeamMembers(teamID: team.id)
            let joined = status.family(teamID: team.id)?.members ?? []
            let memberEntries: [[String: Any]] = members
                .filter { !$0.isCurrentUser && $0.role != .owner }
                .map { member in
                    let record = joined.first { $0.cloudKitUserRecordName == member.userRecordName }
                    return [
                        "user_record_name": member.userRecordName,
                        "display_name": member.displayName,
                        "joined": record != nil,
                        "has_key": record?.hasKey ?? false,
                    ]
                }
            teamEntries.append([
                "team_id": team.id,
                "name": team.name,
                "role": team.role.rawValue,
                "family_plan": team.isFamily,
                "members": memberEntries,
            ])
        }
        let membership: Any = status.membership.map { membership -> Any in
            ["team_id": membership.teamID, "covered": membership.covered, "has_key": membership.key != nil] as [String: Any]
        } ?? NSNull()
        return try jsonString([
            "max_members": status.maxMembers,
            "teams": teamEntries,
            "membership": membership,
            "guidance": "family_plan on a team this account owns means its plan covers the team's members; connect_family_member_key makes a member's OpenRouter key. A membership means another account's plan covers this one.",
        ] as [String: Any])
    }

    func setFamilyPlan(teamID rawTeamID: String?, enabled: Bool?) async throws -> String {
        guard let enabled else { throw MCPError.invalidInput("enabled is required: true to turn the family plan on, false to turn it off.") }
        let team = try await requireFamilyTeam(rawTeamID)
        guard team.role == .owner else {
            throw MCPError.invalidInput("Only the owner of ‘\(team.name)’ can turn its family plan on or off.")
        }
        let saved: TeamRecord
        do {
            saved = try await notebookFileStorage.setFamilyPlan(teamID: team.id, enabled: enabled)
        } catch let error as ManagedAI.ServiceError {
            throw MCPError.invalidInput(error.localizedDescription)
        }
        return try jsonString([
            "team_id": saved.id,
            "family_plan": saved.isFamily,
            "message": enabled
                ? "‘\(saved.name)’ is a family now: this account's plan covers its members, whose Macs join by themselves. Connect a key for each with connect_family_member_key."
                : "The family plan for ‘\(saved.name)’ is off; its members are no longer covered. Keys already made keep working at OpenRouter until revoked there.",
        ] as [String: Any])
    }

    /// Opens OpenRouter in the browser on this Mac to make a key for one
    /// member, then seals it to their device. The learner has to finish the
    /// sign-in there; this call waits for it (up to five minutes).
    func connectFamilyMemberKey(teamID rawTeamID: String?, member rawMember: String?) async throws -> String {
        let team = try await requireFamilyTeam(rawTeamID)
        guard team.role == .owner, team.isFamily else {
            throw MCPError.invalidInput("‘\(team.name)’ has no family plan of this account's. Call set_family_plan first.")
        }
        let members = try await notebookFileStorage.loadTeamMembers(teamID: team.id)
        let member = try resolveFamilyMember(rawMember, members: members, teamName: team.name)
        let status = try await FamilyPlanClient.status()
        guard let record = status.family(teamID: team.id)?.members.first(where: { $0.cloudKitUserRecordName == member.userRecordName }) else {
            throw MCPError.invalidInput("\(member.displayName) has not joined the family plan yet. Their Mac joins it the next time ForeverLM opens there.")
        }
        let label = "ForeverLM · \(member.displayName)"
        let key = try await OpenRouterConnect.connect(keyLabel: label)
        try await FamilyPlanClient.giveKey(key, to: record, label: label)
        return try jsonString([
            "team_id": team.id,
            "user_record_name": member.userRecordName,
            "has_key": true,
            "message": "\(member.displayName)'s OpenRouter key is connected. Their Mac picks it up by itself. A monthly limit for it can be set at openrouter.ai/settings/keys.",
        ] as [String: Any])
    }

    // MARK: - Helpers

    private func requireFamilyTeam(_ rawTeamID: String?) async throws -> TeamRecord {
        let teamID = (rawTeamID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !teamID.isEmpty else {
            throw MCPError.invalidInput("team_id is required. Use list_teams to find it.")
        }
        guard let team = try await notebookFileStorage.loadTeam(teamID) else {
            throw MCPError.notFound("No team with id \(teamID) on this Mac. Use list_teams.")
        }
        return team
    }

    /// A member by user_record_name, or by display name when exactly one
    /// member has it.
    private func resolveFamilyMember(_ raw: String?, members: [TeamMemberRecord], teamName: String) throws -> TeamMemberRecord {
        let wanted = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            throw MCPError.invalidInput("member is required: a user_record_name or display name from list_teams.")
        }
        if let exact = members.first(where: { $0.userRecordName == wanted }) { return exact }
        let byName = members.filter { $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame }
        if byName.count == 1, let only = byName.first { return only }
        let known = members.map { "\($0.displayName) (\($0.userRecordName))" }.joined(separator: ", ")
        throw MCPError.invalidInput(
            byName.isEmpty
                ? "\(wanted) is not a member of ‘\(teamName)’. Members: \(known.isEmpty ? "none on this Mac yet" : known)."
                : "More than one member of ‘\(teamName)’ is called \(wanted). Pass a user_record_name: \(known)."
        )
    }
}
