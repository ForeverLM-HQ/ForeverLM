import SwiftUI
import UniformTypeIdentifiers

/// A canvas: a plane for what the learner thinks (docs/knowledge-map-design.md).
/// Their Ideas, the regions they draw and the arrows between them sit on it;
/// an Idea's sources hang under it as evidence.
///
/// A canvas is an item in the Space, so it opens as a page does: the Space
/// sidebar on the leading edge, the canvas beside it, and the canvas's name
/// at the top as its menu ("Canvases in the Space").
///
/// The plane is `KnowledgeMapCanvasView`. Around it: the tray on the leading
/// edge with what is not on the map yet (Ideas, notebooks, a library search);
/// the tools (select, hand, circle, region, arrow, note) and a find field
/// above, undo, zoom and the shortcuts below; the
/// lens banner while a chat's lens shows; and, on the trailing edge, what is
/// selected — cards with Ask in Chat, an Idea's evidence, a region's name and
/// colour, an arrow's label. An empty map says what to do first.
struct KnowledgeMapPane: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset

    @State private var query = ""
    @State private var noteText = ""
    @State private var regionName = ""
    @State private var edgeLabel = ""
    @FocusState private var noteFocused: Bool
    @FocusState private var regionNameFocused: Bool
    /// This pane's canvas, for Extend to Other Display.
    @State private var canvasHandle = KnowledgeMapCanvasHandle()
    @State private var showsTray = true
    // MARK: The Space beside the canvas
    /// The learner's choice to keep the Space sidebar out of the way, shared
    /// with the Space and its pages; this Mac's.
    @AppStorage("space.sidebarHidden") private var spaceSidebarHiddenByLearner = false
    @State private var paneWidth: CGFloat = 0
    @State private var renamingCanvas: KnowledgeMapCanvas?
    @State private var linkSection: ArtifactSection?
    @State private var linkedArtifactID: String?
    @State private var isCreatingSpace = false

    private var map: KnowledgeMapModel { vm.knowledgeMap }

    /// The sidebar shows unless the learner hid it or the pane is too narrow
    /// for it beside the canvas.
    private var showsSpaceSidebar: Bool {
        !spaceSidebarHiddenByLearner && (paneWidth <= 0 || paneWidth >= SpaceSidebarMetrics.minimumPaneWidth)
    }

    /// The sidebar's lit place: where the open canvas is listed, its space
    /// when the window's Space shows it.
    private var spaceSelection: SpaceDestination {
        guard let canvas = vm.openCanvas else { return .canvases }
        return SpaceDestination.listing(
            canvas,
            within: SpaceDestination(key: windowState.spaceDestinationKey),
            spaces: vm.pageSpaces
        )
    }

    var body: some View {
        let map = map
        HStack(spacing: 0) {
            if showsSpaceSidebar {
                SpaceSidebar(
                    selection: spaceSelection,
                    openArtifactID: map.mapID,
                    onSelect: showSpacePlace,
                    onOpenRecent: openSpaceRecent,
                    onNewPage: newSpacePage,
                    onLink: { linkSection = $0 },
                    onNewSpace: { isCreatingSpace = true }
                )
                .frame(width: SpaceSidebarMetrics.width)
                .background(SpaceSidebarMetrics.background)
                .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            ZStack {
                KnowledgeMapCanvasView(
                    model: map,
                    layoutRevision: map.layoutRevision,
                    contentRevision: map.contentRevision,
                    lensRevision: map.lensRevision,
                    summariesRevision: map.summariesRevision,
                    commandCount: map.commands.count,
                    onOpen: { ref in
                        Task { await vm.openKnowledgeMapItem(ref, in: windowState) }
                    },
                    onNoteRequested: { x, y in
                        noteText = ""
                        map.pendingNote = (x, y)
                        noteFocused = true
                    },
                    onDrop: { drop in
                        Task { @MainActor in
                            // Clips are saved and files, pictures and addresses imported
                            // as they land (`knowledgeMapCards`), so the page knows each card.
                            guard let placed = await vm.knowledgeMapCards(for: drop, on: map) else { return }
                            map.send(.drop(x: drop.point.x, y: drop.point.y, refs: placed.refs, regionName: placed.regionName, notebookID: placed.notebookID))
                        }
                    },
                    onLinkEvidence: { idea, refs in
                        Task { await vm.linkKnowledgeMapEvidence(ideaRef: idea, refs: refs) }
                    },
                    handle: canvasHandle,
                    proposalsRevision: map.proposalsRevision, // Proposals and faces (WP-B1)
                    facesRevision: map.facesRevision,
                    memorySync: map.memory.syncToken, // Memory (WP-B2)
                    windowID: windowState.id
                )
                // Each canvas its own page: another canvas loads afresh rather
                // than taking over the last one's drawn state.
                .id(map.mapID)
                if map.placedCount == 0, map.lens == nil, !map.content.nodes.isEmpty {
                    // Centred in the room the tray leaves: beside the Space
                    // sidebar the plane is narrower, and the tray would cover
                    // the card's leading edge.
                    emptyMapCard
                        .padding(.leading, showsTray && map.memory.review == nil ? 290 + 14 : 0)
                }
                // Freeform's arrangement: the tools float over the plane, the
                // find field top right, zoom bottom left, and what is selected in
                // a card on the trailing edge.
                VStack(spacing: 10) {
                    topBar
                    if let canvas = vm.openCanvas, canvas.isTrashed {
                        trashBanner(canvas)
                    }
                    if let lens = map.lens {
                        lensBanner(lens)
                    }
                    // MARK: Proposals (WP-B1)
                    if map.proposals != nil || (map.asking != nil && !showsInspector) {
                        KnowledgeMapProposalBanner(showsProgress: !showsInspector)
                            .mapFloatingChrome(cornerRadius: 12)
                    }
                    if map.pendingNote != nil {
                        noteComposer
                    }
                    if let error = map.rendererError {
                        Text(error)
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.secondary)
                            .textSelection(.disabled)
                            .padding(10)
                            .mapFloatingChrome(cornerRadius: 10)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom) {
                        zoomPill
                        Spacer(minLength: 12)
                        VStack(spacing: 8) {
                            if showsBackToContent {
                                backToContentPill
                            }
                            if let caption = map.viewCaption {
                                captionCard(caption)
                            }
                        }
                        Spacer(minLength: 12)
                        KnowledgeMapMemoryToggle() // Memory (WP-B2)
                        KnowledgeMapFacesToggle().padding(4).mapFloatingChrome(cornerRadius: 12) // Faces (WP-B1)
                        viewSwitches
                    }
                }
                .padding(14)
                HStack {
                    if showsTray, map.memory.review == nil {
                        KnowledgeMapTray(onClose: { showsTray = false })
                            .frame(width: 290)
                            .frame(maxHeight: 640)
                            .mapFloatingChrome(cornerRadius: 14)
                            .padding(.leading, 14)
                            .padding(.vertical, 64)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer()
                    if showsInspector {
                        inspector
                            .frame(width: 290)
                            .frame(maxHeight: 520)
                            .mapFloatingChrome(cornerRadius: 14)
                            .padding(.trailing, 14)
                            .padding(.vertical, 64)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: showsInspector)
                .animation(.easeInOut(duration: 0.18), value: showsTray)
                // MARK: Review (WP-B2)
                KnowledgeMapReviewLayer()
                // ⌘-click: a card's faces floating beside it.
                KnowledgeMapPopupLayer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.18), value: showsSpaceSidebar)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { paneWidth = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .canvasRenameAlert($renamingCanvas)
        // Opening a canvas is a Recents entry, as opening a page is.
        .onChange(of: map.mapID, initial: true) { _, id in
            SpaceRecents.shared.note(.canvas, id: id)
        }
        // What was linked from the sidebar opens in its pane once the sheet
        // has gone, as from the Space.
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
                if let spaceID = spaceSelection.pageSpaceID {
                    vm.filePages([artifact.id], inPageSpace: spaceID)
                }
                linkedArtifactID = artifact.id
            }
        }
        .sheet(isPresented: $isCreatingSpace) {
            SpaceNewSpaceSheet(onCreated: showSpacePlace)
        }
        .knowledgeMapMemory() // Memory (WP-B2)
        .studioChromeLineHeader { header }
        .studioCenterTabCloseChrome(for: .knowledgeMap)
        .task(id: "\(map.mapID)|\(vm.knowledgeMapContentSignature)") {
            await vm.refreshKnowledgeMapContent()
            Task { await vm.refreshKnowledgeMapFaces() } // Faces (WP-B1)
            await vm.refreshKnowledgeMapSummaries()
        }
        .task(id: "\(map.describesView)-\(map.viewport.captionKey)") {
            await vm.refreshKnowledgeMapViewCaption()
        }
        .onChange(of: map.layoutRevision) {
            Task { await vm.refreshKnowledgeMapSummaries() }
            Task { await vm.refreshKnowledgeMapFaces() } // Faces (WP-B1)
        }
        .onChange(of: map.selectedRegionID) { _, id in
            regionName = id.flatMap { map.layout.regions[$0]?.name } ?? ""
            if let id, map.layout.regions[id]?.name.isEmpty == true { regionNameFocused = true }
        }
        .onChange(of: map.selectedEdgeID) { _, id in
            edgeLabel = id.flatMap { map.layout.edges[$0]?.label } ?? ""
        }
        // A note asked for with the Note tool in the window extended to is
        // written here, in the window extended from.
        .onChange(of: map.pendingNote == nil) { _, isNil in
            if !isNil { noteFocused = true }
        }
        // View ▸ Extend Map to Other Display, in the window it was chosen in.
        .onReceive(NotificationCenter.default.publisher(for: .extendKnowledgeMapToOtherDisplay)) { note in
            let isThisWindow = (note.object as? UUID).map { $0 == windowState.id }
                ?? (StudioWindowRegistry.shared.activeState === windowState)
            guard isThisWindow else { return }
            toggleDisplayExtension()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas")
        .accessibilityIdentifier("knowledgeMap.pane")
    }

    /// The chrome line: the Space sidebar's own line over the sidebar, then
    /// the canvas's name as its menu, as a page's top line draws its name.
    private var header: some View {
        HStack(spacing: 0) {
            if showsSpaceSidebar {
                SpaceSidebarHeader(onSearch: { showSpacePlace(.all) })
                    .frame(width: max(0, SpaceSidebarMetrics.width - headerLeadingInset))
                StudioChromeLineDivider()
            }
            canvasHistoryButtons
            canvasMenu
                .padding(.horizontal, 10)
                .background(WindowDragBlocker())
            regionPath
            Spacer(minLength: 0)
        }
    }

    /// ‹ › over the canvases this window opened (⌘[ and ⌘]): there once it has
    /// opened two.
    @ViewBuilder
    private var canvasHistoryButtons: some View {
        let history = windowState.canvasHistory
        if history.hasHistory {
            HStack(spacing: 0) {
                StudioChromeIconButton(systemImage: "chevron.left", label: "Back to the previous canvas (⌘[)") {
                    vm.navigateCanvasHistory(.back, in: windowState)
                }
                .disabled(!history.canGoBack)
                .accessibilityIdentifier("knowledgeMap.history.back")
                StudioChromeIconButton(systemImage: "chevron.right", label: "Forward to the next canvas (⌘])") {
                    vm.navigateCanvasHistory(.forward, in: windowState)
                }
                .disabled(!history.canGoForward)
                .accessibilityIdentifier("knowledgeMap.history.forward")
            }
            .padding(.leading, 6)
            .background(WindowDragBlocker())
        }
    }

    /// The regions framing the view, after the canvas's name: "› Mootha ›
    /// mtDNA mutations". One plane holds every level, so the path says where
    /// on it the learner is; a step pressed flies out to that region (⌘↑
    /// climbs one step, ⌘↓ dives into the selected region).
    @ViewBuilder
    private var regionPath: some View {
        let path = map.viewport.path
        if !path.isEmpty, map.lens == nil {
            HStack(spacing: 2) {
                ForEach(Array(path.enumerated()), id: \.element.id) { index, step in
                    Image(systemName: "chevron.right")
                        .zoomedSystemFont(size: 9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                    Button {
                        map.send(.focus(refs: [], regionID: step.id))
                    } label: {
                        Text(step.name)
                            .zoomedSystemFont(size: 13, weight: index == path.count - 1 ? .semibold : .regular)
                            .foregroundStyle(index == path.count - 1 ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 220)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0, opacity: 0.09))
                    .help("Zoom out to \(step.name)")
                    .accessibilityIdentifier("knowledgeMap.path.\(step.id)")
                }
            }
            .background(WindowDragBlocker())
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: path.map(\.id))
        }
    }

    /// The canvas's name and its menu: the Space's menu for a canvas, and New
    /// Canvas. A canvas nothing is written to yet can only be named.
    private var canvasMenu: some View {
        Menu {
            if let canvas = vm.openCanvas {
                SpaceCanvasMenuItems(canvas: canvas, onRename: { renamingCanvas = canvas })
            } else {
                Button("Rename…", systemImage: "pencil") {
                    renamingCanvas = KnowledgeMapCanvas(
                        id: map.mapID,
                        name: vm.openCanvasName,
                        createdAt: Date(),
                        updatedAt: Date()
                    )
                }
            }
            Divider()
            Button("New Canvas", systemImage: KnowledgeMap.symbolName) {
                vm.makeAndOpenCanvas(inPageSpace: spaceSelection.pageSpaceID, in: windowState)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: KnowledgeMap.symbolName)
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(vm.openCanvasName)
                    .zoomedSystemFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .zoomedSystemFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0, opacity: 0.09))
        .fixedSize()
        .help("Canvas options")
        .accessibilityLabel("\(vm.openCanvasName), canvas options")
        .accessibilityIdentifier("knowledgeMap.canvasMenu")
    }

    /// Over a canvas the learner put in Trash: it stays readable and usable,
    /// and Restore brings it back to the lists.
    private func trashBanner(_ canvas: KnowledgeMapCanvas) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("This canvas is in Trash")
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .textSelection(.disabled)
            Button("Restore") { vm.restoreCanvases([canvas.id]) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .mapFloatingChrome(cornerRadius: 12)
        .accessibilityIdentifier("knowledgeMap.trashBanner")
    }

    // MARK: The Space beside the canvas

    /// A place chosen in the sidebar: the window's Space shows it, here.
    private func showSpacePlace(_ place: SpaceDestination) {
        if windowState.spaceDestinationKey != place.key { windowState.spaceDestinationKey = place.key }
        vm.openArtifactsInReader(in: windowState)
    }

    private func openSpaceRecent(_ item: SpaceRecents.Item) {
        switch item.kind {
        case .artifact:
            guard let artifact = vm.artifacts.first(where: { $0.id == item.id }) else { return }
            if vm.activeTeamID == nil, artifact.teamID != nil {
                Task { await vm.openTeamArtifact(artifact.id, in: windowState) }
            } else {
                vm.revealArtifact(artifact.id, in: windowState)
            }
        case .canvas:
            vm.openCanvas(item.id, in: windowState)
        case .list:
            showSpacePlace(.list(item.id))
        case .image:
            showSpacePlace(.images)
        }
    }

    /// New page from the sidebar beside a canvas: made in the space the
    /// sidebar has lit, when it has one, and opened.
    private func newSpacePage() {
        let spaceID = spaceSelection.pageSpaceID
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

    // MARK: Toolbar

    private static let tools: [(id: String, title: String, symbol: String)] = [
        ("select", "Select and move (V)", "cursorarrow"),
        ("hand", "Move around the canvas (H, or hold Space)", "hand.raised"),
        ("circle", "Circle cards to select them (C)", "lasso"),
        ("region", "Draw a region (R)", "rectangle.dashed"),
        ("connect", "Draw an arrow from one card to another (A)", "arrow.right"),
        ("note", "Write a note on the canvas (N)", "note.text.badge.plus"),
    ]

    private var toolsPill: some View {
        HStack(spacing: 2) {
            ForEach(Self.tools, id: \.id) { tool in
                Button {
                    map.send(.tool(tool.id))
                } label: {
                    Image(systemName: tool.symbol)
                        .zoomedSystemFont(size: 14)
                        .frame(width: 32, height: 28)
                        .foregroundStyle(map.tool == tool.id ? Color.accentColor : Color.primary.opacity(0.8))
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(map.tool == tool.id ? Color.accentColor.opacity(0.14) : .clear)
                        )
                }
                .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
                .help(tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityIdentifier("knowledgeMap.tool.\(tool.id)")
            }
        }
        .padding(4)
        .mapFloatingChrome(cornerRadius: 12)
    }

    /// The find field's width, and the whole pill's.
    private static let findFieldWidth: CGFloat = 180
    private static let findPillWidth: CGFloat = findFieldWidth + 38

    /// Freeform's arrangement: the tools centred over the plane and the find
    /// field on the trailing edge. A pane too narrow for both puts the tools
    /// beside the field rather than under it, then narrows the field.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                topBarLeading.frame(width: Self.findPillWidth, alignment: .leading)
                Spacer(minLength: 0)
                toolsPill
                Spacer(minLength: 0)
                findPill(fieldWidth: Self.findFieldWidth)
            }
            HStack(spacing: 10) {
                topBarLeading
                Spacer(minLength: 0)
                toolsPill
                findPill(fieldWidth: Self.findFieldWidth)
            }
            HStack(spacing: 8) {
                topBarLeading
                Spacer(minLength: 0)
                toolsPill
                findPill(fieldWidth: 96)
            }
        }
    }

    @ViewBuilder
    private var topBarLeading: some View {
        if !showsTray { trayToggle }
    }

    private func findPill(fieldWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .zoomedSystemFont(size: 12)
            TextField("Find on the canvas", text: $query)
                .textFieldStyle(.plain)
                .frame(width: fieldWidth)
                .onSubmit(find)
                .accessibilityIdentifier("knowledgeMap.find")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .mapFloatingChrome(cornerRadius: 12)
    }

    private var zoomPill: some View {
        HStack(spacing: 2) {
            toolbarButton("arrow.uturn.backward", help: "Undo (⌘Z)") { map.undo() }
                .disabled(!map.canUndo)
            toolbarButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)") { map.redo() }
                .disabled(!map.canRedo)
            Divider().frame(height: 16).padding(.horizontal, 3)
            toolbarButton("minus", help: "Zoom out") { map.send(.zoom(1 / 1.4)) }
            zoomReadout
            toolbarButton("plus", help: "Zoom in") { map.send(.zoom(1.4)) }
            Divider().frame(height: 16).padding(.horizontal, 3)
            toolbarButton("arrow.up.left.and.arrow.down.right", help: "Show the whole canvas (0)") { map.send(.fit) }
            Divider().frame(height: 16).padding(.horizontal, 3)
            displayExtensionButton
            shortcutsButton
        }
        .padding(4)
        .mapFloatingChrome(cornerRadius: 12)
    }

    /// The camera's zoom as a percentage between − and +; a click shows the
    /// whole canvas, as Heptabase's does.
    @ViewBuilder
    private var zoomReadout: some View {
        let scale = map.viewport.scale
        if scale > 0 {
            let percent = Int((scale * 100).rounded())
            Button {
                map.send(.fit)
            } label: {
                Text("\(percent)%")
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .frame(minWidth: 44, minHeight: 28)
            }
            .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
            .help("Zoom: show the whole canvas (0)")
            .accessibilityLabel("Zoom \(percent) percent: show the whole canvas")
            .accessibilityIdentifier("knowledgeMap.zoomReadout")
        }
    }

    /// The shortcuts and gestures, in a popover over the whole pane; ? on the
    /// plane opens it too.
    private var shortcutsButton: some View {
        @Bindable var map = map
        return toolbarButton("keyboard", help: "Keyboard shortcuts and gestures (?)") { map.showsShortcuts.toggle() }
            .popover(isPresented: $map.showsShortcuts, arrowEdge: .top) {
                KnowledgeMapShortcutsView()
            }
            .accessibilityIdentifier("knowledgeMap.shortcuts")
    }

    /// Extend to Other Display: the plane goes on in a second Map window on
    /// the other screen, and the button stops it again.
    private var displayExtensionButton: some View {
        let displays = KnowledgeMapDisplayExtension.shared
        let extending = displays.isExtending(from: canvasHandle.coordinator)
        let title = extending ? "Stop Extending" : "Extend to Other Display"
        return Button(action: toggleDisplayExtension) {
            Image(systemName: "display.2")
                .zoomedSystemFont(size: 13)
                .frame(width: 30, height: 28)
                .foregroundStyle(extending ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
        .disabled(!extending && displays.displayCount < 2)
        .help(displays.displayCount < 2 && !extending ? "Extend to Other Display (connect a second display)" : title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("knowledgeMap.extendToOtherDisplay")
    }

    private func toggleDisplayExtension() {
        let displays = KnowledgeMapDisplayExtension.shared
        if displays.isExtending(from: canvasHandle.coordinator) {
            displays.stop()
        } else if let canvas = canvasHandle.coordinator {
            displays.start(from: canvas, viewModel: vm, windowState: windowState)
        }
    }

    /// Brings the tray back once it was closed.
    private var trayToggle: some View {
        Button { showsTray = true } label: {
            Label("Add to the Canvas", systemImage: "sidebar.left")
                .zoomedSystemFont(size: 12, weight: .medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .buttonStyle(.hoverWash(cornerRadius: 12, inset: 0, opacity: 0.10))
        .mapFloatingChrome(cornerRadius: 12)
        .help("Show what is not on the canvas yet: your Ideas, notebooks and the library")
        .accessibilityIdentifier("knowledgeMap.tray.show")
    }

    /// What an empty map says: what it is for, and the first moves.
    private var emptyMapCard: some View {
        let ideas = map.unplacedIdeaRefs
        return VStack(alignment: .leading, spacing: 12) {
            Text("A canvas for what you think")
                .zoomedSystemFont(size: 17, weight: .semibold)
                .textSelection(.disabled)
            Text("Put your ideas here, group them into regions and draw how they connect. A source comes in as an idea's evidence: drop it on the idea. Or ask the chat to lay a topic out, its papers in context, and keep what helps.")
                .zoomedSystemFont(size: 13)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
            HStack(spacing: 10) {
                if !ideas.isEmpty {
                    Button(ideas.count == 1 ? "Place My Idea" : "Place My \(ideas.count) Ideas") {
                        map.send(.dropAtCenter(refs: ideas, regionName: nil))
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("knowledgeMap.empty.placeIdeas")
                }
                Button("Write an Idea") { map.send(.tool("note")) }
                    .help("Click anywhere on the canvas to write it there (N); double-click the canvas any time")
                Button("Lay Out a Topic…") { vm.requestKnowledgeMapTopicChat() }
                    .help("Ask the chat to show a topic on the canvas, its papers in context")
                    .accessibilityIdentifier("knowledgeMap.empty.topic")
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .mapFloatingChrome(cornerRadius: 16)
    }

    /// ForeverLM's sentence about what is on screen, in its own voice.
    private func captionCard(_ caption: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkle")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(Color.purple.opacity(0.8))
            Text(caption)
                .zoomedSystemFont(size: 12.5)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520)
        .mapFloatingChrome(cornerRadius: 12)
        .transition(.opacity)
    }

    /// The switches for how the plane is shown: the minimap, Focus (everything
    /// but the selection and its arrows fades) and the caption. The renderer
    /// draws the first two (`showsMinimap`, `focusMode`).
    private var viewSwitches: some View {
        @Bindable var map = map
        return HStack(spacing: 2) {
            viewSwitch(
                isOn: $map.showsMinimap,
                symbol: "map",
                label: "Minimap",
                help: map.showsMinimap ? "Hide the minimap" : "Show a minimap of the whole canvas",
                identifier: "knowledgeMap.minimap"
            )
            viewSwitch(
                isOn: $map.focusMode,
                symbol: "viewfinder.circle",
                label: "Focus",
                help: map.focusMode ? "Stop focusing (⇧F)" : "Fade everything but the selection and its arrows (⇧F)",
                identifier: "knowledgeMap.focus"
            )
            viewSwitch(
                isOn: $map.describesView,
                symbol: "text.viewfinder",
                label: "Describe the view",
                help: map.describesView ? "Stop describing what is in view" : "Describe what is in view as you explore",
                identifier: "knowledgeMap.describeView"
            )
        }
        .padding(4)
        .mapFloatingChrome(cornerRadius: 12)
    }

    private func viewSwitch(isOn: Binding<Bool>, symbol: String, label: String, help: String, identifier: String) -> some View {
        Toggle(isOn: isOn) {
            Image(systemName: symbol)
                .zoomedSystemFont(size: 14)
                .frame(width: 32, height: 28)
        }
        .toggleStyle(.button)
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// Nothing drawn is in view while the canvas holds something: the way back.
    private var showsBackToContent: Bool {
        map.viewport.empty && map.lens == nil && (map.placedCount > 0 || !map.layout.regions.isEmpty)
    }

    private var backToContentPill: some View {
        Button {
            map.send(.fit)
        } label: {
            Text("Back to content")
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.hoverWash(in: Capsule(), inset: 0, opacity: 0.10))
        .mapFloatingChrome(cornerRadius: 16)
        .transition(.opacity)
        .help("Show the whole canvas (0)")
        .accessibilityIdentifier("knowledgeMap.backToContent")
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .zoomedSystemFont(size: 13)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
        .help(help)
        .accessibilityLabel(help)
    }

    /// Flies to the cards whose title holds the words typed, and rings them.
    private func find() {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }
        // What is on the plane: placed cards and the evidence under them. The
        // rest of the library is found in the tray.
        let evidence = Set(map.content.links.filter { $0.kind == "idea" && map.layout.placements[$0.a] != nil }.map(\.b))
        let matches = map.content.nodes
            .filter { node in
                guard map.layout.placements[node.ref] != nil || evidence.contains(node.ref) else { return false }
                let title = node.title.lowercased()
                return words.allSatisfy { title.contains($0) }
            }
            .prefix(40)
            .map(\.ref)
        if matches.isEmpty {
            vm.showToast("Nothing on the canvas is called that; the tray finds the rest of your library")
        } else {
            map.send(.focus(refs: Array(matches), regionID: nil))
        }
    }

    // MARK: Lens

    private func lensBanner(_ lens: KnowledgeMapLens) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.filters")
                .foregroundStyle(.secondary)
            Text(lens.title)
                .zoomedSystemFont(size: 12, weight: .semibold)
                .lineLimit(1)
                .textSelection(.disabled)
            Text("\(lens.positions.count) cards")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            Button("Keep") { map.keepLens() }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .help("Place the cards where the lens put them, with its groups as regions")
                .accessibilityIdentifier("knowledgeMap.lens.keep")
            Button("Back to My Canvas") { map.clearLens() }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .accessibilityIdentifier("knowledgeMap.lens.clear")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .mapFloatingChrome(cornerRadius: 12)
    }

    // MARK: Note

    private var noteComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("A note", text: $noteText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($noteFocused)
                .onSubmit(addNote)
                .accessibilityIdentifier("knowledgeMap.note.text")
            HStack {
                Spacer()
                Button("Cancel") { map.pendingNote = nil }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addNote() }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
        .mapFloatingChrome(cornerRadius: 12)
    }

    private func addNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let spot = map.pendingNote else { return }
        map.pendingNote = nil
        map.send(.tool("select"))
        Task { await vm.createKnowledgeMapNote(text, at: spot) }
    }

    // MARK: Inspector

    private var showsInspector: Bool {
        // A review in place has the Canvas to itself (WP-B2).
        guard map.memory.review == nil else { return false }
        return !map.selection.isEmpty || map.selectedRegionID != nil || map.selectedEdgeID != nil
    }

    @ViewBuilder
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let id = map.selectedRegionID, let region = map.layout.regions[id] {
                    regionInspector(id: id, region: region)
                } else if let id = map.selectedEdgeID, let edge = map.layout.edges[id] {
                    edgeInspector(id: id, edge: edge)
                } else if !map.selection.isEmpty {
                    selectionInspector
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func regionInspector(id: String, region: KnowledgeMapLayout.Region) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // A notebook's frame is named by the notebook: renaming happens there.
            if let notebook = map.notebook(ofRegion: id) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(notebook.title, systemImage: "book.closed")
                        .zoomedSystemFont(size: 13, weight: .semibold)
                        .lineLimit(2)
                    if !notebook.summary.isEmpty {
                        Text(notebook.summary)
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    let takeaways = map.summaries["r:" + id]?.takeaways ?? []
                    if !takeaways.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(takeaways, id: \.self) { line in
                                Text("✦ " + line)
                                    .zoomedSystemFont(size: 12)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Button("Open Notebook") { vm.openNotebook(notebook.id, in: windowState) }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                        .help("Open this notebook; its new sources show up in this frame on their own")
                        .accessibilityIdentifier("knowledgeMap.region.openNotebook")
                }
                .textSelection(.disabled)
            } else {
                HStack(spacing: 6) {
                    TextField("Region name", text: $regionName)
                        .textFieldStyle(.roundedBorder)
                        .focused($regionNameFocused)
                        .onSubmit { map.renameRegion(id, to: regionName) }
                        .onChange(of: regionNameFocused) { _, focused in
                            if !focused { map.renameRegion(id, to: regionName) }
                        }
                        .disabled(region.locked == true)
                        .accessibilityIdentifier("knowledgeMap.region.name")
                    if region.locked == true {
                        Image(systemName: "lock.fill")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .help("Locked: unlock it to rename it, move it or take its cards out")
                            .accessibilityLabel("Locked")
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(KnowledgeMapModel.regionColors, id: \.self) { hex in
                    Button {
                        map.recolorRegion(id, to: hex)
                    } label: {
                        Circle()
                            .fill(Color(mapHex: hex))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(region.color == hex ? 0.7 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.hoverWash(in: Circle()))
                    .accessibilityLabel("Colour \(hex)")
                }
            }
            Text(regionCountsLine(id))
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            // A region drawn inside another: where it sits, and the way out.
            if let parentID = map.layout.parentRegionID(of: id), let parent = map.layout.regions[parentID] {
                Button {
                    map.send(.focus(refs: [], regionID: parentID))
                } label: {
                    Label("Inside \(map.notebook(ofRegion: parentID)?.title ?? (parent.name.isEmpty ? "Untitled region" : parent.name))", systemImage: "arrow.up.left")
                        .zoomedSystemFont(size: 12)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                .help("Zoom out to the region around this one (⌘↑)")
                .accessibilityIdentifier("knowledgeMap.region.parent")
            }
            // MARK: Ask (WP-B1)
            if !cardsInRegion(id).isEmpty {
                KnowledgeMapAskSection(refs: cardsInRegion(id), notebookID: map.notebook(ofRegion: id)?.id)
            }
            // A paper's region: shown as its pages, or as its figures only.
            if let paper = vm.knowledgeMapPaperLayout(ofRegion: id) {
                Picker("Show", selection: Binding(
                    get: { paper.layout },
                    set: { chosen in Task { await vm.relayoutKnowledgeMapPaper(regionID: id, as: chosen) } }
                )) {
                    ForEach(KnowledgeMapPaperLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Show this paper as its pages, its figures, or its figures with the extended and supplementary ones")
                .accessibilityIdentifier("knowledgeMap.region.paperLayout")
            }
            // Free, or a mind map laid out from its branches. A notebook's
            // frame is the notebook's own, and keeps its rows.
            if map.notebook(ofRegion: id) == nil {
                Picker("Layout", selection: Binding(
                    get: { region.layout == KnowledgeMapInspectorChoices.treeLayout ? KnowledgeMapInspectorChoices.treeLayout : "free" },
                    set: { vm.setKnowledgeMapRegionLayout(id, $0 == "free" ? nil : $0) }
                )) {
                    Text("Free").tag("free")
                    Text("Mind Map").tag(KnowledgeMapInspectorChoices.treeLayout)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Lay the region's cards out freely, or as a mind map from their branches")
                .accessibilityLabel("Layout")
                .accessibilityIdentifier("knowledgeMap.region.layout")
            }
            // Fold the region up to its name and count, or open it again: its
            // cards stay placed where they are, only not drawn.
            Button {
                map.setRegionCollapsed(id, !region.isCollapsed)
            } label: {
                Label(region.isCollapsed ? "Open Region" : "Fold Region Up", systemImage: region.isCollapsed ? "chevron.down.circle" : "chevron.up.circle")
                    .zoomedSystemFont(size: 12)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
            .disabled(cardsInRegion(id).isEmpty && !region.isCollapsed)
            .help(region.isCollapsed ? "Draw the cards in this region again" : "Draw only this region's name and count; its cards stay where they are")
            .accessibilityIdentifier("knowledgeMap.region.collapse")
            HStack {
                Button("Ask in Chat") { vm.requestChatAboutKnowledgeMapSelection(cardsInRegion(id)) }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .disabled(cardsInRegion(id).isEmpty)
                Spacer()
                regionMenu(id: id, region: region)
                Button("Delete Region", role: .destructive) { map.deleteRegion(id) }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .help("The region goes; its cards stay where they are")
            }
        }
    }

    /// A region's ⋯: Lock or Unlock, Fit to Content, and for a mind map Turn
    /// into Cards and Arrows.
    private func regionMenu(id: String, region: KnowledgeMapLayout.Region) -> some View {
        Menu {
            Button(region.locked == true ? "Unlock" : "Lock", systemImage: region.locked == true ? "lock.open" : "lock") {
                vm.setKnowledgeMapRegionLocked(id, region.locked != true)
            }
            .help(region.locked == true ? "Let its cards and the region be moved again" : "Keep its cards and the region where they are")
            .accessibilityIdentifier("knowledgeMap.region.lock")
            Button("Fit to Content") { vm.fitKnowledgeMapRegionToContent(id) }
                .disabled(cardsInRegion(id).isEmpty)
                .help("Shrink or grow the region to just hold its cards")
                .accessibilityIdentifier("knowledgeMap.region.fit")
            if region.layout == KnowledgeMapInspectorChoices.treeLayout {
                Button("Turn into Cards and Arrows") { vm.turnKnowledgeMapTreeIntoArrows(regionID: id) }
                    .help("Keep the cards where the mind map put them, joined by arrows, and lay the region out freely")
                    .accessibilityIdentifier("knowledgeMap.region.turnIntoArrows")
            }
        } label: {
            Image(systemName: "ellipsis")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .accessibilityIdentifier("knowledgeMap.region.more")
    }

    /// "12 cards · 2 regions inside": the cards in the region, the regions
    /// inside it counted too.
    private func regionCountsLine(_ id: String) -> String {
        let cards = cardsInRegion(id).count
        let nested = map.layout.nestedRegionIDs(in: id).count
        var parts = ["\(cards) \(cards == 1 ? "card" : "cards")"]
        if nested > 0 { parts.append("\(nested) \(nested == 1 ? "region" : "regions") inside") }
        return parts.joined(separator: " · ")
    }

    /// A region's cards: those placed in it (a card in a region inside it is
    /// that region's), and for a notebook's frame the notebook's cards not
    /// placed anywhere, which it draws too.
    private func cardsInRegion(_ id: String) -> [String] {
        let placed = map.layout.placements.keys.filter { map.regionID(containing: $0) == id }.sorted()
        guard let notebook = map.notebook(ofRegion: id) else { return placed }
        return placed + notebook.refs.filter { map.layout.placements[$0] == nil }
    }

    /// **Figures Only** (and **Figures + Extended Data**) on a selected paper:
    /// one clip card per figure, in a row.
    private func layOutFigures(of sourceID: String, extended: Bool) {
        Task { @MainActor in
            do {
                let outcome = try await vm.layOutKnowledgeMapFigures(sourceID: sourceID, includeExtended: extended)
                if outcome.refs.isEmpty {
                    vm.showToast("Every figure of that paper is on the canvas already")
                } else {
                    map.send(.focus(refs: Array(outcome.refs.prefix(3)), regionID: nil))
                    if outcome.extendedLeftOut > 0 {
                        vm.showToast("Laid out \(outcome.refs.count) figures; \(outcome.extendedLeftOut) extended \(outcome.extendedLeftOut == 1 ? "figure waits" : "figures wait") under Figures + Extended Data")
                    }
                }
            } catch {
                vm.showToast(error.localizedDescription)
            }
        }
    }

    /// **Lay Out Pages** on a selected paper: its pages as cards in a row.
    private func layOutPages(of sourceID: String) {
        Task { @MainActor in
            do {
                let outcome = try await vm.layOutKnowledgeMapPages(sourceID: sourceID, pages: nil)
                if outcome.refs.isEmpty {
                    vm.showToast("Every page of that paper is on the canvas already")
                } else {
                    map.send(.focus(refs: Array(outcome.refs.prefix(3)), regionID: nil))
                    if outcome.leftOut > 0 {
                        vm.showToast("Laid out \(outcome.refs.count) pages; \(outcome.leftOut) more wait. Ask for the rest by page range.")
                    }
                }
            } catch {
                vm.showToast(error.localizedDescription)
            }
        }
    }

    private func edgeInspector(id: String, edge: KnowledgeMapLayout.Edge) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(map.title(of: edge.from)) → \(map.title(of: edge.to))")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.disabled)
            TextField("Label", text: $edgeLabel)
                .textFieldStyle(.roundedBorder)
                .onSubmit { map.relabelEdge(id, to: edgeLabel) }
                .accessibilityIdentifier("knowledgeMap.edge.label")
            KnowledgeMapEdgeStyleControls(id: id, edge: edge)
            HStack {
                Spacer()
                Button("Delete Arrow", role: .destructive) { map.deleteEdge(id) }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
            }
        }
        .onDisappear { map.relabelEdge(id, to: edgeLabel) }
    }

    /// The colour every one of `refs` has, nil when none has one or they differ.
    private func sharedCardColor(of refs: [String]) -> String? {
        let colours = Set(refs.map { map.layout.placements[$0]?.color })
        guard colours.count == 1, let only = colours.first else { return nil }
        return only
    }

    /// The cards' ⋯: how one opens, laying a paper out, fold, size, tidying,
    /// moving to another canvas, copying and taking off. The plane's own
    /// right-click menu offers the same through the same calls
    /// (`StudioViewModel+CanvasInspector.swift`).
    private func cardsMenu(refs: [String], placed: [String], pagedSource: String?) -> some View {
        Menu {
            if refs.count == 1 {
                Button("Open Beside", systemImage: "rectangle.righthalf.inset.filled") {
                    Task { await vm.openKnowledgeMapItemBeside(refs[0], in: windowState) }
                }
                .help("Open it beside the canvas, which stays as it is")
                .accessibilityIdentifier("knowledgeMap.selection.openBeside")
                KnowledgeMapOpenInMenu(ref: refs[0])
                Divider()
            }
            // A paper (or a book or hand-out kept as a PDF) can be laid out as
            // its pages, or as its figures only (with or without the extended
            // and supplementary ones).
            if let sourceID = pagedSource {
                Menu("Lay Out") {
                    Button("Pages") { layOutPages(of: sourceID) }
                        .accessibilityIdentifier("knowledgeMap.selection.layOutPages")
                    Button("Figures Only") { layOutFigures(of: sourceID, extended: false) }
                        .accessibilityIdentifier("knowledgeMap.selection.layOutFigures")
                    Button("Figures + Extended Data") { layOutFigures(of: sourceID, extended: true) }
                        .accessibilityIdentifier("knowledgeMap.selection.layOutFiguresExtended")
                }
            }
            KnowledgeMapCardActionItems(refs: refs)
            if !placed.isEmpty {
                Divider()
                Button("Take Off Canvas") { map.unplace(placed) }
                    .help("Send these cards back to their notebook on the shore")
            }
        } label: {
            Image(systemName: "ellipsis")
                .zoomedSystemFont(size: 12)
                .foregroundStyle(.secondary)
        }
        // A borderless Menu redraws its label as a native popup
        // title and drops the font; the button style keeps it.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverHighlight()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .accessibilityIdentifier("knowledgeMap.selection.more")
    }

    @ViewBuilder
    private var selectionInspector: some View {
        let refs = map.selection
        // A single clip is drawn by its own inspector: its note, a way to the
        // page, Ask in Chat and a ⋯. Its card already says what it is.
        if refs.count == 1, let clip = KnowledgeMap.ItemRef(refs[0]), clip.kind == .clip {
            KnowledgeMapClipInspector(clipID: clip.id, ref: refs[0])
                .id(clip.id)
        } else {
            cardsInspector(refs)
        }
    }

    private func cardsInspector(_ refs: [String]) -> some View {
        let placed = vm.knowledgeMapPlacedRefs(among: refs)
        let pagedSource: String? = {
            guard refs.count == 1, let item = KnowledgeMap.ItemRef(refs[0]), item.kind == .source,
                  vm.knowledgeMapSourceHasPages(item.id) else { return nil }
            return item.id
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Ask in Chat") { vm.requestChatAboutKnowledgeMapSelection(refs) }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .accessibilityIdentifier("knowledgeMap.selection.ask")
                if refs.count == 1 {
                    Button("Open") { Task { await vm.openKnowledgeMapItem(refs[0], in: windowState) } }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                }
                KnowledgeMapAskSection(refs: refs) // Ask (WP-B1)
                Spacer()
                cardsMenu(refs: refs, placed: placed, pagedSource: pagedSource)
            }
            // The cards' colour: one of eight, or the kind's own.
            if !placed.isEmpty {
                KnowledgeMapColorRow(
                    selected: sharedCardColor(of: placed),
                    defaultIsSelected: placed.allSatisfy { map.layout.placements[$0]?.color == nil }
                ) { hex in
                    vm.setKnowledgeMapCardColor(placed, to: hex)
                }
            }
            if refs.count == 1, let idea = KnowledgeMap.ItemRef(refs[0]), idea.kind == .idea {
                ideaEvidence(ideaRef: refs[0], ideaID: idea.id)
            }
            ForEach(refs.prefix(40), id: \.self) { ref in
                if let node = map.nodesByRef[ref] {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title)
                            .zoomedSystemFont(size: 12, weight: .medium)
                            .lineLimit(3)
                        if !node.sub.isEmpty {
                            Text(node.sub)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        ForEach(node.detail, id: \.self) { line in
                            Text(line)
                                .zoomedSystemFont(size: 11)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.4)
                }
            }
            if refs.count > 40 {
                Text("and \(refs.count - 40) more")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
        }
    }
}

/// The window the Map is extended to on another display
/// (`KnowledgeMapDisplayExtension`): the same plane, continuing from the
/// first window's, with Stop Extending floating at its top. Its tools,
/// inspector and composer are the first window's: what is selected here
/// shows there, and a card opened here opens there.
struct KnowledgeMapExtensionView: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState

    let handle: KnowledgeMapCanvasHandle
    weak var primaryWindow: NSWindow?

    var body: some View {
        let map = vm.knowledgeMap
        ZStack(alignment: .top) {
            KnowledgeMapCanvasView(
                model: map,
                layoutRevision: map.layoutRevision,
                contentRevision: map.contentRevision,
                lensRevision: map.lensRevision,
                summariesRevision: map.summariesRevision,
                commandCount: 0,
                onOpen: { ref in
                    primaryWindow?.makeKeyAndOrderFront(nil)
                    Task { await vm.openKnowledgeMapItem(ref, in: windowState) }
                },
                onNoteRequested: { x, y in
                    map.pendingNote = (x, y)
                    primaryWindow?.makeKeyAndOrderFront(nil)
                },
                onDrop: { drop in
                    Task { @MainActor in
                        guard let placed = await vm.knowledgeMapCards(for: drop, on: map) else { return }
                        // Set down by this window's renderer: the point is in its
                        // view. Its cards are pushed first, so it knows a new clip.
                        handle.coordinator?.sync()
                        handle.coordinator?.perform(.drop(x: drop.point.x, y: drop.point.y, refs: placed.refs, regionName: placed.regionName, notebookID: placed.notebookID))
                    }
                },
                onLinkEvidence: { idea, refs in
                    Task { await vm.linkKnowledgeMapEvidence(ideaRef: idea, refs: refs) }
                },
                role: .extensionWindow,
                handle: handle,
                proposalsRevision: map.proposalsRevision, // Proposals and faces (WP-B1)
                facesRevision: map.facesRevision,
                memorySync: map.memory.syncToken // Memory (WP-B2)
            )
            .ignoresSafeArea()
            HStack(spacing: 10) {
                Image(systemName: "display.2")
                    .foregroundStyle(.secondary)
                Text("Canvas, extended")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                    .textSelection(.disabled)
                Button("Stop Extending") { KnowledgeMapDisplayExtension.shared.stop() }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .accessibilityIdentifier("knowledgeMap.stopExtending")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .mapFloatingChrome(cornerRadius: 12)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas, extended to this display")
        .accessibilityIdentifier("knowledgeMap.extension")
    }
}

extension Notification.Name {
    /// View ▸ Extend Map to Other Display, for the key window's Map pane.
    static let extendKnowledgeMapToOtherDisplay = Notification.Name("extendKnowledgeMapToOtherDisplay")
}

extension KnowledgeMapPane {
    /// An Idea's evidence in the inspector: each source or Doc linked to it,
    /// to open or unlink. Dropping a card on the Idea links another.
    @ViewBuilder
    fileprivate func ideaEvidence(ideaRef: String, ideaID: String) -> some View {
        let evidence = map.evidence(of: ideaRef)
        VStack(alignment: .leading, spacing: 6) {
            Text(evidence.isEmpty ? "No evidence yet" : "Evidence · \(evidence.count)")
                .zoomedSystemFont(size: 11, weight: .semibold)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            if evidence.isEmpty {
                Text("Drop a source or Page on this idea, from the canvas or the tray, to link it.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
            }
            ForEach(evidence, id: \.self) { ref in
                HStack(alignment: .top, spacing: 6) {
                    Button {
                        Task { await vm.openKnowledgeMapItem(ref, in: windowState) }
                    } label: {
                        Text(map.title(of: ref))
                            .zoomedSystemFont(size: 12)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -3, opacity: 0.08))
                    Button {
                        guard let item = KnowledgeMap.ItemRef(ref) else { return }
                        Task {
                            await vm.unlinkIdea(ideaID: ideaID, kind: item.kind == .doc ? .artifact : .source, targetIDs: [item.id])
                            await vm.refreshKnowledgeMapContent()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .zoomedSystemFont(size: 10)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0, opacity: 0.10))
                    .help("Unlink from this idea")
                    .accessibilityLabel("Unlink \(map.title(of: ref))")
                }
            }
        }
        .padding(.vertical, 4)
        Divider().opacity(0.4)
    }
}

/// What is not on the map yet, on the plane's leading edge: the open Ideas
/// waiting to be placed, the notebooks, and a search of the whole library.
/// Each row's + sets it down in the middle of the view; a source or Doc can
/// also be dragged onto the map, or onto an Idea to become its evidence.
struct KnowledgeMapTray: View {
    @Environment(StudioViewModel.self) private var vm
    let onClose: () -> Void

    @State private var query = ""

    private var map: KnowledgeMapModel { vm.knowledgeMap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add to the Canvas")
                    .zoomedSystemFont(size: 13, weight: .semibold)
                    .textSelection(.disabled)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .zoomedSystemFont(size: 11)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                .help("Hide the tray")
                .accessibilityIdentifier("knowledgeMap.tray.close")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .zoomedSystemFont(size: 12)
                TextField("Find a source, Page or idea", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("knowledgeMap.tray.search")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        regionsSection
                        thisNotebookSection
                        ideasSection
                        clipsSection
                        notebooksSection
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Sections

    /// The open canvas's regions in reading order, a region before the ones
    /// inside it, indented: a table of contents for the plane. A click flies
    /// to the region.
    @ViewBuilder
    private var regionsSection: some View {
        let rows = map.layout.regionOutline()
        if !rows.isEmpty {
            let counts = regionCardCounts()
            sectionHeader("Regions", trailing: nil)
            ForEach(rows, id: \.id) { row in
                regionRow(row, cards: counts[row.id] ?? 0)
            }
        }
    }

    /// How many placed cards each region holds as its own, in one pass.
    private func regionCardCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for ref in map.layout.placements.keys {
            if let id = map.regionID(containing: ref) { counts[id, default: 0] += 1 }
        }
        return counts
    }

    private func regionRow(_ row: KnowledgeMapLayout.RegionOutlineRow, cards: Int) -> some View {
        let region = map.layout.regions[row.id]
        let written = region?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = map.notebook(ofRegion: row.id)?.title ?? (written.isEmpty ? "Untitled region" : written)
        return Button {
            map.send(.focus(refs: [], regionID: row.id))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(Color(mapHex: region?.color ?? ""))
                Text(name)
                    .zoomedSystemFont(size: 12)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if cards > 0 {
                    Text("\(cards)")
                        .zoomedSystemFont(size: 10.5)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 6 + CGFloat(row.depth) * 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.08))
        .help("Zoom to \(name)")
        .accessibilityLabel("Zoom to region \(name)")
        .accessibilityIdentifier("knowledgeMap.tray.region.\(row.id)")
    }

    /// A notebook's own canvas opens its tray on the notebook's sources: the
    /// ticked ones, each placed from here (product owner, 2026-10-09).
    @ViewBuilder
    private var thisNotebookSection: some View {
        if let notebookID = vm.openCanvas?.notebookID, let notebook = vm.notebook(id: notebookID) {
            let unticked = vm.notebookChatExclusions[notebookID] ?? []
            let refs = notebook.approvedSourceIDs
                .filter { !unticked.contains($0) }
                .map { KnowledgeMap.ItemRef(kind: .source, id: $0).description }
                .filter { map.nodesByRef[$0] != nil }
            let unplaced = refs.filter { map.layout.placements[$0] == nil }
            sectionHeader(
                NotebookTitle(notebook.title).text,
                trailing: unplaced.count > 1 ? ("Place All", { map.send(.dropAtCenter(refs: unplaced, regionName: nil)) }) : nil
            )
            ForEach(refs, id: \.self) { ref in
                row(ref)
            }
        }
    }

    @ViewBuilder
    private var ideasSection: some View {
        let ideas = map.unplacedIdeaRefs
        sectionHeader("Ideas", trailing: ideas.count > 1 ? ("Place All", { map.send(.dropAtCenter(refs: ideas, regionName: nil)) }) : nil)
        if ideas.isEmpty {
            Text("Every open idea is on the canvas. Write another anywhere with the Note tool (N).")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
                .textSelection(.disabled)
        }
        ForEach(ideas, id: \.self) { ref in
            row(ref)
        }
    }

    /// Clips saved in the Reader and not placed yet, newest first. A clip
    /// dragged straight onto the Canvas never waits here.
    @ViewBuilder
    private var clipsSection: some View {
        let clips = map.content.nodes
            .filter { $0.kind == "clip" && map.layout.placements[$0.ref] == nil }
            .map(\.ref)
            .reversed()
        if !clips.isEmpty {
            sectionHeader("Clips", trailing: clips.count > 1 ? ("Place All", { map.send(.dropAtCenter(refs: Array(clips), regionName: nil)) }) : nil)
            ForEach(Array(clips), id: \.self) { ref in
                row(ref)
            }
        }
    }

    @ViewBuilder
    private var notebooksSection: some View {
        sectionHeader("Notebooks", trailing: nil)
        ForEach(vm.notebooks.filter { !$0.approvedSourceIDs.isEmpty }.prefix(80), id: \.id) { notebook in
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(NotebookTitle(notebook.title).text)
                        .zoomedSystemFont(size: 12)
                        .lineLimit(2)
                    Text(notebook.approvedSourceIDs.count == 1 ? "1 source" : "\(notebook.approvedSourceIDs.count) sources")
                        .zoomedSystemFont(size: 10.5)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                placeButton(help: "Set this notebook's sources and Pages down in a region of their own") {
                    let placed = vm.knowledgeMapDrop(sourceIDs: [], docIDs: [], notebookIDs: [notebook.id])
                    guard !placed.refs.isEmpty else { return }
                    map.send(.dropAtCenter(refs: placed.refs, regionName: placed.regionName, notebookID: placed.notebookID))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .textSelection(.disabled)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let matches = map.content.nodes
            .filter { node in
                let title = node.title.lowercased()
                return words.allSatisfy { title.contains($0) }
            }
            .prefix(60)
        if matches.isEmpty {
            Text("Nothing in the library is called that.")
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .padding(6)
                .textSelection(.disabled)
        }
        ForEach(Array(matches), id: \.ref) { node in
            row(node.ref)
        }
    }

    // MARK: Rows

    private func sectionHeader(_ title: String, trailing: (String, () -> Void)?) -> some View {
        HStack {
            Text(title.uppercased())
                .zoomedSystemFont(size: 10, weight: .semibold)
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
            Spacer()
            if let trailing {
                Button(trailing.0, action: trailing.1)
                    .buttonStyle(.hoverWash(cornerRadius: 5, inset: -3, opacity: 0.10))
                    .zoomedSystemFont(size: 11)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// One card: its title and who and when; + places it, or, once it is on
    /// the map, the pin flies there. A source or Doc drags onto the map too.
    @ViewBuilder
    private func row(_ ref: String) -> some View {
        if let node = map.nodesByRef[ref] {
            let placed = map.layout.placements[ref] != nil
            let content = HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(node.kind == "idea" ? Color.yellow.opacity(0.8) : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title)
                        .zoomedSystemFont(size: 12)
                        .lineLimit(3)
                    if !node.sub.isEmpty, node.kind != "idea" {
                        Text(node.sub)
                            .zoomedSystemFont(size: 10.5)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if placed {
                    Button {
                        map.send(.focus(refs: [ref], regionID: nil))
                    } label: {
                        Image(systemName: "scope")
                            .zoomedSystemFont(size: 12)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
                    .help("On the canvas: show it")
                } else {
                    placeButton(help: "Place it in the middle of the view") {
                        map.send(.dropAtCenter(refs: [ref], regionName: nil))
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .textSelection(.disabled)
            if let provider = dragProvider(ref) {
                content.onDrag { provider() }
            } else {
                content
            }
        }
    }

    private func placeButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus")
                .zoomedSystemFont(size: 12, weight: .medium)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0, opacity: 0.10))
        .help(help)
    }

    /// A source or Doc drags the way it does from the Sources list or Docs,
    /// so the map, an Idea on it, or a chat can take it.
    private func dragProvider(_ ref: String) -> (() -> NSItemProvider)? {
        guard let item = KnowledgeMap.ItemRef(ref) else { return nil }
        switch item.kind {
        case .source:
            guard let article = vm.articles.first(where: { $0.id == item.id }) else { return nil }
            return { articleDragProvider(for: article) }
        case .doc:
            guard let artifact = vm.artifacts.first(where: { $0.id == item.id }) else { return nil }
            return { studioArtifactDragProvider(for: artifact) }
        case .clip:
            guard let clip = map.clips[item.id], let transfer = StudioClipTransfer(clip: clip) ?? StudioClipTransfer(passage: clip),
                  let data = try? JSONEncoder().encode(transfer) else { return nil }
            return {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.studioClip.identifier, visibility: .ownProcess) { done in
                    done(data, nil)
                    return nil
                }
                return provider
            }
        case .idea, .page, .canvas, .chat, .picture:
            return nil
        }
    }
}

extension View {
    /// The floating chrome over the plane: a frosted rounded card with a
    /// hairline and a soft shadow, like Freeform's toolbars.
    func mapFloatingChrome(cornerRadius: CGFloat) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

extension Color {
    /// `#rrggbb`, the renderer's region tints.
    init(mapHex hex: String) {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        let value = UInt32(digits, radix: 16) ?? 0x888780
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// What the Canvas's keys and gestures do.
struct KnowledgeMapShortcutsView: View {
    struct Row: Identifiable {
        let what: String
        let how: String
        var id: String { what }

        init(_ what: String, _ how: String) {
            self.what = what
            self.how = how
        }
    }

    static let rows: [Row] = [
        .init("Move around", "Scroll with two fingers, or hold Space and drag (H)"),
        .init("Zoom", "Pinch, or ⌘-scroll; + and −"),
        .init("Show everything", "0"),
        .init("Zoom to the selection", "F, or double-tap a card with two fingers"),
        .init("Select", "Click; ⇧-click to add; drag across the empty canvas"),
        .init("Circle cards", "C, or drag with ⌥"),
        .init("Select everything", "⌘A"),
        .init("Select the next card", "The arrow keys"),
        .init("Move the selection", "Drag, or ⌥ with the arrow keys (⇧ for bigger steps)"),
        .init("Line up while dragging", "Guides show; hold ⌘ to place freely"),
        .init("Make a region around it", "⌘G"),
        .init("Draw a region", "R, inside another to nest it"),
        .init("Zoom into a region", "Double-click its name or face; Return or ⌘↓ with it selected"),
        .init("Climb out to the region around", "⌘↑"),
        .init("Draw an arrow", "A"),
        .init("Write a note", "Double-click the empty canvas, or N"),
        .init("Open a card", "Double-click it"),
        .init("Open it beside the canvas", "⌥-click it, or Return (an idea edits instead)"),
        .init("Float it as a popup", "⌘-click it; Esc or a click elsewhere closes it"),
        .init("Edit an idea", "Return, or double-click it; ⌘Return or a click away writes it"),
        .init("Peek at a card", "Tap Space with it selected"),
        .init("Focus on the selection", "⇧F"),
        .init("Previous and next canvas", "⌘[ and ⌘]"),
        .init("Fan a series out", "Double-click its stack"),
        .init("Take it off the canvas", "Delete"),
        .init("Delete the selection", "⌘Delete: an idea goes to Trash, anything else comes off the canvas"),
        .init("Let go", "Esc clears the selection, closes a popup and leaves editing"),
        .init("Undo, Redo", "⌘Z, ⇧⌘Z"),
        .init("These shortcuts", "?"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Canvas shortcuts")
                .zoomedSystemFont(size: 14, weight: .semibold)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(Self.rows) { row in
                    GridRow {
                        Text(row.what)
                            .foregroundStyle(.secondary)
                        Text(row.how)
                    }
                    .zoomedSystemFont(size: 12.5)
                }
            }
        }
        .padding(18)
        .frame(width: 470, alignment: .leading)
        .textSelection(.disabled)
    }
}
