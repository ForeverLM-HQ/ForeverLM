import Foundation
import OSLog

// MARK: - Teams as spaces, generation 2 (docs/cloudkit-schema-design.md §9, §13.7, D21, D40)

/// Under generation 2 a team is a space of the library container: the Mac's team entry points
/// (`createTeam`, `renameTeam`, the invitation link, the roster, leaving and deleting) run here on
/// `SpaceService` and `ShareService`, and never touch the old container, whose paths stay generation
/// 1's until WP30. Sharing into a team copies through generation 1's copy writers, and the copies then
/// take their wire ids and identities in the space (`keepTeamCopiesForGeneration2`); what is filed
/// under the original afterwards does not follow (§9.4: one notebook is edited in place, so there is
/// no follow-on). Moving a notebook into a space the learner owns is WP15b's `SpaceMoveJob`.
extension StorageService {
    /// This account as a space's root names its owner.
    private func spaceOwner(_ coordinator: SyncCoordinator) async throws -> SyncPerson {
        SyncPerson(user: try await coordinator.transport.userRecordName(), name: coordinator.shares.accountName ?? "")
    }

    private func space(forTeam teamID: String, _ service: SpaceService) async throws -> SpaceSummary {
        guard let space = try await service.list().first(where: { $0.localTeamID == teamID && $0.gone == nil }) else {
            throw TeamError.unknownTeam(teamID)
        }
        return space
    }

    func createTeamAsSpace(name: String) async throws -> TeamRecord {
        let service = try SpaceService.current()
        guard let coordinator = SyncCoordinator.current else { throw SpaceServiceError.syncNotRunning }
        let space = try await service.create(kind: "team", name: name, owner: try await spaceOwner(coordinator))
        guard let team = try notebookFilesKnowledgeStore().loadTeam(space.localTeamID) else { throw TeamError.unknownTeam(space.localTeamID) }
        _ = try await refreshSpaceMembers(teamID: team.id)
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
        return team
    }

    func renameTeamAsSpace(_ teamID: String, name: String) async throws {
        let service = try SpaceService.current()
        try await service.rename(try await space(forTeam: teamID, service), to: name)
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
    }

    /// Copy Link: the owner opens the space's share to anyone with the link, at read and write, as
    /// generation 1 does; a member's link is the share's as it stands.
    func spaceInvitationLink(teamID: String) async throws -> URL {
        let service = try SpaceService.current()
        let space = try await space(forTeam: teamID, service)
        let shared = space.isOwned
            ? try await service.shares.share(space.zone, publicPermission: .readWrite)
            : try await service.shares.roster(of: space.zone)
        guard let url = shared.url else { throw TeamError.shareUnavailable(space.name) }
        try notebookFilesKnowledgeStore().execute("UPDATE teams SET share_url = ? WHERE id = ?", [.text(url.absoluteString), .text(teamID)])
        return url
    }

    /// The roster as the space's share holds it, written into the team's member rows.
    func refreshSpaceMembers(teamID: String) async throws -> [TeamMemberRecord] {
        let service = try SpaceService.current()
        let space = try await space(forTeam: teamID, service)
        let roster: SpaceShare
        do {
            roster = try await service.shares.roster(of: space.zone)
        } catch ShareServiceError.notShared {
            return try notebookFilesKnowledgeStore().loadTeamMembers(teamID: teamID)
        }
        let now = Date()
        let members = roster.members.map { member in
            TeamMemberRecord(
                userRecordName: member.person.user, teamID: teamID, displayName: member.person.name ?? member.person.user, email: nil,
                role: member.isOwner ? .owner : .member, permission: member.permission == .readWrite ? .readWrite : .readOnly,
                acceptanceStatus: member.acceptance.rawValue, isCurrentUser: member.isCurrentUser, updatedAt: now
            )
        }
        let store = try notebookFilesKnowledgeStore()
        try store.replaceTeamMembers(teamID: teamID, members: members)
        try store.execute("UPDATE teams SET share_url = COALESCE(?, share_url) WHERE id = ?", [.text(roster.url?.absoluteString), .text(teamID)])
        return members
    }

    /// Leave (§9.6): the share goes from this member's shared database; the space's rows stay hidden on
    /// this Mac for 30 days, for "Keep a personal copy".
    func leaveTeamAsSpace(_ teamID: String) async throws {
        let service = try SpaceService.current()
        let space = try await space(forTeam: teamID, service)
        guard !space.isOwned else { throw TeamError.ownerCannotLeave }
        try await service.shares.leave(space.zone)
        try notebookFilesKnowledgeStore().execute("DELETE FROM teams WHERE id = ?", [.text(teamID)])
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
    }

    /// Delete space (§9.6), after the owner confirmed what it destroys: the zone and its rows.
    func deleteTeamAsSpace(_ teamID: String) async throws {
        let service = try SpaceService.current()
        let space = try await space(forTeam: teamID, service)
        guard space.isOwned else { throw TeamError.memberCannotDelete }
        try await service.delete(space)
        NotificationCenter.default.post(name: .cloudKitSyncStoreDidChange, object: nil)
    }

    /// A family's plan code goes into the space's root too, where members' Macs read it.
    func setFamilyPlanCodeInSpace(teamID: String, code: String?) async throws {
        let service = try SpaceService.current()
        try await service.setFamilyPlanCode(try await space(forTeam: teamID, service), code)
    }

    /// After a copy into a team under generation 2: every row the copy wrote takes its wire id and its
    /// identity in the team's space, so the feeder sends it there (§4.3, §13.7 step 3); every team's
    /// copy writer ends in `scheduleImmediateCloudKitSyncForTeams`, which calls this. Generation 1
    /// writes nothing here.
    func keepTeamCopiesForGeneration2() {
        do {
            let store = try notebookFilesKnowledgeStore()
            for (teamID, zoneKey) in try store.teamZoneKeys().sorted(by: { $0.key < $1.key }) {
                try store.inDerivationTransaction { try SpaceRows.adopt(teamID: teamID, zoneKey: zoneKey, connection: $0) }
            }
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "Teams")
                .error("A team's copies could not take their space identities: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sharing a notebook into a space this account owns moves it there (D21, §5.3): the move is a
    /// `Job(moveToSpace)` that a Mac's `SpaceMoveJob` (WP15b) runs. The notebook keeps its id.
    @discardableResult
    func requestMoveIntoSpace(_ notebookID: String, teamID: String) throws -> String {
        let store = try notebookFilesKnowledgeStore()
        guard let spaceID = try SpaceRows.spaceID(teamID: teamID, connection: store) else { throw TeamError.unknownTeam(teamID) }
        let device = try store.generation2DeviceID() ?? ""
        return try MacJobRequests.request(
            kind: "moveToSpace", target: ItemRef(.notebook, notebookID).rawValue, params: ["spaceID": .string(spaceID)],
            device: device, at: Date(), connection: store
        )
    }
}
