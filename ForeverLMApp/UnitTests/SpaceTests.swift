import Foundation
import Testing
@testable import ForeverLM

/// The Space (docs/docs-design.md, "The Space"): the sidebar's places as a
/// window remembers them, the Recents this Mac keeps, and the short dates.
@MainActor
@Suite("Space")
struct SpaceTests {
    @Test("Every place survives the window's key, a team's id included")
    func destinationKeysRoundTrip() {
        let places: [SpaceDestination] = SpaceDestination.places + [.trash, .team("team-1"), .team("a:b")]
        for place in places {
            #expect(SpaceDestination(key: place.key) == place)
        }
        // A key this build does not know, or a team with no id, is All.
        #expect(SpaceDestination(key: "") == .all)
        #expect(SpaceDestination(key: "somewhere") == .all)
        #expect(SpaceDestination(key: "team:") == .all)
    }

    @Test("The sidebar lists ChatGPT's places in its order, Chats after Notebooks, Canvases after Sites, and no Ideas")
    func placesAreChatGPTsOrder() {
        #expect(SpaceDestination.places == [.all, .notebooks, .chats, .pages, .sites, .canvases, .images, .drive])
        #expect(SpaceDestination.places(listsCanvases: false) == [.all, .notebooks, .chats, .pages, .sites, .images, .drive])
        #expect(SpaceDestination.sidebarPlaces(listsCanvases: true) == [.notebooks, .chats, .pages, .sites, .canvases, .images, .drive],
                "All is the landing list, not a sidebar row")
        #expect(SpaceDestination.sidebarPlaces(listsCanvases: false) == [.notebooks, .chats, .pages, .sites, .images, .drive])
        #expect(SpaceDestination.chats.openableKind == nil, "Chats is a list in the Space, not a pane of its own")
        // Ideas left the sidebar on 2026-10-10 for the chat: a window that
        // remembered the place opens on All.
        #expect(SpaceDestination(key: "ideas") == .all)
        #expect(SpaceDestination.canvases.openableKind == nil, "a canvas opens one at a time, not as a pane of every canvas")
        #expect(SpaceDestination.pages.openableKind == .docs)
        #expect(SpaceDestination.sites.openableKind == .sites)
        #expect(SpaceDestination.all.openableKind == nil)
        #expect(SpaceDestination.trash.openableKind == nil)
    }

    @Test("A record open beside the sidebar lights the place it is listed under")
    func listingPlace() {
        let now = Date()
        let page = ArtifactRecord(id: "p", title: "Page", homeNotebookID: nil, linkedNotebookIDs: [], createdAt: now, updatedAt: now)
        let googleDoc = ArtifactRecord(
            id: "g", title: "Doc", homeNotebookID: nil, linkedNotebookIDs: [],
            linkedURL: "https://docs.google.com/document/d/abc/edit",
            createdAt: now, updatedAt: now
        )
        let trashed = ArtifactRecord(
            id: "t", title: "Old", homeNotebookID: nil, linkedNotebookIDs: [],
            archivedAt: now, createdAt: now, updatedAt: now
        )
        #expect(SpaceDestination.listing(page) == .pages)
        #expect(SpaceDestination.listing(googleDoc) == .drive)
        #expect(SpaceDestination.listing(trashed) == .trash)
    }

    @Test("Recents keep the latest opening first, once, within capacity, across launches")
    func recentsOrderAndPersistence() throws {
        let suite = "SpaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let recents = SpaceRecents(defaults: defaults)
        recents.note(.artifact, id: "a", at: Date(timeIntervalSince1970: 1))
        recents.note(.image, id: "i", title: "A cell", at: Date(timeIntervalSince1970: 2))
        recents.note(.artifact, id: "a", at: Date(timeIntervalSince1970: 3))
        #expect(recents.items.map(\.id) == ["a", "i"])
        #expect(recents.items.first?.openedAt == Date(timeIntervalSince1970: 3))

        // The same kind and id from another launch reads back the same.
        let reloaded = SpaceRecents(defaults: defaults)
        #expect(reloaded.items == recents.items)
        #expect(reloaded.items.last?.title == "A cell")

        reloaded.forget(.image, id: "i")
        #expect(reloaded.items.map(\.id) == ["a"])

        for index in 0..<(SpaceRecents.capacity + 5) {
            reloaded.note(.artifact, id: "r\(index)")
        }
        #expect(reloaded.items.count == SpaceRecents.capacity)
        #expect(reloaded.items.first?.id == "r\(SpaceRecents.capacity + 4)")
    }

    @Test("An unreadable stored value reads as no Recents")
    func recentsIgnoreForeignShapes() throws {
        let suite = "SpaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not a list", forKey: SpaceRecents.preferenceKey)
        #expect(SpaceRecents(defaults: defaults).items.isEmpty)
        defaults.set([["k": "artifact"], ["k": "nonsense", "id": "x", "t": 1.0]], forKey: SpaceRecents.preferenceKey)
        #expect(SpaceRecents(defaults: defaults).items.isEmpty)
    }

    @Test("The Space's keys stay on this Mac")
    func keysAreDeviceLocal() {
        for key in [
            SpaceRecents.preferenceKey, SpaceLayout.preferenceKey, SpaceSort.preferenceKey,
            SpaceLayout.groupsByCollectionKey, "space.sidebarHidden",
        ] {
            #expect(SyncedPreferenceKeys.excluded[key] != nil)
            #expect(!SyncedPreferenceKeys.isSynced(key))
        }
    }

    @Test("Dates read as ChatGPT's short ones")
    func shortDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SpaceDateText.short(now.addingTimeInterval(-20), now: now) == "now")
        #expect(SpaceDateText.short(now.addingTimeInterval(-8 * 60), now: now) == "8m")
        #expect(SpaceDateText.short(now.addingTimeInterval(-8 * 3600), now: now) == "8h")
        #expect(SpaceDateText.short(now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
        #expect(SpaceDateText.short(now.addingTimeInterval(-40 * 86_400), now: now).isEmpty == false)
    }

    @Test("⌘-click chooses one row or lets it go, ⇧-click takes in the run from the last one chosen")
    func selectionClicks() {
        let order = ["a", "b", "c", "d", "e"]
        var selection = SpaceSelection()
        #expect(selection.isEmpty)
        selection.toggle("b")
        #expect(selection.ids == ["b"])
        selection.extend(to: "d", in: order)
        #expect(selection.ordered(in: order) == ["b", "c", "d"])
        // A run upward from the same anchor adds to what is chosen, as Finder's does.
        selection.extend(to: "a", in: order)
        #expect(selection.ordered(in: order) == ["a", "b", "c", "d"])
        selection.toggle("c")
        #expect(selection.ordered(in: order) == ["a", "b", "d"], "⌘-click lets a chosen row go")
        // The row let go is the anchor now: a run from it.
        selection.extend(to: "e", in: order)
        #expect(selection.ordered(in: order) == ["a", "b", "c", "d", "e"])
        #expect(selection.count == 5)
    }

    @Test("Select All takes every row drawn; a row that leaves the list leaves the selection; a run with no anchor chooses one")
    func selectionAllAndPrune() {
        var selection = SpaceSelection()
        selection.extend(to: "c", in: ["a", "b", "c"])
        #expect(selection.ids == ["c"], "no anchor yet: a ⇧-click chooses the one row")
        selection.selectAll(["a", "b", "c"])
        #expect(selection.count == 3)
        selection.keep(only: ["a", "c"])
        #expect(selection.ids == ["a", "c"])
        selection.keep(only: ["c"])
        selection.extend(to: "c", in: ["c", "d"])
        #expect(selection.ids == ["c"])
        selection.clear()
        #expect(selection.isEmpty)
        #expect(SpaceBrowseView.countLabel(1) == "1 Item")
        #expect(SpaceBrowseView.countLabel(4) == "4 Items")
    }

    @Test("Last activity is the default order, as Codex's Space lists, on the Mac and the phone")
    func defaultSortIsActivity() {
        #expect(SpaceSort.standard == .activity)
        #expect(MobileSpaceSort.standard.rawValue == SpaceSort.standard.rawValue)
        #expect(SpaceSort.created.dateColumnTitle == "Created")
        #expect(SpaceSort.activity.dateColumnTitle == "Last activity")
    }
}

