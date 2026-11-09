import Foundation
import OSLog

// MARK: - Fetching a body that arrived (docs/cloudkit-schema-design.md §6.2 step 4, §3.5.30 rule 2)

/// The bodies an inbound Artifact pointed at that this Mac has not brought in yet, as `ck_blob_jobs`
/// rows of direction `body` whose `content_id` names the Artifact. An apply writes the pointer and queues
/// the fetch (it cannot wait on the network inside its transaction, §6.6 step 2); the materializer
/// fetches, applies or merges, and clears the row. While one is queued the publisher leaves that body
/// alone, so a local edit is merged with the server's body before it goes out.
enum DocBodyJobs {
    static let direction = "body"

    /// `record_name` is part of the table's unique key, so a record the replica does not hold yet (a catch-up
    /// or late import notebooks before it stores) is named by its Artifact's id, never by an empty string
    /// that a second Doc's job would collide with.
    static func queueFetch(artifactID: String, zoneKey: String, connection: SQLiteConnection, now: Date = Date()) throws {
        let recordName = try connection.scalarText(
            "SELECT record_name FROM ck_records WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
            [.text(zoneKey), .text(SyncRecordType.artifact.rawValue), .text(artifactID)]
        ) ?? artifactID
        try forget(artifactID: artifactID, connection: connection)
        try connection.execute("""
            INSERT INTO ck_blob_jobs (direction, zone_key, record_name, content_id, state, enqueued_at, updated_at)
            VALUES (?, ?, ?, ?, 'queued', ?, ?)
        """, [.text(direction), .text(zoneKey), .text(recordName), .text(artifactID), .real(now.timeIntervalSinceReferenceDate), .real(now.timeIntervalSinceReferenceDate)])
    }

    static func forget(artifactID: String, connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM ck_blob_jobs WHERE direction = ? AND content_id = ?", [.text(direction), .text(artifactID)])
    }

    static func isPending(artifactID: String, connection: SQLiteConnection) throws -> Bool {
        try connection.scalarInteger(
            "SELECT EXISTS(SELECT 1 FROM ck_blob_jobs WHERE direction = ? AND content_id = ?)", [.text(direction), .text(artifactID)]
        ) == 1
    }

    struct Job: Equatable, Sendable {
        let id: Int64
        let zoneKey: String
        let artifactID: String
    }

    /// How long a body that failed five times waits before it is tried again: the publisher leaves a Doc
    /// alone while its fetch is queued (a local edit must merge with the server's body first), so a fetch
    /// that is never retried would block that Doc's publishing for good.
    static let retryAfterFailures: TimeInterval = 3_600

    /// The queued fetches, oldest first; a body that failed five times waits an hour for its next try.
    static func pending(connection: SQLiteConnection, limit: Int = 20, now: Date = Date()) throws -> [Job] {
        var jobs: [Job] = []
        try connection.query("""
            SELECT id, zone_key, content_id FROM ck_blob_jobs
            WHERE direction = ? AND (attempts < 5 OR updated_at <= ?) ORDER BY attempts, enqueued_at, id LIMIT ?
        """, [.text(direction), .real(now.timeIntervalSinceReferenceDate - retryAfterFailures), .integer(Int64(limit))]) { row in
            if let id = row.integer(0), let zone = row.text(1), let artifact = row.text(2) { jobs.append(Job(id: id, zoneKey: zone, artifactID: artifact)) }
        }
        return jobs
    }
}

// MARK: - The bytes, through BlobStore

/// How bodies reach and leave the server: BlobStore in the app (`DocBodyTransfer.blobStore`), a fake in
/// the suites. `upload` returns once every part is acknowledged (§3.5.30 rule 2).
struct DocBodyTransfer: Sendable {
    var upload: @Sendable (_ body: Data, _ owner: String, _ mime: String, _ encoding: BlobStore.Encoding, _ keeping: FileRef?) async throws -> FileRef
    var fetch: @Sendable (_ file: FileRef) async throws -> Data

