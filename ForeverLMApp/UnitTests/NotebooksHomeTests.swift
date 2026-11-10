import Foundation
import SwiftUI
import Testing
@testable import ForeverLM

// Shell stage 3: every window opens in the notebook last worked in, the Space
// where it has none (the Notebooks home until 2026-10-09), and the full-window
// Library (docs/notebooks-design.md).

private func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_790_000_000 + seconds)
}

/// An active notebook of My Library.
private func notebook(
    _ id: String,
    title: String? = nil,
    summary: String? = nil,
    updatedAt: Date = at(0),
    archived: Bool = false,
    teamID: String? = nil
) -> LearningGoalRecord {
    LearningGoalRecord(
        id: id,
        title: title ?? id,
        startAt: at(0),
        endAt: LearningGoalRecord.openEndedEndAt,
        createdAt: at(0),
        updatedAt: updatedAt,
        status: (archived ? LearningGoalStatus.archived : .active).rawValue,
        items: [],
        kind: LearningGoalRecord.companionKind,
        summary: summary,
        teamID: teamID
    )
}

/// `notebook(...)` holding `count` approved sources.
private func notebook(_ id: String, title: String, sources count: Int, updatedAt: Date = at(0)) -> LearningGoalRecord {
    var record = notebook(id, title: title, updatedAt: updatedAt)
    record.items = (0..<count).map { index in
        LearningGoalItem(id: "\(id)-item-\(index)", goalID: id, sourceID: "\(id)-src-\(index)", addedAt: at(0))
    }
    return record
}

/// Collections named by id, each holding the notebooks listed.
private func collections(_ members: [String: [String]]) -> NotebookCollections {
    var byNotebook: [String: Set<String>] = [:]
    for (collectionID, notebookIDs) in members {
        for notebookID in notebookIDs { byNotebook[notebookID, default: []].insert(collectionID) }
    }
    return NotebookCollections(
        names: Dictionary(uniqueKeysWithValues: members.keys.map { ($0, $0.replacingOccurrences(of: "nbc-", with: "")) }),
        memberships: byNotebook
    )
}

// MARK: - The notebook last worked in

@Suite("Notebook last worked in")
struct NotebookRecencyTests {
    @Test("The latest stamp is the notebook last worked in; a tie goes to the larger id")
    func mostRecent() {
        var recency = NotebookRecency()
        #expect(recency.mostRecent == nil)
        recency.note("bio", at: at(10))
        recency.note("neuro", at: at(20))
        #expect(recency.mostRecent == "neuro")
        // Opening, a chat sent or a source added: the latest event wins.
        recency.note("bio", at: at(30))
        #expect(recency.mostRecent == "bio")
        #expect(recency.stamp("bio") == at(30))
        recency.note("", at: at(40))
        #expect(recency.mostRecent == "bio", "an empty id is no notebook")
        #expect(NotebookRecency(stamps: ["a": at(5), "b": at(5)]).mostRecent == "b")
    }

    @Test("The home's Recent order reads the later of this Mac's stamp and the record's own change")
    func lastWorkedAt() {
        let recency = NotebookRecency(stamps: ["bio": at(50)])
        #expect(recency.lastWorkedAt("bio", updatedAt: at(10)) == at(50))
        #expect(recency.lastWorkedAt("bio", updatedAt: at(90)) == at(90), "a source added on the other Mac")
        #expect(recency.lastWorkedAt("never-here", updatedAt: at(20)) == at(20))
    }

    @Test("Past its capacity the oldest notebooks are forgotten")
    func capacity() {
        var recency = NotebookRecency()
        let total = NotebookRecency.capacity + 5
        for index in 0..<total {
            recency.note("notebook-\(index)", at: at(TimeInterval(index)))
        }
        #expect(recency.stamps.count == NotebookRecency.capacity)
        #expect(recency.stamp("notebook-0") == nil)
        #expect(recency.stamp("notebook-4") == nil)
        #expect(recency.stamp("notebook-5") != nil)
        #expect(recency.mostRecent == "notebook-\(total - 1)")
    }

    @Test("A merged notebook's stamp moves to the one it was merged into")
    func merge() {
        var recency = NotebookRecency(stamps: ["old": at(90), "survivor": at(10)])
        recency.merge("old", into: "survivor")
        #expect(recency.stamps == ["survivor": at(90)])
        recency.merge("missing", into: "survivor")
        #expect(recency.stamps == ["survivor": at(90)])
        var older = NotebookRecency(stamps: ["old": at(5), "survivor": at(60)])
        older.merge("old", into: "survivor")
        #expect(older.stamps == ["survivor": at(60)], "the survivor keeps its own later stamp")
    }

    @Test("Stamps round-trip through this Mac's defaults, and a value another build wrote in another shape is skipped")
    func persistence() throws {
        let suite = "NotebookRecencyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(NotebookRecency.load(from: defaults) == NotebookRecency())
        let recency = NotebookRecency(stamps: ["bio": at(10), "neuro": at(20)])
        recency.save(to: defaults)
        #expect(NotebookRecency.load(from: defaults) == recency)

        defaults.set(["bio": "not a time", "neuro": 1_790_000_020.0, "": 3.0], forKey: NotebookRecency.preferenceKey)
        #expect(NotebookRecency.load(from: defaults).stamps == ["neuro": at(20)])

        // A view model a test makes keeps its stamps in memory alone.
        #expect(NotebookRecency.load(from: nil) == NotebookRecency())
        recency.save(to: nil)
    }

    @Test("The stamps are this Mac's: the key never syncs")
    func neverSynced() {
        #expect(!SyncedPreferenceKeys.isSynced(NotebookRecency.preferenceKey))
        #expect(SyncedPreferenceKeys.excluded[NotebookRecency.preferenceKey] != nil)
    }
}

// MARK: - The notebooks' order, cards and the View menu

