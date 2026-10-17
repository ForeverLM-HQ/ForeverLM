import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// The Board (docs-site/board.md) is one Notebook with a fixed id whose tasks
/// are its cards, so these tests hold the two things that make it safe: two
/// devices opening it make one Notebook, and a dropped card's new place and
/// column survive a save and a reload.
@Suite("Board notebook")
struct BoardNotebookTests {

    @Test("The Board's Notebook is made once, with the same id wherever it is made, and belongs to no team")
    func boardNotebookIsDeterministic() throws {
        let store = try KnowledgeStore(inMemory: true)
        let first = try store.ensureBoardNotebook()
        let second = try store.ensureBoardNotebook()
        #expect(first.created)
        #expect(!second.created)
        #expect(first.notebook.id == TeamContentIdentity.personalBoardNotebookID)
        #expect(first.notebook.id == second.notebook.id)
        #expect(first.notebook.teamID == nil)
        #expect(first.notebook.title == KnowledgeStore.boardNotebookTitle)
        #expect(try store.loadLearningGoals().filter { $0.id == first.notebook.id }.count == 1)
        #expect(TeamContentIdentity.personalBoardNotebookID != TeamContentIdentity.assignmentsNotebookID(teamID: "team-1"))
    }

    @Test("A card dropped into another column keeps its column and its place after a save and a reload")
    func droppedCardPersists() throws {
        let store = try KnowledgeStore(inMemory: true)
        let board = try store.ensureBoardNotebook().notebook
        let now = Date()
        for (index, title) in ["Ship export", "Write notes", "Call Zara Holt"].enumerated() {
            try store.saveNotebookTask(NotebookTaskRecord(
                notebookID: board.id, title: title, sortOrder: Double(index + 1), createdAt: now, updatedAt: now
            ))
        }
        let tasks = try store.loadNotebookTasks(notebookID: board.id)
        let moved = try #require(tasks.first { $0.title == "Call Zara Holt" })
        let before = try #require(tasks.first { $0.title == "Write notes" })

        for change in NotebookTaskBoard.moving(moved, to: .todo, before: before.id, among: tasks) { try store.saveNotebookTask(change) }
        let reloaded = NotebookTaskBoard.sections(try store.loadNotebookTasks(notebookID: board.id))
        #expect(reloaded.first { $0.status == .todo }?.tasks.map(\.title) == ["Ship export", "Call Zara Holt", "Write notes"])

        let doing = try #require(reloaded.first { $0.status == .todo }?.tasks.first)
        for change in NotebookTaskBoard.moving(doing, to: .doing, before: nil, among: try store.loadNotebookTasks(notebookID: board.id)) {
            try store.saveNotebookTask(change)
        }
        let afterMove = NotebookTaskBoard.sections(try store.loadNotebookTasks(notebookID: board.id))
        #expect(afterMove.first { $0.status == .doing }?.tasks.map(\.title) == ["Ship export"])
        #expect(afterMove.first { $0.status == .todo }?.tasks.map(\.title) == ["Call Zara Holt", "Write notes"])
    }
}

#endif
