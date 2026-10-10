import Foundation
import Testing
@testable import ForeverLM

/// The Artifact and Comment projections (docs/cloudkit-schema-design.md §3.5.15, §3.5.16, WP11): a Doc's
/// fields and links round-trip, its body travels only as the pointer the publisher moved, a notebook's
/// notes are its Notes Doc, comments wait for their Doc, deletes reach the server only from the device
/// that made them, and a source's draft deck never becomes a record under generation 2.
@Suite("Artifact projection")
struct ArtifactProjectionTests {
    typealias F = ArtifactSyncFixture
    typealias N = NotebookSyncFixture

    @Test("A Doc's rows encode its fields, its body only once published, and another Mac projects them back")
    func roundTrip() async throws {
        let rig = try F.makeRig("round")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let store = rig.store
        try N.addNotebook(store, "nb-1")
        try N.addSource(store, "src-a")
        try F.addDoc(store, "doc-1", markdown: "# Complex I\n\nIt pumps protons.", notebookID: "nb-1")
        try store.execute("INSERT INTO global_artifact_source_links (artifact_id, source_id, linked_at) VALUES ('doc-1', 'src-a', 5)")

        let before = try #require(N.savedFields(try N.pending(store)["Artifact:doc-1"]))
        #expect(before["kind"] == .string("doc"))
        #expect(before["title"] == .string("Mitochondria notes"))
        #expect(before["notebookID"] == .string("nb-1"))
        #expect(before["linkedNotebookIDs"] == .object(["nb-1": .bool(true)]))
        #expect(before["sourceIDs"] == .object(["src-a": .bool(true)]))
        #expect(before["status"] == .string("active"))
        #expect(before["body"] == nil, "no pointer before the publisher moved one")

        try await F.publishAndSend(rig)
        let held = try #require(try N.held(store, .artifact, "doc-1"))
        let body = try #require(held.fields["body"].flatMap(FileRef.init(json:)))
        #expect(body.hash == (try store.loadArtifactBodyPackageForSync("doc-1"))?.revision, "the FileRef hashes generation 1's bodyRevision")
        #expect(body.owner == "doc-1" && body.role == "body" && body.mime == ArtifactBody.packageMime)
        #expect(held.fields["bodyFormat"] == .string("markdownPackage"))
        #expect(held.fields["preview"] == .string("# Complex I It pumps protons."))
        #expect(try F.text(store, "SELECT COUNT(*) FROM ck_text_bases") == "0", "a Doc's base is document.base.md")
        #expect(try store.loadArtifactBaseMarkdown("doc-1") == "# Complex I\n\nIt pumps protons.", "the acknowledged body is the base")
        #expect(try N.pending(store).isEmpty)

        // Another Mac holds none of it.
        let other = try F.makeRig("round-other")
        defer { try? FileManager.default.removeItem(at: other.root) }
        try N.addNotebook(other.store, "nb-1")
        let record = ReplicaRecord(zoneKey: N.libraryZoneKey, recordName: try #require(try store.replica.record(zoneKey: N.libraryZoneKey, recordType: "Artifact", wireID: "doc-1")).recordName,
                                   recordType: "Artifact", wireID: "doc-1", systemFields: Data([1]),
                                   payload: try held.storedPayload(), seenPass: nil)
        try N.apply(other.store, [record])
        let row = "SELECT title || '|' || home_notebook_id || '|' || COALESCE(kind, 'none') FROM global_artifacts WHERE id = 'doc-1'"
        #expect(try F.text(other.store, row) == "Mitochondria notes|nb-1|none")
        #expect(try F.text(other.store, "SELECT COUNT(*) FROM global_artifact_source_links WHERE artifact_id = 'doc-1' AND source_id = 'src-a'") == "1")
        #expect(try DocBodyJobs.isPending(artifactID: "doc-1", connection: other.store), "the pointer queued its fetch")
        #expect(try N.pending(other.store).keys.filter { $0.hasPrefix("Artifact") }.isEmpty, "an apply sends nothing back")
        // The body is not in the record: it is fetched, by name, and lands in the Doc's folder.
        // (`rig`'s bodies stand in for the server both Macs share.)
        let shared = DocBodyMaterializer(store: MacPrivateSyncStore.direct(other.store), transfer: rig.bodies.transfer)
        #expect(try await shared.materializeDue()["doc-1"] == .applied)
        #expect(try other.store.loadArtifactMarkdownForSync("doc-1") == "# Complex I\n\nIt pumps protons.")
        #expect(try other.store.loadArtifactBodyPackageForSync("doc-1")?.revision == body.hash)
        try await other.publisher.publishDue(now: Date().addingTimeInterval(3_600))
        #expect(other.bodies.uploadCount == 0, "a body brought in is never sent back")
    }