@Suite("Notebook order, cards and the View menu")
struct NotebooksHomeTests {
    @Test("Recent puts the notebook last worked in first; Name reads past a leading emoji")
    func sortOrders() {
        let mito = notebook("a", title: "🧬 Mitochondria", updatedAt: at(100))
        let bio = notebook("b", title: "Bioelectricity", updatedAt: at(50))
        let aging = notebook("c", title: "Aging", updatedAt: at(10))
        let recency = NotebookRecency(stamps: ["c": at(200)])
        #expect(NotebooksHomeSort.recent.ordered([mito, bio, aging], recency: recency).map(\.id) == ["c", "a", "b"])
        #expect(NotebooksHomeSort.name.ordered([mito, bio, aging], recency: recency).map(\.id) == ["c", "b", "a"])
        // Equal moments fall back to the title, so two cards never trade places.
        let twins = [notebook("y", title: "Zeta"), notebook("x", title: "Alpha")]
        #expect(NotebooksHomeSort.recent.ordered(twins, recency: NotebookRecency()).map(\.id) == ["x", "y"])
        #expect(NotebooksHomeSort.allCases.map(\.title) == ["Recent", "Name", "Sources", "Uncategorized first"])
    }

    @Test("A leading emoji is the notebook's icon; a digit, a symbol and an emoji alone stay text")
    func titleIcon() {
        let mito = NotebookTitle("🧬 Mitochondria")
        #expect(mito.icon == "🧬")
        #expect(mito.text == "Mitochondria")
        #expect(NotebookTitle("❤️ Heart failure").icon == "❤️")
        #expect(NotebookTitle("1 Thing").icon == nil)
        #expect(NotebookTitle("1 Thing").text == "1 Thing")
        #expect(NotebookTitle("#ideas").icon == nil)
        #expect(NotebookTitle("🧬").icon == nil)
        #expect(NotebookTitle("🧬").text == "🧬")
        #expect(NotebookTitle("  Sleep  ").text == "Sleep")
    }

    @Test("A book's chapters count as one source on a card and in the list")
    func bookCountsOnce() {
        // 11 chapters of one book plus 12 other sources read 13, not 23.
        let chapters: [(String?)] = (1...11).map { _ in "How Life Works" }
        let others: [(String?)] = Array(repeating: nil, count: 12)
        #expect(NotebookSourceTally.count(chapters + others) { $0 } == 13)
        // Two books count twice; a blank group is not a book.
        #expect(NotebookSourceTally.count(["A", "A", "B", " ", nil]) { $0 } == 4)
        #expect(NotebookSourceTally.count([String?]()) { $0 } == 0)
    }

    @Test("The List names a notebook's first source and how many more; a book is one entry at its first chapter's place")
    func sourceEntries() {
        // (id, book) in the notebook's order.
        let sources: [(id: String, book: String?)] = [
            ("ch2", "How Life Works"), ("paper", nil), ("ch1", "How Life Works"), ("blank", " "), ("ch9", "How Life Works"),
        ]
        let entries = NotebookSourceEntries.entries(sources) { $0.book }
        #expect(entries.map(\.source.id) == ["ch2", "paper", "blank"])
        #expect(entries.map(\.book) == ["How Life Works", nil, nil])
        #expect(entries.map(\.chapters) == [3, 1, 1])
        // The entries are what the count counts.
        #expect(entries.count == NotebookSourceTally.count(sources) { $0.book })
    }

    @Test("A card says how many sources and when it was updated")
    func cardLine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12)))
        func line(_ count: Int, _ date: Date) -> String {
            NotebookCardLine.text(sourceCount: count, updatedAt: date, now: now, calendar: calendar, locale: locale)
        }
        #expect(line(1, now) == "1 source · updated today")
        #expect(line(12, now.addingTimeInterval(-86_400)) == "12 sources · updated yesterday")
        let september = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 9)))
        #expect(line(0, september) == "0 sources · updated Sep 3")
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 3, hour: 9)))
        #expect(line(2, lastYear) == "2 sources · updated Mar 3, 2025")
    }

    @Test("The bulk bar's read toggle reads as the row menu's: Mark Read while any is unread")
    func readToggle() {
        #expect(LibraryBulkAction.readToggle(readStates: [true, false]) == .markRead)
        #expect(LibraryBulkAction.readToggle(readStates: [false]) == .markRead)
        #expect(LibraryBulkAction.readToggle(readStates: [true, true]) == .markUnread)
        #expect(LibraryBulkAction.readToggle(readStates: []) == nil)
    }

    @Test("The View menu says Space on ⌘P and Library on ⇧⌘L")
    func shellCommands() {
        #expect(ShellAction.space.title == "Space")
        #expect(ShellAction.space.keys == [ShellKey("p", .command)])
        #expect(ShellAction.library.title == "Library")
        #expect(ShellAction.library.keys == [ShellKey("l", [.command, .shift])])
        #expect(ShellAction.library.key != ShellKey("l", [.command, .option]), "⌥⌘L is Codex's Copy Chat Link")
        // One name for each place, wherever it is offered: the Space's tab
        // and its Open in Other Window say Space as the menu does.
        #expect(StudioCenterTab.artifacts.title == ShellAction.space.title)
        #expect(StudioWindowDestination.artifacts.noun == ShellAction.space.title)
        #expect(StudioRailItem.library.title == ShellAction.library.title)
        #expect(StudioCenterTab.library.title == ShellAction.library.title)
        #expect(StudioWindowDestination.library.noun == ShellAction.library.title)
        #expect(StudioCenterTab.permanentTabs.last == .plugins, "the newest place is appended, so stored layouts keep their order")
    }

    @Test("A first launch leads with the Space, everything else behind it in one pane")
    func defaultLayoutLeadsWithTheSpace() {
        // Every assignment reconciles the layout (`StudioWindowState
        // .centerTabGroups`), which adds the permanent tabs the default leaves
        // out to its one pane: that reconciled shape is what a first launch shows.
        let layout = StudioCenterTabGroups.reconciled(StudioCenterTabGroups.defaultLayout)
        #expect(layout.groups.count == 1)
        #expect(layout.groups[0].activeTab == .artifacts)
        #expect(layout.groups[0].tabs.first == .artifacts)
        #expect(Set(layout.groups[0].tabs) == Set(StudioCenterTab.permanentTabs))
    }

    @Test("A layout saved with the retired Notebooks home tab shows the Space, however it was stored")
    func retiredHomeTabShowsTheSpace() throws {
        // The Notebooks home (`notebooks`, `projects` before schema 164) went
        // on 2026-10-09; a saved or synced layout still naming it must decode
        // to the Space, never crash and never lose another tab.
        let stored = [
            "notebooks*|chat|reader|tasks|activity|goals|courses|ideas|notepad|sites|browser|videos|animations|artifacts|memory|knowledgeMap|atlas|library",
        ]
        let layout = try #require(StudioCenterTabGroups.fromPersisted(stored))
        let tabs = layout.groups.flatMap(\.tabs)
        #expect(tabs.filter { $0 == .artifacts }.count == 1, "the Space appears exactly once")
        #expect(layout.groups[0].activeTab == .artifacts, "the pane that showed the retired home shows the Space")
        #expect(layout.groups[0].tabs.first == .artifacts)
        #expect(Set(tabs) == Set(StudioCenterTab.permanentTabs), "no other tab is lost")
        // A retired pane pin beside it is ignored; the pane shows the Space.
        let pinned = try #require(StudioCenterTabGroups.fromPersisted(["!|notebooks*|chat", "reader*|tasks"]))
        #expect(pinned.groups[0].activeTab == .artifacts)
        // What it writes back never names the retired tab.
        #expect(!layout.persistedRepresentation.joined(separator: "|").contains("notebooks"))
        // An unreadable layout still falls back to nothing, as before.
        #expect(StudioCenterTabGroups.fromPersisted([]) == nil)
        // The retired name is no `StudioCenterTab` any more.
        #expect(StudioCenterTab(rawValue: "notebooks") == nil)
    }
}

