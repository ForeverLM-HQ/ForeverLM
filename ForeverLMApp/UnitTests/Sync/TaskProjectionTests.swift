import Foundation
import Testing
@testable import ForeverLM

/// The Task projection (docs/cloudkit-schema-design.md §3.5.27, WP14): a notebook's to-dos and
/// assignments, a meeting's action items and a team's share requests, each from the table that stays its
/// local truth; board keys kept by the generation-2 write and applied from another device; a kind that
/// never changes after its first write; a team's tasks held for their space; a deleted task.
@Suite("Task projection")
struct TaskProjectionTests {
    typealias F = NotebookSyncFixture

    private static func store(_ name: String) throws -> (URL, KnowledgeStore) {
        let (root, store) = try F.makeStore("task-\(name)")
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        return (root, store)
    }

    private static func task(_ id: String, _ title: String, sortOrder: Double, status: NotebookTaskStatus = .todo,
                             assignee: String? = nil, sourceID: String? = nil) -> NotebookTaskRecord {
        NotebookTaskRecord(
            id: id, notebookID: "nb-1", title: title, notes: "Methods first", status: status, assigneeRecordName: assignee,
            assigneeDisplayName: assignee.map { _ in "Ana" }, dueAt: Date(timeIntervalSinceReferenceDate: 5_000), sourceID: sourceID,
            sortOrder: sortOrder, createdAt: Date(timeIntervalSinceReferenceDate: 1_000), updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
    }

    @Test("A board task encodes every field the Mac holds, its kind first-writer and its key in board order")
    func boardTaskFields() throws {
        let (root, store) = try Self.store("fields")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveNotebookTask(Self.task("task-1", "Read the methods", sortOrder: 0, sourceID: "src-1"))
        try store.saveNotebookTask(Self.task("task-2", "Write a summary", sortOrder: 1, status: .done, assignee: "_member2"))
        let pending = try F.pending(store)

        let first = try #require(F.savedFields(pending["Task:task-1"]))
        #expect(first["kind"] == .string("todo"))
        #expect(first["notebookID"] == .string("nb-1") && first["title"] == .string("Read the methods"))
        #expect(first["notes"] == .string("Methods first") && first["status"] == .string("todo"))
        #expect(first["about"] == .object(["ref": .string("src:src-1")]))
        #expect(first["dueAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 5_000)))
        #expect(first["createdAt"] == SyncJSON(SyncTime.milliseconds(cocoaSeconds: 1_000)))
        #expect(first["resolvedAt"] == nil, "an open task has no resolution")
        let second = try #require(F.savedFields(pending["Task:task-2"]))
        #expect(second["kind"] == .string("assignment"))
        #expect(second["assignee"] == SyncPerson(user: "_member2", name: "Ana").value)
        #expect(second["status"] == .string("done") && second["resolvedAt"] != nil)
        #expect((first["orderKey"]?.stringValue ?? "") < (second["orderKey"]?.stringValue ?? ""), "the board's order")

        // Once sent, a later assignee does not turn the to-do into an assignment.
        try F.sendAll(store)
        try store.saveNotebookTask(Self.task("task-1", "Read the methods", sortOrder: 0, assignee: "_member3", sourceID: "src-1"))
        let after = try #require(F.savedFields(try F.pending(store)["Task:task-1"]))
        #expect(after["kind"] == .string("todo"))
        #expect(after["assignee"] == SyncPerson(user: "_member3", name: "Ana").value)
    }

    @Test("Moving a task on the board rekeys only that task")
    func reorderMovesOneKey() throws {
        let (root, store) = try Self.store("reorder")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try store.saveNotebookTask(Self.task("task-\(index)", "Task \(index)", sortOrder: Double(index)))
        }
        try F.sendAll(store)
        let keysBefore = try (0..<3).map { try F.text(store, "SELECT order_key FROM notebook_tasks WHERE id = 'task-\($0)'") }
        try store.saveNotebookTask(Self.task("task-0", "Task 0", sortOrder: 5))
        let pending = try F.pending(store)
        #expect(pending.keys.sorted() == ["Task:task-0"], "one record moves")
        let moved = try #require(F.savedFields(pending["Task:task-0"])?["orderKey"]?.stringValue)
        #expect(moved > (keysBefore[2] ?? ""), "after the last")
        #expect(try F.text(store, "SELECT order_key FROM notebook_tasks WHERE id = 'task-1'") == keysBefore[1])
    }

    @Test("A task from another device lands on the board in its key's place, and done records when")
    func inboundBoardTask() throws {
        let (root, store) = try Self.store("inbound")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveNotebookTask(Self.task("task-1", "Ours", sortOrder: 0))
        try F.sendAll(store)
        let ours = try #require(try F.text(store, "SELECT order_key FROM notebook_tasks WHERE id = 'task-1'"))
        let before = try FractionalIndex.key(between: nil, and: ours)
        try F.apply(store, [try F.record(.task, "task-web", [
            "kind": .string("todo"), "notebookID": .string("nb-1"), "title": .string("From the web"), "notes": .string(""),
            "status": .string("done"), "orderKey": .string(before), "about": .object(["ref": .string("art:doc-1")]),
            "createdAt": SyncJSON(Int64(1_759_000_000_000)), "resolvedAt": SyncJSON(Int64(1_759_100_000_000)),
        ])])
        let web = try #require(try store.loadNotebookTask("task-web"))
        #expect(web.title == "From the web" && web.status == .done && web.artifactID == "doc-1")
        #expect(web.completedAt == SyncTime.date(milliseconds: 1_759_100_000_000))
        #expect(try store.loadNotebookTasks(notebookID: "nb-1").map(\.id) == ["task-web", "task-1"], "generation 1's board reads the key's order")
        #expect(try F.pending(store).isEmpty, "an applied record sends nothing back")
    }

