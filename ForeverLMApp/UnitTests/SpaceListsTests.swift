import Foundation
import Testing
@testable import ForeverLM

/// Lists in the Space (docs/docs-design.md, "Lists in the Space"): a list of
/// Ideas is a synced row of its own, and each Idea names
/// the one list it is in.
@Suite("Lists in the Space: the rows")
struct SpaceListRowTests {
    private func list(_ id: String, _ kind: SpaceList.Kind = .ideas, name: String = "Thesis", created: Double = 100, trashed: Double? = nil) -> SpaceList {
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
        let ideas = list("lst-i")
        let retiredGoals = list("lst-g", .goals)
        let lists = SpaceLists(rows: [
            SpaceLists.listKey(listID: "lst-i"): SpaceLists.rowValue(ideas),
            SpaceLists.listKey(listID: "lst-g"): SpaceLists.rowValue(retiredGoals),
            SpaceLists.itemKey(recordID: "idea-1"): "lst-i",
            SpaceLists.itemKey(recordID: "goal-1"): "lst-g",
            SpaceLists.itemKey(recordID: "idea-2"): "lst-gone",
            SpaceLists.itemKey(recordID: "idea-3"): "  ",
            "spaceList.": SpaceLists.rowValue(ideas),
            "pageSpace.psp-1": "Aging",
        ])
        #expect(lists.all == [ideas])
        #expect(lists.listID(of: "idea-1") == "lst-i")
        #expect(lists.listID(of: "goal-1") == nil, "retired Goals lists are not a hidden home")
        #expect(lists.listID(of: "idea-2") == nil, "its list is gone")
        #expect(lists.listID(of: "idea-3") == nil)
        #expect(lists.recordIDs(["idea-2", "idea-1"], in: "lst-i") == ["idea-1"])
    }

    @Test("Filing writes only the rows that change; deleting a list takes every row naming it")
    func rowsAfterActs() {
        let lists = SpaceLists(lists: ["lst-a": list("lst-a"), "lst-b": list("lst-b")], memberships: ["i1": "lst-a", "i2": "lst-b"])
        let rows = lists.itemRowsAfterFiling(["i1", "i2", "i2", ""], in: "lst-a")
        #expect(rows == [SpaceLists.ItemRow(recordID: "i2", listID: "lst-a")], "i1 is there already; i2 once")
        let after = lists.applying(rows)
        #expect(after.listID(of: "i2") == "lst-a")
        #expect(after.itemRowsAfterDeleting("lst-a").map(\.recordID) == ["i1", "i2"])
        #expect(after.itemRowsAfterFiling(["i1"], in: nil) == [SpaceLists.ItemRow(recordID: "i1", listID: nil)])
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
/// at once; the Ideas themselves are never touched.
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
            let list = vm.createSpaceList(.ideas, inPageSpace: space.id, holding: ["idea-1", "idea-2"])
            #expect(list.id.hasPrefix(SpaceLists.idPrefix))
            #expect(list.name == "Ideas")
            #expect(defaults.string(forKey: SpaceLists.listKey(listID: list.id)) != nil)
            #expect(defaults.string(forKey: SpaceLists.itemKey(recordID: "idea-1")) == list.id)
            #expect(vm.pageSpace(ofPage: list.id) == space)
            #expect(vm.spaceList(ofRecord: "idea-2") == list)

            let other = vm.createSpaceList(.ideas, named: "  Lab  ")
            #expect(other.name == "Lab")
            vm.moveRecords(["idea-2"], toSpaceList: other.id)
            #expect(vm.spaceLists.listID(of: "idea-2") == other.id, "an Idea is in one list at a time")
            vm.moveRecords(["idea-2"], toSpaceList: nil)
            #expect(defaults.object(forKey: SpaceLists.itemKey(recordID: "idea-2")) == nil)
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
            let list = vm.createSpaceList(.ideas)
            defaults.removeObject(forKey: SpaceLists.listKey(listID: list.id))
            #expect(vm.fileRecords(["idea-1"], inSpaceList: list.id) == 0)
            #expect(defaults.object(forKey: SpaceLists.itemKey(recordID: "idea-1")) == nil)
            #expect(vm.spaceLists.list(list.id) == nil)
        }
    }
}