// MARK: - The List view's order, the layout and the filter (the iPhone's Home reads these rules)

@Suite("Notebook list order, layout and filter")
struct NotebooksHomeListTests {
    private let alpha = notebook("a", title: "Alpha", sources: 3, updatedAt: at(10))
    private let beta = notebook("b", title: "🧪 Beta", sources: 12, updatedAt: at(30))
    private let gamma = notebook("c", title: "Gamma", sources: 0, updatedAt: at(20))
    private let delta = notebook("d", title: "Delta", sources: 3, updatedAt: at(5))
    private var all: [LearningGoalRecord] { [alpha, beta, gamma, delta] }
    /// Beta in two collections, Delta in one, Alpha and Gamma in none.
    private let held = collections(["nbc-aging": ["b", "d"], "nbc-nexus": ["b"]])

    private func ids(_ sort: NotebooksHomeSort, reversed: Bool = false, recency: NotebookRecency = NotebookRecency()) -> [String] {
        sort.ordered(all, recency: recency, collections: held, reversed: reversed).map(\.id)
    }

    @Test("Each key sorts in its natural direction and turns round, ties always by title")
    func everyKeyAndDirection() {
        // Recent: last worked in first; this Mac's stamp outranks an older record.
        #expect(ids(.recent) == ["b", "c", "a", "d"])
        #expect(ids(.recent, reversed: true) == ["d", "a", "c", "b"])
        #expect(ids(.recent, recency: NotebookRecency(stamps: ["d": at(100)])) == ["d", "b", "c", "a"])
        // Name: A to Z, a leading emoji aside.
        #expect(ids(.name) == ["a", "b", "d", "c"])
        #expect(ids(.name, reversed: true) == ["c", "d", "b", "a"])
        // Sources: most first; Alpha and Delta tie at 3 and stay by title both ways.
        #expect(ids(.sources) == ["b", "a", "d", "c"])
        #expect(ids(.sources, reversed: true) == ["c", "a", "d", "b"])
        // Uncategorized first: none, then one, then two collections; last
        // worked in first within a group.
        #expect(ids(.uncategorized) == ["c", "a", "d", "b"])
        #expect(ids(.uncategorized, reversed: true) == ["b", "d", "c", "a"])
    }

    @Test("A header click turns the shown column round and starts another in its natural direction")
    func headerClicks() {
        let start = NotebooksHomeOrder()
        #expect(start.sort == .recent && !start.isReversed && !start.isAscending)
        let byName = start.clicking(.name)
        #expect(byName == NotebooksHomeOrder(sort: .name, isReversed: false))
        #expect(byName.isAscending, "A to Z points up")
        let reversedName = byName.clicking(.name)
        #expect(reversedName.isReversed && !reversedName.isAscending)
        #expect(reversedName.clicking(.sources) == NotebooksHomeOrder(sort: .sources, isReversed: false))
        // The sort menu always picks the natural direction.
        #expect(reversedName.choosing(.name) == NotebooksHomeOrder(sort: .name, isReversed: false))
        #expect(NotebooksHomeOrder(sort: .uncategorized).isAscending)
    }

