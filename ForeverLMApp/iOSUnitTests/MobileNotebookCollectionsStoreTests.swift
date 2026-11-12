import Foundation
import XCTest
@testable import ForeverLM

/// Home's collections of notebooks on the phone keep the Mac's two kinds of
/// synced row (`notebookCollection.<id>` and `notebook.collections.<notebookID>`,
/// docs/notebooks-design.md "Collections"): found through the notebooks the
/// phone knows, every act reads its rows again and writes only a change, a
/// name goes before the rows that list it, and a failed write puts the
/// notebook back. The rules themselves are `NotebookCollections`', tested
/// on the Mac.
@MainActor
final class MobileNotebookCollectionsStoreTests: XCTestCase {
    /// The account's Preference rows, as the store reads and writes them.
    private actor Rows {
        private(set) var names: [String: String] = [:]
        private(set) var memberships: [String: [String]] = [:]
        /// Every write in order: "set <key> <value>" or "remove <key>".
        private(set) var writes: [String] = []
        /// Every key a read asked for, in order.
        private(set) var reads: [[String]] = []
        private var failsWrites = false
        /// While set, a name read waits until `releaseNameReads()`.
        private var holdsNameReads = false
        private var heldNameReads: [CheckedContinuation<Void, Never>] = []
        private var heldReadWatchers: [CheckedContinuation<Void, Never>] = []

        func readNames(_ keys: [String]) async -> [String: String] {
            reads.append(keys)
            if holdsNameReads {
                await withCheckedContinuation { held in
                    heldNameReads.append(held)
                    heldReadWatchers.forEach { $0.resume() }
                    heldReadWatchers = []
                }
            }
            return names.filter { keys.contains($0.key) }
        }

        func holdNameReads() { holdsNameReads = true }

        /// Returns once a name read is waiting.
        func waitForAHeldNameRead() async {
            guard heldNameReads.isEmpty else { return }
            await withCheckedContinuation { heldReadWatchers.append($0) }
        }

        func releaseNameReads() {
            holdsNameReads = false
            heldNameReads.forEach { $0.resume() }
            heldNameReads = []
        }

        func readMemberships(_ keys: [String]) -> [String: [String]] {
            reads.append(keys)
            return memberships.filter { keys.contains($0.key) }
        }

        func writeName(_ key: String, _ name: String?) throws {
            if failsWrites { throw URLError(.notConnectedToInternet) }
            if let name {
                writes.append("set \(key) \(name)")
                names[key] = name
            } else {
                writes.append("remove \(key)")
                names[key] = nil
            }
        }

        func writeMembership(_ key: String, _ ids: [String]) throws {
            if failsWrites { throw URLError(.notConnectedToInternet) }
            if ids.isEmpty {
                writes.append("remove \(key)")
                memberships[key] = nil
            } else {
                writes.append("set \(key) \(ids.joined(separator: ","))")
                memberships[key] = ids
            }
        }

        func setName(_ id: String, _ name: String?) {
            names[NotebookCollections.nameKey(collectionID: id)] = name
        }

        func setRow(_ notebookID: String, _ ids: [String]?) {
            memberships[NotebookCollections.membershipKey(notebookID: notebookID)] = ids
        }

        func row(_ notebookID: String) -> [String]? {
            memberships[NotebookCollections.membershipKey(notebookID: notebookID)]
        }

        func failWrites() { failsWrites = true }
        func forgetReads() { reads = [] }
    }

    private func store(_ rows: Rows) -> MobileNotebookCollectionsStore {
        MobileNotebookCollectionsStore(
            readNames: { keys in await rows.readNames(keys) },
            readMemberships: { keys in await rows.readMemberships(keys) },
            writeName: { key, name in try await rows.writeName(key, name) },
            writeMembership: { key, ids in try await rows.writeMembership(key, ids) }
        )
    }

    /// p1 is in Lab and in a collection deleted on a device that did not
    /// know p1; p2 is in Reading; Archive has no notebook on this phone.
    private func seeded() async -> Rows {
        let rows = Rows()
        await rows.setName("nbc-lab", "🧪 Lab")
        await rows.setName("nbc-reading", "Reading")
        await rows.setName("nbc-archive", "Archive")
        await rows.setRow("p1", ["nbc-gone", "nbc-lab"])
        await rows.setRow("p2", ["nbc-reading"])
        return rows
    }

