import Foundation
import Testing
@testable import ForeverLM

// Collections of notebooks (docs/notebooks-design.md, "Collections"): the
// rows' rules (`NotebookCollections`), the Mac's writes
// (`StudioViewModel+NotebookCollections`) and the two MCP tools. Every test
// that writes binds its own defaults suite, never the standard defaults the
// Dev build and parallel suites share, and a sync generation: the rows these
// tests read back are generation 1's, so they pin it (the test host runs
// generation 2), and the generation-2 tests pin `.two` beside their own
// NotebookState.

private func withCollectionDefaults<T>(generation: SyncGeneration = .one, _ body: (UserDefaults) throws -> T) throws -> T {
    let suiteName = "NotebookCollectionsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return try ForeverLMRuntimeIdentity.$pinnedSyncGeneration.withValue(generation) {
        try NotebookCollectionRows.$overrideDefaults.withValue(NotebookCollectionRows.DefaultsOverride(defaults: defaults)) {
            try body(defaults)
        }
    }
}

private func withCollectionDefaults(generation: SyncGeneration = .one, _ body: (UserDefaults) async throws -> Void) async throws {
    let suiteName = "NotebookCollectionsMCP.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try await ForeverLMRuntimeIdentity.$pinnedSyncGeneration.withValue(generation) {
        try await NotebookCollectionRows.$overrideDefaults.withValue(NotebookCollectionRows.DefaultsOverride(defaults: defaults)) {
            try await body(defaults)
        }
    }
}

@Suite("Notebook collections: the rows")
struct NotebookCollectionsRowTests {
    @Test("Rows are read under their two prefixes; a blank name, a wrong type and an empty row are no row")
    func readsRows() {
        let state = NotebookCollections(rows: [
            "notebookCollection.nbc-a": "  Aging  ",
            "notebookCollection.nbc-blank": "   ",
            "notebookCollection.nbc-number": 7,
            "notebookCollection.": "No id",
            "notebook.collections.p1": ["nbc-a", "", "nbc-gone"],
            "notebook.collections.p2": [] as [String],
            "notebook.collections.p3": "nbc-a",
            "notebook.chatExcluded.p1": ["src-1"],
            "studio.projectOrder": ["p1"],
        ])
        #expect(state.names == ["nbc-a": "Aging"])
        #expect(state.memberships == ["p1": ["nbc-a", "nbc-gone"]])
        #expect(state.ordered == [NotebookCollection(id: "nbc-a", name: "Aging")])
    }

    @Test("Keys and ids: a name row per collection, a membership row per notebook")
    func keys() {
        #expect(NotebookCollections.nameKey(collectionID: "nbc-1") == "notebookCollection.nbc-1")
        #expect(NotebookCollections.membershipKey(notebookID: "p1") == "notebook.collections.p1")
        #expect(NotebookCollections.collectionID(fromNameKey: "notebookCollection.nbc-1") == "nbc-1")
        #expect(NotebookCollections.collectionID(fromNameKey: "notebook.collections.p1") == nil)
        #expect(NotebookCollections.notebookID(fromMembershipKey: "notebook.collections.p1") == "p1")
        #expect(NotebookCollections.notebookID(fromMembershipKey: "notebookCollection.nbc-1") == nil)
        let id = NotebookCollections.newCollectionID()
        #expect(id.hasPrefix("nbc-"))
        #expect(id == id.lowercased())
        #expect(id.count == 4 + 36)
    }

    @Test("Collections sort by name with a leading emoji aside and numbers in order, then by id")
    func order() {
        let state = NotebookCollections(names: [
            "nbc-3": "🧬 Mitochondria",
            "nbc-2": "Batch 10",
            "nbc-4": "Batch 9",
            "nbc-6": "Aging",
            "nbc-5": "Aging",
            "nbc-1": "Neurons",
        ])
        #expect(state.ordered.map(\.id) == ["nbc-5", "nbc-6", "nbc-4", "nbc-2", "nbc-3", "nbc-1"])
    }