    @Test("The order and Grid or List come back as stored, and a value this build cannot read is the default")
    func storedChoicesPersist() throws {
        let suite = "NotebooksHomeListTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The home writes the raw values through @AppStorage; a relaunch reads them back.
        defaults.set(NotebooksHomeLayout.list.rawValue, forKey: NotebooksHomeLayout.preferenceKey)
        defaults.set(NotebooksHomeSort.sources.rawValue, forKey: NotebooksHomeOrder.sortPreferenceKey)
        defaults.set(true, forKey: NotebooksHomeOrder.reversedPreferenceKey)
        #expect(NotebooksHomeLayout(stored: defaults.string(forKey: NotebooksHomeLayout.preferenceKey) ?? "") == .list)
        let order = NotebooksHomeOrder(
            storedSort: defaults.string(forKey: NotebooksHomeOrder.sortPreferenceKey) ?? "",
            storedReversed: defaults.bool(forKey: NotebooksHomeOrder.reversedPreferenceKey)
        )
        #expect(order == NotebooksHomeOrder(sort: .sources, isReversed: true))
        // A new learner, or a value from another build: Grid, Recent.
        #expect(NotebooksHomeLayout(stored: "") == .grid)
        #expect(NotebooksHomeLayout(stored: "columns") == .grid)
        #expect(NotebooksHomeOrder(storedSort: "popularity", storedReversed: false) == NotebooksHomeOrder())
        // Device-local, declared with a reason.
        for key in [NotebooksHomeLayout.preferenceKey, NotebooksHomeOrder.sortPreferenceKey, NotebooksHomeOrder.reversedPreferenceKey] {
            #expect(!SyncedPreferenceKeys.isSynced(key))
        }
    }

    @Test("The filter shows all, the uncategorized, or one collection's notebooks, and a deleted collection reads as All")
    func collectionFilter() {
        #expect(NotebooksHomeFilter.all.apply(all, collections: held).map(\.id) == ["a", "b", "c", "d"])
        #expect(NotebooksHomeFilter.uncategorized.apply(all, collections: held).map(\.id) == ["a", "c"])
        #expect(NotebooksHomeFilter.collection("nbc-aging").apply(all, collections: held).map(\.id) == ["b", "d"])
        #expect(NotebooksHomeFilter.collection("nbc-gone").resolved(in: held) == .all)
        #expect(NotebooksHomeFilter.collection("nbc-gone").apply(all, collections: held).count == 4)
        // One string per window: empty, the word, or a collection's id.
        for filter in [NotebooksHomeFilter.all, .uncategorized, .collection("nbc-aging")] {
            #expect(NotebooksHomeFilter(storage: filter.storage) == filter)
        }
        #expect(NotebooksHomeFilter(storage: "").storage == "")
    }

    @Test("A new notebook joins the collection shown, and none under All, Uncategorized or a deleted collection")
    func newNotebookCollection() {
        // The iPhone's Notebooks screen files its + by the filter it shows.
        #expect(NotebooksHomeFilter.collection("nbc-aging").resolved(in: held).collectionID == "nbc-aging")
        #expect(NotebooksHomeFilter.collection("nbc-gone").resolved(in: held).collectionID == nil)
        #expect(NotebooksHomeFilter.all.collectionID == nil)
        #expect(NotebooksHomeFilter.uncategorized.collectionID == nil)
    }

    @Test("The iPhone's Status and the Collections columns say little")
    func statusAndCollectionsColumns() {
        #expect(NotebookListStatus.text(isArchived: false, isShared: false, sourceCount: 4) == "")
        #expect(NotebookListStatus.text(isArchived: false, isShared: true, sourceCount: 4) == "Shared")
        #expect(NotebookListStatus.text(isArchived: true, isShared: true, sourceCount: 0) == "Archived · Shared · Empty")
        let two = held.collections(ofNotebook: "b")
        #expect(NotebookListCollections.chips(two) == ["aging", "nexus"])
        #expect(NotebookListCollections.countText(two) == nil)
        let three = two + [NotebookCollection(id: "nbc-x", name: "x")]
        #expect(NotebookListCollections.chips(three).isEmpty)
        #expect(NotebookListCollections.countText(three) == "3 collections")
    }
}

// MARK: - The rail's notebooks

@Suite("Notebook rail")
struct NotebookRailTests {
    /// A library of many notebooks, n0 the most recently updated.
    private func library(_ count: Int) -> [LearningGoalRecord] {
        (0..<count).map { index in
            notebook("n\(index)", title: "Notebook \(index)", updatedAt: at(Double(1000 - index)))
        }
    }

    @Test("A large library: pinned in the learner's order, the last few worked in, the uncategorized counted, every collection")
    func sectionsOfALargeLibrary() {
        let notebooks = library(52)
        let held = collections(["nbc-nexus": ["n3", "n40", "n41"], "nbc-aging": ["n40"]])
        // This Mac worked in n50 last of all.
        let recency = NotebookRecency(stamps: ["n50": at(5000)])
        let rail = NotebookRail(
            notebooks: notebooks,
            pinned: ["n7", "n2", "gone"],
            recency: recency,
            collections: held,
            openNotebookID: nil
        )
        #expect(rail.pinnedIDs == ["n2", "n7"], "in the learner's own order; an id the library lacks is no row")
        #expect(NotebookRail.recentLimit == 6)
        #expect(rail.recentIDs == ["n50", "n0", "n1", "n3", "n4", "n5"], "pinned ones are not repeated")
        #expect(rail.openNotebookID == nil)
        #expect(rail.uncategorizedCount == 49)
        #expect(rail.collections.map(\.collection.name) == ["aging", "nexus"])
        #expect(rail.collections.map(\.count) == [1, 3])
        #expect(rail.notebookIDs.count == 8, "the rail lists 8 notebooks, not 52")
    }

    @Test("The window's notebook keeps a row when it is neither pinned nor recent, and only then")
    func openNotebookKeepsItsRow() {
        let notebooks = library(20)
        let rail = NotebookRail(
            notebooks: notebooks, pinned: ["n1"], recency: NotebookRecency(),
            collections: NotebookCollections(), openNotebookID: "n15"
        )
        #expect(rail.openNotebookID == "n15")
        #expect(rail.notebookIDs.last == "n15")
        for open in ["n1", "n0"] {
            let covered = NotebookRail(
                notebooks: notebooks, pinned: ["n1"], recency: NotebookRecency(),
                collections: NotebookCollections(), openNotebookID: open
            )
            #expect(covered.openNotebookID == nil, "\(open) already has a row")
        }
        // An archived notebook the window holds is not in the active list, and still gets its row.
        let archived = NotebookRail(
            notebooks: notebooks, pinned: [], recency: NotebookRecency(),
            collections: NotebookCollections(), openNotebookID: "archived-one"
        )
        #expect(archived.openNotebookID == "archived-one")
    }

