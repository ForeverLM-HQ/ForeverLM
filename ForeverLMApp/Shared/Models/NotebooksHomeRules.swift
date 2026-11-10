import Foundation

// MARK: - The Notebooks home's rules, shared
//
// What the Mac's rail and Notebooks home decide about notebooks — the order
// they were last worked in, the home's sorts, filter and Grid | List, the
// List's Status and Collections columns, the rail's Pinned, Recent,
// Uncategorized and Collections — kept Foundation-only so the iPhone's Home
// and Notebooks screen compile these same rules (docs/notebooks-design.md,
// "A compact rail" and "iPhone"; docs/web-macos-parity.md). The web's twin
// follows them. The Mac's records (`LearningGoalRecord`) and the phone's
// (`MobileCloudNotebook`) each answer `NotebookHomeListing`.

/// What the home's rules read of a notebook.
protocol NotebookHomeListing {
    var id: String { get }
    var title: String { get }
    /// The record's own last change.
    var updatedAt: Date { get }
    /// How many approved sources its record names (the Mac's
    /// `approvedSourceIDs`, archived and hidden ones included): the List's
    /// Sources column and its sort.
    var homeSourceCount: Int { get }
}

// MARK: - The notebook last worked in

/// When this Mac last worked in each notebook: opened it in a window, sent a
/// message in a chat of it, or added a source to it. The latest of the three
/// is the notebook's stamp; the rail's Recent order and the Space's
/// notebook dates read them (`NotebooksHomeSort`). The iPhone keeps its own
/// under the same key, a notebook opened there, which Home reads with the end of each
/// notebook's latest chat (`MobileNotebookRailRules.recency`).
///
/// Device-local and never synced (`preferenceKey` is declared in
/// `SyncedPreferenceKeys.excluded`): which notebook a window here opens in is
/// this Mac's arrangement, as its windows are, and opening a notebook writes
/// nothing that travels. A notebook's id stays after the notebook is deleted,
/// so a window that would have opened it shows the home instead of the
/// notebook worked in before it; the oldest ids go once `capacity` is passed.
struct NotebookRecency: Equatable, Sendable {
    static let preferenceKey = "studio.notebookLastWorked.v1"
    /// How many notebooks are remembered; the oldest go first.
    static let capacity = 200

    private(set) var stamps: [String: Date]

    init(stamps: [String: Date] = [:]) {
        self.stamps = stamps
    }

    /// The notebook worked in most recently on this Mac, whether or not the
    /// open library still holds it. Two stamps on one clock tick go to the
    /// larger id, so the answer never depends on dictionary order.
    var mostRecent: String? {
        stamps.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key
    }

    /// This Mac's stamp for the notebook, if it has one.
    func stamp(_ notebookID: String) -> Date? {
        stamps[notebookID]
    }

    /// When the notebook was last worked in for the home's Recent order:
    /// this Mac's stamp, or the record's own last change if that is later —
    /// a source added on the other Mac, a notebook never opened here.
    func lastWorkedAt(_ notebookID: String, updatedAt: Date) -> Date {
        max(stamps[notebookID] ?? .distantPast, updatedAt)
    }

    /// Notes work in `notebookID` at `date`, the latest event winning, and
    /// forgets the oldest notebooks past `capacity`.
    mutating func note(_ notebookID: String, at date: Date) {
        guard !notebookID.isEmpty else { return }
        stamps[notebookID] = date
        let excess = stamps.count - Self.capacity
        guard excess > 0 else { return }
        let oldest = stamps
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value }
            .prefix(excess)
            .map(\.key)
        for id in oldest { stamps[id] = nil }
    }

    /// A notebook merged into another: the survivor carries the later of the
    /// two stamps, so a window that would have opened the merged one opens
    /// the notebook it lives on in.
    mutating func merge(_ notebookID: String, into survivorID: String) {
        guard notebookID != survivorID, let merged = stamps.removeValue(forKey: notebookID) else { return }
        stamps[survivorID] = max(stamps[survivorID] ?? .distantPast, merged)
    }

    // MARK: Persistence

    /// The stamps a `save(to:)` left in `defaults`; none for nil (the view
    /// model of a test), an absent key, or a value another build wrote in a
    /// shape this one does not read.
    static func load(from defaults: UserDefaults?) -> NotebookRecency {
        guard let raw = defaults?.dictionary(forKey: preferenceKey) else { return NotebookRecency() }
        var stamps: [String: Date] = [:]
        for (notebookID, value) in raw where !notebookID.isEmpty {
            guard let seconds = (value as? NSNumber)?.doubleValue, seconds.isFinite else { continue }
            stamps[notebookID] = Date(timeIntervalSince1970: seconds)
        }
        return NotebookRecency(stamps: stamps)
    }

    /// Writes the stamps to `defaults` (nothing for nil), as seconds since
    /// 1970 by Notebook id: a plain property list a defaults read can show.
    func save(to defaults: UserDefaults?) {
        guard let defaults else { return }
        defaults.set(stamps.mapValues(\.timeIntervalSince1970), forKey: Self.preferenceKey)
    }
}
// MARK: - The Notebooks home

