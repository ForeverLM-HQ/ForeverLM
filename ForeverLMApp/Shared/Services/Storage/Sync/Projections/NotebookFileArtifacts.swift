import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A notebook's workspace file as `Artifact(kind file)` (docs/cloudkit-schema-design.md §3.5.15, §10:
/// "files in a notebook never reach another device"). Its id is `file:<notebookID>:<sha256 of its path in
/// the workspace>`; its local row is the `notebook_files` index row, whose id is the workspace's own
/// (`project-file:v1:<notebook>:<relative path>`), and its bytes are the file, published on idle like a
/// Doc body (`DocBodyPublisher`) and brought in by `DocBodyMaterializer`. A file has no merge base: one
/// changed here since the bytes this Mac last held keeps its text, the server's version lands beside it
/// as "<name> (from another device)", and the local one goes out next. A file whose notebook was deleted
/// is unfiled locally (`notebook_id` NULL) and keeps its record, which readers show unfiled because its
/// notebook is gone. Generation 2 only.
enum NotebookFileArtifact {
    static let kind = "file"
    static let bodyFormat = "binary"
    /// The server's pointer while its bytes are being brought in; `#body` is the pointer this Mac holds
    /// the bytes of, which tells a local change from a stale file.
    static let incomingKey = "#incoming"