    @Test("A small library lists every notebook once; Screen record mode names only the collections it may show")
    func smallLibraryAndScreenRecording() {
        let notebooks = library(3)
        let held = collections(["nbc-nexus": ["n0"], "nbc-private": []])
        let rail = NotebookRail(
            notebooks: notebooks, pinned: ["n2"], recency: NotebookRecency(),
            collections: held, openNotebookID: nil, shownCollectionIDs: ["nbc-nexus"]
        )
        #expect(rail.pinnedIDs == ["n2"])
        #expect(rail.recentIDs == ["n0", "n1"])
        #expect(rail.collections.map(\.id) == ["nbc-nexus"])
        #expect(rail.uncategorizedCount == 2)
    }

    @Test("Pins are an explicit list: a new pin goes last, an unpin or a forgotten notebook leaves it")
    func pinsList() {
        let known: Set<String> = ["a", "b", "c"]
        #expect(NotebookPins.setting("c", pinned: true, in: ["a", "b"], knownIDs: known) == ["a", "b", "c"])
        #expect(NotebookPins.setting("a", pinned: false, in: ["a", "b"], knownIDs: known) == ["b"])
        #expect(NotebookPins.setting("b", pinned: true, in: ["gone", "b", "a", "a"], knownIDs: known) == ["a", "b"])
    }
}

