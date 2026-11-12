#if os(macOS)
import SwiftUI

/// **The Space**, the home of the app: ChatGPT's Space, copied (product owner,
/// 2026-10-06, showing ChatGPT's: "maybe just copy this spaces design entirely
/// from chatgpt; it looks good. i want you to do that and get to feature
/// parity and also make sure it looks equally beautiful"), and the home
/// (product owner, 2026-10-09: the Notebooks home "doesn't add anything"), so
/// the Space's All lists every notebook and course. The Space sidebar
/// on the leading edge (New chat; Notebooks, Courses, Pages, Sites, Images,
/// Google Drive; Recents; Spaces; Trash), and beside it the place chosen
/// (`SpaceBrowseView`). A page opens in the page pane, which draws the same
/// sidebar beside it (`ArtifactCanvas`), so opening one changes only what is
/// beside the sidebar (docs/docs-design.md, "The Space").
///
/// There is no overarching artifacts page (product owner, 2026-10-06: "maybe
/// artifacts should JUST be at the notebook level.. not some overarching
/// artifacts page"); Docs, Sites and Ideas sit above the notebooks. Images, a
/// row of ChatGPT's sidebar, lists every picture this Mac holds. The other
/// one-off kinds — animations, audio overviews, films,
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
    /// The learner's choice to keep the sidebar out of the way; this window's.
    private var sidebarHiddenByLearner: Bool { windowState?.spaceSidebarHidden ?? false }

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
                    onNewSpace: { isCreatingSpace = true },
                    onSearch: search
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
        // Over the sidebar the chrome line holds nothing but the window's
        // own controls: the sidebar's top line is its first row
        // (`SpaceSidebar.onSearch`). Over the list it holds nothing either.
        .studioChromeLineHeader {
            HStack(spacing: 0) {
                if showsSidebar {
                    SpaceSidebarChromeSpace()
                    // The sidebar's divider, on the chrome line, as Codex
                    // draws the one between its sidebar and the thread.
                    StudioChromeLineDivider()
                }
                Spacer(minLength: 0)
            }
        }
        .studioCenterTabCloseChrome(for: .artifacts)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space")
        // The list is the view model's; nothing else is guaranteed to have
        // loaded it, and a home opened first after launch would say "Nothing
        // here yet" over a full library.
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

    /// The sidebar's search: every place at once, All with its field focused,
    /// as Codex's sidebar search looks through every space and what pages say
    /// ("Search spaces and content"). A place's own field searches that place.
    private func search() {
        select(.all)
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
/// its Pages and Sites rows, dragged to an edge or opened beside
/// (`SpaceDestination.openableKind`). Courses is not a kind here: it is a
/// pane of its own. Ideas have no row: the chat is
/// the way to them (`SpaceTab`); their pane still opens beside a Doc whose
/// idea link is followed (`StudioViewModel.openIdea`).
enum ArtifactsHomeKind: String, CaseIterable, Identifiable {
    case docs, sites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .docs: return "Pages"
        case .sites: return "Sites"
        }
    }

    /// The kind's own pane, which Open Beside and a drag to an edge put in a
    /// column of its own, so two kinds — Pages and Sites, say — sit side by
    /// side.
    var centerTab: StudioCenterTab {
        switch self {
        case .docs: return .notepad
        case .sites: return .sites
        }
    }

    /// The kind's own pane, for Open in Other Window.
    var otherWindowDestination: StudioWindowDestination {
        switch self {
        case .docs: return .docs
        case .sites: return .sites
        }
    }

    /// Opens the kind's own pane — a place, so the click lands on its index.
    @MainActor
    func open(in vm: StudioViewModel) {
        switch self {
        case .docs: vm.openNotepadInReader()
        case .sites: vm.openSitesInReader()
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
        // lands on its index — once the pane is on screen. Were it not on
        // screen, the opener would cover the pane beside which it was asked
        // for, so nothing opens.
        guard vm.activeCenterTabs.contains(centerTab) else { return }
        open(in: vm)
    }
}

#endif
