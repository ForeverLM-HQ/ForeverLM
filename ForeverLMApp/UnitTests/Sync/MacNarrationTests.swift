import Foundation
import Testing
@testable import ForeverLM

/// The narration a Mac on generation 2 makes and plays (docs/cloudkit-schema-design.md §3.5.30
/// `files.audio.<voiceKey>`, children `audioChunk`; §14.2 NARR3), in the shape the iPhone writes: what the Mac
/// generates is kept in a working folder of the audio store's layout and uploaded as the source's manifest
/// satellite with one chunk child per file name, every part acknowledged before the source's pointer is
/// written; what another device made is laid down from the replica, its chunks fetched by name when something
/// plays them; the source keeps one narration; and a source the Mac does not hold as the learner's own keeps
/// its narration here. The audio store's paths are process-wide, so the suite runs one test at a time and puts
/// them back. Two Macs on one FakeCloudKit stand for two devices, each with a working folder of its own.
@Suite("Mac narration records", .serialized)
struct MacNarrationTests {
    typealias M = MaintenanceFixture

    /// Two Macs holding the library and a source, and a working folder for each: `use` points the audio store at one.
    final class Rig: @unchecked Sendable {
        let server: FakeCloudKit
        let a: EngineTestDevice
        let b: EngineTestDevice
        let root: URL
        let clock = NotebookCoverFixture.Clock()
        private let tally = Tally()
        private(set) var libraries: [String: MacNarrationLibrary] = [:]

        var changes: [String] { tally.announced }
        func wrote(_ device: String) -> Int { tally.sent(device) }

        init(sources: [String] = ["src-1"]) async throws {
            server = EngineTestDriver.server()
            a = try await NotebookCoverFixture.mac(server, "narr-a", deviceID: "macaaaaa")
            for id in sources { try NotebookSyncFixture.addSource(a.store, id) }
            await EngineTestDriver.pause()
            try await a.send()
            b = try EngineTestDevice(server, name: "narr-b", deviceID: "macbbbbb", registry: KnowledgeStore.projectionRegistry)
            try await b.bootstrap(.macWithoutLibrary)
            try await b.sync()
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MacNarration-\(UUID().uuidString)", isDirectory: true)
            libraries["a"] = library("a", device: a)
            libraries["b"] = library("b", device: b)
            use("a")
        }

        private func library(_ name: String, device: EngineTestDevice) -> MacNarrationLibrary {
            let clock = clock
            let blobs = M.blobs(device, clock: { clock.now })
            let store = device.local
            let tally = tally
            return MacNarrationLibrary(
                folder: .init(root: root.appendingPathComponent(name, isDirectory: true)),
                session: { MacNarrationLibrary.Session(store: store, blobs: blobs, wrote: { tally.noteSent(name) }) },
                didChange: { id in tally.noteChange("\(name):\(id)") },
                clock: { clock.now },
                iCloudDriveAudio: iCloudDrive
            )
        }

        /// Generation 1's narration folder, standing in for ForeverLM's iCloud Documents `Audio`.
        var iCloudDrive: URL { root.appendingPathComponent("iCloud Drive/Audio", isDirectory: true) }

        /// `name` launched again: a new library over the same store and working folder.
        func relaunch(_ name: String = "a") {
            libraries[name] = library(name, device: device(name))
            use(name)
        }

        var library: MacNarrationLibrary { libraries[current]! }
        private(set) var current = "a"

        func use(_ name: String) {
            current = name
            MacNarrationLibrary.install(library: libraries[name]!, generation: { .two })
        }

        func device(_ name: String) -> EngineTestDevice { name == "a" ? a : b }

        func cleanUp() {
            SyncedArticleAudioStore.workingFolderProvider = nil
            try? FileManager.default.removeItem(at: root)
        }

        /// What the server's record of a source says its `files` hold of a narration, by role (removed ones left out).
        func serverNarrations(_ id: String = "src-1") throws -> [String: FileRef] {
            let files = try a.serverEnvelope(.source, id, zone: "Catalog")?.fields["files"]?.objectValue ?? [:]
            return files.filter { $0.key.hasPrefix("audio.") }.compactMapValues { FileRef(json: $0) }
        }

        func serverRoles(_ id: String = "src-1") throws -> [String] { try serverNarrations(id).keys.sorted() }

        func pointers(_ name: String = "a") async throws -> [String: String] {
            try await device(name).local.onStore { try $0.narrationPointers() }
        }

        /// Sends what `name` wrote, as the coordinator's `sendSoon` would.
        func send(_ name: String = "a") async throws {
            await EngineTestDriver.pause()
            try await device(name).send()
        }

        /// `name` takes in what the server holds now.
        func catchUp(_ name: String = "b") async throws {
            try await device(name).fetch()
        }

        /// Content satellites on the server.
        func contentRecords() -> Int {
            server.recordNames(zone: "Content", owner: "alice").count
        }
    }

    static let model = ArticleSpeechCatalog.grokModelID
    static let created = Date(timeIntervalSince1970: 1_790_000_000)

