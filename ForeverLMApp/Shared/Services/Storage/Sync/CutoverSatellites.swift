import Foundation
import OSLog

// MARK: - P5: the satellites

/// One body the seed uploads: the pointer a record already carries, and where its bytes are.
struct SeedSatellite: Sendable {
    enum Origin: Sendable {
        /// A file on this Mac, relative to the content roots or, under `ck-staging/`, the store's folder.
        case file(String)
        /// A Doc's body package (`SeedDocBodies`).
        case docBody(artifactID: String, keepsSite: Bool)
        /// A source's narration in the Mac's working folder (§3.5.30): the manifest file, and the chunk files its
        /// FileRef's children name by key. Its pointer was written once the bytes were up in the zones of the
        /// time; a library uploaded again (a new salt) needs them in its own.
        case narration(sourceID: String)
        /// A source's text or review guide laid out in a table (staged as gzip under `ck-staging/`).
        case none
    }

    let ownerType: SyncRecordType
    let ref: FileRef
    let origin: Origin
    let priority: Int
}

/// Uploads every satellite a pointer names (§13.4 step 2, P5), in priority order, after the canary
/// passed: text first, then the pictures a list shows, Doc bodies, and the big files last. Every satellite
/// is existence-checked by name first and its payload compared, so a resumed or repeated seed uploads
/// nothing twice (`BlobStore.upload(keeping:)`, rule 8). The pointers are already on the records (the seed
/// sends pointers and then bytes, rule 2's one exception). Runs only while the engine's record backlog is
/// under 200, so satellites never hold small records back (D43).
struct CutoverSatellites: Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "CutoverSeed")

    let store: MacPrivateSyncStore
    let blobs: BlobStore
    let pendingCount: @Sendable () async -> Int
    var backlogLimit = 200
    var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var clock: @Sendable () -> Date = { Date() }

    /// Roles in the order the seed uploads them (§13.4 step 2, P5).
    static let rolePriority: [String] = [
        "text", "thumbnail", "cover", "icon", "reviewGuide", "walkthrough", "figures", "ideas", "citedPapers", "readerHTML", "epub",
        "pdf", "listenText", "timing", "slides", "raw",
    ]

    static func priority(role: String) -> Int {
        let base = role.split(separator: ".").first.map(String.init) ?? role
        return rolePriority.firstIndex(of: base) ?? rolePriority.count
    }

    /// Every pointer of this store, in priority order.
    func satellites(in store: KnowledgeStore) throws -> [SeedSatellite] {
        var found: [SeedSatellite] = []
        for table in [("source_files", "role"), ("source_derived", "kind")] {
            try store.query("""
                SELECT f.file_ref, f.local_path, f.source_id FROM \(table.0) f JOIN sources s ON s.id = f.source_id WHERE s.team_id IS NULL
            """, []) { row in
                guard let ref = ArtifactBody.fileRef(row.text(0)) else { return }
                let origin: SeedSatellite.Origin
                if let path = row.text(1) {
                    origin = .file(path)
                } else if NarrationSatellites.isNarrationRole(ref.role), let sourceID = row.text(2) {
                    origin = .narration(sourceID: sourceID)
                } else {
                    origin = .none
                }
                found.append(SeedSatellite(ownerType: .source, ref: ref, origin: origin, priority: Self.priority(role: ref.role)))
            }
        }
        try store.query("""
            SELECT a.id, a.body_ref FROM global_artifacts a WHERE a.team_id IS NULL AND a.body_ref IS NOT NULL
        """, []) { row in
            guard let id = row.text(0), let ref = ArtifactBody.fileRef(row.text(1)) else { return }
            found.append(SeedSatellite(ownerType: .artifact, ref: ref, origin: .docBody(artifactID: id, keepsSite: store.hasLocalSite(id)), priority: Self.rolePriority.count / 2))
        }
        try store.query("SELECT file_ref, local_path FROM artifact_files WHERE local_path IS NOT NULL", []) { row in
            guard let ref = ArtifactBody.fileRef(row.text(0)), let path = row.text(1) else { return }
            found.append(SeedSatellite(ownerType: .artifact, ref: ref, origin: .file(path), priority: Self.rolePriority.count / 2))
        }
        return found.sorted { ($0.priority, $0.ref.owner, $0.ref.role) < ($1.priority, $1.ref.owner, $1.ref.role) }
    }

    /// The bytes of a satellite, decoded as the FileRef's `hash` names them; nil when this Mac no longer holds
    /// them (the file is gone, or changed since its pointer was laid out).
    func body(of item: SeedSatellite, in store: KnowledgeStore) throws -> Data? {
        let data: Data?
        switch item.origin {
        case .none:
            return nil
        case .docBody(let artifactID, _):
            return try SeedDocBodies.package(for: item.ref, artifactID: artifactID, store: store)
        case .narration(let sourceID):
            // Only from the working folder (generation 2): never the iCloud Drive tree the store names without one.
            guard SyncedArticleAudioStore.workingFolder != nil else { return nil }
            data = try? Data(contentsOf: SyncedArticleAudioStore.manifestURL(sourceID: sourceID))
        case .file(let path):
            let url = path.hasPrefix("ck-staging/")
                ? URL(fileURLWithPath: store.dbPath).deletingLastPathComponent().appendingPathComponent(path)
                : URL(fileURLWithPath: StorageService.absoluteSourcePath(path))
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard let data else { return nil }
        var decoded = data
        if item.ref.encoding == BlobStore.Encoding.gzip.rawValue, SyncGzip.isGzip(data) {
            guard let size = item.ref.size, let inflated = try? SyncGzip.decompress(data, maxBytes: Int(size)) else { return nil }
            decoded = inflated
        }
        return SyncIdentity.sha256Hex(decoded) == item.ref.hash ? decoded : nil
    }

    func upload() async throws -> CutoverSatelliteTotals {
        let items = try await store.onStore { try self.satellites(in: $0) }
        guard let zone = try await store.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) }) else {
            throw BlobStoreError.failed(CloudError(.zoneNotFound, message: "the library's root is not held yet"))
        }
        var totals = CutoverSatelliteTotals()
        for item in items {
            for _ in 0..<60 where await pendingCount() >= backlogLimit { await sleep(1) }
            guard let bytes = try await store.onStore({ try self.body(of: item, in: $0) }) else { continue }
            do {
                if case .narration(let sourceID) = item.origin {
                    // Bytes before pointer: every chunk before the manifest that names them.
                    guard let chunks = try await uploadNarrationChunks(of: item.ref, sourceID: sourceID, into: zone) else { continue }
                    totals.satellites += chunks.parts
                    totals.bytes += chunks.bytes
                }
                let file = try await blobs.upload(
                    bytes, owner: item.ref.owner, ownerType: item.ownerType, role: item.ref.role, mime: item.ref.mime ?? "application/octet-stream",
                    encoding: BlobStore.Encoding(rawValue: item.ref.encoding ?? "identity") ?? .identity, into: zone, keeping: item.ref,
                    children: item.ref.children, gen: item.ref.json["gen"]
                )
                totals.satellites += file.parts.count
                totals.bytes += Int64(bytes.count)
                if case .docBody(let artifactID, true) = item.origin {
                    let now = clock().timeIntervalSinceReferenceDate
                    try await store.perform { state in
                        try state.connection.execute("""
                            INSERT INTO ck_legacy_bodies (record_type, wire_id, field, sent_at) VALUES (?, ?, 'body', ?)
                            ON CONFLICT(record_type, wire_id, field) DO UPDATE SET sent_at = excluded.sent_at
                        """, [.text(SyncRecordType.artifact.rawValue), .text(artifactID), .real(now)])
                    }
                }
            } catch let error as BlobStoreError {
                if case .failed(let cloud) = error, cloud.code == .quotaExceeded { throw CutoverSeedError.quotaExceeded }
                Self.logger.error("A satellite of \(item.ref.role, privacy: .public) was not uploaded: \(String(describing: error), privacy: .public)")
            }
        }
        return totals
    }

    /// A narration's chunks, each child of its FileRef read from the working folder by its key, checked against
    /// its hash and uploaded under that child (existence-checked first, so a chunk the zone holds is not sent
    /// again). Nil when one is not on this Mac whole: the manifest then waits too, and the narration stays on the
    /// Macs that hold it.
    private func uploadNarrationChunks(of ref: FileRef, sourceID: String, into zone: BlobZone) async throws -> (parts: Int, bytes: Int64)? {
        let directory = SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)
            .appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        var totals: (parts: Int, bytes: Int64) = (0, 0)
        for child in ref.children where child.role == NarrationSatellites.chunkRole {
            guard let key = child.key, !key.isEmpty, !key.contains("/"),
                  let body = try? Data(contentsOf: directory.appendingPathComponent(key), options: .mappedIfSafe),
                  SyncIdentity.sha256Hex(body) == child.hash else { return nil }
            let file = try await blobs.upload(
                body, owner: child.owner, ownerType: .source, role: child.role, mime: child.mime ?? NarrationSatellites.chunkMime(fileName: key),
                encoding: BlobStore.Encoding(rawValue: child.encoding ?? "identity") ?? .identity, into: zone, keeping: child
            )
            totals.parts += file.parts.count
            totals.bytes += Int64(body.count)
        }
        return totals
    }
}
