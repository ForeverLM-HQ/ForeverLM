import Foundation
import Observation
import SwiftUI

// MARK: - Center Tabs

/// One of the center surfaces, shown in a center group. Permanent destinations
/// are singletons; a transient second Chat may be added while comparing two
/// conversations across one or two side-by-side groups.
enum StudioCenterTab: String, Codable, CaseIterable, Identifiable {
    case chat
    /// Optional second conversation surface created by dragging a chat to a
    /// workspace edge. Unlike the destination tabs it is not permanent: it
    /// exists only while the learner is comparing two conversations.
    case secondaryChat
    case reader
    /// Recurring instructions the app runs by itself: an instruction on a clock.
    case tasks
    /// What the app saw the learner do on one day, drawn on a clock: split
    /// out of the Planner on 2026-09-22, and kept when the Planner went on
    /// 2026-09-30 (the day's plan is the Mac's Calendar). A saved layout that
    /// still names "planner" drops that tab on load (`fromPersisted`).
    case activity
    /// The Goals tab: everything the learner wants to be true by a date, in
    /// deadline order. Added 2026-09-18; a Goal stands on its own and a
    /// Notebook is only a tag on it (goals-design.md).
    case goals
    /// The Courses tab: every course as a card, and one course's page, its
    /// lectures and quizzes laid out Khan Academy style. Moved here from a
    /// Sources tab on 2026-09-27: a course is a structure over sources, not
    /// a source (courses-design.md).
    case courses
    /// The Ideas tab: what the learner jotted down, newest first, and what
    /// each thought is linked to. Added 2026-09-20; a corollary to Goals — an
    /// Idea has no date until it becomes one (ideas-design.md).
    case ideas
    case notepad
    /// Pages that live elsewhere and open here as themselves — Claude
    /// artifacts and Codex sites — split out of Docs on 2026-09-08.
    case sites
    /// A WebKit browser with profiles — separate cookie jars — so a site can
    /// be signed in to under one Google account while the Drive plugin
    /// holds another, and any page can be added to Sources from where it is
    /// read. Added 2026-09-08.
    case browser
    /// The explainer films ForeverLM has made and the composer that makes
    /// one; a video is an ordinary source under Videos. Added 2026-09-10; see
    /// docs/explainer-video-design.md.
    case videos
    /// Moving explanations of the library's sources, hosted like a site and
    /// listed apart from Sites by the record's kind. Added 2026-09-17; see
    /// docs/animations-design.md.
    case animations
    /// The Space: ChatGPT's Space, the home of the app since 2026-10-09 —
    /// every page, site, picture, idea, canvas, list, notebook and course in
    /// one list, with its own sidebar (docs/docs-design.md, "The Space").
    /// Added 2026-09-17 as the Artifacts home over everything made; cut to
    /// the Docs, Sites and Ideas of every notebook on 2026-10-06, when the
    /// one-off kinds (pictures, animations, audio overviews, films,
    /// walkthroughs, narrations) went to their notebooks' Studio alone, and
    /// copied from ChatGPT's Space the same day. The raw value stays
    /// `artifacts`, as stored layouts name it.
    case artifacts
    /// The Memory pane: today's card review across every notebook or one
    /// (Start Review), the cards to check, and every kept card. The rail's
    /// Memory row opens it; added 2026-10-01 with the card review
    /// (docs/memory-design.md, "The card review"). In a notebook window it
    /// opens in the notebook's document slot.
    case memory
    /// The full-window Library: the whole library's Sources list laid out
    /// wide for managing it — every kind, search, imports, multi-select with
    /// a bulk bar, and the notebooks each source is in. The rail's Library
    /// row and ⇧⌘L open it; added 2026-10-01 (decisions v5, 2;
    /// docs/notebooks-design.md, "The full-window Library"). It leaves a
    /// notebook the way the Space does: inside a notebook the library is its
    /// Sources column's search.
    case library
    /// The Map: the whole library on one zoomable plane, which the learner
    /// arranges and a chat may show a lens over. The rail's Map row opens it;
    /// added 2026-10-05 (docs/knowledge-map-design.md). It leaves a notebook
    /// the way the Library does: the Map is the library's, not a notebook's.
    case knowledgeMap
    /// The Atlas: a topic laid out as concepts at levels of abstraction,
    /// grounded in the library (docs/atlas-design.md). A place like the
    /// Canvas; it leaves a notebook the way the Canvas does. Added 2026-10-05.
    case atlas
    /// Plugins, Codex's (2026-10-13): every plugin and its state, and each
    /// plugin's own page, which were Settings' Plugins pane until then
    /// (docs/codex-shell-plan.md, Track 2). The strip's Plugins row opens it;
    /// it leaves a notebook the way the Library does.
    case plugins

    var id: String { rawValue }

    static let permanentTabs: [StudioCenterTab] = [.chat, .reader, .tasks, .activity, .goals, .courses, .ideas, .notepad, .sites, .browser, .videos, .animations, .artifacts, .memory, .knowledgeMap, .atlas, .library, .plugins]

    /// The panes of the Space's kinds, which open beside one another: the
    /// Pages and Sites the sidebar's rows open (`ArtifactsHomeKind`), and
    /// Ideas, which a Doc's idea link opens beside it (`openIdea`).
    static let artifactKinds: Set<StudioCenterTab> = [.notepad, .sites, .ideas]

    /// What the place registry calls it (`ShellPlaces`).
    var title: String { ShellPlaces.descriptor(for: self).title }
}

extension ArtifactSection {
    /// The center tab that lists the section: Docs is the pane that has
    /// always been called `notepad`; Sites and Animations are their own.
    var centerTab: StudioCenterTab {
        switch self {
        case .docs: return .notepad
        case .sites: return .sites
        case .animations: return .animations
        }
    }
}

/// The user's arrangement of the center tabs: an ordered partition into one,
/// two or three panes, each showing one active tab and a strip of the tabs
/// the learner has open there. Every destination is parked in some pane;
/// the ones the learner opened are that pane's tabs (`Group.openTabs`), and a
/// pane with two or more draws them as a strip above it. Tabs replaced pane
/// pins on 2026-10-19 (product owner: "a primarily tab-based system where i
/// can easily drag a tab to the side to view side by side ... clearer than
/// this whole thing with pinning stuff"): nothing the learner opens covers
/// another surface for good, so nothing needs guarding.
///
/// Persisted and synced as one string per pane — tab raw values joined by
/// "|", the active tab suffixed "*" and every other open tab "+"
/// (e.g. `["artifacts*|chat+|reader", "notepad*"]`), a plist-friendly shape
/// the preference sync rails already carry.
struct StudioCenterTabGroups: Equatable {
    struct Group: Equatable, Identifiable {
        /// Stable for the life of one pane, and deliberately outside `==`.
        ///
        /// The center columns are keyed on this, so reordering the panes moves
        /// each one's hosted views instead of rebuilding them. Keyed
        /// positionally — which is what the layout did before — swapping two
        /// panes kept the slots and changed their contents, so both subtrees
        /// were torn down and built again: the reader's `WKWebView` was
        /// recreated and reloaded its page over the network, and every chat
        /// bubble's measured height reset to its 36pt placeholder and re-grew
        /// as each web view reported back. That is the multi-second pause the
        /// swap control used to produce.
        ///
        /// Equality stays content-only because every comparison of a layout
        /// asks "is this the same arrangement" — the `didSet` deciding whether
        /// reconciliation changed anything, the guards that skip a no-op write,
        /// and the tests that check a layout against a freshly built expected
        /// value. An identity inside `==` would make two identical arrangements
        /// compare unequal and defeat all three.
        let id = UUID()
        var tabs: [StudioCenterTab]
        var activeTab: StudioCenterTab {
            // What a pane stops showing stays one of its tabs: opening
            // something over it never closes it.
            didSet {
                guard activeTab != oldValue else { return }
                if tabs.contains(oldValue), !keptOpen.contains(oldValue) { keptOpen.append(oldValue) }
                if !keptOpen.contains(activeTab) { keptOpen.append(activeTab) }
            }
        }
        /// The open tabs as recorded; read them through `openTabs`.
        private var keptOpen: [StudioCenterTab]

        init(tabs: [StudioCenterTab], activeTab: StudioCenterTab, openTabs: [StudioCenterTab] = []) {
            self.tabs = tabs
            self.activeTab = activeTab
            self.keptOpen = []
            self.openTabs = openTabs
        }

        /// The pane's tabs in strip order: what it shows and every surface it
        /// showed before that the learner has not closed. Always holds the
        /// active tab, and only members of `tabs`.
        ///
        /// Outside `==`, like `id`: equality asks what each pane shows, which is
        /// what every no-op guard and every layout test compares. A change to
        /// the strip alone — a background tab closed — is assigned
        /// unconditionally (`StudioViewModel.closeCenterTab`).
        var openTabs: [StudioCenterTab] {
            get {
                var open = keptOpen.filter { tabs.contains($0) }
                if !open.contains(activeTab) { open.append(activeTab) }
                return open
            }
            set {
                var seen = Set<StudioCenterTab>()
                keptOpen = newValue.filter { seen.insert($0).inserted }
            }
        }

        /// Whether the pane draws its strip: always. Every pane is a tab, a
        /// lone one included, so it can be dragged, closed and added to with
        /// the strip's + (product owner, 2026-11-02: "every pane should
        /// always be a tab ... and i should be able to add additional
        /// tabs"). Until then a pane with one tab drew none.
        var showsTabStrip: Bool { true }

        /// Takes `tab` out of the pane, its strip included. When it was the
        /// active tab the pane shows its neighbour in the strip — the tab to
        /// its right, else to its left — or, with no other tab open, the
        /// Reader, else whatever is parked first.
        mutating func remove(_ tab: StudioCenterTab) {
            let open = openTabs
            tabs.removeAll { $0 == tab }
            keptOpen.removeAll { $0 == tab }
            guard activeTab == tab, !tabs.isEmpty else { return }
            activeTab = Self.neighbour(of: tab, in: open)
                ?? (tabs.contains(.reader) ? .reader : tabs[0])
        }

        /// Closes `tab`'s tab and leaves it parked in the pane. False when it
        /// is the pane's only tab, which closes the pane or shows its home
        /// instead (`StudioViewModel.deactivateCenterTab`).
        mutating func closeTab(_ tab: StudioCenterTab) -> Bool {
            let open = openTabs
            guard open.contains(tab), let next = Self.neighbour(of: tab, in: open) else { return false }
            keptOpen.removeAll { $0 == tab }
            if activeTab == tab { activeTab = next }
            // The closed tab was just kept open by `activeTab`'s own rule.
            keptOpen.removeAll { $0 == tab }
            return true
        }

        private static func neighbour(of tab: StudioCenterTab, in open: [StudioCenterTab]) -> StudioCenterTab? {
            guard let position = open.firstIndex(of: tab) else { return nil }
            if position + 1 < open.count { return open[position + 1] }
            return position > 0 ? open[position - 1] : nil
        }

        static func == (lhs: Group, rhs: Group) -> Bool {
            lhs.tabs == rhs.tabs && lhs.activeTab == rhs.activeTab
        }
    }

    var groups: [Group]

