import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
import WebKit
import AppKit

/// Studio — Knowledge Base interface: the navigation rail on the left and the center panes beside it.
/// Inspired by NotebookLM but with one persistent knowledge base (not per-notebook).
struct StudioView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(ManagedAIAccountModel.self) private var account
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false
    /// The top safe-area inset SwiftUI last laid the window out against, handed
    /// to StudioWindowChrome so it can tell when that measurement has gone
    /// stale against the window's real titlebar band.
    @State private var measuredTopSafeAreaInset: CGFloat = 0
    @State private var settingsInitialPane: SettingsPane?
    @State private var workspaceViews = StudioWorkspaceViewStore.shared
    @State private var showSaveWorkspaceView = false
    @State private var showManageWorkspaces = false
    @State private var workspaceViewName = ""
    @State private var showCreditsEmptyAlert = false
    /// The source whose Edit Details sheet this window shows. Hosted here,
    /// once per window, so a row asks for it from the library list or a
    /// notebook's Sources column alike (`SourceDetailsEditRequest`).
    @State private var editingSourceDetailsID: String?
    @State private var handledCreditsEmptyEpisode = false
    /// Read here as well as by the day's clock, so switching "Plan your
    /// day?" off in Settings or over MCP takes the card down at once.
    @AppStorage(PlanTheDay.settingKey) private var asksToPlanTheDay = true
    /// Read here so Don't Ask Again on the "Cards to check" card, Settings
    /// or MCP takes the card down at once, in every window.
    @SyncedStorage(wrappedValue: true, MemoryCardSettings.draftNudgesKey) private var showsDraftNudges: Bool
    /// The Space sidebar the learner hid, which the one sidebar toggle folds
    /// together with Home's sidebar.
    @AppStorage("space.sidebarHidden") private var spaceSidebarHiddenByLearner = false
    @SyncedStorage("uiZoomStep") private var uiZoomStep = UIZoom.defaultStep
    /// The bout whose write-up sheet this window shows (`requestBoutWriteUp`).
    @State private var writeUpBoutID: String?
    /// The bout waiting for its goal in this window's start sheet
    /// (`requestBoutStart`).
    @State private var boutStartRequest: BoutStartRequest?
    /// Whether the left navigation rail is shown. Toggled from the sidebar
    /// button pinned next to the macOS traffic lights; persisted across launches.
    @SyncedStorage("gettingStarted.completed") private var gettingStartedCompleted = false
    @SyncedStorage("gettingStarted.dismissed") private var gettingStartedDismissed = false
    @SyncedStorage("aiBackground.usageConsented") private var backgroundAIUsageConsented = false
    @State private var showGettingStarted = false
    @State private var whatsNew = WhatsNewCenter.shared
    @State private var studioAssistantSessions = StudioAssistantSessionStore()
    @State private var comparisonAssistantSessions = StudioAssistantSessionStore()
    /// The chat drawn by the card floating over this window's open page
    /// (docs/pages-side-chat-design.md). Its own store, as the comparison
    /// pane's is: the page's passing question is not the window's chat.
    @State private var pageSideChatSessions = StudioAssistantSessionStore()
    @State private var studioAssistantWindow: NSWindow?

    /// Whether this window has given itself over to today's review. The rail
    /// and every other center tab step aside while it has: fifteen
    /// minutes of retrieval is what the review is, and retrieval is the first
    /// thing to go when something else is one click away. The sidebar toggle
    /// still works: it brings the rail back beside the review
    /// (`StudioWindowState.drawsNavigationRail`).
    private var isMemoryReviewFocused: Bool {
        windowState.memoryReviewFocusSessionID != nil
    }

    /// The sidebar toggle, the window's only one (Codex's): it folds the
    /// sidebar beside the icon strip, Home's and the Space's, and brings both
    /// back; the strip itself always stays. It reads as shown only while both
    /// are. Pressed while Home's sidebar is stepping aside for a memory
    /// review, it brings it back now (`setNavigationRailShown`).
    private var navigationRailVisibilityBinding: Binding<Bool> {
        Binding(
            get: { windowState.drawsNavigationRail && !spaceSidebarHiddenByLearner },
            set: { shown in
                windowState.setNavigationRailShown(shown)
                withAnimation(.easeInOut(duration: 0.18)) { spaceSidebarHiddenByLearner = !shown }
            }
        )
    }

    private var studioContent: some View {
        GeometryReader { geo in
            studioPanelContent(totalWidth: geo.size.width)
        }
    }

    /// The golden width for this window: every center pane opens φ times as
    /// wide as the sidebar. It depends on how many center panes are open —
    /// a second pane makes the row owe φ twice, so the sidebar narrows —
    /// which is why only the root, where the rail and the panes are measured
    /// together, can work it out.
    private func goldenSideWidth(windowWidth: CGFloat) -> CGFloat {
        StudioPanelDefaultSizing.goldenSideWidth(
            windowWidth: windowWidth,
            centerPaneCount: windowState.notebook.map { max(1, $0.centerPaneCount) }
                ?? windowState.centerTabGroups.groups.count
        )
    }

    /// The whole Studio surface: the chat navigation rail sits on the outer
    /// edge beside the center panes.
    private var studioRootLayout: some View {
        GeometryReader { geo in
            let golden = goldenSideWidth(windowWidth: geo.size.width)
            HStack(spacing: 0) {
                // The icon strip is always there (product owner, 2026-10-12: "the
                // sidebar all the way on the left should never be hidden; not
                // even when doing that left collapse button"). The toggle folds
                // only the sidebar beside it, Home's or the Space's, as Codex's
                // folds its project list and leaves the strip.
                StudioNavigationRail(
                    sessionStore: studioAssistantSessions,
                    comparisonSessionStore: comparisonAssistantSessions,
                    edge: .leading,
                    style: .strip,
                    onOpenChatBeside: { openChatBeside($0, atLeadingEdge: false) },
                    onOpenSettings: { pane in
                        settingsInitialPane = pane
                        presentSettings()
                    },
                    goldenWidth: golden,
                    isGettingStarted: showGettingStarted
                )
                // The card: everything but the icon strip, Home's sidebar
                // included, as Codex's card holds its project list.
                HStack(spacing: 0) {
                    // Home's sidebar — New chat, the notebooks and the
                    // chats — beside the icon rail while the window is on
                    // Home, as Codex draws its projects.
                    if windowState.drawsNavigationRail, windowState.showsHomeSidebar {
                        StudioNavigationRail(
                            sessionStore: studioAssistantSessions,
                            comparisonSessionStore: comparisonAssistantSessions,
                            edge: .leading,
                            style: .homeSidebar,
                            onOpenChatBeside: { openChatBeside($0, atLeadingEdge: false) },
                            onOpenSettings: { pane in
                                settingsInitialPane = pane
                                presentSettings()
                            },
                            goldenWidth: golden,
                            isGettingStarted: showGettingStarted
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    studioContent
                }
                .studioInsetCard()
            }
            .animation(.easeInOut(duration: 0.22), value: windowState.drawsNavigationRail)
            .animation(.easeInOut(duration: 0.22), value: isMemoryReviewFocused)
        }
    }

    /// What the center area needs at the least: the notebook's columns and
    /// slots, or the sum of the panes' minima. The center is laid out at no
    /// less and clipped at the window's width, so a squeezed window never
    /// hands its panes a degenerate proposal.
    private var centerMinimumWidth: CGFloat {
        max(
            StudioOuterPanelSizing.minimumContentWidth,
            windowState.notebook.map {
                NotebookWorkspaceSizing.minimumWidth(for: $0, studioShows: !windowState.isDockedReaderImmersive)
            } ?? StudioCenterTabGroupSizing.minimumWidth(for: windowState.centerTabGroups.groups)
        )
    }

    @ViewBuilder
    private func studioPanelContent(totalWidth: CGFloat) -> some View {
        // The center area is the app: the tab groups arrange themselves, and
        // the library comes in as one of them (the rail's Library row, dragged
        // to an edge or clicked).
        let contentWidth = max(totalWidth, centerMinimumWidth)
        Color.clear
            .frame(width: totalWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                centerTabArea
                    .frame(width: contentWidth)
                    .frame(maxHeight: .infinity)
                    .environment(\.studioPanelTrailingOverflow, contentWidth - totalWidth)
            }
            .clipShape(StudioPanelColumnClipShape())
            .allowsHitTesting(totalWidth > 1)
        .onChange(of: vm.readerChatSpaceRequestID) { _, requestID in
            guard requestID != nil else { return }
            makeRoomForCenterPanes(totalWidth: totalWidth, animated: true)
        }
        .onChange(of: StudioCenterTabGroupSizing.minimumWidth(for: windowState.centerTabGroups.groups)) { _, _ in
            makeRoomForCenterPanes(totalWidth: totalWidth, animated: true)
        }
        // The notebook's center only: a column the learner unfolds is theirs,
        // and must not fold straight back in a narrow window.
        .onChange(of: windowState.notebook.map(NotebookWorkspaceSizing.centerMinimumWidth(for:))) { _, _ in
            makeRoomForCenterPanes(totalWidth: totalWidth, animated: true)
        }
        .onAppear {
            // A restored multi-pane layout can meet a restored narrow window
            // before either side panel has had a state transition of its own.
            // Resolve that launch shape immediately instead of waiting for a
            // later navigation action to make room.
            makeRoomForCenterPanes(totalWidth: totalWidth, animated: false)
        }
    }

    /// Keep every center pane at or above the same minimum width its internal
    /// divider enforces: when they do not fit, the navigation rail yields.
    /// This applies to restored launch state as
    /// well as newly opened panes so titlebar controls never begin life in a
    /// clipped, mutually overlapping viewport.
    private func makeRoomForCenterPanes(totalWidth: CGFloat, animated: Bool) {
        guard totalWidth > 0 else { return }
        if let notebook = windowState.notebook {
            makeRoomForNotebook(notebook, totalWidth: totalWidth, animated: animated)
            return
        }
        let requiredCenterWidth = StudioCenterTabGroupSizing.minimumWidth(for: windowState.centerTabGroups.groups)
        guard requiredCenterWidth > 0 else { return }

        let shouldCollapseNavigationRail = windowState.navigationRailVisible
            && totalWidth < requiredCenterWidth

        guard shouldCollapseNavigationRail else { return }
        let changes = {
            windowState.navigationRailVisible = false
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.22), changes)
        } else {
            changes()
        }
    }

    /// The notebook's version of the same rule (`NotebookWorkspaceSizing.folds`):
    /// the notebook's Sources column folds to its strip first, then its
    /// Studio. The folds go into the notebook's arrangement, which only this
    /// window's scene snapshot keeps. The navigation rail is not folded here:
    /// its visibility is a synced preference, and opening a notebook writes
    /// none, and the icon strip never steps aside.
    private func makeRoomForNotebook(
        _ notebook: NotebookWorkspace,
        totalWidth: CGFloat,
        animated: Bool
    ) {
        let folds = NotebookWorkspaceSizing.folds(
            for: notebook,
            totalWidth: totalWidth,
            studioShows: !windowState.isDockedReaderImmersive
        )
        guard folds.sources || folds.studio else { return }
        let changes = {
            if folds.sources { windowState.notebook?.sourcesCollapsed = true }
            if folds.studio { windowState.notebook?.studioCollapsed = true }
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.22), changes)
        } else {
            changes()
        }
    }

    /// The center area routes among Chat, Reader, Schedule, and Notebooks.
    /// The underlying groups still support contextual
    /// Reader + Chat splits, but destination tabs are intentionally not drawn:
    /// the navigation rail and source interactions are the navigation surface.
    /// Deliberately NO .ignoresSafeArea anywhere in this subtree: on macOS 26
    /// a safe-area-ignoring subtree stops painting its SwiftUI-drawn content
    /// in the band (the reader title went invisible — same failure as the
    /// source tab bar, see StudioSidebar).
    @ViewBuilder
    private var centerTabArea: some View {
        Group {
            if let cardSession = windowState.memoryCardSession {
                // The card review, and nothing else: its chrome line carries
                // the clock and the × that gives the workspace back, and a
                // card's source opens the window's Reader beside it.
                MemoryCardSessionView(session: cardSession) { AnyView(readerTabContent) }
                    .transition(.opacity)
            } else if isMemoryReviewFocused {
                // A day's review chat from before cards, and nothing else.
                // Its own header carries the clock and the ×.
                dockedChatPanel
                    .transition(.opacity)
            } else if let notebook = windowState.notebook {
                // The notebook workspace takes the window body while the
                // window holds a notebook. The groups below are not mounted
                // meanwhile (the memory-focus precedent), so the chat, the
                // Reader and each canvas stay one mount per window.
                NotebookWorkspaceView(
                    workspace: notebook,
                    chat: { AnyView(dockedChatPanel) },
                    document: { document in AnyView(notebookDocumentContent(document)) }
                )
                .transition(.opacity)
            } else {
                StudioCenterTabGroupsView(
                    onSessionDropAtEdge: { transfer, leading in
                        openChatBeside(transfer.sessionID, atLeadingEdge: leading)
                    }
                ) { tab in
                    centerTabContent(tab)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isMemoryReviewFocused)
        .animation(.easeInOut(duration: 0.18), value: windowState.NotebookID)
    }

    /// One center tab's surface, for the tab groups and, through
    /// `notebookDocumentContent`, for the notebook's document slot: the same
    /// view either way, so a pane behaves alike in both shells.
    @ViewBuilder
    private func centerTabContent(_ tab: StudioCenterTab) -> some View {
        switch tab {
        case .chat:
            dockedChatPanel
        case .secondaryChat:
            comparisonChatPanel
        case .reader:
            readerTabContent
        case .tasks:
            ScheduledTasksReaderPane()
        case .activity:
            DayActivityReaderPane()
        case .notepad:
            // This window's scope: a notebook's own Docs, or every doc.
            ArtifactCanvas(section: .docs, notebookID: windowState.artifactCanvasNotebookID, onBack: nil)
                .studioCenterTabCloseChrome(for: .notepad)
        case .sites:
            // Sites is never scoped to a Notebook: a Notebook's own
            // canvas is its Docs, and a site opened from anywhere
            // opens in the one global Sites pane.
            ArtifactCanvas(section: .sites, notebookID: nil, onBack: nil)
                .studioCenterTabCloseChrome(for: .sites)
        case .browser:
            BrowserPane()
        case .videos:
            ExplainerVideosPane()
        case .animations:
            // Animations is never scoped to a Notebook either: the
            // one global canvas, filtered to the section by each
            // record's kind.
            ArtifactCanvas(section: .animations, notebookID: nil, onBack: nil)
                .studioCenterTabCloseChrome(for: .animations)
        case .artifacts:
            ArtifactsHomePane()
        case .goals:
            GoalsPane()
        case .courses:
            CoursesPane()
        case .ideas:
            IdeasPane()
        case .memory:
            MemoryPane()
        case .library:
            LibraryPane()
        case .knowledgeMap:
            KnowledgeMapPane()
        case .atlas:
            AtlasPane()
        case .plugins:
            PluginsPane()
        }
    }

    /// What the notebook's document slot shows. Card practice
    /// (`NotebookDocument.flashcards`) has no pane and no route leads to it,
    /// so it shows nothing: the notebook's cards are reviewed in the Memory
    /// pane (`.memory`, the slot's like any pane) and the window-filling
    /// memory focus its Start Review opens.
    @ViewBuilder
    private func notebookDocumentContent(_ document: NotebookDocument) -> some View {
        if let tab = document.centerTab {
            centerTabContent(tab)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    /// The Reader tab's surface. While the reader is popped out into its own
    /// window the tab stays, but shows a placeholder instead of rendering the
    /// same source twice.
    @ViewBuilder
    private var readerTabContent: some View {
        if vm.readerPoppedOut {
            ContentUnavailableView {
                Label("Reader is in its own window", systemImage: "macwindow.on.rectangle")
            } actions: {
                Button("Bring It Back") {
                    vm.readerPoppedOut = false
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            SourceReaderPanel()
        }
    }

    /// Extra leading room for the center area's header while it sits in the
    /// titlebar band: without Home's sidebar, the leftmost pane's header
    /// would otherwise run underneath the traffic lights and the sidebar
    /// toggle, which reach past the icon strip.
    private func headerLeadingClearance(hasTitlebarBand: Bool) -> CGFloat {
        // The rail is a 52-point icon strip: the traffic
        // lights and the sidebar toggle reach past it into the band over the
        // notebook's first column, which sits in the center column.
        // In full screen there are no traffic lights, and the toggle sits in
        // flow inside the strip, whose content already starts below it.
        // Home's sidebar beside the strip keeps the panes clear of the
        // lights altogether; without it (a notebook, the Space, the Library)
        // the lights reach into the pane beside the strip.
        if windowState.drawsNavigationRail, windowState.showsHomeSidebar { return 0 }
        // In full screen the controls sit in flow at the left edge, and ‹ ›
        // with the toggle reach past the strip too.
        let clearance = hasTitlebarBand ? StudioTopBar.headerLeadingClearance : StudioTopBar.fullscreenHeaderLeadingClearance
        return max(0, clearance - StudioNavigationRail.compactRailWidth)
    }

    /// What ‹ › puts back that the window state does not hold
    /// (`StudioWindowState.goBackInPlaces`): the chat, asked of this window's
    /// session store as the rail asks, and the source, through
    /// `selectArticle` without revealing the Reader — the panes put back
    /// already say what is in front.
    private func reopenPlaceContent(_ place: StudioWindowPlace) {
        let shown = place.identity
        if let sessionID = shown.chatSessionID, sessionID != windowState.chatSessionID {
            studioAssistantSessions.requestOpen(sessionID: sessionID)
        }
        if let sourceID = shown.readerArticleID, sourceID != windowState.readerArticleID,
           vm.articlesById[sourceID] != nil {
            Task { await vm.selectArticle(sourceID, in: windowState) }
        }
    }

    private var dockedChatPanel: some View {
        StudioDockedAssistantPanel(
            sessionStore: studioAssistantSessions,
            onDismiss: {
                // The hidden-tab-bar × is pane chrome, matching the close
                // control on a visible center tab strip. Beside another pane,
                // park Chat's tabs there and reclaim this pane's full width;
                // as the only pane, switch it to the Reader it also holds —
                // or, while the chat plays a walk, end the walk on New chat.
                vm.dismissCenterSurface(.chat, in: windowState)
            },
            onPopOut: popOutStudioAssistant,
            onOpenNewChatBeside: openNewChatBeside
        )
    }

    /// A new chat on handed-in context, opened in the comparison pane on the
    /// primary Chat's right so the conversation it came out of keeps its pane.
    /// A focused memory review gives the workspace back first: the review
    /// stays in its pane with its transcript and chips, and the new chat
    /// opens beside it rather than over it.
    private func openNewChatBeside(_ request: ReaderSelectionExplanationRequest) {
        comparisonAssistantSessions.requestNewChat(handingOff: request)
        withAnimation(.easeInOut(duration: 0.22)) {
            vm.leaveMemoryReviewFocus(in: windowState)
            vm.openSecondaryChatPane(atLeadingEdge: false)
        }
    }

    private var comparisonChatPanel: some View {
        StudioDockedAssistantPanel(
            sessionStore: comparisonAssistantSessions,
            onDismiss: { vm.dismissSecondaryChatPane(in: windowState) },
            onPopOut: nil,
            acceptsGlobalNavigationRequests: false
        )
    }

    private func openChatBeside(_ sessionID: String, atLeadingEdge: Bool) {
        comparisonAssistantSessions.requestOpen(sessionID: sessionID)
        withAnimation(.easeInOut(duration: 0.22)) {
            vm.openSecondaryChatPane(atLeadingEdge: atLeadingEdge)
        }
    }

    /// The morning's "Plan your day?" (`PlanTheDay`) in the window's
    /// bottom-left corner, for a window whose rail is hidden; with the rail
    /// showing, the card is in its footer, over the Now chip. Not drawn over
    /// the memory review, which this window has given itself to, nor over
    /// Getting Started, where a new learner is still setting up. "Cards to
    /// check" takes the same place once it is answered: one corner card at a
    /// time (`CardsToCheckNudge.isShown`).
    /// The corner cards stand clear of a notebook window's icon rail, whose
    /// clock and account sit in the same corner.
    private var cornerCardLeadingInset: CGFloat {
        StudioDesign.Spacing.large + StudioNavigationRail.compactRailWidth
    }

    @ViewBuilder
    private var planTheDayCard: some View {
        // A notebook window's rail is its icon strip, with no room for the
        // cards: they wait in the corner as they do with the rail hidden.
        if !windowState.showsHomeSidebar, !isMemoryReviewFocused, !showGettingStarted {
            // A card tucked this launch, or read for what it says now, waits
            // in the bell instead.
            let tray = CornerNoticeTray.shared
            let subjects = vm.inboxSubjects(planDay: DayModel.shared.planTheDayAsk)
            if let card = ActivationNotice.shared.card, tray.showsInCorner(.libraryMove, subject: subjects.subject(.libraryMove)) {
                ActivationCard(title: card.title, detail: card.detail, style: .floating)
                    .padding(.leading, cornerCardLeadingInset)
                    .padding(.bottom, StudioDesign.Spacing.large)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else if let message = StoreUpgradeSpaceNotice.shared.visibleMessage,
                      tray.showsInCorner(.storeUpgradeSpace, subject: subjects.subject(.storeUpgradeSpace)) {
                StoreUpgradeSpaceCard(message: message, style: .floating)
                    .padding(.leading, cornerCardLeadingInset)
                    .padding(.bottom, StudioDesign.Spacing.large)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else if asksToPlanTheDay, let day = DayModel.shared.planTheDayAsk,
                      tray.showsInCorner(.planTheDay, subject: subjects.subject(.planTheDay)) {
                PlanTheDayCard(day: day, style: .floating)
                    .padding(.leading, cornerCardLeadingInset)
                    .padding(.bottom, StudioDesign.Spacing.large)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else if tray.showsInCorner(.cardsToCheck, subject: subjects.subject(.cardsToCheck)), vm.showsCardsToCheckCard(
                in: windowState,
                isGettingStarted: showGettingStarted,
                asksToPlanTheDay: false,
                showsNudges: showsDraftNudges
            ), let detail = vm.cardsToCheckDetail {
                CardsToCheckCard(detail: detail, style: .floating)
                    .padding(.leading, cornerCardLeadingInset)
                    .padding(.bottom, StudioDesign.Spacing.large)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    private func studioOverlays(
        _ content: some View,
        titlebarBand: CGFloat?,
        topSafeAreaInset: CGFloat,
        bandWidth: CGFloat
    ) -> some View {
        // Centering a toggle in a frame the exact height of the visual band and
        // lifting it by the AppKit inset (the band's portion above the content)
        // puts its vertical center on the traffic lights' center line. With no
        // band (fullscreen — the toolbar hides and the inset collapses), use
        // the same in-flow header row as the center tabs.
        // That keeps every top control on one baseline.
        let band = titlebarBand ?? StudioPanelChrome.headerHeight
        let lift = titlebarBand == nil ? 0 : topSafeAreaInset
        let toggleLeading = titlebarBand == nil
            ? StudioTopBar.fullscreenLeadingControlsLeading
            : StudioTopBar.leadingControlsLeading
        return VStack(spacing: 0) {
            content
                // "Plan your day?", for a window without its rail, waits in
                // the bottom-left corner: above the audiobook player rather
                // than over it, and under Settings, since a question that
                // waits can wait for Settings to close.
                .overlay(alignment: .bottomLeading) { planTheDayCard }
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: StoreUpgradeSpaceNotice.shared.visibleMessage)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: DayModel.shared.planTheDayAsk)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: vm.cardsToCheckPile)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: vm.cardsToCheckIsPutOff)
            StudioAudiobookPlayerHost()
        }
            // The window's own controls, pinned to the top-left on the macOS
            // traffic lights' row as Codex draws them (the window hides its
            // title bar, so the content is inset below the titlebar band — the
            // negative offset lifts them up into it, right of the lights):
            // ‹ › through the places this window showed, and the sidebar
            // toggle, which folds and brings back the sidebar beside the icon
            // strip, Home's and the Space's, never the strip. Nothing else
            // stands on that corner in any state (product owner, 2026-10-12:
            // "make sure the top left looks clean at all times").
            .overlay(alignment: .topLeading) {
                HStack(spacing: StudioTopBar.leadingControlsSpacing) {
                    WindowPlaceArrows(reopen: reopenPlaceContent)
                    NavigationRailToggle(isVisible: navigationRailVisibilityBinding)
                }
                .frame(height: band)
                .padding(.leading, toggleLeading)
                .offset(y: -lift)
            }
            .overlay {
                if showGettingStarted {
                    GettingStartedGuide(isPresented: $showGettingStarted)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showGettingStarted)
            .onChange(of: showGettingStarted) { _, isShowing in
                // Closing the guide, finished or not, arms whatever source
                // watchers its steps did not already start.
                if !isShowing { vm.startProtectedSourceAutoSyncIfReady() }
            }
            .overlay {
                if showSettings {
                    SettingsOverlay(initialPane: settingsInitialPane, onDismiss: dismissSettings)
                        .equatable()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showSettings)
            // Codex's command menu (⇧⌘P) and keyboard shortcuts sheet (⌘/),
            // and every shell command the menu bar sends this window.
            .shellCommandHost(reopen: reopenPlaceContent)
            // The toast overlay is applied after every modal overlay
            // (Settings and the getting-started guide) so errors and
            // status messages are never hidden behind them.
            .studioToast(vm)
            .teamCreationPrompt()
            .sharingRightsPrompt()
            .reportOptionsSheet()
            .directionTakeSheet()
            .makeCardsSheet()
            .mnemonicReadingSheet()
            .alert("PDF Download Debug Log", isPresented: Bindable(vm).showDebugAlert) {
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(vm.debugAlertMessage, forType: .string)
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text(vm.debugAlertMessage)
            }
            .alert("Save Workspace", isPresented: $showSaveWorkspaceView) {
                TextField("Name", text: $workspaceViewName)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    _ = workspaceViews.save(
                        name: workspaceViewName,
                        windows: StudioWorkspaceWindowCoordinator.shared.captureWorkspace()
                    )
                }
                .disabled(workspaceViewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sheet(isPresented: $showManageWorkspaces) {
                ManageWorkspacesSheet(store: workspaceViews)
            }
    }

    private func presentSettings() {
        showSettings = true
    }

    private func shouldHandleWindowCommand(_ note: Notification) -> Bool {
        if let targetID = note.object as? UUID {
            return targetID == windowState.id
        }
        return StudioWindowRegistry.shared.activeState === windowState
    }

    private func dismissSettings() {
        settingsInitialPane = nil
        showSettings = false
    }

    private func popOutStudioAssistant() {
        if let studioAssistantWindow {
            vm.showAssistantOverlay = false
            if studioAssistantWindow.isMiniaturized {
                studioAssistantWindow.deminiaturize(nil)
            }
            studioAssistantWindow.makeKeyAndOrderFront(nil)
            windowState.isChatPoppedOut = true
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        var window: NSWindow!
        let content = StudioAssistantPopoutWindowContent(
            sessionStore: studioAssistantSessions,
            ownerWindowState: windowState,
            onClose: { window?.close() }
        )
        .environment(vm)
        .environment(vm.articlesStore)
        .environment(windowState.sidebarStore)
        .environment(vm.readingProgressStore)
        .dynamicTypeSize(UIZoom.size(for: uiZoomStep))
        .environment(\.uiZoomScale, UIZoom.scale(for: uiZoomStep))
        .textSelection(.enabled)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ForeverLM Chat"
        window.minSize = NSSize(width: 460, height: 360)
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()

        // The window outlives its closes (it is reopened, not rebuilt), so the
        // rail's "chat is on screen" flag tracks its visibility, not its
        // existence. Observing the window itself keeps this correct however
        // it is closed: the panel's own close, Escape, or the title bar.
        let poppedOutState = windowState
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { poppedOutState.isChatPoppedOut = false }
        }

        studioAssistantWindow = window
        vm.showAssistantOverlay = false
        window.makeKeyAndOrderFront(nil)
        windowState.isChatPoppedOut = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        // A drop does not make its window key, so ask this window, not `vm`.
        let importsBooks = windowState.sidebarStore.sidebarTab == .books
        var handled = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            handled = true
            if importsBooks && vm.bookImportsPending == 0 {
                vm.bookImportStatus = "Opening dropped book…"
            }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let candidate = item as? URL {
                    url = candidate
                } else if let value = item as? String {
                    let parsed = URL(string: value)
                    url = parsed?.isFileURL == true ? parsed : URL(fileURLWithPath: value)
                } else {
                    url = nil
                }
                Task { @MainActor in
                    if importsBooks {
                        guard let url, url.isFileURL else {
                            if vm.bookImportsPending == 0 { vm.bookImportStatus = "" }
                            let detail = error.map { ": \($0.localizedDescription)" } ?? ""
                            vm.errorMessage = "ForeverLM couldn’t read the dropped book from Finder\(detail)."
                            vm.showBookImportError = true
                            return
                        }
                        do {
                            try await vm.importBook(from: url.path)
                        } catch {
                            if vm.bookImportsPending == 0 { vm.bookImportStatus = "" }
                            vm.errorMessage = "Couldn’t import \(url.lastPathComponent): \(error.localizedDescription)"
                            vm.showBookImportError = true
                        }
                    } else if let url, url.pathExtension.lowercased() == "pdf" {
                        let displayName = url.lastPathComponent
                        PaperIngestionDiagnostics.recordDropAccepted(filename: displayName)
                        do {
                            let sourceID = try await vm.importPDF(
                                from: url.path,
                                selectInReader: false
                            )
                            PaperIngestionDiagnostics.recordDropImported(
                                filename: displayName,
                                sourceID: sourceID
                            )
                            let importedTitle = vm.articles.first(where: { $0.id == sourceID })?.title
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            vm.showToast("Imported \(importedTitle?.isEmpty == false ? importedTitle! : displayName)")
                        } catch {
                            PaperIngestionDiagnostics.recordDropFailure(
                                filename: displayName,
                                message: error.localizedDescription
                            )
                            vm.showToast(
                                "Couldn’t import \(displayName): \(error.localizedDescription)"
                            )
                        }
                    } else if !importsBooks {
                        let displayName = url?.lastPathComponent ?? "Dropped Paper.pdf"
                        let message = error?.localizedDescription
                            ?? "Finder did not provide a readable PDF file URL."
                        PaperIngestionDiagnostics.recordDropFailure(
                            filename: displayName,
                            message: message
                        )
                        vm.showToast("Couldn’t import \(displayName): \(message)")
                    }
                }
            }
        }
        return handled
    }

    @MainActor
    /// Puts back what this window showed before a relaunch the app started
    /// itself (`StudioWorkspaceWindowCoordinator.prepareForRelaunch`). Each
    /// piece goes the way a click would: the chat is asked of this window's
    /// session store, which resumes it as the rail does; the doc waits for the
    /// Docs canvas to mount; the source goes through `selectArticle` once the
    /// library is in, without revealing the Reader — the restored layout
    /// already says which tab was in front, and this must not change it.
    private func resumeWindowContent(_ content: StudioWindowContent) {
        windowState.pendingResumeContent = nil
        if let raw = content.sidebarTab, let tab = StudioSidebarTab.fromPersistedRawValue(raw) {
            windowState.sidebarStore.sidebarTab = tab
        }
        if let sessionID = content.chatSessionID {
            studioAssistantSessions.requestOpen(sessionID: sessionID)
        }
        // Both: the pending request switches a canvas that is already showing
        // something else, and the remembered doc is what a canvas built later
        // — the saved layout is applied in the same pass, and rebuilds the
        // panes — starts on.
        windowState.pendingArtifactID = content.artifactID
        if let artifactID = content.artifactID {
            windowState.openArtifactID = artifactID
        }
        guard let sourceID = content.readerSourceID else { return }
        Task {
            // Awaited by polling rather than by `ensureInitialQueueLoaded`,
            // which the launch task owns: a second caller would start a
            // second load. Bounded so a library that never finishes loading
            // cannot leave this running.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(30)
            while !vm.hasCompletedInitialQueueLoad, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // A source removed on another Mac in between is simply not there.
            guard vm.articlesById[sourceID] != nil else { return }
            await vm.selectArticle(sourceID, in: windowState)
            windowState.sidebarSelectedSourceIDs = [sourceID]
        }
    }

    private func loadStudioAtLaunch() async {
        // Text-to-speech prices a book chapter as the book it will auto-advance
        // through, and Studio is what knows a group's chapters and its title.
        // Now Playing names an audio overview's notebook.
        ArticleSpeechService.shared.audioOverviewNotebookTitleProvider = { [weak vm] artifactID in
            vm?.audioOverviewNotebookTitle(artifactID)
        }
        ArticleSpeechService.shared.bookScopeProvider = { [weak vm] groupID in
            guard let vm else { return nil }
            let chapters = vm.bookChapterArticlesInOrder(for: groupID)
            guard !chapters.isEmpty else { return nil }
            return ArticleSpeechBookScope(
                title: vm.bookDisplayName(groupID),
                chapters: chapters,
                coverPath: vm.bookCoverPaths[groupID]
            )
        }
        await vm.ensureInitialQueueLoaded()
        let needsInitialSetup = !UITestConfiguration.isUITesting
            && vm.libraryLoadErrorMessage == nil
            && !gettingStartedCompleted
            && !gettingStartedDismissed
            && vm.activeArticles.isEmpty
        // A first launch imports nothing behind the setup guide's back: the
        // Reading List, Apple Podcasts and Zoom watchers wait until the guide
        // reaches their step or closes, so a new library does not fill with
        // someone's whole Reading List (and its fetch errors) before they
        // have chosen storage or agreed to AI spending.
        if needsInitialSetup {
            // Which browsers' Reading Lists to import is the learner's choice
            // in setup's Articles step, not a default of all three.
            ReadingListBrowser.holdUntilChosen()
        } else {
            vm.startProtectedSourceAutoSyncIfReady()
        }
        AutomaticSourceAudioGenerationService.shared.schedule(vm.activeArticles)
        if !UITestConfiguration.isUITesting {
            // The free-trial key is kept in the Keychain, so this now catches
            // only the real gap: routed to Meta with no credential to use —
            // a forgotten key, or a different Mac. An ordinary relaunch during
            // the trial must never reopen setup.
            let needsMetaKey = (
                KeychainService.aiProvider == .meta
                    || KeychainService.backgroundTaskProvider == .meta
            ) && !KeychainService.hasUsableTextProviderCredentials(for: .meta)
            if needsInitialSetup || !backgroundAIUsageConsented || needsMetaKey {
                showGettingStarted = true
                // The guide's launch still has to count as this build being
                // seen, or the next launch of a fresh install reads as an
                // update and opens What's New for a version it never had.
                whatsNew.deferToGettingStarted()
            }
            // The first launch after an update shows what the release added.
            // The Getting Started guide owns a first launch, so this waits for
            // it to stand down; a library that already exists — or a guide
            // already finished — marks an install the notes are news to.
            if !showGettingStarted {
                whatsNew.presentAfterLaunchIfNeeded(
                    in: windowState,
                    isExistingInstall: gettingStartedCompleted
                        || gettingStartedDismissed
                        || !vm.activeArticles.isEmpty
                )
            }
        }
        vm.startAutoRefreshIfNeeded()
        // Scheduled tasks run as ordinary chat turns, so the runner needs the
        // same article catalog and Notebook lookup Studio uses. Installing them
        // here keeps the runner free of any dependency on the view model.
        ScheduledTaskRunner.shared.articleProvider = { [weak vm] sourceIDs in
            guard let vm else { return [] }
            return sourceIDs
                .compactMap { vm.articlesById[$0] }
                .filter { vm.isSourceIncludedInKnowledge($0) }
        }
        ScheduledTaskRunner.shared.notebookLookup = { [weak vm] goalID in
            vm?.notebook(id: goalID) != nil
        }
        ScheduledTaskRunner.shared.start()
        // Today's cards, selected at the morning's hour when the learner has
        // asked for the review to be ready, and the reminder that says so.
        MemoryReviewPreparationRunner.shared.start()
        // The evening half: the day closed at its hour, the day's chats and
        // reading folded in, and the next morning's cards counted.
        DayCloseRunner.shared.start()
        // Followed journals: checked when due, new articles offered to Notebooks.
        JournalWatchRunner.shared.start()
        // A balance that returned while the app was closed — or on the other
        // Mac — posts no restore event here, so a source parked for want of
        // credit would stay parked across launches. Off the launch path: this
        // is a no-op unless something is actually waiting on it.
        Task { await vm.resumeSourcesPausedByEmptyAIBalance() }
    }

    private var studioGeometryContent: some View {
        // The window uses a hidden title bar plus an empty unified toolbar
        // (StudioWindowChrome), so the content sits below a ~52pt titlebar band
        // with the traffic lights centered in it, and the sidebar toggle, the
        // reader title and the source tabs share the lights' center line.
        // StudioTopBar.extraBandHeight can extend the bar below the band; the
        // chrome then re-centers the lights in the taller bar. Measuring from
        // the top safe-area inset (instead of hardcoding it) keeps the
        // alignment exact; in fullscreen the inset collapses and the
        // band-dependent chrome falls back to its regular in-content layout.
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            let titlebarBand: CGFloat? = topInset >= 20 ? topInset + StudioTopBar.extraBandHeight : nil
            studioOverlays(studioRootLayout, titlebarBand: titlebarBand, topSafeAreaInset: topInset, bandWidth: geo.size.width)
                .onChange(of: topInset, initial: true) { _, inset in
                    measuredTopSafeAreaInset = inset
                }
                .environment(\.studioTitlebarBandHeight, titlebarBand)
                .environment(\.studioCenterPaneHeaderLeadingInset, headerLeadingClearance(hasTitlebarBand: titlebarBand != nil))
                .background {
                    // Native fullscreen retains a small screen-edge safe area
                    // even after the empty toolbar is hidden. Paint behind that
                    // inset so transparent header chrome cannot expose the
                    // window's black backing as an outline. Only the background
                    // ignores the safe area; the List-bearing view hierarchy
                    // deliberately does not (see the center-area note above).
                    StudioInsetCardStyle.chrome
                        .ignoresSafeArea()
                }
        }
    }

    /// The notebook's name while the window holds one; the app's otherwise.
    private var windowTitle: String {
        guard let notebookID = windowState.NotebookID,
              let title = vm.notebook(id: notebookID)?.title,
              !title.isEmpty else { return "ForeverLM Studio" }
        return title
    }

    /// The page side chat's store, and how it asks whether a docked pane shows
    /// a chat, so one chat is never drawn by the card and a pane at once.
    private var pageSideChatHosting: PageSideChatHosting {
        let dock = studioAssistantSessions
        let comparison = comparisonAssistantSessions
        return PageSideChatHosting(
            store: pageSideChatSessions,
            isShownElsewhere: { sessionID in
                dock.activeSessionID == sessionID || comparison.activeSessionID == sessionID
            }
        )
    }

    private var studioWindowContent: some View {
        studioGeometryContent
            .background(StudioWindowChrome(measuredTopSafeAreaInset: measuredTopSafeAreaInset))
            .environment(\.pageSideChatHosting, pageSideChatHosting)
            // The window is named for its notebook while it holds one, so
            // VoiceOver and the Window menu say which notebook it is.
            .navigationTitle(windowTitle)
            .task(id: account.hasAccountAccess) {
                // ContentView keeps this graph alive behind the mandatory Apple
                // account wall so validation cannot destroy it mid-transaction.
                // Do not bootstrap the library until the wall has actually opened.
                guard account.hasAccountAccess || UITestConfiguration.isUITesting else { return }
                await loadStudioAtLaunch()
            }
            .onDrop(of: supportedBookImportDropTypes, isTargeted: nil, perform: handleFileDrop)
            // The window's chat is view state here; the last-session record
            // needs its id, so the window state carries a mirror of it.
            .onChange(of: studioAssistantSessions.activeSessionID, initial: true) { _, sessionID in
                windowState.chatSessionID = sessionID
                // The docked pane took a chat the page's card may hold.
                if let sessionID { pageSideChatSessions.releaseChat(sessionID) }
            }
            .onChange(of: comparisonAssistantSessions.activeSessionID) { _, sessionID in
                if let sessionID { pageSideChatSessions.releaseChat(sessionID) }
            }
            // `initial` because the coordinator may have set this before this
            // view existed, or may set it later: registration and appearance
            // are not ordered against each other.
            .onChange(of: windowState.pendingResumeContent, initial: true) { _, content in
                guard let content else { return }
                resumeWindowContent(content)
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenStudioSettings)) { note in
                guard StudioWindowRegistry.shared.activeState === windowState else { return }
                settingsInitialPane = note.object as? SettingsPane
                presentSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                whatsNew.presentOnRequest(in: windowState)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showGettingStarted)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                showGettingStarted = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestEditSourceDetails)) { note in
                guard SourceDetailsEditRequest.isFor(
                    note,
                    windowID: windowState.id,
                    isKeyWindow: StudioWindowRegistry.shared.activeState === windowState
                ),
                    let id = note.object as? String,
                    vm.articles.contains(where: { $0.id == id }) else { return }
                editingSourceDetailsID = id
            }
            .sheet(isPresented: Binding(
                get: { editingSourceDetailsID != nil },
                set: { if !$0 { editingSourceDetailsID = nil } }
            )) {
                if let id = editingSourceDetailsID,
                   let article = vm.articles.first(where: { $0.id == id }) {
                    SourceDetailsEditor(vm: vm, article: article)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { whatsNew.isPresenting(in: windowState) },
                    // Only Continue confirms the notes; a false written here
                    // is SwiftUI tearing the sheet down with its window.
                    set: { if !$0 { whatsNew.sheetWasTornDown(in: windowState) } }
                )
            ) {
                WhatsNewSheet(entries: whatsNew.entries) {
                    whatsNew.confirm()
                }
            }
            // The morning selected today's cards: the Memory row's help and
            // the Memory pane read the counts again.
            .onReceive(NotificationCenter.default.publisher(for: .memoryReviewDidPrepare)) { _ in
                guard StudioWindowRegistry.shared.activeState === windowState else { return }
                Task { await vm.refreshMemoryCardCounts() }
            }
            // The daily reminder and the Today menu: the Memory pane's
            // review of every notebook, whose Start Review is the way in.
            .onReceive(NotificationCenter.default.publisher(for: .requestMemoryReview)) { _ in
                guard StudioWindowRegistry.shared.activeState === windowState else { return }
                vm.inWindow(windowState) { vm.requestCardReview(scope: .allNotebooks) }
            }
            // The morning-after cards banner: the drafts that wait in To Check
            // over every notebook, or the Make Cards sheet for the finished
            // sources that have none.
            .onReceive(NotificationCenter.default.publisher(for: .requestCardsFromFinished)) { note in
                guard StudioWindowRegistry.shared.activeState === windowState else { return }
                let undrafted = note.object as? [String] ?? []
                vm.inWindow(windowState) {
                    if undrafted.isEmpty {
                        vm.openCardsToCheck(scope: .allNotebooks)
                    } else {
                        vm.presentMakeCards(notebookID: nil, sourceIDs: undrafted)
                    }
                }
            }
            // A journal check found articles for a Notebook: say so once, in the
            // active window, and let the Notebook's pool hold the decision.
            .onReceive(NotificationCenter.default.publisher(for: .journalWatchDidFindMatches)) { note in
                guard StudioWindowRegistry.shared.activeState === windowState else { return }
                let count = note.userInfo?[JournalWatchNotificationInfo.matchCountKey] as? Int ?? 0
                let notebookIDs = note.userInfo?[JournalWatchNotificationInfo.notebookIDsKey] as? [String] ?? []
                guard count > 0 else { return }
                if notebookIDs.count == 1, let title = notebookIDs.first.flatMap({ vm.notebook(id: $0)?.title }) {
                    vm.showToast(count == 1 ? "1 new article from your feeds for \(title)" : "\(count) new articles from your feeds for \(title)")
                } else {
                    vm.showToast("\(count) new articles from your feeds for your notebooks")
                }
            }
            // Another device had merged a notebook first that this Mac merged
            // or split too: say where it leads now, once, in the active window.
            .onReceive(NotificationCenter.default.publisher(for: NotebookFoldNotices.didArrive)) { note in
                guard StudioWindowRegistry.shared.activeState === windowState,
                      let message = note.userInfo?[NotebookFoldNotices.messageKey] as? String else { return }
                vm.showToast(message)
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestNotebookJournalSuggestions)) { note in
                guard StudioWindowRegistry.shared.activeState === windowState else { return }
                vm.inWindow(windowState) { vm.openNotebookJournalSuggestions(notebookID: note.object as? String) }
            }
    }

    private var studioAccountEventContent: some View {
        studioWindowContent
            .onReceive(NotificationCenter.default.publisher(for: .managedAICreditsEmpty)) { _ in
                account.recordCreditsExhausted()

                // A burst of background jobs can all discover the empty balance at once,
                // and more work may fail after the first sheet is dismissed. Prompt once
                // for the whole empty-balance episode. Settings is itself the resolution
                // surface, so never cover it with another billing prompt.
                guard !handledCreditsEmptyEpisode else { return }
                handledCreditsEmptyEpisode = true
                guard !showSettings else { return }
                showCreditsEmptyAlert = true
            }
            .onChange(of: account.creditsAreEmpty) { _, creditsAreEmpty in
                guard !creditsAreEmpty else { return }
                handledCreditsEmptyEpisode = false
                showCreditsEmptyAlert = false
            }
            // Plugins are a place, not a Settings pane: a link to one from
            // Settings, a banner or a chat closes Settings and opens the place.
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenPluginsPlace)) { note in
                guard StudioWindowRegistry.shared.activeState === windowState else { return }
                if showSettings { dismissSettings() }
                vm.openPluginsPlace(note.object as? PluginPage, in: windowState)
            }
    }

    private var studioNavigationEventContent: some View {
        studioAccountEventContent
            .onReceive(NotificationCenter.default.publisher(for: .toggleStudioAssistant)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                // Reopening a closed chat also restores the navigation rail,
                // since closing chat hid both together.
                let wasChatClosed = !vm.showAssistantOverlay
                withAnimation(.easeInOut(duration: 0.22)) {
                    vm.handleAssistantShortcut()
                    if wasChatClosed {
                        windowState.navigationRailVisible = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openStudioReader)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    vm.handleReaderShortcut()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSourceReader)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                guard let sourceID = note.userInfo?[SiriSourceNavigation.sourceIDKey] as? String,
                      !sourceID.isEmpty else { return }
                openWindow(id: "source-reader", value: sourceID)
            }
            // View ▸ Workspaces. Restoring arranges every Studio window, so the
            // window the command lands in only opens the ones that are missing.
            .onReceive(NotificationCenter.default.publisher(for: .saveStudioWorkspace)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                workspaceViewName = ""
                showSaveWorkspaceView = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .manageStudioWorkspaces)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                showManageWorkspaces = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .applyStudioWorkspace)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                guard let id = note.userInfo?[StudioWorkspaceMenuCommand.workspaceIDKey] as? String,
                      let savedView = workspaceViews.views.first(where: { $0.id == id }) else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    let newWindowCount = StudioWorkspaceWindowCoordinator.shared.restore(
                        savedView,
                        invokedBy: windowState
                    )
                    for _ in 0..<newWindowCount {
                        openWindow(id: "studio")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openStudioNotebook)) { note in
                guard shouldHandleWindowCommand(note),
                      let notebookID = note.userInfo?[SiriNotebookNavigation.notebookIDKey] as? String else { return }
                // Siri named the notebook: it opens in this window, as a
                // click opens it.
                vm.inWindow(windowState) { vm.openNotebookInReader(notebookID) }
            }
            // View ▸ Space (⌘P) and Siri's Show Notebooks: the Space's All
            // list, here.
            .onReceive(NotificationCenter.default.publisher(for: .openStudioSpace)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                vm.inWindow(windowState) { vm.showSpaceAll(in: windowState) }
            }
            // View ▸ Library (⇧⌘L): the full-window Library, here.
            .onReceive(NotificationCenter.default.publisher(for: .openStudioLibrary)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    vm.openLibraryView(in: windowState)
                }
            }
            // The Today menu's Plan the Day in Chat, the chip's, and the
            // "Plan your day?" notification: the chat that plans the day by
            // writing events into the Mac's Calendar. Today until the
            // afternoon, tomorrow after it.
            .onReceive(NotificationCenter.default.publisher(for: .requestPlanTheDayChat)) { note in
                guard shouldHandleWindowCommand(note) else { return }
                let plansTomorrow = Calendar.current.component(.hour, from: Date()) >= DayPlan.planTomorrowFromHour
                vm.inWindow(windowState) {
                    vm.requestPlanDayChat(request: ReviewSlashCommandParser.planDayRequest(plansTomorrow ? "tomorrow" : "today"))
                }
            }
            // The chip's Write it up and the Today menu's Write Up the Bout…:
            // the sheet opens in the window in front.
            .onReceive(NotificationCenter.default.publisher(for: .requestBoutWriteUp)) { note in
                guard shouldHandleWindowCommand(note), let bout = DayModel.shared.liveBout else { return }
                writeUpBoutID = bout.id
            }
            .sheet(isPresented: Binding(
                get: { writeUpBoutID.flatMap { DayModel.shared.bout(withID: $0) } != nil },
                set: { if !$0 { writeUpBoutID = nil } }
            )) {
                if let id = writeUpBoutID, let bout = DayModel.shared.bout(withID: id) {
                    LearningBoutWriteUpSheet(
                        bout: bout,
                        onSave: { learned, unclear in
                            do {
                                _ = try await DayModel.shared.writeUpBout(id, learned: learned, unclear: unclear.isEmpty ? nil : unclear)
                                return true
                            } catch {
                                vm.showToast(error.localizedDescription)
                                return false
                            }
                        },
                        onCancel: { writeUpBoutID = nil }
                    )
                }
            }
            // The chip's and the Today menu's Start Pomodoro Timer…: the goal
            // and the minutes are asked in the window in front, then the
            // clock starts.
            .onReceive(NotificationCenter.default.publisher(for: .requestBoutStart)) { note in
                guard shouldHandleWindowCommand(note),
                      DayModel.shared.liveBout == nil,
                      let request = note.userInfo?["request"] as? BoutStartRequest else { return }
                boutStartRequest = request
            }
            .sheet(item: $boutStartRequest) { request in
                LearningBoutStartSheet(
                    request: request,
                    onStart: { goal, minutes in
                        do {
                            _ = try await DayModel.shared.startBout(
                                title: goal,
                                minutes: minutes,
                                notebookID: request.notebookID,
                                sourceIDs: request.sourceIDs
                            )
                            return true
                        } catch {
                            vm.showToast(error.localizedDescription)
                            return false
                        }
                    },
                    onCancel: { boutStartRequest = nil }
                )
            }
            // The chip and the Today menu read the day before any window has
            // shown the Activity pane. Idempotent.
            .task { DayModel.shared.start() }
    }

    private var studioDataEventContent: some View {
        studioNavigationEventContent
            .onReceive(NotificationCenter.default.publisher(for: ScreenRecordMode.didChangeNotification)) { _ in
                // Screen record mode (admin only) turned on or off, changed its
                // Notebook, or the proxy's admin answer changed.
                vm.refreshScreenRecordScope()
            }
            .onChange(of: vm.articles.count) { _, _ in
                AutomaticSourceAudioGenerationService.shared.schedule(vm.activeArticles)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .automaticSourceAudioCandidateDidChange)
                    .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            ) { _ in
                AutomaticSourceAudioGenerationService.shared.schedule(vm.activeArticles)
            }
            .onReceive(NotificationCenter.default.publisher(for: .automaticSourceAudioPreferencesChanged)) { _ in
                AutomaticSourceAudioGenerationService.shared.schedule(
                    vm.activeArticles,
                    retryFailures: true
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: PreferenceStore.didChangeRemotely)) { note in
                let keys = note.userInfo?[PreferenceStore.changedKeysKey] as? Set<String> ?? []
                // A space or collection deleted, renamed or filled elsewhere.
                vm.reloadGroupingRows(afterRemoteChangeOf: keys)
                guard SourceAudioAutomation.automatable.contains(where: {
                    keys.contains($0.preferenceKey)
                }) else { return }
                AutomaticSourceAudioGenerationService.shared.schedule(
                    vm.activeArticles,
                    retryFailures: true
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .foreverLMDataDidChange)
                    .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            ) { _ in
                // The assistant (or an external MCP client) mutated persisted state;
                // reload so panels like Notebooks reflect it. Debounced so a turn
                // with several tool calls collapses into a single refresh.
                Task {
                    await vm.refreshAfterCloudKitRemoteChange()
                    // This window's notebook: each window refreshes the one
                    // it holds, not the key window's.
                    if let notebookID = windowState.NotebookID ?? vm.activeNotebookId {
                        await vm.refreshNotebookFiles(notebookID: notebookID, force: true)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sourceListeningCompletionDidChange)) { note in
                let sourceIDs: [String]
                if let sourceID = note.object as? String, !sourceID.isEmpty {
                    sourceIDs = [sourceID]
                } else if let ids = note.object as? [String] {
                    sourceIDs = ids.filter { !$0.isEmpty }
                } else {
                    sourceIDs = []
                }
                guard !sourceIDs.isEmpty else { return }
                Task { await vm.reflectExternalActivityCompletion(sourceIDs) }
                // Listened to the end: a deliberate finish, whose cards are
                // drafted in the background. Once, from the active window.
                let active = StudioWindowRegistry.shared.activeState
                if active == nil || active === windowState {
                    vm.sourcesWereFinished(sourceIDs)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // CloudKit pushes are opportunistic. Pull once on activation as
                // the event-driven recovery path so phone-authored consumption
                // and Schedule activity appear even when a push was missed.
                vm.syncCloudKitOnActivation()
                // Switching back to the app is the moment to pull the latest from
                // upstream plugins (likes, bookmarks, meetings) — event-driven,
                // not poll-driven. Silent, cooldown-limited, and a no-op while the
                // initial load is still running, so launch stays untouched.
                vm.syncTabPluginsOnEvent(nil)
                AutomaticSourceAudioGenerationService.shared.schedule(
                    vm.activeArticles,
                    retryFailures: true
                )
            }
            .sheet(isPresented: $showCreditsEmptyAlert) {
                CreditsEmptySheet()
            }
    }

    var body: some View {
        // Keep the root associated type small. The full Studio modifier chain is
        // intentionally split across computed properties for readability, but
        // exposing that entire nested generic type as `View.Body` made Swift's
        // runtime recursively instantiate its metadata during the first render.
        // Debug builds could exhaust the stack and terminate with SIGBUS before
        // drawing a window. This single root erasure is outside the frequently
        // diffed panel hierarchy, so its stability matters more than preserving
        // the implementation type here.
        AnyView(
            studioDataEventContent
                // Below this width even a chrome-free two-pane workspace
                // cannot honor the pane minima. AppKit may restore an older,
                // narrower window frame; the content minimum repairs it before
                // the user can resize the window into overlapping controls.
                .frame(minWidth: StudioCenterTabGroupSizing.minimumWindowContentWidth)
        )
    }
}

