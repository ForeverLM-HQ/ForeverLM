import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// An explainer written on the phone (docs/cloudkit-schema-design.md §3.5.4, §3.5.30,
/// §5.4; explainer-design.md; §14.2 WP20c): the article-typed Source every client makes of it, in the
/// learner's `Catalog` under the id the Mac derives, its script the `files.text` satellite uploaded before
/// the pointer.
@Suite("iPhone explainer records", .serialized)
struct MobileExplainerRecordTests {
    typealias Fixture = MobileWriterFixture

    static let paper = MobileCloudSource(id: "src1", title: "Membrane potential", subtitle: nil, sourceType: "paper", dateAdded: Date(),
                                         hasAudio: false, isArchived: false, author: " A. Author ", url: "https://example.org/p")

    /// The seeded library on a synced phone whose writer uploads satellites to the fake server.
    static func phone() async throws -> (server: FakeCloudKit, phone: MobileTestDevice, writer: MobileRecordWriter) {
        let server = try MobileReplicaTests.seededLibrary()
        let phone = try await MobileReplicaTests.phone(server)
        try await phone.sync()
        var pacing = SyncPacerState.Configuration()
        pacing.capacity = 1_000_000
        pacing.refillPerSecond = 1_000_000
        let pacer = SyncPacer(configuration: pacing)
        let blobs = BlobStore(transport: phone.transport, store: phone.replica, deviceID: phone.deviceID, pacer: { _ in pacer })
        return (server, phone, MobileRecordWriter(replica: phone.replica, deviceID: phone.deviceID, blobs: blobs, clock: { Date().addingTimeInterval(-60) }))
    }

    @Test("An explainer is the Source the Mac writes, in Catalog under the Mac's id, its script the text satellite uploaded before the pointer")
    func savesTheSource() async throws {
        let (server, phone, writer) = try await Self.phone()
        let id = try await writer.saveExplainer(MobileExplainerOrigin(Self.paper), script: "  Why this matters.\n\nWhat they found.  ")
        #expect(id == MobileCloudMutationService.explainerSourceID(explaining: "src1"), "the id GeneratedExplainer derives on the Mac")

        let source = try #require(try await Fixture.held(phone.replica, .source, id, in: Fixture.catalog))
        #expect(source.fields["url"] == .string("foreverlm://explainer/src1"))
        #expect(source.fields["primaryKey"] == .string("url:explainer/src1"))
        #expect(source.fields["workKeys"] == .object(["url:explainer/src1": .bool(true)]))
        #expect(source.fields["type"] == .string("article"))
        #expect(source.fields["title"] == .string("Explainer: Membrane potential"))
        #expect(source.fields["status"] == .string("active"))
        #expect(source.fields["ingest"]?["state"] == .string("ready"))
        #expect(source.fields["ingest"]?["ord"] == .array([0, 4]))
        #expect(source.fields["authors"] == .array(["A. Author"]))
        #expect(source.fields["meta"]?["siteName"] == .string("ForeverLM"))
        #expect(source.fields["metrics"]?["wordCount"] == SyncJSON(Int64(6)))
        #expect(source.fields["madeBy"]?["route"] == .string("ios"))
        #expect(source.fields["contentHash"] == .string(SyncIdentity.sha256Hex(Data("Why this matters.\n\nWhat they found.".utf8))))
        let file = try #require(source.fields["files"]?["text"].flatMap(FileRef.init(json:)))
        #expect(file.owner == id)
        #expect(file.role == "text")
        #expect(file.encoding == "gzip")
        let part = try #require(file.satelliteIDs.first)
        #expect(server.storedRecord(RecordNaming.recordName(type: .content, id: part, salt: MobileSyncFixture.librarySalt), zone: "Content",
                                    owner: MobileRecordWriterTests.alice) != nil, "the script is on the server before anything points at it")
        #expect(try MobileRecordWriterTests.stored(server, .source, id, zone: "Catalog") == nil, "the Source waits for the next round")
        #expect(try await Fixture.held(phone.replica, .mark, "mk:provenance:src:\(id)", in: Fixture.library)?.fields["value"]?["origin"] == .string("manual"))

        // The phone reads it back as it reads any source: listed with its url, its text the satellite.
        let snapshot = try await MobileReadModels.snapshot(phone.projection)
        let listed = try #require(snapshot.sources.first { $0.id == id })
        #expect(ExplainerScript.explainedSourceID(from: listed.url ?? "") == "src1")
        #expect(MobileSourceListing.isSpokenScript(listed), "never a row of its own")
        #expect(listed.wordCount == 6)
        let blobs = try #require(writer.blobs)
        let text = try await MobileReadModels.sourceSatellite(id, matching: { $0 == "text" }, projection: phone.projection, blobs: blobs)
        #expect(text.map { String(decoding: $0, as: UTF8.self) } == "Why this matters.\n\nWhat they found.")

        try await phone.sync()
        let stored = try #require(try MobileRecordWriterTests.stored(server, .source, id, zone: "Catalog"))
        #expect(stored.fields["files"]?["text"] == file.value)
    }

    @Test("A rewrite replaces the script and the title on the one record, and keeps when it was added")
    func rewriteKeepsTheRow() async throws {
        let (server, phone, writer) = try await Self.phone()
        let id = try await writer.saveExplainer(MobileExplainerOrigin(Self.paper), script: "First script.")
        try await phone.sync()
        let first = try #require(try MobileRecordWriterTests.stored(server, .source, id, zone: "Catalog"))
        let mark = try await Fixture.held(phone.replica, .mark, "mk:provenance:src:\(id)", in: Fixture.library)

        let later = MobileRecordWriter(replica: phone.replica, deviceID: phone.deviceID, blobs: writer.blobs, clock: { Date().addingTimeInterval(-30) })
        let renamed = MobileExplainerOrigin(sourceID: "src1", title: "Membrane potential, revised")
        #expect(try await later.saveExplainer(renamed, script: "Second script, longer.") == id)
        try await phone.sync()
        let second = try #require(try MobileRecordWriterTests.stored(server, .source, id, zone: "Catalog"))
        #expect(second.fields["addedAt"] == first.fields["addedAt"])
        #expect(second.fields["primaryKey"] == first.fields["primaryKey"])
        #expect(second.fields["title"] == .string("Explainer: Membrane potential, revised"))
        #expect(second.fields["metrics"]?["wordCount"] == SyncJSON(Int64(3)))
        #expect(second.fields["files"]?["text"] != first.fields["files"]?["text"])
        #expect(try await Fixture.held(phone.replica, .mark, "mk:provenance:src:\(id)", in: Fixture.library) == mark, "the provenance is written once")
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources WHERE url = 'foreverlm://explainer/src1'") == 1)

        // The same script again changes nothing.
        let patches = try await Fixture.patchCount(phone.replica)
        _ = try await later.saveExplainer(renamed, script: "Second script, longer.")
        #expect(try await Fixture.patchCount(phone.replica) == patches)
    }

    @Test("An empty script is refused before anything is uploaded or queued")
    func emptyScript() async throws {
        let (server, phone, writer) = try await Self.phone()
        let content = server.recordNames(zone: "Content", owner: MobileRecordWriterTests.alice).count
        await #expect(throws: MobileCloudMutationError.self) {
            _ = try await writer.saveExplainer(MobileExplainerOrigin(Self.paper), script: " \n ")
        }
        #expect(server.recordNames(zone: "Content", owner: MobileRecordWriterTests.alice).count == content)
        #expect(try await Fixture.patchCount(phone.replica) == 0)
    }

}
