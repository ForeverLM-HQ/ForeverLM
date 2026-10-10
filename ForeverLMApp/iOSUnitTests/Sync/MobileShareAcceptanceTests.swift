import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// A space's invitation on the iPhone (docs/cloudkit-schema-design.md §9.7, D13; §14.2 WP20): only a
/// share of the library container, on a build that syncs it, goes to ShareService; once accepted the
/// space is walked and its notebooks appear named for it, and the phone's own notebook is shared by
/// asking a Mac to move it (`Job(moveToSpace)`).
@Suite("iPhone share acceptance", .serialized)
struct MobileShareAcceptanceTests {
    static let library = "iCloud.com.foreverlm.knowledge"

    @Test("Only a share of the library container on a build that syncs it is accepted into a space")
    func route() {
        #expect(MobileShareAcceptance.route(shareContainer: Self.library, libraryContainer: Self.library, enabled: true) == .space)
        #expect(MobileShareAcceptance.route(shareContainer: "iCloud.com.foreverlm", libraryContainer: Self.library, enabled: true) == .notOurs,
                "a team of the old team's container is not ours")
        #expect(MobileShareAcceptance.route(shareContainer: Self.library, libraryContainer: Self.library, enabled: false) == .notOurs,
                "a build that syncs nothing accepts nothing")
        #expect(MobileShareAcceptance.route(shareContainer: Self.library, libraryContainer: nil, enabled: true) == .notOurs)
    }

    @Test("An accepted invitation joins the space with its permission, and its notebook appears named for it")
    func acceptAndWalk() async throws {
        let server = FakeCloudKit(start: Date())
        try MobileSyncFixture.makeLibrary(server, owner: "alice")
        try MobileSyncFixture.makeLibrary(server, owner: "bob", salt: Data(repeating: 4, count: 32))
        try MobileSyncFixture.makeSpace(server, owner: "alice", name: "Acme Lab")
        server.put([
            try MobileSyncFixture.record(.notebook, "nb-team", [
                "title": .string("🧠 Team reading"), "status": .string("active"), "createdAt": SyncJSON(1), "editedAt": SyncJSON(2),
            ], in: CloudZoneID("Space-s1"), salt: MobileSyncFixture.spaceSalt),
        ], zone: "Space-s1", owner: "alice")

        let alice = try MobileTestDevice(server, user: "alice", deviceID: "phonealc")
        try await alice.bootstrap()
        try await alice.sync()
        let aliceShares = ShareService(transport: server.transport(user: "alice", device: "alice-phone"), store: alice.replica, spaces: alice.spaces)
        let shared = try await aliceShares.share(SpaceZone(CloudZoneID("Space-s1"), in: .private), title: "Acme Lab",
                                                  invite: [.userRecordName("bob"): .readWrite])
        let url = try #require(shared.url)

        let bob = try MobileTestDevice(server, user: "bob", deviceID: "phonebob")
        try await bob.bootstrap()
        try await bob.sync()
        #expect(try await bob.projection.loadStructure().notebooks.isEmpty)
        MobileTestDevice.follow(server)
        let bobShares = ShareService(transport: server.transport(user: "bob", device: "bob-phone"), store: bob.replica, spaces: bob.spaces)
        let zone = try await MobileShareAcceptance.accept(CloudShareInvitation(url: url), shares: bobShares, spaces: bob.spaces)
        #expect(!zone.isOwned)
        let row = try await bob.replica.read { try $0.replica.zone(key: zone.zoneKey) }
        #expect(row?.permission == "readWrite")
        let notebook = try #require(try await bob.projection.loadStructure().notebooks.first { $0.notebookID == "nb-team" })
        #expect(notebook.spaceName == "Acme Lab")

        // Bob's own write into the joined space goes there, stamped by his phone.
        let writer = MobileRecordWriter(replica: bob.replica, deviceID: bob.deviceID, clock: { Date().addingTimeInterval(-60) })
        try await writer.transaction { try $0.updateNotebook("nb-team", title: "🧠 Team reading list") }
        try await bob.sync()
        let name = RecordNaming.recordName(type: .notebook, id: "nb-team", salt: MobileSyncFixture.spaceSalt)
        let stored = try #require(server.storedRecord(name, zone: "Space-s1", owner: "alice")?.payload)
        #expect(try SyncEnvelope(storedPayload: stored).fields["title"] == .string("🧠 Team reading list"))
    }

    @Test("Sharing a notebook of the personal library asks a Mac to move it, once the learner has said they may share")
    func shareAsksAMac() async throws {
        let replica = try await MobileWriterFixture.replica(space: nil)
        try await MobileWriterFixture.apply(replica, [(MobileWriterFixture.library, try MobileReadModelFixture.notebook("nb1", "Mine", edited: 5))])
        let writer = MobileWriterFixture.writer(replica)
        #expect(try await writer.read { try $0.sharingAffirmation() } == nil, "not affirmed yet: the sheet asks")
        try await writer.transaction { try $0.writeSharingAffirmation(SharingRightsAffirmation(affirmedAt: Date(timeIntervalSince1970: 1_759_400_000))) }
        #expect(try await writer.read { try $0.sharingAffirmation() }?.isCurrent() == true)
        let id = try await writer.requestMoveToSpace("nb1", to: .newSpace(kind: "notebook", name: "Mine"))
        let job = try #require(try await MobileWriterFixture.held(replica, .job, id, in: MobileWriterFixture.library))
        #expect(job.fields["kind"] == .string("moveToSpace"))
        #expect(job.fields["params"]?["newSpace"]?["kind"] == .string("notebook"))
    }
}
