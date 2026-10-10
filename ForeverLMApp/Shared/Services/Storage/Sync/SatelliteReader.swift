import CloudKit
import Foundation
import OSLog

// MARK: - The satellite reader (docs/cloudkit-schema-design.md §3.5.30)

/// An inbound record whose text or drawing is a satellite this Mac does not hold (a chat's briefing, a
/// long exchange field, a quiz's questions or picture, a source another device finished ingesting) waits in
/// `ck_backfill_queue` with the FileRefs it wants (`ChatSatellites`, `QuizSatellites`, `InboundSourceFiles`).
/// One queue row is one record; its payload names each wanted satellite by field or role.
struct SatelliteWish: Equatable, Sendable {
    let queueID: Int64
    let kind: String
    let target: String
    /// The wanted FileRef by field (a chat's) or role (a quiz's or a source's).
    let files: [String: FileRef]
    /// The replica zone the bytes are fetched from when it is not the learner's own `Content` zone: a source
    /// in a space (`InboundSourceFiles.zoneField`).
    var zone: String? = nil
}

extension KnowledgeStore {
    static let satelliteWishKinds = [ChatSatellites.queueKind, QuizSatellites.queueKind, InboundSourceFiles.queueKind]

    /// The wishes still worth trying, oldest first; a record that failed five times waits for a later
    /// launch (a newer version of it, which saves its wish again, starts it over).
    func dueSatelliteWishes(limit: Int = 20) throws -> [SatelliteWish] {
        var wishes: [SatelliteWish] = []
        let kinds = Self.satelliteWishKinds
        try query("""
            SELECT q.id, q.kind, q.target, q.payload_json FROM ck_backfill_queue q
            WHERE q.kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))
              AND (
                  q.attempts < 5
                  OR (q.kind = ? AND EXISTS (
                      SELECT 1 FROM source_files held
                      WHERE json_extract(held.file_ref, '$.hash') IN (
                          json_extract(q.payload_json, '$.text.hash'),
                          json_extract(q.payload_json, '$.pdf.hash')
                      )
                        AND (
                            (held.role = 'text' AND EXISTS (
                                SELECT 1 FROM source_content c
                                WHERE c.source_id = held.source_id AND TRIM(c.content) != ''
                            ))
                            OR (held.role = 'pdf' AND COALESCE(held.local_path, '') != '')
                        )
                  ))
              )
            ORDER BY q.attempts, q.id LIMIT ?
        """, kinds.map { SQLiteValue.text($0) } + [
            .text(InboundSourceFiles.queueKind), .integer(Int64(limit)),
        ]) { row in
            guard let id = row.integer(0), let kind = row.text(1), let target = row.text(2) else { return }
            let object = row.text(3).flatMap { try? SyncJSON(parsing: Data($0.utf8)) }?.objectValue ?? [:]
            let files = object.compactMapValues { FileRef(json: $0) }
            wishes.append(SatelliteWish(
                queueID: id, kind: kind, target: target, files: files, zone: object[InboundSourceFiles.zoneField]?.stringValue
            ))
        }
        return wishes
    }

    /// Writes one fetched satellite into its record's row and forgets the wish for it (under the apply
    /// guard, so nothing is sent back). Returns false when the bytes are not the ones now wanted.
    /// `installedPath` is where the reader wrote a file the satellite is (a paper's PDF).
    @discardableResult
    func receiveSatellite(_ wish: SatelliteWish, key: String, body: Data, installedPath: String? = nil) throws -> Bool {
        try replica.apply { _ in
            switch wish.kind {
            case InboundSourceFiles.queueKind:
                switch key {
                case InboundSourceFiles.textRole:
                    let held = try InboundSourceFiles.localTextHash(sourceID: wish.target, connection: self)
                    guard try InboundSourceFiles.receivedText(body, sourceID: wish.target, connection: self) else { return false }
                    // Another Mac's text over this Mac's own copy: the search index still holds the old words.
                    // Not sent back out: the text is the one the record names.
                    if let held, try InboundSourceFiles.localTextHash(sourceID: wish.target, connection: self) != held {
                        try dropCanonicalContentIndexes(sourceID: wish.target)
                    }
                    return true
                case InboundSourceFiles.pdfRole:
                    guard let installedPath else { return false }
                    return try InboundSourceFiles.receivedPDF(body, installedPath: installedPath, sourceID: wish.target, connection: self)
                case InboundSourceFiles.figuresRole:
                    return try InboundSourceFiles.receivedFigures(body, sourceID: wish.target, connection: self)
                default:
                    return false
                }
            case QuizSatellites.queueKind:
                guard let wanted = try QuizSatellites.waiting(quizID: wish.target, connection: self)[key].flatMap(FileRef.init(json:)),
                      wanted.hash == SyncIdentity.sha256Hex(body) else { return false }
                try QuizSatellites.received(body, role: key, quizID: wish.target, connection: self)
                return true
            case ChatSatellites.queueKind:
                guard let colon = wish.target.firstIndex(of: ":"),
                      let type = SyncRecordType(rawValue: String(wish.target[..<colon])) else { return false }
                let id = String(wish.target[wish.target.index(after: colon)...])
                guard let wanted = try ChatSatellites.waiting(type, id, connection: self)[key].flatMap(FileRef.init(json:)),
                      wanted.hash == SyncIdentity.sha256Hex(body) else { return false }
                try ChatSatellites.received(body, field: key, type, id, connection: self)
                return true
            default:
                return false
            }
        }
    }

