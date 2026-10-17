import Foundation

// The Board: the learner's own columns of cards (docs-site/board.md). A card
// is an ordinary Notebook task (`notebook_tasks`), so the Board needs no table,
// no migration and no sync work of its own: it is one Notebook, with a fixed
// id, whose tasks the Space draws as To do, In progress and Done. Because the
// cards are tasks, `list_notebook_tasks`, `create_notebook_task` and
// `update_notebook_task` already read and write the Board for an MCP client.
extension KnowledgeStore {

    static let boardNotebookTitle = "Board"

    /// The Board's Notebook, created on first use. The fixed id makes a second
    /// device's creation the same record. `created` is true only for the call
    /// that made it, so the caller syncs once.
    func ensureBoardNotebook() throws -> (notebook: LearningGoalRecord, created: Bool) {
        let id = TeamContentIdentity.personalBoardNotebookID
        if let existing = try loadLearningGoal(id) { return (existing, false) }
        let now = Date()
        let made = try createCompanionGoal(
            title: Self.boardNotebookTitle,
            topic: "",
            startAt: now,
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 1,
            discoveryEnabled: false,
            seedSourceIDs: [],
            id: id
        )
        return (made, true)
    }
}
