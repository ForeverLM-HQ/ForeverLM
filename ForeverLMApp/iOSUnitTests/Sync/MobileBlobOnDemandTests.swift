import Foundation
import Testing
@testable import ForeverLM

/// Satellites on the phone under generation 2 (docs/cloudkit-schema-design.md §2.3, §3.5.30, §8b,
/// §14.2 WP21): found where the phone holds their record, the learner's copy first; fetched by name
/// the first time something opens them and read from disk after; kept durable for a holder; a space's
/// files downloaded whole only after the learner's "Download all files", never the raw originals.
@Suite("iPhone satellites on demand", .serialized)
struct MobileBlobOnDemandTests {
    typealias F = MobileReadModelFixture

    /// A phone that adopted a seeded library and holds a space, a BlobStore over a transport that
    /// counts what is fetched, and satellites on disk in a scratch folder.
    struct Phone {
        let device: MobileTestDevice
        let recording: MobileRecordingTransport
        let blobs: BlobStore
        let satellites: MobileSatellites
        let personal: BlobZone
        let team: BlobZone
        let folder: URL

        init() async throws {
            let server = FakeCloudKit()
            try MobileSyncFixture.makeLibrary(server, owner: "u1")
            try MobileSyncFixture.makeSpace(server, owner: "u1", name: "Acme Lab")
            recording = MobileRecordingTransport(server.transport(user: "u1", device: "phone"))
            device = try MobileTestDevice(server, user: "u1", transport: recording)
            _ = try await device.bootstrap()
            try await MobileSyncFixture.holdSpace(device.replica, zoneKey: F.space, zoneName: "Space-s1", owned: true, name: "Acme Lab")
            var pacing = SyncPacerState.Configuration()
            pacing.capacity = 1_000_000
            pacing.refillPerSecond = 1_000_000
            let pacer = SyncPacer(configuration: pacing)
            blobs = BlobStore(transport: recording, store: device.replica, deviceID: device.deviceID, pacer: { _ in pacer })
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("MobileBlobOnDemand-\(UUID().uuidString)", isDirectory: true)
            satellites = MobileSatellites(projection: device.projection, blobs: blobs, disk: MobileSatelliteDisk(
                cacheRoot: folder.appendingPathComponent("Caches", isDirectory: true),
                durableRoot: folder.appendingPathComponent("Durable", isDirectory: true)
            ))
            let replica = device.replica
            personal = try #require(try await replica.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
            team = try #require(try await replica.perform { try BlobZone.resolve(zoneKey: F.space, in: $0) })
        }

        func upload(_ text: String, owner: String, role: String, mime: String = "application/pdf", into zone: BlobZone,
                    children: [FileRef] = []) async throws -> FileRef {
            let file = try await blobs.upload(Data(text.utf8), owner: owner, ownerType: .source, role: role, mime: mime, encoding: .identity, into: zone)
            guard !children.isEmpty, var object = file.value.objectValue else { return file }
            object["children"] = .array(children.map(\.value))
            return try #require(FileRef(json: .object(object)))
        }

        /// A child FileRef as a writer files it under its parent, with the key it stands for.
        func child(_ text: String, owner: String, role: String, key: String, mime: String, into zone: BlobZone) async throws -> FileRef {
            let file = try await blobs.upload(Data(text.utf8), owner: owner, ownerType: .source, role: role, mime: mime, encoding: .identity, into: zone)
            var object = try #require(file.value.objectValue)
            object["key"] = .string(key)
            return try #require(FileRef(json: .object(object)))
        }

        /// Satellite parts fetched since the last call (`Content` record names asked for with their bytes).
        func fetches() -> Int { recording.recordFetchKeys.filter { $0?.contains(CloudRecord.dataKey) == true }.count }

        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    @Test("A source's PDF is fetched by name the first time it opens, then read from disk; two opens at once share one fetch")
    func fetchedOnceThenFromDisk() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let pdf = try await phone.upload("%PDF-1.4 mitochondria", owner: "src-1", role: "pdf", into: phone.personal)
        try await MobileSyncFixture.apply([(F.catalog, try F.source("src-1", "Fission", added: 1, ["files": .object(["pdf": pdf.value])]))],
                                          to: phone.device.replica)
        let satellite = try #require(try await phone.satellites.source("src-1") { $0 == "pdf" })
        #expect(satellite.zone == phone.personal, "a Catalog source's satellites live in Content")
        #expect(await phone.satellites.localURL(satellite) == nil, "nothing is on the phone before it is opened")

