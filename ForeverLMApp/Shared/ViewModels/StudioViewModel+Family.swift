import Foundation

// Assignments and family plans in the Studio (docs/family-design.md): the
// Assign to menu, the Today panel's Assigned section, and the member side of
// a family plan, which joins and keeps the family's key in step by itself.
extension StudioViewModel {

    // MARK: - Assigning

    struct AssignableTeam: Identifiable {
        let team: TeamRecord
        let members: [TeamMemberRecord]
        var id: String { team.id }
    }

    /// Teams this account can assign in, with the members it can assign to:
    /// every editable team that has anyone besides this account in it.
    var assignableTeams: [AssignableTeam] {
        teams.compactMap { team in
            guard team.canEdit, let members = assignableMembersByTeamID[team.id], !members.isEmpty else { return nil }
            return AssignableTeam(team: team, members: members)
        }
    }

    /// Re-read the stored rosters the Assign to menu offers. No network: the
    /// roster the last share fetch projected is what a menu can show at once.
    func refreshAssignableMembers() async {
        var result: [String: [TeamMemberRecord]] = [:]
        for team in teams where team.canEdit {
            let members = ((try? await storage.loadTeamMembers(teamID: team.id)) ?? [])
                .filter { !$0.isCurrentUser && $0.acceptanceStatus != "removed" }
            if !members.isEmpty { result[team.id] = members }
        }
        if result != assignableMembersByTeamID { assignableMembersByTeamID = result }
    }

    func assign(
        sourceIDs: [String] = [],
        artifactID: String? = nil,
        to member: TeamMemberRecord,
        dueAt: Date? = nil
    ) async {
        let teamName = teams.first(where: { $0.id == member.teamID })?.name ?? "the team"
        do {
            for sourceID in sourceIDs {
                try await storage.assign(sourceID: sourceID, to: member.userRecordName, inTeam: member.teamID, dueAt: dueAt)
            }
            if let artifactID {
                try await storage.assign(artifactID: artifactID, to: member.userRecordName, inTeam: member.teamID, dueAt: dueAt)
            }
            let count = sourceIDs.count + (artifactID == nil ? 0 : 1)
            let what = count == 1 ? "1 item" : "\(count) items"
            showToast("Assigned \(what) to \(member.displayName) in \(teamName)")
            await loadNotebookTasks(notebookID: TeamContentIdentity.assignmentsNotebookID(teamID: member.teamID))
            await loadLearningGoals()
        } catch {
            logger.error("Assigning to \(member.userRecordName) failed: \(error.localizedDescription)")
            showToast("Could not assign: \(error.localizedDescription)")
        }
    }

    // MARK: - Assigned to me

    func refreshAssignedToMe() async {
        let since = Calendar.current.startOfDay(for: Date())
        let loaded = (try? await storage.loadAssignedToMe(recentlyDoneSince: since)) ?? []
        if loaded != assignedToMe { assignedToMe = loaded }
    }

    /// Open what an assignment points at. A team's copy opens only from the
    /// team's library, so that becomes the active library first; there the
    /// learner's own row at the same address is the one that opens
    /// (docs/teams-design.md, decision 19).
    func openAssignment(_ assignment: AssignedTask) async {
        guard let teamID = assignment.teamID else { return }
        if activeTeamID != teamID {
            await setActiveTeam(teamID)
            guard activeTeamID == teamID else { return }
        }
        if let sourceID = assignment.task.sourceID {
            await selectArticle(sourceID, revealingReader: true)
        } else if let artifactID = assignment.task.artifactID {
            if !artifacts.contains(where: { $0.id == artifactID }) { await loadArtifacts() }
            revealArtifact(artifactID)
        }
    }

    /// Reload what changed when tasks arrive from another Mac: the learner's
    /// Assigned list, and any board already open, so a parent watching the
    /// Assignments board sees a child's work tick off.
    func notebookTasksDidChangeRemotely() async {
        await refreshAssignedToMe()
        for notebookID in notebookTasksByNotebookID.keys {
            await loadNotebookTasks(notebookID: notebookID)
        }
    }

    // MARK: - Family plan

    /// Turn a team's family plan on or off (owner only).
    func setFamilyPlan(teamID: String, enabled: Bool) async {
        do {
            _ = try await storage.setFamilyPlan(teamID: teamID, enabled: enabled)
            await loadTeams()
            await refreshFamilyPlanStatus()
        } catch {
            logger.error("Family plan \(enabled ? "on" : "off") for \(teamID) failed: \(error.localizedDescription)")
            showToast(error.localizedDescription)
        }
    }

    /// Off the main actor: the client reads the session from the Keychain.
    func refreshFamilyPlanStatus() async {
        do {
            let status = try await FamilyPlanClient.status()
            if status != familyPlanStatus { familyPlanStatus = status }
        } catch let error as ManagedAI.ServiceError where error.isInvalidSession {
            // Signed out: there is no family to show.
        } catch {
            logger.error("Reading the family plan failed: \(error.localizedDescription)")
        }
    }

    /// The member side of family plans, on an event (teams loaded, the
    /// Studio coming forward). Silent and cooldown-limited; it republishes
    /// only when something changed.
    func scheduleFamilyPlanSync(force: Bool = false) {
        // Involved: a team carries a family plan, the proxy says a family
        // covers this account, or — once per launch — this Mac holds an own
        // key, which may be a family's key whose family has since ended.
        let involved = teams.contains { $0.familyPlanCode != nil }
            || familyPlanStatus?.membership != nil
            || familyPlanSyncedAt == nil
        guard involved else { return }
        if !force, let last = familyPlanSyncedAt, Date().timeIntervalSince(last) < 60 { return }
        guard familyPlanSyncTask == nil else { return }
        familyPlanSyncedAt = Date()
        let storage = storage
        familyPlanSyncTask = Task { [weak self] in
            defer { self?.familyPlanSyncTask = nil }
            do {
                let result = try await storage.syncFamilyPlanMembership()
                guard let self else { return }
                if let status = result.status, status != self.familyPlanStatus { self.familyPlanStatus = status }
                if result.keyApplied {
                    self.showToast("Your family's OpenRouter key is set up on this Mac")
                } else if result.keyRemoved {
                    self.showToast("Your family's OpenRouter key was removed from this Mac")
                }
            } catch let error as ManagedAI.ServiceError where error.isInvalidSession {
                // Signed out; the next sign-in's team load tries again.
            } catch {
                self?.logger.error("Family plan sync failed: \(error.localizedDescription)")
            }
        }
    }
}
