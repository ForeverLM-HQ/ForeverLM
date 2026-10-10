import Foundation
import Testing
@testable import ForeverLM

/// Docs, notes and bodies for WP11's suites (docs/cloudkit-schema-design.md §3.5.15, §3.5.16, §6.2
/// step 4, D44): a generation-2 store from `NotebookSyncFixture`, Docs written as the app writes them
/// (`saveArtifactRecord` and `document.md`), and an in-memory stand-in for BlobStore that counts uploads
/// and serves what was uploaded, so the publisher and the materializer run whole without CloudKit.
enum ArtifactSyncFixture {
    typealias N = NotebookSyncFixture

    /// BlobStore's two calls: an upload lays a body out as a native client does and keeps it by hash.
    final class Bodies: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Data] = [:]
        private(set) var uploads: [(owner: String, hash: String)] = []

        var uploadCount: Int { lock.withLock { uploads.count } }

        var transfer: DocBodyTransfer {
            DocBodyTransfer(
                upload: { body, owner, mime, encoding, keeping in
                    let file: FileRef
                    if let keeping, keeping.hash == SyncIdentity.sha256Hex(body) {
                        file = keeping
                    } else {
                        file = try SourceSatelliteLayout.layout(SourceLocalSatellite(
                            map: .files, role: ArtifactBody.role, mime: mime, encoding: encoding, body: body, localPath: nil, input: nil
                        ), owner: owner).file
                    }
                    self.lock.withLock {
                        self.stored[file.hash] = body
                        self.uploads.append((owner, file.hash))
                    }
                    return file
                },
                fetch: { file in
                    guard let body = self.lock.withLock({ self.stored[file.hash] }) else { throw BlobStoreError.missingParts(file.parts) }
                    return body
                }
            )
        }

        /// A body another device uploaded: kept here, its FileRef returned.
        func put(_ body: Data, owner: String, mime: String, encoding: BlobStore.Encoding) throws -> FileRef {
            let file = try SourceSatelliteLayout.layout(SourceLocalSatellite(
                map: .files, role: ArtifactBody.role, mime: mime, encoding: encoding, body: body, localPath: nil, input: nil
            ), owner: owner).file
            lock.withLock { stored[file.hash] = body }
            return file
        }

        /// A Doc body package another device wrote, from its Markdown alone.
        func putDoc(_ markdown: String, owner: String) throws -> FileRef {
            let package = try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: nil)
            return try put(package.data, owner: owner, mime: ArtifactBody.packageMime, encoding: .identity)
        }

        func putNotes(_ text: String, notebookID: String) throws -> FileRef {
            try put(Data(text.utf8), owner: NotesDoc.id(notebookID: notebookID), mime: "text/markdown", encoding: .gzip)
        }
    }

    struct Rig {
        let root: URL
        let store: KnowledgeStore
        let bodies: Bodies
        let publisher: DocBodyPublisher
        let materializer: DocBodyMaterializer
    }

    static func makeRig(_ name: String) throws -> Rig {
        let (root, store) = try N.makeStore("WP11-\(name)")
        try N.prepareReplica(store)
        let bodies = Bodies()
        let synced = MacPrivateSyncStore.direct(store)
        return Rig(root: root, store: store, bodies: bodies,
                   publisher: DocBodyPublisher(store: synced, transfer: bodies.transfer),
                   materializer: DocBodyMaterializer(store: synced, transfer: bodies.transfer))
    }

    /// A Doc as the editor leaves one: its record, then its `document.md` written at `editedAt`.
    static func addDoc(_ store: KnowledgeStore, _ id: String, title: String = "Mitochondria notes", markdown: String,
                       notebookID: String? = nil, editedAt: Date = Date(timeIntervalSinceNow: -120)) throws {
        try store.saveArtifactRecord(ArtifactRecord(
            id: id, title: title, homeNotebookID: notebookID, linkedNotebookIDs: notebookID.map { [$0] } ?? [],
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000), updatedAt: Date(timeIntervalSinceReferenceDate: 2_000)
        ))
        try write(store, id, markdown, at: editedAt)
    }

    /// The editor saves `document.md`, its modification time set to `at`.
    static func write(_ store: KnowledgeStore, _ id: String, _ markdown: String, at date: Date) throws {
        try store.writeArtifactMarkdown(markdown, artifactID: id)
        let url = try #require(store.artifactMarkdownURL(id))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    static func bodyRef(_ store: KnowledgeStore, _ id: String) throws -> FileRef? {
        try store.scalarText("SELECT body_ref FROM global_artifacts WHERE id = ?", [.text(id)]).flatMap { ArtifactBody.fileRef($0) }
    }

    static func notesRef(_ store: KnowledgeStore, _ notebookID: String) throws -> FileRef? {
        try store.scalarText(
            "SELECT file_ref FROM artifact_files WHERE artifact_id = ? AND file_key = ?",
            [.text(NotesDoc.id(notebookID: notebookID)), .text(ArtifactBody.notesKey)]
        ).flatMap { ArtifactBody.fileRef($0) }
    }

    static func notes(_ store: KnowledgeStore, _ notebookID: String) throws -> String? {
        try store.scalarText("SELECT notes FROM learning_goals WHERE id = ?", [.text(notebookID)])
    }

    /// Notes typed into a notebook at `at` (Cocoa seconds of the edit, as the notebook's save leaves).
    static func setNotes(_ store: KnowledgeStore, _ notebookID: String, _ text: String, at date: Date = Date(timeIntervalSinceNow: -120)) throws {
        try store.execute("UPDATE learning_goals SET notes = ?, updated_at = ? WHERE id = ?",
                          [.text(text), .real(date.timeIntervalSinceReferenceDate), .text(notebookID)])
    }

    /// The Artifact record another device sent, every field stamped at `ms`.
    static func docRecord(_ id: String, title: String = "Mitochondria notes", body: FileRef?, ms: Int64 = 1_759_400_000_000,
                          extra: [String: SyncJSON] = [:]) throws -> ReplicaRecord {
        var fields: [String: SyncJSON] = [
            "kind": .string("doc"), "title": .string(title), "status": .string("active"),
            "createdAt": SyncJSON(Int64(1_759_000_000_000)), "editedAt": SyncJSON(ms),
        ]
        if let body { fields["body"] = body.value; fields["bodyFormat"] = .string(ArtifactBody.packageFormat) }
        fields.merge(extra) { _, new in new }
        return try N.record(.artifact, id, fields, ms: ms)
    }

    static func notesRecord(_ notebookID: String, body: FileRef?, ms: Int64 = 1_759_400_000_000) throws -> ReplicaRecord {
        try N.record(.artifact, NotesDoc.id(notebookID: notebookID), [
            "kind": .string("notes"), "title": .string(NotesDoc.title), "notebookID": .string(notebookID),
            "status": .string("active"), "bodyFormat": .string(NotesDoc.bodyFormat), "body": body?.value ?? .null,
            "createdAt": SyncJSON(Int64(1_759_000_000_000)), "editedAt": SyncJSON(ms),
        ], ms: ms)
    }

    /// Publishes what is due well after every idle period, sends it and acknowledges it.
    static func publishAndSend(_ rig: Rig, forcing: Set<String> = []) async throws {
        try await rig.publisher.publishDue(now: Date().addingTimeInterval(3_600), forcing: forcing)
        try N.sendAll(rig.store)
    }

    /// A record deleted on the server while this Mac holds it: its rows go as the engine's apply takes them.
    static func applyDeletion(_ store: KnowledgeStore, _ type: SyncRecordType, _ id: String) throws {
        let held = try #require(try store.replica.record(zoneKey: N.libraryZoneKey, recordType: type.rawValue, wireID: id))
        try store.replica.apply { replica in
            try ProjectionApply(store: store, registry: N.registry).projectDeletion(
                zoneKey: held.zoneKey, recordName: held.recordName, type: type, wireID: id
            )
            try replica.deleteRecord(zoneKey: held.zoneKey, recordName: held.recordName)
        }
    }
}