    func testALoadFindsTheCollectionsThroughTheNotebooks() async throws {
        let rows = await seeded()
        let collections = store(rows)

        try await collections.load(notebookIDs: ["p1", "p2", "p3"])

        XCTAssertEqual(collections.state.ordered.map(\.id), ["nbc-lab", "nbc-reading"],
                       "by name with the emoji aside; a collection no notebook here is in is not found")
        XCTAssertEqual(collections.state.collections(ofNotebook: "p1").map(\.id), ["nbc-lab"],
                       "a deleted collection's id left in a row is read past")
        XCTAssertTrue(collections.state.contains("p2", in: "nbc-reading"))
        let reads = await rows.reads
        XCTAssertEqual(reads.count, 2, "one batched read of the notebooks' rows, one of the names they list")
        XCTAssertEqual(Set(reads[1]), Set(["nbc-gone", "nbc-lab", "nbc-reading"].map(NotebookCollections.nameKey(collectionID:))))
        let writes = await rows.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testAddingRereadsTheRowAndKeepsAnotherDevicesIDs() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        // Another device put p2 in a collection whose name has not arrived here.
        await rows.setRow("p2", ["nbc-new-elsewhere", "nbc-reading"])
        try await collections.setMembership(notebookID: "p2", collectionID: "nbc-lab", isMember: true)

        let writes = await rows.writes
        XCTAssertEqual(writes, ["set notebook.collections.p2 nbc-lab,nbc-new-elsewhere,nbc-reading"])
        XCTAssertTrue(collections.state.contains("p2", in: "nbc-lab"))
        XCTAssertTrue(collections.state.contains("p2", in: "nbc-reading"))
    }

    func testTakingANotebookOutOfItsLastCollectionRemovesTheRow() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        try await collections.setMembership(notebookID: "p2", collectionID: "nbc-reading", isMember: false)

