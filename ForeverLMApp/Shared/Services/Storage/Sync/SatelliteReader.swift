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
    static let satelliteWishKinds = [ChatSatellites.queueKind, QuizSatellites.queueKind, InboundSourceFiles.queueKind, BookCovers.queueKind]

    /// Gives every wish that failed five times one more try: what "waits for a later launch" means. Run once
    /// a launch. A wish whose parts the server does not hold is left alone (only a newer version of its record,
    /// which saves the wish again, can mend it); any other failure (a bad connection, a full disk, a crash
    /// mid-install) could have passed, and before this a paper whose PDF failed five times stayed "PDF needed"
    /// on that Mac for good. Returns the wishes given another try.
    @discardableResult
    func retryExhaustedSatelliteWishes() throws -> Int {
        let kinds = Self.satelliteWishKinds
        try execute("""
            UPDATE ck_backfill_queue SET attempts = 4
            WHERE kind IN (\(kinds.map { _ in "?" }.joined(separator: ", "))) AND attempts >= 5
              AND COALESCE(last_error, '') NOT LIKE 'missingParts%'
        """, kinds.map { SQLiteValue.text($0) })
        return changedRowCount
    }

    /// The learner's own ready papers whose record names a PDF this Mac never received (no `local_path` on
    /// the pointer) while `papers.local_file_path` names a file anyway: a path this Mac wrote itself (an
    /// ingestion it started before another Mac finished the paper) or an older build's. Both the apply
    /// (`InboundSourceFiles.take`) and the adoption pass skip a paper with a path, so if that file is gone the
    /// PDF the record names is never fetched. The caller checks the disk.
    func papersHoldingAPathInsteadOfTheirPDF() throws -> [(id: String, path: String)] {
        var rows: [(id: String, path: String)] = []
        try query("""
            SELECT p.source_id, p.local_file_path FROM papers p
            JOIN sources s ON s.id = p.source_id
            JOIN source_files f ON f.source_id = p.source_id AND f.role = 'pdf'
            WHERE s.team_id IS NULL AND s.status = 'active' AND s.state = 'ready'
              AND json_extract(f.file_ref, '$.heldBy') IS NULL
              AND COALESCE(f.local_path, '') = '' AND COALESCE(p.local_file_path, '') != ''
              AND NOT EXISTS (SELECT 1 FROM ck_backfill_queue q WHERE q.kind = ? AND q.target = p.source_id)
        """, [.text(InboundSourceFiles.queueKind)]) { row in
            if let id = row.text(0), let path = row.text(1) { rows.append((id, path)) }
        }
        return rows
    }

    /// Forgets the path of papers whose file is gone, so the adoption pass queues the PDF their record names.
    /// Only while the path is still the one the disk was checked for. Under the apply guard: nothing is sent.
    func forgetMissingPaperFiles(_ papers: [(id: String, path: String)]) throws {
        guard !papers.isEmpty else { return }
        try replica.apply { _ in
            for paper in papers {
                try execute(
                    "UPDATE papers SET local_file_path = NULL WHERE source_id = ? AND local_file_path = ?",
                    [.text(paper.id), .text(paper.path)]
                )
            }
        }
    }

    /// The relative file paths of papers and books, for moving home the ones that sit in the iCloud Drive
    /// folder the library left (`StrandedSourceFiles`).
    func relativeSourceFilePaths() throws -> [String] {
        var paths: [String] = []
        for table in ["papers", "book_sources"] {
            try query("""
                SELECT DISTINCT local_file_path FROM \(table)
                WHERE COALESCE(local_file_path, '') != '' AND local_file_path NOT LIKE '/%' AND local_file_path NOT LIKE '%://%'
            """, []) { row in
                if let path = row.text(0) { paths.append(path) }
            }
        }
        return paths
    }

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
    /// `installedPath` is where the reader wrote a file the satellite is (a paper's PDF, a book's cover).
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
                case InboundSourceFiles.referencesRole:
                    return try InboundSourceFiles.receivedReferences(body, sourceID: wish.target, connection: self)
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
            case BookCovers.queueKind:
                guard key == BookCovers.role, let installedPath else { return false }
                return try BookCovers.received(
                    installedPath: installedPath, hash: SyncIdentity.sha256Hex(body), bookID: wish.target, connection: self
                )
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
    private let lock = AppLock()
    private var running = false
    /// The once-a-launch repairs (`launchRepairs`) ran in this process.
    private var repairedThisLaunch = false

    /// Whether the launch repairs move files out of the old iCloud Drive folder: the live reader's, never a
    /// test's, which must not touch the learner's own folders.
    private let movesStrandedFiles: Bool

    init(
        store: MacPrivateSyncStore, fetch: @escaping @Sendable (FileRef) async throws -> Data,
        zonedFetch: (@Sendable (FileRef, String) async throws -> Data)? = nil, movesStrandedFiles: Bool = false
    ) {
        self.store = store
        self.fetch = fetch
        self.zonedFetch = zonedFetch
        self.movesStrandedFiles = movesStrandedFiles
    }

    static func live(blobs: BlobStore, store: MacPrivateSyncStore) -> SatelliteReader {
        SatelliteReader(
            store: store, fetch: DocBodyTransfer.blobStore(blobs, store: store).fetch,
            zonedFetch: { file, zoneKey in
                guard let zone = try await store.perform({ try BlobZone.resolve(zoneKey: zoneKey, in: $0) }) else {
                    throw CloudError(.zoneNotFound, message: "the space's root is not held yet")
                }
                return try await blobs.fetch(file, from: zone)
            },
            movesStrandedFiles: true
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
        var coversWritten = false
        let repair = lock.withLock { () -> Bool in
            guard !repairedThisLaunch else { return false }
            repairedThisLaunch = true
            return true
        }
        if repair { await launchRepairs() }
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
                    if taken > 0, wish.kind == BookCovers.queueKind { coversWritten = true }
                }
                await Task.yield()
            }
        } catch {
            Self.logger.error("The satellite reader stopped: \(String(describing: error), privacy: .public)")
        }
        if sourcesWritten || adopted > 0 { Self.announceSourcesChanged() }
        if coversWritten { Self.announceBooksChanged() }
        return written
    }

    /// What keeps a paper from staying "PDF needed" on one Mac while another holds its PDF, once a launch:
    /// files written into the old iCloud Drive folder move into the content root and the emptied folders go,
    /// so the publisher and every reader find them where new files go; a receiving Mac whose own path for a
    /// paper names a file that is gone drops it, so the PDF the record names is fetched; and wishes that
    /// failed five times get another try. Each repair is logged and never stops the drain. The move runs
    /// before the path check, so a file it just brought home is found there.
    private func launchRepairs() async {
        if movesStrandedFiles {
            do {
                let paths = try await store.onStore { try $0.relativeSourceFilePaths() }
                let moved = StrandedSourceFiles.moveIntoContentRoot(paths)
                if moved > 0 { Self.logger.notice("Moved \(moved) source files from the old iCloud Drive folder into the content root") }
            } catch {
                Self.logger.error("Moving source files home stopped: \(String(describing: error), privacy: .public)")
            }
        }
        do {
            let candidates = try await store.onStore { try $0.papersHoldingAPathInsteadOfTheirPDF() }
            let gone = candidates.filter { StorageService.locateSourceFile($0.path) == nil }
            try await store.onStore { try $0.forgetMissingPaperFiles(gone) }
            if !gone.isEmpty { Self.logger.notice("\(gone.count) papers named a file that is gone; fetching the PDF their record names") }
        } catch {
            Self.logger.error("Checking papers' files stopped: \(String(describing: error), privacy: .public)")
        }
        do {
            let retried = try await store.onStore { try $0.retryExhaustedSatelliteWishes() }
            if retried > 0 { Self.logger.notice("Trying \(retried) satellites that failed five times again") }
        } catch {
            Self.logger.error("Retrying exhausted satellites stopped: \(String(describing: error), privacy: .public)")
        }
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

    /// A book's cover arrived: the book lists read `books` again, as for an inbound Book record.
    private static func announceBooksChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cloudKitSyncRemoteStoreDidChange, object: nil,
                userInfo: [
                    CloudKitSyncNotificationInfo.affectedEntitiesKey: [CloudKitSyncEntity.book.rawValue],
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
                // A book's file another of its chapters already brought is not fetched again.
                let isPDF = wish.kind == InboundSourceFiles.queueKind && key == InboundSourceFiles.pdfRole
                if isPDF, let held = try await store.onStore({ try $0.locallyHeldSourceSatellite(file) }) {
                    body = held
                } else {
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
                }
                // A paper's PDF, or a book's, is a file: written here, off the store, and the row learns where it is.
                var installedPath: String?
                if isPDF, SyncIdentity.sha256Hex(body) == file.hash {
                    let target = wish.target
                    let isBook = try await store.onStore {
                        try InboundSourceFiles.isPageRangeChapter(sourceID: target, connection: $0)
                    }
                    installedPath = try SourceFileInstall.installPDF(body, hash: file.hash, folder: isBook ? "Books" : "Papers")
                } else if wish.kind == BookCovers.queueKind, SyncIdentity.sha256Hex(body) == file.hash {
                    installedPath = try BookCovers.install(body, hash: file.hash)
                }
                let taken = try await store.onStore { try $0.receiveSatellite(wish, key: key, body: body, installedPath: installedPath) }
                if taken { written += 1 } else { failure = "the bytes of \(key) are not the ones wanted" }
            } catch {
                // Offline, rate limited, signed out: nothing about this wish, so it spends no attempt. Five
                // drains while the network was down used to exhaust every wish they met.
                if SourceFilePublisher.isTransient(error) { throw error }
                failure = String(describing: error)
            }
        }
        if let failure, written < wish.files.count {
            try await store.onStore { try $0.failSatelliteWish(wish, message: failure) }
        }
        return written
    }
}