        async let first = phone.satellites.url(satellite)
        async let second = phone.satellites.url(satellite)
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(String(decoding: try Data(contentsOf: a), as: UTF8.self) == "%PDF-1.4 mitochondria")
        #expect(a.pathExtension == "pdf", "PDFKit reads it by its type")
        #expect(phone.fetches() == 1, "two screens opening it at once share one fetch")

        _ = try await phone.satellites.url(satellite)
        #expect(phone.fetches() == 1, "a second open reads the disk and asks the server nothing")
        #expect(try await phone.satellites.source("src-1") { $0 == "epub" } == nil, "a role the source does not name is no satellite")
    }

    @Test("The learner's own copy is read before a space's, and a source only a space holds reads from the space's zone")
    func ownCopyFirst() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let mine = try await phone.upload("mine", owner: "src-shared", role: "thumbnail", mime: "image/jpeg", into: phone.personal)
        let theirs = try await phone.upload("theirs", owner: "src-shared", role: "thumbnail", mime: "image/jpeg", into: phone.team)
        let teamOnly = try await phone.upload("team only", owner: "src-team", role: "thumbnail", mime: "image/jpeg", into: phone.team)
        let space = MobileSyncFixture.spaceSalt
        try await MobileSyncFixture.apply([
            (F.catalog, try F.source("src-shared", "Held twice", added: 1, ["files": .object(["thumbnail": mine.value])])),
            (F.space, try MobileSyncFixture.envelope(.source, "src-shared", ["title": .string("Held twice"), "status": .string("active"),
                                                                              "files": .object(["thumbnail": theirs.value])], salt: space)),
            (F.space, try MobileSyncFixture.envelope(.source, "src-team", ["title": .string("Team only"), "status": .string("active"),
                                                                            "files": .object(["thumbnail": teamOnly.value])], salt: space)),
        ], to: phone.device.replica)

