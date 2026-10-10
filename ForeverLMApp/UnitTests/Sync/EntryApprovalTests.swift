import Foundation
import Testing
@testable import ForeverLM

/// Bug b2 by construction (docs/cloudkit-schema-design.md D15, §3.5.8, §6.3): approval is shared
/// state on the Entry and travels, including into a space; nothing per member is on the record; each
/// field keeps its own event time, so an offline re-add is never re-dated by a later reorder; and a
/// remove and a re-add are one record.
@Suite("Entry approval")
struct EntryApprovalTests {
    typealias F = NotebookSyncFixture

    @Test("No Entry field is per member, and a space takes an Entry's approval as it is")
    func approvalTravels() throws {
        #expect(SyncRecordType.entry.spec.fields.allSatisfy { !$0.isMemberLocal })
        #expect(!SyncRecordType.entry.spec.isPrivateOnly)
        let rows = EntryRows.poolItem(EntryRows.PoolItem(
            containerKind: LearningGoalEntityKind.notebook, containerID: "nb-1", sourceID: "src-a", addedAt: 10, origin: "discovered",
            reviewState: "pending", relevance: 0.75, orderKey: "a3"
        ))
        let fields = EntryProjection.encodeRows(rows)
        #expect(fields["approval"] == .string("pending"))
        let member = SpaceWriteGuard.Writer(user: "_member", permission: .readWrite, isOwner: false)
        #expect(SpaceWriteGuard.refusals(writing: "Entry", fields: fields, by: member).isEmpty, "approval is shared editorial state")

        // Written into a space zone and read back, approval is the space's for every member.
        let space = "private/Space-team1"
        let record = try F.record(.entry, SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a"), fields, zoneKey: space)
        let envelope = try SyncEnvelope(storedPayload: record.payload)
        #expect(envelope.fields["approval"] == .string("pending"))
        #expect(SyncNotebookChatContext.Entry(envelope)?.isInContext == false, "a pending suggestion is in no member's context")
    }

    @Test("Approving a suggestion sends approval alone, and another Mac's projection takes it")
    func approvalRoundTrip() throws {
        let (root, store) = try F.makeStore("b2-approve")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1", reviewState: "pending", origin: "discovered")
        try F.sendAll(store)
        let entryID = SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a")
        try store.execute("UPDATE learning_goal_items SET review_state = 'approved' WHERE goal_id = 'nb-1' AND source_id = 'src-a'")
        let change = try #require(try F.pending(store)["Entry:\(entryID)"])
        #expect(Set(change.stamps.keys.map(\.field)) == ["approval"])
        try F.sendAll(store)
        let held = try #require(try F.held(store, .entry, entryID))

        let (otherRoot, other) = try F.makeStore("b2-approve-other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try F.prepareReplica(other)
        try F.apply(other, [try F.record(.notebook, "nb-1", ["title": .string("Mito"), "status": .string("active")])])
        try F.apply(other, [try F.record(.entry, entryID, held.fields)])
        #expect(try F.text(other, "SELECT review_state FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = 'src-a'") == "approved")
        #expect(try F.pending(other).isEmpty)
        // A later rejection lands on the row this Mac holds.
        var rejected = held.fields
        rejected["approval"] = .string("rejected")
        try F.apply(other, [try F.record(.entry, entryID, rejected, ms: 1_900_000_000_000)])
        #expect(try F.text(other, "SELECT review_state FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = 'src-a'") == "rejected")
    }

    @Test("A re-add at t0, a remote remove at t1, a local reorder at t2: the remove wins and the order stays")
    func offlineReAddLosesToLaterRemove() throws {
        let (root, store) = try F.makeStore("b2-t0t1t2")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.addSource(store, "src-b")
        try F.file(store, "src-a", into: "nb-1")
        try F.file(store, "src-b", into: "nb-1")
        try F.sendAll(store)
        let entryID = SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a")
        // Removed and sent; then, offline, re-added at t0 and moved to the end at t2.
        try store.execute("DELETE FROM learning_goal_items WHERE goal_id = 'nb-1' AND source_id = 'src-a'")
        try F.sendAll(store)
        // Later than the removal's acknowledgement, which every later stamp of the path passes.
        let t0 = Date().timeIntervalSinceReferenceDate + 100, t2 = t0 + 20
        try F.file(store, "src-a", into: "nb-1")
        try store.execute("UPDATE ck_outbox_fields SET dirty_at = ? WHERE source_table = 'learning_goal_items'", [.real(t0)])
        let lastKey = try #require(try F.text(store, "SELECT MAX(order_key) FROM learning_goal_items WHERE goal_id = 'nb-1'"))
        let movedKey = try FractionalIndex.key(between: lastKey, and: nil)
        try store.execute("UPDATE learning_goal_items SET order_key = ? WHERE goal_id = 'nb-1' AND source_id = 'src-a'", [.text(movedKey)])
        try store.execute("UPDATE ck_outbox_fields SET dirty_at = ? WHERE source_table = 'learning_goal_items' AND column = 'order_key'", [.real(t2)])

        let change = try #require(try F.pending(store)["Entry:\(entryID)"])
        guard case .save(let local) = change.action else { Issue.record("expected a save"); return }
        let stateStamp = try #require(change.stamps[StampedPath("state")])
        let orderStamp = try #require(change.stamps[StampedPath("orderKey")])
        #expect(stateStamp.milliseconds == SyncTime.milliseconds(cocoaSeconds: t0), "the re-add keeps its own time")
        #expect(orderStamp.milliseconds == SyncTime.milliseconds(cocoaSeconds: t2))

        // The other device removed it at t1, between the two.
        let t1 = SyncTime.milliseconds(cocoaSeconds: t0 + 10)
        let held = try #require(try F.held(store, .entry, entryID))
        var server = held
        server.fields["state"] = .string("removed")
        server.stamps["state"] = .value(SyncStamp(policy: .lastWriter, milliseconds: t1, counter: 0, deviceID: "otheraaa"))
        let merged = FieldMerge.merge(server: server, local: local, base: held, mintedAgainst: change.mintedAgainst).merged
        #expect(merged.fields["state"] == .string("removed"), "the remote remove wins over the earlier re-add")
        #expect(merged.fields["orderKey"] == .string(movedKey), "the later reorder still lands")
    }

    @Test("A remove and a re-add, two row ids, send one Entry")
    func removeAndReAddCoalesce() throws {
        let (root, store) = try F.makeStore("b2-coalesce")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        try F.sendAll(store)
        let firstRowID = try #require(try F.text(store, "SELECT id FROM learning_goal_items WHERE source_id = 'src-a'"))
        try store.execute("DELETE FROM learning_goal_items WHERE source_id = 'src-a'")
        // Added back as a suggestion, so the record has something to send.
        try F.file(store, "src-a", into: "nb-1", reviewState: "pending", origin: "discovered")
        let secondRowID = try #require(try F.text(store, "SELECT id FROM learning_goal_items WHERE source_id = 'src-a'"))
        #expect(firstRowID != secondRowID)
        let changes = try OutboxFeeder(connection: store, registry: F.registry).pendingChanges(now: Date().addingTimeInterval(60))
        let entryID = SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a")
        let entries = changes.filter { $0.recordType == .entry && $0.wireID == entryID }
        #expect(entries.count == 1)
        let keys = Set(entries.first?.rows.map(\.localKey) ?? [])
        #expect(keys.contains(secondRowID) && keys.contains { $0.hasPrefix(firstRowID) }, "both rows are acknowledged together")
        #expect(F.savedFields(entries.first)?["state"] == .string("active"))
        #expect(F.savedFields(entries.first)?["approval"] == .string("pending"))
    }

    @Test("A reorder moves one key, so it sends one Entry; an inbound order rewrites the study order")
    func reorderSendsOne() throws {
        let (root, store) = try F.makeStore("b2-reorder")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        for id in ["src-a", "src-b", "src-c", "src-d"] {
            try F.addSource(store, id)
            try F.file(store, id, into: "nb-1")
        }
        try F.sendAll(store)
        // The app's reorder writes `sequence`; the last source moves to the front.
        for (index, id) in ["src-d", "src-a", "src-b", "src-c"].enumerated() {
            try store.execute("UPDATE learning_goal_items SET sequence = ? WHERE source_id = ?", [.real(Double(index)), .text(id)])
        }
        try store.keepNotebookRowsForGeneration2(goalIDs: ["nb-1"])
        let entries = try F.pending(store).values.filter { $0.recordType == .entry }
        #expect(entries.map(\.wireID) == [SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-d")])
        try F.sendAll(store)
        var keyed: [String] = []
        try store.query("SELECT source_id FROM learning_goal_items WHERE goal_id = 'nb-1' ORDER BY order_key", []) { keyed.append($0.text(0) ?? "") }
        #expect(keyed == ["src-d", "src-a", "src-b", "src-c"])

        // Another device moves src-c to the front: this Mac's study order follows.
        let held = try #require(try F.held(store, .entry, SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-d")))
        let front = try FractionalIndex.key(between: nil, and: held.fields["orderKey"]?.stringValue)
        try F.apply(store, [try F.entryRecord("nb-1", "src-c", orderKey: front, ms: 1_900_000_000_000)])
        var sequenced: [String] = []
        try store.query("""
            SELECT source_id FROM learning_goal_items WHERE goal_id = 'nb-1'
            ORDER BY (sequence IS NULL) ASC, sequence ASC, added_at ASC, source_id ASC
        """, []) { sequenced.append($0.text(0) ?? "") }
        #expect(sequenced == ["src-c", "src-d", "src-a", "src-b"])
        #expect(try F.pending(store).isEmpty, "the derived study order sends nothing back")
    }

    @Test("Under generation 1 an item is written without a key and nothing is queued")
    func generation1() throws {
        let (root, store) = try F.makeStore("b2-gen1", generation: .one)
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addNotebook(store, "nb-1", classify: false)
        try store.keepNotebookRowsForGeneration2(goalIDs: ["nb-1"])
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE order_key IS NOT NULL") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goals WHERE entity_kind IS NOT NULL") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_outbox_fields") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") == 0)
    }

    @Test("The generation-1 sequence is each row's rank in key order, and a derivation that changes nothing writes nothing")
    func sequenceIsTheRank() throws {
        let (root, store) = try F.makeStore("b2-sequence")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.addNotebook(store, "nb-1")
        let keys = (0..<400).map { String(format: "k%04d", ($0 * 7919) % 400) }
        try F.quietly(store) {
            for (index, key) in keys.enumerated() {
                try F.addSource(store, "src-\(index)")
                try store.execute("""
                    INSERT INTO learning_goal_items (id, goal_id, source_id, added_at, order_key) VALUES (?, 'nb-1', ?, 1, ?)
                """, [.text("item-\(index)"), .text("src-\(index)"), .text(key)])
            }
        }
        try EntryOrderKeys.deriveSequence(goalID: "nb-1", connection: store)
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE sequence = CAST(substr(order_key, 2) AS INTEGER)") == 400)
        let before = try F.count(store, "SELECT total_changes()")
        try EntryOrderKeys.deriveSequence(goalID: "nb-1", connection: store)
        #expect(try F.count(store, "SELECT total_changes()") == before, "no row is rewritten when its rank is already right")
    }
}