@Suite("The Space and Library routing")
@MainActor
struct NotebooksHomeRoutingTests {
    private func makeViewModel() -> StudioViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebooksHomeRoutingTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StudioViewModel(storageService: StorageService(storeRoot: root))
    }

    private static let templateKeys = [
        "studio.centerTabGroups.v1",
        "studio.navigationRailVisible",
    ]

    /// The layout template every new window starts from, MCP's active
    /// Notebook and this Mac's notebook stamps: the unit host's defaults are
    /// the real ones, so each test puts them back.
    private func capturingSharedDefaults() -> () -> Void {
        let keys = Self.templateKeys + [NotebookRecency.preferenceKey, NotebookPins.preferenceKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let activeNotebookID = ActiveNotebookPreference.notebookID
        return {
            for (key, value) in zip(keys, saved) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            ActiveNotebookPreference.notebookID = activeNotebookID
        }
    }

    private func templateValues() -> [String] {
        Self.templateKeys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }
    }

    /// The notebooks as the library the test host has open holds them, so
    /// `notebooks` lists them whichever library that is.
    private func inLibrary(_ vm: StudioViewModel, _ records: [LearningGoalRecord]) -> [LearningGoalRecord] {
        records.map { record in
            var record = record
            record.teamID = vm.activeTeamID
            return record
        }
    }

    /// Chat beside the reading surfaces: a window whose template does not
    /// already show the Space.
    private static let chatBesideReader = StudioCenterTabGroups(groups: [
        .init(tabs: [.chat], activeTab: .chat),
        .init(tabs: [.reader, .tasks, .notepad, .sites, .browser, .artifacts], activeTab: .reader),
    ])

    private func window(_ layout: StudioCenterTabGroups? = nil) -> StudioWindowState {
        let window = StudioWindowState()
        window.centerTabGroups = layout ?? Self.chatBesideReader
        return window
    }

    @Test("A brand-new window opens on the Space, however recently a notebook was worked in")
    func newWindowOpensTheSpace() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        vm.learningGoals = inLibrary(vm, [notebook("bio"), notebook("neuro")])
        vm.hasLoadedLearningGoalsOnce = true
        vm.noteNotebookWork("bio", at: at(10))
        vm.noteNotebookWork("neuro", at: at(20))

        let first = window()
        let template = templateValues()
        vm.showSpaceInNewWindow(first)
        #expect(first.notebook == nil)
        #expect(vm.visibleCenterTabs(in: first).contains(.artifacts))
        #expect(first.spaceDestinationKey == SpaceDestination.all.key, "its All list, where every notebook is")
        #expect(templateValues() == template, "the window's own snapshot, never the layout template")

        // A window already holding a notebook (a link named one) keeps it.
        let named = window()
        named.NotebookID = "bio"
        vm.showSpaceInNewWindow(named)
        #expect(named.NotebookID == "bio")
    }

    @Test("A window restored holding a notebook the library turns out not to hold gives way to the Space")
    func restoredWindowWaitsForTheLibrary() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        vm.hasLoadedLearningGoalsOnce = false
        let restored = window()
        restored.NotebookID = "gone"
        StudioWindowRegistry.shared.register(restored)
        defer { StudioWindowRegistry.shared.unregister(restored) }

        vm.learningGoals = inLibrary(vm, [notebook("bio")])
        vm.hasLoadedLearningGoalsOnce = true
        vm.closeNotebooksMissingFromLibrary()
        #expect(restored.notebook == nil)
        #expect(vm.visibleCenterTabs(in: restored).contains(.artifacts), "the Space, never a spinner")
    }

    @Test("Opening a notebook stamps it, an archived one opened to be read does not, and a test's view model writes no defaults")
    func openingStampsTheNotebook() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let stored = UserDefaults.standard.object(forKey: NotebookRecency.preferenceKey).map { String(describing: $0) }
        let vm = makeViewModel()
        vm.learningGoals = inLibrary(vm, [notebook("bio"), notebook("shelved", archived: true)])
        let target = window()

        vm.openNotebook("shelved", in: target, startsNotebookChat: false)
        #expect(vm.notebookRecency.stamp("shelved") == nil)
        vm.openNotebook("bio", in: target, startsNotebookChat: false)
        #expect(vm.notebookRecency.mostRecent == "bio")
        #expect(UserDefaults.standard.object(forKey: NotebookRecency.preferenceKey).map { String(describing: $0) } == stored)
    }

    @Test("Close Notebook and the notebook's ‹ land on the Space's All list; its row there brings it back as it was")
    func closingLandsOnTheSpace() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        vm.learningGoals = inLibrary(vm, [notebook("bio")])
        let target = window()
        vm.openNotebook("bio", in: target, startsNotebookChat: false)
        target.notebook?.studioCollapsed = true
        target.notebook?.sourcesCollapsed = true
        target.notebook?.sourcesExpanded = true

        // A window that was looking at Trash lands on All, where the notebook
        // is. Close Notebook and ‹ both leave this way: in the notebook's
        // tabs the Space is one more tab and leaves nothing.
        target.spaceDestinationKey = SpaceDestination.trash.key
        vm.leaveNotebookForSpace(in: target)
        #expect(target.notebook == nil)
        #expect(vm.visibleCenterTabs(in: target).contains(.artifacts))
        #expect(target.spaceDestinationKey == SpaceDestination.all.key)

        vm.inWindow(target) { vm.openNotebookInReader("bio") }
        #expect(target.notebook?.studioCollapsed == true)
        #expect(target.notebook?.sourcesCollapsed == true)
        #expect(target.notebook?.sourcesExpanded == false, "its arrangement, not its moments")
    }

    @Test("A notebook archived or deleted under a window lands it on the Space, recorded in that window alone")
    func goneNotebookLandsOnTheSpace() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let holding = window()
        let other = window()
        StudioWindowRegistry.shared.register(holding)
        StudioWindowRegistry.shared.register(other)
        defer {
            StudioWindowRegistry.shared.unregister(holding)
            StudioWindowRegistry.shared.unregister(other)
        }
        holding.NotebookID = "bio"
        other.NotebookID = "neuro"
        let template = templateValues()
        let revision = holding.persistenceRevision

        vm.closeNotebookInEveryWindow("bio")
        #expect(holding.notebook == nil)
        #expect(vm.visibleCenterTabs(in: holding).contains(.artifacts))
        #expect(holding.persistenceRevision > revision, "the window's scene snapshot records it")
        #expect(templateValues() == template)
        #expect(other.NotebookID == "neuro")
    }

    @Test("The Space is what a lone pane closes onto")
    func lonePaneClosesOntoTheSpace() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let target = window(StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs, activeTab: .notepad),
        ]))
        vm.deactivateCenterTab(.notepad, in: target)
        #expect(target.centerTabGroups.groups[0].activeTab == .artifacts)
        vm.deactivateCenterTab(.artifacts, in: target)
        #expect(target.centerTabGroups.groups[0].activeTab == .chat, "the Space cannot close onto itself")
    }

    @Test("The Library and the Space open as tabs of a notebook's panes, and the notebook stays")
    func libraryOpensInTheNotebooksTabs() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        vm.learningGoals = inLibrary(vm, [notebook("bio")])
        let target = window(.defaultLayout)
        vm.openNotebook("bio", in: target, startsNotebookChat: false)
        target.notebook?.sourcesCollapsed = true
        target.notebook?.studioCollapsed = true

        vm.openLibraryView(in: target)
        #expect(target.NotebookID == "bio")
        #expect(target.centerTabGroups.groups.contains { $0.activeTab == .library })
        vm.showSpaceAll(in: target)
        #expect(target.NotebookID == "bio")
        #expect(target.centerTabGroups.groups.contains { $0.activeTab == .artifacts })

        // Left and opened again, it comes back as the window left it.
        vm.leaveNotebookForSpace(in: target)
        #expect(target.notebook == nil)
        vm.openNotebook("bio", in: target)
        #expect(target.NotebookID == "bio")
        #expect(target.notebook?.sourcesCollapsed == true)
        #expect(target.notebook?.studioCollapsed == true)
    }

    @Test("A source clicked in the Library opens in the Reader beside it, and the Library stays")
    func libraryKeepsItsListBesideTheReader() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let target = window(StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs, activeTab: .library),
        ]))
        vm.clearReaderSurfaces(in: target)
        #expect(target.centerTabGroups.groups.map(\.activeTab) == [.library, .reader])
    }

    @Test("A source opened over the Library goes back to the Library, after any source read since")
    func readerBackUncoversTheLibrary() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        // The Space on the left, the Library on the right and last clicked in:
        // the Reader, parked behind the Space, opens in the Library's pane.
        let target = window(StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs.filter { $0 != .library }, activeTab: .artifacts),
            .init(tabs: [.library], activeTab: .library),
        ]))
        target.focusedGroupID = target.centerTabGroups.groups[1].id
        target.readerArticleID = "earlier"
        target.readerArticleID = "episode"
        vm.activateCenterTab(.reader, in: target)
        #expect(target.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .reader])
        #expect(target.readerCover?.tab == .library)
        #expect(target.readerBackReturnsToCover, "what was read before the Library is not the way back")
        #expect(target.centerTabGroups.groups[1].openTabs == [.library, .reader])

        target.readerArticleID = "paper"
        #expect(!target.readerBackReturnsToCover, "a source read since is the page before")
        #expect(target.navigateReaderBack { _ in true } == "episode")
        #expect(target.readerBackReturnsToCover)

        #expect(target.returnFromReaderCover())
        #expect(target.centerTabGroups.groups.map(\.activeTab) == [.artifacts, .library])
        #expect(target.readerCover == nil)
    }

    @Test("A Reader that opened in a pane of its own covered nothing")
    func readerInItsOwnPaneCoversNothing() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let target = window(StudioCenterTabGroups(groups: [
            .init(tabs: StudioCenterTab.permanentTabs, activeTab: .library),
        ]))
        vm.clearReaderSurfaces(in: target)
        #expect(target.centerTabGroups.groups.map(\.activeTab) == [.library, .reader])
        #expect(target.readerCover == nil)
        #expect(!target.readerBackReturnsToCover)
    }

    @Test("A Library row's chips are the open library's notebooks holding it, by title")
    func libraryChips() {
        let vm = makeViewModel()
        let otherTeam = "another-team-\(UUID().uuidString)"
        // The index as the view model keeps it: the open library's notebooks
        // and another library's, by team.
        vm.notebookMemberSourceIDsByNotebook = [
            "bio": ["src-1"],
            "aging": ["src-1", "src-2"],
            "theirs": ["src-1"],
        ]
        vm.notebookTitlesByNotebook = ["bio": "Bioelectricity", "aging": "🧓 Aging", "theirs": "Team notebook"]
        var teams = ["theirs": otherTeam]
        if let library = vm.activeTeamID {
            teams["bio"] = library
            teams["aging"] = library
        }
        vm.notebookTeamIDsByNotebook = teams
        #expect(vm.notebooksHolding("src-1").map(\.notebookID) == ["aging", "bio"], "by title, a leading emoji aside")
        #expect(vm.notebooksHolding("src-2").map(\.notebookID) == ["aging"])
        #expect(vm.notebooksHolding("src-3").isEmpty)
    }

    @Test("The Library's bulk bar goes through the row menus' store APIs")
    func bulkActions() async throws {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let papers = (1...3).map { index in
            StudioArticle(
                url: "https://doi.org/10.1000/bulk-\(index)",
                title: "Paper \(index)",
                sourceType: .paper
            )
        }
        for paper in papers {
            try await vm.storage.saveSource(paper)
        }
        vm.articles = papers
        let target = try #require(await vm.createNotebookContext(title: "Bioenergetics"))
        let rows = Set(papers.prefix(2).map(\.id))

        await vm.performLibraryBulkAction(.addToNotebook(target.id), on: rows, inBooksTab: false)
        #expect(Set(vm.notebook(id: target.id)?.approvedSourceIDs ?? []) == rows)
        #expect(vm.notebookRecency.mostRecent == target.id, "adding a source is working in the notebook")

        #expect(LibraryBulkAction.readToggle(readStates: vm.libraryBulkReadStates(for: rows, inBooksTab: false)) == .markRead)
        await vm.performLibraryBulkAction(.markRead, on: rows, inBooksTab: false)
        #expect(papers.prefix(2).allSatisfy { vm.articlesById[$0.id]?.isRead == true })
        #expect(vm.articlesById[papers[2].id]?.isRead == false, "only the selection")
        #expect(LibraryBulkAction.readToggle(readStates: vm.libraryBulkReadStates(for: rows, inBooksTab: false)) == .markUnread)
        await vm.performLibraryBulkAction(.markUnread, on: rows, inBooksTab: false)
        #expect(papers.prefix(2).allSatisfy { vm.articlesById[$0.id]?.isRead == false })
        // A book row stands for its book: no single read state to toggle.
        #expect(vm.libraryBulkReadStates(for: rows, inBooksTab: true).isEmpty)

        await vm.performLibraryBulkAction(.hide, on: rows, inBooksTab: false)
        #expect(papers.prefix(2).allSatisfy { vm.articlesById[$0.id]?.isHidden == true })
        #expect(vm.articlesById[papers[2].id]?.isHidden == false)
        let stored = try await vm.storage.loadSources()
        let storedHidden = stored.filter { rows.contains($0.id) }.allSatisfy { $0.isHidden }
        #expect(storedHidden, "written to the store, as the row menu's Hide writes it")
    }

    // MARK: A chat's notebook

    @Test("A chat's notebook picker files it in another notebook or in none, and the window goes where the chat now lives")
    func refilingAChatTakesTheWindow() async {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        vm.learningGoals = inLibrary(vm, [notebook("bio"), notebook("neuro")])
        vm.reviewSessionLinks = [
            ReviewSessionRecord(id: "chat", title: "Complex I", createdAt: at(0), status: "completed", sourceIDs: [], goalID: "bio"),
        ]
        let window = StudioWindowState()
        window.NotebookID = "bio"

        await vm.refileChat("chat", inNotebook: "neuro", in: window)
        #expect(vm.reviewSessionLinks.first?.goalID == "neuro")
        #expect(window.NotebookID == "neuro", "the chat opens in its new notebook")

        // The product owner, 2026-10-03: one-off chats "unassigned to a notebook".
        await vm.refileChat("chat", inNotebook: nil, in: window)
        #expect(vm.reviewSessionLinks.first?.goalID == nil)
        #expect(window.NotebookID == nil, "a library chat leaves the notebook")
    }

    @Test("A notebook made from a chat holds what the chat held, each once and only what the library has, and opens with the chat filed in it")
    func notebookFromAChat() async throws {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let papers = (1...3).map { index in
            StudioArticle(
                url: "https://doi.org/10.1000/chat-\(index)",
                title: "Paper \(index)",
                sourceType: .paper
            )
        }
        for paper in papers {
            try await vm.storage.saveSource(paper)
        }
        vm.articles = papers
        vm.reviewSessionLinks = [
            ReviewSessionRecord(
                id: "explore",
                title: "Exploring cristae",
                createdAt: at(0),
                status: "completed",
                sourceIDs: [papers[1].id, "deleted-source"]
            ),
        ]

        let held = await vm.notebookSourceIDs(fromChat: "explore", openChatSourceIDs: [papers[0].id, papers[1].id])
        #expect(held == [papers[0].id, papers[1].id],
                "the open chat's first, then its record's, each once; a source the library no longer has is left out")

        // Made at once, with no form, and named by ForeverLM from the chat
        // (`NotebookNaming`): its row goes to a suite of this test's own.
        let suiteName = "NotebooksHomeTests.fromChat.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        vm.notebookNamerOverride = { _, _ in NotebookNaming.Answer(title: "Cristae remodelling", summary: nil) }
        try await NotebookNamingRows.$overrideDefaults.withValue(NotebookNamingRows.DefaultsOverride(defaults: defaults)) {
            let window = StudioWindowState()
            let created = try #require(await vm.createNotebook(
                fromChat: "explore",
                openChatSourceIDs: [papers[0].id],
                in: window
            ))
            #expect(created.title == "New notebook")
            #expect(Set(vm.notebook(id: created.id)?.approvedSourceIDs ?? []) == [papers[0].id, papers[1].id])
            #expect(vm.reviewSessionLinks.first?.goalID == created.id, "the chat is filed in it")
            #expect(window.NotebookID == created.id, "the window opens it, as opening the chat would")
            for _ in 0..<400 where vm.notebook(id: created.id)?.title == "New notebook" {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(vm.notebook(id: created.id)?.title == "Cristae remodelling", "named from what it holds")
        }
    }

    @Test("The rail lists the window's notebook, or the one it left, while it has no other row")
    func railKeepsTheWindowsNotebook() {
        let restore = capturingSharedDefaults()
        defer { restore() }
        let vm = makeViewModel()
        let many = (0..<12).map { notebook("n\($0)", updatedAt: at(Double(100 - $0))) }
        vm.learningGoals = inLibrary(vm, many)
        vm.hasLoadedLearningGoalsOnce = true
        vm.pinnedNotebookIDs = ["n11"]
        let notebookWindow = window()
        #expect(vm.notebookRail(in: notebookWindow).openNotebookID == nil)
        #expect(vm.notebookRail(in: notebookWindow).pinnedIDs == ["n11"])

        vm.openNotebook("n9", in: notebookWindow)
        // Opening it stamped it, so it is Recent now, not an extra row.
        #expect(vm.notebookRail(in: notebookWindow).recentIDs.first == "n9")
        #expect(vm.notebookRail(in: notebookWindow).openNotebookID == nil)

        // Six others worked in since, on this Mac: n9 is out of Recent, and
        // the window that holds it keeps its row.
        for (offset, id) in ["n0", "n1", "n2", "n3", "n4", "n5"].enumerated() {
            vm.noteNotebookWork(id, at: Date().addingTimeInterval(Double(offset + 1)))
        }
        #expect(!vm.notebookRail(in: notebookWindow).recentIDs.contains("n9"))
        #expect(vm.notebookRail(in: notebookWindow).openNotebookID == "n9")
        #expect(vm.notebookRail(in: StudioWindowState()).openNotebookID == nil, "another window does not list it")
    }

    @Test("A notebook-from-chat request carries the chat's title, never its placeholder")
    func notebookFromChatOffersTheTitle() {
        #expect(NotebookFromChatRequest(sessionID: "a", title: "  Markov blankets ").title == "Markov blankets")
        #expect(NotebookFromChatRequest(sessionID: "b", title: "New chat").title == "")
        #expect(NotebookFromChatRequest(sessionID: "c", title: "Untitled chat").title == "")
        #expect(NotebookFromChatRequest(sessionID: "d", title: "").id == "d")
    }
}

