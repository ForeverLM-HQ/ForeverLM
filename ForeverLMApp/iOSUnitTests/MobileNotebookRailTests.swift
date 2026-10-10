import Foundation
import XCTest
@testable import ForeverLM

/// Home on the phone is the Mac's compact rail (docs/notebooks-design.md, "A
/// compact rail" and "iPhone"): Pinned in the learner's order from the Mac's
/// row, Recent by the opens on this phone and the chats, the notebook last
/// opened here when it is neither, Uncategorized and the collections. The
/// rules themselves are `NotebookRail`'s, tested on the Mac.
@MainActor
final class MobileNotebookRailTests: XCTestCase {
    /// The account's Preference rows, as the store reads and writes them.
    private actor Rows {
        private(set) var rows: [String: [String]] = [:]
        /// Every write in order: "set <key> <ids>".
        private(set) var writes: [String] = []
        /// Every key a read asked for, in order.
        private(set) var reads: [[String]] = []
        private var failsWrites = false

        func read(_ keys: [String]) -> [String: [String]] {
            reads.append(keys)
            return rows.filter { keys.contains($0.key) }
        }

        func write(_ key: String, _ ids: [String]) throws {
            if failsWrites { throw URLError(.notConnectedToInternet) }
            writes.append("set \(key) \(ids.joined(separator: ","))")
            rows[key] = ids
        }

        func set(_ key: String, _ ids: [String]?) { rows[key] = ids }
        func failWrites() { failsWrites = true }
    }

