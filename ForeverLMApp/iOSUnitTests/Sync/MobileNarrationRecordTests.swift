import Foundation
import Testing
@testable import ForeverLM

/// The narration a switched phone makes and plays (docs/cloudkit-schema-design.md §3.5.30
/// `files.audio.<voiceKey>`, children `audioChunk`; §14.2 NARR2): what it generates is kept in a working
/// folder of the audio store's layout and uploaded as the source's manifest satellite with one chunk child
/// per file name, every part acknowledged before the source's pointer moves; what another device made is
/// laid down from the replica, its chunks fetched by name when something plays them; the source keeps one
/// narration; and a source the phone does not hold, or may not write, keeps its narration on the phone.
/// The audio store's paths are process-wide, so the suite runs one test at a time and puts them back.
@Suite("iPhone narration records", .serialized)
struct MobileNarrationRecordTests {
    typealias F = MobileReadModelFixture
    typealias Fixture = MobileWriterFixture

    /// A phone on FakeCloudKit that holds a source, and two working folders over its replica, standing for
    /// two devices: `use` points the audio store at one of them.
    final class Rig: @unchecked Sendable {
        let phone: MobileBlobOnDemandTests.Phone
        let writer: MobileRecordWriter
        let root: URL
        let first: MobileNarrationLibrary
        let second: MobileNarrationLibrary

        init(sources: [String] = ["src-1"]) async throws {
            phone = try await MobileBlobOnDemandTests.Phone()
            writer = MobileRecordWriter(replica: phone.device.replica, deviceID: phone.device.deviceID, blobs: phone.blobs,
                                        clock: { Date().addingTimeInterval(-60) })
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileNarration-\(UUID().uuidString)", isDirectory: true)
            self.root = root
            let writer = writer, satellites = phone.satellites
            func library(_ name: String) -> MobileNarrationLibrary {
                MobileNarrationLibrary(folder: .init(root: root.appendingPathComponent(name, isDirectory: true)),
                                       session: { (writer: writer, satellites: satellites) })
            }
            first = library("first")
            second = library("second")
            try await MobileSyncFixture.apply(try sources.map { (F.catalog, try F.source($0, "Source \($0)", added: 1, type: "article")) },
                                              to: phone.device.replica)
            use(first)
        }

        func use(_ library: MobileNarrationLibrary) {
            MobileNarrationLibrary.install(library: library)
        }

        func cleanUp() {
            SyncedArticleAudioStore.workingFolderProvider = nil
            phone.cleanUp()
            try? FileManager.default.removeItem(at: root)
        }

        /// The roles of a source's `files` that name a narration.
        func narrations(_ id: String = "src-1") async throws -> [String] {
            let source = try await Fixture.held(phone.device.replica, .source, id, in: Fixture.catalog)
            return (source?.fields["files"]?.objectValue ?? [:]).filter { $0.key.hasPrefix("audio.") && $0.value != .null }.keys.sorted()
        }

        func pointer(_ id: String = "src-1") async throws -> FileRef? {
            MobileReadModels.narrationFile(of: try await Fixture.held(phone.device.replica, .source, id, in: Fixture.catalog))
        }

        func patchCount() async throws -> Int { try await Fixture.patchCount(phone.device.replica) }

        func onServer(_ file: FileRef) -> Bool {
            file.satelliteIDs.allSatisfy { part in
                phone.device.server.storedRecord(RecordNaming.recordName(type: .content, id: part, salt: MobileSyncFixture.librarySalt),
                                                 zone: "Content", owner: "u1") != nil
            }
        }
    }

    static let model = ArticleSpeechCatalog.grokModelID
    static let created = Date(timeIntervalSince1970: 1_790_000_000)

