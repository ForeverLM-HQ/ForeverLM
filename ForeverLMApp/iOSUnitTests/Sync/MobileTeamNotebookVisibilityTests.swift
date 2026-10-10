import Foundation
import Testing
@testable import ForeverLM

/// Team notebooks on the iPhone (docs/cloudkit-schema-design.md §2.3, §9.7, P10, D13, §14.2 WP19): a
/// joined space's notebooks appear, named for their space, as soon as SpaceSync's payload-only walk
/// has run. No satellite's `data` or `asset` is asked for to show them, and a space the member loses
/// leaves the phone at once.
@Suite("iPhone team notebooks", .serialized)
struct MobileTeamNotebookVisibilityTests {
    static let teamZone = CloudZoneID("Space-s1")
    static let clubZone = CloudZoneID("Space-n1")
    static let clubSalt = Data(repeating: 9, count: 32)
    static let pdfBytes = Data(repeating: 0x25, count: 40_000)

    /// Alice's team "Acme Lab" with a notebook, its source and the source's PDF satellite, and her
    /// one shared notebook "Reading club"; Bob, on his phone, has joined both.
    static func joined(_ permission: FakeCloudKit.Permission = .readWrite) async throws -> (server: FakeCloudKit, phone: MobileTestDevice, recording: MobileRecordingTransport) {
        let server = FakeCloudKit(start: Date())
        try MobileSyncFixture.makeLibrary(server, owner: "alice")
        try MobileSyncFixture.makeLibrary(server, owner: "bob", salt: Data(repeating: 4, count: 32))
        try MobileSyncFixture.makeSpace(server, owner: "alice", name: "Acme Lab")
        try MobileSyncFixture.makeSpace(server, owner: "alice", zoneName: "Space-n1", kind: "notebook", name: "Reading club",
                                        primaryID: "nb-club", salt: clubSalt)
        let pdf = MobileSyncFixture.fileRef(owner: "src-t", role: "pdf", bytes: pdfBytes)
        let partHash = pdf.value["parts"]?.arrayValue?.first?.stringValue ?? ""
        let satelliteID = "ct:src-t:pdf:\(partHash)"
        var satellite = try MobileSyncFixture.record(.content, satelliteID, [
            "ownerType": .string("Source"), "ownerID": .string("src-t"), "role": .string("pdf"),
        ], in: teamZone, salt: MobileSyncFixture.spaceSalt)
        satellite.encryptedFields[CloudRecord.dataKey] = .bytes(pdfBytes)
        let space = MobileSyncFixture.spaceSalt
        server.put([
            try MobileSyncFixture.record(.notebook, "nb-team", [
                "title": .string("🧠 Team reading"), "status": .string("active"), "createdAt": SyncJSON(1), "editedAt": SyncJSON(2),
                "createdBy": SyncPerson(user: "alice", name: "Alice Owner").value,
            ], in: teamZone, salt: space),
            try MobileSyncFixture.record(.entry, "en:nb-team:source:src-t", [
                "containerKind": .string("notebook"), "containerID": .string("nb-team"), "itemKind": .string("source"),
                "itemID": .string("src-t"), "state": .string("active"), "orderKey": .string("a0"), "origin": .string("added"), "addedAt": SyncJSON(1),
            ], in: teamZone, salt: space),
            try MobileSyncFixture.record(.source, "src-t", [
                "primaryKey": .string("doi:10.1/team"), "type": .string("paper"), "title": .string("Team paper"), "status": .string("active"),
                "addedAt": SyncJSON(1), "files": .object(["pdf": pdf.value]),
            ], in: teamZone, salt: space),
            try MobileSyncFixture.record(.chat, "ch-team", [
                "kind": .string("chat"), "notebookID": .string("nb-team"), "title": .string("Team chat"), "status": .string("active"),
                "contextMode": .string("notebook"), "createdAt": SyncJSON(3), "editedAt": SyncJSON(3),
            ], in: teamZone, salt: space),
            satellite,
        ], zone: teamZone.zoneName, owner: "alice")
        server.put([
            try MobileSyncFixture.record(.notebook, "nb-club", [
                "title": .string("Reading club"), "status": .string("active"), "createdAt": SyncJSON(1), "editedAt": SyncJSON(1),
            ], in: clubZone, salt: clubSalt),
        ], zone: clubZone.zoneName, owner: "alice")
        server.share(zone: teamZone.zoneName, owner: "alice", with: "bob", permission: permission)
        server.share(zone: clubZone.zoneName, owner: "alice", with: "bob", permission: .readOnly)

        let recording = MobileRecordingTransport(server.transport(user: "bob", device: "phone"))
        let phone = try MobileTestDevice(server, user: "bob", transport: recording)
        try await phone.bootstrap()
        try await phone.sync()
        return (server, phone, recording)
    }