    @Test("A meeting's action item is a Task of its series, with its owner and due hint as notes, both ways")
    func actionItems() throws {
        let (root, store) = try Self.store("action")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = MeetingActionItem(groupID: "group-1", sourceID: "meeting-1", position: 2, text: "Send the slides", owner: "Ana",
                                     dueHint: "Friday", createdAt: Date(timeIntervalSinceReferenceDate: 1_000))
        try store.saveMeetingActionItems([item], groupID: "group-1", sourceID: "meeting-1")
        let fields = try #require(F.savedFields(try F.pending(store)["Task:meeting-1#2"]))
        #expect(fields["kind"] == .string("actionItem") && fields["title"] == .string("Send the slides"))
        #expect(fields["notes"] == .string("Owner: Ana\nDue: Friday"))
        #expect(fields["about"] == .object(["ref": .string("col:group-1")]))
        #expect(fields["meetingSourceID"] == .string("meeting-1") && fields["status"] == .string("todo"))
        #expect(fields["orderKey"] == SourceOrderKeys.key(forIndex: 2).map(SyncJSON.string))

        try F.apply(store, [try F.record(.task, "meeting-2#1", [
            "kind": .string("actionItem"), "title": .string("Book the room"), "notes": .string("Owner: Ben"),
            "about": .object(["ref": .string("col:group-1")]), "meetingSourceID": .string("meeting-2"),
            "status": .string("done"), "resolvedAt": SyncJSON(Int64(1_759_100_000_000)),
            "orderKey": SourceOrderKeys.key(forIndex: 1).map(SyncJSON.string) ?? .null, "createdAt": SyncJSON(Int64(1_759_000_000_000)),
        ])])
        let arrived = try #require(try store.loadMeetingActionItem("meeting-2#1"))
        #expect(arrived.groupID == "group-1" && arrived.sourceID == "meeting-2" && arrived.position == 1)
        #expect(arrived.owner == "Ben" && arrived.dueHint == nil && arrived.doneAt == SyncTime.date(milliseconds: 1_759_100_000_000))
    }

    @Test("A team's task and share request wait for their space; a share request encodes its address, requester and status")
    func teamRowsWaitForTheirSpace() throws {
        let (root, store) = try Self.store("team")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.execute("""
            INSERT INTO teams (id, name, role, permission, zone_scope, zone_name, created_at, joined_at, updated_at)
            VALUES ('team-1', 'Lab', 'owner', 'readWrite', 'private', 'Team-team-1', 1, 1, 1)
        """)
        try store.execute("UPDATE learning_goals SET team_id = 'team-1' WHERE id = 'nb-1'")
        try store.saveNotebookTask(Self.task("task-team", "Team task", sortOrder: 0))
        try store.saveShareRequest(ShareRequestRecord(
            id: "req-1", teamID: "team-1", url: "https://example.org/paper", title: nil, artifactID: "doc-1",
            requestedByRecordName: "_member2", requestedByDisplayName: "Ana", status: .open,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000), updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        ))
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_identity WHERE zone_key = 'private/Space-team-1' AND record_type = 'Task'") == 2)
        #expect(try F.pending(store).keys.filter { $0.hasPrefix("Task:") }.isEmpty, "nothing of the team's goes into the personal library")

        let rows = try #require(try TaskProjection().loadRows(
            ProjectionRecordRef(zoneKey: "private/Space-team-1", zone: .library, type: .task, wireID: "req-1", localID: "req-1"),
            connection: store
        ))
        let fields = TaskProjection.encodeRows(rows)
        #expect(fields["kind"] == .string("shareRequest") && fields["status"] == .string("todo"))
        #expect(fields["title"] == .string("https://example.org/paper"))
        #expect(fields["about"] == .object(["url": .string("https://example.org/paper"), "ref": .string("art:doc-1")]))
        #expect(fields["requester"] == SyncPerson(user: "_member2", name: "Ana").value)
    }

    @Test("A task deleted here deletes its record; one deleted elsewhere leaves the board")
    func deletes() throws {
        let (root, store) = try Self.store("delete")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.saveNotebookTask(Self.task("task-1", "Ours", sortOrder: 0))
        try store.saveNotebookTask(Self.task("task-2", "Theirs", sortOrder: 1))
        try F.sendAll(store)
        try store.deleteNotebookTask("task-1")
        let change = try #require(try F.pending(store)["Task:task-1"])
        #expect(change.action == .delete)

        try store.replica.apply { replica in
            let projections = ProjectionApply(store: store, registry: F.registry)
            let held = try #require(try replica.record(zoneKey: F.libraryZoneKey, recordType: "Task", wireID: "task-2"))
            try replica.deleteRecord(zoneKey: F.libraryZoneKey, recordName: held.recordName)
            try projections.projectDeletion(zoneKey: F.libraryZoneKey, recordName: held.recordName, type: .task, wireID: "task-2")
        }
        #expect(try store.loadNotebookTask("task-2") == nil)
        #expect(try F.pending(store)["Task:task-2"] == nil, "an inbound delete sends nothing back")
    }
}
