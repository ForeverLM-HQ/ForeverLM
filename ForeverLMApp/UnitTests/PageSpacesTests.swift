import Foundation
import Testing
@testable import ForeverLM

// Spaces of pages (docs/docs-design.md, "The Space"): the rows' rules
// (`PageSpaces`), the Mac's writes (`PageSpaceRows`,
// `StudioViewModel+PageSpaces`) and the place a space is in the sidebar.
// Every test that writes binds its own defaults suite, never the standard
// defaults the Dev build and parallel suites share.

private func withSpaceDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    let suiteName = "PageSpacesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return try PageSpaceRows.$overrideDefaults.withValue(PageSpaceRows.DefaultsOverride(defaults: defaults)) {
        try body(defaults)
    }
}

// MARK: - The rows (Foundation only)

@Suite("Spaces of pages: the rows")
struct PageSpacesRowTests {
    @Test("Rows are read under their two prefixes; a blank name, a wrong type and an empty row are no row")
    func readsRows() {
        let state = PageSpaces(rows: [
            "pageSpace.psp-a": "  Aging  ",
            "pageSpace.psp-blank": "   ",
            "pageSpace.psp-number": 7,
            "pageSpace.": "No id",
            "page.space.doc-1": "psp-a",
            "page.space.doc-2": "  ",
            "page.space.doc-3": ["psp-a"],
            "page.space.": "psp-a",
            "notebookCollection.nbc-a": "Collection",
            "notebook.collections.p1": ["nbc-a"],
            "space.sort": "created",
        ])
        #expect(state.names == ["psp-a": "Aging"])
        #expect(state.memberships == ["doc-1": "psp-a"])
        #expect(state.ordered == [PageSpace(id: "psp-a", name: "Aging")])
        #expect(state.space(ofPage: "doc-1") == PageSpace(id: "psp-a", name: "Aging"))
    }

    @Test("Keys and ids: a name row per space, a membership row per page")
    func keys() {
        #expect(PageSpaces.nameKey(spaceID: "psp-1") == "pageSpace.psp-1")
        #expect(PageSpaces.membershipKey(pageID: "doc-1") == "page.space.doc-1")
        #expect(PageSpaces.spaceID(fromNameKey: "pageSpace.psp-1") == "psp-1")
        #expect(PageSpaces.spaceID(fromNameKey: "page.space.doc-1") == nil)
        #expect(PageSpaces.pageID(fromMembershipKey: "page.space.doc-1") == "doc-1")
        #expect(PageSpaces.pageID(fromMembershipKey: "pageSpace.psp-1") == nil)
        let id = PageSpaces.newSpaceID()
        #expect(id.hasPrefix("psp-"))
        #expect(id == id.lowercased())
        #expect(id.count == 4 + 36)
        #expect(UUID(uuidString: String(id.dropFirst(4))) != nil)
        #expect(PageSpaces.newSpaceID() != id)
    }

    @Test("Spaces sort by name with a leading emoji aside and numbers in order, then by id")
    func order() {
        let state = PageSpaces(names: [
            "psp-3": "🧬 Mitochondria",
            "psp-2": "Batch 10",
            "psp-4": "Batch 9",
            "psp-6": "Aging",
            "psp-5": "Aging",
            "psp-1": "Neurons",
        ])
        #expect(state.ordered.map(\.id) == ["psp-5", "psp-6", "psp-4", "psp-2", "psp-3", "psp-1"])
    }

    @Test("A row naming a deleted space is read past: the page is in no space and the space holds nothing")
    func deadIDsAreReadPast() {
        let state = PageSpaces(
            names: ["psp-a": "Aging"],
            memberships: ["doc-1": "psp-a", "doc-2": "psp-gone", "doc-3": "psp-a"]
        )
        #expect(state.spaceID(ofPage: "doc-1") == "psp-a")
        #expect(state.spaceID(ofPage: "doc-2") == nil)
        #expect(state.space(ofPage: "doc-2") == nil)
        #expect(state.spaceID(ofPage: "doc-none") == nil)
        #expect(state.pageIDs(["doc-3", "doc-2", "doc-1", "doc-4"], in: "psp-a") == ["doc-3", "doc-1"], "in the order given")
        #expect(state.pageIDs(["doc-2"], in: "psp-gone").isEmpty, "a space with no name row holds nothing")
        #expect(state.space("psp-gone") == nil)
    }

