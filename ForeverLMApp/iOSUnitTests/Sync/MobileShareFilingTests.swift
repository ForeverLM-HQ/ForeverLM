import Foundation
import Testing
@testable import ForeverLM

/// The share sheet on a switched phone (docs/cloudkit-schema-design.md D47, §5.4, §13.6; §14.2 WP20): its
/// notebook list is fed from the replica, space notebooks included, and an item shared into a notebook
/// is filed by its capture, or stays in the library when that notebook is gone.
@Suite("iPhone share filing", .serialized)
struct MobileShareFilingTests {
    typealias Fixture = MobileWriterFixture

    @Test("The share sheet's list includes space notebooks, beside the learner's own")
    func listIncludesSpaceNotebooks() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileReadModelFixture.notebook("nb1", "Mine", edited: 5)),
            (Fixture.space, try MobileReadModelFixture.notebook("nbs", "Team notebook", edited: 9)),
        ])
        let notebooks = try await replica.read { try MobileReadModels.snapshot(in: $0) }.notebooks
        let listed = MobileAudioReviewViewModel.shareNotebooks(notebooks, lastChatAt: [:])
        #expect(Set(listed.map(\.id)) == ["nb1", "nbs"])
        #expect(listed.first { $0.id == "nbs" }?.title == "Team notebook")
    }

    @Test("A shared link into a space notebook is filed there, its source copied into the space")
    func filedIntoASpaceNotebook() async throws {
        let replica = try await Fixture.replica()
        try await Fixture.apply(replica, [(Fixture.space, try MobileReadModelFixture.notebook("nbs", "Team notebook", edited: 9))])
        try await replica.perform { try $0.connection.execute("UPDATE ck_zones SET last_complete_pass_at = 1 WHERE zone_key = 'private/Catalog'") }
        let writer = Fixture.writer(replica)
        let url = try #require(URL(string: "https://example.org/shared"))
        let id = try #require(try await writer.transaction {
            try $0.captureURL(url, title: "Shared", sourceType: "article", target: MobileCaptureTarget(notebookID: "nbs", origin: "share"))
        })
        #expect(try await Fixture.held(replica, .source, id, in: Fixture.space) != nil)
        #expect(try await Fixture.held(replica, .entry, "en:nbs:source:\(id)", in: Fixture.space)?.fields["origin"] == .string("share"))
    }

    @Test("An item whose notebook is gone stays in the library: no target before the pass, no Entry after it")
    func goneNotebook() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica)
        let url = try #require(URL(string: "https://example.org/gone"))
        _ = try await writer.transaction { try $0.captureURL(url, title: nil, sourceType: "article", target: MobileCaptureTarget(notebookID: "gone", origin: "share")) }
        let job = try #require(try await writer.read { try $0.jobs() }.first)
        #expect(job.fields["params"]?["target"] == nil)

        try await replica.perform { try $0.connection.execute("UPDATE ck_zones SET last_complete_pass_at = 1 WHERE zone_key = 'private/Catalog'") }
        let id = try #require(try await writer.transaction {
            try $0.captureURL(url, title: nil, sourceType: "article", target: MobileCaptureTarget(notebookID: "gone", origin: "share"))
        })
        #expect(try await Fixture.held(replica, .source, id, in: Fixture.catalog) != nil)
        #expect(try await replica.read { try $0.connection.scalarInteger("SELECT COUNT(*) FROM m_entries") } == 0)

        // Generation 1's drain does the same through its own adds.
        #expect(MobileShareFiling.adds([(sourceID: id, notebookID: "gone")], liveNotebookIDs: ["nb1"]).isEmpty)
    }

    @Test("The drain drops what can never become a source and what a Mac finishes, and stops on any other error so the item stays for the next drain")
    func drainAnswers() {
        // A capture a Mac finishes (the writer commits its Job, then says so): done, so it leaves the inbox.
        #expect(MobileShareDrain.answer(to: MobileRecordWriterError.queuedForMac) == .queuedForMac(MobileRecordWriterError.queuedForMac.localizedDescription))
        #expect(MobileShareDrain.answer(to: MobileCloudMutationError.unsupportedCaptureURL) == .refused(MobileCloudMutationError.unsupportedCaptureURL.localizedDescription))
        #expect(MobileShareDrain.answer(to: MobileCloudMutationError.unsupportedCaptureFile) != nil)
        #expect(MobileShareDrain.answer(to: MobileRecordWriterError.zoneNotHeld) == nil, "not yet in iCloud: try again at the next drain")
        #expect(MobileShareDrain.answer(to: MobileRecordWriterError.noServerTime) == nil)
        #expect(MobileShareDrain.answer(to: MobileCloudMutationError.emptyNotebookTitle) == nil)
    }
}
