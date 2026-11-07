import Foundation
import Observation
#if os(macOS)
@testable import ForeverLM
#endif

// The Space on the iPhone and iPad (docs/docs-design.md, "The Space"), the parts with no view and no
// store in them: what a page is on the phone, how the learner's own grouping of pages is held, and which
// pages each place lists. The Mac's Space is the spec (`SpaceDestination`, `SpaceCatalog`,
// `SpaceBrowseView.lists` and `passesFilters`, `StudioViewModel+PageSpaces`, `SpaceRecents`), the web's
// twin (`library-space.js`, `library-page-spaces.js`) the second reading of it. The rows themselves are
// the Mac's own types (`PageSpaces`, `PagePins`, `PageParents`, `DailyNote`). Foundation-only and
// compiled into the macOS unit tests, so every rule is pinned against the Mac's.

// MARK: - A page

/// One record the Space lists, as the phone reads it from its replica (`MobileSpaceReadModel`): a page,
/// a linked Google Doc, a site or a mnemonic reading in no notebook, trashed ones included.
struct MobileSpacePage: Identifiable, Equatable, Sendable {
    /// What the Space calls it (`SpaceItem.Kind` without the pictures, which are the Mac's files).
    enum Kind: String, Equatable, Sendable {
        case page, googleDoc, site, reading
    }

    let id: String
    var title: String
    /// The stored Artifact kind (`doc`, `linkedDoc`, `site`, `report`, `mnemonic_reading`, …).
    var kind: String
    /// Its home notebook.
    var notebookID: String?
    /// The other notebooks it is filed in.
    var linkedNotebookIDs: [String] = []
    /// The space (a team, D4) whose record it is; nil for the learner's own.
    var teamID: String?
    var isDraft: Bool
    /// In Trash: the record's `status` is `archived`.
    var isTrashed: Bool
    /// Hidden from the lists by this member (`Mark(hidden, art:)`): listed in Trash only.
    var isHidden = false
    var createdAt: Date
    var editedAt: Date
    /// The body's revision, the hash of its `body` satellite; nil before it has one.
    var bodyRevision: String?
    var linkedURL: String?
    var isDailyNote: Bool
    /// The learner's own Markdown page, which the phone edits: in My Library, not a linked Google Doc
    /// or site, not a reading (the Mac's Markdown editor opens exactly these).
    var isEditableMarkdown: Bool

    /// Page, Google Doc, site or reading, as `SpaceCatalog` sorts a record: the kind first, then the
    /// link. A link no build recognizes is a page, as on the Mac.
    var spaceKind: Kind {
        if kind == MobileSpaceListing.readingKind { return .reading }
        guard let linkedURL else { return .page }
        if MobileCloudArtifact.isGoogleDocLink(linkedURL) { return .googleDoc }
        return MobileCloudArtifact.isSiteLink(linkedURL) ? .site : .page
    }

    var isOwn: Bool { teamID == nil }
    /// A quarter's or a week's plan (`PlanPeriod`), named by its period as a daily note is by its day.
    var isPlan: Bool { teamID == nil && PlanPeriod.isPlanID(id) }