/// The notebooks the Space lists now that it is the home (product owner,
/// 2026-10-09; docs/docs-design.md, "The Space"): under All while active, in
/// Trash while archived, and grouped under their collections on request.
@MainActor
@Suite("Notebooks in the Space")
struct SpaceNotebooksTests {
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceNotebooksTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private func notebook(_ id: String, archived: Bool = false, at seconds: TimeInterval = 0, teamID: String?) -> LearningGoalRecord {
        let date = Date(timeIntervalSince1970: 1_790_000_000 + seconds)
        return LearningGoalRecord(
            id: id,
            title: id,
            startAt: date,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: date,
            updatedAt: date,
            status: (archived ? LearningGoalStatus.archived : .active).rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            teamID: teamID
        )
    }

    private func page(_ id: String, trashed: Bool) -> SpaceItem {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let record = ArtifactRecord(
            id: id, title: id, homeNotebookID: nil, linkedNotebookIDs: [],
            archivedAt: trashed ? date : nil, createdAt: date, updatedAt: date
        )
        return SpaceItem(id: id, kind: .page, title: id, createdAt: date, updatedAt: date, artifact: record)
    }

    @Test("An archived notebook is a Trash item, an active one an All item, each with its cover or emoji")
    func archivedNotebookIsInTrash() {
        let vm = makeViewModel()
        vm.learningGoals = [
            notebook("bio", teamID: vm.activeTeamID),
            notebook("old", archived: true, teamID: vm.activeTeamID),
        ]
        let items = SpaceCatalog.items(vm: vm, images: [])
        let active = items.first { $0.id == "bio" }
        let archived = items.first { $0.id == "old" }
        #expect(active?.kind == .notebook)
        #expect(active?.isArchived == false)
        #expect(active?.isInTrash == false, "an active notebook is never in Trash")
        #expect(archived?.kind == .notebook)
        #expect(archived?.isArchived == true, "so All never lists it")
        #expect(archived?.isInTrash == true)
        #expect(archived?.notebook?.id == "old", "the row draws its cover or emoji from the record")
        #expect(items.filter { $0.kind == .notebook }.count == 2)
    }

