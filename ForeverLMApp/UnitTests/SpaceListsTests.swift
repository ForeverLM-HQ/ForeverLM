import Foundation
import Testing
@testable import ForeverLM

/// Lists in the Space (docs/docs-design.md, "Lists in the Space"): a list of
/// goals or of ideas is a synced row of its own, and each goal or idea names
/// the one list it is in.
@Suite("Lists in the Space: the rows")
struct SpaceListRowTests {
    private func list(_ id: String, _ kind: SpaceList.Kind = .goals, name: String = "Thesis", created: Double = 100, trashed: Double? = nil) -> SpaceList {
        SpaceList(
            id: id, kind: kind, name: name,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: created),
            trashedAt: trashed.map { Date(timeIntervalSince1970: $0) }
        )
    }

    @Test("A list's row round-trips; one that does not read, or names an unknown kind, is no row")
    func rowRoundTrip() throws {
        let made = list("lst-1", .ideas, name: "Hunches", created: 200, trashed: 300)
        let value = SpaceLists.rowValue(made)
        #expect(SpaceLists.list(id: "lst-1", rowValue: value) == made)
        #expect(SpaceLists.list(id: "lst-1", rowValue: "not json") == nil)
        #expect(SpaceLists.list(id: "lst-1", rowValue: #"{"kind":"tasks","name":"x","created":1,"at":1}"#) == nil)
        #expect(SpaceLists.list(id: "lst-1", rowValue: #"{"kind":"goals","name":"   ","created":1,"at":1}"#) == nil)
        #expect(SpaceLists.rowValue(made) == value, "the same list writes the same text")
    }

    @Test("Rows are read under their two prefixes; a record's row naming a deleted list is read past")
    func readsRows() {
        let goals = list("lst-g")
        let lists = SpaceLists(rows: [
            SpaceLists.listKey(listID: "lst-g"): SpaceLists.rowValue(goals),
            SpaceLists.itemKey(recordID: "goal-1"): "lst-g",
            SpaceLists.itemKey(recordID: "goal-2"): "lst-gone",
            SpaceLists.itemKey(recordID: "goal-3"): "  ",
            "spaceList.": SpaceLists.rowValue(goals),
            "pageSpace.psp-1": "Aging",
        ])
        #expect(lists.all == [goals])
        #expect(lists.listID(of: "goal-1") == "lst-g")
        #expect(lists.listID(of: "goal-2") == nil, "its list is gone")
        #expect(lists.listID(of: "goal-3") == nil)
        #expect(lists.recordIDs(["goal-2", "goal-1"], in: "lst-g") == ["goal-1"])
    }

    @Test("Filing writes only the rows that change; deleting a list takes every row naming it")
    func rowsAfterActs() {
        let lists = SpaceLists(lists: ["lst-a": list("lst-a"), "lst-b": list("lst-b")], memberships: ["g1": "lst-a", "g2": "lst-b"])
        let rows = lists.itemRowsAfterFiling(["g1", "g2", "g2", ""], in: "lst-a")
        #expect(rows == [SpaceLists.ItemRow(recordID: "g2", listID: "lst-a")], "g1 is there already; g2 once")
        let after = lists.applying(rows)
        #expect(after.listID(of: "g2") == "lst-a")
        #expect(after.itemRowsAfterDeleting("lst-a").map(\.recordID) == ["g1", "g2"])
        #expect(after.itemRowsAfterFiling(["g1"], in: nil) == [SpaceLists.ItemRow(recordID: "g1", listID: nil)])
    }

    @Test("A list is a Space place the window remembers")
    func place() {
        let place = SpaceDestination.list("lst-1")
        #expect(SpaceDestination(key: place.key) == place)
        #expect(place.key == "list:lst-1")
        #expect(place.spaceListID == "lst-1")
        #expect(place.pageSpaceID == nil)
        #expect(SpaceDestination(key: "list:") == .all)
        #expect(SpaceDestination.space("psp-1").spaceListID == nil)
    }

    @Test("Both prefixes follow the account, and the catalogue and the phone leave them out")
    func rowsSync() {
        for key in [SpaceLists.listKey(listID: "lst-1"), SpaceLists.itemKey(recordID: "goal-1")] {
            #expect(SyncedPreferenceKeys.isSynced(key))
        }
    }
}