    /// Every notebook it is filed in, its home first (`NotebookMembership.filingNotebookIDs`).
    var notebookIDs: [String] {
        var seen = Set<String>()
        return ([notebookID].compactMap { $0 } + linkedNotebookIDs).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - The learner's grouping

/// The learner's own grouping of pages (the Mac's `PageSpaces`, `PagePins` and `PageParents`), as the
/// four kinds of account Setting hold it: `pageSpace.<spaceID>` a space's name, `page.space.<pageID>`
/// the space a page is in, `page.pinned.<pageID>` when it was pinned, `page.parent.<pageID>` the page
/// it sits under. Each map holds the rows as stored, a row naming a deleted space or a gone page
/// included: the readers below read past those, as the Mac does.
struct MobileSpaceOrganization: Equatable, Sendable {
    /// Every space in use, in `PageSpaces.ordered`'s order (by name, a leading emoji aside, then id): a
    /// space in Trash (`pageSpaceTrash.<spaceID>`) is left out, and so are the pages' rows naming it.
    var spaces: [PageSpace] = []
    var spaceIDByPage: [String: String] = [:]
    /// Seconds since 1970.
    var pinnedAtByPage: [String: Int] = [:]
    var parentByPage: [String: String] = [:]

    init(spaces: [PageSpace] = [], spaceIDByPage: [String: String] = [:], pinnedAtByPage: [String: Int] = [:],
         parentByPage: [String: String] = [:]) {
        self.spaces = spaces
        self.spaceIDByPage = spaceIDByPage
        self.pinnedAtByPage = pinnedAtByPage
        self.parentByPage = parentByPage
    }

    /// The grouping a set of Setting values holds, by key (Strings, as every client writes them); keys
    /// under no prefix of the four are ignored.
    init(rows: [String: Any]) {
        self.init(PageSpaces(rows: rows), PagePins(rows: rows), PageParents(rows: rows))
    }

    init(_ spaces: PageSpaces, _ pins: PagePins, _ parents: PageParents) {
        self.init(spaces: spaces.ordered, spaceIDByPage: spaces.memberships, pinnedAtByPage: pins.pinnedAt, parentByPage: parents.parentIDs)
    }

    /// The Setting key prefixes the grouping is read from.
    static let preferenceKeyPrefixes = [
        PageSpaces.namePreferenceKeyPrefix, PageSpaces.membershipPreferenceKeyPrefix, PageSpaces.trashPreferenceKeyPrefix,
        PagePins.preferenceKeyPrefix, PageParents.preferenceKeyPrefix,
    ]

    var pageSpaces: PageSpaces {
        PageSpaces(names: Dictionary(spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }), memberships: spaceIDByPage)
    }

    var pins: PagePins { PagePins(pinnedAt: pinnedAtByPage) }
    var parents: PageParents { PageParents(parentIDs: parentByPage) }

    func space(_ spaceID: String) -> PageSpace? { spaces.first { $0.id == spaceID } }

    /// The space a page is in; nil when in none, or when its row names a deleted space.
    func spaceID(ofPage pageID: String) -> String? {
        guard let spaceID = spaceIDByPage[pageID], space(spaceID) != nil else { return nil }
        return spaceID
    }

    func isPinned(_ pageID: String) -> Bool { pinnedAtByPage[pageID] != nil }

    // The grouping after one row is written (nil: the row goes), for the store's own writes.

    func settingName(_ name: String?, for spaceID: String) -> MobileSpaceOrganization {
        MobileSpaceOrganization(pageSpaces.settingName(name, for: spaceID), pins, parents)
    }

    func settingSpace(_ spaceID: String?, for pageID: String) -> MobileSpaceOrganization {
        MobileSpaceOrganization(pageSpaces.settingMembership(spaceID, for: pageID), pins, parents)
    }

    func settingPin(_ seconds: Int?, for pageID: String) -> MobileSpaceOrganization {
        MobileSpaceOrganization(pageSpaces, pins.setting(seconds, for: pageID), parents)
    }

    func settingParent(_ parentID: String?, for pageID: String) -> MobileSpaceOrganization {
        MobileSpaceOrganization(pageSpaces, pins, parents.settingParent(parentID, for: pageID))
    }
}

/// A team the phone holds (a shared space in the sync design, D4; the Mac's `vm.teams`), listed under
/// Spaces after the learner's own: its space id, which `MobileSpacePlace.team` and a page's `teamID`
/// name, and the name its root gives.
struct MobileSpaceTeam: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
}

// MARK: - Errors