    /// A narration of `sourceID` in the audio store's current folder: its manifest and one chunk file per body.
    @discardableResult
    static func narrate(_ sourceID: String = "src-1", voice: String = "rex", chunks: [String] = ["first chunk", "second chunk", "third chunk"],
                        at date: Date = created, platform: String = "macos", skipping missing: Int? = nil) throws -> (manifest: SyncedArticleAudioManifest, hash: String, bytes: Data) {
        let manifest = SyncedArticleAudioManifest(
            schemaVersion: SyncedArticleAudioManifest.schemaVersion, sourceID: sourceID, title: "Source \(sourceID)", subtitle: nil,
            sourceType: "article", sourceURL: "https://example.org/\(sourceID)", provider: "xai", model: model, voice: voice,
            voiceLabel: voice.capitalized, contentSignature: "signature-\(voice)", totalCharacters: 120, createdAt: date,
            chunks: chunks.enumerated().map { place, body in
                .init(index: place, fileName: SyncedArticleAudioStore.chunkFileName(index: place, fileExtension: "mp3"), byteCount: body.utf8.count, text: nil)
            },
            sourceTextFileName: nil, generatedOnPlatform: platform
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
        return (manifest, SyncIdentity.sha256Hex(bytes), bytes)
    }

    static func chunkText(_ manifest: SyncedArticleAudioManifest, _ place: Int) throws -> String {
        let url = SyncedArticleAudioStore.expectedChunkURLs(for: manifest)[place]
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// Waits for `condition`, which a background upload makes true.
    static func eventually(_ seconds: Double = 15, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return try await condition()
    }

    // MARK: - What a Mac writes

    @Test("A narration the Mac made is uploaded in the phone's shape: gzip manifest satellite, audioChunk children keyed by file name, one pointer")
    func writesThePhonesShape() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let made = try Self.narrate()

        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()

        let role = NarrationSatellites.role(model: Self.model, voice: "rex")
        let files = try rig.serverNarrations()
        #expect(Array(files.keys) == [role], "one narration, under the audio.<model>.<voice> role")
        let file = try #require(files[role])
        #expect(file.hash == made.hash, "the manifest satellite is the manifest file's bytes")
        #expect(file.owner == "src-1" && file.mime == "application/json" && file.encoding == "gzip")
        #expect(file.children.map(\.key) == made.manifest.chunks.map(\.fileName), "each chunk is keyed by its file name, in playback order")
        #expect(file.children.allSatisfy { $0.role == "audioChunk" && $0.mime == "audio/mpeg" && $0.encoding == "identity" && $0.owner == "src-1" })
        #expect(try M.onServer(rig.a, file), "the manifest and every chunk are on the server")
        #expect(try await rig.pointers() == ["src-1": made.hash])
        #expect(NarrationFolder.readPointer(sourceID: "src-1") == made.hash, "the folder remembers it is in step")
        #expect(rig.wrote("a") == 1, "the coordinator was asked to send")

        // What the phone does with the same record: its chunks resolve by name, and the manifest is the bytes.
        let satellites = NarrationSatellites.children(of: file, manifest: made.manifest)
        #expect(satellites.compactMap { $0 }.count == 3)
        let zone = try #require(try await rig.b.local.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        let fetched = try await M.blobs(rig.b, clock: { rig.clock.now }).fetch(file, from: zone)
        #expect(fetched == made.bytes)
    }

    @Test("Bytes go before the pointer: a chunk the server refuses leaves no pointer and nothing queued, and the retry sends only what is missing")
    func pointerWaitsForTheBytes() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let made = try Self.narrate()
        let salt = try #require(try rig.a.personalSalt())
        let second = SyncIdentity.contentID(owner: "src-1", role: "audioChunk", partHash32: FileRef.partHash32(Data("second chunk".utf8)))
        rig.server.failRecord(RecordNaming.recordName(type: .content, id: second, salt: salt), times: 1, with: CloudError(.internalError, message: "refused"))

        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        #expect(try rig.serverRoles().isEmpty, "no pointer on the server")
        #expect(try await rig.pointers().isEmpty, "no pointer row written")
        #expect(try rig.a.outboxRows() == 0, "nothing waits in the outbox")
        #expect(NarrationFolder.readPointer(sourceID: "src-1") == nil)

        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        #expect(try await rig.pointers().isEmpty, "a failed upload is tried again no sooner than a minute later")

        rig.clock.advance(61)
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        let file = try #require(try rig.serverNarrations().values.first)
        #expect(file.hash == made.hash)
        #expect(try M.onServer(rig.a, file))
    }

