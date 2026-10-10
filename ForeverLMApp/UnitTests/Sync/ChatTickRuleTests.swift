import Foundation
import Testing
@testable import ForeverLM

/// Bug b5 and a notebook's context under generation 2 (docs/cloudkit-schema-design.md D16, D52, §5.6):
/// an untick names the stamps of the Entry it is compared with, so a re-add or a re-approval from any
/// device ticks the source again with no write to the member's NotebookState; an untick of an unsent
/// add pins the stamp the add is sent with; and a listed notebook feeds a chat only once the member
/// ticks it, never a Studio maker.
@Suite("Chat-tick rule")
struct ChatTickRuleTests {
    typealias F = NotebookSyncFixture

    private static func notebookStateRows(_ store: KnowledgeStore) throws -> Int64 {
        try F.count(store, "SELECT COUNT(*) FROM ck_outbox_fields WHERE source_table = 'notebook_states'")
    }

    @Test("Untick, a re-add from a second device, and the source is ticked again with no NotebookState write")
    func reAddElsewhereTicks() throws {
        let (root, store) = try F.makeStore("b5-readd")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.addSource(store, "src-b")
        try F.file(store, "src-a", into: "nb-1")
        try F.file(store, "src-b", into: "nb-1")
        try F.sendAll(store)

        try store.setNotebookChatExclusions(notebookID: "nb-1", excluded: ["src-a"])
        #expect(try store.notebookStateSnapshot().excluded["nb-1"] == ["src-a"])
        let entryID = SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a")
        let held = try #require(try F.held(store, .entry, entryID))
        let pair = try #require(NotebookStateRow.load("nb-1", connection: store)?.excluded["src-a"])
        #expect(pair == (held.stamps["state"].flatMap { if case .value(let s) = $0 { return s.rawValue } else { return nil } } ?? "") + "|"
            + (held.stamps["approval"].flatMap { if case .value(let s) = $0 { return s.rawValue } else { return nil } } ?? "-"))
        try F.sendAll(store)
        let written = try F.held(store, .notebookState, "ns:nb-1")
        #expect(written?.fields["excluded"]?["src-a"] == .string(pair))

