import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// A space's zone-wide share (docs/cloudkit-schema-design.md §2.4, §2.5, §9.1, §9.2, §9.6), on Macs
/// with the test course projection and FakeCloudKit: the owner shares and invites, a member accepts by
/// the link and leaves, the owner removes a member and stops sharing, the roster reads as `Person`
/// values, and a member's write over the owner's quota names the owner.
@Suite("Share service", .serialized)
struct ShareServiceTests {
    typealias Device = SpaceSyncTests.Device

    static let spaceZone = CloudZoneID("Space-s1")

    static func service(_ device: Device, accountName: String? = nil) -> ShareService {
        ShareService(transport: device.mac.transport, store: device.mac.local, spaces: device.spaces, accountName: accountName)
    }

    /// Alice's team space made with `ShareService.spaceRoot` and a compare-and-set create, as
    /// `SpaceService` will, held by her Mac, with course c1 in it; Bob's Mac knows nothing of it yet.
    static func ownedSpace() async throws -> (server: FakeCloudKit, alice: Device, bob: Device) {
        let server = EngineTestDriver.server()
        let alice = try await Device(server, name: "alice-mac", deviceID: "macaaaaa", user: "alice")
        let bob = try await Device(server, name: "bob-mac", deviceID: "macbbbbb", user: "bob")
        _ = try await alice.mac.transport.modifyZones(saving: [spaceZone], deleting: [], in: .private)
        let root = try ShareService.spaceRoot(kind: "team", name: "Lab", owner: SyncPerson(user: "alice", name: "Alice Owner"), primaryID: nil,
                                              salt: SpaceSyncTests.spaceSalt, at: 1_759_400_000_000, mint: minter("macaaaaa", at: 1_759_400_000_000))
        let created = try await alice.mac.transport.modifyRecords(saving: [CloudRecord(id: CloudRecordID(SyncSchema.rootRecordName, in: spaceZone),
                                                                                       recordType: "ZoneRoot",
                                                                                       encryptedFields: [CloudRecord.payloadKey: .bytes(try root.storedPayload())])],
                                                                  in: .private)
        #expect(created.error(for: CloudRecordID(SyncSchema.rootRecordName, in: spaceZone)) == nil)
        try await alice.sync()
        try alice.mac.exec("""
            INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES ('\(SpaceSyncTests.ownedKey)', 'Course', 'c1', 'c1');
            INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells');
        """)
        try await alice.send()
        return (server, alice, bob)
    }

    /// Stamps under each field's policy, counting up, as a device's clock would mint them.
    static func minter(_ deviceID: String, at milliseconds: Int64) -> (SyncPolicy, SyncStamp?) throws -> SyncStamp {
        var counter = 0
        return { policy, _ in
            counter += 1
            return SyncStamp(policy: policy, milliseconds: milliseconds, counter: counter, deviceID: deviceID)
        }
    }

    static func ownedZone() -> SpaceZone { SpaceZone(spaceZone, in: .private) }

    @Test("The space root carries its kind, a salt with its saltID, the owner and the revision gate, and a second create loses")
    func spaceRoot() async throws {
        let (server, alice, _) = try await Self.ownedSpace()
        let stored = try #require(server.storedRecord(SyncSchema.rootRecordName, zone: "Space-s1", owner: "alice")?.payload)
        let root = try SyncEnvelope(storedPayload: stored)
        #expect(root.fields["kind"] == .string("team"))
        #expect(root.fields["salt"] == .string(SpaceSyncTests.spaceSalt.base64EncodedString()))
        #expect(root.fields["saltID"] == .string(RecordNaming.saltID(SpaceSyncTests.spaceSalt)))
        #expect(root.saltID == RecordNaming.saltID(SpaceSyncTests.spaceSalt))
        #expect(root.fields["owner"].flatMap(SyncPerson.init(json:))?.user == "alice")
        #expect(root.fields["minClientRevision"]?.intValue == 1)
        #expect(root.fields["primaryID"] == nil)
        guard case .value(let kindStamp)? = root.stamps["kind"], case .value(let nameStamp)? = root.stamps["name"] else {
            Issue.record("the root's fields carry no stamps"); return
        }
        #expect(kindStamp.policy == .serverFirst && nameStamp.policy == .lastWriter, "each field stamped under its own policy")
        #expect(try alice.mac.store.replica.zone(key: SpaceSyncTests.ownedKey)?.saltID == RecordNaming.saltID(SpaceSyncTests.spaceSalt))

        // Another device's create of the same root, with another salt, is refused: the first root stands.
        let other = try ShareService.spaceRoot(kind: "team", name: "Lab", owner: SyncPerson(user: "alice", name: "Alice Owner"), primaryID: nil,
                                               salt: Data(repeating: 9, count: 32), at: 1_759_400_000_001,
                                               mint: Self.minter("macccccc", at: 1_759_400_000_001))
        let id = CloudRecordID(SyncSchema.rootRecordName, in: Self.spaceZone)
        let second = try await server.transport(user: "alice", device: "other").modifyRecords(
            saving: [CloudRecord(id: id, recordType: "ZoneRoot", encryptedFields: [CloudRecord.payloadKey: .bytes(try other.storedPayload())])], in: .private
        )
        #expect(second.error(for: id)?.code == .serverRecordChanged)
    }