    @Test("A joined space's notebook appears with its space's name from a payload-only walk, and no satellite bytes are fetched")
    func joinedNotebookAppears() async throws {
        let (server, phone, recording) = try await Self.joined()
        let structure = try await phone.projection.loadStructure()

        let team = try #require(structure.notebooks.first { $0.notebookID == "nb-team" })
        #expect(team.title == "🧠 Team reading")
        #expect(team.spaceName == "Acme Lab")
        #expect(team.zoneKey == "shared/alice/Space-s1")
        #expect(team.space?.isOwned == false && team.space?.permission == "readWrite" && team.space?.ownerName == "Alice Owner")
        let club = try #require(structure.notebooks.first { $0.notebookID == "nb-club" })
        #expect(club.spaceName == "Reading club" && club.space?.kind == "notebook" && club.space?.isReadOnly == true)
        #expect(club.space?.primaryID == "nb-club")
        #expect(structure.chats(in: team).map(\.chatID) == ["ch-team"])

        let entries = try await phone.projection.entries(of: team)
        #expect(entries.map(\.itemID) == ["src-t"])
        #expect(entries.first?.source?.title == "Team paper" && entries.first?.source?.hasPDF == true,
                "the source shows that it has a PDF from its FileRef alone")

        let spaceRequests = recording.zoneChangeKeys.filter { $0.zone.hasPrefix(SyncSchema.spaceZonePrefix) }
        #expect(!spaceRequests.isEmpty)
        #expect(spaceRequests.allSatisfy { $0.keys == [CloudRecord.payloadKey] || $0.keys == [] }, "\(spaceRequests)")
        #expect(recording.recordFetchKeys.allSatisfy { $0 == [CloudRecord.payloadKey] }, "\(recording.recordFetchKeys)")
        let satelliteName = RecordNaming.recordName(type: .content, id: "ct:src-t:pdf:\(MobileSyncFixture.fileRef(owner: "src-t", role: "pdf", bytes: Self.pdfBytes).value["parts"]?.arrayValue?.first?.stringValue ?? "")",
                                                    salt: MobileSyncFixture.spaceSalt)
        #expect(!recording.recordNamesFetched.contains(satelliteName), "the PDF is fetched only when opened")
        #expect(server.storedRecord(satelliteName, zone: "Space-s1", owner: "alice")?.encryptedFields[CloudRecord.dataKey] != nil,
                "the server holds the bytes the walk left behind")
        #expect(try await phone.count("SELECT COUNT(*) FROM ck_records WHERE zone_key = 'shared/alice/Space-s1' AND record_type = 'Content'") == 1,
                "the satellite's record is known by its payload")
    }

    @Test("A member the owner removes loses the space's notebooks at once, and the phone drops its rows")
    func removedMemberLosesTheSpace() async throws {
        let (server, phone, _) = try await Self.joined()
        server.removeParticipant("bob", zone: Self.teamZone.zoneName, owner: "alice")
        try await phone.sync()

        let structure = try await phone.projection.loadStructure()
        #expect(!structure.notebooks.contains { $0.notebookID == "nb-team" })
        #expect(structure.notebooks.contains { $0.notebookID == "nb-club" }, "the other space stays")
        #expect(try await phone.count("SELECT COUNT(*) FROM m_notebooks WHERE zone_key = 'shared/alice/Space-s1'") == 0)
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources WHERE zone_key = 'shared/alice/Space-s1'") == 0)
    }

    @Test("A rename of the space reaches the phone's notebooks with the next walk")
    func spaceRenamed() async throws {
        let (server, phone, _) = try await Self.joined()
        try MobileSyncFixture.makeSpace(server, owner: "alice", name: "Acme Institute")
        try await phone.sync()
        let structure = try await phone.projection.loadStructure()
        #expect(structure.notebooks.first { $0.notebookID == "nb-team" }?.spaceName == "Acme Institute")
    }
}
