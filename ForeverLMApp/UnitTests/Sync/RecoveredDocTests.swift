import Foundation
import Testing
@testable import ForeverLM

/// "Recovered:" Docs (docs/cloudkit-schema-design.md §4.1, §6.2, R6-3, WP11): a body this Mac edited and
/// the server no longer takes is kept as `recovered:<artifactID>:<hash of the body>` in the same notebook,
/// once, its FileRef kept verbatim when it was already uploaded, and it goes out like any Doc.
@Suite("Recovered Docs")
struct RecoveredDocTests {
    typealias F = ArtifactSyncFixture
    typealias N = NotebookSyncFixture

    private static func recovered(_ store: KnowledgeStore) throws -> [String] {
        var ids: [String] = []
        try store.query("SELECT id FROM global_artifacts WHERE id LIKE 'recovered:%' ORDER BY id", []) { row in
            if let id = row.text(0) { ids.append(id) }
        }
        return ids
    }

    @Test("A sent, unacknowledged body met by a delete becomes one Recovered Doc with its FileRef verbatim, however often it is recovered")
    func sentBodyKeptOnce() async throws {
        let rig = try F.makeRig("recovered-sent")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        try F.addDoc(rig.store, "doc-1", markdown: "Before", notebookID: "nb-1")
        try await F.publishAndSend(rig)
        let held = try #require(try rig.store.replica.record(zoneKey: N.libraryZoneKey, recordType: "Artifact", wireID: "doc-1"))

        // Edited and published (its bytes are on the server), but the pointer was never acknowledged.
        try F.write(rig.store, "doc-1", "After, mine", at: Date(timeIntervalSinceNow: -100))
        try await rig.publisher.publishDue(now: Date().addingTimeInterval(3_600))
        let pointer = try #require(try F.bodyRef(rig.store, "doc-1"))

        try F.applyDeletion(rig.store, .artifact, "doc-1")
        let id = RecoveredDoc.id(artifactID: "doc-1", hash: pointer.hash)
        #expect(try Self.recovered(rig.store) == [id])
        #expect(try F.bodyRef(rig.store, id) == pointer, "the FileRef is kept verbatim: its owner's names stay valid")
        #expect(try F.text(rig.store, "SELECT title || '|' || home_notebook_id FROM global_artifacts WHERE id = '\(id)'") == "Recovered: Mitochondria notes|nb-1")
        #expect(try rig.store.loadArtifactMarkdownForSync(id) == "After, mine")
        #expect(try F.text(rig.store, "SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-1'") == "0")
        let sent = try #require(N.savedFields(try N.pending(rig.store)["Artifact:\(id)"]))
        #expect(sent["body"] == pointer.value)

        // The same body recovered again (a retried delivery) makes no second Doc.
        try F.addDoc(rig.store, "doc-1", markdown: "After, mine", notebookID: "nb-1")
        try rig.store.execute("UPDATE global_artifacts SET body_ref = ? WHERE id = 'doc-1'", [.text(ArtifactBody.text(pointer))])
        try rig.store.replica.upsertRecord(held)
        try F.applyDeletion(rig.store, .artifact, "doc-1")
        #expect(try Self.recovered(rig.store) == [id])
    }

    @Test("An edit never sent is recovered from the Doc's files and published like any Doc")
    func unsentEdit() async throws {
        let rig = try F.makeRig("recovered-unsent")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try F.addDoc(rig.store, "doc-1", markdown: "Before")
        try await F.publishAndSend(rig)
        try F.write(rig.store, "doc-1", "Typed offline", at: Date())

        try F.applyDeletion(rig.store, .artifact, "doc-1")
        let ids = try Self.recovered(rig.store)
        #expect(ids.count == 1)
        let id = try #require(ids.first)
        #expect(try F.bodyRef(rig.store, id) == nil, "never uploaded")
        #expect(try rig.store.loadArtifactMarkdownForSync(id) == "Typed offline")
        #expect(id == RecoveredDoc.id(artifactID: "doc-1", hash: try #require(try rig.store.loadArtifactBodyPackageForSync(id)).revision))
        try await F.publishAndSend(rig)
        let body = try #require(try N.held(rig.store, .artifact, id)?.fields["body"].flatMap(FileRef.init(json:)))
        #expect(body.owner == id)
    }

    @Test("Notes that overlap another device's keep the server's and become one Recovered Doc in the notebook")
    func notesOverlap() async throws {
        let rig = try F.makeRig("recovered-notes")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        try F.setNotes(rig.store, "nb-1", "Shared line")
        try await F.publishAndSend(rig)
        try F.setNotes(rig.store, "nb-1", "Shared line, mine")
        let theirs = try rig.bodies.putNotes("Shared line, theirs", notebookID: "nb-1")
        try N.apply(rig.store, [try F.notesRecord("nb-1", body: theirs, ms: 1_799_000_000_000)])

        let id = RecoveredDoc.id(artifactID: "notes:nb-1", hash: SyncIdentity.sha256Hex(Data("Shared line, mine".utf8)))
        #expect(try await rig.materializer.materializeDue()["notes:nb-1"] == .recovered(id))
        #expect(try F.notes(rig.store, "nb-1") == "Shared line, theirs")
        #expect(try Self.recovered(rig.store) == [id])
        #expect(try F.text(rig.store, "SELECT title || '|' || home_notebook_id FROM global_artifacts WHERE id = '\(id)'") == "Recovered: Notes|nb-1")
        #expect(try rig.store.loadArtifactMarkdownForSync(id) == "Shared line, mine")
        try RecoveredDoc.keepNotes("Shared line, mine", notebookID: "nb-1", in: rig.store)
        #expect(try Self.recovered(rig.store) == [id], "a second recovery of the same body makes no second Doc")
    }
}