    @Test("A move writes only the rows that change, once per page; None removes the row")
    func moveRows() {
        let state = PageSpaces(
            names: ["psp-a": "Aging", "psp-b": "Brain"],
            memberships: ["doc-1": "psp-a", "doc-2": "psp-b", "doc-3": "psp-gone"]
        )
        #expect(state.membershipRowsAfterMoving(["doc-1", "doc-2", "doc-2", "", "doc-4"], to: "psp-a") == [
            .init(pageID: "doc-2", spaceID: "psp-a"),
            .init(pageID: "doc-4", spaceID: "psp-a"),
        ], "a page already there writes nothing, a page is moved once, an empty id never")
        #expect(state.membershipRowsAfterMoving(["doc-1", "doc-4"], to: nil) == [
            .init(pageID: "doc-1", spaceID: nil),
        ], "a page in no space has no row to remove")
        #expect(state.membershipRowsAfterMoving(["doc-3"], to: nil) == [.init(pageID: "doc-3", spaceID: nil)],
                "a row naming a deleted space is removed too")
        #expect(state.membershipRowsAfterMoving(["doc-3"], to: "psp-b") == [.init(pageID: "doc-3", spaceID: "psp-b")])

        let moved = state.applying(state.membershipRowsAfterMoving(["doc-1", "doc-2"], to: "psp-b"))
        #expect(moved.pageIDs(["doc-1", "doc-2"], in: "psp-b") == ["doc-1", "doc-2"])
        #expect(moved.pageIDs(["doc-1", "doc-2"], in: "psp-a").isEmpty, "a page is in one space at a time")
        let removed = moved.applying(moved.membershipRowsAfterMoving(["doc-1"], to: nil))
        #expect(removed.memberships["doc-1"] == nil)
    }

    @Test("Deleting a space removes only the rows that name it")
    func deleteRows() {
        let state = PageSpaces(
            names: ["psp-a": "Aging", "psp-b": "Brain"],
            memberships: ["doc-2": "psp-a", "doc-1": "psp-a", "doc-3": "psp-b"]
        )
        #expect(state.membershipRowsAfterDeleting("psp-a") == [
            .init(pageID: "doc-1", spaceID: nil),
            .init(pageID: "doc-2", spaceID: nil),
        ])
        #expect(state.membershipRowsAfterDeleting("psp-none").isEmpty)
        let deleted = state.applying(state.membershipRowsAfterDeleting("psp-a")).settingName(nil, for: "psp-a")
        #expect(deleted.ordered.map(\.id) == ["psp-b"])
        #expect(deleted.memberships == ["doc-3": "psp-b"])
    }

    @Test("A name is folded to one line, trimmed and cut at 80 characters; a blank one is refused")
    func cleanedName() {
        #expect(PageSpaces.cleanedName("  Design\n studio \t ") == "Design studio")
        #expect(PageSpaces.cleanedName(" \n\t ") == nil)
        #expect(PageSpaces.cleanedName("") == nil)
        #expect(PageSpaces.cleanedName(String(repeating: "a", count: 120))?.count == 80)
        #expect(PageSpaces.cleanedName("🔬 Research project") == "🔬 Research project")
    }

    @Test("Writing a name or a row: an empty or nil value removes it")
    func applyingRows() {
        let state = PageSpaces()
            .settingName("Aging", for: "psp-a")
            .settingMembership("psp-a", for: "doc-1")
        #expect(state.space(ofPage: "doc-1")?.name == "Aging")
        #expect(state.settingName("", for: "psp-a").isEmpty)
        #expect(state.settingMembership(nil, for: "doc-1").memberships.isEmpty)
        #expect(state.settingMembership("", for: "doc-1").memberships.isEmpty)
    }
}

// MARK: - The Mac

@Suite("Spaces of pages: the Mac")
@MainActor
struct PageSpacesMacTests {
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageSpacesTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func page(_ id: String, kind: ArtifactKind? = nil, teamID: String? = nil) -> ArtifactRecord {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return ArtifactRecord(id: id, title: id, homeNotebookID: nil, linkedNotebookIDs: [], teamID: teamID, kind: kind, createdAt: date, updatedAt: date)
    }

    @Test("Both prefixes follow the account under either generation, as Settings no record took over")
    func rowsSync() {
        let name = PageSpaces.nameKey(spaceID: "psp-1")
        let membership = PageSpaces.membershipKey(pageID: "doc-1")
        for generation in [SyncGeneration.one, .two] {
            #expect(SyncedPreferenceKeys.isSynced(name, for: generation))
            #expect(SyncedPreferenceKeys.isSynced(membership, for: generation))
        }
        #expect(SyncedPreferenceKeys.isSetting(name))
        #expect(SyncedPreferenceKeys.isSetting(membership))
        #expect(SyncedPreferenceKeys.syncedPrefixes.contains(PageSpaces.namePreferenceKeyPrefix))
        #expect(SyncedPreferenceKeys.syncedPrefixes.contains(PageSpaces.membershipPreferenceKeyPrefix))
    }

    @Test("The Mac's writes: a name row, a membership row, and nil removing either")
    func rowWrites() throws {
        try withSpaceDefaults { defaults in
            PageSpaceRows.writeName("Aging", spaceID: "psp-a")
            PageSpaceRows.writeMembership("psp-a", pageID: "doc-1")
            #expect(defaults.string(forKey: "pageSpace.psp-a") == "Aging")
            #expect(defaults.string(forKey: "page.space.doc-1") == "psp-a")
            #expect(PageSpaceRows.read().spaceID(ofPage: "doc-1") == "psp-a")

            PageSpaceRows.writeMembership(nil, pageID: "doc-1")
            #expect(defaults.object(forKey: "page.space.doc-1") == nil)
            PageSpaceRows.writeName(nil, spaceID: "psp-a")
            #expect(defaults.object(forKey: "pageSpace.psp-a") == nil)
            #expect(PageSpaceRows.read() == PageSpaces())
        }
    }

