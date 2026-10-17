import SwiftUI
import AppKit

extension Notification.Name {
    /// Opens the Add sources sheet of the notebook in the window whose id is
    /// the notification's object: the Notebook menu.
    static let showNotebookAddSources = Notification.Name("showNotebookAddSources")
    /// Asks the notebook in the window whose id is the object for a new name:
    /// the Notebook menu's Rename Notebook….
    static let renameNotebook = Notification.Name("renameNotebook")
    /// Opens the audio overview's options for the notebook in the window
    /// whose id is the object: the Studio's Audio overview tile and the
    /// Notebook menu's Make ▸ Audio Overview…. The workspace presents the
    /// sheet, so it opens from the Studio column and from its strip alike.
    static let showNotebookAudioOverviewOptions = Notification.Name("showNotebookAudioOverviewOptions")
    /// Opens the notebook's settings — its instructions, description,
    /// research questions, Goals, Tasks and Files — in the window whose id is
    /// the object: the Notebook menu's Notebook Settings….
}

/// Where the notebook's center puts its panes: the chat (or the document a
/// link opened in its place) on the left, the document slot on the right,
/// the divider between them when both show, and the overview when neither
/// does. Pure, so the arrangement can be tested without a view; the view
/// draws each of these in its own place in one stack, so one coming or going
/// never rebuilds another.
struct NotebookCenterLayout: Equatable {
    /// The left pane's width: the chat, or `leadingDocument` in its place.
    /// Nil when neither shows.
    var leadingWidth: CGFloat?
    /// The document standing in the chat's place; nil when the chat leads,
    /// or nothing does.
    var leadingDocument: NotebookDocument?
    /// The document slot's width; nil when the slot is empty.
    var documentWidth: CGFloat?

    var showsDivider: Bool { leadingWidth != nil && documentWidth != nil }
    var showsOverview: Bool { leadingWidth == nil && documentWidth == nil }
}

/// The widths the notebook workspace lays out by. The outer panel layout and
/// the window's make-room pass read the same numbers, so neither decides the
/// notebook fits while the other is clipping it.
///
/// The workspace is Gemini Notebook's three parts (docs/notebooks-design.md,
/// "The notebook workspace"): Sources and Studio take about a quarter of the
/// window each and the center the half between them. A side column folds to
/// nothing, so the window never shows strips beside the chat (product owner,
/// 2026-10-17: "multiple sidebars in a notebook feel a bit strange"): the
/// window's top-left toggles bring them back.
enum NotebookWorkspaceSizing {
    /// A side column's narrowest and widest while open.
    static let sideMinimumWidth: CGFloat = 260
    static let sideMaximumWidth: CGFloat = 360
    /// Each side column's share of the workspace's width, within the two
    /// bounds above: Gemini's quarter, a little less, so the chat keeps the
    /// half between them.
    static let sideShare: CGFloat = 0.24
    /// The Sources column while it shows a web or PubMed search's whole list
    /// (`NotebookWorkspace.sourcesExpanded`): Gemini widens its panel to
    /// 540 px for it, and the Studio drops to its minimum meanwhile.
    static let expandedSourcesWidth: CGFloat = 480
    static let separatorWidth: CGFloat = 1
    /// A document needs more room than a pane of the tab layout: a PDF at
    /// 200 points is unreadable.
    static let documentMinimumWidth: CGFloat = 420
    static let dividerWidth: CGFloat = StudioCenterTabGroupSizing.dividerWidth

    /// The widest the learner may drag the Sources column: past its share's
    /// 360, as the rail and the library's Sources panel go past theirs, but
    /// never so wide that the chat is the narrow column.
    static let sourcesMaximumWidth: CGFloat = 560
    /// The grab strip on the Sources column's trailing edge: the hairline and
    /// the column's own padding beside it, never the center's panes (a chat or
    /// Reader's AppKit view there would take the press, and a pane's overlay
    /// scroller draws its knob along its edge).
    static let sourcesResizeHandleWidth: CGFloat = 7
    /// The Sources column's width as the learner last dragged it, on this Mac
    /// only: absolute points, so display-dependent, like the rail's
    /// (`SyncedPreferenceKeys.excluded`). Absent until the first drag, and a
    /// double-click on the edge removes it: the column then takes its share.
    static let sourcesWidthPreferenceKey = "notebook.sourcesColumnWidth"

    /// An open side column's width in a workspace `totalWidth` wide.
    static func sideWidth(totalWidth: CGFloat) -> CGFloat {
        min(max(totalWidth * sideShare, sideMinimumWidth), sideMaximumWidth)
    }

