import Foundation

// The Board (docs-site/board.md): the learner's own columns of cards. Its
// cards are tasks of one Notebook, so everything here is the Notebook-task
// plumbing in `StudioViewModel+Teams.swift` pointed at that Notebook.
extension StudioViewModel {

    var boardNotebookID: String { TeamContentIdentity.personalBoardNotebookID }

    /// The Board's Notebook, once `loadBoard` has made or found it.
    var boardNotebook: LearningGoalRecord? { notebook(id: boardNotebookID) }

    /// Makes the Board's Notebook on first use, then reads its cards.
    func loadBoard() async {
        do {
            let board = try await storage.ensureBoardNotebook()
            if notebook(id: board.id) == nil { await loadLearningGoals() }
            await loadNotebookTasks(notebookID: board.id)
        } catch {
            logger.error("Opening the Board failed: \(error.localizedDescription)")
            showToast("Could not open the Board: \(error.localizedDescription)")
        }
    }

    /// Drops a card into a column, in front of `targetID` or at the bottom.
    /// `dueTodayBy` is the Today view's end of day: a card moved into To do
    /// there with no date, or a later one, is due today, so it stays in the
    /// view it was just dropped in instead of vanishing.
    func moveNotebookTask(
        _ taskID: String,
        notebookID: String,
        to status: NotebookTaskStatus,
        before targetID: String?,
        dueTodayBy: Date? = nil
    ) async {
        let tasks = tasks(for: notebookID)
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        for var change in NotebookTaskBoard.moving(task, to: status, before: targetID, among: tasks) {
            if change.id == taskID, status == .todo, let dueTodayBy, change.dueAt.map({ $0 > dueTodayBy }) ?? true {
                change.dueAt = dueTodayBy
            }
            await saveNotebookTask(change)
        }
    }
}
