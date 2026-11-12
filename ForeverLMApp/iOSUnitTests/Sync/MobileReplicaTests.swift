import CloudKit
import Foundation
import Testing
@testable import ForeverLM

/// The iPhone's replica (docs/cloudkit-schema-design.md D33, §2.3, §2.5, §6.2, §14.2 WP19): the
/// replica tables and the index the screens query, filled when the private engine applies what it
/// fetches, moved by updates, deletions, the replica audit and purges, merged with the phone's own
/// pending patches, and built again only when its version moves.
@Suite("iPhone replica", .serialized)
struct MobileReplicaTests {
    static let alice = "alice"
    static let catalog = CloudZoneID(SyncZone.catalog.rawValue)
    static let library = CloudZoneID(SyncZone.library.rawValue)

    /// Alice's library as her Mac seeded it: a notebook with one source, a chat, a card and a Setting.
    static func seededLibrary() throws -> FakeCloudKit {
        let server = FakeCloudKit(start: Date())
        try MobileSyncFixture.makeLibrary(server, owner: alice)
        server.put([
            try MobileSyncFixture.record(.notebook, "nb1", [
                "title": .string("🧬 Cells"), "status": .string("active"), "createdAt": SyncJSON(1_759_000_000_000),
                "editedAt": SyncJSON(1_759_100_000_000),
            ], in: library),
            try MobileSyncFixture.record(.entry, "en:nb1:source:src1", [
                "containerKind": .string("notebook"), "containerID": .string("nb1"), "itemKind": .string("source"),
                "itemID": .string("src1"), "state": .string("active"), "orderKey": .string("a0"), "origin": .string("added"),
                "addedAt": SyncJSON(1_759_000_000_000),
            ], in: library),
            try MobileSyncFixture.record(.chat, "ch1", [
                "kind": .string("chat"), "notebookID": .string("nb1"), "title": .string("Why membranes"), "status": .string("active"),
                "contextMode": .string("notebook"), "createdAt": SyncJSON(1_759_000_000_000), "editedAt": SyncJSON(1_759_200_000_000),
            ], in: library),
            try MobileSyncFixture.record(.card, "cd1", [
                "status": .string("kept"), "deckSourceID": .string("src1"), "origin": .string("manual"), "keptAt": SyncJSON(1_759_000_000_000),
            ], in: library),
            try MobileSyncFixture.record(.setting, "chat.model", ["key": .string("chat.model"), "value": .string("default")], in: library),
        ], zone: SyncZone.library.rawValue, owner: alice)
        server.put([
            try MobileSyncFixture.record(.source, "src1", [
                "primaryKey": .string("doi:10.1/x"), "type": .string("paper"), "title": .string("Membrane potential"),
                "authors": .array([.string("A. Author"), .string("B. Author")]), "status": .string("active"),
                "ingest": .object(["ord": .array([SyncJSON(0), SyncJSON(4)]), "state": .string("ready")]),
                "addedAt": SyncJSON(1_759_000_000_000),
                "files": .object(["pdf": MobileSyncFixture.fileRef(owner: "src1", role: "pdf", bytes: Data("pdf".utf8)).value]),
            ], in: catalog),
            try MobileSyncFixture.record(.source, "src2", [
                "primaryKey": .string("url:example.com/b"), "type": .string("article"), "title": .string("Ion channels"),
                "status": .string("active"), "addedAt": SyncJSON(1_759_050_000_000),
            ], in: catalog),
        ], zone: SyncZone.catalog.rawValue, owner: alice)
        return server
    }

    static func phone(_ server: FakeCloudKit, path: String = ":memory:") async throws -> MobileTestDevice {
        let phone = try MobileTestDevice(server, user: alice, path: path)
        let outcome = try await phone.bootstrap()
        #expect(outcome == .adopted(saltID: RecordNaming.saltID(MobileSyncFixture.librarySalt)))
        return phone
    }

    @Test("Opening installs the replica's tables and the index at its version")
    func opensWithTablesAndIndex() async throws {
        let phone = try MobileTestDevice(FakeCloudKit(start: Date()), user: Self.alice)
        for table in ReplicaStore.sharedTables.map(\.name) + MobileReplica.indexTables.map(\.name) {
            #expect(try await phone.count("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) == 1, "\(table)")
        }
        #expect(try await phone.count("PRAGMA user_version") == Int(MobileReplica.indexVersion))
        #expect(MobileReplica.indexTables.count == Set(MobileReplica.indexTables.map(\.type)).count, "one table per type")
    }