    @Test("A notebook's collections pass over a deleted collection's id")
    func deadIDsAreReadPast() {
        let state = NotebookCollections(
            names: ["nbc-a": "Aging", "nbc-b": "Brain"],
            memberships: ["p1": ["nbc-b", "nbc-gone", "nbc-a"], "p2": ["nbc-gone"]]
        )
        #expect(state.collections(ofNotebook: "p1").map(\.id) == ["nbc-a", "nbc-b"])
        #expect(state.collections(ofNotebook: "p2").isEmpty)
        #expect(state.contains("p1", in: "nbc-a"))
        #expect(!state.contains("p2", in: "nbc-gone"), "a collection with no name row holds nothing")
        #expect(state.notebookIDs(["p2", "p1", "p3"], in: "nbc-a") == ["p1"])
        #expect(state.notebookIDs(["p1", "p2"], in: "nbc-gone").isEmpty)
    }

    @Test("Putting a notebook in or out moves only that id, and keeps an id whose name has not arrived")
    func membershipRow() {
        let state = NotebookCollections(
            names: ["nbc-a": "Aging"],
            memberships: ["p1": ["nbc-made-elsewhere"]]
        )
        #expect(state.membershipRow(notebookID: "p1", setting: "nbc-a", isMember: true) == ["nbc-a", "nbc-made-elsewhere"])
        #expect(state.membershipRow(notebookID: "p2", setting: "nbc-a", isMember: true) == ["nbc-a"])
        #expect(state.membershipRow(notebookID: "p1", setting: "nbc-made-elsewhere", isMember: false).isEmpty)
        #expect(state.membershipRow(notebookID: "p3", setting: "nbc-a", isMember: false).isEmpty)
    }

    @Test("Deleting a collection rewrites only the rows that list it")
    func deleteRows() {
        let state = NotebookCollections(
            names: ["nbc-a": "Aging", "nbc-b": "Brain"],
            memberships: ["p1": ["nbc-a", "nbc-b"], "p2": ["nbc-a"], "p3": ["nbc-b"]]
        )
        #expect(state.membershipRowsAfterDeleting("nbc-a") == ["p1": ["nbc-b"], "p2": []])
        #expect(state.membershipRowsAfterDeleting("nbc-none").isEmpty)
    }

    @Test("A merge puts the survivor in every collection either notebook was in")
    func mergeRow() {
        let state = NotebookCollections(
            names: ["nbc-a": "Aging", "nbc-b": "Brain"],
            memberships: ["merged": ["nbc-a", "nbc-b"], "survivor": ["nbc-b"], "inside": ["nbc-a", "nbc-b"]]
        )
        #expect(state.membershipRowAfterMerging("merged", into: "survivor") == ["nbc-a", "nbc-b"])
        #expect(state.membershipRowAfterMerging("merged", into: "inside") == nil, "nothing new, nothing written")
        #expect(state.membershipRowAfterMerging("in-none", into: "survivor") == nil)
        #expect(state.membershipRowAfterMerging("merged", into: "new") == ["nbc-a", "nbc-b"])
    }

    @Test("The Collections tab's cards: every collection by name, each with the notebooks it holds in the home's order")
    func summaries() {
        let state = NotebookCollections(
            names: ["nbc-b": "🧬 Biology", "nbc-a": "Aging", "nbc-e": "Empty"],
            memberships: ["p1": ["nbc-a", "nbc-b"], "p2": ["nbc-a"], "p3": ["nbc-b", "nbc-gone"], "archived": ["nbc-a"]]
        )
        let cards = state.summaries(of: ["p3", "p2", "p1"])
        #expect(cards.map(\.id) == ["nbc-a", "nbc-b", "nbc-e"])
        #expect(cards[0].notebookIDs == ["p2", "p1"], "in the order given; a notebook the home does not list is not counted")
        #expect(cards[1].notebookIDs == ["p3", "p1"])
        #expect(cards[2].notebookIDs.isEmpty, "an empty collection is a card too")
        #expect(cards[1].collection == NotebookCollection(id: "nbc-b", name: "🧬 Biology"))
        #expect(NotebookCollections().summaries(of: ["p1"]).isEmpty)
    }