    /// The Space across the center, every other surface behind it in the same
    /// pane: the first-launch shape since the home became what a window
    /// holding no notebook shows (2026-10-01), and the Space has been that
    /// home since the Notebooks home went (2026-10-09, docs/docs-design.md,
    /// "The Space"). Before, Chat sat beside the reading surfaces. Subsequent
    /// launches restore the learner's saved arrangement, and a source, a chat
    /// or a pane opened from the Space opens as a tab or beside it by the
    /// ordinary rules.
    static let defaultLayout = StudioCenterTabGroups(groups: [
        Group(tabs: [.artifacts, .chat, .reader, .tasks, .notepad, .sites, .browser], activeTab: .artifacts),
    ])

    /// What the app arranges on its own never makes more than two panes: a
    /// third column makes every surface too narrow to use as the default
    /// workspace.
    static let maximumGroupCount = 2

    /// Hard cap. A third pane appears only when the learner drags a tab to an
    /// edge of a two-pane window; four panes are never restored.
    static let draggedGroupCount = 3

    /// True when the app may open another pane on its own (`maximumGroupCount`).
    var canCreateGroup: Bool { groups.count < Self.maximumGroupCount }

    /// True when a tab dragged to an edge may open another pane there.
    var canCreateDraggedGroup: Bool { groups.count < Self.draggedGroupCount }

    /// Whether every pane has the same strip as in `other`, which `==` leaves
    /// out (`Group.openTabs`).
    func hasSameOpenTabs(as other: StudioCenterTabGroups) -> Bool {
        groups.map(\.openTabs) == other.groups.map(\.openTabs)
    }

    /// The arrangement once `tab` is on screen, the way a sidebar click asks:
    /// a tab already open in some pane comes to the front there; otherwise it
    /// opens as a new tab in `focusedGroupID`'s pane — the one the learner
    /// last clicked in — or, with none, the pane it is parked in. What that
    /// pane showed stays one of its tabs. Nil when no pane holds `tab`. The
    /// one rule `StudioViewModel.activateCenterTab` and a window arranging
    /// itself (`StudioWindowState.activateCenterTabForThisWindowOnly`) share.
    func activating(_ tab: StudioCenterTab, focusedGroupID: UUID? = nil) -> StudioCenterTabGroups? {
        var layout = self
        if let open = layout.groups.firstIndex(where: { $0.openTabs.contains(tab) }) {
            layout.groups[open].activeTab = tab
            return layout
        }
        guard let source = layout.groups.firstIndex(where: { $0.tabs.contains(tab) }) else { return nil }
        let target = focusedGroupID.flatMap { id in layout.groups.firstIndex { $0.id == id } } ?? source
        if target != source {
            // Parked and not open, so not the source's active tab either.
            layout.groups[source].tabs.removeAll { $0 == tab }
            layout.groups[target].tabs.append(tab)
        }
        layout.groups[target].activeTab = tab
        return layout
    }

    /// The arrangement once the pane at `index` shows `tab`, the way a drag
    /// onto a pane says it: that pane, and no other, takes it. What the pane
    /// showed stays one of its tabs.
    ///
    /// - `tab` shown alone in another pane: the two panes trade places, so
    ///   what the drop covered stays on screen.
    /// - `tab` parked or sharing another pane: it moves into this one, and
    ///   what this pane showed parks behind it.
    ///
    /// Nil when `index` is not a pane or no pane holds `tab`.
    func replacingPane(at index: Int, with tab: StudioCenterTab) -> StudioCenterTabGroups? {
        guard groups.indices.contains(index),
              let source = groups.firstIndex(where: { $0.tabs.contains(tab) }) else { return nil }
        var layout = self
        if source == index {
            layout.groups[index].activeTab = tab
            return layout
        }
        if layout.groups[source].tabs == [tab] {
            layout.groups.swapAt(source, index)
            return layout
        }
        layout.groups[source].remove(tab)
        layout.groups[index].tabs.append(tab)
        layout.groups[index].activeTab = tab
        return layout
    }

    /// The arrangement with no pane showing one of `unoffered`, the panes of
    /// a feature this Mac does not show yet (`BetaFeatures`): such a pane
    /// shows its first other tab instead, preferring the Space, and a
    /// pane that holds nothing else is closed (its tabs rejoin the last pane
    /// through `reconciled`, behind what that pane shows). No strip offers one
    /// as a tab either. Nothing else moves, so the arrangement comes back as
    /// it was once the feature shows.
    func withoutShowing(_ unoffered: Set<StudioCenterTab>) -> StudioCenterTabGroups {
        guard groups.contains(where: { $0.openTabs.contains(where: unoffered.contains) }) else { return self }
        var layout = self
        for index in layout.groups.indices {
            layout.groups[index].openTabs.removeAll(where: unoffered.contains)
        }
        for index in layout.groups.indices where unoffered.contains(layout.groups[index].activeTab) {
            let others = layout.groups[index].tabs.filter { !unoffered.contains($0) }
            if let shown = others.first(where: { $0 == .artifacts }) ?? others.first {
                layout.groups[index].activeTab = shown
            } else {
                layout.groups[index].tabs = []
            }
        }
        return Self.reconciled(layout)
    }

    /// Restores the invariants no persisted, synced, or mutated value may
    /// break: every permanent tab appears exactly once (first appearance wins,
    /// missing tabs join the last group), no group is empty, every group's
    /// active tab is one of its members, and there are at most
    /// `draggedGroupCount` groups (extras merge into the last, parked). Like the panel
    /// orders, this must run at every assignment, not just at load, or a partial
    /// synced value would permanently drop tabs.
    static func reconciled(_ raw: StudioCenterTabGroups) -> StudioCenterTabGroups {
        var seen = Set<StudioCenterTab>()
        // Copied and mutated rather than rebuilt, so a group that survives
        // reconciliation keeps its `id`. Constructing a replacement here would
        // hand every pane a new identity on each assignment, which is exactly
        // the remount this identity exists to avoid.
        var groups: [Group] = raw.groups.map { group in
            var group = group
            group.tabs = group.tabs.filter { tab in
                return seen.insert(tab).inserted
            }
            return group
        }
        groups.removeAll { $0.tabs.isEmpty }
        if groups.isEmpty { groups = [Group(tabs: [], activeTab: .reader)] }
        for tab in StudioCenterTab.permanentTabs where !seen.contains(tab) {
            groups[groups.count - 1].tabs.append(tab)
        }
        while groups.count > draggedGroupCount {
            let extra = groups.removeLast()
            groups[draggedGroupCount - 1].tabs.append(contentsOf: extra.tabs)
        }
        return StudioCenterTabGroups(groups: groups.map { group in
            var group = group
            if !group.tabs.contains(group.activeTab) {
                group.activeTab = group.tabs.first ?? .reader
            }
            return group
        })
    }

    /// The synced on-disk shape.
    var persistedRepresentation: [String] {
        groups.compactMap { group in
            // A dragged comparison chat is transient. Persisting its slot
            // without its live manager/session would reopen an empty mystery
            // pane on the next launch or another Mac.
            let tabs = group.tabs.filter { $0 != .secondaryChat }
            guard !tabs.isEmpty else { return nil }
            let active = tabs.contains(group.activeTab) ? group.activeTab : tabs[0]
            let open = Set(group.openTabs)
            return tabs
                .map { tab in
                    if tab == active { return tab.rawValue + "*" }
                    return open.contains(tab) ? tab.rawValue + "+" : tab.rawValue
                }
                .joined(separator: "|")
        }
    }

    /// What a saved layout called the Notebooks home before it went.
    private static let retiredHomeTabNames: Set<String> = ["notebooks", "projects"]

    static func fromPersisted(_ raw: [String]) -> StudioCenterTabGroups? {
        guard !raw.isEmpty else { return nil }
        let groups: [Group] = raw.map { line in
            var active: StudioCenterTab?
            var tabs: [StudioCenterTab] = []
            var open: [StudioCenterTab] = []
            for token in line.split(separator: "|") {
                var name = String(token)
                let isActive = name.hasSuffix("*")
                let isOpen = name.hasSuffix("+")
                if isActive || isOpen { name.removeLast() }
                // The Notebooks home is gone (2026-10-09; it was the Projects
                // tab before 2026-10-04): a layout that still names it shows
                // the Space in its place, which is where every notebook is
                // listed now. The one place the retired names are read.
                if Self.retiredHomeTabNames.contains(name) {
                    name = StudioCenterTab.artifacts.rawValue
                }
                guard let tab = StudioCenterTab(rawValue: name), tab != .secondaryChat else { continue }
                tabs.append(tab)
                if isActive { active = tab }
                if isActive || isOpen { open.append(tab) }
            }
            return Group(tabs: tabs, activeTab: active ?? tabs.first ?? .reader, openTabs: open)
        }
        return reconciled(StudioCenterTabGroups(groups: groups))
    }
}

// MARK: - Per-window workspace state

/// One web page opened from a Deep Research citation before the learner has
/// chosen to save it. It is presentation state, not a library record: keeping
/// it out of `StudioViewModel.articles` prevents a click from masquerading as
/// persistence or appearing in Sources before the explicit Add action succeeds.
struct StudioExternalReaderPage: Equatable, Identifiable {
    let url: URL
    let title: String

    var id: String { SourceDiscovery.normalizedURL(url.absoluteString) }

    var article: StudioArticle {
        var article = StudioArticle(
            url: url.absoluteString,
            title: title,
            sourceType: StudioViewModel.detectSourceType(url: url.absoluteString),
            discoveryOrigin: .manual,
            id: "external-reader:\(id)"
        )
        article.domain = url.host ?? url.absoluteString
        article.normalizedURL = id
        return article
    }
}

/// Presentation state that belongs to one macOS Studio window.
///
/// The source catalog, storage actor, sync engine, imports, and AI workflows remain
/// app-wide on `StudioViewModel`. Pane arrangement and side-panel visibility are
/// scene state: changing one monitor's workspace must not rearrange another.
@Observable
@MainActor
final class StudioWindowState: Identifiable {
    struct Snapshot: Codable, Equatable {
        var centerTabGroups: [String]
        var navigationRailVisible: Bool
        /// The notebook the window holds, without its moments
        /// (`NotebookWorkspace.persisted`). Scene-only: it rides the scene
        /// storage, the last session and named workspaces, and never a
        /// template key. Absent in records older builds wrote, which decode
        /// as a window holding no notebook; older builds ignore it.
        var notebook: NotebookWorkspace? = nil
        /// The chat the window last had open in each notebook it held, by
        /// Notebook id (`StudioWindowState.notebookChats`). Scene-only, like
        /// `notebook`; absent in older records.
        var notebookChats: [String: String]? = nil
    }

    static let sceneStorageKey = "studio.window.workspace.v1"
    private static let navigationRailVisibilityKey = "studio.navigationRailVisible"

    let id: UUID
    var persistenceRevision = 0

    var centerTabGroups: StudioCenterTabGroups {
        didSet {
            // A pane of a feature this Mac does not show yet never comes on
            // screen, by whatever route: a restored or synced layout, a
            // template, or a call that slipped past its entry point.
            let reconciled = StudioCenterTabGroups.reconciled(centerTabGroups)
                .withoutShowing(BetaFeatures.unofferedCenterTabs)
            if reconciled != centerTabGroups || !reconciled.hasSameOpenTabs(as: centerTabGroups) {
                centerTabGroups = reconciled
                return
            }
            noteReaderCover(from: oldValue)
            recordPersistentChange {
                PreferenceStore.set(reconciled.persistedRepresentation, forKey: "studio.centerTabGroups.v1")
            }
        }
    }