    @Test("Making, filling, moving, renaming and deleting a space writes its rows and redraws the Space")
    func lifecycle() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            #expect(vm.pageSpaces.isEmpty, "a fresh library has no spaces")
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3")]

            #expect(vm.createPageSpace(named: "   ") == nil, "a blank name makes nothing")
            let studio = try #require(vm.createPageSpace(named: " 🎨 Design  studio ", moving: ["doc-1"]))
            #expect(studio.id.hasPrefix(PageSpaces.idPrefix))
            #expect(studio.name == "🎨 Design studio")
            #expect(defaults.string(forKey: PageSpaces.nameKey(spaceID: studio.id)) == "🎨 Design studio")
            #expect(defaults.string(forKey: "page.space.doc-1") == studio.id)
            #expect(vm.pageSpace(ofPage: "doc-1") == studio)

            let research = try #require(vm.createPageSpace(named: "Research project"))
            #expect(vm.orderedPageSpaces.map(\.id) == [studio.id, research.id], "by name, the emoji aside")

            vm.movePages(["doc-1", "doc-2"], toPageSpace: research.id)
            #expect(defaults.string(forKey: "page.space.doc-1") == research.id, "a page is in one space at a time")
            #expect(vm.pageSpaceArtifacts(in: research.id).map(\.id) == ["doc-1", "doc-2"])
            #expect(vm.pageSpaceArtifacts(in: studio.id).isEmpty)

            vm.movePages(["doc-2"], toPageSpace: nil)
            #expect(defaults.object(forKey: "page.space.doc-2") == nil, "a page in no space has no row")
            #expect(vm.filePages(["doc-3"], inPageSpace: "psp-unknown") == 0, "a space gone since takes nothing")
            #expect(defaults.object(forKey: "page.space.doc-3") == nil)

            vm.renamePageSpace(research.id, to: "Lab notes")
            #expect(vm.pageSpaces.space(research.id)?.name == "Lab notes")
            vm.renamePageSpace(research.id, to: "  ")
            #expect(vm.pageSpaces.space(research.id)?.name == "Lab notes", "a blank rename changes nothing")

            vm.deletePageSpace(research.id)
            #expect(vm.pageSpaces.space(research.id) == nil)
            #expect(defaults.object(forKey: PageSpaces.nameKey(spaceID: research.id)) == nil)
            #expect(defaults.object(forKey: "page.space.doc-1") == nil, "its pages' rows go; the pages stay")
            #expect(vm.artifacts.count == 3)
            #expect(vm.orderedPageSpaces == [studio])
        }
    }

    @Test("A page deleted for good leaves its space; rows another device wrote are read on reload")
    func forgetAndReload() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            let space = try #require(vm.createPageSpace(named: "Aging", moving: ["doc-1", "doc-2"]))
            vm.forgetPageSpaces(of: ["doc-1", "doc-none"])
            #expect(defaults.object(forKey: "page.space.doc-1") == nil)
            #expect(defaults.string(forKey: "page.space.doc-2") == space.id)

            defaults.set("From the other Mac", forKey: "pageSpace.psp-other")
            defaults.set("psp-other", forKey: "page.space.doc-2")
            #expect(vm.pageSpace(ofPage: "doc-2") == space)
            vm.pageSpaces = PageSpaceRows.read()
            #expect(vm.pageSpace(ofPage: "doc-2")?.name == "From the other Mac")
        }
    }

    @Test("Only the learner's own page, Google Doc, site or reading in My Library can be put in a space")
    func whatCanJoin() {
        let vm = makeViewModel()
        #expect(vm.canFileInPageSpace(page("doc-1")))
        #expect(!vm.canFileInPageSpace(page("anim", kind: .animation)), "an animation is its notebook's")
        #expect(!vm.canFileInPageSpace(page("team-doc", teamID: "team-1")), "a team's record is the team's")
    }

    @Test("A space is a place the window remembers, and keeps a page opened from it lit")
    func place() {
        let place = SpaceDestination.space("psp-1")
        #expect(SpaceDestination(key: place.key) == place)
        #expect(place.key == "space:psp-1")
        #expect(SpaceDestination(key: "space:") == .all)
        #expect(place.pageSpaceID == "psp-1")
        #expect(SpaceDestination.team("psp-1").pageSpaceID == nil)
        #expect(place.openableKind == nil)

        let spaces = PageSpaces(names: ["psp-1": "Aging"], memberships: ["doc-1": "psp-1", "doc-2": "psp-2"])
        #expect(SpaceDestination.listing(page("doc-1"), within: place, spaces: spaces) == place)
        #expect(SpaceDestination.listing(page("doc-2"), within: place, spaces: spaces) == .pages, "a page from elsewhere lights its own place")
        #expect(SpaceDestination.listing(page("doc-1"), within: .all, spaces: spaces) == .pages)
    }
}

// MARK: - Pinned pages

@Suite("Pinned pages")
@MainActor
struct PagePinsTests {
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PagePinsTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func page(_ id: String, teamID: String? = nil) -> ArtifactRecord {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return ArtifactRecord(id: id, title: id, homeNotebookID: nil, linkedNotebookIDs: [], teamID: teamID, kind: nil, createdAt: date, updatedAt: date)
    }

