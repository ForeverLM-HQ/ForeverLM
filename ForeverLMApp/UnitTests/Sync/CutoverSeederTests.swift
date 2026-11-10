import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The cutover seed (docs/cloudkit-schema-design.md §13.4): the passes in
/// order and resumable, records dated with their migrated time, the canary, the manifest and the metadata
/// that other Macs, the web and the hosted MCP wait for.
@Suite("Cutover seeder", .serialized)
struct CutoverSeederTests {
    typealias C = CutoverSeedFixture
    typealias F = NotebookSyncFixture

    @Test("A table belongs to the pass of the records it feeds: notebooks and their Entries first, then sources, then the rest")
    func tablesByPass() {
        let tables = SeedTable.tables(in: KnowledgeStore.projectionRegistry)
        func pass(_ name: String) -> SeedPass? { tables.first { $0.name == name }?.pass }
        #expect(pass("learning_goals") == .structure)
        #expect(pass("learning_goal_items") == .structure)
        #expect(pass("sources") == .catalog)
        #expect(pass("group_members") == .catalog, "a playlist's members are the catalog's")
        let order = tables.map(\.pass.order)
        #expect(order == order.sorted(), "passes run in order")
        #expect(tables.firstIndex { $0.name == "learning_goals" }! < tables.firstIndex { $0.name == "sources" }!)
    }

