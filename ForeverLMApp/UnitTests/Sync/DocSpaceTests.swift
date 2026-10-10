import Foundation
import Testing
@testable import ForeverLM

/// A Doc shared on its own (docs/cloudkit-schema-design.md §9.1 `doc`, D5, WP15): it is shared through a
/// Doc space made for it, one per Doc; in it the Doc keeps its `notebookID`, so its notebook still lists
/// it for the owner. Moving the Doc in is WP15b's move job; here the Doc is placed as that job leaves it.
@Suite("Doc spaces", .serialized)
struct DocSpaceTests {
    typealias S = SpaceTestFixture
    typealias F = NotebookSyncFixture

    @Test("A Doc gets one Doc space, shared, whose root names the Doc; asking again finds it")
    func oneSpacePerDoc() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "doc-space", deviceID: "macaaaaa", user: "alice")
        let space = try await alice.service.docSpace(forArtifact: "doc-1", title: "Mitochondria notes", owner: alice.owner)
        #expect(space.kind == "doc" && space.primaryID == "doc-1" && space.isShared && space.isOwned)
        let again = try await alice.service.docSpace(forArtifact: "doc-1", title: "Mitochondria notes", owner: alice.owner)
        #expect(again.zone == space.zone)
        #expect(try await alice.service.list().count == 1)
        #expect(try alice.device.count("SELECT COUNT(*) FROM teams") == 0, "a Doc space is no team")
    }

    @Test("A Doc in its Doc space stays listed in its notebook for the owner, and its record names that notebook")
    func docStaysInItsNotebook() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "doc-space-listed", deviceID: "macaaaaa", user: "alice")
        let store = alice.store
        try F.addNotebook(store, "nb-1")
        try ArtifactSyncFixture.addDoc(store, "doc-1", markdown: "# Notes", notebookID: "nb-1")
        let space = try await alice.service.docSpace(forArtifact: "doc-1", title: "Mitochondria notes", owner: alice.owner)
        // As the move job leaves it: the Doc's row carries the space, its identity names the space's zone.
        try store.execute("UPDATE global_artifacts SET team_id = ? WHERE id = 'doc-1'", [.text(space.localTeamID)])
        try store.recordIdentity(zoneKey: space.zone.zoneKey, recordType: "Artifact", wireID: "doc-1", localID: "doc-1")

        #expect(try store.loadArtifacts(notebookID: "nb-1").map(\.id) == ["doc-1"])
        let change = try #require(try OutboxFeeder(connection: store, registry: F.registry).pendingChanges(now: Date().addingTimeInterval(60))
            .first { $0.recordType == .artifact && $0.wireID == "doc-1" })
        #expect(change.zoneKey == space.zone.zoneKey)
        #expect(F.savedFields(change)?["notebookID"] == .string("nb-1"), "D5: the owner's notebook still names it")
    }
}
