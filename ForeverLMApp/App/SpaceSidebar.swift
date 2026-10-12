#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The courses, listed first in the Space's sidebar (product owner, 2026-10-09:
/// "also courses under spaces then"). The Courses list is a pane of its own
/// (`.courses`) that draws this sidebar beside it, as a canvas does, so the
/// Space is the one home. The notebooks have no row: the Space's All lists
/// them, since the Notebooks home that had a row here went (2026-10-09). A hub
/// is never a `SpaceDestination`: the Space's lists do not browse it, and
/// the window's `spaceDestinationKey` never holds one.
enum SpaceHub: String, CaseIterable, Identifiable, Sendable {
    case courses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .courses: return "Courses"
        }
    }

    var symbolName: String {
        switch self {
        case .courses: return "graduationcap"
        }
    }

    /// The tab a click shows (`showSpaceTab`).
    var tab: SpaceTab {
        switch self {
        case .courses: return .courses
        }
    }
}

/// One place in the Space sidebar (docs/docs-design.md, "The Space").
///
/// The product owner, 2026-10-06, showing ChatGPT's Space: "maybe just copy this spaces
/// design entirely from chatgpt; it looks good". The sidebar is ChatGPT's —
/// New chat, then All, Pages, Sites, Images, Google Drive, the Recents, the
/// Spaces and Trash at the foot. ForeverLM's Ideas had a row beside the
/// pictures until 2026-10-10 (product owner: "goals can perhaps just be
/// visible via chat; same with ideas perhaps"): the chat lists and jots them
/// (`list_ideas`, `create_idea`), and a list of ideas the learner keeps is a
/// Space item (`.list`). A window that remembered the old place opens on All.
enum SpaceDestination: Hashable, Sendable {
    case all
    /// The learner's notebooks, and only those: the row that links them
    /// from the sidebar now that the Notebooks home is gone (product owner,
    /// 2026-10-10: "notebooks have to be linked here").
    case notebooks
    /// Every chat, in a notebook or in none (product owner, 2026-10-10: "maybe
    /// we should still have a separate chats page? chats don't always have to
    /// be in a notebook?"). The chats were Home's sidebar's alone, which shows
    /// only beside a chat or the Reader, so from the Space no list of them was
    /// in reach.
    case chats
    case pages
    case sites
    /// The learner's canvases (`KnowledgeMapCanvas`): a beta place, listed
    /// only where the Canvas shows (`BetaFeatures`) and in My Library.
    case canvases
    case images
    case drive
    case trash
    /// What one team holds or was given, a team being a space in the sync
    /// design (AGENTS.md, Teams): a shared space.
    case team(String)
    /// One of the learner's own spaces of pages (`PageSpaces`), by its id.
    case space(String)
    /// One of the learner's lists of goals or ideas (`SpaceLists`), shown as
    /// its page: what it holds.
    case list(String)

    /// The places listed under New chat, in the sidebar's order.
    static let places: [SpaceDestination] = [.all, .notebooks, .chats, .pages, .sites, .canvases, .images, .drive]

    /// The places this Mac lists: Canvases only where canvases are listed
    /// (`StudioViewModel.listsCanvases`).
    static func places(listsCanvases: Bool) -> [SpaceDestination] {
        listsCanvases ? places : places.filter { $0 != .canvases }
    }

    /// The rows the sidebar draws: the places without All. All is still the
    /// Space's landing list and its search, and the list header's place menu
    /// names it, but it is no row (product owner, 2026-10-09: "i don't want all
    /// here").
    static func sidebarPlaces(listsCanvases: Bool) -> [SpaceDestination] {
        places(listsCanvases: listsCanvases).filter { $0 != .all }
    }

    init(key: String) {
        switch key {
        case "notebooks": self = .notebooks
        case "chats": self = .chats
        case "pages": self = .pages
        case "sites": self = .sites
        case "canvases": self = .canvases
        case "images": self = .images
        case "drive": self = .drive
        case "trash": self = .trash
        default:
            if key.hasPrefix(Self.teamPrefix), key.count > Self.teamPrefix.count {
                self = .team(String(key.dropFirst(Self.teamPrefix.count)))
            } else if key.hasPrefix(Self.spacePrefix), key.count > Self.spacePrefix.count {
                self = .space(String(key.dropFirst(Self.spacePrefix.count)))
            } else if key.hasPrefix(Self.listPrefix), key.count > Self.listPrefix.count {
                self = .list(String(key.dropFirst(Self.listPrefix.count)))
            } else {
                self = .all
            }
        }
    }

    /// How the window remembers the place (`StudioWindowState.spaceDestinationKey`).
    var key: String {
        switch self {
        case .all: return "all"
        case .notebooks: return "notebooks"
        case .chats: return "chats"
        case .pages: return "pages"
        case .sites: return "sites"
        case .canvases: return "canvases"
        case .images: return "images"
        case .drive: return "drive"
        case .trash: return "trash"
        case .team(let id): return Self.teamPrefix + id
        case .space(let id): return Self.spacePrefix + id
        case .list(let id): return Self.listPrefix + id
        }
    }

    private static let teamPrefix = "team:"
    private static let spacePrefix = "space:"
    private static let listPrefix = "list:"

    /// The list this place shows, nil for every other place.
    var spaceListID: String? {
        if case .list(let id) = self { return id }
        return nil
    }

    /// The space of pages this place is, nil for every other place.
    var pageSpaceID: String? {
        if case .space(let id) = self { return id }
        return nil
    }

    /// The place's name; a team's and a space's are their own, which the
    /// caller looks up.
    var title: String {
        switch self {
        case .all: return "All"
        case .notebooks: return "Notebooks"
        case .chats: return "Chats"
        case .pages: return "Pages"
        case .sites: return "Sites"
        case .canvases: return "Canvases"
        case .images: return "Images"
        case .drive: return "Google Drive"
        case .trash: return "Trash"
        case .team, .space: return "Space"
        case .list: return "List"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "rectangle.stack"
        case .notebooks: return NotebookGlyph.systemImage
        case .chats: return "bubble.left.and.bubble.right"
        case .pages: return "doc.text"
        case .sites: return "globe"
        case .canvases: return KnowledgeMap.symbolName
        case .images: return "photo"
        case .drive: return "externaldrive"
        case .trash: return "trash"
        case .team: return "person.2"
        case .space: return "square.stack"
        case .list: return "checklist"
        }
    }