    /// What the Reader covered when it took a pane that showed something else:
    /// the Library a row was clicked in, the Space, Pages. Once the Reader has
    /// no source of its own to go back to, its ‹ shows that surface again
    /// (`returnFromReaderCover`), as a notebook's Reader gives its document
    /// slot back. Until 2026-10-12 a source opened over the Library left ‹
    /// greyed out, and the list it came from was one rail click away.
    struct ReaderCover: Equatable {
        /// The pane the Reader took, by `Group.id`.
        let groupID: UUID
        let tab: StudioCenterTab
        /// The Reader's history depth when it took the pane: a source opened
        /// since is the page before, and below this depth the way back is the
        /// surface rather than whatever was read before.
        fileprivate(set) var backDepth: Int
    }
    private(set) var readerCover: ReaderCover?

    /// Keeps `readerCover` in step with the panes: a Reader becoming a pane's
    /// active tab over another surface records it; the Reader leaving that
    /// pane forgets it. A pane the Reader opened in fresh covered nothing.
    private func noteReaderCover(from old: StudioCenterTabGroups) {
        guard let group = centerTabGroups.groups.first(where: { $0.activeTab == .reader }) else {
            if readerCover != nil { readerCover = nil }
            return
        }
        if readerCover?.groupID == group.id { return }
        guard let before = old.groups.first(where: { $0.id == group.id }),
              before.activeTab != .reader else {
            if readerCover != nil { readerCover = nil }
            return
        }
        readerCover = ReaderCover(
            groupID: group.id,
            tab: before.activeTab,
            backDepth: readerBackStack.count
        )
    }

    /// Whether the Reader's ‹ goes back to the surface it covered: it still
    /// shows in that pane and has read nothing since it took it.
    var readerBackReturnsToCover: Bool {
        guard notebook == nil, let readerCover else { return false }
        return readerBackStack.count <= readerCover.backDepth
    }

    /// The Reader's ‹ over a covered surface: the pane shows that surface
    /// again. False when the surface has left the
    /// pane meanwhile, for the caller to bring it on screen the ordinary way.
    @discardableResult
    func returnFromReaderCover() -> Bool {
        guard let readerCover else { return false }
        var layout = centerTabGroups
        guard let index = layout.groups.firstIndex(where: { $0.id == readerCover.groupID }),
              layout.groups[index].activeTab == .reader,
              layout.groups[index].tabs.contains(readerCover.tab) else {
            self.readerCover = nil
            return false
        }
        layout.groups[index].activeTab = readerCover.tab
        centerTabGroups = layout
        return true
    }

    var navigationRailVisible: Bool {
        didSet {
            recordPersistentChange {
                PreferenceStore.set(
                    navigationRailVisible,
                    forKey: Self.navigationRailVisibilityKey
                )
            }
        }
    }

    /// Whether this window shows the sidebar beside the icon strip: the
    /// learner's choice. The strip itself is always drawn (product owner,
    /// 2026-10-12: "should never be hidden"); this folds Home's sidebar.
    var showsNavigationRail: Bool { navigationRailVisible }

    /// Whether this window draws that sidebar now: as `showsNavigationRail`
    /// says, unless a memory review has the window and the learner has not
    /// asked for the sidebar beside it.
    var drawsNavigationRail: Bool {
        showsNavigationRail && (memoryReviewFocus == nil || memoryReviewFocusShowsSidebar)
    }

    /// The sidebar toggle, and View ▸ Show or Hide Navigation Sidebar. A
    /// sidebar stepping aside for a memory review comes back on asking: it
    /// shows beside the review, which runs on until a row in it is picked.
    func setNavigationRailShown(_ shown: Bool) {
        if memoryReviewFocus != nil, memoryReviewFocusShowsSidebar != shown { memoryReviewFocusShowsSidebar = shown }
        if navigationRailVisible != shown { navigationRailVisible = shown }
    }

    /// Whether Home's sidebar shows beside a place that has the window's card
    /// to itself (the Library, Memory, the Canvas, the Atlas, Plugins). It
    /// starts shown and stays until the learner folds it with the sidebar
    /// toggle, so opening Memory never makes the sidebar vanish (product owner,
    /// 2026-10-26: "when I click memory, the left sidebar disappears randomly
    /// ... get rid of that"). Before then those places opened without it and
    /// the toggle brought it in. Presentation, not layout: absent from
    /// `Snapshot`.
    var homeSidebarBesidePlace = true

    /// Whether the window is on such a place: no notebook, no Space, and a
    /// pane on a place with no sidebar of its own (`ShellPlace.sidebar` nil).
    var isOnPlaceOfItsOwn: Bool {
        guard notebook == nil, !showsSpace else { return false }
        return centerTabGroups.groups.contains { ShellPlaces.descriptor(for: $0.activeTab).sidebar == nil }
    }

    /// Whether the sidebar toggle reads as shown: the sidebar it folds here is
    /// on screen. In a notebook that is the Sources column; on a place of its
    /// own, Home's sidebar beside it; elsewhere, Home's sidebar and the
    /// Space's together.
    /// `spaceSidebarHidden` is this Mac's `space.sidebarHidden`.
    func sidebarToggleReadsShown(spaceSidebarHidden: Bool) -> Bool {
        if let notebook { return !notebook.sourcesCollapsed }
        if isOnPlaceOfItsOwn { return drawsNavigationRail && homeSidebarBesidePlace }
        return drawsNavigationRail && !spaceSidebarHidden
    }

    /// The sidebar toggle pressed, from its button, ⌃⌘S or the View menu.
    /// In a notebook it folds or shows the Sources column.
    /// On a place of its own it brings Home's sidebar in beside it, or folds
    /// it, and leaves the learner's choice for Home and the Space alone.
    /// Elsewhere it folds Home's sidebar and the Space's together, never the
    /// icon strip. Returns the Space sidebar's hidden state to store in
    /// `space.sidebarHidden`, or nil when that choice stays as it is.
    func setSidebarShownFromToggle(_ shown: Bool) -> Bool? {
        // A notebook's one sidebar beside the icon strip is its Sources
        // column; folded, it leaves the window rather than leaving a second
        // strip (product owner, 2026-10-17).
        if notebook != nil {
            notebook?.sourcesCollapsed = !shown
            if !shown { notebook?.sourcesExpanded = false }
            return nil
        }
        if isOnPlaceOfItsOwn {
            if shown { setNavigationRailShown(true) }
            if homeSidebarBesidePlace != shown { homeSidebarBesidePlace = shown }
            return nil
        }
        setNavigationRailShown(shown)
        return !shown
    }

    /// Whether the Space — its lists, the Courses list drawn beside its
    /// sidebar, or the global Pages and Sites with a page open — is on one of
    /// this window's panes. A notebook's own Pages keep their list inside its
    /// columns, and a course's page has no Space sidebar.
    var showsSpace: Bool {
        guard notebook == nil else { return false }
        return centerTabGroups.groups.contains { showsSpaceSidebar(beside: $0.activeTab) }
    }

    /// Whether `tab`, in front of a pane, draws the Space's sidebar: a place
    /// the registry puts beside it (`ShellPlace.sidebar`), unless the pane is
    /// on one thing of its own that has no Space sidebar — a notebook's own
    /// Pages, or one course's page.
    private func showsSpaceSidebar(beside tab: StudioCenterTab) -> Bool {
        guard ShellPlaces.descriptor(for: tab).sidebar == .space else { return false }
        switch tab {
        case .notepad: return artifactCanvasNotebookID == nil
        case .courses: return coursePageID == nil
        default: return true
        }
    }

    /// Whether this window is on Home, the window with no place of its own:
    /// no notebook, no Space, and none of the places that have the window's
    /// card to themselves (`ShellPlace.sidebar` nil) — the Library, the
    /// Canvas, the Atlas and Memory. Chats, the Reader and the rest of what
    /// the learner opens from the Space are Home's. There is no Notebooks home
    /// page since 2026-10-09; this is only the window that shows Home's
    /// sidebar unasked (`homeSidebarBesidePlace`).
    var isOnHome: Bool {
        guard notebook == nil, !showsSpace else { return false }
        return !centerTabGroups.groups.contains { ShellPlaces.descriptor(for: $0.activeTab).sidebar == nil }
    }

    /// Whether Home's sidebar — New chat, the notebooks and the chats, as
    /// Codex's Home draws its projects — shows beside the icon rail
    /// (product owner, 2026-10-07: "similar to codex; some stuff should then be
    /// moved into home ... that is where all the notebooks are"). The rail
    /// is the 52-point icon strip everywhere; this second sidebar is Home's,
    /// as the Space's is the Space's.
    /// Beside a place of its own it shows only while the learner asked for it
    /// there (`homeSidebarBesidePlace`).
    var showsHomeSidebar: Bool {
        showsNavigationRail && (isOnHome || (homeSidebarBesidePlace && isOnPlaceOfItsOwn))
    }

    /// Transient presentation belongs to the window too. It is deliberately not
    /// included in `Snapshot`, so relaunch never restores a half-open mode.
    /// Nothing sets this since the Mac's voice conversation went (2026-10-01).
    var isVoiceWorkspacePresented = false
    /// The memory review this window is giving itself over to, if any.
    ///
    /// Today's review is fifteen minutes of retrieval, and retrieval is what
    /// goes first when something else is one click away. While this is set the
    /// window shows the review and nothing else: no navigation rail, no
    /// Sources, no other center tab. It is presentation, not layout — the rail
    /// and panel state underneath are untouched and come straight back when the
    /// review is left — and like voice it is deliberately absent from
    /// `Snapshot`, so relaunch never reopens a half-finished review as a
    /// takeover.
    ///
    /// Since 2026-10-01 the review the Memory pane's Start Review gives the
    /// window to is a card review (`MemoryCardSessionView`); a day's review
    /// chat from before cards is focused the old way only by code that still
    /// names one (docs/memory-design.md, "The card review").
    ///
    /// The rail comes back beside the review only when the learner asks with
    /// its toggle (`memoryReviewFocusShowsSidebar`); each review starts with
    /// the window to itself.
    var memoryReviewFocus: MemoryReviewFocus? {
        didSet {
            guard memoryReviewFocus?.id != oldValue?.id else { return }
            if memoryReviewFocusShowsSidebar { memoryReviewFocusShowsSidebar = false }
        }
    }
    /// Whether the learner brought the sidebar back beside the focused
    /// review (`setNavigationRailShown`). A row picked in it is the learner
    /// leaving the review, as any other surface asked for is
    /// (`memoryReviewFocusYields`).
    var memoryReviewFocusShowsSidebar = false
    /// The focused review's id: the day's chat, or the card sitting's key.
    /// Setting an id focuses that chat; nil leaves the focus.
    var memoryReviewFocusSessionID: String? {
        get { memoryReviewFocus?.id }
        set { memoryReviewFocus = newValue.map(MemoryReviewFocus.chat) }
    }
    /// The card review this window is given over to, if any.
    var memoryCardSession: MemoryCardSessionModel? {
        guard case .cards(let session) = memoryReviewFocus else { return nil }
        return session
    }

