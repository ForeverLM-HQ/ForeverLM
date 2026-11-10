import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Carries formatting between the page's menu and the editor beneath it.
/// Formatting is the editor's selection bar since 2026-10-06 (docs/ui-design.md,
/// "Quiet chrome"); the page menu's Format items are for a writer without the
/// keyboard, and the editor is the only thing that can run them. A press
/// travels down as a request, and what the caret currently sits inside travels
/// back up so the menu can check the matching items.
@Observable
@MainActor
final class ArtifactFormattingBridge {
    var activeFormats: Set<ArtifactFormatCommand> = []
    var request: ArtifactFormatRequest?

    func run(_ command: ArtifactFormatCommand) {
        request = ArtifactFormatRequest(command: command)
    }

    /// The top line pill's Image, Visualize and Insert +: rows of the editor's
    /// `/` list, run at the caret by the editor.
    func run(_ tool: ArtifactEditorTool) {
        request = ArtifactFormatRequest(tool: tool)
    }
}

/// Carries the open page's own controls up to its top line: the page menu,
/// Edit or Update Page, the comments and Share are chrome, on the pane's one
/// chrome line, where they hold still whether the page shows its editor or
/// its rendered page. What they act on — the sheets, the confirmations, the
/// comments drawer, the page itself — lives in the editor beneath. The header
/// flips the bits here and the editor binds its sheets to them; the editor's
/// comments travel back up so the header shows their count. One instance per
/// pane, reset by each page's editor as it appears, so a page never inherits
/// the last one's Page choice or an open drawer.
@Observable
@MainActor
final class ArtifactDocChromeBridge {
    /// The Page view: the doc drawn the way foreverlm.com draws it, rendered by
    /// the site from the current text. The editor is hidden while it shows.
    /// Only View as Page turns it on: every page opens in the editor, published
    /// or not, as a page opens in Codex (docs/codex-parity-audit.md, F1).
    var showsPage = false
    /// The panel beside the page, Comments or Page activity: one at a time,
    /// as Codex's page holds one.
    var sidePanel: PageSidePanel?
    var isCommentsVisible: Bool {
        get { sidePanel == .comments }
        set { setSidePanel(.comments, shown: newValue) }
    }
    /// The page's **Page activity**: its versions on this Mac
    /// (`PageActivityPanel`), opened by the clock and the page menu.
    var isActivityVisible: Bool {
        get { sidePanel == .activity }
        set { setSidePanel(.activity, shown: newValue) }
    }
    var isPublishSheetPresented = false
    var showUnpublishConfirmation = false
    var isConvertingToGoogleDoc = false
    /// The open comments on the page, set by its editor; the header shows the
    /// comments control while there are any.
    var openCommentCount = 0
    /// The editor's last failure; the header offers Reload while it stands.
    var errorMessage: String?
    var reloadGeneration = 0
    /// The header asked for the open draft to be published to its team; the
    /// editor flushes its text first, then writes.
    var publishDraftRequest: ArtifactDraftPublishRequest?
    /// The team copy changed since the draft began in a way the merge could
    /// not combine; the writer says whether the draft replaces it.
    var showDraftPublishConflict = false
    var showDiscardDraftConfirmation = false
    /// The page menu's **Edit with AI**; each bump opens the editor's Edit with
    /// AI panel on the selection, or on the section at the caret.
    var aiEditOpenRequestID = 0
    /// The page menu's **Export ▸** item last pressed; the editor writes the
    /// file, since it holds the text and draws the page.
    var exportRequest: PageExportRequest?
    /// The page menu's **Rename…** while the editor shows; each bump puts the
    /// caret in the page's title.
    var titleEditRequestID = 0
    /// Write the editor's draft through before the page is published from the
    /// header's Share popover, so the page carries what the pane shows. Set by
    /// the editor while it is on screen.
    @ObservationIgnored var flushDraft: (() async throws -> Void)?
    /// The page's side chat (`PageSideChatLayer`, docs/pages-side-chat-design.md).
    /// Whether the canvas draws its card over this page; the page's chat entry
    /// points open it when it does and dock the Chat pane when it does not.
    /// Set by the canvas, so a page appearing does not reset it.
    var hostsSideChat = false
    /// The editor holds the page's text and sources, so it builds what the
    /// card opens on and sets it here; the card takes it and clears it.
    var sideChatRequest: PageSideChatOpening?
    /// The page menu's Add to Chat and the card's New Chat ask the editor for
    /// a chat about the page as a whole, which it answers with `sideChatRequest`.
    var wholePageChatRequest: PageSideChatWholePageRequest?

    /// Edit or read: the page is the doc as foreverlm.com draws it.
    func togglePage() {
        showsPage.toggle()
    }

    private func setSidePanel(_ panel: PageSidePanel, shown: Bool) {
        if shown {
            sidePanel = panel
        } else if sidePanel == panel {
            sidePanel = nil
        }
    }