    @Test("A name is folded to one line, trimmed and cut at 80 characters; a blank one is refused")
    func cleanedName() {
        #expect(NotebookCollections.cleanedName("  Aging\n research \t ") == "Aging research")
        #expect(NotebookCollections.cleanedName(" \n\t ") == nil)
        #expect(NotebookCollections.cleanedName("") == nil)
        #expect(NotebookCollections.cleanedName(String(repeating: "a", count: 120))?.count == 80)
        #expect(NotebookCollections.cleanedName("🧬 Mitochondria") == "🧬 Mitochondria")
    }

    @Test("Both prefixes follow the account; a device-local key under neither does not")
    func rowsSync() {
        let name = NotebookCollections.nameKey(collectionID: "nbc-1")
        let membership = NotebookCollections.membershipKey(notebookID: "p1")
        #expect(SyncedPreferenceKeys.isSynced(name, for: .one))
        #expect(SyncedPreferenceKeys.isSynced(membership, for: .one))
        #expect(!SyncedPreferenceKeys.isSynced(NotebookRecency.preferenceKey, for: .one))
        // Under generation 2 the name is still a Setting, and the membership is a field of the
        // member's NotebookState: no preference row follows the account.
        #expect(SyncedPreferenceKeys.isSynced(name, for: .two))
        #expect(!SyncedPreferenceKeys.isSynced(membership, for: .two))
        #expect(!SyncedPreferenceKeys.isSynced(NotebookRecency.preferenceKey, for: .two))
    }

    @Test("The Mac's writes: an empty membership removes the row, a merge and a hand-over carry it")
    func rowWrites() throws {
        try withCollectionDefaults { defaults in
            NotebookCollectionRows.writeName("Aging", collectionID: "nbc-a")
            NotebookCollectionRows.writeMembership(["nbc-a"], notebookID: "p1")
            #expect(defaults.string(forKey: "notebookCollection.nbc-a") == "Aging")
            #expect(defaults.stringArray(forKey: "notebook.collections.p1") == ["nbc-a"])
            #expect(NotebookCollectionRows.read().contains("p1", in: "nbc-a"))

            NotebookCollectionRows.writeMembership([], notebookID: "p1")
            #expect(defaults.object(forKey: "notebook.collections.p1") == nil)

            NotebookCollectionRows.writeMembership(["nbc-a"], notebookID: "merged")
            NotebookCollectionRows.writeMembership(["nbc-b"], notebookID: "survivor")
            NotebookCollectionRows.merge("merged", into: "survivor")
            #expect(defaults.stringArray(forKey: "notebook.collections.survivor") == ["nbc-a", "nbc-b"])
            #expect(defaults.object(forKey: "notebook.collections.merged") == nil)

            NotebookCollectionRows.writeMembership(["nbc-a"], notebookID: "parent")
            NotebookCollectionRows.handOver(fromParent: "parent", toHeir: "heir")
            #expect(defaults.stringArray(forKey: "notebook.collections.heir") == ["nbc-a"])
            #expect(defaults.object(forKey: "notebook.collections.parent") == nil)

            NotebookCollectionRows.writeName(nil, collectionID: "nbc-a")
            #expect(defaults.object(forKey: "notebookCollection.nbc-a") == nil)
        }
    }
}