    /// The private `Content` zone, named with the library's salt. A space's Docs are WP15's.
    static func blobStore(_ blobs: BlobStore, store: MacPrivateSyncStore) -> DocBodyTransfer {
        @Sendable func zone() async throws -> BlobZone {
            guard let zone = try await store.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) }) else {
                throw CloudError(.zoneNotFound, message: "the library's root is not held yet")
            }
            return zone
        }
        return DocBodyTransfer(
            upload: { body, owner, mime, encoding, keeping in
                try await blobs.upload(body, owner: owner, ownerType: .artifact, role: ArtifactBody.role, mime: mime, encoding: encoding,
                                       into: try await zone(), keeping: keeping)
            },
            fetch: { file in try await blobs.fetch(file, from: try await zone()) }
        )
    }
}

// MARK: - The bases a T merge starts from (§6.2 step 4, §13.6, R8-m4)

/// A Notes Doc's base: the `ck_text_bases` entry an acknowledged upload or an applied body wrote, else
/// the notes of the notebook's old record that the catch-up's walk returned (`ck_legacy_bodies`, keyed
/// by the notebook's wire id because the walk runs before this Mac knows the zone's salt). A Doc's base
/// is `document.base.md`, as generation 1 keeps it.
enum NotesBase {
    static let field = "body"
    static let legacyType = SyncRecordType.notebook.rawValue
    static let legacyField = "notes"

    static func load(notebookID: String, connection: SQLiteConnection) throws -> String? {
        if let recordName = try recordName(notebookID: notebookID, connection: connection),
           let text = try connection.scalarText(
               "SELECT base_text FROM ck_text_bases WHERE zone_key = ? AND record_name = ? AND field = ?",
               [.text(PrivateSyncZones.libraryKey), .text(recordName), .text(field)]
           ) {
            return text
        }
        return try connection.scalarText(
            "SELECT base_text FROM ck_legacy_bodies WHERE record_type = ? AND wire_id = ? AND field = ? AND base_text IS NOT NULL",
            [.text(legacyType), .text(notebookID), .text(legacyField)]
        )
    }

    /// The server now holds `text` as the notes body: it is the base the next merge starts from.
    static func save(_ text: String, stamp: String, notebookID: String, connection: SQLiteConnection) throws {
        guard let recordName = try recordName(notebookID: notebookID, connection: connection) else { return }
        try connection.execute("""
            INSERT INTO ck_text_bases (zone_key, record_name, field, base_stamp, base_hash, base_text) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone_key, record_name, field) DO UPDATE SET
                base_stamp = excluded.base_stamp, base_hash = excluded.base_hash, base_text = excluded.base_text
        """, [
            .text(PrivateSyncZones.libraryKey), .text(recordName), .text(field), .text(stamp),
            .text(SyncIdentity.sha256Hex(Data(text.utf8))), .text(text),
        ])
    }

    /// The notes base the catch-up's walk found (WP16a, WP16b2 write it before any root exists).
    static func saveLegacy(_ text: String, notebookID: String, connection: SQLiteConnection) throws {
        try connection.execute("""
            INSERT INTO ck_legacy_bodies (record_type, wire_id, field, base_hash, base_text) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(record_type, wire_id, field) DO UPDATE SET base_hash = excluded.base_hash, base_text = excluded.base_text
        """, [.text(legacyType), .text(notebookID), .text(legacyField), .text(SyncIdentity.sha256Hex(Data(text.utf8))), .text(text)])
    }

    /// The Notes Doc's record name: the replica's once it holds the record, else from `Library`'s salt.
    static func recordName(notebookID: String, connection: SQLiteConnection) throws -> String? {
        let id = NotesDoc.id(notebookID: notebookID)
        if let held = try connection.scalarText(
            "SELECT record_name FROM ck_records WHERE zone_key = ? AND record_type = ? AND wire_id = ?",
            [.text(PrivateSyncZones.libraryKey), .text(SyncRecordType.artifact.rawValue), .text(id)]
        ) {
            return held
        }
        guard let root = try ReplicaStore(connection: connection).record(zoneKey: PrivateSyncZones.libraryKey, recordName: SyncSchema.rootRecordName),
              let salt = (try? SyncEnvelope(storedPayload: root.payload))?.fields["salt"]?.stringValue.flatMap(RecordNaming.salt(base64:))
        else { return nil }
        return RecordNaming.recordName(type: .artifact, id: id, salt: salt)
    }
}

// MARK: - A Doc's files on this Mac

extension KnowledgeStore {
    /// A body sent and not yet acknowledged, kept beside `document.md` under its package hash until the
    /// acknowledgement makes it the base (`document.base.md`), and read for the record's preview.
    static func sentBodyName(hash: String) -> String { "document.sent-\(hash.prefix(16)).md" }