    @Test("The seed sends the library: notebooks, sources and Entries are on the server, the metadata is complete and the seed is complete")
    func seedsTheLibrary() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "seed-all")
        let outcome = try await CutoverSeeder(C.environment(mac)).run()
        guard case .complete(let records) = outcome else { Issue.record("the seed did not finish: \(outcome)"); return }
        #expect(records >= 6)

        #expect(try mac.serverEnvelope(.notebook, "nb1")?.fields["title"] == .string("One"))
        #expect(try mac.serverEnvelope(.notebook, "nb2") != nil)
        for id in ["s1", "s2", "s3"] { #expect(try mac.serverEnvelope(.source, id, zone: "Catalog") != nil, "\(id) is in Catalog") }
        let entry = SyncIdentity.entryID(containerID: "nb1", itemKind: "source", itemID: "s1")
        #expect(try mac.serverEnvelope(.entry, entry)?.fields["itemID"] == .string("s1"))
        #expect(try mac.outboxRows() == 0, "everything went out")

        let seed = try C.seedMap(server)
        #expect(seed["state"] == .string("complete"))
        #expect(seed["metadataCompleteAt"]?.int64Value != nil)
        #expect(seed["canaryPassedAt"]?.int64Value != nil)
        #expect(seed["completedAt"]?.int64Value != nil)
        #expect(seed["manifest"].flatMap(FileRef.init(json:)) != nil, "Finish keeps the manifest in the seed map")
        #expect(seed["counts"]?.objectValue?["records"]?.intValue == records)
    }

    @Test("A deferred Mac whose own claim lapsed resumes its seed: it did not start over, and the seed completes from where it was")
    func resumesItsOwnLapsedSeed() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "seed-deferred-resume")
        // A `deferred` activation whose catch-up ran, as the product owner's Mac after build 184's catch-up.
        try C.activate(mac.store, mode: "deferred", catchUpAt: 700_000_000)

        // Sends went out after the earlier stop released the hold: a source edited since the activation is on the server.
        try F.addSource(mac.store, "s4")
        EngineTestDriver.follow(server)
        try await mac.engine.sendChanges()
        #expect(try mac.serverEnvelope(.source, "s4", zone: "Catalog") != nil)

        // The root as the earlier launch left it: `seeding`, and this Mac's claim lapsed an hour ago.
        let library = try #require(try await mac.local.perform { try BlobZone.resolve(zoneKey: PrivateSyncZones.libraryKey, in: $0) })
        var lapse = RecordPatch(.zoneRoot, id: SyncSchema.rootRecordName)
        lapse.changes["seedClaim"] = .value(CutoverSeeder.claimValue(device: mac.deviceID, at: C.clock().addingTimeInterval(-90 * 60)))
        let lapsed = try await C.writer(mac).save([MaintenanceWriter.Write(zone: library, patch: lapse)]).first
        #expect(lapsed == .saved)
        let before = try C.root(server)
        #expect(CutoverRootState(root: before).state == "seeding")
        #expect(CutoverRootState(root: before).claimIsLive(at: SyncTime.milliseconds(C.clock())) == false)
        let startedAt = try #require(try C.seedMap(server)["startedAt"]?.int64Value)

        let outcome = try await CutoverSeeder(C.environment(mac)).run()
        guard case .complete = outcome else { Issue.record("the seed did not finish: \(outcome)"); return }

        let seed = try C.seedMap(server)
        #expect(seed["state"] == .string("complete"))
        #expect(seed["startedAt"]?.int64Value == startedAt, "the seed resumed: it did not start over")
        #expect(try C.root(server).fields["seedClaim"]?.objectValue?["device"] == .string(mac.deviceID), "its own claim, taken again")
        for id in ["s1", "s2", "s3", "s4"] { #expect(try mac.serverEnvelope(.source, id, zone: "Catalog") != nil, "\(id) is in Catalog") }
        #expect(try mac.serverEnvelope(.notebook, "nb1") != nil)
        #expect(try mac.outboxRows() == 0)
    }

    @Test("A record takes its migrated time: the row's own, else the walk's start")
    func migratedTimes() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "seed-times")
        let store = mac.store
        _ = try await CutoverSeeder(C.environment(mac)).run()
        let offset = try #require(try store.replica.loadClock()?.serverOffset)
        // The clock's offset moves a few milliseconds as acknowledged saves add samples.
        func expected(_ seconds: Double) -> Int64 { SyncTime.milliseconds(cocoaSeconds: seconds) + offset }
        func isAbout(_ actual: Int64?, _ seconds: Double) -> Bool { actual.map { abs($0 - expected(seconds)) < 200 } ?? false }

        // A source's address row has no time of its own: the walk's start.
        for id in ["s1", "s2", "s3"] {
            #expect(isAbout(C.stampMilliseconds(try mac.serverEnvelope(.source, id, zone: "Catalog"), "title"), 700_000_000), "\(id)")
        }
        // A notebook's row has its own: updated_at 1000.
        #expect(isAbout(C.stampMilliseconds(try mac.serverEnvelope(.notebook, "nb1"), "title"), 1000))
    }

    @Test("A seed killed between batches resumes at its cursor and finishes with every record once")
    func resumeAfterKill() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "seed-resume")
        var first = C.environment(mac)
        first.configuration.batchSize = 1
        let engine = mac.engine
        let sent = Counter()
        first.send = {
            if sent.next() == 4 { throw CloudError(.networkUnavailable, message: "killed") }
            EngineTestDriver.follow(server)
            try await engine.sendChanges()
        }
        await #expect(throws: CloudError.self) { _ = try await CutoverSeeder(first).run() }
        #expect(try mac.count("SELECT COUNT(*) FROM ck_seed_cursor") > 0, "the cursors were kept")
        #expect(try C.seedMap(server)["state"] == .string("seeding"))
        let before = server.recordNames(zone: "Library", owner: C.user).count + server.recordNames(zone: "Catalog", owner: C.user).count

        var second = C.environment(mac)
        second.configuration.batchSize = 1
        let outcome = try await CutoverSeeder(second).run()
        guard case .complete = outcome else { Issue.record("did not finish: \(outcome)"); return }
        #expect(try mac.serverEnvelope(.notebook, "nb2") != nil)
        for id in ["s1", "s2", "s3"] { #expect(try mac.serverEnvelope(.source, id, zone: "Catalog") != nil) }
        let after = server.recordNames(zone: "Library", owner: C.user).count + server.recordNames(zone: "Catalog", owner: C.user).count
        #expect(after > before)
        #expect(try mac.outboxRows() == 0)
    }

    @Test("An edit made while the seed runs waits for its family's pass to begin: a source edited before P2 is not sent by the feeder")
    func editWaitsForItsFamily() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "seed-gate")
        var environment = C.environment(mac)
        let observed = Box()
        environment.prepare = { pass, state in
            guard pass == .structure else { return }
            // Before P1: nothing of any family has begun, so a source edited now is held back.
            try state.connection.execute("UPDATE articles SET title = 'Edited meanwhile' WHERE source_id = 's2'")
            let feeder = OutboxFeeder(connection: state.connection, registry: KnowledgeStore.projectionRegistry)
            let sent = try feeder.nextBatch(now: Date().addingTimeInterval(600))
            observed.set(held: try state.replica.seedHeldTypes(), sentSource: sent.contains { $0.recordType == .source })
        }
        let outcome = try await CutoverSeeder(environment).run()
        guard case .complete = outcome else { Issue.record("did not finish: \(outcome)"); return }
        #expect(observed.held.contains(.source))
        #expect(!observed.sentSource, "the feeder holds the source's edit back")
        #expect(try mac.store.replica.seedHeldTypes().isEmpty, "the gate is released when the seed ends")
        #expect(try mac.serverEnvelope(.source, "s2", zone: "Catalog")?.fields["title"] == .string("Edited meanwhile"), "the edit went out with its pass")
    }

    @Test("A highlight is seeded at its own time, which it keeps in Unix seconds")
    func highlightsAreSeeded() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "seed-highlights")
        let store = mac.store
        let unix = 1_700_000_000.0
        try C.quietly(store) {
            try HighlightRow(id: "hl_own", sourceID: "s1", pageIndex: 0, geometryJSON: "[]", text: "Complex I", color: SourceHighlightColor.default.rawValue,
                             createdAt: unix, updatedAt: unix).save(store)
        }
        let outcome = try await CutoverSeeder(C.environment(mac)).run()
        guard case .complete = outcome else { Issue.record("the seed did not finish: \(outcome)"); return }
        let offset = try #require(try store.replica.loadClock()?.serverOffset)
        func isAbout(_ actual: Int64?, _ seconds: Double) -> Bool {
            actual.map { abs($0 - (SyncTime.milliseconds(cocoaSeconds: seconds) + offset)) < 200 } ?? false
        }
        let own = unix - Date.timeIntervalBetween1970AndReferenceDate
        #expect(isAbout(C.stampMilliseconds(try mac.serverEnvelope(.highlight, "hl_own"), "color"), own), "the row's own time, converted from Unix seconds")
        #expect(try mac.outboxRows() == 0, "every highlight went out")
    }

    @Test("A row is never dated after now: a time in the future takes the walk's start, so the feeder sends it")
    func futureTimesTakeTheWalksStart() throws {
        let (root, store) = try F.makeStore("seed-future")
        defer { try? FileManager.default.removeItem(at: root) }
        try C.quietly(store) {
            try HighlightRow(id: "hl_future", sourceID: "s1", pageIndex: 0, geometryJSON: "[]", text: "ATP", color: SourceHighlightColor.default.rawValue,
                             createdAt: 1_000, updatedAt: Date().timeIntervalSince1970 + 86_400).save(store)
        }
        let registry = KnowledgeStore.projectionRegistry
        let table = try #require(SeedTable.tables(in: registry).first { $0.name == "source_highlights" })
        let reader = SeedRowReader(connection: store, registry: registry, fallbackTime: 700_000_000)
        let row = try #require(try reader.nextBatch(of: table, after: nil, limit: 10).first)
        #expect(row.time == 700_000_000)
    }

    @Test("A team chat's exchanges are the space's: the seed's personal passes leave them to P6, as the feeder places them")
    func teamChatExchangesAreTheSpaces() throws {
        let (root, store) = try F.makeStore("seed-team-exchanges")
        defer { try? FileManager.default.removeItem(at: root) }
        try F.prepareReplica(store)
        try ChatSyncFixture.addChat(store, "teamchat-1")
        try ChatSyncFixture.addChat(store, "chat-1")
        let team = try ChatSyncFixture.addExchange(store, chat: "teamchat-1")
        let own = try ChatSyncFixture.addExchange(store, chat: "chat-1")
        try store.execute("INSERT INTO ck_identity (zone_key, record_type, wire_id, local_id) VALUES (?, 'Chat', 'teamchat-1', 'teamchat-1')",
                          [.text(ChatSyncFixture.spaceZoneKey)])
        let registry = KnowledgeStore.projectionRegistry
        let table = try #require(SeedTable.tables(in: registry).first { $0.name == "review_exchanges" })
        let reader = SeedRowReader(connection: store, registry: registry, fallbackTime: 0)
        var refs: [String: [SeedRecordRef]] = [:]
        for row in try reader.nextBatch(of: table, after: nil, limit: 10) { refs[row.localKey] = try reader.records(of: row, in: table) }

        let teamExchange = try #require(refs[team]?.first { $0.type == .exchange })
        #expect(teamExchange.isSpaceCopy && teamExchange.zoneKey == ChatSyncFixture.spaceZoneKey && teamExchange.wireID == team)
        #expect(refs[own]?.first { $0.type == .exchange }?.isSpaceCopy == false, "a personal chat's exchange is the library's")
        #expect(try SeedRowDecider.spaces.action(for: refs[team] ?? [], in: store) == .enqueue, "P6 takes it")
    }

    @Test("The seed never reports complete while a record its passes handed the outbox is unsent, and a later round finishes it")
    func unsentRecordsHoldTheSeed() async throws {
        let server = EngineTestDriver.server()
        let mac = try await C.seeder(server, name: "seed-unsent")
        let store = mac.store
        try C.quietly(store) {
            try HighlightRow(id: "hl_stuck", sourceID: "s1", pageIndex: 0, geometryJSON: "[]", text: "Cristae", color: SourceHighlightColor.default.rawValue,
                             createdAt: 1_000, updatedAt: 1_000).save(store)
        }
        // An outbox row dated in the future: the feeder never finds it due, and the engine's count never sees it.
        try store.execute("INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at) VALUES ('source_highlights', 'hl_stuck', '__row', ?)",
                          [.real(Date().timeIntervalSinceReferenceDate + 86_400 * 365)])
        let first = try await CutoverSeeder(C.environment(mac)).run()
        #expect(first == .stopped(.unsent(count: 1)), "\(first)")
        #expect(try C.seedMap(server)["metadataCompleteAt"] == nil, "no canary and no manifest")
        #expect(try mac.serverEnvelope(.notebook, "nb1") != nil, "the passes themselves ran")

        try store.execute("UPDATE ck_outbox_fields SET dirty_at = 1000 WHERE source_table = 'source_highlights'")
        let second = try await CutoverSeeder(C.environment(mac)).run()
        guard case .complete = second else { Issue.record("the seed did not finish: \(second)"); return }
        #expect(try mac.serverEnvelope(.highlight, "hl_stuck") != nil)
        #expect(try C.seedMap(server)["state"] == .string("complete"))
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _held: Set<SyncRecordType> = []
        private var _sent = false
        func set(held: Set<SyncRecordType>, sentSource: Bool) { lock.withLock { _held = held; _sent = sentSource } }
        var held: Set<SyncRecordType> { lock.withLock { _held } }
        var sentSource: Bool { lock.withLock { _sent } }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
}