/// The home's orders: the sort menu's four, and the List view's sortable
/// columns (product owner, 2026-10-03: "maybe there should also be a list view for
/// these not just grid?"). Each has its natural direction — newest, A to Z,
/// most sources, uncategorized first — and the List's header turns it round
/// (`ordered(_:recency:collections:reversed:)`).
enum NotebooksHomeSort: String, CaseIterable, Identifiable, Sendable {
    /// Last worked in first (`NotebookRecency.lastWorkedAt(_:updatedAt:)`).
    case recent
    /// By title, a leading emoji aside.
    case name
    /// Most sources first.
    case sources
    /// Notebooks in no collection first, then by how few collections hold
    /// them; last worked in first within each.
    case uncategorized

    var id: String { rawValue }

    /// The sort menu's words.
    var title: String {
        switch self {
        case .recent: return "Recent"
        case .name: return "Name"
        case .sources: return "Sources"
        case .uncategorized: return "Uncategorized first"
        }
    }

    /// Whether the natural direction reads as ascending in the List's
    /// header: A to Z, and fewest collections first, go up; newest and most
    /// sources go down.
    var isNaturallyAscending: Bool {
        switch self {
        case .name, .uncategorized: return true
        case .recent, .sources: return false
        }
    }

    /// `notebooks` in this order, the natural direction turned round when
    /// `reversed`. Only the key turns: a tie always breaks by title, then id,
    /// so two notebooks never trade places between two reads.
    func ordered<Notebook: NotebookHomeListing>(
        _ notebooks: [Notebook],
        recency: NotebookRecency,
        collections: NotebookCollections = NotebookCollections(),
        reversed: Bool = false
    ) -> [Notebook] {
        func worked(_ goal: Notebook) -> Date {
            recency.lastWorkedAt(goal.id, updatedAt: goal.updatedAt)
        }
        /// The key's own comparison in its natural direction: negative
        /// when `lhs` comes first, zero on a tie.
        func compare(_ lhs: Notebook, _ rhs: Notebook) -> Int {
            switch self {
            case .recent:
                let left = worked(lhs), right = worked(rhs)
                return left == right ? 0 : (left > right ? -1 : 1)
            case .name:
                let order = NotebookTitle(lhs.title).text.localizedStandardCompare(NotebookTitle(rhs.title).text)
                return order == .orderedSame ? 0 : (order == .orderedAscending ? -1 : 1)
            case .sources:
                let left = lhs.homeSourceCount, right = rhs.homeSourceCount
                return left == right ? 0 : (left > right ? -1 : 1)
            case .uncategorized:
                let left = collections.collections(ofNotebook: lhs.id).count
                let right = collections.collections(ofNotebook: rhs.id).count
                return left == right ? 0 : (left < right ? -1 : 1)
            }
        }
        return notebooks.sorted { lhs, rhs in
            let order = compare(lhs, rhs)
            if order != 0 { return reversed ? order > 0 : order < 0 }
            // Within a group of Uncategorized first, either way round, the
            // notebook last worked in first.
            if self == .uncategorized {
                let left = worked(lhs), right = worked(rhs)
                if left != right { return left > right }
            }
            return Self.titleOrder(lhs, rhs)
        }
    }