    func artifactFolder(_ artifactID: String) -> URL? {
        artifactMarkdownURL(artifactID)?.deletingLastPathComponent()
    }

    /// When anything in the Doc's folder last changed (`document.md`, its pictures, its site), and a
    /// fingerprint of what is there, for the idle rule (D44); nil when it has no `document.md`.
    func artifactFolderState(_ artifactID: String) -> (lastEdit: Date, fingerprint: String)? {
        guard let folder = artifactFolder(artifactID),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("document.md").path) else { return nil }
        var newest = Date.distantPast
        var parts: [String] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        func visit(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return }
            let modified = values.contentModificationDate ?? .distantPast
            newest = max(newest, modified)
            parts.append("\(url.lastPathComponent):\(values.fileSize ?? 0):\(modified.timeIntervalSinceReferenceDate)")
        }
        visit(folder.appendingPathComponent("document.md"))
        for sub in ["Attachments", KnowledgeStore.localSiteFolderName] {
            guard let enumerator = FileManager.default.enumerator(at: folder.appendingPathComponent(sub), includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator { visit(url) }
        }
        return (newest, parts.sorted().joined(separator: "|"))
    }

    /// The Markdown of the body this Mac last published or took from the server: a sent body first,
    /// then the base, then the file itself.
    func publishedArtifactMarkdown(_ artifactID: String) throws -> String? {
        if let ref = try scalarText("SELECT body_ref FROM global_artifacts WHERE id = ?", [.text(artifactID)]).flatMap({ ArtifactBody.fileRef($0) }),
           let sent = try loadArtifactSidecar(artifactID, name: Self.sentBodyName(hash: ref.hash)) {
            return sent
        }
        return try loadArtifactBaseMarkdown(artifactID) ?? loadArtifactMarkdownForSync(artifactID)
    }

    /// The files a server body was written into, so the publisher never sends them back as an edit
    /// when this Mac's own encoding of them does not reproduce that body's bytes (a package another
    /// client wrote, §13.6): the body's hash and the folder's fingerprint once written.
    static let appliedBodyName = "document.applied"

    func markArtifactBodyApplied(_ artifactID: String, hash: String) throws {
        guard let fingerprint = artifactFolderState(artifactID)?.fingerprint else { return }
        try saveArtifactSidecar(hash + "\n" + fingerprint, artifactID: artifactID, name: Self.appliedBodyName)
    }

    /// Whether the folder still holds exactly the server body `hash` was written as.
    func artifactFolderHoldsAppliedBody(_ artifactID: String, hash: String, fingerprint: String) throws -> Bool {
        try loadArtifactSidecar(artifactID, name: Self.appliedBodyName) == hash + "\n" + fingerprint
    }

    /// The Doc's folder, gone with its record, and this Mac's versions of it.
    func removeArtifactFolder(_ artifactID: String) {
        pageVersionHistory?.removeHistory(of: artifactID)
        guard let folder = artifactFolder(artifactID) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Runs `body` with the apply guard lifted, inside an apply: what it writes is the learner's own
    /// (a Recovered Doc), and goes out like any local write (§6.2).
    func outsideApplyGuard(_ body: () throws -> Void) throws {
        let guarded = try replica.isApplying
        if guarded { try execute("DELETE FROM ck_apply_guard") }
        defer { if guarded { try? execute("INSERT INTO ck_apply_guard (id) VALUES (1)") } }
        try body()
    }
}

// MARK: - Publishing on idle (D44)

