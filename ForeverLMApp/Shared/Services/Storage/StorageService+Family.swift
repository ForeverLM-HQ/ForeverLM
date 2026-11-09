import Foundation
import OSLog

// Assignments and family plans (docs/family-design.md). An assignment is a
// task in the team's Assignments Notebook that points at the team's copy of a
// source or Doc; a family plan is the owner's plan covering the team's
// members, with each member's OpenRouter key sealed to their device.
extension StorageService {
    private static let familyLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Family")

    // MARK: - Assignments

    enum AssignmentError: LocalizedError {
        case nothingToAssign
        case notAMember(String)
        case readOnly(String)
        case ownerOnly(String)

        var errorDescription: String? {
            switch self {
            case .nothingToAssign:
                return "Choose a source or a Page to assign."
            case .notAMember(let team):
                return "That person is not a member of \(team)."
            case .readOnly(let team):
                return "\(team) is read-only for you, so you cannot assign anything in it."
            case .ownerOnly(let team):
                return "Only the owner of \(team) can turn its family plan on or off."
            }
        }
    }

    /// Assign a source or a Doc to one member of a team. The item is copied
    /// into the team first (sharing copies, docs/teams-design.md decision 2)
    /// and filed in the team's Assignments Notebook; the task points at the
    /// team's copy, so the member opens the same record everyone else sees.
    /// Assigning the same item to the same member again updates their open
    /// task rather than adding a second one.
    @discardableResult
    func assign(
        sourceID: String? = nil,
        artifactID: String? = nil,
        to assigneeRecordName: String,
        inTeam teamID: String,
        dueAt: Date? = nil,
        notes: String = ""
    ) throws -> NotebookTaskRecord {
        guard sourceID != nil || artifactID != nil else { throw AssignmentError.nothingToAssign }
        let store = try notebookFilesKnowledgeStore()
        guard let team = try store.loadTeam(teamID) else { throw TeamError.unknownTeam(teamID) }
        guard team.canEdit else { throw AssignmentError.readOnly(team.name) }
        let members = try store.loadTeamMembers(teamID: teamID)
        guard let assignee = members.first(where: { $0.userRecordName == assigneeRecordName }) else {
            throw AssignmentError.notAMember(team.name)
        }
        let assigner = members.first(where: \.isCurrentUser)
        let notebook = try store.ensureAssignmentsNotebook(teamID: teamID)

        var teamSourceID: String?
        var teamArtifactID: String?
        var title = ""
        if let sourceID {
            // Copies an own source into the team (file included); a team row
            // maps to itself. The copy is filed in the Notebook's pool.
            guard let copyID = try sourceIDsForGoalLibrary(goalID: notebook.id, [sourceID]).first else {
                throw KnowledgeStoreError.invalidData("Source \(sourceID) could not be copied into \(team.name).")
            }
            _ = try addCompanionSeedSources(goalID: notebook.id, sourceIDs: [copyID])
            teamSourceID = copyID
            title = try store.assignableSourceTitle(copyID) ?? "Source"
        }
        if let artifactID {
            guard let artifact = try store.loadArtifact(artifactID) else {
                throw KnowledgeStoreError.invalidData("Page \(artifactID) does not exist.")
            }
            teamArtifactID = artifact.teamID == teamID
                ? artifact.id
                : try shareArtifact(artifactID, withTeam: teamID, linkedTeamNotebookIDs: [notebook.id]).id
            if title.isEmpty { title = artifact.title }
        }

        let now = Date()
        var task = try store.openAssignment(
            teamID: teamID,
            assigneeRecordName: assigneeRecordName,
            sourceID: teamSourceID,
            artifactID: teamArtifactID
        ) ?? NotebookTaskRecord(
            notebookID: notebook.id,
            teamID: teamID,
            title: title,
            assigneeRecordName: assignee.userRecordName,
            assigneeDisplayName: assignee.displayName,
            sourceID: teamSourceID,
            artifactID: teamArtifactID,
            sortOrder: now.timeIntervalSinceReferenceDate,
            createdByRecordName: assigner?.userRecordName,
            createdByDisplayName: assigner?.displayName,
            createdAt: now,
            updatedAt: now
        )
        task.dueAt = dueAt ?? task.dueAt
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty { task.notes = trimmedNotes }
        return try saveNotebookTask(task)
    }

    /// Every task assigned to this account across its teams
    /// (`KnowledgeStore.loadAssignedToMe`).
    func loadAssignedToMe(recentlyDoneSince: Date? = nil) throws -> [AssignedTask] {
        try notebookFilesKnowledgeStore().loadAssignedToMe(recentlyDoneSince: recentlyDoneSince)
    }

    // MARK: - Family plan (owner)

