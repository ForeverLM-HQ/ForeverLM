// ArtifactCanvas: the Space helpers, toolbar, page menus and page actions.

import AppKit
import SwiftUI

extension ArtifactCanvas {
    // MARK: - The Space

    /// A place chosen in the sidebar: the list shows beside it, here, in the
    /// pane the page was in.
    func showSpacePlace(_ place: SpaceDestination) {
        if windowState.spaceDestinationKey != place.key { windowState.spaceDestinationKey = place.key }
        spaceSearchText = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedArtifactID = nil
            isShowingIndex = true
        }
    }

    /// The sidebar's search: every place at once, with the field focused.
    func searchSpace() {
        // Every place at once, as the Space's own sidebar search does.
        if !showsSpaceList || spaceDestination != .all {
            showSpacePlace(.all)
        }
        spaceSearchFocusRequest += 1
    }

    /// A record chosen in the Space: here when this pane lists it, else in
    /// its own section's pane; a team's record listed in My Library in its
    /// team's library.
    func openFromSpace(_ artifact: ArtifactRecord) {
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

    func openSpaceRecent(_ item: SpaceRecents.Item) {
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
    func newSpacePage() {
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

    func linkFromSpace(_ linkSection: ArtifactSection) {
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

    /// How much of the page's trailing controls the top line draws, from all
    /// of them down to what is needed (`ViewThatFits` takes the first that
    /// fits the strip).
    enum ToolbarTier {
        /// The tool pill, Codex's four, Edit and Share, labelled.
        case full
        /// The pill, the version history and the person go (the menu carries
        /// the pill's tools); Share is its glyph.
        case compact
        /// Edit (or Update) and Share's glyph only.
        case minimal
    }

    /// The page's top line, as ChatGPT draws a page in its Space (product owner,
    /// 2026-10-06: "there are often way too many buttons at the top in
    /// foreverlm. please learn from chatgpt"; docs/ui-design.md, "Quiet
    /// chrome"). The page's menu leads — everything the page can do, its
    /// formatting, its view and its publishing among it — and the trailing
    /// side holds only what is happening now (Reload after a failure, Update
    /// Page while a published page has edits, Edit while the page shows, the
    /// comments while there are some) and Share. Formatting is the page's
    /// selection bar; New page and the links are the Space sidebar's. The line
    /// is a clone of Codex's own (product owner, 2026-10-07): after the menu a pill of four tools (`pageToolPill`), and before Share
    /// the version history, the comments and the person's initials.
    func toolbar(_ tier: ToolbarTier) -> some View {
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
            if isSpaceCanvas, showsPage, let place = spaceSidebarSelection {
                spaceBackButton(to: place)
            }
            if let selectedArtifact, showsPage {
                if selectedArtifact.isLinked {
                    linkedDocMenu(for: selectedArtifact)
                    // A Google Doc's own header already names it.
                    if linkedDocFillsPane, !selectedArtifact.namesItself {
                        linkedPageTitle(for: selectedArtifact)
                    }
                } else if selectedArtifact.isMnemonicReading {
                    readingMenu(for: selectedArtifact)
                } else {
                    pageMenu(for: selectedArtifact, toolPillShown: tier == .full && showsPageTools(for: selectedArtifact))
                    if vm.teamArtifactID(forDraft: selectedArtifact.id) != nil {
                        draftControls
                    }
                    if tier == .full, showsPageTools(for: selectedArtifact) {
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
                docControls(for: selectedArtifact, tier: tier)
            }
        }
        // Clearance for the traffic lights and for the chrome overlaying the
        // pane's top-right corner comes from studioChromeLineHeader; this row
        // only owns its own margins. Beside the Space sidebar the page's
        // menu sits close to the sidebar's edge, as ChatGPT's does.
        .padding(.leading, showsSpaceSidebar ? 12 : StudioDesign.Metrics.pageMargin)
        .padding(.trailing, StudioDesign.Metrics.pageMargin)
    }

    /// A Space page's way back to the list it is in, as Codex draws it: ‹ and
    /// the place's name, quiet until hovered (product owner, 2026-11-26: "i
    /// need a more intuitive back button here; you can copy from the codex
    /// app design in spaces"). The page menu's glyph alone never read as
    /// the way out.
    private func spaceBackButton(to place: SpaceDestination) -> some View {
        let title = place == .all ? StudioCenterTab.artifacts.title : vm.spacePlaceTitle(place)
        return SpaceBackButton(title: title) { showSpacePlace(place) }
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

    /// Animations' way in, in the list's head beside its search, as a new
    /// chat is in ChatGPT's and Codex's lists: an animation is made in a chat
    /// from a source, so the button opens one with the request typed (the
    /// same call the empty state's pill makes). A page or a site is added
    /// from the Space sidebar; nothing is linked here.
    var animateSourceButton: some View {
        StudioChromeIconButton(systemImage: "square.and.pencil", label: section.linkActionTitle) {
            vm.requestAnimationChat()
        }
    }

    /// The ways an entry gets into the list, shared by the empty state and the
    /// list's context menu so they never drift apart from the header buttons.
    /// Docs has two, a new doc and a linked Google Doc; Sites has the link.
    @ViewBuilder
    var addDocMenuItems: some View {
        if section == .docs {
            Button {
                beginCreation()
            } label: {
                Label("New Page", systemImage: "doc.badge.plus")
            }
        }
        if section == .animations {
            Button {
                vm.requestAnimationChat()
            } label: {
                Label(section.linkActionTitle, systemImage: "square.and.pencil")
            }
        } else {
            Button {
                isLinkingPage = true
            } label: {
                Label(section.linkActionTitle, systemImage: "link.badge.plus")
            }
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
    private func docControls(for artifact: ArtifactRecord, tier: ToolbarTier) -> some View {
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
        if tier == .full {
            Button {
                docChrome.isActivityVisible.toggle()
            } label: {
                chromeIconLabel("clock.arrow.circlepath", prominent: docChrome.isActivityVisible)
            }
            .buttonStyle(.hoverWash)
            .help(docChrome.isActivityVisible ? "Close page activity" : "Page activity")
            .accessibilityLabel("Page activity")
            .accessibilityIdentifier("page.versionHistory")
        }
        if tier != .minimal {
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
        }
        if tier == .full { accountAvatar }
        shareButton(for: artifact, labelled: tier == .full)
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
        return workspaceWidth - (showsSpaceSidebar ? SpaceSidebarMetrics.width : 0) - chromeReservation.total
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
    /// Show pages). The learner's choice is this window's
    /// (`StudioWindowState.spaceSidebarHidden`), which the Space home in it
    /// reads as well.
    func togglePagesSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) { windowState.spaceSidebarHidden.toggle() }
    }

    /// Whether the pane is wide enough to hold the sidebar at all; narrower,
    /// it steps aside by itself and Show pages would change nothing.
    var spaceSidebarFitsPane: Bool {
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
    private func shareButton(for artifact: ArtifactRecord, labelled: Bool = true) -> some View {
        Button {
            isSharePopoverPresented = true
        } label: {
            if labelled {
                chromeChipLabel("Share", systemImage: "person.badge.plus")
            } else {
                chromeIconLabel("person.badge.plus")
            }
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
    func select(_ artifact: ArtifactRecord) {
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

    /// The page's menu, on the leading side of its top line: Codex's page ▾.
    /// Codex's items come first and in Codex's order (docs/codex-parity-audit.md,
    /// F8; product owner, 2026-10-13: "at first it should be a copy of the codex
    /// pages functionality; THEN we can gradually add some features on top"),
    /// and everything ForeverLM adds is under **More**, below one divider, so the
    /// menu reads as Codex's ("Quiet chrome", docs/ui-design.md, holds for menus
    /// as for bars). What it opens — the publish sheet, the confirmations, the
    /// Google Doc conversion, the comments drawer — is presented by the editor,
    /// which binds to the same bridge this menu writes.
    private func pageMenu(for artifact: ArtifactRecord, toolPillShown: Bool) -> some View {
        Menu {
            pageCodexItems(for: artifact, toolPillShown: toolPillShown)
            Divider()
            Menu {
                pageMoreItems(for: artifact, toolPillShown: toolPillShown)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
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

    /// Codex's page menu, in its order: Show pages · Rename · Pin · Delete │
    /// Share · Copy ▸ · Download as Markdown │ Open in new window (the product
    /// owner's screenshot of 2026-10-07; `codex.space.page.actions.*`), in
    /// ForeverLM's words where they differ: Move to Trash for Delete, and Open
    /// in Other Window, which also names the windows already open. Codex's
    /// New schedule is left out while Scheduled has no way in (product owner,
    /// 2026-10-13: "scheduled is not so important btw; skip that for now"),
    /// and Show attribution is not built (docs/docs-design.md, "The page menu,
    /// after Codex's"). A team's page is read, shared and exported here, never
    /// renamed or pinned; a daily note is named by its day.
    @ViewBuilder
    private func pageCodexItems(for artifact: ArtifactRecord, toolPillShown: Bool) -> some View {
        let isOwn = artifact.teamID == nil
        // The Space sidebar beside the page, out of the way and back. The key
        // is also held by an invisible button, since a menu's shortcut does not
        // run while the menu is shut.
        if spaceSidebarFitsPane {
            Button {
                togglePagesSidebar()
            } label: {
                Label(showsSpaceSidebar ? "Hide pages" : "Show pages", systemImage: "sidebar.leading")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        if isOwn, DailyNote.dayKey(ofID: artifact.id) == nil, !artifact.namesItself {
            Button {
                renamePage(artifact)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }
        if isOwn, vm.activeTeamID == nil {
            SpacePagePinItem(artifact: artifact)
        }
        Button(role: .destructive) {
            trash(artifact)
        } label: {
            Label(vm.trashTitle(for: artifact.id), systemImage: "trash")
        }
        Divider()
        // A Doc someone shared with this account is theirs to share.
        if vm.sharedDocs[artifact.id]?.isOwner != false {
            Button {
                ArtifactSharingService.shared.presentShare(
                    artifactID: artifact.id,
                    title: artifact.title
                )
            } label: {
                Label("Share…", systemImage: "person.crop.circle.badge.plus")
            }
        }
        if vm.sharedDocs[artifact.id]?.isOwner == true {
            Button {
                Task { await vm.stopSharingDoc(artifact.id) }
            } label: {
                Label("Stop Sharing", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        // Copy ▸ and Download as Markdown are items of their own, as in
        // Codex: the text is the Markdown, so the one everyday export is a
        // single press, and More's Export ▸ keeps the formats that are drawn
        // rather than written. Both take the text on screen.
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
        Divider()
        OpenStudioDestinationInOtherWindowMenu(
            destination: .doc(artifact.id),
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
    }

    /// What ForeverLM adds to Codex's page menu, under **More**, in four
    /// groups: the page itself (New Page, Duplicate, subpages, Version
    /// History…), writing and reading it (Edit with AI…, Format, View as Page,
    /// Page Width, Comments), where it lives and who has it (Add to Chat,
    /// notebooks, canvases, spaces, teams), and taking it out of ForeverLM
    /// (publishing, Google Docs, Export, Finder).
    @ViewBuilder
    private func pageMoreItems(for artifact: ArtifactRecord, toolPillShown: Bool) -> some View {
        let publishedStatus = publishedStatuses[artifact.id]
        let isOwn = artifact.teamID == nil
        let isOwnEditable = isOwn && !docChrome.showsPage
        if section == .docs {
            Button {
                beginCreation()
            } label: {
                Label("New Page", systemImage: "doc.badge.plus")
            }
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
            docChrome.isActivityVisible.toggle()
        } label: {
            Label(docChrome.isActivityVisible ? "Hide Page Activity" : "Page Activity", systemImage: "clock.arrow.circlepath")
        }
        .help("Earlier versions of this page on this Mac")
        Divider()
        if isOwnEditable {
            Button {
                docChrome.aiEditOpenRequestID += 1
            } label: {
                Label("Edit with AI…", systemImage: "sparkles")
            }
            .help("Ask for a change to the selected passage, or to the section at the caret")
            // The tool pill's other three, while the line is too short to
            // hold the pill.
            if !toolPillShown {
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
        // The page's edges drag to any width; these are the usual ones, and
        // the menu says which the page is at, or the width it was dragged to.
        Menu {
            ForEach(ArtifactPageWidth.presets) { preset in
                Toggle(preset.title, isOn: Binding(
                    get: { ArtifactPageWidth.maxWidth(pageWidth) == ArtifactPageWidth.maxWidth(preset.width) },
                    set: { if $0 { pageWidth = preset.width } }
                ))
            }
            if let custom = ArtifactPageWidth.maxWidth(pageWidth),
               !ArtifactPageWidth.presets.contains(where: { ArtifactPageWidth.maxWidth($0.width) == custom }) {
                Divider()
                Toggle("\(Int(custom)) pt", isOn: .constant(true))
                    .disabled(true)
            }
            Divider()
            Text("Drag the page's edges for any width")
        } label: {
            Label("Page Width", systemImage: "arrow.left.and.right")
        }
        Button {
            docChrome.isCommentsVisible.toggle()
        } label: {
            Label(docChrome.isCommentsVisible ? "Hide Comments" : "Comments", systemImage: "text.bubble")
        }
        .help("Comments on this page, and the chats its passages started")
        Divider()
        Button {
            // The side chat over the page takes the page with its sources; a
            // window with none keeps the docked route.
            if pageHostsSideChat {
                docChrome.wholePageChatRequest = PageSideChatWholePageRequest(intent: .addToChat)
            } else {
                Task { await vm.attachDocToChat(artifact.id) }
            }
        } label: {
            Label("Add to Chat", systemImage: "message")
        }
        ArtifactNotebooksMenu(artifact: artifact)
        KnowledgeMapAddToCanvasMenu(refs: ["doc:\(artifact.id)"])
        KnowledgeMapOnCanvasesSection(ref: "doc:\(artifact.id)", windowState: windowState)
        PageSpaceMenu(page: artifact)
        // A team copy needs no publishing and no reader list, so this sits
        // with Notebooks (where the Doc is filed) rather than with publishing
        // (who outside the library may read it).
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
            Button(role: .destructive) {
                docChrome.showDiscardDraftConfirmation = true
            } label: {
                Label("Discard Draft…", systemImage: "trash")
            }
        }
        Divider()
        // Who can open the page is the Share popover's; the submenu names the
        // answer with the same sentence and keeps what the popover does not
        // do — the address, a republish of the text, Unpublish.
        if let publishedStatus {
            Menu {
                Button {
                    isSharePopoverPresented = true
                } label: {
                    Label("Who Can Open the Page…", systemImage: "person.badge.plus")
                }
                .help("Invite people, open the link to anyone, or share with a team")
                Button {
                    WebLinkOpening.open(publishedStatus.url)
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
        Button {
            Task {
                guard let url = await vm.artifactFileURL(artifact.id) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
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
            if selectedArtifactID == artifact.id {
                do {
                    try await docChrome.flushDraft?()
                } catch {
                    vm.logger.error("Writing the typing on screen before duplicating failed: \(error.localizedDescription, privacy: .public)")
                }
            }
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
    /// the Space's Trash at once, undone from the toast or from Trash
    /// (Restore); an animation keeps its question and is deleted, as it has
    /// no Trash to be found in. A page with subpages takes them with it, as a
    /// Codex page's Delete does, so it asks first and says so.
    func trash(_ artifact: ArtifactRecord) {
        guard section != .animations else {
            artifactToDelete = artifact
            return
        }
        guard vm.pageTree.descendantIDs(of: artifact.id).isEmpty else {
            pageToTrash = artifact
            return
        }
        moveToTrash(artifact)
    }

    /// The move itself, the page's subpages with it; the pane lets go of
    /// whichever of them it shows.
    func moveToTrash(_ artifact: ArtifactRecord) {
        let going = [artifact.id] + vm.pageTree.descendantIDs(of: artifact.id)
        if let open = artifacts.first(where: { $0.id == selectedArtifactID }), going.contains(open.id) {
            closeIfOpen(open)
        }
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
}

/// ‹ Pages: Codex's back control, the chevron and where it goes in one
/// hover-washed capsule.
struct SpaceBackButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 11, weight: .semibold)
                Text(title)
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .lineLimit(1)
            }
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(height: StudioDesign.Metrics.chromeButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                    .fill(StudioDesign.selectionFill(isSelected: false, isHovered: isHovered))
            )
            .contentShape(RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Back to \(title)")
        .accessibilityLabel("Back to \(title)")
        .onHover { isHovered = $0 }
    }
}
