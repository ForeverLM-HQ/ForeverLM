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
        /// A source's body whose pointer keeps no path: what `SourceFilePublisher` points at (text, Listen text,
        /// TTML, review guide, walkthrough, figures, or the source's own file). Built again from the source's rows
        /// (`SourceSatelliteRoles.localSatellites`) and used when it is the body the pointer names. Until
        /// 2026-10-13 the seed had no body for these and skipped them, so a library uploaded again (a new salt)
        /// carried their pointers without their bytes.
        case table(sourceID: String)
        /// Nothing on this Mac to read it from.
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
        "text", "thumbnail", "cover", "icon", "reviewGuide", "walkthrough", "figures", "ideas", "citedPapers", "references", "readerHTML", "epub",
        "pdf", "listenText", "timing", "slides", "raw",
    ]

    static func priority(role: String) -> Int {
        let base = role.split(separator: ".").first.map(String.init) ?? role
        return rolePriority.firstIndex(of: base) ?? rolePriority.count
    }

    /// Every pointer of this store's personal library, in priority order; with `teamID`, the pointers of that
    /// team's copies instead (the bytes a converted team's space needs in its own zone, which `restoreMissing(inSpace:)`
    /// sends).
    func satellites(in store: KnowledgeStore, teamID: String? = nil) throws -> [SeedSatellite] {
        var found: [SeedSatellite] = []
        let owner: [SQLiteValue] = teamID.map { [.text($0)] } ?? []
        for table in [("source_files", "role"), ("source_derived", "kind")] {
            try store.query("""
                SELECT f.file_ref, f.local_path, f.source_id FROM \(table.0) f JOIN sources s ON s.id = f.source_id
                WHERE \(teamID == nil ? "s.team_id IS NULL" : "s.team_id = ?")
            """, owner) { row in
                guard let ref = ArtifactBody.fileRef(row.text(0)) else { return }
                let origin: SeedSatellite.Origin
                if let path = row.text(1) {
                    origin = .file(path)
                } else if let sourceID = row.text(2) {
                    origin = NarrationSatellites.isNarrationRole(ref.role) ? .narration(sourceID: sourceID) : .table(sourceID: sourceID)
                } else {
                    origin = .none
                }
                found.append(SeedSatellite(ownerType: .source, ref: ref, origin: origin, priority: Self.priority(role: ref.role)))
            }
        }
        try store.query("""
            SELECT a.id, a.body_ref FROM global_artifacts a
            WHERE \(teamID == nil ? "a.team_id IS NULL" : "a.team_id = ?") AND a.body_ref IS NOT NULL
        """, owner) { row in
            guard let id = row.text(0), let ref = ArtifactBody.fileRef(row.text(1)) else { return }
            found.append(SeedSatellite(ownerType: .artifact, ref: ref, origin: .docBody(artifactID: id, keepsSite: store.hasLocalSite(id)), priority: Self.rolePriority.count / 2))
        }
        if teamID == nil {
            try store.query("SELECT file_ref, local_path FROM artifact_files WHERE local_path IS NOT NULL", []) { row in
                guard let ref = ArtifactBody.fileRef(row.text(0)), let path = row.text(1) else { return }
                found.append(SeedSatellite(ownerType: .artifact, ref: ref, origin: .file(path), priority: Self.rolePriority.count / 2))
            }
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
        case .table(let sourceID):
            return try Self.tableBodies(sourceID: sourceID, role: item.ref.role, in: store).first { SyncIdentity.sha256Hex($0) == item.ref.hash }
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

    /// The bodies of `role` this Mac makes for a source from its rows today (a file is read mapped, so it is paged
    /// in only where it is hashed).
    static func tableBodies(sourceID: String, role: String, in store: KnowledgeStore) throws -> [Data] {
        try SourceSatelliteRoles.localSatellites(sourceID: sourceID, connection: store, resolve: {
            KnowledgeStore.sourceFileLocationOverride?($0) ?? URL(fileURLWithPath: StorageService.absoluteSourcePath($0))
        }).filter { $0.role == role }.map(\.body)
    }

    func upload() async throws -> CutoverSatelliteTotals {
        let items = try await store.onStore { try self.satellites(in: $0) }
        guard let zone = try await store.perform({ try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) }) else {
            throw BlobStoreError.failed(CloudError(.zoneNotFound, message: "the library's root is not held yet"))
        }
        return try await upload(items, into: zone).totals
    }

    /// Uploads `items` in order; `failed` counts the ones whose upload was refused (logged, the rest go on).
    private func upload(_ items: [SeedSatellite], into zone: BlobZone) async throws -> (totals: CutoverSatelliteTotals, failed: Int) {
        var totals = CutoverSatelliteTotals()
        var failed = 0
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
                            INSERT INTO ck_body_sends (record_type, wire_id, field, sent_at) VALUES (?, ?, 'body', ?)
                            ON CONFLICT(record_type, wire_id, field) DO UPDATE SET sent_at = excluded.sent_at
                        """, [.text(SyncRecordType.artifact.rawValue), .text(artifactID), .real(now)])
                    }
                }
            } catch let error as BlobStoreError {
                if case .failed(let cloud) = error, cloud.code == .quotaExceeded { throw CutoverSeedError.quotaExceeded }
                failed += 1
                Self.logger.error("A satellite of \(item.ref.role, privacy: .public) was not uploaded: \(String(describing: error), privacy: .public)")
            }
        }
        return (totals, failed)
    }

    /// `ck_engine_state` scope: the `saltID` of the library whose pointers `restoreMissing` last found whole.
    static let restoredScope = "satellites.restoredForSalt"

    /// Puts back the satellites the library's pointers name and the server lacks, from what this Mac holds: once
    /// per library (its root's salt), after its seed is complete, on a Mac whose sends are not held. Every
    /// pointer's parts are looked up by name in batches (`BlobStore.filesMissingParts`), and only the missing are
    /// read and uploaded under the pointer as it stands. A source whose body of that role changed here since it was
    /// published is queued for the publisher, which points it at what this Mac holds now; a body this Mac does not
    /// hold at all (another Mac's, or an archived source's) is left to the Mac that holds it. Repairs the library
    /// uploaded again on 2026-10-11, whose seed skipped every pointer with no path (`Origin.table`), so a
    /// client reading `Source.derived.figures` or a published `files.text` met `missingParts`. Returns nil when
    /// there is nothing to do; a refused upload leaves the pass to run again after a later round.
    @discardableResult
    func restoreMissing() async throws -> CutoverSatelliteTotals? {
        let found = try await store.perform { state -> (zone: BlobZone, saltID: String)? in
            guard let root = try state.replica.personalRoot()?.envelope, CutoverRootState(root: root).state == "complete",
                  let zone = try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: state)
            else { return nil }
            let saltID = RecordNaming.saltID(zone.salt)
            let done = try state.replica.engineState(Self.restoredScope).map { String(decoding: $0, as: UTF8.self) }
            return done == saltID ? nil : (zone, saltID)
        }
        guard let (zone, saltID) = found else { return nil }
        let items = try await store.onStore { try self.satellites(in: $0) }
        let missing = try await blobs.filesMissingParts(items.map(\.ref), in: zone)
        let lost = items.indices.filter(missing.contains).map { items[$0] }
        // A body this Mac holds under the role but no longer as the pointer names it (made again here since and
        // never published): the publisher uploads what it holds now and points the source at it.
        let republished = try await store.onStore { store -> Int in
            var sources = Set<String>()
            for item in lost {
                guard case .table(let sourceID) = item.origin else { continue }
                let bodies = try Self.tableBodies(sourceID: sourceID, role: item.ref.role, in: store)
                if !bodies.isEmpty, !bodies.contains(where: { SyncIdentity.sha256Hex($0) == item.ref.hash }) { sources.insert(sourceID) }
            }
            for sourceID in sources { try store.queueSourceFilesRefresh(sourceID: sourceID) }
            return sources.count
        }
        let (totals, failed) = try await upload(lost, into: zone)
        if !lost.isEmpty {
            Self.logger.notice("Satellites restored: \(totals.satellites) parts for \(lost.count) missing, \(republished) sources to publish again, \(failed) refused")
        }
        if failed == 0 {
            try await store.perform { try $0.replica.setEngineState(Self.restoredScope, Data(saltID.utf8)) }
        }
        return totals
    }

    /// `ck_engine_state` scope: the `saltID` of the space whose team's pointers `restoreMissing(inSpace:)` last found whole.
    static func spaceRestoredScope(_ zoneKey: String) -> String { "satellites.spaceRestoredForSalt.\(zoneKey)" }

    /// Puts into a space's own zone the bytes its team's pointers name and the zone lacks, from what this Mac holds.
    /// A team converted to a space (`TeamToSpace`) carries its copies' pointers into the space, but nothing laid
    /// their bytes in the space's zone: the seed and the publisher send the personal library's only, and only a
    /// move or a share copies a record's satellites across (`SpaceMoveJob`). So every other device met
    /// `missingParts` on a team source's text and PDF (2026-10-25: 52 sources). Once per space (its root's salt, so
    /// a space made again is done again), the pointers are looked up by name and only the missing are read and
    /// uploaded. Returns nil when the space is not held or this is already done.
    @discardableResult
    func restoreMissing(inSpace zoneKey: String, teamID: String) async throws -> CutoverSatelliteTotals? {
        let found = try await store.perform { state -> (zone: BlobZone, saltID: String)? in
            guard let zone = try BlobZone.resolve(zoneKey: zoneKey, in: state), zone.isSpace else { return nil }
            let saltID = RecordNaming.saltID(zone.salt)
            let done = try state.replica.engineState(Self.spaceRestoredScope(zoneKey)).map { String(decoding: $0, as: UTF8.self) }
            return done == saltID ? nil : (zone, saltID)
        }
        guard let (zone, saltID) = found else { return nil }
        let items = try await store.onStore { try self.satellites(in: $0, teamID: teamID) }
        let missing = try await blobs.filesMissingParts(items.map(\.ref), in: zone)
        let lost = items.indices.filter(missing.contains).map { items[$0] }
        let (totals, failed) = try await upload(lost, into: zone)
        if !lost.isEmpty {
            Self.logger.notice("Space satellites restored: \(totals.satellites) parts for \(lost.count) missing, \(failed) refused")
        }
        if failed == 0 {
            try await store.perform { try $0.replica.setEngineState(Self.spaceRestoredScope(zoneKey), Data(saltID.utf8)) }
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