    @Test("The owner shares a space: a link and a title, invitees pending on the roster, and the zone row records the share")
    func create() async throws {
        let (server, alice, bob) = try await Self.ownedSpace()
        server.register(email: "bob@example.com", user: "bob")
        let shared = try await Self.service(alice, accountName: "Alice Owner").share(
            Self.ownedZone(), title: "Lab", invite: [.email("bob@example.com"): .readOnly]
        )
        #expect(shared.url != nil)
        #expect(shared.title == "Lab")
        #expect(shared.publicPermission == CloudShare.Permission.none)
        #expect(shared.members.count == 2)
        #expect(shared.members[0].isOwner && shared.members[0].isCurrentUser)
        #expect(shared.members[0].person.user == "alice")
        #expect(shared.members[0].person.name == "Alice Owner")
        #expect(shared.members[1].person.user == "bob")
        #expect(shared.members[1].person.name == "bob@example.com")
        #expect(shared.members[1].permission == .readOnly)
        #expect(shared.members[1].acceptance == .pending)
        let row = try #require(try alice.mac.store.replica.zone(key: SpaceSyncTests.ownedKey))
        #expect(row.shareRecordName == CloudRecordID.zoneShareRecordName)
        #expect(row.role == "owner")

        // Only the owner shares.
        try await Self.accept(bob, url: try #require(shared.url))
        await #expect(throws: ShareServiceError.notOwner) {
            try await Self.service(bob).share(SpaceZone(CloudZoneID("Space-s1", ownerName: "alice"), in: .shared), title: "Mine")
        }
    }

    @discardableResult
    static func accept(_ device: Device, url: URL) async throws -> SpaceZone {
        EngineTestDriver.follow(device.mac.server)
        return try await Self.service(device).accept(CloudShareInvitation(url: url))
    }