@Suite("A destination dropped on a pane")
struct ReplacingPaneTests {
    /// Memory beside the Reader, the way a source opened in the Reader
    /// leaves the window; Chat and the Space parked behind them.
    private static let memoryBesideReader = StudioCenterTabGroups(groups: [
        .init(tabs: [.memory, .chat], activeTab: .memory),
        .init(tabs: [.reader, .artifacts], activeTab: .reader),
    ])

    @Test("The pane under the drop takes the tab, what it showed kept as a tab")
    func paneUnderTheDropTakesTheTab() throws {
        let layout = try #require(Self.memoryBesideReader.replacingPane(at: 1, with: .artifacts))
        #expect(layout.groups[1].activeTab == .artifacts)
        #expect(layout.groups[1].openTabs == [.reader, .artifacts], "what it showed stays a tab")
        #expect(layout.groups[0] == Self.memoryBesideReader.groups[0], "the other pane is untouched")
    }

    @Test("A tab parked in the other pane moves across and leaves that pane on the Reader or its next tab")
    func tabLeavesItsPane() throws {
        let layout = try #require(Self.memoryBesideReader.replacingPane(at: 1, with: .chat))
        #expect(layout.groups[1].activeTab == .chat)
        #expect(layout.groups[0].tabs == [.memory])
        #expect(layout.groups[0].activeTab == .memory)
    }