    /// A doc's editor appearing takes the header over. Every page opens in the
    /// editor; nothing of the previous doc's carries across.
    func reset() {
        showsPage = false
        sidePanel = nil
        isPublishSheetPresented = false
        showUnpublishConfirmation = false
        isConvertingToGoogleDoc = false
        openCommentCount = 0
        errorMessage = nil
        reloadGeneration = 0
        publishDraftRequest = nil
        showDraftPublishConflict = false
        showDiscardDraftConfirmation = false
        exportRequest = nil
        flushDraft = nil
        sideChatRequest = nil
        wholePageChatRequest = nil
    }
}

/// The panel beside an open page (`ArtifactDocChromeBridge.sidePanel`).
enum PageSidePanel: Equatable {
    case comments
    case activity
}

/// One press of Publish on a draft. A fresh value each time, so a second press
/// after a conflict is heard as its own request.
struct ArtifactDraftPublishRequest: Equatable {
    let id = UUID()
    var overwrite = false
}

/// The Docs pane and the Sites pane: one canvas, two sections. Docs holds the
/// Markdown docs and the linked Google Docs; Sites holds the linked Claude
/// artifacts and Codex sites (product owner, 2026-09-08: "make sure you do a split
/// within the app between sites and docs"). The section decides which records
/// are listed, what the home is called and offers, which link sheet opens and
/// what the menus say; the page an entry opens as is the record's own, so a
/// linked page renders the same in either.
struct ArtifactCanvas: View {
    @Environment(StudioViewModel.self) var vm
    @Environment(StudioWindowState.self) var windowState
    @Environment(\.openWindow) var openWindow
    @Environment(\.pageSideChatHosting) private var sideChatHosting
    /// The pane this canvas is drawn in: with Pages in two panes, a request
    /// naming a pane is this canvas's only when it names this one.
    @Environment(\.studioPaneGroupID) private var paneGroupID
    /// False while this canvas is kept mounted behind another tab of its pane
    /// (`StudioKeptPaneTabs`): its page is loaded but not on screen.
    @Environment(\.studioPaneTabIsShown) private var paneTabIsShown
    let section: ArtifactSection
    let notebookID: String?
    let onBack: (() -> Void)?

    /// Tells the window which page this canvas shows, or that it shows its
    /// index or is hidden behind another tab, for the chats of every window
    /// (`ChatOpenPanes.openOnScreen`).
    private func registerArtifactOnScreen() {
        let shown = isShowingIndex || !paneTabIsShown ? nil : selectedArtifactID
        let entry = shown.map { StudioWindowState.ArtifactOnScreen(pane: paneGroupID, artifactID: $0) }
        if windowState.artifactsOnScreen[screenKey] != entry {
            windowState.artifactsOnScreen[screenKey] = entry
        }
    }

    /// Whether a request aimed at `groupID`'s pane is this canvas's.
    func answers(paneOf groupID: UUID?) -> Bool {
        groupID == nil || paneGroupID == nil || groupID == paneGroupID
    }

    @State var selectedArtifactID: String?
    /// The canvas is showing its index: every doc listed across the pane and
    /// none open. Entered from the rail's Docs row, left by choosing a doc.
    /// While it is on, `reconcileSelection` leaves the selection empty rather
    /// than reopening the remembered doc.
    @State var isShowingIndex = false
    /// This canvas's key in `StudioWindowState.artifactsOnScreen`.
    @State private var screenKey = UUID()
    /// The canvas has read the library and chosen what to open at least once.
    /// Until then an empty selection is a doc on its way, not a choice left to
    /// the learner, so the pane spins rather than saying "Select a doc".
    @State var hasSettledSelection = false
    /// Which docs the home shows: every doc, the published ones, or the drafts.
    @State var homeFilter: ArtifactHomeFilter = .all
    @State var searchText = ""
    @State var formatting = ArtifactFormattingBridge()
    @State var linkedDoc = LinkedDocBridge()
    @State var artifactToUnlink: ArtifactRecord?
    /// A linked page about to become ForeverLM's own published page.
    @State var artifactToAdopt: ArtifactRecord?
    @State var workspaceWidth: CGFloat = 0
    @State var isLinkingPage = false
    @State var artifactToConvert: ArtifactRecord?
    @State var artifactToRename: ArtifactRecord?
    /// The page the page menu's Move to Page… is asking a parent for.
    @State var artifactToNest: ArtifactRecord?
    @State var artifactRenameDraft = ""
    @State var artifactToDelete: ArtifactRecord?
    /// A page with subpages whose Move to Trash is asking first, since its
    /// subpages go with it.
    @State var pageToTrash: ArtifactRecord?
    /// The open doc's chrome controls — Page/Edit, the published address, the
    /// overflow — drawn in the toolbar and acted on by the editor beneath.
    @State var docChrome = ArtifactDocChromeBridge()
    /// The teams holding a copy of the selected Doc in My Library, for the
    /// header's "Shared with" control; empty while a team is open.
    @State var sharingTeamsByArtifactID: [String: [TeamRecord]] = [:]
    /// The header's Share popover: who can open the selected Doc.
    @State var isSharePopoverPresented = false
    /// A block to show in the doc a reveal request brought forward — a block
    /// reference or a linked reference followed — held until that doc's
    /// editor takes it (docs/notes-graph-design.md).
    @State var pendingBlockReveal: ArtifactBlockRevealRequest?
    @SyncedStorage var isArtifactListVisible: Bool
    @SyncedStorage(ArtifactPageWidth.key) var pageWidth = ArtifactPageWidth.standard
    /// The learner's name, for the initials on the page's top line.
    @SyncedStorage(wrappedValue: "", MacAccountUser.displayNamePreferenceKey) var savedDisplayName: String
    @Environment(\.uiZoomScale) var uiZoomScale
    /// What the pane's swap control and close claim of the top line's trailing
    /// end; the page's own controls stop short of it.
    @Environment(\.studioChromeLineReservation) var chromeReservation
    /// How far the chrome line's row starts past the pane's leading edge, so
    /// the Space sidebar's top line ends where the sidebar does.
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset
    /// The learner's choice to keep the Space sidebar out of the way; this
    /// Mac's, shared with the Space home.
    @AppStorage("space.sidebarHidden") var spaceSidebarHiddenByLearner = false
    /// The Space's own search, apart from the side list's.
    @State var spaceSearchText = ""
    @State var spaceSearchFocusRequest = 0
    /// A link the Space sidebar asked for into the other section — a site from
    /// beside a page, a Google Doc from beside a site.
    @State var spaceLinkSection: ArtifactSection?
    @State private var isCreatingSpace = false

