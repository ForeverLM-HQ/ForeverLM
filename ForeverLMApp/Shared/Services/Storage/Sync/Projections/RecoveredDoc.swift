import Foundation
import OSLog

extension Notification.Name {
    /// A body this Mac had edited lost to a delete or to an overlapping edit and was kept as a Doc
    /// "Recovered: <title>" (§6.2). `userInfo["artifactID"]` names the new Doc. Posted off the main actor.
    static let recoveredDocMade = Notification.Name("ForeverLM.recoveredDocMade")
}

/// A "Recovered:" Doc (docs/cloudkit-schema-design.md §4.1, §6.2, R6-3): a body this Mac edited and the
/// server no longer takes (its record was deleted elsewhere, or its notes overlapped another device's) is
/// kept as a new Doc in the same notebook under `recovered:<artifactID>:<hash of the body>`. The id is
/// deterministic, so a second recovery of the same body finds the first and makes nothing. A body already
/// uploaded keeps its FileRef verbatim (D41: the satellites keep their owner's names); one never sent is
/// published later like any Doc. The Doc is the learner's own write and goes out as one, even when it is
/// made inside an apply.
enum RecoveredDoc {
    static let titlePrefix = "Recovered: "
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "RecoveredDoc")

    static func id(artifactID: String, hash: String) -> String { "recovered:\(artifactID):\(hash)" }

    /// Before an Artifact's rows go (an inbound deletion, or `unknownItem` on a save): its body, when this
    /// Mac holds an edit of it the server never took, becomes a Recovered Doc.
    static func keepPendingBody(of record: ProjectionRecordRef, connection: SQLiteConnection) throws {
        guard let store = connection as? KnowledgeStore else { return }
        let artifactID = record.localID
        if let notebookID = NotesDoc.notebookID(of: artifactID) {
            guard let notes = try store.scalarText("SELECT notes FROM learning_goals WHERE id = ?", [.text(notebookID)]) else { return }
            let mine = NotesDoc.text(notes)
            guard !mine.isEmpty, try NotesBase.load(notebookID: notebookID, connection: store).map(NotesDoc.text) != mine else { return }
            _ = try keepNotes(mine, notebookID: notebookID, in: store)
            return
        }
        var row: (title: String, home: String?, bodyRef: String?)?
        try store.query("SELECT title, home_notebook_id, body_ref FROM global_artifacts WHERE id = ?", [.text(artifactID)]) {
            row = ($0.text(0) ?? "", $0.text(1), $0.text(2))
        }
        guard let row else { return }
        let held = try store.replica.record(zoneKey: record.zoneKey, recordType: SyncRecordType.artifact.rawValue, wireID: record.wireID)
            .flatMap { try? SyncEnvelope(storedPayload: $0.payload) }?.fields["body"].flatMap(FileRef.init(json:))
        let pointer = ArtifactBody.fileRef(row.bodyRef)
        // Sent and not acknowledged: its bytes are on the server, so the FileRef is kept verbatim.
        if let pointer, pointer != held {
            try make(in: store, artifactID: artifactID, hash: pointer.hash, title: row.title, notebookID: row.home, bodyRef: pointer, copying: artifactID, text: nil)
            return
        }
        // Edited here and not sent yet: the files are copied and published like any Doc's.
        guard let package = try store.loadArtifactBodyPackageForSync(artifactID),
              package.revision != (held ?? pointer)?.hash else { return }
        try make(in: store, artifactID: artifactID, hash: package.revision, title: row.title, notebookID: row.home, bodyRef: nil, copying: artifactID, text: nil)
    }

    /// A notebook's notes this Mac wrote and the server's overlapping notes replace. Returns the
    /// Recovered Doc's id.
    @discardableResult
    static func keepNotes(_ text: String, notebookID: String, in store: KnowledgeStore) throws -> String {
        let artifactID = NotesDoc.id(notebookID: notebookID)
        let hash = SyncIdentity.sha256Hex(Data(text.utf8))
        try make(in: store, artifactID: artifactID, hash: hash, title: NotesDoc.title, notebookID: notebookID, bodyRef: nil, copying: nil, text: text)
        return id(artifactID: artifactID, hash: hash)
    }

    /// A body generation 1 held for the writer beside a Doc (`document.remote.md`, kept when its
    /// three-way merge overlapped, §13.3 step 3c, R8-m8): no generation-2 surface reads a held body, so
    /// it is saved as `recovered:<artifactID>:<hash of its text>` before the derivations. Returns the id.
    @discardableResult
    static func keepHeldRemote(_ markdown: String, artifactID: String, title: String, notebookID: String?, in store: KnowledgeStore) throws -> String {
        let hash = SyncIdentity.sha256Hex(Data(markdown.utf8))
        try make(in: store, artifactID: artifactID, hash: hash, title: title, notebookID: notebookID, bodyRef: nil, copying: nil, text: markdown)
        return id(artifactID: artifactID, hash: hash)
    }

    private static func make(in store: KnowledgeStore, artifactID: String, hash: String, title: String, notebookID: String?,
                             bodyRef: FileRef?, copying sourceID: String?, text: String?) throws {
        let id = id(artifactID: artifactID, hash: hash)
        guard try store.scalarInteger("SELECT EXISTS(SELECT 1 FROM global_artifacts WHERE id = ?)", [.text(id)]) != 1 else { return }
        guard let folder = store.artifactFolder(id) else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
        if let sourceID, let source = store.artifactFolder(sourceID), fileManager.fileExists(atPath: source.path) {
            try fileManager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: folder)
            // This device's bookkeeping about the old record is not the new Doc's.
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            where name == "document.base.md" || name == "document.remote.md" || name == KnowledgeStore.appliedBodyName || name.hasPrefix("document.sent-") {
                try? fileManager.removeItem(at: folder.appendingPathComponent(name))
            }
        } else {
            try store.writeArtifactMarkdown(text ?? "", artifactID: id)
        }
        let home = try notebookID.flatMap { notebook in
            try store.scalarInteger("SELECT EXISTS(SELECT 1 FROM learning_goals WHERE id = ?)", [.text(notebook)]) == 1 ? notebook : nil
        }
        let now = Date().timeIntervalSinceReferenceDate
        try store.outsideApplyGuard {
            try store.execute("""
                INSERT INTO global_artifacts (id, title, home_notebook_id, is_draft, created_at, updated_at, body_ref, wire_id)
                VALUES (?, ?, ?, 0, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
            """, [.text(id), .text(titlePrefix + title), .text(home), .real(now), .real(now), .text(bodyRef.map(ArtifactBody.text)), .text(id)])
            if let home {
                try store.execute("""
                    INSERT INTO global_artifact_notebook_links (artifact_id, notebook_id, linked_at) VALUES (?, ?, ?)
                    ON CONFLICT(artifact_id, notebook_id) DO NOTHING
                """, [.text(id), .text(home), .real(now)])
            }
        }
        logger.notice("Kept a body that lost as \(id, privacy: .private)")
        NotificationCenter.default.post(name: .recoveredDocMade, object: nil, userInfo: ["artifactID": id])
    }
}