    @Test("Rows are read under their prefix as whole seconds, the newest pin first; anything else is no row")
    func readsRows() {
        let pins = PagePins(rows: [
            "page.pinned.doc-1": "1790000100",
            "page.pinned.doc-2": NSNumber(value: 1_790_000_300),
            "page.pinned.doc-3": "1790000300",
            "page.pinned.doc-4": "not a time",
            "page.pinned.doc-5": ["x"],
            "page.pinned.": "1790000100",
            "page.space.doc-1": "psp-a",
        ])
        #expect(pins.orderedPageIDs == ["doc-2", "doc-3", "doc-1"], "newest first, the id breaking a tie")
        #expect(pins.isPinned("doc-1"))
        #expect(!pins.isPinned("doc-4"))
        #expect(PagePins.key(pageID: "doc-1") == "page.pinned.doc-1")
        #expect(PagePins.pageID(fromKey: "page.pinned.doc-1") == "doc-1")
        #expect(PagePins.pageID(fromKey: "page.space.doc-1") == nil)
    }

    @Test("A pin row follows the account under either generation")
    func rowsSync() {
        let key = PagePins.key(pageID: "doc-1")
        for generation in [SyncGeneration.one, .two] {
            #expect(SyncedPreferenceKeys.isSynced(key, for: generation))
        }
        #expect(SyncedPreferenceKeys.isSetting(key))
    }

    @Test("Pinning writes one row with the moment, unpinning removes it, and the sidebar lists the newest pin first")
    func lifecycle() throws {
        let suite = "PagePinsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try PageSpaceRows.$overrideDefaults.withValue(PageSpaceRows.DefaultsOverride(defaults: defaults)) {
            let vm = makeViewModel()
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3", teamID: "t1")]
            #expect(vm.pinnedPages.isEmpty)

            vm.setPagePinned("doc-1", pinned: true, now: Date(timeIntervalSince1970: 1_790_000_100))
            vm.setPagePinned("doc-2", pinned: true, now: Date(timeIntervalSince1970: 1_790_000_200))
            #expect(defaults.string(forKey: "page.pinned.doc-1") == "1790000100")
            #expect(vm.isPagePinned("doc-2"))
            #expect(vm.pinnedPages.map(\.id) == ["doc-2", "doc-1"])

            vm.setPagePinned("doc-1", pinned: true, now: Date(timeIntervalSince1970: 1_790_000_900))
            #expect(defaults.string(forKey: "page.pinned.doc-1") == "1790000100", "pinning again keeps the first moment")

            vm.setPagePinned("doc-3", pinned: true, now: Date(timeIntervalSince1970: 1_790_000_300))
            #expect(vm.pinnedPages.map(\.id) == ["doc-2", "doc-1"], "a team's page is never listed as the learner's pin")

            vm.setPagePinned("doc-2", pinned: false)
            #expect(defaults.object(forKey: "page.pinned.doc-2") == nil)
            #expect(vm.pinnedPages.map(\.id) == ["doc-1"])
        }
    }

    @Test("A drag reorders the pins by rewriting values: the moved pin lands between its neighbours, the rest stay put")
    func reorderRows() {
        let pins = PagePins(pinnedAt: ["a": 500, "b": 400, "c": 300, "d": 200])
        #expect(pins.orderedPageIDs == ["a", "b", "c", "d"])

        // Up into a gap: only the moved pin's row is written.
        let up = pins.rowsAfterMoving("d", before: "b")
        #expect(up == [PagePins.Row(pageID: "d", seconds: 450)])
        #expect(pins.applying(up).orderedPageIDs == ["a", "d", "b", "c"])

        // To the top: one over the first.
        let top = pins.rowsAfterMoving("c", before: "a")
        #expect(top == [PagePins.Row(pageID: "c", seconds: 501)])
        #expect(pins.applying(top).orderedPageIDs == ["c", "a", "b", "d"])

        // To the end, and down past one.
        #expect(pins.applying(pins.rowsAfterMoving("a", before: nil)).orderedPageIDs == ["b", "c", "d", "a"])
        #expect(pins.applying(pins.rowsAfterMoving("a", before: "c")).orderedPageIDs == ["b", "a", "c", "d"])

        // Nothing moves: already there, onto itself, or not pinned.
        #expect(pins.rowsAfterMoving("b", before: "c").isEmpty)
        #expect(pins.rowsAfterMoving("d", before: nil).isEmpty)
        #expect(pins.rowsAfterMoving("b", before: "b").isEmpty)
        #expect(pins.rowsAfterMoving("x", before: "a").isEmpty)
        #expect(pins.rowsAfterMoving("a", before: "x").isEmpty)
    }

    @Test("Pins with no room between them, or pinned the same second, are rewritten down the list until each sits under the last")
    func reorderWithoutRoom() {
        // Two devices pinned three pages within the same second.
        let tied = PagePins(pinnedAt: ["a": 100, "b": 100, "c": 100, "d": 99])
        #expect(tied.orderedPageIDs == ["a", "b", "c", "d"], "the id breaks a tie")
        let rows = tied.rowsAfterMoving("c", before: "a")
        let after = tied.applying(rows)
        #expect(after.orderedPageIDs == ["c", "a", "b", "d"])
        let values = after.orderedPageIDs.compactMap { after.pinnedAt[$0] }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 > $1 }, "no two values tie after a move")

        let tight = PagePins(pinnedAt: ["a": 10, "b": 9, "c": 8, "d": 7])
        let moved = tight.applying(tight.rowsAfterMoving("d", before: "b"))
        #expect(moved.orderedPageIDs == ["a", "d", "b", "c"])
        #expect(moved.pinnedAt["a"] == 10, "the rows above the move are never written")
    }

    @Test("movePin writes the reorder rows, and pages, canvases and lists keep one pinned order")
    func movePinWritesRows() throws {
        let suite = "PagePinsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try PageSpaceRows.$overrideDefaults.withValue(PageSpaceRows.DefaultsOverride(defaults: defaults)) {
            let vm = makeViewModel()
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3")]
            vm.setPagePinned("doc-1", pinned: true, now: Date(timeIntervalSince1970: 1_790_000_100))
            vm.setPagePinned("doc-2", pinned: true, now: Date(timeIntervalSince1970: 1_790_000_200))
            vm.setPagePinned("doc-3", pinned: true, now: Date(timeIntervalSince1970: 1_790_000_300))
            #expect(vm.pinnedPages.map(\.id) == ["doc-3", "doc-2", "doc-1"])

            vm.movePin("doc-1", before: "doc-3")
            #expect(vm.pinnedPages.map(\.id) == ["doc-1", "doc-3", "doc-2"])
            #expect(defaults.string(forKey: "page.pinned.doc-1") == "1790000301")
            #expect(PagePinRows.read() == vm.pagePins, "what is written is what the sidebar reads")
        }
    }
}

