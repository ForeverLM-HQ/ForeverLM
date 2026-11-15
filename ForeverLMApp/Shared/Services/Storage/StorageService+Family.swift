import Foundation
import OSLog

// Assignments (docs/family-design.md). An assignment is a task in the team's
// Assignments Notebook that points at the team's copy of a source or Doc.
extension StorageService {

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
}
