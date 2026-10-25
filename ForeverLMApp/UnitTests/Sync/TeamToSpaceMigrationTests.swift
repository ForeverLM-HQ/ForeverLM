import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Teams become spaces (docs/cloudkit-schema-design.md §13.7, R6-m7, WP15): on the owner's Mac each team
/// gets `Space-<team id>` with a team or family root and its share; its copies go into it under canonical
/// wire ids, its notebook's Entries keep their approval states (b2), and every record is listed for the
/// seed's delta. A member's identities move to the space as the library container names its owner.
/// Generation 1 writes none of it.
@Suite("Team to space migration", .serialized)
struct TeamToSpaceMigrationTests {
    typealias S = SpaceTestFixture
    typealias F = NotebookSyncFixture

    static let teamID = "0a9b80fe-1fd9-48ff-9cb3-69614aeb07fa"
    static let zoneKey = "private/Space-\(teamID)"

    /// Alice's team as generation 1 left it: a notebook with three copies filed approved, pending and
    /// rejected; the first copy's original is in her own library.
    static func ownerWithTeam(_ server: FakeCloudKit, familyPlanCode: String? = nil) async throws -> (S.Mac, personal: String, others: [String]) {
        let alice = try await S.Mac(server, name: "team-owner", deviceID: "macaaaaa", user: "alice")
        let store = alice.store
        try S.addTeam(store, teamID, name: "Mito lab", familyPlanCode: familyPlanCode)
        let personal = try S.addPersonalSource(store, url: "https://example.org/a")
        try F.addNotebook(store, "nb-team")
        try store.execute("UPDATE learning_goals SET team_id = ? WHERE id = 'nb-team'", [.text(teamID)])
        let urls = ["https://example.org/a", "https://example.org/b", "https://example.org/c"]
        for (index, url) in urls.enumerated() {
            try S.addTeamSource(store, "src-team-\(index)", teamID: teamID, url: url)
        }
        try F.file(store, "src-team-0", into: "nb-team", reviewState: "approved")
        try F.file(store, "src-team-1", into: "nb-team", reviewState: "pending", origin: "discovered")
        try F.file(store, "src-team-2", into: "nb-team", reviewState: "rejected", origin: "discovered")
        if familyPlanCode != nil {
            try F.addNotebook(store, TeamContentIdentity.assignmentsNotebookID(teamID: teamID), title: "Assignments")
            try store.execute("UPDATE learning_goals SET team_id = ? WHERE id = ?", [.text(teamID), .text(TeamContentIdentity.assignmentsNotebookID(teamID: teamID))])
        }
        let others = urls.dropFirst().map { SyncIdentity.sourceID(normalizedURL: URLNormalizer.normalize($0)) }
        return (alice, personal, others)
    }

