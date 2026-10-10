import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The in-memory CloudKit's own contract (docs/cloudkit-schema-design.md §14.2, WP4b): what every
/// later sync suite relies on it to answer as CloudKit does.
@Suite("In-memory CloudKit")
struct FakeCloudKitTests {
    private static let library = CloudZoneID(SyncZone.library.rawValue)
    private static let catalog = CloudZoneID(SyncZone.catalog.rawValue)
    private static let content = CloudZoneID(SyncZone.content.rawValue)

    private static func record(_ name: String, in zone: CloudZoneID = library, type: String = "Notebook",
                               payload: String = #"{"env":1}"#) -> CloudRecord {
        CloudRecord(id: CloudRecordID(name, in: zone), recordType: type,
                    encryptedFields: [CloudRecord.payloadKey: .bytes(Data(payload.utf8))])
    }

    /// A device of `user` whose private database has `zones`.
    private static func device(_ server: FakeCloudKit, user: String = "_alice", name: String = "macA",
                               zones: [CloudZoneID] = [library]) async throws -> FakeCloudKit.Transport {
        let transport = server.transport(user: user, device: name)
        let made = try await transport.modifyZones(saving: zones, deleting: [], in: .private)
        for zone in zones { try made.saved[zone]?.get() }
        return transport
    }

    private static func saved(_ results: CloudModifyResults, _ id: CloudRecordID) throws -> CloudRecord {
        try #require(results.savedRecord(id), "\(id): \(results.error(for: id).map(String.init(describing:)) ?? "no result")")
    }

    /// The code a call throws, nil when it does not.
    private static func thrownCode<T>(_ body: () async throws -> T) async -> CKError.Code? {
        do {
            _ = try await body()
            return nil
        } catch let error as CloudError {
            return error.code
        } catch {
            return .internalError
        }
    }

    @Test("The build names the schema's container, and the fake serves it")
    func libraryContainer() {
        #expect(ForeverLMRuntimeIdentity.libraryContainerIdentifier == SyncSchema.containerIdentifier)
        #expect(FakeCloudKit.libraryContainer == SyncSchema.containerIdentifier)
        #expect(FakeCloudKit.libraryContainer != FakeCloudKit.legacyContainer)
    }