    @Test("Two Docs whose records the replica does not hold yet queue their body fetches without colliding")
    func fetchJobsForRecordsNotYetHeld() throws {
        let (root, store) = try MemorySyncFixture.makeStore("body-jobs")
        defer { try? FileManager.default.removeItem(at: root) }
        // A catch-up and a late import notebook records before the replica stores them: no `ck_records` row names them.
        try DocBodyJobs.queueFetch(artifactID: "doc-1", zoneKey: N.libraryZoneKey, connection: store)
        try DocBodyJobs.queueFetch(artifactID: "doc-2", zoneKey: N.libraryZoneKey, connection: store)
        try DocBodyJobs.queueFetch(artifactID: "doc-1", zoneKey: N.libraryZoneKey, connection: store)
        #expect(try F.text(store, "SELECT COUNT(*) FROM ck_blob_jobs WHERE direction = 'body'") == "2")
        #expect(try DocBodyJobs.isPending(artifactID: "doc-1", connection: store) && DocBodyJobs.isPending(artifactID: "doc-2", connection: store))

        // A fetch that failed five times is not given up for good (the Doc is held back from publishing
        // meanwhile): it is tried again an hour after its last try.
        let failedAt = Date()
        try store.execute("UPDATE ck_blob_jobs SET attempts = 5, updated_at = ? WHERE content_id = 'doc-1'", [.real(failedAt.timeIntervalSinceReferenceDate)])
        #expect(try DocBodyJobs.pending(connection: store, now: failedAt.addingTimeInterval(60)).map(\.artifactID) == ["doc-2"])
        #expect(Set(try DocBodyJobs.pending(connection: store, now: failedAt.addingTimeInterval(3_700)).map(\.artifactID)) == ["doc-1", "doc-2"])
    }

    @Test("A notebook's notes are its Notes Doc, whose body is the published pointer, cleared with the notes")
    func notesDoc() async throws {
        let rig = try F.makeRig("notes")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        try F.setNotes(rig.store, "nb-1", "  Complex I leaks electrons.\n")
        #expect(try N.pending(rig.store)["Artifact:notes:nb-1"] == nil, "notes are not sent per keystroke")
        try await F.publishAndSend(rig)
        let held = try #require(try N.held(rig.store, .artifact, "notes:nb-1"))
        #expect(held.fields["kind"] == .string("notes"))
        #expect(held.fields["title"] == .string("Notes"))
        #expect(held.fields["notebookID"] == .string("nb-1"))
        #expect(held.fields["bodyFormat"] == .string("markdown"))
        let body = try #require(held.fields["body"].flatMap(FileRef.init(json:)))
        #expect(body.hash == SyncIdentity.sha256Hex(Data("Complex I leaks electrons.".utf8)) && body.encoding == "gzip")
        #expect(held.fields["body"] == (try NotesDoc.body(notebookID: "nb-1", notes: "Complex I leaks electrons."))?.file.value,
                "the publisher's layout is NotesDoc's")
        #expect(try NotesBase.load(notebookID: "nb-1", connection: rig.store) == "Complex I leaks electrons.", "the acknowledged notes are the base")

        try F.setNotes(rig.store, "nb-1", "")
        try await F.publishAndSend(rig)
        #expect(try N.held(rig.store, .artifact, "notes:nb-1")?.fields["body"] == .null)

