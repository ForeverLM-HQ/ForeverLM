import Foundation
import OSLog

// The narration a Mac on generation 2 makes and plays (docs/cloudkit-schema-design.md §3.5.30
// `files.audio.<voiceKey>`, children `audioChunk`; D29; §14.2 NARR3). It is the shape the iPhone writes
// (`MobileNarrationLibrary`), so a narration made on either plays on the other: the manifest is the
// source's `audio.<model>.<voice>` satellite, each chunk a child satellite keyed by its file name, and the
// pointer is a row of `source_files`, which the outbox sends once the satellites are acknowledged.
//
// The generator and the player still work on files, so the Mac keeps a working folder of the layout
// `SyncedArticleAudioStore` has always used (`Narration` beside the Mac's `Content` folder, out of
// backups) instead of the iCloud Drive tree: what the Mac generates is written there and uploaded after,
// what other devices made is laid down there from the replica, and the chunks come from their satellites
// when something plays them. Generation 1 never installs the folder, so it reads and writes iCloud Drive
// exactly as before.
//
// The narration generation 1 made sits in ForeverLM's iCloud Documents folder, which no build is entitled to
// any more and nothing reads as narration under generation 2. Once per store, after this Mac holds the whole
// library, every whole narration there whose source the library holds and narrates nowhere yet is copied into
// the working folder (`NarrationCarryOver`), where the next pass sends it like one this Mac just made.

/// What the Mac's replica says of a source's narration: whether this Mac holds the learner's own copy of
/// the record (so its silence about audio means something), and the pointer it names.
struct MacNarrationView: Equatable, Sendable {
    var held: Bool
    var file: FileRef?
}

extension KnowledgeStore {
    /// The sources whose narration this Mac syncs: the learner's own copies, under the id every device knows
    /// them by (a space's copy of a source keeps its narration where it is made).
    private static let narratedSources = "s.team_id IS NULL AND s.wire_key = s.id"

    /// What the replica says of each source in `sourceIDs`: held, and the narration its `files` name (the
    /// first `audio.*` role by name; a source keeps one).
    func narrationViews(sourceIDs: [String]) throws -> [String: MacNarrationView] {
        var views: [String: MacNarrationView] = [:]
        for start in stride(from: 0, to: sourceIDs.count, by: 400) {
            let slice = Array(sourceIDs[start ..< min(start + 400, sourceIDs.count)])
            let marks = slice.map { _ in "?" }.joined(separator: ", ")
            try query("""
                SELECT s.id, f.file_ref FROM sources s
                LEFT JOIN source_files f ON f.source_id = s.id AND substr(f.role, 1, 6) = 'audio.'
                WHERE \(Self.narratedSources) AND s.id IN (\(marks)) ORDER BY s.id, f.role
            """, slice.map { .text($0) }) { row in
                guard let id = row.text(0) else { return }
                let file = ArtifactBody.fileRef(row.text(1))
                if views[id] == nil { views[id] = MacNarrationView(held: true, file: file) }
            }
        }
        return views
    }

    /// The manifest hash each narrated source's pointer names: one read of every `audio.*` row, so a round
    /// that changed none of them costs one query.
    func narrationPointers() throws -> [String: String] {
        var pointers: [String: String] = [:]
        try query("""
            SELECT f.source_id, f.file_ref FROM source_files f JOIN sources s ON s.id = f.source_id
            WHERE \(Self.narratedSources) AND substr(f.role, 1, 6) = 'audio.' ORDER BY f.source_id, f.role
        """, []) { row in
            guard let id = row.text(0), pointers[id] == nil, let file = ArtifactBody.fileRef(row.text(1)) else { return }
            pointers[id] = file.hash
        }
        return pointers
    }