        let writes = await rows.writes
        XCTAssertEqual(writes, ["remove notebook.collections.p2"])
        let row = await rows.row("p2")
        XCTAssertNil(row)
        XCTAssertFalse(collections.state.contains("p2", in: "nbc-reading"))
    }

    func testTheSameMembershipAgainWritesNothing() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        try await collections.setMembership(notebookID: "p1", collectionID: "nbc-lab", isMember: true)
        try await collections.setMembership(notebookID: "p2", collectionID: "nbc-lab", isMember: false)

        let writes = await rows.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testCreatingWritesTheNameThenTheNotebooksRow() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        let made = try await collections.create(name: "  📚   Thesis\n reading  ", notebookIDs: ["p2"])

        XCTAssertTrue(made.id.hasPrefix(NotebookCollections.idPrefix))
        XCTAssertEqual(made.name, "📚 Thesis reading", "folded and trimmed as every device keeps a name")
        let writes = await rows.writes
        XCTAssertEqual(writes, [
            "set notebookCollection.\(made.id) 📚 Thesis reading",
            "set notebook.collections.p2 \([made.id, "nbc-reading"].sorted().joined(separator: ","))",
        ], "the name row first, so no device reads past the new id as a deleted one")
        XCTAssertEqual(collections.state.collection(made.id), made)
        XCTAssertTrue(collections.state.contains("p2", in: made.id))
    }

    func testAnEmptyNameMakesNothing() async throws {
        let rows = await seeded()
        let collections = store(rows)

        do {
            try await collections.create(name: " \n ", notebookIDs: ["p1"])
            XCTFail("an empty name is refused")
        } catch let failure as MobileNotebookCollectionsStore.Failure {
            XCTAssertEqual(failure, .emptyName)
        }
        let writes = await rows.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testACollectionMadeHereWithNoNotebookStaysUntilItsNameGoes() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        let made = try await collections.create(name: "Later")
        try await collections.load(notebookIDs: ["p1", "p2"])
        XCTAssertNotNil(collections.state.collection(made.id), "seen here, so its name row is read again")

        // Deleted on another device.
        await rows.setName(made.id, nil)
        try await collections.load(notebookIDs: ["p1", "p2"])
        XCTAssertNil(collections.state.collection(made.id))
    }

    func testRenamingRewritesOnlyTheNameRow() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        try await collections.rename(collectionID: "nbc-lab", to: "🧪 Lab")
        var writes = await rows.writes
        XCTAssertTrue(writes.isEmpty, "the same name writes nothing")

        try await collections.rename(collectionID: "nbc-lab", to: "🧪  Wet lab ")
        writes = await rows.writes
        XCTAssertEqual(writes, ["set notebookCollection.nbc-lab 🧪 Wet lab"])
        XCTAssertEqual(collections.state.collection("nbc-lab")?.name, "🧪 Wet lab")
    }

    func testRenamingACollectionDeletedElsewhereDoesNotBringItBack() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        await rows.setName("nbc-lab", nil)
        do {
            try await collections.rename(collectionID: "nbc-lab", to: "Wet lab")
            XCTFail("the rename is refused")
        } catch let failure as MobileNotebookCollectionsStore.Failure {
            XCTAssertEqual(failure, .deletedElsewhere)
        }

        let writes = await rows.writes
        XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(collections.state.collection("nbc-lab"), "and it leaves the phone")
    }

    func testDeletingRemovesTheNameThenEveryRowThatListsIt() async throws {
        let rows = await seeded()
        await rows.setRow("p3", ["nbc-lab", "nbc-reading"])
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2", "p3"])

        // p2 joined Lab on another device since the load.
        await rows.setRow("p2", ["nbc-lab", "nbc-reading"])
        try await collections.delete(collectionID: "nbc-lab")

        let writes = await rows.writes
        XCTAssertEqual(writes, [
            "remove notebookCollection.nbc-lab",
            "set notebook.collections.p1 nbc-gone",
            "set notebook.collections.p2 nbc-reading",
            "set notebook.collections.p3 nbc-reading",
        ], "the name first; each row read again and kept but for the deleted id")
        XCTAssertNil(collections.state.collection("nbc-lab"))
        XCTAssertEqual(collections.state.collections(ofNotebook: "p3").map(\.id), ["nbc-reading"])
    }

    func testDeletingTheOnlyCollectionOfANotebookRemovesItsRow() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        try await collections.delete(collectionID: "nbc-reading")

        let writes = await rows.writes
        XCTAssertEqual(writes, ["remove notebookCollection.nbc-reading", "remove notebook.collections.p2"])
    }

    func testAFailedWritePutsTheNotebookBack() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])
        await rows.failWrites()

        do {
            try await collections.setMembership(notebookID: "p2", collectionID: "nbc-lab", isMember: true)
            XCTFail("the failure reaches the caller, which shows it")
        } catch {}

        XCTAssertFalse(collections.state.contains("p2", in: "nbc-lab"))
        XCTAssertTrue(collections.state.contains("p2", in: "nbc-reading"))
    }

    func testALoadAskedForBeforeAnActCannotPublishOverIt() async throws {
        let rows = await seeded()
        let collections = store(rows)
        try await collections.load(notebookIDs: ["p1", "p2"])

        // A load has read p2's row and waits on the names when p2 is put in Lab.
        await rows.holdNameReads()
        let load = Task { try await collections.load(notebookIDs: ["p1", "p2"]) }
        await rows.waitForAHeldNameRead()
        let add = Task {
            try await collections.setMembership(notebookID: "p2", collectionID: "nbc-lab", isMember: true)
        }
        // Long enough for an act that did not wait for the load to finish.
        for _ in 0..<500 {
            if await !rows.writes.isEmpty { break }
            await Task.yield()
        }
        await rows.releaseNameReads()
        try await load.value
        try await add.value

        XCTAssertTrue(collections.state.contains("p2", in: "nbc-lab"),
                      "the load's older read of p2's row does not undo the act asked for after it")
    }
    // MARK: Generation 2 (§3.5.3, §3.5.20, R7-m2)

    /// The store over the phone's replica, as its generation-2 rows read and write it.
    private func replicaStore(_ writer: MobileRecordWriter) -> MobileNotebookCollectionsStore {
        MobileNotebookCollectionsStore(
            readNames: { try await MobileNotebookRows.strings($0, writer: writer) },
            readMemberships: { try await MobileNotebookRows.stringArrays($0, writer: writer) },
            writeName: { try await MobileNotebookRows.write($0, string: $1, writer: writer) },
            writeMembership: { try await MobileNotebookRows.write($0, ids: $1, writer: writer) }
        )
    }

    func testUnderGenerationTwoAToggleWritesNotebookStateCollectionsAndANewNameItsSetting() async throws {
        let replica = try await MobileWriterFixture.replica(space: nil)
        try await MobileWriterFixture.apply(replica, [
            (MobileWriterFixture.library, try MobileReadModelFixture.notebook("p1", "Cells", edited: 5)),
            (MobileWriterFixture.library, try MobileReadModelFixture.notebook("p2", "Ions", edited: 6)),
        ])
        let writer = MobileWriterFixture.writer(replica)
        let collections = replicaStore(writer)
        let made = try await collections.create(name: "  📚 Reading  ", notebookIDs: ["p1"])

        let setting = try await MobileWriterFixture.held(replica, .setting, NotebookCollections.nameKey(collectionID: made.id), in: MobileWriterFixture.library)
        XCTAssertEqual(setting?.fields["value"], .object(["t": .string("string"), "v": .string("📚 Reading")]))
        XCTAssertEqual(setting?.fields["key"], .string(NotebookCollections.nameKey(collectionID: made.id)))
        let state = try await MobileWriterFixture.held(replica, .notebookState, "ns:p1", in: MobileWriterFixture.library)
        XCTAssertEqual(state?.fields["collections"]?[made.id], .bool(true))
        XCTAssertEqual(state?.fields["notebookID"], .string("p1"))

        try await collections.setMembership(notebookID: "p2", collectionID: made.id, isMember: true)
        try await collections.setMembership(notebookID: "p1", collectionID: made.id, isMember: false)
        let p1 = try await MobileWriterFixture.held(replica, .notebookState, "ns:p1", in: MobileWriterFixture.library)
        XCTAssertEqual(p1?.fields["collections"]?[made.id], .bool(false), "a removal is kept as a false element")

        let fresh = replicaStore(writer)
        try await fresh.load(notebookIDs: ["p1", "p2"])
        XCTAssertTrue(fresh.state.contains("p2", in: made.id))
        XCTAssertFalse(fresh.state.contains("p1", in: made.id))

        try await fresh.delete(collectionID: made.id)
        let cleared = try await MobileWriterFixture.held(replica, .setting, NotebookCollections.nameKey(collectionID: made.id), in: MobileWriterFixture.library)
        XCTAssertEqual(cleared?.fields["value"], .null, "a deleted collection's Setting is cleared, never deleted")
        let p2 = try await MobileWriterFixture.held(replica, .notebookState, "ns:p2", in: MobileWriterFixture.library)
        XCTAssertEqual(p2?.fields["collections"]?[made.id], .bool(false))
    }

    func testTheCollectionNamePassesTheCatalogThroughItsLeftOutEntryAndAnyOtherKeyIsRefused() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schema/generated/settings-catalog.json")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let leftOut = try XCTUnwrap(catalog["leftOut"] as? [String: [String: Any]])
        // The phone keeps the keys its writers set. The cover backfill's marker is the Mac's alone (D53, §5.9):
        // the phone reads the Setting and never writes it, so it is the one catalog key the phone leaves out.
        let phoneKeys = Set(MobileSettingCatalog.leftOut.map(\.prefix))
        XCTAssertTrue(phoneKeys.isSubset(of: Set(leftOut.keys)), "the phone lists only keys the catalog leaves out")
        XCTAssertEqual(Set(leftOut.keys).subtracting(phoneKeys), ["images.notebookCoverBackfill."], "the marker is the Mac's alone")
        for entry in MobileSettingCatalog.leftOut {
            XCTAssertEqual(leftOut[entry.prefix]?["type"] as? String, entry.type)
            XCTAssertEqual(leftOut[entry.prefix]?["scope"] as? [String], entry.scopes)
        }
        XCTAssertNotNil(MobileSettingCatalog.leftOutEntry(for: NotebookCollections.nameKey(collectionID: "nbc-1")))

        let replica = try await MobileWriterFixture.replica(space: nil)
        let writer = MobileWriterFixture.writer(replica)
        do {
            try await MobileNotebookRows.write("chat.model", string: "x", writer: writer)
            XCTFail("a Setting the catalog keeps for set_app_setting is not a collection writer's")
        } catch MobileRecordWriterError.refused {}
        let count = try await MobileWriterFixture.patchCount(replica)
        XCTAssertEqual(count, 0)
    }
}
