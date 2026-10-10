import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The seed's bytes (docs/cloudkit-schema-design.md §13.4 step 2 P5, §3.5.30): a record carries the
/// pointer to a satellite the Mac has laid out, and the bytes follow once the canary passed, existence-
/// checked first so a repeated seed uploads nothing twice.
@Suite("Cutover satellites", .serialized)
struct CutoverSatelliteTests {
    typealias C = CutoverSeedFixture

    /// The sample library with each source's text laid out as the activation's backfill leaves it: pointers
    /// in `source_files`, the gzip bytes staged beside the store, no outbox row.
    private static func libraryWithText(_ mac: EngineTestDevice) throws {
        try C.quietly(mac.store) {
            for id in ["s1", "s2", "s3"] {
                try mac.store.execute("INSERT INTO source_content (source_id, content) VALUES (?, ?)", [.text(id), .text("Body of \(id). " + String(repeating: "word ", count: 40))])
            }
        }
        try mac.store.queueSourceFilesBackfill()
        #expect(try mac.store.runSourceFilesBackfill(limit: 50) == 3)
    }

    private static func satellites(_ mac: EngineTestDevice) -> CutoverSatellites {
        let engine = mac.engine
        return CutoverSatellites(store: mac.local, blobs: C.blobs(mac), pendingCount: { await engine.pendingCount })
    }

    private static func textRef(_ mac: EngineTestDevice, _ id: String) throws -> FileRef {
        let json = try #require(try mac.text("SELECT file_ref FROM source_files WHERE source_id = ? AND role = 'text'", [.text(id)]))
        return try #require(ArtifactBody.fileRef(json))
    }

    @Test("A source's record carries its text pointer before the bytes exist, and the bytes follow the canary")
    func pointersBeforeBytes() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "sat-order")
        try Self.libraryWithText(mac)
        var environment = C.environment(mac)
        let sat = Self.satellites(mac)
        let before = CutoverSeederTests.Counter()
        // At the canary no satellite exists yet: the pointers are on the records, the bytes are not.
        environment.recoverBytes = {
            let names = server.recordNames(zone: "Content", owner: C.user)
            let files = try (1...3).map { try Self.textRef(mac, "s\($0)") }
            let held = try files.filter { try MaintenanceFixture.onServer(mac, $0) }
            _ = names
            if held.isEmpty { _ = before.next() }
        }
        environment.uploadSatellites = { try await sat.upload() }
        let outcome = try await CutoverSeeder(environment).run()
        guard case .complete = outcome else { Issue.record("did not finish: \(outcome)"); return }
        #expect(before.next() == 2, "no text satellite existed before the canary")

        for id in ["s1", "s2", "s3"] {
            let ref = try Self.textRef(mac, id)
            let pointer = try mac.serverEnvelope(.source, id, zone: "Catalog")?.fields["files"]?.objectValue?["text"].flatMap(FileRef.init(json:))
            #expect(pointer == ref, "\(id)'s record names the satellite")
            #expect(try MaintenanceFixture.onServer(mac, ref), "\(id)'s text is on the server")
        }
        let counts = try C.seedMap(server)["counts"]?.objectValue
        #expect(counts?["satellites"]?.intValue == 3)
        #expect((counts?["bytes"]?.intValue ?? 0) > 0)
    }

    @Test("A repeated seed uploads no satellite twice: each is looked up by name and its pointer kept")
    func existenceCheckSkipsUploaded() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "sat-twice")
        try Self.libraryWithText(mac)
        let sat = Self.satellites(mac)
        var environment = C.environment(mac)
        environment.uploadSatellites = { try await sat.upload() }
        _ = try await CutoverSeeder(environment).run()
        let created = server.recordNames(zone: "Content", owner: C.user).count

        // Forget that this Mac acknowledged them: the next upload checks the server by name.
        try mac.store.execute("DELETE FROM ck_blobs")
        mac.transport.server.resetCalls()
        let totals = try await sat.upload()
        #expect(totals.satellites == 3)
        let content = CloudZoneID("Content")
        let saves = mac.transport.calls.filter { $0.operation == .modifyRecords && $0.zones.contains(content.zoneName) }
        #expect(saves.isEmpty, "nothing was saved again")
        #expect(server.recordNames(zone: "Content", owner: C.user).count == created)
    }

    @Test("A file that changed since its pointer was laid out is not uploaded under the old hash")
    func changedFileIsSkipped() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "sat-changed")
        try Self.libraryWithText(mac)
        let ref = try Self.textRef(mac, "s2")
        let path = try #require(try mac.text("SELECT local_path FROM source_files WHERE source_id = 's2' AND role = 'text'"))
        let url = URL(fileURLWithPath: mac.store.dbPath).deletingLastPathComponent().appendingPathComponent(path)
        try SyncGzip.compress(Data("something else".utf8)).write(to: url)
        let totals = try await Self.satellites(mac).upload()
        #expect(totals.satellites == 2)
        #expect(try !MaintenanceFixture.onServer(mac, ref))
    }

    @Test("Source files of a space copy are not the library's: only team_id NULL rows are uploaded")
    func spaceCopiesAreLeftOut() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "sat-team")
        try Self.libraryWithText(mac)
        try mac.store.execute("UPDATE sources SET team_id = 'team-1' WHERE id = 's3'")
        let totals = try await Self.satellites(mac).upload()
        #expect(totals.satellites == 2)
    }
}