/// View ▸ Workspaces reaches the window through these. Save and Manage put up
/// the window's own alert and sheet; Apply carries the saved workspace's id.
extension Notification.Name {
    static let saveStudioWorkspace = Notification.Name("saveStudioWorkspace")
    static let manageStudioWorkspaces = Notification.Name("manageStudioWorkspaces")
    static let applyStudioWorkspace = Notification.Name("applyStudioWorkspace")
}

enum StudioWorkspaceMenuCommand {
    static let workspaceIDKey = "workspaceID"
}

/// Rename and delete saved workspaces. Each row is its name, editable in
/// place — Return or leaving the field commits, and a rejected name (empty, or
/// one another workspace already holds) snaps back to what it was. Delete acts
/// immediately: a workspace is a layout, cheap to save again, and the list
/// shrinking is the confirmation.
private struct ManageWorkspacesSheet: View {
    let store: StudioWorkspaceViewStore

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: String] = [:]
    @FocusState private var focusedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Manage Workspaces")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 12)

            if store.views.isEmpty {
                Text("No saved workspaces.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
                    ForEach(store.views) { savedView in
                        row(for: savedView)
                        if savedView.id != store.views.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer(minLength: 0)
                Button("Done") {
                    commitFocusedDraft()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 400)
        .onChange(of: focusedID) { previous, _ in
            if let previous, let view = store.views.first(where: { $0.id == previous }) {
                commit(view)
            }
        }
    }

    private func row(for savedView: StudioSavedWorkspaceView) -> some View {
        HStack(spacing: 8) {
            TextField("Name", text: draftBinding(for: savedView))
                .textFieldStyle(.plain)
                .focused($focusedID, equals: savedView.id)
                .onSubmit { commit(savedView) }
                .accessibilityLabel("Workspace name")

            Button(role: .destructive) {
                drafts[savedView.id] = nil
                store.delete(savedView)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete \(savedView.name)")
            .accessibilityLabel("Delete \(savedView.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func draftBinding(for savedView: StudioSavedWorkspaceView) -> Binding<String> {
        Binding(
            get: { drafts[savedView.id] ?? savedView.name },
            set: { drafts[savedView.id] = $0 }
        )
    }

    private func commit(_ savedView: StudioSavedWorkspaceView) {
        guard let draft = drafts[savedView.id] else { return }
        // Success shows the new name from the store; a refusal drops the draft
        // so the field reads the stored name again.
        _ = store.rename(savedView, to: draft)
        drafts[savedView.id] = nil
    }

    private func commitFocusedDraft() {
        guard let focusedID, let view = store.views.first(where: { $0.id == focusedID }) else { return }
        commit(view)
    }
}

private struct CreditsEmptySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 52, height: 52)
            .padding(.bottom, 16)

            Text("Add your OpenRouter key")
                .font(.title2.weight(.semibold))

            Text("AI features run on your own OpenRouter API key, billed by OpenRouter at cost, and ForeverLM adds nothing. Add your key in Settings → AI Usage.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Later") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Key") {
                    dismiss()
                    NotificationCenter.default.post(
                        name: .requestOpenStudioSettings,
                        object: SettingsPane.aiUsage
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 24)
        }
        .padding(28)
        .frame(width: 360)
    }
}

