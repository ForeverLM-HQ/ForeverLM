import Foundation
import OSLog

// The narration the phone makes (docs/cloudkit-schema-design.md §3.5.30 `files.audio.<voiceKey>`,
// children `audioChunk`; D29). The replica holds a narration as its source's satellites, not as
// files in iCloud Drive: the manifest is the `audio.<voiceKey>` satellite (`SyncedArticleAudioManifest`
// as JSON, gzip) and each chunk a child satellite of role `audioChunk`
// keyed by the chunk's file name, which is what every reader on the phone already expects
// (`MobileNarrationChunks`, `MobileAudioOverviewNarrationStore`, `MobileOfflineLibrary`).
//
// The player and the generator still work on files, so the phone keeps a working folder of the layout
// `SyncedArticleAudioStore` has always used (`SyncedArticleAudioWorkingFolder`): what it generates is
// written there and uploaded after, what other devices made is laid down there from the replica, and the
// chunks come from the satellites when something plays them.

/// What the phone names a narration's satellites (shared with the Mac: `NarrationSatellites`).
typealias MobileNarrationSatellites = NarrationSatellites

extension MobileWrite {
    /// The narration pointer of a source in the zone that holds it, after its manifest and every chunk
    /// are uploaded and acknowledged (§3.5.30 rule 2). A source keeps one narration: the other
    /// `audio.*` entries go, so a voice change replaces the old audio rather than sitting beside it
    /// (the readers take the first role by name).
    mutating func saveNarration(sourceID: String, zoneKey: String, manifest file: FileRef) throws {
        guard let held = try held(.source, sourceID, in: zoneKey) else { throw MobileRecordWriterError.sourceGone }
        var elements: [String: SyncJSON] = [file.role: file.value]
        // A removal marker already there (`null`) is not written again.
        for (role, value) in held.fields["files"]?.objectValue ?? [:]
        where role.hasPrefix(MobileNarrationSatellites.rolePrefix) && role != file.role && value != .null {
            elements[role] = .null
        }
        try write(RecordPatch(.source, id: sourceID, changes: ["files": .elements(elements)]), in: zoneKey)
    }

    /// Where the phone writes a source's narration pointer: its own `Catalog` copy, else the first space
    /// copy this member may write, with the narration the record names now.
    func narrationTarget(for sourceID: String) throws -> (zoneKey: String, current: FileRef?)? {
        let keys = try zoneKeys(holding: .source, sourceID).sorted { lhs, rhs in
            (lhs == Self.catalogKey ? 0 : 1, lhs) < (rhs == Self.catalogKey ? 0 : 1, rhs)
        }
        for key in keys {
            if let writer = try spaceWriter(key), writer.permission == .readOnly { continue }
            guard let source = try held(.source, sourceID, in: key) else { continue }
            return (key, MobileReadModels.narrationFile(of: source))
        }
        return nil
    }
}

/// What a phone's working folder holds of a narration, what its replica holds, and what to do about it: the
/// plan the Mac follows too (`NarrationPlan`).
typealias MobileNarrationLocal = NarrationLocal
typealias MobileNarrationReplica = NarrationReplica
typealias MobileNarrationPlan = NarrationPlan

