import Foundation
import Testing
@testable import ForeverLM

/// Satellite garbage collection (docs/cloudkit-schema-design.md §5.8, D11, PD-11, R2-2, R3-m20): two
/// sweeps at least 7 days apart, 60 days of age, a fresh fetch and the owner's re-read before any
/// delete; a superseded Doc body after 2 days, judged a whole body at a time. The maintenance Mac's
/// clock is the server's here, so days pass by advancing it.
@Suite("Satellite GC", .serialized)
struct SatelliteGCTests {
    private typealias F = MaintenanceFixture
    private static let day: TimeInterval = 86_400
    private static let content = "private/Content"

    private static func mac(_ server: FakeCloudKit, _ name: String, deviceID: String = "macaaaaa",
                            client: ZoneBootstrap.Client = .macHoldingLibrary) async throws -> EngineTestDevice {
        let mac = try EngineTestDevice(server, name: name, deviceID: deviceID)
        try await mac.bootstrap(client)
        try await mac.sync()
        return mac
    }

    private static func upload(_ mac: EngineTestDevice, _ text: String, owner: String, role: String = "pdf",
                               ownerType: SyncRecordType = .source, keeping: FileRef? = nil) async throws -> FileRef {
        let server = mac.server
        let blobs = F.blobs(mac, clock: { server.now })
        return try await blobs.upload(Data(text.utf8), owner: owner, ownerType: ownerType, role: role, mime: "application/pdf",
                                      encoding: .identity, into: .personal(salt: try mac.personalSalt() ?? Data()), keeping: keeping)
    }

    private static func point(_ mac: EngineTestDevice, source id: String, at file: FileRef) throws {
        try F.put(mac, .source, id, ["title": .value(.string(id)), "files": .elements(["pdf": file.value])], zone: "Catalog",
                  at: F.milliseconds(mac.server.now))
    }

