import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// Spaces on the Mac (docs/cloudkit-schema-design.md §2.2, §2.4, §2.5, §4.3, §9.1, §9.4, §9.6, WP15): a
/// space is made as a zone, a root by compare-and-set create and a zone-wide share; its records notebook
/// onto local rows under their wire ids; a light client's capture into a space notebook is copied into
/// the space and filed there; a space that went stays hidden for 30 days and is then purged.
@Suite("Space service", .serialized)
struct SpaceServiceTests {
    typealias S = SpaceTestFixture
    typealias F = NotebookSyncFixture
    typealias J = JobSyncFixture

    /// What the feeder would send into the space `zoneKey` now, by `<type>:<wire id>`.
    static func inSpace(_ store: KnowledgeStore, _ zoneKey: String) throws -> [String: OutboxChange] {
        let changes = try OutboxFeeder(connection: store, registry: F.registry).pendingChanges(now: Date().addingTimeInterval(60)).filter { $0.zoneKey == zoneKey }
        return Dictionary(changes.map { ("\($0.recordType.rawValue):\($0.wireID)", $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("A team space: zone, root with kind, salt and owner, the zone-wide share, a teams row, and the list says so")
    func createTeamSpace() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "space-alice", deviceID: "macaaaaa", user: "alice")
        let space = try await alice.service.create(kind: "team", name: "Mito lab", owner: alice.owner, spaceID: "s1")

        let root = try SyncEnvelope(storedPayload: try #require(server.storedRecord("root", zone: "Space-s1", owner: "alice")?.payload))
        #expect(root.fields["kind"] == .string("team") && root.fields["name"] == .string("Mito lab"))
        #expect(root.fields["saltID"] == .string(S.spaceSaltID) && root.saltID == S.spaceSaltID)
        #expect(root.fields["owner"].flatMap(SyncPerson.init(json:))?.user == "alice")
        #expect(server.recordNames(zone: "Space-s1", owner: "alice").contains(CloudRecordID.zoneShareRecordName), "shared zone-wide")

        let row = try #require(try alice.store.replica.zone(key: "private/Space-s1"))
        #expect(row.kind == "space" && row.role == "owner" && row.saltID == S.spaceSaltID && row.shareRecordName != nil)
        #expect(space.kind == "team" && space.isOwned && space.isShared && space.localTeamID == "s1" && space.gone == nil)
        #expect(try alice.device.text("SELECT name || ':' || role || ':' || zone_name FROM teams WHERE id = 's1'") == "Mito lab:owner:Space-s1")
        #expect(try await alice.service.list().map(\.spaceID) == ["s1"])
    }

    @Test("A root another device saved first is adopted when it is the same kind, and refused when it is another")
    func rootRaceAdopts() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "space-race", deviceID: "macaaaaa", user: "alice")
        _ = try await alice.service.create(kind: "team", name: "Lab", owner: alice.owner, spaceID: "s1", share: false)
        // A second Mac of the owner makes the same space with another salt: the first root stands.
        let second = try await S.Mac(server, name: "space-race-2", deviceID: "macbbbbb", user: "alice", holdsLibrary: false)
        second.service.makeSalt = { Data(repeating: 9, count: 32) }
        let adopted = try await second.service.create(kind: "team", name: "Lab", owner: second.owner, spaceID: "s1", share: false)
        #expect(adopted.kind == "team")
        #expect(try second.store.replica.zone(key: "private/Space-s1")?.saltID == S.spaceSaltID, "the first salt names the space")

        await #expect(throws: SpaceServiceError.self) {
            try await second.service.create(kind: "notebook", name: "Other", owner: second.owner, primaryID: "nb-1", spaceID: "s1", share: false)
        }
    }