    @Test("What the private engine fetches is applied to the replica and its index columns, without sending anything")
    func fetchFillsTheIndex() async throws {
        let server = try Self.seededLibrary()
        let phone = try await Self.phone(server)
        try await phone.sync()

        #expect(try await phone.text("SELECT title FROM m_notebooks WHERE zone_key = 'private/Library' AND id = 'nb1'") == "🧬 Cells")
        #expect(try await phone.text("SELECT item_id FROM m_entries WHERE container_id = 'nb1' AND state = 'active'") == "src1")
        let stateStamp = try #require(try await phone.text("SELECT state_stamp FROM m_entries WHERE id = 'en:nb1:source:src1'"))
        #expect(SyncStamp(stateStamp) != nil, "the Entry's state stamp is kept for the chat ticks")
        #expect(try await phone.text("SELECT authors FROM m_sources WHERE id = 'src1'") == "A. Author; B. Author")
        #expect(try await phone.text("SELECT ingest_state FROM m_sources WHERE id = 'src1'") == "ready")
        #expect(try await phone.count("SELECT has_pdf FROM m_sources WHERE id = 'src1'") == 1)
        #expect(try await phone.count("SELECT has_pdf FROM m_sources WHERE id = 'src2'") == 0)
        #expect(try await phone.text("SELECT zone_key FROM m_sources WHERE id = 'src2'") == "private/Catalog")
        #expect(try await phone.text("SELECT notebook_id FROM m_chats WHERE id = 'ch1'") == "nb1")
        #expect(try await phone.text("SELECT status FROM m_cards WHERE id = 'cd1'") == "kept")
        #expect(try await phone.text("SELECT value_json FROM m_settings WHERE key = 'chat.model'") == "\"default\"")
        #expect(try await phone.count("SELECT COUNT(*) FROM m_notebooks WHERE record_name IS NULL") == 0)
        #expect(server.calls.filter { $0.operation == .modifyRecords && $0.device == "phone" && $0.zones != [SyncZone.library.rawValue] }.isEmpty,
                "the phone saves nothing but the root's offset save")
    }

    @Test("An update moves the index and a deletion removes the row")
    func updatesAndDeletions() async throws {
        let server = try Self.seededLibrary()
        let phone = try await Self.phone(server)
        try await phone.sync()

        let mac = server.transport(user: Self.alice, device: "mac")
        server.put([try MobileSyncFixture.record(.notebook, "nb1", [
            "title": .string("🧬 Cell biology"), "status": .string("archived"), "createdAt": SyncJSON(1_759_000_000_000),
        ], in: Self.library, at: MobileSyncFixture.stampMilliseconds + 10)], zone: SyncZone.library.rawValue, owner: Self.alice)
        let source = CloudRecordID(RecordNaming.recordName(type: .source, id: "src2", salt: MobileSyncFixture.librarySalt), in: Self.catalog)
        _ = try await mac.modifyRecords(deleting: [source], in: .private)
        try await phone.sync()

        #expect(try await phone.text("SELECT title FROM m_notebooks WHERE id = 'nb1'") == "🧬 Cell biology")
        #expect(try await phone.text("SELECT status FROM m_notebooks WHERE id = 'nb1'") == "archived")
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources WHERE id = 'src2'") == 0)
        #expect(try await phone.count("SELECT COUNT(*) FROM ck_records WHERE wire_id = 'src2'") == 0)
    }

    @Test("A pending patch shows merged in the index, and an inbound version of another field keeps it")
    func pendingPatchMerges() async throws {
        let server = try Self.seededLibrary()
        let phone = try await Self.phone(server)
        try await phone.sync()

        // The phone renamed the notebook (WP20's writer saves such a patch and indexes it again).
        let later = SyncStamp(policy: .lastWriter, milliseconds: MobileSyncFixture.stampMilliseconds + 1_000, counter: 0, deviceID: "phoneaaa")
        let patch = PendingPatch(changes: ["title": .string("🧬 Membranes")], stamps: ["title": .value(later)],
                                 zoneKey: "private/Library", type: "Notebook", wireID: "nb1")
        try await phone.replica.read { replica in
            try patch.save(in: replica.connection, now: Date())
            try replica.reindex(zoneKey: "private/Library", type: .notebook, wireID: "nb1")
        }
        #expect(try await phone.text("SELECT title FROM m_notebooks WHERE id = 'nb1'") == "🧬 Membranes")

        // A Mac archived it meanwhile, with an older title stamp: the merge keeps both.
        server.put([try MobileSyncFixture.record(.notebook, "nb1", [
            "title": .string("🧬 Cells"), "status": .string("archived"), "createdAt": SyncJSON(1_759_000_000_000),
        ], in: Self.library, at: MobileSyncFixture.stampMilliseconds + 10)], zone: SyncZone.library.rawValue, owner: Self.alice)
        try await phone.sync()
        #expect(try await phone.text("SELECT title FROM m_notebooks WHERE id = 'nb1'") == "🧬 Membranes")
        #expect(try await phone.text("SELECT status FROM m_notebooks WHERE id = 'nb1'") == "archived")
        let held = try #require(try await phone.projection.envelope(.notebook, id: "nb1", zoneKey: "private/Library"))
        #expect(held.fields["title"] == .string("🧬 Membranes"))
        #expect(try await phone.count("SELECT COUNT(*) FROM ck_patches") == 1, "the patch waits for the writer to send it")
    }

    @Test("A record created on the phone and not acknowledged is indexed from its patch alone, and the sweep keeps it")
    func patchOnlyRecord() async throws {
        let server = try Self.seededLibrary()
        let phone = try await Self.phone(server)
        try await phone.sync()
        let stamp = SyncStamp(policy: .lastWriter, milliseconds: MobileSyncFixture.stampMilliseconds + 1_000, counter: 0, deviceID: "phoneaaa")
        let patch = PendingPatch(changes: ["title": .string("New"), "status": .string("active")],
                                 stamps: ["title": .value(stamp), "status": .value(stamp)],
                                 zoneKey: "private/Library", type: "Notebook", wireID: "nb-new")
        try await phone.replica.read { replica in
            try patch.save(in: replica.connection, now: Date())
            try replica.reindex(zoneKey: "private/Library", type: .notebook, wireID: "nb-new")
            try replica.sweepIndex()
        }
        #expect(try await phone.text("SELECT title FROM m_notebooks WHERE id = 'nb-new'") == "New")
        #expect(try await phone.count("SELECT COUNT(*) FROM m_notebooks WHERE id = 'nb-new' AND record_name IS NULL") == 1)
    }

    @Test("A record the replica forgets without a deletion (a move's original, a purge) takes its index row, unless a patch still makes it")
    func forgottenRecordsLeaveTheIndex() async throws {
        let server = try Self.seededLibrary()
        let phone = try await Self.phone(server)
        try await phone.sync()
        let stamp = SyncStamp(policy: .lastWriter, milliseconds: MobileSyncFixture.stampMilliseconds + 1_000, counter: 0, deviceID: "phoneaaa")
        try await phone.replica.read { replica in
            try PendingPatch(changes: ["title": .string("Kept")], stamps: ["title": .value(stamp)],
                             zoneKey: "private/Library", type: "Notebook", wireID: "nb1").save(in: replica.connection, now: Date())
            // As `InboundApply.serverLost` forgets a moved record, and `PurgeHandler` a zone's rows.
            try replica.connection.execute("DELETE FROM ck_records WHERE wire_id IN ('src2', 'nb1', 'ch1')")
        }
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources WHERE id = 'src2'") == 0)
        #expect(try await phone.count("SELECT COUNT(*) FROM m_chats WHERE id = 'ch1'") == 0)
        #expect(try await phone.count("SELECT COUNT(*) FROM m_notebooks WHERE id = 'nb1'") == 1, "a pending patch still makes it")
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources WHERE id = 'src1'") == 1)

        // An inbound deletion removes the row before the replica forgets the record.
        try await phone.replica.perform { state in
            try state.projectDeletion(zoneKey: "private/Catalog", recordName: "", type: .source, wireID: "src1")
        }
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources WHERE id = 'src1'") == 0)
        #expect(try await phone.count("SELECT COUNT(*) FROM ck_records WHERE wire_id = 'src1'") == 1)
    }

    @Test("The replica audit sweeps a record deleted while the token was invalid, and its index row with it")
    func auditSweepsGhosts() async throws {
        let server = try Self.seededLibrary()
        let phone = try await Self.phone(server)
        try await phone.sync()
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources") == 2)

        let mac = server.transport(user: Self.alice, device: "mac")
        let ghost = CloudRecordID(RecordNaming.recordName(type: .source, id: "src2", salt: MobileSyncFixture.librarySalt), in: Self.catalog)
        _ = try await mac.modifyRecords(deleting: [ghost], in: .private)
        // The token expires and takes the deletion with it: a pass from nil never reports it (§2.3).
        server.expireZoneChangeTokens(zone: SyncZone.catalog.rawValue, owner: Self.alice)
        try await phone.sync()

        #expect(try await phone.count("SELECT COUNT(*) FROM ck_records WHERE wire_id = 'src2'") == 0, "the audit swept the ghost")
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources WHERE id = 'src2'") == 0, "and its index row")
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources WHERE id = 'src1'") == 1, "a record the walk returned stays")
        #expect(try await phone.count("SELECT COUNT(*) FROM ck_zones WHERE zone_key = 'private/Catalog' AND last_complete_pass_at IS NOT NULL") == 1)
    }

    @Test("A purge stops the private database and clears the index, and a projection then shows nothing of it")
    func purgeClearsTheIndex() async throws {
        let server = try Self.seededLibrary()
        let phone = try await Self.phone(server)
        try await phone.sync()
        #expect(try await phone.projection.loadStructure().notebooks.count == 1)

        server.deleteZone(SyncZone.library.rawValue, owner: Self.alice, reason: .purged)
        try await phone.sync()

        #expect(await phone.engine.stopped != nil)
        #expect(try await phone.count("SELECT COUNT(*) FROM m_notebooks") == 0)
        #expect(try await phone.count("SELECT COUNT(*) FROM m_sources") == 0, "Catalog's rows went with the replica's")
        let structure = try await phone.projection.loadStructure()
        #expect(structure.notebooks.isEmpty && structure.chats.isEmpty && structure.cards.isEmpty)
    }

    @Test("A reopened replica decodes nothing; one whose index version moved builds the index again from its records")
    func reopenAndRebuild() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MobileReplicaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent(MobileReplica.fileName).path

        let server = try Self.seededLibrary()
        let first = try await Self.phone(server, path: path)
        try await first.sync()
        let rows = try await first.count("SELECT (SELECT COUNT(*) FROM m_notebooks) + (SELECT COUNT(*) FROM m_sources) + (SELECT COUNT(*) FROM m_entries)")

        let reopened = try MobileReplica(path: path)
        #expect(reopened.decodedRecords == 0, "an open at the current version decodes nothing")
        #expect(try await reopened.read { Int(try $0.connection.scalarInteger("SELECT COUNT(*) FROM m_notebooks") ?? 0) } == 1)

        try await reopened.read { try $0.connection.executeScript("PRAGMA user_version = 0; DELETE FROM m_sources;") }
        let rebuilt = try MobileReplica(path: path)
        let indexed = try await rebuilt.read { Int(try $0.connection.scalarInteger("SELECT COUNT(*) FROM ck_records WHERE record_type IN ('Notebook','Entry','Source','Chat','Card','Setting')") ?? 0) }
        #expect(rebuilt.decodedRecords == indexed, "a rebuild decodes each indexed record once")
        #expect(try await rebuilt.read { Int(try $0.connection.scalarInteger("SELECT (SELECT COUNT(*) FROM m_notebooks) + (SELECT COUNT(*) FROM m_sources) + (SELECT COUNT(*) FROM m_entries)") ?? 0) } == rows)
        #expect(try await rebuilt.read { try $0.connection.scalarInteger("PRAGMA user_version") } == MobileReplica.indexVersion)
    }

    @Test("Synced state is kept apart per CloudKit environment: Production keeps today's names")
    func environmentScopesFiles() throws {
        #expect(MobileCloudKitEnvironment.resolve(nil) == .production)
        #expect(MobileCloudKitEnvironment.resolve(" Development ") == .development)
        #expect(MobileCloudKitEnvironment.resolve("Staging") == .production)
        #expect(MobileCloudKitEnvironment.production.scopedName("knowledge.db") == "knowledge.db")
        #expect(MobileCloudKitEnvironment.development.scopedName("knowledge.db") == "knowledge-Development.db")
        #expect(MobileCloudKitEnvironment.development.scopedName("SourceCatalog") == "SourceCatalog-Development")
        #expect(try MobileReplica.fileURL(environment: .production).lastPathComponent == "ForeverLMReplica.sqlite")
        #expect(try MobileReplica.fileURL(environment: .development).lastPathComponent == "ForeverLMReplica-Development.sqlite")
    }
}