/// The status banner at the bottom of the Studio window.
///
/// The same banner carries "Copied source ID" and a provider's refusal naming the
/// model and the setting to change. The second kind is worth reading twice and
/// often worth pasting into a note or a bug report, so the text is selectable,
/// copies in one click, and can be closed rather than only ever timed out.
/// `StudioViewModel.toastDuration(for:)` decides how long it waits on its own, and
/// the pointer resting on it stops the clock entirely.
///
/// When the message reports something reversible — "Hid <title>" — the banner
/// also carries Undo, so the click that hid the wrong paper is taken back from
/// the notice itself rather than from the Hidden Items list.
private struct StudioToastBanner: View {
    let message: String
    var onUndo: (() -> Void)? = nil
    /// A second offer under its own title — "Open here" on a notice that the
    /// thing opened in another window — for windows that can act on it.
    var action: (title: String, run: () -> Void)? = nil
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message)
                .font(.subheadline.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let onUndo {
                Button("Undo", action: onUndo)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.hoverWash(tint: Color.accentColor))
                    .accessibilityIdentifier("studio.toast.undo")
                    .padding(.top, -2)
            }

            if let action {
                Button(action.title, action: action.run)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.hoverWash(tint: Color.accentColor))
                    .accessibilityIdentifier("studio.toast.action")
                    .padding(.top, -2)
            }

            // Equal square boxes with a circular wash: `doc.on.doc` and `xmark`
            // have very different glyph widths, so left to size themselves they
            // read as a mismatched pair and their default washes overlap.
            HStack(spacing: 4) {
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .zoomedSystemFont(size: 11, weight: .semibold)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .help("Copy this message")
                .accessibilityLabel("Copy message")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                }
                .help("Dismiss")
                .accessibilityLabel("Dismiss message")
            }
            .buttonStyle(.hoverWash(in: Circle(), inset: 0, opacity: 0.12))
            // Centre the glyphs on the message's first line rather than on the
            // top of its line box.
            .padding(.top, -2)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private struct StudioDeletionUndoBanner: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.hoverWash(tint: Color.accentColor))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
    }
}

