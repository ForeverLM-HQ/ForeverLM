#if os(macOS)
import SwiftUI

/// **The Space**, the home of the app: ChatGPT's Space, copied (product owner,
/// 2026-10-06, showing ChatGPT's: "maybe just copy this spaces design entirely
/// from chatgpt; it looks good. i want you to do that and get to feature
/// parity and also make sure it looks equally beautiful"), and the home since
/// 2026-10-09, when the Notebooks home went ("it doesn't add anything") and
/// the Space's All began to list every notebook and course. The Space sidebar
/// on the leading edge (New page; All, Pages, Sites, Images, Ideas, Google
/// Drive; Recents; Spaces; Trash), and beside it the place chosen
/// (`SpaceBrowseView`). A page opens in the page pane, which draws the same
/// sidebar beside it (`ArtifactCanvas`), so opening one changes only what is
/// beside the sidebar (docs/docs-design.md, "The Space").
///
/// It began on 2026-09-17 as the Artifacts page over everything made, became
/// the Notebooks home's Artifacts tab at shell stage 4 (2026-10-01), and its
/// Docs tab on 2026-10-06, when the product owner said "maybe artifacts should JUST be at the
/// notebook level.. not some overarching artifacts page" and kept Docs, Sites
/// and Ideas above the notebooks. Copying the Space brought one kind back the
/// same day: Images, a row of ChatGPT's sidebar, lists every picture this Mac
/// holds again. The other one-off kinds — animations, audio overviews, films,
/// walkthroughs, narrations, and a mnemonic reading a notebook holds — stay
/// in their notebook's Studio (`NotebookOutputs`,
/// `isListedOnlyInItsNotebook`).
struct ArtifactsHomePane: View {
    @Environment(StudioViewModel.self) private var vm
    /// The window this pane is in; the place it shows is the window's.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset
    @State private var searchText = ""
    @State private var searchFocusRequest = 0
    /// The link sheet, and the section it links into: a Google Doc into
    /// Pages, a Claude artifact or a Codex site into Sites.
    @State private var linkSection: ArtifactSection?
    /// The record just linked, opened once its sheet has gone.
    @State private var linkedArtifactID: String?
    @State private var isCreatingSpace = false
    @State private var paneWidth: CGFloat = 0
    /// The learner's choice to keep the sidebar out of the way; this Mac's.
    @AppStorage("space.sidebarHidden") private var sidebarHiddenByLearner = false

    private var destination: SpaceDestination {
        SpaceDestination(key: windowState?.spaceDestinationKey ?? "all")
    }

