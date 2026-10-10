import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The canary (docs/cloudkit-schema-design.md §13.4 step 2): after the last record, walk `Library` and
/// `Catalog` from nil and check sets, not counts. Names the seeder saved must be there; extras written by
/// other devices are never fatal; a missing name or `quotaExceeded` stops before any asset, and the seed's
/// metadata is not announced.
@Suite("Seed canary", .serialized)
struct SeedCanaryTests {
    typealias C = CutoverSeedFixture

    @Test("The set check passes with a concurrent write from another device")
    func concurrentWritePasses() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "canary-ok")
        var environment = C.environment(mac)
        let satellites = CutoverSeederTests.Counter()
        environment.uploadSatellites = {
            _ = satellites.next()
            return CutoverSatelliteTotals()
        }
        // Another device writes a Device record while this one seeds: an extra, never fatal.
        environment.recoverBytes = {
            try MaintenanceFixture.put(mac, .device, DeviceRecord.id("macbbbbb"), [
                "deviceID": .value(.string("macbbbbb")), "platform": .value(.string("mac")), "appVersion": .value(.string("1")), "appBuild": .value(.string("1")),
                "schemaRevision": .value(SyncJSON(SyncSchema.schemaRevision)), "firstSeenAt": .value(SyncJSON(1)), "lastSeenDay": .value(.string("2026-10-04")),
            ])
        }
        let outcome = try await CutoverSeeder(environment).run()
        guard case .complete = outcome else { Issue.record("did not finish: \(outcome)"); return }
        #expect(satellites.next() == 2, "satellites ran once the canary passed")
    }

    @Test("A name the seeder saved and the server lost stops the seed before any asset, with no metadata announced")
    func missingNameStops() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "canary-missing")
        var environment = C.environment(mac)
        let satellites = CutoverSeederTests.Counter()
        environment.uploadSatellites = {
            _ = satellites.next()
            return CutoverSatelliteTotals()
        }
        let transport = mac.transport
        // Between the last record and the canary, a record of the seed disappears from the server.
        environment.recoverBytes = {
            let name = try mac.recordName(.notebook, "nb2")
            _ = try await transport.modifyRecords(deleting: [CloudRecordID(name, in: PrivateSyncZones.library)], in: .private)
        }
        let outcome = try await CutoverSeeder(environment).run()
        #expect(outcome == .stopped(.canaryMissing(count: 1)), "\(outcome)")
        #expect(satellites.next() == 1, "no satellite was uploaded")
        let seed = try C.seedMap(server)
        #expect(seed["metadataCompleteAt"] == nil)
        #expect(seed["canaryPassedAt"] == nil)
        #expect(seed["state"] == .string("seeding"))
    }

    @Test("quotaExceeded stops before any asset")
    func quotaStops() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "canary-quota")
        var environment = C.environment(mac)
        let satellites = CutoverSeederTests.Counter()
        environment.uploadSatellites = {
            _ = satellites.next()
            return CutoverSatelliteTotals()
        }
        environment.recoverBytes = {
            server.failNext(.zoneChanges, device: "canary-quota", with: CloudError(.quotaExceeded))
        }
        let outcome = try await CutoverSeeder(environment).run()
        #expect(outcome == .stopped(.quotaExceeded), "\(outcome)")
        #expect(satellites.next() == 1)
        #expect(try C.seedMap(server)["metadataCompleteAt"] == nil)
    }

    @Test("A full pacer pause stops the satellites after the canary, while the metadata is already announced")
    func pausedForQuota() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "canary-pause")
        var environment = C.environment(mac)
        environment.pause = { .quotaExceeded(owner: nil) }
        let satellites = CutoverSeederTests.Counter()
        environment.uploadSatellites = {
            _ = satellites.next()
            return CutoverSatelliteTotals()
        }
        let outcome = try await CutoverSeeder(environment).run()
        #expect(outcome == .stopped(.quotaExceeded), "\(outcome)")
        #expect(satellites.next() == 1)
        #expect(try C.seedMap(server)["metadataCompleteAt"]?.int64Value != nil, "metadata continues; only satellites stop")
    }
}
