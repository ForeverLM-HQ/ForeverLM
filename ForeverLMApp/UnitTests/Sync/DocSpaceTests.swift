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

    @Test("A Doc in its Doc space stays listed in its notebook for the owner, keeps its own row, and sends into the space")
    func docStaysInItsNotebook() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "doc-space-listed", deviceID: "macaaaaa", user: "alice")
        let store = alice.store
        try F.addNotebook(store, "nb-1")
        try ArtifactSyncFixture.addDoc(store, "doc-1", markdown: "# Notes", notebookID: "nb-1")
        let space = try await alice.service.docSpace(forArtifact: "doc-1", title: "Mitochondria notes", owner: alice.owner)
        // Never sent: placement sends its first record into the space, and its body goes there too.
        #expect(try DocSpaces.bodyZoneKey(of: "doc-1", connection: store) == space.zone.zoneKey)
        // While `Library` holds it (shared, the move not finished), the record and the body stay there.
        let fields: [String: SyncJSON] = ["kind": "doc", "title": "Mitochondria notes", "notebookID": "nb-1", "status": "active"]
        let inLibrary = try F.record(.artifact, "doc-1", fields)
        try store.replica.upsertRecord(inLibrary)
        #expect(try DocSpaces.bodyZoneKey(of: "doc-1", connection: store) == nil)
        #expect(try DocSpaces.zoneKey(holding: "doc-1", connection: store) == nil)
        // As the move job leaves it: the replica holds the Doc in its space alone; the row is the learner's own still.
        try store.replica.deleteRecord(zoneKey: inLibrary.zoneKey, recordName: inLibrary.recordName)
        try store.replica.upsertRecord(try S.record(.artifact, "doc-1", fields, zoneKey: space.zone.zoneKey, device: "macaaaaa"))
        #expect(try DocSpaces.bodyZoneKey(of: "doc-1", connection: store) == space.zone.zoneKey)
        #expect(try DocSpaces.canWrite(zoneKey: space.zone.zoneKey, connection: store))
        #expect(try store.scalarText("SELECT COALESCE(team_id, 'mine') FROM global_artifacts WHERE id = 'doc-1'") == "mine")

        #expect(try store.loadArtifacts(notebookID: "nb-1").map(\.id) == ["doc-1"])
        let change = try #require(try OutboxFeeder(connection: store, registry: F.registry).pendingChanges(now: Date().addingTimeInterval(60))
            .first { $0.recordType == .artifact && $0.wireID == "doc-1" })
        #expect(change.zoneKey == space.zone.zoneKey)
        #expect(F.savedFields(change)?["notebookID"] == .string("nb-1"), "D5: the owner's notebook still names it")
    }

    private static let at = SyncJSON(Int64(1_759_400_000_000))

    private static func sharedDoc(_ zoneKey: String, id: String = "doc-1", title: String = "Mitochondria notes") throws -> ReplicaRecord {
        try S.record(.artifact, id, ["kind": "doc", "title": .string(title), "notebookID": "nb-alice", "status": "active", "createdAt": at],
                     zoneKey: zoneKey, device: "alicemac")
    }

    private static func sharedComment(_ zoneKey: String, id: String = "cmt-1", on doc: String = "doc-1") throws -> ReplicaRecord {
        try S.record(.comment, id, ["artifactID": .string(doc), "body": "Check the figure", "author": SyncPerson(user: "alice", name: "Alice").value,
                                    "createdAt": at, "editedAt": at], zoneKey: zoneKey, device: "alicemac")
    }

    @Test("A Doc someone shared is a row of the member's own library under the Doc's id, with its Comments; a team's Doc is not")
    func sharedDocLandsInTheMembersLibrary() async throws {
        let bob = try await S.Mac(EngineTestDriver.server(), name: "doc-member", deviceID: "macbbbbb", user: "bob")
        let store = bob.store
        let zoneKey = try S.holdSpace(store, spaceID: "d1", kind: "doc", name: "Mitochondria notes", owner: "alice", primaryID: "doc-1")
        try F.apply(store, [try Self.sharedDoc(zoneKey), try Self.sharedComment(zoneKey)])
        #expect(try store.scalarText("""
            SELECT title || '|' || COALESCE(team_id, 'mine') || '|' || COALESCE(home_notebook_id, '') FROM global_artifacts WHERE id = 'doc-1'
        """) == "Mitochondria notes|mine|nb-alice", "the row says what the record says, the owner's notebook included")
        #expect(try store.scalarText("SELECT body || '|' || author_record_name FROM artifact_comments WHERE id = 'cmt-1'") == "Check the figure|alice")
        #expect(try DocSpaces.zoneKey(holding: "doc-1", connection: store) == zoneKey)
        #expect(try DocSpaces.canWrite(zoneKey: zoneKey, connection: store))

        // Only the Doc the space was made for: another Doc in it, and a team space's Docs, stay in the replica.
        let team = try S.holdSpace(store, spaceID: "t1", kind: "team", owner: "alice")
        try F.apply(store, [try Self.sharedDoc(zoneKey, id: "doc-stray"), try Self.sharedDoc(team, id: "doc-team"),
                            try Self.sharedComment(team, id: "cmt-team", on: "doc-team")])
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id IN ('doc-stray', 'doc-team')") == 0)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM artifact_comments WHERE id = 'cmt-team'") == 0)
    }

    @Test("A member's edit of a shared Doc goes into its space and leaves the owner's notebook alone; a read-only member publishes no body")
    func membersEditGoesIntoTheSpace() async throws {
        let bob = try await S.Mac(EngineTestDriver.server(), name: "doc-member-edit", deviceID: "macbbbbb", user: "bob")
        let store = bob.store
        let zoneKey = try S.holdSpace(store, spaceID: "d1", kind: "doc", owner: "alice", primaryID: "doc-1")
        try F.apply(store, [try Self.sharedDoc(zoneKey)])
        try store.execute("UPDATE global_artifacts SET title = 'Mitochondria notes, edited' WHERE id = 'doc-1'")
        let change = try #require(try bob.pendingInSpaces()["Artifact:doc-1"])
        #expect(change.zoneKey == zoneKey)
        #expect(F.savedFields(change)?["title"] == .string("Mitochondria notes, edited"))
        #expect(F.savedFields(change)?["notebookID"] == .string("nb-alice"))
        #expect(change.stamps.keys.contains { $0.field == "title" } && !change.stamps.keys.contains { $0.field == "notebookID" },
                "the member's Mac holds no such notebook, and says nothing about it")

        let readOnly = try S.holdSpace(store, spaceID: "d2", kind: "doc", owner: "alice", permission: "readOnly", primaryID: "doc-2")
        try F.apply(store, [try Self.sharedDoc(readOnly, id: "doc-2")])
        #expect(try !DocSpaces.canWrite(zoneKey: readOnly, connection: store))
        try ArtifactSyncFixture.write(store, "doc-2", "# Mine", at: Date(timeIntervalSinceNow: -120))
        let bodies = ArtifactSyncFixture.Bodies()
        let publisher = DocBodyPublisher(store: MacPrivateSyncStore.direct(store), transfer: bodies.transfer)
        let due = try publisher.candidates(in: store, now: Date().addingTimeInterval(3_600), forcing: ["doc-1", "doc-2"])
        #expect(!due.contains { $0.artifactID == "doc-2" })
    }

    @Test("A shared Doc's body goes into its space's zone and comes from it; any other Doc's stays in private Content")
    func bodyTravelsThroughTheSpace() async throws {
        let alice = try await S.Mac(EngineTestDriver.server(), name: "doc-space-body", deviceID: "macaaaaa", user: "alice")
        let store = alice.store
        try ArtifactSyncFixture.addDoc(store, "doc-1", markdown: "# Shared")
        try ArtifactSyncFixture.addDoc(store, "doc-2", markdown: "# Mine")
        let zoneKey = try S.holdSpace(store, spaceID: "d1", kind: "doc", primaryID: "doc-1")
        let publisher = DocBodyPublisher(store: MacPrivateSyncStore.direct(store), transfer: ArtifactSyncFixture.Bodies().transfer)
        let due = try publisher.candidates(in: store, now: Date().addingTimeInterval(3_600), forcing: [])
        #expect(due.first { $0.artifactID == "doc-1" }?.spaceZoneKey == zoneKey)
        #expect(due.contains { $0.artifactID == "doc-2" } && due.first { $0.artifactID == "doc-2" }?.spaceZoneKey == nil)

        // The transfer sends each to its zone, and fetches a body from the zone its record arrived in.
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var zones: [String] = []
            func note(_ zone: String) { lock.withLock { zones.append(zone) } }
        }
        let seen = Seen()
        let file = try ArtifactBody.layout(package: Data("body".utf8), owner: "doc-1").file
        let transfer = DocBodyTransfer(
            upload: { _, _, _, _, _ in seen.note("up:Content"); return file },
            fetch: { _ in seen.note("down:Content"); return Data() },
            spaceUpload: { _, _, _, _, _, zone in seen.note("up:" + zone); return file },
            spaceFetch: { _, zone in seen.note("down:" + zone); return Data() }
        )
        _ = try await transfer.upload(Data(), owner: "doc-1", mime: ArtifactBody.packageMime, encoding: .identity, keeping: nil, zoneKey: zoneKey)
        _ = try await transfer.upload(Data(), owner: "doc-2", mime: ArtifactBody.packageMime, encoding: .identity, keeping: nil, zoneKey: nil)
        _ = try await transfer.fetch(file, recordZoneKey: zoneKey)
        _ = try await transfer.fetch(file, recordZoneKey: F.libraryZoneKey)
        #expect(seen.zones == ["up:" + zoneKey, "up:Content", "down:" + zoneKey, "down:Content"])
    }

    @Test("When a Doc's space goes, the member's Doc and its Comments go with it; the owner's Doc stays, since it moved back")
    func aGoneSpaceTakesTheMembersDoc() async throws {
        let server = EngineTestDriver.server()
        let bob = try await S.Mac(server, name: "doc-member-gone", deviceID: "macbbbbb", user: "bob")
        let joined = try S.holdSpace(bob.store, spaceID: "d1", kind: "doc", owner: "alice", primaryID: "doc-1")
        try F.apply(bob.store, [try Self.sharedDoc(joined), try Self.sharedComment(joined)])
        let joinedRow = try #require(try bob.store.replica.zone(key: joined))
        try await bob.spaces.spaceGone(try #require(SpaceZone(joinedRow)), reason: "deleted")
        #expect(try bob.store.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-1'") == 0)
        #expect(try bob.store.scalarInteger("SELECT COUNT(*) FROM artifact_comments WHERE id = 'cmt-1'") == 0)

        let alice = try await S.Mac(server, name: "doc-owner-gone", deviceID: "macaaaaa", user: "alice")
        let owned = try S.holdSpace(alice.store, spaceID: "d1", kind: "doc", primaryID: "doc-1")
        try F.apply(alice.store, [try Self.sharedDoc(owned), try Self.sharedComment(owned)])
        let ownedRow = try #require(try alice.store.replica.zone(key: owned))
        try await alice.spaces.spaceGone(try #require(SpaceZone(ownedRow)), reason: "deleted")
        #expect(try alice.store.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-1'") == 1)
        #expect(try alice.store.scalarInteger("SELECT COUNT(*) FROM artifact_comments WHERE id = 'cmt-1'") == 1)
    }

    @Test("A Doc's deletion in the zone it left keeps its row while the replica holds it where it went")
    func aMovedDocsOldRecordGoesAlone() async throws {
        let alice = try await S.Mac(EngineTestDriver.server(), name: "doc-moved-delete", deviceID: "macaaaaa", user: "alice")
        let store = alice.store
        let zoneKey = try S.holdSpace(store, spaceID: "d1", kind: "doc", primaryID: "doc-1")
        let fields: [String: SyncJSON] = ["kind": "doc", "title": "Mitochondria notes", "status": "active", "createdAt": Self.at]
        // A second Mac: `Library`'s Doc and its Comment, then the space's copies, then `Library`'s deletions,
        // before the move list has reached it.
        try F.apply(store, [try F.record(.artifact, "doc-1", fields),
                            try F.record(.comment, "cmt-1", ["artifactID": "doc-1", "body": "Check the figure", "createdAt": Self.at, "editedAt": Self.at]),
                            try Self.sharedDoc(zoneKey), try Self.sharedComment(zoneKey)])
        try ArtifactSyncFixture.applyDeletion(store, .comment, "cmt-1")
        try ArtifactSyncFixture.applyDeletion(store, .artifact, "doc-1")
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-1'") == 1)
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM artifact_comments WHERE id = 'cmt-1'") == 1)

        // Moved back: `Library` holds it again, and the space's record goes without its row.
        try F.apply(store, [try F.record(.artifact, "doc-1", fields)])
        let held = try #require(try store.replica.record(zoneKey: zoneKey, recordType: "Artifact", wireID: "doc-1"))
        try store.replica.apply { replica in
            try ProjectionApply(store: store, registry: F.registry).projectDeletion(zoneKey: zoneKey, recordName: held.recordName, type: .artifact, wireID: "doc-1")
            try replica.deleteRecord(zoneKey: zoneKey, recordName: held.recordName)
        }
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-1'") == 1)

        // Deleted outright: with no copy anywhere else, the row goes.
        try ArtifactSyncFixture.applyDeletion(store, .artifact, "doc-1")
        #expect(try store.scalarInteger("SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-1'") == 0)
    }
}