    /// Whether a request for `tab` leaves the focused review. A chat review
    /// stays for its own chat; a card review is all the window shows, so a
    /// request for any surface, Chat included, is the learner going — except
    /// the Reader a card's source opened beside it: a link followed in that
    /// Reader stays in it, as the chip promised ("without ending it").
    func memoryReviewFocusYields(to tab: StudioCenterTab) -> Bool {
        switch memoryReviewFocus {
        case .chat: return tab != .chat
        case .cards(let session): return !(tab == .reader && session.besideSourceID != nil)
        case nil: return false
        }
    }
    /// What this window's Memory pane shows: the notebooks it counts and
    /// deals, and its section. Its opener says — the rail's Memory row every
    /// notebook, a notebook's Studio Cards tile that notebook
    /// (`StudioViewModel.openMemoryPane(scope:section:in:)`, `requestCardReview(scope:)`)
    /// — and the pane's own controls change them. Presentation, like the
    /// focus: absent from `Snapshot`, so a relaunched pane starts on every
    /// notebook's review.
    var memoryPaneScope: MemoryReviewScope = .allNotebooks
    /// Think first's ask before Find directions, in the window it was asked
    /// from (`StudioViewModel.requestDirectionSearch`): "What would you try?",
    /// the search waiting on the answer or Skip. Presentation, absent from
    /// `Snapshot`.
    var pendingDirectionTake: DirectionTakeRequest?
    var memoryPaneSection: MemoryPaneSection = .review
    /// The card To Check selects and scrolls to once it lists it: the one a
    /// chat's saved cards were opened at (`openChatSavedCard`). To Check
    /// clears it when it takes it, or once it has read its cards without it.
    var memoryPaneFocusCardID: String?
    var isDockedReaderImmersive = false
    /// Whether this window's chat is showing in its own pop-out window. The
    /// rail highlights the chat's row while the chat is on screen somewhere,
    /// and the pop-out shows it even when the docked Chat tab is hidden
    /// behind the Space or a notebook.
    var isChatPoppedOut = false
    /// A cited web page being inspected before it enters the library. This is
    /// deliberately absent from `Snapshot`, so reopening the app never revives
    /// an unsaved page or implies that it was imported.
    var externalReaderPage: StudioExternalReaderPage?
    /// The pane, by `Group.id`, the learner last clicked in: where a sidebar
    /// click opens what is not open yet (`StudioCenterTabGroups.activating`).
    /// Not observed, since nothing on screen draws from it, and not in
    /// `Snapshot`: pane identities are new after a relaunch.
    @ObservationIgnored var focusedGroupID: UUID?
    /// The sources this window's readers are displaying right now. Each docked
    /// reader registers what it shows while it is mounted, so the window-wide
    /// audiobook bar can stay away while the narrated source is on screen with
    /// its own player, and appear the moment it is not
    /// (`StudioAudiobookPlayerPlacement`). Presentation, so not in `Snapshot`.
    var readerSourceIDsOnScreen: Set<String> = []
    /// The linked pages (Docs, Sites, animations) this window's panes are
    /// showing right now, by artifact id; each `LinkedDocView` registers what
    /// it shows while mounted. A walkthrough step that shows an animation on
    /// screen here points the pane at the step and draws no card of its own.
    var linkedArtifactIDsOnScreen: Set<String> = []
    #if os(macOS)
    /// The chat whose walkthrough is playing in this window: a click on a
    /// panel in the Reader answers that chat's Find it card. Its cards stay
    /// above its own transcript. Presentation, so not in `Snapshot`.
    var walkthroughDeckManager: ReviewSessionManager?
    #endif
    /// Where each Reader on screen stands in its source — "page 3 of 15",
    /// "chapter 2 of 9" — keyed by source id, as its toolbar says it. Read by
    /// the chat's `list_open_panes`, since "figure 2D" is usually on the page
    /// in front of the learner. Not observed: it changes on every page turn
    /// and no view renders from it.
    @ObservationIgnored var readerPositionsOnScreen: [String: String] = [:]
    /// The flashcard this window's Memory pane (To Check) has in front of
    /// the learner, registered by the pane while it is mounted and cleared
    /// when it goes. Every message sent from a chat beside it carries the
    /// card (`ChatContextAdditions.cardFraming`) and `list_open_panes` says
    /// it. Observed, for the chip over the chat's composer that shows it;
    /// it changes once per card dealt. Presentation, so not in `Snapshot`.
    var memoryCardOnScreen: ChatContextAdditions.CardOnScreen?
    /// Every card this window's To Check pane still has waiting, in front or
    /// not, registered by the pane while it is mounted. A chat that moved on
    /// to another card can still put a picture on one of these
    /// (`holdPicturesOnCardToCheck`). Not observed: no view renders from it.
    @ObservationIgnored var memoryCardsWaitingIDs: Set<String> = []
    /// Pictures put on a card to check from outside the pane, by card id: the
    /// chat beside it, through `update_card`, on the learner's word ("can you
    /// add it to the card?"). Like a drawn picture they are held with the card
    /// until it is decided: a Keep carries them, a Skip drops them, and nothing
    /// is written before. Presentation, so not in `Snapshot`.
    var memoryCardPictures: [String: MemoryCardPictures] = [:]

    /// The pictures held for one card: a nil face keeps the card's own.
    struct MemoryCardPictures: Equatable {
        var front: [MemoryCardImage]?
        var back: [MemoryCardImage]?
    }
    /// Where each video Reader on screen stands — the playhead, and whether
    /// the player is playing — keyed by source id, registered by the Reader
    /// while it is mounted. Every message sent beside it carries the moment
    /// (`ChatContextAdditions.VideoMoment`), and `list_open_panes` says it.
    /// Not observed: it changes every second while a video plays, and no view
    /// renders from it.
    @ObservationIgnored var videoPlayheadsOnScreen: [String: ChatOpenPanes.VideoPlayhead] = [:]
    /// The chat this window's docked Chat is showing, mirrored from the
    /// window's session store so the last-session record can name it. The
    /// store itself is view state in `StudioView`; this is only its id.
    var chatSessionID: String?
    /// The doc this window's Docs pane last showed, mirrored from the canvas
    /// while it is mounted and kept after it unmounts, so a window quit with
    /// Docs behind another tab still records the doc it would come back to.
    var openArtifactID: String?
    /// The Notebook this window's Docs canvas is scoped to — its list, and
    /// where a doc made there is filed — or nil for every doc. A notebook's
    /// own Docs scope it to the notebook (`openArtifactsBeside(notebookID:)`,
    /// and `revealArtifact` for a doc filed there); the rail's Docs row and a
    /// doc filed elsewhere clear it, and so does the notebook leaving the
    /// window (`notebook`): the Docs pane underneath and the next notebook's
    /// slot share this canvas, and must not come back on the last notebook's
    /// list. The window's, like the notebook it follows: another window's
    /// Docs keep their own list. Presentation, so not in `Snapshot`.
    var artifactCanvasNotebookID: String?
    /// Which of the Space sidebar's places this window's Space shows — All,
    /// Pages, Sites, Images, Ideas, Google Drive, Trash or one team's space —
    /// as `SpaceDestination.key` (docs/docs-design.md, "The Space"). The
    /// window's, like the notebook it holds: two windows can show two places,
    /// and the Space home and the page pane in one window share it, so the
    /// sidebar reads the same in both. Presentation, so not in `Snapshot`.
    var spaceDestinationKey = "all"
    /// What this window should show once its views exist, set by the
    /// coordinator when the app is coming back from a relaunch it asked for
    /// itself. `StudioView` consumes it: the reader source and Sources tab are
    /// applied at once, the chat is requested from the window's session
    /// store, and the doc waits in `pendingArtifactID` for the Docs canvas.
    var pendingResumeContent: StudioWindowContent?
    /// The doc the Docs canvas selects when it next appears, from a resume.
    var pendingArtifactID: String?
    /// The course whose page this window's Courses pane shows; nil shows every
    /// course (courses-design.md). It belongs to the window, like the Sources
    /// tab: two windows can be on two courses. Presentation, so not in
    /// `Snapshot`.
    var coursePageID: String?
    /// Where this window's Plugins place is: the plugins' directory, a
    /// plugin's page, the skills, a skill's page. The window's, like the
    /// course page: two windows can be on two plugins. Presentation, so not
    /// in `Snapshot`.
    var pluginsLocation: PluginsPlaceLocation = .directory
    /// The notebook this window holds; nil while it holds none. It belongs
    /// to the window: two windows can hold two notebooks, and opening one
    /// here leaves the other window's alone. While it holds one, the notebook
    /// workspace draws the window, and the library's rows a window lists
    /// mark the notebook's sources (`StudioViewModel.sidebarNotebook(in:)`).
    ///
    /// In `Snapshot` without its moments, so a relaunch reopens it. A change
    /// advances only the scene snapshot, never a template key: the most
    /// recently edited window's layout is what a new window starts from, and
    /// a new window must not start inside somebody's notebook.
    ///
    /// A notebook closing here, or another taking its place, drops a Docs
    /// scope naming one this window no longer holds
    /// (`artifactCanvasNotebookID`), so the panes underneath come back as they
    /// were and the next notebook's Docs are not the last one's.
    var notebook: NotebookWorkspace? {
        didSet {
            if notebook?.notebookID != oldValue?.notebookID,
               let scope = artifactCanvasNotebookID, scope != notebook?.notebookID {
                artifactCanvasNotebookID = nil
            }
            // The notebook leaving — for the Space, the Library, a pane
            // underneath or another notebook — is the one the window can
            // go back to.
            if let oldValue, oldValue.notebookID != notebook?.notebookID {
                notebookLeft = oldValue.persisted
            }
            if notebook?.notebookID != oldValue?.notebookID {
                StudioWindowRegistry.shared.windowNotebookDidChange(self)
            }
            guard notebook?.persisted != oldValue?.persisted else { return }
            recordSceneOnlyChange()
        }
    }

    /// The picture the chat popped out beside itself, which the notebook's
    /// document slot shows while it holds `.picture`
    /// (`StudioViewModel.dockPicture`). A moment: never in `Snapshot`, so a
    /// relaunch does not keep megabytes of figure.
    var dockedPicture: DockedChatPicture?

    /// The notebook this window last left, and how it had it arranged (its
    /// faces and folds, not its moments): opening it here again — its rail
    /// row, its card — brings its columns back as they were (decisions v5, 2: "the
    /// rail brings the notebook back"). Presentation: absent from `Snapshot`,
    /// so a relaunch opens a notebook fresh, as before.
    private(set) var notebookLeft: NotebookWorkspace? = nil

    /// The Notebook of the notebook this window holds. Setting another opens
    /// that notebook here — as the window last left it, if it was the one
    /// it left (`notebookLeft`), else fresh; setting the one already open
    /// keeps its arrangement and republishes nothing; nil closes it
    /// (`NotebookWorkspace.opening(_:over:)`).
    var NotebookID: String? {
        get { notebook?.notebookID }
        set {
            let next = newValue.map { notebookID in
                NotebookWorkspace.opening(
                    notebookID,
                    over: notebook?.notebookID == notebookID ? notebook : notebookLeft
                )
            }
            guard next != notebook else { return }
            notebook = next
        }
    }
    /// Whether the window holds a notebook whose center is the chat and one
    /// document slot, which every center-tab request then routes into
    /// (`StudioViewModel.routeIntoNotebook`). False for a window with no
    /// notebook, and for a tabbed one (`NotebookWorkspace.tabbed`), whose
    /// center is the window's own panes and takes requests as a window with
    /// no notebook does.
    var holdsNotebookSlot: Bool {
        guard let notebook else { return false }
        return !notebook.tabbed
    }