extension View {
    /// Pins the shared Studio status banner to the bottom of this view's window.
    ///
    /// `StudioViewModel.showToast(_:)` fires from the source-reader and assistant
    /// pop-out windows as well as the main Studio window, but only the main window
    /// used to render the banner — messages raised from a secondary window (a PDF
    /// download result, a review command's usage hint) were silently dropped. Each
    /// window that can raise a toast now carries this overlay so the message lands
    /// where the action happened.
    ///
    /// There is a single shared `toastMessage`, so the same text appears in every
    /// open window at once and dismissing or hovering it in one governs them all —
    /// acceptable because it is one message, and scoping per window would mean
    /// threading a window identity through every `showToast` call site. The
    /// one thing that is per window is the banner's action: "Open here" means
    /// the Studio window it was pressed in, and a window with no
    /// `StudioWindowState` in its environment — a popped-out Reader — has
    /// nowhere to open it, so shows no such button.
    func studioToast(_ vm: StudioViewModel) -> some View {
        modifier(StudioToastOverlay(vm: vm))
    }
}

private struct StudioToastOverlay: ViewModifier {
    let vm: StudioViewModel
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var toastAction: (title: String, run: () -> Void)? {
        guard let action = vm.toastAction, let windowState else { return nil }
        return (action.title, { Task { await vm.runToastAction(in: windowState) } })
    }