/// The phone's narration: reconciles its working folder with the replica (laying
/// down what other devices made, uploading what this phone made), and brings a narration's chunks down
/// from their satellites when something plays them. Opening a narration writes nothing synced (P9); only
/// a narration this phone generated is ever uploaded.
actor MobileNarrationLibrary {
    static let shared = MobileNarrationLibrary(folder: .current, session: { await MobileNarrationLibrary.currentSession() })

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MobileNarrationLibrary")

    typealias Session = (writer: MobileRecordWriter, satellites: MobileSatellites)

    /// Where the working copy lives: Application Support, per CloudKit environment and out of backups,
    /// since the replica holds every byte.
    struct Folder: Sendable {
        let root: URL

        static var current: Folder { Folder(environment: .current) }

        init(root: URL) { self.root = root }

        init(environment: MobileCloudKitEnvironment) {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ForeverLM", isDirectory: true)
                .appendingPathComponent(environment.scopedName("Narration"), isDirectory: true)
        }

        func prepare() {
            guard !FileManager.default.fileExists(atPath: root.path) else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var url = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    /// How a reconcile treats a narration that needs uploading.
    enum Publishing: Sendable {
        /// Upload in the background: the caller never waits on bytes.
        case background
        case awaiting
    }

    static let pointerFileName = NarrationFolder.pointerFileName
    /// How many chunks move at once, in order.
    private static let width = 4
    /// A failed upload is tried again no sooner than this.
    private static let retryAfter: TimeInterval = 60

    nonisolated let folder: Folder
    private let session: @Sendable () async -> Session?
    private let clock: @Sendable () -> Date
    private var tail: Task<Void, Never>?
    private var waitingForFullPass = false
    private var uploading: Set<String> = []
    private var attempts: [String: (hash: String, at: Date)] = [:]
    private var refused: [String: String] = [:]

    init(folder: Folder, session: @escaping @Sendable () async -> Session?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.session = session
        self.clock = clock
    }

    private static func currentSession() async -> Session? {
        guard let session = await MobileSyncSession.startIfEnabled() else { return nil }
        return (session.writer, session.satellites)
    }

    /// Points the audio store at the working folder (§3.5.30).
    static func install(library: MobileNarrationLibrary = .shared) {
        SyncedArticleAudioStore.workingFolderProvider = {
            library.folder.prepare()
            return SyncedArticleAudioWorkingFolder(
                root: library.folder.root,
                materialize: { manifest, progress in try await library.materialize(manifest, onProgress: progress) },
                adopt: { sourceID in await library.refresh(only: sourceID) }
            )
        }
    }

    // MARK: - Reconciling

    /// Lays the replica's narrations into the working folder and sends this phone's own to the replica
    /// (one source, or every one a pass sees). Runs one at a time; a full pass asked for while another
    /// waits is that pass. Uploads run in the background unless `publishing` says to wait for them.
    func refresh(only sourceID: String? = nil, publishing: Publishing = .background) async {
        if sourceID == nil, waitingForFullPass, let tail {
            await tail.value
            return
        }
        if sourceID == nil { waitingForFullPass = true }
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            await reconcile(only: sourceID, publishing: publishing)
        }
        tail = task
        await task.value
    }

    private func reconcile(only sourceID: String?, publishing: Publishing) async {
        if sourceID == nil { waitingForFullPass = false }
        guard let session = await session() else { return }
        var locals: [String: MobileNarrationLocal] = [:]
        var ids: Set<String> = []
        if let sourceID {
            ids = [sourceID]
            locals[sourceID] = Self.localState(sourceID: sourceID)
        } else {
            locals = Self.localStates()
            ids = Set(locals.keys)
            ids.formUnion((try? await session.satellites.projection.replica.read { replica -> [String] in
                var found: [String] = []
                try replica.connection.query("SELECT id FROM m_sources WHERE has_audio = 1", []) { found.append($0.text(0) ?? "") }
                return found
            }) ?? [])
        }
        let sorted = ids.sorted()
        guard let views = try? await Self.replicaViews(sourceIDs: sorted, writer: session.writer) else { return }
        var uploads: [String] = []
        for id in sorted where !uploading.contains(id) {
            guard let view = views[id] else { continue }
            let local = locals[id]
            var action = MobileNarrationPlan.action(local: local, replica: MobileNarrationReplica(held: view.held, hash: view.file?.hash))
            if action == .compare, let local, let file = view.file, let zoneKey = view.zoneKey {
                let remote = try? await Self.manifest(file, zoneKey: zoneKey, satellites: session.satellites)
                let newer = remote.map { local.createdAt > $0.createdAt } == true
                action = local.complete && newer ? .publish : .mirror
            }
            switch action {
            case .none, .compare:
                break
            case .record:
                if let hash = view.file?.hash { Self.writePointer(hash, sourceID: id) }
            case .remove:
                try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: id))
            case .mirror:
                if let file = view.file, let zoneKey = view.zoneKey {
                    await mirror(sourceID: id, file: file, zoneKey: zoneKey, satellites: session.satellites)
                }
            case .publish:
                uploads.append(id)
            }
        }
        switch publishing {
        case .awaiting:
            for id in uploads { await publishLoggingFailure(sourceID: id) }
        case .background:
            for id in uploads {
                Task(priority: .utility) { [self] in await publishLoggingFailure(sourceID: id) }
            }
        }
    }

    /// What the working folder holds of every narration it has, by source (`NarrationFolder`).
    static func localStates() -> [String: MobileNarrationLocal] { NarrationFolder.localStates() }

    static func localState(sourceID: String) -> MobileNarrationLocal? { NarrationFolder.localState(sourceID: sourceID) }

    static func decode(_ bytes: Data) -> SyncedArticleAudioManifest? { NarrationFolder.decode(bytes) }

    static func readPointer(sourceID: String) -> String? { NarrationFolder.readPointer(sourceID: sourceID) }

    static func writePointer(_ hash: String, sourceID: String) { NarrationFolder.writePointer(hash, sourceID: sourceID) }

    typealias ReplicaView = (held: Bool, file: FileRef?, zoneKey: String?)

    /// What the replica holds of each source: whether the phone has the record at all, and the narration
    /// it names (the learner's own copy first), with the zone the pointer was found in. One read.
    static func replicaViews(sourceIDs: [String], writer: MobileRecordWriter) async throws -> [String: ReplicaView] {
        try await writer.read { write -> [String: ReplicaView] in
            var views: [String: ReplicaView] = [:]
            for sourceID in sourceIDs {
                let keys = try write.zoneKeys(holding: .source, sourceID).sorted { lhs, rhs in
                    (lhs == MobileProjection.catalogKey ? 0 : 1, lhs) < (rhs == MobileProjection.catalogKey ? 0 : 1, rhs)
                }
                var view: ReplicaView = (!keys.isEmpty, nil, nil)
                for key in keys {
                    if let file = MobileReadModels.narrationFile(of: try write.held(.source, sourceID, in: key)) {
                        view = (true, file, key)
                        break
                    }
                }
                views[sourceID] = view
            }
            return views
        }
    }

    private static func manifest(_ file: FileRef, zoneKey: String, satellites: MobileSatellites) async throws -> SyncedArticleAudioManifest? {
        guard let satellite = try await satellites.satellite(file, ownerZoneKey: zoneKey) else { return nil }
        return decode(try await satellites.data(satellite))
    }

    /// Lays the replica's manifest down in the folder, as the file the audio store reads, and drops chunk
    /// files the new manifest does not name. The chunks themselves wait until something plays them.
    private func mirror(sourceID: String, file: FileRef, zoneKey: String, satellites: MobileSatellites) async {
        do {
            guard let satellite = try await satellites.satellite(file, ownerZoneKey: zoneKey) else { return }
            try NarrationFolder.lay(manifest: try await satellites.data(satellite), sourceID: sourceID)
        } catch {
            Self.logger.error("A narration was not laid down from the replica: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Uploading

    /// `publish(sourceID:)` for a caller that has nobody to tell: a failure is logged.
    private func publishLoggingFailure(sourceID: String) async {
        do {
            try await publish(sourceID: sourceID)
        } catch {
            Self.logger.error("Uploading a narration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Uploads a narration this phone made: every chunk as a child satellite, then the manifest, each
    /// acknowledged before anything points at it, then the source's pointer (§3.5.30 rule 2). Returns
    /// whether a pointer was written. A source this phone does not hold, or may not write, keeps its
    /// narration on the phone alone.
    @discardableResult
    func publish(sourceID: String) async throws -> Bool {
        guard uploading.insert(sourceID).inserted else { return false }
        defer { uploading.remove(sourceID) }
        guard let session = await session(), let blobs = session.writer.blobs else { return false }
        let url = SyncedArticleAudioStore.manifestURL(sourceID: sourceID)
        guard let bytes = try? Data(contentsOf: url), let manifest = Self.decode(bytes), manifest.sourceID == sourceID,
              manifest.usesSupportedPlaybackFormat, SyncedArticleAudioStore.hasLocalChunks(for: manifest) else { return false }
        let hash = SyncIdentity.sha256Hex(bytes)
        guard refused[sourceID] != hash, attempts[sourceID].map({ $0.hash != hash || clock().timeIntervalSince($0.at) >= Self.retryAfter }) != false else { return false }
        attempts[sourceID] = (hash, clock())

        guard let target = try await session.writer.read({ try $0.narrationTarget(for: sourceID) }),
              let zone = try await session.writer.replica.perform({ try BlobZone.resolve(zoneKey: MobileSatellites.satelliteZoneKey(forOwnerIn: target.zoneKey), in: $0) })
        else { return false }
        let role = MobileNarrationSatellites.role(model: manifest.model, voice: manifest.voice)
        let current = target.current?.role == role ? target.current : nil
        let known = Dictionary((current?.children ?? []).compactMap { child in child.key.map { ($0, child) } }, uniquingKeysWith: { first, _ in first })

        let ordered = manifest.chunks.sorted { $0.index < $1.index }
        let directory = url.deletingLastPathComponent().appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        var children: [FileRef] = []
        for window in stride(from: 0, to: ordered.count, by: Self.width).map({ Array(ordered[$0 ..< min($0 + Self.width, ordered.count)]) }) {
            let uploaded = try await withThrowingTaskGroup(of: (Int, FileRef).self) { group in
                for (place, chunk) in window.enumerated() {
                    group.addTask {
                        let body = try Data(contentsOf: directory.appendingPathComponent(chunk.fileName), options: .mappedIfSafe)
                        let file = try await blobs.upload(
                            body, owner: sourceID, ownerType: .source, role: MobileNarrationSatellites.chunkRole,
                            mime: MobileNarrationSatellites.chunkMime(fileName: chunk.fileName), encoding: .identity, into: zone,
                            keeping: known[chunk.fileName]
                        )
                        return (place, file.keyed(chunk.fileName))
                    }
                }
                var found: [(Int, FileRef)] = []
                for try await item in group { found.append(item) }
                return found.sorted { $0.0 < $1.0 }.map(\.1)
            }
            children += uploaded
        }
        let file = try await blobs.upload(
            bytes, owner: sourceID, ownerType: .source, role: role, mime: "application/json", encoding: .gzip, into: zone,
            keeping: current, children: children
        )
        do {
            try await session.writer.transaction { try $0.saveNarration(sourceID: sourceID, zoneKey: target.zoneKey, manifest: file) }
        } catch let error as MobileRecordWriterError {
            if case .refused = error { refused[sourceID] = hash }
            throw error
        }
        Self.writePointer(file.hash, sourceID: sourceID)
        return true
    }

    // MARK: - Playing

    /// Brings the chunks of a narration the replica holds into the folder (a hard link from the satellite's
    /// cached or kept file, or a copy), a few at a time and in order, so the contiguous prefix grows and
    /// playback can start on it. A chunk already here is not fetched.
    func materialize(_ manifest: SyncedArticleAudioManifest, onProgress: @escaping @Sendable (SyncedArticleAudioDownloadProgress) -> Void) async throws {
        let ordered = manifest.chunks.sorted { $0.index < $1.index }
        let urls = SyncedArticleAudioStore.expectedChunkURLs(for: manifest)
        func measure() -> SyncedArticleAudioDownloadProgress {
            SyncedArticleAudioDownloadProgress.measure(ready: urls.map(SyncedArticleAudioStore.isMaterializedChunk))
        }
        var last = measure()
        if last.isComplete { return }
        onProgress(last)
        guard let session = await session(),
              let found = try await Self.replicaViews(sourceIDs: [manifest.sourceID], writer: session.writer)[manifest.sourceID],
              let file = found.file, let zoneKey = found.zoneKey,
              let narration = try await session.satellites.satellite(file, ownerZoneKey: zoneKey) else {
            throw SyncedArticleAudioStoreError.missingAudioChunk(manifest.sourceID)
        }
        var inOrder = manifest
        inOrder.chunks = ordered
        let satellites = MobileNarrationChunks.satellites(of: narration, manifest: inOrder)
        let missing = ordered.indices.filter { !SyncedArticleAudioStore.isMaterializedChunk(urls[$0]) }
        for window in stride(from: 0, to: missing.count, by: Self.width).map({ Array(missing[$0 ..< min($0 + Self.width, missing.count)]) }) {
            try Task.checkCancellation()
            let fetched = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
                for index in window {
                    guard let satellite = satellites[index] else { throw SyncedArticleAudioStoreError.missingAudioChunk(ordered[index].fileName) }
                    group.addTask {
                        // Bound before the tuple: AGENTS.md's Release miscompile.
                        let url = try await session.satellites.url(satellite)
                        return (index, url)
                    }
                }
                var found: [(Int, URL)] = []
                for try await item in group { found.append(item) }
                return found.sorted { $0.0 < $1.0 }
            }
            for (index, source) in fetched { try Self.place(source, at: urls[index]) }
            let progress = measure()
            if progress != last {
                last = progress
                onProgress(progress)
            }
        }
        guard measure().isComplete else { throw SyncedArticleAudioStoreError.missingAudioChunk(manifest.sourceID) }
    }

    /// A chunk file in its place in the folder: a hard link when the volume allows, else a copy.
    static func place(_ source: URL, at destination: URL) throws { try NarrationFolder.place(source, at: destination) }
}