// MARK: - Subpages (the rows)

@Suite("Subpages: the rows")
struct PageParentsTests {
    @Test("Rows are read under their prefix; a blank value, a wrong type, a self-parent and an empty id are no row")
    func readsRows() {
        let parents = PageParents(rows: [
            "page.parent.doc-2": "  doc-1  ",
            "page.parent.doc-3": "doc-1",
            "page.parent.doc-4": "   ",
            "page.parent.doc-5": ["doc-1"],
            "page.parent.doc-6": "doc-6",
            "page.parent.": "doc-1",
            "page.pinned.doc-7": "1790000100",
            "page.space.doc-8": "psp-a",
        ])
        #expect(parents.parentIDs == ["doc-2": "doc-1", "doc-3": "doc-1"])
        #expect(PageParents.key(pageID: "doc-2") == "page.parent.doc-2")
        #expect(PageParents.pageID(fromKey: "page.parent.doc-2") == "doc-2")
        #expect(PageParents.pageID(fromKey: "page.pinned.doc-2") == nil)
    }

    @Test("A parent row follows the account under either generation")
    func rowsSync() {
        let key = PageParents.key(pageID: "doc-1")
        for generation in [SyncGeneration.one, .two] {
            #expect(SyncedPreferenceKeys.isSynced(key, for: generation))
        }
        #expect(SyncedPreferenceKeys.isSetting(key))
        #expect(!SyncedPreferenceKeys.isSynced("space.pagesExpanded"), "which subpages a list shows is this Mac's")
    }

    @Test("A page is under its parent only while the parent is one of the pages asked about; the rest list at the top")
    func missingAndTrashedParents() {
        let parents = PageParents(parentIDs: ["b": "a", "c": "a", "d": "gone", "e": "b"])
        // a, b, c, d, e are the live pages; `gone` is in Trash or deleted, and d's row stays.
        let tree = parents.tree(among: ["a", "b", "c", "d", "e"])
        #expect(tree.rootIDs == ["a", "d"])
        #expect(tree.childIDs(of: "a") == ["b", "c"])
        #expect(tree.parentID(ofPage: "d") == nil)
        #expect(parents.rawParentID(ofPage: "d") == "gone", "the row is read past, never deleted")
        // The parent leaves the set (Trash): its children list at the top, in order.
        let withoutA = parents.tree(among: ["b", "c", "d", "e"])
        #expect(withoutA.rootIDs == ["b", "c", "d"])
        #expect(withoutA.childIDs(of: "b") == ["e"])
        // And they are back under it when the parent returns.
        #expect(parents.tree(among: ["a", "b", "c", "d", "e"]).parentID(ofPage: "b") == "a")
    }

    @Test("Siblings and roots keep the order they were given in; a page listed twice is listed once")
    func ordering() {
        let parents = PageParents(parentIDs: ["x": "p", "y": "p", "z": "p"])
        let tree = parents.tree(among: ["z", "p", "x", "q", "y", "x"])
        #expect(tree.orderedIDs == ["z", "p", "x", "q", "y"])
        #expect(tree.rootIDs == ["p", "q"])
        #expect(tree.childIDs(of: "p") == ["z", "x", "y"], "in the order given, though z came before its parent")
    }