/// The library's first arrival on the phone (`MobileLibraryArrival`, §2.3): a first fetch takes minutes and
/// the replica is on screen from its first records, so the screens say the library is still coming until
/// both fetched zones have been taken to their end. A paper list that read 64 of a thousand, with nothing
/// to say the rest were on their way, is what these hold.
@Suite("iPhone library arrival", .serialized)
struct MobileLibraryArrivalTests {
    private static func holdsWhole(_ replica: MobileReplica) async throws -> Bool {
        try await replica.read { try MobileLibraryArrival.holdsWhole(in: $0) }
    }

    private static func markComplete(_ zones: [CloudZoneID], in replica: MobileReplica) async throws {
        try await replica.perform { state in
            for zone in zones {
                guard var held = try state.replica.zone(key: PrivateSyncZones.key(zone)) else { continue }
                held.lastCompletePassAt = Date().timeIntervalSinceReferenceDate
                try state.replica.upsertZone(held)
            }
        }
    }

    @Test("A round over a library never held whole is arriving, a failed one interrupted, anything else settled")
    func stateFollowsTheRound() {
        #expect(MobileLibraryArrival.state(phase: .starting, heldWhole: false) == .arriving)
        #expect(MobileLibraryArrival.state(phase: .syncing, heldWhole: false) == .arriving)
        #expect(MobileLibraryArrival.state(phase: .failed("The network connection was lost."), heldWhole: false) == .interrupted)
        #expect(MobileLibraryArrival.state(phase: .upToDate, heldWhole: false) == .settled)
        #expect(MobileLibraryArrival.state(phase: .noAccount, heldWhole: false) == .settled)
        #expect(MobileLibraryArrival.state(phase: .waiting(.zonesWithoutRoot), heldWhole: false) == .settled)
        #expect(MobileLibraryArrival.state(phase: .idle, heldWhole: false) == .settled)
    }