    static func titleOrder<Notebook: NotebookHomeListing>(_ lhs: Notebook, _ rhs: Notebook) -> Bool {
        let order = NotebookTitle(lhs.title).text.localizedStandardCompare(NotebookTitle(rhs.title).text)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}

/// The home's order as this Mac keeps it: the key and whether the List's
/// header turned it round. Device-local, as the home's view is
/// (`SyncedPreferenceKeys.excluded`); a value another build wrote that this
/// one does not read is Recent.
struct NotebooksHomeOrder: Equatable, Sendable {
    static let sortPreferenceKey = "notebooks.home.sort.v1"
    static let reversedPreferenceKey = "notebooks.home.sortReversed.v1"

    var sort: NotebooksHomeSort
    var isReversed: Bool

    init(sort: NotebooksHomeSort = .recent, isReversed: Bool = false) {
        self.sort = sort
        self.isReversed = isReversed
    }

    /// The stored pair; Recent, unreversed, for none.
    init(storedSort: String, storedReversed: Bool) {
        self.init(sort: NotebooksHomeSort(rawValue: storedSort) ?? .recent, isReversed: storedReversed)
    }

    /// Whether the List's header draws the key's arrow pointing up.
    var isAscending: Bool { sort.isNaturallyAscending != isReversed }

    /// A click on the List header's column for `key`: the shown key turns
    /// round, another starts in its natural direction.
    func clicking(_ key: NotebooksHomeSort) -> NotebooksHomeOrder {
        key == sort
            ? NotebooksHomeOrder(sort: key, isReversed: !isReversed)
            : NotebooksHomeOrder(sort: key, isReversed: false)
    }

    /// The sort menu's choice: always the natural direction.
    func choosing(_ key: NotebooksHomeSort) -> NotebooksHomeOrder {
        NotebooksHomeOrder(sort: key, isReversed: false)
    }
}

/// How the home draws its notebooks: cards (the default, as NotebookLM's
/// home), or a dense sortable list for a large library (product owner,
/// 2026-10-03). Device-local, with the order.
enum NotebooksHomeLayout: String, CaseIterable, Identifiable, Sendable {
    static let preferenceKey = "notebooks.home.layout.v1"

    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    /// The stored choice; Grid for none, or a value this build does not read.
    init(stored: String) {
        self = NotebooksHomeLayout(rawValue: stored) ?? .grid
    }
}

/// Which notebooks the home's Notebooks tab shows: every one, those in no
/// collection (the rail's Uncategorized), or one collection's (a chip, a
/// Collections card, a rail row). Kept per window as one string
/// (`@SceneStorage`): empty for all, `uncategorized`, or a collection's
/// `nbc-` id, which can never be the word.
enum NotebooksHomeFilter: Equatable, Hashable, Sendable {
    static let uncategorizedStorage = "uncategorized"

    case all
    case uncategorized
    case collection(String)

    init(storage: String) {
        switch storage {
        case "": self = .all
        case Self.uncategorizedStorage: self = .uncategorized
        default: self = .collection(storage)
        }
    }

    var storage: String {
        switch self {
        case .all: return ""
        case .uncategorized: return Self.uncategorizedStorage
        case .collection(let id): return id
        }
    }

    /// The collection's id, for a collection filter.
    var collectionID: String? {
        if case .collection(let id) = self { return id }
        return nil
    }

    /// This filter as the home can show it: a collection deleted since
    /// reads as All.
    func resolved(in collections: NotebookCollections) -> NotebooksHomeFilter {
        if case .collection(let id) = self, collections.collection(id) == nil { return .all }
        return self
    }