        let shared = try #require(try await phone.satellites.source("src-shared") { $0 == "thumbnail" })
        #expect(String(decoding: try await phone.satellites.data(shared), as: UTF8.self) == "mine")
        let team = try #require(try await phone.satellites.source("src-team") { $0 == "thumbnail" })
        #expect(team.zone == phone.team)
        #expect(String(decoding: try await phone.satellites.data(team), as: UTF8.self) == "team only")
        #expect(MobileSatellites.satelliteZoneKey(forOwnerIn: F.library) == "private/Content")
        #expect(MobileSatellites.satelliteZoneKey(forOwnerIn: F.space) == F.space)
        #expect(MobileSatellites.satelliteZoneKey(forOwnerIn: F.space, personal: true) == "private/Content", "a personal satellite never lives in a space")
    }

    @Test("A kept satellite outlives the purgeable cache, and taking its holder off removes exactly its copy")
    func keptForAHolder() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let pdf = try await phone.upload("%PDF kept", owner: "src-1", role: "pdf", into: phone.personal)
        try await MobileSyncFixture.apply([(F.catalog, try F.source("src-1", "Fission", added: 1, ["files": .object(["pdf": pdf.value])]))],
                                          to: phone.device.replica)
        let satellite = try #require(try await phone.satellites.source("src-1") { $0 == "pdf" })
        let holder = MobileSatelliteHolder.source("src-1")
        try await phone.satellites.keep(satellite, for: holder)
        #expect(await phone.satellites.byteCount(holder: holder) == Int64("%PDF kept".utf8.count))

        try FileManager.default.removeItem(at: phone.satellites.disk.cacheRoot)
        let kept = try #require(await phone.satellites.localURL(satellite), "iOS purging Caches leaves the kept copy")
        #expect(kept.path.hasPrefix(phone.satellites.disk.durableRoot.path))
        _ = try await phone.satellites.url(satellite)
        #expect(phone.fetches() == 1, "a kept satellite is never fetched again")

        await phone.satellites.release(holder: holder)
        #expect(await phone.satellites.localURL(satellite) == nil)
        #expect(await phone.satellites.byteCount(holder: holder) == 0)
    }

    @Test("A narration's chunks and a walk's pictures are found under their parent by the key their writer gave them")
    func childrenByKey() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let chunk0 = try await phone.child("chunk zero", owner: "src-1", role: "audioChunk", key: "chunk-000.m4a", mime: "audio/mp4", into: phone.personal)
        let chunk1 = try await phone.child("chunk one", owner: "src-1", role: "audioChunk", key: "chunk-001.m4a", mime: "audio/mp4", into: phone.personal)
        let manifest = try await phone.upload("{}", owner: "src-1", role: "audio.alloy", mime: "application/json", into: phone.personal, children: [chunk0, chunk1])
        let picture = try await phone.child("png", owner: "src-1", role: "walkthroughPicture", key: "IMG-7", mime: "image/png", into: phone.personal)
        let walk = try await phone.upload("{\"steps\":[]}", owner: "src-1", role: "walkthrough", mime: "application/json", into: phone.personal, children: [picture])
        try await MobileSyncFixture.apply([(F.catalog, try F.source("src-1", "Fission", added: 1, [
            "files": .object(["audio.alloy": manifest.value]), "derived": .object(["walkthrough": walk.value]),
        ]))], to: phone.device.replica)

        let narration = try #require(try await phone.satellites.source("src-1") { $0.hasPrefix("audio.") })
        #expect(narration.children(role: "audioChunk").map(\.file.key) == ["chunk-000.m4a", "chunk-001.m4a"], "in the order the FileRef lists them")
        let second = try #require(narration.child(role: "audioChunk", key: "chunk-001.m4a"))
        #expect(String(decoding: try await phone.satellites.data(second), as: UTF8.self) == "chunk one")
        let walkthrough = try #require(try await phone.satellites.source("src-1", in: "derived") { $0 == "walkthrough" })
        let drawn = try #require(walkthrough.child(role: "walkthroughPicture", key: "img-7"), "an image id matches without case")
        #expect(String(decoding: try await phone.satellites.data(drawn), as: UTF8.self) == "png")
        #expect(walkthrough.child(role: "walkthroughPicture", key: "img-8") == nil)
    }

    @Test("Download all files keeps a space's files and their children, never its raw originals; a quiet space is not walked again; a space that went gives its files back")
    func downloadAllFiles() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let pdf = try await phone.upload("%PDF team", owner: "src-team", role: "pdf", into: phone.team)
        let raw = try await phone.upload("<tt>raw</tt>", owner: "src-team", role: "raw", mime: "application/ttml+xml", into: phone.team)
        let chunk = try await phone.child("chunk", owner: "src-team", role: "audioChunk", key: "chunk-000.m4a", mime: "audio/mp4", into: phone.team)
        let manifest = try await phone.upload("{}", owner: "src-team", role: "audio.alloy", mime: "application/json", into: phone.team, children: [chunk])
        let questions = try await phone.upload("[]", owner: "qz-1", role: "questions", mime: "application/json", into: phone.team)
        let mine = try await phone.upload("%PDF mine", owner: "src-mine", role: "pdf", into: phone.personal)
        let space = MobileSyncFixture.spaceSalt
        try await MobileSyncFixture.apply([
            (F.space, try MobileSyncFixture.envelope(.source, "src-team", ["title": .string("Team only"), "status": .string("active"), "files": .object([
                "pdf": pdf.value, "raw": raw.value, "audio.alloy": manifest.value,
            ])], salt: space)),
            (F.space, try MobileSyncFixture.envelope(.quiz, "qz-1", ["courseID": .string("crs-1"), "title": .string("Quiz"), "questions": questions.value],
                                                     salt: space)),
            (F.catalog, try F.source("src-mine", "Mine", added: 1, ["files": .object(["pdf": mine.value])])),
        ], to: phone.device.replica)

        let size = try await phone.satellites.spaceSize(zoneKey: F.space)
        #expect(size.total == Int64("%PDF team".utf8.count + "chunk".utf8.count + "{}".utf8.count + "[]".utf8.count), "the raw original is not counted")
        #expect(size.kept == 0)

        #expect(await phone.satellites.downloadSpaces([F.space]) == 4)
        let holder = MobileSatelliteHolder.space(F.space)
        #expect(await phone.satellites.byteCount(holder: holder) == size.total)
        let rawSatellite = try #require(try await phone.satellites.source("src-team") { $0 == "raw" })
        #expect(await phone.satellites.localURL(rawSatellite) == nil, "a raw original is fetched only when opened")
        let personalPDF = try #require(try await phone.satellites.source("src-mine") { $0 == "pdf" })
        #expect(await phone.satellites.localURL(personalPDF) == nil, "only the space's own files")

        let before = phone.recording.recordFetchKeys.count
        #expect(await phone.satellites.downloadSpaces([F.space]) == 0)
        #expect(phone.recording.recordFetchKeys.count == before, "a space whose records did not move is not walked again")

        try await phone.device.replica.perform { try $0.replica.setEngineState(SpaceSync.StateScope.gonePrefix + F.space, Data("{}".utf8)) }
        #expect(await phone.satellites.downloadSpaces([F.space]) == 0)
        #expect(await phone.satellites.byteCount(holder: holder) == 0, "a space that went takes its downloaded files with it")
    }

    @Test("The phone remembers which spaces it downloads, per environment and on this device only")
    func downloadChoice() throws {
        let defaults = try #require(UserDefaults(suiteName: "MobileBlobOnDemandTests-\(UUID().uuidString)"))
        let development = MobileSpaceDownloads(defaults: defaults, environment: .development)
        development.set(F.space, downloaded: true)
        #expect(development.contains(F.space))
        #expect(!MobileSpaceDownloads(defaults: defaults, environment: .production).contains(F.space))
        development.set(F.space, downloaded: false)
        #expect(development.zoneKeys.isEmpty)
    }

    @Test("Settings names each space by its root, else by its kind, and shows what downloading it takes, then how much of it is here")
    @MainActor
    func downloadChoiceRows() {
        func space(_ name: String?, kind: String?) -> MobileProjection.Space {
            MobileProjection.Space(zoneKey: F.space, zoneName: "Space-s1", isOwned: false, kind: kind, name: name, ownerName: nil,
                                   permission: "readOnly", primaryID: nil)
        }
        #expect(MobileOfflineChoicesModel.name(of: space("Acme Lab", kind: "team")) == "Acme Lab")
        #expect(MobileOfflineChoicesModel.name(of: space("  ", kind: "family")) == "Family")
        #expect(MobileOfflineChoicesModel.name(of: space(nil, kind: "notebook")) == "Shared notebook")
        #expect(MobileOfflineChoicesModel.name(of: space(nil, kind: nil)) == "Team", "a space whose root has not arrived")

        var row = MobileOfflineChoicesModel.SpaceRow(id: F.space, name: "Acme Lab", isDownloaded: false)
        #expect(row.sizeLine == nil, "not measured yet")
        row.total = 2_000_000
        #expect(row.sizeLine == MobileOfflineByteFormat.string(2_000_000))
        row.isDownloaded = true
        row.kept = 500_000
        #expect(row.sizeLine == "\(MobileOfflineByteFormat.string(500_000)) of \(MobileOfflineByteFormat.string(2_000_000))")
        row.kept = 2_000_000
        #expect(row.sizeLine == MobileOfflineByteFormat.string(2_000_000), "a space downloaded whole shows its size")
    }

    // MARK: - What the readers read

    @Test("A Doc's body is its package satellite, checked against the revision its FileRef names; plain Markdown reads as it is")
    func docBody() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let package = try ArtifactBodyPackage.encode(markdown: "# Fission\n\nMitochondria divide.", attachmentDirectory: nil)
        let body = try await phone.blobs.upload(package.data, owner: "art-1", ownerType: .artifact, role: "body", mime: "application/octet-stream",
                                                encoding: .gzip, into: phone.personal)
        #expect(body.hash == package.revision, "the body's hash is its revision")
        let plain = try await phone.blobs.upload(Data("Team notes".utf8), owner: "art-2", ownerType: .artifact, role: "body", mime: "text/markdown",
                                                 encoding: .gzip, into: phone.team)
        try await MobileSyncFixture.apply([
            (F.library, try MobileSyncFixture.envelope(.artifact, "art-1", ["title": .string("Fission"), "status": .string("active"), "body": body.value])),
            (F.space, try MobileSyncFixture.envelope(.artifact, "art-2", ["title": .string("Notes"), "status": .string("active"), "body": plain.value],
                                                     salt: MobileSyncFixture.spaceSalt)),
            (F.library, try MobileSyncFixture.envelope(.artifact, "art-3", ["title": .string("Empty"), "status": .string("active")])),
        ], to: phone.device.replica)

        let doc = try await MobileNotebookDocStore.satelliteBody(Self.artifact("art-1"), satellites: phone.satellites)
        #expect(doc.markdown == "# Fission\n\nMitochondria divide.")
        #expect(doc.revision == package.revision)
        #expect(try await MobileNotebookDocStore.satelliteBody(Self.artifact("art-2"), satellites: phone.satellites).markdown == "Team notes")
        await #expect(throws: MobileNotebookDocStore.DocError.noBody) {
            try await MobileNotebookDocStore.satelliteBody(Self.artifact("art-3"), satellites: phone.satellites)
        }
        await #expect(throws: MobileNotebookDocStore.DocError.noTextCopy) {
            try await MobileNotebookDocStore.satelliteBody(Self.artifact("art-3", linkedURL: "https://docs.google.com/document/d/x"), satellites: phone.satellites)
        }
    }

    @Test("A walk's animation reads its Artifact as the phone holds it: the body satellite's bytes with their hash as the revision, and its linked page")
    func animationBody() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let bytes = Data("animation package".utf8)
        let body = try await phone.blobs.upload(bytes, owner: "anim-1", ownerType: .artifact, role: "body", mime: "application/octet-stream",
                                                encoding: .gzip, into: phone.personal)
        try await MobileSyncFixture.apply([
            (F.library, try MobileSyncFixture.envelope(.artifact, "anim-1", ["kind": .string("animation"), "title": .string("Fission"),
                                                                             "status": .string("active"), "body": body.value,
                                                                             "linkedURL": .string("foreverlm-site://anim-1/")])),
            (F.library, try MobileSyncFixture.envelope(.artifact, "anim-2", ["kind": .string("animation"), "title": .string("Hosted"),
                                                                             "status": .string("active"),
                                                                             "linkedURL": .string("https://sites.foreverlm.com/s/x/")])),
        ], to: phone.device.replica)

        let held = try #require(try await phone.satellites.artifactBody("anim-1"))
        #expect(held.linkedURL == "foreverlm-site://anim-1/")
        #expect(held.bodyRevision == body.hash)
        #expect(held.package == bytes)
        let hosted = try #require(try await phone.satellites.artifactBody("anim-2"))
        #expect(hosted.linkedURL == "https://sites.foreverlm.com/s/x/")
        #expect(hosted.bodyRevision == nil && hosted.package == nil)
        #expect(try await phone.satellites.artifactBody("anim-missing") == nil)
    }

    static func artifact(_ id: String, linkedURL: String? = nil) -> MobileCloudArtifact {
        MobileCloudArtifact(id: id, title: id, kind: nil, homeNotebookID: nil, linkedNotebookIDs: [], sourceIDs: [], linkedURL: linkedURL,
                            isDraft: false, teamID: nil, createdAt: nil, updatedAt: Date(timeIntervalSince1970: 0), bodyRevision: nil)
    }

    @Test("A course's quizzes come from their Quiz records and questions satellites, covering lessons in course order; one whose questions are not on the server is left out")
    func courseQuizzes() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let question = CourseQuizQuestion(id: "q1", sourceID: "src-1", firstLine: 1, lastLine: 4, question: "Why do mitochondria divide?",
                                          answer: "To share load.", keyPoints: ["load"], quote: nil)
        let json = try JSONEncoder().encode([question])
        let questions = try await phone.blobs.upload(json, owner: "qz-1", ownerType: .quiz, role: "questions", mime: "application/json",
                                                     encoding: .gzip, into: phone.personal)
        let artwork = try await phone.blobs.upload(Data("jpeg".utf8), owner: "qz-1", ownerType: .quiz, role: "picture.artwork", mime: "image/jpeg",
                                                   encoding: .identity, into: phone.personal)
        let lost = MobileSyncFixture.fileRef(owner: "qz-2", role: "questions", bytes: Data("[]".utf8))
        try await MobileSyncFixture.apply([
            (F.library, try MobileSyncFixture.envelope(.quiz, "qz-1", [
                "courseID": .string("crs-1"), "kind": .string("checkpoint"), "title": .string("Fission and fusion"), "lessonID": .string("les-2"),
                "coversLessonIDs": F.set(["les-2", "les-1"]), "author": .string("learner"), "createdAt": SyncJSON(Int64(1_700_000_000_000)),
                "questions": questions.value, "pictures": .object(["artwork": artwork.value]), "symbol": .string("atom"),
            ])),
            (F.library, try MobileSyncFixture.envelope(.quiz, "qz-2", [
                "courseID": .string("crs-1"), "kind": .string("practice"), "title": .string("Lost"), "questions": lost.value,
            ])),
        ], to: phone.device.replica)

        let quizzes = await MobileCourseQuizzes.load(courseID: "crs-1", lessonOrder: ["les-1", "les-2"], satellites: phone.satellites)
        #expect(quizzes.map(\.id) == ["qz-1"])
        let quiz = try #require(quizzes.first)
        #expect(quiz.kind == .checkpoint)
        #expect(quiz.lectureIDs == ["les-1", "les-2"], "the lessons it covers, in the course's order")
        #expect(quiz.afterLectureID == "les-2")
        #expect(quiz.questions == [question])
        #expect(quiz.author == .assistant, "the schema's learner is the Mac's assistant author")
        #expect(quiz.artwork == Data("jpeg".utf8))
        #expect(quiz.symbol == "atom")
        #expect(quiz.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(await MobileCourseQuizzes.load(courseID: "crs-2", lessonOrder: [], satellites: phone.satellites).isEmpty)
    }

    @Test("Listen text is read only while it was made from the source's text as it is now, by this build's generator")
    func listenText() throws {
        let canonical = "  Mitochondria divide by fission.\n"
        let input = SyncIdentity.sha256Hex(Data(canonical.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        func file(_ gen: [String: SyncJSON]) throws -> FileRef {
            var object = try #require(MobileSyncFixture.fileRef(owner: "src-1", role: "listenText", bytes: Data("x".utf8)).value.objectValue)
            object["gen"] = .object(gen)
            return try #require(FileRef(json: .object(object)))
        }
        let prepared = try file(["input": .string(input), "prompt": .string("paper-narration-v5:abc"), "at": SyncJSON(Int64(1_700_000_000_000))])
        let content = try #require(MobileListenText.content(narration: "Mitochondria divide.", file: prepared, canonicalText: canonical))
        #expect(content.text == "Mitochondria divide.")
        #expect(content.metadata.sourceSHA256 == input)
        #expect(content.metadata.preparationSignature == "paper-narration-v5:abc")
        #expect(content.metadata.characterCount == "Mitochondria divide.".count)
        #expect(content.metadata.preparedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(MobileListenText.content(narration: "Mitochondria divide.", file: prepared, canonicalText: "Revised text.") == nil,
                "made from older text")
        #expect(MobileListenText.content(narration: "x", file: try file(["input": .string(input), "version": SyncJSON(99)]), canonicalText: canonical) == nil,
                "another generator's output")
        #expect(MobileListenText.content(narration: "x", file: try file([:]), canonicalText: canonical) == nil, "no record of what it was made from")
        #expect(MobileListenText.content(narration: "  ", file: prepared, canonicalText: canonical) == nil)
    }

    @Test("A narration's chunks are its manifest's, matched by file name, else by place when the writer keyed none")
    func narrationChunks() throws {
        let zone = BlobZone.personal(salt: MobileSyncFixture.librarySalt)
        func chunk(_ text: String, key: String?) throws -> FileRef {
            var object = try #require(MobileSyncFixture.fileRef(owner: "src-1", role: "audioChunk", bytes: Data(text.utf8)).value.objectValue)
            if let key { object["key"] = .string(key) }
            return try #require(FileRef(json: .object(object)))
        }
        func narration(_ children: [FileRef]) throws -> MobileSatellite {
            var object = try #require(MobileSyncFixture.fileRef(owner: "src-1", role: "audio.alloy", bytes: Data("{}".utf8)).value.objectValue)
            object["children"] = .array(children.map(\.value))
            return MobileSatellite(file: try #require(FileRef(json: .object(object))), zone: zone)
        }
        let manifest = SyncedArticleAudioManifest(
            schemaVersion: 1, sourceID: "src-1", title: "Fission", subtitle: nil, sourceType: "paper", sourceURL: "", provider: "openai", model: "m",
            voice: "alloy", voiceLabel: "Alloy", contentSignature: "sig", totalCharacters: 2, createdAt: Date(timeIntervalSince1970: 0), chunks: [
                .init(index: 0, fileName: "chunk-000.m4a", byteCount: 1), .init(index: 1, fileName: "chunk-001.m4a", byteCount: 1),
            ], sourceTextFileName: nil
        )
        let keyed = try narration([try chunk("b", key: "chunk-001.m4a"), try chunk("a", key: "chunk-000.m4a")])
        #expect(MobileNarrationChunks.satellites(of: keyed, manifest: manifest).map { $0?.file.key } == ["chunk-000.m4a", "chunk-001.m4a"])
        let placed = try narration([try chunk("a", key: nil), try chunk("b", key: nil)])
        #expect(MobileNarrationChunks.satellites(of: placed, manifest: manifest).map { $0?.file.parts } == [
            [FileRef.partHash32(Data("a".utf8))], [FileRef.partHash32(Data("b".utf8))],
        ])
        let short = try narration([try chunk("a", key: "chunk-000.m4a")])
        #expect(MobileNarrationChunks.satellites(of: short, manifest: manifest).map { $0 == nil } == [false, true], "a chunk the FileRef lists none for")
    }

    @Test("A file the Mac keeps to itself, or one still arriving, says so to the reader")
    func readerErrors() async throws {
        let phone = try await Phone()
        defer { phone.cleanUp() }
        let kept = FileRef(owner: "src-1", role: "pdf", hash: String(repeating: "a", count: 64), size: 3, mime: "application/pdf", encoding: "identity",
                           storedParts: [Data("pdf".utf8)], heldBy: "macaaaaa")
        let missing = MobileSyncFixture.fileRef(owner: "src-2", role: "pdf", bytes: Data("never uploaded".utf8))
        try await MobileSyncFixture.apply([
            (F.catalog, try F.source("src-1", "Kept", added: 1, ["files": .object(["pdf": kept.value])])),
            (F.catalog, try F.source("src-2", "Arriving", added: 1, ["files": .object(["pdf": missing.value])])),
        ], to: phone.device.replica)
        for (id, expected) in [("src-1", MobileSourceFileError.keptOnMac), ("src-2", .arriving)] {
            let satellite = try #require(try await phone.satellites.source(id) { $0 == "pdf" })
            do {
                _ = try await phone.satellites.url(satellite)
                Issue.record("\(id) has no bytes to read")
            } catch let error as BlobStoreError {
                #expect(MobileSourceFileError(error) == expected)
            }
        }
    }
}
