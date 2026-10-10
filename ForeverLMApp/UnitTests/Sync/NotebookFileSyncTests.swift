import Foundation
import Testing
@testable import ForeverLM

/// A notebook's workspace files as `Artifact(kind file)` (docs/cloudkit-schema-design.md §3.5.15, §10,
/// WP11): `file:<notebookID>:<sha256 of the path>`, its bytes published on idle and brought in on another
/// Mac, a change on both sides kept as two files, a rescan that changes nothing sends nothing, and a file
/// deleted elsewhere goes here too.
@Suite("Notebook file sync")
struct NotebookFileSyncTests {
    typealias F = ArtifactSyncFixture
    typealias N = NotebookSyncFixture

    /// A file in the notebook's workspace and its index row, as `reconcileNotebookFiles` leaves them.
    private static func addFile(_ store: KnowledgeStore, notebookID: String, path: String, bytes: Data, at date: Date = Date(timeIntervalSinceNow: -120)) throws {
        let relative = NotebookFileArtifact.relativePath(notebookID: notebookID, path: path)
        let url = try #require(store.contentDirectory).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        try store.execute("""
            INSERT INTO notebook_files (id, notebook_id, relative_path, name, role, content_type, size_bytes, modified_at, created_at)
            VALUES (?, ?, ?, ?, 'file', NULL, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET size_bytes = excluded.size_bytes, modified_at = excluded.modified_at
        """, [
            .text(NotebookFileArtifact.localID(notebookID: notebookID, relativePath: relative)), .text(notebookID), .text(relative),
            .text(URL(fileURLWithPath: path).lastPathComponent), .integer(Int64(bytes.count)), .real(date.timeIntervalSinceReferenceDate), .real(1_000),
        ])
    }

    private static func file(_ store: KnowledgeStore, _ notebookID: String, _ path: String) throws -> Data? {
        try? Data(contentsOf: try #require(store.contentDirectory).appendingPathComponent(NotebookFileArtifact.relativePath(notebookID: notebookID, path: path)))
    }

    @Test("A workspace file is an Artifact of kind file, its bytes published and brought in on another Mac")
    func roundTrip() async throws {
        let rig = try F.makeRig("files")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        let bytes = Data("gene\tcount\nND1\t42\n".utf8)
        try Self.addFile(rig.store, notebookID: "nb-1", path: "data/counts.tsv", bytes: bytes)
        let id = NotebookFileArtifact.wireID(notebookID: "nb-1", path: "data/counts.tsv")
        #expect(id == "file:nb-1:" + SyncIdentity.sha256Hex(Data("data/counts.tsv".utf8)))

        try await F.publishAndSend(rig)
        let held = try #require(try N.held(rig.store, .artifact, id))
        #expect(held.fields["kind"] == .string("file"))
        #expect(held.fields["title"] == .string("counts.tsv"))
        #expect(held.fields["path"] == .string("data/counts.tsv"))
        #expect(held.fields["notebookID"] == .string("nb-1"))
        #expect(held.fields["bodyFormat"] == .string("binary"))
        let body = try #require(held.fields["body"].flatMap(FileRef.init(json:)))
        #expect(body.hash == SyncIdentity.sha256Hex(bytes) && body.owner == id)

        // A rescan rewrites the index rows as they were: nothing goes out.
        let row = try #require(try NotebookFileArtifact.row(for: id, connection: rig.store))
        try rig.store.execute("DELETE FROM notebook_files WHERE notebook_id = 'nb-1'")
        try Self.addFile(rig.store, notebookID: "nb-1", path: "data/counts.tsv", bytes: bytes, at: Date(timeIntervalSinceReferenceDate: row.modifiedAt))
        #expect(try N.pending(rig.store)["Artifact:\(id)"] == nil)

        // Another Mac.
        let other = try F.makeRig("files-other")
        defer { try? FileManager.default.removeItem(at: other.root) }
        try N.addNotebook(other.store, "nb-1")
        let record = try #require(try rig.store.replica.record(zoneKey: N.libraryZoneKey, recordType: "Artifact", wireID: id))
        try N.apply(other.store, [record])
        #expect(try F.text(other.store, "SELECT relative_path FROM notebook_files WHERE notebook_id = 'nb-1'") == "Projects/nb-1/data/counts.tsv")
        let materializer = DocBodyMaterializer(store: MacPrivateSyncStore.direct(other.store), transfer: rig.bodies.transfer)
        #expect(try await materializer.materializeDue()[id] == .applied)
        #expect(try Self.file(other.store, "nb-1", "data/counts.tsv") == bytes)
        try await other.publisher.publishDue(now: Date().addingTimeInterval(3_600))
        #expect(other.bodies.uploadCount == 0, "bytes brought in are never sent back")
    }

    @Test("A Files-tab rescan keeps an inbound file whose bytes have not arrived, and sends no delete for it")
    func rescanKeepsIncomingFiles() async throws {
        let rig = try F.makeRig("files-rescan")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        try Self.addFile(rig.store, notebookID: "nb-1", path: "mine.txt", bytes: Data("mine".utf8))
        try await F.publishAndSend(rig)
        let id = NotebookFileArtifact.wireID(notebookID: "nb-1", path: "remote.bin")
        let body = try rig.bodies.put(Data("remote bytes".utf8), owner: id, mime: "application/octet-stream", encoding: .identity)
        try N.apply(rig.store, [try N.record(.artifact, id, [
            "kind": .string("file"), "title": .string("remote.bin"), "notebookID": .string("nb-1"), "path": .string("remote.bin"),
            "status": .string("active"), "body": body.value, "bodyFormat": .string("binary"),
        ])])
        #expect(try F.text(rig.store, "SELECT COUNT(*) FROM notebook_files WHERE relative_path = 'Projects/nb-1/remote.bin'") == "1")

        // The Files tab lists what is on disk: this Mac's file, not the one on its way.
        let onDisk = try rig.store.loadNotebookFiles(notebookID: "nb-1").filter { $0.notebookRelativePath.hasSuffix("mine.txt") }
        #expect(onDisk.count == 1)
        try rig.store.replaceNotebookFiles(notebookID: "nb-1", with: onDisk)
        #expect(try F.text(rig.store, "SELECT COUNT(*) FROM notebook_files WHERE relative_path = 'Projects/nb-1/remote.bin'") == "1",
                "an index row waiting for its bytes is not a deleted file")
        #expect(try N.pending(rig.store)["Artifact:\(id)"] == nil, "no delete goes to the other devices")
        #expect(try N.pending(rig.store)["Artifact:" + NotebookFileArtifact.wireID(notebookID: "nb-1", path: "mine.txt")] == nil, "an unchanged file queues nothing")

        // Once the bytes have arrived, a file that is gone from disk is deleted as before.
        #expect(try await rig.materializer.materializeDue()[id] == .applied)
        try FileManager.default.removeItem(at: try #require(rig.store.contentDirectory).appendingPathComponent("Projects/nb-1/mine.txt"))
        try rig.store.replaceNotebookFiles(notebookID: "nb-1", with: try rig.store.loadNotebookFiles(notebookID: "nb-1").filter { $0.notebookRelativePath.hasSuffix("remote.bin") })
        #expect(try F.text(rig.store, "SELECT COUNT(*) FROM notebook_files WHERE relative_path = 'Projects/nb-1/mine.txt'") == "0")
    }

    @Test("A file changed here and on another device keeps both: the server's lands beside it, this Mac's goes out")
    func changedOnBothSides() async throws {
        let rig = try F.makeRig("files-both")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        try Self.addFile(rig.store, notebookID: "nb-1", path: "plan.md", bytes: Data("v1".utf8))
        try await F.publishAndSend(rig)
        let id = NotebookFileArtifact.wireID(notebookID: "nb-1", path: "plan.md")
        try Self.addFile(rig.store, notebookID: "nb-1", path: "plan.md", bytes: Data("v2 mine".utf8), at: Date())

        let theirs = try rig.bodies.put(Data("v2 theirs".utf8), owner: id, mime: "text/markdown", encoding: .identity)
        let held = try #require(try N.held(rig.store, .artifact, id))
        var fields = held.fields
        fields["body"] = theirs.value
        try N.apply(rig.store, [try N.record(.artifact, id, fields, ms: 1_799_000_000_000)])
        #expect(try await rig.materializer.materializeDue()[id] == .held)
        #expect(try Self.file(rig.store, "nb-1", "plan.md") == Data("v2 mine".utf8))
        #expect(try Self.file(rig.store, "nb-1", "plan (from another device).md") == Data("v2 theirs".utf8))
        try await F.publishAndSend(rig)
        #expect(try N.held(rig.store, .artifact, id)?.fields["body"].flatMap(FileRef.init(json:))?.hash == SyncIdentity.sha256Hex(Data("v2 mine".utf8)))
    }

    @Test("A file deleted on another device goes here, and one deleted here is deleted on the server")
    func deletes() async throws {
        let rig = try F.makeRig("files-delete")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try N.addNotebook(rig.store, "nb-1")
        try Self.addFile(rig.store, notebookID: "nb-1", path: "a.txt", bytes: Data("a".utf8))
        try Self.addFile(rig.store, notebookID: "nb-1", path: "b.txt", bytes: Data("b".utf8))
        try await F.publishAndSend(rig)
        let a = NotebookFileArtifact.wireID(notebookID: "nb-1", path: "a.txt")
        let b = NotebookFileArtifact.wireID(notebookID: "nb-1", path: "b.txt")

        try F.applyDeletion(rig.store, .artifact, a)
        #expect(try F.text(rig.store, "SELECT COUNT(*) FROM notebook_files WHERE relative_path = 'Projects/nb-1/a.txt'") == "0")
        #expect(try Self.file(rig.store, "nb-1", "a.txt") == nil)

        try rig.store.execute("DELETE FROM notebook_files WHERE relative_path = 'Projects/nb-1/b.txt'")
        #expect(try N.pending(rig.store)["Artifact:\(b)"]?.action == .delete)
    }
}