    @Test("A narration already sent is not sent again, and the replica's pointer stays")
    func noSecondUpload() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        let records = rig.contentRecords()
        let sent = rig.wrote("a")

        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        await rig.library.refresh(publishing: .awaiting)
        try await rig.send()
        #expect(rig.contentRecords() == records, "no satellite is made twice")
        #expect(rig.wrote("a") == sent, "no second pointer write")
    }

    @Test("A source keeps one narration: a new voice replaces the old audio, and the server's record drops the old role")
    func oneNarrationPerSource() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate(voice: "rex")
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        #expect(try rig.serverRoles() == [NarrationSatellites.role(model: Self.model, voice: "rex")])

        try Self.narrate(voice: "eve", chunks: ["other one", "other two"], at: Self.created.addingTimeInterval(3_600))
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        #expect(try rig.serverRoles() == [NarrationSatellites.role(model: Self.model, voice: "eve")], "one narration per source")
        let rows = try rig.a.count("SELECT COUNT(*) FROM source_files WHERE source_id = 'src-1' AND substr(role, 1, 6) = 'audio.'")
        #expect(rows == 1)
        let envelope = try #require(try rig.a.serverEnvelope(.source, "src-1", zone: "Catalog"))
        #expect(envelope.fields["files"]?.objectValue?[NarrationSatellites.role(model: Self.model, voice: "rex")] == .null, "the old role carries a removal marker")
    }

    @Test("A finished generation is sent: saving the manifest asks the library, which uploads in the background")
    func aFinishedGenerationIsSent() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        for (index, body) in ["one", "two"].enumerated() {
            _ = try SyncedArticleAudioStore.saveChunk(Data(body.utf8), sourceID: "src-1", index: index, fileExtension: "mp3")
        }
        let manifest = SyncedArticleAudioManifest(
            schemaVersion: SyncedArticleAudioManifest.schemaVersion, sourceID: "src-1", title: "Source", subtitle: nil, sourceType: "article",
            sourceURL: "https://example.org/src-1", provider: "xai", model: Self.model, voice: "rex", voiceLabel: "Rex",
            contentSignature: "sig", totalCharacters: 6, createdAt: Self.created,
            chunks: (0..<2).map { .init(index: $0, fileName: SyncedArticleAudioStore.chunkFileName(index: $0, fileExtension: "mp3"), byteCount: 3, text: nil) },
            sourceTextFileName: nil, generatedOnPlatform: "macos"
        )
        try SyncedArticleAudioStore.saveManifest(manifest)

        #expect(try await Self.eventually { try await rig.pointers()["src-1"] != nil }, "the pointer is written once the bytes are up")
        try await rig.send()
        #expect(try rig.serverRoles() == [NarrationSatellites.role(model: Self.model, voice: "rex")])
    }

    @Test("A source the Mac does not hold as the learner's own keeps its narration here: a copy in a team, an id nobody holds")
    func staysOnTheMac() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try NotebookSyncFixture.addTeamCopy(rig.a.store, "team-src", of: "src-1")
        try Self.narrate("team-src")
        try Self.narrate("ghost")
        let records = rig.contentRecords()

        await rig.library.refresh(publishing: .awaiting)
        try await rig.send()
        #expect(rig.contentRecords() == records, "nothing was uploaded")
        #expect(try await rig.pointers().isEmpty)
        #expect(NarrationFolder.readPointer(sourceID: "team-src") == nil && NarrationFolder.readPointer(sourceID: "ghost") == nil)
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.manifestURL(sourceID: "ghost").path), "the narration stays on this Mac")
    }

    @Test("A narration whose audio is not all here is not uploaded")
    func incompleteStaysHere() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate(skipping: 1)
        let records = rig.contentRecords()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        #expect(rig.contentRecords() == records)
        #expect(try await rig.pointers().isEmpty)
    }

    // MARK: - What a Mac reads

    @Test("Another Mac's narration is laid down from the replica and plays: manifest first, chunks fetched by name when asked, nothing written")
    func laidDownAndPlayed() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let made = try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()

        rig.use("b")
        try await rig.catchUp()
        let patches = try rig.b.outboxRows()
        await rig.library.refresh(only: "src-1")
        let laid = try #require(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1"), "the manifest is laid down")
        #expect(laid == made.manifest)
        #expect(SyncedArticleAudioStore.hasLocalChunks(for: laid) == false, "the chunks wait until something plays them")
        #expect(NarrationFolder.readPointer(sourceID: "src-1") == made.hash)
        #expect(ArticleSpeechAudioCache.hasCachedMarker(sourceID: "src-1"), "the narration shows as made")
        #expect(rig.changes.contains("b:src-1"), "the surfaces that show it were told")

        let progress = ProgressLog()
        try await SyncedArticleAudioStore.materializeChunks(for: laid) { progress.add($0) }
        #expect(SyncedArticleAudioStore.hasLocalChunks(for: laid))
        for (place, body) in ["first chunk", "second chunk", "third chunk"].enumerated() {
            #expect(try Self.chunkText(laid, place) == body)
        }
        #expect(progress.last?.isComplete == true)
        #expect(try rig.b.outboxRows() == patches, "opening and playing write nothing synced")
        #expect(rig.wrote("b") == 0)
        #expect(SyncedArticleAudioStore.loadCompleteManifest(sourceID: "src-1") != nil)
        #expect(try rig.serverRoles() == [NarrationSatellites.role(model: Self.model, voice: "rex")], "the replica's pointer was not touched")
    }

    @Test("Playing a source asks the replica first: one call lays the manifest down and brings every chunk in")
    func bringReplicaNarration() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        rig.use("b")
        try await rig.catchUp()

        #expect(SyncedArticleAudioStore.loadCompleteManifest(sourceID: "src-1") == nil)
        await SyncedArticleAudioStore.bringReplicaNarration(sourceID: "src-1")
        let manifest = try #require(SyncedArticleAudioStore.loadCompleteManifest(sourceID: "src-1"), "the narration plays here without being made again")
        #expect(try Self.chunkText(manifest, 2) == "third chunk")
    }

    @Test("A chunk already here is not fetched again")
    func presentChunksStay() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        rig.use("b")
        try await rig.catchUp()
        await rig.library.refresh(only: "src-1")
        let manifest = try #require(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1"))
        let urls = SyncedArticleAudioStore.expectedChunkURLs(for: manifest)
        try FileManager.default.createDirectory(at: urls[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: urls[0])

        try await SyncedArticleAudioStore.materializeChunks(for: manifest) { _ in }
        #expect(try Self.chunkText(manifest, 0) == "kept")
        #expect(try Self.chunkText(manifest, 1) == "second chunk")
    }

    @Test("A narration written the way the phone writes it plays on a Mac: keyed children, a gzip manifest, its pointer as the record's files entry")
    func thePhonesNarrationPlays() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        // The phone's writer, standing in: chunks as children keyed by name, then the manifest, then the source's pointer.
        rig.use("a")
        let made = try Self.narrate(platform: "ios")
        let blobs = M.blobs(rig.a, clock: { rig.clock.now })
        let zone = try #require(try await rig.a.local.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        var children: [FileRef] = []
        for chunk in made.manifest.chunks {
            let body = try Data(contentsOf: SyncedArticleAudioStore.expectedChunkURLs(for: made.manifest)[chunk.index])
            let file = try await blobs.upload(body, owner: "src-1", ownerType: .source, role: "audioChunk", mime: "audio/mpeg", encoding: .identity, into: zone)
            children.append(file.keyed(chunk.fileName))
        }
        let manifest = try await blobs.upload(made.bytes, owner: "src-1", ownerType: .source, role: NarrationSatellites.role(model: Self.model, voice: "rex"),
                                              mime: "application/json", encoding: .gzip, into: zone, children: children)
        let catalog = try #require(try await rig.a.local.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.catalog), in: $0) })
        let writer = MaintenanceWriter(transport: rig.a.transport, store: rig.a.local, moveMaps: MoveMapIndex(), deviceID: "phoneaaa", clock: { rig.clock.now })
        _ = try await writer.save([.init(zone: catalog, patch: RecordPatch(.source, id: "src-1", changes: ["files": .elements([manifest.role: manifest.value])]))])
        try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: "src-1"))

        rig.use("b")
        try await rig.catchUp()
        await SyncedArticleAudioStore.bringReplicaNarration(sourceID: "src-1")
        let played = try #require(SyncedArticleAudioStore.loadCompleteManifest(sourceID: "src-1"))
        #expect(played.generatedOnPlatform == "ios")
        #expect(try Self.chunkText(played, 1) == "second chunk")
    }

    @Test("A narration the replica names is not mistaken for one this Mac made: nothing is uploaded for it")
    func mirroredIsNotRepublished() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        rig.use("b")
        try await rig.catchUp()
        await rig.library.refresh(only: "src-1")
        try await SyncedArticleAudioStore.materializeChunks(for: try #require(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1"))) { _ in }
        let records = rig.contentRecords()

        await rig.library.refresh(publishing: .awaiting)
        #expect(rig.contentRecords() == records)
        #expect(rig.wrote("b") == 0)
    }

    @Test("A round that fetched a new pointer lays the narration down, and looks again only when a pointer changed or a while passed")
    func aRoundLaysItDown() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        rig.use("b")
        try await rig.catchUp()

        await rig.library.roundSettled()
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") != nil, "the round laid it down")

        try FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: "src-1"))
        await rig.library.roundSettled()
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") == nil, "nothing changed and little time passed: no second look")
        rig.clock.advance(11 * 60)
        await rig.library.roundSettled()
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") != nil, "a while passed: the folder is looked over again")
    }

    // MARK: - Two devices, one source

    @Test("When both made one, the newer wins: the older Mac lays the newer down, and its old chunks do not play under the new names")
    func theNewerWins() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let first = try Self.narrate(voice: "rex", chunks: ["old one", "old two"], at: Self.created)
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        rig.use("b")
        try await rig.catchUp()
        await rig.library.refresh(only: "src-1")

        // Mac B makes its own, later, never having been in step with the replica's.
        try? FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: "src-1"))
        let newer = try Self.narrate(voice: "eve", chunks: ["new one", "new two", "new three"], at: Self.created.addingTimeInterval(7_200))
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send("b")
        #expect(try rig.serverRoles() == [NarrationSatellites.role(model: Self.model, voice: "eve")])

        rig.use("a")
        try await rig.catchUp("a")
        await rig.library.refresh(only: "src-1")
        #expect(NarrationFolder.readPointer(sourceID: "src-1") == newer.hash, "the older Mac's folder now mirrors the replica's")
        #expect(first.hash != newer.hash)
        let laid = try #require(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1"))
        #expect(laid.voice == "eve")
        #expect(SyncedArticleAudioStore.hasLocalChunks(for: laid) == false, "the old narration's chunk files went with it")
        try await SyncedArticleAudioStore.materializeChunks(for: laid) { _ in }
        #expect(try Self.chunkText(laid, 0) == "new one")
    }

    @Test("An older narration made here never replaces a newer one in the replica: the replica's is laid down instead")
    func theOlderYields() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate(voice: "eve", chunks: ["new one", "new two"], at: Self.created.addingTimeInterval(7_200))
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()

        rig.use("b")
        try await rig.catchUp()
        try Self.narrate(voice: "rex", chunks: ["old one"], at: Self.created)
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send("b")
        #expect(try rig.serverRoles() == [NarrationSatellites.role(model: Self.model, voice: "eve")], "the newer narration stands")
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1")?.voice == "eve")
    }

    @Test("When another device drops the narration, this Mac drops the folder it mirrored; a narration made here and never sent stays")
    func theReplicaDropsOne() async throws {
        let rig = try await Rig(sources: ["src-1", "src-2"])
        defer { rig.cleanUp() }
        try Self.narrate("src-1")
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        rig.use("b")
        try await rig.catchUp()
        await rig.library.refresh(only: "src-1")
        try Self.narrate("src-2", chunks: ["incomplete"], skipping: 0)
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") != nil)

        // Mac A's learner removes it.
        try await rig.a.local.onStore { try $0.clearNarration(sourceID: "src-1") }
        try await rig.send("a")
        try await rig.catchUp()
        await rig.library.refresh(publishing: .awaiting)
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") == nil, "the folder it mirrored went")
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.manifestURL(sourceID: "src-2").path), "another source's narration stays")
    }

    // MARK: - Removing

    @Test("Removing a narration removes the account's pointer with the folder, and no pass lays it down again")
    func removingForgetsThePointer() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        #expect(try rig.serverRoles().count == 1)

        ArticleSpeechAudioCache.deleteCachedAudio(sourceID: "src-1")
        #expect(try await Self.eventually { try await rig.pointers().isEmpty }, "the pointer row is cleared")
        try await rig.send()
        #expect(try rig.serverRoles().isEmpty, "the server's record names no narration")
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") == nil)
        await rig.library.refresh(publishing: .awaiting)
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") == nil, "nothing came back")
        #expect(ArticleSpeechAudioCache.hasCachedMarker(sourceID: "src-1") == false)

        rig.use("b")
        try await rig.catchUp()
        await rig.library.refresh(publishing: .awaiting)
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") == nil)
    }

    @Test("A generation cancelled half way clears what it made here and keeps the pointer of the narration before it, which comes back")
    func cancellingKeepsThePointer() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        let made = try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()

        ArticleSpeechAudioCache.deleteCachedAudio(sourceID: "src-1", forgettingReplicaNarration: false)
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") == nil)
        try await Task.sleep(nanoseconds: 500_000_000)   // long enough for a pointer clear, if one were started
        #expect(try await rig.pointers()["src-1"] == made.hash, "the pointer stands")
        await rig.library.refresh(publishing: .awaiting)
        #expect(SyncedArticleAudioStore.publishedManifest(sourceID: "src-1") == made.manifest, "the earlier narration is laid down again")
    }

    // MARK: - Generation 1's narration in iCloud Drive

    /// A narration as generation 1 left it in iCloud Drive: `<folder>/manifest.json`, `Chunks/` and the text it read.
    /// `missing` leaves a chunk out, `misSized` writes one of another size than the manifest gives, and
    /// `writesManifest: false` is a generation that never finished.
    @discardableResult
    static func oldNarration(_ sourceID: String, in rig: Rig, folder: String? = nil, chunks: [String] = ["old first", "old second"],
                             skipping missing: Int? = nil, misSized: Int? = nil, writesManifest: Bool = true) throws -> (manifest: SyncedArticleAudioManifest, bytes: Data) {
        let directory = rig.iCloudDrive.appendingPathComponent(folder ?? sourceID, isDirectory: true)
        let chunkFolder = directory.appendingPathComponent(SyncedArticleAudioStore.chunksDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: chunkFolder, withIntermediateDirectories: true)
        let manifest = SyncedArticleAudioManifest(
            schemaVersion: SyncedArticleAudioManifest.schemaVersion, sourceID: sourceID, title: "Old \(sourceID)", subtitle: nil,
            sourceType: "article", sourceURL: "https://example.org/\(sourceID)", provider: "openrouter", model: model, voice: "jack",
            voiceLabel: "Jack", contentSignature: "old-signature", totalCharacters: 40, createdAt: created.addingTimeInterval(-40 * 86_400),
            chunks: chunks.enumerated().map { place, body in
                .init(index: place, fileName: SyncedArticleAudioStore.chunkFileName(index: place, fileExtension: "mp3"), byteCount: body.utf8.count, text: body)
            },
            sourceTextFileName: SyncedArticleAudioStore.sourceTextFileName, generatedOnPlatform: "macos"
        )
        for (place, body) in chunks.enumerated() where place != missing {
            let written = place == misSized ? body + " and more" : body
            try Data(written.utf8).write(to: chunkFolder.appendingPathComponent(manifest.chunks[place].fileName))
        }
        try Data("The text that was read.".utf8).write(to: directory.appendingPathComponent(SyncedArticleAudioStore.sourceTextFileName))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(manifest)
        if writesManifest { try bytes.write(to: directory.appendingPathComponent(SyncedArticleAudioStore.manifestFileName)) }
        return (manifest, bytes)
    }

    /// Every file under `folder`, by relative path, with its bytes: what the carry must never change.
    static func snapshot(_ folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let base = folder.resolvingSymlinksInPath().path
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) ?? NSEnumerator() {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return files
    }

    static func carryMarker(_ device: EngineTestDevice) throws -> String? {
        try device.store.replica.engineState(NarrationCarryOver.scope).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `Library` and `Catalog` have each had a complete fetch, which the carry waits for.
    static func fetchedWhole(_ device: EngineTestDevice) throws -> Bool {
        try device.count("SELECT COUNT(*) FROM ck_zones WHERE kind IN ('library', 'catalog') AND last_complete_pass_at IS NOT NULL") == 2
    }

    @Test("A whole narration in iCloud Drive is copied into the working folder, byte for byte, and sent like one this Mac just made; iCloud Drive is left as it was")
    func carriesAWholeNarration() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        #expect(try Self.fetchedWhole(rig.a))
        let old = try Self.oldNarration("src-1", in: rig)
        let before = try Self.snapshot(rig.iCloudDrive)

        await rig.library.roundSettled()

        let carried = try #require(SyncedArticleAudioStore.loadCompleteManifest(sourceID: "src-1"), "the narration plays from the working folder")
        #expect(carried == old.manifest)
        #expect(try Data(contentsOf: SyncedArticleAudioStore.manifestURL(sourceID: "src-1")) == old.bytes, "the manifest file is the same bytes")
        #expect(try Self.chunkText(carried, 0) == "old first")
        #expect(try Self.chunkText(carried, 1) == "old second")
        let text = SyncedArticleAudioStore.sourceDirectory(sourceID: "src-1").appendingPathComponent(SyncedArticleAudioStore.sourceTextFileName)
        #expect(try String(contentsOf: text, encoding: .utf8) == "The text that was read.")
        #expect(try Self.snapshot(rig.iCloudDrive) == before, "nothing in iCloud Drive was moved or changed")
        #expect(rig.changes.contains("a:src-1"), "the surfaces that show it were told")
        #expect(try Self.carryMarker(rig.a) == "done")
        let staging = rig.library.folder.root.appendingPathComponent(".carrying")
        #expect(FileManager.default.fileExists(atPath: staging.path) == false, "nothing is left half-assembled")

        // Queued as a narration made here: the pass that follows the carry sends it in the background.
        let hash = SyncIdentity.sha256Hex(old.bytes)
        #expect(try await Self.eventually { try await rig.pointers()["src-1"] == hash }, "the pointer is written once the bytes are up")
        try await rig.send()
        let file = try #require(try rig.serverNarrations()[NarrationSatellites.role(model: Self.model, voice: "jack")])
        #expect(file.hash == hash)
        #expect(file.children.map(\.key) == old.manifest.chunks.map(\.fileName))
        #expect(try M.onServer(rig.a, file), "the manifest and every chunk are on the server")
    }

    @Test("A narration that is not whole stays in iCloud Drive: a chunk missing, a chunk of another size, a generation with no manifest")
    func incompleteIsNotCarried() async throws {
        let rig = try await Rig(sources: ["src-1", "src-2", "src-3"])
        defer { rig.cleanUp() }
        try Self.oldNarration("src-1", in: rig, skipping: 1)
        try Self.oldNarration("src-2", in: rig, misSized: 0)
        try Self.oldNarration("src-3", in: rig, writesManifest: false)

        let outcome = try #require(await rig.library.carryFromICloudDrive())
        #expect(outcome.carried.isEmpty && outcome.failed.isEmpty)
        for id in ["src-1", "src-2", "src-3"] {
            #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.sourceDirectory(sourceID: id).path) == false, "\(id) has nothing in the working folder")
        }
        #expect(try Self.carryMarker(rig.a) == "done", "a narration that is not whole is not owed again")
    }

    @Test("A narration already in the working folder is never replaced; a folder holding only a saved position takes the narration beside it")
    func workingFolderNarrationStays() async throws {
        let rig = try await Rig(sources: ["src-1", "src-2"])
        defer { rig.cleanUp() }
        let mine = try Self.narrate("src-1", voice: "eve", chunks: ["mine"])
        try Self.oldNarration("src-1", in: rig)
        let position = SyncedArticleAudioStore.playbackPositionURL(sourceID: "src-2")
        try FileManager.default.createDirectory(at: position.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: position)
        let old = try Self.oldNarration("src-2", in: rig)

        let outcome = try #require(await rig.library.carryFromICloudDrive())
        #expect(outcome.carried == ["src-2"])
        #expect(try Data(contentsOf: SyncedArticleAudioStore.manifestURL(sourceID: "src-1")) == mine.bytes, "this Mac's own narration stands")
        #expect(try Self.chunkText(mine.manifest, 0) == "mine")
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.expectedChunkURLs(for: mine.manifest)[0]
            .deletingLastPathComponent().appendingPathComponent("chunk-0001.mp3").path) == false, "no old chunk joined it")
        #expect(SyncedArticleAudioStore.loadCompleteManifest(sourceID: "src-2") == old.manifest)
        #expect(try Data(contentsOf: position) == Data("{}".utf8), "the saved position stays")
    }

    @Test("A second run copies nothing: the carry is remembered by the store, and without the note a run skips what is already here")
    func secondRunIsANoOp() async throws {
        let rig = try await Rig(sources: ["src-1", "src-2"])
        defer { rig.cleanUp() }
        try Self.oldNarration("src-1", in: rig)
        #expect(await rig.library.carryFromICloudDrive()?.carried == ["src-1"])
        let manifest = SyncedArticleAudioStore.manifestURL(sourceID: "src-1")
        let stamp = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date

        try Self.oldNarration("src-2", in: rig)
        #expect(await rig.library.carryFromICloudDrive() == nil, "the same launch does not look again")
        rig.relaunch()
        #expect(await rig.library.carryFromICloudDrive() == nil, "nor does the next launch: the store remembers")
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.manifestURL(sourceID: "src-2").path) == false)

        // Without the note (a run cut short), the next one copies only what is not here yet.
        try await rig.a.local.perform { try $0.replica.setEngineState(NarrationCarryOver.scope, nil) }
        rig.relaunch()
        #expect(await rig.library.carryFromICloudDrive()?.carried == ["src-2"])
        #expect(try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date == stamp, "src-1 was not copied again")
    }

    @Test("Only a source the library holds and narrates nowhere takes one: not an id it does not hold, not a source the account already narrates")
    func sourceNotInLibraryIsSkipped() async throws {
        let rig = try await Rig(sources: ["src-1", "src-2"])
        defer { rig.cleanUp() }
        // src-2's narration is the account's already (made on another device, not laid down here).
        try Self.narrate("src-2", voice: "eve")
        await rig.library.refresh(only: "src-2", publishing: .awaiting)
        try FileManager.default.removeItem(at: SyncedArticleAudioStore.sourceDirectory(sourceID: "src-2"))
        try Self.oldNarration("ghost", in: rig)
        try Self.oldNarration("src-2", in: rig)
        try Self.oldNarration("src-1", in: rig)

        let outcome = try #require(await rig.library.carryFromICloudDrive())
        #expect(outcome.carried == ["src-1"])
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.sourceDirectory(sourceID: "ghost").path) == false)
        #expect(FileManager.default.fileExists(atPath: SyncedArticleAudioStore.manifestURL(sourceID: "src-2").path) == false)
    }

    @Test("The carry waits for the whole library and for generation 2: before a complete fetch, or with no working folder, nothing is copied or noted")
    func carryWaitsForTheLibrary() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.oldNarration("src-1", in: rig)
        try rig.a.exec("UPDATE ck_zones SET last_complete_pass_at = NULL WHERE kind = 'catalog'")
        #expect(await rig.library.carryFromICloudDrive() == nil)
        #expect(try Self.carryMarker(rig.a) == nil)

        try rig.a.exec("UPDATE ck_zones SET last_complete_pass_at = 1 WHERE kind = 'catalog'")
        MacNarrationLibrary.install(library: rig.library, generation: { .one })
        #expect(await rig.library.carryFromICloudDrive() == nil, "generation 1 has no working folder to carry into")
        let working = rig.library.folder.root.appendingPathComponent("Audio/src-1/manifest.json")
        #expect(FileManager.default.fileExists(atPath: working.path) == false)

        rig.use("a")
        #expect(await rig.library.carryFromICloudDrive()?.carried == ["src-1"])
    }

    @Test("A run that could not copy is owed again, at most three runs in all")
    func failedRunsAreCounted() {
        #expect(NarrationCarryOver.standing(nil) == .owed(failedRuns: 0))
        let failed = NarrationCarryOver.Outcome(carried: [], failed: ["src-1"])
        var runs = 0
        var marker = NarrationCarryOver.marker(after: failed, failedRuns: runs)
        #expect(marker.done == false && NarrationCarryOver.standing(marker.marker) == .owed(failedRuns: 1))
        runs = 1
        marker = NarrationCarryOver.marker(after: failed, failedRuns: runs)
        #expect(marker.done == false && NarrationCarryOver.standing(marker.marker) == .owed(failedRuns: 2))
        runs = 2
        marker = NarrationCarryOver.marker(after: failed, failedRuns: runs)
        #expect(marker.done && NarrationCarryOver.standing(marker.marker) == .done)
        #expect(NarrationCarryOver.marker(after: .init(carried: ["src-1"]), failedRuns: 1).done)
        #expect(NarrationCarryOver.areApart(URL(fileURLWithPath: "/a/b"), URL(fileURLWithPath: "/a/b/c")) == false)
        #expect(NarrationCarryOver.areApart(URL(fileURLWithPath: "/a/b"), URL(fileURLWithPath: "/a/bc")))
    }

    @Test("A library uploaded again sends the narrations its sources point at: the seed's satellites read the chunks and manifest from the working folder")
    func theSeedSendsANarrationsBytes() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        try Self.narrate()
        await rig.library.refresh(only: "src-1", publishing: .awaiting)
        try await rig.send()
        let file = try #require(try rig.serverNarrations().values.first)

        // The zone the pointer was written for is not the one the library went up into: none of its satellites
        // is there, and this Mac's ledger knows none of them.
        let ids = try M.names(rig.a, file).map { CloudRecordID($0, in: PrivateSyncZones.content) }
        _ = try await rig.a.transport.modifyRecords(deleting: ids, in: .private)
        try rig.a.exec("DELETE FROM ck_blobs")
        #expect(try M.onServer(rig.a, file) == false)

        let blobs = M.blobs(rig.a, clock: { rig.clock.now })
        let totals = try await CutoverSatellites(store: rig.a.local, blobs: blobs, pendingCount: { 0 }).upload()
        #expect(try M.onServer(rig.a, file), "the manifest and every chunk are back")
        #expect(totals.satellites >= 4)
    }

    // MARK: - Generation 1 and the audio store

    @Test("Under generation 1 nothing changes: the audio store keeps iCloud Drive, no folder is made, and nothing is asked of the replica")
    func generationOneLeavesItAlone() async throws {
        let rig = try await Rig()
        defer { rig.cleanUp() }
        MacNarrationLibrary.install(library: rig.library, generation: { .one })
        #expect(SyncedArticleAudioStore.workingFolder == nil)
        #expect(SyncedArticleAudioStore.audioRootURL() == SyncedArticleAudioStore.ubiquityAudioRootURL())
        #expect(SyncedArticleAudioStore.isUbiquitousAudioRootAvailable)
        await SyncedArticleAudioStore.bringReplicaNarration(sourceID: "src-1")
        let folder = await rig.library.folder
        #expect(FileManager.default.fileExists(atPath: folder.root.path) == false, "no working folder is made")

        MacNarrationLibrary.install(library: rig.library, generation: { .two })
        #expect(SyncedArticleAudioStore.audioRootURL() == folder.root.appendingPathComponent("Audio", isDirectory: true))
        #expect(SyncedArticleAudioStore.isUbiquitousAudioRootAvailable == false)
        #expect(SyncedArticleAudioStore.audioRootURL() != SyncedArticleAudioStore.ubiquityAudioRootURL(),
                "the activation still reads the iCloud Drive tree, not the working folder")
        #expect(SyncedArticleAudioStore.ubiquityPlaybackPositionURL(sourceID: "src-1").path.hasPrefix(SyncedArticleAudioStore.ubiquityAudioRootURL().path))
    }

    @Test("The names are the phone's: the voice key, the chunk role and the chunk types")
    func theNames() {
        #expect(NarrationSatellites.role(model: "x-ai/grok-tts", voice: "Rex") == "audio.x-ai-grok-tts.rex")
        #expect(NarrationSatellites.role(model: "openai/gpt-4o-mini-tts", voice: "") == "audio.openai-gpt-4o-mini-tts.default")
        #expect(NarrationSatellites.role(model: "  A  B ", voice: "--v--") == "audio.a-b.v")
        #expect(NarrationSatellites.chunkRole == "audioChunk")
        #expect(NarrationSatellites.chunkMime(fileName: "chunk-0000.mp3") == "audio/mpeg")
        #expect(NarrationSatellites.chunkMime(fileName: "chunk-0000.M4A") == "audio/mp4")
    }

    /// What the libraries told their surroundings: sources announced as changed, and pointer writes per device.
    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [String] = []
        private var writes: [String: Int] = [:]

        var announced: [String] { lock.withLock { changes } }
        func sent(_ device: String) -> Int { lock.withLock { writes[device] ?? 0 } }
        func noteChange(_ change: String) { lock.withLock { changes.append(change) } }
        func noteSent(_ device: String) { lock.withLock { writes[device, default: 0] += 1 } }
    }

    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [SyncedArticleAudioDownloadProgress] = []
        func add(_ progress: SyncedArticleAudioDownloadProgress) { lock.withLock { seen.append(progress) } }
        var last: SyncedArticleAudioDownloadProgress? { lock.withLock { seen.last } }
    }
}