    func failSatelliteWish(_ wish: SatelliteWish, message: String) throws {
        try execute("UPDATE ck_backfill_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?", [.text(message), .integer(wish.queueID)])
    }

    /// Exact bytes this library already holds under the same content hash.
    ///
    /// FileRefs are content-addressed, so a paper copied between a personal and
    /// space library may legitimately point at the same text and PDF under two
    /// source ids. Requiring CloudKit to serve a second copy is both wasteful and
    /// brittle: an old pointer can outlive one of its blob parts even though the
    /// complete bytes are already on this Mac. Reuse only after hashing the held
    /// body, so a stale path or mismatched row can never satisfy the request.
    func locallyHeldSourceSatellite(_ file: FileRef) throws -> Data? {
        switch file.role {
        case InboundSourceFiles.textRole:
            var bodies: [String] = []
            try query("""
                SELECT c.content
                FROM source_files f JOIN source_content c ON c.source_id = f.source_id
                WHERE f.role = ? AND json_extract(f.file_ref, '$.hash') = ? AND TRIM(c.content) != ''
            """, [.text(file.role), .text(file.hash)]) { row in
                if let body = row.text(0) { bodies.append(body) }
            }
            return bodies.lazy.map { Data($0.utf8) }.first { SyncIdentity.sha256Hex($0) == file.hash }

        case InboundSourceFiles.pdfRole:
            var paths: [String] = []
            try query("""
                SELECT local_path FROM source_files
                WHERE role = ? AND json_extract(file_ref, '$.hash') = ? AND COALESCE(local_path, '') != ''
            """, [.text(file.role), .text(file.hash)]) { row in
                if let path = row.text(0) { paths.append(path) }
            }
            for path in paths {
                let overridden = KnowledgeStore.installedSourceFileRootOverride.map {
                    path.hasPrefix("/") ? path : $0.appendingPathComponent(path).path
                }
                guard let resolved = overridden.flatMap({ FileManager.default.fileExists(atPath: $0) ? $0 : nil })
                        ?? StorageService.locateSourceFile(path),
                      let body = try? Data(contentsOf: URL(fileURLWithPath: resolved), options: .mappedIfSafe),
                      SyncIdentity.sha256Hex(body) == file.hash else { continue }
                return body
            }
            return nil

        default:
            return nil
        }
    }
}