    /// With Reduce Motion on, a card fades in and out rather than sliding.
    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    // Background work is an icon in the strip, never a stack
                    // of banners here (2026-10-06, 2026-10-13;
                    // StudioWorkButton). What follows asks the learner for
                    // something, so keeps its own card.

                    // A warning label is never filmed: screen record mode keeps
                    // the publisher check waiting off screen (Settings › Data & Privacy
                    // or the app menu turns the mode off to answer it).
                    if let verification = WebVerificationRequests.shared.latest,
                       !vm.isScreenRecordModeActive {
                        StudioWebVerificationBanner(
                            request: verification,
                            waiting: WebVerificationRequests.shared.pending.count
                        )
                        .transition(cardTransition)
                    }
                    if let deletion = vm.pendingDeletionNotices.last {
                        StudioDeletionUndoBanner(message: deletion.message) {
                            Task { await vm.undoLatestDeletion() }
                        }
                        .transition(cardTransition)
                    }
                    if let toast = vm.toastMessage {
                        StudioToastBanner(
                            message: toast,
                            onUndo: vm.toastUndo == nil ? nil : { Task { await vm.undoToast() } },
                            action: toastAction,
                            onDismiss: { vm.dismissToast() }
                        )
                        .onHover { vm.setToastHovered($0) }
                        .transition(cardTransition)
                    }
                }
                .padding(.bottom, 20)
            }
            .animation(.easeInOut(duration: 0.3), value: vm.toastMessage)
            .animation(.easeInOut(duration: 0.3), value: vm.pendingDeletionNotices.last?.id)
            .animation(.easeInOut(duration: 0.3), value: WebVerificationRequests.shared.latest?.id)
    }
}