    /// A Sources width the learner asked for, kept to the column's bounds.
    static func clampedSourcesWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, sideMinimumWidth), sourcesMaximumWidth)
    }

    /// The open Sources column's width before the center is given its room:
    /// the learner's dragged width (`preferredWidth`) if there is one, else
    /// its share of a workspace `totalWidth` wide.
    static func openSourcesWidth(totalWidth: CGFloat, preferredWidth: CGFloat?) -> CGFloat {
        preferredWidth.map(clampedSourcesWidth) ?? sideWidth(totalWidth: totalWidth)
    }

    /// The width a drag of the Sources column's edge asks for: where the
    /// column stood when the drag began, moved by the pointer, within bounds.
    static func draggedSourcesWidth(startWidth: CGFloat, translation: CGFloat) -> CGFloat {
        clampedSourcesWidth(startWidth + translation)
    }

    /// A second chat needs a chat's width; anything else in the slot a
    /// document's.
    static func minimumWidth(of document: NotebookDocument) -> CGFloat {
        document.isChat ? StudioCenterTabGroupSizing.minimumChatContentWidth : documentMinimumWidth
    }

    /// The left pane's minimum: the chat's, or the document's standing in its
    /// place; zero when neither shows.
    static func leadingMinimumWidth(for workspace: NotebookWorkspace) -> CGFloat {
        if workspace.showsChat { return StudioCenterTabGroupSizing.minimumChatContentWidth }
        return workspace.leadingDocument.map(minimumWidth(of:)) ?? 0
    }

    /// The center's minimum: the left pane and the document side by side, or
    /// the one of them that shows, or the overview's chat-wide column.
    static func centerMinimumWidth(for workspace: NotebookWorkspace) -> CGFloat {
        let leading = leadingMinimumWidth(for: workspace)
        let document = workspace.document.map(minimumWidth(of:)) ?? 0
        guard leading > 0 || document > 0 else { return StudioCenterTabGroupSizing.minimumChatContentWidth }
        return leading + document + (leading > 0 && document > 0 ? dividerWidth : 0)
    }

    /// What the Sources column takes at its narrowest, separator included.
    /// Nothing while it is folded.
    static func sourcesFootprint(for workspace: NotebookWorkspace) -> CGFloat {
        workspace.sourcesCollapsed ? 0 : sideMinimumWidth + separatorWidth
    }

    /// What the Studio column takes at its narrowest, separator included;
    /// nothing while it is folded or steps aside (`studioShows` false: an immersive video
    /// takes the window, as it took the library's Sources panel).
    static func studioFootprint(for workspace: NotebookWorkspace, studioShows: Bool = true) -> CGFloat {
        guard studioShows, !workspace.studioCollapsed else { return 0 }
        return sideMinimumWidth + separatorWidth
    }

    /// The whole workspace's minimum: both side columns as they are, open or
    /// folded, and the center's panes.
    static func minimumWidth(for workspace: NotebookWorkspace, studioShows: Bool = true) -> CGFloat {
        sourcesFootprint(for: workspace)
            + centerMinimumWidth(for: workspace)
            + studioFootprint(for: workspace, studioShows: studioShows)
    }

    /// The three columns' widths in a workspace `totalWidth` wide, separators
    /// apart: each open side column takes its share — Sources the width the
    /// learner dragged it to (`sourcesPreferredWidth`) if they did — a folded
    /// one nothing, Sources showing a search's whole list its widened width
    /// (the Studio its minimum meanwhile), and the center the rest. When the
    /// side columns would leave the center short of its minimum, the open
    /// ones give it back down to their own minimum, Studio first, so a fold
    /// judged against the minimum (`folds`) never leaves the chat clipped,
    /// and a Sources column dragged wide narrows Studio before the chat.
    static func columnWidths(
        for workspace: NotebookWorkspace,
        totalWidth: CGFloat,
        studioShows: Bool = true,
        sourcesPreferredWidth: CGFloat? = nil
    ) -> (sources: CGFloat, center: CGFloat, studio: CGFloat) {
        let share = sideWidth(totalWidth: totalWidth)
        let open = openSourcesWidth(totalWidth: totalWidth, preferredWidth: sourcesPreferredWidth)
        let expanded = workspace.sourcesExpanded && !workspace.sourcesCollapsed
        var sources = workspace.sourcesCollapsed ? 0 : (expanded ? max(open, expandedSourcesWidth) : open)
        let studioOpen = studioShows && !workspace.studioCollapsed
        var studio = studioOpen ? (expanded ? sideMinimumWidth : share) : 0
        let separators = (workspace.sourcesCollapsed ? 0 : separatorWidth) + (studioOpen ? separatorWidth : 0)
        let centerMinimum = centerMinimumWidth(for: workspace)
        var short = centerMinimum - (totalWidth - separators - sources - studio)
        if short > 0, studioOpen {
            let give = min(short, max(0, studio - sideMinimumWidth))
            studio -= give
            short -= give
        }
        if short > 0, !workspace.sourcesCollapsed {
            sources -= min(short, max(0, sources - sideMinimumWidth))
        }
        let center = max(0, totalWidth - separators - sources - studio)
        return (sources, center, studio)
    }

    /// The Sources width a finished drag keeps: what the column shows at the
    /// dragged width once the center has its room, so the learner gets back
    /// the column they saw — and not a search's widened list, which is a
    /// moment of its own (`sourcesExpanded`).
    static func settledSourcesWidth(
        for workspace: NotebookWorkspace,
        totalWidth: CGFloat,
        studioShows: Bool = true,
        draggedWidth: CGFloat
    ) -> CGFloat {
        var settled = workspace
        settled.sourcesCollapsed = false
        settled.sourcesExpanded = false
        return columnWidths(
            for: settled,
            totalWidth: totalWidth,
            studioShows: studioShows,
            sourcesPreferredWidth: draggedWidth
        ).sources
    }

    /// The left pane's and the document's widths in a center `centerWidth`
    /// wide, the left taking `leadingFraction` of what the divider leaves —
    /// kept to each side's minimum while there is room for both.
    static func paneWidths(
        centerWidth: CGFloat,
        leadingFraction: CGFloat,
        leadingMinimum: CGFloat,
        documentMinimum: CGFloat
    ) -> (leading: CGFloat, document: CGFloat) {
        let usable = max(0, centerWidth - dividerWidth)
        var leading = usable * min(max(leadingFraction, 0), 1)
        if usable >= leadingMinimum + documentMinimum {
            leading = min(max(leading, leadingMinimum), usable - documentMinimum)
        }
        return (leading, max(0, usable - leading))
    }

    /// Where the center's panes go in a center `centerWidth` wide.
    static func centerLayout(
        for workspace: NotebookWorkspace,
        centerWidth: CGFloat,
        leadingFraction: CGFloat
    ) -> NotebookCenterLayout {
        let lead = workspace.showsChat ? nil : workspace.leadingDocument
        let hasLeading = workspace.showsChat || lead != nil
        switch (hasLeading, workspace.document) {
        case (true, let document?):
            let widths = paneWidths(
                centerWidth: centerWidth,
                leadingFraction: leadingFraction,
                leadingMinimum: leadingMinimumWidth(for: workspace),
                documentMinimum: minimumWidth(of: document)
            )
            return NotebookCenterLayout(leadingWidth: widths.leading, leadingDocument: lead, documentWidth: widths.document)
        case (true, nil):
            return NotebookCenterLayout(leadingWidth: centerWidth, leadingDocument: lead, documentWidth: nil)
        case (false, _?):
            return NotebookCenterLayout(leadingWidth: nil, leadingDocument: nil, documentWidth: centerWidth)
        case (false, nil):
            return NotebookCenterLayout(leadingWidth: nil, leadingDocument: nil, documentWidth: nil)
        }
    }

    /// What a workspace `totalWidth` wide folds so the notebook's center
    /// fits: Sources first — opening a source is what usually asks for the
    /// room, and the window's sidebar toggle brings it back — then Studio, which
    /// the product owner wants on screen while the notebook is worked in (2026-10-02).
    /// Never the navigation rail, whose visibility is a synced preference an
    /// open must not write; and only for the center's sake, so Show Sources
    /// or Show Studio in a narrow window stays shown.
    static func folds(
        for workspace: NotebookWorkspace,
        totalWidth: CGFloat,
        studioShows: Bool = true
    ) -> (sources: Bool, studio: Bool) {
        let center = centerMinimumWidth(for: workspace)
        let studio = studioFootprint(for: workspace, studioShows: studioShows)
        let foldSources = !workspace.sourcesCollapsed
            && totalWidth < sourcesFootprint(for: workspace) + center + studio
        let sources = foldSources ? 0 : sourcesFootprint(for: workspace)
        let foldStudio = studioShows && !workspace.studioCollapsed && totalWidth < sources + center + studio
        return (foldSources, foldStudio)
    }
}

