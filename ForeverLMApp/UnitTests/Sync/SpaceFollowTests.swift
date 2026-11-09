import Foundation
import Testing
@testable import ForeverLM

/// A space's follow of a Collection, the one space Setting (docs/cloudkit-schema-design.md §3.5.3, §3.5.5,
/// §9.9, PD-15): `follow.<collectionID>` = `{autoImport, runnerDeviceID}` in the space's zone, kept on the
/// Mac as a `user_preferences` row that no preference writer touches. It is sent into the space and never
/// into `Library`, an inbound one lands on the same row, a cleared one reaches the space as a `null`, a
/// space that goes takes its follows, and only a member who may write, in a space that stands, with a
/// Collection that has a feed, can make one. Copying a followed Collection into a space follows nothing.
@Suite("Space follow")
struct SpaceFollowTests {
    typealias S = SpaceTestFixture
    typealias F = NotebookSyncFixture

    static let spaceZone = "private/Space-s1"

    static func dictionary(autoImport: Bool, runner: String?) -> SyncJSON {
        var value: [String: SyncJSON] = ["autoImport": .bool(autoImport)]
        if let runner { value["runnerDeviceID"] = .string(runner) }
        return .object(["t": .string("dict"), "v": .object(value)])
    }

    /// A Collection the space's replica holds, as a member's device sent it.
    static func holdCollection(_ store: KnowledgeStore, _ id: String, kind: String = "podcastShow", zoneKey: String = spaceZone) throws {
        try store.replica.upsertRecord(try S.record(.collection, id, [
            "kind": .string(kind), "externalKey": .string("show-\(id)"), "title": .string("Show \(id)"), "status": .string("active"),
            "addedAt": SyncJSON(Int64(1_759_000_000_000)),
        ], zoneKey: zoneKey))
    }

    /// A store holding the owned space `s1` with the podcast show `col_a`.
    static func ownedSpace(_ name: String) throws -> (root: URL, store: KnowledgeStore) {
        let (root, store) = try F.makeStore(name)
        try F.prepareReplica(store)
        try S.holdSpace(store, spaceID: "s1")
        try holdCollection(store, "col_a")
        return (root, store)
    }