@Suite("Notebook collections: the Notebooks home")
@MainActor
struct NotebookCollectionsViewModelTests {
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookCollectionsTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func notebook(_ id: String, in vm: StudioViewModel, archived: Bool = false) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: id,
            startAt: Date(timeIntervalSince1970: 1_790_000_000),
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            status: (archived ? LearningGoalStatus.archived : .active).rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            teamID: vm.activeTeamID
        )
    }

    @Test("Making, filling, renaming and deleting a collection writes its rows and redraws the home")
    func lifecycle() throws {
        try withCollectionDefaults { defaults in
            let vm = makeViewModel()
            #expect(vm.notebookCollections.isEmpty, "a fresh library has no collections")
            vm.learningGoals = [notebook("bio", in: vm), notebook("neuro", in: vm), notebook("shelved", in: vm, archived: true)]

            #expect(vm.createNotebookCollection(named: "   ") == nil, "a blank name makes nothing")
            let aging = try #require(vm.createNotebookCollection(named: " ⏳ Aging ", adding: ["bio", "shelved"]))
            #expect(aging.name == "⏳ Aging")
            #expect(defaults.string(forKey: NotebookCollections.nameKey(collectionID: aging.id)) == "⏳ Aging")
            #expect(defaults.stringArray(forKey: "notebook.collections.bio") == [aging.id])
            #expect(vm.orderedNotebookCollections == [aging])
            #expect(vm.notebookCollectionCounts[aging.id] == 1, "the chip counts active notebooks only")

            vm.setNotebook("neuro", inCollection: aging.id, isMember: true)
            #expect(vm.notebookCollections.notebookIDs(["bio", "neuro"], in: aging.id) == ["bio", "neuro"])
            vm.setNotebook("bio", inCollection: aging.id, isMember: false)
            #expect(defaults.object(forKey: "notebook.collections.bio") == nil, "a notebook in none has no row")
            vm.setNotebook("bio", inCollection: "nbc-unknown", isMember: true)
            #expect(defaults.object(forKey: "notebook.collections.bio") == nil, "a collection gone since takes nothing")

            vm.renameNotebookCollection(aging.id, to: "Longevity")
            #expect(vm.notebookCollections.collection(aging.id)?.name == "Longevity")
            vm.renameNotebookCollection(aging.id, to: "  ")
            #expect(vm.notebookCollections.collection(aging.id)?.name == "Longevity", "a blank rename changes nothing")

            vm.deleteNotebookCollection(aging.id)
            #expect(vm.notebookCollections.isEmpty)
            #expect(defaults.object(forKey: NotebookCollections.nameKey(collectionID: aging.id)) == nil)
            #expect(defaults.object(forKey: "notebook.collections.neuro") == nil)
            #expect(defaults.object(forKey: "notebook.collections.shelved") == nil)
            #expect(vm.learningGoals.count == 3, "deleting a collection leaves its notebooks alone")
        }
    }

    @Test("A deleted notebook leaves its collections, and a merged one's go to the survivor")
    func deleteAndMerge() throws {
        try withCollectionDefaults { defaults in
            let vm = makeViewModel()
            vm.learningGoals = [notebook("a", in: vm), notebook("b", in: vm)]
            let first = try #require(vm.createNotebookCollection(named: "First", adding: ["a"]))
            let second = try #require(vm.createNotebookCollection(named: "Second", adding: ["a", "b"]))

            vm.mergeNotebookCollections("a", into: "b")
            #expect(defaults.stringArray(forKey: "notebook.collections.b") == [first.id, second.id].sorted())
            #expect(defaults.object(forKey: "notebook.collections.a") == nil)
            #expect(vm.notebookCollections.collections(ofNotebook: "b").map(\.id) == [first.id, second.id])

            vm.forgetNotebookCollections(of: "b")
            #expect(defaults.object(forKey: "notebook.collections.b") == nil)
            #expect(vm.notebookCollections.collections(ofNotebook: "b").isEmpty)
            #expect(vm.orderedNotebookCollections.count == 2, "the collections stay, empty")
        }
    }

    @Test("Rows another device wrote are read on the next preference reload")
    func reloadPicksUpRows() throws {
        try withCollectionDefaults { defaults in
            let vm = makeViewModel()
            vm.learningGoals = [notebook("bio", in: vm)]
            defaults.set("From the phone", forKey: "notebookCollection.nbc-phone")
            defaults.set(["nbc-phone"], forKey: "notebook.collections.bio")
            #expect(vm.notebookCollections.isEmpty)
            vm.notebookCollections = NotebookCollectionRows.read()
            #expect(vm.notebookCollections.contains("bio", in: "nbc-phone"))
            #expect(vm.notebookCollectionCounts["nbc-phone"] == 1)
        }
    }
}