    @Test("A tab shown alone in another pane trades places with the pane it lands on")
    func aloneTabSwaps() throws {
        let layout = StudioCenterTabGroups(groups: [
            .init(tabs: [.memory], activeTab: .memory),
            .init(tabs: [.reader, .chat], activeTab: .reader),
        ])
        let swapped = try #require(layout.replacingPane(at: 1, with: .memory))
        #expect(swapped.groups.map(\.activeTab) == [.reader, .memory])
    }

    @Test("A tab already on top of the pane changes nothing; one parked in it comes forward")
    func samePane() throws {
        let unchanged = try #require(Self.memoryBesideReader.replacingPane(at: 0, with: .memory))
        #expect(unchanged == Self.memoryBesideReader)
        let forward = try #require(Self.memoryBesideReader.replacingPane(at: 0, with: .chat))
        #expect(forward.groups[0].activeTab == .chat)
        #expect(forward.groups[0].tabs == [.memory, .chat])
    }

    @Test("No pane at the slot, or no pane holding the tab, is no change")
    func nothingToShow() {
        #expect(Self.memoryBesideReader.replacingPane(at: 2, with: .chat) == nil)
        #expect(Self.memoryBesideReader.replacingPane(at: -1, with: .chat) == nil)
        #expect(Self.memoryBesideReader.replacingPane(at: 0, with: .secondaryChat) == nil)
    }

    @Test("A replaced pane keeps its identity, so its views are not rebuilt")
    func keepsIdentity() throws {
        let before = Self.memoryBesideReader.groups.map(\.id)
        let layout = try #require(Self.memoryBesideReader.replacingPane(at: 1, with: .chat))
        #expect(layout.groups.map(\.id) == before)
    }
}