    /// Turn the family plan on or off for a team this account owns. On asks
    /// the proxy for a code (which needs this account's own plan) and writes
    /// it into the team's record, so every member's Mac joins by itself; off
    /// ends every membership that came through the team and clears the code.
    @discardableResult
    func setFamilyPlan(teamID: String, enabled: Bool) async throws -> TeamRecord {
        let store = try notebookFilesKnowledgeStore()
        guard var team = try store.loadTeam(teamID) else { throw TeamError.unknownTeam(teamID) }
        guard team.role == .owner else { throw AssignmentError.ownerOnly(team.name) }
        if enabled {
            team.familyPlanCode = try await FamilyPlanClient.enable(teamID: teamID)
        } else {
            try await FamilyPlanClient.disable(teamID: teamID)
            team.familyPlanCode = nil
        }
        team.updatedAt = Date()
        try store.saveTeam(team)
        // Generation 2 carries the code in the family space's root (§3.5.1).
        try await setFamilyPlanCodeInSpace(teamID: teamID, code: team.familyPlanCode)
        scheduleImmediateCloudKitSyncForTeams()
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return team
    }

    // MARK: - Family plan (member)

    /// What this Mac did about the account's family on one pass.
    struct FamilyPlanSyncResult: Equatable, Sendable {
        var joinedTeamID: String?
        var leftTeamID: String?
        var keyApplied = false
        var keyRemoved = false
        var status: FamilyPlanClient.Status?
    }

    /// A member's side, run on events (app activation, a team arriving or
    /// changing): join the family a team this account belongs to is carrying,
    /// leave one whose team is gone from this Mac, and keep the own key in
    /// step with the key the parent sealed for this account. Idempotent;
    /// every step is a no-op once the state already matches.
    func syncFamilyPlanMembership() async throws -> FamilyPlanSyncResult {
        let store = try notebookFilesKnowledgeStore()
        let teams = try store.loadTeams()
        var result = FamilyPlanSyncResult()
        var status = try await FamilyPlanClient.status()

        if let membership = status.membership,
           !teams.contains(where: { $0.id == membership.teamID && $0.role == .member }) {
            // The child left the team, or the parent deleted it: the family
            // they paid through goes too.
            try await FamilyPlanClient.leave()
            result.leftTeamID = membership.teamID
            status = try await FamilyPlanClient.status()
        }

        if status.membership == nil,
           let team = teams.first(where: { $0.role == .member && $0.familyPlanCode != nil }),
           let code = team.familyPlanCode {
            let me = try store.loadTeamMembers(teamID: team.id).first(where: \.isCurrentUser)
            do {
                let joined = try await FamilyPlanClient.join(
                    code: code,
                    displayName: me?.displayName ?? "",
                    cloudKitUserRecordName: me?.userRecordName
                )
                result.joinedTeamID = joined.teamID
                status = try await FamilyPlanClient.status()
            } catch let error as ManagedAI.ServiceError
                where ["family_taken", "family_code_unknown", "family_full", "family_own"].contains(error.code) {
                // Not this Mac's to fix: another family, a renewed code the
                // team record has not delivered yet, or a full family. Logged,
                // and the next pass tries again.
                Self.familyLogger.notice("Family plan join for team \(team.id, privacy: .public) refused: \(error.code, privacy: .public)")
            }
        }

        let applied = try applyFamilyKey(status.membership)
        result.keyApplied = applied == .applied
        result.keyRemoved = applied == .removed
        result.status = status
        return result
    }

    enum FamilyKeyChange: Equatable { case unchanged, applied, removed }

    /// Keep the own key in step with the family's sealed key. A key the
    /// learner set themselves (no applied stamp) is never replaced; a family
    /// key is replaced when the parent seals a new one and removed when the
    /// parent takes it away or the family ends.
    func applyFamilyKey(_ membership: FamilyPlanClient.Membership?) throws -> FamilyKeyChange {
        let appliedStamp = KeychainService.load(.familyAppliedKeyStamp)
        guard let membership, membership.covered, let sealed = membership.key else {
            guard appliedStamp != nil else { return .unchanged }
            ManagedAI.setOwnKey(nil, router: .openRouter)
            KeychainService.delete(.familyAppliedKeyStamp)
            return .removed
        }
        let stamp = sealed.updatedAt ?? sealed.encapsulation
        if appliedStamp == stamp { return .unchanged }
        if appliedStamp == nil, ManagedAI.hasOwnKey { return .unchanged }
        let key = try FamilyKeySealing.open(sealed, with: FamilyDeviceKey.privateKey())
        ManagedAI.setOwnKey(key, router: .openRouter)
        KeychainService.save(stamp, for: .familyAppliedKeyStamp)
        return .applied
    }
}
