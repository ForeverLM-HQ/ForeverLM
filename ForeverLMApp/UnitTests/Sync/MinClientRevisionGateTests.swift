import Foundation
import Testing
@testable import ForeverLM

/// `ZoneRoot.minClientRevision` and `Device.schemaRevision` (docs/cloudkit-schema-design.md §12.5,
/// D31): a client below the root's revision keeps fetching and stops sending; a change of meaning
/// is switched on only when every Device seen in the last 30 days reports the revision.
@Suite("Minimum client revision gate", .serialized)
struct MinClientRevisionGateTests {
    @Test("A root that asks for a newer client holds every send while fetches go on, until it no longer does")
    func raisedRootHoldsSends() async throws {
        let server = EngineTestDriver.server()
        let a = try EngineTestDevice(server, name: "mcr-a", deviceID: "macaaaaa")
        try await a.bootstrap()
        try await a.sync()
        let newer = SyncSchema.schemaRevision + 1
        try MaintenanceFixture.patchRoot(server, ["minClientRevision": .value(SyncJSON(newer))])
        try a.exec("INSERT INTO test_courses (id, title) VALUES ('c1', 'Cells')")
        try MaintenanceFixture.put(a, .course, "c2", ["title": .value(.string("Genes")), "status": .value(.string("active"))])
        try await a.sync()
        #expect(await a.engine.sendHold == .updateRequired(minClientRevision: newer))
        #expect(try a.serverEnvelope(.course, "c1") == nil, "nothing is sent")
        #expect(try a.count("SELECT COUNT(*) FROM test_courses WHERE id = 'c2'") == 1, "fetches go on")
        #expect(try a.outboxRows() > 0, "the change waits in the outbox")

        // Only a test lowers it (the field is X); the held change then goes out.
        try MaintenanceFixture.patchRoot(server, ["minClientRevision": .value(SyncJSON(SyncSchema.schemaRevision))], at: 1_759_600_000_000)
        await EngineTestDriver.pause()
        try await a.sync()
        #expect(await a.engine.sendHold == nil)
        #expect(try a.serverEnvelope(.course, "c1")?.fields["title"] == .string("Cells"))
    }

    @Test("A change of meaning waits for every Device seen in 30 days, or for the root's minimum")
    func deviceRevisions() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let utc = MaintenanceFixture.utc
        func device(_ day: String, _ revision: Int) throws -> SyncEnvelope {
            try MaintenanceFixture.envelope(.device, "dev:x", ["lastSeenDay": .value(.string(day)), "schemaRevision": .value(SyncJSON(revision))], saltID: "00000000")
        }
        let recentOld = try! device(MaintenanceDays.day(now, minus: 3, timeZone: utc), 1)
        let recentNew = try! device(MaintenanceDays.day(now, minus: 1, timeZone: utc), 2)
        let longGone = try! device(MaintenanceDays.day(now, minus: 45, timeZone: utc), 1)
        #expect(SchemaRevisionGate.allows(2, devices: [recentNew, longGone], minClientRevision: 1, now: now, timeZone: utc))
        #expect(!SchemaRevisionGate.allows(2, devices: [recentNew, recentOld], minClientRevision: 1, now: now, timeZone: utc))
        #expect(SchemaRevisionGate.allows(2, devices: [recentNew, recentOld], minClientRevision: 2, now: now, timeZone: utc))
    }
}