    /// The chat this window last had open in each notebook it held, by
    /// Notebook id: reopening a notebook here reopens its chat rather than
    /// starting over (`StudioViewModel.openNotebook`). Kept on the window and
    /// not in its `NotebookWorkspace`, which goes when the notebook closes;
    /// in the scene snapshot only, like the notebook, so another window or
    /// device never takes it.
    var notebookChats: [String: String] = [:] {
        didSet {
            guard notebookChats != oldValue else { return }
            recordSceneOnlyChange()
        }
    }
    /// The rows highlighted in this window's Sources list. A highlight is
    /// presentation, so it belongs to the window: two Studio windows browsing
    /// the same library select different rows, and a click in one must not grey
    /// out a row in the other. Deliberately absent from `Snapshot`, like the
    /// Reader source below.
    var sidebarSelectedSourceIDs: Set<String> = []
    /// This window's Sources panel: its tab, search text, filters, pagination,
    /// expanded groups, and the filtered-list caches that serve them. The tab a
    /// learner is browsing on one display is a view of the library, not a fact
    /// about the library, so switching to Podcasts here must not switch the
    /// window on the other monitor too. `StudioViewModel.sidebarStore` resolves
    /// to the key window's copy for imperative flows; views render their own
    /// window's copy from the environment. Not part of `Snapshot`: a relaunch
    /// starts every window on the default tab with an empty search, as before.
    let sidebarStore = StudioSidebarStore()
    /// The canvases this window opened, for ⌘[ and ⌘] and the Canvas's ‹ ›
    /// (`KnowledgeMapCanvasHistory`). Not part of `Snapshot`: a relaunch starts
    /// every window with none.
    let canvasHistory = KnowledgeMapCanvasHistory()
    /// Whether this window's Reader has a source of its own. Until it does, the
    /// window renders the app-wide selection, so navigation that only moves
    /// `selectedArticleId` still lands somewhere. Once it does — including on a
    /// deliberately empty Reader — another window's clicks no longer move it.
    private(set) var ownsReaderSelection = false
    /// The source displayed by this window's primary Reader. Selection is
    /// transient scene state: two Studio windows may read different sources,
    /// and a cross-display drop must not replace the source in its origin.
    var readerArticleID: String? {
        didSet {
            ownsReaderSelection = true
            guard !isNavigatingReaderHistory,
                  readerArticleID != oldValue,
                  let oldValue else { return }
            readerBackStack.append(oldValue)
            if readerBackStack.count > Self.readerHistoryLimit {
                let dropped = readerBackStack.count - Self.readerHistoryLimit
                readerBackStack.removeFirst(dropped)
                if let cover = readerCover { readerCover?.backDepth = max(0, cover.backDepth - dropped) }
            }
        }
    }
    /// Source navigation belongs to the Reader pane, not the global library
    /// selection. Keeping it beside `readerArticleID` preserves independent
    /// history when two Studio windows are reading on different displays.
    private(set) var readerBackStack: [String] = []

    @ObservationIgnored private var isRestoringSnapshot = false
    @ObservationIgnored private var isNavigatingReaderHistory = false
    /// Updated by the AppKit window attachment. Presentation metadata stays
    /// out of ordinary observation so moving/resizing a window never republishes
    /// the Studio view hierarchy.
    @ObservationIgnored var workspacePlacement: StudioWindowPlacement?
    @ObservationIgnored var workspaceRestoreOverridesSceneSnapshot = false
    private static let readerHistoryLimit = 50

    /// The places behind and ahead of the one this window shows, for the ‹ ›
    /// beside the traffic lights. Not part of `Snapshot`: a relaunch starts
    /// every window with none, as the Reader's history does.
    private(set) var placeHistory = StudioWindowPlaceHistory()
    /// The place the window last settled on: where the next move leaves
    /// from. Nil until it first settles.
    @ObservationIgnored private var settledPlace: StudioWindowPlace?

    /// What the window shows now, across its panes.
    var currentPlace: StudioWindowPlace {
        StudioWindowPlace(
            centerTabGroups: centerTabGroups,
            notebook: notebook,
            spaceDestinationKey: spaceDestinationKey,
            coursePageID: coursePageID,
            readerArticleID: readerArticleID,
            chatSessionID: chatSessionID,
            openArtifactID: openArtifactID,
            pluginsLocation: pluginsLocation
        )
    }

    /// Whether ‹ › can move: never while a memory review has the window,
    /// which hands the window back as it found it.
    var canGoBackInPlaces: Bool { memoryReviewFocus == nil && placeHistory.canGoBack }
    var canGoForwardInPlaces: Bool { memoryReviewFocus == nil && placeHistory.canGoForward }

    /// The window has come to rest on what it shows (`StudioView` calls this
    /// once a move has stopped changing it): a place that differs from the
    /// one it settled on before is a step the learner can go back from.
    func notePlaceSettled() {
        guard memoryReviewFocus == nil else { return }
        let now = currentPlace
        defer { self.settledPlace = now }
        guard let previous = settledPlace, previous.identity != now.identity else { return }
        placeHistory.record(leaving: previous)
    }

    /// ‹: the place before this one, its panes, notebook and places put back
    /// here. The chat and the source it showed are the caller's to reopen,
    /// through the window's session store and `selectArticle`.
    func goBackInPlaces() -> StudioWindowPlace? {
        guard memoryReviewFocus == nil else { return nil }
        notePlaceSettled()
        guard let place = placeHistory.goBack(from: currentPlace) else { return nil }
        restorePlace(place)
        return place
    }

    /// ›: the place ‹ left.
    func goForwardInPlaces() -> StudioWindowPlace? {
        guard memoryReviewFocus == nil else { return nil }
        notePlaceSettled()
        guard let place = placeHistory.goForward(from: currentPlace) else { return nil }
        restorePlace(place)
        return place
    }

    /// Puts back what the window state itself holds of `place`, and settles
    /// on it, so the chat and the source arriving after are no new step.
    private func restorePlace(_ place: StudioWindowPlace) {
        if notebook != place.notebook { notebook = place.notebook }
        if spaceDestinationKey != place.spaceDestinationKey { spaceDestinationKey = place.spaceDestinationKey }
        if coursePageID != place.coursePageID { coursePageID = place.coursePageID }
        if pluginsLocation != place.pluginsLocation { pluginsLocation = place.pluginsLocation }
        if centerTabGroups != place.centerTabGroups { centerTabGroups = place.centerTabGroups }
        if let artifactID = place.openArtifactID, openArtifactID != artifactID {
            // Both, as a resume does: the request switches a canvas already
            // on screen, the remembered doc is what one built later opens on.
            pendingArtifactID = artifactID
            openArtifactID = artifactID
        }
        settledPlace = place
    }

    init(id: UUID = UUID(), snapshot: Snapshot? = nil) {
        self.id = id

        let storedGroups = UserDefaults.standard
            .stringArray(forKey: "studio.centerTabGroups.v1")
            .flatMap(StudioCenterTabGroups.fromPersisted)
            ?? .defaultLayout
        let storedNavigation = UserDefaults.standard.object(
            forKey: Self.navigationRailVisibilityKey
        ) as? Bool ?? true

        // `didSet` does not run in an initializer, so the beta-feature rule it
        // applies is applied here to the layout a window opens with.
        let unoffered = BetaFeatures.unofferedCenterTabs
        if let snapshot {
            centerTabGroups = (StudioCenterTabGroups.fromPersisted(snapshot.centerTabGroups) ?? storedGroups)
                .withoutShowing(unoffered)
            navigationRailVisible = snapshot.navigationRailVisible
            notebook = snapshot.notebook?.persisted
            notebookChats = snapshot.notebookChats ?? [:]
        } else {
            // A brand-new window holds no notebook: the template it starts
            // from is a layout, never a notebook. The notebook it opens in
            // — the one last worked in, or the Space — is chosen when its
            // window registers (`StudioWorkspaceWindowCoordinator.register`,
            // `StudioViewModel.openNotebookOrSpaceInNewWindow`).
            centerTabGroups = storedGroups.withoutShowing(unoffered)
            navigationRailVisible = storedNavigation
        }
        readerArticleID = nil
        externalReaderPage = nil
        // Last, and deliberately: clearing the Reader above is an assignment
        // like any other, and a window that has not been navigated yet owns
        // nothing — it still follows the app-wide selection.
        ownsReaderSelection = false
    }

    /// The source this window's Reader shows, given the app-wide selection a
    /// window that has never navigated falls back to.
    func readerSourceID(fallingBackTo globalSelection: String?) -> String? {
        ownsReaderSelection ? readerArticleID : globalSelection
    }

    /// Stops this window from following the app-wide selection, keeping what it
    /// shows right now — including nothing at all. A window that already has a
    /// source of its own is left alone.
    func pinReaderSelection(to sourceID: String?) {
        guard !ownsReaderSelection else { return }
        readerArticleID = sourceID
    }

    /// Moves to the newest still-available source without recording that move
    /// as a fresh forward selection. Invalid IDs are retired as they are found,
    /// so a removed or not-yet-synced source cannot strand the Back button.
    @discardableResult
    func navigateReaderBack(where isAvailable: (String) -> Bool) -> String? {
        while let candidate = readerBackStack.popLast() {
            guard candidate != readerArticleID, isAvailable(candidate) else { continue }
            isNavigatingReaderHistory = true
            readerArticleID = candidate
            isNavigatingReaderHistory = false
            return candidate
        }
        return nil
    }

    var snapshot: Snapshot {
        Snapshot(
            centerTabGroups: centerTabGroups.persistedRepresentation,
            navigationRailVisible: navigationRailVisible,
            notebook: notebook?.persisted,
            notebookChats: notebookChats.isEmpty ? nil : notebookChats
        )
    }

    func restore(from encodedSnapshot: String) {
        guard !encodedSnapshot.isEmpty,
              let data = encodedSnapshot.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        isRestoringSnapshot = true
        centerTabGroups = StudioCenterTabGroups.fromPersisted(snapshot.centerTabGroups) ?? .defaultLayout
        navigationRailVisible = snapshot.navigationRailVisible
        notebook = snapshot.notebook?.persisted
        notebookChats = snapshot.notebookChats ?? [:]
        isRestoringSnapshot = false
        persistenceRevision &+= 1
    }

    /// Applies a saved workspace to this window only. Ordinary property writes
    /// are intentional here: they advance the scene snapshot and make the
    /// restored arrangement the template for a subsequently opened window.
    /// The notebook is the exception the template never takes: the window
    /// holds the one the record names, or none for a record without one.
    func applyWorkspaceSnapshot(_ snapshot: Snapshot) {
        centerTabGroups = StudioCenterTabGroups.fromPersisted(snapshot.centerTabGroups) ?? .defaultLayout
        navigationRailVisible = snapshot.navigationRailVisible
        notebook = snapshot.notebook?.persisted
        notebookChats = snapshot.notebookChats ?? [:]
        isVoiceWorkspacePresented = false
        memoryReviewFocus = nil
        externalReaderPage = nil
    }

    /// Takes a beta feature's pane off screen once this Mac stops showing the
    /// feature (`BetaFeatures`): the sign-up turned off here, from MCP or on
    /// another Mac. A scene-only change, like the one below, so turning a
    /// beta off does not rewrite the layout every other window starts from.
    func closeUnofferedPanes() {
        let layout = centerTabGroups.withoutShowing(BetaFeatures.unofferedCenterTabs)
        guard layout != centerTabGroups else { return }
        withoutRecordingPersistentChanges {
            centerTabGroups = layout
        }
        recordSceneOnlyChange()
    }