    @Test("Trash lists the trashed pages first and the archived notebooks after them, each run in its own order")
    func trashOrdersNotebooksLast() {
        let vm = makeViewModel()
        vm.learningGoals = [
            notebook("aging", archived: true, teamID: vm.activeTeamID),
            notebook("bio", archived: true, teamID: vm.activeTeamID),
        ]
        let notebooks = SpaceCatalog.items(vm: vm, images: []).filter { $0.kind == .notebook }
        let trashed = [notebooks[0], page("zeta", trashed: true), notebooks[1], page("alpha", trashed: true)]
        let ordered = SpaceCatalog.trashOrder(trashed)
        #expect(ordered.map(\.id) == ["zeta", "alpha", notebooks[0].id, notebooks[1].id])
        let everyOneInTrash = ordered.allSatisfy { $0.isInTrash }
        #expect(everyOneInTrash)
    }

    @Test("Chats lists a notebook's chats beside the loose and the hidden ones, never a memory review, whatever the rail's filter")
    func chatsPlaceListsEveryChat() {
        let vm = makeViewModel()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        vm.learningGoals = [notebook("bio", teamID: vm.activeTeamID)]
        vm.reviewSessionLinks = [
            ReviewSessionRecord(id: "in-bio", title: "About cells", createdAt: date, status: "active", sourceIDs: ["s1"], goalID: "bio"),
            ReviewSessionRecord(id: "loose", title: "", createdAt: date.addingTimeInterval(60), status: "active", sourceIDs: []),
            ReviewSessionRecord(id: "tucked", title: "Put away", createdAt: date.addingTimeInterval(120), status: "active", sourceIDs: [], hiddenAt: date),
            ReviewSessionRecord(id: MemoryReviewSession.sessionID(for: date), title: "Memory", createdAt: date, status: "active", sourceIDs: []),
        ]
        // The rail's chats can be narrowed to a source; the Space's Chats never is.
        vm.reviewSessionFilter = .source("s1")
        let items = SpaceCatalog.chatItems(vm: vm)
        #expect(items.map(\.id) == ["tucked", "loose", "in-bio"], "newest first; a day's memory review is Memory's")
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(byID["in-bio"]?.kind == .chat)
        #expect(byID["in-bio"]?.location == "bio", "the Notebook column names the chat's notebook")
        #expect(byID["loose"]?.location == nil, "a chat in no notebook reads —")
        #expect(byID["loose"]?.title == "Untitled chat")
        #expect(byID["tucked"]?.isHidden == true, "so only the Hidden scope lists it")
        #expect(byID["in-bio"]?.otherWindowDestination == .chat("in-bio"))
        #expect(byID["in-bio"].map { vm.notebooksHolding($0.filing) } == ["bio"])
        #expect(byID["loose"].map { vm.notebooksHolding($0.filing).isEmpty } == true, "Not in a Notebook finds it")
    }