@Suite("Notebook collections: MCP")
struct NotebookCollectionsMCPTests {
    private func makeStore() throws -> (MCPDataStore, String) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp_collections_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let store = MCPDataStore(dbPath: tmpDir.appendingPathComponent("knowledge.db").path)
        _ = try store.knowledgeStore()
        return (store, tmpDir.path)
    }

    private func notebook(_ title: String, store: MCPDataStore) throws -> LearningGoalRecord {
        try store.knowledgeStore().createCompanionGoal(
            title: title,
            topic: title.lowercased(),
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("update_notebook_collection makes, fills, renames and deletes a collection; list_notebook_collections reads it")
    func lifecycle() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bio = try notebook("Bioelectricity", store: store)
        let aging = try notebook("Aging", store: store)

        try await withCollectionDefaults { defaults in
            let created = try parseJSON(try await store.updateNotebookCollection(
                action: "create", collectionID: nil, name: "🔬 Science", notebookIDs: [bio.id, bio.id]
            ))
            let collection = try #require(created["collection"] as? [String: Any])
            let id = try #require(collection["id"] as? String)
            #expect(id.hasPrefix("nbc-"))
            #expect(collection["name"] as? String == "🔬 Science")
            #expect(collection["notebook_ids"] as? [String] == [bio.id])
            #expect(defaults.stringArray(forKey: NotebookCollections.membershipKey(notebookID: bio.id)) == [id])

            let added = try parseJSON(try await store.updateNotebookCollection(
                action: "add_notebooks", collectionID: id, name: nil, notebookIDs: [aging.id]
            ))
            let addedRow = try #require(added["collection"] as? [String: Any])
            #expect(addedRow["notebook_ids"] as? [String] == [aging.id, bio.id], "listed by title")

            _ = try await store.updateNotebookCollection(action: "remove_notebooks", collectionID: id, name: nil, notebookIDs: [bio.id])
            #expect(defaults.object(forKey: NotebookCollections.membershipKey(notebookID: bio.id)) == nil)

            _ = try await store.updateNotebookCollection(action: "rename", collectionID: id, name: "Labs", notebookIDs: nil)
            let listed = try parseJSON(try store.listNotebookCollections())
            let rows = try #require(listed["collections"] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows.first?["name"] as? String == "Labs")
            #expect(rows.first?["notebook_ids"] as? [String] == [aging.id])

            let deleted = try parseJSON(try await store.updateNotebookCollection(
                action: "delete", collectionID: id, name: nil, notebookIDs: nil
            ))
            #expect(deleted["deleted"] as? Bool == true)
            #expect(defaults.object(forKey: NotebookCollections.nameKey(collectionID: id)) == nil)
            #expect(defaults.object(forKey: NotebookCollections.membershipKey(notebookID: aging.id)) == nil)
            let empty = try parseJSON(try store.listNotebookCollections())
            #expect((empty["collections"] as? [[String: Any]])?.isEmpty == true)
            #expect(try store.knowledgeStore().loadLearningGoal(aging.id) != nil, "the Notebook stays")
        }
    }

    @Test("update_notebook_collection refuses an unknown action, a blank name, a missing collection and a non-Notebook, writing nothing")
    func refusals() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bio = try notebook("Bioelectricity", store: store)

        try await withCollectionDefaults { defaults in
            func refused(_ action: String, _ collectionID: String?, _ name: String?, _ notebookIDs: [String]?, _ phrase: String) async {
                do {
                    _ = try await store.updateNotebookCollection(action: action, collectionID: collectionID, name: name, notebookIDs: notebookIDs)
                    Issue.record("\(action) was accepted")
                } catch let error as MCPError {
                    #expect(error.localizedDescription.contains(phrase), "\(error.localizedDescription)")
                } catch {
                    Issue.record("unexpected \(error)")
                }
            }
            await refused("archive", nil, "X", nil, "action must be")
            await refused("create", nil, "  ", [bio.id], "name is required")
            await refused("create", nil, "Science", ["not-a-notebook"], "Notebook not found")
            await refused("rename", "nbc-missing", "X", nil, "Collection not found")
            await refused("delete", nil, nil, nil, "collection_id is required")
            #expect(NotebookCollectionRows.read() == NotebookCollections(), "a refusal writes nothing")

            let created = try parseJSON(try await store.updateNotebookCollection(action: "create", collectionID: nil, name: "Science", notebookIDs: nil))
            let id = try #require((created["collection"] as? [String: Any])?["id"] as? String)
            await refused("add_notebooks", id, nil, [], "notebook_ids is required")
        }
    }
}