/// Publishes Doc and notes bodies: on idle (nothing in the Doc's folder, or the notebook, changed for
/// 30 s), on close, on Publish and before a send that needs them (`publishNow`), never per keystroke.
/// A body is uploaded first and its pointer moved only once every part is acknowledged (§3.5.30 rule
/// 2), so a typing session mints one satellite per idle period. A body whose server version is still
/// being fetched, or one held beside a server version the writer has not chosen between, waits.
/// Generation 2 only.
final class DocBodyPublisher: @unchecked Sendable {
    static let idleInterval: TimeInterval = 30
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "DocBodyPublisher")

    let store: MacPrivateSyncStore
    let transfer: DocBodyTransfer
    private let lock = NSLock()
    /// The package revision a folder fingerprint gave, so an idle Doc is not encoded every round.
    private var revisions: [String: (fingerprint: String, revision: String)] = [:]
    /// The same for a notebook's workspace files.
    private var fileHashes: [String: (fingerprint: String, hash: String)] = [:]

    init(store: MacPrivateSyncStore, transfer: DocBodyTransfer) {
        self.store = store
        self.transfer = transfer
    }

    enum Body {
        case doc(package: Data, markdown: String, revision: String, keeping: FileRef?)
        /// The notes' trimmed text, nil when they were cleared.
        case notes(notebookID: String, text: String?, keeping: FileRef?)
        /// A notebook's workspace file (`NotebookFileArtifact`).
        case file(data: Data, mime: String, relativePath: String, keeping: FileRef?)
    }

    struct Candidate {
        let artifactID: String
        let owner: String
        let body: Body
    }

    /// Publishes every body due at `now`, and those in `forcing` whatever their idle time. Returns the
    /// Artifacts whose pointer moved.
    @discardableResult
    func publishDue(now: Date = Date(), forcing: Set<String> = []) async throws -> [String] {
        let candidates = try await store.onStore { try self.candidates(in: $0, now: now, forcing: forcing) }
        var published: [String] = []
        for candidate in candidates {
            do {
                let file: FileRef?
                switch candidate.body {
                case .doc(let package, _, _, let keeping):
                    file = try await transfer.upload(package, candidate.owner, ArtifactBody.packageMime, .identity, keeping)
                case .file(let data, let mime, _, let keeping):
                    file = try await transfer.upload(data, candidate.owner, mime, .identity, keeping)
                case .notes(_, let text, let keeping):
                    if let text {
                        file = try await transfer.upload(Data(text.utf8), candidate.owner, "text/markdown", .gzip, keeping)
                    } else {
                        file = nil
                    }
                }
                if try await store.onStore({ try Self.movePointer(candidate, to: file, in: $0) }) {
                    published.append(candidate.artifactID)
                }
            } catch {
                Self.logger.error("A body of \(candidate.artifactID, privacy: .private) was not published: \(String(describing: error), privacy: .public)")
            }
        }
        return published
    }

    /// Close, Publish, or a send that needs the body: publishes it now if it moved. The notes of a
    /// notebook go by its Notes Doc's id.
    @discardableResult
    func publishNow(_ artifactID: String, now: Date = Date()) async throws -> Bool {
        try await publishDue(now: now, forcing: [artifactID]).contains(artifactID)
    }

    // MARK: Which bodies are due

    func candidates(in store: KnowledgeStore, now: Date, forcing: Set<String>) throws -> [Candidate] {
        var candidates: [Candidate] = []
        var docs: [(id: String, owner: String, bodyRef: String?)] = []
        try store.query("""
            SELECT id, wire_key, body_ref, kind FROM global_artifacts WHERE team_id IS NULL ORDER BY id
        """, []) { row in
            guard let id = row.text(0), !ArtifactBody.isCardDeck(id: id, kind: row.text(3)) else { return }
            docs.append((id, row.text(1) ?? id, row.text(2)))
        }
        for doc in docs {
            guard let state = store.artifactFolderState(doc.id) else { continue }
            let forced = forcing.contains(doc.id)
            guard forced || now.timeIntervalSince(state.lastEdit) >= Self.idleInterval else { continue }
            guard try !DocBodyJobs.isPending(artifactID: doc.id, connection: store),
                  try store.loadArtifactHeldRemoteMarkdown(doc.id) == nil else { continue }
            let pointer = ArtifactBody.fileRef(doc.bodyRef)
            if let pointer, try store.artifactFolderHoldsAppliedBody(doc.id, hash: pointer.hash, fingerprint: state.fingerprint) { continue }
            let known = lock.withLock { revisions[doc.id] }
            if let known, known.fingerprint == state.fingerprint, known.revision == pointer?.hash { continue }
            guard let markdown = try store.loadArtifactMarkdownForSync(doc.id),
                  let package = try store.loadArtifactBodyPackageForSync(doc.id) else { continue }
            lock.withLock { revisions[doc.id] = (state.fingerprint, package.revision) }
            guard package.revision != pointer?.hash else { continue }
            candidates.append(Candidate(artifactID: doc.id, owner: doc.owner,
                                        body: .doc(package: package.data, markdown: markdown, revision: package.revision, keeping: pointer)))
        }

        var notebooks: [(id: String, notes: String?, updatedAt: Double)] = []
        try store.query(
            "SELECT id, notes, updated_at FROM learning_goals WHERE entity_kind = ? AND team_id IS NULL ORDER BY id",
            [.text(LearningGoalEntityKind.notebook)]
        ) { row in
            if let id = row.text(0) { notebooks.append((id, row.text(1), row.real(2) ?? 0)) }
        }
        for notebook in notebooks {
            let artifactID = NotesDoc.id(notebookID: notebook.id)
            let text = NotesDoc.text(notebook.notes)
            let pointer = try store.scalarText(
                "SELECT file_ref FROM artifact_files WHERE artifact_id = ? AND file_key = ?", [.text(artifactID), .text(ArtifactBody.notesKey)]
            ).flatMap { ArtifactBody.fileRef($0) }
            if text.isEmpty {
                guard pointer != nil else { continue }
            } else if pointer?.hash == SyncIdentity.sha256Hex(Data(text.utf8)) {
                continue
            }
            let forced = forcing.contains(artifactID)
            guard forced || now.timeIntervalSinceReferenceDate - notebook.updatedAt >= Self.idleInterval else { continue }
            guard try !DocBodyJobs.isPending(artifactID: artifactID, connection: store) else { continue }
            candidates.append(Candidate(artifactID: artifactID, owner: artifactID,
                                        body: .notes(notebookID: notebook.id, text: text.isEmpty ? nil : text, keeping: pointer)))
        }
        var hashes = lock.withLock { fileHashes }
        candidates += try NotebookFileArtifact.candidates(in: store, now: now, forcing: forcing, hashes: &hashes)
        lock.withLock { fileHashes = hashes }
        return candidates
    }

    // MARK: Moving the pointer

    /// Writes the pointer of a body whose bytes the server acknowledged, unless an inbound body arrived
    /// meanwhile (its fetch merges first). The sent body is kept until its acknowledgement makes it the
    /// base. Returns whether the pointer moved.
    static func movePointer(_ candidate: Candidate, to file: FileRef?, in store: KnowledgeStore) throws -> Bool {
        guard try !DocBodyJobs.isPending(artifactID: candidate.artifactID, connection: store) else { return false }
        switch candidate.body {
        case .file(_, _, let relativePath, _):
            try NotebookFileArtifact.setPointer(candidate.artifactID, key: ArtifactBody.notesKey, to: file, localPath: relativePath, connection: store)
            return file != nil
        case .doc(_, let markdown, _, _):
            guard let file else { return false }
            try store.saveArtifactSidecar(markdown, artifactID: candidate.artifactID, name: KnowledgeStore.sentBodyName(hash: file.hash))
            try store.execute("UPDATE global_artifacts SET body_ref = ? WHERE id = ?", [.text(ArtifactBody.text(file)), .text(candidate.artifactID)])
            return true
        case .notes(_, let text, _):
            // Cleared notes keep their row, holding JSON null, so the Notes Doc still has a row to go with
            // its notebook.
            var pointer = "null"
            var staged: String?
            if let file, let text {
                pointer = ArtifactBody.text(file)
                staged = try store.stageNotesBody(text, owner: candidate.artifactID, hash: file.hash)
            }
            try store.execute("""
                INSERT INTO artifact_files (artifact_id, file_key, file_ref, local_path) VALUES (?, ?, ?, ?)
                ON CONFLICT(artifact_id, file_key) DO UPDATE SET file_ref = excluded.file_ref, local_path = excluded.local_path
            """, [.text(candidate.artifactID), .text(ArtifactBody.notesKey), .text(pointer), .text(staged)])
            return true
        }
    }
}

