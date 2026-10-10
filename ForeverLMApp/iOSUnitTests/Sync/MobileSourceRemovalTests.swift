import Foundation
import Testing
@testable import ForeverLM

/// Archiving and deleting a source, and saving a walkthrough, from the phone under generation 2
/// (docs/cloudkit-schema-design.md §5.4, D18; §14.2 WP20b): the changes WP20 left refused.
@Suite("iPhone source removal", .serialized)
struct MobileSourceRemovalTests {
    typealias Fixture = MobileWriterFixture

    static func library() async throws -> MobileReplica {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileReadModelFixture.notebook("nb1", "Cells", edited: 1)),
            (Fixture.library, try MobileReadModelFixture.entry("nb1", "source", "srcA", order: "a0")),
            (Fixture.library, try MobileSyncFixture.envelope(.placement, "pl:srcA", [
                "sourceID": "srcA", "state": "active", "day": "2027-01-15", "addedAt": 1,
            ])),
            (Fixture.library, try MobileSyncFixture.envelope(.highlight, "h1", ["sourceID": "srcA", "createdAt": 1])),
            (Fixture.catalog, try MobileReadModelFixture.source("srcA", "Membranes", added: 1, ["url": "https://example.org/a"])),
            (Fixture.catalog, try MobileReadModelFixture.source("srcX", "Explainer", added: 2, type: "article")),
            (Fixture.space, try MobileReadModelFixture.source("srcS", "Team paper", added: 3)),
        ])
        return replica
    }

    @Test("Archiving leaves every notebook and the Schedule, dismisses the source and archives it; highlights and history stay")
    func archive() async throws {
        let replica = try await Self.library()
        let writer = Fixture.writer(replica)
        try await writer.transaction { try $0.archiveSource("srcA") }
        #expect(try await Fixture.held(replica, .entry, "en:nb1:source:srcA", in: Fixture.library)?.fields["state"] == .string("removed"))
        #expect(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library)?.fields["state"] == .string("removed"))
        let mark = try #require(try await Fixture.held(replica, .mark, "mk:dismissed:wk:url:example.org/a", in: Fixture.library))
        #expect(mark.fields["on"] == .bool(true))
        #expect(mark.fields["value"] == .object(["url": "https://example.org/a", "title": "Membranes"]))
        #expect(try await Fixture.held(replica, .source, "srcA", in: Fixture.catalog)?.fields["status"] == .string("archived"))
        #expect(try await Fixture.held(replica, .highlight, "h1", in: Fixture.library) != nil)

        try await writer.transaction { try $0.archiveSource("srcS") }
        #expect(try await Fixture.held(replica, .source, "srcS", in: Fixture.space)?.fields["status"] == .string("archived"), "a space's copy is archived for the space")
        #expect(try await Fixture.held(replica, .mark, "mk:dismissed:src:srcS", in: Fixture.library) == nil)
        #expect(try await Fixture.held(replica, .mark, "mk:dismissed:src:srcA", in: Fixture.library) == nil, "a dismissal is never keyed by the source's id")
    }

    @Test("Deleting deletes the Source and its explainer and flips the Placement; Entries, highlights and per-member state are never written")
    func delete() async throws {
        let replica = try await Self.library()
        let writer = Fixture.writer(replica)
        let entry = try await Fixture.held(replica, .entry, "en:nb1:source:srcA", in: Fixture.library)
        try await writer.transaction { try $0.deleteSource("srcA", explainerID: "srcX") }
        #expect(try await writer.read { try $0.held(.source, "srcA", in: Fixture.catalog) } == nil, "gone from what the phone holds")
        #expect(try await writer.read { try $0.held(.source, "srcX", in: Fixture.catalog) } == nil)
        #expect(try await replica.read { try $0.connection.scalarInteger("SELECT COUNT(*) FROM m_sources WHERE id IN ('srcA', 'srcX')") } == 0)
        let deletes = try await Fixture.changes(replica).filter { $0.action == .delete }.map(\.wireID).sorted()
        #expect(deletes == ["srcA", "srcX"])
        // A satellite lookup, the projection's own read and a read of the raw record see the same: gone until the delete is acknowledged.
        #expect(try await MobileProjection(replica: replica).envelope(.source, id: "srcA", zoneKey: Fixture.catalog) == nil)
        #expect(try await Fixture.held(replica, .source, "srcA", in: Fixture.catalog) == nil)
        #expect(try await Fixture.held(replica, .source, "srcS", in: Fixture.space) != nil, "a record the phone did not delete is still held")
        #expect(try await Fixture.held(replica, .placement, "pl:srcA", in: Fixture.library)?.fields["state"] == .string("removed"))
        #expect(try await Fixture.held(replica, .entry, "en:nb1:source:srcA", in: Fixture.library) == entry)
        #expect(try await Fixture.held(replica, .highlight, "h1", in: Fixture.library) != nil)
        await #expect(throws: MobileRecordWriterError.self) { try await writer.transaction { try $0.deleteSource("srcS", explainerID: nil) } }
    }

    @Test("A walkthrough the phone wrote is its source's walkthrough satellite, uploaded first, gen.input its text's hash")
    func walkthrough() async throws {
        let (server, phone, writer) = try await MobileSittingRecorderTests.phoneWithBlobs()
        let walk = PaperWalkthrough(sourceID: "src1", sourceSHA256: "sha-of-text", title: "Walk",
                                    steps: [PaperWalkthroughStep(id: "s1", kind: .explain, title: "Setup", body: "Cells keep sodium low.")], author: .app)
        try await writer.saveWalkthrough(walk)
        let source = try #require(try await Fixture.held(phone.replica, .source, "src1", in: Fixture.catalog))
        let file = try #require(source.fields["derived"]?["walkthrough"].flatMap(FileRef.init(json:)))
        #expect(file.value["gen"]?["input"] == .string("sha-of-text"))
        #expect(file.hash == SyncIdentity.sha256Hex(Data(try PaperWalkthroughCoding.json(walk).utf8)))
        let content = SyncIdentity.contentID(owner: "src1", role: "walkthrough", partHash32: try #require(file.parts.first))
        #expect(server.storedRecord(RecordNaming.recordName(type: .content, id: content, salt: MobileSyncFixture.librarySalt), zone: "Content",
                                    owner: MobileReplicaTests.alice) != nil)
        await #expect(throws: MobileRecordWriterError.self) {
            try await writer.saveWalkthrough(PaperWalkthrough(sourceID: "not-held", sourceSHA256: "s", title: "W", steps: [], author: .app))
        }
    }
}