    @Test("The owner's team becomes Space-<team id>: its copies go under canonical ids, its Entries keep their approvals, every record is listed")
    func ownerTeamBecomesASpace() async throws {
        let server = EngineTestDriver.server()
        let (alice, personal, others) = try await Self.ownerWithTeam(server)
        let job = TeamToSpace(service: alice.service, passKey: "macaaaaa.p6")
        let outcome = try await job.run(owner: alice.owner)
        #expect(outcome.spaces == [Self.teamID: Self.teamID], "a UUID team keeps its id as the space's")

        let root = try SyncEnvelope(storedPayload: try #require(server.storedRecord("root", zone: "Space-\(Self.teamID)", owner: "alice")?.payload))
        #expect(root.fields["kind"] == .string("team") && root.fields["name"] == .string("Mito lab"))
        #expect(server.recordNames(zone: "Space-\(Self.teamID)", owner: "alice").contains(CloudRecordID.zoneShareRecordName))
        #expect(try alice.device.text("SELECT zone_name || ':' || zone_scope FROM teams WHERE id = ?", [.text(Self.teamID)]) == "Space-\(Self.teamID):private")
        #expect(try alice.device.text("SELECT share_url FROM teams WHERE id = ?", [.text(Self.teamID)]) != nil)

        // Wire ids are canonical: the personal original's id, else the address's stable id.
        #expect(try alice.device.text("SELECT wire_id FROM sources WHERE id = 'src-team-0'") == personal)
        #expect(try alice.device.text("SELECT wire_id FROM sources WHERE id = 'src-team-1'") == others[0])
        let pending = try alice.pendingInSpaces()
        for wire in [personal] + others {
            #expect(pending["Source:\(wire)"]?.zoneKey == Self.zoneKey)
        }
        #expect(pending["Notebook:nb-team"]?.zoneKey == Self.zoneKey)
        let approvals = [(personal, "approved"), (others[0], "pending"), (others[1], "rejected")]
        for (wire, approval) in approvals {
            let entry = try #require(pending["Entry:\(SyncIdentity.entryID(containerID: "nb-team", itemKind: "source", itemID: wire))"])
            #expect(entry.zoneKey == Self.zoneKey && F.savedFields(entry)?["approval"] == .string(approval) && F.savedFields(entry)?["itemID"] == .string(wire))
        }
        #expect(try alice.device.count("SELECT COUNT(*) FROM ck_manifest_pending WHERE pass_key = 'macaaaaa.p6' AND zone_key = ?", [.text(Self.zoneKey)])
                == alice.device.count("SELECT COUNT(*) FROM ck_identity WHERE zone_key = ?", [.text(Self.zoneKey)]))
        #expect(outcome.listed[Self.teamID] == 7, "three sources, the notebook and its Entries: \(outcome.listed)")

        // SpaceSync sends them; the server holds the pending suggestion as pending.
        try await alice.syncSpaces()
        let entryName = RecordNaming.recordName(type: .entry, id: SyncIdentity.entryID(containerID: "nb-team", itemKind: "source", itemID: others[0]), salt: S.spaceSalt)
        let held = try SyncEnvelope(storedPayload: try #require(server.storedRecord(entryName, zone: "Space-\(Self.teamID)", owner: "alice")?.payload))
        #expect(held.fields["approval"] == .string("pending"))

        // A second run finds the team done.
        #expect(try await job.run(owner: alice.owner) == TeamToSpace.Outcome())
    }

    @Test("A family team's space carries its plan code and its Assignments notebook")
    func familyBecomesAFamilySpace() async throws {
        let server = EngineTestDriver.server()
        let (alice, _, _) = try await Self.ownerWithTeam(server, familyPlanCode: "fam-1")
        try await TeamToSpace(service: alice.service, passKey: "macaaaaa.p6").run(owner: alice.owner)
        let root = try SyncEnvelope(storedPayload: try #require(server.storedRecord("root", zone: "Space-\(Self.teamID)", owner: "alice")?.payload))
        #expect(root.fields["kind"] == .string("family"))
        #expect(root.fields["familyPlanCode"] == .string("fam-1"))
        #expect(root.fields["assignmentsNotebookID"] == .string(TeamContentIdentity.assignmentsNotebookID(teamID: Self.teamID)))
    }

    @Test("A resumed run adopts the space an earlier run made, and makes no second one")
    func resumedRunAdopts() async throws {
        let server = EngineTestDriver.server()
        let (alice, _, _) = try await Self.ownerWithTeam(server)
        // The earlier run made the space and stopped before its share.
        _ = try await alice.service.create(kind: "team", name: "Mito lab", owner: alice.owner, spaceID: Self.teamID, share: false)
        try await TeamToSpace(service: alice.service, passKey: "macaaaaa.p6").run(owner: alice.owner)
        #expect(try await alice.service.list().count == 1)
        #expect(try alice.store.replica.engineState(TeamToSpace.journal(Self.teamID)) == Data("done".utf8))
    }

    // MARK: A space the library's move left behind

    private static func isOwed(_ mac: S.Mac) async throws -> Bool {
        try await mac.device.local.perform { try TeamToSpace.isOwed(teamID: teamID, in: $0) }
    }

    /// The personal root as if the library's zones were made `seconds` from now (an hour back: before the
    /// team's journal; an hour ahead: after it), with the same salt.
    private static func setLibraryMade(_ mac: S.Mac, seconds: TimeInterval) async throws {
        try await mac.device.local.perform { state in
            let replica = state.replica
            let personal = try #require(try replica.personalRoot())
            let made = SyncJSON(SyncTime.milliseconds(Date().addingTimeInterval(seconds)))
            try replica.upsertRecord(ReplicaRecord(
                zoneKey: PrivateSyncZones.libraryKey, recordName: SyncSchema.rootRecordName, recordType: SyncRecordType.zoneRoot.rawValue,
                wireID: "root", systemFields: nil,
                payload: try OutboxTestProjections.payload(.zoneRoot, "root", [
                    "kind": "personal", "salt": try #require(personal.envelope.fields["salt"]),
                    "saltID": try #require(personal.envelope.fields["saltID"]), "createdAt": made,
                ]),
                seenPass: nil
            ))
        }
    }

    /// SpaceSync's mark for a space the server no longer lists (`SpaceSync.spaceGone`).
    private static func markGone(_ mac: S.Mac) async throws {
        try await mac.device.local.perform { state in
            let mark = SyncJSON.object(["reason": .string("deleted"), "at": SyncJSON(SyncTime.milliseconds(Date()))]).serialized()
            try state.replica.setEngineState(SpaceSync.StateScope.gone(zoneKey), mark)
        }
    }

    @Test("A team's space that went when the library's zones were made anew is made again, and the team's rows go to it")
    func spaceLostWithTheLibraryIsMadeAgain() async throws {
        let server = EngineTestDriver.server()
        let (alice, _, others) = try await Self.ownerWithTeam(server)
        try await Self.setLibraryMade(alice, seconds: -3_600)
        let job = TeamToSpace(service: alice.service, passKey: "macaaaaa.p6")
        try await job.run(owner: alice.owner)
        #expect(try await Self.isOwed(alice) == false)

        // The library moves to a new container: its zones are made anew, later than the journal, the space is
        // not among them, and SpaceSync finds it gone. Nothing the team holds is sent while it stays so.
        server.deleteZone("Space-\(Self.teamID)", owner: "alice")
        try await Self.setLibraryMade(alice, seconds: 3_600)
        try await Self.markGone(alice)
        #expect(try await Self.isOwed(alice))

        let outcome = try await job.run(owner: alice.owner)
        #expect(outcome.spaces == [Self.teamID: Self.teamID], "the same space id: the team's rows already name it")
        #expect(server.storedRecord("root", zone: "Space-\(Self.teamID)", owner: "alice") != nil)
        #expect(server.recordNames(zone: "Space-\(Self.teamID)", owner: "alice").contains(CloudRecordID.zoneShareRecordName))
        #expect(try await alice.service.list().first?.gone == nil)
        #expect(try await Self.isOwed(alice) == false)

        try await alice.syncSpaces()
        let sourceName = RecordNaming.recordName(type: .source, id: others[0], salt: S.spaceSalt)
        #expect(server.storedRecord(sourceName, zone: "Space-\(Self.teamID)", owner: "alice") != nil, "the team's source reaches the new zone")

        // A second run finds the team done.
        #expect(try await job.run(owner: alice.owner) == TeamToSpace.Outcome())
    }

    @Test("A space that went while the library's zones stayed as they were was deleted on purpose and stays gone")
    func deletedSpaceStaysGone() async throws {
        let server = EngineTestDriver.server()
        let (alice, _, _) = try await Self.ownerWithTeam(server)
        try await Self.setLibraryMade(alice, seconds: -3_600)
        let job = TeamToSpace(service: alice.service, passKey: "macaaaaa.p6")
        try await job.run(owner: alice.owner)

        server.deleteZone("Space-\(Self.teamID)", owner: "alice")
        try await Self.markGone(alice)
        #expect(try await Self.isOwed(alice) == false)
        #expect(try await job.run(owner: alice.owner) == TeamToSpace.Outcome())
        #expect(server.storedRecord("root", zone: "Space-\(Self.teamID)", owner: "alice") == nil)
    }

    @Test("A remake that stops after the zone is made is resumed as an unfinished run")
    func interruptedRemakeResumes() async throws {
        let server = EngineTestDriver.server()
        let (alice, _, _) = try await Self.ownerWithTeam(server)
        try await Self.setLibraryMade(alice, seconds: -3_600)
        let job = TeamToSpace(service: alice.service, passKey: "macaaaaa.p6")
        try await job.run(owner: alice.owner)
        server.deleteZone("Space-\(Self.teamID)", owner: "alice")
        try await Self.setLibraryMade(alice, seconds: 3_600)
        try await Self.markGone(alice)

        // The run made the zone and its root, then stopped before the share: the journal was dropped first.
        try await alice.device.local.perform { try $0.replica.setEngineState(TeamToSpace.journal(Self.teamID), nil) }
        _ = try await alice.service.create(kind: "team", name: "Mito lab", owner: alice.owner, spaceID: Self.teamID, share: false)
        #expect(try await alice.service.list().first?.gone == nil)
        #expect(try await Self.isOwed(alice), "no journal: the share and the journal are still to do")

        try await job.run(owner: alice.owner)
        #expect(server.recordNames(zone: "Space-\(Self.teamID)", owner: "alice").contains(CloudRecordID.zoneShareRecordName))
        #expect(try await Self.isOwed(alice) == false)
    }

    @Test("A converted team's files go into its space's own zone, once; the personal seed leaves them alone")
    func teamFilesGoIntoTheSpace() async throws {
        let server = EngineTestDriver.server()
        let (alice, _, _) = try await Self.ownerWithTeam(server)
        try await TeamToSpace(service: alice.service, passKey: "macaaaaa.p6").run(owner: alice.owner)

        // Each team copy has its text laid out as the publisher leaves it: a pointer with no path, the body in its rows.
        var files: [FileRef] = []
        for index in 0..<3 {
            let id = "src-team-\(index)"
            let wire = try #require(try alice.device.text("SELECT wire_id FROM sources WHERE id = ?", [.text(id)]))
            let body = "Body of \(id). " + String(repeating: "word ", count: 40)
            try alice.store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text(id), .text(body)])
            let satellite = SourceLocalSatellite(map: .files, role: "text", mime: "text/plain", encoding: .gzip, body: Data(body.utf8), localPath: nil, input: nil)
            let (file, _) = try SourceSatelliteLayout.layout(satellite, owner: wire)
            try alice.store.execute("INSERT INTO source_files (source_id, role, file_ref, local_path) VALUES (?, 'text', ?, NULL)", [.text(id), .text(ArtifactBody.text(file))])
            files.append(file)
        }

        let satellites = CutoverSatellites(store: alice.device.local, blobs: CutoverSeedFixture.blobs(alice.device), pendingCount: { 0 })
        #expect(try satellites.satellites(in: alice.store).isEmpty, "the personal library's seed holds none of the team's copies")
        #expect(try satellites.satellites(in: alice.store, teamID: Self.teamID).count == 3)

        let zone = "Space-\(Self.teamID)"
        let totals = try await satellites.restoreMissing(inSpace: Self.zoneKey, teamID: Self.teamID)
        #expect(totals?.satellites == 3)
        for file in files {
            for id in file.satelliteIDs {
                let name = RecordNaming.recordName(type: .content, id: id, salt: S.spaceSalt)
                #expect(server.storedRecord(name, zone: zone, owner: "alice") != nil, "\(id) is in the space's zone")
            }
        }
        #expect(try await satellites.restoreMissing(inSpace: Self.zoneKey, teamID: Self.teamID) == nil, "once per space")
    }

