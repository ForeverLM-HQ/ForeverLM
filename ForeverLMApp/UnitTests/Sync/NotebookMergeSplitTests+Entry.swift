import Foundation
import Testing
@testable import ForeverLM

/// The store's own merge and split entry points (`KnowledgeStore+Learning.swift`): generation 2 takes
/// the jobs and hides the stubs they leave, and generation 1 takes today's path, the preference rows'
/// hand-over included (D40). These run in the test host only: the standalone harness has no
/// `KnowledgeStore+Learning.swift`.
extension NotebookMergeSplitTests {
    @Test("Under generation 2 the store's merge and split run the jobs, and the stubs they leave are no notebooks of their own")
    func generation2EntryPointsTakeTheJobs() throws {
        let (root, store) = try F.makeStore("entry-gen2")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "Mitochondria")
        try F.addNotebook(store, "nb-b", title: "Mito Phenotyping")
        try F.addNotebook(store, "nb-p", title: "Bioenergetics")
        for source in ["src-1", "src-2", "src-3"] { try F.addSource(store, source) }
        try F.file(store, "src-1", into: "nb-a")
        try F.file(store, "src-2", into: "nb-p")
        try F.file(store, "src-3", into: "nb-p")

        let merged = try store.mergeCompanionGoals(notebookIDs: ["nb-b", "nb-a"], title: "  ")
        #expect(merged.sourcesAdded == 1)
        #expect(try F.text(store, "SELECT merged_into FROM learning_goals WHERE id = 'nb-a'") == "nb-b")
        #expect(try store.loadLearningGoal("nb-b")?.title == "Mito Phenotyping", "a blank title renames nothing")

        let split = try store.splitCompanionGoal(
            sourceGoalID: "nb-p",
            splits: [CompanionGoalSplitSpec(title: "OXPHOS", topic: nil, sourceIDs: ["src-2", "src-3"], gapIDs: [])],
            keepParent: false
        )
        let heir = try #require(split.heirGoalID)
        #expect(split.parentGoalID == nil)
        #expect(try F.text(store, "SELECT fold_kind FROM learning_goals WHERE id = 'nb-p'") == "split")
        let listed = Set(try store.loadLearningGoals().map(\.id))
        #expect(listed == ["nb-b", heir], "stubs are redirects, not notebooks the learner sees")
    }

    @Test("Under generation 1 merge and split take today's path: the merged notebook and an emptied parent are deleted, no stub is written, and the parent's rows are handed over")
    func generation1TakesTodaysPath() throws {
        let (root, store) = try F.makeStore("entry-gen1", generation: .one)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addNotebook(store, "nb-a", title: "Mitochondria")
        try F.addNotebook(store, "nb-b", title: "Mito Phenotyping")
        try F.addNotebook(store, "nb-p", title: "Bioenergetics")
        for source in ["src-1", "src-2", "src-3"] { try F.addSource(store, source) }
        try F.file(store, "src-1", into: "nb-a")
        try F.file(store, "src-2", into: "nb-p")
        try F.file(store, "src-3", into: "nb-p")

        _ = try store.mergeCompanionGoals(notebookIDs: ["nb-b", "nb-a"])
        #expect(try store.loadLearningGoal("nb-a") == nil)
        let split = try store.splitCompanionGoal(
            sourceGoalID: "nb-p",
            splits: [CompanionGoalSplitSpec(title: "OXPHOS", topic: nil, sourceIDs: ["src-2", "src-3"], gapIDs: [])],
            keepParent: false
        )
        let heir = try #require(split.heirGoalID)
        #expect(try store.loadLearningGoal("nb-p") == nil)
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goals WHERE merged_into IS NOT NULL OR fold_kind IS NOT NULL") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM notebook_states") == 0)

        // What the callers run after a generation-1 split (`StorageService`, MCP `split_notebook`).
        let suite = "WP8b-gen1-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The callers read the build's generation, which the test host sets to 2: pin this store's.
        try ForeverLMRuntimeIdentity.$pinnedSyncGeneration.withValue(.one) {
            try NotebookChatSelection.$overrideDefaults.withValue(NotebookChatSelection.DefaultsOverride(defaults: defaults)) {
                #expect(!NotebookStateStore.isActive)
                NotebookChatSelection.write(["src-2"], notebookID: "nb-p")
                NotebookChatSelection.handOver(
                    fromParent: "nb-p", toHeir: heir,
                    heirPool: try store.notebookContextSourceIDs(notebookID: heir), heirLinks: try store.relatedNotebookIDsForNotebook(notebookID: heir)
                )
                #expect(defaults.stringArray(forKey: NotebookChatSelection.preferenceKey(notebookID: heir)) == ["src-2"])
                #expect(defaults.object(forKey: NotebookChatSelection.preferenceKey(notebookID: "nb-p")) == nil)
            }
        }
    }
}