    @Test("A page in the Trash is a Trash item and a live page is not")
    func pagesFollowTheSameRule() {
        #expect(page("a", trashed: true).isInTrash)
        #expect(!page("b", trashed: false).isInTrash)
    }

    @Test("Group by Collection puts each notebook under every collection it is in, then everything else")
    func groupsUnderCollections() {
        let vm = makeViewModel()
        vm.learningGoals = (["aging", "bio", "neuro", "loose"]).map { notebook($0, teamID: vm.activeTeamID) }
        let items = SpaceCatalog.items(vm: vm, images: [])
            .filter { $0.kind == .notebook }
            .sorted { $0.title < $1.title }
        let collections = NotebookCollections(
            names: ["nbc-a": "Aging", "nbc-b": "Brains", "nbc-empty": "Zeta"],
            memberships: ["aging": ["nbc-a"], "bio": ["nbc-a", "nbc-b"], "neuro": ["nbc-b"]]
        )
        let sections = SpaceCatalog.groupedByCollection(
            items + [page("a-page", trashed: false)],
            ordered: collections.ordered,
            collections: collections,
            keepsEmpty: true
        )
        #expect(sections.map(\.id) == ["nbc-a", "nbc-b", "nbc-empty", "none"])
        #expect(sections[0].items.map(\.id) == ["aging", "bio"])
        #expect(sections[1].items.map(\.id) == ["bio", "neuro"], "a notebook in two collections is in both runs")
        #expect(sections[2].items.isEmpty, "an empty collection keeps its heading so it can be renamed or deleted")
        #expect(sections[3].collection == nil)
        #expect(sections[3].items.map(\.id) == ["loose", "a-page"], "the other kinds and the uncollected notebooks")

        // Narrowed by a search, a scope or a notebook filter, an empty collection has no heading.
        let narrowed = SpaceCatalog.groupedByCollection(
            items, ordered: collections.ordered, collections: collections, keepsEmpty: false
        )
        #expect(narrowed.map(\.id) == ["nbc-a", "nbc-b", "none"])
    }

    @Test("A library with no collection offers no grouping and every item is one run")
    func noCollectionsNoHeadings() {
        let vm = makeViewModel()
        vm.learningGoals = [notebook("bio", teamID: vm.activeTeamID)]
        let items = SpaceCatalog.items(vm: vm, images: [])
        let sections = SpaceCatalog.groupedByCollection(items, ordered: [], collections: NotebookCollections(), keepsEmpty: true)
        #expect(sections.map(\.id) == ["none"])
        #expect(sections[0].items.map(\.id) == items.map(\.id))
    }
}