    @Test("A page never becomes its own ancestor: not under itself, not under one of its descendants")
    func cyclePrevention() {
        let parents = PageParents(parentIDs: ["b": "a", "c": "b", "d": "c"])
        let ids = ["a", "b", "c", "d", "e"]
        let tree = parents.tree(among: ids)
        #expect(!tree.canSetParent("a", for: "a"))
        #expect(!tree.canSetParent("b", for: "a"), "a child cannot be its parent's parent")
        #expect(!tree.canSetParent("d", for: "a"), "nor a grandchild further down")
        #expect(tree.canSetParent("e", for: "a"))
        #expect(tree.canSetParent("a", for: "d"), "moving a leaf up is fine")
        #expect(tree.canSetParent(nil, for: "b"), "out to the top is always fine")
        #expect(!tree.canSetParent("not-a-page", for: "a"), "the parent must be one of the pages")
        #expect(tree.descendantIDs(of: "a") == ["b", "c", "d"])

        #expect(parents.rowsAfterSettingParent("d", for: "a", among: ids).isEmpty)
        #expect(parents.rowsAfterSettingParent("a", for: "a", among: ids).isEmpty)
        #expect(parents.rowsAfterSettingParent("ghost", for: "a", among: ids).isEmpty)
    }

    @Test("A cycle two devices made is cut at its smallest id, whatever order the pages come in")
    func storedCycleIsCut() {
        // a under b, b under c, c under a, and d under a.
        let parents = PageParents(parentIDs: ["a": "b", "b": "c", "c": "a", "d": "a"])
        for ids in [["a", "b", "c", "d"], ["d", "c", "b", "a"], ["b", "d", "a", "c"]] {
            let tree = parents.tree(among: ids)
            #expect(tree.parentID(ofPage: "a") == nil, "the smallest id of the cycle is the top")
            #expect(tree.parentID(ofPage: "c") == "a")
            #expect(tree.parentID(ofPage: "b") == "c")
            #expect(tree.parentID(ofPage: "d") == "a")
            #expect(tree.rootIDs == ids.filter { $0 == "a" }, "every page is reachable from the one root")
            #expect(Set(tree.descendantIDs(of: "a")) == ["b", "c", "d"])
        }
    }

    @Test("Depth, the ancestors' chain, and the trail over an open page")
    func depthAndTrail() {
        let parents = PageParents(parentIDs: ["b": "a", "c": "b", "d": "c", "e": "d", "f": "e", "g": "f", "h": "g"])
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let tree = parents.tree(among: ids)
        #expect(tree.depth(ofPage: "a") == 0)
        #expect(tree.depth(ofPage: "d") == 3)
        #expect(tree.ancestorIDs(ofPage: "d") == ["a", "b", "c"], "the top one first, the parent last")
        #expect(tree.ancestorIDs(ofPage: "a").isEmpty)

        // The same chain read row by row, as the open page does.
        let live = Set(ids)
        #expect(parents.ancestorIDs(ofPage: "d", isLive: { live.contains($0) }) == ["a", "b", "c"])
        #expect(parents.ancestorIDs(ofPage: "d", isLive: { $0 != "b" && live.contains($0) }) == ["c"], "the chain stops at a page that is gone")
        let cyclic = PageParents(parentIDs: ["a": "b", "b": "a"])
        #expect(cyclic.ancestorIDs(ofPage: "a", isLive: { _ in true }) == ["b"], "a stored cycle never loops")

        let short = PageParents.trail(["a", "b", "c"])
        #expect(short.ids == ["a", "b", "c"])
        #expect(!short.isTruncated)
        let long = PageParents.trail(tree.ancestorIDs(ofPage: "h") + ["x"], limit: 4)
        #expect(long.ids == ["e", "f", "g", "x"], "the nearest ancestors, the top left off")
        #expect(long.isTruncated)
        #expect(!PageParents.trail(Array(repeating: "p", count: 6)).isTruncated)
        #expect(PageParents.trail(Array(repeating: "p", count: 7)).isTruncated)
    }

    @Test("A list draws a page's subpages only while it is open, indented, and never past the display depth")
    func listRows() {
        let parents = PageParents(parentIDs: [
            "b": "a", "c": "a", "d": "b",
            "n1": "n0", "n2": "n1", "n3": "n2", "n4": "n3", "n5": "n4", "n6": "n5", "n7": "n6", "n8": "n7",
        ])
        let ids = ["a", "z", "b", "c", "d", "n0", "n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8"]
        let tree = parents.tree(among: ids)

        let closed = tree.listRows(expanded: [])
        #expect(closed.map(\.id) == ["a", "z", "n0"], "a subpage is not a top-level row while its parent is listed")
        #expect(closed[0].hasChildren)
        #expect(!closed[0].isExpanded)
        #expect(!closed[1].hasChildren)

        let open = tree.listRows(expanded: ["a"])
        #expect(open.map(\.id) == ["a", "b", "c", "z", "n0"])
        #expect(open.map(\.level) == [0, 1, 1, 0, 0])
        #expect(open[0].isExpanded)

        let nested = tree.listRows(expanded: ["a", "b"])
        #expect(nested.map(\.id) == ["a", "b", "d", "c", "z", "n0"])
        #expect(nested.map(\.level) == [0, 1, 2, 1, 0, 0])

        let deep = tree.listRows(expanded: Set(ids)).filter { $0.id.hasPrefix("n") }
        #expect(deep.map(\.level) == [0, 1, 2, 3, 4, 5, 6, 6, 6], "deeper than the display depth is drawn at it")
        #expect(tree.depth(ofPage: "n8") == 8, "and still stored as deep as it is")
        // Opening a page that has no subpages opens nothing.
        #expect(tree.listRows(expanded: ["z"]).map(\.id) == ["a", "z", "n0"])
    }