    /// Points the source at `file` and drops every other narration it names, in one transaction, so a new voice
    /// replaces the old audio rather than sitting beside it (readers take the first role by name). The write
    /// is an ordinary one: the outbox triggers send it as the source's `files` change. False when this Mac no
    /// longer holds the source.
    func pointNarration(sourceID: String, to file: FileRef) throws -> Bool {
        try exec("BEGIN IMMEDIATE")
        do {
            guard try scalarInteger("SELECT EXISTS(SELECT 1 FROM sources s WHERE \(Self.narratedSources) AND s.id = ?)", [.text(sourceID)]) == 1 else {
                try exec("ROLLBACK")
                return false
            }
            try execute("""
                INSERT INTO source_files (source_id, role, file_ref, local_path) VALUES (?, ?, ?, NULL)
                ON CONFLICT(source_id, role) DO UPDATE SET file_ref = excluded.file_ref, local_path = NULL
            """, [.text(sourceID), .text(file.role), .text(ArtifactBody.text(file))])
            try execute(
                "DELETE FROM source_files WHERE source_id = ? AND substr(role, 1, 6) = 'audio.' AND role <> ?",
                [.text(sourceID), .text(file.role)]
            )
            try exec("COMMIT")
            return true
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Drops the source's narration pointer (the learner removed the audio).
    func clearNarration(sourceID: String) throws {
        try execute("DELETE FROM source_files WHERE source_id = ? AND substr(role, 1, 6) = 'audio.'", [.text(sourceID)])
    }

    /// Of `sourceIDs`, the sources this library holds that name no narration: where one carried from iCloud
    /// Drive may go. A source the account already narrates keeps that narration, which plays here from the
    /// replica.
    func sourcesWithoutNarration(among sourceIDs: [String]) throws -> Set<String> {
        var found: Set<String> = []
        for start in stride(from: 0, to: sourceIDs.count, by: 400) {
            let slice = Array(sourceIDs[start ..< min(start + 400, sourceIDs.count)])
            let marks = slice.map { _ in "?" }.joined(separator: ", ")
            try query("""
                SELECT s.id FROM sources s WHERE s.id IN (\(marks))
                AND NOT EXISTS (SELECT 1 FROM source_files f WHERE f.source_id = s.id AND substr(f.role, 1, 6) = 'audio.')
            """, slice.map { .text($0) }) { row in
                if let id = row.text(0) { found.insert(id) }
            }
        }
        return found
    }
}

/// The Mac's narration under generation 2: reconciles its working folder with the replica (laying down what
/// other devices made, uploading what this Mac made), and brings a narration's chunks down from their
/// satellites when something plays them. Opening a narration writes nothing synced (P9); only a narration
/// this Mac generated is ever uploaded.
actor MacNarrationLibrary {
    static let shared = MacNarrationLibrary(
        folder: .current,
        session: { await MacSyncSession.current?.narrationSession() },
        didChange: { ArticleSpeechAudioCache.announceStatusChange(sourceID: $0) },
        // A test host never reads the learner's iCloud Drive.
        iCloudDriveAudio: ForeverLMRuntimeIdentity.isTestHost ? nil : SyncedArticleAudioStore.ubiquityAudioRootURL()
    )

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MacNarrationLibrary")

    /// What a pass needs of the Mac's sync: the store the rows live in, the blobs the satellites move through,
    /// and what to call when a pointer was written (the coordinator's `sendSoon`).
    struct Session: Sendable {
        let store: MacPrivateSyncStore
        let blobs: BlobStore
        let wrote: @Sendable () async -> Void
    }

    /// Where the working copy lives: Application Support, beside the Mac's `Content` folder and out of
    /// backups, since the replica holds every byte.
    struct Folder: Sendable {
        let root: URL

        static var current: Folder {
            Folder(root: ForeverLMRuntimeIdentity.applicationSupportRootURL.appendingPathComponent("Narration", isDirectory: true))
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

    /// How many chunks move at once, in order.
    private static let width = 4
    /// A failed upload is tried again no sooner than this.
    private static let retryAfter: TimeInterval = 60
    /// A round that changed no pointer still looks over the folder this often, which is how an upload that
    /// failed is tried again.
    private static let fullPassEvery: TimeInterval = 10 * 60

    nonisolated let folder: Folder
    /// Generation 1's narration folder (`Audio` in ForeverLM's iCloud Documents folder, read by plain path),
    /// carried into the working folder once; nil carries nothing.
    nonisolated let iCloudDriveAudio: URL?
    private let session: @Sendable () async -> Session?
    private let didChange: @Sendable (String) -> Void
    private let clock: @Sendable () -> Date
    private let removals = NarrationRemovals()
    private var tail: Task<Void, Never>?
    private var waitingForFullPass = false
    private var uploading: Set<String> = []
    private var attempts: [String: (hash: String, at: Date)] = [:]
    private var lastPointers: [String: String]?
    private var lastFullPass = Date.distantPast
    /// Uploads asked for in the background, sent one narration at a time.
    private var waiting: [String] = []
    private var queued: Set<String> = []
    private var draining = false
    private var carrying = false
    /// The carry ran in this launch, or the store says it is done: it is not looked for again until the next.
    private var carryRan = false

    init(folder: Folder, session: @escaping @Sendable () async -> Session?, didChange: @escaping @Sendable (String) -> Void = { _ in },
         clock: @escaping @Sendable () -> Date = { Date() }, iCloudDriveAudio: URL? = nil) {
        self.folder = folder
        self.session = session
        self.didChange = didChange
        self.clock = clock
        self.iCloudDriveAudio = iCloudDriveAudio
    }

    /// Points the audio store at the working folder (§13.6).
    static func install(library: MacNarrationLibrary = .shared) {
        SyncedArticleAudioStore.workingFolderProvider = {
            library.folder.prepare()
            return SyncedArticleAudioWorkingFolder(
                root: library.folder.root,
                materialize: { manifest, progress in try await library.materialize(manifest, onProgress: progress) },
                adopt: { sourceID in await library.refresh(only: sourceID) },
                saved: { sourceID in Task(priority: .utility) { await library.refresh(only: sourceID) } },
                removed: { sourceID in library.removeNarration(sourceID: sourceID) }
            )
        }
    }

    // MARK: - Reconciling

    /// What a round that fetched changes asks: look over the folder when a narration pointer changed since the
    /// last look, or when it has been a while (an upload that failed is tried again). The first round after
    /// this Mac holds the whole library carries generation 1's narration in from iCloud Drive, once, and the
    /// look that follows sends what it carried.
    func roundSettled() async {
        guard let session = await session() else { return }
        if let carried = await carryFromICloudDrive(), !carried.carried.isEmpty { lastPointers = nil }
        let pointers: [String: String]
        do {
            pointers = try await session.store.onStore({ try $0.narrationPointers() })
        } catch {
            Self.logger.error("Reading the narration pointers failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard pointers != lastPointers || clock().timeIntervalSince(lastFullPass) >= Self.fullPassEvery else { return }
        lastPointers = pointers
        await refresh()
    }

    /// Lays the replica's narrations into the working folder and sends this Mac's own to the replica (one
    /// source, or every one a pass sees). Runs one at a time; a full pass asked for while another waits is
    /// that pass. Uploads run in the background unless `publishing` says to wait for them.
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
        if sourceID == nil {
            waitingForFullPass = false
            lastFullPass = clock()
        }
        guard let session = await session() else { return }
        var locals: [String: NarrationLocal] = [:]
        var ids: Set<String> = []
        if let sourceID {
            ids = [sourceID]
            locals[sourceID] = NarrationFolder.localState(sourceID: sourceID)
        } else {
            locals = NarrationFolder.localStates()
            ids = Set(locals.keys)
            do {
                ids.formUnion(try await session.store.onStore { try $0.narrationPointers() }.keys)
            } catch {
                Self.logger.error("Reading the narration pointers for a pass failed: \(String(describing: error), privacy: .public)")
            }
        }
        let sorted = ids.sorted().filter { !removals.contains($0) }
        let views: [String: MacNarrationView]
        do {
            views = try await Self.views(sourceIDs: sorted, session: session)
        } catch {
            Self.logger.error("Reading the narration views failed: \(String(describing: error), privacy: .public)")
            return
        }
        var uploads: [String] = []
        for id in sorted where !uploading.contains(id) {
            guard let view = views[id] else { continue }
            let local = locals[id]
            var action = NarrationPlan.action(local: local, replica: NarrationReplica(held: view.held, hash: view.file?.hash))
            if action == .compare, let local, let file = view.file {
                let remote: SyncedArticleAudioManifest?
                do {
                    remote = try await Self.manifest(file, session: session)
                } catch {
                    Self.logger.error("Reading a narration manifest from the replica failed: \(String(describing: error), privacy: .public)")
                    remote = nil
                }
                let newer = remote.map { local.createdAt > $0.createdAt } == true
                action = local.complete && newer ? .publish : .mirror
            }
            switch action {
            case .none, .compare:
                break
            case .record:
                if let hash = view.file?.hash { NarrationFolder.writePointer(hash, sourceID: id) }
            case .remove:
                try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: id))
                didChange(id)
            case .mirror:
                if let file = view.file { await mirror(sourceID: id, file: file, session: session) }
            case .publish:
                uploads.append(id)
            }
        }
        switch publishing {
        case .awaiting:
            for id in uploads { await publishLoggingFailure(sourceID: id) }
        case .background:
            queueUploads(uploads)
        }
    }

    /// Sends narrations in the background one at a time, in the order they were asked for, so a pass that finds
    /// hundreds (what the carry from iCloud Drive brings) keeps one narration's chunks in flight, not every one's.
    private func queueUploads(_ ids: [String]) {
        for id in ids where queued.insert(id).inserted { waiting.append(id) }
        guard !draining, !waiting.isEmpty else { return }
        draining = true
        Task(priority: .utility) { [self] in await drainUploads() }
    }

    private func drainUploads() async {
        while !waiting.isEmpty {
            let id = waiting.removeFirst()
            queued.remove(id)
            await publishLoggingFailure(sourceID: id)
        }
        draining = false
    }

    private func publishLoggingFailure(sourceID: String) async {
        do {
            _ = try await publish(sourceID: sourceID)
        } catch {
            Self.logger.error("Publishing a narration failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func views(sourceIDs: [String], session: Session) async throws -> [String: MacNarrationView] {
        try await session.store.onStore { try $0.narrationViews(sourceIDs: sourceIDs) }
    }

    private static func contentZone(_ session: Session) async throws -> BlobZone {
        let zone = try await session.store.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) }
        guard let zone else { throw CloudError(.zoneNotFound, message: "the library's root is not held yet") }
        return zone
    }

    private static func manifest(_ file: FileRef, session: Session) async throws -> SyncedArticleAudioManifest? {
        NarrationFolder.decode(try await session.blobs.fetch(file, from: try await contentZone(session)))
    }

    /// Lays the replica's manifest down in the folder, as the file the audio store reads, and drops chunk
    /// files the new manifest does not name. The chunks themselves wait until something plays them.
    private func mirror(sourceID: String, file: FileRef, session: Session) async {
        do {
            let bytes = try await session.blobs.fetch(file, from: try await Self.contentZone(session))
            if try NarrationFolder.lay(manifest: bytes, sourceID: sourceID) { didChange(sourceID) }
        } catch {
            Self.logger.error("A narration was not laid down from the replica: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Uploading

    /// Uploads a narration this Mac made: every chunk as a child satellite, then the manifest, each
    /// acknowledged before anything points at it, then the source's pointer (§3.5.30 rule 2). Returns whether
    /// a pointer was written. A source this Mac does not hold as the learner's own keeps its narration here
    /// alone.
    @discardableResult
    func publish(sourceID: String) async throws -> Bool {
        guard uploading.insert(sourceID).inserted else { return false }
        defer { uploading.remove(sourceID) }
        guard !removals.contains(sourceID), let session = await session() else { return false }
        let url = SyncedArticleAudioStore.manifestURL(sourceID: sourceID)
        guard let bytes = try? Data(contentsOf: url), let manifest = NarrationFolder.decode(bytes), manifest.sourceID == sourceID,
              manifest.usesSupportedPlaybackFormat, SyncedArticleAudioStore.hasLocalChunks(for: manifest) else { return false }
        let hash = SyncIdentity.sha256Hex(bytes)
        guard attempts[sourceID].map({ $0.hash != hash || clock().timeIntervalSince($0.at) >= Self.retryAfter }) != false else { return false }
        attempts[sourceID] = (hash, clock())

        guard let view = try await Self.views(sourceIDs: [sourceID], session: session)[sourceID] else { return false }
        let zone = try await Self.contentZone(session)
        let role = NarrationSatellites.role(model: manifest.model, voice: manifest.voice)
        let current = view.file?.role == role ? view.file : nil
        let known = Dictionary((current?.children ?? []).compactMap { child in child.key.map { ($0, child) } }, uniquingKeysWith: { first, _ in first })

        let ordered = manifest.chunks.sorted { $0.index < $1.index }
        let directory = url.deletingLastPathComponent().appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        let blobs = session.blobs
        var children: [FileRef] = []
        for window in stride(from: 0, to: ordered.count, by: Self.width).map({ Array(ordered[$0 ..< min($0 + Self.width, ordered.count)]) }) {
            let uploaded = try await withThrowingTaskGroup(of: (Int, FileRef).self) { group in
                for (place, chunk) in window.enumerated() {
                    group.addTask {
                        let body = try Data(contentsOf: directory.appendingPathComponent(chunk.fileName), options: .mappedIfSafe)
                        let file = try await blobs.upload(
                            body, owner: sourceID, ownerType: .source, role: NarrationSatellites.chunkRole,
                            mime: NarrationSatellites.chunkMime(fileName: chunk.fileName), encoding: .identity, into: zone,
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
        // The Mac may have been told to drop this narration while its bytes went up.
        guard !removals.contains(sourceID) else { return false }
        guard try await session.store.onStore({ try $0.pointNarration(sourceID: sourceID, to: file) }) else { return false }
        NarrationFolder.writePointer(file.hash, sourceID: sourceID)
        await session.wrote()
        return true
    }

    // MARK: - Playing

    /// Brings the chunks of a narration the replica holds into the folder, a few at a time and in order, so
    /// the contiguous prefix grows. A chunk already here is not fetched.
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
              let file = try await Self.views(sourceIDs: [manifest.sourceID], session: session)[manifest.sourceID]?.file else {
            throw SyncedArticleAudioStoreError.missingAudioChunk(manifest.sourceID)
        }
        let zone = try await Self.contentZone(session)
        var inOrder = manifest
        inOrder.chunks = ordered
        let children = NarrationSatellites.children(of: file, manifest: inOrder)
        let missing = ordered.indices.filter { !SyncedArticleAudioStore.isMaterializedChunk(urls[$0]) }
        let blobs = session.blobs
        for window in stride(from: 0, to: missing.count, by: Self.width).map({ Array(missing[$0 ..< min($0 + Self.width, missing.count)]) }) {
            try Task.checkCancellation()
            let fetched = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for index in window {
                    guard let child = children[index] else { throw SyncedArticleAudioStoreError.missingAudioChunk(ordered[index].fileName) }
                    group.addTask {
                        // Bound before the tuple: AGENTS.md's Release miscompile.
                        let data = try await blobs.fetch(child, from: zone)
                        return (index, data)
                    }
                }
                var found: [(Int, Data)] = []
                for try await item in group { found.append(item) }
                return found.sorted { $0.0 < $1.0 }
            }
            for (index, body) in fetched { try NarrationFolder.place(body, at: urls[index]) }
            let progress = measure()
            if progress != last {
                last = progress
                onProgress(progress)
            }
        }
        guard measure().isComplete else { throw SyncedArticleAudioStoreError.missingAudioChunk(manifest.sourceID) }
        didChange(manifest.sourceID)
    }

    // MARK: - Carrying generation 1's narration

    /// Copies the whole narrations in iCloud Drive into the working folder (`NarrationCarryOver.carry`), once
    /// per store: only while the audio store uses this library's folder (generation 2), only once `Library`
    /// and `Catalog` have each had a complete fetch (so a source not in the library is not merely still on its
    /// way), and never again once a run finished, which `ck_engine_state` remembers. A run that could not copy
    /// one is tried again at the next launch, at most `NarrationCarryOver.runsBeforeGivingUp` times. The files
    /// are read and copied on a detached utility task, so the library keeps answering meanwhile. Nil when it
    /// did not run.
    @discardableResult
    func carryFromICloudDrive() async -> NarrationCarryOver.Outcome? {
        guard let source = iCloudDriveAudio, !carrying, !carryRan else { return nil }
        guard let working = SyncedArticleAudioStore.workingFolder?.root,
              working.standardizedFileURL == folder.root.standardizedFileURL,
              NarrationCarryOver.areApart(source, folder.root) else { return nil }
        guard let session = await session() else { return nil }
        carrying = true
        defer { carrying = false }

        let scope = NarrationCarryOver.scope
        let found: (marker: Data?, fetched: Bool)
        do {
            found = try await session.store.perform { state in
                let complete = try state.connection.scalarInteger(
                    "SELECT COUNT(*) FROM ck_zones WHERE kind IN ('library', 'catalog') AND last_complete_pass_at IS NOT NULL"
                ) ?? 0
                return (marker: try state.replica.engineState(scope), fetched: complete == 2)
            }
        } catch {
            return nil
        }
        guard case .owed(let failedRuns) = NarrationCarryOver.standing(found.marker) else {
            carryRan = true
            return nil
        }
        guard found.fetched else { return nil }

        folder.prepare()
        let audio = folder.root.appendingPathComponent("Audio", isDirectory: true)
        let staging = folder.root.appendingPathComponent(".carrying", isDirectory: true)
        let whole = await Task.detached(priority: .utility) { NarrationCarryOver.wholeNarrations(in: source) }.value
        let ids = Array(Set(whole.map(\.manifest.sourceID))).sorted()
        let sources: Set<String>
        do {
            sources = try await session.store.onStore { try $0.sourcesWithoutNarration(among: ids) }
        } catch {
            return nil
        }
        let removals = removals
        let outcome = await Task.detached(priority: .utility) {
            NarrationCarryOver.carry(whole, sources: sources, into: audio, staging: staging, skipping: { removals.contains($0) })
        }.value

        carryRan = true
        let next = NarrationCarryOver.marker(after: outcome, failedRuns: failedRuns)
        do {
            try await session.store.perform { try $0.replica.setEngineState(scope, next.marker) }
        } catch {
            Self.logger.error("The carry of narration from iCloud Drive was not recorded: \(String(describing: error), privacy: .public)")
        }
        for id in outcome.carried { didChange(id) }
        Self.logger.notice(
            "Carried \(outcome.carried.count) narrations from iCloud Drive into the working folder; \(outcome.failed.count) could not be copied"
        )
        return outcome
    }

    // MARK: - Removing

    /// The learner removed a source's narration here: its pointer goes too, or the next pass would lay it down
    /// again. Called while the audio store removes the folder, so the source is set apart at once and the pointer
    /// is cleared after, in step with any pass that runs.
    nonisolated func removeNarration(sourceID: String) {
        removals.insert(sourceID)
        Task(priority: .utility) { [self] in await finishRemoval(sourceID: sourceID) }
    }

    private func finishRemoval(sourceID: String) async {
        defer { removals.remove(sourceID) }
        guard let session = await session() else { return }
        do {
            try await session.store.onStore { try $0.clearNarration(sourceID: sourceID) }
            await session.wrote()
        } catch {
            Self.logger.error("A narration's pointer was not cleared: \(String(describing: error), privacy: .public)")
        }
        // A pass that ran in between may have laid the narration down again.
        try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID))
        didChange(sourceID)
    }
}

/// The sources whose narration the learner just removed: no pass lays one down or uploads it while its pointer
/// is being cleared.
final class NarrationRemovals: @unchecked Sendable {
    private let lock = AppLock()
    private var held: Set<String> = []

    func insert(_ id: String) { lock.withLock { _ = held.insert(id) } }
    func remove(_ id: String) { lock.withLock { _ = held.remove(id) } }
    func contains(_ id: String) -> Bool { lock.withLock { held.contains(id) } }
}

/// Generation 1's narration carried into the working folder (§14.2 NARR3's gap): what it made sat in ForeverLM's
/// iCloud Documents folder (`Audio/<source>/manifest.json` and `Chunks/`), which no build is entitled to any more,
/// so under generation 2 nothing played it or sent it to the replica. The folder is read by plain path, never
/// through a ubiquity API, and only read: every file is copied (a clone on APFS), never moved.
///
/// A narration is carried when it is whole (its manifest decodes and plays here, and every chunk it names is a
/// downloaded file of exactly the byte count it gives), its source is in the library and names no narration, and
/// the working folder holds none for it. Each is assembled in a staging folder beside `Audio`, every size checked,
/// and moved in at once, so the folder never shows half of one; the library's next pass then finds a complete
/// narration this Mac never sent and uploads it, as it does one it just generated.
enum NarrationCarryOver {
    /// The `ck_engine_state` scope that remembers the carry on this store: `done`, or `failed <n>` after n runs that
    /// could not copy everything.
    static let scope = "narration.carriedFromICloudDrive"
    /// A run that could not copy a narration (a disk error) is tried again at the next launch, this many in all.
    static let runsBeforeGivingUp = 3

    enum Standing: Equatable, Sendable {
        case owed(failedRuns: Int)
        case done
    }

    struct Found: Sendable {
        /// The narration's folder in iCloud Drive.
        let directory: URL
        let manifest: SyncedArticleAudioManifest
        /// The manifest file's bytes, written unchanged, so every Mac that carries it sends the same satellite.
        let bytes: Data
    }

    struct Outcome: Equatable, Sendable {
        /// Sources whose narration is now in the working folder.
        var carried: [String] = []
        /// Sources whose narration could not be copied this run.
        var failed: [String] = []
    }

    static func standing(_ marker: Data?) -> Standing {
        guard let marker else { return .owed(failedRuns: 0) }
        let text = String(decoding: marker, as: UTF8.self)
        guard text.hasPrefix("failed "), let runs = Int(text.dropFirst("failed ".count)) else { return .done }
        return runs >= runsBeforeGivingUp ? .done : .owed(failedRuns: runs)
    }

    /// What a run leaves in `scope`: `done` once nothing failed, or after the last run allowed.
    static func marker(after outcome: Outcome, failedRuns: Int) -> (marker: Data, done: Bool) {
        let runs = outcome.failed.isEmpty ? 0 : failedRuns + 1
        guard runs > 0, runs < runsBeforeGivingUp else { return (Data("done".utf8), true) }
        return (Data("failed \(runs)".utf8), false)
    }

    /// Whether neither folder lies inside the other: the carry never writes into the tree it reads.
    static func areApart(_ a: URL, _ b: URL) -> Bool {
        let first = a.standardizedFileURL.resolvingSymlinksInPath().path
        let second = b.standardizedFileURL.resolvingSymlinksInPath().path
        return first != second && !first.hasPrefix(second + "/") && !second.hasPrefix(first + "/")
    }

    /// Every whole narration under `audioRoot`, by folder name: a CloudDocs conflict copy (`<id> 2`) sorts after
    /// the folder it copies, so the original wins when both are whole.
    static func wholeNarrations(in audioRoot: URL) -> [Found] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: audioRoot.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { whole(in: audioRoot.appendingPathComponent($0, isDirectory: true)) }
    }

    /// The narration in `directory` when it is whole; nil for a generation that never finished (no manifest), a
    /// manifest this build would not play, an evicted file, or a chunk missing or of another size than the
    /// manifest says (two Macs' generations that iCloud Drive interleaved).
    static func whole(in directory: URL) -> Found? {
        let manifestURL = directory.appendingPathComponent(SyncedArticleAudioStore.manifestFileName)
        guard plainFileSize(manifestURL) != nil, let bytes = try? Data(contentsOf: manifestURL),
              let manifest = NarrationFolder.decode(bytes), manifest.usesSupportedPlaybackFormat,
              !manifest.sourceID.isEmpty else { return nil }
        let chunks = directory.appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        var names: Set<String> = []
        for chunk in manifest.chunks {
            guard isPlainName(chunk.fileName), names.insert(chunk.fileName).inserted, chunk.byteCount > 0,
                  plainFileSize(chunks.appendingPathComponent(chunk.fileName)) == chunk.byteCount else { return nil }
        }
        return Found(directory: directory, manifest: manifest, bytes: bytes)
    }

    /// Copies each found narration whose source is in `sources` into `audioRoot`, the first found for a source
    /// winning, and leaves alone a source `skipping` names or one whose folder there already holds a narration or
    /// a generation. Blocking file work: never on the main actor.
    static func carry(_ found: [Found], sources: Set<String>, into audioRoot: URL, staging: URL, skipping: (String) -> Bool) -> Outcome {
        var outcome = Outcome()
        var seen: Set<String> = []
        defer { try? FileManager.default.removeItem(at: staging) }
        for item in found {
            let id = item.manifest.sourceID
            guard sources.contains(id), seen.insert(id).inserted, !skipping(id) else { continue }
            let destination = audioRoot.appendingPathComponent(SyncedArticleAudioStore.sanitizedPathComponent(id), isDirectory: true)
            guard !holdsNarration(destination) else { continue }
            do {
                if try place(item, at: destination, staging: staging) { outcome.carried.append(id) }
            } catch {
                logger.error("A narration was not carried from iCloud Drive: \(String(describing: error), privacy: .public)")
                outcome.failed.append(id)
            }
        }
        return outcome
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM", category: "MacNarrationLibrary")

    enum CarryError: Error, Equatable {
        /// A copied file is not the size it should be.
        case sizeMismatch(String)
    }

    /// Whether a working-folder directory holds a narration, its chunks, or a generation under way.
    static func holdsNarration(_ directory: URL) -> Bool {
        [SyncedArticleAudioStore.manifestFileName, SyncedArticleAudioStore.chunksDirectoryName, ArticleSpeechGenerationProgress.fileName]
            .contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    /// One narration into its place: chunks, text and manifest copied into a staging folder and checked, then
    /// moved in whole (or, beside a saved position that is all the folder holds, its parts moved in with the
    /// manifest last). False when the folder took a narration meanwhile.
    private static func place(_ item: Found, at destination: URL, staging root: URL) throws -> Bool {
        let manager = FileManager.default
        let staged = root.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try? manager.removeItem(at: staged)
        defer { try? manager.removeItem(at: staged) }
        let chunks = staged.appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        try manager.createDirectory(at: chunks, withIntermediateDirectories: true)
        let from = item.directory.appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        for chunk in item.manifest.chunks {
            let copy = chunks.appendingPathComponent(chunk.fileName)
            try manager.copyItem(at: from.appendingPathComponent(chunk.fileName), to: copy)
            guard plainFileSize(copy) == chunk.byteCount else { throw CarryError.sizeMismatch(chunk.fileName) }
        }
        let textName = ((item.manifest.sourceTextFileName ?? SyncedArticleAudioStore.sourceTextFileName) as NSString).lastPathComponent
        let text = item.directory.appendingPathComponent(textName)
        if isPlainName(textName), plainFileSize(text) != nil {
            try manager.copyItem(at: text, to: staged.appendingPathComponent(textName))
        }
        let manifest = staged.appendingPathComponent(SyncedArticleAudioStore.manifestFileName)
        try item.bytes.write(to: manifest)
        guard plainFileSize(manifest) == item.bytes.count else { throw CarryError.sizeMismatch(SyncedArticleAudioStore.manifestFileName) }

        guard manager.fileExists(atPath: destination.path) else {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: staged, to: destination)
            return true
        }
        guard !holdsNarration(destination) else { return false }
        try manager.moveItem(at: chunks, to: destination.appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true))
        let placedText = destination.appendingPathComponent(textName)
        if manager.fileExists(atPath: staged.appendingPathComponent(textName).path), !manager.fileExists(atPath: placedText.path) {
            try manager.moveItem(at: staged.appendingPathComponent(textName), to: placedText)
        }
        try manager.moveItem(at: manifest, to: destination.appendingPathComponent(SyncedArticleAudioStore.manifestFileName))
        return true
    }

    /// A name a manifest may give a file beside it: no folder, no hidden file.
    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/")
    }

    /// The size of a regular file whose bytes are on this Mac; nil for anything else, including a file iCloud
    /// Drive evicted (`SF_DATALESS`), whose bytes would come only from a download no build may ask for.
    private static func plainFileSize(_ url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_flags & datalessFlag == 0 else { return nil }
        return Int(info.st_size)
    }

    /// `SF_DATALESS` in `<sys/stat.h>`.
    private static let datalessFlag: UInt32 = 0x4000_0000
}