/// The view model's acts on lists: each writes the rows, and the Space follows
/// at once; the goals and ideas themselves are never touched.
@MainActor
@Suite("Lists in the Space: the acts")
struct SpaceListActTests {
    private func withListDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "SpaceListActTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try PageSpaceRows.$overrideDefaults.withValue(.init(defaults: defaults)) {
            try body(defaults)
        }
    }

    @Test("A list is made with its rows at once, in the space asked for, holding what it was given")
    func create() throws {
        try withListDefaults { defaults in
            let vm = makeViewModel()
            let space = try #require(vm.createPageSpace(named: "Thesis"))
            let list = vm.createSpaceList(.goals, inPageSpace: space.id, holding: ["goal-1", "goal-2"])
            #expect(list.id.hasPrefix(SpaceLists.idPrefix))
            #expect(list.name == "Goals", "a new goals list is called Goals")
            #expect(defaults.string(forKey: SpaceLists.listKey(listID: list.id)) != nil)
            #expect(defaults.string(forKey: SpaceLists.itemKey(recordID: "goal-1")) == list.id)
            #expect(vm.pageSpace(ofPage: list.id) == space)
            #expect(vm.spaceList(ofRecord: "goal-2") == list)

            let other = vm.createSpaceList(.goals, named: "  Lab  ")
            #expect(other.name == "Lab")
            vm.moveRecords(["goal-2"], toSpaceList: other.id)
            #expect(vm.spaceLists.listID(of: "goal-2") == other.id, "a goal is in one list at a time")
            vm.moveRecords(["goal-2"], toSpaceList: nil)
            #expect(defaults.object(forKey: SpaceLists.itemKey(recordID: "goal-2")) == nil)
        }
    }

    @Test("Rename, Trash, Restore and Delete Forever; only a list in Trash is deleted, and its records' rows go with it")
    func lifecycle() throws {
        try withListDefaults { defaults in
            let vm = makeViewModel()
            let list = vm.createSpaceList(.ideas, holding: ["idea-1"])
            vm.renameSpaceList(list.id, to: "Hunches")
            #expect(vm.spaceLists.list(list.id)?.name == "Hunches")
            vm.renameSpaceList(list.id, to: " ")
            #expect(vm.spaceLists.list(list.id)?.name == "Hunches")

            vm.setPagePinned(list.id, pinned: true)
            #expect(vm.pinnedSpaceLists.map(\.id) == [list.id])
            vm.deleteSpaceListsForever([list.id])
            #expect(vm.spaceLists.list(list.id) != nil, "a list not in Trash is not deleted")

            vm.moveSpaceListsToTrash([list.id])
            #expect(vm.spaceLists.list(list.id)?.isTrashed == true)
            #expect(vm.pinnedSpaceLists.isEmpty, "a list in Trash leaves Pinned")
            vm.restoreSpaceLists([list.id])
            #expect(vm.spaceLists.list(list.id)?.isTrashed == false)

            vm.moveSpaceListsToTrash([list.id])
            vm.deleteSpaceListsForever([list.id])
            #expect(vm.spaceLists.list(list.id) == nil)
            #expect(defaults.object(forKey: SpaceLists.listKey(listID: list.id)) == nil)
            #expect(defaults.object(forKey: SpaceLists.itemKey(recordID: "idea-1")) == nil, "its records leave it")
            #expect(!vm.isPagePinned(list.id))
        }
    }

    @Test("A list deleted on another device is read before an act, so filing into it writes nothing back")
    func deletedElsewhere() throws {
        try withListDefaults { defaults in
            let vm = makeViewModel()
            let list = vm.createSpaceList(.goals)
            defaults.removeObject(forKey: SpaceLists.listKey(listID: list.id))
            #expect(vm.fileRecords(["goal-1"], inSpaceList: list.id) == 0)
            #expect(defaults.object(forKey: SpaceLists.itemKey(recordID: "goal-1")) == nil)
            #expect(vm.spaceLists.list(list.id) == nil)
        }
    }
}