        // The notebook deleted here takes its Notes Doc with it.
        try rig.store.releaseFilesOfDeletedNotebook("nb-1")
        try rig.store.execute("DELETE FROM learning_goals WHERE id = 'nb-1'")
        try N.sendAll(rig.store)
        #expect(try N.held(rig.store, .artifact, "notes:nb-1") == nil)
    }

    @Test("A source's draft deck is never a record under generation 2, sent or applied")
    func deckRetired() throws {
        let rig = try F.makeRig("deck")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let deckID = MemoryCard.draftDeckIDPrefix + "src-a"
        try rig.store.saveArtifactRecord(ArtifactRecord(
            id: deckID, title: "Cards to check", homeNotebookID: nil, linkedNotebookIDs: [], kind: .flashcards,
            sourceIDs: ["src-a"], createdAt: Date(), updatedAt: Date()
        ))
        #expect(try N.pending(rig.store).keys.allSatisfy { !$0.contains(deckID) })
        try N.apply(rig.store, [try F.docRecord("\(MemoryCard.draftDeckIDPrefix)src-b", body: nil, extra: ["kind": .string("flashcards")])])
        #expect(try F.text(rig.store, "SELECT COUNT(*) FROM global_artifacts WHERE id = '\(MemoryCard.draftDeckIDPrefix)src-b'") == "0")
    }

    @Test("A comment round-trips with its anchor and author, and one applied before its Doc waits for it")
    func comments() throws {
        let rig = try F.makeRig("comments")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try F.addDoc(rig.store, "doc-1", markdown: "Body")
        try rig.store.saveArtifactCommentRecord(ArtifactCommentRecord(
            id: "c-1", artifactID: "doc-1", parentCommentID: nil, authorRecordName: "_user1", authorDisplayName: "Robin",
            body: "Which complex?", anchorRevision: "rev-1", anchorStart: 3, anchorEnd: 9, anchorQuote: "Body",
            createdAt: Date(timeIntervalSinceReferenceDate: 3_000), updatedAt: Date(timeIntervalSinceReferenceDate: 3_000), resolvedAt: nil
        ))
        let fields = try #require(N.savedFields(try N.pending(rig.store)["Comment:c-1"]))
        #expect(fields["artifactID"] == .string("doc-1"))
        #expect(fields["author"] == .object(["user": .string("_user1"), "name": .string("Robin")]))
        #expect(fields["anchor"]?["t"] == .string("doc") && fields["anchor"]?["bodyHash"] == .string("rev-1"))
        #expect(fields["anchor"]?["start"] == SyncJSON(Int64(3)) && fields["anchor"]?["end"] == SyncJSON(Int64(9)))
        #expect(fields["body"] == .string("Which complex?"))

        // On another Mac the reply and the comment arrive before the Doc.
        let other = try F.makeRig("comments-other")
        defer { try? FileManager.default.removeItem(at: other.root) }
        var reply = fields
        reply["replyTo"] = .string("c-1")
        reply["body"] = .string("Complex I")
        try N.apply(other.store, [try N.record(.comment, "c-2", reply), try N.record(.comment, "c-1", fields)])
        #expect(try F.text(other.store, "SELECT COUNT(*) FROM artifact_comments") == "0")
        try N.apply(other.store, [try F.docRecord("doc-1", body: nil)])
        #expect(try F.text(other.store, "SELECT group_concat(id || ':' || COALESCE(parent_comment_id, '-'), ',') FROM (SELECT * FROM artifact_comments ORDER BY id)") == "c-1:-,c-2:c-1")
        #expect(try F.text(other.store, "SELECT author_display_name || '|' || anchor_quote FROM artifact_comments WHERE id = 'c-1'") == "Robin|Body")
    }

    @Test("A Doc deleted here deletes its record and its comments; one deleted elsewhere removes the rows here")
    func deletes() async throws {
        let rig = try F.makeRig("deletes")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try F.addDoc(rig.store, "doc-1", markdown: "One")
        try F.addDoc(rig.store, "doc-2", markdown: "Two")
        try rig.store.saveArtifactCommentRecord(ArtifactCommentRecord(
            id: "c-1", artifactID: "doc-1", parentCommentID: nil, authorRecordName: "_u", authorDisplayName: "M", body: "Hm",
            anchorRevision: "r", anchorStart: 0, anchorEnd: 1, anchorQuote: "O", createdAt: Date(), updatedAt: Date(), resolvedAt: nil
        ))
        try await F.publishAndSend(rig)
        #expect(try N.held(rig.store, .comment, "c-1") != nil)

        try rig.store.deleteArtifactRecord("doc-1")
        let pending = try N.pending(rig.store)
        #expect(pending["Artifact:doc-1"]?.action == .delete)
        #expect(pending["Comment:c-1"]?.action == .delete, "its comment goes with it: this device deleted the Doc")

        try F.applyDeletion(rig.store, .artifact, "doc-2")
        #expect(try F.text(rig.store, "SELECT COUNT(*) FROM global_artifacts WHERE id = 'doc-2'") == "0")
        #expect(try F.text(rig.store, "SELECT COUNT(*) FROM global_artifacts WHERE id LIKE 'recovered:%'") == "0", "nothing was edited here")
        #expect(try N.pending(rig.store)["Artifact:doc-2"] == nil, "an inbound delete is not sent back")
    }
}

extension ArtifactSyncFixture {
    static func text(_ store: KnowledgeStore, _ sql: String) throws -> String? {
        try store.scalarText(sql)
    }
}