    /// Brings `tab` on screen the way a click does
    /// (`StudioCenterTabGroups.activating(_:)`), recorded in this window's
    /// scene snapshot alone: no template key is written. For what the app
    /// arranges in a window on its own — a brand-new window with no notebook
    /// to open showing the Space, the Space taking the place of a notebook
    /// deleted under the window — which must not become the layout every
    /// later window, here or on the other Mac, starts from.
    func activateCenterTabForThisWindowOnly(_ tab: StudioCenterTab) {
        guard !BetaFeatures.unofferedCenterTabs.contains(tab),
              let layout = centerTabGroups.activating(tab, focusedGroupID: focusedGroupID),
              layout != centerTabGroups else { return }
        withoutRecordingPersistentChanges {
            centerTabGroups = layout
        }
        recordSceneOnlyChange()
    }

    func replaceCenterTabGroupsFromDefault(_ groups: StudioCenterTabGroups) {
        // An inbound sync that agrees with what is already on screen is not a
        // change. Assigning it anyway would swap in a set of freshly parsed
        // groups whose identities are new, remounting both panes — a reader
        // page reload triggered by a preference echo.
        guard centerTabGroups != groups else { return }
        withoutRecordingPersistentChanges {
            centerTabGroups = groups
        }
    }


    func encodedSnapshot() -> String {
        guard let data = try? JSONEncoder().encode(snapshot) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func recordPersistentChange(_ updateDefault: () -> Void) {
        guard !isRestoringSnapshot else { return }
        persistenceRevision &+= 1
        // The most recently edited window becomes the template for a brand-new
        // window. Existing windows retain their own SceneStorage snapshot.
        updateDefault()
    }

    /// A change only this window's scene snapshot records: no template key
    /// is written, so no other window, new or synced, takes it.
    private func recordSceneOnlyChange() {
        guard !isRestoringSnapshot else { return }
        persistenceRevision &+= 1
    }

    private func withoutRecordingPersistentChanges(_ update: () -> Void) {
        isRestoringSnapshot = true
        update()
        isRestoringSnapshot = false
    }
}

/// Display-relative placement for one Studio window. Normalized coordinates
/// survive resolution and scaling changes; display identity/name/order provide
/// progressively weaker fallbacks when monitors are unplugged or reconnected.
struct StudioWindowPlacement: Codable, Equatable {
    /// CoreGraphics' persistent display UUID. Unlike `NSScreenNumber`, this
    /// survives ordinary display reconfiguration and disambiguates two
    /// monitors that publish the same product name. Optional so workspace
    /// records saved by older builds and Web Studio keep decoding.
    var displayUUID: String? = nil
    var displayID: String?
    var displayName: String?
    var displayIndex: Int
    var normalizedX: Double
    var normalizedY: Double
    var normalizedWidth: Double
    var normalizedHeight: Double

    /// Left-to-right, top-to-bottom across the connected displays. Workspace
    /// restore matches saved windows in this order, and so does any command
    /// that has to name the other windows to the learner — both must agree,
    /// or "Window 2" would mean a different window in each.
    var onScreenSortKey: String {
        String(
            format: "%06d:%012.6f:%012.6f",
            displayIndex,
            normalizedX,
            normalizedY
        )
    }

    /// A window whose frame has not been recorded yet sorts last.
    static func onScreenSortKey(_ placement: StudioWindowPlacement?) -> String {
        placement?.onScreenSortKey ?? "999999"
    }
}

/// What one Studio window was showing, as opposed to how it was arranged:
/// the source in its Reader, the chat in its Chat pane, the doc in Docs, and
/// the Sources tab. Recorded beside the layout when the app quits and put
/// back only after a relaunch the app started itself — an update's Restart,
/// the Full Disk Access relaunch — so the learner returns to the exact view
/// they were in. An ordinary quit still opens the layout with fresh panes,
/// which is why none of this lives in `StudioWindowState.Snapshot`.
/// One place a window showed, for the ‹ › beside the traffic lights (product
/// owner, 2026-10-12, showing Codex's top left: "can do front and back
/// arrow"): the panes and what each shows in front, the notebook and how it
/// is laid out, and the Space's place, the course, the source, the chat and
/// the page on screen. Going back puts all of it back as it was.
struct StudioWindowPlace: Equatable {
    var centerTabGroups: StudioCenterTabGroups
    var notebook: NotebookWorkspace?
    var spaceDestinationKey: String
    var coursePageID: String?
    var readerArticleID: String?
    var chatSessionID: String?
    var openArtifactID: String?
    var pluginsLocation: PluginsPlaceLocation = .directory

    /// What makes two places two to the learner: which panes are in front
    /// and what they show. A fold, a pin or what waits behind another pane
    /// is not a move, so it never becomes a step back.
    struct Identity: Equatable {
        var activeTabs: [StudioCenterTab]
        var notebookID: String?
        var notebookDocument: NotebookDocument?
        var notebookLeadingDocument: NotebookDocument?
        var notebookShowsChat = false
        var spaceDestinationKey: String?
        var coursePageID: String?
        var readerArticleID: String?
        var chatSessionID: String?
        var openArtifactID: String?
        var pluginsLocation: PluginsPlaceLocation?
    }

    var identity: Identity {
        let activeTabs = notebook == nil ? centerTabGroups.groups.map(\.activeTab) : []
        let documents = [notebook?.document, notebook?.leadingDocument].compactMap { $0 }
        let shows: (StudioCenterTab) -> Bool = { activeTabs.contains($0) }
        return Identity(
            activeTabs: activeTabs,
            notebookID: notebook?.notebookID,
            notebookDocument: notebook?.document,
            notebookLeadingDocument: notebook?.leadingDocument,
            notebookShowsChat: notebook?.showsChat ?? false,
            spaceDestinationKey: shows(.artifacts) ? spaceDestinationKey : nil,
            coursePageID: shows(.courses) ? coursePageID : nil,
            readerArticleID: shows(.reader) || documents.contains(.reader) ? readerArticleID : nil,
            chatSessionID: shows(.chat) || notebook?.showsChat == true ? chatSessionID : nil,
            openArtifactID: shows(.notepad) || documents.contains(.docs) ? openArtifactID : nil,
            pluginsLocation: shows(.plugins) ? pluginsLocation : nil
        )
    }
}

/// A window's places behind and ahead of the one it shows, as a browser keeps
/// its pages: going somewhere new drops what was ahead.
struct StudioWindowPlaceHistory: Equatable {
    private(set) var back: [StudioWindowPlace] = []
    private(set) var forward: [StudioWindowPlace] = []
    static let limit = 50

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// The window moved on from `previous` to a place of its own choosing.
    mutating func record(leaving previous: StudioWindowPlace) {
        back.append(previous)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
    }

    /// The place before `current`, skipping any that look the same to the
    /// learner; `current` waits ahead.
    mutating func goBack(from current: StudioWindowPlace) -> StudioWindowPlace? {
        while let place = back.popLast() {
            guard place.identity != current.identity else { continue }
            forward.append(current)
            return place
        }
        return nil
    }

    /// The place `goBack` left, `current` going behind again.
    mutating func goForward(from current: StudioWindowPlace) -> StudioWindowPlace? {
        while let place = forward.popLast() {
            guard place.identity != current.identity else { continue }
            back.append(current)
            return place
        }
        return nil
    }
}

struct StudioWindowContent: Codable, Equatable {
    var readerSourceID: String?
    var chatSessionID: String?
    var artifactID: String?
    var sidebarTab: String?

    var isEmpty: Bool {
        readerSourceID == nil && chatSessionID == nil && artifactID == nil
            && sidebarTab == nil
    }
}

struct StudioSavedWorkspaceWindow: Codable, Equatable {
    var snapshot: StudioWindowState.Snapshot
    var placement: StudioWindowPlacement?
    /// Absent in records saved by older builds and in named workspaces, which
    /// describe an arrangement rather than a moment.
    var content: StudioWindowContent? = nil

    init(
        snapshot: StudioWindowState.Snapshot,
        placement: StudioWindowPlacement?,
        content: StudioWindowContent? = nil
    ) {
        self.snapshot = snapshot
        self.placement = placement
        self.content = content
    }

    /// The same window with only its arrangement, for stores that must not
    /// carry what was open.
    var withoutContent: StudioSavedWorkspaceWindow {
        StudioSavedWorkspaceWindow(snapshot: snapshot, placement: placement)
    }
}

/// The windows that were open when the app last quit, so relaunching puts them
/// back rather than opening one empty Studio.
///
/// Deliberately local, and deliberately not a `SyncedStorage` row: this records
/// window frames and which panes sat in them, which belong to one Mac and one
/// display arrangement. Syncing it would drag a laptop's two-window layout onto
/// a desk with a different screen, and would fight the other Mac's own last
/// session every time either one quit. Named workspaces are the synced concept;
/// this is the unnamed one that only means something here.
enum StudioLastSessionStore {
    static let preferenceKey = "studio.lastSessionWindows"

    /// More Studio windows than anyone arranges by hand. The store is capped
    /// here, and the coordinator closes live windows past it, because a saved
    /// session that has grown beyond this is a bug's output, not a workspace:
    /// on 2026-09-03 a Dev library was relaunching into 269 cascaded copies of
    /// two windows, because each launch reopened the saved count on top of the
    /// windows SwiftUI had already restored and the quit then saved the sum.
    /// The cap was twelve; on 2026-09-06 a Dev library quit with seven windows
    /// that verification runs had opened, and every one of the 31 launches the
    /// next morning put six Studio windows back, all of them under the cap.
    /// Four is one or two windows on each of two displays; anything past that
    /// is left over from something that opened windows, not an arrangement.
    static let maximumWindows = 4

    /// `FOREVERLM_LAST_SESSION=0` in the environment turns the whole record
    /// off for that process: nothing is put back at launch and nothing is
    /// saved at quit. For launches that are not the learner's — a build script
    /// or a driver opening the Dev app to look at one change — whose windows
    /// would otherwise become the arrangement the next launch restores.
    static let environmentKey = "FOREVERLM_LAST_SESSION"

    static func isDisabled(by environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return ["0", "off", "no", "false"].contains(value)
    }

    static func save(_ windows: [StudioSavedWorkspaceWindow]) {
        let windows = normalized(windows)
        guard !windows.isEmpty, let data = try? JSONEncoder().encode(windows) else {
            clear()
            return
        }
        UserDefaults.standard.set(data, forKey: preferenceKey)
    }

    static func load() -> [StudioSavedWorkspaceWindow] {
        guard let data = UserDefaults.standard.data(forKey: preferenceKey),
              let windows = try? JSONDecoder().decode([StudioSavedWorkspaceWindow].self, from: data)
        else { return [] }
        return normalized(windows)
    }

    /// Drops exact copies and caps the count. Two records with the same panes
    /// on the same frame describe one window sitting on top of itself, which
    /// is what an inflated session is made of; keeping the first of each and
    /// at most `maximumWindows` lets a library that already saved hundreds
    /// come back as a workable set, and the next quit saves that set.
    static func normalized(_ windows: [StudioSavedWorkspaceWindow]) -> [StudioSavedWorkspaceWindow] {
        var distinct: [StudioSavedWorkspaceWindow] = []
        for window in windows where !distinct.contains(window) {
            distinct.append(window)
            if distinct.count == maximumWindows { break }
        }
        return distinct
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: preferenceKey)
    }

    /// Set when the app is about to quit for a relaunch it started itself, so
    /// the next launch knows to put the saved content back and not only the
    /// layout. Read once and cleared: a launch after that is an ordinary one.
    static let resumeContentKey = "studio.lastSessionResumesContent"

    static func requestContentResume() {
        UserDefaults.standard.set(true, forKey: resumeContentKey)
    }