    /// `notebooks` this filter shows, in the order given.
    func apply<Notebook: NotebookHomeListing>(_ notebooks: [Notebook], collections: NotebookCollections) -> [Notebook] {
        switch resolved(in: collections) {
        case .all:
            return notebooks
        case .uncategorized:
            return notebooks.filter { collections.collections(ofNotebook: $0.id).isEmpty }
        case .collection(let id):
            return notebooks.filter { collections.contains($0.id, in: id) }
        }
    }
}

/// The List view's Status column: short words, the weightiest first —
/// Archived, Shared (a team's notebook, or one a team holds a copy of),
/// Empty (no sources) — joined by " · "; empty for an ordinary notebook.
enum NotebookListStatus {
    static func text(isArchived: Bool, isShared: Bool, sourceCount: Int) -> String {
        var words: [String] = []
        if isArchived { words.append("Archived") }
        if isShared { words.append("Shared") }
        if sourceCount == 0 { words.append("Empty") }
        return words.joined(separator: " · ")
    }
}

/// The List view's Collections column: the names when one or two, else a
/// count ("3 collections"); empty for none.
enum NotebookListCollections {
    static let namesShown = 2

    static func chips(_ collections: [NotebookCollection]) -> [String] {
        collections.count <= namesShown ? collections.map(\.name) : []
    }

    static func countText(_ collections: [NotebookCollection]) -> String? {
        collections.count > namesShown ? "\(collections.count) collections" : nil
    }
}

// MARK: - The rail's notebooks

/// What the rail lists about notebooks since 2026-10-03 (docs/notebooks-
/// design.md, "The rail"). The product owner, of a rail listing ~52 notebooks: "is it
/// even still good design to have all these notebooks in the left sidebar as
/// well?" The whole catalog lives on the Notebooks home; the rail is a
/// compact way in: **Uncategorized** (notebooks in no collection, counted),
/// **Pinned**, **Recent** (the last few worked in, pinned ones aside), the
/// window's open notebook when it is none of those, and **Collections**.
/// Foundation-only, so the iPhone and the web's twin read the same rules.
struct NotebookRail: Equatable, Sendable {
    /// How many notebooks Recent lists.
    static let recentLimit = 6

    struct CollectionRow: Equatable, Identifiable, Sendable {
        let collection: NotebookCollection
        /// How many of the active notebooks it holds.
        let count: Int

        var id: String { collection.id }
    }

    /// Active notebooks in no collection.
    let uncategorizedCount: Int
    /// The pinned notebooks, in the order given (the learner's own).
    let pinnedIDs: [String]
    /// The last `recentLimit` worked in that are not pinned, last first.
    let recentIDs: [String]
    /// The window's notebook when neither pinned nor recent; nil otherwise.
    let openNotebookID: String?
    /// Every collection, by name.
    let collections: [CollectionRow]

    /// Every notebook with a row, in rail order: what the rail's chat folds
    /// and drop targets are for.
    var notebookIDs: [String] {
        pinnedIDs + recentIDs + [openNotebookID].compactMap { $0 }
    }

    /// - Parameters:
    ///   - notebooks: the open library's active notebooks, in the learner's
    ///     own order.
    ///   - pinned: the ids the learner pinned (`studio.pinnedNotebooks.v1`).
    ///   - openNotebookID: the notebook the window holds (or last left); a
    ///     notebook not in `notebooks` (archived) still gets its row.
    ///   - shownCollectionIDs: the collections the rail may name, nil for
    ///     all (Screen record mode names only those on screen).
    init<Notebook: NotebookHomeListing>(
        notebooks: [Notebook],
        pinned: Set<String>,
        recency: NotebookRecency,
        collections: NotebookCollections,
        openNotebookID: String?,
        shownCollectionIDs: Set<String>? = nil
    ) {
        let pinnedIDs = notebooks.map(\.id).filter(pinned.contains)
        self.pinnedIDs = pinnedIDs
        let recentIDs = NotebooksHomeSort.recent.ordered(notebooks, recency: recency)
            .lazy
            .map(\.id)
            .filter { !pinned.contains($0) }
            .prefix(Self.recentLimit)
        self.recentIDs = Array(recentIDs)
        if let openNotebookID, !openNotebookID.isEmpty,
           !pinnedIDs.contains(openNotebookID), !self.recentIDs.contains(openNotebookID) {
            self.openNotebookID = openNotebookID
        } else {
            self.openNotebookID = nil
        }
        var counts: [String: Int] = [:]
        var uncategorized = 0
        for notebook in notebooks {
            let held = collections.collections(ofNotebook: notebook.id)
            if held.isEmpty { uncategorized += 1 }
            for collection in held { counts[collection.id, default: 0] += 1 }
        }
        uncategorizedCount = uncategorized
        self.collections = collections.ordered
            .filter { shownCollectionIDs?.contains($0.id) ?? true }
            .map { CollectionRow(collection: $0, count: counts[$0.id] ?? 0) }
    }
}

/// The notebooks the learner pinned to the rail: an explicit list, synced
/// (`studio.pinnedNotebooks.v1`, per member like the order beside it).
/// Until 2026-10-03 every notebook was pinned unless the learner took it off
/// (`studio.unpinnedProjects`, the exceptions); with the catalog on the home
/// and Recent in the rail, a pin is the few the learner keeps at hand, so
/// nothing is pinned until they pin it.
enum NotebookPins {
    static let preferenceKey = "studio.pinnedNotebooks.v1"