/// The notebook workspace: while a window holds a notebook, the window body is
/// this — Gemini Notebook's three parts: the notebook's **Sources** column,
/// its **Chat** with one document slot beside it (the Reader, a Doc, a second
/// chat), and its **Studio** column (docs/notebooks-design.md, "The notebook
/// workspace"). The Reader stays ForeverLM's — the PDF with its figures, the
/// video with its transcript — beside the chat, never a text column inside
/// Sources. The window's panes wait underneath, untouched, and come back when
/// the notebook closes — the precedent the memory review's focus set.
///
/// Its own struct with explicit parameters, and the chat and document handed
/// in type-erased: `StudioView` erases its root because its generic type once
/// grew deep enough to crash a debug build, and this keeps the notebook's
/// branch from adding to it. The chat is the window's one primary chat panel
/// (`StudioView.dockedChatPanel`), mounted here instead of in the tab groups,
/// never beside them.
struct NotebookWorkspaceView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset
    @Environment(\.studioPanelTrailingOverflow) private var outerTrailingOverflow
    @Environment(\.openWindow) private var openWindow
    @SyncedStorage("uiZoomStep") private var uiZoomStep = UIZoom.defaultStep
    /// Observed so Atlas of This Notebook comes and goes with the beta
    /// sign-up (`BetaFeatures`).
    @SyncedStorage(wrappedValue: false, BetaReleases.preferenceKey) private var signedUpForBetas: Bool

    let workspace: NotebookWorkspace
    let chat: () -> AnyView
    let document: (NotebookDocument) -> AnyView

    init(
        workspace: NotebookWorkspace,
        chat: @escaping () -> AnyView,
        document: @escaping (NotebookDocument) -> AnyView
    ) {
        self.workspace = workspace
        self.chat = chat
        self.document = document
    }

    /// The left pane's share of the center beside a document. This window's,
    /// for as long as the notebook shows; a divider drag moves it.
    @State private var leadingFraction: CGFloat = 0.5
    @State private var dragStartFraction: CGFloat?
    /// The slot a sidebar destination is being dragged over.
    @State private var replaceTarget: CenterPane?
    @State private var isAddingSources = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var showMergeSheet = false
    /// The Share popover from the workspace's top right, for Share… while the
    /// Studio column, where Share lives, is not on screen.
    @State private var isShowingShareUnderMenu = false
    /// The Sources column's width as the learner last dragged it, on this
    /// Mac; nil until the first drag, and again after a double-click on the
    /// edge, when the column takes its share of the window.
    @AppStorage(NotebookWorkspaceSizing.sourcesWidthPreferenceKey) private var storedSourcesWidth: Double?
    /// The width a drag of the column's edge asks for while it runs; nil when
    /// idle. Written to `storedSourcesWidth` once, when the drag ends.
    @State private var draggedSourcesWidth: CGFloat?
    @State private var dragStartSourcesWidth: CGFloat?
    /// The center's width when that drag began. The center keeps it while the
    /// drag runs, so the chat and the Reader are not re-typeset at a new
    /// width on every mouse move (that was the lag); it takes the real
    /// width once, when the drag ends.
    @State private var dragStartCenterWidth: CGFloat?
    /// The audio overview's options, asked for by the Studio's tile or the
    /// Notebook menu.
    @State private var audioOverviewTarget: AudioOverviewOptionsTarget?

    private typealias Sizing = NotebookWorkspaceSizing

    private var goal: LearningGoalRecord? {
        vm.notebook(id: workspace.notebookID)
    }

    /// Whether the open library has read its Notebooks and holds this one;
    /// nil until the first read, when a restored notebook is still on its way.
    private var isHeldByLibrary: Bool? {
        guard vm.hasLoadedLearningGoalsOnce else { return nil }
        return vm.allNotebooks.contains { $0.id == workspace.notebookID }
    }

    /// The chat on screen and where it is filed, so the window notes it as
    /// the notebook's last once its record says it is the notebook's.
    private var notebookChatKey: String? {
        guard let sessionID = windowState.chatSessionID else { return nil }
        let home = vm.chatHome(forSessionID: sessionID)
        return "\(sessionID)|\(home.map { String(describing: $0) } ?? "")"
    }

    /// Whether the Studio column is on screen at all: an immersive video
    /// takes the window, as it took the library's Sources panel.
    private var studioShows: Bool { !windowState.isDockedReaderImmersive }

    /// Whether the Studio column, where Share lives, is open on screen.
    private var studioIsOpen: Bool { studioShows && !workspace.studioCollapsed }

    /// The width the Sources column is asked to take: a drag's while one
    /// runs, else the learner's kept one; nil for its share.
    private var sourcesPreferredWidth: CGFloat? {
        draggedSourcesWidth ?? storedSourcesWidth.map { CGFloat($0) }
    }

    var body: some View {
        GeometryReader { geo in
            // The columns share what is on screen. When the notebook's
            // minimum is wider than the window (a column the learner
            // unfolded), the outer layout lays it out wider and clips its
            // trailing edge; laid out against the visible width, the center
            // gives up the room — its panes clip as a squeezed pane does —
            // and the Studio, with its Hide, stays on screen.
            let visibleWidth = max(0, geo.size.width - max(0, outerTrailingOverflow))
            let widths = Sizing.columnWidths(
                for: workspace,
                totalWidth: visibleWidth,
                studioShows: studioShows,
                sourcesPreferredWidth: sourcesPreferredWidth
            )
            let centerStart = widths.sources + (workspace.sourcesCollapsed ? 0 : Sizing.separatorWidth)
            HStack(spacing: 0) {
                if !workspace.sourcesCollapsed {
                    sourcesColumn
                        .frame(width: widths.sources)
                        .frame(maxHeight: .infinity)
                    columnSeparator
                }
                // While the Sources edge is dragged the panes stay as wide as
                // they were and hang from the Studio's side: a wider Sources
                // column clips their leading edge, a narrower one leaves a
                // margin there. Always the same modifiers, so the chat and the
                // Reader keep their identity when the drag starts and ends.
                let heldCenter = dragStartCenterWidth ?? widths.center
                center(
                    width: heldCenter,
                    start: centerStart + widths.center - heldCenter,
                    totalWidth: visibleWidth
                )
                    .frame(width: heldCenter)
                    .frame(width: widths.center, alignment: .trailing)
                    .clipShape(Rectangle().inset(by: dragStartCenterWidth == nil ? -4000 : 0))
                    .frame(maxHeight: .infinity)
                if studioShows, !workspace.studioCollapsed {
                    columnSeparator
                    studioColumn
                        .frame(width: widths.studio)
                        .frame(maxHeight: .infinity)
                }
            }
            // The Sources column's edge drags, over the hairline and the
            // column's own padding beside it; folded, there is no column.
            .overlay(alignment: .topLeading) {
                if !workspace.sourcesCollapsed {
                    sourcesResizeHandle(
                        shownWidth: widths.sources,
                        centerWidth: widths.center,
                        totalWidth: visibleWidth
                    )
                        .offset(x: centerStart - Sizing.sourcesResizeHandleWidth)
                }
            }
            .frame(width: visibleWidth, alignment: .leading)
            .coordinateSpace(.named("notebookWorkspace"))
        }
        // Siri and Shortcuts know which notebook is on screen, as they did
        // on the old Notebook page.
        .siriNotebookAnnotation(workspace.notebookID)
        // Presentations that need the notebook ride a view of their own, so
        // the record arriving after a relaunch adds them without rebuilding
        // the columns — and the chat — around them.
        .background { notebookPresentations }
        .sheet(isPresented: $isAddingSources) {
            if let goal {
                NotebookAddSourcesSheet(goal: goal)
                    .environment(vm)
                    .environment(windowState)
            }
        }
        .alert("Rename Notebook", isPresented: $isRenaming) {
            TextField("Notebook name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: commitRename)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNotebookAddSources)) { note in
            guard (note.object as? UUID) == windowState.id else { return }
            isAddingSources = true
        }
        // Share while Studio is folded: its popover hangs from the workspace's
        // top right, since neither Studio's header nor the Sources column (it
        // may be folded too) is there to hold it.
        .overlay(alignment: .topTrailing) {
            if let goal {
                Color.clear
                    .frame(width: 1, height: 1)
                    .popover(isPresented: $isShowingShareUnderMenu, arrowEdge: .bottom) {
                        NotebookSharePopover(goal: goal, close: { isShowingShareUnderMenu = false })
                            .environment(vm)
                    }
                    .padding(.trailing, 24)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNotebookShare)) { note in
            guard (note.object as? UUID) == windowState.id, !studioIsOpen, vm.notebook(id: workspace.notebookID) != nil else { return }
            isShowingShareUnderMenu = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .renameNotebook)) { note in
            guard (note.object as? UUID) == windowState.id, let goal, !vm.isNotebookReadOnly(goal) else { return }
            beginRename(goal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNotebookAudioOverviewOptions)) { note in
            guard (note.object as? UUID) == windowState.id,
                  vm.notebookTakesMadeThings(workspace.notebookID) else { return }
            audioOverviewTarget = vm.audioOverviewOptionsTarget(notebookID: workspace.notebookID)
        }
        // The journals banner asks for a notebook's sources: they are this
        // column, so it opens if it was folded.
        .onChange(of: vm.pendingNotebookSourcesRequestID, initial: true) { _, requested in
            guard let requested, requested == workspace.notebookID else { return }
            vm.pendingNotebookSourcesRequestID = nil
            setSourcesCollapsed(false)
        }
        // A notebook the open library does not hold — deleted elsewhere, a
        // team library switched away, a relaunch that brought back one whose
        // record is gone — is open nowhere; the window shows the Space,
        // never a spinner. Not before the library's first read, which
        // brings a restored notebook's record in. The view model closes it in
        // every window as well (`closeNotebooksMissingFromLibrary`); this
        // catches a window whose notebook was set after that read, such as a
        // later restore.
        .onChange(of: isHeldByLibrary, initial: true) { _, held in
            guard held == false else { return }
            vm.leaveNotebookForSpace(in: windowState)
        }
        .onChange(of: notebookChatKey, initial: true) { _, _ in
            vm.rememberNotebookChat(in: windowState)
        }
    }

    @ViewBuilder
    private var notebookPresentations: some View {
        if let goal {
            Color.clear
                .notebookDeleteConfirmation(goal: goal, isPresented: $showDeleteConfirm)
                .sheet(isPresented: $showMergeSheet) {
                    NotebookMergeSheet(goal: goal)
                        .environment(vm)
                }
                // Its own view: one presenter per sheet.
                .background {
                    Color.clear.sheet(item: $audioOverviewTarget) { target in
                        AudioOverviewOptionsSheet(vm: vm, target: target)
                            .environment(vm)
                            .environment(windowState)
                    }
                }
        }
    }

    /// The hairline between a side column and the center, with its short
    /// stroke in the titlebar band as the outer layout's dividers have.
    private var columnSeparator: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Sizing.separatorWidth)
            .overlay(StudioColumnHairline())
            .accessibilityHidden(true)
    }

    /// The Sources column's trailing edge, which resizes it as the rail's
    /// edge resizes the rail: a drag moves it between 260 and 560 points (a
    /// Studio beside it narrows before the chat does), and the width is kept
    /// on this Mac when the drag ends; a double-click gives the column back
    /// its share of the window. It covers the hairline and the column's own
    /// padding, never the center's panes.
    private func sourcesResizeHandle(shownWidth: CGFloat, centerWidth: CGFloat, totalWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: Sizing.sourcesResizeHandleWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .onTapGesture(count: 2) {
                // Removes the kept width rather than writing the share, so
                // the column goes back to following the window.
                storedSourcesWidth = nil
            }
            .gesture(
                // The workspace's space: the handle moves with the column's
                // edge, so a local-space translation would feed back into
                // itself and stutter.
                DragGesture(minimumDistance: 1, coordinateSpace: .named("notebookWorkspace"))
                    .onChanged { value in
                        let start = dragStartSourcesWidth ?? shownWidth
                        if dragStartSourcesWidth == nil {
                            dragStartSourcesWidth = start
                            dragStartCenterWidth = centerWidth
                        }
                        draggedSourcesWidth = Sizing.draggedSourcesWidth(
                            startWidth: start,
                            translation: value.translation.width
                        )
                    }
                    .onEnded { _ in
                        if let dragged = draggedSourcesWidth {
                            storedSourcesWidth = Double(Sizing.settledSourcesWidth(
                                for: workspace,
                                totalWidth: totalWidth,
                                studioShows: studioShows,
                                draggedWidth: dragged
                            ))
                        }
                        dragStartSourcesWidth = nil
                        dragStartCenterWidth = nil
                        draggedSourcesWidth = nil
                    }
            )
            .accessibilityHidden(true)
    }

    // MARK: - Studio column

    /// The right-hand column: the notebook's Studio, or its strip.
    private var studioColumn: some View {
        NotebookStudioPanel(notebookID: workspace.notebookID)
            .dynamicTypeSize(UIZoom.size(for: uiZoomStep))
    }

    // MARK: - Sources column

    /// Drawn only while open: folded, the column is not in the window.
    private var sourcesColumn: some View {
        Group {
            if let goal {
                VStack(alignment: .leading, spacing: 10) {
                    notebookTitle(goal)
                    NotebookSourcePoolView(goal: goal, column: columnActions)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .studioChromeLineHeader { sourcesHeader }
        // The leftmost column of the window while the rail is hidden: its
        // header clears the traffic lights. Nothing overlays its corner.
        .environment(\.studioCenterPaneHeaderLeadingInset, headerLeadingInset)
        .environment(\.studioChromeLineReservation, StudioChromeLineReservation())
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
        .accessibilityIdentifier("notebook.sources")
    }

    private var columnActions: NotebookSourcePoolColumnActions {
        NotebookSourcePoolColumnActions(
            openSource: { article in
                Task { await vm.selectArticle(article.id, in: windowState, revealingReader: true) }
            },
            addSources: { isAddingSources = true },
            isShowingResults: workspace.sourcesExpanded,
            showResults: { shown in
                guard windowState.notebook?.sourcesExpanded != shown else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    windowState.notebook?.sourcesExpanded = shown
                }
            }
        )
    }

    /// The column's row on the chrome line: the fold, and nothing else. The
    /// window's ← → and sidebar toggle already sit on this line, and the
    /// traffic lights before them, so a ‹, the name and a ⋯ squeezed in after
    /// them left the name a few letters (product owner, 2026-10-17: "looks
    /// bad in the top left"). The name is the column's title
    /// below (`notebookTitle`); Close Notebook in its menu, the window's ←
    /// and the rail lead back to the Space.
    private var sourcesHeader: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 8)
            TitlebarBandButton(
                help: "Hide Sources",
                accessibilityIdentifier: "notebook.sources.collapse",
                action: { setSourcesCollapsed(true) }
            ) {
                Image(systemName: "sidebar.left")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    /// The notebook's name at the head of its column, over the search, as a
    /// Space list wears its name ("One head for every list"): the column's
    /// whole width, two lines before it truncates. A click opens the
    /// notebook's menu, Rename Notebook… in it (the name renamed on a click
    /// until 2026-10-17; the notebook has had no settings sheet since
    /// 2026-10-04). Off the chrome line it is an ordinary SwiftUI `Menu`.
    @ViewBuilder
    private func notebookTitle(_ goal: LearningGoalRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Menu {
                notebookMenuItems(goal)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(goal.title)
                        .zoomedSystemFont(size: 17, weight: .semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down")
                        .zoomedSystemFont(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .hoverHighlight()
            .help("Notebook actions")
            .accessibilityLabel(goal.title)
            .accessibilityHint("Notebook actions")
            .accessibilityIdentifier("notebook.name")
            // ForeverLM could not name a notebook made without one: the
            // placeholder stays, and this says why (`NotebookNaming`).
            if let namingError = vm.notebookNamingErrors[goal.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.orange)
                    .help(namingError)
                    .accessibilityLabel(namingError)
                    .accessibilityIdentifier("notebook.namingError")
            }
        }
        // The wash sits 4 pt outside the words: the name lines up with the
        // search field's edge.
        .padding(.leading, -4)
    }

    private func setSourcesCollapsed(_ collapsed: Bool) {
        guard windowState.notebook?.sourcesCollapsed != collapsed else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            windowState.notebook?.sourcesCollapsed = collapsed
            // Folded, the column shows no list; unfolded, it opens on the
            // notebook's sources and the results card.
            if collapsed { windowState.notebook?.sourcesExpanded = false }
        }
    }

    /// Close Notebook: the window shows the Space's All list, the one place a
    /// window holding no notebook shows; the notebook's row there or its rail
    /// row brings it back as it was.
    private func closeNotebook() {
        withAnimation(.easeInOut(duration: 0.22)) {
            vm.showSpaceAll(in: windowState)
        }
    }

    // MARK: - The notebook's actions

    @ViewBuilder
    private func notebookMenuItems(_ goal: LearningGoalRecord) -> some View {
        // A read-only team's notebook is read here too: the items stay so the
        // menu keeps its shape, but nothing in it changes the team. Read from
        // the notebook's own team, not the library on screen.
        let isReadOnly = vm.isNotebookReadOnly(goal)
        Button("Add Sources…", systemImage: "plus") { isAddingSources = true }
            .disabled(vm.importableNotebook(goal.id) == nil)
        AddContextNotebookMenu(goal: goal)
        // This notebook's own Think first level over the library's: the
        // learner's, so it is offered on a read-only team's notebook too.
        NotebookThinkFirstMenu(notebookID: goal.id)
        // Its sources laid out as concepts at levels (docs/atlas-design.md):
        // the one made before, else a new one. A beta feature with the
        // Canvas (`BetaFeatures`).
        if BetaFeatures.showsCanvas(signedUpForBetas: signedUpForBetas) {
            Button("Atlas of This Notebook", systemImage: AtlasPane.systemImage) {
                vm.inWindow(windowState) { vm.openAtlas(topic: nil, itemRefs: [], notebookID: goal.id) }
            }
        }
        Divider()
        Button("Rename Notebook…", systemImage: "pencil") { beginRename(goal) }
            .disabled(isReadOnly)
        if goal.isArchived {
            Button("Restore Notebook", systemImage: "arrow.uturn.backward") {
                Task { await vm.setGoalStatus(goalID: goal.id, status: .active) }
            }
            .disabled(isReadOnly)
        } else {
            NotebookPinToggleButton(goal: goal)
            Button("Archive Notebook", systemImage: "archivebox") {
                Task { await vm.setGoalStatus(goalID: goal.id, status: .archived) }
            }
            .disabled(isReadOnly)
        }
        Divider()
        // The notebook's Share popover, under the Share at the top right of
        // Studio; from the workspace's top right while Studio is folded or an
        // immersive video has its place.
        Button("Share…", systemImage: "person.badge.plus") {
            NotificationCenter.default.post(name: .showNotebookShare, object: windowState.id)
        }
        ShareWithTeamMenu { teamID in
            Task { await vm.shareNotebook(goal.id, withTeam: teamID) }
        }
        Divider()
        NotebookMergeMenuButton(goal: goal) { showMergeSheet = true }
        OpenStudioDestinationInOtherWindowMenu(
            destination: .notebook(goal.id),
            currentWindowState: windowState,
            openNewWindow: { openWindow(id: "studio") }
        )
        Button("Close Notebook", systemImage: "xmark") { closeNotebook() }
        Divider()
        Button("Delete Notebook…", systemImage: "trash", role: .destructive) {
            showDeleteConfirm = true
        }
        .disabled(isReadOnly)
    }

    private func beginRename(_ goal: LearningGoalRecord) {
        renameText = goal.title
        isRenaming = true
    }

    private func commitRename() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let goal, title != goal.title else { return }
        Task { await vm.renameNotebook(goal.id, to: title) }
    }

    // MARK: - Center

    /// The chat, the document in its place, the divider, the document slot
    /// and the overview, each in its own place in one stack. A pane keeps its
    /// identity while another comes or goes: a chat pane rebuilt on every
    /// citation stopped speech and dictation and lost its state and scroll,
    /// and a Reader rebuilt by ⇧⌘K reloaded its PDF or video.
    private func center(width: CGFloat, start: CGFloat, totalWidth: CGFloat) -> some View {
        let layout = Sizing.centerLayout(for: workspace, centerWidth: width, leadingFraction: leadingFraction)
        let leadingWidth = layout.leadingWidth ?? 0
        let documentWidth = layout.documentWidth ?? 0
        // The document stands left of the chat unless the learner swapped
        // them; `layout` always counts the chat's side as the leading one.
        let documentLeads = workspace.documentPrecedesChat
        let chatStart = documentLeads ? start + documentWidth + Sizing.dividerWidth : start
        let documentStart = documentLeads
            ? start
            : start + (layout.leadingWidth.map { $0 + Sizing.dividerWidth } ?? 0)
        // Keyed by pane, so a swap moves the views and never rebuilds them.
        return HStack(spacing: 0) {
            ForEach(centerPanes(layout: layout, documentLeads: documentLeads), id: \.self) { pane in
                switch pane {
                case .chat:
                    chatSlot(width: leadingWidth, start: chatStart, totalWidth: totalWidth)
                case .leadingDocument:
                    if let lead = layout.leadingDocument {
                        documentSlot(
                            lead,
                            width: leadingWidth,
                            start: start,
                            totalWidth: totalWidth,
                            identifier: "notebook.document.leading"
                        )
                    }
                case .divider:
                    centerDivider(centerWidth: width, documentLeads: documentLeads)
                case .document:
                    if let document = workspace.document {
                        documentSlot(
                            document,
                            width: documentWidth,
                            start: documentStart,
                            totalWidth: totalWidth,
                            identifier: "notebook.document"
                        )
                    }
                case .overview:
                    overview
                }
            }
        }
    }

    private enum CenterPane: Hashable {
        case chat, leadingDocument, divider, document, overview
    }

    /// The center's panes left to right.
    private func centerPanes(layout: NotebookCenterLayout, documentLeads: Bool) -> [CenterPane] {
        var panes: [CenterPane] = []
        let chat: [CenterPane] = workspace.showsChat ? [.chat] : []
        let leadingDocument: [CenterPane] = layout.leadingDocument == nil ? [] : [.leadingDocument]
        let divider: [CenterPane] = layout.showsDivider ? [.divider] : []
        let document: [CenterPane] = workspace.document == nil ? [] : [.document]
        if documentLeads {
            panes = document + divider + chat
        } else {
            panes = chat + leadingDocument + divider + document
        }
        if layout.showsOverview { panes.append(.overview) }
        return panes
    }

    /// The leading chrome a slot starting `start` points in must clear: the
    /// traffic lights reach into it only while the Sources column is folded
    /// and the rail is hidden.
    private func leadingReservation(start: CGFloat) -> CGFloat {
        max(0, headerLeadingInset - start)
    }

    private func clip(start: CGFloat, width: CGFloat, totalWidth: CGFloat) -> CGFloat {
        StudioCenterTabGroupSizing.clippedTrailingWidth(
            groupStart: start,
            groupWidth: width,
            totalWidth: totalWidth,
            // `totalWidth` is the visible width already: the overflow is
            // counted out where the columns are laid out.
            enclosingOverflow: 0
        )
    }

    private func chatSlot(width: CGFloat, start: CGFloat, totalWidth: CGFloat) -> some View {
        StudioPaneHost(
            activeTab: .chat,
            width: width,
            enclosingClip: clip(start: start, width: width, totalWidth: totalWidth),
            leadingReservation: leadingReservation(start: start)
        ) {
            chat()
        }
        .overlay { replaceDropOverlay(.chat) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
        .accessibilityIdentifier("notebook.chat")
    }

    /// A destination dragged from the sidebar onto a slot opens in the
    /// notebook's chat or document slot, as it does anywhere in this window.
    private func replaceDropOverlay(_ pane: CenterPane) -> some View {
        ZStack {
            StudioPaneReplaceDropTarget(
                onTargeted: { targeted in
                    if targeted {
                        replaceTarget = pane
                    } else if replaceTarget == pane {
                        replaceTarget = nil
                    }
                },
                onDrop: {
                    replaceTarget = nil
                    vm.showDropped($0, inPaneAt: 0, in: windowState)
                }
            )
            StudioDropZoneOverlay(isActive: replaceTarget == pane, cornerRadius: 10, inset: 6)
        }
    }

    private func documentSlot(
        _ document: NotebookDocument,
        width: CGFloat,
        start: CGFloat,
        totalWidth: CGFloat,
        identifier: String
    ) -> some View {
        // The slot beside the chat can become Pages, Browser or Memory from its
        // corner; the slot standing in the chat's place has no swap control.
        let swaps = identifier == "notebook.document.leading" ? [] : StudioPaneSwap.notebookDocumentDestinations
        return StudioPaneHost(
            activeTab: document.centerTab ?? .reader,
            width: width,
            enclosingClip: clip(start: start, width: width, totalWidth: totalWidth),
            leadingReservation: leadingReservation(start: start),
            swapDestinationCount: swaps.count
        ) {
            self.document(document)
        } corner: { corner in
            StudioPaneSwapControl(
                corner: corner,
                destinations: swaps,
                current: document.centerTab ?? .reader,
                identifierPrefix: identifier,
                reservesPin: false,
                onSelect: { destination in
                    vm.replaceCenterPane(
                        at: 0,
                        with: destination.tab,
                        startsBlankChat: destination.startsBlankChat,
                        in: windowState
                    )
                }
            )
        }
        .overlay { replaceDropOverlay(identifier == "notebook.document.leading" ? .leadingDocument : .document) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(document.centerTab?.title ?? "Cards")
        .accessibilityIdentifier(identifier)
    }

    /// The divider between the chat and the document; a drag moves it, and
    /// its swap button, in the titlebar band as the tab layout's divider
    /// carries it, puts the one where the other stood.
    private func centerDivider(centerWidth: CGFloat, documentLeads: Bool) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Sizing.dividerWidth)
            .overlay(StudioColumnHairline())
            .contentShape(Rectangle())
            .cursor(.resizeLeftRight)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("notebookWorkspace"))
                    .onChanged { value in
                        let usable = max(1, centerWidth - Sizing.dividerWidth)
                        let start = dragStartFraction ?? leadingFraction
                        if dragStartFraction == nil { dragStartFraction = start }
                        // `leadingFraction` is the chat's share, which a drag
                        // to the right takes from when the document leads.
                        let moved = value.translation.width / usable
                        leadingFraction = min(max(documentLeads ? start - moved : start + moved, 0.15), 0.85)
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
            .accessibilityHidden(true)
            // Above the drag surface, so the click is a swap and not a drag;
            // shown while the pointer is over the divider (Quiet chrome).
            .modifier(StudioPaneSwapAffordance(
                titlebarBandHeight: titlebarBandHeight,
                accessibilityIdentifier: "notebook.centerPanes.swap",
                action: {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        windowState.notebook?.documentLeads.toggle()
                    }
                }
            ))
            // Wider than the divider, so it stays above both panes while
            // they animate into their new order.
            .zIndex(1)
    }

    /// The center with neither the chat nor a document: the notebook, and the
    /// way back to its chat.
    private var overview: some View {
        VStack(spacing: StudioDesign.Spacing.medium) {
            Text(goal?.title ?? "")
                .font(.system(size: 24, weight: .medium, design: .serif))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let summary = goal?.displaySummary {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    vm.inWindow(windowState) {
                        vm.showAssistantOverlay = true
                        vm.reviewChatFocusRequestID = UUID()
                    }
                }
            } label: {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("notebook.overview.chat")
        }
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
        .accessibilityIdentifier("notebook.chat")
    }
}