    @Test("A member's identities move from the old container's owner name to the space as the library container names it")
    func memberRehomes() throws {
        let (root, store) = try F.makeStore("team-member")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try S.addTeam(store, Self.teamID, role: "member", ownerRecordName: "_oldAlice")
        try S.addTeamSource(store, "src-team-0", teamID: Self.teamID, url: "https://example.org/a")
        let old = try #require(try store.teamZoneKeys()[Self.teamID])
        #expect(old == "shared/_oldAlice/Space-\(Self.teamID)")
        try SpaceRows.adopt(teamID: Self.teamID, zoneKey: old, connection: store)
        let zone = try S.holdSpace(store, spaceID: Self.teamID, owner: "_alice")

        try SpaceRows.rehome(from: old, to: zone, connection: store)
        try store.execute("UPDATE teams SET zone_name = ?, zone_owner_record_name = '_alice' WHERE id = ?", [.text("Space-\(Self.teamID)"), .text(Self.teamID)])
        #expect(try store.teamZoneKeys()[Self.teamID] == zone)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_identity WHERE zone_key = ?", [.text(old)]) == 0)
        #expect(try F.text(store, "SELECT local_id FROM ck_identity WHERE zone_key = ? AND record_type = 'Source'", [.text(zone)]) == "src-team-0")

        // The space's Source lands on the member's team copy, never beside it.
        let wire = try #require(try F.text(store, "SELECT wire_id FROM sources WHERE id = 'src-team-0'"))
        try F.apply(store, [try S.sourceRecord(wire, url: "https://example.org/a", zoneKey: zone)])
        #expect(try F.count(store, "SELECT COUNT(*) FROM sources WHERE team_id = ?", [.text(Self.teamID)]) == 1)
    }

