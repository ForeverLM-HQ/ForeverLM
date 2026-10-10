import Foundation
import Testing
import UIKit
@testable import ForeverLM

/// A notebook's AI-drawn cover on the iPhone (docs/cloudkit-schema-design.md D53, §3.5.6 `files`, §5.9,
/// §14.2 WP31b): the phone shows `Notebook.files.cover` where it drew the title's emoji, bare as the Mac
/// draws it (`NotebookCoverCutout`), the emoji while the cover is missing or still arriving, and asks a Mac for
/// a cover (`Job(makeDerived, nb:<id>, {derived: "cover"})`) when the learner makes a notebook here, none in
/// Free mode or with the Setting off. It draws nothing itself, and never runs the backfill or writes its marker.
@Suite("iPhone notebook covers", .serialized)
struct MobileNotebookCoverTests {
    typealias F = MobileReadModelFixture
    typealias Fixture = MobileWriterFixture

    static let automaticKey = "images.drawNotebookCovers.automatic"
    static let freeModeKey = "aiFreeMode.enabled"
    static let markerKey = "images.notebookCoverBackfill.Library"

    /// A small solid-colour JPEG, as a Mac stores a cover (square, JPEG).
    static func jpeg(_ color: UIColor, side: CGFloat = 64) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).jpegData(withCompressionQuality: 0.8) { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    static let cream = UIColor(red: 250 / 255, green: 246 / 255, blue: 235 / 255, alpha: 1)
    static let navy = UIColor(red: 20 / 255, green: 50 / 255, blue: 110 / 255, alpha: 1)

    /// A 256-pixel JPEG cover as a model draws one: a disc of `radius` off the middle of a flat `ground`.
    static func jpeg(ground: UIColor, disc: UIColor, radius: CGFloat = 40) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).jpegData(withCompressionQuality: 0.9) { context in
            ground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            disc.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 100 - radius, y: 140 - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// The alpha of one pixel of `image`, from its top-left.
    static func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels[(y * image.width + x) * 4 + 3]
    }

    static func upload(_ phone: MobileBlobOnDemandTests.Phone, _ data: Data, owner: String, into zone: BlobZone) async throws -> FileRef {
        try await phone.blobs.upload(data, owner: owner, ownerType: .notebook, role: "cover", mime: "image/jpeg", encoding: .identity, into: zone)
    }

    static func setting(_ key: String, _ value: Bool) throws -> (String, SyncEnvelope) {
        (Fixture.library, try MobileSyncFixture.envelope(.setting, key, ["key": .string(key), "value": .object(["t": "bool", "v": .bool(value)])]))
    }

    // MARK: - Showing the cover

    @Test("A notebook whose record names a cover shows it, fetched by name once and then kept by its hash; the emoji shows while it is missing")
    @MainActor
    func theCoverShowsInPlaceOfTheEmoji() async throws {
        let phone = try await MobileBlobOnDemandTests.Phone()
        defer { phone.cleanUp() }
        let teal = Self.jpeg(.systemTeal)
        let cover = try await Self.upload(phone, teal, owner: "nb-cells", into: phone.personal)
        try await MobileSyncFixture.apply([
            (F.library, try F.notebook("nb-cells", "🧬 Cells", edited: 5, ["files": .object(["cover": cover.value])])),
            (F.library, try F.notebook("nb-bare", "Membranes", edited: 4)),
        ], to: phone.device.replica)

        let covers = MobileNotebookCoverImages()
        let picture = try #require(await covers.picture(forNotebook: "nb-cells", satellites: phone.satellites))
        #expect(picture.image.size.width > 0)
        #expect(try await phone.satellites.notebookCover("nb-cells")?.zone == phone.personal, "a personal notebook's cover lives in Content")
        #expect(phone.fetches() == 1)

        _ = try #require(await covers.picture(forNotebook: "nb-cells", satellites: phone.satellites))
        #expect(phone.fetches() == 1, "the picture is kept by the hash of its bytes: nothing is fetched again")
        let other = MobileNotebookCoverImages()
        _ = try #require(await other.picture(forNotebook: "nb-cells", satellites: phone.satellites))
        #expect(phone.fetches() == 1, "and a fresh cache reads the file the phone kept")

        #expect(await covers.picture(forNotebook: "nb-bare", satellites: phone.satellites) == nil, "no cover: the emoji shows")
        #expect(try await phone.satellites.notebookCover("nb-bare") == nil)
        #expect(await covers.picture(forNotebook: "missing", satellites: phone.satellites) == nil, "a notebook the phone does not hold has none")
    }

    @Test("A cover whose bytes are not on iCloud yet shows the emoji, and shows once they are")
    @MainActor
    func aCoverStillArrivingShowsTheEmoji() async throws {
        let phone = try await MobileBlobOnDemandTests.Phone()
        defer { phone.cleanUp() }
        let data = Self.jpeg(.systemOrange)
        let real = try await Self.upload(phone, data, owner: "nb-late", into: phone.personal)
        // A pointer whose parts the server does not hold (another device is still uploading them).
        var object = try #require(real.value.objectValue)
        object["parts"] = .array([.string(String(repeating: "0", count: 32))])
        object["hash"] = .string(String(repeating: "f", count: 64))
        let early = try #require(FileRef(json: .object(object)))
        try await MobileSyncFixture.apply([(F.library, try F.notebook("nb-late", "Sleep", edited: 3, ["files": .object(["cover": early.value])]))],
                                          to: phone.device.replica)
        let covers = MobileNotebookCoverImages()
        #expect(await covers.picture(forNotebook: "nb-late", satellites: phone.satellites) == nil, "the emoji stays while the bytes are not there")

        try await MobileSyncFixture.apply([(F.library, try MobileSyncFixture.envelope(
            .notebook, "nb-late", ["title": .string("Sleep"), "status": .string("active"), "files": .object(["cover": real.value])],
            at: MobileSyncFixture.stampMilliseconds + 60_000
        ))], to: phone.device.replica)
        #expect(await covers.picture(forNotebook: "nb-late", satellites: phone.satellites) != nil, "the picture takes its place once they are")
    }

    @Test("A cover on a flat ground is drawn bare, cut as the Mac cuts it: the ground taken away, the subject cropped square, once for its hash")
    @MainActor
    func aCoverIsDrawnBare() async throws {
        let phone = try await MobileBlobOnDemandTests.Phone()
        defer { phone.cleanUp() }
        let icon = try await Self.upload(phone, Self.jpeg(ground: Self.cream, disc: Self.navy), owner: "nb-icon", into: phone.personal)
        let flat = try await Self.upload(phone, Self.jpeg(.systemTeal), owner: "nb-flat", into: phone.personal)
        try await MobileSyncFixture.apply([
            (F.library, try F.notebook("nb-icon", "🧬 Cells", edited: 5, ["files": .object(["cover": icon.value])])),
            (F.library, try F.notebook("nb-flat", "Membranes", edited: 4, ["files": .object(["cover": flat.value])])),
        ], to: phone.device.replica)

        let covers = MobileNotebookCoverImages()
        let bare = try #require(await covers.picture(forNotebook: "nb-icon", satellites: phone.satellites))
        #expect(bare.isBare, "the cream ground is taken away")
        let cut = try #require(bare.image.cgImage)
        #expect(cut.width == cut.height, "square, so every place draws it the same way")
        #expect((80...100).contains(cut.width), "the disc's 81 pixels and a little room, not the 256 it was drawn in (\(cut.width))")
        #expect(Self.alpha(cut, x: 0, y: 0) == 0 && Self.alpha(cut, x: cut.width - 1, y: cut.height - 1) == 0, "the corners are ground")
        #expect(Self.alpha(cut, x: cut.width / 2, y: cut.height / 2) == 255, "the subject is opaque")
        #expect(await covers.picture(forNotebook: "nb-icon", satellites: phone.satellites) === bare, "cut once: kept by the hash of its bytes")

        let made = try #require(await covers.picture(forNotebook: "nb-flat", satellites: phone.satellites))
        #expect(!made.isBare, "a picture that is all ground has no subject to cut out, so it is drawn as made")
        #expect(MobileNotebookCoverPicture.make(from: Data("not a picture".utf8)) == nil)
    }

    @Test("The learner's own copy of a notebook is read before a space's, and a space's notebook reads from the space's zone")
    func ownCopyFirstAndSpaceZone() async throws {
        let phone = try await MobileBlobOnDemandTests.Phone()
        defer { phone.cleanUp() }
        let mine = try await Self.upload(phone, Self.jpeg(.systemRed), owner: "nb-both", into: phone.personal)
        let theirs = try await Self.upload(phone, Self.jpeg(.systemBlue), owner: "nb-both", into: phone.team)
        let teamOnly = try await Self.upload(phone, Self.jpeg(.systemGreen), owner: "nb-team", into: phone.team)
        let space = MobileSyncFixture.spaceSalt
        try await MobileSyncFixture.apply([
            (F.library, try F.notebook("nb-both", "Held twice", edited: 2, ["files": .object(["cover": mine.value])])),
            (F.space, try MobileSyncFixture.envelope(.notebook, "nb-both", ["title": .string("Held twice"), "status": .string("active"),
                                                                             "files": .object(["cover": theirs.value])], salt: space)),
            (F.space, try MobileSyncFixture.envelope(.notebook, "nb-team", ["title": .string("Team only"), "status": .string("active"),
                                                                             "files": .object(["cover": teamOnly.value])], salt: space)),
        ], to: phone.device.replica)

        let both = try #require(try await phone.satellites.notebookCover("nb-both"))
        #expect(both.file.hash == mine.hash, "the learner's own copy first")
        let team = try #require(try await phone.satellites.notebookCover("nb-team"))
        #expect(team.zone == phone.team, "a space's notebook keeps its cover in the space's zone")
        #expect(team.file.hash == teamOnly.hash)
    }

    @Test("Only a notebook the index says has a cover is decoded: a list of notebooks costs one query each")
    func theIndexSaysWhichHaveACover() async throws {
        let phone = try await MobileBlobOnDemandTests.Phone()
        defer { phone.cleanUp() }
        let cover = try await Self.upload(phone, Self.jpeg(.systemPurple), owner: "nb-1", into: phone.personal)
        try await MobileSyncFixture.apply([
            (F.library, try F.notebook("nb-1", "With", edited: 2, ["files": .object(["cover": cover.value])])),
            (F.library, try F.notebook("nb-2", "Without", edited: 1)),
        ], to: phone.device.replica)
        let held = try await phone.device.replica.read { replica -> [String] in
            var ids: [String] = []
            try replica.connection.query("SELECT id FROM m_notebooks WHERE has_cover = 1 ORDER BY id", []) { ids.append($0.text(0) ?? "") }
            return ids
        }
        #expect(held == ["nb-1"])
        let structure = try await phone.device.projection.loadStructure()
        #expect(structure.notebooks.first { $0.notebookID == "nb-1" }?.hasCover == true)
        #expect(structure.notebooks.first { $0.notebookID == "nb-2" }?.hasCover == false)
    }

    // MARK: - Asking a Mac for a cover

    @Test("A notebook made on the phone writes one Job(makeDerived) naming it, with no tool, and asks again for nothing while it waits")
    func aNewNotebookWritesOneJob() async throws {
        let replica = try await Fixture.replica()
        let writer = Fixture.writer(replica)
        let id = try await writer.createNotebook(title: "New notebook", instructions: nil, summary: nil)
        let job = try #require(try await writer.requestNotebookCover(id))
        let held = try #require(try await Fixture.held(replica, .job, job, in: Fixture.library))
        #expect(held.fields["kind"] == .string("makeDerived"))
        #expect(held.fields["target"] == .string("nb:\(id)"))
        #expect(held.fields["params"] == .object(["derived": .string("cover")]), "{derived: cover} alone: a tool would send the Mac to that tool")
        #expect(held.fields["status"] == .string("queued"))
        #expect(held.fields["requestedBy"]?["platform"] == .string("ios"))
        #expect(held.fields["requestedAt"]?.int64Value != nil)
        #expect(held.fields["expiresAt"]?.int64Value != nil)
        #expect(try await writer.requestNotebookCover(id) == job, "the waiting request answers")
        #expect(try await Fixture.patched(replica).filter { $0.contains(" Job ") } == ["private/Library Job \(job)"], "one Job")
    }

    @Test("No Job is written for a notebook that has a cover, one in a space, or one that is gone")
    func noJobWhereNoneIsNeeded() async throws {
        let replica = try await Fixture.replica()
        let cover = FileRef(owner: "nb-has", role: "cover", hash: String(repeating: "a", count: 64), size: 3, mime: "image/jpeg",
                            encoding: "identity", storedParts: [Data([1, 2, 3])])
        try await Fixture.apply(replica, [
            (Fixture.library, try F.notebook("nb-has", "Has one", edited: 5, ["files": .object(["cover": cover.value])])),
            (Fixture.library, try F.notebook("nb-archived", "Old", edited: 4, ["status": .string("merged")])),
            (Fixture.space, try MobileSyncFixture.envelope(.notebook, "nb-shared", ["title": .string("Shared"), "status": .string("active"), "createdAt": SyncJSON(1)],
                                                           salt: MobileSyncFixture.spaceSalt)),
        ])
        let writer = Fixture.writer(replica)
        #expect(try await writer.requestNotebookCover("nb-has") == nil, "it has a cover")
        #expect(try await writer.requestNotebookCover("nb-shared") == nil, "a space notebook's cover is the space owner's Mac's")
        await #expect(throws: MobileRecordWriterError.self) { try await writer.requestNotebookCover("nb-archived") }
        await #expect(throws: MobileRecordWriterError.self) { try await writer.requestNotebookCover("missing") }
        #expect(try await Fixture.patchCount(replica) == 0)
    }

    @Test("None is written in Free mode or with the Setting off; with the Setting on or absent and Free mode off, one is")
    func theGates() async throws {
        #expect(MobileNotebookCover.automaticSettingKey == Self.automaticKey)
        #expect(MobileNotebookCover.isWanted(freeMode: false, automatic: nil))
        #expect(MobileNotebookCover.isWanted(freeMode: false, automatic: true))
        #expect(!MobileNotebookCover.isWanted(freeMode: false, automatic: false))
        #expect(!MobileNotebookCover.isWanted(freeMode: true, automatic: nil))
        #expect(!MobileNotebookCover.isWanted(freeMode: true, automatic: true), "an image model is never free")

        func made(_ settings: [(String, SyncEnvelope)]) async throws -> (replica: MobileReplica, writer: MobileRecordWriter, store: MobileModelPreferenceStore, id: String) {
            let replica = try await Fixture.replica()
            try await Fixture.apply(replica, settings)
            let writer = Fixture.writer(replica)
            let id = try await writer.createNotebook(title: "New notebook", instructions: nil, summary: nil)
            return (replica, writer, MobileSettingWriterTests.store(writer), id)
        }
        func jobs(_ replica: MobileReplica) async throws -> Int {
            try await Fixture.patched(replica).filter { $0.contains(" Job ") }.count
        }
        func request(_ phone: (replica: MobileReplica, writer: MobileRecordWriter, store: MobileModelPreferenceStore, id: String)) async -> String? {
            let store = phone.store
            return await MobileNotebookCoverRequest.requestIfWanted(
                notebookID: phone.id, writer: phone.writer,
                freeMode: { try await store.refreshFreeMode() },
                automatic: { try await store.bool(forKey: MobileNotebookCover.automaticSettingKey) }
            )
        }

        let plain = try await made([])
        #expect(await request(plain) != nil, "neither stored: covers are drawn")
        #expect(try await jobs(plain.replica) == 1)

        let off = try await made([try Self.setting(Self.automaticKey, false)])
        #expect(await request(off) == nil, "the Setting is off")
        #expect(try await jobs(off.replica) == 0)

        let free = try await made([try Self.setting(Self.freeModeKey, true)])
        #expect(await request(free) == nil, "Free mode draws nothing")
        #expect(try await jobs(free.replica) == 0)

        let both = try await made([try Self.setting(Self.freeModeKey, true), try Self.setting(Self.automaticKey, true)])
        #expect(await request(both) == nil)
        #expect(try await jobs(both.replica) == 0)

        let on = try await made([try Self.setting(Self.automaticKey, true), try Self.setting(Self.freeModeKey, false)])
        #expect(await request(on) != nil)
        #expect(try await jobs(on.replica) == 1)
    }

    @Test("A Setting that cannot be read writes nothing: a stale answer would spend")
    func anUnreadableSettingWritesNothing() async throws {
        let replica = try await Fixture.replica()
        let writer = Fixture.writer(replica)
        let id = try await writer.createNotebook(title: "New notebook", instructions: nil, summary: nil)
        struct Unreadable: Error {}
        let free = await MobileNotebookCoverRequest.requestIfWanted(notebookID: id, writer: writer, freeMode: { throw Unreadable() }, automatic: { nil })
        let setting = await MobileNotebookCoverRequest.requestIfWanted(notebookID: id, writer: writer, freeMode: { false }, automatic: { throw Unreadable() })
        #expect(free == nil && setting == nil)
        #expect(try await Fixture.patched(replica).filter { $0.contains(" Job ") }.isEmpty)
    }

    @Test("The phone reads the Setting from the replica and never writes it, nor the backfill's marker")
    func theSettingIsReadNeverWritten() async throws {
        let replica = try await Fixture.replica(space: nil)
        try await Fixture.apply(replica, [try Self.setting(Self.automaticKey, false)])
        let writer = Fixture.writer(replica)
        #expect(try await writer.preferenceValue(Self.automaticKey) as? Bool == false, "read as the Mac wrote it")
        await #expect(throws: MobileRecordWriterError.self) { try await writer.writePreference(Self.automaticKey, true) }
        await #expect(throws: MobileRecordWriterError.self) { try await writer.writePreference(Self.markerKey, "done") }
        #expect(MobileSettingCatalog.keys[Self.automaticKey] == nil && MobileSettingCatalog.leftOutEntry(for: Self.markerKey) == nil,
                "neither is a key the phone sets")
        #expect(try await Fixture.patchCount(replica) == 0)
    }

    @Test("Every icon on screen asks for its cover again once per interval of replica changes, not once per change: one observer, a revision")
    @MainActor
    func aBurstOfChangesIsOneRevision() async throws {
        let covers = MobileNotebookCoverImages()
        for _ in 0..<50 { NotificationCenter.default.post(name: .mobileReplicaDidChange, object: nil) }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(covers.revision == 1, "the first change after a quiet stretch is heard at once, the other 49 wait for the next interval")
    }

    @Test("The phone's left-out Setting keys are the catalog's, less the cover backfill's marker, which only the Mac writes")
    func leftOutKeysMatchTheCatalog() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("schema/generated/settings-catalog.json"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let leftOut = Set(try #require(catalog["leftOut"] as? [String: Any]).keys)
        let phone = Set(MobileSettingCatalog.leftOut.map(\.prefix))
        #expect(phone.isSubset(of: leftOut), "the phone lists only keys the catalog leaves out")
        #expect(leftOut.subtracting(phone) == ["images.notebookCoverBackfill."], "the marker is the one it omits")
    }

    // MARK: - Where the emoji was

    @Test("Every place the phone draws a notebook's emoji as a picture is a MobileNotebookIconView, so the cover takes its place")
    func everyPictureSurfaceShowsTheCover() throws {
        let iOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: iOS, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count > 50)
        var surfaces = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".displayIcon") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                surfaces += 1
                let before = lines[max(0, index - 6)...index].joined(separator: "\n")
                // A picture is the fallback of the cover's view; the collection preview's emoji is built into its icon
                // list; a collection card's own emoji is the collection's (`row(title:`, `gallery(title:`), which has no cover.
                #expect(before.contains("MobileNotebookIconView(") || before.contains("PreviewIcon(") || before.contains("(title: NotebookTitle"),
                        "\(file.lastPathComponent):\(index + 1) draws a notebook's emoji without its cover")
            }
        }
        #expect(surfaces >= 8, "the cards, the list, the gallery, the collection previews, the context groups, the chat tab and the pickers")
    }

    @Test("A tile a place puts behind a notebook's emoji is the icon's plate, so a cover never sits on one; a collection's stack keeps its circles' colours")
    func aCoverSitsOnNoTile() throws {
        let iOS = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: iOS, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        var calls = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("MobileNotebookIconView(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                calls += 1
                // The call ends where its closure closes, at the call's own indentation; its modifiers follow at that indentation.
                guard let end = lines[(index + 1)...].firstIndex(where: { indent($0) == indent(line) && $0.trimmingCharacters(in: .whitespaces).hasPrefix("}") }) else {
                    Issue.record("\(file.lastPathComponent):\(index + 1): the call has no end")
                    continue
                }
                // A collection's stack: the circle is the notebook's colour under its cover too, as on the Mac.
                if lines[index...end].joined().contains("cornerRadius: nil") { continue }
                let tiles = lines[(end + 1)...].prefix { indent($0) == indent(line) && $0.trimmingCharacters(in: .whitespaces).hasPrefix(".") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix(".background") || $0.hasPrefix(".clipShape") }
                #expect(tiles.isEmpty, "\(file.lastPathComponent):\(index + 1) draws \(tiles) round the icon, so a cover would sit on it: pass the tile as `plate:`")
            }
        }
        #expect(calls >= 8, "the cards, the list, the gallery, the collection previews, the context groups, the chat tab and the pickers")
    }
}