        // The phone removes it and adds it back: the Entry's state takes two new stamps.
        try F.apply(store, [try F.entryRecord("nb-1", "src-a", state: "removed", ms: 1_900_000_000_000, device: "phoneaaa")])
        try F.apply(store, [try F.entryRecord("nb-1", "src-a", state: "active", ms: 1_900_000_000_100, device: "phoneaaa")])
        #expect(try store.notebookStateSnapshot().excluded["nb-1"] == nil, "ticked again")
        #expect(try Self.notebookStateRows(store) == 0, "no write to the member's NotebookState")
        #expect(try F.pending(store)["NotebookState:ns:nb-1"] == nil)
        // A write that keeps everything else ticked leaves the stale pair alone, so it sends nothing.
        try store.setNotebookChatExclusions(notebookID: "nb-1", excluded: [])
        #expect(try F.pending(store)["NotebookState:ns:nb-1"] == nil)
    }

    @Test("A re-approval from another device ticks a source again too")
    func reApprovalTicks() throws {
        let (root, store) = try F.makeStore("b5-reapprove")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        try F.sendAll(store)
        try store.setNotebookChatExclusions(notebookID: "nb-1", excluded: ["src-a"])
        let held = try #require(try F.held(store, .entry, SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a")))
        var fields = held.fields
        fields["approval"] = .string("approved")
        try F.apply(store, [try F.record(.entry, held.id, fields, ms: 1_900_000_000_000, device: "webaaaaa")])
        #expect(try store.notebookStateSnapshot().excluded["nb-1"] == nil)
    }

    @Test("An offline add unticked before it is sent: the untick names the stamp the add is sent with")
    func offlineAddThenUntick() throws {
        let (root, store) = try F.makeStore("b5-offline")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try F.sendAll(store)
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        try store.setNotebookChatExclusions(notebookID: "nb-1", excluded: ["src-a"])
        let pair = try #require(NotebookStateRow.load("nb-1", connection: store)?.excluded["src-a"])
        #expect(pair != NotebookStateRow.pendingPair)
        #expect(try store.notebookStateSnapshot().excluded["nb-1"] == ["src-a"], "unticked before the add is sent")
        try F.sendAll(store)
        let entry = try #require(try F.held(store, .entry, SyncIdentity.entryID(containerID: "nb-1", itemKind: "source", itemID: "src-a")))
        guard case .value(let sent)? = entry.stamps["state"] else { Issue.record("no state stamp"); return }
        #expect(pair.hasPrefix(sent.rawValue + "|"), "the add went out with the pinned stamp")
        #expect(try store.notebookStateSnapshot().excluded["nb-1"] == ["src-a"], "and still matches after the send")
    }

    @Test("Without a server offset an untick waits for its stamp and holds the map back, then names it")
    func untickBeforeOffset() throws {
        let (root, store) = try F.makeStore("b5-noclock")
        defer { try? FileManager.default.removeItem(at: root) }
        try OutboxTestProjections.prepareReplica(store, clock: false)
        try F.addNotebook(store, "nb-1")
        try F.addSource(store, "src-a")
        try F.file(store, "src-a", into: "nb-1")
        try store.setNotebookChatExclusions(notebookID: "nb-1", excluded: ["src-a"])
        #expect(try NotebookStateRow.load("nb-1", connection: store)?.excluded["src-a"] == NotebookStateRow.pendingPair)
        #expect(try store.notebookStateSnapshot().excluded["nb-1"] == ["src-a"])
        let row = try #require(try NotebookStateRow.load("nb-1", connection: store))
        #expect(NotebookStateProjection.encodeRows(row)["excluded"] == nil)
        try OutboxFeeder(connection: store, registry: F.registry).saveClock(StampClock(deviceID: "macaaaaa", offsetSamples: [0]))
        try store.resolvePendingUnticks()
        let resolved = try #require(try NotebookStateRow.load("nb-1", connection: store)?.excluded["src-a"])
        #expect(resolved != NotebookStateRow.pendingPair)
        #expect(try store.notebookStateSnapshot().excluded["nb-1"] == ["src-a"])
    }

    @Test("A listed notebook feeds no chat until the member ticks it, and never the Studio")
    func contextNotebooks() throws {
        let (root, store) = try F.makeStore("d52-context")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-a", title: "A")
        try F.addNotebook(store, "nb-b", title: "B")
        for id in ["src-own", "src-ctx"] { try F.addSource(store, id) }
        try F.file(store, "src-own", into: "nb-a")
        try F.file(store, "src-ctx", into: "nb-b")
        try store.execute("INSERT INTO notebook_related_notebook_links (notebook_id, related_notebook_id, linked_at) VALUES ('nb-a', 'nb-b', 1)")
        try NotebookResolutionTable.refresh(store)

        var context = try store.notebookContextEntries("nb-a", row: nil)
        #expect(context.contextNotebookIDs.isEmpty, "linked is not ticked")
        #expect(Set(context.holders.keys) == ["src-own"])

        try store.setNotebookContextNotebooks(notebookID: "nb-a", contextNotebookIDs: ["nb-b"])
        context = try store.notebookContextEntries("nb-a", row: try NotebookStateRow.load("nb-a", connection: store))
        #expect(context.contextNotebookIDs == ["nb-b"])
        #expect(Set(context.holders.keys) == ["src-own", "src-ctx"], "a chat reads the ticked notebook's sources")
        #expect(try store.notebookStateSnapshot().contextNotebooks["nb-a"] == ["nb-b"])
        #expect(F.savedFields(try F.pending(store)["NotebookState:ns:nb-a"])?["contextNotebooks"] == .object(["nb-b": .bool(true)]))
        // A tick of a notebook that is not listed feeds nothing; one level deep only.
        try store.setNotebookContextNotebooks(notebookID: "nb-b", contextNotebookIDs: ["nb-a"])
        #expect(try store.notebookContextEntries("nb-b", row: try NotebookStateRow.load("nb-b", connection: store)).contextNotebookIDs.isEmpty)

        // Unticking a context notebook's source names that notebook's Entry.
        try F.sendAll(store)
        try store.setNotebookChatExclusions(notebookID: "nb-a", excluded: ["src-ctx"])
        #expect(try store.notebookStateSnapshot().excluded["nb-a"] == ["src-ctx"])
        // Filing it into nb-a itself ticks it again: its own Entry is now the one compared.
        try F.file(store, "src-ctx", into: "nb-a")
        #expect(try store.notebookStateSnapshot().excluded["nb-a"] == nil)
    }

    @Test("Collections are a set per member: two devices filing one notebook into two collections keep both")
    func collectionsMerge() throws {
        let (root, store) = try F.makeStore("nbc-merge")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try F.addNotebook(store, "nb-1")
        try store.setNotebookCollections(notebookID: "nb-1", collectionIDs: ["nbc-a"])
        try F.sendAll(store)
        // Another Mac filed it into nbc-b meanwhile; its record merges per element on the server.
        let held = try #require(try F.held(store, .notebookState, "ns:nb-1"))
        var merged = held
        merged.fields["collections"] = .object(["nbc-a": .bool(true), "nbc-b": .bool(true)])
        merged.stamps["collections"] = .elements([
            "nbc-a": (held.stamps["collections"].flatMap { if case .elements(let e) = $0 { return e["nbc-a"] } else { return nil } })!,
            "nbc-b": SyncStamp(policy: .lastWriter, milliseconds: 1_900_000_000_000, counter: 0, deviceID: "otheraaa"),
        ])
        try F.apply(store, [ReplicaRecord(
            zoneKey: F.libraryZoneKey, recordName: RecordNaming.recordName(type: .notebookState, id: "ns:nb-1", salt: F.salt),
            recordType: SyncRecordType.notebookState.rawValue, wireID: "ns:nb-1", systemFields: Data([2]),
            payload: try merged.storedPayload(), seenPass: nil
        )])
        #expect(try store.notebookStateSnapshot().collections["nb-1"] == ["nbc-a", "nbc-b"])
        #expect(try F.pending(store)["NotebookState:ns:nb-1"] == nil)
    }
}