    /// The list once `notebookID` is pinned or unpinned: ids the library no
    /// longer knows (`knownIDs`) leave on the way, so a deleted notebook's id
    /// never stays in the synced row; a new pin goes last.
    static func setting(_ notebookID: String, pinned: Bool, in ids: [String], knownIDs: Set<String>) -> [String] {
        var kept: [String] = []
        var seen = Set<String>()
        for id in ids where id != notebookID && knownIDs.contains(id) && seen.insert(id).inserted {
            kept.append(id)
        }
        if pinned, !notebookID.isEmpty { kept.append(notebookID) }
        return kept
    }
}

/// The line under a notebook card's title: "12 sources · updated Sep 30".
/// The source count a notebook's card and list show. A book is one source to
/// the learner even though it is stored as one source per chapter, so its
/// chapters count once (product owner, 2026-10-04: a book of 11 chapters made a
/// notebook read "23 sources" where the Sources column lists 13 rows).
enum NotebookSourceTally {
    /// `bookGroup` names the book a source is a chapter of (a book source with
    /// a non-blank parent group) and is nil for every other source.
    static func count<S: Sequence>(_ sources: S, bookGroup: (S.Element) -> String?) -> Int {
        NotebookSourceEntries.entries(sources, bookGroup: bookGroup).count
    }
}

/// One of a notebook's sources as the List names it: a source, or a book
/// standing for its chapters.
struct NotebookSourceEntry<Source> {
    /// The source, or the first of the book's chapters in the notebook's order.
    let source: Source
    /// The book's group name when the entry is a book; nil for a source alone.
    let book: String?
    /// How many of the book's chapters the notebook holds; 1 for a source alone.
    var chapters: Int
}

extension NotebookSourceEntry: Equatable where Source: Equatable {}

/// A notebook's sources as its row in the List names them (product owner,
/// 2026-10-06: "maybe on this page one of the sources can be shown; and then
/// maybe +30 more"): the first by name and how many more, a click listing
/// them all ("maybe we can expand that sources thing in a dropdown list").
/// The entries are the ones `NotebookSourceTally` counts, in the notebook's
/// own order, a book at its first chapter's place.
enum NotebookSourceEntries {
    /// `bookGroup` as `NotebookSourceTally.count` reads it.
    static func entries<S: Sequence>(_ sources: S, bookGroup: (S.Element) -> String?) -> [NotebookSourceEntry<S.Element>] {
        var entries: [NotebookSourceEntry<S.Element>] = []
        var bookEntry: [String: Int] = [:]
        for source in sources {
            if let group = bookGroup(source)?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty {
                if let index = bookEntry[group] {
                    entries[index].chapters += 1
                } else {
                    bookEntry[group] = entries.count
                    entries.append(NotebookSourceEntry(source: source, book: group, chapters: 1))
                }
            } else {
                entries.append(NotebookSourceEntry(source: source, book: nil, chapters: 1))
            }
        }
        return entries
    }
}

enum NotebookCardLine {
    static func text(
        sourceCount: Int,
        updatedAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let sources = sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
        return "\(sources) · updated \(when(updatedAt, now: now, calendar: calendar, locale: locale))"
    }

    /// "today", "yesterday", "Sep 30", or "Sep 30, 2025" for another year.
    static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated)
            .day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }
}