    static func consumeContentResumeRequest() -> Bool {
        let requested = UserDefaults.standard.bool(forKey: resumeContentKey)
        UserDefaults.standard.removeObject(forKey: resumeContentKey)
        return requested
    }
}

/// A named, synced whole-app workspace arrangement. Each view occupies its own
/// preference row so independently saved notebooks cannot overwrite one another.
struct StudioSavedWorkspaceView: Identifiable, Equatable {
    static let preferenceKeyPrefix = "studio.workspaceView."

    let id: String
    var name: String
    var createdAt: Double
    var windows: [StudioSavedWorkspaceWindow]

    var preferenceKey: String { Self.preferenceKeyPrefix + id }
    var snapshot: StudioWindowState.Snapshot { windows[0].snapshot }

    var propertyList: [String] {
        let encoder = JSONEncoder()
        return ["v2", name, String(createdAt)] + windows.compactMap { window in
            guard let data = try? encoder.encode(window) else { return nil }
            return "window:" + data.base64EncodedString()
        }
    }

    init(id: String, name: String, createdAt: Double, snapshot: StudioWindowState.Snapshot) {
        self.init(
            id: id,
            name: name,
            createdAt: createdAt,
            windows: [.init(snapshot: snapshot, placement: nil)]
        )
    }

    init(
        id: String,
        name: String,
        createdAt: Double,
        windows: [StudioSavedWorkspaceWindow]
    ) {
        precondition(!windows.isEmpty)
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.windows = windows
    }

    init?(preferenceKey: String, value: Any) {
        guard preferenceKey.hasPrefix(Self.preferenceKeyPrefix),
              let values = value as? [String],
              let version = values.first,
              ["v1", "v2"].contains(version),
              values.count >= 3 else {
            return nil
        }
        let name = values[1]
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let keyID = String(preferenceKey.dropFirst(Self.preferenceKeyPrefix.count))
        id = keyID
        self.name = name
        createdAt = Double(values[2]) ?? 0
        if version == "v2" {
            let decoder = JSONDecoder()
            windows = values.compactMap { value in
                guard value.hasPrefix("window:"),
                      let data = Data(base64Encoded: String(value.dropFirst("window:".count))) else {
                    return nil
                }
                return try? decoder.decode(StudioSavedWorkspaceWindow.self, from: data)
            }
            guard !windows.isEmpty else { return nil }
        } else {
            guard let navigation = values.first(where: { $0.hasPrefix("navigation:") }) else {
                return nil
            }
            windows = [.init(
                snapshot: StudioWindowState.Snapshot(
                    centerTabGroups: values.compactMap {
                        $0.hasPrefix("group:") ? String($0.dropFirst("group:".count)) : nil
                    },
                    navigationRailVisible: navigation == "navigation:1"
                ),
                placement: nil
            )]
        }
    }
}

@Observable
@MainActor
final class StudioWorkspaceViewStore {
    static let shared = StudioWorkspaceViewStore()

    private(set) var views: [StudioSavedWorkspaceView] = []
    @ObservationIgnored private var remoteObserver: NSObjectProtocol?

    private init() {
        reload()
        remoteObserver = NotificationCenter.default.addObserver(
            forName: PreferenceStore.didChangeRemotely,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let changed = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String> ?? []
            guard changed.contains(where: {
                $0.hasPrefix(StudioSavedWorkspaceView.preferenceKeyPrefix)
            }) else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        views = UserDefaults.standard.dictionaryRepresentation()
            .compactMap { key, value in
                StudioSavedWorkspaceView(preferenceKey: key, value: value)
            }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.createdAt < $1.createdAt
            }
    }

    @discardableResult
    func save(name rawName: String, snapshot: StudioWindowState.Snapshot) -> Bool {
        save(
            name: rawName,
            windows: [.init(snapshot: snapshot, placement: nil)]
        )
    }

    @discardableResult
    func save(name rawName: String, windows: [StudioSavedWorkspaceWindow]) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !windows.isEmpty else { return false }
        let existing = views.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        let saved = StudioSavedWorkspaceView(
            id: existing?.id ?? UUID().uuidString,
            name: name,
            createdAt: existing?.createdAt ?? Date().timeIntervalSince1970,
            windows: windows
        )
        PreferenceStore.set(saved.propertyList, forKey: saved.preferenceKey)
        reload()
        return true
    }

    /// Renames a workspace in place, keeping its identity, creation order,
    /// and windows. Unlike `save(name:windows:)`, which matches by name and
    /// would mint a second workspace under the new name, this edits the one
    /// row. Refuses an empty name and a name another workspace already holds,
    /// so two menu items never read the same.
    @discardableResult
    func rename(_ view: StudioSavedWorkspaceView, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        if name == view.name { return true }
        let taken = views.contains {
            $0.id != view.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !taken else { return false }
        var renamed = view
        renamed.name = name
        PreferenceStore.set(renamed.propertyList, forKey: renamed.preferenceKey)
        reload()
        return true
    }

    func delete(_ view: StudioSavedWorkspaceView) {
        PreferenceStore.remove(forKey: view.preferenceKey)
        reload()
    }
}

/// Routes legacy `StudioViewModel` navigation helpers to the key Studio window.
/// Views render from their own `StudioWindowState`; this registry is only the
/// imperative bridge for commands and workflows that predate multi-window state.
@Observable
@MainActor
final class StudioWindowRegistry {
    static let shared = StudioWindowRegistry()

    private(set) var activeState: StudioWindowState?
    @ObservationIgnored private var registeredStates: [UUID: StudioWindowState] = [:]
    /// True while one of the app's own windows that is not a Studio window — a
    /// popped-out Reader — is key. `activeState` still names the Studio window
    /// used last, which is where a request made in that window lands; this
    /// flag is what tells the chat router the request was not made there, so
    /// it can say where the chat went. Not observed: it flips on every focus
    /// change and no view renders from it.
    @ObservationIgnored private(set) var detachedWindowIsKey = false

    /// The windows' ids in the order they registered, for `get_app_context`.
    @ObservationIgnored private var registrationOrder: [UUID] = []

    private init() {}

    var states: [StudioWindowState] {
        Array(registeredStates.values)
    }

    func register(_ state: StudioWindowState, makeActive: Bool = false) {
        registeredStates[state.id] = state
        if !registrationOrder.contains(state.id) { registrationOrder.append(state.id) }
        if makeActive || activeState == nil {
            activeState = state
        }
        publishWindowNotebooks()
    }

    func activate(_ state: StudioWindowState) {
        registeredStates[state.id] = state
        if !registrationOrder.contains(state.id) { registrationOrder.append(state.id) }
        detachedWindowIsKey = false
        if activeState !== state {
            activeState = state
        }
        publishWindowNotebooks()
    }

    /// A registered window opened, left or swapped its notebook
    /// (`StudioWindowState.notebook`).
    func windowNotebookDidChange(_ state: StudioWindowState) {
        guard registeredStates[state.id] === state else { return }
        publishWindowNotebooks()
    }

    /// Tells MCP which notebook each window holds and which window is
    /// frontmost (`MCPAppWindows`, read by `get_app_context` alone).
    private func publishWindowNotebooks() {
        let windows = registrationOrder.compactMap { registeredStates[$0] }
        MCPAppWindows.publish(MCPAppWindows.ordered(
            notebookIDs: windows.map(\.NotebookID),
            frontmost: windows.firstIndex { $0 === activeState }
        ))
    }

    /// A window that stands for a Studio window became key — the chat popped
    /// out of it. Acting there is acting in that window, so it becomes the one
    /// requests route to; a window that has since closed is left closed rather
    /// than resurrected by its pop-out.
    func activateIfRegistered(_ state: StudioWindowState) {
        guard registeredStates[state.id] != nil else { return }
        activate(state)
    }

    func noteDetachedWindowIsKey(_ isKey: Bool) {
        detachedWindowIsKey = isKey
    }

    func unregister(_ state: StudioWindowState) {
        registeredStates.removeValue(forKey: state.id)
        registrationOrder.removeAll { $0 == state.id }
        if activeState === state {
            activeState = registeredStates.values.first
        }
        publishWindowNotebooks()
    }
}

/// A button on the Studio status banner besides Undo: `title` is its label,
/// and `run` receives the Studio window whose banner was pressed — the same
/// message shows in every window at once, so "here" is decided by the click,
/// not by the request. Nil when the banner sits on a window that is no Studio
/// window (a popped-out Reader), which has no panes to open anything in.
struct StudioToastAction {
    let title: String
    let run: @MainActor (StudioWindowState?) async -> Void

    /// "Open here" for a notice that names another window.
    static func openHere(_ run: @escaping @MainActor (StudioWindowState) async -> Void) -> StudioToastAction {
        StudioToastAction(title: "Open here") { window in
            guard let window else { return }
            await run(window)
        }
    }
}

enum ReviewChatPanelMode: String, CaseIterable, Codable, Hashable {
    case chat
    case sessions

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .sessions: return "Sessions"
        }
    }
}

/// How the learner wants to pay for or connect their AI tutor.
enum AIBillingMode: String, CaseIterable, Codable, Hashable, Identifiable {
    /// Use an existing chat subscription (Claude, ChatGPT, Gemini, Grok) via MCP.
    /// No per-use API charges — usually the cheapest option.
    case subscription
    /// Use the in-app Chat panel powered by ForeverLM AI, paying the
    /// provider per use.
    case api

    /// Persisted under this key in `UserDefaults` / `@AppStorage`.
    static let defaultsKey = "studio.aiBillingMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscription: return "Use my own AI subscription"
        case .api: return "Pay with the API as you go"
        }
    }
}

// MARK: - Sidebar Tab

enum StudioSidebarTab: String, CaseIterable, Codable {
    case articles = "Articles"
    case papers = "Papers"
    case books = "Books"
    case meetings = "Meetings"
    case podcasts = "Podcasts"
    case videos = "YouTube"
    case xPosts = "X"

    static let knowledgeExclusionPreferenceKey = "studio.excludedKnowledgeSourceTabs"

    /// Restores tabs saved before the Videos → YouTube rename, and before the
    /// Google Drive, Read AI and Zoom tabs were folded back into one Meetings
    /// tab. "Courses" names no tab since courses moved to their own pane
    /// (courses-design.md), so a stored order or hidden set drops it.
    ///
    /// All three provider raw values resolve to `.meetings`, and so does the
    /// pre-split "Meetings" value — which the split itself stranded, since
    /// nothing answered to that name while the two tabs existed. A saved order
    /// naming several providers therefore yields `.meetings` more than once;
    /// `reconciledOrder` de-duplicates, and every other reader is a `Set`.
    static func fromPersistedRawValue(_ raw: String) -> StudioSidebarTab? {
        if raw == "Videos" { return .videos }
        if raw == "Google Drive" || raw == "Read AI" || raw == "Zoom" { return .meetings }
        return StudioSidebarTab(rawValue: raw)
    }

    /// The source family that owns a record for library-wide search and AI discovery.
    /// This is intentionally independent of whether that family's tab is pinned.
    /// Course material — a generated lesson, a course's own PDF — belongs to no
    /// family: it has no tab, lives on its course's page, and is searched with
    /// the rest of the library (courses-design.md).
    static func knowledgeTab(
        sourceType: StudioSourceType,
        url: String
    ) -> StudioSidebarTab? {
        switch sourceType {
        case .article, .manual, .unclassified: return .articles
        case .paper: return .papers
        case .book: return .books
        case .course: return nil
        case .meeting: return .meetings
        case .podcast: return .podcasts
        case .video:
            // A Zoom recording is stored as a meeting from ingest onward, so
            // this arm is for one synced from a build that still typed it a
            // video: route it to the family it belongs to rather than to
            // YouTube, where nothing would ever show it.
            return ZoomRecordingService.isZoomRecordingURL(url) ? .meetings : .videos
        case .xPost: return .xPosts
        }
    }