/// Fetches what the queue wants and writes it into the rows, in bounded batches off the main actor, one
/// drain at a time. Run after each inbound round: the records the round applied queued their wishes, and
/// without this reader an inbound quiz keeps `questions_json = '[]'` and an inbound chat never gets the
/// text a long field spilled into a satellite, and a second Mac keeps a source another Mac finished as a
/// `ready` row with no text and no PDF (`InboundSourceFiles`). The bytes are fetched from the private `Content`
/// zone, where a personal record's satellites live, or from the space's own zone for a space's source.
final class SatelliteReader: @unchecked Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "SatelliteReader")

    private let store: MacPrivateSyncStore
    private let fetch: @Sendable (FileRef) async throws -> Data
    private let zonedFetch: (@Sendable (FileRef, String) async throws -> Data)?
    private let lock = NSLock()
    private var running = false

    init(
        store: MacPrivateSyncStore, fetch: @escaping @Sendable (FileRef) async throws -> Data,
        zonedFetch: (@Sendable (FileRef, String) async throws -> Data)? = nil
    ) {
        self.store = store
        self.fetch = fetch
        self.zonedFetch = zonedFetch
    }

    static func live(blobs: BlobStore, store: MacPrivateSyncStore) -> SatelliteReader {
        SatelliteReader(
            store: store, fetch: DocBodyTransfer.blobStore(blobs, store: store).fetch,
            zonedFetch: { file, zoneKey in
                guard let zone = try await store.perform({ try BlobZone.resolve(zoneKey: zoneKey, in: $0) }) else {
                    throw CloudError(.zoneNotFound, message: "the space's root is not held yet")
                }
                return try await blobs.fetch(file, from: zone)
            }
        )
    }

    /// Starts a drain on a utility task unless one is running.
    func drainSoon() {
        let start = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) { [self] in
            _ = await drain()
            lock.withLock { running = false }
        }
    }

    /// Reads batches until none is left that this drain has not tried: a wish that failed spends one
    /// attempt per drain, never five at once. Returns the satellites written.
    @discardableResult
    func drain(batch: Int = 20) async -> Int {
        var written = 0
        var tried = Set<Int64>()
        var adopted = 0
        var sourcesWritten = false
        // First what the records applied before this Mac took their work left behind, and the sources
        // whose satellite pointer arrived after the record did: queued as the apply queues them.
        do {
            for _ in 0..<40 {
                let handled = try await store.onStore { try $0.adoptSyncedSources(limit: 50) }
                adopted += handled
                if handled < 50 { break }
                await Task.yield()
            }
        } catch {
            Self.logger.error("Adopting the sources another Mac finished stopped: \(String(describing: error), privacy: .public)")
        }
        do {
            while true {
                let wishes = try await store.onStore { try $0.dueSatelliteWishes(limit: batch) }.filter { !tried.contains($0.queueID) }
                guard !wishes.isEmpty else { break }
                for wish in wishes {
                    tried.insert(wish.queueID)
                    let taken = try await read(wish)
                    written += taken
                    if taken > 0, wish.kind == InboundSourceFiles.queueKind { sourcesWritten = true }
                }
                await Task.yield()
            }
        } catch {
            Self.logger.error("The satellite reader stopped: \(String(describing: error), privacy: .public)")
        }
        if sourcesWritten || adopted > 0 { Self.announceSourcesChanged() }
        return written
    }

    /// The rows under the view model's sources changed (text, a PDF, an attestation): the same event an inbound
    /// Source record raises, so the list reloads from the store and the search index catches up.
    private static func announceSourcesChanged() {
        StudioArticle.invalidateAllResolvedPathCaches()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cloudKitSyncRemoteStoreDidChange, object: nil,
                userInfo: [
                    CloudKitSyncNotificationInfo.affectedEntitiesKey: [CloudKitSyncEntity.source.rawValue],
                    CloudKitSyncNotificationInfo.requiresFullRefreshKey: false,
                ]
            )
        }
    }

    private func read(_ wish: SatelliteWish) async throws -> Int {
        var written = 0
        var failure: String?
        for (key, file) in wish.files.sorted(by: { $0.key < $1.key }) {
            do {
                let body: Data
                do {
                    if let zone = wish.zone, let zonedFetch {
                        body = try await zonedFetch(file, zone)
                    } else {
                        body = try await fetch(file)
                    }
                } catch {
                    guard wish.kind == InboundSourceFiles.queueKind,
                          let held = try await store.onStore({ try $0.locallyHeldSourceSatellite(file) }) else {
                        throw error
                    }
                    body = held
                }
                // A paper's PDF is a file: written here, off the store, and the row learns where it is.
                var installedPath: String?
                if wish.kind == InboundSourceFiles.queueKind, key == InboundSourceFiles.pdfRole, SyncIdentity.sha256Hex(body) == file.hash {
                    installedPath = try SourceFileInstall.installPDF(body, hash: file.hash)
                }
                let taken = try await store.onStore { try $0.receiveSatellite(wish, key: key, body: body, installedPath: installedPath) }
                if taken { written += 1 } else { failure = "the bytes of \(key) are not the ones wanted" }
            } catch {
                failure = String(describing: error)
            }
        }
        if let failure, written < wish.files.count {
            try await store.onStore { try $0.failSatelliteWish(wish, message: failure) }
        }
        return written
    }
}

/// Where a paper's PDF lands on this Mac when it arrives as a satellite.
enum SourceFileInstall {
    /// Writes the PDF under the content root's `Papers` folder, named by its hash so two sources that share
    /// the file share the copy, and returns its path relative to the content roots. A file already there
    /// with the same bytes is kept.
    static func installPDF(_ body: Data, hash: String) throws -> String {
        let root = KnowledgeStore.installedSourceFileRootOverride ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true)
        let folder = root.appendingPathComponent("Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("synced-\(hash.prefix(24)).pdf")
        let held = (try? Data(contentsOf: url, options: .mappedIfSafe)).map(SyncIdentity.sha256Hex)
        if held != hash { try body.write(to: url, options: .atomic) }
        return StorageService.relativeSourcePath(url.path)
    }
}
