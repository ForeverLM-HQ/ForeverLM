import Foundation
import Testing
@testable import ForeverLM

/// Bug b1 by construction (docs/cloudkit-schema-design.md D14, §3.5.6, §3.5.7): a notebook and a Goal
/// are separate record types, a row's kind is decided once (`entity_kind`), and a record of one type
/// never projects as the other.
@Suite("Notebook versus Goal")
struct NotebookVersusGoalTests {
    typealias F = NotebookSyncFixture

    @Test("Each row feeds its own type only, however its deadline later reads")
    func rowsFeedTheirOwnType() throws {
        let (root, store) = try F.makeStore("b1-rows")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addGoal(store, "goal-1", parent: "nb-1")
        #expect(try F.text(store, "SELECT entity_kind FROM learning_goals WHERE id = 'nb-1'") == "notebook")
        #expect(try F.text(store, "SELECT entity_kind FROM learning_goals WHERE id = 'goal-1'") == "goal")
        let pending = try F.pending(store)
        #expect(pending["Notebook:nb-1"] != nil && pending["Goal:nb-1"] == nil)
        #expect(pending["Goal:goal-1"] != nil && pending["Notebook:goal-1"] == nil)
        #expect(F.savedFields(pending["Goal:goal-1"])?["notebookID"] == .string("nb-1"))
        try F.sendAll(store)

        // A notebook given a deadline (an old client's edit) stays a notebook: the kind is not read
        // from `end_at` again.
        try store.execute("UPDATE learning_goals SET end_at = 800000000, title = 'Still a notebook' WHERE id = 'nb-1'")
        try store.keepNotebookRowsForGeneration2(goalIDs: ["nb-1"])
        let after = try F.pending(store)
        #expect(after["Notebook:nb-1"] != nil)
        #expect(after["Goal:nb-1"] == nil)
        #expect(try F.text(store, "SELECT entity_kind FROM learning_goals WHERE id = 'nb-1'") == "notebook")
    }

    @Test("A Notebook record never lands on a Goal's row, nor a Goal record on a notebook's")
    func recordsNeverCross() throws {
        let (root, store) = try F.makeStore("b1-records")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addGoal(store, "goal-1", parent: nil)
        try F.apply(store, [
            try F.record(.notebook, "goal-1", ["title": .string("Hijack"), "status": .string("active")]),
            try F.record(.goal, "nb-1", ["title": .string("Hijack"), "status": .string("active"), "dueAt": SyncJSON(Int64(1_800_000_000_000))]),
        ])
        #expect(try F.text(store, "SELECT title || '|' || entity_kind FROM learning_goals WHERE id = 'goal-1'") == "Finish the review|goal")
        #expect(try F.text(store, "SELECT title || '|' || entity_kind FROM learning_goals WHERE id = 'nb-1'") == "🧬 Mitochondria|notebook")
        // A new id of each type lands as its own type, whatever its fields suggest.
        try F.apply(store, [
            try F.record(.goal, "goal-new", ["title": .string("Exam"), "status": .string("active"), "dueAt": SyncJSON(Int64(4_200_000_000_000))]),
            try F.record(.notebook, "nb-new", ["title": .string("Open"), "status": .string("active")]),
        ])
        #expect(try F.text(store, "SELECT entity_kind FROM learning_goals WHERE id = 'goal-new'") == "goal", "a far deadline does not make a notebook")
        #expect(try F.text(store, "SELECT entity_kind FROM learning_goals WHERE id = 'nb-new'") == "notebook")
        #expect(try NotebookProjection.loadRows(localID: "goal-new", connection: store) == nil)
        #expect(try GoalProjection().loadRows(
            ProjectionRecordRef(zoneKey: F.libraryZoneKey, zone: .library, type: .goal, wireID: "nb-new", localID: "nb-new"), connection: store
        ) == nil)
    }

    @Test("A Goal's Entries carry the goal container and no approval")
    func goalEntries() throws {
        let (root, store) = try F.makeStore("b1-goal-entries")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addGoal(store, "goal-1", parent: nil)
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "goal-1")
        let fields = try #require(F.savedFields(try F.pending(store)["Entry:\(SyncIdentity.entryID(containerID: "goal-1", itemKind: "source", itemID: "src-a"))"]))
        #expect(fields["containerKind"] == .string("goal"))
        #expect(fields["approval"] == nil)
    }
}