/// Offers the browser window for a download that hit a publisher check, instead
/// of that window opening itself over whatever the user was doing. Papers
/// download headless; this is the only thing that surfaces when one cannot.
private struct StudioWebVerificationBanner: View {
    let request: WebVerificationRequests.Request
    /// Total parked requests, so a batch of blocked downloads says so once.
    let waiting: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.message)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if let detail = request.detail, !detail.isEmpty {
                    Text(waiting > 1 ? "\(detail) · \(waiting - 1) more waiting" : detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if waiting > 1 {
                    Text("\(waiting - 1) more waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Skip") { WebVerificationRequests.shared.skip(request.id) }
                .font(.subheadline)
                .buttonStyle(.hoverWash(tint: Color.accentColor))

            Button("Open") { WebVerificationRequests.shared.open(request.id) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.hoverWash(tint: Color.accentColor))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
    }
}

private struct StudioAssistantPopoutWindowContent: View {
    let sessionStore: StudioAssistantSessionStore
    /// The Studio window this chat was popped out of; requests made in that
    /// window reach this pane, requests made in another window do not. While
    /// this window is key it stands for that one, so a request made in here —
    /// forking a chat, say — is routed as if made there and shows in place.
    let ownerWindowState: StudioWindowState
    let onClose: () -> Void
    @Environment(StudioViewModel.self) private var vm

    var body: some View {
        InternalReviewPanel(
            sessionStore: sessionStore,
            onDismiss: onClose,
            fillsAvailableSpace: true,
            expandsChatContent: true,
            ownerWindowID: ownerWindowState.id
        )
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(StudioWindowKeyAttachment.standing(for: ownerWindowState))
        .onExitCommand(perform: onClose)
        // InternalReviewPanel raises toasts through the same shared vm;
        // without this the pop-out's own messages would render only on the main
        // Studio window and be missed here.
        .studioToast(vm)
    }
}

struct StudioActivityStatusRow: View {
    let message: String
    let systemImage: String
    var textStyle: Font = .caption
    var iconColor: Color = .accentColor

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(message)
                .font(textStyle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sidebar Tab Icon

struct SidebarTabIcon: View {
    let tab: StudioSidebarTab
    let showLabel: Bool
    var isRoomy = false
    var badgeCount = 0
    /// A plain red dot at the badge position, for a tab whose plugin needs
    /// the learner's attention but has nothing to count — an X bookmark sync
    /// that failed, say. The string is what the dot says to accessibility; the
    /// tab's own tooltip carries it for sighted users. Ignored while a count
    /// badge is showing, since both occupy the same corner.
    var attentionLabel: String? = nil
    /// Renders the glyph in the tab's identity color regardless of selection,
    /// matching the full-color brand icons used by plugin tabs. The label
    /// keeps inheriting the outer foreground so selection still reads there.
    var colorfulIcon = false
    /// Draws the type's SF Symbol (X its bare logo) in the inherited
    /// foreground instead of the full-colour badge: the Library's tab
    /// strip, its kind chips and the Customize popover, where the
    /// list is monochrome and selection reads as primary over secondary
    /// (docs/ui-design.md, "Lists are monochrome"; the product owner, 2026-10-06, "kind
    /// of like the chatgpt app"). Overrides `colorfulIcon`.
    var monochrome = false
    /// User-selected size multiplier (SourceTabIconSize.scale).
    var iconScale: CGFloat = 1
    /// The full-window Library's chip: the glyph beside the name rather than
    /// over it, with the badge or dot after the name instead of on the
    /// glyph's corner.
    var isChip = false

    private var iconSize: CGFloat {
        let base: CGFloat
        if isChip {
            base = 16
        } else if showLabel {
            base = isRoomy ? 20 : 14
        } else {
            // Without labels the icon gets the label's space too, so it grows to
            // fill more of the tab square instead of floating in empty padding.
            base = isRoomy ? 27 : 22
        }
        return base * iconScale
    }

    private var symbolFont: Font {
        if isChip {
            return .system(size: 14 * iconScale)
        }
        if showLabel {
            if iconScale == 1 {
                return isRoomy ? .title3 : .body
            }
            return .system(size: (isRoomy ? 15 : 13) * iconScale)
        }
        return .system(size: (isRoomy ? 23 : 19) * iconScale)
    }

    private var glyphStyle: AnyShapeStyle {
        colorfulIcon && !monochrome ? AnyShapeStyle(tab.color) : AnyShapeStyle(.foreground)
    }

    var body: some View {
        Group {
            if isChip {
                chipBody
            } else {
                VStack(spacing: isRoomy ? 3 : 2) {
                    iconView
                    if showLabel {
                        Text(tab.rawValue)
                            .zoomedSystemFont(size: isRoomy ? 10 : 9, weight: isRoomy ? .medium : .regular)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .accessibilityLabel(tab.rawValue)
    }

    private var chipBody: some View {
        HStack(spacing: 6) {
            glyph
            // The X logo is the name already; "X X" says it twice.
            if showLabel, tab != .xPosts {
                Text(tab.rawValue)
                    .zoomedSystemFont(size: 13, weight: .medium)
            }
            if badgeCount > 0 {
                Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(.red, in: Capsule())
                    .textSelection(.disabled)
                    .accessibilityLabel("\(badgeCount) papers without PDF")
            } else if let attentionLabel {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(attentionLabel)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var glyph: some View {
        if tab == .xPosts {
            // The bare X glyph fills its whole frame, while the brand badges
            // carry built-in padding, so at an equal box the X reads heavier
            // than its neighbors. Nudge it down a touch to match their weight;
            // beside the outline symbols of the monochrome strip, a touch more.
            let scale: CGFloat = monochrome ? 0.75 : 0.85
            XLogoShape()
                .fill(glyphStyle, style: FillStyle(eoFill: true))
                .frame(width: iconSize * scale, height: iconSize * scale)
        } else if !monochrome, let assetName = tab.iconAsset {
            Image(assetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
        } else {
            // Same box the brand icons get, so every tab's label sits on the
            // same baseline instead of drifting with the glyph's own height.
            Image(systemName: tab.icon)
                .font(symbolFont)
                .foregroundStyle(glyphStyle)
                .frame(height: iconSize)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack(alignment: .topTrailing) {
            glyph

            if badgeCount > 0 {
                Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                    .zoomedSystemFont(size: isRoomy ? 8 : 7, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 3)
                    .frame(minWidth: isRoomy ? 14 : 12, minHeight: isRoomy ? 14 : 12)
                    .background(.red, in: Capsule())
                    .offset(x: iconSize / 2 + (isRoomy ? 0 : 1), y: isRoomy ? -7 : -6)
                    // Selectable text cannot carry its own AX label on macOS; see
                    // AGENTS.md, "Text that speaks for itself".
                    .textSelection(.disabled)
                    .accessibilityLabel("\(badgeCount) papers without PDF")
            } else if let attentionLabel {
                Circle()
                    .fill(.red)
                    .frame(width: isRoomy ? 9 : 8, height: isRoomy ? 9 : 8)
                    .offset(x: iconSize / 2 + (isRoomy ? 1 : 2), y: isRoomy ? -4 : -3)
                    .accessibilityLabel(attentionLabel)
            }
        }
    }
}

// MARK: - Sidebar


/// The window's shell as Codex draws it (product owner, 2026-10-07: "this top left
/// still looks terrible", "make it look more like codex"). One quiet chrome
/// surface holds the icon strip, the whole titlebar band across the window and
/// the gutters at the trailing and bottom edges; everything else is one card
/// on it, starting under the band with a rounded top-left corner where it
/// meets the strip. The traffic lights, the sidebar toggle and every pane's
/// chrome line sit on the band's chrome, as Codex's lights, arrows and thread
/// title do, so no corner has to step around the lights.
enum StudioInsetCardStyle {
    static let cornerRadius: CGFloat = 11
    static let gutterWidth: CGFloat = 8

    /// The chrome the card sits on: Codex's light grey (#F3F3F3, measured off
    /// its window), a step off the panes, and a step deeper than them in dark
    /// mode. One flat color, so the strip, the band and the gutters can never
    /// disagree the way a material and a color laid side by side did.
    static let chrome = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(white: 0.09, alpha: 1)
            : NSColor(white: 0.953, alpha: 1)
    })
}

private struct StudioInsetCardModifier: ViewModifier {
    /// The titlebar band above the content, which the panes draw their chrome
    /// line into; nil in fullscreen, where that chrome moves into the content.
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight

    /// How far the panes sit under the band. SwiftUI hands the band to every
    /// view whose top meets it as that view's top safe area, and paints into
    /// it: a `.background(Color)` extends up through it by default, and a list
    /// or a scroll view scrolls its rows up under it. Half a point down, no
    /// pane meets the band, so none of that reaches it, while the chrome
    /// lines still hang in it (measured in a stand-alone window with this
    /// titlebar, 2026-10-07: build 197's first run showed the chat pane white
    /// to the window's top; with the inset the band stays the chrome over a
    /// pane with neither a header nor a backing).
    static let bandClearance: CGFloat = 0.5

    func body(content: Content) -> some View {
        let card = RoundedRectangle(cornerRadius: StudioInsetCardStyle.cornerRadius, style: .continuous)
        content
            .padding(.top, titlebarBandHeight == nil ? 0 : Self.bandClearance)
            .background { card.fill(Color(nsColor: .windowBackgroundColor)) }
            .clipShape(StudioInsetCardClip(band: titlebarBandHeight ?? 0))
            .overlay { card.stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5) }
            .padding(.trailing, StudioInsetCardStyle.gutterWidth)
            .padding(.bottom, StudioInsetCardStyle.gutterWidth)
    }
}

/// What the card's content may draw in: the card, and the band above it. The
/// content is laid out below the band, but every pane draws its chrome line up
/// into the band (`studioChromeLineHeader`); a clip to the card alone cut all
/// of that away — the Space's tabs, a page's menu and Share, the Reader's
/// title, ⋯ and × — while they stayed in the accessibility tree (seen
/// 2026-10-06 in a Dev build of ddcd5dd5b). Nothing paints a background in the
/// band, so it stays the chrome.
private struct StudioInsetCardClip: Shape {
    var band: CGFloat

    var animatableData: CGFloat {
        get { band }
        set { band = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: StudioInsetCardStyle.cornerRadius, style: .continuous)
        if band > 0 {
            path.addRect(CGRect(x: rect.minX, y: rect.minY - band, width: rect.width, height: band))
        }
        return path
    }
}

extension View {
    /// Draws the content area as the window's inset card.
    func studioInsetCard() -> some View {
        modifier(StudioInsetCardModifier())
    }
}