    @Test("A member accepts by the link: the space joins their spaces with the permission it gives, and the next round walks it")
    func accept() async throws {
        let (server, alice, bob) = try await Self.ownedSpace()
        let shared = try await Self.service(alice).share(Self.ownedZone(), invite: [.userRecordName("bob"): .readOnly])
        let url = try #require(shared.url)
        let joined = try await Self.accept(bob, url: url)
        #expect(joined.zoneKey == SpaceSyncTests.joinedKey)
        #expect(!joined.isOwned)
        let row = try #require(try bob.mac.store.replica.zone(key: SpaceSyncTests.joinedKey))
        #expect(row.role == "member")
        #expect(row.permission == "readOnly")
        #expect(row.shareRecordName == CloudRecordID.zoneShareRecordName)
        #expect(try await bob.spaces.heldSpaces().map(\.zoneKey) == [SpaceSyncTests.joinedKey])
        try await bob.sync()
        #expect(try bob.mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells")

        // Someone not invited is refused while the link is private, and joins once it is public.
        let carol = try await Device(server, name: "carol-mac", deviceID: "maccccca", user: "carol")
        await #expect(throws: ShareServiceError.failed(CloudError(.permissionFailure, message: "carol was not invited to Space-s1"))) {
            try await Self.accept(carol, url: url)
        }
        #expect(try carol.mac.store.replica.zone(key: SpaceSyncTests.joinedKey) == nil)
        _ = try await Self.service(alice).share(Self.ownedZone(), publicPermission: .readWrite)
        try await Self.accept(carol, url: url)
        #expect(try carol.mac.store.replica.zone(key: SpaceSyncTests.joinedKey)?.permission == "readWrite")
    }

    @Test("A member leaves: the space leaves their shared database and goes from their spaces as left; the owner cannot leave")
    func leave() async throws {
        let (server, alice, bob) = try await Self.ownedSpace()
        let shared = try await Self.service(alice).share(Self.ownedZone(), invite: [.userRecordName("bob"): .readWrite])
        let joined = try await Self.accept(bob, url: try #require(shared.url))
        try await bob.sync()
        try await Self.service(bob).leave(joined)
        #expect(try await bob.spaces.goneSpaces()[SpaceSyncTests.joinedKey]?.contains("left") == true)
        #expect(try await bob.spaces.heldSpaces().isEmpty)
        #expect(try await server.transport(user: "bob", device: "bob-other").allZones(in: .shared).isEmpty)
        #expect(try bob.mac.text("SELECT title FROM test_courses WHERE id = 'c1'") == "Cells", "the space packages decide about local rows")
        let roster = try await Self.service(alice).roster(of: Self.ownedZone())
        #expect(roster.members.map(\.person.user) == ["alice"])
        await #expect(throws: ShareServiceError.ownerCannotLeave) { try await Self.service(alice).leave(Self.ownedZone()) }
        #expect(server.zoneNames(owner: "alice").contains("Space-s1"))
    }

    @Test("The owner removes a member, then stops sharing: the zone stays, owned, with no share")
    func removeAndStopSharing() async throws {
        let (server, alice, bob) = try await Self.ownedSpace()
        let owner = Self.service(alice)
        let shared = try await owner.share(Self.ownedZone(), invite: [.userRecordName("bob"): .readWrite])
        try await Self.accept(bob, url: try #require(shared.url))
        try await bob.sync()
        let removed = try await owner.removeParticipant("bob", from: Self.ownedZone())
        #expect(removed.members.map(\.person.user) == ["alice"])
        try await bob.sync()
        #expect(try await bob.spaces.goneSpaces()[SpaceSyncTests.joinedKey] != nil)

        try await owner.stopSharing(Self.ownedZone())
        await #expect(throws: ShareServiceError.notShared) { try await owner.roster(of: Self.ownedZone()) }
        #expect(server.zoneNames(owner: "alice").contains("Space-s1"))
        #expect(server.storedRecord(SyncSchema.rootRecordName, zone: "Space-s1", owner: "alice") != nil)
        #expect(try alice.mac.store.replica.zone(key: SpaceSyncTests.ownedKey)?.shareRecordName == nil)
        try await alice.sync()
        #expect(try await alice.spaces.heldSpaces().map(\.zoneKey) == [SpaceSyncTests.ownedKey], "an unshared space is still the owner's")
        await #expect(throws: ShareServiceError.notOwner) {
            try await Self.service(bob).stopSharing(SpaceZone(CloudZoneID("Space-s1", ownerName: "alice"), in: .shared))
        }
    }

    @Test("The roster is Person values: the owner first, this account under its own name, the owner by the root's name, others by email")
    func rosterAsPeople() async throws {
        let (server, alice, bob) = try await Self.ownedSpace()
        server.register(email: "carol@example.com", user: "carol")
        let shared = try await Self.service(alice).share(Self.ownedZone(), invite: [.userRecordName("bob"): .readWrite, .email("carol@example.com"): .readOnly])
        try await Self.accept(bob, url: try #require(shared.url))
        try await bob.sync()
        let seen = try await Self.service(bob, accountName: "Bob Member").roster(of: SpaceZone(CloudZoneID("Space-s1", ownerName: "alice"), in: .shared))
        #expect(seen.members.map(\.person.user) == ["alice", "bob", "carol"])
        #expect(seen.members.map(\.person.name) == ["Alice Owner", "Bob Member", "carol@example.com"])
        #expect(seen.members.map(\.isCurrentUser) == [false, true, false])
        #expect(seen.members[0].isOwner)
        #expect(seen.members[2].acceptance == .pending)
        #expect(seen.members[1].person.value == SyncPerson(user: "bob", name: "Bob Member").value)

        // Read again, the roster gives the member their permission as the owner changed it.
        _ = try await Self.service(alice).share(Self.ownedZone(), permissions: ["bob": .readOnly])
        _ = try await Self.service(bob).roster(of: SpaceZone(CloudZoneID("Space-s1", ownerName: "alice"), in: .shared))
        #expect(try bob.mac.store.replica.zone(key: SpaceSyncTests.joinedKey)?.permission == "readOnly")

        let unnamed = CloudShare.Participant(user: "dave", name: " ", email: nil, permission: .readOnly, role: .privateUser, acceptance: .accepted, isCurrentUser: false)
        #expect(ShareService.displayName(unnamed, isCurrentUser: false, accountName: "Alice Owner") == "Member")
        #expect(ShareService.displayName(unnamed, isCurrentUser: true, accountName: nil) == "You")
    }

    @Test("A member's write over the owner's full iCloud storage is reported in the owner's name")
    func quotaNamesTheOwner() async throws {
        let (server, alice, bob) = try await Self.ownedSpace()
        let shared = try await Self.service(alice).share(Self.ownedZone(), invite: [.userRecordName("bob"): .readWrite])
        try await Self.accept(bob, url: try #require(shared.url))
        try await bob.sync()
        server.setQuota(server.usedBytes(of: "alice"), for: "alice")
        await EngineTestDriver.pause()
        try bob.mac.exec("UPDATE test_courses SET title = 'Cells, their membranes and what crosses them' WHERE id = 'c1'")
        try await bob.send()
        let owner = await bob.spaces.quotaOwner
        #expect(owner == "Alice Owner")
        #expect(ShareService.quotaNotice(owner: owner).hasPrefix("Alice Owner's iCloud storage is full"))
        #expect(try bob.mac.outboxRows() > 0, "the write waits for space")
        #expect(!ShareService.quotaNotice(owner: nil).contains("Alice"))
        #expect(ShareService.quotaNotice(owner: nil).hasPrefix("Your iCloud storage is full"))

        // Settings › iCloud shows it from the status the coordinator publishes.
        var status = SyncStatus()
        status.phase = .upToDate
        #expect(status.notice == nil)
        status.pause = .quotaExceeded(owner: owner)
        #expect(status.notice == ShareService.quotaNotice(owner: "Alice Owner"))
    }
}