    init(section: ArtifactSection, notebookID: String?, onBack: (() -> Void)?) {
        self.section = section
        self.notebookID = notebookID
        self.onBack = onBack
        // Each section remembers its own list: Docs keeps the key it has
        // always synced under, so nothing a learner set is lost.
        let listKey: String
        switch section {
        case .docs: listKey = "notepad.artifactListVisible"
        case .sites: listKey = "sites.listVisible"
        case .animations: listKey = "animations.listVisible"
        }
        _isArtifactListVisible = SyncedStorage(wrappedValue: false, listKey)
    }

    /// Whether the pane can hold the doc list and a readable page side by side.
    /// Below this the two columns cannot both fit, and HSplitView answers that
    /// by overflowing the pane rather than by shrinking.
    var listFitsBesideDocument: Bool {
        workspaceWidth <= 0 || workspaceWidth >= 520
    }

    /// Publication is server-owned rather than Artifact metadata. The view
    /// model holds one bounded projection for every canvas, so the list has
    /// its Published state and the selected Doc its live address without one
    /// request per row.
    var publishedStatuses: [String: PublishedDocStatus] { vm.publishedDocStatuses }

    /// The section's records, by each record's link: a Notebook's canvas is
    /// its Docs, everything filed there that is not a site by its link, and
    /// the global canvases split the library the same way. A published
    /// Markdown doc is a Doc (product owner, 2026-09-10: "sites should only hold
    /// actual sites, published docs stay in docs").
    var artifacts: [ArtifactRecord] {
        // An audio overview is played and opened from its notebook's Studio,
        // never edited as a Doc; its body is only its recipe.
        if let notebookID {
            return vm.linkedArtifacts(notebookID: notebookID).filter { $0.section == section && !vm.isAudioOverview($0) }
        }
        return vm.artifacts.filter { vm.section(of: $0) == section && !vm.isAudioOverview($0) }
    }

    var selectedArtifact: ArtifactRecord? {
        guard let selectedArtifactID else { return nil }
        return artifacts.first { $0.id == selectedArtifactID }
    }