    @Test("A joined team found in the shared database is adopted before its walk: its row and identities name the space")
    func adoptJoinedTeamBeforeWalk() async throws {
        let server = EngineTestDriver.server()
        let bob = try await S.Mac(server, name: "team-bob", deviceID: "macbbbbb", user: "bob")
        try S.addTeam(bob.store, Self.teamID, role: "member", ownerRecordName: "_oldAlice")
        try S.addTeamSource(bob.store, "src-team-0", teamID: Self.teamID, url: "https://example.org/a")
        try SpaceRows.adopt(teamID: Self.teamID, zoneKey: "shared/_oldAlice/Space-\(Self.teamID)", connection: bob.store)
        try S.holdSpace(bob.store, spaceID: Self.teamID, owner: "alice")
        try await bob.service.adoptJoinedTeams()
        #expect(try bob.device.text("SELECT zone_scope || ':' || zone_owner_record_name || ':' || zone_name FROM teams WHERE id = ?", [.text(Self.teamID)])
                == "shared:alice:Space-\(Self.teamID)")
        #expect(try bob.device.count("SELECT COUNT(*) FROM ck_identity WHERE zone_key = ?", [.text("shared/alice/Space-\(Self.teamID)")]) == 1)
    }

    @Test("Under generation 1 a team's pool write records no identity and queues nothing")
    func generationOneWritesNothing() throws {
        let (root, store) = try F.makeStore("team-gen1", generation: .one)
        defer { try? FileManager.default.removeItem(at: root) }
        try S.addTeam(store, Self.teamID)
        try F.addNotebook(store, "nb-team", classify: false)
        try store.execute("UPDATE learning_goals SET team_id = ? WHERE id = 'nb-team'", [.text(Self.teamID)])
        try S.addTeamSource(store, "src-team-0", teamID: Self.teamID, url: "https://example.org/a")
        try F.file(store, "src-team-0", into: "nb-team")
        try store.keepNotebookRowsForGeneration2(goalIDs: ["nb-team"])
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_identity") == 0)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_outbox") == 0)
        #expect(try F.text(store, "SELECT wire_id FROM sources WHERE id = 'src-team-0'") == nil)
    }
}