    /// A narration of `sourceID` in the audio store's current folder: its manifest and one chunk file per body.
    @discardableResult
    static func narrate(_ sourceID: String = "src-1", voice: String = "rex", chunks: [String] = ["first chunk", "second chunk", "third chunk"],
                        at date: Date = created, skipping missing: Int? = nil) throws -> (manifest: SyncedArticleAudioManifest, hash: String) {
        let manifest = SyncedArticleAudioManifest(
            schemaVersion: SyncedArticleAudioManifest.schemaVersion, sourceID: sourceID, title: "Source \(sourceID)", subtitle: nil,
            sourceType: "article", sourceURL: "https://example.org/\(sourceID)", provider: "xai", model: model, voice: voice,
            voiceLabel: voice.capitalized, contentSignature: "signature-\(voice)", totalCharacters: 120, createdAt: date,
            chunks: chunks.enumerated().map { place, body in
                .init(index: place, fileName: SyncedArticleAudioStore.chunkFileName(index: place, fileExtension: "mp3"), byteCount: body.utf8.count, text: nil)
            },
            sourceTextFileName: nil, generatedOnPlatform: "ios"
        )
        let directory = SyncedArticleAudioStore.sourceDirectory(sourceID: sourceID)
        let folder = directory.appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (place, body) in chunks.enumerated() where place != missing {
            try Data(body.utf8).write(to: folder.appendingPathComponent(manifest.chunks[place].fileName))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(manifest)
        try bytes.write(to: SyncedArticleAudioStore.manifestURL(sourceID: sourceID))
        return (manifest, SyncIdentity.sha256Hex(bytes))
    }

    static func chunkText(_ manifest: SyncedArticleAudioManifest, _ place: Int) throws -> String {
        let url = SyncedArticleAudioStore.expectedChunkURLs(for: manifest)[place]
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // MARK: - Names and the plan

    @Test("A narration's role is audio. plus its model and voice made safe for a name; its chunks are audioChunk, typed by extension")
    func theNames() {
        #expect(MobileNarrationSatellites.role(model: "x-ai/grok-tts", voice: "Rex") == "audio.x-ai-grok-tts.rex")
        #expect(MobileNarrationSatellites.role(model: "openai/gpt-4o-mini-tts", voice: "") == "audio.openai-gpt-4o-mini-tts.default")
        #expect(MobileNarrationSatellites.role(model: "  A  B ", voice: "--v--") == "audio.a-b.v")
        #expect(MobileNarrationSatellites.chunkRole == "audioChunk")
        #expect(MobileNarrationSatellites.chunkMime(fileName: "chunk-0000.mp3") == "audio/mpeg")
        #expect(MobileNarrationSatellites.chunkMime(fileName: "chunk-0000.M4A") == "audio/mp4")
        #expect(MobileNarrationSatellites.chunkMime(fileName: "chunk-0000.wav") == "application/octet-stream")
    }

    @Test("The plan: publish what only this phone has, mirror what only the replica has, remove what the replica dropped, and let the newer win")
    func thePlan() {
        func local(_ hash: String, complete: Bool = true, pointer: String? = nil) -> MobileNarrationLocal {
            MobileNarrationLocal(hash: hash, complete: complete, createdAt: .distantPast, pointer: pointer)
        }
        func replica(held: Bool = true, _ hash: String? = nil) -> MobileNarrationReplica { MobileNarrationReplica(held: held, hash: hash) }
        typealias Plan = MobileNarrationPlan

        #expect(Plan.action(local: nil, replica: replica("a")) == .mirror, "another device made it: lay it down")
        #expect(Plan.action(local: nil, replica: replica()) == .none)
        #expect(Plan.action(local: nil, replica: replica(held: false)) == .none)

        #expect(Plan.action(local: local("a"), replica: replica()) == .publish, "made here, the replica has none")
        #expect(Plan.action(local: local("a", complete: false), replica: replica()) == .none, "a narration still being made is not uploaded")
        #expect(Plan.action(local: local("a"), replica: replica(held: false)) == .none, "a source the phone does not hold keeps its narration here")
        #expect(Plan.action(local: local("a", pointer: "a"), replica: replica()) == .remove, "the replica dropped what this folder mirrored")
        #expect(Plan.action(local: local("a", pointer: "a"), replica: replica(held: false)) == .none)

        #expect(Plan.action(local: local("a", pointer: "a"), replica: replica("a")) == .none)
        #expect(Plan.action(local: local("a"), replica: replica("a")) == .record, "in step already, so remember it")
        #expect(Plan.action(local: local("a", pointer: "a"), replica: replica("b")) == .mirror, "the replica moved on")
        #expect(Plan.action(local: local("a"), replica: replica("b")) == .compare, "two narrations, never in step: the newer wins")
        #expect(Plan.action(local: local("a", pointer: "z"), replica: replica("b")) == .compare)
    }

    // MARK: - The pointer

    @Test("The pointer files the manifest under its role and clears every other narration, and leaves the source's other files")
    func theSourceKeepsOneNarration() async throws {
        let replica = try await Fixture.replica()
        let writer = Fixture.writer(replica)
        try await Fixture.apply(replica, [(Fixture.catalog, try MobileReadModelFixture.source("src-1", "Fission", added: 1, type: "article", [
            "files": .object([
                "pdf": MobileSyncFixture.fileRef(owner: "src-1", role: "pdf", bytes: Data("pdf".utf8)).value,
                "audio.old.voice": MobileSyncFixture.fileRef(owner: "src-1", role: "audio.old.voice", bytes: Data("{}".utf8)).value,
            ]),
        ]))])
        let fresh = MobileSyncFixture.fileRef(owner: "src-1", role: "audio.new.voice", bytes: Data("{}".utf8))
        try await writer.transaction { try $0.saveNarration(sourceID: "src-1", zoneKey: Fixture.catalog, manifest: fresh) }

        let source = try #require(try await Fixture.held(replica, .source, "src-1", in: Fixture.catalog))
        let files = try #require(source.fields["files"]?.objectValue).filter { $0.value != .null }
        #expect(files.keys.sorted() == ["audio.new.voice", "pdf"], "the old voice's narration went with the new one's arrival")
        #expect(MobileReadModels.narrationFile(of: source)?.role == "audio.new.voice")

        await #expect(throws: MobileRecordWriterError.self) {
            try await writer.transaction { try $0.saveNarration(sourceID: "ghost", zoneKey: Fixture.catalog, manifest: fresh) }
        }
    }

    // MARK: - Making a narration here

    @Test("A narration made on the phone is uploaded chunks first, then the manifest, then the source names it; the replica serves it back as the player reads it")
    func publishes() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let (manifest, hash) = try Self.narrate()
        #expect(try await rig.narrations().isEmpty)

        await rig.first.refresh(only: "src-1", publishing: .awaiting)

        let role = MobileNarrationSatellites.role(model: Self.model, voice: "rex")
        #expect(try await rig.narrations() == [role])
        let file = try #require(try await rig.pointer())
        #expect(file.owner == "src-1")
        #expect(file.role == role)
        #expect(file.hash == hash, "the manifest satellite is the manifest file, byte for byte")
        #expect(file.encoding == "gzip")
        #expect(file.mime == "application/json")
        #expect(file.children.map(\.role) == Array(repeating: "audioChunk", count: 3))
        #expect(file.children.map(\.key) == manifest.chunks.map(\.fileName), "each chunk is keyed by its file name, in playback order")
        #expect(file.children.map(\.mime) == Array(repeating: "audio/mpeg", count: 3))
        #expect(rig.onServer(file), "the manifest's parts are on the server before the source points at them")
        #expect(file.children.allSatisfy { rig.onServer($0) }, "and so is every chunk's")
        #expect(MobileNarrationLibrary.readPointer(sourceID: "src-1") == hash, "the folder remembers it is in step")

        // The phone's own readers find it as they find any narration.
        let satellite = try #require(try await rig.phone.satellites.source("src-1") { $0.hasPrefix("audio.") })
        let bytes = try await rig.phone.satellites.data(satellite)
        #expect(MobileNarrationLibrary.decode(bytes) == manifest)
        let chunks = MobileNarrationChunks.satellites(of: satellite, manifest: manifest)
        #expect(chunks.count == 3 && chunks.allSatisfy { $0 != nil })
        #expect(String(decoding: try await rig.phone.satellites.data(try #require(chunks[1])), as: UTF8.self) == "second chunk")
    }