    var visibleArtifacts: [ArtifactRecord] {
        // A member's draft of a team Doc opens through Edit on the team copy;
        // it is never a row of its own. An archived record is off the list
        // until the Archived filter asks for it — and then it is the list. A
        // hidden record is off every list but Hidden's, archived or not: the
        // learner asked not to see it here, and Hidden is where it is found.
        let showingArchived = homeFilter == .archived
        let showingHidden = homeFilter == .hidden
        let listed = artifacts.filter {
            guard !TeamContentIdentity.isDraftArtifactID($0.id) else { return false }
            // A daily note is reached by its day, and found by a search.
            guard NotesGraphDocListing.isListed($0, searchQuery: searchText) else { return false }
            guard listsHere($0) else { return false }
            if showingHidden { return $0.isHidden }
            return !$0.isHidden && $0.isArchived == showingArchived
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? listed : listed.filter { artifact in
            artifact.title.localizedCaseInsensitiveContains(query)
                || artifact.linkedNotebookIDs.contains { notebookID in
                    vm.notebook(id: notebookID)?.title.localizedCaseInsensitiveContains(query) == true
                }
        }
        return matching.sorted(by: Self.isListedBefore)
    }

    /// Whether this canvas lists `artifact` at all. A mnemonic reading a
    /// notebook holds is listed only there — its Studio and the notebook's
    /// own Docs — never in the global canvas (`isListedOnlyInItsNotebook`),
    /// which still opens one a link, a card or a reveal asks for: `artifacts`
    /// keeps it.
    func listsHere(_ artifact: ArtifactRecord) -> Bool {
        notebookID != nil || !vm.isListedOnlyInItsNotebook(artifact)
    }

    /// A record keeps the place it was created in: newest first, and an edit
    /// never moves it. The product owner (2026-09-29): "when a doc gets edited, the order
    /// in the left side bar gets reordered to put the last edited at the top;
    /// don't do that. just do it by creation date and time". Storage hands the
    /// library over newest edit first, which other lists still want, so this
    /// list orders itself.
    private static func isListedBefore(_ lhs: ArtifactRecord, _ rhs: ArtifactRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// A Google Doc shown on its own gets the pane edge to edge: Google's page
    /// carries its own margins and chrome, and a frame of ours around them is
    /// two borders where one already reads as the doc's. With the list beside
    /// it the pane keeps its margins, so the two columns share one frame.
    var linkedDocFillsPane: Bool {
        selectedArtifact?.isLinked == true && (isSpaceCanvas || !isArtifactListVisible)
    }

    /// The global Pages and Sites panes are the Space with a page open: the
    /// Space sidebar beside the page, as ChatGPT draws a page in its Space
    /// (docs/docs-design.md, "The Space"). A notebook's own Pages keep their
    /// list, which the notebook's columns frame; Animations keep theirs.
    var isSpaceCanvas: Bool {
        notebookID == nil && section != .animations
    }

    /// The sidebar shows unless the learner hid it or the pane is too narrow
    /// for it beside a readable page.
    var showsSpaceSidebar: Bool {
        isSpaceCanvas && !spaceSidebarHiddenByLearner
            && (workspaceWidth <= 0 || workspaceWidth >= SpaceSidebarMetrics.minimumPaneWidth)
    }

    /// The place this window's Space shows when no page is open.
    var spaceDestination: SpaceDestination {
        SpaceDestination(key: windowState.spaceDestinationKey)
    }

    /// The Space shows a list rather than a page: its index was asked for, or
    /// nothing is open once the canvas has settled.
    var showsSpaceList: Bool {
        isShowingIndex
            || (hasSettledSelection && selectedArtifact == nil && !isAwaitingRevealedArtifact && vm.hasLoadedArtifactsOnce)
    }

    /// The place the sidebar lights: the list on screen, or where the open
    /// page is listed — the window's space while the page is in it. New page
    /// and a link made from the sidebar are filed in it when it is a space.
    var spaceSidebarSelection: SpaceDestination? {
        if showsSpaceList { return spaceDestination }
        return selectedArtifact.map { SpaceDestination.listing($0, within: spaceDestination, spaces: vm.pageSpaces) }
    }

    var body: some View {
        canvasContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .studioChromeLineHeader {
                HStack(spacing: 0) {
                    // Over the sidebar, only the window's own controls: the
                    // sidebar's top line is its first row.
                    if showsSpaceSidebar {
                        SpaceSidebarChromeSpace()
                        // The sidebar's divider, on the chrome line.
                        StudioChromeLineDivider()
                    }
                    // The controls run the row's full width here, so there is no
                    // draggable remainder to protect — back the whole thing and
                    // AppKit's titlebar drag stops eating the toolbar's clicks.
                    // The first of the toolbar's tiers that fits the strip is
                    // the one drawn: a row too wide for it was cut at both
                    // edges, Share under the swap control and the person's
                    // initials under the window's leading chrome.
                    ViewThatFits(in: .horizontal) {
                        toolbar(.full)
                        toolbar(.compact)
                        toolbar(.minimal)
                    }
                    .frame(maxWidth: .infinity)
                    .background(WindowDragBlocker())
                }
            }
            .onAppear { answerRequestsBeforeLoad() }
            .task {
                await vm.loadArtifacts()
                if section == .docs {
                    await vm.refreshPublishedDocStatuses()
                }
                // A reveal asked for before this canvas existed — a Docs row
                // dropped at a workspace edge opens Docs beside and names the
                // doc in one motion — is answered here; `onChange` only hears
                // requests made after the canvas appeared.
                answerRevealRequestIfListed()
                openPendingArtifactIfNeeded()
                // The Docs row clicked before this canvas existed: it opened
                // the pane, and the index is what it asked for.
                showIndexIfRequested()
                reconcileSelection()
                hasSettledSelection = true
            }
            .onChange(of: vm.artifactIndexRequest) { _, _ in showIndexIfRequested() }
            .task(id: "\(selectedArtifactID ?? "")|\(vm.activeTeamID ?? "")|\(vm.teams.count)") {
                guard let id = selectedArtifactID else { return }
                sharingTeamsByArtifactID[id] = await vm.teamsHoldingDoc(id)
            }
            .onChange(of: artifacts.map(\.id)) { _, _ in reconcileSelection() }
            // The doc the window showed before a relaunch the app started
            // itself. Heard here as well as in `task`: the window's resume can
            // land before or after this canvas appears.
            .onChange(of: windowState.pendingArtifactID) { _, _ in
                openPendingArtifactIfNeeded()
            }
            .onChange(of: vm.artifactRevealRequest) { _, request in
                // Only the window and the section the request names answer;
                // another window's canvas, and the other section's, leave it
                // for the one that lists the record.
                guard let request, request.windowID == windowState.id, request.section == section,
                      answers(paneOf: request.groupID) else { return }
                // Consumed even when the doc is not in this canvas's list: a
                // Notebook-scoped canvas and the global one both observe this,
                // and leaving the request standing would make the next reveal
                // of the same doc a no-op.
                vm.artifactRevealRequest = nil
                guard artifacts.contains(where: { $0.id == request.artifactID }) else { return }
                searchText = ""
                selectedArtifactID = request.artifactID
                pendingBlockReveal = request.block.map { ArtifactBlockRevealRequest(artifactID: request.artifactID, reveal: $0) }
            }
            // The page this canvas shows, for the chats of every window: what
            // is open is in their context (`ChatOpenPanes.openOnScreen`).
            .onChange(of: "\(selectedArtifactID ?? "")|\(isShowingIndex)|\(paneTabIsShown)", initial: true) { _, _ in
                registerArtifactOnScreen()
            }
            .onDisappear {
                windowState.artifactsOnScreen[screenKey] = nil
            }
            .onChange(of: selectedArtifactID, initial: true) { _, artifactID in
                // The replacement editor publishes its own caret state once it
                // is ready. Until then, never show formatting inherited from the
                // doc that was just closed or deliver one of its queued presses.
                formatting.activeFormats = []
                formatting.request = nil
                // A block waiting to be shown belongs to its own doc.
                if pendingBlockReveal?.artifactID != artifactID { pendingBlockReveal = nil }
                // Mirrored to the window so the last-session record can name
                // the doc; kept there after this canvas unmounts.
                if let artifactID {
                    windowState.openArtifactID = artifactID
                    // Choosing a doc, by any route, is the way out of the index.
                    isShowingIndex = false
                    // What the Space sidebar's Recents lists: this Mac's, and
                    // nothing about the record moves (`SpaceRecents`).
                    if isSpaceCanvas { SpaceRecents.shared.note(.artifact, id: artifactID) }
                }
            }
            .sheet(isPresented: $isLinkingPage) {
                LinkPageSheet(section: section) { urlString in
                    let artifact = try await vm.linkPage(
                        urlString: urlString,
                        in: section,
                        homeNotebookID: notebookID,
                        linkedNotebookIDs: notebookID.map { [$0] } ?? []
                    )
                    if isSpaceCanvas, let spaceID = spaceSidebarSelection?.pageSpaceID {
                        vm.filePages([artifact.id], inPageSpace: spaceID)
                    }
                    searchText = ""
                    selectedArtifactID = artifact.id
                }
            }
            // From the list row: the stored body is what travels, which is the
            // editor's draft too once its autosave has run.
            .sheet(item: $artifactToConvert) { artifact in
                ConvertToGoogleDocSheet(artifact: artifact) {
                    _ = try await vm.convertDocToGoogleDoc(artifact.id)
                }
            }
            .sheet(item: $artifactToNest) { artifact in
                PageParentPickerSheet(page: artifact)
            }
            .alert(
                "Rename \(section.noun.capitalized)",
                isPresented: Binding(
                    get: { artifactToRename != nil },
                    set: { if !$0 { artifactToRename = nil } }
                )
            ) {
                TextField("\(section.noun.capitalized) name", text: $artifactRenameDraft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { commitArtifactRename() }
                    .disabled(artifactRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            // A deletion that cannot be undone asks first: Delete Forever on a
            // page or site in Trash, and an animation's Move to Trash (a page
            // or a site goes to Trash without a question, and comes back from
            // there). A linked page loses only its link: the page it points at
            // is not ours to delete, and the dialog says so.
            .confirmationDialog(
                artifactToDelete.map { artifact in
                    artifact.isArchived && section != .animations
                        ? "Delete ‘\(artifact.title)’ forever?"
                        : artifact.isLinked
                            ? "Remove ‘\(artifact.title)’ from \(section.title)?"
                            : "Delete ‘\(artifact.title)’?"
                } ?? "",
                isPresented: Binding(
                    get: { artifactToDelete != nil },
                    set: { if !$0 { artifactToDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: artifactToDelete
            ) { artifact in
                if artifact.isArchived, section != .animations {
                    Button("Delete Forever", role: .destructive) {
                        Task {
                            await vm.deleteArtifactsForever([artifact.id])
                            SpaceRecents.shared.forget(.artifact, id: artifact.id)
                        }
                    }
                } else {
                    Button(artifact.isLinked ? "Remove from \(section.title)" : "Move to Trash", role: .destructive) {
                        Task { await vm.deleteArtifact(artifact.id) }
                    }
                }
            } message: { artifact in
                if artifact.isArchived, section != .animations {
                    Text(artifact.isLinked
                         ? "This can’t be undone. The \(artifact.linkedKind?.label ?? "page") itself is not touched."
                         : "This can’t be undone.")
                } else if artifact.isLinked {
                    Text("The \(artifact.linkedKind?.label ?? "page") itself is not touched.")
                }
            }
            // Codex's Delete asks, and says the subpages go too
            // (`codex.space.page.archive.description`). Here only a page that
            // has subpages asks: one alone goes at once, with Undo on the toast.
            .confirmationDialog(
                "Move “\(pageToTrash?.title ?? "")” to Trash?",
                isPresented: Binding(
                    get: { pageToTrash != nil },
                    set: { if !$0 { pageToTrash = nil } }
                ),
                titleVisibility: .visible,
                presenting: pageToTrash
            ) { page in
                Button("Move to Trash", role: .destructive) { moveToTrash(page) }
                Button("Cancel", role: .cancel) {}
            } message: { page in
                Text(PageTrashWording.message(subpageCount: vm.pageTree.descendantIDs(of: page.id).count))
            }
            // The inverse of Convert to Google Doc, and the non-destructive
            // way out for any linked doc: the text copy stays as an editable
            // doc.
            .confirmationDialog(
                "Unlink ‘\(artifactToUnlink?.title ?? "")’ from \(artifactToUnlink?.linkedKind?.productName ?? "its page")?",
                isPresented: Binding(
                    get: { artifactToUnlink != nil },
                    set: { if !$0 { artifactToUnlink = nil } }
                ),
                titleVisibility: .visible,
                presenting: artifactToUnlink
            ) { artifact in
                Button("Unlink") {
                    Task { await vm.unlinkDoc(artifact.id) }
                }
            } message: { artifact in
                Text(section == .sites
                     ? "The text copy becomes a page you can edit, in Pages. The \(artifact.linkedKind?.label ?? "page") itself is not touched."
                     : "The text copy stays here as a page you can edit. The \(artifact.linkedKind?.label ?? "page") itself is not touched.")
            }
            .confirmationDialog(
                "Make ‘\(artifactToAdopt?.title ?? "")’ a ForeverLM page?",
                isPresented: Binding(
                    get: { artifactToAdopt != nil },
                    set: { if !$0 { artifactToAdopt = nil } }
                ),
                titleVisibility: .visible,
                presenting: artifactToAdopt
            ) { artifact in
                Button("Make a ForeverLM Page") {
                    Task { await vm.adoptLinkedPage(artifact.id) }
                }
            } message: { artifact in
                Text("The text copy becomes a page of your own, published on foreverlm.com, where you, the chat and your assistants can edit it. The \(artifact.linkedKind?.label ?? "page") itself is not touched.")
            }
    }

    /// The Space (the global Pages and Sites) or, for a notebook's Pages and
    /// for Animations, the list-and-page workspace with its margins.
    @ViewBuilder
    private var canvasContent: some View {
        if isSpaceCanvas {
            spaceContent
        } else {
            workspace
                .padding(.horizontal, linkedDocFillsPane ? 0 : StudioDesign.Metrics.pageMargin)
                .padding(.top, linkedDocFillsPane ? 0 : 14)
                .padding(.bottom, linkedDocFillsPane ? 0 : 12)
        }
    }

    /// The Space sidebar, flush to the pane's leading edge and its full
    /// height, and beside it the page — or, with none open, the place the
    /// window's Space shows.
    private var spaceContent: some View {
        HStack(spacing: 0) {
            if showsSpaceSidebar {
                SpaceSidebar(
                    selection: spaceSidebarSelection,
                    openArtifactID: showsSpaceList ? nil : selectedArtifactID,
                    onSelect: showSpacePlace,
                    onOpenRecent: openSpaceRecent,
                    onNewPage: newSpacePage,
                    onLink: linkFromSpace,
                    onNewSpace: { isCreatingSpace = true },
                    onSearch: searchSpace
                )
                .frame(width: SpaceSidebarMetrics.width)
                .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            Group {
                if artifacts.isEmpty && !vm.hasLoadedArtifactsOnce {
                    // Until the first load lands an empty list is "not read
                    // yet", and saying "No pages" would read as data loss.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if showsSpaceList {
                    SpaceBrowseView(
                        destination: spaceDestination,
                        showsPlaceMenu: !showsSpaceSidebar,
                        searchText: $spaceSearchText,
                        searchFocusRequest: spaceSearchFocusRequest,
                        onSelectPlace: showSpacePlace,
                        onOpen: openFromSpace,
                        onNewPage: newSpacePage,
                        onLink: linkFromSpace,
                        onNewSpace: { isCreatingSpace = true }
                    )
                    .transition(.opacity)
                } else {
                    pageView
                        .padding(.horizontal, linkedDocFillsPane ? 0 : StudioDesign.Metrics.pageMargin)
                        .padding(.top, linkedDocFillsPane ? 0 : 14)
                        .padding(.bottom, linkedDocFillsPane ? 0 : 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.18), value: showsSpaceSidebar)
        .background(alignment: .leading) {
            // The sidebar's tone, in the card under the band: the band above
            // it is the window's chrome, as Codex's is over its sidebar.
            if showsSpaceSidebar {
                SpaceSidebarMetrics.background
                    .frame(width: SpaceSidebarMetrics.width)
            }
        }
        // Show pages, ⇧⌘E, with a page open (the page menu's item shows the
        // key, this runs it; the Space home has no page menu and, with no
        // page open, this is not here, so two panes never hold the key).
        .background {
            if spaceSidebarFitsPane, !showsSpaceList, selectedArtifact != nil {
                Button("Show pages", action: togglePagesSidebar)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            workspaceWidth = width
        }
        .sheet(item: $spaceLinkSection) { linkSection in
            LinkPageSheet(section: linkSection) { urlString in
                let artifact = try await vm.linkPage(
                    urlString: urlString,
                    in: linkSection,
                    homeNotebookID: nil,
                    linkedNotebookIDs: []
                )
                if let spaceID = spaceSidebarSelection?.pageSpaceID {
                    vm.filePages([artifact.id], inPageSpace: spaceID)
                }
                vm.revealArtifact(artifact.id, in: windowState)
            }
        }
        .sheet(isPresented: $isCreatingSpace) {
            SpaceNewSpaceSheet(onCreated: showSpacePlace)
        }
    }

    private var workspace: some View {
        Group {
            if artifacts.isEmpty {
                // Until the first load lands, an empty array means "not read
                // yet", and claiming "No docs" over a populated library reads
                // as data loss. Hold a quiet spinner instead.
                if !vm.hasLoadedArtifactsOnce {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    artifactHome
                }
            } else if isShowingIndex || (isArtifactListVisible && !listFitsBesideDocument) {
                // The home: every doc across the whole pane, none open. The
                // rail's Docs row lands here; a click on a card hands the pane
                // to that doc. The same layout serves a pane narrower than list
                // plus page, where the two columns cannot both fit without the
                // document overflowing.
                artifactHome
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                HSplitView {
                    if isArtifactListVisible {
                        artifactList
                            .frame(minWidth: 200, idealWidth: 280, maxWidth: 340)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    pageView
                }
                .animation(.easeInOut(duration: 0.18), value: isArtifactListVisible)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            workspaceWidth = width
        }
    }

    /// The open record, with the page's side chat floating over it: a compact
    /// card at the bottom right that the page's chat entry points open
    /// (docs/pages-side-chat-design.md). Only a page in the editor asks for it;
    /// the layer is the same over every kind so the pane's size is measured once.
    private var pageView: some View {
        pageContent
            .overlay(alignment: .bottomTrailing) {
                if pageHostsSideChat, let selectedArtifact {
                    PageSideChatLayer(artifact: selectedArtifact, section: section, chrome: docChrome)
                }
            }
            .onChange(of: pageHostsSideChat, initial: true) { _, hosts in
                docChrome.hostsSideChat = hosts
            }
    }

    /// Whether this window can draw the card: it has a Studio root's store for
    /// it, and the open record is a page the editor holds.
    var pageHostsSideChat: Bool {
        guard sideChatHosting != nil, section == .docs, let selectedArtifact else { return false }
        return !selectedArtifact.isLinked && !selectedArtifact.isMnemonicReading
    }

    /// The open record as its kind is read: a Google Doc or a linked site in
    /// its own page, a mnemonic reading as its questions, a page in the
    /// editor.
    @ViewBuilder
    private var pageContent: some View {
        if let selectedArtifact, selectedArtifact.isLinked {
            // A Google Doc has no Markdown body to edit: Google's
            // own editor takes the page, with the doc's text export
            // kept behind it for chat and review.
            LinkedDocView(artifact: selectedArtifact, bridge: linkedDoc)
                .id(selectedArtifact.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selectedArtifact, selectedArtifact.isMnemonicReading {
            // A mnemonic reading is read, not edited: its sources'
            // text with its questions in it (docs/memory-design.md,
            // "Mnemonic reading").
            MnemonicReadingView(artifact: selectedArtifact)
                .id(selectedArtifact.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selectedArtifact {
            ArtifactEditor(
                artifact: selectedArtifact,
                publishedStatus: publishedStatusBinding(for: selectedArtifact.id),
                formatting: formatting,
                chrome: docChrome,
                // A source clicked in a doc opens beside the doc,
                // not instead of it: the writer is citing what they
                // are reading, so both have to stay on screen.
                onOpenSource: { sourceID in
                    Task { await vm.openLinkedSourceInReader(sourceID, beside: section.centerTab) }
                },
                blockReveal: pendingBlockReveal?.artifactID == selectedArtifact.id ? pendingBlockReveal : nil
            )
                .id(selectedArtifact.id)
                // No floor of its own. A pane can be narrower than a
                // comfortable page, and a doc that keeps a wider
                // fitting size is drawn centred and clipped on both
                // sides — the page has to reflow to the pane instead.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasSettledSelection || isAwaitingRevealedArtifact {
            // A doc was clicked and is still on its way here.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select \(section == .animations ? "an" : "a") \(section.noun)", systemImage: section == .docs ? "note.text" : "globe")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The home's filters. Docs has three and Archived: every doc, the docs with
/// a page on foreverlm.com, and the drafts — a doc marked Draft, or a team
/// Doc the member holds a draft of. ("Yours" and "Shared with you", the
/// Artifacts page's pair, need an author on the Doc record; a team copy
/// carries none.) Sites has three of its own and Archived: every site, the
/// sites published from ForeverLM, the Claude artifacts and the Codex sites
/// — by where the site lives. A published doc is a Doc, so Published is a
/// Docs filter on every Docs home, global or a Notebook's. Hidden, last on
/// both, lists what the learner hid.
enum ArtifactHomeFilter: String, CaseIterable, Identifiable {
    case all, published, drafts, foreverlmPages, claudeArtifacts, codexSites, archived, hidden

    var id: String { rawValue }

    /// Archived and Hidden close every row: the other filters never list an
    /// archived or a hidden record, so each is the one place to find one again.
    static func cases(for section: ArtifactSection, notebookScoped: Bool) -> [ArtifactHomeFilter] {
        switch section {
        case .docs: return [.all, .published, .drafts, .archived, .hidden]
        case .sites: return [.all, .foreverlmPages, .claudeArtifacts, .codexSites, .archived, .hidden]
        // Every animation is ForeverLM's own, so there is nothing to split
        // by where it lives.
        case .animations: return [.all, .archived, .hidden]
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .published: return "Published"
        case .drafts: return "Drafts"
        case .foreverlmPages: return "ForeverLM"
        case .claudeArtifacts: return "Claude"
        case .codexSites: return "Codex"
        case .archived: return "Archived"
        case .hidden: return "Hidden"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all: return "Nothing here yet"
        case .published: return "Nothing published yet"
        case .drafts: return "No drafts"
        case .foreverlmPages: return "No sites published yet"
        case .claudeArtifacts: return "No Claude artifacts linked"
        case .codexSites: return "No Codex sites linked"
        case .archived: return "Nothing archived"
        case .hidden: return "Nothing hidden"
        }
    }

    var emptySymbol: String {
        switch self {
        case .all: return "doc.text"
        case .published, .foreverlmPages: return "globe"
        case .drafts: return "pencil.line"
        case .claudeArtifacts: return LinkedPageKind.claudeArtifact.symbolName
        case .codexSites: return LinkedPageKind.codexSite.symbolName
        case .archived: return "archivebox"
        case .hidden: return "eye.slash"
        }
    }
}

/// The page's text as the editor last reported it, kept out of its host's
/// observed state. The editor reports the text at each pause in typing. Held
/// in `@State`, every report ran the host's whole body again (some 2,900 lines
/// of view code) and hashed the page for the page view's task, between words
/// (docs/codex-parity-audit.md, F3: "Typing never touches the rest of the
/// window"). Here a report replaces what is held and starts the autosave's
/// pause over, and nothing is drawn again.
@MainActor
final class ArtifactEditorDraft {
    /// The page's text: the writer's typing as last reported, or what the
    /// host put in its place.
    private(set) var text = ""
    private var autosave: Task<Void, Never>?

    /// Takes `newText`; false when the draft already holds it. A change starts
    /// the autosave's pause over: `save` runs once the text has stood still
    /// for `pause`, and decides then whether there is anything to write.
    @discardableResult
    func replaceText(with newText: String, autosaveAfter pause: Duration, save: @escaping @MainActor () -> Void) -> Bool {
        guard newText != text else { return false }
        text = newText
        autosave?.cancel()
        autosave = Task { @MainActor in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            save()
        }
        return true
    }

    /// The page is closing, and saves what it holds itself: a pause still
    /// running ends without a save.
    func cancelAutosave() {
        autosave?.cancel()
        autosave = nil
    }
}

/// The Notebooks a doc is filed under, as a checklist the doc's own menus carry:
/// the ⋯ menu above an open doc and the right-click menu on its row in the Docs
/// list. Ticking one links the doc to that Notebook the way a doc created inside
/// the Notebook is linked; unticking takes it out. A doc under no Notebook reads
/// Unfiled in the list. Until this menu existed the only way to change a doc's
/// Notebooks after creation was the `update_doc` tool.
struct ArtifactNotebooksMenu: View {
    @Environment(StudioViewModel.self) private var vm
    let artifact: ArtifactRecord

    var body: some View {
        Menu {
            if vm.notebooks.isEmpty {
                Text("No Notebooks")
            }
            ForEach(vm.notebooks) { notebook in
                Toggle(isOn: Binding(
                    get: { artifact.linkedNotebookIDs.contains(notebook.id) },
                    set: { isMember in
                        Task {
                            await vm.setArtifactNotebookMembership(
                                artifact.id,
                                notebookID: notebook.id,
                                isMember: isMember
                            )
                        }
                    }
                )) {
                    Text(notebook.title)
                }
            }
        } label: {
            Label("Notebooks", systemImage: NotebookGlyph.systemImage)
        }
    }
}