    /// Since the move to the company Apple team (XXXXXXXXXX, 2026-10-09) every build names one
    /// container, `iCloud.com.foreverlm.knowledge`, and nothing of the old team's: no
    /// `iCloud.com.foreverlm` or `iCloud.com.foreverlm.library`, no iCloud Documents (ubiquity)
    /// container, no key-value store and no retired FeynmanLM keychain group. `CKContainer(identifier:)`
    /// traps on a container the app is not entitled to, so the list must be exactly this one. Release,
    /// the App Store iPhone and the Development builds ask for push, which their sync registers for;
    /// First Run (a stranger's first launch, which never syncs) asks for none. The iPhone app and its
    /// extensions share `group.com.foreverlm`.
    @Test("Every build names the knowledge container alone; Release, the iPhone and Development ask for push, First Run for none")
    func entitlementsPerConfiguration() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func entitlements(_ path: String) throws -> [String: Any] {
            let data = try Data(contentsOf: app.appendingPathComponent(path))
            return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], "\(path)")
        }
        let container = ["iCloud.com.foreverlm.knowledge"]
        #expect(SyncSchema.containerIdentifier == container[0])
        let containerFiles = [
            "App/ForeverLMDevelopment.entitlements", "App/ForeverLMDirectDownload.entitlements", "App/ForeverLMFirstRun.entitlements",
            "iOS/ForeverLMiOS.entitlements", "iOS/ForeverLMiOSDevelopment.entitlements",
        ]
        for path in containerFiles {
            let file = try entitlements(path)
            #expect(file["com.apple.developer.icloud-container-identifiers"] as? [String] == container, "\(path)")
            #expect(file["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"], "\(path)")
            #expect(file["com.apple.developer.ubiquity-container-identifiers"] == nil, "\(path)")
            #expect(file["com.apple.developer.ubiquity-kvstore-identifier"] == nil, "\(path)")
            let groups = file["keychain-access-groups"] as? [String] ?? []
            #expect(!groups.contains { $0.contains("feynmanlm") }, "\(path)")
        }
        let dev = try entitlements("App/ForeverLMDevelopment.entitlements")
        #expect(dev["com.apple.developer.aps-environment"] as? String == "development")
        #expect(dev["com.apple.developer.icloud-container-environment"] as? String == "Development")
        let release = try entitlements("App/ForeverLMDirectDownload.entitlements")
        #expect(release["com.apple.developer.aps-environment"] as? String == "production")
        #expect(release["com.apple.developer.icloud-container-environment"] as? String == "Production")
        let firstRun = try entitlements("App/ForeverLMFirstRun.entitlements")
        #expect(firstRun["com.apple.developer.aps-environment"] == nil && firstRun["aps-environment"] == nil)
        #expect(firstRun["com.apple.developer.icloud-container-environment"] as? String == "Development")
        let phone = try entitlements("iOS/ForeverLMiOS.entitlements")
        #expect(phone["aps-environment"] as? String == "production")
        #expect(phone["com.apple.developer.icloud-container-environment"] as? String == "Production")
        let phoneDebug = try entitlements("iOS/ForeverLMiOSDevelopment.entitlements")
        #expect(phoneDebug["com.apple.developer.icloud-container-environment"] as? String == "Development")
        #expect(phoneDebug["aps-environment"] as? String == "development")
        for path in ["iOS/ForeverLMiOS.entitlements", "iOS/ForeverLMiOSDevelopment.entitlements",
                     "iOSShare/ForeverLMShare.entitlements", "iOSWidget/ForeverLMTodayWidget.entitlements"] {
            #expect(try entitlements(path)["com.apple.security.application-groups"] as? [String] == ["group.com.foreverlm"], "\(path)")
        }
    }

    @Test("A create gets a change tag and the server's dates, and a second create of the name meets the server's record")
    func createCollides() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server)
        let macB = server.transport(user: "_alice", device: "macB")
        let first = Self.record("nb_1", payload: "first")

        let created = try Self.saved(try await macA.modifyRecords(saving: [first], in: .private), first.id)
        #expect(created.changeTag != nil)
        #expect(created.systemFields != nil)
        #expect(created.creationDate == created.modificationDate)
        #expect(created.modificationDate.map { $0 <= server.now } == true)

        let collision = try await macB.modifyRecords(saving: [Self.record("nb_1", payload: "second")], in: .private)
        let error = try #require(collision.error(for: first.id))
        #expect(error.code == .serverRecordChanged)
        #expect(error.serverRecord?.payload == Data("first".utf8))
        #expect(error.serverRecord?.changeTag == created.changeTag)
        #expect(server.storedRecord("nb_1", zone: "Library", owner: "_alice")?.payload == Data("first".utf8))
    }

    @Test("An update names the version it read: an older one meets the newer record, the current one wins")
    func updateComparesTags() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server)
        let macB = server.transport(user: "_alice", device: "macB")
        let id = CloudRecordID("nb_1", in: Self.library)
        let v1 = try Self.saved(try await macA.modifyRecords(saving: [Self.record("nb_1", payload: "v1")], in: .private), id)
        let seenByB = try await macB.record(id, in: .private).get()
        #expect(seenByB.changeTag == v1.changeTag)

        var update = v1
        update.payload = Data("v2".utf8)
        let v2 = try Self.saved(try await macA.modifyRecords(saving: [update], in: .private), id)
        #expect(v2.changeTag != v1.changeTag)
        #expect(v2.creationDate == v1.creationDate)

        var stale = seenByB
        stale.payload = Data("from B".utf8)
        let lost = try #require(try await macB.modifyRecords(saving: [stale], in: .private).error(for: id))
        #expect(lost.code == .serverRecordChanged)
        #expect(lost.serverRecord?.payload == Data("v2".utf8))
        #expect(lost.serverRecord?.changeTag == v2.changeTag)

        var merged = try #require(lost.serverRecord)
        merged.payload = Data("v2 and B".utf8)
        let v3 = try Self.saved(try await macB.modifyRecords(saving: [merged], in: .private), id)
        #expect(v3.payload == Data("v2 and B".utf8))
        #expect(try await macA.record(id, in: .private).get().changeTag == v3.changeTag)
    }

    @Test("Updating or deleting a record deleted elsewhere is unknownItem")
    func goneIsUnknownItem() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server)
        let macB = server.transport(user: "_alice", device: "macB")
        let id = CloudRecordID("en_1", in: Self.library)
        _ = try Self.saved(try await macA.modifyRecords(saving: [Self.record("en_1", type: "Entry")], in: .private), id)
        var held = try await macB.record(id, in: .private).get()
        try await macA.modifyRecords(deleting: [id], in: .private).deleted[id]?.get()

        held.payload = Data("edit".utf8)
        #expect(try await macB.modifyRecords(saving: [held], in: .private).error(for: id)?.code == .unknownItem)
        #expect(try await macB.modifyRecords(deleting: [id], in: .private).error(for: id)?.code == .unknownItem)
        #expect(try await macB.record(id, in: .private).error?.code == .unknownItem)
        // A deliberate re-create, with no system fields, is a create.
        #expect(try await macB.modifyRecords(saving: [Self.record("en_1", type: "Entry")], in: .private).savedRecord(id) != nil)
    }

    @Test("changedKeys writes the fields it carries and allKeys replaces the record, neither checking the tag")
    func uncheckedPolicies() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server, zones: [Self.content])
        let id = CloudRecordID("ct_1", in: Self.content)
        var full = Self.record("ct_1", in: Self.content, type: "Content", payload: "p1")
        full.encryptedFields[CloudRecord.dataKey] = .bytes(Data("body".utf8))
        _ = try Self.saved(try await mac.modifyRecords(saving: [full], in: .private), id)

        let payloadOnly = Self.record("ct_1", in: Self.content, type: "Content", payload: "p2")
        _ = try Self.saved(try await mac.modifyRecords(saving: [payloadOnly], deleting: [], in: .private, savePolicy: .changedKeys, atomically: false), id)
        let merged = try #require(server.storedRecord("ct_1", zone: "Content", owner: "_alice"))
        #expect(merged.payload == Data("p2".utf8))
        #expect(merged.encryptedFields[CloudRecord.dataKey] == .bytes(Data("body".utf8)))

        let replacement = Self.record("ct_1", in: Self.content, type: "Content", payload: "p3")
        _ = try Self.saved(try await mac.modifyRecords(saving: [replacement], deleting: [], in: .private, savePolicy: .allKeys, atomically: false), id)
        let replaced = try #require(server.storedRecord("ct_1", zone: "Content", owner: "_alice"))
        #expect(replaced.payload == Data("p3".utf8))
        #expect(replaced.encryptedFields[CloudRecord.dataKey] == nil)
    }

    @Test("A zone's changes come in pages with tokens, and deletions come only after a token")
    func pagedChanges() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server)
        let macB = server.transport(user: "_alice", device: "macB")
        let names = (1...5).map { "nb_\($0)" }
        _ = try await macA.modifyRecords(saving: names.map { Self.record($0) }, in: .private)

        var token: CloudChangeToken?
        var pages: [[String]] = []
        var more = true
        while more {
            let page = try await macB.zoneChanges(Self.library, in: .private, since: token, resultsLimit: 2).get()
            pages.append(page.modified.map(\.id.recordName))
            #expect(page.deleted.isEmpty)
            token = page.changeToken
            more = page.moreComing
        }
        #expect(pages == [["nb_1", "nb_2"], ["nb_3", "nb_4"], ["nb_5"]])
        #expect(try await macB.zoneChanges(Self.library, in: .private, since: token).get().modified.isEmpty)

        let gone = CloudRecordID("nb_2", in: Self.library)
        var edited = try await macA.record(CloudRecordID("nb_4", in: Self.library), in: .private).get()
        edited.payload = Data("edited".utf8)
        _ = try await macA.modifyRecords(saving: [edited], deleting: [gone], in: .private)

        let after = try await macB.zoneChanges(Self.library, in: .private, since: token).get()
        #expect(after.modified.map(\.id.recordName) == ["nb_4"])
        #expect(after.deleted == [CloudRecordDeletion(id: gone, recordType: "Notebook")])
        #expect(!after.moreComing)
        let fromNil = try await macB.zoneChanges(Self.library, in: .private).get()
        #expect(Set(fromNil.modified.map(\.id.recordName)) == ["nb_1", "nb_3", "nb_4", "nb_5"])
        #expect(fromNil.deleted.isEmpty, "a pass from nil never returns the deletions it missed")
    }

    @Test("Only the desired keys come back, and an asset arrives as a file only when asked for")
    func desiredKeys() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server, zones: [Self.content])
        let part = FileManager.default.temporaryDirectory.appendingPathComponent("FakeCloudKitTests-\(UUID().uuidString).part")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: part)
        defer { try? FileManager.default.removeItem(at: part) }
        var satellite = Self.record("ct_part", in: Self.content, type: "Content", payload: #"{"part":0}"#)
        satellite.fields[CloudRecord.assetKey] = .asset(part)
        let id = satellite.id
        _ = try Self.saved(try await mac.modifyRecords(saving: [satellite], in: .private), id)

        let whole = try await mac.record(id, in: .private).get()
        guard case .asset(let url)? = whole.fields[CloudRecord.assetKey] else {
            Issue.record("no asset in a fetch of every key")
            return
        }
        #expect(url != part)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(whole.payload != nil)

        let namesOnly = try await mac.record(id, in: .private, desiredKeys: []).get()
        #expect(namesOnly.encryptedFields.isEmpty && namesOnly.fields.isEmpty)
        #expect(namesOnly.changeTag == whole.changeTag)

        let light = try await mac.zoneChanges(Self.content, in: .private, desiredKeys: [CloudRecord.payloadKey]).get()
        #expect(light.modified.count == 1)
        #expect(light.modified.first?.payload == whole.payload)
        #expect(light.modified.first?.fields.isEmpty == true, "the light walk never carries data or asset (§2.3)")
    }

    @Test("An expired zone token is changeTokenExpired, and the fetch from nil after it never hears of the deletion")
    func expiredZoneToken() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server)
        let macB = server.transport(user: "_alice", device: "macB")
        _ = try await macA.modifyRecords(saving: [Self.record("nb_1"), Self.record("nb_2")], in: .private)
        let token = try await macB.zoneChanges(Self.library, in: .private).get().changeToken
        _ = try await macA.modifyRecords(deleting: [CloudRecordID("nb_1", in: Self.library)], in: .private)

        server.expireZoneChangeTokens(zone: "Library", owner: "_alice")
        let expired = try await macB.zoneChanges(Self.library, in: .private, since: token)
        #expect(expired.error?.code == .changeTokenExpired)
        let again = try await macB.zoneChanges(Self.library, in: .private).get()
        #expect(again.modified.map(\.id.recordName) == ["nb_2"])
        #expect(again.deleted.isEmpty, "nb_1 stays on B as a ghost until the replica audit sweeps it (§2.3)")
        #expect(try await macB.zoneChanges(Self.library, in: .private, since: again.changeToken).get().modified.isEmpty)
    }

    @Test("After a zone's tokens expire its deletions are gone: a paged walk from nil to the end never reports one")
    func expiryDropsDeletions() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server)
        let macB = server.transport(user: "_alice", device: "macB")
        _ = try await macA.modifyRecords(saving: ["nb_1", "nb_2", "nb_3"].map { Self.record($0) }, in: .private)
        _ = try await macA.modifyRecords(deleting: [CloudRecordID("nb_1", in: Self.library)], in: .private)
        server.expireZoneChangeTokens(zone: "Library", owner: "_alice")

        // One record a page, so every page after the first is asked for with a token, as deletions are.
        var token: CloudChangeToken?
        var seen: [String] = []
        var deleted: [CloudRecordDeletion] = []
        var more = true
        while more {
            let page = try await macB.zoneChanges(Self.library, in: .private, since: token, resultsLimit: 1).get()
            seen += page.modified.map(\.id.recordName)
            deleted += page.deleted
            token = page.changeToken
            more = page.moreComing
        }
        #expect(seen == ["nb_2", "nb_3"])
        #expect(deleted.isEmpty, "the deletion went with the expired tokens; the replica audit finds nb_1 (§2.3, D30)")
    }

    @Test("A record the server cannot hand over arrives in its page's failed list, and the page's token moves past it")
    func pageCarriesRecordFailure() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server)
        let macB = server.transport(user: "_alice", device: "macB")
        _ = try await macA.modifyRecords(saving: ["nb_1", "nb_2", "nb_3"].map { Self.record($0) }, in: .private)
        server.failRecord("nb_2", with: CloudError(.assetFileNotFound, message: "the asset would not download"))

        let page = try await macB.zoneChanges(Self.library, in: .private).get()
        let failed = CloudRecordID("nb_2", in: Self.library)
        #expect(page.modified.map(\.id.recordName) == ["nb_1", "nb_3"])
        #expect(Array(page.failed.keys) == [failed])
        #expect(page.failed[failed]?.code == .assetFileNotFound)
        // A caller storing this token without fetching nb_2 by name would not hear of it again.
        #expect(try await macB.zoneChanges(Self.library, in: .private, since: page.changeToken).get().modified.isEmpty)
        #expect(try await macB.record(failed, in: .private).get().payload != nil, "fetched by name, it arrives")
    }

    @Test("A missing zone is zoneNotFound, a purged one userDeletedZone, and a zone made again refuses its old tokens")
    func missingZones() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server)
        #expect(try await mac.zoneChanges(Self.catalog, in: .private).error?.code == .zoneNotFound)
        #expect(try await mac.modifyRecords(saving: [Self.record("src_1", in: Self.catalog, type: "Source")], in: .private)
            .error(for: CloudRecordID("src_1", in: Self.catalog))?.code == .zoneNotFound)

        _ = try await mac.modifyRecords(saving: [Self.record("nb_1")], in: .private)
        let token = try await mac.zoneChanges(Self.library, in: .private).get().changeToken
        server.deleteZone("Library", owner: "_alice", reason: .purged)
        #expect(try await mac.zoneChanges(Self.library, in: .private, since: token).error?.code == .userDeletedZone)
        #expect(try await mac.modifyRecords(saving: [Self.record("nb_2")], in: .private)
            .error(for: CloudRecordID("nb_2", in: Self.library))?.code == .userDeletedZone)
        #expect(try await mac.allZones(in: .private).isEmpty)

        // Only ZoneBootstrap ever does this, and only after the learner asks (§2.4 step 5). The new
        // zone has moved past the old token's position, and the token still names nothing in it.
        try await mac.modifyZones(saving: [Self.library], deleting: [], in: .private).saved[Self.library]?.get()
        _ = try await mac.modifyRecords(saving: [Self.record("nb_3"), Self.record("nb_4")], in: .private)
        #expect(try await mac.zoneChanges(Self.library, in: .private, since: token).error?.code == .changeTokenExpired)
        let fresh = try await mac.zoneChanges(Self.library, in: .private).get()
        #expect(Set(fresh.modified.map(\.id.recordName)) == ["nb_3", "nb_4"])

        try await mac.modifyZones(saving: [], deleting: [Self.library], in: .private).deleted[Self.library]?.get()
        #expect(try await mac.zoneChanges(Self.library, in: .private).error?.code == .zoneNotFound)
    }

    @Test("Database changes name the zones that changed and why each one went")
    func databaseChanges() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server, zones: [Self.library, Self.catalog, Self.content, CloudZoneID("Space-1")])
        let macB = server.transport(user: "_alice", device: "macB")
        let start = try await macB.databaseChanges(in: .private, since: nil, resultsLimit: nil)
        #expect(Set(start.modifiedZones.map(\.zoneName)) == ["Library", "Catalog", "Content", "Space-1"])
        #expect(start.deletedZones.isEmpty && !start.moreComing)

        _ = try await macA.modifyRecords(saving: [Self.record("nb_1")], in: .private)
        server.deleteZone("Catalog", owner: "_alice", reason: .purged)
        try await macA.modifyZones(saving: [], deleting: [CloudZoneID("Space-1")], in: .private).deleted[CloudZoneID("Space-1")]?.get()
        let changes = try await macB.databaseChanges(in: .private, since: start.changeToken, resultsLimit: nil)
        #expect(changes.modifiedZones == [Self.library])
        #expect(Set(changes.deletedZones) == [
            CloudZoneDeletion(zoneID: Self.catalog, reason: .purged),
            CloudZoneDeletion(zoneID: CloudZoneID("Space-1"), reason: .deleted),
        ])

        server.resetEncryptedData(owner: "_alice")
        let reset = try await macB.databaseChanges(in: .private, since: changes.changeToken, resultsLimit: nil)
        #expect(Set(reset.deletedZones) == [
            CloudZoneDeletion(zoneID: Self.library, reason: .encryptedDataReset),
            CloudZoneDeletion(zoneID: Self.content, reason: .encryptedDataReset),
        ])
        #expect(reset.modifiedZones.isEmpty)
    }

    @Test("Database changes come in pages, and an expired database token is changeTokenExpired")
    func databaseChangePages() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server)
        let start = try await mac.databaseChanges(in: .private, since: nil, resultsLimit: nil).changeToken
        try await mac.modifyZones(saving: [Self.catalog, Self.content], deleting: [], in: .private).saved[Self.content]?.get()
        let first = try await mac.databaseChanges(in: .private, since: start, resultsLimit: 1)
        #expect(first.modifiedZones == [Self.catalog] && first.moreComing)
        let second = try await mac.databaseChanges(in: .private, since: first.changeToken, resultsLimit: 1)
        #expect(second.modifiedZones == [Self.content] && !second.moreComing)

        server.expireDatabaseChangeTokens(user: "_alice", scope: .private)
        #expect(await Self.thrownCode { try await mac.databaseChanges(in: .private, since: second.changeToken, resultsLimit: nil) } == .changeTokenExpired)
        #expect(try await mac.databaseChanges(in: .private, since: nil, resultsLimit: nil).modifiedZones.count == 3)
    }

    @Test("A shared zone shows in the participant's shared database under its owner's name, and writes go both ways")
    func sharedDatabaseView() async throws {
        let server = FakeCloudKit()
        let space = CloudZoneID("Space-1")
        let alice = try await Self.device(server, zones: [Self.library, space])
        let bob = try await Self.device(server, user: "_bob", name: "bobMac")
        _ = try await alice.modifyRecords(saving: [Self.record("nb_team", in: space)], in: .private)
        #expect(try await bob.allZones(in: .shared).isEmpty)
        let bobStart = try await bob.databaseChanges(in: .shared, since: nil, resultsLimit: nil).changeToken

        server.share(zone: "Space-1", owner: "_alice", with: "_bob")
        let asSeen = CloudZoneID("Space-1", ownerName: "_alice")
        #expect(try await bob.allZones(in: .shared) == [asSeen])
        #expect(try await bob.allZones(in: .private) == [Self.library])
        #expect(try await bob.databaseChanges(in: .shared, since: bobStart, resultsLimit: nil).modifiedZones == [asSeen])

        let walk = try await bob.zoneChanges(asSeen, in: .shared, desiredKeys: [CloudRecord.payloadKey]).get()
        #expect(Set(walk.modified.map(\.id.recordName)) == ["nb_team", CloudRecordID.zoneShareRecordName])
        #expect(walk.modified.allSatisfy { $0.id.zoneID == asSeen })
        #expect(walk.modified.first(where: { $0.id.recordName == CloudRecordID.zoneShareRecordName })?.recordType == CloudRecordID.shareRecordType)

        let fromBob = Self.record("en_bob", in: asSeen, type: "Entry")
        _ = try Self.saved(try await bob.modifyRecords(saving: [fromBob], in: .shared), fromBob.id)
        let ownerView = try await alice.record(CloudRecordID("en_bob", in: space), in: .private).get()
        #expect(ownerView.id.zoneID == space)
        #expect(await Self.thrownCode { try await alice.zoneChanges(asSeen, in: .shared).get() } == .zoneNotFound)
    }

    @Test("A read-only participant cannot write, and any participant can leave by deleting the zone-wide share")
    func readOnlyAndLeave() async throws {
        let server = FakeCloudKit()
        let space = CloudZoneID("Space-1")
        let alice = try await Self.device(server, zones: [space])
        _ = try await alice.modifyRecords(saving: [Self.record("nb_team", in: space)], in: .private)
        server.share(zone: "Space-1", owner: "_alice", with: "_bob")
        server.share(zone: "Space-1", owner: "_alice", with: "_carol", permission: .readOnly)
        let carol = server.transport(user: "_carol", device: "carolPhone")
        let asSeen = CloudZoneID("Space-1", ownerName: "_alice")
        let start = try await carol.databaseChanges(in: .shared, since: nil, resultsLimit: nil)
        #expect(start.modifiedZones == [asSeen])

        let attempt = Self.record("en_carol", in: asSeen, type: "Entry")
        #expect(try await carol.modifyRecords(saving: [attempt], in: .shared).error(for: attempt.id)?.code == .permissionFailure)
        let teamRecord = CloudRecordID("nb_team", in: asSeen)
        #expect(try await carol.modifyRecords(deleting: [teamRecord], in: .shared).error(for: teamRecord)?.code == .permissionFailure)
        #expect(try await carol.record(teamRecord, in: .shared).get().payload != nil, "reading is allowed")

        let share = CloudRecordID(CloudRecordID.zoneShareRecordName, in: asSeen)
        try await carol.modifyRecords(deleting: [share], in: .shared).deleted[share]?.get()
        let left = try await carol.databaseChanges(in: .shared, since: start.changeToken, resultsLimit: nil)
        #expect(left.deletedZones == [CloudZoneDeletion(zoneID: asSeen, reason: .deleted)])
        #expect(try await carol.allZones(in: .shared).isEmpty)
        #expect(try await carol.record(teamRecord, in: .shared).error?.code == .zoneNotFound)
        let bob = server.transport(user: "_bob", device: "bobMac")
        #expect(try await bob.allZones(in: .shared) == [asSeen], "one member leaving changes nothing for the others")
        #expect(server.recordNames(zone: "Space-1", owner: "_alice").contains(CloudRecordID.zoneShareRecordName))
    }

    @Test("The owner removing one participant takes the zone from that one alone, and deleting the zone-wide share takes it from all")
    func ownerUnshares() async throws {
        let server = FakeCloudKit()
        let space = CloudZoneID("Space-1")
        let alice = try await Self.device(server, zones: [space])
        _ = try await alice.modifyRecords(saving: [Self.record("nb_team", in: space)], in: .private)
        for member in ["_bob", "_carol", "_dan"] { server.share(zone: "Space-1", owner: "_alice", with: member) }
        let bob = server.transport(user: "_bob", device: "bobMac")
        let carol = server.transport(user: "_carol", device: "carolPhone")
        let dan = server.transport(user: "_dan", device: "danMac")
        let asSeen = CloudZoneID("Space-1", ownerName: "_alice")
        let teamRecord = CloudRecordID("nb_team", in: asSeen)
        let bobStart = try await bob.databaseChanges(in: .shared, since: nil, resultsLimit: nil)
        let carolStart = try await carol.databaseChanges(in: .shared, since: nil, resultsLimit: nil)
        let danStart = try await dan.databaseChanges(in: .shared, since: nil, resultsLimit: nil)
        #expect([bobStart, carolStart, danStart].allSatisfy { $0.modifiedZones == [asSeen] })

        server.removeParticipant("_dan", zone: "Space-1", owner: "_alice")
        let danAfter = try await dan.databaseChanges(in: .shared, since: danStart.changeToken, resultsLimit: nil)
        #expect(danAfter.deletedZones == [CloudZoneDeletion(zoneID: asSeen, reason: .deleted)])
        #expect(try await dan.allZones(in: .shared).isEmpty)
        #expect(try await dan.record(teamRecord, in: .shared).error?.code == .zoneNotFound)
        #expect(try await bob.databaseChanges(in: .shared, since: bobStart.changeToken, resultsLimit: nil).deletedZones.isEmpty)
        #expect(try await bob.allZones(in: .shared) == [asSeen], "removing one participant tells no one else")

        let zoneShare = CloudRecordID(CloudRecordID.zoneShareRecordName, in: space)
        try await alice.modifyRecords(deleting: [zoneShare], in: .private).deleted[zoneShare]?.get()
        for (member, start) in [(bob, bobStart), (carol, carolStart)] {
            let after = try await member.databaseChanges(in: .shared, since: start.changeToken, resultsLimit: nil)
            #expect(after.deletedZones == [CloudZoneDeletion(zoneID: asSeen, reason: .deleted)])
            #expect(try await member.allZones(in: .shared).isEmpty)
            #expect(try await member.record(teamRecord, in: .shared).error?.code == .zoneNotFound)
        }
        #expect(server.recordNames(zone: "Space-1", owner: "_alice") == ["nb_team"], "the zone stays the owner's, unshared")
        #expect(try await alice.record(CloudRecordID("nb_team", in: space), in: .private).get().payload != nil)
    }

    @Test("A participant's writes count against the owner's quota, and the owner deleting the zone takes it from every participant")
    func ownerQuotaAndZoneDelete() async throws {
        let server = FakeCloudKit()
        let space = CloudZoneID("Space-1")
        let alice = try await Self.device(server, zones: [space])
        let bob = try await Self.device(server, user: "_bob", name: "bobMac")
        server.share(zone: "Space-1", owner: "_alice", with: "_bob")
        let asSeen = CloudZoneID("Space-1", ownerName: "_alice")
        let bobStart = try await bob.databaseChanges(in: .shared, since: nil, resultsLimit: nil).changeToken

        server.setQuota(server.usedBytes(of: "_alice") + 10, for: "_alice")
        let big = Self.record("en_big", in: asSeen, type: "Entry", payload: String(repeating: "x", count: 100))
        #expect(try await bob.modifyRecords(saving: [big], in: .shared).error(for: big.id)?.code == .quotaExceeded)
        let own = Self.record("nb_own", payload: String(repeating: "y", count: 100))
        #expect(try await bob.modifyRecords(saving: [own], in: .private).savedRecord(own.id) != nil, "bob's own storage is his")
        #expect(server.usedBytes(of: "_bob") >= 100)

        try await alice.modifyZones(saving: [], deleting: [space], in: .private).deleted[space]?.get()
        let gone = try await bob.databaseChanges(in: .shared, since: bobStart, resultsLimit: nil)
        #expect(gone.deletedZones == [CloudZoneDeletion(zoneID: asSeen, reason: .deleted)])
        #expect(try await bob.zoneChanges(asSeen, in: .shared).error?.code == .zoneNotFound)
    }

    @Test("A save past the quota is quotaExceeded, and a delete makes room again")
    func quota() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server)
        let small = Self.record("nb_small", payload: String(repeating: "a", count: 40))
        _ = try Self.saved(try await mac.modifyRecords(saving: [small], in: .private), small.id)
        server.setQuota(server.usedBytes(of: "_alice") + 20, for: "_alice")

        let big = Self.record("nb_big", payload: String(repeating: "b", count: 50))
        #expect(try await mac.modifyRecords(saving: [big], in: .private).error(for: big.id)?.code == .quotaExceeded)
        try await mac.modifyRecords(deleting: [small.id], in: .private).deleted[small.id]?.get()
        #expect(try await mac.modifyRecords(saving: [big], in: .private).savedRecord(big.id) != nil)
    }

    @Test("Within a page, records come in the delivery order the test asks for, and each arrives exactly once")
    func deliveryOrder() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server)
        let names = (0..<10).map { String(format: "nb_%02d", $0) }
        for name in names {
            _ = try await mac.modifyRecords(saving: [Self.record(name)], in: .private)
        }

        server.deliveryOrder = .reversed
        #expect(try await mac.zoneChanges(Self.library, in: .private).get().modified.map(\.id.recordName) == names.reversed())

        server.deliveryOrder = .shuffled(seed: 7)
        var token: CloudChangeToken?
        var pages: [[String]] = []
        repeat {
            let page = try await mac.zoneChanges(Self.library, in: .private, since: token, resultsLimit: 4).get()
            pages.append(page.modified.map(\.id.recordName))
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        #expect(pages.map { Set($0) } == [Set(names[0..<4]), Set(names[4..<8]), Set(names[8..<10])], "pages follow change order")
        #expect(pages.flatMap { $0 }.count == names.count)
        #expect(pages.flatMap { $0 } != names, "a seeded shuffle reorders within a page")
        server.deliveryOrder = .shuffled(seed: 7)
        let replay = try await mac.zoneChanges(Self.library, in: .private, resultsLimit: 4).get().modified.map(\.id.recordName)
        #expect(replay == pages[0], "the same seed gives the same order")
    }

    @Test("The server's clock dates every record: creation once, modification at each save")
    func serverDates() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let server = FakeCloudKit(start: start, tick: 0.001)
        let mac = try await Self.device(server)
        let first = try Self.saved(try await mac.modifyRecords(saving: [Self.record("nb_1")], in: .private), CloudRecordID("nb_1", in: Self.library))
        let createdAt = try #require(first.creationDate)
        #expect(createdAt >= start && createdAt < start.addingTimeInterval(1))

        server.advance(by: 90)
        var edit = first
        edit.payload = Data("later".utf8)
        let second = try Self.saved(try await mac.modifyRecords(saving: [edit], in: .private), first.id)
        #expect(second.creationDate == createdAt)
        let modifiedAt = try #require(second.modificationDate)
        #expect(modifiedAt.timeIntervalSince(createdAt) >= 90)
        #expect(try await mac.record(first.id, in: .private).get().modificationDate == modifiedAt)
    }

    @Test("A throttle answers with retryAfter until its window passes, for its account or its zone only")
    func throttles() async throws {
        let server = FakeCloudKit()
        let alice = try await Self.device(server, zones: [Self.library, Self.catalog])
        let bob = try await Self.device(server, user: "_bob", name: "bobMac")

        server.throttle(.requestRateLimited, for: 30, scope: .account("_alice"))
        do {
            _ = try await alice.zoneChanges(Self.library, in: .private)
            Issue.record("a throttled account's call went through")
        } catch let error as CloudError {
            #expect(error.code == .requestRateLimited)
            #expect(abs((error.retryAfter ?? 0) - 30) < 0.01)
        }
        server.advance(by: 10)
        do {
            _ = try await alice.allZones(in: .private)
            Issue.record("a throttled account's call went through")
        } catch let error as CloudError {
            #expect(abs((error.retryAfter ?? 0) - 20) < 0.01)
        }
        #expect(try await bob.allZones(in: .private) == [Self.library], "another account is not throttled")
        server.advance(by: 21)
        #expect(try await alice.allZones(in: .private).count == 2)

        server.throttle(.zoneBusy, for: 5, scope: .zone("Library", owner: "_alice"))
        let busy = Self.record("nb_1")
        let calm = Self.record("src_1", in: Self.catalog, type: "Source")
        let results = try await alice.modifyRecords(saving: [busy, calm], in: .private)
        #expect(results.error(for: busy.id)?.code == .zoneBusy)
        #expect(results.error(for: busy.id)?.retryAfter.map { $0 > 0 && $0 <= 5 } == true)
        #expect(results.savedRecord(calm.id) != nil, "zoneBusy holds one zone")
    }

    @Test("Injected failures stand in for any other error, per call or per record")
    func injectedFailures() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server)
        server.failNext(.modifyRecords, times: 2, with: CloudError(.networkFailure, message: "offline"))
        let record = Self.record("nb_1")
        #expect(await Self.thrownCode { try await mac.modifyRecords(saving: [record], in: .private) } == .networkFailure)
        #expect(await Self.thrownCode { try await mac.modifyRecords(saving: [record], in: .private) } == .networkFailure)
        #expect(try await mac.modifyRecords(saving: [record], in: .private).savedRecord(record.id) != nil)

        server.failRecord("nb_3", with: CloudError(.serverRejectedRequest))
        let batch = ["nb_2", "nb_3", "nb_4"].map { Self.record($0) }
        let results = try await mac.modifyRecords(saving: batch, in: .private)
        #expect(results.error(for: batch[1].id)?.code == .serverRejectedRequest)
        #expect(results.savedRecord(batch[0].id) != nil && results.savedRecord(batch[2].id) != nil)

        server.failNext(.zoneChanges, device: "another device", with: CloudError(.networkUnavailable))
        #expect(try await mac.zoneChanges(Self.library, in: .private).get().modified.count == 3, "aimed at another device")
    }

    @Test("A request or a record over CloudKit's limits is limitExceeded")
    func limits() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server)
        server.limits = FakeCloudKit.Limits(itemsPerRequest: 3, requestBytes: 150, recordBytes: 100, changesPageSize: 200)

        let four = (1...4).map { Self.record("nb_\($0)", payload: "x") }
        #expect(await Self.thrownCode { try await mac.modifyRecords(saving: four, in: .private) } == .limitExceeded)
        #expect(await Self.thrownCode { try await mac.records(four.map(\.id), in: .private, desiredKeys: nil) } == .limitExceeded)
        #expect(try await mac.modifyRecords(saving: Array(four.prefix(3)), in: .private).saved.values.allSatisfy { (try? $0.get()) != nil })

        let large = Self.record("nb_large", payload: String(repeating: "z", count: 120))
        let small = Self.record("nb_small", payload: "s")
        let mixed = try await mac.modifyRecords(saving: [large, small], in: .private)
        #expect(mixed.error(for: large.id)?.code == .limitExceeded)
        #expect(mixed.savedRecord(small.id) != nil)
        let twoNineties = [Self.record("nb_a", payload: String(repeating: "a", count: 90)),
                           Self.record("nb_b", payload: String(repeating: "b", count: 90))]
        #expect(await Self.thrownCode { try await mac.modifyRecords(saving: twoNineties, in: .private) } == .limitExceeded)
    }

    @Test("An atomic request fails every change to a zone when one fails; a non-atomic one keeps the rest")
    func atomicity() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server)
        let macB = server.transport(user: "_alice", device: "macB")
        let id = CloudRecordID("nb_1", in: Self.library)
        let v1 = try Self.saved(try await macA.modifyRecords(saving: [Self.record("nb_1", payload: "v1")], in: .private), id)
        var newer = v1
        newer.payload = Data("v2".utf8)
        _ = try await macA.modifyRecords(saving: [newer], in: .private)
        var stale = v1
        stale.payload = Data("stale".utf8)
        let others = [Self.record("nb_2"), Self.record("nb_3")]

        let atomic = try await macB.modifyRecords(saving: [stale] + others, deleting: [], in: .private,
                                                  savePolicy: .ifServerRecordUnchanged, atomically: true)
        #expect(atomic.error(for: id)?.code == .serverRecordChanged)
        #expect(others.allSatisfy { atomic.error(for: $0.id)?.code == .batchRequestFailed })
        #expect(server.recordNames(zone: "Library", owner: "_alice") == ["nb_1"])

        let separate = try await macB.modifyRecords(saving: [stale] + others, in: .private)
        #expect(separate.error(for: id)?.code == .serverRecordChanged)
        #expect(others.allSatisfy { separate.savedRecord($0.id) != nil })
    }

    @Test("An atomic request spanning two zones fails only the zone that holds the failing change")
    func atomicityIsPerZone() async throws {
        let server = FakeCloudKit()
        let macA = try await Self.device(server, zones: [Self.library, Self.catalog])
        let macB = server.transport(user: "_alice", device: "macB")
        let id = CloudRecordID("nb_1", in: Self.library)
        let v1 = try Self.saved(try await macA.modifyRecords(saving: [Self.record("nb_1", payload: "v1")], in: .private), id)
        var newer = v1
        newer.payload = Data("v2".utf8)
        _ = try await macA.modifyRecords(saving: [newer], in: .private)
        var stale = v1
        stale.payload = Data("stale".utf8)
        let sameZone = Self.record("nb_2")
        let otherZone = Self.record("so_1", in: Self.catalog, type: "Source")

        let atomic = try await macB.modifyRecords(saving: [stale, sameZone, otherZone], deleting: [], in: .private,
                                                  savePolicy: .ifServerRecordUnchanged, atomically: true)
        #expect(atomic.error(for: id)?.code == .serverRecordChanged)
        #expect(atomic.error(for: sameZone.id)?.code == .batchRequestFailed)
        #expect(atomic.savedRecord(otherZone.id) != nil, "CloudKit holds an atomic save per zone, not across the request")
        #expect(server.recordNames(zone: "Library", owner: "_alice") == ["nb_1"])
        #expect(server.recordNames(zone: "Catalog", owner: "_alice") == ["so_1"])
    }

    @Test("A field keeps the kind and the encryption of its first write, and assets are plain files that must exist")
    func fieldSchema() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server, zones: [Self.content])
        _ = try await mac.modifyRecords(saving: [Self.record("ct_1", in: Self.content, type: "Content")], in: .private)

        var plainPayload = CloudRecord(id: CloudRecordID("ct_2", in: Self.content), recordType: "Content")
        plainPayload.fields[CloudRecord.payloadKey] = .bytes(Data("{}".utf8))
        var stringPayload = CloudRecord(id: CloudRecordID("ct_3", in: Self.content), recordType: "Content")
        stringPayload.encryptedFields[CloudRecord.payloadKey] = .string("{}")
        var encryptedAsset = Self.record("ct_4", in: Self.content, type: "Content")
        encryptedAsset.encryptedFields[CloudRecord.assetKey] = .asset(URL(fileURLWithPath: "/dev/null"))
        var missingFile = Self.record("ct_5", in: Self.content, type: "Content")
        missingFile.fields[CloudRecord.assetKey] = .asset(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))

        let results = try await mac.modifyRecords(saving: [plainPayload, stringPayload, encryptedAsset, missingFile], in: .private)
        #expect(results.error(for: plainPayload.id)?.code == .invalidArguments)
        #expect(results.error(for: stringPayload.id)?.code == .invalidArguments)
        #expect(results.error(for: encryptedAsset.id)?.code == .invalidArguments)
        #expect(results.error(for: missingFile.id)?.code == .assetFileNotFound)
        #expect(server.recordNames(zone: "Content", owner: "_alice") == ["ct_1"])
    }

    @Test("Containers and accounts are separate, and the old container's fixtures are read like any zone")
    func containersAndAccounts() async throws {
        let server = FakeCloudKit()
        let library = try await Self.device(server)
        _ = try await library.modifyRecords(saving: [Self.record("nb_1")], in: .private)
        let legacy = server.transport(user: "_alice", container: FakeCloudKit.legacyContainer, device: "macA-legacy")
        #expect(try await legacy.allZones(in: .private).isEmpty)

        var old = CloudRecord(id: CloudRecordID("source-1", in: CloudZoneID("Knowledge")), recordType: "Source",
                              encryptedFields: ["payload": .bytes(Data("{}".utf8)), "userModificationDate": .date(server.now)])
        old.fields["note"] = .string("plain")
        server.put([old], zone: "Knowledge", owner: "_alice", container: FakeCloudKit.legacyContainer)
        #expect(try await legacy.allZones(in: .private) == [CloudZoneID("Knowledge")])
        let read = try await legacy.zoneChanges(CloudZoneID("Knowledge"), in: .private).get().modified
        #expect(read.first?.encryptedFields["userModificationDate"] != nil)
        #expect(read.first?.fields["note"] == .string("plain"))
        #expect(try await library.allZones(in: .private) == [Self.library])

        #expect(try await library.userRecordName() == "_alice")
        server.signIn(library, as: "_bob")
        #expect(try await library.allZones(in: .private).isEmpty, "another account's private database")
        #expect(try await library.userRecordName() == "_bob")
    }

    @Test("Devices writing at once each get their own tags, and a fetch afterwards holds every write once")
    func concurrentDevices() async throws {
        let server = FakeCloudKit()
        _ = try await Self.device(server)
        let devices = (0..<8).map { server.transport(user: "_alice", device: "mac\($0)") }
        let tags = try await withThrowingTaskGroup(of: [String].self) { group in
            for (index, device) in devices.enumerated() {
                group.addTask {
                    var tags: [String] = []
                    for n in 0..<25 {
                        let record = Self.record("nb_\(index)_\(n)")
                        tags.append(try Self.saved(try await device.modifyRecords(saving: [record], in: .private), record.id).changeTag ?? "")
                    }
                    return tags
                }
            }
            return try await group.reduce(into: [String]()) { $0 += $1 }
        }
        #expect(tags.count == 200 && Set(tags).count == 200)
        var token: CloudChangeToken?
        var names: [String] = []
        repeat {
            let page = try await devices[0].zoneChanges(Self.library, in: .private, since: token, resultsLimit: 64).get()
            names += page.modified.map(\.id.recordName)
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        #expect(names.count == 200 && Set(names).count == 200)
    }

    @Test("Every call is logged; a signed-out device is refused, and one that was never used made no call")
    func callLogAndAccounts() async throws {
        let server = FakeCloudKit()
        let mac = try await Self.device(server)
        let idle = server.transport(user: "_alice", device: "idle")
        let signedOut = server.transport(user: nil, device: "signedOut")
        _ = try await mac.zoneChanges(Self.library, in: .private)

        #expect(try await signedOut.accountStatus() == .noAccount)
        #expect(await Self.thrownCode { try await signedOut.allZones(in: .private) } == .notAuthenticated)
        server.setAccountStatus(.temporarilyUnavailable, for: mac)
        #expect(try await mac.accountStatus() == .temporarilyUnavailable)
        server.setAccountStatus(nil, for: mac)
        #expect(try await mac.accountStatus() == .available)

        #expect(idle.calls.isEmpty)
        let macCalls = mac.calls
        #expect(macCalls.map(\.operation) == [.modifyZones, .zoneChanges, .accountStatus, .accountStatus])
        try #require(macCalls.count == 4)
        #expect(macCalls[1].zones == ["Library"] && macCalls[1].database == .private)
        #expect(signedOut.calls.map(\.operation) == [.accountStatus, .allZones])
        #expect(server.calls.count == 6)
        server.resetCalls()
        #expect(server.calls.isEmpty)
    }
}

private extension Result where Failure == CloudError {
    var error: CloudError? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
