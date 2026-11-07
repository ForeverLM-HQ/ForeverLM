import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A rail row above the notebooks the learner may take off the rail: New
/// chat, Memory, Browser, Library and the Space. Memory is one row like
/// the others since 2026-09-22 (the product owner: it "just needs to be part of that
/// list"), not a row of its own over the notebooks. The Notebooks header,
/// the chats and the footer are the rail's skeleton and stay.
///
/// Rows that left, each falling out of the stored hidden set as a name this
/// build does not know (`StudioRailHiddenItems.init(storage:)`):
///
/// - Docs, Sites, Videos and Animations (`docs`, `sites`, `videos`,
///   `animations`) went under one Artifacts row on 2026-09-17 (the product owner: "we
///   should just have an 'artifacts' page in the left sidebar") and off the
///   rail on 2026-09-20, as the Artifacts index's kind chips (since
///   2026-10-06 only Docs and Sites are chips, on the Space's tab; the rest
///   are listed in their notebook's Studio).
/// - Planner (`planner`) left on 2026-09-28 and the app on 2026-09-30: the
///   Now chip in the footer shows the day, which is the Mac's Calendar.
/// - Goals and Ideas (`goals`, `ideas`) became Artifacts chips on 2026-09-29
///   (the product owner: "maybe ideas and goals should live under artifacts").
/// - Activity, Courses and Artifacts (`activity`, `courses`, `artifacts`)
///   left with shell stage 4 (2026-10-01; docs/notebooks-design.md, "The
///   rail"): the rail leads with the notebooks, where the learner works.
///   Activity is reached from the menu bar's Today menu and the Now chip's
///   popover; the courses (a course lives in no notebook; 2026-10-03) are
///   the Space's Courses row, and the Goals (2026-10-06) the Space's tab.
/// - Home (`notebooks`) left on 2026-10-09, when the Notebooks home went
///   ("it doesn't add anything"): the Space is the rail's first row, and its
///   All lists every notebook and course. A stored hidden set naming it drops
///   the name like the rows above.
/// - Canvas (`knowledgeMap`) left on 2026-10-07, when canvases became items
///   in the Space (the product owner: "canvases should be within spaces; just like
///   sites, pages, etc"): each opens from the Space's Canvases, its Recents
///   or its Pinned, as a page does (docs/knowledge-map-design.md).
enum StudioRailItem: String, CaseIterable, Identifiable {
    /// Home (2026-10-16), Codex's first icon, and the strip's + before it
    /// (product owner, 2026-10-16: "the home button should just replace that
    /// + button; and it should show what's currently shown under that +
    /// button"): a blank chat with Home's sidebar beside it, New chat, the
    /// notebooks and every chat. An action that takes the window home, not a
    /// pane of its own.
    case home
    case newChat
    case memory
    /// The Space (2026-10-07): the Pages home, ChatGPT's Space with its own
    /// sidebar. The row was Daily Notes (2026-10-06, docs/notes-graph-design.md)
    /// until the rail became Codex's icon rail; today's note is one page in
    /// the Space, and ⇧⌘D still opens it.
    case space
    /// The web itself, in tabs. Inside a notebook it opens in the document
    /// slot; Discover lives in Add sources.
    case browser
    /// The full-window Library (2026-10-01, decisions v5, 2): the whole
    /// library, every kind, laid out for managing it.
    case library
    /// Plugins (2026-10-13), Codex's grid: every plugin and its state, and
    /// each plugin's page (docs/codex-shell-plan.md, Track 2).
    case plugins
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .newChat: return "New chat"
        case .memory: return "Memory"
        case .space: return "Spaces"
        case .browser: return "Browser"
        case .library: return "Library"
        case .plugins: return ShellPlaces.descriptor(for: .plugins).title
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .newChat: return "square.and.pencil"
        case .memory: return MemoryReviewSession.sidebarIcon
        case .space: return "square.on.square"
        case .browser: return "safari"
        case .library: return "books.vertical"
        case .plugins: return ShellPlaces.descriptor(for: .plugins).glyph
        }
    }
}

/// Which rail rows the learner has hidden. Follows the account, like
/// `studio.hiddenTabs` and `studio.pinnedNotebooks.v1`: hiding a row is tidying
/// work, and the learner who did it on one Mac meant it about their sidebar,
/// not about that Mac (product owner, 2026-09-14: "please make sure it all behaves
/// the same way"). Every row is shown until the learner hides it, and a hidden
/// row comes back from the Show in Sidebar submenu on any remaining row's menu
/// — the Notebooks header's included, so the way back never disappears with the
/// rows.
struct StudioRailHiddenItems: Equatable {
    static let storageKey = "studio.navigation.hiddenItems.v1"

    var items: Set<StudioRailItem>

    init(_ items: Set<StudioRailItem> = []) {
        self.items = items
    }

    /// Decodes the comma-separated raw values `@AppStorage` holds. A name this
    /// build does not know — a row a later build added, then removed, or a row
    /// that retired (`StudioRailItem`'s list) — is dropped rather than kept as a
    /// phantom, and leaves the stored value with the learner's next change.
    init(storage: String) {
        items = Set(
            storage.split(separator: ",")
                .compactMap { StudioRailItem(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
        )
    }

    /// Sorted so equal sets encode identically.
    var storage: String {
        items.map(\.rawValue).sorted().joined(separator: ",")
    }

    func contains(_ item: StudioRailItem) -> Bool { items.contains(item) }

    func toggling(_ item: StudioRailItem) -> StudioRailHiddenItems {
        var copy = self
        if copy.items.contains(item) { copy.items.remove(item) } else { copy.items.insert(item) }
        return copy
    }

    func setting(_ item: StudioRailItem, hidden: Bool) -> StudioRailHiddenItems {
        var copy = self
        if hidden { copy.items.insert(item) } else { copy.items.remove(item) }
        return copy
    }

    /// The rows still shown at the top of the rail, in rail order.
    var visibleTopItems: [StudioRailItem] {
        [.home, .newChat, .memory, .space, .browser, .library, .plugins].filter { !items.contains($0) }
    }

    /// The icon rail's rows, Codex's: Home, then Spaces, Memory, Library and
    /// Plugins, in that order, less any the learner hid. The Space led the
    /// places since the Notebooks home, which led until 2026-10-09, went; a
    /// + for a new chat led them from 2026-10-13 until Home took its place
    /// (2026-10-16), and Plugins came out of Settings under the Library on
    /// 2026-10-13. New chat is Home's sidebar's row alone.
    static let railOrder: [StudioRailItem] = [.home, .space, .memory, .library, .plugins]

    /// The rows at the top of Home's sidebar: New chat and the Browser.
    static let sidebarOrder: [StudioRailItem] = [.newChat, .browser]

    func railItems() -> [StudioRailItem] {
        Self.railOrder.filter { !items.contains($0) }
    }

    func sidebarItems() -> [StudioRailItem] {
        Self.sidebarOrder.filter { !items.contains($0) }
    }
}

/// A place the learner keeps on the icon strip, under its line, as Codex
/// keeps the rows pinned to its strip (product owner, 2026-10-12: "the left
/// sidebar never gets collapsed basically so there can be some shortcuts
/// there similar to codex app"). The strip's own rows — Spaces, Memory,
/// Library — stay above the ⋯, which offers every other place and keeps one
/// here; a shortcut is one of those places, one click away from anywhere.
enum StudioRailShortcut: Hashable, Identifiable, Sendable {
    /// One of the Space sidebar's places: Notebooks, Board, Pages, Sites, Canvases,
    /// Images or Google Drive.
    case place(SpaceDestination)
    /// The Courses list, the Space sidebar's hub.
    case courses

    var id: String { key }

    /// The Space places a shortcut can be. All is the Space itself (its
    /// row), Trash is a place to visit rarely, and a team's, a space's or a
    /// list's place is an item the Space sidebar pins.
    private static let places: Set<SpaceDestination> = [.notebooks, .board, .plan, .pages, .sites, .canvases, .images, .drive]

    /// Every shortcut this Mac offers, in the Space sidebar's order:
    /// Notebooks, Courses, then the rest; Canvases only where canvases are
    /// listed.
    static func offered(listsCanvases: Bool) -> [StudioRailShortcut] {
        let sidebar = SpaceDestination.sidebarPlaces(listsCanvases: listsCanvases).filter(places.contains)
        let leading = sidebar.filter { $0 == .notebooks }
        let rest = sidebar.filter { $0 != .notebooks }
        return leading.map(Self.place) + [.courses] + rest.map(Self.place)
    }

    /// How the strip stores it: the place's `SpaceDestination.key`, or
    /// `courses`.
    var key: String {
        switch self {
        case .place(let place): return place.key
        case .courses: return "courses"
        }
    }

    /// Nil for a key that names no shortcut — one a later build added, or a
    /// place that is no shortcut — so the strip drops it rather than drawing
    /// a phantom.
    init?(key: String) {
        if key == "courses" {
            self = .courses
            return
        }
        let place = SpaceDestination(key: key)
        guard place.key == key, Self.places.contains(place) else { return nil }
        self = .place(place)
    }

    /// The Space sidebar's hub as a shortcut: every hub is one.
    init(hub: SpaceHub) {
        switch hub {
        case .courses: self = .courses
        }
    }

    var title: String {
        switch self {
        case .place(let place): return place.title
        case .courses: return SpaceHub.courses.title
        }
    }

    var systemImage: String {
        switch self {
        case .place(let place): return place.symbolName
        case .courses: return SpaceHub.courses.symbolName
        }
    }

    /// The picture the strip draws instead of `systemImage`, where the Space
    /// sidebar's row draws one: Google Drive's own logo.
    var assetImage: String? {
        self == .place(.drive) ? "GoogleDriveIcon" : nil
    }

    /// The pane the place also opens in, dragged to an edge of the center:
    /// Pages, Sites and Courses. Nil for a place that opens only in the Space.
    var centerTab: StudioCenterTab? {
        switch self {
        case .place(let place): return place.openableKind?.centerTab
        case .courses: return SpaceHub.courses.tab.centerTab
        }
    }

    /// What a Space sidebar row or a kept shortcut drags: the place, which
    /// the strip keeps where it is dropped (product owner, 2026-10-13: "let me
    /// drag these things to the left side bar to pin them; e.g. pages"), and
    /// the place's pane where it has one, which an edge of the center opens
    /// beside, as the row's drag always did. Each destination reads only the
    /// type it registered for.
    func dragProvider() -> NSItemProvider {
        let provider = centerTab.map { studioCenterTabDragProvider(for: $0) } ?? NSItemProvider()
        let data = Data(key.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.studioRailShortcut.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        provider.suggestedName = title
        return provider
    }

    /// Starts the drag: the strip draws the place where it would land, and
    /// the content drop zones stay hidden, as for a pane.
    func beginDrag() {
        StudioDragVisibility.shared.begin(centerTab: centerTab, railShortcut: self)
    }

    /// The place a strip drop carries, read off the first provider with one.
    /// False when none carries a place.
    @discardableResult
    static func loadDropped(
        from providers: [NSItemProvider],
        _ receive: @escaping @MainActor (StudioRailShortcut) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.studioRailShortcut.identifier)
        }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.studioRailShortcut.identifier) { data, _ in
            guard let data, let shortcut = StudioRailShortcut(key: String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in receive(shortcut) }
        }
        return true
    }
}

/// The shortcuts on the icon strip, in the order the learner kept them.
/// Follows the account, like the hidden rows (`StudioRailHiddenItems`): the
/// strip is the learner's arrangement, not one Mac's. None until the learner
/// keeps one from the ⋯.
struct StudioRailShortcuts: Equatable {
    static let storageKey = "studio.navigation.shortcuts.v1"

    var items: [StudioRailShortcut]

    init(_ items: [StudioRailShortcut] = []) {
        var seen = Set<StudioRailShortcut>()
        self.items = items.filter { seen.insert($0).inserted }
    }

    /// Decodes the comma-separated keys the preference holds, dropping a key
    /// this build does not know and any repeat.
    init(storage: String) {
        self.init(
            storage.split(separator: ",")
                .compactMap { StudioRailShortcut(key: String($0).trimmingCharacters(in: .whitespaces)) }
        )
    }

    var storage: String {
        items.map(\.key).joined(separator: ",")
    }

    func contains(_ shortcut: StudioRailShortcut) -> Bool { items.contains(shortcut) }

    /// Kept at the end of the strip, or taken off it.
    func setting(_ shortcut: StudioRailShortcut, shown: Bool) -> StudioRailShortcuts {
        var kept = items.filter { $0 != shortcut }
        if shown { kept.append(shortcut) }
        return StudioRailShortcuts(kept)
    }

    /// Kept just above `next`, the shortcut it was dropped on, or at the end
    /// when dropped anywhere else on the strip. One already kept moves there,
    /// which is how a drag up or down the strip reorders it.
    func keeping(_ shortcut: StudioRailShortcut, before next: StudioRailShortcut?) -> StudioRailShortcuts {
        // Dropped back on itself: kept where it is.
        if next == shortcut, contains(shortcut) { return self }
        var kept = items.filter { $0 != shortcut }
        if let next, let index = kept.firstIndex(of: next) {
            kept.insert(shortcut, at: index)
        } else {
            kept.append(shortcut)
        }
        return StudioRailShortcuts(kept)
    }

    /// The shortcuts the strip draws: the kept ones this Mac offers, so a
    /// kept Canvases waits, unshown, where canvases are not listed.
    func shown(listsCanvases: Bool) -> [StudioRailShortcut] {
        let offered = Set(StudioRailShortcut.offered(listsCanvases: listsCanvases))
        return items.filter(offered.contains)
    }
}