extension KnowledgeStore {
    /// A notes body as it was sent, in the staging folder beside the store (relative to its folder), until
    /// its acknowledgement writes the notes base.
    func stageNotesBody(_ text: String, owner: String, hash: String) throws -> String {
        let folder = satelliteStagingFolder.appendingPathComponent(SyncIdentity.sha256Hex(Data(owner.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "notes.\(hash.prefix(16)).md"
        try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
        return "ck-staging/\(folder.lastPathComponent)/\(name)"
    }

    func stagedText(_ relativePath: String) -> String? {
        let url = URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent(relativePath)
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }
}

// MARK: - An acknowledged body becomes the base

extension ArtifactProjection {
    /// The server took a body this Mac sent: for a Doc the sent Markdown becomes `document.base.md`; for
    /// a Notes Doc the sent notes become its `ck_text_bases` entry, which wins over the catch-up's
    /// notes base from then on (§6.2 step 4, R8-m4).
    func acknowledged(_ change: OutboxChange, serverRecord: ReplicaRecord, connection: SQLiteConnection) throws {
        guard !change.zone.isSpace, change.stamps.keys.contains(where: { $0.field == "body" }),
              let store = connection as? KnowledgeStore,
              let server = try? SyncEnvelope(storedPayload: serverRecord.payload) else { return }
        let file = server.fields["body"].flatMap(FileRef.init(json:))
        let stamp: String = if case .value(let stamp)? = server.stamps["body"] { stamp.rawValue } else { "" }
        if let notebookID = NotesDoc.notebookID(of: change.wireID) {
            guard let file else {
                try NotesBase.save("", stamp: stamp, notebookID: notebookID, connection: connection)
                return
            }
            var staged: String?
            try connection.query("SELECT file_ref, local_path FROM artifact_files WHERE artifact_id = ? AND file_key = ?",
                                 [.text(change.wireID), .text(ArtifactBody.notesKey)]) { row in
                if ArtifactBody.fileRef(row.text(0))?.hash == file.hash { staged = row.text(1) }
            }
            if let text = staged.flatMap(store.stagedText) {
                try NotesBase.save(text, stamp: stamp, notebookID: notebookID, connection: connection)
            }
            return
        }
        guard let file, let sent = try store.loadArtifactSidecar(change.wireID, name: KnowledgeStore.sentBodyName(hash: file.hash)) else { return }
        try store.saveArtifactBaseMarkdown(sent, artifactID: change.wireID)
        if let url = store.artifactSidecarURL(change.wireID, name: KnowledgeStore.sentBodyName(hash: file.hash)) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Bringing in a body that arrived, with the T merge (§6.2 step 4)

/// Fetches the bodies inbound pointers named and applies them. A Doc or notes this Mac has not edited
/// since its base takes the server's body. One edited on both sides is merged line by line against the
/// base (`ArtifactThreeWayMerge`, the Docs merge): a clean merge becomes the local body, which the
/// publisher then sends as a new body with a new stamp. A Doc whose edits overlap keeps the writer's text
/// on screen and holds the server's beside it (`document.remote.md`) until the writer chooses
/// (teams-design decision 12); the server keeps its body meanwhile. Notes have no such choice: their
/// overlap, or a merge with no base, keeps the server's notes and saves this Mac's as a Recovered Doc,
/// as the web does. Generation 2 only.
final class DocBodyMaterializer: @unchecked Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "DocBodyMaterializer")

    let store: MacPrivateSyncStore
    let transfer: DocBodyTransfer

    init(store: MacPrivateSyncStore, transfer: DocBodyTransfer) {
        self.store = store
        self.transfer = transfer
    }

    enum Outcome: Equatable, Sendable {
        case applied
        case merged
        case held
        case recovered(String)
        case unchanged
    }

    /// Brings in every queued body. Returns each Artifact's outcome.
    @discardableResult
    func materializeDue() async throws -> [String: Outcome] {
        let jobs = try await store.onStore { store -> [DocBodyJobs.Job] in
            return try DocBodyJobs.pending(connection: store)
        }
        var outcomes: [String: Outcome] = [:]
        for job in jobs {
            do {
                let pointer = try await store.onStore { try Self.pointer(job.artifactID, in: $0) }
                var bytes: Data?
                if let pointer { bytes = try await transfer.fetch(pointer) }
                if let outcome = try await store.onStore({ try Self.apply(job, pointer: pointer, bytes: bytes, in: $0) }) {
                    outcomes[job.artifactID] = outcome
                }
            } catch {
                Self.logger.error("A body of \(job.artifactID, privacy: .private) was not brought in: \(String(describing: error), privacy: .public)")
                try? await store.onStore { store in
                    try store.execute("UPDATE ck_blob_jobs SET attempts = attempts + 1, last_error = ?, updated_at = ? WHERE id = ?", [
                        .text(String(describing: error)), .real(Date().timeIntervalSinceReferenceDate), .integer(job.id),
                    ])
                }
            }
        }
        return outcomes
    }

    static func pointer(_ artifactID: String, in store: KnowledgeStore) throws -> FileRef? {
        if NotebookFileArtifact.notebookID(of: artifactID) != nil {
            return try NotebookFileArtifact.pointer(artifactID, key: NotebookFileArtifact.incomingKey, connection: store)
        }
        if NotesDoc.notebookID(of: artifactID) != nil {
            return try store.scalarText(
                "SELECT file_ref FROM artifact_files WHERE artifact_id = ? AND file_key = ?", [.text(artifactID), .text(ArtifactBody.notesKey)]
            ).flatMap { ArtifactBody.fileRef($0) }
        }
        return try store.scalarText("SELECT body_ref FROM global_artifacts WHERE id = ?", [.text(artifactID)]).flatMap { ArtifactBody.fileRef($0) }
    }

    /// Applies one fetched body, unless the pointer moved again meanwhile (the newer job brings that).
    /// Nil when the job is left for a later round.
    static func apply(_ job: DocBodyJobs.Job, pointer: FileRef?, bytes: Data?, in store: KnowledgeStore) throws -> Outcome? {
        guard try self.pointer(job.artifactID, in: store) == pointer,
              try store.scalarInteger("SELECT EXISTS(SELECT 1 FROM ck_blob_jobs WHERE id = ?)", [.integer(job.id)]) == 1
        else { return nil }
        let outcome: Outcome
        if let notebookID = NotesDoc.notebookID(of: job.artifactID) {
            outcome = try applyNotes(notebookID: notebookID, server: bytes.map { String(decoding: $0, as: UTF8.self) } ?? "",
                                     stamp: try serverStamp(job, in: store), in: store)
        } else if NotebookFileArtifact.notebookID(of: job.artifactID) != nil, let bytes, let pointer {
            outcome = try NotebookFileArtifact.materialize(job.artifactID, incoming: pointer, bytes: bytes, in: store)
        } else if let bytes, let pointer {
            outcome = try applyDoc(job.artifactID, package: bytes, revision: pointer.hash, in: store)
        } else {
            outcome = .unchanged
        }
        try store.execute("DELETE FROM ck_blob_jobs WHERE id = ?", [.integer(job.id)])
        return outcome
    }

    private static func serverStamp(_ job: DocBodyJobs.Job, in store: KnowledgeStore) throws -> String {
        guard let held = try store.replica.record(zoneKey: job.zoneKey, recordType: SyncRecordType.artifact.rawValue, wireID: job.artifactID),
              let envelope = try? SyncEnvelope(storedPayload: held.payload),
              case .value(let stamp)? = envelope.stamps["body"] else { return "" }
        return stamp.rawValue
    }

    static func applyDoc(_ artifactID: String, package: Data, revision: String, in store: KnowledgeStore) throws -> Outcome {
        let theirs = try ArtifactBodyPackage.decode(package, expectedRevision: revision)
        func take() throws -> Outcome {
            _ = try store.saveArtifactBodyPackageFromSync(package, artifactID: artifactID, expectedRevision: revision)
            try store.markArtifactBodyApplied(artifactID, hash: revision)
            return .applied
        }
        guard let mine = try store.loadArtifactMarkdownForSync(artifactID) else { return try take() }
        if try store.loadArtifactBodyPackageForSync(artifactID)?.revision == revision {
            try store.saveArtifactBaseMarkdown(theirs.markdown, artifactID: artifactID)
            return .unchanged
        }
        let base = try store.loadArtifactBaseMarkdown(artifactID)
        // This Mac's body, as a version in its page history, before another
        // device's replaces it or is merged into it (`PageVersionHistory`,
        // docs/docs-design.md "Version history"). Logged, never thrown.
        // Only a page of the learner's own words: a linked Google Doc's or
        // site's text copy and an audio overview's script are not written
        // here, and no page menu offers their versions.
        func keepMine(before incoming: String) {
            guard let record = try? store.loadArtifactForSync(artifactID),
                  !record.isLinked, !record.isAudioOverview else { return }
            store.pageVersionHistory?.keepIfDue(previous: mine, replacedBy: incoming, artifactID: artifactID, reason: .anotherDevice)
        }
        if base == mine || mine == theirs.markdown {
            keepMine(before: theirs.markdown)
            return try take()
        }
        // Both changed: the server's pictures and site land first, so either text can show them.
        try store.writeArtifactAttachments(theirs, artifactID: artifactID)
        if let base, case .merged(let merged) = ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs.markdown) {
            keepMine(before: merged)
            try store.saveArtifactBaseMarkdown(theirs.markdown, artifactID: artifactID)
            try store.writeArtifactMarkdown(merged, artifactID: artifactID)
            return .merged
        }
        try store.saveArtifactHeldRemoteMarkdown(theirs.markdown, artifactID: artifactID)
        try store.saveArtifactBaseMarkdown(theirs.markdown, artifactID: artifactID)
        return .held
    }

    static func applyNotes(notebookID: String, server: String, stamp: String, in store: KnowledgeStore) throws -> Outcome {
        let theirs = NotesDoc.text(server)
        guard let held = try store.scalarText(
            "SELECT COALESCE(notes, '') FROM learning_goals WHERE id = ? AND entity_kind = ?", [.text(notebookID), .text(LearningGoalEntityKind.notebook)]
        ) else { return .unchanged }
        let mine = NotesDoc.text(held)
        func take(_ notes: String) throws {
            try store.execute("UPDATE learning_goals SET notes = ? WHERE id = ?", [.text(notes.isEmpty ? nil : notes), .text(notebookID)])
        }
        defer { try? NotesBase.save(theirs, stamp: stamp, notebookID: notebookID, connection: store) }
        if mine == theirs { return .unchanged }
        let base = try NotesBase.load(notebookID: notebookID, connection: store).map(NotesDoc.text)
        if mine.isEmpty || base == mine {
            try take(theirs)
            return .applied
        }
        if let base, case .merged(let merged) = ArtifactThreeWayMerge.merge(base: base, mine: mine, theirs: theirs) {
            try take(NotesDoc.text(merged))
            return .merged
        }
        let recovered = try RecoveredDoc.keepNotes(mine, notebookID: notebookID, in: store)
        try take(theirs)
        return .recovered(recovered)
    }
}

extension KnowledgeStore {
    /// The pictures and site files of a package, written beside `document.md` without touching it.
    func writeArtifactAttachments(_ decoded: ArtifactBodyPackage.Decoded, artifactID: String) throws {
        guard let folder = artifactFolder(artifactID) else { throw KnowledgeStoreError.invalidData("Invalid artifact identifier.") }
        if let siteFiles = decoded.siteFiles { try writeLocalSiteFiles(siteFiles, artifactID: artifactID) }
        let attachments = folder.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        for attachment in decoded.attachments {
            try attachment.data.write(to: attachments.appendingPathComponent(attachment.token), options: .atomic)
        }
    }

    /// A body this Mac merged: `document.md` takes it, as a local edit the publisher sends.
    func writeArtifactMarkdown(_ markdown: String, artifactID: String) throws {
        guard let url = artifactMarkdownURL(artifactID) else { throw KnowledgeStoreError.invalidData("Invalid artifact identifier.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }
}

// MARK: - In each round

/// The Mac's body work in each private round (`SyncRoundHooks`): bodies inbound pointers named are
/// brought in after the fetch, and idle bodies are published before the send. The Docs editor's close,
/// Publish and a send that needs a body call `publishNow` (`requestPublish`). Generation 2 only: nothing
/// makes one under generation 1.
final class DocBodySync: SyncRoundHooks, @unchecked Sendable {
    nonisolated(unsafe) static weak var current: DocBodySync?

    let publisher: DocBodyPublisher
    let materializer: DocBodyMaterializer

    init(store: MacPrivateSyncStore, transfer: DocBodyTransfer) {
        publisher = DocBodyPublisher(store: store, transfer: transfer)
        materializer = DocBodyMaterializer(store: store, transfer: transfer)
    }

    func afterFetch() async {
        _ = try? await materializer.materializeDue()
    }

    func beforeSend() async {
        _ = try? await publisher.publishDue()
    }

    /// The Doc (or a notebook's Notes Doc) closed, was published or is about to be sent somewhere: its
    /// body goes now rather than on idle. Does nothing under generation 1.
    static func requestPublish(_ artifactID: String) {
        guard let sync = current else { return }
        Task.detached(priority: .utility) {
            _ = try? await sync.publisher.publishNow(artifactID)
        }
    }
}