/// Why the Space did not do what it was asked, in words for the learner.
enum MobileSpaceError: LocalizedError, Equatable {
    /// The phone is not on the new iCloud store (generation 1), or its library has not arrived.
    case unavailable
    /// The page or the space is gone, here or on another device.
    case notFound
    /// A name with nothing in it.
    case invalidName
    /// The page's text changed on another device since the editor opened it: what it is now.
    case conflict(currentMarkdown: String, currentRevision: String?)
    /// The page's text has not reached this phone yet (a Mac has not uploaded it).
    case notArrived
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Pages open on this iPhone once your library has moved to the new iCloud store."
        case .notFound: return "It was deleted on another device."
        case .invalidName: return "Enter a name."
        case .conflict: return "This page changed on another device. Its newer text is shown; copy what you wrote before saving again."
        case .notArrived: return "This page’s text has not reached iCloud yet."
        case .refused(let reason): return reason
        }
    }
}

// MARK: - Places

/// One place the phone's Space lists (the Mac's `SpaceDestination` without Images and Ideas, which the
/// Mac alone holds, as on the web): All, Pages, Sites, Google Drive, a team, one of the learner's spaces
/// of pages, and Trash. Pinned and Recents are sidebar sections, read with `MobileSpaceListing.pinned`
/// and `MobileSpaceRecents`.
enum MobileSpacePlace: Hashable, Sendable {
    case all
    /// The learner's plans for a quarter and a week (`PlanPeriod`), the Mac's Space › Plan.
    case plan
    case pages
    case sites
    case drive
    case trash
    /// What one team holds (a space in the sync design, D4), by its space id.
    case team(String)
    /// One of the learner's spaces of pages (`PageSpaces`), by its id.
    case space(String)

    /// The places listed under New page, in the sidebar's order.
    static let places: [MobileSpacePlace] = [.all, .plan, .pages, .sites, .drive]

    /// The place a key names, as the Mac's window remembers one; anything else is All.
    init(key: String) {
        switch key {
        case "plan": self = .plan
        case "pages": self = .pages
        case "sites": self = .sites
        case "drive": self = .drive
        case "trash": self = .trash
        default:
            if key.hasPrefix(Self.teamPrefix), key.count > Self.teamPrefix.count {
                self = .team(String(key.dropFirst(Self.teamPrefix.count)))
            } else if key.hasPrefix(Self.spacePrefix), key.count > Self.spacePrefix.count {
                self = .space(String(key.dropFirst(Self.spacePrefix.count)))
            } else {
                self = .all
            }
        }
    }

    var key: String {
        switch self {
        case .all: return "all"
        case .plan: return "plan"
        case .pages: return "pages"
        case .sites: return "sites"
        case .drive: return "drive"
        case .trash: return "trash"
        case .team(let id): return Self.teamPrefix + id
        case .space(let id): return Self.spacePrefix + id
        }
    }

    private static let teamPrefix = "team:"
    private static let spacePrefix = "space:"

    /// The place's name; a team's and a space's are their own, which the caller looks up.
    var title: String {
        switch self {
        case .all: return "All"
        case .plan: return "Plan"
        case .pages: return "Pages"
        case .sites: return "Sites"
        case .drive: return "Google Drive"
        case .trash: return "Trash"
        case .team, .space: return "Space"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "rectangle.stack"
        case .plan: return "target"
        case .pages: return "doc.text"
        case .sites: return "globe"
        case .drive: return "externaldrive"
        case .trash: return "trash"
        case .team: return "person.2"
        case .space: return "square.stack"
        }
    }

    var pageSpaceID: String? {
        if case .space(let id) = self { return id }
        return nil
    }

    /// The place an open page is listed under (`SpaceDestination.listing`): the space the list was
    /// showing while the page is in it, so New page files beside it; else by what the page is.
    static func listing(_ page: MobileSpacePage, within place: MobileSpacePlace? = nil, organization: MobileSpaceOrganization) -> MobileSpacePlace {
        if let spaceID = place?.pageSpaceID, !page.isTrashed, organization.spaceID(ofPage: page.id) == spaceID { return .space(spaceID) }
        if page.isTrashed { return .trash }
        switch page.spaceKind {
        case .googleDoc: return .drive
        case .site: return .sites
        case .page, .reading: return .pages
        }
    }
}