    @Test("A library held whole never reads as arriving: an ordinary round stays silent")
    func aWholeLibraryStaysSilent() {
        #expect(MobileLibraryArrival.state(phase: .syncing, heldWhole: true) == .settled)
        #expect(MobileLibraryArrival.state(phase: .starting, heldWhole: true) == .settled)
        #expect(MobileLibraryArrival.state(phase: .failed("offline"), heldWhole: true) == .settled)
    }

    @Test("The library is whole once Library and Catalog each have a complete pass, and a purge takes that back")
    func wholeNeedsBothZones() async throws {
        let replica = try await MobileWriterFixture.replica(space: nil)
        #expect(try await Self.holdsWhole(replica) == false, "zones adopted, nothing fetched to its end")

        try await Self.markComplete([PrivateSyncZones.library], in: replica)
        #expect(try await Self.holdsWhole(replica) == false, "Catalog, which holds the sources, is still coming")

        try await Self.markComplete([PrivateSyncZones.catalog], in: replica)
        #expect(try await Self.holdsWhole(replica))

        try await replica.perform { try PurgeHandler.handle(.zoneDeleted(reason: .purged), in: $0) }
        #expect(try await Self.holdsWhole(replica) == false, "after a purge the library arrives again from nothing")
    }

    @Test("A replica with no zones yet is not whole: a first launch reads as arriving")
    func noZonesIsNotWhole() async throws {
        let replica = try MobileReplica(path: ":memory:")
        #expect(try await Self.holdsWhole(replica) == false)
    }

    @Test("The line counts the sources on screen while they arrive, and says a failed round will be tried again")
    func statusLines() {
        #expect(MobileCatalogSyncStatus.arrival(.settled, sourceCount: 12) == nil)

        let connecting = MobileCatalogSyncStatus.arrival(.arriving, sourceCount: 0)
        #expect(connecting?.stepText == "Syncing your library")
        #expect(connecting?.detailText == "Connecting to iCloud…")
        #expect(connecting?.isRunning == true)

        #expect(MobileCatalogSyncStatus.arrival(.arriving, sourceCount: 1)?.detailText == "1 source so far")
        #expect(MobileCatalogSyncStatus.arrival(.arriving, sourceCount: 64)?.detailText == "64 sources so far")

        let paused = MobileCatalogSyncStatus.arrival(.interrupted, sourceCount: 64)
        #expect(paused?.phase == .interrupted)
        #expect(paused?.isRunning == false, "a round that stopped never spins")
        #expect(paused?.detailText == "iCloud did not answer. ForeverLM will try again.")
    }
}
