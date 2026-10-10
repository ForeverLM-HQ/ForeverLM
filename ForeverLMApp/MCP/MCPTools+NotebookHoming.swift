import Foundation

// MARK: - Homing over MCP (docs/notebooks-design.md, "Homing")
//
// A maker's optional notebook_id files what it makes in that notebook — a
// picture, a video; for a course it names a Notebook that follows it, since a
// course lives in no Notebook — and a list's optional notebook_id keeps only
// what belongs to it, by the notebook rule (`NotebookMembership`): a filed
// thing by its home and links, a derived thing by its source.
//
// notebook_id is only ever the id the caller gave: never a window's
// notebook (`MCPAppWindows`, which get_app_context alone reads), never matched
// by title
// (MCPTools+Notebooks.swift). A Notebook's chat in the app fills it in for the
// things it makes when the model left it out
// (`ReviewSessionManager.notebookScopedArguments`), and only when the Notebook
// can take them.

extension MCPDataStore {

    /// The notebook a maker's notebook_id names, checked before anything is
    /// made or billed. Nil when notebook_id is absent or blank (models fill an
    /// unused slot with ""). A Notebook only: a Goal is not a notebook. An
    /// archived Notebook, a team's this account can only read, and a team not
    /// on this Mac refuse the call (`NotebookImportRefusal`, the rule imports
    /// keep). Reads through the storage actor, so a tool holding no store gate
    /// may ask.
    func notebookForMadeThing(notebookID rawNotebookID: String?) async throws -> LearningGoalRecord? {
        guard let notebookID = Self.nilIfBlank(rawNotebookID ?? "") else { return nil }
        guard let notebook = try await notebookFileStorage.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw MCPError.invalidInput("Notebook not found: \(notebookID). Use list_notebooks to see available Notebooks, or leave notebook_id out to file it in none.")
        }
        let team = try await notebook.teamID.asyncFlatMap { try await notebookFileStorage.loadTeam($0) }
        try requireNotebookTakesMadeThings(notebook, team: team)
        return notebook
    }

    /// The same check for a tool that holds the store gate and reads the
    /// cached connection.
    func notebookForMadeThing(notebookID rawNotebookID: String?, store: KnowledgeStore) throws -> LearningGoalRecord? {
        guard let notebookID = Self.nilIfBlank(rawNotebookID ?? "") else { return nil }
        guard let notebook = try store.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw MCPError.invalidInput("Notebook not found: \(notebookID). Use list_notebooks to see available Notebooks, or leave notebook_id out to file it in none.")
        }
        let team = try notebook.teamID.flatMap { try store.loadTeam($0) }
        try requireNotebookTakesMadeThings(notebook, team: team)
        return notebook
    }

    /// Throws, naming why, when `notebook` cannot take a new thing.
    func requireNotebookTakesMadeThings(_ notebook: LearningGoalRecord, team: TeamRecord?) throws {
        guard let refusal = NotebookImportRefusal.refusal(for: notebook, team: team) else { return }
        switch refusal {
        case .missing:
            throw MCPError.invalidInput("Notebook not found: \(notebook.id). Use list_notebooks to see available Notebooks.")
        case .archived:
            throw MCPError.invalidInput(
                "‘\(notebook.title)’ (\(notebook.id)) is archived, so nothing was made. Restore it first, or leave notebook_id out to file it in no Notebook."
            )
        case .readOnlyTeam:
            if let team {
                throw MCPError.invalidInput(readOnlyRefusal(team, action: "file things in ‘\(notebook.title)’") + " Nothing was made.")
            }
            throw MCPError.invalidInput("‘\(notebook.title)’ is read-only for this account, so nothing was made.")
        case .teamNotOnThisMac(let teamID):
            throw MCPError.invalidInput(
                "‘\(notebook.title)’ belongs to team \(teamID), which is not on this Mac, so nothing was made. Call list_teams."
            )
        }
    }

    /// The notebook a list's notebook_id names, as `NotebookMembership` asks
    /// it; nil when notebook_id is absent or blank. Throws for an id that is
    /// not a Notebook. For a tool holding the store gate.
    func notebookMembershipForListing(notebookID rawNotebookID: String?, store: KnowledgeStore) throws -> NotebookMembership? {
        guard let notebookID = Self.nilIfBlank(rawNotebookID ?? "") else { return nil }
        _ = try resolveMCPNotebookGoal(notebookID: notebookID, store: store)
        return try store.notebookMembership(notebookID: notebookID)
    }

    /// The same through the storage actor, for a tool that reads there.
    func notebookMembershipForListing(notebookID rawNotebookID: String?) async throws -> NotebookMembership? {
        guard let notebookID = Self.nilIfBlank(rawNotebookID ?? "") else { return nil }
        guard let notebook = try await notebookFileStorage.loadLearningGoal(notebookID), notebook.isNotebook else {
            throw MCPError.invalidInput("Notebook not found: \(notebookID). Use list_notebooks to see available Notebooks.")
        }
        return try await notebookFileStorage.notebookMembership(notebookID: notebook.id)
    }

    /// A course tool's notebook_id against the course it lands in, checked
    /// before anything is imported: a Notebook follows only a course of its
    /// own library (`KnowledgeStore.followCourse`). An import naming no course
    /// that exists makes one in My Library.
    func requireNotebook(_ notebook: LearningGoalRecord?, takesCourse courseID: String?, store: KnowledgeStore) throws {
        guard let notebook else { return }
        let courseTeamID = try courseID.flatMap { try store.courseTeamID($0) }
        guard notebook.teamID != courseTeamID else { return }
        throw MCPError.invalidInput(Self.courseLibraryMismatch(notebook: notebook, courseTeamID: courseTeamID) + " Nothing was imported.")
    }

    /// Why `notebook` cannot follow a course of the library `courseTeamID`
    /// names (nil: My Library).
    static func courseLibraryMismatch(notebook: LearningGoalRecord, courseTeamID: String?) -> String {
        guard let courseTeamID else {
            return "‘\(notebook.title)’ is a team's Notebook. The course is My Library's, so only a Notebook of My Library follows it: pass one from list_notebooks, or leave notebook_id out."
        }
        return "The course is team \(courseTeamID)'s, so only a Notebook of that team follows it, and ‘\(notebook.title)’ is not one: pass one of the team's Notebooks, or leave notebook_id out."
    }

    /// The course tools' notebook_id on a course that exists: the Notebook
    /// follows it, so its sources join and later lectures too. A course lives
    /// in no Notebook, so nothing moves and no Notebook is "the" one. A Notebook
    /// of another library is refused, so a team's Notebook never follows a
    /// course of My Library or the other way round. Returns the Notebook and
    /// what happened.
    func fileCourse(_ courseID: String, inNotebook notebook: LearningGoalRecord) async throws -> (applied: String, note: String) {
        let courseTeamID = try await notebookFileStorage.loadCourseTeamIDs()[courseID]
        guard notebook.teamID == courseTeamID else {
            throw MCPError.invalidInput(Self.courseLibraryMismatch(notebook: notebook, courseTeamID: courseTeamID))
        }
        let alreadyFollowing = try await notebookFileStorage.linkedCourseIDsForNotebook(goalID: notebook.id).contains(courseID)
        let added = try await notebookFileStorage.followCourse(courseID: courseID, notebookID: notebook.id)
        if alreadyFollowing {
            return (notebook.id, "Notebook ‘\(notebook.title)’ already followed the course; \(added) of its source\(added == 1 ? "" : "s") joined now.")
        }
        return (
            notebook.id,
            "Notebook ‘\(notebook.title)’ now follows the course, and \(added) of its source\(added == 1 ? "" : "s") joined. The course itself lives in no Notebook."
        )
    }
}

private extension Optional {
    func asyncFlatMap<U>(_ transform: (Wrapped) async throws -> U?) async rethrows -> U? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