    /// A synced preference as the app writes one: its row, typed as `PreferenceStore` stores it.
    static func writePreference(_ store: KnowledgeStore, _ key: String, _ value: Any) throws {
        try store.execute("""
            INSERT INTO user_preferences (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
        """, [.text(key), .text(try #require(PreferenceStore.encodePlist(value))), .real(Date().timeIntervalSinceReferenceDate)])
    }

    /// Every Setting the feeder would send now, by wire id.
    static func settings(_ store: KnowledgeStore) throws -> [String: OutboxChange] {
        try F.pending(store).filter { $0.value.recordType == .setting }.reduce(into: [:]) { $0[$1.value.wireID] = $1.value }
    }

    @Test("The two spellings of a follow's key round trip, and the local one is no preference and no personal Setting")
    func keyForms() {
        #expect(SpaceFollowKey.wireKey(collectionID: "col_a") == "follow.col_a")
        #expect(SpaceFollowKey.collectionID(wireKey: "follow.col_a") == "col_a")
        #expect(SpaceFollowKey.collectionID(wireKey: "follow.") == nil && SpaceFollowKey.collectionID(wireKey: "uiZoomStep") == nil)
        let local = SpaceFollowKey.localKey(spaceID: "s1", collectionID: "col_a")
        #expect(local == "space.s1.follow.col_a")
        let parsed = SpaceFollowKey.parse(localKey: local)
        #expect(parsed?.spaceID == "s1" && parsed?.collectionID == "col_a")
        let dotted = SpaceFollowKey.parse(localKey: SpaceFollowKey.localKey(spaceID: "s1", collectionID: "col.follow.x"))
        #expect(dotted?.spaceID == "s1" && dotted?.collectionID == "col.follow.x", "the first marker after the space id splits the key")
        for key in ["space..follow.c", "space.s1.follow.", "space.s1", "uiZoomStep", "follow.col_a"] {
            #expect(SpaceFollowKey.parse(localKey: key) == nil, "\(key)")
        }
        #expect(!SyncedPreferenceKeys.isSynced(local), "no preference writer ever reads or writes it")
        #expect(!SyncedPreferenceKeys.isSetting(local) && !SyncedPreferenceKeys.isSetting("follow.col_a"), "it is no Setting of the account")
    }

    @Test("A follow is sent into its space as follow.<collection>, typed, and nothing of it goes into Library")
    func followIsSentIntoTheSpace() throws {
        let (root, store) = try Self.ownedSpace("follow-send")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePreference(store, "readerOriginalPageColors", true)
        try store.setSpaceFollow(spaceID: "s1", collectionID: "col_a", autoImport: true, runnerDeviceID: "macaaaaa")

        let sent = try Self.settings(store)
        let follow = try #require(sent["follow.col_a"])
        #expect(follow.zone == .space("s1") && follow.zoneKey == Self.spaceZone)
        let fields = try #require(F.savedFields(follow))
        #expect(fields["key"] == .string("follow.col_a"))
        #expect(fields["value"] == Self.dictionary(autoImport: true, runner: "macaaaaa"))
        #expect(sent["readerOriginalPageColors"]?.zone == .library, "an account Setting still goes to Library")
        #expect(sent.keys.filter { $0.hasPrefix("space.") }.isEmpty, "the local key is never a record's id")
        let held = try #require(try store.spaceFollows().first)
        #expect(held.spaceID == "s1" && held.collectionID == "col_a" && held.autoImport && held.runnerDeviceID == "macaaaaa")

        // Acknowledged, an unchanged follow sends nothing; a changed runner sends the new value only.
        try F.sendAll(store)
        #expect(try Self.settings(store)["follow.col_a"] == nil)
        try store.setSpaceFollow(spaceID: "s1", collectionID: "col_a", autoImport: true, runnerDeviceID: "macbbbbb")
        let changed = try #require(F.savedFields(try Self.settings(store)["follow.col_a"]))
        #expect(changed["value"] == Self.dictionary(autoImport: true, runner: "macbbbbb"))
    }

    @Test("Ending a follow sends null into the space, never a delete, and a later follow writes the same record again")
    func clearingSendsNull() throws {
        let (root, store) = try Self.ownedSpace("follow-clear")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.setSpaceFollow(spaceID: "s1", collectionID: "col_a", autoImport: true, runnerDeviceID: "macaaaaa")
        try F.sendAll(store)

        try store.clearSpaceFollow(spaceID: "s1", collectionID: "col_a")
        #expect(try store.spaceFollows().isEmpty)
        let cleared = try #require(try Self.settings(store)["follow.col_a"])
        guard case .save(let envelope) = cleared.action else { Issue.record("a cleared Setting is saved, not deleted"); return }
        #expect(envelope.fields["value"] == .null && cleared.zone == .space("s1"))
        try F.sendAll(store)

        try store.setSpaceFollow(spaceID: "s1", collectionID: "col_a", autoImport: false, runnerDeviceID: nil)
        let again = try #require(try Self.settings(store)["follow.col_a"])
        #expect(F.savedFields(again)?["value"] == Self.dictionary(autoImport: false, runner: nil))
        #expect(again.recordName == cleared.recordName, "one record for the follow, whatever happens to it")

        // A follow never made sends no null.
        try store.clearSpaceFollow(spaceID: "s1", collectionID: "col_b")
        #expect(try Self.settings(store)["follow.col_b"] == nil)
    }

    @Test("An inbound follow writes its row and identity under the guard and echoes nothing; an inbound null removes the row")
    func inboundFollow() throws {
        let (root, store) = try F.makeStore("follow-inbound")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let zone = try S.holdSpace(store, spaceID: "s1", owner: "_alice")
        try F.apply(store, [try S.record(.setting, "follow.col_a", [
            "key": .string("follow.col_a"), "value": Self.dictionary(autoImport: true, runner: "macbbbbb"), "editedAt": SyncJSON(Int64(1_759_500_000_000)),
        ], zoneKey: zone)])
        let follow = try #require(try store.spaceFollows(spaceID: "s1").first)
        #expect(follow.collectionID == "col_a" && follow.autoImport && follow.runnerDeviceID == "macbbbbb")
        #expect(follow.updatedAt == Date(timeIntervalSinceReferenceDate: SyncTime.cocoaSeconds(milliseconds: 1_759_500_000_000)))
        #expect(try F.text(store, "SELECT local_id FROM ck_identity WHERE zone_key = ? AND record_type = 'Setting' AND wire_id = 'follow.col_a'", [.text(zone)])
                == "space.s1.follow.col_a")
        #expect(try Self.settings(store).isEmpty, "an apply sends nothing back")
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_outbox") == 0)

        // Another member's later change, then its removal.
        try F.apply(store, [try S.record(.setting, "follow.col_a", [
            "key": .string("follow.col_a"), "value": Self.dictionary(autoImport: false, runner: nil),
        ], zoneKey: zone, ms: 1_759_600_000_000)])
        #expect(try store.spaceFollows().first?.autoImport == false && store.spaceFollows().first?.runnerDeviceID == nil)
        try F.apply(store, [try S.record(.setting, "follow.col_a", ["key": .string("follow.col_a"), "value": .null], zoneKey: zone, ms: 1_759_700_000_000)])
        #expect(try store.spaceFollows().isEmpty)
        #expect(try F.count(store, "SELECT COUNT(*) FROM user_preferences WHERE key LIKE 'space.%'") == 0)
        #expect(try Self.settings(store).isEmpty)
    }

    @Test("A space's Setting this Mac does not model, or a follow of the wrong type, writes nothing and stays in the replica")
    func inboundSettingsItDoesNotModel() throws {
        let (root, store) = try F.makeStore("follow-other")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        let zone = try S.holdSpace(store, spaceID: "s1", owner: "_alice")
        try F.apply(store, [
            try S.record(.setting, "uiZoomStep", ["key": .string("uiZoomStep"), "value": .object(["t": .string("int"), "v": SyncJSON(3)])], zoneKey: zone),
            try S.record(.setting, "follow.col_a", ["key": .string("follow.col_a"), "value": .object(["t": .string("string"), "v": .string("yes")])], zoneKey: zone),
            try S.record(.setting, "follow.", ["key": .string("follow."), "value": Self.dictionary(autoImport: true, runner: nil)], zoneKey: zone),
        ])
        #expect(try F.count(store, "SELECT COUNT(*) FROM user_preferences") == 0, "no row, not even a personal uiZoomStep")
        #expect(try store.replica.record(zoneKey: zone, recordType: "Setting", wireID: "uiZoomStep") != nil, "the record is kept as it arrived")

        // A Collection holds no follow of its own: following is a Mark, and a space's is this Setting.
        #expect(SyncRecordType.collection.spec.field("follow") == nil, "copying a followed Collection into a space carries no follow")
        #expect(try store.spaceFollows().isEmpty)
    }

    @Test("A follow row nothing has placed in a space is sent nowhere, never into Library")
    func unplacedRowSendsNothing() throws {
        let (root, store) = try Self.ownedSpace("follow-unplaced")
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = try #require(PreferenceStore.encodePlist(SpaceFollows.plist(autoImport: true, runnerDeviceID: "macaaaaa")))
        try store.execute("INSERT INTO user_preferences (key, value, updated_at) VALUES ('space.s1.follow.col_a', ?, 1)", [.text(xml)])
        #expect(try Self.settings(store).isEmpty)
        try store.execute("DELETE FROM user_preferences WHERE key = 'space.s1.follow.col_a'")
        #expect(try Self.settings(store).isEmpty)
    }

    @Test("A follow is refused without a held space, in a gone one, for a reader, without the Collection, or without a feed, and under generation 1")
    func refusals() throws {
        let (root, store) = try Self.ownedSpace("follow-refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        func follow(_ spaceID: String = "s1", _ collectionID: String = "col_a", in target: KnowledgeStore? = nil) throws {
            try (target ?? store).setSpaceFollow(spaceID: spaceID, collectionID: collectionID, autoImport: true, runnerDeviceID: "macaaaaa")
        }
        #expect(throws: SpaceFollowError.unknownSpace) { try follow("s404") }
        #expect(throws: SpaceFollowError.unknownCollection) { try follow("s1", "col_missing") }
        try Self.holdCollection(store, "col_book", kind: "book")
        #expect(throws: SpaceFollowError.notFollowable("book")) { try follow("s1", "col_book") }
        for kind in ["youtubeChannel", "playlist"] {
            try Self.holdCollection(store, "col_\(kind)", kind: kind)
            try follow("s1", "col_\(kind)")
        }
        #expect(try store.spaceFollows().count == 2)
        #expect(throws: SpaceFollowError.unknownSpace) { try store.clearSpaceFollow(spaceID: "s404", collectionID: "col_a") }

        let readerZone = try S.holdSpace(store, spaceID: "s2", owner: "_alice", permission: "readOnly")
        try Self.holdCollection(store, "col_a", zoneKey: readerZone)
        #expect(throws: SpaceFollowError.readOnly) { try follow("s2") }
        #expect(throws: SpaceFollowError.readOnly) { try store.clearSpaceFollow(spaceID: "s2", collectionID: "col_a") }
        let writerZone = try S.holdSpace(store, spaceID: "s3", owner: "_alice", permission: "readWrite")
        try Self.holdCollection(store, "col_a", zoneKey: writerZone)
        try follow("s3")

        try store.replica.setEngineState(SpaceSync.StateScope.gone(writerZone), Data(#"{"reason":"left","at":1759000000000}"#.utf8))
        #expect(throws: SpaceFollowError.spaceGone) { try follow("s3") }
        #expect(throws: SpaceFollowError.spaceGone) { try store.clearSpaceFollow(spaceID: "s3", collectionID: "col_a") }
    }

    @Test("A Mac runs the follows that import and name it, in spaces that have not gone")
    func followsAMacRuns() throws {
        let (root, store) = try Self.ownedSpace("follow-running")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.holdCollection(store, "col_b", kind: "playlist")
        try Self.holdCollection(store, "col_c", kind: "youtubeChannel")
        try store.setSpaceFollow(spaceID: "s1", collectionID: "col_a", autoImport: true, runnerDeviceID: "macaaaaa")
        try store.setSpaceFollow(spaceID: "s1", collectionID: "col_b", autoImport: false, runnerDeviceID: "macaaaaa")
        try store.setSpaceFollow(spaceID: "s1", collectionID: "col_c", autoImport: true, runnerDeviceID: "macbbbbb")
        let goneZone = try S.holdSpace(store, spaceID: "s2", owner: "_alice")
        try F.apply(store, [try S.record(.setting, "follow.col_d", ["key": .string("follow.col_d"), "value": Self.dictionary(autoImport: true, runner: "macaaaaa")], zoneKey: goneZone)])

        #expect(try store.spaceFollowsRunning(onDevice: "macaaaaa").map(\.collectionID).sorted() == ["col_a", "col_d"])
        #expect(try store.spaceFollowsRunning(onDevice: "macbbbbb").map(\.collectionID) == ["col_c"])
        #expect(try store.spaceFollowsRunning(onDevice: "macccccc").isEmpty)
        try store.replica.setEngineState(SpaceSync.StateScope.gone(goneZone), Data(#"{"reason":"deleted","at":1759000000000}"#.utf8))
        #expect(try store.spaceFollowsRunning(onDevice: "macaaaaa").map(\.collectionID) == ["col_a"], "a gone space refreshes nothing")
        #expect(try store.spaceFollows().count == 4, "its rows stay while the learner may keep a copy")
    }

    @Test("Two members' Macs: one's follow reaches the other's rows, whose runner is not this Mac")
    func followTravelsToAnotherMember() throws {
        let (aliceRoot, alice) = try Self.ownedSpace("follow-alice")
        defer { try? FileManager.default.removeItem(at: aliceRoot) }
        try alice.setSpaceFollow(spaceID: "s1", collectionID: "col_a", autoImport: true, runnerDeviceID: "macaaaaa")
        let sent = try #require(try Self.settings(alice)["follow.col_a"])
        guard case .save(let envelope) = sent.action else { Issue.record("a follow is saved"); return }

        // Bob's Mac receives exactly the record Alice's feeder built, as the server holds it.
        let (bobRoot, bob) = try F.makeStore("follow-bob")
        defer { try? FileManager.default.removeItem(at: bobRoot) }
        try F.prepareReplica(bob)
        let bobZone = try S.holdSpace(bob, spaceID: "s1", owner: "_alice")
        try F.apply(bob, [ReplicaRecord(
            zoneKey: bobZone, recordName: sent.recordName, recordType: "Setting", wireID: "follow.col_a", systemFields: Data([1]),
            payload: try envelope.storedPayload(), seenPass: nil
        )])
        let received = try #require(try bob.spaceFollows().first)
        #expect(received.runnerDeviceID == "macaaaaa" && received.autoImport)
        #expect(try bob.spaceFollowsRunning(onDevice: "macbbbbb").isEmpty, "naming one Mac makes every other member's Mac run nothing")
        #expect(try bob.spaceFollowsRunning(onDevice: "macaaaaa").count == 1)
    }
}

/// The follows of a space that goes: kept while the learner may keep a copy, removed with the space.
@Suite("Space follow of a space that goes")
struct SpaceFollowGoneTests {
    typealias S = SpaceTestFixture
    typealias F = NotebookSyncFixture

    @Test("A space that is purged takes its follows; another space's and the account's Settings stay")
    func purgingASpaceTakesItsFollows() async throws {
        let server = EngineTestDriver.server()
        let alice = try await S.Mac(server, name: "follow-purge", deviceID: "macaaaaa", user: "alice")
        let store = alice.store
        let gone = try S.holdSpace(store, spaceID: "s9", owner: "_bob")
        let kept = try S.holdSpace(store, spaceID: "s8", owner: "_bob")
        try F.apply(store, [
            try S.record(.setting, "follow.col_a", ["key": .string("follow.col_a"), "value": SpaceFollowTests.dictionary(autoImport: true, runner: "macbbbbb")], zoneKey: gone),
            try S.record(.setting, "follow.col_a", ["key": .string("follow.col_a"), "value": SpaceFollowTests.dictionary(autoImport: true, runner: "macbbbbb")], zoneKey: kept),
        ])
        try SpaceFollowTests.writePreference(store, "uiZoomStep", 2)
        #expect(try store.spaceFollows().count == 2)
        // The account's own write is unsent and stays pending; the purge adds nothing to it.
        let pending = try SpaceFollowTests.settings(store).keys.sorted()
        #expect(pending == ["uiZoomStep"], "\(pending)")

        try await alice.spaces.spaceGone(SpaceZone(CloudZoneID("Space-s9", ownerName: "_bob"), in: .shared), reason: "deleted")
        #expect(try store.spaceFollows().count == 2, "kept hidden while the learner may keep a copy")
        alice.service.now = { Date().addingTimeInterval(31 * 86_400) }
        #expect(try await alice.service.purgeExpired() == 1)
        #expect(try store.spaceFollows().map { $0.spaceID } == ["s8"])
        #expect(try F.count(store, "SELECT COUNT(*) FROM user_preferences WHERE key = 'uiZoomStep'") == 1)
        #expect(try F.count(store, "SELECT COUNT(*) FROM ck_identity WHERE zone_key = ? AND record_type = 'Setting'", [.text(gone)]) == 0)
        #expect(try SpaceFollowTests.settings(store).keys.sorted() == pending, "a purge sends nothing")
    }
}
