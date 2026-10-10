import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// P6 of the seed (docs/cloudkit-schema-design.md §13.4, §13.7, R5-3): after the manifest was written, WP15's
/// `TeamToSpace` makes the owner's teams spaces, and the records it creates are listed in the pass's own
/// manifest delta once the space's records are acknowledged; the delta waits for SpaceSync and resumes
/// from `ck_manifest_pending` after a crash.
@Suite("Cutover space seed", .serialized)
struct CutoverSpaceSeedTests {
    typealias C = CutoverSeedFixture

    private static func environment(_ alice: SpaceTestFixture.Mac) -> CutoverSeedEnvironment {
        var environment = C.environment(alice.device)
        environment.runTeams = { passKey in
            _ = try await TeamToSpace(service: alice.service, passKey: passKey).run(owner: alice.owner)
        }
        return environment
    }

    @Test("A team becomes a space after the manifest, its records are sent by SpaceSync and listed in P6's own delta")
    func teamsSeedAsSpaces() async throws {
        let server = EngineTestDriver.server()
        let (alice, _, _) = try await TeamToSpaceMigrationTests.ownerWithTeam(server)
        try C.activate(alice.store)
        let outcome = try await CutoverSeeder(Self.environment(alice)).run()
        guard case .complete = outcome else { Issue.record("did not finish: \(outcome)"); return }

        let seed = try C.seedMap(server)
        #expect(seed["manifest"] != nil && seed["metadataCompleteAt"] != nil, "the manifest was written before P6")
        let teamID = TeamToSpaceMigrationTests.teamID
        #expect(server.recordNames(zone: "Space-\(teamID)", owner: C.user).contains(SyncSchema.rootRecordName))
        #expect(try C.root(server).fields["manifestDeltas"]?.objectValue?["macaaaaa.p6"] == nil, "SpaceSync has not acknowledged the space's records yet")
        #expect(try alice.device.count("SELECT COUNT(*) FROM ck_manifest_pending WHERE pass_key = 'macaaaaa.p6'") > 0)

        // SpaceSync sends them; the next flush lists them, and the pending rows go.
        try await alice.syncSpaces()
        let writer = C.writer(alice.device)
        let flush = try await SeedManifestWriter(store: alice.device.local, blobs: C.blobs(alice.device), writer: writer).flushDelta(passKey: "macaaaaa.p6")
        guard case .written(let entries) = flush else { Issue.record("the delta was not written: \(flush)"); return }
        #expect(entries > 0)
        let delta = try #require(try C.root(server).fields["manifestDeltas"]?.objectValue?["macaaaaa.p6"].flatMap(FileRef.init(json:)))
        let content = try #require(try await alice.device.local.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.key(PrivateSyncZones.content), in: $0) })
        let listed = try SeedManifestCodec.decode(try await C.blobs(alice.device).fetch(delta, from: content))
        #expect(listed.contains { $0.spaceID == teamID && $0.type == "Notebook" })
        #expect(try alice.device.count("SELECT COUNT(*) FROM ck_manifest_pending WHERE pass_key = 'macaaaaa.p6'") == 0)
    }
}