    @Test("A narration that is already in the replica is not uploaded again, and two refreshes at once upload it once")
    func uploadsOnce() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate()
        async let one: Void = rig.first.refresh(only: "src-1", publishing: .awaiting)
        async let two: Void = rig.first.refresh(only: "src-1", publishing: .awaiting)
        _ = await (one, two)
        let pointer = try #require(try await rig.pointer())
        let patches = try await rig.patchCount()

        await rig.first.refresh(only: "src-1", publishing: .awaiting)
        await rig.first.refresh(publishing: .awaiting)
        #expect(try await rig.patchCount() == patches, "nothing is written when the replica already names this narration")
        #expect(try await rig.pointer() == pointer)
    }

    @Test("A narration still being made, a source the phone does not hold, and a space it may only read are not uploaded; the narration stays on the phone")
    func keepsWhatItMayNotUpload() async throws {
        let rig = try await Rig(sources: ["src-1", "src-open"])
        defer { rig.cleanUp() }
        let patches = try await rig.patchCount()

        // A chunk that has not been written yet.
        let partial = try Self.narrate("src-1", skipping: 1)
        await rig.first.refresh(only: "src-1", publishing: .awaiting)
        #expect(try await rig.narrations().isEmpty)
        #expect(MobileNarrationLibrary.localState(sourceID: "src-1")?.complete == false)
        #expect(MobileNarrationLibrary.readPointer(sourceID: "src-1") == nil)
        #expect(partial.manifest.chunks.count == 3)

        // A source this phone never held.
        let ghost = try Self.narrate("ghost")
        await rig.first.refresh(only: "ghost", publishing: .awaiting)
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.manifestURL(sourceID: "ghost").path), "its narration is still here")
        #expect(MobileNarrationLibrary.readPointer(sourceID: "ghost") == nil)
        #expect(ghost.hash.count == 64)

        // A source only a space holds, where the member may only read.
        try await MobileSyncFixture.holdSpace(rig.phone.device.replica, zoneKey: F.space, zoneName: "Space-s1", owned: false, name: "Acme Lab",
                                              permission: "readOnly")
        try await MobileSyncFixture.apply([(F.space, try MobileSyncFixture.envelope(
            .source, "src-team", ["primaryKey": .string("native:src-team"), "type": .string("article"), "title": .string("Team"), "status": .string("active"),
                                  "addedAt": SyncJSON(1)], salt: MobileSyncFixture.spaceSalt))], to: rig.phone.device.replica,
                                         salt: MobileSyncFixture.spaceSalt)
        try Self.narrate("src-team")
        await rig.first.refresh(only: "src-team", publishing: .awaiting)
        #expect(try await rig.narrations("src-team").isEmpty)
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.manifestURL(sourceID: "src-team").path))

        #expect(try await rig.patchCount() == patches, "no pointer was written for any of them")
        #expect(try await rig.narrations("src-open").isEmpty)
    }

    @Test("A new voice replaces the source's narration: its role goes, the new one stays, and the other files are untouched")
    func aNewVoiceReplacesTheOld() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let pdf = try await rig.phone.upload("%PDF-1.4 mitochondria", owner: "src-1", role: "pdf", into: rig.phone.personal)
        try await MobileSyncFixture.apply([(F.catalog, try F.source("src-1", "Source src-1", added: 1, type: "article", ["files": .object(["pdf": pdf.value])]))],
                                          to: rig.phone.device.replica)
        try Self.narrate("src-1", voice: "rex", chunks: ["a", "b"])
        await rig.first.refresh(only: "src-1", publishing: .awaiting)
        #expect(try await rig.narrations() == [MobileNarrationSatellites.role(model: Self.model, voice: "rex")])

        try Self.narrate("src-1", voice: "eve", chunks: ["c", "d", "e"], at: Self.created.addingTimeInterval(60))
        await rig.first.refresh(only: "src-1", publishing: .awaiting)
        #expect(try await rig.narrations() == [MobileNarrationSatellites.role(model: Self.model, voice: "eve")], "one narration per source")
        let source = try #require(try await Fixture.held(rig.phone.device.replica, .source, "src-1", in: Fixture.catalog))
        #expect(source.fields["files"]?["pdf"].flatMap(FileRef.init(json:))?.hash == pdf.hash)
        #expect(try await rig.pointer()?.children.count == 3)
    }

    // MARK: - Another device's narration

    @Test("Another device's narration is laid down as the audio store's manifest, its chunks fetched by name when played, in order, once")
    func mirrorsAndPlays() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let (manifest, hash) = try Self.narrate()
        await rig.first.refresh(only: "src-1", publishing: .awaiting)

        // A second phone: an empty folder over the same replica.
        rig.use(rig.second)
        #expect(SyncedArticleAudioStore.libraryRootURL() == rig.second.folder.root)
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") == nil, "nothing is on this folder yet")
        let held = await SyncedArticleAudioStore.awaitPublishedManifest(sourceID: "src-1")
        #expect(held == manifest, "the store asks the replica, and what it holds is laid down at once")
        #expect(MobileNarrationLibrary.readPointer(sourceID: "src-1") == hash)
        #expect(SyncedArticleAudioStore.hasLocalChunks(for: manifest) == false, "no chunk is fetched until something plays it")

        let before = rig.phone.fetches()
        let progress = ProgressLog()
        try await SyncedArticleAudioStore.materializeChunks(for: manifest) { progress.add($0) }
        #expect(SyncedArticleAudioStore.hasLocalChunks(for: manifest))
        #expect(try (0 ..< 3).map { try Self.chunkText(manifest, $0) } == ["first chunk", "second chunk", "third chunk"])
        #expect(rig.phone.fetches() - before <= 3, "a chunk is fetched by name, once")
        let steps = progress.values
        #expect(steps.last?.isComplete == true)
        #expect(steps.map(\.contiguousChunks) == steps.map(\.contiguousChunks).sorted(), "the playable prefix only grows")

        let fetched = rig.phone.fetches()
        try await SyncedArticleAudioStore.materializeChunks(for: manifest) { _ in }
        #expect(rig.phone.fetches() == fetched, "a chunk already in the folder is not fetched again")

        // A chunk lost from the folder comes back by name, and only that one is asked for.
        try FileManager.default.removeItem(at: SyncedArticleAudioStore.expectedChunkURLs(for: manifest)[1])
        let resumed = ProgressLog()
        try await SyncedArticleAudioStore.materializeChunks(for: manifest) { resumed.add($0) }
        #expect(resumed.values.first == SyncedArticleAudioDownloadProgress(readyChunks: 2, contiguousChunks: 1, totalChunks: 3))
        #expect(try Self.chunkText(manifest, 1) == "second chunk")

        // The narration the phone laid down is not uploaded back: it is in step with the replica.
        let patches = try await rig.patchCount()
        await rig.second.refresh(publishing: .awaiting)
        #expect(try await rig.patchCount() == patches)
    }

    @Test("A full pass lays down every narration the replica holds, and one the replica dropped goes from the folder")
    func aFullPassFollowsTheReplica() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let (_, hash) = try Self.narrate()
        await rig.first.refresh(only: "src-1", publishing: .awaiting)
        let file = try #require(try await rig.pointer())
        #expect(file.hash == hash)

        rig.use(rig.second)
        await rig.second.refresh()
        #expect(MobileNarrationLibrary.readPointer(sourceID: "src-1") == hash, "the pass found the source by its index")
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.manifestURL(sourceID: "src-1").path))

        // The replica drops the narration (a later write clears the pointer).
        let later = MobileSyncFixture.stampMilliseconds + 3_600_000_000_000
        try await MobileSyncFixture.apply([(F.catalog, try MobileSyncFixture.envelope(
            .source, "src-1", ["primaryKey": .string("native:src-1"), "type": .string("article"), "title": .string("Source src-1"), "status": .string("active"),
                               "addedAt": SyncJSON(1), "files": .object([file.role: .null])], at: later))], to: rig.phone.device.replica)
        #expect(try await rig.pointer() == nil)
        await rig.second.refresh()
        #expect(!FileManager.default.fileExists(atPath: SyncedArticleAudioStore.sourceDirectory(sourceID: "src-1").path), "the folder dropped what it mirrored")
        #expect(MobileNarrationLibrary.localStates().isEmpty)
    }

    @Test("Two narrations never in step: the newer one wins, whichever side made it")
    func theNewerWins() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let (older, olderHash) = try Self.narrate(voice: "rex", chunks: ["old one", "old two"], at: Self.created)
        await rig.first.refresh(only: "src-1", publishing: .awaiting)

        // This folder made a newer one meanwhile (never in step with the replica): it replaces the replica's.
        rig.use(rig.second)
        let (newer, newerHash) = try Self.narrate(voice: "rex", chunks: ["new one", "new two", "new three"], at: Self.created.addingTimeInterval(120))
        #expect(MobileNarrationLibrary.localState(sourceID: "src-1")?.pointer == nil)
        await rig.second.refresh(only: "src-1", publishing: .awaiting)
        #expect(try await rig.pointer()?.hash == newerHash, "the newer manifest took the pointer")
        #expect(try await rig.pointer()?.children.count == 3)
        #expect(newer.chunks.count == 3 && older.chunks.count == 2 && olderHash != newerHash)

        // And a folder holding an older one is brought to the replica's.
        rig.use(rig.first)
        try FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: "src-1"))
        try Self.narrate(voice: "rex", chunks: ["stale"], at: Self.created.addingTimeInterval(-600))
        await rig.first.refresh(only: "src-1", publishing: .awaiting)
        #expect(try await rig.pointer()?.hash == newerHash, "an older narration does not take the pointer")
        #expect(MobileNarrationLibrary.readPointer(sourceID: "src-1") == newerHash, "the folder now mirrors the replica's")
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1")?.chunks.count == 3)
    }

    @Test("A narration that replaces another takes the old chunks with it: every narration numbers its files chunk-0000 on, so they would play the old audio")
    func aReplacedNarrationTakesItsChunksWithIt() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate(voice: "rex", chunks: ["old one", "old two", "old three"], at: Self.created)
        await rig.first.refresh(only: "src-1", publishing: .awaiting)

        // The second folder lays it down and plays it, so it holds every chunk.
        rig.use(rig.second)
        await rig.second.refresh(only: "src-1")
        let before = try #require(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1"))
        try await SyncedArticleAudioStore.materializeChunks(for: before) { _ in }
        #expect(try Self.chunkText(before, 0) == "old one")

        // A newer narration of the same names is made elsewhere and takes the pointer.
        rig.use(rig.first)
        try Self.narrate(voice: "eve", chunks: ["new one", "new two", "new three"], at: Self.created.addingTimeInterval(600))
        await rig.first.refresh(only: "src-1", publishing: .awaiting)

        rig.use(rig.second)
        await rig.second.refresh(only: "src-1")
        let after = try #require(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1"))
        #expect(after.voice == "eve")
        #expect(SyncedArticleAudioStore.hasLocalChunks(for: after) == false, "the old narration's chunk files went with its manifest")
        try await SyncedArticleAudioStore.materializeChunks(for: after) { _ in }
        #expect(try (0 ..< 3).map { try Self.chunkText(after, $0) } == ["new one", "new two", "new three"])
    }

    // MARK: - Where the store reads

    @Test("The audio store reads an Application Support folder out of backups")
    func theStoreReadsTheWorkingFolder() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let before = SyncedArticleAudioStore.libraryRootURL()
        #expect(before == rig.first.folder.root, "the working folder")
        #expect(try rig.first.folder.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "the replica holds every byte")

        let folder = MobileNarrationLibrary.Folder(environment: .current)
        #expect(folder.root.path.contains("/Application Support/ForeverLM/"))
        #expect(folder.root.lastPathComponent.contains("Narration"))
    }

    /// Progress reports from a materialize, collected across tasks.
    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SyncedArticleAudioDownloadProgress] = []
        func add(_ item: SyncedArticleAudioDownloadProgress) { lock.lock(); items.append(item); lock.unlock() }
        var values: [SyncedArticleAudioDownloadProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