/// The iCloud Drive folder the library left (`StorageService.ubiquityContentRootPath`) is emptied and removed.
/// Until 2026-11-18 the MCP tools still saved papers' PDFs there; the app opened them through its old-root
/// fallback, but the sync publisher read the content root alone, so those papers reached the learner's other
/// Macs with no PDF. Each file a row on this Mac names is moved to the same relative path under the content
/// root: copied (which downloads an evicted file), checked, then deleted from the old folder; one that differs
/// from the file already at that path comes home beside it as `name-from-icloud`. Then every empty
/// folder under the container's `Documents` goes. A file no row here names is left for the Mac whose row names
/// it, which moves it when it runs this; a paper that loses its file that way fetches the PDF its record
/// names (`papersHoldingAPathInsteadOfTheirPDF`).
enum StrandedSourceFiles {
    /// Moves every relative path the old folder holds into the content root, and removes the old folders left
    /// empty. Returns the files moved. Touches the disk: off the main actor only.
    @discardableResult
    static func moveIntoContentRoot(
        _ relativePaths: [String],
        contentRoot: String = StorageService.libraryRootPath,
        oldRoot: String = StorageService.ubiquityContentRootPath
    ) -> Int {
        guard contentRoot != oldRoot else { return 0 }
        let fileManager = FileManager.default
        var moved = 0
        for path in Set(relativePaths) where !path.hasPrefix("/") && !path.contains("..") {
            let source = (oldRoot as NSString).appendingPathComponent(path)
            guard fileManager.fileExists(atPath: source) else { continue }
            var target = (contentRoot as NSString).appendingPathComponent(path)
            if fileManager.fileExists(atPath: target), !fileManager.contentsEqual(atPath: source, andPath: target) {
                // A different file under the same name (an MCP import that collided with one already home, a
                // newer version of a preprint): the rows name the one at home, and this one comes home beside it
                // under a name of its own, so the old folder can go without losing it.
                target = freeName(beside: target, fileManager: fileManager)
            }
            do {
                if !fileManager.fileExists(atPath: target) {
                    try fileManager.createDirectory(
                        atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true
                    )
                    do {
                        // Copying an evicted file downloads it, and the download can time out halfway.
                        try fileManager.copyItem(atPath: source, toPath: target)
                    } catch {
                        try? fileManager.removeItem(atPath: target)
                        throw error
                    }
                }
                guard fileManager.contentsEqual(atPath: source, andPath: target) else {
                    try? fileManager.removeItem(atPath: target)
                    continue
                }
                try fileManager.removeItem(atPath: source)
                moved += 1
            } catch {
                continue
            }
        }
        removeEmptyFolders(under: (oldRoot as NSString).deletingLastPathComponent)
        if moved > 0 { StudioArticle.invalidateAllResolvedPathCaches() }
        return moved
    }