    @Test("A share that cannot be saved takes the space back out, and nothing of it stays on the Mac")
    func failedShareTakesTheZoneBack() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "space-noshare", deviceID: "macaaaaa", user: "alice")
        server.failNext(.saveShare, with: CloudError(.serverRejectedRequest, message: "no cloudkit.share type"))
        await #expect(throws: SpaceServiceError.self) {
            try await alice.service.create(kind: "team", name: "Lab", owner: alice.owner, spaceID: "s1")
        }
        #expect(!(try await alice.device.transport.allZones(in: .private)).contains(CloudZoneID("Space-s1")))
        #expect(try alice.device.count("SELECT COUNT(*) FROM ck_zones WHERE zone_key = 'private/Space-s1'") == 0)
        #expect(try alice.device.count("SELECT COUNT(*) FROM teams") == 0)
        #expect(try await alice.service.list().isEmpty)
    }

    @Test("A share that fails over a root another device made leaves that device's zone alone, and a stopped request's unshared space is shared on resume (F15)")
    func failedShareOverAnAdoptedRoot() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "space-adopt-a", deviceID: "macaaaaa", user: "alice")
        _ = try await alice.service.create(kind: "team", name: "Lab", owner: alice.owner, spaceID: "s1", share: false)
        let second = try await S.Mac(server, name: "space-adopt-b", deviceID: "macbbbbb", user: "alice", holdsLibrary: false)
        server.failNext(.saveShare, with: CloudError(.serverRejectedRequest, message: "no cloudkit.share type"))
        await #expect(throws: SpaceServiceError.self) {
            try await second.service.create(kind: "team", name: "Lab", owner: second.owner, spaceID: "s1")
        }
        #expect((try await alice.device.transport.allZones(in: .private)).contains(CloudZoneID("Space-s1")), "the zone is the first device's")

        // The space is held and not shared; a resumed request shares it instead of leaving it private for ever.
        let held = try #require(try await second.service.list().first { $0.spaceID == "s1" })
        #expect(!held.isShared)
        try await second.service.ensureShared(spaceID: "s1", title: "Lab")
        #expect(try await second.service.list().first { $0.spaceID == "s1" }?.isShared == true)
    }

    @Test("Only the owner renames a space for everyone (F19)")
    func memberCannotRename() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "space-rename", deviceID: "macaaaaa", user: "alice")
        let space = try await alice.service.create(kind: "team", name: "Lab", owner: alice.owner, spaceID: "s1")
        let joined = SpaceSummary(
            zone: SpaceZone(CloudZoneID("Space-s1", ownerName: "alice"), in: .shared), spaceID: "s1", kind: space.kind, name: space.name, primaryID: nil,
            permission: .readWrite, isShared: true, ownerName: "alice", localTeamID: "s1", gone: nil
        )
        await #expect(throws: SpaceServiceError.notOwner) { try await alice.service.rename(joined, to: "Taken over") }
        try await alice.service.rename(space, to: "Mito lab")
        let root = try SyncEnvelope(storedPayload: try #require(server.storedRecord("root", zone: "Space-s1", owner: "alice")?.payload))
        #expect(root.fields["name"] == .string("Mito lab"))
    }

    @Test("Owned spaces warn from 100 and refuse a 251st")
    func room() async throws {
        #expect(SpaceService.room(owned: 99) == .fine)
        #expect(SpaceService.room(owned: 100) == .warn(100))
        #expect(SpaceService.room(owned: 249) == .warn(249))
        #expect(SpaceService.room(owned: 250) == .full(250))
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "space-room", deviceID: "macaaaaa", user: "alice")
        for index in 0..<250 { try S.holdSpace(alice.store, spaceID: "held-\(index)") }
        await #expect(throws: SpaceServiceError.tooManySpaces(250)) {
            try await alice.service.create(kind: "team", name: "One too many", owner: alice.owner)
        }
    }

    @Test("A space's notebook and its Entry land on the space's rows, and an approval edit goes back under wire ids")
    func spaceNotebookIsProjected() throws {
        let (root, store) = try F.makeStore("space-notebook")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let zone = try S.holdSpace(store, spaceID: "s1", owner: "_bob")
        let personal = try S.addPersonalSource(store, url: "https://example.org/a")
        // The Entry arrives before its source, and waits for it.
        try F.apply(store, [
            try S.record(.notebook, "nb-team", ["title": .string("Team notebook"), "status": .string("active")], zoneKey: zone),
            try S.record(.entry, SyncIdentity.entryID(containerID: "nb-team", itemKind: "source", itemID: personal), [
                "containerKind": .string("notebook"), "containerID": .string("nb-team"), "itemKind": .string("source"),
                "itemID": .string(personal), "state": .string("active"), "approval": .string("pending"), "orderKey": .string("a0"),
            ], zoneKey: zone),
        ])
        #expect(try F.text(store, "SELECT team_id || ':' || wire_id FROM learning_goals WHERE id = 'nb-team'") == "s1:nb-team")
        #expect(try F.count(store, "SELECT COUNT(*) FROM learning_goal_items WHERE goal_id = 'nb-team'") == 0)
        try F.apply(store, [try S.sourceRecord(personal, url: "https://example.org/a", zoneKey: zone)])

        let copy = SpaceLocalID.localID(spaceID: "s1", type: .source, wireID: personal)
        #expect(try F.text(store, "SELECT review_state FROM learning_goal_items WHERE goal_id = 'nb-team' AND source_id = ?", [.text(copy)]) == "pending",
                "the space's copy of the source, under its own local id, holds the item")
        #expect(try F.text(store, "SELECT team_id FROM sources WHERE id = ?", [.text(copy)]) == "s1")
        #expect(try F.text(store, "SELECT team_id FROM sources WHERE id = ?", [.text(personal)]) == nil, "the personal source is untouched")
        let afterApply = try Self.inSpace(store, zone)
        #expect(afterApply.isEmpty, "an apply sends nothing back: \(afterApply.mapValues { F.savedFields($0) ?? [:] })")

        try store.execute("UPDATE learning_goal_items SET review_state = 'approved' WHERE goal_id = 'nb-team'")
        try store.keepNotebookRowsForGeneration2(goalIDs: ["nb-team"])
        let entryID = SyncIdentity.entryID(containerID: "nb-team", itemKind: "source", itemID: personal)
        let change = try #require(try Self.inSpace(store, zone)["Entry:\(entryID)"], "into the space")
        #expect(F.savedFields(change)?["itemID"] == .string(personal) && F.savedFields(change)?["approval"] == .string("approved"))
    }

    @Test("A Job(ingestURL) whose target is a space notebook copies the Source into the space and files it there")
    func captureIntoSpaceNotebook() async throws {
        let (root, store) = try F.makeStore("space-job")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let zone = try S.holdSpace(store, spaceID: "s1", owner: "_bob")
        try F.apply(store, [try S.record(.notebook, "nb-team", ["title": .string("Team notebook"), "status": .string("active")], zoneKey: zone)])
        try store.execute("INSERT INTO notebook_resolution (id, resolved_id, resolved_zone) VALUES ('nb-team', 'nb-team', 'Space-s1') ON CONFLICT(id) DO NOTHING")
        let url = "https://example.org/shared-into-the-team"
        try F.apply(store, [try J.jobRecord("job-space", kind: "ingestURL", params: [
            "url": .string(url), "workKeys": .array([]),
            "target": .object(["notebookID": .string("nb-team"), "approval": .string("approved")]),
        ])])
        let runner = J.runner(store, work: FakeJobWork(store: store))
        #expect(await runner.pass() == [.claim("job-space")])
        try F.sendAll(store)
        #expect(await runner.pass() == [.start("job-space")])
        #expect(try await J.settled(store, "job-space") == "done")

        let personal = SourceIdentity.stableID(for: url)
        let copy = SpaceLocalID.localID(spaceID: "s1", type: .source, wireID: personal)
        #expect(try F.text(store, "SELECT team_id || ':' || wire_id FROM sources WHERE id = ?", [.text(copy)]) == "s1:\(personal)")
        #expect(try F.text(store, "SELECT review_state FROM learning_goal_items WHERE goal_id = 'nb-team' AND source_id = ?", [.text(copy)]) == "approved")
        let inSpace = try Self.inSpace(store, zone)
        #expect(inSpace["Source:\(personal)"] != nil, "the space's copy goes to the space under the source's id")
        let entry = try #require(inSpace["Entry:\(SyncIdentity.entryID(containerID: "nb-team", itemKind: "source", itemID: personal))"])
        #expect(F.savedFields(entry)?["approval"] == .string("approved"))
        #expect(F.savedFields(try F.pending(store)["Job:job-space"])?["result"]?["refs"] == .array([.string("src:\(personal)"), .string("nb:nb-team")]))
    }

    @Test("A team's notebook waits until its team is a space; once the space has its root, a capture files into it")
    func teamNotebookWaitsForItsSpace() async throws {
        let (root, store) = try F.makeStore("space-team-job")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try S.addTeam(store, "s1")
        try F.addNotebook(store, "nb-team")
        try store.execute("UPDATE learning_goals SET team_id = 's1' WHERE id = 'nb-team'")
        try store.recordIdentity(zoneKey: "private/Space-s1", recordType: "Notebook", wireID: "nb-team", localID: "nb-team")
        let target = SyncJSON.object(["notebookID": .string("nb-team"), "approval": .string("approved")])
        try F.apply(store, [try J.jobRecord("job-team", kind: "ingestURL", params: ["url": .string("https://example.org/t"), "target": target])])
        let job = try #require(try JobRow.load("job-team", connection: store))
        #expect(try MacJobRunner.filing(job, store: store) == .waits)
        try S.holdSpace(store, spaceID: "s1")
        #expect(try MacJobRunner.filing(job, store: store) == .intoSpace(notebookID: "nb-team", localID: "nb-team", spaceID: "s1", approval: "approved"))
    }

    @Test("A space that went stays hidden for 30 days, then its rows go; a deleted space goes at once")
    func goneSpaces() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "space-gone", deviceID: "macaaaaa", user: "alice")
        let zone = try S.holdSpace(alice.store, spaceID: "s9", owner: "_bob")
        try S.addTeamSource(alice.store, "src-team", teamID: "s9", url: "https://example.org/t")
        try await alice.spaces.spaceGone(SpaceZone(CloudZoneID("Space-s9", ownerName: "_bob"), in: .shared), reason: "left")
        #expect(try await alice.service.hiddenTeamIDs() == ["s9"])
        #expect(try await alice.service.purgeExpired() == 0, "kept while the learner may still keep a copy")
        #expect(try alice.device.count("SELECT COUNT(*) FROM sources WHERE team_id = 's9'") == 1)

        alice.service.now = { Date().addingTimeInterval(31 * 86_400) }
        #expect(try await alice.service.purgeExpired() == 1)
        #expect(try alice.device.count("SELECT COUNT(*) FROM sources WHERE team_id = 's9'") == 0)
        #expect(try alice.device.count("SELECT COUNT(*) FROM ck_zones WHERE zone_key = ?", [.text(zone)]) == 0)
        #expect(try alice.device.count("SELECT COUNT(*) FROM ck_identity WHERE zone_key = ?", [.text(zone)]) == 0)

        alice.service.now = { Date() }
        let owned = try await alice.service.create(kind: "team", name: "Lab", owner: alice.owner, spaceID: "s2", share: false)
        #expect(try await alice.service.counts(owned)["sources"] == 0)
        try await alice.service.delete(owned)
        #expect(!(try await alice.device.transport.allZones(in: .private)).contains(CloudZoneID("Space-s2")))
        #expect(try await alice.service.list().allSatisfy { $0.spaceID != "s2" })
        #expect(try alice.device.count("SELECT COUNT(*) FROM teams WHERE id = 's2'") == 0)
    }

    @Test("A rename and a family's plan code go into the root by compare-and-set, and the teams row follows")
    func rootEdits() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "space-root", deviceID: "macaaaaa", user: "alice")
        let space = try await alice.service.create(kind: "team", name: "Lab", owner: alice.owner, spaceID: "s1")
        try await alice.service.rename(space, to: "Mito lab")
        let renamed = try #require(try await alice.service.list().first)
        try await alice.service.setFamilyPlanCode(renamed, "fam-123")
        let root = try SyncEnvelope(storedPayload: try #require(server.storedRecord("root", zone: "Space-s1", owner: "alice")?.payload))
        #expect(root.fields["name"] == .string("Mito lab") && root.fields["kind"] == .string("family") && root.fields["familyPlanCode"] == .string("fam-123"))
        #expect(try alice.device.text("SELECT name || ':' || family_plan_code FROM teams WHERE id = 's1'") == "Mito lab:fam-123")
        try await alice.service.setDownloadsAllFiles(renamed, true)
        #expect(try await alice.service.downloadsAllFiles(renamed))
    }
}