    @Test("The rows an act writes: set, move, clear, and nothing for what changes nothing")
    func rowsAfterActs() {
        let parents = PageParents(parentIDs: ["b": "a"])
        let ids = ["a", "b", "c"]
        #expect(parents.rowsAfterSettingParent("a", for: "c", among: ids) == [PageParents.Row(pageID: "c", parentID: "a")])
        #expect(parents.rowsAfterSettingParent("c", for: "b", among: ids) == [PageParents.Row(pageID: "b", parentID: "c")], "a move writes the child's one row")
        #expect(parents.rowsAfterSettingParent("a", for: "b", among: ids).isEmpty, "already there")
        #expect(parents.rowsAfterSettingParent(nil, for: "b", among: ids) == [PageParents.Row(pageID: "b", parentID: nil)])
        #expect(parents.rowsAfterSettingParent(nil, for: "c", among: ids).isEmpty, "a top-level page has no row to clear")
        // A row naming a page in Trash is rewritten by a new parent and cleared by Remove from Parent.
        let stale = PageParents(parentIDs: ["b": "trashed"])
        #expect(stale.rowsAfterSettingParent("a", for: "b", among: ids) == [PageParents.Row(pageID: "b", parentID: "a")])
        #expect(stale.rowsAfterSettingParent(nil, for: "b", among: ids) == [PageParents.Row(pageID: "b", parentID: nil)])

        let after = parents.applying([PageParents.Row(pageID: "c", parentID: "b"), PageParents.Row(pageID: "b", parentID: nil)])
        #expect(after.parentIDs == ["c": "b"])
        #expect(after.settingParent("c", for: "c").parentIDs.isEmpty, "a row naming the page itself is no row")
    }

    @Test("Deleting a page for good removes its row and the rows naming it, by id")
    func forgetting() {
        let parents = PageParents(parentIDs: ["b": "a", "c": "a", "d": "b", "e": "x"])
        #expect(parents.rowsAfterForgetting(["a"]).map(\.pageID) == ["b", "c"])
        #expect(parents.rowsAfterForgetting(["b"]).map(\.pageID) == ["b", "d"])
        #expect(parents.rowsAfterForgetting(["a", "b"]).map(\.pageID) == ["b", "c", "d"])
        #expect(parents.rowsAfterForgetting(["zz"]).isEmpty)
        #expect(parents.rowsAfterForgetting(["a"]).allSatisfy { $0.parentID == nil })
    }
}

// MARK: - Subpages (the Mac's writes)

@Suite("Subpages: the Mac's writes")
@MainActor
struct PageParentsMacTests {
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageParentsMacTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func page(
        _ id: String,
        teamID: String? = nil,
        linkedURL: String? = nil,
        archived: Bool = false
    ) -> ArtifactRecord {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return ArtifactRecord(
            id: id,
            title: id,
            homeNotebookID: nil,
            linkedNotebookIDs: [],
            linkedURL: linkedURL,
            teamID: teamID,
            archivedAt: archived ? date : nil,
            kind: nil,
            createdAt: date,
            updatedAt: date
        )
    }

    @Test("Nesting writes one row, reads back as a parent and its subpages, and Remove from Parent clears it")
    func lifecycle() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3"), page("doc-4")]
            #expect(vm.pageParent(of: "doc-2") == nil)
            #expect(vm.subpages(of: "doc-1").isEmpty)

            #expect(vm.setPageParent("doc-2", to: "doc-1"))
            #expect(vm.setPageParent("doc-3", to: "doc-1"))
            #expect(defaults.string(forKey: "page.parent.doc-2") == "doc-1")
            #expect(vm.pageParent(of: "doc-2")?.id == "doc-1")
            #expect(vm.subpages(of: "doc-1").map(\.id) == ["doc-2", "doc-3"], "in the library's order")
            #expect(vm.pageAncestors(of: "doc-2").map(\.id) == ["doc-1"])

            #expect(!vm.setPageParent("doc-2", to: "doc-1"), "already there writes nothing")
            #expect(vm.setPageParent("doc-4", to: "doc-2"))
            #expect(vm.pageAncestors(of: "doc-4").map(\.id) == ["doc-1", "doc-2"], "the top one first")