    private func store(_ rows: Rows) -> MobileNotebookRailStore {
        MobileNotebookRailStore(
            readRows: { keys in await rows.read(keys) },
            writeRow: { key, ids in try await rows.write(key, ids) },
            defaults: nil
        )
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// 52 notebooks, p0 changed first and p51 last, a minute apart.
    private func library() -> [MobileCloudNotebook] {
        let notebooks = (0..<52).map { index in
            MobileCloudNotebook(
                id: "p\(index)",
                title: "Notebook \(index)",
                instructions: nil,
                sourceIDs: (0..<(index % 5)).map { "s\($0)" },
                isArchived: false,
                updatedAt: start.addingTimeInterval(Double(index) * 60)
            )
        }
        // Newest first, as the view model publishes them.
        return Array(notebooks.reversed())
    }

    // MARK: The store

    func testALoadReadsThePinsAndTheOrderInOneBatch() async throws {
        let rows = Rows()
        await rows.set(NotebookPins.preferenceKey, ["p3", "p9", "p3"])
        await rows.set(MobileNotebookRailStore.notebookOrderPreferenceKey, ["p9", "p3"])
        await rows.set("studio.unpinnedProjects", ["p1"])
        let rail = store(rows)

        try await rail.load()

        XCTAssertEqual(rail.pinnedIDs, ["p3", "p9"], "deduplicated, in the row's order")
        XCTAssertEqual(rail.notebookOrder, ["p9", "p3"])
        let reads = await rows.reads
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(Set(reads[0]), [NotebookPins.preferenceKey, MobileNotebookRailStore.notebookOrderPreferenceKey],
                       "the retired exceptions row is never read")
    }

    func testPinningRereadsTheRowAndKeepsAnotherDevicesPins() async throws {
        let rows = Rows()
        await rows.set(NotebookPins.preferenceKey, ["p1"])
        let rail = store(rows)
        try await rail.load()
        // Pinned on the Mac since the load, and one the phone cannot see.
        await rows.set(NotebookPins.preferenceKey, ["p1", "p2", "archived"])

        try await rail.setPinned("p7", true)

        XCTAssertEqual(rail.pinnedIDs, ["p1", "p2", "archived", "p7"], "a new pin goes last")
        let writes = await rows.writes
        XCTAssertEqual(writes, ["set \(NotebookPins.preferenceKey) p1,p2,archived,p7"])
    }

    func testUnpinningWritesOnlyAChange() async throws {
        let rows = Rows()
        await rows.set(NotebookPins.preferenceKey, ["p1", "p2"])
        let rail = store(rows)
        try await rail.load()

        try await rail.setPinned("p1", false)
        try await rail.setPinned("p1", false)

        XCTAssertEqual(rail.pinnedIDs, ["p2"])
        let writes = await rows.writes
        XCTAssertEqual(writes, ["set \(NotebookPins.preferenceKey) p2"], "the second unpin finds nothing to change")
    }

    func testAFailedPinPutsThePinsBack() async throws {
        let rows = Rows()
        await rows.set(NotebookPins.preferenceKey, ["p1"])
        let rail = store(rows)
        try await rail.load()
        await rows.failWrites()

        do {
            try await rail.setPinned("p4", true)
            XCTFail("the write failed")
        } catch {}

        XCTAssertEqual(rail.pinnedIDs, ["p1"])
    }

    func testOpeningANotebookStampsIt() {
        let rail = store(Rows())
        rail.noteOpened("p2", at: start)
        XCTAssertEqual(rail.opened.stamp("p2"), start)
    }

    func testTheOpenedStampsLiveInThisDevicesDefaults() throws {
        let suite = "MobileNotebookRailTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = Rows()
        let first = MobileNotebookRailStore(readRows: { await rows.read($0) }, writeRow: { _, _ in }, defaults: defaults)
        first.noteOpened("p5", at: start)

        let second = MobileNotebookRailStore(readRows: { await rows.read($0) }, writeRow: { _, _ in }, defaults: defaults)
        XCTAssertEqual(second.opened.stamp("p5"), start)
    }

    // MARK: The rules

    func testPinnedKeepsTheLearnersOrder() {
        let rail = MobileNotebookRailRules.rail(
            notebooks: library(),
            pinnedIDs: ["p3", "p40", "gone"],
            order: ["p40", "p12", "p3"],
            recency: NotebookRecency(),
            collections: NotebookCollections(),
            lastOpenedID: nil
        )
        XCTAssertEqual(rail.pinnedIDs, ["p40", "p3"], "the learner's order, not the order pinned; a gone id is no row")
        XCTAssertEqual(rail.recentIDs, ["p51", "p50", "p49", "p48", "p47", "p46"], "six, last changed first")
    }

    func testRecentReadsOpensAndChats() {
        var opened = NotebookRecency()
        opened.note("p2", at: start.addingTimeInterval(100_000))
        let recency = MobileNotebookRailRules.recency(
            opened: opened,
            lastChatAt: ["p5": start.addingTimeInterval(90_000), "p2": start]
        )
        let rail = MobileNotebookRailRules.rail(
            notebooks: library(),
            pinnedIDs: [],
            order: [],
            recency: recency,
            collections: NotebookCollections(),
            lastOpenedID: nil
        )
        XCTAssertEqual(Array(rail.recentIDs.prefix(3)), ["p2", "p5", "p51"],
                       "opened here, then a chat elsewhere, then the record's own change")
        XCTAssertEqual(recency.stamp("p2"), start.addingTimeInterval(100_000), "an older chat never moves an open back")
    }

    func testTheLastOpenedNotebookGetsARowWhenNeitherPinnedNorRecent() {
        let notebooks = library()
        let shown = MobileNotebookRailRules.rail(
            notebooks: notebooks, pinnedIDs: [], order: [], recency: NotebookRecency(),
            collections: NotebookCollections(), lastOpenedID: "p7"
        )
        XCTAssertEqual(shown.openNotebookID, "p7")
        XCTAssertEqual(shown.notebookIDs.last, "p7", "at the end of Recent")

        let recent = MobileNotebookRailRules.rail(
            notebooks: notebooks, pinnedIDs: [], order: [], recency: NotebookRecency(),
            collections: NotebookCollections(), lastOpenedID: "p51"
        )
        XCTAssertNil(recent.openNotebookID, "already in Recent")

        let gone = MobileNotebookRailRules.rail(
            notebooks: notebooks, pinnedIDs: [], order: [], recency: NotebookRecency(),
            collections: NotebookCollections(), lastOpenedID: "archived"
        )
        XCTAssertNil(gone.openNotebookID, "a notebook Home does not list has no row")
    }

    func testUncategorizedAndTheCollectionsAreCounted() {
        let collections = NotebookCollections(
            names: ["nbc-mito": "🧬 Mito Journal Club", "nbc-lab": "Lab"],
            memberships: ["p1": ["nbc-mito"], "p2": ["nbc-mito", "nbc-lab"], "gone": ["nbc-lab"]]
        )
        let rail = MobileNotebookRailRules.rail(
            notebooks: library(), pinnedIDs: [], order: [], recency: NotebookRecency(),
            collections: collections, lastOpenedID: nil
        )
        XCTAssertEqual(rail.uncategorizedCount, 50)
        XCTAssertEqual(rail.collections.map(\.id), ["nbc-lab", "nbc-mito"], "by name, the emoji aside")
        XCTAssertEqual(rail.collections.map(\.count), [1, 2], "only notebooks Home lists")
    }

    func testTheSourcesSortReadsTheMacsCount() {
        let few = MobileCloudNotebook(id: "a", title: "A", instructions: nil, sourceIDs: ["s1"],
                                     approvedSourceCount: 9, isArchived: false, updatedAt: start)
        let many = MobileCloudNotebook(id: "b", title: "B", instructions: nil, sourceIDs: ["s1", "s2"],
                                      approvedSourceCount: 2, isArchived: false, updatedAt: start)
        XCTAssertEqual(NotebooksHomeSort.sources.ordered([many, few], recency: NotebookRecency()).map(\.id), ["a", "b"],
                       "approved sources as the Mac counts them, hidden and archived ones included")
    }
}