    static func localID(notebookID: String, relativePath: String) -> String {
        SHA256.hash(data: Data("project-file:v1:\(notebookID):\(relativePath)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The path inside the notebook's workspace: `Projects/<notebook>/` left off.
    static func workspacePath(_ relativePath: String) -> String {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        return components.count > 2 ? components.dropFirst(2).joined(separator: "/") : (components.last.map(String.init) ?? relativePath)
    }

    static func relativePath(notebookID: String, path: String) -> String { "Projects/\(notebookID)/\(path)" }

    static func wireID(notebookID: String, path: String) -> String {
        "file:\(notebookID):\(SyncIdentity.sha256Hex(Data(path.utf8)))"
    }

    static func wireID(notebookID: String?, relativePath: String?) -> String? {
        guard let notebookID, !notebookID.isEmpty, let relativePath else { return nil }
        return wireID(notebookID: notebookID, path: workspacePath(relativePath))
    }

    /// The notebook a file's id names.
    static func notebookID(of wireID: String) -> String? {
        guard wireID.hasPrefix("file:") else { return nil }
        let rest = wireID.dropFirst(5)
        guard let colon = rest.lastIndex(of: ":") else { return nil }
        return String(rest[..<colon])
    }

    static func mime(_ relativePath: String) -> String {
        UTType(filenameExtension: URL(fileURLWithPath: relativePath).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static let table = ProjectedTable(
        "notebook_files", localKey: ["id"], keyColumns: ["id", "notebook_id", "relative_path"],
        syncedColumns: ["name", "size_bytes", "modified_at", "created_at"], recordTypes: [.artifact],
        record: { values in
            guard let id = values["id"]?.textValue,
                  let wire = wireID(notebookID: values["notebook_id"]?.textValue, relativePath: values["relative_path"]?.textValue) else { return nil }
            return RowRecord(type: .artifact, localID: id, personalID: wire)
        },
        localIDSQL: { "\($0).id" }, personalIDSQL: { "\($0).id" }
    )

    struct Row: Equatable, Sendable {
        let id: String
        let notebookID: String
        let relativePath: String
        let name: String
        let sizeBytes: Int64
        let modifiedAt: Double
        let createdAt: Double
        var wireID: String { NotebookFileArtifact.wireID(notebookID: notebookID, path: workspacePath(relativePath)) }
    }

    /// The row a local id or a file's id names: the row itself, or the one of its notebook whose path
    /// hashes to the id (bounded by the notebook's files).
    static func row(for id: String, connection: SQLiteConnection) throws -> Row? {
        var rows: [Row] = []
        let sql = "SELECT id, notebook_id, relative_path, name, size_bytes, modified_at, created_at FROM notebook_files"
        let (condition, parameter): (String, String)
        if let notebookID = notebookID(of: id) { (condition, parameter) = ("notebook_id = ?", notebookID) } else { (condition, parameter) = ("id = ?", id) }
        try connection.query("\(sql) WHERE \(condition)", [.text(parameter)]) { row in
            guard let id = row.text(0), let notebook = row.text(1), let path = row.text(2) else { return }
            rows.append(Row(id: id, notebookID: notebook, relativePath: path, name: row.text(3) ?? "", sizeBytes: row.integer(4) ?? 0,
                            modifiedAt: row.real(5) ?? 0, createdAt: row.real(6) ?? 0))
        }
        return id.hasPrefix("file:") ? rows.first { $0.wireID == id } : rows.first
    }

    static func pointer(_ wireID: String, key: String = ArtifactBody.notesKey, connection: SQLiteConnection) throws -> FileRef? {
        try connection.scalarText("SELECT file_ref FROM artifact_files WHERE artifact_id = ? AND file_key = ?", [.text(wireID), .text(key)])
            .flatMap { ArtifactBody.fileRef($0) }
    }

    static func setPointer(_ wireID: String, key: String, to file: FileRef?, localPath: String?, connection: SQLiteConnection) throws {
        guard let file else {
            try connection.execute("DELETE FROM artifact_files WHERE artifact_id = ? AND file_key = ?", [.text(wireID), .text(key)])
            return
        }
        try connection.execute("""
            INSERT INTO artifact_files (artifact_id, file_key, file_ref, local_path) VALUES (?, ?, ?, ?)
            ON CONFLICT(artifact_id, file_key) DO UPDATE SET file_ref = excluded.file_ref, local_path = excluded.local_path
        """, [.text(wireID), .text(key), .text(ArtifactBody.text(file)), .text(localPath)])
    }

    // MARK: The record

    static func encode(_ row: Row, body: FileRef?) -> [String: SyncJSON] {
        var fields: [String: SyncJSON] = [
            "kind": .string(kind), "title": .string(row.name), "notebookID": .string(row.notebookID),
            "path": .string(workspacePath(row.relativePath)), "status": .string("active"),
            "createdAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: row.createdAt)),
            "editedAt": SyncJSON(SyncTime.milliseconds(cocoaSeconds: row.modifiedAt)),
        ]
        if let body {
            fields["body"] = body.value
            fields["bodyFormat"] = .string(bodyFormat)
        }
        return fields
    }

    /// An inbound file: its index row (kept where it is when this Mac holds it), and the server's
    /// pointer for the materializer.
    static func apply(_ fields: [String: SyncJSON], wireID: String, zoneKey: String, connection: SQLiteConnection) throws -> ProjectionApplyOutcome {
        guard let notebookID = fields["notebookID"]?.stringValue ?? notebookID(of: wireID), let path = fields["path"]?.stringValue else { return .projected }
        let relative = relativePath(notebookID: notebookID, path: path)
        let created = fields["createdAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? Date().timeIntervalSinceReferenceDate
        let edited = fields["editedAt"]?.int64Value.map { SyncTime.cocoaSeconds(milliseconds: $0) } ?? created
        let body = fields["body"].flatMap(FileRef.init(json:))
        try connection.execute("""
            INSERT INTO notebook_files (id, notebook_id, relative_path, name, role, content_type, size_bytes, modified_at, created_at)
            VALUES (?, ?, ?, ?, 'file', ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name
        """, [
            .text(localID(notebookID: notebookID, relativePath: relative)), .text(notebookID), .text(relative),
            .text(fields["title"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent),
            .text(UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.identifier), .integer(body?.size ?? 0),
            .real(edited), .real(created),
        ])
        guard let body, body != (try pointer(wireID, connection: connection)) else { return .projected }
        try setPointer(wireID, key: incomingKey, to: body, localPath: relative, connection: connection)
        try DocBodyJobs.queueFetch(artifactID: wireID, zoneKey: zoneKey, connection: connection)
        return .projected
    }

    static func applyDeletion(_ wireID: String, connection: SQLiteConnection) throws {
        if let row = try row(for: wireID, connection: connection) {
            try connection.execute("DELETE FROM notebook_files WHERE id = ?", [.text(row.id)])
            if let url = (connection as? KnowledgeStore)?.contentDirectory?.appendingPathComponent(row.relativePath) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try connection.execute("DELETE FROM artifact_files WHERE artifact_id = ?", [.text(wireID)])
        try DocBodyJobs.forget(artifactID: wireID, connection: connection)
    }

    // MARK: The bytes

    /// The files due for publishing: idle for 30 s (their modification time), not being brought in, and
    /// holding bytes other than the pointer's. A file is hashed once per change of its size and time.
    static func candidates(in store: KnowledgeStore, now: Date, forcing: Set<String>,
                           hashes: inout [String: (fingerprint: String, hash: String)]) throws -> [DocBodyPublisher.Candidate] {
        var rows: [Row] = []
        try store.query("""
            SELECT f.id, f.notebook_id, f.relative_path, f.name, f.size_bytes, f.modified_at, f.created_at FROM notebook_files f
            JOIN learning_goals g ON g.id = f.notebook_id WHERE g.team_id IS NULL ORDER BY f.id
        """, []) { row in
            guard let id = row.text(0), let notebook = row.text(1), let path = row.text(2) else { return }
            rows.append(Row(id: id, notebookID: notebook, relativePath: path, name: row.text(3) ?? "", sizeBytes: row.integer(4) ?? 0,
                            modifiedAt: row.real(5) ?? 0, createdAt: row.real(6) ?? 0))
        }
        var candidates: [DocBodyPublisher.Candidate] = []
        for row in rows {
            let wire = row.wireID
            guard forcing.contains(wire) || now.timeIntervalSinceReferenceDate - row.modifiedAt >= DocBodyPublisher.idleInterval,
                  try !DocBodyJobs.isPending(artifactID: wire, connection: store),
                  let url = store.contentDirectory?.appendingPathComponent(row.relativePath) else { continue }
            let pointer = try pointer(wire, connection: store)
            let fingerprint = "\(row.sizeBytes)|\(row.modifiedAt)"
            if let known = hashes[wire], known.fingerprint == fingerprint, known.hash == pointer?.hash { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let hash = SyncIdentity.sha256Hex(data)
            hashes[wire] = (fingerprint, hash)
            guard hash != pointer?.hash else { continue }
            candidates.append(DocBodyPublisher.Candidate(artifactID: wire, owner: wire,
                                                         body: .file(data: data, mime: mime(row.relativePath), relativePath: row.relativePath, keeping: pointer)))
        }
        return candidates
    }

    /// Brings in a file's server bytes: written over a file this Mac has not changed since the bytes it
    /// last held, else beside it as "<name> (from another device)".
    static func materialize(_ wireID: String, incoming: FileRef, bytes: Data, in store: KnowledgeStore) throws -> DocBodyMaterializer.Outcome {
        guard let row = try row(for: wireID, connection: store), let url = store.contentDirectory?.appendingPathComponent(row.relativePath) else {
            return .unchanged
        }
        let held = try pointer(wireID, connection: store)
        let local = try? Data(contentsOf: url)
        let outcome: DocBodyMaterializer.Outcome
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let local, SyncIdentity.sha256Hex(local) == incoming.hash {
            outcome = .unchanged
        } else if let local, SyncIdentity.sha256Hex(local) != held?.hash {
            let stem = url.deletingPathExtension().lastPathComponent
            let copy = url.deletingLastPathComponent().appendingPathComponent("\(stem) (from another device)")
                .appendingPathExtension(url.pathExtension)
            try bytes.write(to: copy, options: .atomic)
            outcome = .held
        } else {
            try bytes.write(to: url, options: .atomic)
            outcome = .applied
        }
        try store.replica.apply { _ in
            try setPointer(wireID, key: ArtifactBody.notesKey, to: incoming, localPath: row.relativePath, connection: store)
            try setPointer(wireID, key: incomingKey, to: nil, localPath: nil, connection: store)
        }
        return outcome
    }
}
