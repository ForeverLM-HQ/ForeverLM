import Foundation

// A notebook's Share… (docs/teams-design.md, decision 22; the product owner, 2026-10-03:
// "also make sure that notebooks are easily shareable with other people" …
// "including all the sources in them"): who has a notebook, and the team its
// Invite People… and Copy Invitation Link invite to — made in the same step
// when the notebook is in no team yet. The popover (`NotebookSharePopover`)
// asks "Before you share" first and hands the team to Apple's sharing sheet
// or the invitation link (`TeamSharingService`).
extension StudioViewModel {

    /// The teams that have a notebook: its team, for a team's own notebook;
    /// otherwise every team holding a copy, read-only ones included. Read off
    /// the main actor; empty when the read fails.
    func teamsSharingNotebook(_ notebookID: String) async -> [TeamRecord] {
        do {
            return try await storage.teamsHoldingNotebook(notebookID)
        } catch {
            logger.error("Reading who has notebook \(notebookID) failed: \(error.localizedDescription)")
            return []
        }
    }

    /// The team a notebook's Share… invites people to: `teamID`, a team that
    /// already has the notebook, as it stands; or, for a notebook in no team
    /// yet, the one step (`StorageService.shareNotebook`): a new team named
    /// after the notebook, holding it with its approved sources and their
    /// files. Nil after a failure, which the toast says.
    func teamForSharingNotebook(_ notebookID: String, inTeam teamID: String?) async -> TeamRecord? {
        let title = notebook(id: notebookID)?.title ?? "the notebook"
        if let teamID {
            if team(id: teamID) == nil { await loadTeams() }
            guard let team = team(id: teamID) else {
                showToast("That team is no longer on this Mac")
                return nil
            }
            return team
        }
        do {
            let share = try await storage.shareNotebook(notebookID)
            await loadTeams()
            await refreshTeamMembers(teamID: share.team.id)
            if share.createdTeam {
                let sources = share.sharedSourceCount == 1 ? "its source" : "its \(share.sharedSourceCount) sources"
                showToast(share.sharedSourceCount == 0
                    ? "Made a team for \(title)"
                    : "Made a team for \(title) with \(sources)")
            }
            return team(id: share.team.id) ?? share.team
        } catch {
            logger.error("Sharing notebook \(notebookID) failed: \(error.localizedDescription)")
            showToast("Could not share \(title): \(error.localizedDescription)")
            return nil
        }
    }
}
