import Foundation
import Testing
@testable import ForeverLM

/// The Mac's `ck_patches` rows as changes the engine sends (docs/cloudkit-schema-design.md §6.6, WP16b): the
/// outbox feeder never sent them, so late import's patches would have gone nowhere. A patch is laid over the
/// record's outbox change field by field by stamp, and an acknowledgement takes exactly the paths a save carried.
@Suite("Mac patch outbox")
struct MacPatchOutboxTests {
    private typealias N = NotebookSyncFixture

    private static func stamp(_ policy: SyncPolicy, _ ms: Int64, _ device: String = SyncIdentity.legacyDeviceID) -> SyncStamp {
        SyncStamp(policy: policy, milliseconds: ms, counter: 0, deviceID: device)
    }

    private static func patch(_ fields: [String: (SyncJSON, SyncStamp)]) -> PendingPatch {
        PendingPatch(
            changes: fields.mapValues(\.0), stamps: fields.mapValues { .value($0.1) },
            zoneKey: N.libraryZoneKey, type: SyncRecordType.notebook.rawValue, wireID: "nb-1"
        )
    }

    private static func change(title: String, ms: Int64) -> OutboxChange {
        var envelope = SyncEnvelope.new(.notebook, id: "nb-1", saltID: OutboxTestProjections.saltID)
        envelope.fields["title"] = .string(title)
        envelope.stamps["title"] = .value(stamp(.lastWriter, ms, "macaaaaa"))
        return OutboxChange(
            zoneKey: N.libraryZoneKey, zone: .library, recordType: .notebook, wireID: "nb-1", recordName: "nb_x", systemFields: nil,
            action: .save(envelope), priority: .structure, stamps: [StampedPath("title"): stamp(.lastWriter, ms, "macaaaaa")], mintedAgainst: [:], rows: []
        )
    }

    @Test("A patch is laid over the outbox's change for the same record where its stamp is later, and loses where it is earlier")
    func laidByStamp() throws {
        let later = Self.patch(["title": (.string("old world"), Self.stamp(.lastWriter, 9_000))])
        let merged = try #require(MacPatchOutbox.lay(later, over: Self.change(title: "mine", ms: 5_000)))
        guard case .save(let envelope) = merged.action else { Issue.record("not a save"); return }
        #expect(envelope.fields["title"] == .string("old world") && merged.stamps[StampedPath("title")]?.milliseconds == 9_000)

        let earlier = Self.patch(["title": (.string("old world"), Self.stamp(.lastWriter, 1_000))])
        let kept = try #require(MacPatchOutbox.lay(earlier, over: Self.change(title: "mine", ms: 5_000)))
        guard case .save(let held) = kept.action else { Issue.record("not a save"); return }
        #expect(held.fields["title"] == .string("mine") && kept.stamps[StampedPath("title")]?.deviceID == "macaaaaa", "the Mac's own later edit is sent")
    }

    @Test("A patch stamped earlier than the envelope's own stamp does not override it when applied")
    func appliedKeepsALaterStamp() {
        var envelope = SyncEnvelope.new(.notebook, id: "nb-1", saltID: OutboxTestProjections.saltID)
        envelope.fields["title"] = .string("mine")
        envelope.stamps["title"] = .value(Self.stamp(.lastWriter, 5_000, "macaaaaa"))
        let earlier = Self.patch(["title": (.string("old world"), Self.stamp(.lastWriter, 1_000))])
        #expect(earlier.applied(to: envelope).fields["title"] == .string("mine"))
        let later = Self.patch(["title": (.string("old world"), Self.stamp(.lastWriter, 9_000))])
        #expect(later.applied(to: envelope).fields["title"] == .string("old world"))
    }

    @Test("A due patch is sent as a save on the replica's version, and the acknowledgement takes only the paths it carried")
    func sentAndSettled() throws {
        let (root, store) = try N.makeStore("patch-outbox")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        try N.apply(store, [try N.record(.notebook, "nb-1", ["title": "Held", "status": "active"])])

        var patch = Self.patch([
            "title": (.string("Patched"), Self.stamp(.lastWriter, 1_759_500_000_000)),
            "summary": (.string("Added"), Self.stamp(.lastWriter, 1_759_500_000_000)),
        ])
        try patch.save(in: store, now: Date().addingTimeInterval(-60))

        let outbox = MacPatchOutbox(connection: store)
        let changes = try outbox.changes(now: Date(), limit: 10, scope: .all, alongside: [])
        let sent = try #require(changes.first { $0.wireID == "nb-1" })
        guard case .save(let envelope) = sent.action else { Issue.record("not a save"); return }
        #expect(envelope.fields["title"] == .string("Patched") && envelope.fields["status"] == .string("active"), "the replica's version with the patch over it")
        #expect(sent.systemFields != nil, "sent on the replica's change tag")

        // A patch folded in while the save was out survives its acknowledgement.
        patch.changes["summary"] = .string("Written again")
        patch.stamps["summary"] = .value(Self.stamp(.lastWriter, 1_759_600_000_000))
        try patch.save(in: store, now: Date())
        try MacPatchOutbox.settle(sent, in: store)
        let left = try #require(try PendingPatch.load(zoneKey: N.libraryZoneKey, type: "Notebook", wireID: "nb-1", in: store))
        #expect(left.changes["title"] == nil && left.changes["summary"] == .string("Written again"))

        let final = try #require(try outbox.changes(now: Date().addingTimeInterval(60), limit: 10, scope: .all, alongside: []).first)
        try MacPatchOutbox.settle(final, in: store)
        #expect(try PendingPatch.load(zoneKey: N.libraryZoneKey, type: "Notebook", wireID: "nb-1", in: store) == nil, "the row goes when nothing is left")
    }

    @Test("A patch waits while a delete of its record is on its way, and a patch out of scope is not handed to the wrong engine")
    func waitsAndScopes() throws {
        let (root, store) = try N.makeStore("patch-outbox-wait")
        defer { try? FileManager.default.removeItem(at: root) }
        try N.prepareReplica(store)
        let record = try N.record(.notebook, "nb-1", ["title": "Held"])
        try N.apply(store, [record])
        try Self.patch(["title": (.string("Patched"), Self.stamp(.lastWriter, 1_759_500_000_000))]).save(in: store, now: Date().addingTimeInterval(-60))

        let outbox = MacPatchOutbox(connection: store)
        #expect(try outbox.changes(now: Date(), limit: 10, scope: .spaces, alongside: []).isEmpty, "a private zone's patch is not a space's")
        try store.execute(
            "INSERT INTO ck_pending_deletes (zone_key, record_name, record_type, wire_id, deleted_at) VALUES (?, ?, 'Notebook', 'nb-1', 1)",
            [.text(N.libraryZoneKey), .text(record.recordName)]
        )
        #expect(try outbox.changes(now: Date(), limit: 10, scope: .all, alongside: []).isEmpty, "the delete goes first")
    }
}