/// The list's order (the Mac's `SpaceSort`): Last Activity by default, as Codex's Space lists (product owner,
/// 2026-10-13: "at first it should be a copy of the codex"); Date Created was the default before
/// (2026-09-29: "just do it by creation date and time").
enum MobileSpaceSort: String, CaseIterable, Identifiable, Sendable {
    case created, activity, name

    /// The order a phone that never chose one lists in (the Mac's `SpaceSort.standard`).
    static let standard: MobileSpaceSort = .activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .created: return "Date Created"
        case .activity: return "Last Activity"
        case .name: return "Name"
        }
    }
}

// MARK: - What each place lists

/// The Space's rules on the phone, each the Mac's own (`SpaceCatalog`, `SpaceBrowseView`,
/// `StudioViewModel+PageSpaces`).
enum MobileSpaceListing {
    /// The stored kind of a mnemonic reading (`ArtifactKind.mnemonicReading`).
    static let readingKind = "mnemonic_reading"
    /// A new page's title (`ArtifactPlaceholderTitle.current`).
    static let untitledTitle = "Untitled Page"
    /// The longest title kept, as the web keeps one.
    static let titleCharacterLimit = 500

    /// The stored kinds that are never a Space item: a notebook's Notes Doc and its files, a standalone
    /// picture (a picture is the Mac's), an animation and an audio overview (their notebook's), and a
    /// source's draft deck. Every other kind is listed, one the phone has no word for as a page, as the
    /// Mac reads an unknown kind as a kindless Doc.
    static let unlistedKinds: Set<String> = ["notes", "file", "picture", "animation", "audioOverview", "audio_overview", "flashcards"]

    /// Whether a record of `kind` under `id` is a Space item at all: not a member's draft of a team page
    /// (`draft:`, and generation 1's `draft_`), a Notes Doc, a notebook file, a picture, a card deck or the
    /// working memory (`WorkingMemoryRecords`).
    static func isSpaceRecord(id: String, kind: String?) -> Bool {
        guard !id.isEmpty, !unlistedKinds.contains(kind ?? ""), !WorkingMemoryRecords.contains(id) else { return false }
        for prefix in ["draft:", MobileCloudArtifact.teamDraftIDPrefix, "notes:", "file:", "picture:"] where id.hasPrefix(prefix) {
            return false
        }
        return !MemoryCard.isDraftDeckID(id)
    }