    @Test("A crash between upload and pointer is collected after two sweeps and 60 days; a named satellite never is")
    func crashBeforePointer() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "gc-crash")
        let orphan = try await Self.upload(a, "a PDF whose pointer never went out", owner: "s1")
        let named = try await Self.upload(a, "a PDF its source names", owner: "s2")
        try Self.point(a, source: "s2", at: named)
        try await a.sync()
        let service = F.service(a, clock: { server.now })

        var report = try await service.collectSatellites(in: Self.content)
        #expect(report.listed == 2)
        #expect(report.unreachable == 1)
        #expect(report.deleted == 0)
        server.advance(by: 8 * Self.day)
        #expect(try await service.collectSatellites(in: Self.content).deleted == 0, "two sweeps, but younger than 60 days")
        server.advance(by: 53 * Self.day)
        report = try await service.collectSatellites(in: Self.content)
        #expect(report.deleted == 1)
        #expect(try !F.onServer(a, orphan))
        #expect(try F.onServer(a, named))
        #expect(try a.count("SELECT COUNT(*) FROM ck_blobs WHERE zone_key = ?", [.text(Self.content)]) == 1)
    }

    @Test("A satellite only a record this build quarantined names is not collected (F24)")
    func quarantinedRecordKeepsItsSatellite() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "gc-quarantine")
        let held = try await Self.upload(a, "named by a newer build's record", owner: "s9")
        let newer = SyncJSON.object([
            "env": SyncJSON(99), "type": .string("Source"), "id": .string("s9"),
            "fields": .object(["files": .object(["pdf": held.value])]),
        ])
        let hex = newer.serialized().map { String(format: "%02x", $0) }.joined()
        try a.exec("""
            INSERT INTO ck_quarantine (zone_key, record_name, record_type, reason, payload, quarantined_at)
            VALUES ('private/Catalog', 'src_s9', 'Source', 'unsupportedEnvelope', X'\(hex)', 0)
        """)
        let service = F.service(a, clock: { server.now })
        #expect(try await service.collectSatellites(in: Self.content).unreachable == 0, "named by the quarantined record")
        server.advance(by: 8 * Self.day)
        _ = try await service.collectSatellites(in: Self.content)
        server.advance(by: 53 * Self.day)
        #expect(try await service.collectSatellites(in: Self.content).deleted == 0)
        #expect(try F.onServer(a, held))
    }

    @Test("A single sweep, however old the satellite, deletes nothing")
    func oneSweepIsNotEnough() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "gc-one-sweep")
        let orphan = try await Self.upload(a, "an old orphan", owner: "s1")
        server.advance(by: 90 * Self.day)
        let report = try await F.service(a, clock: { server.now }).collectSatellites(in: Self.content)
        #expect(report.unreachable == 1)
        #expect(report.deleted == 0)
        #expect(try F.onServer(a, orphan))
    }

    @Test("A re-pointed satellite is kept: by the fresh fetch before the delete, and by the owner's re-read on the server")
    func repointedIsRechecked() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "gc-repoint")
        let fetched = try await Self.upload(a, "pointed at later, fetched", owner: "s3")
        let reread = try await Self.upload(a, "pointed at later, read again", owner: "s4")
        let other = try await Self.mac(server, "gc-repoint-other", deviceID: "macbbbbb", client: .macWithoutLibrary)
        _ = try await F.service(a, clock: { server.now }).collectSatellites(in: Self.content)
        server.advance(by: 61 * Self.day)
        // Another device points at both after the sweep marked them.
        try Self.point(other, source: "s3", at: fetched)
        try Self.point(other, source: "s4", at: reread)

        let withFetch = try await F.service(a, clock: { server.now }).collectSatellites(in: Self.content)
        #expect(withFetch.candidates == 2)
        #expect(withFetch.deleted == 0, "the fetch brought both pointers in")
        #expect(try F.onServer(a, fetched))

        // Here the fetch brings nothing (a pointer the change feed has not delivered yet): the owner's
        // re-read by name still finds it.
        let b = try await Self.mac(server, "gc-repoint-b", deviceID: "macbbbbc", client: .macWithoutLibrary)
        let late = try await Self.upload(b, "pointed at, never fetched here", owner: "s5")
        _ = try await F.service(b, fetch: false, clock: { server.now }).collectSatellites(in: Self.content)
        server.advance(by: 61 * Self.day)
        try Self.point(other, source: "s5", at: late)
        let reread5 = try await F.service(b, fetch: false, clock: { server.now }).collectSatellites(in: Self.content)
        #expect(reread5.kept >= 1)
        #expect(try F.onServer(b, late))
    }

    @Test("A pointer delayed five weeks survives and re-verifies; a re-import after GC uploads the bytes again")
    func delayedPointerAndReimport() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "gc-delayed")
        let delayed = try await Self.upload(a, "a PDF whose pointer waits on a closed laptop", owner: "s6")
        let service = F.service(a, clock: { server.now })
        _ = try await service.collectSatellites(in: Self.content)
        server.advance(by: 35 * Self.day)
        #expect(try await service.collectSatellites(in: Self.content).deleted == 0)
        // The writer re-verifies a part acknowledged long ago before pointing at it (rule 4).
        let again = try await Self.upload(a, "a PDF whose pointer waits on a closed laptop", owner: "s6", keeping: delayed)
        #expect(again == delayed)
        try Self.point(a, source: "s6", at: delayed)
        try await a.sync()
        server.advance(by: 30 * Self.day)
        #expect(try await service.collectSatellites(in: Self.content).unreachable == 0)
        #expect(try F.onServer(a, delayed))

        let reimported = try await Self.upload(a, "a PDF imported, dropped and imported again", owner: "s7")
        _ = try await service.collectSatellites(in: Self.content)
        server.advance(by: 61 * Self.day)
        #expect(try await service.collectSatellites(in: Self.content).deleted == 1)
        #expect(try !F.onServer(a, reimported))
        _ = try await Self.upload(a, "a PDF imported, dropped and imported again", owner: "s7")
        #expect(try F.onServer(a, reimported), "the import uploads what GC took")
    }

    @Test("A laptop closed for 3 days between a body's acknowledgement and its pointer keeps that body, and the send re-verifies it")
    func closedLaptopKeepsBody() async throws {
        let server = EngineTestDriver.server()
        let maintenance = try await Self.mac(server, "gc-laptop-m")
        let laptop = try await Self.mac(server, "gc-laptop-l", deviceID: "macbbbbb", client: .macWithoutLibrary)
        let (pointed, pointedParts) = F.body("Version one", owner: "art1")
        try F.putPart(maintenance, pointed, 0, pointedParts[0])
        try F.put(maintenance, .artifact, "art1", ["title": .value(.string("Plan")), "body": .value(pointed.value)], at: F.milliseconds(server.now))
        try await maintenance.sync()
        server.advance(by: 3_600)
        let pending = try await Self.upload(laptop, "Version two, written before the lid closed", owner: "art1", role: "body", ownerType: .artifact)

        let service = F.service(maintenance, clock: { server.now })
        for _ in 0..<3 {
            server.advance(by: Self.day + 1)
            #expect(try await service.collectSatellites(in: Self.content).deleted == 0)
        }
        #expect(try F.onServer(maintenance, pending), "a body newer than the pointed one never takes the fast path")
        server.resetCalls()
        let verified = try await Self.upload(laptop, "Version two, written before the lid closed", owner: "art1", role: "body", ownerType: .artifact, keeping: pending)
        #expect(verified == pending)
        #expect(server.calls.contains { $0.device == "gc-laptop-l" && $0.operation == .records }, "looked up by name first")
        #expect(!server.calls.contains { $0.device == "gc-laptop-l" && $0.operation == .modifyRecords }, "and found there, so not sent again")
    }

    @Test("A Recovered Doc made after the last sweep keeps the bytes it copied")
    func recoveredDocKeepsBytes() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "gc-recovered")
        let other = try await Self.mac(server, "gc-recovered-o", deviceID: "macbbbbb", client: .macWithoutLibrary)
        let lost = try await Self.upload(a, "the losing side of an overlap", owner: "art2", role: "body", ownerType: .artifact)
        let service = F.service(a, clock: { server.now })
        _ = try await service.collectSatellites(in: Self.content)
        server.advance(by: 61 * Self.day)
        try F.put(other, .artifact, "recovered:art2:1", ["title": .value(.string("Recovered: Plan")), "body": .value(lost.value)],
                  at: F.milliseconds(server.now))
        let report = try await service.collectSatellites(in: Self.content)
        #expect(report.deleted == 0)
        #expect(try F.onServer(a, lost), "the copy names the owner's satellites (D41)")
    }

    @Test("A superseded body goes after 2 days, whole; one whose upload interleaved with the pointed body's, or one still uploading, never takes the fast path")
    func supersededBodies() async throws {
        let server = EngineTestDriver.server()
        let a = try await Self.mac(server, "gc-bodies")
        let (old, oldParts) = F.body("The first draft of the plan, long enough for two parts", owner: "art3", parts: 2)
        let (interleaved, interleavedParts) = F.body("A second draft whose upload interleaved", owner: "art3", parts: 2)
        let (partial, partialParts) = F.body("A draft another device is still uploading", owner: "art3", parts: 2)
        let (current, currentParts) = F.body("The draft the pointer names now, in two parts", owner: "art3", parts: 2)
        try F.putPart(a, old, 0, oldParts[0])
        try F.putPart(a, old, 1, oldParts[1])
        // Older than the pointed body, but only one of its two parts is there yet.
        try F.putPart(a, partial, 0, partialParts[0])
        server.advance(by: 60)
        try F.putPart(a, interleaved, 0, interleavedParts[0])
        server.advance(by: 60)
        try F.putPart(a, current, 0, currentParts[0])
        server.advance(by: 60)
        try F.putPart(a, interleaved, 1, interleavedParts[1])
        server.advance(by: 60)
        try F.putPart(a, current, 1, currentParts[1])
        server.advance(by: 60)
        try F.put(a, .artifact, "art3", ["title": .value(.string("Plan")), "body": .value(current.value)], at: F.milliseconds(server.now))
        try await a.sync()
        server.advance(by: 3_600)

        let service = F.service(a, clock: { server.now })
        let first = try await service.collectSatellites(in: Self.content)
        #expect(first.unreachable == 5)
        #expect(first.deleted == 0)
        server.advance(by: 2 * Self.day + 3_600)
        let second = try await service.collectSatellites(in: Self.content)
        #expect(second.deleted == 2)
        #expect(try !F.onServer(a, old), "the whole older body goes")
        #expect(try F.onServer(a, interleaved), "its newest part came after the pointed body's oldest")
        #expect(try F.names(a, partial).prefix(1).allSatisfy { server.storedRecord($0, zone: "Content", owner: F.user) != nil },
                "a body with a part still missing is not judged yet")
        #expect(try F.onServer(a, current))
    }
}