    static func knowledgeTab(for article: StudioArticle) -> StudioSidebarTab? {
        knowledgeTab(sourceType: article.sourceType, url: article.url)
    }

    static func excludedKnowledgeTabs(in defaults: UserDefaults = .standard) -> Set<StudioSidebarTab> {
        Set(
            (defaults.stringArray(forKey: knowledgeExclusionPreferenceKey) ?? [])
                .compactMap { fromPersistedRawValue($0) }
        )
    }

    /// Completes a persisted tab order so it names every case exactly once.
    ///
    /// A saved order is a preference about *arrangement*, never about
    /// membership — hiding a tab is `hiddenTabs`, which is stored separately. So
    /// any case missing from the persisted array is appended rather than
    /// dropped: that heals orders written by an older build (or delivered by a
    /// partial sync) instead of letting them silently delete tabs. Meetings
    /// slots in right after Books rather than trailing at the very end for
    /// users upgrading from before that tab existed.
    ///
    /// Must be applied at *every* assignment to the stored order, not just at
    /// load: adopting a short array verbatim persists it through `didSet` and
    /// makes the truncation permanent.
    static func reconciledOrder(_ persisted: [StudioSidebarTab]) -> [StudioSidebarTab] {
        var ordered = persisted.reduce(into: [StudioSidebarTab]()) { result, tab in
            if !result.contains(tab) { result.append(tab) }
        }
        for tab in StudioSidebarTab.allCases where !ordered.contains(tab) {
            if tab == .meetings, let anchorIndex = ordered.firstIndex(of: .books) {
                ordered.insert(tab, at: anchorIndex + 1)
            } else {
                ordered.append(tab)
            }
        }
        return ordered
    }

    /// Tabs fed wholly from outside the app by a plugin, rather than by
    /// the learner's own ingestion on this Mac. None today: Slack was the last
    /// such tab, and it went away with saved Slack threads — Slack is read live
    /// through the plugin and files nothing. Meetings is deliberately not one
    /// even though Read AI and Zoom feed it: it is a source *family* with
    /// several providers behind it, so Settings draws their branded cards from
    /// `MeetingProvider.isPlugin` instead. The rule stays because the pin
    /// logic and Settings are written against it, so the next plugin-fed tab
    /// only has to answer here.
    var isPluginBacked: Bool { false }

    /// Tabs whose sources can only arrive once the learner sets something up:
    /// an account sign-in (Google Drive behind Meetings, X) or a registered
    /// ingest plugin (Read AI and Zoom behind Meetings). Studio keeps these
    /// off a new library's tab bar until there is evidence the integration is in
    /// use — a brand-new Studio showing a Meetings tab reads as "that app is
    /// connected" to someone who has connected nothing.
    ///
    /// Podcasts and YouTube are deliberately absent: both ingest from this Mac
    /// and both are steps in Getting Started, so their tabs are part of the
    /// first-run surface rather than a claim about a connected account.
    var requiresIntegrationSetup: Bool {
        switch self {
        case .meetings, .xPosts: return true
        default: return false
        }
    }

    /// Names the integration tabs whose one-time unpin has already run, so no
    /// tab is unpinned twice. Synced: a rebuild lands in a fresh preferences
    /// container, and a marker that does not survive that turns a one-time
    /// default into one the learner has to override after every build.
    static let integrationUnpinAppliedPreferenceKey = "studio.integrationTabUnpinDefaultsApplied"

    /// Names the integration tabs Studio unpinned on its own and the learner
    /// has not touched since — the only tabs eligible to be pinned back when
    /// the integration turns out to be in use. Synced for the same reason: it
    /// says which of the unpinned tabs are still Studio's call.
    static let autoUnpinnedIntegrationTabsPreferenceKey = "studio.integrationTabsUnpinnedByDefault"

    /// Plural noun for use mid-sentence ("Search 12 articles", "Refresh YouTube videos").
    /// Brand names keep their casing instead of being lowercased.
    var itemNoun: String {
        switch self {
        case .videos: return "videos from YouTube"
        case .xPosts: return "X posts"
        default: return rawValue.lowercased()
        }
    }

    var icon: String {
        switch self {
        case .articles: return "doc.richtext"
        case .papers: return "doc.text.magnifyingglass"
        case .books: return "book.closed"
        case .meetings: return "person.2.wave.2"
        case .podcasts: return "headphones"
        case .videos: return "play.rectangle"
        case .xPosts: return "" // uses custom XLogoShape instead
        }
    }

    /// Full-color icon asset, rendered in place of the SF Symbol when present.
    /// Plugin tabs use their brand logos; the local source-type tabs use
    /// solid rounded-square badges drawn in the same idiom so the tab bar and
    /// Settings lists read as one family. X stays a bare monochrome logo by
    /// brand convention, so it is the lone custom-shape holdout.
    ///
    /// Meetings takes the family badge rather than any one provider's mark —
    /// the Google Drive, Read AI and Zoom logos moved onto the rows, where they
    /// say which provider a given series or session came from.
    var iconAsset: String? {
        switch self {
        case .articles: return "ArticlesIcon"
        case .papers: return "PapersIcon"
        case .books: return "BooksIcon"
        case .meetings: return "MeetingsIcon"
        case .videos: return "YouTubeIcon"
        case .podcasts: return "ApplePodcastsIcon"
        case .xPosts: return nil
        }
    }

    var color: Color {
        switch self {
        case .articles: return .blue
        case .papers: return .teal
        case .books: return .orange
        case .meetings: return .teal
        case .podcasts: return .purple
        case .videos: return .red
        case .xPosts: return .primary
        }
    }

    /// Tabs that render their items inside collapsible groups (book chapters,
    /// meeting series, video playlists). These paginate by group, not by
    /// individual item, so their sections stay coherent.
    var isGrouped: Bool {
        switch self {
        case .books, .meetings, .videos: return true
        default: return false
        }
    }

    /// The source type that articles in this tab have.
    var sourceType: StudioSourceType? {
        switch self {
        case .articles: return .article
        case .papers:   return .paper
        case .books:    return .book
        case .meetings: return .meeting
        case .podcasts: return .podcast
        case .videos:   return .video
        case .xPosts:   return .xPost
        }
    }
}

// MARK: - X Logo

/// The X (formerly Twitter) logo drawn as a SwiftUI Shape using the official brand path.
struct XLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Official X logo path, original viewBox: 0 0 1200 1227
        let svgWidth: CGFloat = 1200
        let svgHeight: CGFloat = 1227
        let scale = min(rect.width / svgWidth, rect.height / svgHeight)
        let offsetX = rect.minX + (rect.width - svgWidth * scale) / 2
        let offsetY = rect.minY + (rect.height - svgHeight * scale) / 2

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }

        var p = Path()

        // Outer shape
        p.move(to: pt(714.163, 519.284))
        p.addLine(to: pt(1160.89, 0))
        p.addLine(to: pt(1055.03, 0))
        p.addLine(to: pt(667.137, 450.887))
        p.addLine(to: pt(357.328, 0))
        p.addLine(to: pt(0, 0))
        p.addLine(to: pt(468.492, 681.821))
        p.addLine(to: pt(0, 1226.37))
        p.addLine(to: pt(105.866, 1226.37))
        p.addLine(to: pt(515.491, 750.218))
        p.addLine(to: pt(842.672, 1226.37))
        p.addLine(to: pt(1200, 1226.37))
        p.addLine(to: pt(714.137, 519.284))
        p.closeSubpath()

        // Inner cutout (rendered with even-odd fill rule)
        p.move(to: pt(569.165, 687.828))
        p.addLine(to: pt(521.697, 619.934))
        p.addLine(to: pt(144.011, 79.6944))
        p.addLine(to: pt(306.615, 79.6944))
        p.addLine(to: pt(611.412, 515.685))
        p.addLine(to: pt(658.88, 583.579))
        p.addLine(to: pt(1055.08, 1150.3))
        p.addLine(to: pt(892.476, 1150.3))
        p.closeSubpath()

        return p
    }
}

// MARK: - Meeting plugin notice

/// The Meetings tab's one-line notice that a meeting plugin has gone quiet,
/// and the single action that goes with it.
///
/// Two different situations used to share one "disconnected — reconnect" line
/// and one Reconnect button that opened the generic Build Your Own page, which
/// listed no plugins and never mentioned the provider. They need different
/// words and different actions. When no plugin exists for meetings that only
/// a plugin can bring in, the useful thing to hand over is the setup prompt
/// itself, filled in for that provider. When a plugin exists and has
/// reported trouble, the useful thing is what it reported.
struct MeetingPluginNotice: Equatable {
    /// A registered ingest plugin as the notice sees it: its name, and why
    /// it needs attention — nil while it is healthy.
    struct Plugin: Equatable {
        let name: String
        let trouble: String?
    }

    enum Action: Equatable {
        /// No plugin is registered for this provider, yet its meetings are
        /// in the library, so one ran once: copy the setup prompt filled in for
        /// it, asking the user's assistant to find and reconnect that plugin
        /// and to build one only if none is left.
        case copySetupPrompt
        /// No plugin exists and MCP isn't set up either, so there is no
        /// address to put in a prompt. The Build Your Own page explains the
        /// model and offers Set Up MCP.
        case openBuildYourOwn
        /// A plugin exists and reported trouble; the Plugins place lists
        /// what it said.
        case showPluginStatus
    }

    let provider: MeetingProvider
    let message: String
    let actionTitle: String
    let action: Action

    /// - Parameters:
    ///   - providersInUse: providers the library has meetings from.
    ///   - expectsSync: whether meetings from a provider can only keep arriving
    ///     through a plugin — Read AI always; Zoom only once a plugin has
    ///     pushed some, since a Zoom link can also be added by hand.
    ///   - plugins: every registered ingest plugin.
    ///   - hasMCPAddress: whether MCP is set up, so a prompt can be filled in.
    static func resolve(
        providersInUse: [MeetingProvider],
        expectsSync: (MeetingProvider) -> Bool,
        plugins: [Plugin],
        hasMCPAddress: Bool
    ) -> MeetingPluginNotice? {
        for provider in providersInUse where provider.isPlugin && expectsSync(provider) {
            let claiming = plugins.filter { provider.matches(connectorLabel: $0.name) }
            if claiming.isEmpty {
                return MeetingPluginNotice(
                    provider: provider,
                    message: "\(provider.displayName) meetings aren't syncing — get the plugin going again for the latest",
                    actionTitle: hasMCPAddress ? "Copy Setup Prompt" : "Set Up…",
                    action: hasMCPAddress ? .copySetupPrompt : .openBuildYourOwn
                )
            }
            // One healthy plugin for the provider is enough; an abandoned
            // second registration for it is not worth a banner.
            if claiming.contains(where: { $0.trouble == nil }) { continue }
            guard let troubled = claiming.first, let trouble = troubled.trouble else { continue }
            return MeetingPluginNotice(
                provider: provider,
                message: "\(troubled.name) \(trouble)",
                actionTitle: "Details",
                action: .showPluginStatus
            )
        }
        return nil
    }
}