    /// The sidebar shows unless the learner hid it or the pane is too narrow
    /// for it beside a readable list.
    private var showsSidebar: Bool {
        !sidebarHiddenByLearner && (paneWidth <= 0 || paneWidth >= SpaceSidebarMetrics.minimumPaneWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                SpaceSidebar(
                    selection: destination,
                    openArtifactID: nil,
                    onSelect: select,
                    onOpenRecent: openRecent,
                    onNewPage: newPage,
                    onLink: { linkSection = $0 },
                    onNewSpace: { isCreatingSpace = true }
                )
                .frame(width: SpaceSidebarMetrics.width)
                .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            SpaceBrowseView(
                destination: destination,
                showsPlaceMenu: !showsSidebar,
                searchText: $searchText,
                searchFocusRequest: searchFocusRequest,
                onSelectPlace: select,
                onOpen: open,
                onNewPage: newPage,
                onLink: { linkSection = $0 },
                onNewSpace: { isCreatingSpace = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.18), value: showsSidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { paneWidth = $0 }
        .background(alignment: .leading) {
            // The sidebar's tone, in the card under the band: the band above
            // it is the window's chrome, as Codex's is over its sidebar.
            if showsSidebar {
                SpaceSidebarMetrics.background
                    .frame(width: SpaceSidebarMetrics.width)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // The sidebar's own line over the sidebar, and the Space's tabs over
        // the list, on the chrome line.
        .studioChromeLineHeader {
            HStack(spacing: 0) {
                if showsSidebar {
                    SpaceSidebarHeader(onSearch: search)
                        .frame(width: max(0, SpaceSidebarMetrics.width - headerLeadingInset))
                    // The sidebar's divider, on the chrome line, as Codex
                    // draws the one between its sidebar and the thread.
                    StudioChromeLineDivider()
                }
                // A pane too narrow for the tabs folds them into one menu.
                ViewThatFits(in: .horizontal) {
                    SpaceTabBar(selected: .space)
                    SpaceTabBar(selected: .space, compact: true)
                }
                .padding(.horizontal, 24)
                .background(WindowDragBlocker())
                Spacer(minLength: 0)
            }
        }
        .studioCenterTabCloseChrome(for: .artifacts)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space")
        // The list is the view model's; nothing else is guaranteed to have
        // loaded it. Until 2026-09-19 the home drew only what a Docs or Sites
        // pane had loaded before it, so opened first after launch it said
        // "Nothing here yet" over a full library.
        .task {
            await vm.loadArtifacts()
            await vm.refreshPublishedDocStatuses()
        }
        .task {
            await vm.loadLearningGoals()
            await vm.loadIdeas()
        }
        // What was linked opens in its pane once the sheet has gone.
        .sheet(item: $linkSection, onDismiss: {
            guard let id = linkedArtifactID else { return }
            linkedArtifactID = nil
            vm.revealArtifact(id, in: windowState)
        }) { section in
            LinkPageSheet(section: section) { urlString in
                let artifact = try await vm.linkPage(
                    urlString: urlString,
                    in: section,
                    homeNotebookID: nil,
                    linkedNotebookIDs: []
                )
                // Linked from a space: it is filed there, as a new page is.
                if let spaceID = destination.pageSpaceID {
                    vm.filePages([artifact.id], inPageSpace: spaceID)
                }
                linkedArtifactID = artifact.id
            }
        }
        .sheet(isPresented: $isCreatingSpace) {
            SpaceNewSpaceSheet(onCreated: select)
        }
    }

    // MARK: Actions

    private func select(_ place: SpaceDestination) {
        guard let windowState else { return }
        if windowState.spaceDestinationKey != place.key { windowState.spaceDestinationKey = place.key }
    }

    /// The sidebar's search: every place at once, with the field focused.
    private func search() {
        if destination == .images || destination == .ideas || destination == .trash {
            select(.all)
        }
        searchFocusRequest += 1
    }

    /// A record opens in its own pane; a team's record listed in My Library
    /// in its team's library, where it lives.
    private func open(_ artifact: ArtifactRecord) {
        if vm.activeTeamID == nil, artifact.teamID != nil {
            Task { await vm.openTeamArtifact(artifact.id, in: windowState) }
        } else {
            vm.revealArtifact(artifact.id, in: windowState)
        }
    }

    private func openRecent(_ item: SpaceRecents.Item) {
        switch item.kind {
        case .artifact:
            guard let artifact = vm.artifacts.first(where: { $0.id == item.id }) else { return }
            open(artifact)
        case .canvas:
            vm.openCanvas(item.id, in: windowState)
        case .list:
            select(.list(item.id))
        case .image:
            select(.images)
        }
    }

    /// New page: made in the open library, in no notebook — in the space
    /// chosen, when one is — and opened.
    private func newPage() {
        Task {
            do {
                let snapshot = try await vm.createArtifact(
                    title: ArtifactPlaceholderTitle.current,
                    homeNotebookID: nil,
                    linkedNotebookIDs: [],
                    pageSpaceID: destination.pageSpaceID
                )
                vm.revealArtifact(snapshot.artifact.id, in: windowState)
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Card pictures

    /// The two kinds of record a picture is made for.
    struct Entry {
        enum Kind: Equatable {
            case doc, site
        }
    }

    /// Which pictures are made how: a Site's page is photographed at its
    /// address; a Doc draws its own lines.
    static func previewRequest(kind: Entry.Kind, linkedURL: String?, linkedKind: LinkedPageKind?) -> ArtifactPreviewStore.Request? {
        switch kind {
        case .site:
            // A page on the web, or a site kept in the library, which the
            // snapshot's web view serves from its folder.
            guard let linkedURL, let url = URL(string: linkedURL),
                  url.scheme?.hasPrefix("http") == true || LinkedPage.localSiteID(from: url) != nil else { return nil }
            return .page(url: url, kind: linkedKind)
        case .doc:
            return nil
        }
    }
}

extension ArtifactSection: Identifiable {
    var id: String { rawValue }
}

/// One of the kinds that opens in a pane of its own from the Space sidebar —
/// its Pages, Sites and Ideas rows, dragged to an edge or opened beside
/// (`SpaceDestination.openableKind`). Courses and Goals are not kinds here:
/// each is a pane of its own.
enum ArtifactsHomeKind: String, CaseIterable, Identifiable {
    case docs, sites, ideas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .docs: return "Pages"
        case .sites: return "Sites"
        case .ideas: return "Ideas"
        }
    }

    var symbolName: String {
        switch self {
        case .docs: return "note.text"
        case .sites: return "globe"
        case .ideas: return "lightbulb"
        }
    }

    /// The kind's colour: its badge on every card, and the ground behind a
    /// picture that is not made yet.
    var tint: Color {
        switch self {
        case .docs: return .blue
        case .sites: return .teal
        case .ideas: return .yellow
        }
    }

    /// "3 pages", "1 site", "No ideas yet".
    func countLabel(_ count: Int) -> String {
        let singular: String
        let plural: String
        switch self {
        case .docs: (singular, plural) = ("page", "pages")
        case .sites: (singular, plural) = ("site", "sites")
        case .ideas: (singular, plural) = ("idea", "ideas")
        }
        if count == 0 { return "No \(plural) yet" }
        return "\(count) \(count == 1 ? singular : plural)"
    }

    /// Where the first one comes from, under an empty chip.
    var emptyHint: String {
        switch self {
        case .docs: return "Write one with your sources beside you, or link a Google Doc."
        case .sites: return "Publish a site from ForeverLM, or link a Codex site or a Claude artifact."
        // Ideas draw their own list, empty line included.
        case .ideas: return ""
        }
    }

    /// The kind's own pane, which Open Beside and a drag to an edge put in a
    /// column of its own, so two kinds — Docs and Ideas, say — sit side by
    /// side.
    var centerTab: StudioCenterTab {
        switch self {
        case .docs: return .notepad
        case .sites: return .sites
        case .ideas: return .ideas
        }
    }

    /// Ideas are sentences, not things with a picture, so under their chip
    /// the home draws the Ideas' own list — the bands, the jot field —
    /// instead of cards. An Idea is not shared with a team the way a record
    /// is, so the team filter stands down for it.
    var listsOwnRows: Bool { self == .ideas }

    /// Where a link made under this kind's chip is filed: a Google Doc in
    /// Docs, a Claude artifact or a Codex site in Sites. An Idea is jotted,
    /// not linked in.
    var linkSection: ArtifactSection? {
        switch self {
        case .docs: return .docs
        case .sites: return .sites
        case .ideas: return nil
        }
    }

    /// The kind's own pane, for Open in Other Window.
    var otherWindowDestination: StudioWindowDestination {
        switch self {
        case .docs: return .docs
        case .sites: return .sites
        case .ideas: return .ideas
        }
    }

    /// Opens the kind's own pane — a place, so the click lands on its index.
    @MainActor
    func open(in vm: StudioViewModel) {
        switch self {
        case .docs: vm.openNotepadInReader()
        case .sites: vm.openSitesInReader()
        case .ideas: vm.openIdeasInReader()
        }
    }

    /// Opens the kind's own pane in a column beside what is on screen,
    /// keeping one of the tab's panes already showing (product owner, 2026-09-29:
    /// "make sure we can also open 2 different artifact panes side by side;
    /// e.g. docs and ideas"). See `StudioViewModel.openArtifactKindBeside`.
    @MainActor
    func openBeside(in vm: StudioViewModel) {
        vm.openArtifactKindBeside(centerTab)
        // Then the kind's own opener, for what it asks of its pane — Docs
        // lands on its index — once the pane is on screen. With no room for
        // it (every other pane pinned, three already), the opener would
        // cover the pane beside which it was asked for, so nothing opens.
        guard vm.activeCenterTabs.contains(centerTab) else { return }
        open(in: vm)
    }
}

// MARK: - The Space's tabs

/// The Space's tabs, Space and Goals (`SpaceTab.barTabs`; the notebooks and
/// the courses are listed in the Space), on the chrome line of each of their
/// panes (shell stage 4): a click shows that tab in the same pane
/// (`showSpaceTab`). The Space is lit while the Courses list shows beside its
/// sidebar. The pane's own right-click menus — its rail header's, a kind
/// chip's — keep Open Beside and Open in Other Window.
struct SpaceTabBar: View {
    @Environment(StudioViewModel.self) private var vm
    /// The window this pane is in. Absent outside a Studio window.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.uiZoomScale) private var uiZoomScale
    let selected: SpaceTab
    /// One control naming the tab shown, whose menu lists the two, for a
    /// pane too narrow for the row.
    var compact = false

    var body: some View {
        if compact {
            tabMenu
        } else {
            tabRow
        }
    }

    @ViewBuilder
    private var tabMenu: some View {
        let label = HStack(spacing: 4) {
            Text(selected.barTab.title)
                .zoomedSystemFont(size: 13, weight: .semibold)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .zoomedSystemFont(size: 9, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        if #available(macOS 14.4, *) {
            TitlebarBandButton(
                help: "Show another tab",
                accessibilityLabel: "Space tab",
                accessibilityValue: selected.barTab.title,
                accessibilityIdentifier: "space.tabMenu",
                controlWidth: labelWidth(selected.barTab) + 14 * uiZoomScale,
                action: {},
                menu: { NSHostingMenu(rootView: tabMenuItems) }
            ) {
                label
            }
        } else {
            Menu {
                tabMenuItems
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .hoverHighlight()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show another tab")
        }
    }

    private var tabMenuItems: some View {
        ForEach(SpaceTab.barTabs) { tab in
            Button {
                show(tab)
            } label: {
                if tab == selected.barTab {
                    Label(tab.title, systemImage: "checkmark")
                } else {
                    Text(tab.title)
                }
            }
        }
    }

    private var tabRow: some View {
        HStack(spacing: 4) {
            ForEach(SpaceTab.barTabs) { tab in
                let isSelected = tab == selected.barTab
                TitlebarBandButton(
                    help: isSelected ? tab.title : "Show \(tab.title)",
                    accessibilityLabel: tab.title,
                    accessibilityValue: isSelected ? "Selected" : nil,
                    accessibilityIdentifier: "space.tab.\(tab.rawValue)",
                    controlWidth: labelWidth(tab),
                    action: { show(tab) }
                ) {
                    Text(tab.title)
                        .zoomedSystemFont(size: 13, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .frame(width: labelWidth(tab), height: StudioPanelChrome.centerTabCloseButtonSize)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(isSelected ? 0.07 : 0))
                        )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space tabs")
    }

    /// A tab's label at the window's zoom, with room for its wash.
    private func labelWidth(_ tab: SpaceTab) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13 * uiZoomScale, weight: .semibold)
        let text = (tab.title as NSString).size(withAttributes: [.font: font]).width
        return ceil(text) + 18 * uiZoomScale
    }

    private func show(_ tab: SpaceTab) {
        guard tab != selected else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            vm.showSpaceTab(tab, in: windowState ?? vm.activeWindowState)
        }
    }
}
#endif
