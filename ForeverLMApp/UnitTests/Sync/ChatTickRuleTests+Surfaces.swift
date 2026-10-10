import Foundation
import Testing
@testable import ForeverLM

/// D52 on the Mac's surfaces under generation 2 (docs/cloudkit-schema-design.md §5.6): with the
/// member's NotebookState bound (`NotebookStateStore.override`), a listed notebook reaches nothing until
/// the member ticks it; `update_notebook`'s `related_notebook_ids` writes the link and the tick; a
/// ticked notebook then reaches the notebook's chat context (`get_notebook_context`,
/// `list_notebook_sources`, and every chat, spoken reviews included, through `NotebookChatSelection`)
/// but never a Studio maker's input or count (`NotebookSourceLoader`).
extension ChatTickRuleTests {
    @Test("A listed notebook reaches no surface until ticked; a ticked one reaches the chat context, never the Studio")
    func surfaces() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WP8-d52-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPDataStore(dbPath: root.appendingPathComponent("knowledge.db").path)
        let knowledge = try store.knowledgeStore()
        for id in ["src-own", "src-ctx"] {
            try knowledge.execute("INSERT INTO sources (id, date_added, state, source_type, status) VALUES (?, 1, 'ready', 'article', 'active')", [.text(id)])
            try knowledge.execute("INSERT INTO articles (source_id, url, normalized_url, title, domain) VALUES (?, ?, ?, ?, 'example.com')",
                                  [.text(id), .text("https://example.com/\(id)"), .text("example.com/\(id)"), .text("Title \(id)")])
        }
        func notebook(_ title: String, _ source: String) throws -> LearningGoalRecord {
            try knowledge.createCompanionGoal(title: title, topic: title, startAt: Date(), endAt: LearningGoalRecord.openEndedEndAt,
                                              dailyTarget: 3, discoveryEnabled: false, seedSourceIDs: [source])
        }
        let a = try notebook("Notebook A", "src-own")
        let b = try notebook("Notebook B", "src-ctx")

        let box = NotebookStateStore.Box()
        try await NotebookStateStore.$override.withValue(box) {
            #expect(NotebookStateStore.isActive)
            // A link made before the rule starts unticked.
            try knowledge.setRelatedNotebooks(notebookID: a.id, relatedNotebookIDs: [b.id])
            let before = try await store.getNotebookContext(notebookID: a.id, maxSourceChars: nil, includeEmergentState: false, includeSourceContent: true)
            #expect(before.contains("1 sources its chats read"), "listed is not ticked")

            // Taken out and put back with update_notebook: the link and this member's tick.
            try knowledge.setRelatedNotebooks(notebookID: a.id, relatedNotebookIDs: [])
            _ = try await store.updateNotebook(notebookID: a.id, title: nil, description: nil, topic: nil, endDateString: nil, openEnded: nil,
                                              dailyTarget: nil, discover: nil, relatedNotebookIDs: [b.id])
            #expect(box.snapshot.contextNotebooks[a.id] == [b.id])
            let context = try await store.getNotebookContext(notebookID: a.id, maxSourceChars: nil, includeEmergentState: false, includeSourceContent: true)
            #expect(context.contains("2 sources its chats read"))
            #expect(try store.listNotebookSources(notebookID: a.id).contains("src-ctx"))
            #expect(NotebookChatSelection.selection(notebookID: a.id).contextNotebookIDs == [b.id], "every chat reads the tick")

            // The Studio reads the notebook's own ticked sources only, and its count with them.
            let reloaded = try #require(try knowledge.loadLearningGoal(a.id))
            let studio = NotebookSourceLoader.tickedSourceIDs(pool: reloaded.approvedSourceIDs, notebookID: a.id)
            #expect(studio == ["src-own"])
        }
    }
}
