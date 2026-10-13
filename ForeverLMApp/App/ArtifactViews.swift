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
    var showsPage = false
    /// Once the writer explicitly presses Edit/Page, their choice wins for this
    /// open Doc. Until then a published Doc opens as its rendered page.
    var pagePresentationWasChosen = false
    var isCommentsVisible = false
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
    /// The page menu's **Version History…**: the editor presents the page's
    /// versions on this Mac (`PageVersionHistorySheet`).
    var isVersionHistoryPresented = false
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
        pagePresentationWasChosen = true
        showsPage.toggle()
    }

    /// A doc's editor appearing takes the header over. A published doc opens as
    /// its page; nothing of the previous doc's carries across.
    func reset(opensAsPage: Bool) {
        showsPage = opensAsPage
        pagePresentationWasChosen = false
        isCommentsVisible = false
        isPublishSheetPresented = false
        showUnpublishConfirmation = false
        isConvertingToGoogleDoc = false
        openCommentCount = 0
        errorMessage = nil
        reloadGeneration = 0
        publishDraftRequest = nil
        showDraftPublishConflict = false
        showDiscardDraftConfirmation = false
        isVersionHistoryPresented = false
        exportRequest = nil
        flushDraft = nil
        sideChatRequest = nil
        wholePageChatRequest = nil
    }
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
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pageSideChatHosting) private var sideChatHosting
    let section: ArtifactSection
    let notebookID: String?
    let onBack: (() -> Void)?

    @State private var selectedArtifactID: String?
    /// The canvas is showing its index: every doc listed across the pane and
    /// none open. Entered from the rail's Docs row, left by choosing a doc.
    /// While it is on, `reconcileSelection` leaves the selection empty rather
    /// than reopening the remembered doc.
    @State private var isShowingIndex = false
    /// The canvas has read the library and chosen what to open at least once.
    /// Until then an empty selection is a doc on its way, not a choice left to
    /// the learner, so the pane spins rather than saying "Select a doc".
    @State private var hasSettledSelection = false
    /// Which docs the home shows: every doc, the published ones, or the drafts.
    @State private var homeFilter: ArtifactHomeFilter = .all
    @State private var searchText = ""
    @State private var formatting = ArtifactFormattingBridge()
    @State private var linkedDoc = LinkedDocBridge()
    @State private var artifactToUnlink: ArtifactRecord?
    /// A linked page about to become ForeverLM's own published page.
    @State private var artifactToAdopt: ArtifactRecord?
    @State private var workspaceWidth: CGFloat = 0
    @State private var isLinkingPage = false
    @State private var artifactToConvert: ArtifactRecord?
    @State private var artifactToRename: ArtifactRecord?
    /// The page the page menu's Move to Page… is asking a parent for.
    @State private var artifactToNest: ArtifactRecord?
    @State private var artifactRenameDraft = ""
    @State private var artifactToDelete: ArtifactRecord?
    /// The open doc's chrome controls — Page/Edit, the published address, the
    /// overflow — drawn in the toolbar and acted on by the editor beneath.
    @State private var docChrome = ArtifactDocChromeBridge()
    /// The teams holding a copy of the selected Doc in My Library, for the
    /// header's "Shared with" control; empty while a team is open.
    @State private var sharingTeamsByArtifactID: [String: [TeamRecord]] = [:]
    /// The header's Share popover: who can open the selected Doc.
    @State private var isSharePopoverPresented = false
    /// A block to show in the doc a reveal request brought forward — a block
    /// reference or a linked reference followed — held until that doc's
    /// editor takes it (docs/notes-graph-design.md).
    @State private var pendingBlockReveal: ArtifactBlockRevealRequest?
    @SyncedStorage private var isArtifactListVisible: Bool
    @SyncedStorage(ArtifactPageWidth.key) private var pageWidth = ArtifactPageWidth.standard
    @SyncedStorage(ArtifactMarginCards.key) private var showsMarginCards = true
    /// The learner's name, for the initials on the page's top line.
    @SyncedStorage(wrappedValue: "", MacAccountUser.displayNamePreferenceKey) private var savedDisplayName: String
    @Environment(\.uiZoomScale) private var uiZoomScale
    /// How far the chrome line's row starts past the pane's leading edge, so
    /// the Space sidebar's top line ends where the sidebar does.
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset
    /// The learner's choice to keep the Space sidebar out of the way; this
    /// Mac's, shared with the Space home.
    @AppStorage("space.sidebarHidden") private var spaceSidebarHiddenByLearner = false
    /// The Space's own search, apart from the side list's.
    @State private var spaceSearchText = ""
    @State private var spaceSearchFocusRequest = 0
    /// A link the Space sidebar asked for into the other section — a site from
    /// beside a page, a Google Doc from beside a site.
    @State private var spaceLinkSection: ArtifactSection?
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
    private var listFitsBesideDocument: Bool {
        workspaceWidth <= 0 || workspaceWidth >= 520
    }

    /// Publication is server-owned rather than Artifact metadata. The view
    /// model holds one bounded projection for every canvas, so the list has
    /// its Published state and the selected Doc its live address without one
    /// request per row.
    private var publishedStatuses: [String: PublishedDocStatus] { vm.publishedDocStatuses }

    /// The section's records, by each record's link: a Notebook's canvas is
    /// its Docs, everything filed there that is not a site by its link, and
    /// the global canvases split the library the same way. A published
    /// Markdown doc is a Doc (product owner, 2026-09-10: "sites should only hold
    /// actual sites, published docs stay in docs").
    private var artifacts: [ArtifactRecord] {
        // An audio overview is played and opened from its notebook's Studio,
        // never edited as a Doc; its body is only its recipe.
        if let notebookID {
            return vm.linkedArtifacts(notebookID: notebookID).filter { $0.section == section && !vm.isAudioOverview($0) }
        }
        return vm.artifacts.filter { vm.section(of: $0) == section && !vm.isAudioOverview($0) }
    }

    private var selectedArtifact: ArtifactRecord? {
        guard let selectedArtifactID else { return nil }
        return artifacts.first { $0.id == selectedArtifactID }
    }

    private var visibleArtifacts: [ArtifactRecord] {
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
    private func listsHere(_ artifact: ArtifactRecord) -> Bool {
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
    private var linkedDocFillsPane: Bool {
        selectedArtifact?.isLinked == true && (isSpaceCanvas || !isArtifactListVisible)
    }

    /// The global Pages and Sites panes are the Space with a page open: the
    /// Space sidebar beside the page, as ChatGPT draws a page in its Space
    /// (docs/docs-design.md, "The Space"). A notebook's own Pages keep their
    /// list, which the notebook's columns frame; Animations keep theirs.
    private var isSpaceCanvas: Bool {
        notebookID == nil && section != .animations
    }

    /// The sidebar shows unless the learner hid it or the pane is too narrow
    /// for it beside a readable page.
    private var showsSpaceSidebar: Bool {
        isSpaceCanvas && !spaceSidebarHiddenByLearner
            && (workspaceWidth <= 0 || workspaceWidth >= SpaceSidebarMetrics.minimumPaneWidth)
    }

    /// The place this window's Space shows when no page is open.
    private var spaceDestination: SpaceDestination {
        SpaceDestination(key: windowState.spaceDestinationKey)
    }

    /// The Space shows a list rather than a page: its index was asked for, or
    /// nothing is open once the canvas has settled.
    private var showsSpaceList: Bool {
        isShowingIndex
            || (hasSettledSelection && selectedArtifact == nil && !isAwaitingRevealedArtifact && vm.hasLoadedArtifactsOnce)
    }

    /// The place the sidebar lights: the list on screen, or where the open
    /// page is listed — the window's space while the page is in it. New page
    /// and a link made from the sidebar are filed in it when it is a space.
    private var spaceSidebarSelection: SpaceDestination? {
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
                    toolbar.background(WindowDragBlocker())
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
                guard let request, request.windowID == windowState.id, request.section == section else { return }
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
    private var pageHostsSideChat: Bool {
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

    // MARK: - The Space

    /// A place chosen in the sidebar: the list shows beside it, here, in the
    /// pane the page was in.
    private func showSpacePlace(_ place: SpaceDestination) {
        if windowState.spaceDestinationKey != place.key { windowState.spaceDestinationKey = place.key }
        spaceSearchText = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedArtifactID = nil
            isShowingIndex = true
        }
    }

    /// The sidebar's search: every place at once, with the field focused.
    private func searchSpace() {
        let place = spaceDestination
        if !showsSpaceList || place == .images || place == .trash {
            showSpacePlace(place == .images || place == .trash ? .all : place)
        }
        spaceSearchFocusRequest += 1
    }

    /// A record chosen in the Space: here when this pane lists it, else in
    /// its own section's pane; a team's record listed in My Library in its
    /// team's library.
    private func openFromSpace(_ artifact: ArtifactRecord) {
        if vm.activeTeamID == nil, artifact.teamID != nil {
            Task { await vm.openTeamArtifact(artifact.id, in: windowState) }
        } else if artifacts.contains(where: { $0.id == artifact.id }) {
            spaceSearchText = ""
            selectedArtifactID = artifact.id
            isShowingIndex = false
        } else {
            vm.revealArtifact(artifact.id, in: windowState)
        }
    }

    private func openSpaceRecent(_ item: SpaceRecents.Item) {
        switch item.kind {
        case .artifact:
            guard let artifact = vm.artifacts.first(where: { $0.id == item.id }) else { return }
            openFromSpace(artifact)
        case .canvas:
            vm.openCanvas(item.id, in: windowState)
        case .list:
            showSpacePlace(.list(item.id))
        case .image:
            showSpacePlace(.images)
        }
    }

    /// New page from the sidebar: here in Pages; from beside a site, in Pages;
    /// in the space the sidebar has lit, when it has one.
    private func newSpacePage() {
        let spaceID = spaceSidebarSelection?.pageSpaceID
        guard section != .docs else {
            beginCreation(inPageSpace: spaceID)
            return
        }
        Task {
            do {
                let snapshot = try await vm.createArtifact(
                    title: ArtifactPlaceholderTitle.current,
                    homeNotebookID: nil,
                    linkedNotebookIDs: [],
                    pageSpaceID: spaceID
                )
                vm.revealArtifact(snapshot.artifact.id, in: windowState)
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    private func linkFromSpace(_ linkSection: ArtifactSection) {
        if linkSection == section {
            isLinkingPage = true
        } else {
            spaceLinkSection = linkSection
        }
    }

    /// The list column is on screen beside the page — not hidden, not
    /// replaced by the home.
    private var isSideListShowing: Bool {
        isArtifactListVisible && listFitsBesideDocument && !isShowingIndex
    }

    /// The page's top line, as ChatGPT draws a page in its Space (product owner,
    /// 2026-10-06: "there are often way too many buttons at the top in
    /// foreverlm. please learn from chatgpt"; docs/ui-design.md, "Quiet
    /// chrome"). The page's menu leads — everything the page can do, its
    /// formatting, its view and its publishing among it — and the trailing
    /// side holds only what is happening now (Reload after a failure, Update
    /// Page while a published page has edits, Edit while the page shows, the
    /// comments while there are some) and Share. Formatting is the page's
    /// selection bar; New page and the links are the Space sidebar's. Until
    /// that day this line carried the section's name, the published address,
    /// the teams, Format, AI, Page/Edit, Share, ⋯, New and Link at once.
    /// The product owner (2026-10-07) then sent Codex's own line and asked for a clone:
    /// after the menu a pill of four tools (`pageToolPill`), and before Share
    /// the version history, the comments and the person's initials.
    private var toolbar: some View {
        let showsPage = !(isSpaceCanvas && showsSpaceList)
        return HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                }
                .buttonStyle(.hoverWash)
                .help("Back")
            }
            listToggle
            if let selectedArtifact, showsPage {
                if selectedArtifact.isLinked {
                    linkedDocMenu(for: selectedArtifact)
                    if linkedDocFillsPane {
                        linkedPageTitle(for: selectedArtifact)
                    }
                } else if selectedArtifact.isMnemonicReading {
                    readingMenu(for: selectedArtifact)
                } else {
                    pageMenu(for: selectedArtifact)
                    if vm.teamArtifactID(forDraft: selectedArtifact.id) != nil {
                        draftControls
                    }
                    if showsPageTools(for: selectedArtifact) {
                        pageToolPill
                    }
                }
            } else if !isSpaceCanvas {
                // A notebook's Pages, and Animations, name themselves while no
                // page is open; the Space's list says where it is itself.
                Text(section.title)
                    .zoomedSystemFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                if let notebookID, let notebook = vm.notebook(id: notebookID) {
                    Text(notebook.title)
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let selectedArtifact, showsPage, !selectedArtifact.isLinked, !selectedArtifact.isMnemonicReading {
                docControls(for: selectedArtifact)
            }
            // An animation is made in a chat from a source; this is where.
            if section == .animations {
                linkPageButton
            }
        }
        // Clearance for the traffic lights and for the chrome overlaying the
        // pane's top-right corner comes from studioChromeLineHeader; this row
        // only owns its own margins. Beside the Space sidebar the page's
        // menu sits close to the sidebar's edge, as ChatGPT's does.
        .padding(.leading, showsSpaceSidebar ? 12 : StudioDesign.Metrics.pageMargin)
        .padding(.trailing, StudioDesign.Metrics.pageMargin)
    }

    /// The way to a notebook's Pages list beside the page while it is out of
    /// sight. A Space page has none: the Space sidebar comes back with the
    /// window's sidebar toggle, by the traffic lights.
    @ViewBuilder
    private var listToggle: some View {
        if !isSpaceCanvas, !artifacts.isEmpty, !isSideListShowing {
            // While the list is on screen its own header carries the control
            // that hides it (see artifactList). The glyph is what the button
            // reveals, a list of pages, not `sidebar.leading`, which the
            // rail's own toggle uses on this line.
            StudioChromeIconButton(
                systemImage: "list.bullet",
                label: isArtifactListVisible ? "Hide \(section.pluralNoun) list" : "Show \(section.pluralNoun) list"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isArtifactListVisible.toggle()
                }
            }
        }
    }

    /// The page menu's label: the record's mark and a chevron, ChatGPT's
    /// page ▾.
    private func pageMenuLabel<Mark: View>(@ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 4) {
            mark()
            Image(systemName: "chevron.down")
                .zoomedSystemFont(size: 8.5, weight: .bold)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .frame(height: StudioDesign.Metrics.chromeButtonHeight)
        .contentShape(Rectangle())
    }

    private func linkedPageProfile(for artifact: ArtifactRecord) -> BrowserProfile {
        LinkedPageProfiles.shared.profile(for: artifact.id, in: BrowserProfileStore.shared)
    }

    /// The open linked page's name, in the header, while the page fills the
    /// pane. With the list hidden nothing of ours names a site or a linked
    /// doc, and nothing of ours can be picked up: a Markdown doc keeps its
    /// title above the page, but a linked page is all the page's own, and the
    /// only way to a chat was the overflow menu's Add to Chat (product owner,
    /// 2026-09-14: "even when the sites sidebar is hidden, i can still drag
    /// something into a chat on the side. perhaps there should be a title of
    /// the site that i can drag"). The name is that handle. It is the doc
    /// title's shape — a button a click renames and a press-and-move drags,
    /// on the list row's provider, so a chat beside the pane takes the page
    /// whether or not its row is showing — and it carries the row's context
    /// menu, so none of the row's actions leave with the list. Not drawn
    /// beside the list: the row is the handle then, and one name per pane.
    private func linkedPageTitle(for artifact: ArtifactRecord) -> some View {
        Button {
            artifactRenameDraft = artifact.title
            artifactToRename = artifact
        } label: {
            HStack(spacing: 6) {
                artifactKindIcon(for: artifact, height: 11)
                Text(artifact.title)
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        // The first to give way when the header is short of room: the
        // section's name and the trailing controls keep their width, and this
        // truncates.
        .layoutPriority(-1)
        .help("Click to rename. Drag into a chat to add this \(section.noun) to it.")
        .accessibilityLabel(artifact.title)
        .accessibilityHint("Click to rename. Drag into a chat to add this \(section.noun) to it.")
        .contextMenu {
            docActions(for: artifact)
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: section.centerTab, artifactID: artifact.id)
            return studioArtifactDragProvider(for: artifact)
        }
    }

    /// The linked doc's actions, in the pane header where the Markdown editor
    /// keeps its formatting menu. Reload and Refresh Text Copy reach the page
    /// through `LinkedDocBridge`; the rest act on the record or its URL.
    private func linkedDocMenu(for artifact: ArtifactRecord) -> some View {
        let url = artifact.linkedURL.flatMap(URL.init(string:))
        return Menu {
            Button {
                Task { await vm.attachDocToChat(artifact.id) }
            } label: {
                Label("Add to Chat", systemImage: "message")
            }
            OpenStudioDestinationInOtherWindowMenu(
                destination: .doc(artifact.id),
                currentWindowState: windowState,
                openNewWindow: { openWindow(id: "studio") }
            )
            KnowledgeMapAddToCanvasMenu(refs: ["doc:\(artifact.id)"])
            Button {
                linkedDoc.exportRefreshGeneration += 1
            } label: {
                Label("Refresh Text Copy", systemImage: "arrow.clockwise")
            }
            .help("Pull the page’s text again so chat and review read the latest version")
            Divider()
            // A site kept in the library has no web address to open or copy.
            if LinkedPage.localSiteID(fromURLString: artifact.linkedURL) == nil {
                Button {
                    if let url { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open in Browser", systemImage: "arrow.up.forward.app")
                }
                .disabled(url == nil)
                Button {
                    if let url { vm.openInBrowser(url, profileID: linkedPageProfile(for: artifact).id) }
                } label: {
                    Label("Open in ForeverLM Browser", systemImage: "safari")
                }
                .help("The same page in ForeverLM's Browser, in its sign-in profile — sign in there and this page picks it up")
                .disabled(url == nil)
                // The jar the page signs in with. Library is shared with the
                // Browser pane's Library tabs and the readers; any other profile
                // is a separate set of logins, so a site shared with one ChatGPT
                // workspace can use one account while the Browser keeps another.
                Menu {
                    let current = linkedPageProfile(for: artifact)
                    ForEach(BrowserProfileStore.shared.profiles) { profile in
                        Toggle(isOn: Binding(
                            get: { current.id == profile.id },
                            set: { _ in LinkedPageProfiles.shared.assign(profile.id, to: artifact.id) }
                        )) {
                            Text(profile.name)
                        }
                    }
                    Divider()
                    Button("New Profile…") {
                        let profile = BrowserProfileStore.shared.add(name: "\(artifact.linkedKind?.productName ?? "Page") account")
                        LinkedPageProfiles.shared.assign(profile.id, to: artifact.id)
                        if let url { vm.openInBrowser(url, profileID: profile.id) }
                    }
                    .help("A fresh set of logins, assigned to this page and opened in the Browser pane to sign in; rename it under the Browser's profile menu")
                } label: {
                    Label("Sign-in Profile: \(linkedPageProfile(for: artifact).name)", systemImage: "person.crop.circle")
                }
                Button {
                    guard let url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    vm.showToast("Link copied")
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
                .disabled(url == nil)
            }
            Button {
                linkedDoc.reloadGeneration += 1
            } label: {
                Label("Reload", systemImage: "arrow.counterclockwise")
            }
            Divider()
            // The page as ForeverLM's own: the text copy becomes a doc and is
            // published on foreverlm.com, where the chat, Claude and Codex can
            // edit it. The product owner (2026-09-08), told a Codex site can only be
            // changed in Codex: "so can you make it a foreverlm site".
            Button {
                artifactToAdopt = artifact
            } label: {
                Label("Make a ForeverLM Page…", systemImage: "globe")
            }
            .help("Publish the text copy as a page on foreverlm.com that you, the chat and your assistants can edit; the \(artifact.linkedKind?.label ?? "page") itself is not touched")
            Button {
                artifactToUnlink = artifact
            } label: {
                Label("Unlink from \(artifact.linkedKind?.productName ?? "the page")…", systemImage: "doc.text")
            }
            .help(section == .sites
                  ? "Keep the text copy as a page you can edit, in Pages"
                  : "Keep the text copy here as a page you can edit")
            Button(role: .destructive) {
                trash(artifact)
            } label: {
                Label(section == .animations ? "Remove from \(section.title)" : "Move to Trash", systemImage: "trash")
            }
        } label: {
            pageMenuLabel {
                artifactKindIcon(for: artifact, height: 13)
            }
        }
        // The page's menu, ChatGPT's page ▾, on the leading side.
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverWash)
        .help("\(artifact.linkedKind?.label ?? "Linked page") actions")
        .accessibilityLabel("\(artifact.linkedKind?.label ?? "Linked page") actions")
    }

    /// Animations' way in on the top line, the one section that still keeps
    /// it there: a page or a site is added from the Space sidebar.
    private var linkPageButton: some View {
        StudioChromeIconButton(systemImage: "link.badge.plus", label: section.linkActionTitle) {
            isLinkingPage = true
        }
    }

    /// The ways an entry gets into the list, shared by the empty state and the
    /// list's context menu so they never drift apart from the header buttons.
    /// Docs has two, a new doc and a linked Google Doc; Sites has the link.
    @ViewBuilder
    private var addDocMenuItems: some View {
        if section == .docs {
            Button {
                beginCreation()
            } label: {
                Label("New Page", systemImage: "doc.badge.plus")
            }
        }
        Button {
            isLinkingPage = true
        } label: {
            Label(section.linkActionTitle, systemImage: "link.badge.plus")
        }
    }

    /// The page's trailing controls (docs/ui-design.md, "Quiet chrome"): only
    /// what is happening now, then Share. Reload while the editor has failed;
    /// Update Page while a published page is being edited (the Confluence
    /// loop of Edit, change, Update: the page is republished on purpose);
    /// Edit while the page shows, named rather than left to a pencil glyph,
    /// or on a team Doc the member's draft; then Codex's four: the version
    /// history, the comments (with the open count), the person and Share, the
    /// one primary action. Everything else is the page's menu.
    @ViewBuilder
    private func docControls(for artifact: ArtifactRecord) -> some View {
        if let errorMessage = docChrome.errorMessage {
            Button("Reload") { docChrome.reloadGeneration += 1 }
                .buttonStyle(.hoverWash)
                .foregroundStyle(.red)
                .help(errorMessage)
        }
        if docChrome.showsPage {
            if artifact.teamID != nil, !vm.isActiveLibraryReadOnly {
                editTeamDocButton(for: artifact)
            } else {
                Button {
                    docChrome.togglePage()
                } label: {
                    chromeChipLabel("Edit", systemImage: "pencil", prominent: true)
                }
                .buttonStyle(.hoverWash)
                .help(artifact.teamID != nil
                      ? "Read the page's Markdown source"
                      : "Edit the page; its published version is updated when you choose Update Page")
                .accessibilityLabel("Edit")
            }
        } else if artifact.teamID != nil {
            // A team Doc reads as a page; changes go through a draft.
            if !vm.isActiveLibraryReadOnly { editTeamDocButton(for: artifact) }
        } else if publishedStatuses[artifact.id] != nil {
            updatePageButton
        }
        // Codex's top line, right to left: Share, the person, the comments and
        // the version history (product owner, 2026-10-07: "essentially an end to end
        // clone"; this overrules "Quiet chrome" for these four).
        Button {
            docChrome.isVersionHistoryPresented = true
        } label: {
            chromeIconLabel("clock.arrow.circlepath")
        }
        .buttonStyle(.hoverWash)
        .help("Version history")
        .accessibilityLabel("Version history")
        .accessibilityIdentifier("page.versionHistory")
        Button {
            docChrome.isCommentsVisible.toggle()
        } label: {
            if docChrome.openCommentCount > 0 {
                chromeChipLabel("\(docChrome.openCommentCount)", systemImage: "text.bubble", prominent: docChrome.isCommentsVisible)
            } else {
                chromeIconLabel("text.bubble", prominent: docChrome.isCommentsVisible)
            }
        }
        .buttonStyle(.hoverWash)
        .help(docChrome.isCommentsVisible ? "Hide comments" : "Show comments")
        .accessibilityLabel("Comments")
        .accessibilityValue("\(docChrome.openCommentCount) open")
        .accessibilityIdentifier("page.comments")
        accountAvatar
        shareButton(for: artifact)
    }

    /// The signed-in person, as the initials in a small circle (the roster's
    /// `TeamMemberAvatar`). Nothing is drawn while the account has no name.
    @ViewBuilder
    private var accountAvatar: some View {
        let name = MacAccountUser.displayedFullName(saved: savedDisplayName)
        if let initials = MacAccountUser.monogram(of: name) {
            TeamMemberAvatar(initials: initials, size: 22)
                .help(name ?? initials)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name ?? initials)
                .accessibilityIdentifier("page.avatar")
        }
    }

    /// Below this width of the page's own column, in points at the default
    /// size, the top line has no room for the tool pill and the page menu
    /// carries its three tools as an Insert submenu instead.
    private static let pageToolPillMinimumWidth: CGFloat = 560

    /// The page's column as the top line has it: the pane less the Space
    /// sidebar. Unknown before the pane is measured, which counts as wide.
    private var pageColumnWidth: CGFloat {
        guard workspaceWidth > 0 else { return .infinity }
        return workspaceWidth - (showsSpaceSidebar ? SpaceSidebarMetrics.width : 0)
    }

    /// Whether the page's tool pill is on the top line: only while the page
    /// can be written in (its own, with the editor showing, not a team's
    /// read-only copy and not the rendered page) and the line is wide enough.
    private func showsPageTools(for artifact: ArtifactRecord) -> Bool {
        artifact.teamID == nil
            && !docChrome.showsPage
            && docChrome.errorMessage == nil
            && pageColumnWidth >= Self.pageToolPillMinimumWidth * uiZoomScale
    }

    /// Codex's pill of four tools after the page menu: Edit with AI, Image,
    /// Visualize and Insert +. The last three run rows of the editor's `/`
    /// list at the caret (`ArtifactEditorTool`); Edit with AI is the page
    /// menu's item.
    private var pageToolPill: some View {
        HStack(spacing: 0) {
            pageToolButton("sparkles", "Edit with AI", id: "ai") {
                docChrome.aiEditOpenRequestID += 1
            }
            pageToolButton("photo", "Image", id: "image") { formatting.run(.image) }
            pageToolButton("square.on.circle", "Visualize", id: "visualize") { formatting.run(.visualize) }
            pageToolButton("plus", "Insert", id: "insert") { formatting.run(.insert) }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page tools")
        .accessibilityIdentifier("page.tools")
    }

    private func pageToolButton(
        _ systemImage: String,
        _ title: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: StudioDesign.Metrics.chromeButtonHeight - 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.10))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("page.tools.\(id)")
    }

    /// Shows or hides the Space sidebar beside the open page (⇧⌘E, Codex's
    /// Show pages). The learner's choice is this Mac's `space.sidebarHidden`,
    /// which the Space home reads as well.
    private func togglePagesSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) { spaceSidebarHiddenByLearner.toggle() }
    }

    /// Whether the pane is wide enough to hold the sidebar at all; narrower,
    /// it steps aside by itself and Show pages would change nothing.
    private var spaceSidebarFitsPane: Bool {
        isSpaceCanvas && (workspaceWidth <= 0 || workspaceWidth >= SpaceSidebarMetrics.minimumPaneWidth)
    }

    /// A mnemonic reading's actions, where a Doc keeps its controls: no
    /// formatting, page or publishing of ours — its body is its questions —
    /// only where it is filed, its name, and the Trash.
    private func readingMenu(for artifact: ArtifactRecord) -> some View {
        Menu {
            Button {
                Task { await vm.attachDocToChat(artifact.id) }
            } label: {
                Label("Add to Chat", systemImage: "message")
            }
            OpenStudioDestinationInOtherWindowMenu(
                destination: .doc(artifact.id),
                currentWindowState: windowState,
                openNewWindow: { openWindow(id: "studio") }
            )
            ArtifactNotebooksMenu(artifact: artifact)
            KnowledgeMapAddToCanvasMenu(refs: ["doc:\(artifact.id)"])
            KnowledgeMapOnCanvasesSection(ref: "doc:\(artifact.id)", windowState: windowState)
            ShareWithTeamMenu { teamID in
                Task {
                    await vm.shareArtifact(artifact.id, withTeam: teamID)
                    sharingTeamsByArtifactID[artifact.id] = await vm.teamsHoldingDoc(artifact.id)
                }
            }
            Divider()
            Button {
                artifactRenameDraft = artifact.title
                artifactToRename = artifact
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                trash(artifact)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        } label: {
            pageMenuLabel {
                Image(systemName: "text.book.closed")
                    .zoomedSystemFont(size: 12.5, weight: .medium)
                    .foregroundStyle(.primary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverWash)
        .help("Reading")
        .accessibilityLabel("Reading menu")
    }

    /// Who can open the Doc, in one sentence — the same one the Share
    /// popover's footer, the More menu and `list_docs` say (`DocSharing`).
    private func accessSummary(for artifact: ArtifactRecord) -> String {
        DocSharing.summary(
            status: publishedStatuses[artifact.id],
            teamNames: (vm.activeTeamID == nil ? sharingTeamsByArtifactID[artifact.id] ?? [] : []).map(\.name)
        )
    }

    /// **Share**: the one entry point to who can open the Doc — the page's
    /// link, the teams, the readers — in a popover under the button.
    /// Spec: docs/docs-design.md → Publishing → The Share popover.
    private func shareButton(for artifact: ArtifactRecord) -> some View {
        Button {
            isSharePopoverPresented = true
        } label: {
            chromeChipLabel("Share", systemImage: "person.badge.plus")
        }
        .buttonStyle(.hoverWash)
        .help(accessSummary(for: artifact))
        .accessibilityLabel("Share")
        .accessibilityIdentifier("page.share")
        .popover(isPresented: $isSharePopoverPresented, arrowEdge: .bottom) {
            DocSharePopover(
                artifact: artifact,
                teamsHoldingCopy: vm.activeTeamID == nil ? sharingTeamsByArtifactID[artifact.id] ?? [] : [],
                publish: { access in
                    try await docChrome.flushDraft?()
                    return try await vm.publishDoc(artifact.id, access: access)
                },
                teamShared: {
                    sharingTeamsByArtifactID[artifact.id] = await vm.teamsHoldingDoc(artifact.id)
                },
                firstPublished: {
                    docChrome.pagePresentationWasChosen = false
                    docChrome.showsPage = true
                },
                openSettings: {
                    isSharePopoverPresented = false
                    docChrome.isPublishSheetPresented = true
                },
                close: { isSharePopoverPresented = false }
            )
        }
    }

    /// A team's record listed in My Library (docs/teams-design.md, decision
    /// 18): a small mark and the team's name on hover. Nothing while a team
    /// library is open — every row there is the team's.
    @ViewBuilder
    func teamMembershipBadge(for artifact: ArtifactRecord) -> some View {
        if vm.activeTeamID == nil, let teamID = artifact.teamID {
            let name = vm.teams.first { $0.id == teamID }?.name ?? "a team"
            Image(systemName: "person.2")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .help("In \(name)")
                .accessibilityLabel("In \(name)")
        }
    }

    /// Select a row. A team's record listed in My Library opens in the team's
    /// library, since a Doc opens only from the library that holds it.
    private func select(_ artifact: ArtifactRecord) {
        if vm.activeTeamID == nil, artifact.teamID != nil {
            Task { await vm.openTeamArtifact(artifact.id) }
        } else {
            selectedArtifactID = artifact.id
        }
    }

    /// The open Doc is a member's draft of a team Doc: say so, and offer to
    /// publish it. The team sees the doc as it was until then.
    private var draftControls: some View {
        HStack(spacing: 2) {
            Text("Draft")
                .zoomedSystemFont(size: 9, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: Capsule())
            Button {
                docChrome.publishDraftRequest = ArtifactDraftPublishRequest()
            } label: {
                chromeChipLabel("Publish", systemImage: "arrow.up.doc", prominent: true)
            }
            .buttonStyle(.hoverWash)
            .help("Publish this draft to \(vm.activeLibraryTitle)")
            .accessibilityLabel("Publish Draft")
        }
    }

    /// **Update Page** while a published doc is being edited: republish the
    /// current text at the page's address. The publish sheet does the work and
    /// the pane returns to the page when it is done.
    private var updatePageButton: some View {
        Button {
            docChrome.isPublishSheetPresented = true
        } label: {
            chromeChipLabel("Update Page", systemImage: "arrow.up.doc", prominent: true)
        }
        .buttonStyle(.hoverWash)
        .help("Publish the current text to the page on foreverlm.com")
        .accessibilityLabel("Update Page")
    }

    /// Edit on a team Doc: take a private draft of it, or return to the one
    /// already taken.
    private func editTeamDocButton(for artifact: ArtifactRecord) -> some View {
        let hasDraft = vm.teamDocDraftID(for: artifact.id) != nil
        return Button {
            Task { await vm.beginEditingTeamDoc(artifact.id) }
        } label: {
            chromeChipLabel(hasDraft ? "Continue Draft" : "Edit", systemImage: "square.and.pencil", prominent: true)
        }
        .buttonStyle(.hoverWash)
        .help(hasDraft
              ? "Open your draft of this page"
              : "Edit a private draft; the team sees your changes when you publish")
        .accessibilityLabel(hasDraft ? "Continue Draft" : "Edit")
    }

    /// The chrome line's glyph-only control: the chip's size and tone without
    /// its words.
    private func chromeIconLabel(_ systemImage: String, prominent: Bool = false) -> some View {
        Image(systemName: systemImage)
            .zoomedSystemFont(size: 12, weight: .medium)
            .foregroundStyle(prominent ? Color.primary : Color.secondary)
            .frame(width: StudioDesign.Metrics.chromeButtonWidth - 6, height: StudioDesign.Metrics.chromeButtonHeight)
            .contentShape(Rectangle())
    }

    /// The chrome line's small labelled control, in the treatment the
    /// published address uses.
    private func chromeChipLabel(_ title: String, systemImage: String, prominent: Bool = false) -> some View {
        Label(title, systemImage: systemImage)
            .zoomedSystemFont(size: 11, weight: .medium)
            .foregroundStyle(prominent ? Color.primary : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: StudioDesign.Metrics.chromeButtonHeight)
            .contentShape(Rectangle())
    }

    /// The page's menu, on the leading side of its top line: ChatGPT's page ▾.
    /// Everything the page can do that is not happening now — the AI, the
    /// formatting a keyboardless writer reaches for, how it is drawn, where it
    /// lives and who has it, publishing, and the Trash — so the line itself
    /// holds only Share and what needs the learner now ("Quiet chrome",
    /// docs/ui-design.md). What it opens — the publish sheet, the
    /// confirmations, the Google Doc conversion, the comments drawer — is
    /// presented by the editor, which binds to the same bridge this menu
    /// writes.
    private func pageMenu(for artifact: ArtifactRecord) -> some View {
        let publishedStatus = publishedStatuses[artifact.id]
        let isOwnEditable = artifact.teamID == nil && !docChrome.showsPage
        return Menu {
            // Codex's first item: the Space sidebar beside the page, out of
            // the way and back. The key is also held by an invisible button
            // (`pagesShortcut`), since a menu's shortcut does not run while the
            // menu is shut.
            if spaceSidebarFitsPane {
                Button {
                    togglePagesSidebar()
                } label: {
                    Label(showsSpaceSidebar ? "Hide pages" : "Show pages", systemImage: "sidebar.leading")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            if section == .docs {
                Button {
                    beginCreation()
                } label: {
                    Label("New Page", systemImage: "doc.badge.plus")
                }
            }
            pageEverydayItems(for: artifact)
            if isOwnEditable {
                Button {
                    docChrome.aiEditOpenRequestID += 1
                } label: {
                    Label("Edit with AI…", systemImage: "sparkles")
                }
                .help("Ask for a change to the selected passage, or to the section at the caret")
                // The tool pill's other three, while the line is too short
                // to hold the pill.
                if !showsPageTools(for: artifact) {
                    Menu {
                        Button("Image…", systemImage: "photo") { formatting.run(.image) }
                        Button("Visualize…", systemImage: "square.on.circle") { formatting.run(.visualize) }
                        Button("All Blocks…", systemImage: "plus") { formatting.run(.insert) }
                    } label: {
                        Label("Insert", systemImage: "plus")
                    }
                }
                Menu {
                    Section { formatItems(ArtifactFormatCommand.markGroup) }
                    Section { formatItems(ArtifactFormatCommand.insertGroup) }
                } label: {
                    Label("Format", systemImage: "textformat")
                }
            }
            Button {
                docChrome.togglePage()
            } label: {
                Label(
                    docChrome.showsPage ? "Edit Page" : "View as Page",
                    systemImage: docChrome.showsPage ? "pencil" : "doc.richtext"
                )
            }
            .help("This Page as it reads on foreverlm.com, published or not")
            Menu {
                Picker("Page Width", selection: $pageWidth) {
                    ForEach(ArtifactPageWidth.allCases) { width in
                        Text(width.title).tag(width)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                // The cards beside a paragraph for the sources it cites. A
                // reader who wants the prose alone turns them off for every
                // page; the links stay in the prose.
                Toggle(isOn: $showsMarginCards) {
                    Label("Show Source Cards", systemImage: "sidebar.right")
                }
            } label: {
                Label("Page Width", systemImage: "arrow.left.and.right")
            }
            Button {
                docChrome.isCommentsVisible.toggle()
            } label: {
                Label(docChrome.isCommentsVisible ? "Hide Discussion" : "Discussion", systemImage: "text.bubble")
            }
            .help("Comments on this page, and the chats its passages started")
            Divider()
            Button {
                // The side chat over the page takes the page with its
                // sources; a window with none keeps the docked route.
                if pageHostsSideChat {
                    docChrome.wholePageChatRequest = PageSideChatWholePageRequest(intent: .addToChat)
                } else {
                    Task { await vm.attachDocToChat(artifact.id) }
                }
            } label: {
                Label("Add to Chat", systemImage: "message")
            }
            OpenStudioDestinationInOtherWindowMenu(
                destination: .doc(artifact.id),
                currentWindowState: windowState,
                openNewWindow: { openWindow(id: "studio") }
            )
            ArtifactNotebooksMenu(artifact: artifact)
            KnowledgeMapAddToCanvasMenu(refs: ["doc:\(artifact.id)"])
            KnowledgeMapOnCanvasesSection(ref: "doc:\(artifact.id)", windowState: windowState)
            PageSpaceMenu(page: artifact)
            // A team copy needs no publishing and no reader list, so this
            // sits with Notebooks (where the Doc is filed) rather than with
            // Share… and Publish… (who outside the library may read it).
            ShareWithTeamMenu { teamID in
                Task {
                    await vm.shareArtifact(artifact.id, withTeam: teamID)
                    sharingTeamsByArtifactID[artifact.id] = await vm.teamsHoldingDoc(artifact.id)
                }
            }
            // Where a Doc in My Library has gone: each team holding a copy.
            if vm.activeTeamID == nil, let teams = sharingTeamsByArtifactID[artifact.id], !teams.isEmpty {
                Menu {
                    ForEach(teams) { team in
                        Button(team.name) {
                            Task { await vm.openTeamCopy(ofDoc: artifact.id, inTeam: team.id) }
                        }
                    }
                } label: {
                    Label("Open Team Copy", systemImage: "person.2")
                }
            }
            AssignToMemberMenu { member in
                Task { await vm.assign(artifactID: artifact.id, to: member) }
            }
            if vm.teamArtifactID(forDraft: artifact.id) != nil {
                Divider()
                Button(role: .destructive) {
                    docChrome.showDiscardDraftConfirmation = true
                } label: {
                    Label("Discard Draft…", systemImage: "trash")
                }
            }
            Divider()
            Button {
                ArtifactSharingService.shared.presentShare(
                    artifactID: artifact.id,
                    title: artifact.title
                )
            } label: {
                Label("Share…", systemImage: "person.crop.circle.badge.plus")
            }
            // Who can open the page is the Share popover's; the submenu names
            // the answer with the same sentence and keeps what the popover
            // does not do — the address, a republish of the text, Unpublish.
            if let publishedStatus {
                Menu {
                    Button {
                        isSharePopoverPresented = true
                    } label: {
                        Label("Who Can Open the Page…", systemImage: "person.badge.plus")
                    }
                    .help("Invite people, open the link to anyone, or share with a team")
                    Button {
                        NSWorkspace.shared.open(publishedStatus.url)
                    } label: {
                        Label("Open Page", systemImage: "safari")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(publishedStatus.url.absoluteString, forType: .string)
                        vm.showToast("Link copied")
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    Button {
                        docChrome.isPublishSheetPresented = true
                    } label: {
                        Label("Update Page or Address…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Replace the published page with this Page's current text, or give it a custom address")
                    Divider()
                    Button(role: .destructive) {
                        docChrome.showUnpublishConfirmation = true
                    } label: {
                        Label("Unpublish…", systemImage: "globe.badge.chevron.backward")
                    }
                } label: {
                    Label(accessSummary(for: artifact), systemImage: publishedStatus.isProtected ? "lock" : "globe")
                }
            } else {
                Button {
                    isSharePopoverPresented = true
                } label: {
                    Label("Publish to foreverlm.com…", systemImage: "globe")
                }
                .help("Publish this Page on foreverlm.com — for anyone with the link, or for the people you invite")
            }
            Button {
                docChrome.isConvertingToGoogleDoc = true
            } label: {
                Label("Convert to Google Doc…", systemImage: LinkedGoogleDoc.symbolName)
            }
            .help("Copy this page into a new Google Doc and edit it there from now on")
            Divider()
            Button {
                Task {
                    guard let url = await vm.artifactFileURL(artifact.id) else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) {
                trash(artifact)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        } label: {
            pageMenuLabel {
                Image(systemName: "doc.text")
                    .zoomedSystemFont(size: 12.5, weight: .medium)
                    .foregroundStyle(formatting.activeFormats.isEmpty ? Color.primary : Color.accentColor)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverWash)
        .help("Page")
        .accessibilityLabel("Page menu")
        .accessibilityIdentifier("page.menu")
    }

    /// ChatGPT's page menu, its everyday items, in a block of their own under
    /// New Page: Rename…, Duplicate, Version History… and Export ▸
    /// (docs/docs-design.md, "The page" and "Version history"; the product owner,
    /// 2026-10-06: "make sure the docs etc work equally nicely and have
    /// feature parity"). A team's page is read and exported here, never
    /// renamed or copied; a daily note is named by its day.
    @ViewBuilder
    private func pageEverydayItems(for artifact: ArtifactRecord) -> some View {
        let isOwn = artifact.teamID == nil
        if isOwn, DailyNote.dayKey(ofID: artifact.id) == nil {
            Button {
                renamePage(artifact)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }
        if isOwn, vm.activeTeamID == nil {
            SpacePagePinItem(artifact: artifact)
        }
        if isOwn, vm.teamArtifactID(forDraft: artifact.id) == nil {
            Button {
                duplicatePage(artifact)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        // Nested pages (docs/docs-design.md, "Subpages"): a page made inside
        // this one, this one put under another, and back to the top.
        if isOwn, vm.activeTeamID == nil {
            PageNestMenuItems(page: artifact, onMoveToPage: { artifactToNest = artifact }) { subpage in
                openSubpage(subpage)
            }
        }
        Button {
            docChrome.isVersionHistoryPresented = true
        } label: {
            Label("Version History…", systemImage: "clock.arrow.circlepath")
        }
        .help("Earlier versions of this page on this Mac")
        // Codex's page menu has Copy ▸ and Download as Markdown as items of
        // their own (product owner, 2026-10-07, with its screenshot): the text is
        // the Markdown, so the one everyday export is a single press, and
        // Export ▸ keeps the formats that are drawn rather than written.
        Menu {
            Button {
                docChrome.exportRequest = PageExportRequest(format: .markdown, delivery: .copy)
            } label: {
                Label("Copy as Markdown", systemImage: "doc.plaintext")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(StudioEntityLink.doc(artifact.id).markdownDestination, forType: .string)
                vm.showToast("Link copied")
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            .help("This page's address inside ForeverLM, to paste into another page or a chat")
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            docChrome.exportRequest = PageExportRequest(format: .markdown)
        } label: {
            Label("Download as Markdown", systemImage: "arrow.down.to.line")
        }
        Menu {
            ForEach(PageExportFormat.allCases.filter { $0 != .markdown }) { format in
                Button {
                    docChrome.exportRequest = PageExportRequest(format: format)
                } label: {
                    Label(format.menuTitle, systemImage: format.systemImage)
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        if isOwn {
            Button {
                vm.requestNewScheduledTaskChat(aboutPageID: artifact.id, title: artifact.title)
            } label: {
                Label("New schedule…", systemImage: "clock")
            }
            .help("Ask the assistant to run something about this page on a schedule")
        }
        Divider()
    }

    /// Rename… puts the caret in the page's title, as a click on it does; on
    /// the rendered page, which draws no title field, the name is asked for.
    private func renamePage(_ artifact: ArtifactRecord) {
        if docChrome.showsPage {
            artifactRenameDraft = artifact.title
            artifactToRename = artifact
        } else {
            docChrome.titleEditRequestID += 1
        }
    }

    /// Duplicate: the typing on screen is written first, so the copy is the
    /// page as it reads; the copy opens in this pane.
    private func duplicatePage(_ artifact: ArtifactRecord) {
        Task {
            if selectedArtifactID == artifact.id { try? await docChrome.flushDraft?() }
            guard let copy = await vm.duplicateArtifact(artifact.id) else { return }
            if artifacts.contains(where: { $0.id == copy.id }) {
                searchText = ""
                selectedArtifactID = copy.id
            } else {
                vm.revealArtifact(copy.id, in: windowState)
            }
        }
    }

    /// New Subpage: the page just made under this one opens in this pane.
    private func openSubpage(_ subpage: ArtifactRecord) {
        if artifacts.contains(where: { $0.id == subpage.id }) {
            searchText = ""
            selectedArtifactID = subpage.id
        } else {
            vm.revealArtifact(subpage.id, in: windowState)
        }
    }

    /// Move to Trash, from any of the page's menus: a page or a site goes to
    /// the Space's Trash at once, undone from there (Restore); an animation
    /// keeps its question and is deleted, as it has no Trash to be found in.
    private func trash(_ artifact: ArtifactRecord) {
        guard section != .animations else {
            artifactToDelete = artifact
            return
        }
        closeIfOpen(artifact)
        Task { await vm.moveArtifactToTrash(artifact.id) }
    }

    @ViewBuilder
    private func formatItems(_ commands: [ArtifactFormatCommand]) -> some View {
        ForEach(commands) { command in
            Toggle(isOn: formatBinding(command)) {
                Label(command.helpText, systemImage: command.symbolName)
            }
        }
    }

    /// An item reads as on while the caret sits inside that formatting. Setting
    /// it either way runs the one toggling command the editor already binds to
    /// its keymap, so switching a mark off goes through the editor too.
    private func formatBinding(_ command: ArtifactFormatCommand) -> Binding<Bool> {
        Binding(
            get: { formatting.activeFormats.contains(command) },
            set: { _ in formatting.run(command) }
        )
    }

    private var artifactList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.tertiary)
                TextField("Search \(section.pluralNoun)", text: $searchText)
                    .textFieldStyle(.plain)
                    .zoomedSystemFont(size: 11)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.hoverWash(in: Circle(), inset: -3))
                    .help("Clear search")
                }
                // The list's collapse control lives on the list, at its inner
                // edge beside the search field, the way a side panel is
                // closed from inside itself rather than from the pane title.
                StudioChromeIconButton(
                    systemImage: "sidebar.leading",
                    label: "Hide \(section.pluralNoun) list"
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isArtifactListVisible = false
                    }
                }
                .padding(.trailing, -6)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(visibleArtifacts) { artifact in
                        Button {
                            select(artifact)
                            // In a pane that only holds one column, choosing a
                            // doc is the gesture that asks for the page.
                            if !listFitsBesideDocument {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isArtifactListVisible = false
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    // A linked page is named as one in two
                                    // places — the glyph here and the caption
                                    // below — so it never blends in with a doc
                                    // the writer can edit in place.
                                    artifactKindIcon(for: artifact, height: 11)
                                    Text(artifact.title)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    teamMembershipBadge(for: artifact)
                                    if artifact.isDraft || vm.teamDocDraftID(for: artifact.id) != nil {
                                        Text("Draft")
                                            .zoomedSystemFont(size: 8, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.primary.opacity(0.07),
                                                in: Capsule()
                                            )
                                            .accessibilityLabel("Draft document")
                                    }
                                    if artifact.isArchived {
                                        Text("Archived")
                                            .zoomedSystemFont(size: 8, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.primary.opacity(0.07),
                                                in: Capsule()
                                            )
                                            .accessibilityLabel("Archived")
                                    }
                                    if artifact.isHidden {
                                        Text("Hidden")
                                            .zoomedSystemFont(size: 8, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.primary.opacity(0.07),
                                                in: Capsule()
                                            )
                                            .accessibilityLabel("Hidden")
                                    }
                                    if publishedStatuses[artifact.id] != nil {
                                        Text("Published")
                                            .zoomedSystemFont(size: 8, weight: .semibold)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(
                                                Color.primary.opacity(0.07),
                                                in: Capsule()
                                            )
                                            .accessibilityLabel("Published document")
                                    }
                                }
                                Text(docListDetail(for: artifact))
                                    .lineLimit(1)
                                    .zoomedSystemFont(size: 9)
                                    .foregroundStyle(.tertiary)
                            }
                            .zoomedSystemFont(size: 11)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedArtifactID == artifact.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
                        .contextMenu {
                            docActions(for: artifact)
                        }
                        // The row drags the doc as well as the pane: dropped on
                        // the center edge it opens Docs beside showing this doc,
                        // dropped on a chat it joins that chat's context, dropped
                        // on the open doc's page it is written there as a link.
                        // The row must not select itself as the drag begins:
                        // the editor is keyed on the selection, so that swapped
                        // the open doc for the dragged one under the pointer and
                        // the drop landed on itself, which writes nothing. The
                        // edge split reveals the dragged doc when it lands.
                        .onDrag {
                            StudioDragVisibility.shared.begin(centerTab: section.centerTab, artifactID: artifact.id)
                            return studioArtifactDragProvider(for: artifact)
                        }
                    }

                    if visibleArtifacts.isEmpty {
                        ContentUnavailableView("No matching \(section.pluralNoun)", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                    }
                }
                .padding(7)
                // The space under the rows takes the whole height, so a
                // right-click anywhere in the list that is not a row offers
                // the same two ways in that the header buttons do. A row's own
                // context menu still wins over it.
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .contextMenu {
                    addDocMenuItems
                }
            }
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - Docs home

    /// A doc's actions, shared by its row in the list and its card on the
    /// home so the two never drift apart.
    @ViewBuilder
    private func docActions(for artifact: ArtifactRecord) -> some View {
        // An animation with a walkthrough is walked through in the chat
        // beside it, one step a turn, the page following each step
        // (walkthrough-design.md, "Animations are walked through").
        if artifact.isAnimation, vm.artifactIDsWithWalkthroughs.contains(artifact.id) {
            Button("Walk Through", systemImage: "figure.walk") {
                selectedArtifactID = artifact.id
                vm.requestWalkthroughPlayback(forAnimation: artifact.id)
            }
            .accessibilityIdentifier("animations.walkThrough")
            Divider()
        }
        Button("Rename…", systemImage: "pencil") {
            artifactRenameDraft = artifact.title
            artifactToRename = artifact
        }
        // The name as the row shows it, for pasting into a chat or a message
        // (product owner, 2026-09-10: "give me a right click copy name of a site").
        Button("Copy Name", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(artifact.title, forType: .string)
            vm.showToast("Name copied")
        }
        // Draft is a state of something written here; a site is not written
        // here, so it is neither a draft nor production, and a mnemonic
        // reading is written by its writer.
        if section == .docs, !artifact.isMnemonicReading {
            Button(
                artifact.isDraft ? "Mark as Production" : "Mark as Draft",
                systemImage: artifact.isDraft ? "checkmark.seal" : "pencil.line"
            ) {
                Task {
                    await vm.updateArtifact(
                        artifactID: artifact.id,
                        isDraft: !artifact.isDraft
                    )
                }
            }
        }
        // Put away, not thrown away: the record keeps its body, its page and
        // its Notebook links and only leaves the list (product owner, 2026-09-10:
        // "allow me to archive sites"). For a page or a site the put-away
        // place is the Space's Trash since 2026-10-06, so Move to Trash below
        // is the one way there and Restore the way back; an animation keeps
        // Archive, having no Trash to be found in.
        if artifact.isArchived {
            Button("Restore \(section.noun.capitalized)", systemImage: "arrow.uturn.backward") {
                Task { await vm.restoreArtifactFromTrash(artifact.id) }
            }
        } else if section == .animations {
            Button("Archive \(section.noun.capitalized)", systemImage: "archivebox") {
                closeIfOpen(artifact)
                Task { await vm.updateArtifact(artifactID: artifact.id, isArchived: true) }
            }
        }
        // Hide is the learner's view, where Archive is the record's state
        // (product owner, 2026-09-11: "allow me to hide docs also; and sites as
        // well"). Nothing about the record moves — not its date, its team
        // copies or its page; the hide syncs as a record of its own, so every
        // Mac of the learner's hides it and no teammate does. The Hidden
        // filter is the one place it is listed again, with Show on the same
        // menu.
        if artifact.isHidden {
            Button("Show \(section.noun.capitalized)", systemImage: "eye") {
                Task { await vm.setArtifactHidden(artifactID: artifact.id, isHidden: false) }
            }
        } else {
            Button("Hide \(section.noun.capitalized)", systemImage: "eye.slash") {
                closeIfOpen(artifact)
                Task { await vm.setArtifactHidden(artifactID: artifact.id, isHidden: true) }
            }
        }
        ArtifactNotebooksMenu(artifact: artifact)
        KnowledgeMapAddToCanvasMenu(refs: ["doc:\(artifact.id)"])
        KnowledgeMapOnCanvasesSection(ref: "doc:\(artifact.id)", windowState: windowState)
        ShareWithTeamMenu { teamID in
            Task { await vm.shareArtifact(artifact.id, withTeam: teamID) }
        }
        AssignToMemberMenu { member in
            Task { await vm.assign(artifactID: artifact.id, to: member) }
        }
        Divider()
        // A site kept in the library has no web address to open.
        if LinkedPage.localSiteID(fromURLString: artifact.linkedURL) == nil {
            if let linkedURL = artifact.linkedURL, let url = URL(string: linkedURL) {
                Button("Open in Browser", systemImage: "safari") {
                    NSWorkspace.shared.open(url)
                }
            } else if !artifact.isMnemonicReading {
                Button("Convert to Google Doc…", systemImage: LinkedGoogleDoc.symbolName) {
                    artifactToConvert = artifact
                }
            }
        }
        Button("Add to Chat", systemImage: "message") {
            Task { await vm.attachDocToChat(artifact.id) }
        }
        Button("Open Beside", systemImage: "rectangle.split.2x1") {
            selectedArtifactID = artifact.id
            vm.placeCenterTabAtEdge(section.centerTab, leading: false)
        }
        // Where a click on the row goes: a team's record listed in My
        // Library opens through its team's library (`select(_:)`).
        OpenStudioDestinationInOtherWindowMenu(
            destination: vm.activeTeamID == nil && artifact.teamID != nil
                ? .teamArtifact(artifact.id)
                : .doc(artifact.id),
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
        Divider()
        if artifact.isArchived, section != .animations {
            Button("Delete Forever…", systemImage: "trash", role: .destructive) {
                artifactToDelete = artifact
            }
        } else {
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                trash(artifact)
            }
        }
    }

    private func commitArtifactRename() {
        guard let artifact = artifactToRename else { return }
        let title = artifactRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        artifactToRename = nil
        guard title != artifact.title else { return }
        Task { await vm.updateArtifact(artifactID: artifact.id, title: title) }
    }

    /// Putting the open record away — archiving or hiding it — closes it onto
    /// the index, since the list beside it no longer shows it.
    private func closeIfOpen(_ artifact: ArtifactRecord) {
        guard selectedArtifactID == artifact.id else { return }
        if notebookID == nil {
            selectedArtifactID = nil
            isShowingIndex = true
        } else {
            // A Notebook's canvas has no index: the next doc in the list takes
            // the pane, or the placeholder does.
            selectedArtifactID = visibleArtifacts.first { $0.id != artifact.id }?.id
        }
    }

    /// The home's entries: the search, then the filter, in the side list's
    /// order — newest created first, so an edit moves a card no more than it
    /// moves a row.
    private var homeArtifacts: [ArtifactRecord] {
        let filtered: [ArtifactRecord]
        switch homeFilter {
        case .all: filtered = visibleArtifacts
        case .published: filtered = visibleArtifacts.filter { publishedStatuses[$0.id] != nil }
        // ForeverLM's own: a site made here (`save_site`).
        case .foreverlmPages: filtered = visibleArtifacts.filter { $0.linkedKind == .foreverlmSite }
        case .drafts: filtered = visibleArtifacts.filter { $0.isDraft || vm.teamDocDraftID(for: $0.id) != nil }
        case .claudeArtifacts: filtered = visibleArtifacts.filter { $0.linkedKind == .claudeArtifact }
        case .codexSites: filtered = visibleArtifacts.filter { $0.linkedKind == .codexSite }
        // `visibleArtifacts` is already the archived, or the hidden, set under
        // these filters.
        case .archived, .hidden: filtered = visibleArtifacts
        }
        return filtered
    }

    /// The Docs home: what the rail's Docs row lands on. A gallery in the shape
    /// Claude's Artifacts and Codex's Sites pages take (product owner, 2026-09-08):
    /// the surface's name and one line on what it is for; the filters, the
    /// search and the one prominent way to make a new doc on a row; the docs
    /// as cards, newest first; and, with nothing written yet, an illustration,
    /// a question and the same button. The side list a doc opens with is
    /// unchanged — this is the place with no doc open.
    private var artifactHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                homeControls

                if homeArtifacts.isEmpty {
                    homeEmptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
                        .padding(.bottom, 32)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(homeArtifacts) { artifact in
                            homeCard(for: artifact)
                        }
                    }
                    .padding(.top, 18)
                }
            }
            // The Space's column (`spacePlaceColumn`), less the margin the
            // workspace already draws around this home.
            .padding(.horizontal, SpacePlaceMetrics.horizontalPadding - StudioDesign.Metrics.pageMargin)
            .padding(.top, SpacePlaceMetrics.topPadding - 14)
            .padding(.bottom, SpacePlaceMetrics.bottomPadding - 12)
            .frame(maxWidth: SpacePlaceMetrics.maxWidth - 2 * StudioDesign.Metrics.pageMargin, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title) home")
    }

    /// The Space's head (`SpacePlaceHeader`): the name, the search and the one
    /// prominent way in, then the filters as the Space's scope pills.
    /// Teammates' requests for sources this library holds sit between the
    /// two: they are the one thing on this home that waits on you.
    private var homeControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            SpacePlaceHeader(searchText: $searchText, searchIdentifier: "artifacts.home.search") {
                SpacePlaceTitle(title: notebookID.flatMap { vm.notebook(id: $0)?.title } ?? section.title)
            } actions: {
                homeNewDocButton
            }
            if !vm.fulfillableShareRequests.isEmpty {
                ShareRequestsBanner()
            }
            homeFilterChips
        }
    }

    /// The chips keep their words whole: a pane narrower than the row scrolls
    /// it sideways rather than breaking "Published" into syllables stacked
    /// five lines tall, which is what a squeezed HStack of Texts did in a
    /// three-pane window once Hidden made the row five and six chips long.
    private var homeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(ArtifactHomeFilter.cases(for: section, notebookScoped: notebookID != nil)) { filter in
                    SpaceScopePill(title: filter.title, isSelected: homeFilter == filter) {
                        homeFilter = filter
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The one prominent way in, as the Space's dark pill: New Page on the
    /// Pages home, Link a Site… on the Sites home, where nothing is written
    /// and every entry is a link, and the animation chat on Animations.
    @ViewBuilder
    private var homeNewDocButton: some View {
        switch section {
        case .docs:
            SpaceDarkPillButton(
                title: "New Page",
                systemImage: nil,
                image: nil,
                shortcut: KeyboardShortcut("n", modifiers: [.command, .shift])
            ) {
                beginCreation()
            }
            .help("Start a new page")
        case .sites:
            SpaceDarkPillButton(title: section.linkActionTitle, systemImage: nil, image: nil) {
                isLinkingPage = true
            }
            .help("Link a Codex site or a Claude artifact from its address")
        case .animations:
            // An animation is made in a chat, not linked: the button opens
            // one with the request typed, and the learner names the source.
            SpaceDarkPillButton(title: section.linkActionTitle, systemImage: nil, image: nil) {
                vm.requestAnimationChat()
            }
            .help("Ask the chat for an animation of how something in a source works")
        }
    }

    /// One doc on the home: its title, where it lives or where it is
    /// published, what it is (Draft, Published, a Google Doc, a team's copy)
    /// and when it last changed. The same drag, actions and destination as
    /// its row in the list.
    private func homeCard(for artifact: ArtifactRecord) -> some View {
        let published = publishedStatuses[artifact.id]
        let teams = vm.activeTeamID == nil ? (sharingTeamsByArtifactID[artifact.id] ?? []) : []
        return Button {
            if vm.activeTeamID == nil, artifact.teamID != nil {
                Task { await vm.openTeamArtifact(artifact.id) }
                return
            }
            selectedArtifactID = artifact.id
            if !listFitsBesideDocument {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isArtifactListVisible = false
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    artifactKindIcon(for: artifact, height: 13)
                    Text(artifact.title)
                        .zoomedSystemFont(size: 15, weight: .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(published.map { "foreverlm.com/share/\($0.slug)" } ?? notebookLabel(for: artifact))
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 4)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if artifact.isDraft || vm.teamDocDraftID(for: artifact.id) != nil {
                        homeBadge("Draft")
                    }
                    if artifact.isArchived {
                        homeBadge("Archived", systemImage: "archivebox")
                    }
                    if artifact.isHidden {
                        homeBadge("Hidden", systemImage: "eye.slash")
                    }
                    if published != nil {
                        homeBadge(published?.isProtected == true ? "Published · shared" : "Published")
                    }
                    ForEach(teams) { team in
                        homeBadge(team.name, systemImage: "person.2")
                    }
                    Spacer(minLength: 0)
                    Text("\(section == .docs ? "Edited" : "Updated") \(artifact.updatedAt.formatted(.dateTime.month(.abbreviated).day()))")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.top, 12)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0))
        .accessibilityLabel(artifact.title)
        .contextMenu {
            docActions(for: artifact)
        }
        .onDrag {
            StudioDragVisibility.shared.begin(centerTab: section.centerTab, artifactID: artifact.id)
            return studioArtifactDragProvider(for: artifact)
        }
    }

    private func homeBadge(_ title: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .zoomedSystemFont(size: 8, weight: .semibold)
            }
            Text(title)
                .zoomedSystemFont(size: 9, weight: .semibold)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    /// Nothing to show: either the library has no docs yet, which gets the
    /// illustration and the question, or the search and filter left none,
    /// which says so quietly. The blank slate asks about the whole library,
    /// not the filter: an empty Archived or Hidden filter over a full library
    /// says "Nothing archived" / "Nothing hidden", never "What will you write?".
    @ViewBuilder
    private var homeEmptyState: some View {
        let libraryIsEmpty = !artifacts.contains {
            !TeamContentIdentity.isDraftArtifactID($0.id) && !DailyNote.isDailyNoteID($0.id)
        }
        if libraryIsEmpty && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch section {
            case .docs:
                VStack(spacing: 14) {
                    homeIllustration
                    Text("What will you write?")
                        .zoomedSystemFont(size: 15, weight: .semibold)
                    Text("A page starts out empty. Cite the sources you are reading as you go, ask the AI to draft or revise a passage, publish it on foreverlm.com, or share it with a team that edits it with you.")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    HStack(spacing: 10) {
                        SpaceDarkPillButton(title: "New Page", systemImage: nil, image: nil) { beginCreation() }
                        Button(section.linkActionTitle) { isLinkingPage = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            case .sites:
                VStack(spacing: 14) {
                    sitesIllustration
                    Text("Bring your pages here")
                        .zoomedSystemFont(size: 15, weight: .semibold)
                    Text("A page you publish from Pages appears here as it reads on foreverlm.com. A Codex site or a Claude artifact opens here as itself, with a read-only text copy that chat and review can read; paste its link to start, and the site or artifact itself stays where it is.")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    SpaceDarkPillButton(title: section.linkActionTitle, systemImage: nil, image: nil) { isLinkingPage = true }
                        .padding(.top, 2)
                }
            case .animations:
                VStack(spacing: 14) {
                    Image(systemName: ArtifactKind.animation.symbolName)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .accessibilityHidden(true)
                    Text("See how it works")
                        .zoomedSystemFont(size: 15, weight: .semibold)
                    Text("Ask a chat about a paper to animate its mechanism — the steps of a pathway, where each happens, with and without the intervention — and it draws one that plays here, linked to the paper. Claude and Codex can save one too, through the ForeverLM plugin.")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    SpaceDarkPillButton(title: section.linkActionTitle, systemImage: nil, image: nil) {
                        vm.requestAnimationChat()
                    }
                    .padding(.top, 2)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: searchText.isEmpty ? homeFilter.emptySymbol : "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(searchText.isEmpty ? homeFilter.emptyTitle : "No matching \(section.pluralNoun)")
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Line art in the same monochrome as the doc's: a browser window with a
    /// title bar and a page inside, and a link ring at its corner.
    private var sitesIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 68, height: 52)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 3) {
                            Circle().frame(width: 3.5, height: 3.5)
                            Circle().frame(width: 3.5, height: 3.5)
                            Circle().frame(width: 3.5, height: 3.5)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().frame(height: 1.5)
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().frame(width: 30, height: 1.5)
                            Capsule().frame(width: 22, height: 1.5)
                            Capsule().frame(width: 26, height: 1.5)
                        }
                        .padding(9)
                    }
                }
                .offset(x: -8, y: 0)
            Image(systemName: "link")
                .font(.system(size: 22, weight: .light))
                .padding(7)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(lineWidth: 1.5))
                .offset(x: 30, y: 22)
        }
        .frame(width: 104, height: 104)
        .foregroundStyle(Color.primary.opacity(0.7))
        .accessibilityHidden(true)
    }

    /// Line art in the doc's own monochrome: a page, a circle and a pencil.
    /// Accent colour stays reserved for content.
    private var homeIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 44, height: 56)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().frame(width: 22, height: 1.5)
                        Capsule().frame(width: 16, height: 1.5)
                        Capsule().frame(width: 20, height: 1.5)
                    }
                    .padding(9)
                }
                .offset(x: -16, y: 6)
            Circle()
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 40, height: 40)
                .offset(x: 18, y: 16)
            Image(systemName: "pencil")
                .font(.system(size: 30, weight: .light))
                .rotationEffect(.degrees(-10))
                .offset(x: 20, y: -18)
        }
        .frame(width: 104, height: 104)
        .foregroundStyle(Color.primary.opacity(0.7))
        .accessibilityHidden(true)
    }

    /// The glyph before a linked record's title: the product's mark for a
    /// linked page, the animation glyph for an animation — which is kept as
    /// a ForeverLM site and would otherwise carry the site's mark — and
    /// nothing for a Markdown doc.
    @ViewBuilder
    private func artifactKindIcon(for artifact: ArtifactRecord, height: CGFloat) -> some View {
        if artifact.isAnimation {
            Image(systemName: ArtifactKind.animation.symbolName)
                .font(.system(size: height, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(ArtifactKind.animation.label)
        } else if let kind = artifact.linkedKind {
            LinkedPageIcon(kind: kind, height: height)
        }
    }

    private func notebookLabel(for artifact: ArtifactRecord) -> String {
        // What kind of thing the row is outranks where it is filed: a linked
        // page says which where another row says its Notebook, and an
        // animation says so rather than naming the site it is hosted as.
        if artifact.isLinked { return artifact.kindLabel ?? "Linked page" }
        if notebookID != nil { return "Edited" }
        let names = artifact.linkedNotebookIDs.compactMap { vm.notebook(id: $0)?.title }
        if names.isEmpty { return "Unfiled" }
        return names.joined(separator: ", ")
    }

    private func docListDetail(for artifact: ArtifactRecord) -> String {
        if let status = publishedStatuses[artifact.id] {
            return "foreverlm.com/share/\(status.slug)"
        }
        return notebookLabel(for: artifact)
    }

    private func publishedStatusBinding(for artifactID: String) -> Binding<PublishedDocStatus?> {
        Binding(
            get: { vm.publishedDocStatuses[artifactID] },
            set: { status in vm.publishedDocStatuses[artifactID] = status }
        )
    }

    private func beginCreation(inPageSpace pageSpaceID: String? = nil) {
        Task {
            do {
                let snapshot = try await vm.createArtifact(
                    title: ArtifactPlaceholderTitle.current,
                    homeNotebookID: notebookID,
                    linkedNotebookIDs: notebookID.map { [$0] } ?? [],
                    pageSpaceID: pageSpaceID
                )
                searchText = ""
                selectedArtifactID = snapshot.artifact.id
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    /// A canvas with no valid selection comes back to the doc this window
    /// last showed, if it lists it, before falling back to the first doc. The
    /// selection is view state and a pane rebuild — a layout change, a tab
    /// swap, the saved layout being applied at launch — makes a fresh canvas;
    /// without this the doc that was open would give way to whichever is first.
    /// Opens the record a card asked for before this canvas could list it.
    /// Clicking an Animation's card on the Artifacts home (an animation is a
    /// row of its notebook's Studio since 2026-10-06) made this canvas and
    /// asked for the record in one motion, but the canvas's list was still
    /// loading when `task` looked, so the request was never answered and the
    /// pane said "Select an animation" (seen filming, 2026-09-24). The list
    /// arriving is heard here as well (`reconcileSelection`).
    private func answerRevealRequestIfListed() {
        guard let request = vm.artifactRevealRequest,
              request.windowID == windowState.id,
              request.section == section,
              artifacts.contains(where: { $0.id == request.artifactID }) else { return }
        vm.artifactRevealRequest = nil
        searchText = ""
        isShowingIndex = false
        selectedArtifactID = request.artifactID
        pendingBlockReveal = request.block.map { ArtifactBlockRevealRequest(artifactID: request.artifactID, reveal: $0) }
    }

    /// A doc this window asked this canvas for that it has not opened yet.
    private var isAwaitingRevealedArtifact: Bool {
        guard let request = vm.artifactRevealRequest else { return false }
        return request.windowID == windowState.id && request.section == section
    }

    /// The canvas's first answer, given before its first frame rather than
    /// after `task`'s reload. A doc clicked in the sidebar or on the Artifacts
    /// home makes this canvas and asks for the doc in one motion, and the
    /// library is almost always loaded already; waiting on the reload — the
    /// shared-doc CloudKit round trip included — left the pane saying "Select
    /// a doc" in the meantime (product owner, 2026-09-29).
    private func answerRequestsBeforeLoad() {
        answerRevealRequestIfListed()
        openPendingArtifactIfNeeded()
        showIndexIfRequested()
        // A doc asked for but not listed yet is still coming; opening the
        // remembered one meanwhile would flash a doc nobody chose. `task`
        // answers once the reload lands.
        guard !isAwaitingRevealedArtifact, windowState.pendingArtifactID == nil else { return }
        reconcileSelection()
        if selectedArtifactID != nil || isShowingIndex { hasSettledSelection = true }
    }

    private func reconcileSelection() {
        answerRevealRequestIfListed()
        if let selectedArtifactID, artifacts.contains(where: { $0.id == selectedArtifactID }) { return }
        // The open record changed section under the pane — published from
        // Docs, unpublished or unlinked from Sites — and is still in the
        // library: follow it to its new pane rather than swapping in whatever
        // is first here. Only the global canvases: a Notebook's Docs lists its
        // published docs too.
        if let selectedArtifactID, notebookID == nil,
           vm.artifacts.contains(where: { $0.id == selectedArtifactID }) {
            vm.revealArtifact(selectedArtifactID)
            self.selectedArtifactID = nil
            return
        }
        // The index has no open doc by design; it is not a selection to repair.
        if isShowingIndex {
            selectedArtifactID = nil
            return
        }
        if let remembered = windowState.openArtifactID,
           artifacts.contains(where: { $0.id == remembered }) {
            selectedArtifactID = remembered
            return
        }
        // Whatever is first on the list as shown — never an archived or a
        // hidden record the list is keeping out of sight, nor a daily note,
        // which is reached by its day, nor a record this canvas does not list.
        selectedArtifactID = visibleArtifacts.first?.id
            ?? artifacts.first { !$0.isArchived && !$0.isHidden && !DailyNote.isDailyNoteID($0.id) && listsHere($0) }?.id
    }

    /// Answers the rail's Docs or Sites row with the index. Only the global
    /// canvas of the row's section does: a Notebook's own Docs list is a
    /// different place, and the row always opens the global one
    /// (`openNotepadInReader` clears the scope). And only the canvas in the
    /// window the row was clicked in: a doc open in another window stays.
    private func showIndexIfRequested() {
        guard notebookID == nil,
              let request = vm.artifactIndexRequest,
              request.windowID == windowState.id,
              request.section == section else { return }
        vm.artifactIndexRequest = nil
        searchText = ""
        // The Space shows the section's own place: Pages, or Sites.
        let place: SpaceDestination = section == .sites ? .sites : .pages
        if windowState.spaceDestinationKey != place.key { windowState.spaceDestinationKey = place.key }
        isShowingIndex = true
        selectedArtifactID = nil
    }

    /// Selects the doc a resume left waiting, if this canvas lists it. A
    /// Notebook-scoped canvas that does not leaves the request standing for
    /// the global one, which does.
    private func openPendingArtifactIfNeeded() {
        guard let artifactID = windowState.pendingArtifactID,
              artifacts.contains(where: { $0.id == artifactID }) else { return }
        windowState.pendingArtifactID = nil
        searchText = ""
        selectedArtifactID = artifactID
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

private struct ArtifactEditor: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    let artifact: ArtifactRecord
    @Binding var publishedStatus: PublishedDocStatus?
    let formatting: ArtifactFormattingBridge
    /// The pane header's controls for this doc; what they open is presented here.
    @Bindable var chrome: ArtifactDocChromeBridge
    let onOpenSource: (String) -> Void
    /// A block of this doc to show and flash once the editor holds it.
    var blockReveal: ArtifactBlockRevealRequest? = nil

    /// The notes graph for this doc: what the editor is told about it, and
    /// the answers to what it asks (`ArtifactNotesGraphHost`).
    @State private var notesGraph = ArtifactNotesGraphHost()
    @State private var snapshot: ArtifactMarkdownSnapshot?
    @State private var draft = ""
    @State private var isLoading = true
    @State private var isDownloadingFromICloud = false
    @State private var isSaving = false
    /// A save was asked for while one was in flight. Only that it was: when
    /// the first one lands, what goes out is the draft as it is then.
    @State private var saveQueued = false
    /// Another writer's version of the body that could not be merged into this
    /// draft — the same passage changed on both sides. Held until the writer
    /// picks one; autosave waits with it.
    @State private var heldRemoteMarkdown: String?
    @State private var isUpdatingTitle = false
    @State private var pageHTML: String?
    @State private var pageError: String?
    /// The page's Edit mode: the change asked for on a hovered block, through
    /// to Keep or Discard (docs/docs-design.md → Edit with AI → On the page).
    @State private var pageEdit: DocPageEditSession?
    @State private var sourceInsertion: ArtifactSourceInsertion?
    /// A doc or Notebook dropped on the page, named and on its way into the prose.
    @State private var linkInsertion: ArtifactLinkInsertion?
    /// The editor asking what the highlighted passage stands on.
    @State private var groundingRequest: ArtifactGroundingRequest?
    @State private var groundingAttachment: ArtifactGroundingAttachment?
    @State private var mutedShelfSourceIDs: Set<String> = []
    @State private var isSourceDropTargeted = false
    @State private var titleDraft = ""
    /// Whether the header shows the title as a field. At rest the title is a
    /// label the writer can drag — into a chat to add the doc to its context,
    /// to the center edge to open Docs beside — and a click on it opens the
    /// field. An editable field cannot be that drag source: its field editor
    /// takes the press for text selection before SwiftUI's drag can start.
    @State private var isEditingTitle = false
    /// Whether the doc is named by its first heading: the stored title is the
    /// `# ` heading the body opens with, so the header would only say the
    /// name a second time, and is not drawn. The heading is the title then —
    /// editing it renames the doc, deleting it brings the header back.
    @State private var titleFollowsHeading = false
    /// The page opened with its title row, so the row keeps its place until the
    /// page is opened again. When the first heading names the page mid-visit,
    /// the row goes blank rather than away: taking it away moved the whole
    /// page up under the caret as the writer went on from the heading.
    @State private var titleRowHeld = false
    @State private var editorSelection = ArtifactEditorSelection(text: "", from: 0, to: 0)
    @State private var attachmentDataURLs: [String: String] = [:]
    /// The web references the editor draws as cards, and the library's answer
    /// for each. The editor reports the addresses; the host looks them up and
    /// hands the answers back, and re-asks whenever the library changes.
    @State private var referenceHrefs: [String] = []
    @State private var referenceStatuses: [String: ArtifactReferenceStatus] = [:]
    /// Resolves the cards' pictures after the answers, a few at a time; a new
    /// answer or a closed doc cancels the one in flight.
    @State private var referenceArtworkTask: Task<Void, Never>?
    /// Whether the editor is drawing a margin column — cards beside paragraphs
    /// that cite the web — which moves the page over; the title follows it.
    @State private var hasMarginColumn = false
    /// How wide the page is drawn; the title's inset follows it.
    @SyncedStorage(ArtifactPageWidth.key) private var pageWidthPreference = ArtifactPageWidth.standard
    /// Whether the margin cards are drawn. Off, the page takes back their
    /// column at once, without waiting for the editor to report it.
    @SyncedStorage(ArtifactMarginCards.key) private var showsMarginCardsPreference = true
    @State private var attachmentInsertion: ArtifactAttachmentInsertion?
    @State private var isImportingImage = false
    @State private var publicationRequestID = 0
    /// The Export ▸ format waiting for the editor's publication HTML: the
    /// HTML file, or the PDF printed from it.
    @State private var pendingPublicationExport: PageExportFormat?
    /// What the next save is, for the page's version history: Keep on a
    /// change the page's Edit proposed is an assistant's edit; everything
    /// else the editor writes is the writer's typing.
    @State private var nextSaveVersionReason: PageVersionReason?
    @State private var comments: [ArtifactCommentRecord] = []
    @State private var chatLinks: [ArtifactChatLink] = []
    @State private var pendingCommentSelection: ArtifactEditorSelection?
    @State private var commentDraft = ""
    @State private var paneWidth: CGFloat = 0
    @State private var findState = ReaderFindState()
    @FocusState private var titleFocused: Bool

    /// Mirrors the page geometry in `artifact-editor.css` so the title starts on
    /// the same left edge as the prose beneath it: a column capped at the page
    /// width the reader chose (760pt by default, or the whole pane), centred in
    /// the pane, with side padding that yields as the pane narrows.
    /// The title is the first field in the page, not a band above one, so it
    /// has to move with the page instead of keeping an inset of its own.
    ///
    /// With a margin column — cards beside the paragraphs that cite the web —
    /// the page moves over, in the same three tiers the stylesheet uses: wide
    /// enough for both, page and column are centred together; narrower, the
    /// page yields the column's width and sits at the left; narrower still, there
    /// is no column — the editor flows the cards below their paragraphs — and the
    /// page is where it always was.
    ///
    /// `width` is the document column's own — the pane's, less the comments
    /// drawer — read by the column's `GeometryReader`, so that while it animates
    /// the rows move with the prose rather than ahead of it (`ArtifactPageInset`).
    private func pageInset(for width: CGFloat) -> ArtifactPageInset {
        ArtifactPageInset(
            paneWidth: width,
            pageMaxWidth: pageWidthPreference.maxWidth,
            hasMarginColumn: hasMarginColumn && showsMarginCardsPreference
        )
    }

    /// Whether the pane can hold the page and the comments drawer at once.
    private var commentsFitBesidePage: Bool { paneWidth <= 0 || paneWidth >= 620 }

    private var commentsWidth: CGFloat { min(300, max(240, paneWidth * 0.4)) }

    private var hasUnsavedChanges: Bool {
        guard let snapshot else { return false }
        return draft != snapshot.markdown
    }

    /// A team Doc reads as a page here; a member edits a private draft of it
    /// (docs/teams-design.md, decision 11).
    private var isReadOnly: Bool { artifact.teamID != nil }

    /// The day this doc is the daily note for; nil for any other doc.
    private var dailyNoteDayKey: String? { DailyNote.dayKey(ofID: artifact.id) }

    /// The library this doc's graph is: its team's — a member's draft of a
    /// team Doc too — or My Library (nil).
    private var graphTeamID: String? { vm.referenceLibraryTeamID(for: artifact) }

    /// The library's docs and Ideas as the graph last read them.
    private var notesGraphLibrarySignature: Int {
        ArtifactNotesGraphHost.librarySignature(
            artifacts: vm.artifacts,
            ideas: vm.ideas,
            openDocID: artifact.id,
            teamID: graphTeamID
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if !chrome.isCommentsVisible || commentsFitBesidePage {
                // The column's width is read in layout, so it reaches the rows
                // in the resize's own transaction: when the pane's width
                // animates, the title moves with the prose instead of jumping
                // to where the prose will end up (`ArtifactPageInset`).
                GeometryReader { column in
                    let inset = pageInset(for: column.size.width)
                    VStack(spacing: 0) {
                        if chrome.showsPage {
                            // The HTML owns its title and report header, and the
                            // doc's controls are in the pane header: nothing of
                            // ours stands between the chrome line and the page
                            // until Cmd+F opens the find bar. A published doc
                            // opens as its page, so this is where most presses
                            // of the shortcut land.
                            ReaderFindBar(state: findState, prompt: "Find in page")
                            pageSurface
                        } else {
                            // A doc named by its first heading has its title on
                            // the page already; the header would say it twice.
                            // A daily note's header steps between days, so it
                            // always stands. A subpage names the pages above it
                            // first, quietly (docs/docs-design.md, "Subpages").
                            PageParentTrail(pageID: artifact.id, inset: inset)
                            if let dayKey = dailyNoteDayKey {
                                dailyNoteHeader(dayKey: dayKey, inset: inset)
                            } else if !titleFollowsHeading || isEditingTitle {
                                header(inset: inset)
                            } else if titleRowHeld {
                                header(inset: inset).hidden()
                            }
                            ReaderFindBar(state: findState, prompt: "Find in page")
                            heldVersionBanner(inset: inset)
                            documentSurface
                            referencesShelf
                        }
                    }
                }
                // Cmd+F reaches the doc while focus is anywhere in its column —
                // the page, its title, or the find bar itself — and from the
                // rest of the window when no reader holds focus: the same claim
                // every reader makes. No zoom handlers, because the page scales
                // with the app's UI zoom rather than a zoom of its own.
                .background {
                    ReaderShortcutTarget(find: { findState.show() })
                }
            }
            if chrome.isCommentsVisible {
                if commentsFitBesidePage {
                    Divider()
                    commentsSidebar
                        .frame(width: commentsWidth)
                } else {
                    // Too narrow to stand beside the page: the drawer takes the
                    // pane rather than pushing the document off it.
                    commentsSidebar
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            paneWidth = width
        }
        // Skipped while the doc is still loading: `load()` fetches the links
        // itself, and running both would query twice for the same answer.
        .task(id: vm.artifactChatLinksRevision) {
            guard !isLoading else { return }
            chatLinks = await vm.artifactChatLinks(artifact.id)
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Keep the complete note as a fallback target for drops that land on
        // its title or source shelf. Drops over the document use the narrower
        // target below, whose passage is the paragraph under the pointer.
        //
        // Off the page there is no paragraph, so the highlighted passage is the
        // only thing such a drop can mean — and with nothing highlighted there
        // is nothing to attach to, which the drag springing back says better
        // than a source silently landing somewhere the writer cannot see.
        .dropDestination(for: StudioArticleTransfer.self) { transfers, _ in
            guard !isReadOnly, editorSelection.hasText else { return false }
            let citations = transfers.flatMap(citations(from:))
            guard !citations.isEmpty else { return false }
            sourceInsertion = ArtifactSourceInsertion(citations: citations)
            return true
        }
        .task(id: "\(artifact.id)-\(chrome.reloadGeneration)") { await load() }
        .onChange(of: publishedStatus, initial: true) { oldStatus, newStatus in
            if newStatus != nil, !chrome.pagePresentationWasChosen {
                chrome.showsPage = true
            } else if oldStatus != nil, newStatus == nil {
                chrome.showsPage = false
                chrome.pagePresentationWasChosen = false
                pageHTML = nil
            }
        }
        // The page follows the text: toggling it on renders the current draft,
        // and a save while it shows re-renders. Off, nothing is fetched. Nor is
        // it before the text has loaded: a published doc opens as its page, and
        // the status arrives ahead of the file, so rendering then would post an
        // empty doc that the loaded text cancels a moment later.
        .task(id: chrome.showsPage && snapshot != nil ? "page:\(titleDraft):\(draft.hashValue):\(pageEdit?.renderKey ?? "")" : "editor") {
            guard chrome.showsPage, snapshot != nil else { return }
            await renderPage()
        }
        // Leaving the page drops a proposal that was never kept: the editor
        // shows the draft, and the draft is what the page comes back to.
        .onChange(of: chrome.showsPage) { _, showsPage in
            if !showsPage, let pageEdit, pageEdit.status != .kept { self.pageEdit = nil }
            // The match belongs to the surface that is leaving; the bar
            // reopens over the other one with Cmd+F.
            findState.close()
        }
        .task(id: draft) {
            guard snapshot != nil, hasUnsavedChanges, heldRemoteMarkdown == nil else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            save(draft)
        }
        // The notes graph follows the library — another doc saved, a page
        // made, an Idea linked — and the doc's own saves, half a second after
        // each settles (docs/notes-graph-design.md).
        .task(id: notesGraphLibrarySignature) {
            guard snapshot != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            notesGraph.libraryChanged(signature: notesGraphLibrarySignature)
        }
        .task(id: snapshot?.revision) {
            guard let revision = snapshot?.revision else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            notesGraph.bodySaved(revision: revision)
        }
        // A daily note's page foot lists what its day held, which grows as
        // the day is read and written in: heard two seconds after the log
        // last changed.
        .task(id: artifact.id) {
            guard dailyNoteDayKey != nil else { return }
            var pending: Task<Void, Never>?
            for await _ in NotificationCenter.default.notifications(named: .dayPlansDidChange) {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    notesGraph.dayActivityChanged()
                }
            }
            pending?.cancel()
        }
        .onChange(of: blockReveal) { _, _ in applyBlockReveal() }
        // The header's comments control shows while comments are open.
        .onChange(of: comments, initial: true) { _, comments in
            chrome.openCommentCount = comments.filter { !$0.isResolved }.count
        }
        .onAppear {
            titleDraft = artifact.title
            // This editor takes the pane header over: a published doc opens
            // as its page, and nothing of the previous doc's carries across.
            chrome.reset(opensAsPage: publishedStatus != nil)
            chrome.flushDraft = { try await flushDraft() }
            applyBlockReveal()
        }
        .onDisappear {
            save(draft)
            saveTitle()
            referenceArtworkTask?.cancel()
            notesGraph.close()
            chrome.flushDraft = nil
            // Closing a Doc publishes its body now rather than on idle (generation 2, D44).
            DocBodySync.requestPublish(artifact.id)
        }
        .onChange(of: artifact.title) { _, title in
            if !titleFocused { titleDraft = title }
            // Judged against the saved body, not the draft: a rename the
            // heading made is measured by the text it was made from, so
            // typing on in the heading does not bring the header back
            // between one save and the next.
            titleFollowsHeading = ArtifactMarkdownTitle.names(title, in: snapshot?.markdown ?? draft)
        }
        .onChange(of: titleFocused) { _, focused in
            guard !focused else { return }
            saveTitle()
            isEditingTitle = false
        }
        .onChange(of: artifact.updatedAt) { _, _ in
            Task { await refreshBodyAfterArtifactUpdate() }
        }
        // Another writer's body landed on disk — a teammate's edit through the
        // team's zone. Re-read at once rather than after the list reloads.
        .task(id: artifact.id) {
            for await notification in NotificationCenter.default.notifications(named: .cloudKitSyncRemoteStoreDidChange) {
                let changed = notification.userInfo?[CloudKitSyncNotificationInfo.changedArtifactIDsKey] as? [String] ?? []
                guard changed.contains(artifact.id) else { continue }
                await refreshBodyAfterArtifactUpdate()
            }
        }
        .onChange(of: chrome.publishDraftRequest) { _, request in
            guard let request else { return }
            chrome.publishDraftRequest = nil
            Task { await publishDraft(overwrite: request.overwrite) }
        }
        .confirmationDialog(
            "Someone else changed this page since your draft began",
            isPresented: $chrome.showDraftPublishConflict,
            titleVisibility: .visible
        ) {
            Button("Replace with My Draft", role: .destructive) {
                chrome.publishDraftRequest = ArtifactDraftPublishRequest(overwrite: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their changes and yours touch the same passage, so they cannot be combined.")
        }
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $chrome.showDiscardDraftConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) {
                Task { await vm.discardTeamDocDraft(artifact.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The team's page stays as it is.")
        }
        // The page menu's Version History…, Export ▸ and Rename…, answered
        // here, where the text is (docs/docs-design.md, "Version history").
        .sheet(isPresented: $chrome.isVersionHistoryPresented) {
            PageVersionHistorySheet(
                pageTitle: titleDraft.isEmpty ? artifact.title : titleDraft,
                currentMarkdown: draft,
                loadVersions: { await vm.pageVersions(artifact.id) },
                loadMarkdown: { try await vm.pageVersionMarkdown(artifact.id, version: $0) },
                restore: isReadOnly ? nil : { try await restoreVersion($0) }
            )
        }
        .onChange(of: chrome.exportRequest) { _, request in
            guard let request else { return }
            chrome.exportRequest = nil
            if request.delivery == .copy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft, forType: .string)
                vm.showToast("Copied as Markdown")
            } else {
                export(request.format)
            }
        }
        .onChange(of: chrome.titleEditRequestID) { _, _ in
            guard !isReadOnly, !chrome.showsPage else { return }
            isEditingTitle = true
            // After the menu has closed and handed focus back to the page.
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                titleFocused = true
            }
        }
        // Add to Chat and the card's New Chat: a chat about the page as a whole.
        .onChange(of: chrome.wholePageChatRequest) { _, request in
            guard let request else { return }
            chrome.wholePageChatRequest = nil
            Task { await openWholePageSideChat(request) }
        }
        // The picker's one job: what the highlighted passage stands on. It opens
        // showing the current answer and sends the whole edited set back at once.
        .sheet(item: $groundingRequest) { request in
            ArtifactSourcePicker(initial: request.sourceIDs, seed: request.selectedText) { sourceIDs in
                groundingAttachment = ArtifactGroundingAttachment(sourceIDs: sourceIDs)
            }
        }
        // The draft is flushed first, so what Google receives is what the page
        // shows, and the autosave has nothing left to write once the doc is
        // read-only.
        .sheet(isPresented: $chrome.isConvertingToGoogleDoc) {
            ConvertToGoogleDocSheet(artifact: artifact) {
                try await flushDraft()
                _ = try await vm.convertDocToGoogleDoc(artifact.id)
            }
        }
        // The draft is flushed first so the page carries what the pane shows.
        .sheet(isPresented: $chrome.isPublishSheetPresented) {
            PublishDocSheet(artifact: artifact, existing: publishedStatus) { access, slug in
                try await flushDraft()
                return try await vm.publishDoc(artifact.id, access: access, slug: slug)
            } published: { status in
                publishedStatus = status
                chrome.pagePresentationWasChosen = false
                chrome.showsPage = true
            }
        }
        .confirmationDialog(
            "Unpublish ‘\(artifact.title)’?",
            isPresented: $chrome.showUnpublishConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpublish", role: .destructive) {
                Task {
                    do {
                        try await vm.unpublishDoc(artifact.id)
                        publishedStatus = nil
                    } catch {
                        chrome.errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("The published page on foreverlm.com is taken down and its link stops working. This Page stays in your library.")
        }
        // Image in the slash menu: the picture goes in at the caret, which is
        // still where the writer left it (`insertImage`).
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.png, .jpeg, .heic, .gif, .webP],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { chrome.errorMessage = error.localizedDescription }
                return
            }
            Task { await insertImage(from: url) }
        }
    }

    /// The stored title identifies the Doc; Markdown headings own the page
    /// hierarchy and are where the writer chooses scale.
    private static let titleFont = Font.system(size: 18, weight: .semibold)

    /// The title: the first field in the page, and the header's only content.
    /// Not drawn while the doc's first heading is its title
    /// (`titleFollowsHeading`): the page says the name already.
    /// The doc's controls — Page/Edit, its address, its overflow — are the
    /// pane header's (`ArtifactCanvas.docControls`), so this row is never drawn
    /// over the rendered page.
    private func header(inset: ArtifactPageInset) -> some View {
        HStack(spacing: 8) {
            if isEditingTitle {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Self.titleFont)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .focused($titleFocused)
                    .onAppear { titleFocused = true }
                    .onSubmit {
                        saveTitle()
                        titleFocused = false
                        // Return goes on into the page, as it does from a title
                        // in Notion and ChatGPT's Pages.
                        formatting.run(.focus)
                    }
                    .task(id: titleDraft) {
                        guard titleFocused else { return }
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        saveTitle()
                    }
            } else {
                // The same shape as the Docs-list row: a button that a click
                // activates and a press-and-move drags, carrying the doc and
                // the Docs pane on one provider, so the title drags wherever
                // the row does.
                Button {
                    if !isReadOnly { isEditingTitle = true }
                } label: {
                    Text(titleDraft.isEmpty ? "Title" : titleDraft)
                        .font(Self.titleFont)
                        .lineLimit(1)
                        .foregroundStyle(titleDraft.isEmpty ? .tertiary : .primary)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Title")
                .accessibilityValue(titleDraft)
                .accessibilityHint("Click to rename. Drag into a chat to add this page to it.")
                .onDrag {
                    StudioDragVisibility.shared.begin(centerTab: .notepad, artifactID: artifact.id)
                    return studioArtifactDragProvider(for: artifact)
                }
            }
        }
        .modifier(inset)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    /// A daily note's title row: its day, which is its name until it is
    /// clicked and renamed (2026-10-07; emptying the name gives the day back),
    /// then ‹ and › to step a day back or forward — opening that
    /// day's note, made if it does not exist yet — and Today while the note
    /// is another day's (docs/notes-graph-design.md, "Daily Notes"). Since
    /// 2026-10-06 Today, ‹ and › show while the pointer is over the row, in
    /// slots that keep their size (the product owner: "cleaner and fewer buttons");
    /// ⇧⌘D still opens today. The day drags as a doc's title does, into a
    /// chat or to the center edge.
    private func dailyNoteHeader(dayKey: String, inset: ArtifactPageInset) -> some View {
        // The hover lives in its own view, so pointing at the row never
        // re-runs the editor's body.
        NotebookHoverRow(isActive: true) { isHovered in
            dailyNoteHeaderRow(dayKey: dayKey, revealsControls: isHovered, inset: inset)
        }
    }

    private func dailyNoteHeaderRow(dayKey: String, revealsControls: Bool, inset: ArtifactPageInset) -> some View {
        let previous = DailyNoteDays.dayKey(dayKey, offsetBy: -1)
        let next = DailyNoteDays.dayKey(dayKey, offsetBy: 1)
        return HStack(spacing: 2) {
            if isEditingTitle {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Self.titleFont)
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .focused($titleFocused)
                    .onAppear { titleFocused = true }
                    .onSubmit {
                        saveTitle()
                        titleFocused = false
                    }
                    .task(id: titleDraft) {
                        guard titleFocused else { return }
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        saveTitle()
                    }
            } else {
                // Clicking the day renames the note, as a doc's title does;
                // a press-and-move drags it.
                Button {
                    if !isReadOnly { isEditingTitle = true }
                } label: {
                    Text(titleDraft.isEmpty ? (DailyNote.title(forDayKey: dayKey) ?? artifact.title) : titleDraft)
                        .font(Self.titleFont)
                        .lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint("Click to rename. Drag into a chat to add this page to it.")
                .onDrag {
                    StudioDragVisibility.shared.begin(centerTab: .notepad, artifactID: artifact.id)
                    return studioArtifactDragProvider(for: artifact)
                }
            }
            if !DailyNoteDays.isToday(dayKey) {
                Button {
                    openDailyNote(DailyNoteDays.today())
                } label: {
                    Text("Today")
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help("Today's daily note")
                .accessibilityLabel("Today")
                .opacity(revealsControls ? 1 : 0)
            }
            Group {
                dayStepButton(systemImage: "chevron.left", label: "Previous day", target: previous)
                dayStepButton(systemImage: "chevron.right", label: "Next day", target: next)
            }
            .opacity(revealsControls ? 1 : 0)
        }
        .modifier(inset)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private func dayStepButton(systemImage: String, label: String, target: String?) -> some View {
        Button {
            if let target { openDailyNote(target) }
        } label: {
            Image(systemName: systemImage)
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
        .disabled(target == nil)
        .help(target.flatMap { DailyNote.title(forDayKey: $0) }.map { "\(label): \($0)" } ?? label)
        .accessibilityLabel(label)
    }

    /// Another day's note, in this window's Docs.
    private func openDailyNote(_ dayKey: String) {
        Task { await vm.openDailyNote(dayKey: dayKey, in: windowState) }
    }

    /// What the highlighted passage stands on.
    ///
    /// This is the shelf's only job. It used to list everything the doc stood on —
    /// every chip anywhere in it, plus every source its Notebooks lent it — which
    /// made it a pile that answered a question nobody was asking, and a permanent
    /// band under the page. Sources attached to a passage are invisible in the
    /// prose, so the moment they are worth showing is the moment a writer selects
    /// the passage, and this is where they appear.
    ///
    /// The doc-wide list still exists, as `documentContextSourceIDs`, because a
    /// question about a passage that stands on nothing has to fall back to
    /// something. It is no longer drawn.
    /// The doc as a page, or why it cannot be shown yet.
    @ViewBuilder
    private var pageSurface: some View {
        if let pageHTML {
            ArtifactPageWebView(
                html: pageHTML,
                // A team Doc reads without a caret and without Edit; the
                // member's draft has both.
                editing: isReadOnly || snapshot == nil ? nil : DocPageEditing(review: pageEdit?.review),
                onAddToLibrary: { href in
                    Task {
                        let status = await vm.addReferenceToLibrary(href, teamID: vm.referenceLibraryTeamID(for: artifact))
                        switch status.state {
                        case .inLibrary: vm.showToast(artifact.teamID == nil ? "Added to your library" : "Added to the team library")
                        case .failed, .requestable: vm.showToast(status.message ?? "The source could not be added.")
                        // A standing request, or one this Mac can fulfil, is the
                        // card's business; the page surface has nothing to add.
                        case .absent, .adding, .requested, .fulfillable: break
                        }
                    }
                },
                onEditMessage: handlePageEditMessage,
                sourceForLines: { start, end in
                    isReadOnly ? nil : DocPagePassage.passage(markdown: draft, start: start, end: end)
                },
                findState: findState,
                findRevision: findState.searchRevision
            )
        } else if let pageError {
            VStack(spacing: 10) {
                Text(pageError)
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                Button("Try Again") { Task { await renderPage() } }
                    .buttonStyle(.hoverWash)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Rendering the page…")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the page draws: the proposal under review while there is one, else
    /// the draft.
    private var pageMarkdown: String { pageEdit?.candidate ?? draft }

    /// The page reads block references, title links and tags as their words,
    /// as the published page does — but line for line
    /// (`docGraphResolvedMarkdownKeepingLines`: an embed reads as its block's
    /// own words on its own line), because the page's Edit mode maps each
    /// block it draws back to the draft's lines. A resolution that would
    /// still move a line leaves the page on the draft as written.
    private func pageMarkdownForReaders(_ markdown: String) async -> String {
        guard NotesGraphHostText.mayHoldGraphMarkup(markdown),
              let resolved = try? await vm.storage.docGraphResolvedMarkdownKeepingLines(markdown, teamID: graphTeamID)
        else { return markdown }
        return NotesGraphHostText.lineKeepingResolution(original: markdown, resolved: resolved)
    }

    private func renderPage() async {
        pageError = nil
        do {
            let markdown = await pageMarkdownForReaders(pageMarkdown)
            // A link to another doc that has a page of its own becomes a link
            // to that page, as it does on foreverlm.com; the statuses the Docs
            // list already holds say which docs those are.
            let html = try await DocPublishing.page(
                title: titleDraft.isEmpty ? artifact.title : titleDraft,
                markdown: markdown,
                pageURL: publishedStatus?.url,
                publishedAt: publishedStatus?.publishedAt,
                docLinks: vm.publishedDocStatuses.mapValues { $0.url.absoluteString }
            )
            guard chrome.showsPage else { return }
            pageHTML = html
        } catch {
            // A render superseded by a newer draft is cancelled, not failed: the
            // replacement is already on its way, and "cancelled" is not a page
            // error the writer can act on.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            guard chrome.showsPage else { return }
            pageHTML = nil
            pageError = error.localizedDescription
        }
    }

    /// The page's Edit mode asking. The block's lines name a passage of the
    /// draft; the model answers on the Edit-with-AI route; the page is drawn
    /// again with the proposal in place; and only Keep writes.
    private func handlePageEditMessage(_ message: DocPageEditMessage) {
        guard !isReadOnly, snapshot != nil else { return }
        switch message {
        case .editRequested(let start, let end, let instruction, let selection):
            if let pageEdit, pageEdit.status == .working { return }
            let session = DocPageEditSession(start: start, end: end, instruction: instruction, selection: selection, original: draft)
            pageEdit = session
            performPageEdit(session)
        case .retry(let instruction):
            guard var session = pageEdit, session.status != .working else { return }
            session.instruction = instruction
            session.status = .working
            pageEdit = session
            performPageEdit(session)
        case .keep:
            guard var session = pageEdit, session.status == .proposed, let candidate = session.candidate else { return }
            draft = candidate
            nextSaveVersionReason = .assistantEdit
            session.status = .kept
            pageEdit = session
        case .discard:
            pageEdit = nil
        case .undo:
            guard let session = pageEdit, session.status == .kept, let candidate = session.candidate, draft == candidate else {
                pageEdit = nil
                return
            }
            draft = session.original
            if draft == snapshot?.markdown { nextSaveVersionReason = nil }
            pageEdit = nil
        case .sourceRequested:
            // Answered by the web view itself, from `sourceForLines`.
            break
        case .textEdited(let start, let end, let markdown):
            // The writer's own words, written as typing would be: no proposal
            // to review, only Undo for a moment.
            guard DocPagePassage.passage(markdown: draft, start: start, end: end) != nil else { return }
            let session = DocPageEditSession.kept(start: start, end: end, original: draft, markdown: markdown)
            guard let candidate = session.candidate else { return }
            draft = candidate
            pageEdit = session
        }
    }

    private func performPageEdit(_ session: DocPageEditSession) {
        Task {
            var updated = session
            guard let request = DocPagePassage.request(
                markdown: session.original,
                start: session.start,
                end: session.end,
                instruction: session.instruction,
                selection: session.selection,
                docTitle: titleDraft.isEmpty ? artifact.title : titleDraft
            ) else {
                updated.status = .failed("The page no longer matches this Page's text. Try again from the redrawn page.")
                if pageEdit?.id == session.id { pageEdit = updated }
                return
            }
            do {
                let proposal = try await vm.editDocPassageWithAI(request)
                updated.propose(proposal)
            } catch {
                updated.status = .failed(error.localizedDescription)
            }
            // A decision taken meanwhile (Discard, a new request) wins.
            guard pageEdit?.id == session.id, pageEdit?.status == .working else { return }
            pageEdit = updated
        }
    }

    @ViewBuilder
    private var referencesShelf: some View {
        if editorSelection.hasText {
            Divider()
            selectionChatsRow
            shelfRow
        }
    }

    /// The conversations that started on the selected passage.
    ///
    /// Same rule as the shelf: a chat anchored to a paragraph is invisible in
    /// the prose, so it appears the moment the writer selects that paragraph and
    /// nowhere else on the page. The doc-wide list stays in Discussion. Offsets
    /// are trusted only for the saved revision the page is showing; a draft
    /// with unsaved edits has moved its positions, so the quote decides instead.
    private var selectionChatLinks: [ArtifactChatLink] {
        guard editorSelection.hasText, !chatLinks.isEmpty else { return [] }
        let revision = hasUnsavedChanges ? "" : (snapshot?.revision ?? "")
        let range = min(editorSelection.from, editorSelection.to)..<max(editorSelection.from, editorSelection.to)
        return chatLinks.filter {
            $0.link.anchors(selection: range, selectedText: editorSelection.text, inRevision: revision)
        }
    }

    @ViewBuilder
    private var selectionChatsRow: some View {
        let links = selectionChatLinks
        if !links.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.tertiary)
                    .help("Chats that started on the selected passage")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(links) { entry in
                            ArtifactSelectionChatChip(
                                entry: entry,
                                open: { vm.requestResumeReviewSession(entry.session.id) },
                                forget: {
                                    Task {
                                        await vm.forgetArtifactChatLink(entry.link.id)
                                        chatLinks = await vm.artifactChatLinks(artifact.id)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 14)
            .padding(.top, 5)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chats about the selected passage")
        }
    }

    private var shelfRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "books.vertical")
                .zoomedSystemFont(size: 10, weight: .medium)
                .foregroundStyle(.tertiary)
                .help("What the selected passage stands on")

            if shelfSources.isEmpty {
                // A selected claim standing on nothing is worth saying plainly —
                // it is the one thing this row can tell a writer that the prose
                // cannot.
                Text("No sources linked to this passage yet")
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelfSources) { entry in
                            ArtifactShelfChip(
                                article: entry.article,
                                bookCoverPath: entry.bookCoverPath,
                                title: entry.title,
                                isMuted: mutedShelfSourceIDs.contains(entry.id),
                                toggle: {
                                    if mutedShelfSourceIDs.remove(entry.id) == nil {
                                        mutedShelfSourceIDs.insert(entry.id)
                                    }
                                },
                                open: { onOpenSource(entry.article.id) }
                            )
                        }
                    }
                }
            }

            // The verb on a row that is about one passage can only mean one
            // thing: attach a source to that passage.
            Button {
                groundingRequest = ArtifactGroundingRequest(
                    selectedText: editorSelection.text,
                    sourceIDs: editorSelection.groundedSourceIDs
                )
            } label: {
                Image(systemName: "plus.circle")
                    .zoomedSystemFont(size: 11, weight: .medium)
            }
            .buttonStyle(.hoverWash(inset: -3))
            .foregroundStyle(.secondary)
            .help("Attach a source to this passage")
        }
        .frame(height: 30)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var documentSurface: some View {
        @Bindable var formatting = formatting
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isDownloadingFromICloud {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading from iCloud…")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshot != nil {
            ArtifactMarkdownEditorView(
                markdown: $draft,
                saveRequestID: 0,
                publicationRequestID: publicationRequestID,
                aiEditOpenRequestID: chrome.aiEditOpenRequestID,
                docTitle: titleDraft,
                sourceInsertion: $sourceInsertion,
                onSourceDragTargeted: { isSourceDropTargeted = $0 },
                // A drop on the page attaches to the passage under the pointer.
                // The editor's web view receives the drag itself, because
                // WebKit would otherwise claim it — see `ArtifactEditorWebView`.
                onSourceDrop: { transfers, location in
                    guard !isReadOnly else { return }
                    let citations = transfers.flatMap(citations(from:))
                    guard !citations.isEmpty else { return }
                    sourceInsertion = ArtifactSourceInsertion(
                        citations: citations,
                        editorLocation: location
                    )
                },
                // A doc or Notebook dropped on the page is written where it
                // landed as a titled link. The library's current name wins
                // over the one the drag carried, and a doc dropped on itself
                // writes nothing — a page pointing at itself is not a link.
                onLinkDrop: { transfers, location in
                    guard !isReadOnly else { return }
                    let links = transfers.compactMap(pageLink(for:))
                    guard !links.isEmpty else { return }
                    linkInsertion = ArtifactLinkInsertion(links: links, editorLocation: location)
                },
                linkInsertion: $linkInsertion,
                // A doc opens in this window's Docs. A day's link opens its
                // daily note, made when the day has none yet — the one write
                // opening a link does (docs/notes-graph-design.md).
                onOpenLink: { link in
                    Task {
                        if case .doc(let id) = link {
                            if let day = DailyNote.dayKey(ofID: id), !vm.artifacts.contains(where: { $0.id == id }) {
                                await vm.openDailyNote(dayKey: day, in: windowState)
                            } else {
                                await vm.openDoc(id, revealing: nil, in: windowState)
                            }
                        } else {
                            await vm.open(link)
                        }
                    }
                },
                linkTargets: linkTargets,
                referenceStatuses: referenceStatuses,
                onReferencesChange: { hrefs in
                    referenceHrefs = hrefs
                    Task { await refreshReferenceStatuses() }
                },
                onMarginColumnChange: { hasMarginColumn = $0 },
                // Add to Sources on a card. The card waits while the import
                // runs; only a card still waiting hears the answer, so a doc
                // that moved on in the meantime is not written over.
                onAddReference: { href in
                    referenceStatuses[href] = .adding
                    Task {
                        let teamID = vm.referenceLibraryTeamID(for: artifact)
                        var status = await vm.addReferenceToLibrary(href, teamID: teamID)
                        // On a team Doc an import that did not land is not the
                        // end: a teammate may hold the source. The card offers
                        // to ask them (docs/teams-design.md, decision 14).
                        if status.state == .failed, teamID != nil {
                            status = .requestable(status.message ?? "The source could not be added.")
                        }
                        if referenceStatuses[href] == .adding { referenceStatuses[href] = status }
                    }
                },
                onRequestReference: { href in
                    guard let teamID = vm.referenceLibraryTeamID(for: artifact) else { return }
                    referenceStatuses[href] = .adding
                    Task {
                        let status = await vm.requestShare(href, teamID: teamID, artifactID: artifact.id, title: referenceStatuses[href]?.title)
                        if referenceStatuses[href] == .adding { referenceStatuses[href] = status }
                    }
                },
                onFulfilReference: { href, requestID in
                    // Answering copies the source into the team: the first
                    // time, the learner affirms they may share it.
                    SharingRightsPrompt.shared.askIfNeeded {
                        referenceStatuses[href] = .adding
                        Task {
                            var status: ArtifactReferenceStatus = .failed("The request could not be answered.")
                            if let request = await vm.fulfilShareRequest(requestID), let copy = request.fulfilledSourceID {
                                status = .inLibrary(sourceID: copy)
                            }
                            if referenceStatuses[href] == .adding { referenceStatuses[href] = status }
                        }
                    }
                },
                // The check on a card opens the source beside the doc, the way
                // the References shelf does.
                onOpenSource: { sourceID in
                    Task { await vm.openLinkedSourceInReader(sourceID, beside: .notepad) }
                },
                attachmentDataURLs: attachmentDataURLs,
                attachmentInsertion: $attachmentInsertion,
                groundingAttachment: $groundingAttachment,
                formatRequest: $formatting.request,
                pageMaxWidth: pageWidthPreference.maxWidth,
                showsMarginCards: showsMarginCardsPreference,
                isEditable: !isReadOnly,
                foldDocumentID: artifact.id,
                notesGraph: notesGraph.bridge,
                findState: findState,
                findRevision: findState.searchRevision,
                onSave: save,
                onPublication: receivePublication,
                onRequestChat: { openChat(about: $0) },
                onRequestComment: { selection in
                    editorSelection = selection
                    pendingCommentSelection = selection
                    chrome.isCommentsVisible = true
                },
                onRequestGrounding: { request in groundingRequest = request },
                onRequestAIEdit: { request in try await vm.editDocPassageWithAI(request.edit) },
                // Image in the slash menu: the file picker for a picture.
                onRequestImage: { isImportingImage = true },
                // A screenshot pasted, a picture dropped: kept like a picked file,
                // one after another, and the temporary copies removed.
                onImageFiles: { files in
                    guard !isReadOnly else { return }
                    Task {
                        for file in files {
                            await insertImage(from: file)
                            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                        }
                    }
                },
                // Generate image: drawn on the account's image model and kept in
                // this doc's Attachments; the editor writes it at the caret.
                onRequestImageGeneration: { [artifactID = artifact.id] request in
                    try await vm.generateDocImage(prompt: request.prompt, artifactID: artifactID)
                },
                onGeneratedImageInserted: { image in
                    attachmentDataURLs[image.token] = image.dataURL
                },
                // A Prompt block's Chat about this: Chat opens beside the page
                // with the prompt's words waiting, unsent, in the composer.
                onRequestPrompt: { text in openChat(withPrompt: text) },
                // File in the slash menu: any file, kept in this page's
                // Attachments and linked at the caret.
                onRequestFile: { await attachFile() },
                // Save file… on a link to an attached file.
                onOpenAttachment: { request in
                    Task { await saveAttachment(request) }
                },
                onSelectionChange: { selection in
                    editorSelection = selection
                    formatting.activeFormats = selection.activeFormats
                },
                onError: { chrome.errorMessage = $0 }
            )
            .id(chrome.reloadGeneration)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // A source added or removed anywhere — the sidebar, an assistant,
            // another Mac through sync — changes what the cards should say.
            .onChange(of: vm.articles.count) { _, _ in
                Task { await refreshReferenceStatuses() }
            }
            // A request made, answered or declined anywhere in the team changes
            // what a team Doc's cards offer.
            .onChange(of: vm.openShareRequestsByTeamID) { _, _ in
                Task { await refreshReferenceStatuses() }
            }
            .overlay {
                if isSourceDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        } else {
            ContentUnavailableView(
                "Could not open page",
                systemImage: "exclamationmark.triangle",
                description: Text(chrome.errorMessage ?? "The page is unavailable.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Ask the library about the doc's reference cards. A card whose import is
    /// still running keeps its wait — that import answers for it — unless the
    /// library already reports the source, which is the answer either way.
    private func refreshReferenceStatuses() async {
        let hrefs = referenceHrefs
        guard !hrefs.isEmpty else {
            referenceArtworkTask?.cancel()
            referenceStatuses = [:]
            return
        }
        let teamID = vm.referenceLibraryTeamID(for: artifact)
        var fresh = await vm.referenceLibraryStatuses(for: hrefs, teamID: teamID)
        // On a team Doc a source the team lacks may already be asked for: the
        // card shows the standing request, and Share when this Mac holds it.
        if let teamID {
            for href in hrefs where fresh[href]?.state == .absent {
                guard let request = vm.openShareRequest(teamID: teamID, url: href) else { continue }
                fresh[href] = vm.canFulfil(request) ? .fulfillable(request) : .requested(request)
            }
        }
        for (href, status) in referenceStatuses {
            if status.state == .adding, fresh[href]?.state != .inLibrary {
                fresh[href] = .adding
            } else if status.state == .requestable, fresh[href]?.state == .absent {
                // The offer to ask stands until the library or a request answers.
                fresh[href] = status
            } else if let answer = fresh[href], answer.state == status.state, answer.sourceID == status.sourceID {
                // The same answer as before keeps the picture already resolved
                // for it, so a library change elsewhere does not blank every tile.
                fresh[href] = status
            }
        }
        referenceStatuses = fresh
        referenceArtworkTask?.cancel()
        referenceArtworkTask = Task { await resolveReferenceArtwork(order: hrefs) }
    }

    /// The cards' pictures, after the answers: the library's own artwork for a
    /// saved source, a link preview for one the library does not hold. Resolved
    /// in the doc's order, a few at a time, and handed over a batch at a time —
    /// every batch re-sends the whole map to the editor, so one message per
    /// card would be the wrong shape for a report with a hundred and fifty. The
    /// library's pictures come first: they are on disk and quick, and the
    /// previews wait on the network.
    private func resolveReferenceArtwork(order hrefs: [String]) async {
        let pending = hrefs.compactMap { href -> (String, ArtifactReferenceStatus)? in
            guard let status = referenceStatuses[href], status.kind == nil, status.state != .adding else { return nil }
            return (href, status)
        }
        guard !pending.isEmpty else { return }
        let saved = pending.filter { $0.1.state == .inLibrary }
        let unsaved = pending.filter { $0.1.state != .inLibrary }

        let articlesByID = Dictionary(vm.articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for batch in Self.batches(of: saved, size: 8) {
            let resolved = await withTaskGroup(of: (String, ArtifactReferenceStatus).self) { group in
                for (href, status) in batch {
                    group.addTask {
                        var decorated = status
                        if let id = status.sourceID, let article = articlesByID[id] {
                            decorated.kind = article.sourceType.rawValue
                            decorated.title = article.title
                            decorated.detail = ReferenceCardArtwork.libraryDetail(for: article)
                            decorated.thumbnailURL = await ReferenceCardArtwork.libraryThumbnailURL(for: article)
                        } else {
                            decorated.kind = "page"
                        }
                        return (href, decorated)
                    }
                }
                var collected: [String: ArtifactReferenceStatus] = [:]
                for await (href, decorated) in group { collected[href] = decorated }
                return collected
            }
            guard !Task.isCancelled else { return }
            applyReferenceArtwork(resolved)
        }

        for batch in Self.batches(of: unsaved, size: 6) {
            let resolved = await withTaskGroup(of: (String, ArtifactReferenceStatus).self) { group in
                for (href, status) in batch {
                    group.addTask {
                        let preview = await ReferenceLinkPreviews.shared.preview(for: href)
                        var decorated = status
                        decorated.kind = preview.kind
                        decorated.thumbnailURL = preview.imageURL
                        decorated.iconURL = preview.iconURL
                        decorated.title = preview.title
                        decorated.detail = preview.detail
                        return (href, decorated)
                    }
                }
                var collected: [String: ArtifactReferenceStatus] = [:]
                for await (href, decorated) in group { collected[href] = decorated }
                return collected
            }
            guard !Task.isCancelled else { return }
            applyReferenceArtwork(resolved)
        }
    }

    /// A picture lands only on a card whose answer is still the one it was
    /// resolved for; a card that was added or removed in the meantime keeps the
    /// answer that arrived since.
    private func applyReferenceArtwork(_ resolved: [String: ArtifactReferenceStatus]) {
        for (href, decorated) in resolved {
            guard let current = referenceStatuses[href],
                  current.state == decorated.state,
                  current.sourceID == decorated.sourceID else { continue }
            referenceStatuses[href] = decorated
        }
    }

    private static func batches<Element>(of elements: [Element], size: Int) -> [[Element]] {
        stride(from: 0, to: elements.count, by: size).map { Array(elements[$0..<min($0 + size, elements.count)]) }
    }

    private func openChatAboutSelection() {
        openChat(about: editorSelection)
    }

    /// The editor's publication HTML, asked for by Export ▸ HTML… or PDF…:
    /// the page's title goes in as its title, and as its heading unless the
    /// body opens with it, then the file is written where the writer says.
    private func receivePublication(_ editorHTML: String) {
        guard let format = pendingPublicationExport else { return }
        pendingPublicationExport = nil
        let title = titleDraft.isEmpty ? artifact.title : titleDraft
        let html = PageExport.titledHTML(editorHTML, title: title, bodyOpensWithTitle: titleFollowsHeading)
        Task {
            guard let url = await PageExport.chooseDestination(title: title, format: format) else { return }
            do {
                let data = format == .pdf ? try await PageExport.pdf(fromHTML: html) : Data(html.utf8)
                try await PageExport.write(data, to: url)
                vm.showToast("Exported \(url.lastPathComponent)")
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    /// The page as its side chat is told about it: the stored revision, not the
    /// unsaved draft, which is the text `read_doc` returns and what
    /// `attachDocToChat` keeps to.
    private func sideChatPage(_ snapshot: ArtifactMarkdownSnapshot?) -> PageSideChatPage {
        PageSideChatPage(
            artifactID: artifact.id,
            title: artifact.title,
            revision: snapshot?.revision ?? "",
            notebookID: artifact.homeNotebookID,
            attachment: snapshot.map { ChatDocAttachment(snapshot: $0) }
        )
    }

    /// A chat about the page as a whole, for the side chat: the page rides
    /// along by identity, on the sources it stands on. The page is read from
    /// storage when the editor has not loaded it, so the chat is never opened
    /// without the page in its context.
    @MainActor
    private func openWholePageSideChat(_ request: PageSideChatWholePageRequest) async {
        let stored: ArtifactMarkdownSnapshot?
        if let snapshot {
            stored = snapshot
        } else {
            stored = try? await vm.artifactMarkdown(artifact.id)
        }
        chrome.sideChatRequest = PageSideChatOpening(
            page: sideChatPage(stored),
            sourceIDs: documentContextSourceIDs,
            passage: nil,
            draft: nil,
            joinsOpenChat: request.intent == .addToChat
        )
    }

    private func openChat(about selection: ArtifactEditorSelection) {
        // A highlighted passage is the sharpest question; without one, the
        // section the caret sits in is what the writer means by "here".
        let framing = selection.hasText ? selection.text : selection.sectionText
        // A window with a side chat over its pages opens the card instead of
        // docking the Chat pane, with the same passage, sources, page and
        // Notebook (docs/pages-side-chat-design.md).
        if chrome.hostsSideChat {
            let sourceIDs = chatSourceIDs(for: selection)
            chrome.sideChatRequest = PageSideChatOpening(
                page: sideChatPage(snapshot),
                sourceIDs: sourceIDs,
                passage: StudioViewModel.notepadSelectionRequest(
                    noteTitle: artifact.title,
                    sectionTitle: selection.sectionTitle,
                    selectedText: framing,
                    sourceIDs: sourceIDs,
                    artifactID: artifact.id,
                    artifactRevision: snapshot?.revision ?? "",
                    artifactNotebookID: artifact.homeNotebookID,
                    selectionRange: selection.hasText ? selection.from..<selection.to : nil,
                    contextExcerpt: selection.hasText ? selection.sectionText : nil,
                    artifactAttachment: snapshot.map { ChatDocAttachment(snapshot: $0) }
                ),
                draft: nil
            )
            return
        }
        vm.requestNotepadChat(
            noteTitle: artifact.title,
            sectionTitle: selection.sectionTitle,
            selectedText: framing,
            sourceIDs: chatSourceIDs(for: selection),
            artifactID: artifact.id,
            artifactRevision: snapshot?.revision ?? "",
            artifactNotebookID: artifact.homeNotebookID,
            selectionRange: selection.hasText ? selection.from..<selection.to : nil,
            contextExcerpt: selection.hasText ? selection.sectionText : nil,
            // The stored revision, not the unsaved draft: that is the text
            // `read_doc` returns, the same contract `attachDocToChat` keeps.
            artifactAttachment: snapshot.map { ChatDocAttachment(snapshot: $0) }
        )
    }

    /// Chat about the page as a whole, opened from a Prompt block: no passage is
    /// quoted, the page rides along so Chat can read it, its Notebook frames
    /// the chat, and the prompt's words wait under the composer to be edited
    /// and sent by the writer.
    private func openChat(withPrompt text: String) {
        if chrome.hostsSideChat {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            chrome.sideChatRequest = PageSideChatOpening(
                page: sideChatPage(snapshot),
                sourceIDs: documentContextSourceIDs,
                passage: nil,
                draft: words.isEmpty ? nil : words
            )
            return
        }
        vm.requestNotepadChat(
            noteTitle: artifact.title,
            selectedText: "",
            sourceIDs: documentContextSourceIDs,
            artifactID: artifact.id,
            artifactRevision: snapshot?.revision ?? "",
            artifactNotebookID: artifact.homeNotebookID,
            selectionRange: nil,
            contextExcerpt: nil,
            // The stored revision, as `openChat(about:)` attaches it.
            artifactAttachment: snapshot.map { ChatDocAttachment(snapshot: $0) },
            draft: text
        )
    }

    private struct ShelfSource: Identifiable {
        /// The grounding reference this row stands for, and its identity: a source
        /// id, or `book:<book-id>`.
        let id: String
        /// The source whose reader this row opens. For a book that is its first
        /// chapter, which is neither what the row is called nor what it looks like.
        let article: StudioArticle
        /// The book's cover, for a `book:` row. A chapter's own art is a figure
        /// from inside it, so a whole-book row draws this instead.
        let bookCoverPath: String?
        let title: String
    }

    /// What the highlighted passage stands on, one row per thing the writer
    /// attached or named.
    ///
    /// One row per *reference*, not per resolved source: a book is one thing to
    /// stand on, so attaching "How Life Works" draws one chip called that. It
    /// expands into its chapters for the question Chat receives, which is why the
    /// count here and the ids sent there legitimately differ.
    private var shelfSources: [ShelfSource] {
        var seen = Set<String>()
        var entries: [ShelfSource] = []
        for reference in editorSelection.citedSourceIDs {
            guard seen.insert(reference).inserted else { continue }
            if reference.hasPrefix(StudioViewModel.notepadGroundingBookPrefix) {
                let bookID = String(reference.dropFirst(StudioViewModel.notepadGroundingBookPrefix.count))
                guard let representative = vm.bookChapterArticlesInOrder(for: bookID).first else { continue }
                entries.append(ShelfSource(
                    id: reference,
                    article: representative,
                    bookCoverPath: vm.bookCoverPaths[bookID],
                    title: vm.bookDisplayName(bookID)
                ))
            } else if let article = vm.articlesById[reference] {
                entries.append(ShelfSource(
                    id: reference,
                    article: article,
                    bookCoverPath: nil,
                    title: article.title
                ))
            }
        }
        return entries
    }

    /// The grounding a question inherits from where it was asked.
    ///
    /// Highlighting two passages and asking about them has to put those sources in
    /// the chat and nothing else — a doc's whole shelf standing behind every
    /// question is how a chat ends up answering from a source the writer never
    /// pointed at. The doc-wide list is the fallback for a passage that stands on
    /// nothing of its own, where the doc itself is the only grounding there is.
    private func chatSourceIDs(for selection: ArtifactEditorSelection) -> [String] {
        let cited = vm.expandedGroundingSourceIDs(
            selection.citedSourceIDs.filter { !mutedShelfSourceIDs.contains($0) }
        )
        return cited.isEmpty ? documentContextSourceIDs : cited
    }

    /// Everything the doc stands on: every source referenced anywhere in it, then
    /// every source its Notebooks lend it. No longer drawn anywhere — the shelf
    /// shows the selected passage — but still the fallback grounding.
    private var documentContextSourceIDs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for sourceID in vm.sourceIDsReferencedByNotepadMarkdown(draft) {
            guard vm.articlesById[sourceID] != nil, seen.insert(sourceID).inserted else { continue }
            ordered.append(sourceID)
        }
        for notebookID in artifact.linkedNotebookIDs {
            for sourceID in vm.notebook(id: notebookID)?.approvedSourceIDs ?? [] {
                guard vm.articlesById[sourceID] != nil, seen.insert(sourceID).inserted else { continue }
                ordered.append(sourceID)
            }
        }
        return ordered.filter { !mutedShelfSourceIDs.contains($0) }
    }

    @MainActor
    private func load() async {
        isLoading = true
        isDownloadingFromICloud = false
        chrome.errorMessage = nil
        while !Task.isCancelled {
            do {
                let loaded = await vm.keepingDocPictures(of: try await vm.artifactMarkdown(artifact.id))
                snapshot = loaded
                draft = loaded.markdown
                titleFollowsHeading = ArtifactMarkdownTitle.names(artifact.title, in: loaded.markdown)
                titleRowHeld = !titleFollowsHeading
                // A page made a moment ago opens on its name, as ChatGPT's and
                // Notion's do: type it, press Return, and the caret is in the
                // page. Left empty, it keeps the placeholder and still takes its
                // first heading.
                if !isReadOnly, dailyNoteDayKey == nil,
                   loaded.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   ArtifactPlaceholderTitle.isPlaceholder(artifact.title) {
                    titleDraft = ""
                    isEditingTitle = true
                }
                attachmentDataURLs = try await vm.artifactAttachmentDataURLs(
                    artifact.id,
                    markdown: loaded.markdown
                )
                comments = try await vm.artifactComments(artifact.id)
                chatLinks = await vm.artifactChatLinks(artifact.id)
                heldRemoteMarkdown = await vm.artifactHeldRemoteMarkdown(artifact.id)
                isDownloadingFromICloud = false
                isLoading = false
                openNotesGraph(revision: loaded.revision)
                return
            } catch ArtifactError.downloading(_) {
                snapshot = nil
                isLoading = false
                isDownloadingFromICloud = true
                guard let documentURL = await vm.artifactFileURL(artifact.id) else { return }
                await ICloudFileChangeMonitor.waitForChangeOrBackstop(
                    at: documentURL.deletingLastPathComponent(),
                    timeout: .seconds(1)
                )
            } catch {
                snapshot = nil
                isDownloadingFromICloud = false
                chrome.errorMessage = error.localizedDescription
                isLoading = false
                return
            }
        }
    }

    /// The doc's graph, read once its body is here: the editor learns the
    /// block texts it references, which titles name pages, how often its own
    /// blocks are referenced and what points at it, and its requests are
    /// answered (docs/notes-graph-design.md).
    private func openNotesGraph(revision: String) {
        if !vm.hasLoadedIdeasOnce {
            // `[[` offers the Ideas, and a doc's Linked References list the
            // Ideas linked to it; the library heard about them changes the
            // signature, and the graph is read again.
            Task { await vm.loadIdeas() }
        }
        notesGraph.open(
            docID: artifact.id,
            pageID: vm.teamArtifactID(forDraft: artifact.id) ?? artifact.id,
            teamID: graphTeamID,
            vm: vm,
            window: windowState,
            librarySignature: notesGraphLibrarySignature,
            revision: revision,
            draft: { draft },
            replaceInDraft: { old, new in
                let replaced = draft.replacingOccurrences(of: old, with: new)
                if replaced != draft { draft = replaced }
            },
            // A page made from the editor opens in this pane: the draft is
            // written first, so the link to it is kept.
            flushDraft: { try await flushDraft() }
        )
    }

    /// A block asked to be shown in this doc: the editor shows it once it
    /// holds the doc. A published doc opens as its page, which has no blocks
    /// to flash, so the doc comes up in the editor for it.
    private func applyBlockReveal() {
        guard let blockReveal, blockReveal.artifactID == artifact.id else { return }
        // Also keeps a page status arriving later from turning the pane to
        // the page (`publishedStatus`'s handler respects a chosen view).
        chrome.pagePresentationWasChosen = true
        if chrome.showsPage { chrome.showsPage = false }
        notesGraph.bridge.reveal(blockReveal)
    }

    /// The body on disk moved on — another writer's edit arrived through
    /// CloudKit, or this Mac's own save landed — and the editor follows it.
    ///
    /// `updatedAt` also advances for this editor's own body saves and for
    /// metadata-only changes such as a title edit, and rebuilding the WebView
    /// for either one would destroy its caret-anchored Source menu, so the
    /// revision is compared first. A clean draft simply takes the new body. A
    /// draft with unsaved typing is merged with it line by line, against the
    /// body this editor opened, so a teammate's paragraph and this writer's
    /// both stand; when both changed the same passage the writer's draft stays
    /// on screen and the other version is held for them to choose.
    @MainActor
    private func refreshBodyAfterArtifactUpdate() async {
        guard let openedSnapshot = snapshot,
              !isSaving,
              !isUpdatingTitle else { return }

        do {
            let latest = try await vm.artifactMarkdown(artifact.id)
            let held = await vm.artifactHeldRemoteMarkdown(artifact.id)
            if latest.revision != openedSnapshot.revision {
                let latestAttachmentURLs = try await vm.artifactAttachmentDataURLs(
                    artifact.id,
                    markdown: latest.markdown
                )
                // A save may have started while storage was being read; it
                // owns the revision then, and its completion comes back here.
                guard snapshot?.revision == openedSnapshot.revision,
                      !isSaving,
                      !isUpdatingTitle else { return }
                if !hasUnsavedChanges {
                    draft = latest.markdown
                } else {
                    switch ArtifactThreeWayMerge.merge(
                        base: openedSnapshot.markdown,
                        mine: draft,
                        theirs: latest.markdown
                    ) {
                    case .merged(let merged):
                        // Autosave carries the combined text back out.
                        draft = merged
                    case .conflict:
                        heldRemoteMarkdown = latest.markdown
                    }
                }
                snapshot = latest
                titleFollowsHeading = ArtifactMarkdownTitle.names(artifact.title, in: draft)
                attachmentDataURLs = latestAttachmentURLs
            }
            if let held, heldRemoteMarkdown == nil { heldRemoteMarkdown = held }
        } catch ArtifactError.downloading(_) {
            // Keep the intact local draft visible while iCloud materializes the
            // newer package. A later file-change event will advance updatedAt.
        } catch {
            chrome.errorMessage = error.localizedDescription
        }
    }

    /// Two versions of one passage, and only the writer can say which stands.
    /// Theirs is held off screen; Keep mine saves this draft over it, Use
    /// theirs takes it in place of the draft.
    @ViewBuilder
    private func heldVersionBanner(inset: ArtifactPageInset) -> some View {
        if heldRemoteMarkdown != nil {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text("Changed elsewhere while you were editing")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Use theirs") { resolveHeldRemoteVersion(keepMine: false) }
                    .buttonStyle(.hoverWash)
                Button("Keep mine") { resolveHeldRemoteVersion(keepMine: true) }
                    .buttonStyle(.hoverWash)
            }
            .modifier(inset)
            .padding(.vertical, 6)
        }
    }

    private func resolveHeldRemoteVersion(keepMine: Bool) {
        guard let held = heldRemoteMarkdown else { return }
        heldRemoteMarkdown = nil
        if !keepMine { draft = held }
        Task { await vm.discardArtifactHeldRemoteMarkdown(artifact.id) }
        save(draft)
    }

    /// Publish this draft to its team: the text goes through first, so the
    /// stored body is what publishes.
    @MainActor
    private func publishDraft(overwrite: Bool) async {
        do {
            try await flushDraft()
            try await vm.publishTeamDocDraft(artifact.id, overwrite: overwrite)
        } catch ArtifactError.conflict {
            chrome.showDraftPublishConflict = true
        } catch {
            chrome.errorMessage = error.localizedDescription
        }
    }

    private func save(_ markdown: String) {
        guard let snapshot, markdown != snapshot.markdown else { return }
        if isSaving {
            saveQueued = true
            return
        }
        isSaving = true
        chrome.errorMessage = nil
        let versionReason = nextSaveVersionReason ?? .learnerEdit
        nextSaveVersionReason = nil
        Task {
            do {
                let saved = try await vm.saveArtifactMarkdown(
                    artifactID: artifact.id,
                    markdown: markdown,
                    expectedRevision: snapshot.revision,
                    versionReason: versionReason
                )
                self.snapshot = saved
                if draft == markdown { draft = saved.markdown }
                await saveInferredTitleIfNeeded(from: saved.markdown)
            } catch ArtifactError.conflict {
                // Another writer's body landed between this draft's snapshot
                // and its save. Merge against what was opened, then save the
                // result; `draft` already holds the newest typing, so a save
                // queued behind this one has nothing more to add.
                isSaving = false
                saveQueued = false
                await refreshBodyAfterArtifactUpdate()
                if hasUnsavedChanges, heldRemoteMarkdown == nil { save(draft) }
                return
            } catch {
                chrome.errorMessage = error.localizedDescription
            }
            isSaving = false
            if saveQueued {
                saveQueued = false
                // The draft as it is now. Replaying the text the queued request
                // carried set the draft back to it, and the editor with it
                // (`setMarkdown`): words typed while the first save was out
                // vanished and the caret jumped.
                save(draft)
            }
        }
    }

    /// Write the draft through now and wait for it, where `save(_:)` schedules
    /// and returns. Used before the doc changes kind: a conversion sends the
    /// stored body, so the stored body has to be the page.
    private func flushDraft() async throws {
        // The page's text as it stands, not the draft, which trails typing by
        // the editor's pause: the buttons that call this (Share, Duplicate,
        // Restore, Convert) never take focus from the page, so nothing has
        // told the pane about the last words yet.
        try? await notesGraph.bridge.syncMarkdownFromPage()
        // A save already in flight owns the revision; let it land first.
        while isSaving {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let snapshot, draft != snapshot.markdown else { return }
        isSaving = true
        defer { isSaving = false }
        let versionReason = nextSaveVersionReason ?? .learnerEdit
        nextSaveVersionReason = nil
        let saved = try await vm.saveArtifactMarkdown(
            artifactID: artifact.id,
            markdown: draft,
            expectedRevision: snapshot.revision,
            versionReason: versionReason
        )
        self.snapshot = saved
    }

    /// **Restore This Version**: the typing on screen is written first, so the
    /// version list keeps it; then the version is written over it, keeping
    /// what it replaces as a version, and the editor takes the restored text
    /// the way it takes a body another writer saved.
    @MainActor
    private func restoreVersion(_ version: PageVersion) async throws {
        try await flushDraft()
        guard let opened = snapshot else { throw ArtifactError.unavailable(artifact.title) }
        isSaving = true
        defer { isSaving = false }
        let restored = try await vm.restorePageVersion(
            artifact.id,
            version: version,
            expectedRevision: opened.revision
        )
        snapshot = restored
        draft = restored.markdown
        titleFollowsHeading = ArtifactMarkdownTitle.names(artifact.title, in: restored.markdown)
        if let urls = try? await vm.artifactAttachmentDataURLs(artifact.id, markdown: restored.markdown) {
            attachmentDataURLs = urls
        }
    }

    /// **Export ▸**. Markdown is the text on screen. HTML and PDF are the
    /// page as the editor draws it — its publication HTML, pictures inside —
    /// so the rendered page, which has no editor beneath it, hands the pane
    /// to the editor first.
    private func export(_ format: PageExportFormat) {
        let title = titleDraft.isEmpty ? artifact.title : titleDraft
        switch format {
        case .markdown:
            let markdown = draft
            Task {
                guard let url = await PageExport.chooseDestination(title: title, format: .markdown) else { return }
                do {
                    try await PageExport.write(Data(markdown.utf8), to: url)
                    vm.showToast("Exported \(url.lastPathComponent)")
                } catch {
                    vm.errorMessage = error.localizedDescription
                }
            }
        case .html, .pdf:
            guard snapshot != nil else { return }
            pendingPublicationExport = format
            if chrome.showsPage {
                chrome.pagePresentationWasChosen = true
                chrome.showsPage = false
                // The editor is made on this pass with the current request
                // id; a later bump is what it answers.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    publicationRequestID += 1
                }
            } else {
                publicationRequestID += 1
            }
        }
    }

    private func saveTitle() {
        let typed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emptying a daily note's title gives it its day back.
        let title = typed.isEmpty ? (dailyNoteDayKey.flatMap { DailyNote.title(forDayKey: $0) } ?? "") : typed
        guard !title.isEmpty else {
            titleDraft = artifact.title
            return
        }
        guard title != artifact.title else {
            titleDraft = title
            return
        }
        titleDraft = title
        // A name typed to match the heading folds the header into it.
        titleFollowsHeading = ArtifactMarkdownTitle.names(title, in: draft)
        isUpdatingTitle = true
        Task {
            await vm.updateArtifact(artifactID: artifact.id, title: title)
            isUpdatingTitle = false
        }
    }

    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .zoomedSystemFont(size: 9, weight: .semibold)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
            .padding(.horizontal, 2)
    }

    /// The conversations this doc's passages started.
    ///
    /// One row per passage, newest first, showing the words that were asked
    /// about rather than the chat's topic — the quote is what tells the writer
    /// which of five conversations about this doc is the one they want, and it
    /// stays readable after the paragraph it came from has been rewritten.
    @ViewBuilder
    private var chatLinksSection: some View {
        if !chatLinks.isEmpty {
            sidebarSectionLabel("Chats")
            ForEach(chatLinks) { entry in
                Button {
                    vm.requestResumeReviewSession(entry.session.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .zoomedSystemFont(size: 9)
                                .foregroundStyle(Color.accentColor)
                            Text(entry.displayTitle)
                                .zoomedSystemFont(size: 11, weight: .medium)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Text(entry.link.createdAt, style: .relative)
                                .zoomedSystemFont(size: 9)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.link.anchorQuote)
                            .zoomedSystemFont(size: 10)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.28))
                                    .frame(width: 2)
                            }
                        if !entry.link.sectionTitle.isEmpty {
                            Text(entry.link.sectionTitle)
                                .zoomedSystemFont(size: 9)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
                .buttonStyle(.plain)
                .help("Open the chat that started on this passage")
                .contextMenu {
                    OtherWindowMenuItem(.chat(entry.session.id))
                    Divider()
                    Button("Forget This Link") {
                        Task {
                            await vm.forgetArtifactChatLink(entry.link.id)
                            chatLinks = await vm.artifactChatLinks(artifact.id)
                        }
                    }
                }
                .accessibilityLabel("Chat \(entry.displayTitle), about: \(entry.link.anchorQuote)")
            }
        }
    }

    private var commentsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Discussion")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                if !comments.isEmpty {
                    Text("\(comments.filter { !$0.isResolved }.count)")
                        .zoomedSystemFont(size: 10, weight: .medium)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    chrome.isCommentsVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.hoverWash)
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    chatLinksSection
                    if !chatLinks.isEmpty && !comments.isEmpty {
                        sidebarSectionLabel("Comments")
                    }
                    ForEach(comments.filter { $0.parentCommentID == nil }) { comment in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(comment.authorDisplayName)
                                    .zoomedSystemFont(size: 10, weight: .semibold)
                                Spacer()
                                Text(comment.updatedAt, style: .relative)
                                    .zoomedSystemFont(size: 9)
                                    .foregroundStyle(.tertiary)
                            }
                            if !comment.anchorQuote.isEmpty {
                                Text(comment.anchorQuote)
                                    .zoomedSystemFont(size: 10)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .padding(.leading, 8)
                                    .overlay(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.28))
                                            .frame(width: 2)
                                    }
                            }
                            Text(comment.body)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(comment.isResolved ? .secondary : .primary)
                            Button(comment.isResolved ? "Reopen" : "Resolve") {
                                Task {
                                    do {
                                        try await vm.setArtifactCommentResolved(
                                            comment.id,
                                            resolved: !comment.isResolved
                                        )
                                        comments = try await vm.artifactComments(artifact.id)
                                    } catch {
                                        chrome.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(.hoverWash(tint: Color.accentColor))
                            .zoomedSystemFont(size: 9, weight: .medium)
                        }
                        .padding(11)
                        .background(
                            Color.primary.opacity(comment.isResolved ? 0.02 : 0.04),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                    }
                }
                .padding(10)
            }

            if let selection = pendingCommentSelection, selection.hasText {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(selection.text)
                        .zoomedSystemFont(size: 9)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    TextField("Add a comment…", text: $commentDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...5)
                        .onSubmit { addComment() }
                    HStack {
                        Spacer()
                        Button("Comment") { addComment() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func addComment() {
        guard let selection = pendingCommentSelection,
              let openedSnapshot = snapshot else { return }
        let body = commentDraft
        Task {
            do {
                if draft != openedSnapshot.markdown {
                    let saved = try await vm.saveArtifactMarkdown(
                        artifactID: artifact.id,
                        markdown: draft,
                        expectedRevision: openedSnapshot.revision
                    )
                    snapshot = saved
                }
                _ = try await vm.addArtifactComment(
                    artifactID: artifact.id,
                    body: body,
                    selection: selection
                )
                comments = try await vm.artifactComments(artifact.id)
                commentDraft = ""
                pendingCommentSelection = nil
            } catch {
                chrome.errorMessage = error.localizedDescription
            }
        }
    }

    /// File in the slash menu: the writer picks any file, and the page keeps a
    /// copy of it in its Attachments. Nil when they cancel or the file cannot
    /// be kept (over 25 MB, empty, a folder, a linked page); the reason is
    /// shown, and nothing is cut to fit.
    @MainActor
    private func attachFile() async -> ArtifactFileAttachment? {
        guard let url = await FilePanel.open({ panel in
            panel.message = "Choose a file to attach to this page"
            panel.prompt = "Attach"
        }).first else { return nil }
        do {
            return try await vm.importArtifactFile(url, artifactID: artifact.id)
        } catch {
            chrome.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Save file… on a link to an attached file: a copy goes where the writer
    /// chooses, under the name the link shows. A token that is not one this app
    /// wrote is refused before anything is read.
    @MainActor
    private func saveAttachment(_ request: ArtifactAttachmentOpenRequest) async {
        do {
            let source = try await vm.artifactAttachmentFileURL(artifact.id, token: request.token)
            let suggested = ArtifactFileAttachment.suggestedFileName(
                linkName: request.name,
                token: request.token,
                pageTitle: artifact.title
            )
            guard let destination = await FilePanel.save({ panel in
                panel.nameFieldStringValue = suggested
                panel.message = "Save a copy of this file"
            }) else { return }
            try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                try data.write(to: destination, options: .atomic)
            }.value
            vm.showToast("Saved \(destination.lastPathComponent)")
        } catch {
            vm.showToast("Could not save the file: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func insertImage(from url: URL) async {
        do {
            let attachment = try await vm.importArtifactImage(url, artifactID: artifact.id)
            let urls = try await vm.artifactAttachmentDataURLs(
                artifact.id,
                markdown: draft + "\n\n![](" + "foreverlm://attachment/" + attachment.token + ")"
            )
            attachmentDataURLs.merge(urls) { _, new in new }
            guard let dataURL = attachmentDataURLs[attachment.token] else {
                throw ArtifactBodyPackageError.missingAttachment(attachment.token)
            }
            attachmentInsertion = ArtifactAttachmentInsertion(
                token: attachment.token,
                altText: attachment.altText,
                dataURL: dataURL
            )
        } catch {
            chrome.errorMessage = error.localizedDescription
        }
    }

    /// A doc named by its first heading follows it. The placeholder title
    /// takes the first `# ` heading as the doc's name; a title that is the
    /// heading is renamed when the heading is; a heading deleted outright
    /// leaves the title standing and brings the header back.
    private func saveInferredTitleIfNeeded(from markdown: String) async {
        guard titleDraft == artifact.title, !titleFocused else { return }
        guard let heading = ArtifactMarkdownTitle.first(in: markdown) else {
            titleFollowsHeading = false
            return
        }
        if ArtifactMarkdownTitle.names(artifact.title, in: markdown) {
            titleFollowsHeading = true
            return
        }
        guard titleFollowsHeading || ArtifactPlaceholderTitle.isPlaceholder(artifact.title) else { return }
        titleFollowsHeading = true
        titleDraft = heading
        isUpdatingTitle = true
        await vm.updateArtifact(artifactID: artifact.id, title: heading)
        isUpdatingTitle = false
    }

}

enum ArtifactMarkdownTitle {
    /// The `# ` heading the body opens with, or nil when it opens with
    /// anything else. Reads no further than the first non-blank line, so it
    /// is cheap enough to ask of every draft.
    static func first(in markdown: String) -> String? {
        var start = markdown.startIndex
        while start < markdown.endIndex {
            let end = markdown[start...].firstIndex(of: "\n") ?? markdown.endIndex
            let trimmed = markdown[start..<end].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                guard trimmed.hasPrefix("# ") else { return nil }
                let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : String(title.prefix(500))
            }
            guard end < markdown.endIndex else { break }
            start = markdown.index(after: end)
        }
        return nil
    }

    /// Whether the body's first heading is the doc's title — trimmed and
    /// case-insensitive, the comparison the published page makes
    /// (`splitLeadingTitle`) before it lifts that heading into its header —
    /// so drawing both would say the name twice.
    static func names(_ title: String, in markdown: String) -> Bool {
        guard let heading = first(in: markdown) else { return false }
        return heading.lowercased() == title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension ArtifactEditor {

    /// What a link typed into this doc can point at: the other docs of the
    /// same library — a team Doc offers the team's docs, a doc in My Library
    /// offers My Library's, because a teammate cannot follow a link into a
    /// library they do not have — newest edit first, then the open Ideas (My
    /// Library's own, so not in a team's Doc), then the Notebooks, then the
    /// learner's recent chats (also My Library's own, for `@`). Archived
    /// and hidden docs stay out, and so does the doc itself; so do the daily
    /// notes, which the editor offers as days. The detail column says where
    /// a doc is filed, or that it is a draft.
    var linkTargets: [ArtifactPageLinkTarget] {
        let docs = ArtifactPageLinkTargets.docs(
            vm.artifacts,
            openDocID: artifact.id,
            teamID: artifact.teamID,
            isAudioOverview: { vm.isAudioOverview($0) },
            filedUnder: { $0.homeNotebookID.flatMap { vm.notebook(id: $0)?.title } ?? "" }
        )
        let ideas = graphTeamID == nil ? ArtifactPageLinkTargets.ideas(vm.ideas) : []
        let notebooks = vm.notebooks.map {
            ArtifactPageLinkTarget(link: .notebook($0.id), title: $0.title, detail: "Notebook")
        }
        // A teammate cannot open the learner's chats, so a team page offers none.
        let chats = graphTeamID == nil ? ArtifactPageLinkTargets.chats(vm.reviewSessionLinks) : []
        return docs + ideas + notebooks + chats
    }

    /// The link a dropped doc or Notebook becomes, named from the library.
    private func pageLink(for transfer: ArtifactPageLinkTransfer) -> ArtifactPageLink? {
        switch transfer.link {
        case .doc(let id):
            guard id != artifact.id else { return nil }
            let title = vm.artifacts.first { $0.id == id }?.title ?? transfer.title
            guard let title, !title.isEmpty else { return nil }
            return ArtifactPageLink(title: title, link: transfer.link)
        case .notebook(let id):
            guard let notebook = vm.notebook(id: id) else { return nil }
            return ArtifactPageLink(title: notebook.title, link: transfer.link)
        case .chat(let id):
            let title = vm.reviewSessionLinks.first { $0.id == id }?.title ?? transfer.title
            guard let title, !title.isEmpty else { return nil }
            return ArtifactPageLink(title: title, link: transfer.link)
        case .quiz(let id):
            let title = vm.courseQuiz(id)?.title ?? transfer.title
            guard let title, !title.isEmpty else { return nil }
            return ArtifactPageLink(title: title, link: transfer.link)
        case .idea(let id):
            let title = vm.ideas.first { $0.id == id }?.title ?? transfer.title
            guard let title, !title.isEmpty else { return nil }
            return ArtifactPageLink(title: title, link: transfer.link)
        }
    }

    private func citations(from transfer: StudioArticleTransfer) -> [ArtifactSourceCitation] {
        let sourceIDs = transfer.draggedSourceIDs
        let sources = sourceIDs.compactMap { vm.articlesById[$0] }
        let bookIDs = Set(sources.compactMap { source -> String? in
            guard source.sourceType == .book else { return nil }
            return source.parentGroup
        })
        if bookIDs.count == 1, let bookID = bookIDs.first,
           sources.count == sourceIDs.count,
           sources.allSatisfy({ $0.sourceType == .book && $0.parentGroup == bookID }),
           let representative = vm.bookChapterArticlesInOrder(for: bookID).first {
            return [ArtifactSourceCitation(
                sourceID: representative.id,
                title: vm.bookDisplayName(bookID),
                bookID: bookID
            )]
        }
        return sourceIDs.compactMap { sourceID in
            if let source = vm.articlesById[sourceID] {
                return ArtifactSourceCitation(sourceID: source.id, title: source.title)
            }
            // A source the library does not hold is named only by the drag
            // that carried its title; a drag that carried none writes nothing.
            guard sourceID == transfer.articleId, !transfer.title.isEmpty else { return nil }
            return ArtifactSourceCitation(sourceID: sourceID, title: transfer.title)
        }
    }
}

/// One book on the Docs source picker's chapter screen. Flat by design, for the
/// same reason `ArtifactSourcePickerRow` is: the picker's `List` only ever needs
/// the strings a row draws.
private struct ArtifactSourcePickerChapter: Identifiable, Equatable {
    let id: String
    let title: String
}

private struct ArtifactSourcePickerBook: Identifiable, Equatable {
    let id: String
    let title: String
    let chapters: [ArtifactSourcePickerChapter]
}

/// The highlighted passage, read as a first guess at what to search for.
enum ArtifactSourceSeedQuery {
    /// The words the writer highlighted, when they are short enough to work as a
    /// query. The picker matches titles, authors and domains — so a phrase stands
    /// a chance of naming a source and a paragraph never does. Anything longer
    /// than a phrase opens the picker unfiltered rather than on an empty list.
    static func from(_ selectedText: String) -> String {
        let collapsed = selectedText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: Self.edgePunctuation)
        guard !trimmed.isEmpty,
              trimmed.count <= 60,
              trimmed.split(separator: " ").count <= 8 else { return "" }
        return trimmed
    }

    /// Sentence punctuation the highlight drags along at either end. Dropped so
    /// "…fluorescence." searches for the word rather than the word plus a stop.
    private static let edgePunctuation = CharacterSet(charactersIn: " .,;:!?…\"'“”‘’")
}

struct ArtifactSourcePicker: View {
    /// What the chosen sources are for. The list and the search are the same;
    /// only the words at the bottom change, because "stands on" is a claim about
    /// a passage and makes no sense when the sources are joining a chat.
    enum Purpose {
        /// Grounding a Docs passage: the sources it stands on.
        case grounding
        /// Adding sources to the chat's context, from `/source` in the composer.
        case chat

        var emptyStatus: String {
            switch self {
            case .grounding: return "No sources linked to this passage yet"
            case .chat: return "Nothing chosen yet"
            }
        }

        func status(count: Int) -> LocalizedStringKey {
            switch self {
            case .grounding: return "^[\(count) source](inflect: true) attached"
            case .chat: return "^[\(count) source](inflect: true) chosen"
            }
        }

        var clearTitle: String {
            switch self {
            case .grounding: return "Detach all"
            case .chat: return "Clear"
            }
        }

        var commitTitle: String {
            switch self {
            case .grounding: return "Done"
            case .chat: return "Add to Chat"
            }
        }
    }

    /// Choosing here answers "what does this passage stand on" — usually more
    /// than one source, and an edit to an answer that already exists — so the
    /// picker collects a set and commits once rather than closing on a click.
    let initial: [String]
    let purpose: Purpose
    let commit: ([String]) -> Void

    /// The passage's own words, prefilled into the search field. Focusing selects
    /// them, so typing replaces the guess instead of having to clear it first.
    init(
        initial: [String],
        seed: String,
        purpose: Purpose = .grounding,
        commit: @escaping ([String]) -> Void
    ) {
        self.initial = initial
        self.purpose = purpose
        self.commit = commit
        let seeded = ArtifactSourceSeedQuery.from(seed)
        _search = State(initialValue: seeded)
        _seededQuery = State(initialValue: seeded)
    }

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var search: String
    /// The seed still standing unedited in the field, kept so a guess that names
    /// nothing can be taken back exactly once.
    @State private var seededQuery: String
    @State private var rows: [ArtifactSourcePickerRow] = []
    /// The library analysed for search, built once per opening. Held as a task so
    /// a keystroke that lands while it is being built waits for that build rather
    /// than starting another.
    @State private var libraryIndex: Task<ArtifactSourcePickerIndex, Never>?
    @State private var sourceTypeFilter: ArtifactSourcePickerFilter = .all
    @State private var attached: [String] = []
    @State private var didLoadAttached = false
    /// The book whose chapters are on screen. A passage rarely stands on a whole
    /// book, so choosing one asks which chapter rather than committing the shelf.
    @State private var drilledBook: ArtifactSourcePickerBook?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let book = drilledBook {
                chapterList(for: book)
            } else {
                sourceList
            }

            Divider()
            footer
        }
        .frame(minWidth: 440, minHeight: 480)
        .task(id: search) { await refreshRows() }
        .onAppear {
            searchFocused = true
            guard !didLoadAttached else { return }
            didLoadAttached = true
            attached = initial
        }
        .onExitCommand {
            // Escape backs out of a book before it closes the picker, so a
            // wrong turn costs one keystroke rather than the whole selection.
            if drilledBook != nil {
                drilledBook = nil
            } else {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let book = drilledBook {
                Button {
                    drilledBook = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverWash(inset: -3))
                .help("All sources")
                Text(book.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sources", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                sourceTypeMenu
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: -3))
            .help("Close")
        }
        .padding(12)
    }

    private var sourceTypeMenu: some View {
        Menu {
            ForEach(ArtifactSourcePickerFilter.allCases) { filter in
                Button {
                    sourceTypeFilter = filter
                    searchFocused = true
                } label: {
                    if sourceTypeFilter == filter {
                        Label(filter.title, systemImage: "checkmark")
                    } else {
                        Text(filter.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if sourceTypeFilter != .all {
                    Text(sourceTypeFilter.activeTitle)
                        .lineLimit(1)
                }
            }
            .zoomedSystemFont(size: 10, weight: sourceTypeFilter == .all ? .regular : .medium)
            .foregroundStyle(sourceTypeFilter == .all ? Color.secondary : Color.accentColor)
            .padding(.horizontal, sourceTypeFilter == .all ? 2 : 7)
            .padding(.vertical, 4)
            .background(
                sourceTypeFilter == .all ? Color.clear : Color.accentColor.opacity(0.12),
                in: Capsule()
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(sourceTypeFilter == .all ? "Filter source type" : "Showing \(sourceTypeFilter.title.lowercased())")
        .accessibilityLabel("Filter source type")
        .accessibilityValue(sourceTypeFilter.title)
    }

    /// A lazy stack, not a `List`. On the Mac a `List` is an outline view, and when
    /// its rows change it measures every row it holds: a keystroke that took the
    /// library's ~4,500 rows down to a handful wedged the main thread for two to
    /// four seconds (the product owner's stall samples, 2026-10-07, all in
    /// `OutlineListCoordinator.diffRows` asking each row whether it is a group
    /// row). A lazy stack builds only the rows on screen.
    private var sourceList: some View {
        let shown = filteredRows
        let firstID = shown.first?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.sourceListTop)
                    ForEach(shown) { row in
                        if row.id != firstID {
                            // Under the text, as an inset list draws it.
                            Divider()
                                .padding(.leading, 51)
                        }
                        sourceRow(row)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            // New results start at the top, as a list's did.
            .onChange(of: search) { proxy.scrollTo(Self.sourceListTop, anchor: .top) }
            .onChange(of: sourceTypeFilter) { proxy.scrollTo(Self.sourceListTop, anchor: .top) }
        }
    }

    private static let sourceListTop = "source-list-top"

    private func sourceRow(_ row: ArtifactSourcePickerRow) -> some View {
        Button {
            select(row)
        } label: {
            HStack(spacing: 9) {
                // Looked up here rather than carried in the row: the thumbnail is
                // the only thing that wants the whole source, and only rows the
                // list actually draws reach this point.
                if let source = vm.articlesById[row.sourceID] {
                    SourceThumbnail(
                        source: source,
                        size: 34,
                        bookCoverPath: row.bookID.flatMap { vm.bookCoverPaths[$0] }
                    )
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.quaternary)
                        .frame(width: 34, height: 34)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .lineLimit(1)
                    Text(row.subtitle)
                        .zoomedSystemFont(size: 9)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let bookID = row.bookID {
                    bookIndicator(for: bookID)
                } else {
                    attachmentMark(isAttached: attached.contains(row.sourceID))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // The wash fills the row and stops there, so it never covers the
        // dividers either side.
        .buttonStyle(.hoverWash(inset: 0))
    }

    private var filteredRows: [ArtifactSourcePickerRow] {
        rows.filter { sourceTypeFilter.includes(sourceType: $0.sourceType) }
    }

    private func chapterList(for book: ArtifactSourcePickerBook) -> some View {
        List {
            Button {
                attachWholeBook(book)
            } label: {
                chapterRow(
                    title: "Whole book",
                    subtitle: "^[\(book.chapters.count) chapter](inflect: true)",
                    isAttached: attached.contains(Self.bookToken(book.id))
                )
            }
            .buttonStyle(.hoverWash)

            ForEach(book.chapters) { chapter in
                Button {
                    attachChapter(chapter, of: book)
                } label: {
                    chapterRow(
                        title: chapter.title,
                        subtitle: nil,
                        isAttached: attached.contains(chapter.id)
                    )
                }
                .buttonStyle(.hoverWash)
            }
        }
        .listStyle(.inset)
    }

    private func chapterRow(
        title: String,
        subtitle: LocalizedStringKey?,
        isAttached: Bool
    ) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .zoomedSystemFont(size: 9)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            attachmentMark(isAttached: isAttached)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Group {
                if attached.isEmpty {
                    Text(purpose.emptyStatus)
                } else {
                    Text(purpose.status(count: attached.count))
                }
            }
            .zoomedSystemFont(size: 11)
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // Detaching is the same gesture as attaching nothing, so it
            // belongs here rather than behind a second control.
            if !attached.isEmpty {
                Button(purpose.clearTitle) { attached = [] }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
            }
            Button(purpose.commitTitle) {
                commit(attached)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func attachmentMark(isAttached: Bool) -> some View {
        Image(systemName: isAttached ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isAttached ? Color.accentColor : Color.secondary.opacity(0.5))
    }

    /// What a book row reports: the whole book, a count of the chapters chosen
    /// inside it, or nothing — always beside the chevron that leads to them.
    @ViewBuilder
    private func bookIndicator(for bookID: String) -> some View {
        HStack(spacing: 6) {
            if attached.contains(Self.bookToken(bookID)) {
                attachmentMark(isAttached: true)
            } else if let count = attachedChapterCountByBook[bookID], count > 0 {
                Text("\(count)")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
            Image(systemName: "chevron.right")
                .zoomedSystemFont(size: 10)
                .foregroundStyle(.tertiary)
        }
    }

    /// How many chapters of each book are attached on their own. Cheap because it
    /// walks what is attached rather than the library: a chapter token is an
    /// ordinary source id, and its book is the source's own group.
    private var attachedChapterCountByBook: [String: Int] {
        var counts: [String: Int] = [:]
        for token in attached where !token.hasPrefix(StudioViewModel.notepadGroundingBookPrefix) {
            guard let source = vm.articlesById[token],
                  source.sourceType == .book,
                  let bookID = source.parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bookID.isEmpty else { continue }
            counts[bookID, default: 0] += 1
        }
        return counts
    }

    /// What a whole book is attached as. The same reference `notepadGroundingToken`
    /// builds for a book row, spelled out here because the picker asks for it by
    /// book id rather than by the chapter that happens to represent it.
    private static func bookToken(_ bookID: String) -> String {
        StudioViewModel.notepadGroundingBookPrefix + bookID
    }

    /// A book row opens its chapters; every other row attaches itself.
    private func select(_ row: ArtifactSourcePickerRow) {
        guard let bookID = row.bookID else {
            toggle(row.sourceID)
            return
        }
        let chapters = vm.bookChapterArticlesInOrder(for: bookID)
            .map { ArtifactSourcePickerChapter(id: $0.id, title: $0.title) }
        guard !chapters.isEmpty else {
            toggle(Self.bookToken(bookID))
            return
        }
        drilledBook = ArtifactSourcePickerBook(id: bookID, title: row.title, chapters: chapters)
    }

    /// The whole book and a hand-picked chapter answer the same question, so
    /// choosing one clears the other rather than stacking both onto the passage.
    private func attachWholeBook(_ book: ArtifactSourcePickerBook) {
        let chapterIDs = Set(book.chapters.map(\.id))
        attached.removeAll { chapterIDs.contains($0) }
        toggle(Self.bookToken(book.id))
    }

    private func attachChapter(_ chapter: ArtifactSourcePickerChapter, of book: ArtifactSourcePickerBook) {
        attached.removeAll { $0 == Self.bookToken(book.id) }
        toggle(chapter.id)
    }

    private func toggle(_ reference: String) {
        if let index = attached.firstIndex(of: reference) {
            attached.remove(at: index)
        } else {
            attached.append(reference)
        }
    }

    /// Rows come from a task, not a computed property.
    ///
    /// Read during `body`, this rebuilt the entire library on every body pass —
    /// and presenting a sheet triggers several while AppKit sizes the window, all
    /// of it on the main thread before anything could draw. Now the library is
    /// analysed once per opening (`ArtifactSourcePickerIndex`) and a keystroke is a
    /// few milliseconds of comparing, off the main actor.
    private func refreshRows() async {
        let query = search
        let index = await analysedLibrary()
        guard !Task.isCancelled else { return }
        var matched = await Task.detached(priority: .userInitiated) {
            index.rows(matching: query)
        }.value
        guard !Task.isCancelled else { return }
        rows = matched

        // The titles answer every keystroke; the words inside a source's own text
        // answer once typing pauses, from the same indexed pass the sidebar's
        // search runs, and join the list. "direct data" names no title, but it is
        // in the page that says it.
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let contentIDs = await vm.storage.strictSourceContentMatchIDs(queryText: query, limit: 300)
            guard !Task.isCancelled else { return }
            if !contentIDs.isEmpty {
                let withContent = await Task.detached(priority: .userInitiated) {
                    index.rows(matching: query, contentMatchIDs: contentIDs)
                }.value
                guard !Task.isCancelled else { return }
                if withContent.count != matched.count {
                    matched = withContent
                    rows = matched
                }
            }
        }

        // The seed is a guess the writer never typed. When it matches nothing,
        // hand back the whole library rather than an empty list they have to
        // clear a field to escape — but only while the guess stands untouched,
        // so a search they typed themselves is allowed to find nothing.
        if matched.isEmpty, !seededQuery.isEmpty, query == seededQuery {
            seededQuery = ""
            search = ""
        }
    }

    private func analysedLibrary() async -> ArtifactSourcePickerIndex {
        if let libraryIndex { return await libraryIndex.value }
        let build = Task { await vm.artifactSourcePickerIndex() }
        libraryIndex = build
        return await build.value
    }
}

/// One source on the note's shelf. The title opens the source; the trailing
/// check controls whether the next Chat question receives it as grounding.
/// One conversation that started on the selected passage, as a chip in the
/// row above the shelf. Named for the chat; the words it was asked about live in
/// the tooltip, since the writer is looking at them.
private struct ArtifactSelectionChatChip: View {
    let entry: ArtifactChatLink
    let open: () -> Void
    let forget: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .zoomedSystemFont(size: 9)
                    .foregroundStyle(Color.accentColor)
                Text(entry.displayTitle)
                    .zoomedSystemFont(size: 10)
                    .lineLimit(1)
                Text(entry.link.createdAt, style: .relative)
                    .zoomedSystemFont(size: 9)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 220, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .background(
            Color.primary.opacity(0.07),
            in: Capsule()
        )
        .help("Open this chat — about: \(entry.link.anchorQuote)")
        .accessibilityLabel("Open chat \(entry.displayTitle), about: \(entry.link.anchorQuote)")
        .contextMenu {
            Button("Open Chat", systemImage: "bubble.left.and.text.bubble.right") { open() }
            OtherWindowMenuItem(.chat(entry.session.id))
            Button("Forget This Link", systemImage: "link.badge.minus", role: .destructive) { forget() }
        }
    }
}

private struct ArtifactShelfChip: View {
    let article: StudioArticle
    /// A whole book's cover. Its `article` is one chapter, whose own art is a
    /// picture from inside the book rather than its front.
    let bookCoverPath: String?
    /// What the row is called. A book's row is named for the book, not for the
    /// chapter that happens to stand for it.
    let title: String
    let isMuted: Bool
    let toggle: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Button(action: open) {
                HStack(spacing: 5) {
                    SourceThumbnail(source: article, size: 20, bookCoverPath: bookCoverPath)

                    Text(title)
                        .zoomedSystemFont(size: 10)
                        .lineLimit(1)
                }
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: 176, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help("Open \(title)")
            .accessibilityLabel("Open \(title)")

            Button(action: toggle) {
                Image(systemName: isMuted ? "circle" : "checkmark.circle.fill")
                    .zoomedSystemFont(size: 9, weight: .medium)
                    .foregroundStyle(isMuted ? Color.secondary.opacity(0.6) : Color.accentColor)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help(isMuted ? "Add when opening Chat" : "Don't add when opening Chat")
            .accessibilityLabel(isMuted ? "Add \(title) when opening Chat" : "Don't add \(title) when opening Chat")
        }
        .background(
            Color.primary.opacity(0.07),
            in: Capsule()
        )
        .opacity(isMuted ? 0.45 : 1)
        .contextMenu {
            Button("Open in Reader", systemImage: "book") { open() }
            OtherWindowSourceMenuItem(article)
            Button(
                isMuted ? "Add When Opening Chat" : "Don't Add When Opening Chat",
                systemImage: isMuted ? "plus.circle" : "minus.circle"
            ) { toggle() }
        }
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