    /// `name-from-icloud.pdf` beside `path`, numbered when that is taken too.
    private static func freeName(beside path: String, fileManager: FileManager) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let ext = (path as NSString).pathExtension
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension + "-from-icloud"
        var candidate = (folder as NSString).appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var number = 2
        while fileManager.fileExists(atPath: candidate) {
            let name = "\(base)-\(number)"
            candidate = (folder as NSString).appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Removes every folder under `root` that holds nothing (Finder's `.DS_Store` counts as nothing), deepest
    /// first; `root` itself stays, since the system owns the container.
    static func removeEmptyFolders(under root: String) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else { return }
        for entry in entries {
            let path = (root as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            removeEmptyFolders(under: path)
            let left = ((try? fileManager.contentsOfDirectory(atPath: path)) ?? ["?"]).filter { $0 != ".DS_Store" }
            if left.isEmpty { try? fileManager.removeItem(atPath: path) }
        }
    }
}

/// Where a paper's or a book's PDF lands on this Mac when it arrives as a satellite.
enum SourceFileInstall {
    /// Writes the PDF under the content root's `folder` (`Papers`, or `Books` for a book kept as one file),
    /// named by its hash so two sources that share the file share the copy, and returns its path relative
    /// to the content roots. A file already there with the same bytes is kept.
    static func installPDF(_ body: Data, hash: String, folder name: String = "Papers") throws -> String {
        let root = KnowledgeStore.installedSourceFileRootOverride ?? URL(fileURLWithPath: StorageService.libraryRootPath, isDirectory: true)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("synced-\(hash.prefix(24)).pdf")
        let held = (try? Data(contentsOf: url, options: .mappedIfSafe)).map(SyncIdentity.sha256Hex)
        if held != hash { try body.write(to: url, options: .atomic) }
        return StorageService.relativeSourcePath(url.path)
    }
}
