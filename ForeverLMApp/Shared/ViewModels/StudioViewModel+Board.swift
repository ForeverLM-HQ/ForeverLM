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

    /// **Chat About This** on a card (product owner, 2026-11-18: launch a chat
    /// from a Board card and keep the link): a card already taken into a chat
    /// this Mac holds opens it; otherwise a fresh chat opens with the card's
    /// words ready under the composer, and the chat links itself to the card
    /// when the first message is sent (`ReviewSessionManager.pendingNotebookTaskLink`).
    func requestBoardCardChat(_ task: NotebookTaskRecord) {
        if let chatID = task.chatID, reviewSessionLinks.contains(where: { $0.id == chatID }) {
            requestResumeReviewSession(chatID)
            return
        }
        pendingReviewChatNotebookID = nil
        pendingReviewChatDraft = Self.boardCardChatDraft(task)
        pendingReviewChatTaskID = task.id
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
    }

    /// A card as words for a chat: its title, then its notes. Pure, so it can be tested.
    nonisolated static func boardCardChatDraft(_ task: NotebookTaskRecord) -> String {
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = "I had this idea: \u{201C}\(title)\u{201D}"
        if !notes.isEmpty { draft += "\n\n\(notes)" }
        draft += "\n\nHelp me think it through."
        return draft
    }

    /// Every card the Board and the notebooks have loaded, by id.
    func loadedNotebookTask(_ id: String) -> NotebookTaskRecord? {
        for tasks in notebookTasksByNotebookID.values {
            if let task = tasks.first(where: { $0.id == id }) { return task }
        }
        return nil
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
        await moveNotebookTask(taskID, notebookID: notebookID, into: .status(status), before: targetID, dueTodayBy: dueTodayBy)
    }

    /// Drops a card into a column, a status's or one of the board's lists.
    /// An open card dropped in Today's view is due today (`dueTodayBy`).
    func moveNotebookTask(
        _ taskID: String,
        notebookID: String,
        into column: NotebookTaskBoard.Column,
        before targetID: String?,
        dueTodayBy: Date? = nil
    ) async {
        let tasks = tasks(for: notebookID)
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        let moves = NotebookTaskBoard.moving(task, into: column, before: targetID, among: tasks, lists: taskLists(for: notebookID))
        for var change in moves {
            if change.id == taskID, change.status == .todo, let dueTodayBy, change.dueAt.map({ $0 > dueTodayBy }) ?? true {
                change.dueAt = dueTodayBy
            }
            await saveNotebookTask(change)
        }
    }
}