/// Codex-style chat navigation rail. It is the app's primary navigation surface,
/// led by the notebooks since shell stage 4 (docs/notebooks-design.md, "The
/// rail"): Spaces, Memory and Library as icons, with Home's sidebar beside
/// them while a chat or the Reader is on screen: New chat and the Browser, the
/// Notebooks header (the Space's All list), then the Pinned and Recent
/// notebooks with their chats — a compact way in since 2026-10-03, the whole
/// catalog living in the Space (`NotebookRail`); the library's own chats; the
/// day and the account in the footer. The icon strip is always drawn, in a
/// window holding a notebook too; the sidebar toggle folds only Home's
/// sidebar.
struct StudioNavigationRail: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(ManagedAIAccountModel.self) private var account
    @EnvironmentObject private var appUpdates: AppUpdateController
    /// Owns the selected manager and any chats still generating off screen.
    let sessionStore: StudioAssistantSessionStore
    let comparisonSessionStore: StudioAssistantSessionStore
    let edge: HorizontalEdge
    /// The icon rail, or Home's sidebar beside it: the same view twice, so the
    /// notebooks' and chats' state and menus stay in one place.
    var style: Style = .strip
    let onOpenChatBeside: (String) -> Void
    let onOpenSettings: (SettingsPane?) -> Void
    /// The golden-ratio width for this window, computed by the root layout —
    /// the only place that can measure the whole window. Nil where no
    /// measurement exists yet; the rail then falls back to `defaultRailWidth`.
    var goldenWidth: CGFloat?
    /// Getting Started covers the window: no corner card is raised under it.
    var isGettingStarted = false

    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.openWindow) private var openWindow

    @State private var renamingSession: ReviewSessionRecord?
    /// The chat whose Delete… is asking first.
    @State private var deletingSession: ReviewSessionRecord?
    @State private var notebookFromChatRequest: NotebookFromChatRequest?
    @State private var renameText = ""
    /// Disclosure is local navigation state, but it persists across launches so
    /// opening Studio does not repeatedly erase the learner's rail organization.
    /// It is intentionally not a synced preference.
    @State private var expandedNotebookIDs: Set<String> = StudioNavigationRail.storedExpandedNotebookIDs()
    /// How many chats each list has drawn as the learner scrolled past its
    /// first page, keyed by list (a notebook, the loose chats or the hidden
    /// ones). Absent means the list shows one page. Window state, not a
    /// preference: a long history is something the learner digs into once,
    /// not a layout they chose.
    @State private var revealedChatCounts: [String: Int] = [:]
    @State private var showsAccountMenu = false
    @SyncedStorage(wrappedValue: "", StudioRailHiddenItems.storageKey) private var hiddenRailItemsStorage: String
    private var hiddenRailItems: StudioRailHiddenItems { StudioRailHiddenItems(storage: hiddenRailItemsStorage) }
    @SyncedStorage(wrappedValue: "", StudioRailShortcuts.storageKey) private var railShortcutsStorage: String
    private var railShortcuts: StudioRailShortcuts { StudioRailShortcuts(storage: railShortcutsStorage) }
    /// A Space place is being dragged over the strip, which keeps it at the
    /// end of its shortcuts unless it is over one of them.
    @State private var shortcutDropIsTargeted = false
    /// The kept shortcut a dragged place is over: dropped, it lands above it.
    @State private var shortcutDropBefore: StudioRailShortcut?
    @State private var mcpLauncher = MCPServerLauncher.shared
    @SyncedStorage(AssistantIntegrationSettings.enabledKey) private var assistantIntegrationsEnabled = true
    @SyncedStorage(AssistantIntegrationSettings.statusLightVisibleKey) private var showsMCPStatusLight = true
    /// Observed so a rename, here or on another client, redraws the footer.
    @SyncedStorage(wrappedValue: "", MacAccountUser.displayNamePreferenceKey) private var savedDisplayName: String
    @SyncedStorage(MacAccountUser.showsCompCrownPreferenceKey) private var showsCompCrown = true
    @AppStorage(PlanTheDay.settingKey) private var asksToPlanTheDay = true
    @SyncedStorage(wrappedValue: true, MemoryCardSettings.draftNudgesKey) private var showsDraftNudges: Bool
    /// What the learner's own key has spent since local midnight, in USD, read
    /// from the usage ledger each time the account menu opens. Nil until read.
    /// The name the rail shows: the stand-in while Screen record mode films.
    private var accountFullName: String? { MacAccountUser.displayedFullName(saved: savedDisplayName) }

    /// Untouched outer panels open at the same golden-ratio width. This is only
    /// the fallback for layouts that cannot measure the window; after the
    /// learner resizes this rail, its own persisted width takes precedence.
    static let defaultRailWidth: CGFloat = 360
    static let minRailWidth: CGFloat = 200
    /// High enough to clear the golden width of the widest arrangement — a
    /// single center pane on a 2560pt window wants ~705 — so the ratio is
    /// never clipped exactly where the side panels are meant to be widest.
    static let maxRailWidth: CGFloat = 720

    /// Persisted rail width; the user drags the trailing edge to resize.
    @AppStorage("studio.navigationRailWidth") private var storedRailWidth: Double = Double(Self.defaultRailWidth)
    /// Live width while the trailing edge is being dragged; nil when idle.
    @State private var draggedRailWidth: CGFloat?
    @State private var dragStartRailWidth: CGFloat?

    enum Style { case strip, homeSidebar }

    private var railWidth: CGFloat {
        if isCompact { return Self.compactRailWidth }
        return draggedRailWidth ?? Self.resolvedRailWidth(goldenDefault: goldenWidth)
    }

    /// The rail inside a notebook window: an icon strip, so the notebook's
    /// three columns — Sources, the chat and Studio, as in Gemini Notebook,
    /// which has no sidebar — take the window (product owner, 2026-10-02). Its
    /// notebook chats are in the strip's Chats menu, the chat's header and
    /// the notebook's guide.
    static let compactRailWidth: CGFloat = 52

    /// Whether this is the icon rail, which is the window's rail everywhere
    /// since 2026-10-07; the other style is Home's sidebar.
    private var isCompact: Bool { style == .strip }

    private static func clampedRailWidth(_ value: CGFloat) -> CGFloat {
        min(max(value, minRailWidth), maxRailWidth)
    }

    static let widthKey = "studio.navigationRailWidth"

    /// A width the learner dragged themselves, or nil while the rail has never
    /// been resized. Absent means the golden width is free to follow the
    /// window; a stored value is a deliberate override and outranks it.
    private static var draggedWidthPreference: CGFloat? {
        (UserDefaults.standard.object(forKey: widthKey) as? Double).map { CGFloat($0) }
    }

    /// The width this rail opens at: the learner's own if they ever dragged it,
    /// otherwise the golden width for this window.
    static func resolvedRailWidth(goldenDefault: CGFloat?) -> CGFloat {
        clampedRailWidth(draggedWidthPreference ?? goldenDefault ?? defaultRailWidth)
    }

    /// The rail's width with no window measurement available.
    static var currentRailWidth: CGFloat { resolvedRailWidth(goldenDefault: nil) }

    private var activeSessionIDs: Set<String> {
        Self.highlightedSessionIDs(
            primary: sessionStore.activeSessionID,
            comparison: comparisonSessionStore.activeSessionID,
            in: windowState
        )
    }

    /// Whether the primary chat surface is on screen in this window: the Chat
    /// tab is the active tab of some pane, or the chat is popped out into its
    /// own window. Selecting Docs or Notebooks in a pane replaces Chat as that
    /// pane's active tab, and the rail follows: the destination row takes the
    /// highlight and the chat row gives it up, so the rail never shows a chat
    /// as selected while nothing on screen is that chat.
    static func isChatVisible(layout: StudioCenterTabGroups, chatPoppedOut: Bool) -> Bool {
        chatPoppedOut || layout.groups.contains { $0.activeTab == .chat }
    }

    /// The chats whose rail rows carry the selection. A store's chat counts
    /// only while it is showing: the primary store's while Chat is an active
    /// tab or popped out, the comparison store's while its "Open Beside" pane
    /// is the active tab of a pane in this window's layout. Both stores keep
    /// their chat after its surface is hidden so bringing it back is cheap,
    /// and without this gate a hidden chat's row stayed highlighted with
    /// nothing showing it.
    /// `isChatVisible` for a window holding a notebook: its chat shows while
    /// the notebook shows it (or it is popped out).
    static func isChatVisible(notebook: NotebookWorkspace, chatPoppedOut: Bool) -> Bool {
        chatPoppedOut || notebook.showsChat
    }

    /// Whether the primary chat is on screen in `windowState`, in either shell.
    static func isChatVisible(in windowState: StudioWindowState) -> Bool {
        if let notebook = windowState.notebook, !notebook.tabbed {
            return isChatVisible(notebook: notebook, chatPoppedOut: windowState.isChatPoppedOut)
        }
        return isChatVisible(layout: windowState.centerTabGroups, chatPoppedOut: windowState.isChatPoppedOut)
    }

    /// `highlightedSessionIDs` for a window holding a notebook: the primary
    /// chat's row while the notebook shows its chat, the comparison chat's
    /// while it sits in the document slot.
    static func highlightedSessionIDs(
        primary: String?,
        comparison: String?,
        notebook: NotebookWorkspace,
        chatPoppedOut: Bool = false
    ) -> Set<String> {
        var ids = Set<String>()
        if let primary, isChatVisible(notebook: notebook, chatPoppedOut: chatPoppedOut) {
            ids.insert(primary)
        }
        if let comparison, notebook.showsSecondChat {
            ids.insert(comparison)
        }
        return ids
    }

    /// The highlighted chats of `windowState`, in either shell.
    static func highlightedSessionIDs(
        primary: String?,
        comparison: String?,
        in windowState: StudioWindowState
    ) -> Set<String> {
        if let notebook = windowState.notebook, !notebook.tabbed {
            return highlightedSessionIDs(
                primary: primary,
                comparison: comparison,
                notebook: notebook,
                chatPoppedOut: windowState.isChatPoppedOut
            )
        }
        return highlightedSessionIDs(
            primary: primary,
            comparison: comparison,
            layout: windowState.centerTabGroups,
            chatPoppedOut: windowState.isChatPoppedOut
        )
    }

    static func highlightedSessionIDs(
        primary: String?,
        comparison: String?,
        layout: StudioCenterTabGroups,
        chatPoppedOut: Bool = false
    ) -> Set<String> {
        var ids = Set<String>()
        if let primary, isChatVisible(layout: layout, chatPoppedOut: chatPoppedOut) {
            ids.insert(primary)
        }
        if let comparison,
           layout.groups.contains(where: { $0.activeTab == .secondaryChat }) {
            ids.insert(comparison)
        }
        return ids
    }

    var body: some View {
        Group {
            switch style {
            case .strip: compactRail
            case .homeSidebar: fullRail
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: appUpdates.phase)
        .animation(.easeInOut(duration: 0.2), value: account.creditsAreEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: StoreUpgradeSpaceNotice.shared.visibleMessage)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: DayModel.shared.planTheDayAsk)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: vm.cardsToCheckPile)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: vm.cardsToCheckIsPutOff)
        .frame(width: railWidth)
        .background(railBackground)
        .overlay(alignment: edge == .leading ? .trailing : .leading) {
            if !isCompact {
                railResizeHandle
            }
        }
        .task {
            await vm.loadTeams()
            await vm.loadLearningGoals()
            await vm.loadReviewSessionLinks()
            reconcileExpandedNotebooks()
        }
        // An accepted invitation and a roster change both happen outside the
        // view model; the switcher's list has to follow them.
        .onReceive(NotificationCenter.default.publisher(for: TeamSharingService.teamDidJoin)) { _ in
            Task { await vm.loadTeams() }
        }
        .onReceive(NotificationCenter.default.publisher(for: TeamSharingService.teamRosterDidChange)) { note in
            Task {
                await vm.loadTeams()
                if let teamID = note.object as? String { await vm.refreshTeamMembers(teamID: teamID) }
            }
        }
        .onChange(of: expandedNotebookIDs) { _, ids in
            PreferenceStore.set(ids.sorted(), forKey: Self.expandedNotebookIDsKey)
            NotebookSidebarSync.setExpanded(ids)
        }
        // The folds the rail keeps in `@SyncedStorage` redraw themselves when a
        // remote change lands; this one is a `Set` seeded once into `@State`, so
        // it has to be reseeded explicitly or the other Mac's change would not
        // show until the next launch — the difference `PreferenceStore` warns
        // about for exactly this shape of reader.
        .onReceive(NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)) { note in
            let changed = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String>
            guard changed?.contains(Self.expandedNotebookIDsKey) ?? true else { return }
            let stored = Self.storedExpandedNotebookIDs()
            if stored != expandedNotebookIDs { expandedNotebookIDs = stored }
        }
        .onChange(of: activeSessionIDs) { _, _ in
            expandNotebooksContainingActiveChats()
        }
        .onChange(of: vm.notebooks.map(\.id)) { _, _ in
            reconcileExpandedNotebooks()
        }
        // Codex's Rename chat: the title in a field, Save.
        .alert(
            "Rename Chat",
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            )
        ) {
            TextField("Add a title…", text: $renameText)
            Button("Cancel", role: .cancel) { renamingSession = nil }
            Button("Save") {
                if let session = renamingSession {
                    let title = renameText
                    Task { await vm.renameReviewSession(session.id, title: title) }
                }
                renamingSession = nil
            }
        }
        // Delete asks first, as Codex's does and Home's list does; until
        // 2026-10-13 the rail's Delete was the one hard delete that did not.
        .confirmationDialog(
            "Delete \u{2018}\(deletingSession.map(railChatTitle) ?? "this chat")\u{2019}?",
            isPresented: Binding(
                get: { deletingSession != nil },
                set: { if !$0 { deletingSession = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingSession
        ) { session in
            Button("Delete", role: .destructive) {
                deleteSession(session)
                deletingSession = nil
            }
        } message: { _ in
            Text("The chat and its transcript are deleted. This can\u{2019}t be undone; Hide keeps it out of the list instead.")
        }
        .newNotebookFromChat($notebookFromChatRequest, vm: vm, window: windowState)
    }

    /// A chat's name as its row shows it.
    private func railChatTitle(_ session: ReviewSessionRecord) -> String {
        session.title.isEmpty
            ? "Untitled chat"
            : MemoryReviewSession.displayTitle(storedTitle: session.title, sessionID: session.id)
    }

    /// The window's rail, Codex's: a + for a new chat, Spaces, Memory,
    /// Library and Plugins as icons, the ⋯ with every other place, and under a short
    /// line the places the learner kept there (`StudioRailShortcuts`), from
    /// the ⋯ or by dragging a Space sidebar row onto the strip; then
    /// the day's calendar glyph, whose popover is the schedule, and the
    /// account. The notebooks and the chats are Home's sidebar (`fullRail`),
    /// which shows beside a chat or the Reader; "Plan your day?" and "Cards
    /// to check" are in its footer, or in the window's corner where Home's
    /// sidebar is not showing.
    @ViewBuilder
    private var compactRail: some View {
        let hiddenItems = hiddenRailItems
        let shortcuts = railShortcuts.shown(listsCanvases: vm.listsCanvases)
        let litShortcut = shortcuts.first(where: isShowing)
        // The place a drag over the strip would keep at the end, drawn
        // there until the drop: over a kept shortcut, a line above that one
        // shows where it lands instead.
        let landing = shortcutDropIsTargeted && shortcutDropBefore == nil
            ? StudioDragVisibility.shared.draggedRailShortcut
            : nil
        VStack(spacing: 4) {
            ForEach(hiddenItems.railItems()) { item in
                switch item {
                case .space: spaceButton(compact: true, yieldsTo: litShortcut != nil)
                case .memory: memoryButton(compact: true)
                case .library: libraryButton(compact: true)
                case .plugins: pluginsButton(compact: true)
                case .home: homeButton()
                case .newChat, .browser: EmptyView()
                }
            }
            // Always drawn: it is also the way back for a hidden row, its
            // menu ending with Show in Sidebar.
            RailMoreButton(
                places: StudioRailShortcut.offered(listsCanvases: vm.listsCanvases)
                    .filter { !shortcuts.contains($0) },
                open: openShortcut
            )
            if !shortcuts.isEmpty || landing != nil {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 24, height: 1)
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)
                ForEach(shortcuts) { shortcut in
                    shortcutButton(shortcut, isSelected: shortcut == litShortcut)
                        // A kept one dragged to the end shows there instead.
                        .opacity(shortcut == landing ? 0.35 : 1)
                }
                if let landing {
                    RailGlyph(systemImage: landing.systemImage, assetImage: landing.assetImage)
                        .background(StudioSelectionBackground(isSelected: true, isHovered: false))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            if account.creditsAreEmpty, !vm.isScreenRecordModeActive {
                Button { onOpenSettings(.aiUsage) } label: {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 36, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
                .railTooltip("Credits used up")
                .accessibilityLabel("Credits used up")
                .transition(.opacity)
            }
            // The update offer's own place: Sparkle leaves announcing an update
            // to the rail whenever the rail is shown (`pillOwnsOffer`), so the
            // strip has to carry it too, or a notebook window never offers one.
            if appUpdates.isUpdateAvailable {
                RailUpdateButton(updateController: appUpdates, isCompact: true)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            // What an AI app set the app's models to do, an explainer, an
            // import: the app's logo, over the paid work (product owner, 2026-10-13).
            StudioWorkButton()
            // The OpenRouter button: paid work running in the background, one
            // click from its progress and a Stop (product owner, 2026-10-08),
            // and under it what has run and the key (2026-10-15).
            BackgroundWorkButton(
                monitor: BackgroundWorkMonitor.shared,
                onOpenSettings: { onOpenSettings($0) }
            )
            DayNowChip(style: .rail, compact: true, iconOnly: true)
            // Every corner card that is waiting, the ones tucked away included.
            NotificationCenterButton(
                kinds: activeNoticeKinds,
                planDay: DayModel.shared.planTheDayAsk,
                cardsToCheckDetail: vm.cardsToCheckDetail
            )
            accountMenuButton(compact: true)
                .padding(.bottom, 8)
        }
        .task { BackgroundWorkMonitor.shared.start() }
        // The strip is in every window, always: it reports the window's chats
        // to the unread marks.
        .background {
            ChatActivityReporter(sessionStore: sessionStore, comparisonSessionStore: comparisonSessionStore)
        }
        .padding(.top, titlebarBandHeight == nil && edge == .leading ? 48 : StudioDesign.Spacing.medium)
        .frame(maxWidth: .infinity)
        // A Space sidebar row dropped anywhere on the strip is kept at the
        // end of its shortcuts, its glyph alone, as the ⋯'s Show in Sidebar
        // keeps one.
        .contentShape(Rectangle())
        .onDrop(of: [.studioRailShortcut], isTargeted: $shortcutDropIsTargeted) { providers in
            StudioDragVisibility.shared.endSoon()
            return keepDroppedShortcut(providers, before: nil)
        }
        .animation(.easeInOut(duration: 0.16), value: landing)
    }

    /// Keeps the place a drop carries on the strip, above `next` or at the end.
    private func keepDroppedShortcut(_ providers: [NSItemProvider], before next: StudioRailShortcut?) -> Bool {
        StudioRailShortcut.loadDropped(from: providers) { shortcut in
            withAnimation(.easeInOut(duration: 0.16)) {
                railShortcutsStorage = StudioRailShortcuts(storage: railShortcutsStorage)
                    .keeping(shortcut, before: next)
                    .storage
            }
        }
    }

    /// The notices with something to say right now: the corner cards, tucked
    /// or not, and what only the bell holds. What the bell lists beside the
    /// chats that need attention.
    private var activeNoticeKinds: [CornerNoticeKind] {
        var kinds: [CornerNoticeKind] = []
        if ActivationNotice.shared.card != nil { kinds.append(.libraryMove) }
        if StoreUpgradeSpaceNotice.shared.visibleMessage != nil { kinds.append(.storeUpgradeSpace) }
        if asksToPlanTheDay, DayModel.shared.planTheDayAsk != nil { kinds.append(.planTheDay) }
        if vm.cardsToCheckDetail != nil,
           vm.showsCardsToCheckCard(
               in: windowState,
               isGettingStarted: isGettingStarted,
               asksToPlanTheDay: false,
               showsNudges: showsDraftNudges
           ) {
            kinds.append(.cardsToCheck)
        }
        // What only the bell holds: teammates' requests, and plugins to
        // reconnect.
        if !vm.fulfillableShareRequests.isEmpty { kinds.append(.shareRequests) }
        if !vm.pluginsNeedingReconnect.isEmpty { kinds.append(.pluginReconnect) }
        return kinds
    }


    /// The notebooks the rail has rows for, by id: the active ones, and an
    /// archived one this window holds.
    private func railNotebooksByID(_ rail: NotebookRail) -> [String: LearningGoalRecord] {
        let ids = Set(rail.notebookIDs)
        return Dictionary(
            vm.allNotebooks.filter { ids.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @ViewBuilder
    private var fullRail: some View {
        let hiddenItems = hiddenRailItems
        VStack(spacing: 0) {
            // Each top row can be taken off the rail from its own menu; with
            // every one hidden the block goes too, so the notebooks move up
            // rather than sitting under an empty band.
            let topItems = hiddenItems.sidebarItems()
            if !topItems.isEmpty {
                VStack(spacing: 2) {
                    ForEach(topItems) { item in
                        switch item {
                        case .newChat: newChatButton()
                        case .browser: browserButton()
                        case .home, .space, .memory, .library, .plugins: EmptyView()
                        }
                    }
                }
                    .padding(.horizontal, StudioDesign.Spacing.small)
                    // With no titlebar band (fullscreen) the sidebar toggle sits
                    // in-flow over the rail's top-left corner; start the rail's
                    // content below that row instead of underneath the toggle.
                    .padding(.top, titlebarBandHeight == nil && edge == .leading ? 48 : StudioDesign.Spacing.medium)
                    .padding(.bottom, StudioDesign.Spacing.small)
            }

            ScrollView {
                // Notebooks is a clickable section header that opens the
                // Space's All list, with the Pinned and Recent notebooks
                // beneath it (`NotebookRail`): a compact way in, the whole
                // catalog living in the Space (product owner, 2026-10-03, of ~52
                // notebooks: "is it even still good design to have all these
                // notebooks in the left sidebar as well?"). The collections'
                // rows went with the Notebooks home (2026-10-09): All groups
                // by collection. A notebook's
                // chats live directly beneath its row; library chats and
                // chats whose notebook has no row here — archived, neither
                // pinned nor recent — remain in the Chats section so nothing
                // becomes unreachable.
                // The notebook this window holds: another window's never
                // lights a notebook here.
                let scopedNotebook = vm.railScopedNotebook(in: windowState)
                let rail = vm.notebookRail(in: windowState)
                let notebooks = railNotebooksByID(rail)
                let railNotebooks = rail.notebookIDs.compactMap { notebooks[$0] }
                let chatGroups = vm.reviewSessionGroups(for: railNotebooks)
                // A pinned chat leaves its notebook's chats or the loose ones
                // for Pinned, under the pinned notebooks, as Codex's pinned
                // chats leave their project (`ChatPins`).
                let chats = vm.splittingPinnedChats(
                    byNotebookID: chatGroups.byNotebookID,
                    outsideNotebooks: chatGroups.outsideNotebooks
                )
                let unreadChatIDs = ChatReadMarks.shared.unreadSessionIDs
                // Hidden chats leave every list above and sit folded under the
                // loose chats, whichever Notebook they are filed in.
                let hiddenChats = vm.hiddenReviewSessions(for: railNotebooks)
                // One pass over the live managers for the whole rail; asking
                // per row registered every row against every manager's
                // generation flags and re-scanned the managers rows × flips
                // times per turn.
                let runningSessionIDs = sessionStore.runningSessionIDs
                    .union(comparisonSessionStore.runningSessionIDs)

                // Chat rows carry menus, drag support, and hover state. Building the
                // entire history eagerly made SwiftUI materialize every row and its
                // nested notebook menu before the rail could draw; with a moderately
                // sized history that produced a multi-gigabyte display list and a
                // permanent beachball. Keep only the viewport's rows alive.
                LazyVStack(alignment: .leading, spacing: 2) {
                    // The header opens the Space's All list, where every
                    // notebook is listed: the notebook the window holds
                    // leaves, and its row below brings it back. Home's sidebar
                    // shows only while the window is not on the Space, so the
                    // header is never the lit row.
                    RailSectionHeaderButton(
                        title: "Notebooks",
                        identifier: "studio.navigation.notebooks"
                    ) {
                        vm.inWindow(windowState) { vm.showSpaceAll(in: windowState) }
                    }
                    .onDrag {
                        StudioDragVisibility.shared.begin(centerTab: .artifacts)
                        return studioCenterTabDragProvider(for: .artifacts)
                    }
                    .contextMenu {
                        // The Courses list: every course, which lives in no
                        // notebook.
                        Section("Courses") {
                            Button("Open Courses", systemImage: "graduationcap") {
                                vm.inWindow(windowState) { vm.showSpaceTab(.courses) }
                            }
                            Button("Open Courses Beside", systemImage: "rectangle.split.2x1") {
                                vm.inWindow(windowState) {
                                    vm.openCenterTabBeside(.courses)
                                    vm.openCoursesListInReader()
                                }
                            }
                            OpenStudioDestinationInOtherWindowMenu(
                                destination: .courses,
                                currentWindowState: windowState,
                                openNewWindow: { openWindow(id: "studio") }
                            )
                        }
                        // The Space: every page, site, picture, canvas, list,
                        // notebook and course. Goals and Ideas are the chat's
                        // to show since 2026-10-10 (`SpaceTab`).
                        Section("Space") {
                            Button("Open Space", systemImage: "square.grid.2x2") {
                                vm.inWindow(windowState) { vm.showSpaceAll(in: windowState) }
                            }
                            Button("Open Space Beside", systemImage: "rectangle.split.2x1") {
                                vm.inWindow(windowState) {
                                    vm.openCenterTabBeside(.artifacts)
                                    vm.openArtifactsInReader()
                                }
                            }
                            OpenStudioDestinationInOtherWindowMenu(
                                destination: .artifacts,
                                currentWindowState: windowState,
                                openNewWindow: { openWindow(id: "studio") }
                            )
                        }
                        // The Notebooks header cannot be hidden, so this menu is
                        // the one route back that survives hiding every row
                        // above it.
                        Divider()
                        RailItemVisibilityMenu()
                    }

                    // Both placeholders wait for the first library load: until
                    // then an empty list means "still reading", and "No notebooks
                    // yet" would greet a learner whose notebooks are seconds away.
                    if railNotebooks.isEmpty, vm.hasCompletedInitialQueueLoad {
                        RailPlaceholderRow(
                            text: vm.archivedNotebooks.isEmpty ? "No notebooks yet" : "No active notebooks",
                            indent: 8
                        )
                    }

                    if !rail.pinnedIDs.isEmpty || !chats.pinned.isEmpty {
                        RailSectionHeader(title: "Pinned")
                        ForEach(rail.pinnedIDs.compactMap { notebooks[$0] }) { notebook in
                            notebookRow(
                                notebook,
                                scopedNotebook: scopedNotebook,
                                chatGroups: chats.byNotebookID,
                                runningSessionIDs: runningSessionIDs,
                                unreadChatIDs: unreadChatIDs
                            )
                        }
                        // The pinned chats, in the learner's order: a drop on
                        // one moves the dragged pin to its place.
                        let pinnedIDs = chats.pinned.map(\.id)
                        ForEach(chats.pinned) { session in
                            chatRow(
                                session,
                                siblingIDs: pinnedIDs,
                                runningSessionIDs: runningSessionIDs,
                                indent: 0,
                                reorder: { dragged in
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        vm.reorderPinnedChat(from: dragged, to: session.id, listed: pinnedIDs)
                                    }
                                }
                            )
                        }
                    }

                    // The last few worked in, and the notebook this window last
                    // left when it is neither pinned nor recent, so going back
                    // to it stays one click.
                    let recent = (rail.recentIDs + [rail.openNotebookID].compactMap { $0 }).compactMap { notebooks[$0] }
                    if !recent.isEmpty {
                        RailSectionHeader(title: "Recent")
                        ForEach(recent) { notebook in
                            notebookRow(
                                notebook,
                                scopedNotebook: scopedNotebook,
                                chatGroups: chats.byNotebookID,
                                runningSessionIDs: runningSessionIDs,
                                unreadChatIDs: unreadChatIDs
                            )
                        }
                    }

                    // The library's own chats. The header's + starts one: a
                    // library chat, which leaves a notebook the window holds
                    // (the chat-home rule), where New chat above makes a
                    // notebook chat there. The + shows while the pointer is
                    // over the header (product owner, 2026-10-06: "cleaner and fewer
                    // buttons"), and the header's menu keeps it for the
                    // keyboard. Scoped to this rail's window: the request must
                    // land in the Chat pane beside this rail, not in whichever
                    // window's pane happens to run its task first.
                    RailSectionHeader(
                        title: "Chats",
                        isExpanded: isChatsExpanded,
                        toggleExpanded: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isChatsExpanded.toggle()
                            }
                        }
                    ) {
                        vm.inWindow(windowState) { vm.requestBlankReviewChat() }
                    }
                    .contextMenu {
                        Button("New Library Chat", systemImage: "plus") {
                            vm.inWindow(windowState) { vm.requestBlankReviewChat() }
                        }
                        Divider()
                        // Hidden chats are hidden: no row in the rail says
                        // they exist. The learner who hid them knows where to
                        // look, and this menu is the one route to them
                        // (product owner, 2026-09-20).
                        if !hiddenChats.isEmpty {
                            Button(
                                isHiddenChatsExpanded
                                    ? "Hide Hidden Chats"
                                    : "Show Hidden Chats (\(hiddenChats.count))",
                                systemImage: isHiddenChatsExpanded ? "eye.slash" : "eye"
                            ) {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    isHiddenChatsExpanded.toggle()
                                    if isHiddenChatsExpanded { isChatsExpanded = true }
                                }
                            }
                        } else {
                            Text("No hidden chats")
                        }
                    }
                    if isChatsExpanded {
                        if chatGroups.totalCount == 0 && hiddenChats.isEmpty {
                            if vm.hasCompletedInitialQueueLoad {
                                RailPlaceholderRow(
                                    text: "No chats yet",
                                    indent: 8
                                )
                            }
                        } else {
                            chatList(chats.outsideNotebooks, listID: Self.looseChatListID, runningSessionIDs: runningSessionIDs)
                            if !hiddenChats.isEmpty, isHiddenChatsExpanded {
                                hiddenChatsFold(hiddenChats, runningSessionIDs: runningSessionIDs)
                            }
                        }
                    }
                }
                .padding(.horizontal, StudioDesign.Spacing.small)
                .padding(.bottom, StudioDesign.Spacing.large)
            }

            // "Plan your day?" on a morning with nothing planned, over the
            // Now chip's place, until it is answered
            // (product owner, 2026-09-28: "maybe in the bottom left? maybe better
            // than popups"). A library update waiting for disk space comes
            // first: one corner card at a time.
            // A card tucked this launch, or read for what it says now, waits
            // in the bell instead.
            let tray = CornerNoticeTray.shared
            let subjects = vm.inboxSubjects(planDay: DayModel.shared.planTheDayAsk)
            if let card = ActivationNotice.shared.card, tray.showsInCorner(.libraryMove, subject: subjects.subject(.libraryMove)) {
                ActivationCard(title: card.title, detail: card.detail, style: .rail)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let message = StoreUpgradeSpaceNotice.shared.visibleMessage,
                      tray.showsInCorner(.storeUpgradeSpace, subject: subjects.subject(.storeUpgradeSpace)) {
                StoreUpgradeSpaceCard(message: message, style: .rail)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if asksToPlanTheDay, let day = DayModel.shared.planTheDayAsk,
                      tray.showsInCorner(.planTheDay, subject: subjects.subject(.planTheDay)) {
                PlanTheDayCard(day: day, style: .rail)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The strip paints nothing: it stands on the window's chrome, the
    /// surface the titlebar band and the gutters are, so the traffic lights
    /// above it and the strip below them are one color, as in Codex, and the
    /// card's rounded edge is the only seam. Home's sidebar is inside the card
    /// and takes the sidebar's tone there, as the Space's sidebar does,
    /// starting under the band.
    @ViewBuilder
    private var railBackground: some View {
        if !isCompact {
            SpaceSidebarMetrics.background
        }
    }

    /// One notebook's row, Pinned or Recent, and its chats beneath it while
    /// it is unfolded.
    @ViewBuilder
    private func notebookRow(
        _ notebook: LearningGoalRecord,
        scopedNotebook: LearningGoalRecord?,
        chatGroups: [String: [ReviewSessionRecord]],
        runningSessionIDs: Set<String>,
        unreadChatIDs: Set<String>
    ) -> some View {
        let isExpanded = expandedNotebookIDs.contains(notebook.id)
        // Its chats that read as unread on this Mac: the row carries Codex's
        // dot for them while it is folded, and Mark All as Read.
        let unreadInNotebook = unreadChatIDs.isEmpty
            ? []
            : (chatGroups[notebook.id] ?? []).map(\.id).filter(unreadChatIDs.contains)
        RailNotebookRow(
            goal: notebook,
            notebookTitle: NotebookTitle(notebook.title),
            // Active means "this notebook is open" — the rail keeps
            // showing which one even after the reader column has
            // moved on to a source, so fresh chats keep adopting it.
            isActive: scopedNotebook?.id == notebook.id,
            // Selected while its notebook fills this window.
            isSelected: windowState.NotebookID == notebook.id,
            isExpanded: isExpanded,
            unreadChatIDs: unreadInNotebook,
            // A click opens the notebook in this window and shows
            // its chats; it never closes the notebook or folds
            // them — ‹ Notebooks, the notebook's ⋯ and the
            // Notebook menu close it, and the chevron folds.
            // A notebook fills its window, so there is no pane
            // to open it beside; Open in Other Window is on the
            // row's menu.
            open: {
                if !isExpanded {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        _ = expandedNotebookIDs.insert(notebook.id)
                    }
                }
                vm.inWindow(windowState) { vm.openNotebookInReader(notebook.id) }
            },
            toggleExpanded: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isExpanded {
                        expandedNotebookIDs.remove(notebook.id)
                    } else {
                        expandedNotebookIDs.insert(notebook.id)
                    }
                }
            },
            // Open the notebook first: the fresh chat has to land
            // in it and appear beneath this row.
            newChat: {
                vm.inWindow(windowState) {
                    vm.openNotebook(notebook.id, startsNotebookChat: false)
                    vm.requestBlankReviewChat(notebookID: notebook.id)
                }
            }
        )
        if isExpanded {
            // The row already reserves an icon column. A small
            // extra inset is enough to communicate nesting
            // without pushing chat titles into a second column.
            chatList(
                chatGroups[notebook.id] ?? [],
                listID: Self.notebookChatListID(notebook.id),
                runningSessionIDs: runningSessionIDs,
                indent: 12
            )
        }
    }

    private static let expandedNotebookIDsKey = "studio.navigation.expandedProjectIDs.v1"

    /// Whether the loose chats show beneath the Chats header. Open by default
    /// so a learner who has never folded it finds the chats; it folds so a long history of chats
    /// outside Notebooks stops pushing the account row's neighbours around.
    @SyncedStorage(wrappedValue: true, "studio.navigation.chatsExpanded.v1") private var isChatsExpanded: Bool
    /// Whether the Hidden fold under Chats is open. Closed by default: a chat
    /// is hidden to be out of the way, and the fold's count says it is there.
    @SyncedStorage(wrappedValue: false, "studio.navigation.hiddenChatsExpanded.v1") private var isHiddenChatsExpanded: Bool

    private static func storedExpandedNotebookIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: expandedNotebookIDsKey) ?? [])
    }

    /// Folds are kept for every active notebook, not only those with a row
    /// now: Recent changes as the learner works, and a notebook coming back
    /// into it comes back as it was left.
    private func reconcileExpandedNotebooks() {
        let validIDs = Set(vm.notebooks.map(\.id))
        expandedNotebookIDs.formIntersection(validIDs)
        expandNotebooksContainingActiveChats()
    }

    private func expandNotebooksContainingActiveChats() {
        let railIDs = Set(vm.notebookRail(in: windowState).notebookIDs)
        for session in vm.reviewSessionLinks where activeSessionIDs.contains(session.id) {
            if MemoryReviewSession.isMemorySession(session.id) {
                // A day's review has no row in the rail; the Memory row is
                // where it is reached, and nothing unfolds.
                continue
            } else if vm.isChatPinned(session.id) {
                // Its row is in Pinned, which never folds.
                continue
            } else if let goalID = session.goalID, railIDs.contains(goalID) {
                expandedNotebookIDs.insert(goalID)
            } else {
                // Loose, or in a notebook the rail has no row for (archived,
                // neither pinned nor recent): the row lives in Chats, so an
                // active one unfolds the section the way it would a notebook.
                isChatsExpanded = true
            }
        }
    }

    /// Inner-edge grab strip that resizes the rail, drawn over the rail's own
    /// padding so it never steals clicks from row content. The visible
    /// hairline is the card's column divider, with its short stroke in the
    /// titlebar band as the panel dividers have.
    private var railResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .overlay(alignment: edge == .leading ? .trailing : .leading) {
                StudioColumnHairline()
            }
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .onTapGesture(count: 2) {
                // Double-click clears the override rather than writing the
                // fallback width, so the rail goes back to tracking the
                // window's golden ratio instead of freezing at 360.
                UserDefaults.standard.removeObject(forKey: Self.widthKey)
            }
            .gesture(
                // Global space: the handle moves with the rail's edge while
                // dragging, so a local-space translation would feed back into
                // itself and stutter.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartRailWidth ?? railWidth
                        dragStartRailWidth = start
                        let delta = edge == .leading ? value.translation.width : -value.translation.width
                        draggedRailWidth = Self.clampedRailWidth(start + delta)
                    }
                    .onEnded { _ in
                        if let width = draggedRailWidth {
                            storedRailWidth = Double(width)
                        }
                        dragStartRailWidth = nil
                        draggedRailWidth = nil
                    }
            )
    }

    // MARK: - New chat

    // MARK: - Library

    /// Which library the Studio shows: My Library or one team. A team is a
    /// second library, so the switch sits above every destination the rail
    /// offers; everything beneath it reloads for the chosen scope. The row
    /// carries the team's name while a team is open, so the learner is never
    /// left guessing whose sources and chats they are looking at.

    /// New chat: Home's sidebar's first row, and on the icon strip a + above
    /// Spaces (product owner, 2026-10-13: "maybe we need a 'new chat' button
    /// at the top of the left side bar as well; just a + sign"), so a chat
    /// is one click away from every place, a notebook window included.
    private func newChatButton() -> some View {
        // Highlighted only while the user is actually on a fresh/blank chat
        // (no session loaded yet) and that chat is on screen. Once a real chat
        // is open its own row carries the selection, and once Docs or Notebooks
        // has replaced Chat in its pane that row does, so the rail never shows
        // two selected items at once.
        RailButtonRow(
            title: "New chat",
            systemImage: "square.and.pencil",
            railItem: .newChat,
            isSelected: sessionStore.activeSessionID == nil
                && Self.isChatVisible(in: windowState),
            openBeside: {
                vm.inWindow(windowState) {
                    vm.openCenterTabBeside(.chat)
                    vm.requestNewChat()
                }
            },
            otherWindowDestination: .newChat,
            help: "Start a new chat",
            identifier: "studio.navigation.newChat",
            isCompact: false
        ) {
            vm.inWindow(windowState) { vm.requestNewChat() }
        }
        // Draggable like the other workspace destinations: dropped at either
        // edge of the center area it opens a fresh chat in its own pane.
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .chat)
            return studioCenterTabDragProvider(for: .chat, startsBlankChat: true)
        }
    }

    /// Home (2026-10-16), Codex's first icon, which took the + 's place on the
    /// strip: a blank chat with Home's sidebar beside it, New chat, the
    /// notebooks and every chat. In a window holding a notebook it leaves the
    /// notebook first (`requestBlankReviewChat`), and the notebook's row
    /// brings it back. Lit while the window is on Home, the sidebar showing.
    private func homeButton() -> some View {
        RailButtonRow(
            title: StudioRailItem.home.title,
            systemImage: StudioRailItem.home.systemImage,
            railItem: .home,
            isSelected: windowState.isOnHome && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) {
                    vm.openCenterTabBeside(.chat)
                    vm.requestBlankReviewChat()
                }
            },
            otherWindowDestination: .newChat,
            help: "Home: a new chat, with your notebooks and chats beside it",
            identifier: "studio.navigation.home",
            isCompact: true
        ) {
            vm.inWindow(windowState) { vm.requestBlankReviewChat() }
        }
        // Draggable like New chat: dropped at either edge of the center area
        // it opens a fresh chat in its own pane.
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .chat)
            return studioCenterTabDragProvider(for: .chat, startsBlankChat: true)
        }
    }

    /// Browser, under Memory: the web itself, in tabs, with profiles that keep
    /// separate logins. A place, so every click lands on the pane with the
    /// tabs it had; a fresh window opens on a blank tab. In a window holding a
    /// notebook it opens in the notebook's document slot.
    private func browserButton(compact: Bool = false) -> some View {
        RailButtonRow(
            title: "Browser",
            systemImage: "safari",
            railItem: .browser,
            isSelected: vm.visibleCenterTabs(in: windowState).contains(.browser)
                && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.openCenterTabBeside(.browser)
                vm.openBrowserInReader()
            },
            otherWindowDestination: .browser,
            help: "Open Browser",
            identifier: "studio.navigation.browser",
            isCompact: compact
        ) {
            vm.openBrowserInReader()
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .browser)
            return studioCenterTabDragProvider(for: .browser)
        }
    }

    /// A place since the card review (2026-10-01): the Memory pane, with
    /// today's cards across every notebook (a notebook one click away in the
    /// pane), Start Review, what is waiting to be checked, and every kept
    /// card. In a window holding a notebook it opens in the notebook's
    /// document slot, still over every notebook. Only the pane's Start Review
    /// gives the window over, as only the Review mode sheet's did before.
    /// Nothing trails the label: a countdown there read as a stuck clock
    /// whenever the review was not being worked; the counts are in the help.
    private func memoryButton(compact: Bool = false) -> some View {
        RailButtonRow(
            title: "Memory",
            systemImage: MemoryReviewSession.sidebarIcon,
            railItem: .memory,
            isSelected: vm.visibleCenterTabs(in: windowState).contains(.memory)
                && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) { vm.openMemoryPaneBeside() }
            },
            otherWindowDestination: .memory,
            help: memoryHelp,
            identifier: "studio.navigation.memory",
            isCompact: compact
        ) {
            vm.inWindow(windowState) { vm.openMemoryPane() }
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .memory)
            return studioCenterTabDragProvider(for: .memory)
        }
        .onAppear { goalTracker.configure(storage: vm.storage) }
    }

    /// Spaces (2026-10-07): ChatGPT's Space, the first row of the rail since
    /// the Notebooks home went (2026-10-09), with its own sidebar beside it
    /// and every notebook and course in its All list. Lit while the Space is
    /// on one of this window's panes — its lists, the Courses list, or the
    /// global Pages and Sites. Today's daily note is a page in it (⇧⌘D opens it
    /// from the View menu). A click shows the place the window last showed.
    /// `yieldsTo`: a shortcut kept on the strip is lit for the place on
    /// screen, and the Space's row gives the light to it.
    private func spaceButton(compact: Bool = false, yieldsTo shortcutIsLit: Bool = false) -> some View {
        RailButtonRow(
            title: StudioRailItem.space.title,
            systemImage: StudioRailItem.space.systemImage,
            railItem: .space,
            isSelected: windowState.showsSpace && !shortcutIsLit && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) {
                    vm.openCenterTabBeside(.artifacts)
                    vm.openArtifactsInReader()
                }
            },
            otherWindowDestination: .artifacts,
            help: "Open Spaces: your notebooks, pages, sites, pictures and ideas (⌘P)",
            identifier: "studio.navigation.space",
            isCompact: compact
        ) {
            vm.inWindow(windowState) { vm.openArtifactsInReader() }
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .artifacts)
            return studioCenterTabDragProvider(for: .artifacts)
        }
    }

    /// The Library (decisions v5, 2): the whole library, every
    /// kind, laid out for managing it. A place, like Memory: a pane with its
    /// ×, Open Beside, Open in Other Window and a drag. In a window holding a
    /// notebook it leaves the notebook the way the Space does; the notebook's
    /// row below brings it back.
    private func libraryButton(compact: Bool = false) -> some View {
        RailButtonRow(
            title: "Library",
            systemImage: StudioRailItem.library.systemImage,
            railItem: .library,
            isSelected: vm.visibleCenterTabs(in: windowState).contains(.library)
                && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) { vm.openCenterTabBeside(.library) }
            },
            otherWindowDestination: .library,
            help: "Open Library (⇧⌘L)",
            identifier: "studio.navigation.library",
            isCompact: compact
        ) {
            vm.inWindow(windowState) { vm.openLibraryView() }
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .library)
            return studioCenterTabDragProvider(for: .library)
        }
    }

    /// Plugins (2026-10-13), Codex's grid: every plugin and its state, and a
    /// plugin's page a click away. A place like the Library: a pane with its
    /// ×, Open Beside, Open in Other Window and a drag; a click shows the
    /// list, as Codex's Plugins does, and in a window holding a notebook it
    /// leaves the notebook the way the Library does.
    private func pluginsButton(compact: Bool = false) -> some View {
        RailButtonRow(
            title: StudioRailItem.plugins.title,
            systemImage: StudioRailItem.plugins.systemImage,
            railItem: .plugins,
            isSelected: vm.visibleCenterTabs(in: windowState).contains(.plugins)
                && !windowState.isVoiceWorkspacePresented,
            openBeside: {
                vm.inWindow(windowState) { vm.openCenterTabBeside(.plugins) }
            },
            otherWindowDestination: .plugins(.directory),
            help: "Open Plugins",
            identifier: "studio.navigation.plugins",
            isCompact: compact
        ) {
            vm.openPluginsPlace(nil, in: windowState)
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: .plugins)
            return studioCenterTabDragProvider(for: .plugins)
        }
    }

    // MARK: - Shortcuts

    /// A place the learner kept on the strip: its glyph, lit while the
    /// window shows it, its menu taking it off again. It drags as its
    /// Space sidebar row does, so a drag up or down the strip reorders the
    /// shortcuts: a place dropped on one lands above it.
    private func shortcutButton(_ shortcut: StudioRailShortcut, isSelected: Bool) -> some View {
        RailButtonRow(
            title: shortcut.title,
            systemImage: shortcut.systemImage,
            assetImage: shortcut.assetImage,
            isSelected: isSelected,
            otherWindowDestination: otherWindowDestination(for: shortcut),
            identifier: "studio.navigation.shortcut.\(shortcut.key)",
            isCompact: true,
            removeFromRail: {
                railShortcutsStorage = StudioRailShortcuts(storage: railShortcutsStorage)
                    .setting(shortcut, shown: false)
                    .storage
            }
        ) {
            openShortcut(shortcut)
        }
        .onDrag {
            shortcut.beginDrag()
            return shortcut.dragProvider()
        }
        .onDrop(of: [.studioRailShortcut], isTargeted: Binding(
            get: { shortcutDropBefore == shortcut },
            set: { targeted in
                if targeted {
                    shortcutDropBefore = shortcut
                } else if shortcutDropBefore == shortcut {
                    shortcutDropBefore = nil
                }
            }
        )) { providers in
            StudioDragVisibility.shared.endSoon()
            return keepDroppedShortcut(providers, before: shortcut)
        }
        .overlay(alignment: .top) {
            if shortcutDropBefore == shortcut, StudioDragVisibility.shared.draggedRailShortcut != shortcut {
                Capsule()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 24, height: 2)
                    .offset(y: -3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Whether this window shows the place: the Space on that place (its
    /// list, not a page opened from it), or the Courses pane.
    private func isShowing(_ shortcut: StudioRailShortcut) -> Bool {
        guard !windowState.holdsNotebookSlot, !windowState.isVoiceWorkspacePresented else { return false }
        let activeTabs = windowState.centerTabGroups.groups.map(\.activeTab)
        switch shortcut {
        case .place(let place):
            return activeTabs.contains(.artifacts) && windowState.spaceDestinationKey == place.key
        case .courses:
            return activeTabs.contains(.courses)
        }
    }

    /// Shows the place in this window as the Space sidebar's row does.
    private func openShortcut(_ shortcut: StudioRailShortcut) {
        vm.inWindow(windowState) {
            switch shortcut {
            case .place(let place): vm.showSpace(place, in: windowState)
            case .courses: vm.openCoursesListInReader(in: windowState)
            }
        }
    }

    private func otherWindowDestination(for shortcut: StudioRailShortcut) -> StudioWindowDestination? {
        switch shortcut {
        case .place(.pages): return .docs
        case .place(.sites): return .sites
        case .place: return nil
        case .courses: return .courses
        }
    }

    private var goalTracker: MemoryReviewEngagementTracker { MemoryReviewEngagementTracker.shared }

    private var memoryHelp: String {
        if case .done = goalTracker.state { return "Today's review is done" }
        if case .ended(let seconds) = goalTracker.state {
            let minutes = Int((seconds / 60).rounded())
            return minutes >= 1
                ? "Today's review ended after \(minutes) min"
                : "Today's review ended"
        }
        return vm.memoryCardCounts.line ?? "Nothing due today"
    }

    // MARK: - Chats

    /// A list draws this many chats, and this many more each time the
    /// learner scrolls to its end. It was ten behind a "Show 10 more" row
    /// until the product owner, on 2026-10-02: "instead of show 10 more i should just
    /// be able to scroll down and see all? also make it 20". The page still
    /// matters: a notebook keeps its whole history, and a list drawn whole
    /// would push the Chats section out of reach before anyone scrolled.
    static let chatListPageSize = 20

    static let looseChatListID = "chats"
    static let hiddenChatListID = "chats.hidden"
    static func notebookChatListID(_ notebookID: String) -> String { "notebook:\(notebookID)" }

    /// How many of a list's `total` chats the rail draws. `revealed` is the
    /// count scrolling to the list's end has reached (nil for a fresh list),
    /// and `requiredIndex` is the position of a chat that must stay visible —
    /// the open one — so selecting an old chat from Search or a deep link
    /// never lands on a row the rail then hides behind the fold.
    static func visibleChatCount(
        total: Int,
        revealed: Int?,
        requiredIndex: Int?,
        pageSize: Int = chatListPageSize
    ) -> Int {
        var count = max(revealed ?? pageSize, pageSize)
        if let requiredIndex {
            count = max(count, requiredIndex + 1)
        }
        return min(max(count, 0), max(total, 0))
    }

    /// The rows for one list of chats — a notebook's chats, the loose ones or
    /// the hidden ones — a page at a time: an empty marker after the last row
    /// drawn adds the next page when the rail's lazy stack builds it, which is
    /// as the learner scrolls it into view. Drag reordering keeps the whole
    /// list as its sibling set: a chat dropped on a visible row still lands
    /// among the same siblings whether or not the rest are drawn.
    @ViewBuilder
    private func chatList(
        _ sessions: [ReviewSessionRecord],
        listID: String,
        runningSessionIDs: Set<String>,
        indent: CGFloat = 8
    ) -> some View {
        let siblingIDs = sessions.map(\.id)
        let activeIDs = activeSessionIDs
        let visibleCount = Self.visibleChatCount(
            total: sessions.count,
            revealed: revealedChatCounts[listID],
            requiredIndex: sessions.lastIndex { activeIDs.contains($0.id) }
        )
        ForEach(sessions.prefix(visibleCount)) { session in
            chatRow(session, siblingIDs: siblingIDs, runningSessionIDs: runningSessionIDs, indent: indent)
        }
        if visibleCount < sessions.count {
            // Identified by the count it extends, so each page gets a fresh
            // marker: one that stayed on screen after a page landed (a tall
            // window) would never appear again to ask for the next.
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
                .id("\(listID).more.\(visibleCount)")
                .onAppear {
                    revealedChatCounts[listID] = visibleCount + Self.chatListPageSize
                }
        }
    }

    /// The chats the learner hid from the sidebar, listed beneath the loose
    /// chats only after the Chats header's menu revealed them: a hidden chat
    /// leaves no row behind, not even a count, so the rail reads as if it
    /// were gone. Once revealed, a "Hidden" marker row heads the list and
    /// folds it away again; the rows themselves offer Show, and a chat shown
    /// again returns to its notebook or the loose list.
    @ViewBuilder
    private func hiddenChatsFold(
        _ sessions: [ReviewSessionRecord],
        runningSessionIDs: Set<String>
    ) -> some View {
        RailShowMoreRow(
            title: "Hidden",
            accessibilityHint: "Fold the \(sessions.count) hidden chat\(sessions.count == 1 ? "" : "s") away",
            systemImage: "eye.slash",
            indent: 8
        ) {
            withAnimation(.easeInOut(duration: 0.16)) {
                isHiddenChatsExpanded = false
            }
        }
        .accessibilityIdentifier("studio.rail.hiddenChats")
        chatList(sessions, listID: Self.hiddenChatListID, runningSessionIDs: runningSessionIDs, indent: 12)
    }

    /// One chat's row. `reorder` replaces the list's own drop (the chats'
    /// order) where the row is in Pinned, whose drop moves a pin.
    private func chatRow(
        _ session: ReviewSessionRecord,
        siblingIDs: [String],
        runningSessionIDs: Set<String>,
        indent: CGFloat = 8,
        reorder: ((String) -> Void)? = nil
    ) -> some View {
        let isMemoryReview = MemoryReviewSession.isMemorySession(session.id)
        let isPinned = vm.isChatPinned(session.id)
        let isUnread = ChatReadMarks.shared.isUnread(session.id)
        return RailChatRow(
            sessionID: session.id,
            title: railChatTitle(session),
            // A team's snapshot is the one chat marked apart: nobody
            // continues it (docs/teams-design.md).
            systemImage: chatRowIcon(for: session),
            isSelected: activeSessionIDs.contains(session.id),
            isRunning: runningSessionIDs.contains(session.id),
            indent: indent,
            // A day's review stays under Memory wherever it is filed, so
            // offering to move it would promise a change the rail never shows.
            notebooks: MemoryReviewSession.isMemorySession(session.id) ? [] : vm.notebooks,
            // A Goal is the other home a chat can have (2026-09-20): the
            // submenu lists the open ones beneath the notebooks.
            goals: MemoryReviewSession.isMemorySession(session.id) ? [] : vm.allGoals.filter { !$0.isDone && !$0.isArchived },
            // The chats this row sits beside in the rail. Only they may be
            // dropped on it, so a reorder can never quietly refile a chat under
            // a different notebook — the notebook row's drop does that.
            siblingIDs: siblingIDs,
            displayedNotebookID: session.goalID,
            hasExplicitNotebook: session.goalID != nil,
            open: { vm.inWindow(windowState) { vm.requestResumeReviewSession(session.id) } },
            openBeside: { onOpenChatBeside(session.id) },
            moveToNotebook: { goalID in
                Task { await vm.moveReviewSession(session.id, toNotebook: goalID) }
            },
            reorder: reorder ?? { draggedSessionID in
                withAnimation(.easeInOut(duration: 0.16)) {
                    vm.reorderReviewSession(from: draggedSessionID, to: session.id)
                }
            },
            // Codex's Pin chat: a day's review is Memory's and never pins.
            isPinned: isPinned,
            togglePinned: isMemoryReview ? nil : {
                withAnimation(.easeInOut(duration: 0.16)) {
                    vm.setChatPinned(session.id, pinned: !isPinned)
                }
            },
            // Codex's dot, this Mac's: Mark as Read takes it off by hand,
            // Mark as Unread puts it on until the chat is opened again.
            isUnread: isUnread,
            toggleUnread: {
                if isUnread {
                    ChatReadMarks.shared.markRead(session.id)
                } else {
                    ChatReadMarks.shared.markUnread(session.id)
                }
            },
            rename: {
                renameText = session.title
                renamingSession = session
            },
            isHidden: session.isHidden,
            toggleHidden: {
                let hidden = !session.isHidden
                Task { await vm.setReviewSessionHidden(session.id, hidden: hidden) }
            },
            // A snapshot is already a team's, and a day's review is about the
            // learner; neither is offered to a team.
            shareWithTeam: session.isTeamSnapshot || MemoryReviewSession.isMemorySession(session.id)
                ? nil
                : { teamID in Task { await vm.shareChat(session.id, withTeam: teamID) } },
            newNotebookFromChat: session.isTeamSnapshot || MemoryReviewSession.isMemorySession(session.id)
                || vm.isActiveLibraryReadOnly
                ? nil
                : { notebookFromChatRequest = NotebookFromChatRequest(sessionID: session.id, title: session.title) },
            // Delete asks first, as Codex's does: it is the chat's fate, where
            // Hide is only the list's.
            delete: { deletingSession = session }
        )
        .onDrag { () -> NSItemProvider in
            StudioDragVisibility.shared.begin(sessionID: session.id)
            return reviewSessionDragProvider(for: ReviewSessionTransfer(from: session))
        }
    }

    /// The row's leading glyph. A transcript a team shares is a snapshot
    /// nobody continues; the pair of figures marks it apart from the
    /// learner's own chats. Every other chat draws none, as in ChatGPT's
    /// sidebar (product owner, 2026-10-06: "fewer buttons and bells and
    /// whistles"): the iPhone and CarPlay marks, the scheduled run's clock and
    /// the memory review's brain went that day. A memory review is listed
    /// under Memory, not in these lists, and a task's chat takes its task's
    /// title.
    private func chatRowIcon(for session: ReviewSessionRecord) -> String? {
        session.isTeamSnapshot ? "person.2" : nil
    }

    private func deleteSession(_ session: ReviewSessionRecord) {
        // Close first, before waiting for the storage actor. A CloudKit merge can
        // keep that actor busy for a while; leaving the selected chat active in
        // the meantime lets an in-flight response save back into the session the
        // learner just deleted.
        StudioAssistantSessionStore.deleteSessionEverywhere(session.id)
        Task {
            await vm.deleteReviewSessionLink(session.id)
        }
    }

    // MARK: - Account

    /// The account control. In the icon rail (`compact`)
    /// it is the avatar alone, with the MCP status light on its corner while
    /// the connection needs attention; the menu it opens is the same.
    private func accountMenuButton(compact: Bool = false) -> some View {
        Button {
            showsAccountMenu.toggle()
        } label: {
            if compact {
                accountAvatar(size: 24)
                    .overlay(alignment: .bottomTrailing) {
                        if showsMCPStatusLightOnButton {
                            mcpStatusLight
                                .offset(x: 2, y: 2)
                        }
                    }
                    .frame(width: 36, height: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                accountMenuLabel
            }
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .modifier(RailHelpOrTooltip(text: compact ? "Account" : accountButtonHelpText, isCompact: compact))
        .accessibilityLabel("Account menu")
        .accessibilityValue(accountButtonAccessibilityValue)
        .accessibilityIdentifier(AccessibilityID.accountMenuButton)
        .popover(
            isPresented: $showsAccountMenu,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: compact ? .trailing : .bottom
        ) {
            accountMenu
        }
        .onChange(of: showsAccountMenu) { _, isShown in
            guard isShown else { return }
            // Whether usage is comped is only as fresh as the last balance fetch,
            // which is otherwise launch and Settings. Opening the menu asks again.
            if showsCompOnScreen {
                Task { await account.refresh(minimumInterval: 30, silently: true) }
            }
        }
    }

    private var accountMenuLabel: some View {
        // The avatar and the name, as ChatGPT's sidebar ends (product owner,
        // 2026-10-06: "fewer buttons and bells and whistles"). The open
        // team's badge says whose library this is, and the MCP status light
        // rides inside the button only while the connection needs attention;
        // the comp crown is the account menu's "Usage is paid for" row now.
        // Their click actions live in the menu this button opens.
        HStack(spacing: 8) {
            accountAvatar(size: 22)
            Text(MacAccountUser.leadingName(of: accountFullName) ?? "Account")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let team = vm.activeTeam {
                activeTeamBadge(team)
                    .transition(.opacity)
            }
            if showsMCPStatusLightOnButton {
                mcpStatusLight
                    .padding(.trailing, 2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// The account menu is shaped like Claude's: who you are, then a short
    /// flat list of account actions. Which library is open is chosen in the
    /// Space sidebar, not here (product owner, 2026-10-17: "there is no team
    /// library anymore ... that is now in spaces"), and team management lives
    /// in Settings, scoped to the open team (product owner, 2026-09-08).
    private var accountMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                accountAvatar(size: 30)
                Text(accountFullName ?? "Account")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)

            Divider()

            accountMenuActions
        }
        .padding(8)
        .frame(width: 232)
    }

    @ViewBuilder
    private var accountMenuActions: some View {
        // The free days' count, quietly: "29 days free left". It opens
        // Billing, where the deal is (docs/pricing-pro-design.md → The free
        // days).
        if let freeDays = account.freeDaysStatus {
            accountMenuAction(
                title: freeDays,
                systemImage: "gift",
                accessibilityIdentifier: "rail.freeDays"
            ) {
                showsAccountMenu = false
                onOpenSettings(.aiBilling)
            }
            .help("Open Billing")
        }

        if showsMCPStatusLight {
            accountMenuAction(
                title: mcpStatusLightLabel,
                icon: mcpStatusLight,
                accessibilityIdentifier: AccessibilityID.mcpStatusButton
            ) {
                showsAccountMenu = false
                // Locked, the way back to MCP is Billing, where it is paid for.
                onOpenSettings(account.isMCPLocked ? .aiBilling : .mcp)
            }
            .help(account.isMCPLocked ? "Open Billing" : "Open MCP settings")
            .accessibilityValue(mcpStatusLightLabel)
        }

        accountMenuAction(
            title: "My Settings",
            systemImage: "gearshape",
            accessibilityIdentifier: AccessibilityID.settingsButton
        ) {
            showsAccountMenu = false
            onOpenSettings(nil)
        }

        if let team = vm.activeTeam {
            accountMenuAction(
                title: "\(team.name) Settings",
                systemImage: team.canEdit ? "person.2.badge.gearshape" : "lock",
                accessibilityIdentifier: "rail.teamSettings"
            ) {
                showsAccountMenu = false
                onOpenSettings(.teamGeneral)
            }
            .help(team.canEdit ? "Open the team's settings" : "Open the team's settings (read-only library)")
        }

        accountMenuAction(
            title: "Sign Out",
            systemImage: "rectangle.portrait.and.arrow.right",
            accessibilityIdentifier: AccessibilityID.signOutButton
        ) {
            showsAccountMenu = false
            account.signOut()
        }
    }

    private func accountMenuAction(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        accountMenuAction(
            title: title,
            icon: Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary),
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        )
    }

    private func accountMenuAction<Icon: View>(
        title: String,
        subtitle: String? = nil,
        icon: Icon,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 32)
            .padding(.vertical, subtitle == nil ? 0 : 4)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// Names the open team on the account button, where the switcher now
    /// lives, so a team library is never mistaken for My Library.
    private func activeTeamBadge(_ team: TeamRecord) -> some View {
        HStack(spacing: 3) {
            Image(systemName: team.canEdit ? "person.2.fill" : "lock.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(team.name)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .accessibilityHidden(true)
    }

    private func accountAvatar(size: CGFloat) -> some View {
        Text(MacAccountUser.monogram(of: accountFullName) ?? "?")
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.08), in: Circle())
            .overlay { Circle().stroke(Color.primary.opacity(0.08)) }
    }

    /// The MCP light is decoration inside the account button; the menu row that
    /// reuses it is where clicking leads to MCP settings.
    private var mcpStatusLight: some View {
        Circle()
            .fill(mcpStatusLightColor)
            .frame(width: 8, height: 8)
            .overlay {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    // MARK: Comp

    /// The comp pays only for what goes through the proxy. With the learner's
    /// own key stored, everything the key
    /// covers goes straight to its router and is billed there, so the comp row
    /// said "Usage is paid for by ForeverLM · $0.00 used today" while the key
    /// paid for the day's chats (2026-09-27). The help text names the key instead.
    private var ownKeyPays: Bool { account.ownKey != nil }

    private var compHelpText: String {
        if let own = account.ownKey, ownKeyPays {
            return "\(own.router.billedScopeCapitalized) are billed to your \(own.router.label) account"
        }
        return "Usage is paid for by ForeverLM on this account"
    }

    /// The button's tooltip and the comp refresh on opening the menu: on for a comped account unless the learner switched the crown
    /// off, and never while screen record mode is filming (usage stays off
    /// screen). The button itself carries no crown since 2026-10-06.
    private var showsCompOnScreen: Bool {
        account.usageIsComped && showsCompCrown && !vm.isScreenRecordModeActive
    }

    private var accountButtonHelpText: String {
        var parts = ["Account menu"]
        if let team = vm.activeTeam {
            parts.append(team.canEdit ? "Team library: \(team.name)" : "Team library: \(team.name), read only")
        }
        // The tooltip is on screen too; VoiceOver's value below keeps it.
        if showsCompOnScreen { parts.append(compHelpText) }
        if showsMCPStatusLight { parts.append(mcpStatusLightLabel) }
        return parts.joined(separator: " · ")
    }

    private var accountButtonAccessibilityValue: String {
        var parts: [String] = ["Library: \(vm.activeLibraryTitle)"]
        if account.usageIsComped { parts.append(compHelpText) }
        if showsMCPStatusLight { parts.append(mcpStatusLightLabel) }
        return parts.joined(separator: ", ")
    }

    /// The light on the account button: only while assistants cannot reach
    /// this Mac — connecting (amber), offline or failed (red). Connected
    /// draws nothing (2026-10-06; it was a green dot at all times), and so
    /// do integrations the learner turned off, which is a choice rather than
    /// something to fix; `studio.showMCPStatusLight` turns it off altogether.
    /// The account menu's MCP row keeps saying how the connection stands.
    private var showsMCPStatusLightOnButton: Bool {
        guard showsMCPStatusLight else { return false }
        guard assistantIntegrationsEnabled else { return false }
        switch mcpLauncher.state {
        case .running, .servedElsewhere:
            return false
        case .starting, .settingUp, .idle, .failed:
            return true
        }
    }

    private var mcpStatusLightColor: Color {
        guard assistantIntegrationsEnabled else { return .red }
        switch mcpLauncher.state {
        // Assistants reach the library either way; the label says which Mac answers.
        case .running, .servedElsewhere:
            return .green
        case .starting, .settingUp:
            return .yellow
        case .idle, .failed:
            return .red
        }
    }

    /// While MCP is locked (the free days over, nothing paid) the connection
    /// is stopped on purpose (product owner, 2026-10-10), so the light says
    /// so rather than calling it a failure.
    private var mcpStatusLightLabel: String {
        guard assistantIntegrationsEnabled else { return "MCP disabled" }
        if account.isMCPLocked { return "MCP locked" }
        switch mcpLauncher.state {
        case .running:
            return "MCP connected"
        case .servedElsewhere:
            return "MCP served by another Mac"
        case .starting, .settingUp:
            return "MCP connecting"
        case .idle:
            return "MCP offline"
        case .failed:
            return "MCP connection failed"
        }
    }

}

// MARK: - Update button

/// Codex-style update pill at the trailing edge of the rail's footer, beside
/// Voice. Sparkle keeps its own install window. Clicking the pill runs a fresh
/// check, so the dialog that opens offers the newest build on the feed rather
/// than the one the pill was found with (see `AppUpdateOfferPolicy`); during a
/// download or install it brings that progress back into focus instead.
struct RailUpdateButton: View {
    @ObservedObject var updateController: AppUpdateController
    /// In a notebook window's icon strip: a blue disc with the phase's glyph,
    /// the word in its help.
    var isCompact = false

    @State private var isHovering = false

    private var compactSymbol: String {
        switch updateController.phase {
        case .idle, .available: return "arrow.down"
        case .downloading, .preparing: return "arrow.down"
        case .readyToInstall, .relaunchToFinish: return "arrow.clockwise"
        }
    }

    private var versionText: String {
        if let version = updateController.phase.version {
            return "ForeverLM \(version)"
        }
        return "ForeverLM update"
    }

    private var helpText: String {
        switch updateController.phase {
        case .idle:
            return "ForeverLM is up to date"
        case .available:
            return "\(versionText) is available — click to update"
        case .downloading:
            return "Downloading \(versionText) — click to show progress"
        case .preparing:
            return "Preparing \(versionText) — click to show progress"
        case .readyToInstall:
            return "\(versionText) is ready — click to install and relaunch"
        case .relaunchToFinish:
            return "\(versionText) is already installed — click to relaunch"
        }
    }

    /// One word: the pill is a status, the tooltip carries the sentence.
    private var labelText: String {
        switch updateController.phase {
        case .idle, .available:
            return "Update"
        case .downloading, .preparing:
            return "Updating"
        case .readyToInstall, .relaunchToFinish:
            return "Restart"
        }
    }

    /// Relaunching needs no Sparkle session, so it stays clickable while
    /// Sparkle cannot check.
    private var isRelaunchOnly: Bool {
        if case .relaunchToFinish = updateController.phase { return true }
        return false
    }

    private var isInProgress: Bool {
        switch updateController.phase {
        case .downloading, .preparing:
            return true
        case .idle, .available, .readyToInstall, .relaunchToFinish:
            return false
        }
    }

    var body: some View {
        Button {
            updateController.checkForUpdates()
        } label: {
            HStack(spacing: 5) {
                if isInProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
                if isCompact {
                    if !isInProgress {
                        Image(systemName: compactSymbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text(labelText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isCompact ? 0 : 10)
            .frame(width: isCompact ? 24 : nil, height: isCompact ? 24 : 22)
            // The pill is opaque, so the shared grey hover wash would paint
            // behind it and never show. Brighten the fill itself instead.
            .background(
                Capsule().fill(Color.blue)
                    .overlay { Capsule().fill(Color.white.opacity(isHovering ? 0.14 : 0)) }
            )
            // The same 32pt row height as Voice and the MCP light, so the pill
            // centres on the footer's rhythm without stretching the hit area.
            .frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .disabled(!updateController.canCheckForUpdates && !isRelaunchOnly)
        .modifier(RailHelpOrTooltip(text: helpText, isCompact: isCompact))
        .accessibilityLabel("App update")
        .accessibilityValue(helpText)
        .accessibilityIdentifier(AccessibilityID.appUpdateButton)
    }
}

// MARK: - Current macOS user

/// User-owned display identity for account chrome and the idle chat greeting.
/// The Mac account name supplies the first value; the synced preference is the
/// durable authority after the user edits it on any client.
enum MacAccountUser {
    static let displayNamePreferenceKey = "account.displayName"
    /// Synced: whether the account menu shows a complimentary account's
    /// "Usage is paid for" row with its crown, and the web's footer its crown
    /// (the Mac's account button carried one too until 2026-10-06). On unless
    /// the learner hides them, for a screenshot or a recording; Settings ›
    /// AI Usage still says who pays.
    static let showsCompCrownPreferenceKey = "account.showsCompCrown"
    /// The web Studio's name field takes the same length.
    static let maximumDisplayNameLength = 120

    /// Full name from the macOS account, used only to seed the user-owned synced
    /// profile name. A name the user edits on web or another Mac wins thereafter.
    private static let systemFullName: String? = {
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }()

    static var fullName: String? {
        resolvedFullName(saved: UserDefaults.standard.string(forKey: displayNamePreferenceKey))
    }

    /// The name to show for a saved preference value. A view that observes the
    /// key passes the value it read, so a rename redraws it.
    static func resolvedFullName(saved: String?) -> String? {
        // Release/UI-test captures must never inherit the developer's local
        // account name. This is display-only and does not touch synced state.
        if UITestConfiguration.isUITesting { return "Learner" }
        let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved : systemFullName
    }

    static func seedSyncedDisplayNameIfNeeded() {
        let saved = UserDefaults.standard.string(forKey: displayNamePreferenceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard saved?.isEmpty != false, let systemFullName else { return }
        PreferenceStore.set(systemFullName, forKey: displayNamePreferenceKey)
    }

    /// The name as it would be saved: trimmed, and nil when there is nothing
    /// to save. A blank field keeps the current name rather than clearing it,
    /// as on the web; a name past the limit is refused, not cut.
    static func normalizedDisplayName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maximumDisplayNameLength else { return nil }
        return name
    }

    /// Renames the learner on every client. Returns false, writing nothing,
    /// for a name `normalizedDisplayName` refuses.
    @discardableResult
    static func setDisplayName(_ raw: String) -> Bool {
        guard let name = normalizedDisplayName(raw) else { return false }
        PreferenceStore.set(name, forKey: displayNamePreferenceKey)
        return true
    }

    static var showsCompCrown: Bool {
        UserDefaults.standard.object(forKey: showsCompCrownPreferenceKey) as? Bool ?? true
    }

    static func setShowsCompCrown(_ shows: Bool) {
        PreferenceStore.set(shows, forKey: showsCompCrownPreferenceKey)
    }

    /// Shown in place of the learner's name while Screen record mode is on. A
    /// take films the account row and the New chat greeting, and the website
    /// must not carry the admin's own name (2026-09-25: every clip of that
    /// night showed it). A made-up person's name, so a greeting reads as a
    /// person's and not a role's (product owner, 2026-10-12: "let's not do
    /// learner; let's maybe do Richard"). Display only: what is saved, synced
    /// and signed with (`fullName`, CloudKit, Doc sharing) is untouched.
    static let recordingStandInName = "Richard"

    /// The name to *show* for a saved preference value: `resolvedFullName`,
    /// or the stand-in while Screen record mode is on. Settings' name field
    /// reads `resolvedFullName`, so editing never saves the stand-in.
    static func displayedFullName(saved: String?, recording: Bool = ScreenRecordMode.isEffective) -> String? {
        recording ? recordingStandInName : resolvedFullName(saved: saved)
    }

    /// First given name, for casual greetings ("Good morning, the product owner"), or
    /// the stand-in while Screen record mode is on.
    static var firstName: String? {
        leadingName(of: displayedFullName(saved: UserDefaults.standard.string(forKey: displayNamePreferenceKey)))
    }

    static func leadingName(of fullName: String?) -> String? {
        fullName?.components(separatedBy: " ").first
    }

    static var initials: String? { monogram(of: fullName) }

    static func monogram(of fullName: String?) -> String? {
        guard let fullName else { return nil }
        let parts = fullName.components(separatedBy: " ").filter { !$0.isEmpty }
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}

// MARK: - Sidebar toggle

/// Compact show/hide control for the navigation rail, styled to sit in the
/// window's top-left chrome next to the macOS traffic lights (Claude/Codex-style).
struct NavigationRailToggle: View {
    @Binding var isVisible: Bool

    var body: some View {
        StudioChromeIconButton(
            systemImage: "sidebar.left",
            label: isVisible ? "Hide sidebar" : "Show sidebar"
        ) {
            isVisible.toggle()
        }
    }
}

/// ‹ › beside the traffic lights, Codex's (product owner, 2026-10-12: "can do
/// front and back arrow"): back to the place this window showed before, and
/// forward again (`StudioWindowState.placeHistory`). Greyed where there is
/// nowhere to go. It also settles each place the window comes to rest on,
/// here rather than in `StudioView`, so only this small view redraws as the
/// window moves.
struct WindowPlaceArrows: View {
    @Environment(StudioWindowState.self) private var windowState
    /// Reopens what `place` showed that the window state does not hold: its
    /// chat and its source.
    let reopen: (StudioWindowPlace) -> Void
    @State private var settle: Task<Void, Never>?

    var body: some View {
        HStack(spacing: StudioTopBar.leadingControlsSpacing) {
            arrow("arrow.left", label: "Back", identifier: "studio.window.back", enabled: windowState.canGoBackInPlaces) {
                if let place = windowState.goBackInPlaces() { reopen(place) }
            }
            arrow("arrow.right", label: "Forward", identifier: "studio.window.forward", enabled: windowState.canGoForwardInPlaces) {
                if let place = windowState.goForwardInPlaces() { reopen(place) }
            }
        }
        // A move changes the window in several steps — the pane, then the
        // chat or the source it shows — so a place is settled once the
        // window has stopped changing, as one step back.
        .onChange(of: windowState.currentPlace.identity, initial: true) { _, _ in
            settle?.cancel()
            settle = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                windowState.notePlaceSettled()
            }
        }
    }

    private func arrow(
        _ systemImage: String,
        label: String,
        identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        StudioChromeIconButton(systemImage: systemImage, label: label) {
            withAnimation(.easeInOut(duration: 0.18)) { action() }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Rows

/// One of the rail's top rows: an icon and a title, in one colour, as
/// ChatGPT's sidebar draws them (product owner, 2026-10-06: "cleaner and fewer
/// buttons and bells and whistles"). A selected row is told by its fill
/// alone; its icon is never tinted. Open Beside, Open in Other Window and
/// Hide are on its menu, and the row drags to the center's edge; the
/// hover glyph that opened it beside went that day.
private struct RailButtonRow: View {
    let title: String
    var systemImage: String? = nil
    /// A picture drawn in the strip in place of `systemImage`: a kept
    /// place's own logo (`StudioRailShortcut.assetImage`).
    var assetImage: String? = nil
    /// Non-nil for a row the learner may hide: its menu then ends with Hide
    /// and the Show in Sidebar submenu that brings any hidden row back.
    var railItem: StudioRailItem? = nil
    var isSelected = false
    var openBeside: (() -> Void)?
    /// What this row opens, when it is a destination that can be sent to
    /// another window. Nil for a row that is only an action here.
    var otherWindowDestination: StudioWindowDestination? = nil
    var help: String? = nil
    var identifier: String? = nil
    /// Drawn in a notebook window's icon strip (`StudioNavigationRail`'s
    /// compact rail): the glyph alone, its title as the help, the same menu.
    var isCompact = false
    /// Non-nil for a shortcut the learner kept on the strip
    /// (`StudioRailShortcuts`): its menu then offers Remove from Sidebar and
    /// the Show in Sidebar submenu.
    var removeFromRail: (() -> Void)? = nil
    let action: () -> Void
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @SyncedStorage(wrappedValue: "", StudioRailHiddenItems.storageKey) private var hiddenRailItemsStorage: String
    @State private var hovering = false

    var body: some View {
        if isCompact {
            compactBody
        } else {
            fullBody
        }
    }

    private var iconStyle: Color {
        isSelected ? Color.primary : Color.secondary
    }

    private var compactBody: some View {
        Button(action: action) {
            RailGlyph(systemImage: systemImage ?? "circle", assetImage: assetImage, isSelected: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(StudioSelectionBackground(isSelected: isSelected, isHovered: hovering))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .railTooltip(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    private var fullBody: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(iconStyle)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, StudioDesign.Spacing.xSmall)
            .frame(minHeight: StudioDesign.Metrics.navigationRowMinHeight)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(StudioSelectionBackground(isSelected: isSelected, isHovered: hovering))
        .help(help ?? "")
        .accessibilityIdentifier(identifier ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
            if let openBeside {
                Button("Open Beside", systemImage: "rectangle.split.2x1", action: openBeside)
            }
            if let otherWindowDestination {
                OpenStudioDestinationInOtherWindowMenu(
                    destination: otherWindowDestination,
                    currentWindowState: windowState,
                    openNewWindow: { openWindow(id: "studio") }
                )
            }
            if let railItem {
                if openBeside != nil || otherWindowDestination != nil {
                    Divider()
                }
                Button {
                    hiddenRailItemsStorage = StudioRailHiddenItems(storage: hiddenRailItemsStorage)
                        .setting(railItem, hidden: true)
                        .storage
                } label: {
                    Label("Hide \(title)", systemImage: "eye.slash")
                }
                .accessibilityIdentifier("studio.navigation.hide.\(railItem.rawValue)")
                RailItemVisibilityMenu()
            }
            if let removeFromRail {
                if otherWindowDestination != nil {
                    Divider()
                }
                Button(action: removeFromRail) {
                    Label("Remove from Sidebar", systemImage: "pin.slash")
                }
                RailItemVisibilityMenu()
            }
    }
}

/// An icon strip glyph in its 36 × 30 square. Lit, a symbol is filled, as
/// Codex's strip draws its lit icon (measured off its window, 2026-10-12); a
/// symbol with no fill keeps its outline. A logo (`assetImage`) is drawn as
/// it is, the selection fill behind it saying it is lit.
private struct RailGlyph: View {
    let systemImage: String
    var assetImage: String? = nil
    var isSelected = false

    var body: some View {
        Group {
            if let assetImage {
                Image(assetImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .symbolVariant(isSelected ? .fill : .none)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .frame(width: 36, height: 30)
    }
}

/// The strip's ⋯, Codex's: every place not kept on the strip, opened with a
/// click, and Show in Sidebar, which keeps one there or hides a row. Drawn
/// whatever the learner hid, so the way back to a hidden row is always here.
private struct RailMoreButton: View {
    /// The places to list: the shortcuts the strip does not draw.
    let places: [StudioRailShortcut]
    let open: (StudioRailShortcut) -> Void
    @State private var hovering = false

    var body: some View {
        // A single Image label in a `.button` Menu, sized from outside: a
        // macOS Menu drops any chrome inside its label.
        Menu {
            ForEach(places) { place in
                Button { open(place) } label: {
                    Label(place.title, systemImage: place.systemImage)
                }
            }
            if !places.isEmpty {
                Divider()
            }
            RailItemVisibilityMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 30)
        .background(StudioSelectionBackground(isSelected: false, isHovered: hovering))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .railTooltip("More")
        .accessibilityLabel("More")
        .accessibilityIdentifier("studio.navigation.more")
        .onHover { hovering = $0 }
    }
}

/// Show in Sidebar: one checkmark per hideable rail row, then one per place
/// the strip can keep as a shortcut (`StudioRailShortcuts`). It sits on every
/// hideable row's menu, every shortcut's, the ⋯'s and the Notebooks header's,
/// so a row that has been hidden is always one right-click away from coming
/// back.
private struct RailItemVisibilityMenu: View {
    @Environment(StudioViewModel.self) private var vm
    @SyncedStorage(wrappedValue: "", StudioRailHiddenItems.storageKey) private var hiddenRailItemsStorage: String
    @SyncedStorage(wrappedValue: "", StudioRailShortcuts.storageKey) private var railShortcutsStorage: String

    var body: some View {
        let hidden = StudioRailHiddenItems(storage: hiddenRailItemsStorage)
        let shortcuts = StudioRailShortcuts(storage: railShortcutsStorage)
        Menu {
            ForEach(StudioRailItem.allCases) { item in
                Toggle(isOn: Binding(
                    get: { !hidden.contains(item) },
                    set: { shown in
                        hiddenRailItemsStorage = StudioRailHiddenItems(storage: hiddenRailItemsStorage)
                            .setting(item, hidden: !shown)
                            .storage
                    }
                )) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            Divider()
            ForEach(StudioRailShortcut.offered(listsCanvases: vm.listsCanvases)) { shortcut in
                Toggle(isOn: Binding(
                    get: { shortcuts.contains(shortcut) },
                    set: { shown in
                        railShortcutsStorage = StudioRailShortcuts(storage: railShortcutsStorage)
                            .setting(shortcut, shown: shown)
                            .storage
                    }
                )) {
                    Label(shortcut.title, systemImage: shortcut.systemImage)
                }
            }
        } label: {
            Label("Show in Sidebar", systemImage: "sidebar.left")
        }
        .accessibilityIdentifier("studio.navigation.showInSidebar")
    }
}

/// One notebook, listed under the Notebooks section header. Two states, deliberately
/// distinct: `isSelected` is "the reader column is showing this notebook" and gets
/// the usual row highlight, while `isActive` is the weaker "this notebook is open"
/// — a bolder title, no background. The rail keeps showing the
/// active notebook after the column moves on to a source, so a new chat still gets
/// filed beneath it; without the split, that would read as a second selected row
/// competing with the open chat. On hover the row reveals a plus that starts a
/// chat in this notebook. Notebook management actions live on the notebook page.
private struct RailNotebookRow: View {
    @Environment(StudioViewModel.self) private var vm
    private let dragVisibility = StudioDragVisibility.shared
    let goal: LearningGoalRecord
    /// Its emoji is the row's icon, as in the Space's list.
    let notebookTitle: NotebookTitle
    let isActive: Bool
    let isSelected: Bool
    let isExpanded: Bool
    /// Its chats that read as unread on this Mac (`ChatReadMarks`): folded,
    /// the row carries Codex's dot for them, and its menu Mark All as Read.
    let unreadChatIDs: [String]
    let open: () -> Void
    let toggleExpanded: () -> Void
    let newChat: () -> Void

    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false
    @State private var isTargeted = false
    @State private var showDeleteConfirm = false
    /// The notebook's Share popover, from Share… on the row's menu.
    @State private var isShowingShare = false

    /// True while a source drag is in flight that this notebook doesn't already
    /// hold. Drives both the drop highlight and whether a drop is accepted, so a
    /// notebook you can't add to never lights up.
    private var canAcceptCurrentDrag: Bool {
        notebookCanAcceptCurrentDrag(goal: goal, dragVisibility: dragVisibility)
    }

    private var supportedDropTypes: [UTType] {
        mcpSourceContextDropTypes + [.reviewSession, .studioNotebook]
    }

    private var canAcceptNotebookDrag: Bool {
        guard let draggedNotebookID = dragVisibility.draggedNotebookID else { return false }
        return draggedNotebookID != goal.id
    }

    private var title: String {
        notebookTitle.text.isEmpty ? "Untitled notebook" : notebookTitle.text
    }

    private var newChatGlyph: some View {
        Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    private var foldGlyph: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 8) {
                    NotebookIconView(notebookID: goal.id, size: 16, cornerRadius: 4) {
                        Text(notebookTitle.displayIcon)
                            .font(.system(size: 12))
                    }
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint("Opens the notebook in this window")

            // The + and the chevron are built only while they show, a hidden
            // glyph holding each one's place. A button at opacity 0 is still
            // a live control, and while an assistive app reads the screen
            // SwiftUI walks every control in the window for each one an
            // update builds (2026-10-03). The row's actions below reach both
            // with no pointer.
            if hovering {
                Button(action: newChat) {
                    newChatGlyph
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .help("New chat in this notebook")
            } else if !isExpanded, !unreadChatIDs.isEmpty {
                // A folded notebook holding an unread chat shows Codex's dot,
                // as a Codex project does; unfolded, the chat's own row has it.
                RailUnreadDot()
                    .frame(width: 20, height: 20)
            } else {
                newChatGlyph
                    .hidden()
            }

            // The chats' fold, apart from opening: the row's click opens the
            // notebook, this shows or hides its chats beneath it.
            if hovering || isExpanded {
                Button(action: toggleExpanded) {
                    foldGlyph
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .help(isExpanded ? "Hide chats" : "Show chats")
                .accessibilityLabel(isExpanded ? "Hide chats in \(title)" : "Show chats in \(title)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else {
                foldGlyph
                    .hidden()
            }

        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, StudioDesign.Spacing.xSmall)
        .frame(minHeight: StudioDesign.Metrics.navigationRowMinHeight)
        .background(StudioSelectionBackground(isSelected: isSelected, isHovered: hovering))
        .overlay {
            // Mounted only while a drag could land here: at rest this overlay
            // put an animatable stroke + fill node on every rail row, which
            // multiplied into visible AttributeGraph cost on each render pass.
            if canAcceptCurrentDrag || canAcceptNotebookDrag || isTargeted {
                StudioDropZoneOverlay(
                    isActive: isTargeted && (canAcceptCurrentDrag || canAcceptNotebookDrag),
                    isVisible: canAcceptCurrentDrag || canAcceptNotebookDrag,
                    cornerRadius: 7,
                    inset: 0
                )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(unreadChatIDs.isEmpty ? "" : "Unread chats")
        // The + and the chevron, for VoiceOver: it has no pointer to bring
        // them out, and neither is on the right-click menu.
        .accessibilityAction(named: Text("New Chat in Notebook"), newChat)
        .accessibilityAction(named: Text(isExpanded ? "Hide Chats" : "Show Chats"), toggleExpanded)
        // Pin keeps a notebook in the rail whatever Recent does; Unpin and
        // Archive take it off. Without these the only routes were the Space's
        // row and the open notebook's own page.
        .contextMenu {
            OpenStudioDestinationInOtherWindowMenu(
                destination: .notebook(goal.id),
                currentWindowState: windowState,
                openNewWindow: { openWindow(id: "studio") }
            )
            Divider()
            // Codex's Mark all as read on a project.
            if !unreadChatIDs.isEmpty {
                Button("Mark All as Read", systemImage: "checkmark.circle") {
                    for id in unreadChatIDs { ChatReadMarks.shared.markRead(id) }
                }
            }
            // Pinning is this learner's own rail, not the team's Notebook, so
            // a read-only library does not disable it.
            NotebookPinToggleButton(goal: goal)
            NotebookCoverMenuItems(notebookID: goal.id)
                .disabled(vm.isActiveLibraryReadOnly)
            Button("Archive Notebook", systemImage: "archivebox") {
                Task { await vm.setGoalStatus(goalID: goal.id, status: .archived) }
            }
            .disabled(vm.isActiveLibraryReadOnly)
            Divider()
            Button("Share…", systemImage: "person.badge.plus") { isShowingShare = true }
            ShareWithTeamMenu { teamID in
                Task { await vm.shareNotebook(goal.id, withTeam: teamID) }
            }
            Divider()
            Button("Delete Notebook…", systemImage: "trash", role: .destructive) {
                showDeleteConfirm = true
            }
            .disabled(vm.isActiveLibraryReadOnly)
        }
        .notebookDeleteConfirmation(goal: goal, isPresented: $showDeleteConfirm)
        .popover(isPresented: $isShowingShare, arrowEdge: .trailing) {
            NotebookSharePopover(goal: goal, close: { isShowingShare = false })
                .environment(vm)
        }
        .onHover { hovering = $0 }
        .onDrag {
            dragVisibility.begin(notebookID: goal.id)
            return notebookDragProvider(for: StudioNotebookTransfer(notebookID: goal.id), title: title)
        } preview: {
            Label {
                Text(title)
            } icon: {
                NotebookIconView(notebookID: goal.id, size: 16, cornerRadius: 4) {
                    Text(notebookTitle.displayIcon)
                }
            }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        // Drop a source straight onto the row to add it to that notebook, or
        // drop a chat to move the conversation into the notebook. Notebook payloads
        // use the same destination without interfering with either existing type.
        .onDrop(of: supportedDropTypes, isTargeted: Binding(
            get: { isTargeted },
            set: { isTargeted = $0 && (canAcceptCurrentDrag || canAcceptNotebookDrag) }
        )) { providers in
            // Accept on the payload alone — `canAcceptCurrentDrag` races the mouse-up
            // monitors that clear drag state as the drop fires (see the Notebook pill).
            StudioDragVisibility.shared.endSoon()
            if reorderDroppedNotebook(providers) {
                return true
            }
            if moveDroppedChat(providers) {
                return true
            }
            return NotebookSourceDropHandler.handle(providers: providers, vm: vm, notebookID: goal.id)
        }
    }

    private func reorderDroppedNotebook(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.studioNotebook.identifier)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.studioNotebook.identifier) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(StudioNotebookTransfer.self, from: data) else { return }
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.16)) {
                    vm.reorderNotebook(from: transfer.notebookID, to: goal.id)
                }
            }
        }
        return true
    }

    private func moveDroppedChat(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.reviewSession.identifier)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.reviewSession.identifier) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(ReviewSessionTransfer.self, from: data) else { return }
            Task { @MainActor in
                await vm.moveReviewSession(transfer.sessionID, toNotebook: goal.id)
            }
        }
        return true
    }
}

/// A notebook's drag: the rail's rows, and the Canvas Library's notebooks.
func notebookDragProvider(for transfer: StudioNotebookTransfer, title: String) -> NSItemProvider {
    let provider = NSItemProvider()
    if let data = try? JSONEncoder().encode(transfer) {
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.studioNotebook.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
    }
    provider.suggestedName = title
    return provider
}

/// A previous-chat row: opens the chat on click and reveals an ellipsis menu on
/// hover (Claude-style) with rename, Move to Notebook, and delete actions. The
/// same actions are mirrored in a right-click context menu. Dragging one chat
/// onto another in the same section rearranges the list.
private struct RailChatRow: View {
    private let dragVisibility = StudioDragVisibility.shared
    let sessionID: String
    let title: String
    /// The row's leading mark: a team's snapshot's pair of figures. Nil for
    /// every other chat.
    let systemImage: String?
    let isSelected: Bool
    let isRunning: Bool
    let indent: CGFloat
    let notebooks: [LearningGoalRecord]
    /// The open Goals a chat can be filed under, listed in their own section
    /// of the Move to Notebook submenu. A chat on a Goal is listed on the
    /// Goal's row and in its editor, and beneath the Goal's Notebook in the
    /// rail when it draws on one.
    let goals: [LearningGoalRecord]
    /// Every chat rendered in this row's own section, this one included. A drop
    /// is a reorder within one list, so a chat from another section is refused
    /// rather than silently refiled.
    let siblingIDs: [String]
    /// The notebook section this row is rendered under, if any. Used to mark the
    /// current location in the Move to Notebook submenu.
    let displayedNotebookID: String?
    /// Whether the session is explicitly linked to a notebook (`goal_id` set), as
    /// opposed to appearing under one through source overlap. Only explicit
    /// links can be removed.
    let hasExplicitNotebook: Bool
    let open: () -> Void
    let openBeside: () -> Void
    let moveToNotebook: (String?) -> Void
    /// Called with the dragged chat's id once a sibling has been dropped here.
    let reorder: (String) -> Void
    /// Whether the chat is in Pinned (`ChatPins`).
    let isPinned: Bool
    /// Pin Chat / Unpin Chat; nil where a chat never pins (a day's review).
    let togglePinned: (() -> Void)?
    /// Whether the chat reads as unread on this Mac (`ChatReadMarks`): the
    /// row's leading column shows Codex's dot.
    let isUnread: Bool
    let toggleUnread: () -> Void
    let rename: () -> Void
    /// Whether the chat is hidden from the sidebar — the row is then
    /// drawn under the Hidden fold and its menu offers Show instead of Hide.
    let isHidden: Bool
    let toggleHidden: () -> Void
    /// Copies the transcript into the chosen team; nil where sharing is not
    /// offered (a team's own snapshot, a memory review).
    let shareWithTeam: ((String) -> Void)?
    /// New Notebook from This Chat…; nil where it is not offered (a team's
    /// snapshot, a memory review, a read-only library).
    let newNotebookFromChat: (() -> Void)?
    let delete: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false
    @State private var isTargeted = false
    /// Once revealed, keep the Menu alive for the row's lifetime so moving the
    /// pointer from its label into the open menu cannot tear down the presenter.
    @State private var hasRevealedActionsMenu = false
    @State private var isPickingNotebook = false

    /// True while a chat from this row's own section is in flight. Drives both
    /// the drop outline and whether the row lights up, so a chat that cannot be
    /// rearranged here never offers a target.
    private var canAcceptCurrentDrag: Bool {
        guard let draggedSessionID = dragVisibility.draggedSessionID,
              draggedSessionID != sessionID else { return false }
        return siblingIDs.contains(draggedSessionID)
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 8) {
                    // Keep the leading column even when there is no icon, so
                    // a team's snapshot and the learner's chats keep one left
                    // edge. One colour, selected or not: the row's fill says
                    // which is selected.
                    Group {
                        // Codex's unread dot, in the leading column; a chat
                        // still running shows its spinner instead.
                        if isUnread, !isRunning {
                            RailUnreadDot()
                        } else if let systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        }
                    }
                    .frame(width: 16)
                    .accessibilityHidden(true)
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Opacity does not make a view lazy: the previous hidden Menu still
            // built its full nested notebook list for every chat row. Preserve the
            // row geometry with a cheap placeholder and create the menu only while
            // the pointer can interact with it.
            if hasRevealedActionsMenu {
                actionsMenu
                    .opacity(hovering ? 1 : 0)
            } else {
                Color.clear
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 8 + indent)
        .padding(.trailing, 6)
        .padding(.vertical, StudioDesign.Spacing.xSmall)
        .frame(minHeight: StudioDesign.Metrics.navigationRowMinHeight)
        .background(StudioSelectionBackground(isSelected: isSelected, isHovered: hovering))
        .overlay {
            // Same rest-cost rule as RailNotebookRow: no drag in flight that
            // this row could accept means no overlay nodes at all.
            if canAcceptCurrentDrag || isTargeted {
                StudioDropZoneOverlay(
                    isActive: isTargeted && canAcceptCurrentDrag,
                    isVisible: canAcceptCurrentDrag,
                    cornerRadius: 7,
                    inset: 0
                )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isRunning ? "Running" : isUnread ? "Unread" : "")
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                hasRevealedActionsMenu = true
            }
        }
        .onDrop(of: [.reviewSession], isTargeted: Binding(
            get: { isTargeted },
            set: { isTargeted = $0 && canAcceptCurrentDrag }
        )) { providers in
            handleChatDrop(providers)
        }
        .contextMenu { menuItems }
        .popover(isPresented: $isPickingNotebook, arrowEdge: .trailing) {
            NotebookPickerPopover(
                placeholder: "Search notebooks",
                notebooks: notebooks + goals,
                checkedIDs: displayedNotebookID.map { [$0] } ?? [],
                none: hasExplicitNotebook
                    ? .init(
                        title: goals.contains { $0.id == displayedNotebookID } ? "Remove from Goal" : "Remove from Notebook"
                    ) { moveToNotebook(nil) }
                    : nil,
                pick: { picked in
                    if picked.id != displayedNotebookID { moveToNotebook(picked.id) }
                },
                close: { isPickingNotebook = false }
            )
            .environment(vm)
        }
    }

    /// The section guard runs against the payload rather than `canAcceptCurrentDrag`,
    /// which races the mouse-up monitors that clear drag state as the drop fires
    /// (see the Notebook row). The dropped id is authoritative; the live drag state
    /// may already be gone.
    private func handleChatDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.reviewSession.identifier)
        }) else { return false }
        StudioDragVisibility.shared.endSoon()
        let siblingIDs = siblingIDs
        let ownID = sessionID
        let reorder = reorder
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.reviewSession.identifier
        ) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(ReviewSessionTransfer.self, from: data),
                  transfer.sessionID != ownID,
                  siblingIDs.contains(transfer.sessionID) else { return }
            Task { @MainActor in
                reorder(transfer.sessionID)
            }
        }
        return true
    }

    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // A `Menu` is not a `Button`, so `.hoverWash` cannot style it — this is
        // the non-button wash, sized to the same 20x20 square the row's other
        // trailing controls light up.
        .hoverHighlight(cornerRadius: 6, inset: 0, opacity: 0.10)
        .opacity(hovering ? 1 : 0)
        .help("More actions")
    }

    /// The row's menu, in Codex's order (product owner, 2026-10-13: "at first it
    /// should be a copy of the codex ... functionality"): Pin, Rename, Mark as
    /// Unread and Hide — ForeverLM's put-away in place of Codex's Archive —
    /// then where the chat is filed, then where it opens and its address,
    /// then Delete…, which asks first. ForeverLM's own items (Open Beside,
    /// Add to Canvas, New Notebook from This Chat, Share Transcript with Team)
    /// sit in the sections they belong to.
    @ViewBuilder
    private var menuItems: some View {
        if let togglePinned {
            Button(action: togglePinned) {
                Label(isPinned ? "Unpin Chat" : "Pin Chat", systemImage: isPinned ? "pin.slash" : "pin")
            }
        }
        Button(action: rename) {
            Label("Rename…", systemImage: "pencil")
        }
        Button(action: toggleUnread) {
            Label(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "checkmark.circle" : "circle")
        }
        // Hide is the learner's view, where Delete is the record's fate (product owner,
        // 2026-09-12: "please allow me to hide chats as well"). The chat, its
        // transcript and its Notebook link stay; only the row leaves, for the
        // Hidden fold under Chats, where Show on this same menu brings it back.
        Button(action: toggleHidden) {
            Label(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
        }
        .help(isHidden
            ? "List this chat in the sidebar again"
            : "Take this chat out of the sidebar on every Mac signed into your account; it stays under Hidden, beneath Chats")
        if !notebooks.isEmpty || !goals.isEmpty || newNotebookFromChat != nil || shareWithTeam != nil {
            Divider()
        }
        if !notebooks.isEmpty || !goals.isEmpty {
            // A popover under the row with a search field, not a menu of every
            // notebook and Goal.
            Button {
                isPickingNotebook = true
            } label: {
                Label("Move to Notebook…", systemImage: "folder")
            }
        }
        // An exploring chat becomes a notebook of its own (product owner,
        // 2026-10-03), as the chat's notebook picker and ⋯ offer it too.
        if let newNotebookFromChat {
            Button(action: newNotebookFromChat) {
                Label("New Notebook from This Chat", systemImage: "rectangle.stack.badge.plus")
            }
        }
        if let shareWithTeam {
            // A transcript carries no source, so it asks nothing first.
            ShareWithTeamMenu(title: "Share Transcript with Team", asksSharingRights: false, share: shareWithTeam)
        }
        Divider()
        Button(action: openBeside) {
            Label("Open Beside", systemImage: "rectangle.split.2x1")
        }
        OpenStudioDestinationInOtherWindowMenu(
            destination: .chat(sessionID),
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
        // The chat's address, `foreverlm://chat/<id>`: it opens the chat in the
        // app, a doc renders it as a link, and every plugin tool that takes a
        // session_id takes it as given — so a chat still running here can be
        // pasted to Codex or Claude, which read its turns so far over MCP.
        Button(action: copyLink) {
            Label("Copy Link", systemImage: "link")
        }
        .help("Copy this chat's address; paste it to a person or to an assistant using the ForeverLM plugin")
        Button {
            Task { await vm.copyChatConversation(sessionID) }
        } label: {
            Label("Copy Conversation", systemImage: "doc.on.doc")
        }
        .help("Copy the whole chat as text")
        KnowledgeMapAddToCanvasMenu(refs: [KnowledgeMapOutside.chatRef(sessionID)])
        Divider()
        Button(role: .destructive, action: delete) {
            Label("Delete…", systemImage: "trash")
        }
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            StudioEntityLink.chat(sessionID).markdownDestination,
            forType: .string
        )
        vm.showToast("Link copied")
    }

    private func notebookTitle(_ notebook: LearningGoalRecord) -> String {
        notebook.title.isEmpty ? "Untitled notebook" : notebook.title
    }
}

/// Codex's unread dot: on a chat whose reply finished while no window showed
/// it, and on a folded notebook holding one (`ChatReadMarks`).
struct RailUnreadDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }
}

/// Tells `ChatReadMarks` what this window's chats are doing: the ones on
/// screen, which a window showing them reads, and the ones running, which the
/// bell lists and whose reply leaves them unread when it finishes with no
/// window showing them. Its
/// own view, mounted once per window by the icon strip, so a turn's flags
/// flipping redraw this and not the strip.
private struct ChatActivityReporter: View {
    let sessionStore: StudioAssistantSessionStore
    let comparisonSessionStore: StudioAssistantSessionStore

    @Environment(StudioWindowState.self) private var windowState

    private var shown: Set<String> {
        StudioNavigationRail.highlightedSessionIDs(
            primary: sessionStore.activeSessionID,
            comparison: comparisonSessionStore.activeSessionID,
            in: windowState
        )
    }

    private var running: Set<String> {
        sessionStore.runningSessionIDs.union(comparisonSessionStore.runningSessionIDs)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: shown, initial: true) { _, ids in
                ChatReadMarks.shared.showing(ids, inWindow: windowState.id.uuidString)
            }
            .onChange(of: running, initial: true) { before, now in
                for sessionID in before.subtracting(now) {
                    ChatReadMarks.shared.replyFinished(sessionID)
                }
                ChatReadMarks.shared.running(now, inWindow: windowState.id.uuidString)
            }
            .onDisappear {
                ChatReadMarks.shared.closingWindow(windowState.id.uuidString)
            }
    }
}

private struct RailSectionHeader: View {
    let title: String
    var action: (() -> Void)?
    /// `nil` means the section is not foldable; otherwise the label and a
    /// chevron toggle it, the way a notebook row folds its chats.
    var isExpanded: Bool?
    var toggleExpanded: (() -> Void)?

    @State private var hovering = false

    init(
        title: String,
        isExpanded: Bool? = nil,
        toggleExpanded: (() -> Void)? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.toggleExpanded = toggleExpanded
        self.action = action
    }

    private var plusGlyph: some View {
        Image(systemName: "plus")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    var body: some View {
        HStack(spacing: 8) {
            if let isExpanded, let toggleExpanded {
                Button(action: toggleExpanded) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            // The chevron is a hint, not chrome: it shows on
                            // hover or while the section is folded, so an open
                            // section keeps the quiet label it always had.
                            .opacity(hovering || !isExpanded ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded ? "Hides this section's chats" : "Shows this section's chats")
                .accessibilityIdentifier("studio.navigation.section.\(title.lowercased()).toggle")
            } else {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            // Built only while the pointer is over the header, a hidden glyph
            // holding its place so the header keeps its height (2026-10-06):
            // a + at rest beside New chat read as a second New chat. The
            // header's menu offers it without a pointer.
            if let action {
                if hovering {
                    Button(action: action) {
                        plusGlyph
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                    .help("New library chat, in no notebook")
                    .accessibilityLabel("New library chat")
                } else {
                    plusGlyph
                        .hidden()
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.top, 10)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole header is the hover target, its empty middle included,
        // so the + stays while the pointer travels to it.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Section header that doubles as a destination: it titles the run of rows
/// beneath it but still opens its browse-all view on click. Same type treatment
/// as `RailSectionHeader`, with a hover wash hugging the text so it
/// reads as clickable without turning back into a full row. Open Beside is
/// on its menu (the hover glyph went on 2026-10-06), and it drags to the
/// center's edge.
private struct RailSectionHeaderButton: View {
    let title: String
    var identifier: String? = nil
    var isSelected = false
    let action: () -> Void
    @State private var hovering = false

    private var textStyle: HierarchicalShapeStyle {
        if isSelected { return .primary }
        return hovering ? .secondary : .tertiary
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: action) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(textStyle)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier ?? "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // 5pt outer leading + 5pt wash inset keeps the text at the same 10pt
        // leading as the plain headers; 10pt top + 3pt wash inset lands the
        // text on the same 13pt/3pt vertical rhythm.
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .padding(.top, 10)
    }
}

private struct RailPlaceholderRow: View {
    let text: String
    var indent: CGFloat = 8

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.leading, 8 + indent)
            .padding(.vertical, StudioDesign.Spacing.xSmall)
            .frame(minHeight: 28, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "Hidden" marker that heads the hidden chats and folds them away. It
/// sits on the chat rows' left edge, with its glyph in the rows' icon column,
/// so it reads as a line of the list rather than a control that belongs to
/// the section header.
private struct RailShowMoreRow: View {
    let title: String
    let accessibilityHint: String
    let systemImage: String
    var indent: CGFloat = 8
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .padding(.leading, 8 + indent)
            .padding(.trailing, 6)
            .padding(.vertical, StudioDesign.Spacing.xSmall)
            .frame(minHeight: StudioDesign.Metrics.navigationRowMinHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .onHover { hovering = $0 }
        .accessibilityHint(accessibilityHint)
    }
}