// MARK: - Generation 2 (schema v2 §3.5.20, WP8)

extension NotebookCollectionsViewModelTests {
    @Test("Under generation 2 a toggle writes the member's NotebookState.collections, the name stays a Setting, and a deleted collection is read past")
    func generation2() throws {
        try withCollectionDefaults(generation: .two) { defaults in
            let box = NotebookStateStore.Box()
            try NotebookStateStore.$override.withValue(box) {
                let vm = makeViewModel()
                vm.learningGoals = [notebook("bio", in: vm), notebook("neuro", in: vm)]
                let aging = try #require(vm.createNotebookCollection(named: "Aging", adding: ["bio"]))
                #expect(box.snapshot.collections["bio"] == [aging.id])
                #expect(defaults.object(forKey: "notebook.collections.bio") == nil, "no preference row under generation 2")
                #expect(defaults.string(forKey: NotebookCollections.nameKey(collectionID: aging.id)) == "Aging")
                vm.setNotebook("neuro", inCollection: aging.id, isMember: true)
                #expect(box.snapshot.collections["neuro"] == [aging.id])
                #expect(vm.notebookCollections.notebookIDs(["bio", "neuro"], in: aging.id) == ["bio", "neuro"])
                // Deleted on another device: the name goes, and the membership is read past, never pruned.
                defaults.removeObject(forKey: NotebookCollections.nameKey(collectionID: aging.id))
                #expect(NotebookCollectionRows.read().collections(ofNotebook: "bio").isEmpty)
                #expect(box.snapshot.collections["bio"] == [aging.id])
            }
        }
    }
}

extension NotebookCollectionsMCPTests {
    @Test("Under generation 2 update_notebook_collection files notebooks into the member's NotebookState")
    func generation2() async throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bio = try notebook("Bioelectricity", store: store)
        try await withCollectionDefaults(generation: .two) { defaults in
            let box = NotebookStateStore.Box()
            try await NotebookStateStore.$override.withValue(box) {
                let created = try parseJSON(try await store.updateNotebookCollection(
                    action: "create", collectionID: nil, name: "🔬 Science", notebookIDs: [bio.id]
                ))
                let id = try #require((created["collection"] as? [String: Any])?["id"] as? String)
                #expect(box.snapshot.collections[bio.id] == [id])
                #expect(defaults.object(forKey: NotebookCollections.membershipKey(notebookID: bio.id)) == nil)
                #expect(try store.listNotebookCollections().contains(bio.id))
            }
        }
    }
}
