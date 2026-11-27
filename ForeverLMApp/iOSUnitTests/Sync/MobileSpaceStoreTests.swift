import Foundation
import Testing
@testable import ForeverLM

/// The Space on the iPhone under generation 2 (docs/docs-design.md, "The Space"; docs/cloudkit-schema-design.md
/// §3.5.3, §3.5.15, §3.5.30): a page is the Artifact the web's writer makes, its text the `body` satellite
/// uploaded before the pointer and saved only over the revision the editor opened; the learner's spaces,
/// pins and subpages are the four left-out Settings the Mac writes, read back by prefix with what the
/// phone has not sent yet; a daily note lands on the Mac's record by its id; and under generation 1 the
/// Space is unavailable and writes nothing.
@MainActor
@Suite("The Space on the iPhone", .serialized)
struct MobileSpaceStoreTests {
    typealias Fixture = MobileWriterFixture

    static let now = Date(timeIntervalSince1970: 1_791_000_000)

    struct Phone {
        let server: FakeCloudKit
        let device: MobileTestDevice
        let writer: MobileRecordWriter
        let satellites: MobileSatellites
        let backend: MobileSpaceStore.Backend
        let recents: MobileSpaceRecents
        let store: MobileSpaceStore
    }

    /// Alice's seeded library on a synced phone whose writer uploads bodies to the fake server, and the
    /// Space over it, its satellites cached in a folder of the test's own.
    static func phone() async throws -> Phone {
        let (server, device, writer) = try await MobileExplainerRecordTests.phone()
        guard let blobs = writer.blobs else { throw MobileSpaceError.unavailable }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileSpaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        let satellites = MobileSatellites(projection: device.projection, blobs: blobs, disk: MobileSatelliteDisk(
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true), durableRoot: root.appendingPathComponent("durable", isDirectory: true)
        ))
        let backend = MobileSpaceStore.Backend(writer: writer, satellites: satellites)
        let recents = MobileSpaceRecents(defaults: nil)
        let now = Self.now
        let store = MobileSpaceStore(connect: { backend }, now: { now }, recents: recents, observesReplica: false)
        await store.refresh()
        return Phone(server: server, device: device, writer: writer, satellites: satellites, backend: backend, recents: recents, store: store)
    }

    static func setting(_ phone: Phone, _ key: String) async throws -> SyncJSON? {
        try await Fixture.held(phone.device.replica, .setting, key, in: Fixture.library)?.fields["value"]
    }

    static func string(_ value: String) -> SyncJSON {
        .object(["t": .string("string"), "v": .string(value)])
    }

    static func body(_ phone: Phone, _ id: String) async throws -> FileRef? {
        try await Fixture.held(phone.device.replica, .artifact, id, in: Fixture.library)?.fields["body"].flatMap(FileRef.init(json:))
    }

    // MARK: - Pages

    @Test("A new page is the web's Doc in Library, its body the package uploaded before the record names it, on the list at once")
    func createsAPage() async throws {
        let phone = try await Self.phone()
        let page = try await phone.store.createPage(title: "  Membranes  ", markdown: "# Membranes\n\nIons cross.", spaceID: nil, parentID: nil)
        #expect(page.id == page.id.lowercased() && UUID(uuidString: page.id) != nil)
        #expect(page.title == "Membranes")
        #expect(page.isEditableMarkdown && page.isOwn && !page.isTrashed && !page.isDailyNote && page.spaceKind == .page)
        #expect(phone.store.pages == [page])

        let record = try #require(try await Fixture.held(phone.device.replica, .artifact, page.id, in: Fixture.library))
        #expect(record.fields["kind"] == .string("doc"))
        #expect(record.fields["title"] == .string("Membranes"))
        #expect(record.fields["status"] == .string("active"))
        #expect(record.fields["isDraft"] == .bool(false))
        #expect(record.fields["bodyFormat"] == .string("markdownPackage"))
        #expect(record.fields["preview"] == .string("# Membranes Ions cross."))
        #expect(record.fields["madeBy"]?["route"] == .string("ios"))
        #expect(record.fields["createdAt"]?.int64Value != nil && record.fields["editedAt"]?.int64Value != nil)
        let body = try #require(record.fields["body"].flatMap(FileRef.init(json:)))
        #expect(body.owner == page.id && body.role == "body" && body.mime == "application/vnd.foreverlm.article" && body.encoding == "identity")
        let package = try ArtifactBodyPackage.encode(markdown: "# Membranes\n\nIons cross.", attachmentDirectory: nil)
        #expect(body.hash == package.revision, "the package's revision, the one the Mac gives the same text")
        #expect(page.bodyRevision == body.hash)
        let part = try #require(body.satelliteIDs.first)
        #expect(phone.server.storedRecord(RecordNaming.recordName(type: .content, id: part, salt: MobileSyncFixture.librarySalt), zone: "Content",
                                          owner: MobileRecordWriterTests.alice) != nil, "the body is on the server before anything points at it")
        #expect(try await Fixture.patched(phone.device.replica) == ["private/Library Artifact \(page.id)"])

        let read = try await phone.store.body(of: page.id)
        #expect(read.markdown == "# Membranes\n\nIons cross.")
        #expect(read.revision == body.hash)

        try await phone.device.sync()
        let stored = try #require(try MobileRecordWriterTests.stored(phone.server, .artifact, page.id, zone: "Library"))
        #expect(stored.fields["body"] == body.value)
        #expect(stored.fields["title"] == .string("Membranes"))

        let fresh = MobileSpaceStore(connect: { phone.backend }, recents: MobileSpaceRecents(defaults: nil), observesReplica: false)
        await fresh.refresh()
        #expect(fresh.isAvailable)
        #expect(fresh.pages.map(\.id) == [page.id])
        #expect(fresh.pages.first?.bodyRevision == body.hash)
        let untitled = try await phone.store.createPage(title: " ", markdown: "", spaceID: nil, parentID: nil)
        #expect(untitled.title == MobileSpaceListing.untitledTitle)
    }

    @Test("A page the editor linked before it existed is made under the editor's id, once, and a subpage goes under the page it came from")
    func createsAPageUnderTheEditorsID() async throws {
        let phone = try await Self.phone()
        let space = try await phone.store.createSpace(named: "Lab")
        let parent = try await phone.store.createPage(title: "Parent", markdown: "", spaceID: space, parentID: nil)
        let id = UUID().uuidString.lowercased()
        let page = try await phone.store.createPage(title: "Untitled", markdown: "", spaceID: nil, parentID: parent.id, id: id)
        #expect(page.id == id && page.title == "Untitled" && page.isEditableMarkdown)
        #expect(phone.store.organization.parentByPage[id] == parent.id)
        #expect(phone.store.organization.spaceID(ofPage: id) == space, "in its parent's space")
        #expect(try await Fixture.held(phone.device.replica, .artifact, id, in: Fixture.library)?.fields["title"] == .string("Untitled"))

        let patches = try await Fixture.patched(phone.device.replica)
        let again = try await phone.store.createPage(title: "Another name", markdown: "Other text.", spaceID: nil, parentID: nil, id: id)
        #expect(again.id == id && again.title == "Untitled", "the page held under the id is returned as it is")
        #expect(try await Fixture.patched(phone.device.replica) == patches, "a request made twice makes one page")
        #expect(phone.store.pages.filter { $0.id == id }.count == 1)

        await #expect(throws: MobileSpaceError.self) {
            _ = try await phone.store.createPage(title: "x", markdown: "", spaceID: nil, parentID: nil, id: "daily-2026-10-07")
        }
        await #expect(throws: MobileSpaceError.self) {
            _ = try await phone.store.createPage(title: "x", markdown: "", spaceID: nil, parentID: nil, id: "notes:nb1")
        }
        #expect(try await Fixture.patched(phone.device.replica) == patches, "a refused id writes nothing")
    }

    @Test("A save writes over the revision the editor opened; one over a revision that moved here or by sync is a conflict carrying the text now")
    func savesOverItsRevision() async throws {
        let phone = try await Self.phone()
        let page = try await phone.store.createPage(title: "Notes", markdown: "First.", spaceID: nil, parentID: nil)
        let first = try #require(page.bodyRevision)
        let second = try #require(try await phone.store.saveBody("Second.", of: page.id, expectedRevision: first))
        #expect(second != first)
        #expect(phone.store.pages.first { $0.id == page.id }?.bodyRevision == second)
        #expect(try await Self.body(phone, page.id)?.hash == second)
        #expect(try await Fixture.held(phone.device.replica, .artifact, page.id, in: Fixture.library)?.fields["preview"] == .string("Second."))
        let read = try await phone.store.body(of: page.id)
        #expect(read.markdown == "Second." && read.revision == second)

        // The same text again writes nothing and answers the revision held.
        #expect(try await phone.store.saveBody("Second.", of: page.id, expectedRevision: second) == second)

        // Over the revision before the last save, or over none, it is a conflict, and nothing is written.
        await #expect(throws: MobileSpaceError.conflict(currentMarkdown: "Second.", currentRevision: second)) {
            try await phone.store.saveBody("A stale edit.", of: page.id, expectedRevision: first)
        }
        await #expect(throws: MobileSpaceError.conflict(currentMarkdown: "Second.", currentRevision: second)) {
            try await phone.store.saveBody("Another.", of: page.id, expectedRevision: nil)
        }
        #expect(try await Self.body(phone, page.id)?.hash == second)

        // A Mac's edit arrives by sync: the editor's revision is no longer the page's.
        try await phone.device.sync()
        let mac = try ArtifactBodyPackage.encode(markdown: "From the Mac.", attachmentDirectory: nil)
        let macBody = FileRef(owner: page.id, role: "body", hash: mac.revision, size: Int64(mac.data.count), mime: MobileSpaceBody.packageMime,
                              encoding: "identity", storedParts: [mac.data])
        phone.satellites.hold(mac.data, as: macBody)
        try await MobileSyncFixture.apply([(Fixture.library, try MobileSyncFixture.envelope(.artifact, page.id, [
            "kind": .string("doc"), "title": .string("Notes"), "status": .string("active"), "body": macBody.value,
            "createdAt": SyncJSON(Int64(1_759_000_000_000)), "editedAt": SyncJSON(Int64(1_759_500_000_000)),
        ]))], to: phone.device.replica)
        let patches = try await Fixture.patchCount(phone.device.replica)
        await #expect(throws: MobileSpaceError.conflict(currentMarkdown: "From the Mac.", currentRevision: mac.revision)) {
            try await phone.store.saveBody("Written on the phone.", of: page.id, expectedRevision: second)
        }
        #expect(try await Fixture.patchCount(phone.device.replica) == patches)
        #expect(try await phone.store.saveBody("Merged by hand.", of: page.id, expectedRevision: mac.revision) != nil)
    }

    @Test("A save keeps the pictures its Markdown still names; one naming a picture the page does not hold is refused")
    func carriesPictures() async throws {
        let phone = try await Self.phone()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MobileSpaceStoreTests-pic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = Data((0..<512).map { UInt8($0 % 251) })
        try picture.write(to: folder.appendingPathComponent("cell.png"))
        let markdown = "A cell.\n\n![Cell](foreverlm://attachment/cell.png)"
        let package = try ArtifactBodyPackage.encode(markdown: markdown, attachmentDirectory: folder)
        let id = "mac-page-1"
        let file = try await phone.writer.uploadPageBody(package.data, pageID: id, keeping: nil)
        try await phone.writer.transaction { try $0.createPage(id, title: "Cells", body: file, markdown: markdown) }
        await phone.store.refresh()

        let saved = try #require(try await phone.store.saveBody("A cell, redrawn.\n\n![Cell](foreverlm://attachment/cell.png)", of: id,
                                                                  expectedRevision: file.hash))
        let held = try #require(try await phone.satellites.artifactBody(id)?.package)
        let decoded = try ArtifactBodyPackage.decode(held, expectedRevision: saved)
        #expect(decoded.markdown == "A cell, redrawn.\n\n![Cell](foreverlm://attachment/cell.png)")
        #expect(decoded.attachments.map(\.token) == ["cell.png"])
        #expect(decoded.attachments.first?.data == picture)
        let opened = try await phone.store.body(of: id)
        #expect(opened.pictures == ["cell.png": "data:image/png;base64,\(picture.base64EncodedString())"], "the editor draws the page's pictures")

        let dropped = try #require(try await phone.store.saveBody("No picture now.", of: id, expectedRevision: saved))
        let without = try ArtifactBodyPackage.decode(try #require(try await phone.satellites.artifactBody(id)?.package), expectedRevision: dropped)
        #expect(without.attachments.isEmpty)

        let patches = try await Fixture.patchCount(phone.device.replica)
        await #expect(throws: MobileSpaceError.self) {
            try await phone.store.saveBody("![Gone](foreverlm://attachment/missing.png)", of: id, expectedRevision: dropped)
        }
        #expect(try await Self.body(phone, id)?.hash == dropped)
        #expect(try await Fixture.patchCount(phone.device.replica) == patches)
    }

    @Test("Rename, Move to Trash and Restore write the title and the status on the one record")
    func renamesTrashesRestores() async throws {
        let phone = try await Self.phone()
        let page = try await phone.store.createPage(title: "Old", markdown: "", spaceID: nil, parentID: nil)
        #expect(try await Fixture.held(phone.device.replica, .artifact, page.id, in: Fixture.library)?.fields["preview"] == nil,
                "an empty page writes no preview")
        try await phone.store.rename(page.id, to: "  New  ")
        #expect(phone.store.pages.first?.title == "New")
        #expect(try await Fixture.held(phone.device.replica, .artifact, page.id, in: Fixture.library)?.fields["title"] == .string("New"))
        await #expect(throws: MobileSpaceError.invalidName) { try await phone.store.rename(page.id, to: " \n ") }
        await #expect(throws: MobileSpaceError.notFound) { try await phone.store.rename("no-such-page", to: "x") }

        try await phone.store.moveToTrash(page.id)
        #expect(try await Fixture.held(phone.device.replica, .artifact, page.id, in: Fixture.library)?.fields["status"] == .string("archived"))
        #expect(phone.store.pages.first?.isTrashed == true)
        #expect(MobileSpaceListing.pages(in: .trash, from: phone.store.pages, organization: phone.store.organization).map(\.id) == [page.id])
        #expect(MobileSpaceListing.pages(in: .all, from: phone.store.pages, organization: phone.store.organization).isEmpty)

        try await phone.store.restore(page.id)
        #expect(try await Fixture.held(phone.device.replica, .artifact, page.id, in: Fixture.library)?.fields["status"] == .string("active"))
        #expect(phone.store.pages.first?.isTrashed == false)
        try await phone.device.sync()
        let stored = try #require(try MobileRecordWriterTests.stored(phone.server, .artifact, page.id, zone: "Library"))
        #expect(stored.fields["title"] == .string("New") && stored.fields["status"] == .string("active"))
    }

    @Test("Delete Forever deletes the record; the page leaves its space, the pages under it come out to the top, and Recents forget it")
    func deletesForever() async throws {
        let phone = try await Self.phone()
        let space = try await phone.store.createSpace(named: "Lab")
        let parent = try await phone.store.createPage(title: "Parent", markdown: "", spaceID: space, parentID: nil)
        let child = try await phone.store.createPage(title: "Child", markdown: "", spaceID: nil, parentID: parent.id)
        #expect(phone.store.organization.parentByPage[child.id] == parent.id)
        #expect(phone.store.organization.spaceID(ofPage: child.id) == space, "a subpage goes in its parent's space, as the Mac's New Subpage")
        phone.recents.note(parent.id)
        try await phone.device.sync()

        try await phone.store.deleteForever(parent.id)
        #expect(try await Fixture.held(phone.device.replica, .artifact, parent.id, in: Fixture.library) == nil)
        #expect(try await phone.device.count("SELECT COUNT(*) FROM ck_pending_deletes WHERE wire_id = ?", [.text(parent.id)]) == 1)
        #expect(!phone.store.pages.contains { $0.id == parent.id })
        #expect(try await Self.setting(phone, PageSpaces.membershipKey(pageID: parent.id)) == .null)
        #expect(try await Self.setting(phone, PageParents.key(pageID: child.id)) == .null)
        #expect(phone.store.organization.parentByPage.isEmpty)
        #expect(phone.store.organization.spaceID(ofPage: child.id) == space, "the child stays in its space")
        #expect(phone.recents.items.isEmpty)

        try await phone.device.sync()
        #expect(try MobileRecordWriterTests.stored(phone.server, .artifact, parent.id, zone: "Library") == nil)
        #expect(try MobileRecordWriterTests.stored(phone.server, .setting, PageParents.key(pageID: child.id), zone: "Library")?.fields["value"] == .null,
                "a Setting is cleared, never deleted")
    }

    // MARK: - The learner's grouping

    @Test("Spaces, pins and moves are the Mac's Settings, read back by prefix with what the phone has not sent")
    func spacesAndPins() async throws {
        let phone = try await Self.phone()
        let id = try await phone.store.createSpace(named: "  🧪   Lab  ")
        #expect(id.hasPrefix(PageSpaces.idPrefix))
        #expect(phone.store.organization.spaces == [PageSpace(id: id, name: "🧪 Lab")])
        #expect(try await Self.setting(phone, PageSpaces.nameKey(spaceID: id)) == Self.string("🧪 Lab"))
        let names = try await phone.device.projection.settings(withPrefixes: [PageSpaces.namePreferenceKeyPrefix])
        #expect(Array(names.keys) == [PageSpaces.nameKey(spaceID: id)], "a space with no page in it is listed before it is sent")
        await #expect(throws: MobileSpaceError.invalidName) { _ = try await phone.store.createSpace(named: " ") }

        let page = try await phone.store.createPage(title: "Cells", markdown: "", spaceID: nil, parentID: nil)
        try await phone.store.move(page.id, toSpace: id)
        #expect(try await Self.setting(phone, PageSpaces.membershipKey(pageID: page.id)) == Self.string(id))
        #expect(MobileSpaceListing.pages(in: .space(id), from: phone.store.pages, organization: phone.store.organization).map(\.id) == [page.id])
        await #expect(throws: MobileSpaceError.notFound) { try await phone.store.move(page.id, toSpace: "psp-gone") }

        try await phone.store.setPinned(page.id, true)
        let seconds = Int(Self.now.timeIntervalSince1970)
        #expect(phone.store.organization.pinnedAtByPage[page.id] == seconds)
        #expect(try await Self.setting(phone, PagePins.key(pageID: page.id)) == Self.string(String(seconds)))
        #expect(MobileSpaceListing.pinned(phone.store.pages, organization: phone.store.organization).map(\.id) == [page.id])
        let patches = try await Fixture.patched(phone.device.replica)
        try await phone.store.setPinned(page.id, true)
        #expect(try await Fixture.patched(phone.device.replica) == patches, "pinning again keeps the first moment")
        try await phone.store.setPinned(page.id, false)
        #expect(try await Self.setting(phone, PagePins.key(pageID: page.id)) == .null)
        #expect(!phone.store.organization.isPinned(page.id))

        // A fresh read of the replica sees what this phone wrote and has not sent.
        let fresh = MobileSpaceStore(connect: { phone.backend }, recents: MobileSpaceRecents(defaults: nil), observesReplica: false)
        await fresh.refresh()
        #expect(fresh.organization == phone.store.organization)

        try await phone.store.renameSpace(id, to: "Lab two")
        #expect(phone.store.organization.space(id)?.name == "Lab two")
        try await phone.store.deleteSpace(id)
        #expect(try await Self.setting(phone, PageSpaces.nameKey(spaceID: id)) == .null)
        #expect(try await Self.setting(phone, PageSpaces.membershipKey(pageID: page.id)) == .null)
        #expect(phone.store.organization.spaces.isEmpty && phone.store.organization.spaceIDByPage.isEmpty)
        await #expect(throws: MobileSpaceError.notFound) { try await phone.store.renameSpace(id, to: "Back again") }
        #expect(try await Self.setting(phone, PageSpaces.nameKey(spaceID: id)) == .null, "a deleted space is never brought back by a rename")

        try await phone.device.sync()
        #expect(try MobileRecordWriterTests.stored(phone.server, .setting, PageSpaces.nameKey(spaceID: id), zone: "Library")?.fields["key"]
                == .string(PageSpaces.nameKey(spaceID: id)))
    }

    @Test("A team's page neither pins nor files in the learner's spaces; a member who may write edits it, a reader cannot")
    func teamPagesStayTheTeams() async throws {
        let phone = try await Self.phone()
        try await MobileSyncFixture.holdSpace(phone.device.replica, zoneKey: Fixture.space, zoneName: "Space-s1", owned: true, name: "Acme Lab")
        try await Fixture.apply(phone.device.replica, [(Fixture.space, try MobileSyncFixture.envelope(.artifact, "team-page", [
            "kind": .string("doc"), "title": .string("Team page"), "status": .string("active"), "createdAt": SyncJSON(Int64(1)),
            "editedAt": SyncJSON(Int64(1)),
        ], salt: MobileSyncFixture.spaceSalt))])
        await phone.store.refresh()
        let page = try #require(phone.store.pages.first { $0.id == "team-page" })
        #expect(page.teamID == "s1" && page.isEditableMarkdown, "a team's Page is written in place, live with the team")
        #expect(phone.store.teams.contains(MobileSpaceTeam(id: "s1", name: "Acme Lab")), "listed under Spaces by its root's name")
        let space = try await phone.store.createSpace(named: "Lab")
        await #expect(throws: MobileSpaceError.self) { try await phone.store.setPinned(page.id, true) }
        await #expect(throws: MobileSpaceError.self) { try await phone.store.move(page.id, toSpace: space) }
        #expect(try await Self.setting(phone, PagePins.key(pageID: page.id)) == nil)

        // A space this member may only read: its page reads as a page and never saves.
        let readerZone = "shared/alice/Space-s2"
        try await MobileSyncFixture.holdSpace(phone.device.replica, zoneKey: readerZone, zoneName: "Space-s2", owned: false, name: "Their Lab",
                                              permission: "readOnly")
        try await Fixture.apply(phone.device.replica, [(readerZone, try MobileSyncFixture.envelope(.artifact, "read-page", [
            "kind": .string("doc"), "title": .string("Read page"), "status": .string("active"), "createdAt": SyncJSON(Int64(1)),
            "editedAt": SyncJSON(Int64(1)),
        ], salt: MobileSyncFixture.spaceSalt))])
        await phone.store.refresh()
        let read = try #require(phone.store.pages.first { $0.id == "read-page" })
        #expect(read.teamID == "s2" && !read.isEditableMarkdown)
        await #expect(throws: MobileSpaceError.self) { try await phone.store.saveBody("x", of: read.id, expectedRevision: nil) }
    }

    @Test("Subpages nest the learner's own pages; a cycle, the page itself and a daily note are refused, and Remove from Parent clears the row")
    func subpages() async throws {
        let phone = try await Self.phone()
        let a = try await phone.store.createPage(title: "A", markdown: "", spaceID: nil, parentID: nil)
        let b = try await phone.store.createPage(title: "B", markdown: "", spaceID: nil, parentID: nil)
        let c = try await phone.store.createPage(title: "C", markdown: "", spaceID: nil, parentID: nil)
        try await phone.store.setParent(of: b.id, to: a.id)
        try await phone.store.setParent(of: c.id, to: b.id)
        #expect(try await Self.setting(phone, PageParents.key(pageID: c.id)) == Self.string(b.id))
        #expect(MobileSpaceListing.ancestors(of: c.id, in: phone.store.pages, organization: phone.store.organization).map(\.id) == [a.id, b.id])

        let patches = try await Fixture.patched(phone.device.replica)
        await #expect(throws: MobileSpaceError.self) { try await phone.store.setParent(of: a.id, to: c.id) }
        await #expect(throws: MobileSpaceError.self) { try await phone.store.setParent(of: a.id, to: a.id) }
        let daily = try await phone.store.ensureDailyNote(dayKey: "2026-10-07")
        let afterDaily = try await Fixture.patched(phone.device.replica)
        #expect(afterDaily == (patches + ["private/Library Artifact \(daily.id)"]).sorted())
        await #expect(throws: MobileSpaceError.self) { try await phone.store.setParent(of: daily.id, to: a.id) }
        #expect(try await Fixture.patched(phone.device.replica) == afterDaily, "a refusal writes nothing")

        try await phone.store.setParent(of: c.id, to: nil)
        #expect(try await Self.setting(phone, PageParents.key(pageID: c.id)) == .null)
        #expect(MobileSpaceListing.children(of: b.id, in: phone.store.pages, organization: phone.store.organization).isEmpty)

        let nested = try await phone.store.createPage(title: "Under A", markdown: "", spaceID: nil, parentID: a.id)
        #expect(phone.store.organization.parentByPage[nested.id] == a.id)
        await #expect(throws: MobileSpaceError.self) {
            _ = try await phone.store.createPage(title: "Under a day", markdown: "", spaceID: nil, parentID: daily.id)
        }
    }

    // MARK: - Daily notes

    @Test("A daily note is the Mac's record by its id, titled by its day, made once; one a Mac made is taken as it is")
    func dailyNotes() async throws {
        let phone = try await Self.phone()
        let note = try await phone.store.ensureDailyNote(dayKey: "2026-10-07")
        #expect(note.id == "daily-2026-10-07")
        #expect(note.title == "October 7th, 2026")
        #expect(note.isDailyNote && note.isEditableMarkdown)
        let record = try #require(try await Fixture.held(phone.device.replica, .artifact, note.id, in: Fixture.library))
        #expect(record.fields["kind"] == .string("doc") && record.fields["preview"] == nil && record.fields["body"] != nil)
        #expect(try await phone.store.body(of: note.id).markdown.isEmpty)

        let patches = try await Fixture.patched(phone.device.replica)
        #expect(try await phone.store.ensureDailyNote(dayKey: "2026-10-07") == note)
        #expect(try await Fixture.patched(phone.device.replica) == patches, "made once")
        #expect(!MobileSpaceListing.pages(in: .pages, from: phone.store.pages, organization: phone.store.organization).contains(note),
                "reached by its day")
        #expect(MobileSpaceListing.pages(in: .pages, from: phone.store.pages, organization: phone.store.organization, query: "October 7").contains(note))
        #expect(MobileSpaceListing.dailyNotes(phone.store.pages) == [note])

        try await phone.device.sync()
        #expect(try MobileRecordWriterTests.stored(phone.server, .artifact, "daily-2026-10-07", zone: "Library") != nil,
                "named from its id and the library's salt, as the Mac names its own, so the two land on one record")

        // A note a Mac made for another day, its body not uploaded yet.
        try await MobileSyncFixture.apply([(Fixture.library, try MobileSyncFixture.envelope(.artifact, "daily-2026-10-06", [
            "kind": .string("doc"), "title": .string("October 6th, 2026"), "status": .string("active"),
            "createdAt": SyncJSON(Int64(1_759_000_000_000)), "editedAt": SyncJSON(Int64(1_759_000_000_000)),
        ]))], to: phone.device.replica)
        let before = try await Fixture.patched(phone.device.replica)
        let macs = try await phone.store.ensureDailyNote(dayKey: "2026-10-06")
        #expect(macs.title == "October 6th, 2026")
        #expect(try await Fixture.patched(phone.device.replica) == before)
        await #expect(throws: MobileSpaceError.notArrived) { _ = try await phone.store.body(of: macs.id) }
        await #expect(throws: MobileSpaceError.self) { _ = try await phone.store.ensureDailyNote(dayKey: "2026-02-30") }
    }

    // MARK: - Reading

    @Test("The Space lists every kind the Mac's does, the trashed and the hidden flagged, a team's page as the team's")
    func readsTheSpace() async throws {
        let replica = try await Fixture.replica()
        func artifact(_ id: String, _ fields: [String: SyncJSON], salt: Data = MobileSyncFixture.librarySalt) throws -> SyncEnvelope {
            var all: [String: SyncJSON] = ["title": .string(id), "status": .string("active"), "createdAt": SyncJSON(Int64(1)), "editedAt": SyncJSON(Int64(2))]
            all.merge(fields) { $1 }
            return try MobileSyncFixture.envelope(.artifact, id, all, salt: salt)
        }
        let library = Fixture.library
        try await Fixture.apply(replica, [
            (library, try MobileReadModelFixture.notebook("nb1", "Cells", edited: 1)),
            (library, try artifact("p1", ["kind": .string("doc")])),
            (library, try artifact("r1", ["kind": .string("report")])),
            (library, try artifact("g1", ["kind": .string("linkedDoc"), "linkedURL": .string("https://docs.google.com/document/d/abc/edit")])),
            (library, try artifact("s1", ["kind": .string("site"), "linkedURL": .string("foreverlm-site://site-1/")])),
            (library, try artifact("a1", ["kind": .string("animation")])),
            (library, try artifact("o1", ["kind": .string("audioOverview")])),
            (library, try artifact("notes:nb1", ["kind": .string("notes"), "notebookID": .string("nb1")])),
            (library, try artifact("draft:t9", ["kind": .string("doc")])),
            (library, try artifact("m1", ["kind": .string("mnemonic_reading"), "notebookID": .string("nb1")])),
            (library, try artifact("m2", ["kind": .string("mnemonic_reading")])),
            (library, try artifact("m3", ["kind": .string("mnemonic_reading"), "notebookID": .string("nb1"), "status": .string("archived")])),
            (library, try artifact("h1", ["kind": .string("doc")])),
            (library, try MobileReadModelFixture.mark("hidden", "art:h1")),
            (library, try artifact("x1", ["kind": .string("doc"), "status": .string("archived")])),
            (library, try artifact("daily-2026-10-07", ["kind": .string("doc")])),
            (Fixture.space, try artifact("t1", ["kind": .string("doc")], salt: MobileSyncFixture.spaceSalt)),
        ])
        let snapshot = try await replica.read { try MobileSpaceReadModel.snapshot(in: $0) }
        let pages = Dictionary(uniqueKeysWithValues: snapshot.pages.map { ($0.id, $0) })
        #expect(Set(pages.keys) == ["p1", "r1", "g1", "s1", "m2", "m3", "h1", "x1", "daily-2026-10-07", "t1"])
        #expect(pages["p1"]?.isEditableMarkdown == true && pages["r1"]?.isEditableMarkdown == true)
        #expect(pages["g1"]?.spaceKind == .googleDoc && pages["g1"]?.isEditableMarkdown == false)
        #expect(pages["s1"]?.spaceKind == .site)
        #expect(pages["m2"]?.spaceKind == .reading && pages["m2"]?.isEditableMarkdown == false)
        #expect(pages["m3"]?.isTrashed == true, "a reading its notebook holds is listed in Trash, to be restored")
        #expect(pages["h1"]?.isHidden == true)
        #expect(pages["x1"]?.isTrashed == true)
        #expect(pages["daily-2026-10-07"]?.isDailyNote == true)
        #expect(pages["t1"]?.teamID == "s1" && pages["t1"]?.isEditableMarkdown == true, "a member who may write the team edits its Page")
        #expect(MobileSpaceListing.pages(in: .team("s1"), from: snapshot.pages, organization: snapshot.organization).map(\.id) == ["t1"])
        #expect(snapshot.teams == [MobileSpaceTeam(id: "s1", name: "Acme Lab")])
    }

    @Test("The grouping is read by prefix with the pending writes, a cleared row left out; only the four keys pass the catalog")
    func settingsByPrefix() async throws {
        let replica = try await Fixture.replica(space: nil)
        let writer = Fixture.writer(replica)
        try await Fixture.apply(replica, [
            (Fixture.library, try MobileSyncFixture.envelope(.setting, "page.pinned.p1", ["key": .string("page.pinned.p1"), "value": Self.string("1700000000")])),
            (Fixture.library, try MobileSyncFixture.envelope(.setting, "pageSpace.psp-old", ["key": .string("pageSpace.psp-old"), "value": .null])),
            (Fixture.library, try MobileSyncFixture.envelope(.setting, "chat.model", ["key": .string("chat.model"), "value": Self.string("x")])),
        ])
        try await writer.transaction { try $0.writePageRow(PageSpaces.nameKey(spaceID: "psp-1"), "Lab") }
        let settings = try await MobileProjection(replica: replica).settings(withPrefixes: MobileSpaceOrganization.preferenceKeyPrefixes)
        #expect(Set(settings.keys) == ["page.pinned.p1", "pageSpace.psp-1"])
        #expect(try await Fixture.patched(replica) == ["private/Library \(SyncRecordType.setting.rawValue) pageSpace.psp-1"])
        let organization = try await replica.read { try MobileSpaceReadModel.organization(in: $0.connection) }
        #expect(organization.spaces == [PageSpace(id: "psp-1", name: "Lab")])
        #expect(organization.pinnedAtByPage == ["p1": 1_700_000_000])

        let patches = try await Fixture.patchCount(replica)
        try await writer.transaction { write in
            try write.writePageRow(PageSpaces.nameKey(spaceID: "psp-1"), "Lab")
            try write.writePageRow(PageParents.key(pageID: "p9"), nil)
        }
        #expect(try await Fixture.patchCount(replica) == patches, "the same value, or clearing a row never held, writes nothing")
        for prefix in MobileSpaceOrganization.preferenceKeyPrefixes {
            #expect(MobileSettingCatalog.leftOutEntry(for: prefix + "x")?.type == "string")
        }
        await #expect(throws: MobileRecordWriterError.self) { try await writer.transaction { try $0.writePageRow("chat.model", "y") } }
    }

    // MARK: - Generation 1

    @Test("Under generation 1 the Space is unavailable and every act is refused before anything is written")
    func generationOne() async throws {
        let store = MobileSpaceStore(connect: { nil }, recents: MobileSpaceRecents(defaults: nil), observesReplica: false)
        await store.refresh()
        #expect(!store.isAvailable && store.pages.isEmpty && store.organization == MobileSpaceOrganization())
        await #expect(throws: MobileSpaceError.unavailable) { _ = try await store.createPage(title: "x", markdown: "", spaceID: nil, parentID: nil) }
        await #expect(throws: MobileSpaceError.unavailable) { _ = try await store.ensureDailyNote(dayKey: "2026-10-07") }
        await #expect(throws: MobileSpaceError.unavailable) { _ = try await store.body(of: "p1") }
        await #expect(throws: MobileSpaceError.unavailable) { _ = try await store.createSpace(named: "Lab") }
        await #expect(throws: MobileSpaceError.unavailable) { try await store.setPinned("p1", false) }
    }
}