    /// A title as it is kept: trimmed, at most `titleCharacterLimit` characters; nil when empty.
    static func cleanedTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(titleCharacterLimit))
    }

    /// Whether a place lists a page at all, before the filters (`SpaceBrowseView.lists`).
    static func lists(_ place: MobileSpacePlace, _ page: MobileSpacePage, organization: MobileSpaceOrganization) -> Bool {
        if place == .trash { return page.isTrashed }
        guard !page.isTrashed else { return false }
        switch place {
        case .all: return true
        case .plan: return page.isPlan
        case .pages: return page.spaceKind == .page || page.spaceKind == .reading
        case .sites: return page.spaceKind == .site
        case .drive: return page.spaceKind == .googleDoc
        case .team(let id): return page.teamID == id
        case .space(let id): return organization.spaceID(ofPage: page.id) == id
        case .trash: return false
        }
    }

    /// The hidden rule, the daily-note rule and the search (`SpaceBrowseView.passesFilters`): a hidden
    /// page is listed only in Trash (the phone has no Hidden scope, as the web has none), a daily note
    /// is reached by its day unless it holds writing (`NotesGraphDocListing`), and a search matches the title.
    static func passesFilters(_ page: MobileSpacePage, in place: MobileSpacePlace, query: String) -> Bool {
        if place != .trash, page.isHidden { return false }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if page.spaceKind == .page, page.isDailyNote,
           !NotesGraphDocListing.isListed(id: page.id, title: page.title, createdAt: page.createdAt,
                                          updatedAt: page.editedAt, searchQuery: query) { return false }
        guard !query.isEmpty else { return true }
        return page.title.localizedCaseInsensitiveContains(query)
    }

    /// What a place shows: the pages it lists that pass the filters, in the order asked for.
    static func pages(in place: MobileSpacePlace, from pages: [MobileSpacePage], organization: MobileSpaceOrganization,
                      query: String = "", sort: MobileSpaceSort = .created) -> [MobileSpacePage] {
        sorted(pages.filter { lists(place, $0, organization: organization) && passesFilters($0, in: place, query: query) }, by: sort)
    }

    /// Newest made first, newest activity first, or by name; ties by id, so two devices list alike.
    static func sorted(_ pages: [MobileSpacePage], by sort: MobileSpaceSort) -> [MobileSpacePage] {
        pages.sorted { lhs, rhs in
            switch sort {
            case .created where lhs.createdAt != rhs.createdAt:
                return lhs.createdAt > rhs.createdAt
            case .activity where lhs.editedAt != rhs.editedAt:
                return lhs.editedAt > rhs.editedAt
            case .name:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
            default:
                break
            }
            return lhs.id < rhs.id
        }
    }

    /// The date a row shows: when it went to Trash, in Trash (the record keeps its last edit as that),
    /// else the one the order is by.
    static func date(of page: MobileSpacePage, in place: MobileSpacePlace, sort: MobileSpaceSort) -> Date {
        place == .trash || sort == .activity ? page.editedAt : page.createdAt
    }

    // MARK: Pins

    /// Whether a page pins: the learner's own, out of Trash (`canPinPageItem`). A team's page is the team's.
    static func canPin(_ page: MobileSpacePage) -> Bool {
        page.isOwn && !page.isTrashed
    }

    /// The pinned pages the sidebar lists, the newest pin first (`StudioViewModel.pinnedPages`): the
    /// learner's own, not in Trash, not hidden.
    static func pinned(_ pages: [MobileSpacePage], organization: MobileSpaceOrganization) -> [MobileSpacePage] {
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return organization.pins.orderedPageIDs.compactMap { id in
            guard let page = byID[id], canPin(page), !page.isHidden else { return nil }
            return page
        }
    }

    // MARK: Spaces of pages

    /// Whether a page can be put in a space (`canFileInPageSpace`): the learner's own page, linked
    /// Google Doc, site or reading. A reading a notebook holds is never listed outside Trash here.
    static func canFileInSpace(_ page: MobileSpacePage) -> Bool {
        page.isOwn && isSpaceRecord(id: page.id, kind: page.kind)
    }

    // MARK: Subpages

    /// Whether a page can be a parent or a child (`canNestPage`): one of the learner's own Markdown pages,
    /// not a linked page, a reading or a daily note (a daily note is reached by its day).
    static func canNest(_ page: MobileSpacePage) -> Bool {
        canFileInSpace(page) && page.spaceKind == .page && page.linkedURL == nil && !page.isDailyNote && !page.isPlan
    }

    /// The pages that can be a parent now, nestable and out of Trash, in the order given (`nestablePages`).
    static func nestable(_ pages: [MobileSpacePage]) -> [MobileSpacePage] {
        pages.filter { !$0.isTrashed && canNest($0) }
    }

    /// The nestable pages as a tree (`pageTree`): a page whose parent is gone, in Trash or not nestable
    /// lists at the top, and its row stays.
    static func tree(_ pages: [MobileSpacePage], organization: MobileSpaceOrganization) -> PageParents.Tree {
        organization.parents.tree(among: nestable(pages).map(\.id))
    }

    /// The page a page sits under; nil when it is top-level, or its parent cannot be one now.
    static func parent(of pageID: String, in pages: [MobileSpacePage], organization: MobileSpaceOrganization) -> MobileSpacePage? {
        guard let parentID = tree(pages, organization: organization).parentID(ofPage: pageID) else { return nil }
        return pages.first { $0.id == parentID }
    }

    /// The pages directly under a page, in the order given (`subpages`).
    static func children(of pageID: String, in pages: [MobileSpacePage], organization: MobileSpaceOrganization) -> [MobileSpacePage] {
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tree(pages, organization: organization).childIDs(of: pageID).compactMap { byID[$0] }
    }

    /// The pages above a page, the top one first and the parent last: the trail over an open page
    /// (`pageAncestors`), read row by row from the page up.
    static func ancestors(of pageID: String, in pages: [MobileSpacePage], organization: MobileSpaceOrganization) -> [MobileSpacePage] {
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let page = byID[pageID], canNest(page) else { return [] }
        let chain = organization.parents.ancestorIDs(ofPage: pageID) { id in
            guard let candidate = byID[id] else { return false }
            return !candidate.isTrashed && canNest(candidate)
        }
        return chain.compactMap { byID[$0] }
    }

    /// The pages **Move to Page…** offers (`pageParentCandidates`): every other nestable page that is not
    /// hidden and not under it, by name.
    static func parentCandidates(for pageID: String, in pages: [MobileSpacePage], organization: MobileSpaceOrganization) -> [MobileSpacePage] {
        let below = Set(tree(pages, organization: organization).descendantIDs(of: pageID))
        return nestable(pages)
            .filter { $0.id != pageID && !$0.isHidden && !below.contains($0.id) }
            .sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    /// Whether a place's list draws subpages under their parent (`SpaceBrowseView.nestsList`): in All,
    /// Pages and a space, unsearched; a team's place and Trash are flat.
    static func nests(_ place: MobileSpacePlace, query: String, organization: MobileSpaceOrganization) -> Bool {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !organization.parentByPage.isEmpty else { return false }
        switch place {
        case .all, .pages, .space: return true
        case .plan, .sites, .drive, .trash, .team: return false
        }
    }

    /// One row of a list.
    struct Entry: Identifiable, Equatable, Sendable {
        let page: MobileSpacePage
        /// How far in it is drawn, at most `PageParents.displayDepthLimit`.
        var level = 0
        var hasChildren = false
        var isExpanded = false

        var id: String { page.id }
    }

    /// A place's pages as a list's rows (`SpaceBrowseView.listEntries`): nested, a subpage of a page in
    /// the list is drawn under it, only while its parent is open, at its depth; any other page is a row
    /// of its own, in the list's order. Flat when the place does not nest.
    static func entries(_ shown: [MobileSpacePage], nests: Bool, organization: MobileSpaceOrganization,
                        expanded: Set<String>) -> [Entry] {
        let flat = shown.map { Entry(page: $0) }
        guard nests else { return flat }
        let nestableIDs = Set(shown.filter(canNest).map(\.id))
        guard !nestableIDs.isEmpty else { return flat }
        let tree = organization.parents.tree(among: shown.map(\.id).filter { nestableIDs.contains($0) })
        guard shown.contains(where: { tree.hasChildren($0.id) }) else { return flat }
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Each top-level page's rows: itself, then what is open under it.
        var segments: [String: [PageParents.Tree.ListRow]] = [:]
        var root: String?
        for row in tree.listRows(expanded: expanded) {
            if row.level == 0 { root = row.id }
            if let root { segments[root, default: []].append(row) }
        }
        var entries: [Entry] = []
        entries.reserveCapacity(shown.count)
        for page in shown {
            guard nestableIDs.contains(page.id) else {
                entries.append(Entry(page: page))
                continue
            }
            // A subpage is drawn under its parent, not on its own.
            guard tree.parentID(ofPage: page.id) == nil else { continue }
            for row in segments[page.id] ?? [] {
                guard let member = byID[row.id] else { continue }
                entries.append(Entry(page: member, level: row.level, hasChildren: row.hasChildren, isExpanded: row.isExpanded))
            }
        }
        return entries
    }

    // MARK: Daily notes

    /// The daily notes out of Trash, the newest day first (`dailyNotes(before:limit:)`).
    static func dailyNotes(_ pages: [MobileSpacePage]) -> [MobileSpacePage] {
        pages
            .filter { $0.isDailyNote && !$0.isTrashed }
            .sorted { (DailyNote.dayKey(ofID: $0.id) ?? "") > (DailyNote.dayKey(ofID: $1.id) ?? "") }
    }
}