            #expect(vm.setPageParent("doc-2", to: nil))
            #expect(defaults.object(forKey: "page.parent.doc-2") == nil)
            #expect(vm.subpages(of: "doc-1").map(\.id) == ["doc-3"])
            #expect(vm.pageAncestors(of: "doc-4").map(\.id) == ["doc-2"])
        }
    }

    @Test("A page is never put under itself or under its own subpage, and nothing is written")
    func refusesCycles() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3")]
            vm.setPageParent("doc-2", to: "doc-1")
            vm.setPageParent("doc-3", to: "doc-2")

            #expect(!vm.setPageParent("doc-1", to: "doc-1"))
            #expect(!vm.setPageParent("doc-1", to: "doc-3"))
            #expect(!vm.setPageParent("doc-1", to: "doc-2"))
            #expect(defaults.object(forKey: "page.parent.doc-1") == nil)
            #expect(vm.pageParentCandidates(for: "doc-1").isEmpty, "every other page is under it")
            #expect(vm.pageParentCandidates(for: "doc-3").map(\.id) == ["doc-1", "doc-2"], "by name")
            #expect(vm.pageParentCandidates(for: "doc-2").map(\.id) == ["doc-1"])
        }
    }

    @Test("A parent in Trash leaves its subpages at the top and the rows alone; restoring brings them back")
    func trashedParent() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3")]
            vm.setPageParent("doc-2", to: "doc-1")
            vm.setPageParent("doc-3", to: "doc-2")

            vm.artifacts = [page("doc-1", archived: true), page("doc-2"), page("doc-3")]
            #expect(vm.pageParent(of: "doc-2") == nil)
            #expect(vm.pageTree.rootIDs == ["doc-2"])
            #expect(vm.pageTree.childIDs(of: "doc-2") == ["doc-3"], "a subtree stays together")
            #expect(defaults.string(forKey: "page.parent.doc-2") == "doc-1", "the row stays")
            #expect(!vm.setPageParent("doc-3", to: "doc-1"), "a page in Trash is no parent to choose")
            #expect(vm.pageParentCandidates(for: "doc-3").map(\.id) == ["doc-2"])

            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3")]
            #expect(vm.pageParent(of: "doc-2")?.id == "doc-1")
        }
    }

    @Test("Only the learner's own Markdown pages nest: not a team's, a linked page or a daily note")
    func onlyOwnPages() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            vm.artifacts = [
                page("doc-1"),
                page("team-1", teamID: "t1"),
                page("google-1", linkedURL: "https://docs.google.com/document/d/x/edit"),
                page("daily-2026-10-07"),
                page("doc-2"),
            ]
            #expect(!vm.setPageParent("team-1", to: "doc-1"))
            #expect(!vm.setPageParent("doc-1", to: "team-1"))
            #expect(!vm.setPageParent("google-1", to: "doc-1"))
            #expect(!vm.setPageParent("doc-1", to: "google-1"))
            #expect(!vm.setPageParent("daily-2026-10-07", to: "doc-1"), "a daily note is reached by its day")
            #expect(!vm.setPageParent("doc-1", to: "daily-2026-10-07"))
            #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("page.parent.") })
            #expect(vm.pageParentCandidates(for: "doc-1").map(\.id) == ["doc-2"])
            #expect(vm.setPageParent("doc-2", to: "doc-1"))
        }
    }

    @Test("A page made inside another is nested under it and filed in the parent's space")
    func newSubpageInheritsSpace() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3")]
            let space = try #require(vm.createPageSpace(named: "Aging", moving: ["doc-1"]))

            vm.nestNewPage("doc-2", under: "doc-1")
            #expect(defaults.string(forKey: "page.parent.doc-2") == "doc-1")
            #expect(vm.pageSpace(ofPage: "doc-2")?.id == space.id)

            vm.nestNewPage("doc-3", under: "doc-2")
            #expect(vm.pageSpace(ofPage: "doc-3")?.id == space.id, "a subpage of a subpage too")
            #expect(vm.pageAncestors(of: "doc-3").map(\.id) == ["doc-1", "doc-2"])
        }
    }

    @Test("Deleting a page for good frees its subpages and removes its row")
    func forgettingPages() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3")]
            vm.setPageParent("doc-2", to: "doc-1")
            vm.setPageParent("doc-3", to: "doc-2")

            vm.forgetPageParents(of: ["doc-2"])
            #expect(defaults.object(forKey: "page.parent.doc-2") == nil)
            #expect(defaults.object(forKey: "page.parent.doc-3") == nil)
            #expect(vm.pageParents.isEmpty)
        }
    }

    @Test("Rows another device wrote are read before an act writes over them")
    func readsStoredRowsFirst() throws {
        try withSpaceDefaults { defaults in
            let vm = makeViewModel()
            vm.artifacts = [page("doc-1"), page("doc-2"), page("doc-3")]
            #expect(vm.pageParent(of: "doc-3") == nil)
            // Another Mac nested doc-1 under doc-2; this cache has not heard.
            defaults.set("doc-2", forKey: "page.parent.doc-1")
            #expect(!vm.setPageParent("doc-2", to: "doc-1"), "that would make doc-2 its own ancestor")
            #expect(vm.setPageParent("doc-3", to: "doc-1"))
            #expect(vm.pageAncestors(of: "doc-3").map(\.id) == ["doc-2", "doc-1"])

            defaults.removeObject(forKey: "page.parent.doc-1")
            vm.reloadGroupingRows(afterRemoteChangeOf: ["page.parent.doc-1"])
            #expect(vm.pageAncestors(of: "doc-3").map(\.id) == ["doc-1"])
        }
    }
}