    /// The green tag after the place's name in the sidebar: Beta on
    /// Canvases, which is still a beta feature (`BetaFeatures`) (product
    /// owner, 2026-10-10: "add a green 'beta' button to show that it's still
    /// in beta"); nil for every other place.
    var badge: String? {
        self == .canvases ? "Beta" : nil
    }

    /// The Pages home's kind a place opens in a pane of its own, for the
    /// row's drag to an edge and its Open Beside; nil for a place with no
    /// pane of its own.
    var openableKind: ArtifactsHomeKind? {
        switch self {
        case .pages: return .docs
        case .sites: return .sites
        default: return nil
        }
    }

    /// The place a record is listed under, for the sidebar's highlight while
    /// the record is open beside it.
    static func listing(_ artifact: ArtifactRecord) -> SpaceDestination {
        if artifact.isArchived { return .trash }
        if artifact.linkedKind == .googleDoc { return .drive }
        return artifact.section == .sites ? .sites : .pages
    }

    /// The place a canvas is listed under: Trash while it is there, else
    /// Canvases, or the window's own space while the canvas is in it.
    static func listing(_ canvas: KnowledgeMapCanvas, within place: SpaceDestination?, spaces: PageSpaces) -> SpaceDestination {
        if canvas.isTrashed { return .trash }
        if let spaceID = place?.pageSpaceID, spaces.spaceID(ofPage: canvas.id) == spaceID { return place ?? .canvases }
        return .canvases
    }

    /// The same, but the window's own space while the record is in it: a page
    /// opened from a space keeps its space lit, and New page files beside it.
    static func listing(_ artifact: ArtifactRecord, within place: SpaceDestination, spaces: PageSpaces) -> SpaceDestination {
        if let spaceID = place.pageSpaceID, !artifact.isArchived, spaces.spaceID(ofPage: artifact.id) == spaceID {
            return place
        }
        return listing(artifact)
    }
}

/// The sidebar's measures and colours, shared by the Space home and the page
/// pane so the two read as one surface when a page opens from a list.
enum SpaceSidebarMetrics {
    static let width: CGFloat = 244
    /// The sidebar's top line — the Space's name, the bell, the search — as
    /// its first row.
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 28
    static let rowCornerRadius: CGFloat = 8
    /// How many Recents the sidebar shows.
    static let recentsShown = 8
    /// The pane width under which the sidebar steps aside for the content.
    static let minimumPaneWidth: CGFloat = 600

    /// ChatGPT's sidebar is a step off the page: #F9F9F9 beside white.
    static let background = Color.primary.opacity(0.028)
    /// Codex's selected row, measured off its window (2026-10-12): #EDEDED
    /// on #FAFAFA, a 5% step; a hover is a lighter one (`StudioDesign.selectionFill`).
    static let selectedFill = Color.primary.opacity(0.05)
    static let hoverFill = Color.primary.opacity(0.035)
}

/// The sidebar's top line, its first row: the Space's name, the bell and the
/// search, as ChatGPT draws them. It sits under the window's chrome, not on
/// it, as Codex's sidebar title does, so the band over the sidebar holds only
/// the traffic lights, ‹ › and the sidebar toggle in every state (product
/// owner, 2026-10-12: "make sure the top left looks clean at all times"). It
/// has no hide control: the window's one sidebar toggle, by the traffic
/// lights, folds this sidebar with the rail.
struct SpaceSidebarHeader: View {
    @Environment(StudioViewModel.self) private var vm
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(vm.activeTeamID == nil ? "Space" : vm.activeLibraryTitle)
                .zoomedSystemFont(size: 15, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.disabled)
            Spacer(minLength: 4)
            SpaceActivityButton()
            SpaceHeaderIconButton(systemImage: "magnifyingglass", help: "Search the Space", action: onSearch)
                .accessibilityIdentifier("space.sidebar.search")
        }
        // In line with the rows' glyphs: the list's 8 and a row's own 8.
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

/// What the chrome line holds over the Space sidebar: nothing but the
/// window's own controls, which the window draws over it — the traffic
/// lights, ‹ › and the sidebar toggle. With no band (full screen) the line is
/// in flow above the sidebar and takes its tone, back under the leading inset
/// too, so the sidebar is one column from the card's top edge, as Codex's is
/// (product owner, 2026-10-12: "this top left still looks a bit bad with
/// colors").
struct SpaceSidebarChromeSpace: View {
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset

    var body: some View {
        Color.clear
            .frame(width: max(0, SpaceSidebarMetrics.width - headerLeadingInset))
            .frame(maxHeight: .infinity)
            .background {
                if titlebarBandHeight == nil {
                    SpaceSidebarMetrics.background
                        .padding(.leading, -headerLeadingInset)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A quiet glyph button for the sidebar's top line.
struct SpaceHeaderIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0, opacity: 0.09))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The bell: what in the Space waits on the learner. Today that is a
/// teammate's request for a source this library holds (docs/teams-design.md,
/// decision 14), answered here with Share or Decline; a dot on the bell says
/// one is waiting.
struct SpaceActivityButton: View {
    @Environment(StudioViewModel.self) private var vm
    @State private var isPresented = false

    var body: some View {
        let waiting = vm.fulfillableShareRequests.count
        Button {
            isPresented = true
        } label: {
            Image(systemName: "bell")
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .overlay(alignment: .topTrailing) {
                    if waiting > 0 {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: -6, y: 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0, opacity: 0.09))
        .help(waiting > 0 ? "Activity: \(waiting) waiting" : "Activity")
        .accessibilityLabel("Activity")
        .accessibilityValue(waiting > 0 ? "\(waiting) waiting" : "Nothing new")
        .accessibilityIdentifier("space.sidebar.activity")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SpaceActivityPopover { isPresented = false }
        }
    }
}

private struct SpaceActivityPopover: View {
    @Environment(StudioViewModel.self) private var vm
    let close: () -> Void

    var body: some View {
        let items = vm.fulfillableShareRequests
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Activity")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                Text("Nothing new")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        } else {
            ShareRequestsReviewList(items: items, dismiss: close)
                .frame(width: 420)
        }
    }
}

/// The sidebar: New chat, the places, Recents, Spaces, and Trash at the foot.
/// Drawn by the Space home and by the page pane beside an open page, with the
/// same width, rows and colour, so opening a page from a list changes only
/// what is beside the sidebar.
struct SpaceSidebar: View {
    @Environment(StudioViewModel.self) private var vm
    /// The window the sidebar is in, where New Canvas opens what it makes.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    /// The place highlighted: the list on screen, or where the open page is
    /// listed. Nil highlights none.
    let selection: SpaceDestination?
    /// The record or canvas open beside the sidebar, whose Pinned or Recents
    /// row is highlighted.
    let openArtifactID: String?
    /// The courses, lit while their list is beside the sidebar; nil in every
    /// other pane, where a place or a page is lit.
    var hub: SpaceHub? = nil
    let onSelect: (SpaceDestination) -> Void
    let onOpenRecent: (SpaceRecents.Item) -> Void
    let onNewPage: () -> Void
    let onLink: (ArtifactSection) -> Void
    let onNewSpace: () -> Void
    /// The search glyph on the sidebar's top line (`SpaceSidebarHeader`):
    /// with it the sidebar draws that line as its own first row, under the
    /// window's chrome, as Codex's sidebar does (product owner, 2026-10-12:
    /// "make sure the top left looks clean at all times"). Nil for a sidebar
    /// drawn without its line.
    var onSearch: (() -> Void)? = nil
    /// The space whose Rename… or Delete Space… is asking.
    @State private var renamingSpace: PageSpace?
    @State private var spaceNameDraft = ""
    @State private var deletingSpace: PageSpace?
    /// The space row a dragged page is over.
    @State private var dropTargetSpaceID: String?
    /// The page whose Rename… is asking, from a Pinned or Recents row.
    @State private var renamingPage: ArtifactRecord?
    @State private var pageNameDraft = ""
    /// The canvas whose Rename… is asking, from a Pinned or Recents row.
    @State private var renamingCanvas: KnowledgeMapCanvas?
    /// The list whose Rename… is asking, from a Pinned or Recents row.
    @State private var renamingList: SpaceList?
    /// Recents folds under its header, as ChatGPT's does. This Mac's own
    /// arrangement, like the list it folds.
    @AppStorage("space.sidebar.recentsFolded") private var recentsFolded = false

    private var recents: SpaceRecents { SpaceRecents.shared }