// MARK: - Recents

/// What this iPhone opened last in the Space, newest first (the Mac's `SpaceRecents`): device-local and
/// never synced, since which page this phone had open is this phone's arrangement, and opening a page
/// writes nothing that travels. An id stays after its page is gone; the sidebar shows only what the
/// library still holds out of Trash, and the oldest go once `capacity` is passed.
@Observable
@MainActor
final class MobileSpaceRecents {
    static let shared = MobileSpaceRecents()
    /// This phone's own key, its entries in the Mac's shape (`SpaceRecents.preferenceKey`'s).
    static let preferenceKey = "ios.space.recents.v1"
    static let capacity = 40
    /// How many the sidebar shows.
    static let shown = 8

    struct Item: Equatable, Hashable, Sendable {
        let id: String
        var openedAt: Date
    }

    private(set) var items: [Item]
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        items = Self.load(from: defaults)
    }

    /// Notes an opening, the latest winning: the page moves to the top.
    func note(_ pageID: String, at date: Date = Date()) {
        guard !pageID.isEmpty, items.first?.id != pageID else { return }
        var next = items.filter { $0.id != pageID }
        next.insert(Item(id: pageID, openedAt: date), at: 0)
        if next.count > Self.capacity { next.removeLast(next.count - Self.capacity) }
        items = next
        save()
    }

    /// Forgets a page deleted for good, so it is never offered again.
    func forget(_ pageID: String) {
        let next = items.filter { $0.id != pageID }
        guard next.count != items.count else { return }
        items = next
        save()
    }

    /// The Recents the sidebar shows: the first few the library still holds out of Trash, hidden ones
    /// left out, in the order they were opened.
    func shown(among pages: [MobileSpacePage]) -> [MobileSpacePage] {
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var shown: [MobileSpacePage] = []
        for item in items {
            guard shown.count < Self.shown else { break }
            guard let page = byID[item.id], !page.isTrashed, !page.isHidden else { continue }
            shown.append(page)
        }
        return shown
    }

    /// The entries a `save()` left in `defaults`, in the Mac's shape (`{k, id, t}`, a page being an
    /// `artifact`); none for nil, an absent key or a shape this build does not read.
    static func load(from defaults: UserDefaults?) -> [Item] {
        guard let raw = defaults?.array(forKey: preferenceKey) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return raw.compactMap { entry -> Item? in
            guard (entry["k"] as? String ?? "artifact") == "artifact", let id = entry["id"] as? String, !id.isEmpty,
                  let seconds = (entry["t"] as? NSNumber)?.doubleValue, seconds.isFinite, seen.insert(id).inserted else { return nil }
            return Item(id: id, openedAt: Date(timeIntervalSince1970: seconds))
        }
        .prefix(capacity)
        .map { $0 }
    }

    private func save() {
        defaults?.set(items.map { ["k": "artifact", "id": $0.id, "t": $0.openedAt.timeIntervalSince1970] as [String: Any] }, forKey: Self.preferenceKey)
    }
}
