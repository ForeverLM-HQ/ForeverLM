import Foundation
import Testing
@testable import ForeverLM

/// A client that does not hold a Source writes only create-safe fields (docs/cloudkit-schema-design.md
/// §5.4): a provisional title, type and address (millisecond 1), `ingest [0, 1]` (X), keys that only add.
/// Whichever reaches the server first, a ready source stays ready and keeps its real values, and the
/// Mac that ingests a skeleton it received sends values that beat it.
@Suite("Skeletal import")
struct SkeletalImportTests {
    private typealias Fixture = SourceSyncFixture

    private static let id = SourceIdentity.stableID(for: "https://example.org/paper")
    private static let saltID = OutboxTestProjections.saltID

    /// The phone's skeleton of the paper, shared from Safari.
    private static func skeleton() throws -> SyncEnvelope {
        let patch = SourceSkeleton.patch(
            id: id, primaryKey: "url:example.org/paper", workKeys: ["url:example.org/paper", "doi:10.1000/xyz"],
            title: "example.org", type: "article", url: "https://example.org/paper",
            madeBy: MadeBy(route: "share", device: "phoneaaa", at: 1_759_500_000_000), addedAt: 1_759_500_000_000
        )
        var counter = 0
        return try SourceSkeleton.envelope(patch, saltID: saltID, deviceID: "phoneaaa") { _, policy in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: 1_759_500_000_000, counter: counter, deviceID: "phoneaaa")
        }
    }

    /// The Mac's ready paper, ingested earlier.
    private static func ready() throws -> SyncEnvelope {
        var envelope = SyncEnvelope.new(.source, id: id, saltID: saltID)
        var patch = RecordPatch(.source, id: id)
        patch.changes = [
            "primaryKey": .value("url:example.org/paper"),
            "workKeys": .elements(["url:example.org/paper": true]),
            "title": .value("A real title"), "type": .value("paper"), "url": .value("https://example.org/paper"),
            "status": .value("active"),
            "ingest": .value(.object(["ord": .array([0, 4]), "state": "ready"])),
            "madeBy": .value(MadeBy(route: "app", device: "macaaaaa", at: 1_759_400_000_000).value),
            "addedAt": .value(SyncJSON(Int64(1_759_400_000_000))),
        ]
        var counter = 0
        try envelope.apply(patch) { _, policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: 1_759_400_000_000, counter: counter, deviceID: "macaaaaa")
        }
        return envelope
    }

    @Test("The skeleton's stamps: provisional title, type and address; ingest at [0, 1]")
    func skeletonShape() throws {
        let skeleton = try Self.skeleton()
        for field in ["title", "type", "url"] {
            guard case .value(let stamp)? = skeleton.stamps[field] else { Issue.record("\(field) has no stamp"); continue }
            #expect(stamp.milliseconds == 1, "\(field)")
        }
        #expect(skeleton.fields["ingest"]?["ord"] == .array([0, 1]))
        #expect(skeleton.fields["ingest"]?["state"] == "queued")
        #expect(skeleton.fields["summary"] == nil && skeleton.fields["files"] == nil, "nothing a client without the record cannot know")
    }

    @Test("A skeleton sent after the source is ready never overwrites it; its new key is added")
    func skeletonAfterReady() throws {
        let merged = FieldMerge.merge(server: try Self.ready(), local: try Self.skeleton(), base: nil).merged
        #expect(merged.fields["title"] == "A real title")
        #expect(merged.fields["type"] == "paper")
        #expect(merged.fields["ingest"]?["state"] == "ready")
        #expect(merged.fields["ingest"]?["ord"] == .array([0, 4]))
        #expect(merged.fields["madeBy"]?["route"] == "app", "the first write stands")
        #expect(merged.fields["addedAt"] == SyncJSON(Int64(1_759_400_000_000)), "the earlier date added stands")
        #expect(merged.fields["workKeys"]?["doi:10.1000/xyz"] == true, "keys only add")
    }

    @Test("A ready source sent after a skeleton replaces every provisional value")
    func readyAfterSkeleton() throws {
        let merged = FieldMerge.merge(server: try Self.skeleton(), local: try Self.ready(), base: nil).merged
        #expect(merged.fields["title"] == "A real title")
        #expect(merged.fields["type"] == "paper")
        #expect(merged.fields["ingest"]?["state"] == "ready")
        #expect(merged.fields["madeBy"]?["route"] == "share", "the first acknowledged write stands")
        #expect(merged.fields["workKeys"]?["doi:10.1000/xyz"] == true)
    }

    @Test("On the Mac a ready source stays ready when the merged record arrives")
    func macKeepsItsReadySource() throws {
        let (root, store) = try Fixture.makeStore("skeleton-mac")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let merged = FieldMerge.merge(server: try Self.ready(), local: try Self.skeleton(), base: nil).merged
        let record = ReplicaRecord(
            zoneKey: Fixture.catalogZoneKey, recordName: RecordNaming.recordName(type: .source, id: Self.id, salt: Fixture.salt),
            recordType: SyncRecordType.source.rawValue, wireID: Self.id, systemFields: Data([1]), payload: try merged.storedPayload(), seenPass: nil
        )
        try Fixture.apply(store, [record])
        #expect(try Fixture.text(store, "SELECT state || '|' || source_type FROM sources WHERE id = ?", [.text(Self.id)]) == "ready|paper")
        #expect(try Fixture.text(store, "SELECT title FROM papers WHERE source_id = ?", [.text(Self.id)]) == "A real title")
        #expect(try Fixture.count(store, "SELECT COUNT(*) FROM ck_outbox_fields") == 0, "an apply sends nothing back")
    }

    @Test("The Mac that ingests a skeleton it received sends a real title and a ready ingest, which beat it")
    func macIngestsASkeleton() throws {
        let (root, store) = try Fixture.makeStore("skeleton-ingest")
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixture.prepareReplica(store)
        let skeleton = try Self.skeleton()
        let record = ReplicaRecord(
            zoneKey: Fixture.catalogZoneKey, recordName: RecordNaming.recordName(type: .source, id: Self.id, salt: Fixture.salt),
            recordType: SyncRecordType.source.rawValue, wireID: Self.id, systemFields: Data([1]), payload: try skeleton.storedPayload(), seenPass: nil
        )
        try Fixture.apply(store, [record])
        #expect(try Fixture.text(store, "SELECT state FROM sources WHERE id = ?", [.text(Self.id)]) == "queued")

        // The Mac fetches it: a real title, its text, ready.
        try store.execForTesting("""
            UPDATE articles SET title = 'A real title' WHERE source_id = '\(Self.id)';
            INSERT INTO source_content (source_id, content) VALUES ('\(Self.id)', 'The text.');
            UPDATE sources SET state = 'ready' WHERE id = '\(Self.id)';
        """)
        let change = try Fixture.pending(store)["Source:\(Self.id)"]
        let fields = try #require(Fixture.savedFields(change))
        #expect(fields["title"] == "A real title")
        #expect(fields["ingest"]?["state"] == "ready")
        let stamp = try #require(change?.stamps[StampedPath("title")])
        #expect(stamp.milliseconds > 1, "a real stamp beats the provisional one")
        guard case .save(let envelope)? = change?.action else { Issue.record("not a save"); return }
        let merged = FieldMerge.merge(server: skeleton, local: envelope, base: skeleton).merged
        #expect(merged.fields["title"] == "A real title")
        #expect(merged.fields["ingest"]?["state"] == "ready")
    }
}