    var body: some View {
        VStack(spacing: 0) {
            if let onSearch {
                SpaceSidebarHeader(onSearch: onSearch)
                    .frame(height: SpaceSidebarMetrics.headerHeight)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    newChatRow
                        .padding(.bottom, 10)
                    // Notebooks lead and the chats follow them, the two places
                    // the learner works in; then Courses and the rest.
                    placeRow(.notebooks)
                    placeRow(.chats)
                    ForEach(SpaceHub.allCases) { hub in
                        hubRow(hub)
                    }
                    ForEach(SpaceDestination.sidebarPlaces(listsCanvases: vm.listsCanvases).filter { $0 != .notebooks && $0 != .chats }, id: \.self) { place in
                        placeRow(place)
                    }
                    pinnedSection
                    recentsSection
                    spacesSection
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            placeRow(.trash)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space")
        .canvasRenameAlert($renamingCanvas)
        .spaceListRenameAlert($renamingList)
        .alert(
            "Rename Page",
            isPresented: Binding(
                get: { renamingPage != nil },
                set: { if !$0 { renamingPage = nil } }
            ),
            presenting: renamingPage
        ) { page in
            TextField("Name", text: $pageNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = pageNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title != page.title else { return }
                Task { await vm.updateArtifact(artifactID: page.id, title: title) }
            }
            .disabled(pageNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Rename Space",
            isPresented: Binding(
                get: { renamingSpace != nil },
                set: { if !$0 { renamingSpace = nil } }
            ),
            presenting: renamingSpace
        ) { space in
            TextField("Name", text: $spaceNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { vm.renamePageSpace(space.id, to: spaceNameDraft) }
                .disabled(PageSpaces.cleanedName(spaceNameDraft) == nil)
        }
        .confirmationDialog(
            "Delete “\(NotebookTitle(deletingSpace?.name ?? "").text)”?",
            isPresented: Binding(
                get: { deletingSpace != nil },
                set: { if !$0 { deletingSpace = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingSpace
        ) { space in
            // A list showing the space shows All once it is gone
            // (`SpaceBrowseView`); a page open beside the sidebar stays.
            Button("Delete Space", role: .destructive) { vm.deletePageSpace(space.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its pages stay in All.")
        }
    }

    // MARK: Rows

    /// New chat leads the sidebar, as it leads ChatGPT's (product owner,
    /// 2026-10-10, of the row that was New page: "we should just have new
    /// chat"). The icon rail beside the Space has no New chat, so this is the
    /// window's way to one: the rail's own route (`requestNewChat`), a chat in
    /// the window's notebook while it holds one, taking this pane as Chat
    /// does. A page stays one step away: New Page leads the ⋯, the list's
    /// New ▾ makes one, and ⇧⌘N still does.
    private var newChatRow: some View {
        SpaceSidebarRow(
            title: "New chat",
            isSelected: false,
            accessibilityIdentifier: "space.sidebar.newChat",
            action: startNewChat
        ) {
            Image(systemName: "square.and.pencil")
                .zoomedSystemFont(size: 13, weight: .regular)
        } trailing: {
            Menu {
                Button("New Page", systemImage: "doc.badge.plus", action: onNewPage)
                Button("New Notebook", systemImage: NotebookGlyph.systemImage) {
                    vm.makeAndOpenNotebook(in: windowState)
                }
                .disabled(vm.isActiveLibraryReadOnly)
                Button(ArtifactSection.docs.linkActionTitle, systemImage: "link.badge.plus") { onLink(.docs) }
                Button(ArtifactSection.sites.linkActionTitle, systemImage: "link.badge.plus") { onLink(.sites) }
                if vm.activeTeamID == nil {
                    Button("New Goals List", systemImage: SpaceList.Kind.goals.symbolName) {
                        vm.makeAndOpenSpaceList(.goals, inPageSpace: selection?.pageSpaceID, in: windowState)
                    }
                    Button("New Ideas List", systemImage: SpaceList.Kind.ideas.symbolName) {
                        vm.makeAndOpenSpaceList(.ideas, inPageSpace: selection?.pageSpaceID, in: windowState)
                    }
                }
                if vm.listsCanvases {
                    Button("New Canvas", systemImage: KnowledgeMap.symbolName) {
                        vm.makeAndOpenCanvas(inPageSpace: selection?.pageSpaceID, in: windowState)
                    }
                }
                if vm.activeTeamID == nil {
                    Divider()
                    Button("New Space…", systemImage: "square.stack", action: onNewSpace)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .fixedSize()
            .help("More ways to add")
            .accessibilityLabel("More ways to add")
        }
        .contextMenu {
            Button("Open Beside", systemImage: "rectangle.split.2x1") {
                let window = windowState ?? vm.activeWindowState
                vm.inWindow(window) {
                    vm.openCenterTabBeside(.chat)
                    vm.requestNewChat()
                }
            }
            OtherWindowMenuItem(.newChat)
        }
        // The shortcut the Pages home's New Page button carried.
        .background {
            Button("New Page", action: onNewPage)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func startNewChat() {
        vm.inWindow(windowState ?? vm.activeWindowState) { vm.requestNewChat() }
    }

    /// Courses: a click shows that pane in this window, the sidebar staying
    /// where it is.
    private func hubRow(_ target: SpaceHub) -> some View {
        SpaceSidebarRow(
            title: target.title,
            isSelected: hub == target,
            accessibilityIdentifier: "space.sidebar.hub.\(target.rawValue)",
            action: {
                guard hub != target else { return }
                vm.showSpaceTab(target.tab, in: windowState ?? vm.activeWindowState)
            }
        ) {
            Image(systemName: target.symbolName)
                .zoomedSystemFont(size: 13, weight: .regular)
        } trailing: {
            EmptyView()
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: target.tab.centerTab)
            return studioCenterTabDragProvider(for: target.tab.centerTab)
        }
        .contextMenu {
            Button("Open \(target.title) Beside", systemImage: "rectangle.split.2x1") {
                let window = windowState ?? vm.activeWindowState
                vm.inWindow(window) {
                    vm.openCenterTabBeside(target.tab.centerTab)
                    switch target {
                    case .courses: vm.openCoursesListInReader()
                    }
                }
            }
            OtherWindowMenuItem(.courses)
        }
    }

    @ViewBuilder
    private func placeRow(_ place: SpaceDestination) -> some View {
        let row = SpaceSidebarRow(
            title: place.title,
            isSelected: selection == place,
            accessibilityIdentifier: "space.sidebar.\(place.key)",
            badge: place.badge,
            action: { onSelect(place) }
        ) {
            placeIcon(place)
        } trailing: {
            EmptyView()
        }
        if let kind = place.openableKind {
            // Pages and Sites each open in a pane of their own as well:
            // dragged to an edge of the center, or from the right-click.
            row
                .onDrag {
                    StudioDragVisibility.shared.begin(centerTab: kind.centerTab)
                    return studioCenterTabDragProvider(for: kind.centerTab)
                }
                .contextMenu {
                    Button("Open \(kind.title) Beside", systemImage: "rectangle.split.2x1") { kind.openBeside(in: vm) }
                    OtherWindowMenuItem(kind.otherWindowDestination)
                }
        } else {
            row
        }
    }

    @ViewBuilder
    private func placeIcon(_ place: SpaceDestination) -> some View {
        if place == .drive {
            Image("GoogleDriveIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        } else {
            Image(systemName: place.symbolName)
                .zoomedSystemFont(size: 13, weight: .regular)
        }
    }

    // MARK: Recents

    /// One Recents row: the opening, its name now, and the record or canvas
    /// it opens.
    struct RecentRow: Identifiable {
        let item: SpaceRecents.Item
        let title: String
        let artifact: ArtifactRecord?
        var canvas: KnowledgeMapCanvas? = nil
        var list: SpaceList? = nil
        var id: String { "\(item.kind.rawValue):\(item.id)" }
    }

    /// What this Mac opened last, that the open library still holds and has
    /// not put in Trash.
    private var shownRecents: [RecentRow] {
        Self.recentRows(recents.items, vm: vm)
    }

    /// The first `limit` of `items` the open library still holds, has not
    /// put in Trash, and, in Screen record mode, lets on screen: a page as
    /// `artifacts` lists it (narrowed as it loads), a canvas or a list as the
    /// Space lists them (`listedCanvases`, `listedSpaceLists`), a picture by
    /// the date it was drawn (`ScreenRecordScope.allowsImage`). On build 208
    /// (2026-10-10) a take's Recents named three of the learner's canvases.
    static func recentRows(
        _ items: [SpaceRecents.Item], vm: StudioViewModel, limit: Int = SpaceSidebarMetrics.recentsShown
    ) -> [RecentRow] {
        var shown: [RecentRow] = []
        for item in items {
            guard shown.count < limit else { break }
            switch item.kind {
            case .artifact:
                guard let artifact = vm.artifacts.first(where: { $0.id == item.id }),
                      !artifact.isArchived, !artifact.isHidden,
                      !TeamContentIdentity.isDraftArtifactID(artifact.id) else { continue }
                shown.append(RecentRow(item: item, title: artifact.title, artifact: artifact))
            case .image:
                // A picture is this Mac's file; a team library holds none.
                guard vm.activeTeamID == nil,
                      vm.screenRecordScope?.allowsImage(id: item.id, createdAt: item.createdAt) ?? true else { continue }
                shown.append(RecentRow(item: item, title: item.title ?? GeneratedImageActions.untitled, artifact: nil))
            case .canvas:
                // A canvas is the learner's own: listed where canvases are.
                guard vm.listsCanvases, let canvas = vm.canvases.canvas(item.id), !canvas.isTrashed,
                      vm.isVisibleInRecordingMode(canvas) else { continue }
                shown.append(RecentRow(item: item, title: canvas.name, artifact: nil, canvas: canvas))
            case .list:
                // A list is the learner's own: listed in My Library.
                guard vm.activeTeamID == nil, let list = vm.spaceLists.list(item.id), !list.isTrashed,
                      vm.isVisibleInRecordingMode(list) else { continue }
                shown.append(RecentRow(item: item, title: list.name, artifact: nil, list: list))
            }
        }
        return shown
    }

    /// ChatGPT's **Pinned**: the pages the learner pinned, above Recents,
    /// newest pin first. Each row has Recents' own menu.
    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = vm.pinnedPages
        let pinnedCanvases = vm.pinnedCanvases
        let pinnedLists = vm.pinnedSpaceLists
        if !pinned.isEmpty || !pinnedCanvases.isEmpty || !pinnedLists.isEmpty {
            SpaceSidebarSectionHeader(title: "Pinned")
            ForEach(pinned) { artifact in
                pageRow(
                    artifact,
                    identifier: "space.sidebar.pinned.\(artifact.id)",
                    open: { onOpenRecent(SpaceRecents.Item(kind: .artifact, id: artifact.id, openedAt: Date())) }
                )
            }
            ForEach(pinnedCanvases) { canvas in
                canvasRow(canvas, identifier: "space.sidebar.pinned.\(canvas.id)")
            }
            ForEach(pinnedLists) { list in
                listRow(list, identifier: "space.sidebar.pinned.\(list.id)")
            }
        }
    }

    /// A row for a list of goals or ideas: its glyph and name, lit while its
    /// page shows, and a list's menu under the ⋯ and on right-click
    /// (`SpaceListMenuItems`).
    private func listRow(_ list: SpaceList, identifier: String) -> some View {
        SpaceSidebarRow(
            title: list.name,
            isSelected: selection == .list(list.id),
            accessibilityIdentifier: identifier,
            action: { onSelect(.list(list.id)) }
        ) {
            Image(systemName: list.kind.symbolName)
                .zoomedSystemFont(size: 13, weight: .regular)
        } trailing: {
            Menu {
                SpaceListMenuItems(list: list, onRename: { renamingList = list })
            } label: {
                Image(systemName: "ellipsis")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .fixedSize()
            .help("List options")
            .accessibilityLabel("List options")
        }
        .contextMenu {
            SpaceListMenuItems(list: list, onRename: { renamingList = list })
        }
    }

    /// A row for a canvas: its glyph and name, and a canvas's menu under the
    /// ⋯ and on right-click (`SpaceCanvasMenuItems`).
    private func canvasRow(_ canvas: KnowledgeMapCanvas, identifier: String) -> some View {
        SpaceSidebarRow(
            title: canvas.name,
            isSelected: canvas.id == openArtifactID,
            accessibilityIdentifier: identifier,
            action: { onOpenRecent(SpaceRecents.Item(kind: .canvas, id: canvas.id, openedAt: Date())) }
        ) {
            SpaceCanvasGlyph(size: 13)
        } trailing: {
            Menu {
                SpaceCanvasMenuItems(canvas: canvas, onRename: { renamingCanvas = canvas })
            } label: {
                Image(systemName: "ellipsis")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
            .fixedSize()
            .help("Canvas options")
            .accessibilityLabel("Canvas options")
        }
        .contextMenu {
            SpaceCanvasMenuItems(canvas: canvas, onRename: { renamingCanvas = canvas })
        }
    }

    /// A row for a page: its glyph and name, the ⋯ and open-in-another-window
    /// under the pointer, and the same menu on right-click (ChatGPT's page
    /// row: Rename, Pin, Delete, Share, Copy, Download as Markdown, Open in
    /// new window).
    @ViewBuilder
    private func pageRow(_ artifact: ArtifactRecord, identifier: String, open: @escaping () -> Void) -> some View {
        SpaceSidebarRow(
            title: artifact.title,
            isSelected: artifact.id == openArtifactID,
            accessibilityIdentifier: identifier,
            action: open
        ) {
            SpaceItemGlyph(artifact: artifact, size: 13)
        } trailing: {
            HStack(spacing: 0) {
                Menu {
                    SpacePageRowMenuItems(artifact: artifact, onRename: { beginRename(artifact) })
                } label: {
                    Image(systemName: "ellipsis")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .fixedSize()
                .help("Page options")
                .accessibilityLabel("Page options")
                OtherWindowMenuItem(artifact.teamID != nil && vm.activeTeamID == nil
                                    ? .teamArtifact(artifact.id) : .doc(artifact.id))
                    .labelStyle(.iconOnly)
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .fixedSize()
                    .help("Open in new window")
            }
        }
        .contextMenu {
            SpacePageRowMenuItems(artifact: artifact, onRename: { beginRename(artifact) })
        }
    }

    private func beginRename(_ artifact: ArtifactRecord) {
        pageNameDraft = artifact.title
        renamingPage = artifact
    }

    @ViewBuilder
    private var recentsSection: some View {
        let shown = shownRecents
        if !shown.isEmpty {
            SpaceSidebarSectionHeader(title: "Recents", folded: $recentsFolded)
            if !recentsFolded {
                ForEach(shown) { entry in
                    if let artifact = entry.artifact {
                        pageRow(
                            artifact,
                            identifier: "space.sidebar.recent.\(entry.item.id)",
                            open: { onOpenRecent(entry.item) }
                        )
                    } else if let canvas = entry.canvas {
                        canvasRow(canvas, identifier: "space.sidebar.recent.\(entry.item.id)")
                    } else if let list = entry.list {
                        listRow(list, identifier: "space.sidebar.recent.\(entry.item.id)")
                    } else {
                        SpaceSidebarRow(
                            title: entry.title,
                            isSelected: false,
                            accessibilityIdentifier: "space.sidebar.recent.\(entry.item.id)",
                            action: { onOpenRecent(entry.item) }
                        ) {
                            SpaceItemGlyph(artifact: nil, isImage: entry.item.kind == .image, size: 13)
                        } trailing: {
                            EmptyView()
                        }
                        .contextMenu {
                            Button("Remove from Recents", systemImage: "clock.badge.xmark") {
                                recents.forget(entry.item.kind, id: entry.item.id)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Spaces

    /// In My Library: the learner's spaces of pages (`PageSpaces`), each row
    /// listing its pages, then the teams, the shared spaces, each row listing
    /// what is shared with that team. In a team's library the rows switch
    /// library, My Library first. In Screen record mode only the spaces and
    /// teams holding something on screen (`orderedPageSpaces`, `shownTeams`).
    @ViewBuilder
    private var spacesSection: some View {
        if let activeTeamID = vm.activeTeamID {
            SpaceSidebarSectionHeader(title: "Spaces")
            SpaceSidebarRow(
                title: "My Library",
                isSelected: false,
                accessibilityIdentifier: "space.sidebar.myLibrary",
                action: { Task { await vm.setActiveTeam(nil) } }
            ) {
                Image(systemName: "person.crop.circle")
                    .zoomedSystemFont(size: 13, weight: .regular)
            } trailing: {
                EmptyView()
            }
            ForEach(vm.shownTeams.filter { $0.id != activeTeamID }) { team in
                SpaceSidebarRow(
                    title: team.name,
                    isSelected: false,
                    accessibilityIdentifier: "space.sidebar.team.\(team.id)",
                    action: { Task { await vm.setActiveTeam(team.id) } }
                ) {
                    SpaceTeamMark(name: team.name)
                } trailing: {
                    EmptyView()
                }
            }
        } else {
            SpaceSidebarSectionHeader(title: "Spaces") {
                Button(action: onNewSpace) {
                    Image(systemName: "plus")
                        .zoomedSystemFont(size: 10.5, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0, opacity: 0.10))
                .help("New space")
                .accessibilityLabel("New space")
                .accessibilityIdentifier("space.sidebar.newSpace")
            }
            ForEach(vm.orderedPageSpaces) { space in
                pageSpaceRow(space)
            }
            ForEach(vm.shownTeams) { team in
                SpaceSidebarRow(
                    title: team.name,
                    isSelected: selection == .team(team.id),
                    accessibilityIdentifier: "space.sidebar.team.\(team.id)",
                    action: { onSelect(.team(team.id)) }
                ) {
                    SpaceTeamMark(name: team.name)
                } trailing: {
                    EmptyView()
                }
                .contextMenu {
                    Button("Invite People…", systemImage: "person.badge.plus") {
                        TeamSharingService.shared.presentMembers(for: team)
                    }
                    Button("Open \(team.name)’s Library", systemImage: "arrow.right.circle") {
                        Task { await vm.setActiveTeam(team.id) }
                    }
                }
            }
        }
    }

    /// One of the learner's spaces: its name (a leading emoji drawn as its
    /// icon), its pages beside it when chosen, and a page dropped on it moved
    /// there, as Move to Space ▸ moves one.
    private func pageSpaceRow(_ space: PageSpace) -> some View {
        SpaceSidebarRow(
            title: NotebookTitle(space.name).text,
            isSelected: selection == .space(space.id),
            accessibilityIdentifier: "space.sidebar.space.\(space.id)",
            action: { onSelect(.space(space.id)) }
        ) {
            PageSpaceGlyph(name: space.name)
        } trailing: {
            EmptyView()
        }
        .overlay {
            if dropTargetSpaceID == space.id {
                RoundedRectangle(cornerRadius: SpaceSidebarMetrics.rowCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.studioArtifact], isTargeted: Binding(
            get: { dropTargetSpaceID == space.id },
            set: { isTargeted in
                if isTargeted {
                    dropTargetSpaceID = space.id
                } else if dropTargetSpaceID == space.id {
                    dropTargetSpaceID = nil
                }
            }
        )) { providers in
            dropPages(providers, into: space.id)
        }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                spaceNameDraft = space.name
                renamingSpace = space
            }
            Button("Delete Space…", systemImage: "trash", role: .destructive) {
                deletingSpace = space
            }
        }
    }

    /// A page row dropped on a space: the page moves there. Only a record a
    /// space can hold moves (`canFileInPageSpace`).
    private func dropPages(_ providers: [NSItemProvider], into spaceID: String) -> Bool {
        StudioDragVisibility.shared.endSoon()
        let pages = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.studioArtifact.identifier) }
        guard !pages.isEmpty else { return false }
        for provider in pages {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.studioArtifact.identifier) { data, _ in
                guard let data,
                      let transfer = try? JSONDecoder().decode(StudioArtifactTransfer.self, from: data) else { return }
                Task { @MainActor in
                    guard let artifact = vm.artifacts.first(where: { $0.id == transfer.artifactID }),
                          vm.canFileInPageSpace(artifact) else { return }
                    vm.movePages([artifact.id], toPageSpace: spaceID)
                }
            }
        }
        return true
    }
}

/// A sidebar row as ChatGPT draws one: a 16-point monochrome glyph, the
/// name, a grey fill when chosen and a lighter one under the pointer, and a
/// trailing control that shows only under the pointer.
struct SpaceSidebarRow<Icon: View, Trailing: View>: View {
    let title: String
    let isSelected: Bool
    var accessibilityIdentifier: String? = nil
    /// A small green tag after the title, always shown (`SpaceDestination.badge`).
    var badge: String? = nil
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let trailing: () -> Trailing
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.78))
                    .frame(width: 16, height: 16)
                Text(title)
                    .zoomedSystemFont(size: 13, weight: isSelected ? .medium : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let badge {
                    SpaceSidebarBadge(text: badge)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: SpaceSidebarMetrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: SpaceSidebarMetrics.rowCornerRadius, style: .continuous)
                    .fill(isSelected
                          ? SpaceSidebarMetrics.selectedFill
                          : (isHovering ? SpaceSidebarMetrics.hoverFill : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: SpaceSidebarMetrics.rowCornerRadius, style: .continuous))
        }
        // The row paints its own hover fill (AGENTS.md, "Every button lights
        // up under the pointer": a row that washes itself takes `.plain`).
        .buttonStyle(.plain)
        .ownsRowHoverWash()
        .overlay(alignment: .trailing) {
            trailing()
                .padding(.trailing, 4)
                .opacity(isHovering ? 1 : 0)
        }
        .onHover { isHovering = $0 }
        .help(badge.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

/// The green tag a sidebar row wears after its name, such as Beta on
/// Canvases: the Studio's green, its text over a pale wash, deeper in a light
/// window and lighter in a dark one so it reads in both.
private struct SpaceSidebarBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .zoomedSystemFont(size: 10, weight: .semibold)
            .foregroundStyle(NotebookStudioHue.green.glyph)
            .textSelection(.disabled)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule(style: .continuous).fill(NotebookStudioHue.green.wash))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A section's small grey label, and a control that shows beside it.
struct SpaceSidebarSectionHeader<Trailing: View>: View {
    let title: String
    /// A header that folds its section, with ChatGPT's chevron after the
    /// name ("Recents ⌄"); nil for one that does not.
    var folded: Binding<Bool>? = nil
    @ViewBuilder let trailing: () -> Trailing
    @State private var isHovering = false

    init(title: String, folded: Binding<Bool>? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.folded = folded
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .zoomedSystemFont(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            if let folded {
                Image(systemName: "chevron.down")
                    .zoomedSystemFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded.wrappedValue ? -90 : 0))
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            // Under the pointer only, as the rows' own controls are.
            trailing()
                .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let folded { folded.wrappedValue.toggle() }
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(folded.map { $0.wrappedValue ? "Folded" : "Open" } ?? "")
    }
}

extension SpaceSidebarSectionHeader where Trailing == EmptyView {
    init(title: String, folded: Binding<Bool>? = nil) {
        self.init(title: title, folded: folded) { EmptyView() }
    }
}

/// ChatGPT's page row menu, on a Pinned or Recents row's ⋯ and right-click and
/// on a list row's: Rename… · Pin · Delete | Share… · Copy ▸ · Download as
/// Markdown | Open in new window (product owner, 2026-10-07, with the Codex app's
/// own menu: "need full parity"). Delete is **Move to Trash**: Trash is the
/// archive, so nothing is lost. A team's page and a record that is no
/// Markdown page (a site, a linked Google Doc) show only what applies.
struct SpacePageRowMenuItems: View {
    @Environment(StudioViewModel.self) private var vm
    let artifact: ArtifactRecord
    /// The row's own Rename… (an alert beside the list); nil leaves it out.
    var onRename: (() -> Void)? = nil

    private var isOwn: Bool { artifact.teamID == nil && vm.activeTeamID == nil }

    var body: some View {
        if isOwn {
            if let onRename {
                Button("Rename…", systemImage: "pencil", action: onRename)
            }
            SpacePagePinItem(artifact: artifact)
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                Task { await vm.moveArtifactToTrash(artifact.id) }
            }
            Divider()
        }
        if SpacePageSharingItems.applies(to: artifact) {
            SpacePageSharingItems(artifact: artifact)
            Divider()
        }
        OtherWindowMenuItem(artifact.teamID != nil && vm.activeTeamID == nil
                            ? .teamArtifact(artifact.id) : .doc(artifact.id))
    }
}

/// **Pin** and **Unpin**, for the learner's own pages.
struct SpacePagePinItem: View {
    @Environment(StudioViewModel.self) private var vm
    let artifact: ArtifactRecord

    var body: some View {
        let pinned = vm.isPagePinned(artifact.id)
        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
            vm.setPagePinned(artifact.id, pinned: !pinned)
        }
    }
}

/// **Share…**, **Copy ▸** (as Markdown, the link) and **Download as
/// Markdown**: what ChatGPT's page menu offers for taking a page out, for a
/// Markdown page. A site or a linked Google Doc has no Markdown body to give.
struct SpacePageSharingItems: View {
    @Environment(StudioViewModel.self) private var vm
    let artifact: ArtifactRecord

    static func applies(to artifact: ArtifactRecord) -> Bool {
        artifact.section == .docs && artifact.linkedKind == nil
    }

    var body: some View {
        Button("Share…", systemImage: "square.and.arrow.up") {
            ArtifactSharingService.shared.presentShare(artifactID: artifact.id, title: artifact.title)
        }
        Menu {
            Button("Copy as Markdown", systemImage: "doc.plaintext") { copyMarkdown() }
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(StudioEntityLink.doc(artifact.id).markdownDestination, forType: .string)
                vm.showToast("Link copied")
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button("Download as Markdown", systemImage: "arrow.down.to.line") { downloadMarkdown() }
    }

    private func copyMarkdown() {
        Task {
            do {
                let snapshot = try await vm.artifactMarkdown(artifact.id)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snapshot.markdown, forType: .string)
                vm.showToast("Copied as Markdown")
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    private func downloadMarkdown() {
        Task {
            do {
                let snapshot = try await vm.artifactMarkdown(artifact.id)
                guard let url = await PageExport.chooseDestination(title: artifact.title, format: .markdown) else { return }
                try await PageExport.write(Data(snapshot.markdown.utf8), to: url)
                vm.showToast("Exported \(url.lastPathComponent)")
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }
}

/// A team's mark in the sidebar: its first letter on a soft square.
struct SpaceTeamMark: View {
    let name: String

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 15, height: 15)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// What kind of thing a row is, at a glance: a page, a Google Doc, a site,
/// a picture.
struct SpaceItemGlyph: View {
    let artifact: ArtifactRecord?
    var isImage = false
    var size: CGFloat = 13

    var body: some View {
        if isImage {
            Image(systemName: "photo")
                .zoomedSystemFont(size: size, weight: .regular)
        } else if let artifact, let linkedKind = artifact.linkedKind {
            LinkedPageIcon(kind: linkedKind, height: size + 1)
        } else if artifact?.isMnemonicReading == true {
            Image(systemName: "text.book.closed")
                .zoomedSystemFont(size: size, weight: .regular)
        } else {
            Image(systemName: "doc.text")
                .zoomedSystemFont(size: size, weight: .regular)
        }
    }
}

/// **New space**, as ChatGPT's New ▸ Space asks for one: a name, and a
/// folded **Invite people**. Without it Create makes one of the learner's own
/// spaces at once, with nothing sent anywhere (`createPageSpace`); unfolded,
/// Create makes a shared space — a team (`createTeam`) — and opens the
/// system's sharing sheet to invite people by name or email
/// (`TeamSharingService`). The product owner, 2026-10-06: "perhaps we also need a
/// 'spaces' equivalent"; until then New space always made a team.
struct SpaceNewSpaceSheet: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    /// Hears of the place made: the learner's space, or the team.
    let onCreated: (SpaceDestination) -> Void
    @State private var name = ""
    @State private var invitesPeople = false
    @State private var isCreating = false
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool { PageSpaces.cleanedName(name) != nil && !isCreating }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New space")
                .zoomedSystemFont(size: 15, weight: .semibold)
            TextField("Name your space", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(create)
                .disabled(isCreating)
                .accessibilityIdentifier("space.newSpace.name")
            DisclosureGroup("Invite people", isExpanded: $invitesPeople) {
                Text("After Create, choose who to invite by name or email.")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .zoomedSystemFont(size: 12.5)
            .disabled(isCreating)
            .accessibilityIdentifier("space.newSpace.invite")
            if let errorText {
                Text(errorText)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("space.newSpace.create")
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard canCreate, let cleaned = PageSpaces.cleanedName(name) else { return }
        guard invitesPeople else {
            guard let space = vm.createPageSpace(named: cleaned) else { return }
            dismiss()
            onCreated(.space(space.id))
            return
        }
        isCreating = true
        errorText = nil
        Task {
            do {
                let team = try await vm.createTeam(name: cleaned)
                isCreating = false
                dismiss()
                onCreated(.team(team.id))
                TeamSharingService.shared.presentMembers(for: team)
            } catch {
                isCreating = false
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - The Space around a hub pane

/// A hub pane drawn inside the Space: the sidebar on the leading edge with
/// the hub lit, the pane beside it, and on the chrome line the sidebar's own
/// header over the sidebar, as on the Space's own pane. A canvas
/// opens the same way (`KnowledgeMapPane`) and a page does (`ArtifactCanvas`),
/// so going from the courses to a page changes only what is beside the
/// sidebar. The sidebar's hide state and the room it needs are the Space's
/// (`space.sidebarHidden`, `SpaceSidebarMetrics.minimumPaneWidth`).
struct SpaceFrame<Content: View>: View {
    @Environment(StudioViewModel.self) private var vm
    /// The window this pane is in. Absent outside a Studio window.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset
    @AppStorage("space.sidebarHidden") private var sidebarHiddenByLearner = false
    @State private var paneWidth: CGFloat = 0
    @State private var linkSection: ArtifactSection?
    @State private var linkedArtifactID: String?
    @State private var isCreatingSpace = false

    private let hub: SpaceHub
    private let content: Content

    init(hub: SpaceHub, @ViewBuilder content: () -> Content) {
        self.hub = hub
        self.content = content()
    }

    private var showsSidebar: Bool {
        !sidebarHiddenByLearner && (paneWidth <= 0 || paneWidth >= SpaceSidebarMetrics.minimumPaneWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                SpaceSidebar(
                    selection: nil,
                    openArtifactID: nil,
                    hub: hub,
                    onSelect: showPlace,
                    onOpenRecent: openRecent,
                    onNewPage: newPage,
                    onLink: { linkSection = $0 },
                    onNewSpace: { isCreatingSpace = true },
                    onSearch: { showPlace(.all) }
                )
                .frame(width: SpaceSidebarMetrics.width)
                .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.18), value: showsSidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { paneWidth = $0 }
        .background(alignment: .leading) {
            if showsSidebar {
                SpaceSidebarMetrics.background
                    .frame(width: SpaceSidebarMetrics.width)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .studioChromeLineHeader {
            HStack(spacing: 0) {
                if showsSidebar {
                    // The sidebar's top line is its first row.
                    SpaceSidebarChromeSpace()
                    StudioChromeLineDivider()
                }
                Spacer(minLength: 0)
            }
        }
        .sheet(item: $linkSection, onDismiss: {
            guard let id = linkedArtifactID else { return }
            linkedArtifactID = nil
            vm.revealArtifact(id, in: windowState ?? vm.activeWindowState)
        }) { section in
            LinkPageSheet(section: section) { urlString in
                let artifact = try await vm.linkPage(
                    urlString: urlString,
                    in: section,
                    homeNotebookID: nil,
                    linkedNotebookIDs: []
                )
                linkedArtifactID = artifact.id
            }
        }
        .sheet(isPresented: $isCreatingSpace) {
            SpaceNewSpaceSheet(onCreated: showPlace)
        }
    }

    // MARK: Actions

    /// A place of the Space: the Space tab takes this pane's place, showing
    /// it.
    private func showPlace(_ place: SpaceDestination) {
        let window = windowState ?? vm.activeWindowState
        if window.spaceDestinationKey != place.key { window.spaceDestinationKey = place.key }
        vm.showSpaceTab(.space, in: window)
    }

    private func openRecent(_ item: SpaceRecents.Item) {
        let window = windowState ?? vm.activeWindowState
        switch item.kind {
        case .artifact:
            guard let artifact = vm.artifacts.first(where: { $0.id == item.id }) else { return }
            if vm.activeTeamID == nil, artifact.teamID != nil {
                Task { await vm.openTeamArtifact(artifact.id, in: window) }
            } else {
                vm.revealArtifact(artifact.id, in: window)
            }
        case .canvas:
            vm.openCanvas(item.id, in: window)
        case .list:
            showPlace(.list(item.id))
        case .image:
            showPlace(.images)
        }
    }

    /// New page: made in the open library, in no notebook, and opened.
    private func newPage() {
        let window = windowState ?? vm.activeWindowState
        Task {
            do {
                let snapshot = try await vm.createArtifact(
                    title: ArtifactPlaceholderTitle.current,
                    homeNotebookID: nil,
                    linkedNotebookIDs: [],
                    pageSpaceID: nil
                )
                vm.revealArtifact(snapshot.artifact.id, in: window)
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
