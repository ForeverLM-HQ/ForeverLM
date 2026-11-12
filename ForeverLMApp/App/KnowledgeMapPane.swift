import SwiftUI

/// A canvas: a plane for what the learner thinks (docs/knowledge-map-design.md).
/// Their Ideas, the regions they draw and the arrows between them sit on it;
/// an Idea's sources hang under it as evidence.
///
/// A canvas is an item in the Space, so it opens as a page does: the Space
/// sidebar on the leading edge, the canvas beside it, and the canvas's name
/// at the top as its menu ("Canvases in the Space").
///
/// The plane is `KnowledgeMapCanvasView`. Around it, kept quiet
/// (docs/knowledge-map-design.md, "A quiet canvas"): three tools (select,
/// region, arrow), a find field that also adds, and the Library button above;
/// zoom below, and the view switches that are on; the lens banner while a
/// chat's lens shows; the Library, a sidebar on the trailing edge with what is
/// not on the canvas yet (closed until asked for, and the plane narrows for
/// it); and, over the plane's trailing edge, what is selected — its name or
/// cards, Ask in Chat, Ask, and a ⋯ for the rest. Everything else is a key, the
/// canvas's menu (Show ▸), the View menu or a right-click. An empty map says
/// what to do first. docs/knowledge-map-design.md, "Adding to the canvas".
struct KnowledgeMapPane: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.studioCenterPaneHeaderLeadingInset) private var headerLeadingInset

    @State private var findQuery = ""
    @State private var findHighlight = 0
    @FocusState private var findFocused: Bool
    /// How tall the inspector's content is, measured: the card is that tall.
    @State private var inspectorHeight: CGFloat = 200
    @State private var noteText = ""
    @State private var regionName = ""
    @FocusState private var noteFocused: Bool
    @FocusState private var regionNameFocused: Bool
    /// This pane's canvas, for Extend to Other Display.
    @State private var canvasHandle = KnowledgeMapCanvasHandle()
    // MARK: The Space beside the canvas
    /// The learner's choice to keep the Space sidebar out of the way, shared
    /// with the Space and its pages; this Mac's.
    @AppStorage(Prefs.Space.sidebarHidden) private var spaceSidebarHiddenByLearner
    @State private var paneWidth: CGFloat = 0
    @State private var renamingCanvas: KnowledgeMapCanvas?
    @State private var linkSection: ArtifactSection?
    @State private var linkedArtifactID: String?
    @State private var isCreatingSpace = false

    private var map: KnowledgeMapModel { vm.knowledgeMap }

    /// The narrowest the plane is drawn beside its sidebars: room for its
    /// tools, the find field and the Library button. Below it the sidebars
    /// step aside (the Space's first, then the Library) rather than push the
    /// pane wider than its frame: a canvas opened beside the home in a
    /// 1,300-point window would otherwise draw its Space sidebar under the
    /// home and cut the Library off at the window's edge.
    private static let minimumPlaneWidth: CGFloat = 440
    private static let librarySidebarWidth: CGFloat = 300

    /// The Library sits beside the plane while the learner has it open, and
    /// steps aside for a review in place, or while the pane has no room for it.
    private var showsLibrarySidebar: Bool {
        map.showsLibrary && map.memory.review == nil
            && (paneWidth <= 0 || paneWidth >= Self.minimumPlaneWidth + Self.librarySidebarWidth + 1)
    }

    /// Nothing placed yet on a canvas with a library to place from.
    private var isBlankCanvas: Bool {
        map.placedCount == 0 && map.lens == nil && !map.content.nodes.isEmpty
    }

    /// The sidebar shows unless the learner hid it or the pane is too narrow
    /// for it beside the canvas (and the Library, when that shows).
    private var showsSpaceSidebar: Bool {
        guard !spaceSidebarHiddenByLearner else { return false }
        guard paneWidth > 0 else { return true }
        let beside = SpaceSidebarMetrics.width + 1 + (showsLibrarySidebar ? Self.librarySidebarWidth + 1 : 0)
        return paneWidth >= SpaceSidebarMetrics.minimumPaneWidth && paneWidth - beside >= Self.minimumPlaneWidth
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

    /// The Space sidebar, the plane with what floats over it, and the Library.
    @ViewBuilder
    private var paneLayout: some View {
        let map = map
        // Read here, in the layout, for the overlay that draws them below.
        let findListing = findListing
        let findHighlight = findHighlight
        HStack(spacing: 0) {
            if showsSpaceSidebar {
                SpaceSidebar(
                    selection: spaceSelection,
                    openArtifactID: map.mapID,
                    onSelect: showSpacePlace,
                    onOpenRecent: openSpaceRecent,
                    onNewPage: newSpacePage,
                    onLink: { linkSection = $0 },
                    onNewSpace: { isCreatingSpace = true },
                    onSearch: { showSpacePlace(.all) }
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
                            map.send(.drop(x: drop.point.x, y: drop.point.y, refs: placed.refs, regionName: placed.regionName, notebookID: placed.notebookID),
                                     in: windowState.id)
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
                if isBlankCanvas {
                    blankCanvasHint
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
                            // Speaking to the canvas: only while it listens or works.
                            if KnowledgeMapVoice.shared.isShowing {
                                KnowledgeMapVoiceCapsule()
                                    .transition(.opacity)
                            }
                            if showsBackToContent {
                                backToContentPill
                            }
                            if let caption = map.viewCaption {
                                captionCard(caption)
                            }
                        }
                        Spacer(minLength: 12)
                        switchesOn
                    }
                }
                .padding(14)
                // What is selected hangs from the top of the trailing edge, under the
                // find field, as tall as it is (at most 520 points, then it scrolls).
                HStack {
                    Spacer()
                    if showsInspector {
                        inspector
                            .frame(width: 290)
                            .mapFloatingChrome(cornerRadius: 14)
                            .padding(.trailing, 14)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.vertical, 64)
                .animation(.easeInOut(duration: 0.18), value: showsInspector)
                // MARK: Review (WP-B2)
                KnowledgeMapReviewLayer()
                // ⌘-click: a card's faces floating beside it.
                KnowledgeMapPopupLayer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // What floats under the chrome (the add box under the tools, the find
            // field's list under the field) is placed from where the pills are.
            .overlayPreferenceValue(KnowledgeMapChromeAnchorKey.self) { anchors in
                chromeOverlay(anchors, findListing: findListing, findHighlight: findHighlight)
            }
            // The Library: a sidebar on the plane's trailing edge; the plane narrows.
            if showsLibrarySidebar {
                Divider()
                KnowledgeMapLibrarySidebar(onClose: { map.showsLibrary = false })
                    .frame(width: Self.librarySidebarWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsSpaceSidebar)
        .animation(.easeInOut(duration: 0.18), value: showsLibrarySidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The width the pane is given, not what its row asks for: measured on
        // the row, a row too wide for its pane reports its own width and the
        // sidebars never step aside.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { paneWidth = $0 }
        // Nothing of the pane is drawn over the pane beside it.
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var body: some View {
        paneLayout
            .canvasRenameAlert($renamingCanvas)
            // Opening a canvas is a Recents entry, as opening a page is.
            .onChange(of: map.mapID, initial: true) { _, id in
                SpaceRecents.shared.note(.canvas, id: id)
            }
            // A blank canvas opens with the Library beside it, so there is
            // something to drag on; closing it keeps it closed.
            .onChange(of: "\(map.mapID)|\(isBlankCanvas)", initial: true) {
                if isBlankCanvas { map.showsLibrary = true }
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
            // Written Faces turned on, from the canvas's menu or anywhere:
            // what each source says is written now.
            .onChange(of: map.showsWrittenFaces) { _, isOn in
                if isOn { Task { await vm.refreshKnowledgeMapFaces() } }
            }
            .onChange(of: map.selectedRegionID) { _, id in
                regionName = id.flatMap { map.layout.regions[$0]?.name } ?? ""
                if let id, map.layout.regions[id]?.name.isEmpty == true { regionNameFocused = true }
            }
            // ⌘F on the plane: the cursor goes to the find field, in the window
            // the learner is working in.
            .onChange(of: map.findFocusRequests) {
                guard StudioWindowRegistry.shared.activeState === windowState else { return }
                findFocused = true
            }
            .onChange(of: findQuery) { findHighlight = 0 }
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

    /// The chrome line: nothing over the sidebar but the window's own
    /// controls (the sidebar's top line is its first row), then the canvas's
    /// name as its menu, as a page's top line draws its name.
    private var header: some View {
        HStack(spacing: 0) {
            if showsSpaceSidebar {
                SpaceSidebarChromeSpace()
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
            // Hold S on the plane to speak, or tap it; this is the same.
            Button("Speak to the Canvas", systemImage: "mic") { KnowledgeMapVoice.shared.toggle() }
                .accessibilityIdentifier("knowledgeMap.speak")
            showMenuSection
            regionsMenuSection
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

    /// **Show**, in the canvas's menu: how the plane is drawn, and the keys.
    /// A switch that is on shows bottom right as well (`switchesOn`), so it is
    /// turned off where it shows.
    private var showMenuSection: some View {
        @Bindable var map = map
        let memory = map.memory
        return Section("Show") {
            Toggle("Minimap", isOn: $map.showsMinimap)
                .accessibilityIdentifier("knowledgeMap.show.minimap")
            Toggle("Focus on the Selection", isOn: $map.focusMode)
                .accessibilityIdentifier("knowledgeMap.show.focus")
            Toggle("Written Faces", isOn: $map.showsWrittenFaces)
                .accessibilityIdentifier("knowledgeMap.show.writtenFaces")
            Toggle("Memory", isOn: Binding(get: { memory.isShown }, set: { memory.isShown = $0 }))
                .accessibilityIdentifier("knowledgeMap.show.memory")
            Toggle("Describe the View", isOn: $map.describesView)
                .accessibilityIdentifier("knowledgeMap.show.describeView")
            Button("Keyboard Shortcuts") { map.showsShortcuts = true }
                .accessibilityIdentifier("knowledgeMap.show.shortcuts")
        }
    }

    /// The most regions the canvas menu lists.
    private static let regionMenuLimit = 40

    /// **Regions**, after the menu's own items: the canvas's regions in reading
    /// order, a region before the ones inside it, each indented one step per
    /// level; a click flies to the region (docs/knowledge-map-design.md,
    /// "Adding to the canvas", part 4).
    @ViewBuilder
    private var regionsMenuSection: some View {
        let rows = Array(map.layout.regionOutline().prefix(Self.regionMenuLimit))
        if !rows.isEmpty {
            Section("Regions") {
                ForEach(rows, id: \.id) { row in
                    Button(String(repeating: "\u{2003}", count: row.depth) + regionMenuName(row.id)) {
                        map.send(.focus(refs: [], regionID: row.id))
                    }
                }
            }
        }
    }

    /// A notebook's frame is named by its notebook; a region nobody named is
    /// "Untitled region".
    private func regionMenuName(_ id: String) -> String {
        let written = map.layout.regions[id]?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return map.notebook(ofRegion: id)?.title ?? (written.isEmpty ? "Untitled region" : written)
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

    /// The tools on the bar. The rest are keys the shortcuts list: H or Space
    /// for the hand, C to circle cards, N for a note (a double-click writes an
    /// Idea), and / or a right-click's Add Here for the add box, which Find or
    /// add… does too.
    private static let tools: [(id: String, title: String, symbol: String)] = [
        ("select", "Select and move (V)", "cursorarrow"),
        ("region", "Draw a region (R)", "rectangle.dashed"),
        ("connect", "Draw an arrow from one card to another (A)", "arrow.right"),
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
        .anchorPreference(key: KnowledgeMapChromeAnchorKey.self, value: .bounds) { KnowledgeMapChromeAnchors(tools: $0) }
    }

    /// The find field's width, the whole pill's, and the pill with the Library
    /// button beside it.
    private static let findFieldWidth: CGFloat = 180
    private static let findPillWidth: CGFloat = findFieldWidth + 38
    private static let findClusterWidth: CGFloat = findPillWidth + 6 + 40

    /// Freeform's arrangement: the tools centred over the plane and the find
    /// field, with the Library button, on the trailing edge. A pane too narrow
    /// for both puts the tools beside the field rather than centred, then
    /// narrows the field.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Color.clear.frame(width: Self.findClusterWidth, height: 0)
                Spacer(minLength: 0)
                toolsPill
                Spacer(minLength: 0)
                findCluster(fieldWidth: Self.findFieldWidth)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                toolsPill
                findCluster(fieldWidth: Self.findFieldWidth)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                toolsPill
                findCluster(fieldWidth: 96)
            }
        }
    }

    private func findCluster(fieldWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            findPill(fieldWidth: fieldWidth)
            libraryToggle
        }
    }

    /// One field that finds and adds: the cards on the canvas, the library's,
    /// the notebooks, and what is typed as a new Idea, listed under it
    /// (`KnowledgeMapFindDropdown`). ⌘F on the plane puts the cursor here.
    private func findPill(fieldWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .zoomedSystemFont(size: 12)
            TextField("Find or add…", text: $findQuery)
                .textFieldStyle(.plain)
                .frame(width: fieldWidth)
                .focused($findFocused)
                .onSubmit(takeHighlightedFindRow)
                .onKeyPress(.downArrow) { moveFindHighlight(1) }
                .onKeyPress(.upArrow) { moveFindHighlight(-1) }
                .onKeyPress(.escape) {
                    endFind()
                    return .handled
                }
                .onExitCommand(perform: endFind)
                .accessibilityIdentifier("knowledgeMap.find")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .mapFloatingChrome(cornerRadius: 12)
        .anchorPreference(key: KnowledgeMapChromeAnchorKey.self, value: .bounds) { KnowledgeMapChromeAnchors(find: $0) }
    }

    /// The Library's button, after the find field: lit while the sidebar is open.
    private var libraryToggle: some View {
        Button {
            map.showsLibrary.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .zoomedSystemFont(size: 14)
                .frame(width: 32, height: 28)
                .foregroundStyle(map.showsLibrary ? Color.accentColor : Color.primary.opacity(0.8))
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0, opacity: 0.10))
        .help("Library: what is not on this canvas yet (L)")
        .accessibilityLabel("Library")
        .accessibilityIdentifier("knowledgeMap.library.toggle")
        .padding(4)
        .mapFloatingChrome(cornerRadius: 12)
    }

    // MARK: The find field's list and the add box

    /// The rows under the find field while it has the cursor and words are in
    /// it; nil otherwise.
    private var findListing: KnowledgeMapAddSearch.Listing? {
        guard findFocused, !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return KnowledgeMapAddSearch.listing(
            query: findQuery,
            mode: .find,
            content: map.content,
            placed: Set(map.layout.placements.keys),
            selection: map.selection,
            index: map.addSearchIndex
        )
    }

    private func moveFindHighlight(_ step: Int) -> KeyPress.Result {
        guard let count = findListing?.rows.count, count > 0 else { return .handled }
        findHighlight = min(max(findHighlight + step, 0), count - 1)
        return .handled
    }

    private func takeHighlightedFindRow() {
        guard let rows = findListing?.rows, rows.indices.contains(findHighlight) else { return }
        takeFindRow(rows[findHighlight])
    }

    /// A row of the find field's list: set down beside the selection, else in
    /// the middle of the view (a new Idea at its centre), or flown to.
    private func takeFindRow(_ row: KnowledgeMapAddSearch.Row) {
        endFind()
        vm.takeKnowledgeMapAddRow(row, at: KnowledgeMapAddSpot(view: nil, world: nil))
    }

    /// Esc, or a row taken: the field empties, lets go of the cursor and the
    /// keys go back to the plane.
    private func endFind() {
        findQuery = ""
        findFocused = false
        focusPlane()
    }

    /// Gives the keys back to the plane after the add box or the find field
    /// lets go of them.
    private func focusPlane() {
        guard let webView = canvasHandle.coordinator?.webView else { return }
        webView.window?.makeFirstResponder(webView)
    }

    /// What floats over the plane under the chrome: the add box, and the find
    /// field's list hanging from the field's trailing edge.
    private func chromeOverlay(
        _ anchors: KnowledgeMapChromeAnchors,
        findListing: KnowledgeMapAddSearch.Listing?,
        findHighlight: Int
    ) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)
                KnowledgeMapAddBoxLayer(
                    plane: proxy.size,
                    toolsPill: anchors.tools.map { proxy[$0] },
                    focusPlane: focusPlane
                )
                if let listing = findListing, let field = anchors.find.map({ proxy[$0] }) {
                    KnowledgeMapFindDropdown(
                        listing: listing,
                        highlighted: min(findHighlight, max(listing.rows.count - 1, 0)),
                        onTake: takeFindRow
                    )
                    .offset(
                        x: max(KnowledgeMapAddBox.margin, field.maxX - KnowledgeMapFindDropdown.width),
                        y: field.maxY + 6
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    /// Zoom and nothing else: − and + around the percentage, which shows the
    /// whole canvas (as 0 does). Undo is ⌘Z, Extend Canvas to Other Display is
    /// in the View menu, and the shortcuts (?, or Show ▸ Keyboard Shortcuts in
    /// the canvas's menu) hang from here.
    private var zoomPill: some View {
        @Bindable var map = map
        return HStack(spacing: 2) {
            toolbarButton("minus", help: "Zoom out") { map.send(.zoom(1 / 1.4)) }
            zoomReadout
            toolbarButton("plus", help: "Zoom in") { map.send(.zoom(1.4)) }
        }
        .padding(4)
        .mapFloatingChrome(cornerRadius: 12)
        .popover(isPresented: $map.showsShortcuts, arrowEdge: .top) {
            KnowledgeMapShortcutsView()
        }
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

    /// View ▸ Extend Canvas to Other Display: the plane goes on in a second
    /// window on the other screen, or stops.
    private func toggleDisplayExtension() {
        let displays = KnowledgeMapDisplayExtension.shared
        if displays.isExtending(from: canvasHandle.coordinator) {
            displays.stop()
        } else if let canvas = canvasHandle.coordinator {
            displays.start(from: canvas, viewModel: vm, windowState: windowState)
        }
    }

    /// What an empty canvas says, in a line under everything: the plane is
    /// the drop target, so nothing here takes a click or a drag.
    private var blankCanvasHint: some View {
        Text("Drag sources, Pages, clips or files here. Double-click to write an idea, or hold S and say what to add.")
            .zoomedSystemFont(size: 13)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .textSelection(.disabled)
            .allowsHitTesting(false)
            .accessibilityIdentifier("knowledgeMap.empty.hint")
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

    /// The switches for how the plane is shown, bottom right, only while they
    /// are on: state happening now, turned off where it shows. Off, they wait
    /// in the canvas's menu under Show. The Memory layer brings its legend; the
    /// renderer draws the minimap and Focus (`showsMinimap`, `focusMode`).
    @ViewBuilder
    private var switchesOn: some View {
        @Bindable var map = map
        if map.memory.isShown {
            KnowledgeMapMemoryToggle() // Memory (WP-B2)
        }
        if map.showsWrittenFaces || map.showsMinimap || map.focusMode || map.describesView {
            HStack(spacing: 2) {
                if map.showsWrittenFaces {
                    KnowledgeMapFacesToggle() // Faces (WP-B1)
                }
                if map.showsMinimap {
                    viewSwitch(
                        isOn: $map.showsMinimap,
                        symbol: "map",
                        label: "Minimap",
                        help: "Hide the minimap",
                        identifier: "knowledgeMap.minimap"
                    )
                }
                if map.focusMode {
                    viewSwitch(
                        isOn: $map.focusMode,
                        symbol: "viewfinder.circle",
                        label: "Focus",
                        help: "Stop focusing (⇧F)",
                        identifier: "knowledgeMap.focus"
                    )
                }
                if map.describesView {
                    viewSwitch(
                        isOn: $map.describesView,
                        symbol: "text.viewfinder",
                        label: "Describe the view",
                        help: "Stop describing what is in view",
                        identifier: "knowledgeMap.describeView"
                    )
                }
            }
            .padding(4)
            .mapFloatingChrome(cornerRadius: 12)
        }
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

    /// The most the inspector grows to before it scrolls.
    private static let inspectorMaximumHeight: CGFloat = 520

    /// What is selected, as tall as it says (measured), at most
    /// `inspectorMaximumHeight`, then it scrolls.
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
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                if abs(height - inspectorHeight) > 0.5 { inspectorHeight = height }
            }
        }
        .frame(maxHeight: min(inspectorHeight, Self.inspectorMaximumHeight))
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
            // The ways in, as a card's are: Ask in Chat and Ask, the rest
            // under the ⋯ in the trailing corner.
            let cards = cardsInRegion(id)
            FlowLayout(spacing: 10) {
                Button("Ask in Chat") { vm.requestChatAboutKnowledgeMapSelection(cards) }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .disabled(cards.isEmpty)
                    .accessibilityIdentifier("knowledgeMap.region.askInChat")
                // MARK: Ask (WP-B1)
                if !cards.isEmpty {
                    KnowledgeMapAskSection(refs: cards, notebookID: map.notebook(ofRegion: id)?.id)
                }
            }
            .padding(.trailing, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                regionMenu(id: id, region: region, cards: cards)
            }
        }
    }

    /// A region's ⋯, as its right-click menu: Colour ▸, Layout ▸ (Free or a
    /// mind map laid out from its branches; a notebook's frame keeps its rows),
    /// a paper's Show ▸ (its pages, or its figures only), Fold Up, Lock or
    /// Unlock, Fit to Content, for a mind map Turn into Cards and Arrows, and
    /// Delete Region.
    private func regionMenu(id: String, region: KnowledgeMapLayout.Region, cards: [String]) -> some View {
        Menu {
            KnowledgeMapColourMenu(selected: region.color, offersDefault: false) { hex in
                if let hex { map.recolorRegion(id, to: hex) }
            }
            if map.notebook(ofRegion: id) == nil {
                Picker("Layout", selection: Binding(
                    get: { region.layout == KnowledgeMapInspectorChoices.treeLayout ? KnowledgeMapInspectorChoices.treeLayout : "free" },
                    set: { vm.setKnowledgeMapRegionLayout(id, $0 == "free" ? nil : $0) }
                )) {
                    Text("Free").tag("free")
                    Text("Mind Map").tag(KnowledgeMapInspectorChoices.treeLayout)
                }
                .pickerStyle(.menu)
                .help("Lay the region's cards out freely, or as a mind map from their branches")
                .accessibilityIdentifier("knowledgeMap.region.layout")
            }
            if let paper = vm.knowledgeMapPaperLayout(ofRegion: id) {
                Picker("Show", selection: Binding(
                    get: { paper.layout },
                    set: { chosen in Task { await vm.relayoutKnowledgeMapPaper(regionID: id, as: chosen) } }
                )) {
                    ForEach(KnowledgeMapPaperLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .help("Show this paper as its pages, its figures, or its figures with the extended and supplementary ones")
                .accessibilityIdentifier("knowledgeMap.region.paperLayout")
            }
            Divider()
            // Folded, the region draws only its name and count; its cards stay
            // placed where they are.
            Button(region.isCollapsed ? "Open" : "Fold Up") { map.setRegionCollapsed(id, !region.isCollapsed) }
                .disabled(cards.isEmpty && !region.isCollapsed)
                .accessibilityIdentifier("knowledgeMap.region.collapse")
            Button(region.locked == true ? "Unlock" : "Lock", systemImage: region.locked == true ? "lock.open" : "lock") {
                vm.setKnowledgeMapRegionLocked(id, region.locked != true)
            }
            .help(region.locked == true ? "Let its cards and the region be moved again" : "Keep its cards and the region where they are")
            .accessibilityIdentifier("knowledgeMap.region.lock")
            Button("Fit to Content") { vm.fitKnowledgeMapRegionToContent(id) }
                .disabled(cards.isEmpty)
                .help("Shrink or grow the region to just hold its cards")
                .accessibilityIdentifier("knowledgeMap.region.fit")
            if region.layout == KnowledgeMapInspectorChoices.treeLayout {
                Button("Turn into Cards and Arrows") { vm.turnKnowledgeMapTreeIntoArrows(regionID: id) }
                    .help("Keep the cards where the mind map put them, joined by arrows, and lay the region out freely")
                    .accessibilityIdentifier("knowledgeMap.region.turnIntoArrows")
            }
            Divider()
            Button("Delete Region", role: .destructive) { map.deleteRegion(id, takingCardsOff: true) }
                .help("The region goes, with its cards and the regions inside it")
                .accessibilityIdentifier("knowledgeMap.region.delete")
            Button("Delete Region, Keep Cards") { map.deleteRegion(id) }
                .help("Only the frame goes; its cards stay where they are")
                .accessibilityIdentifier("knowledgeMap.region.deleteKeepingCards")
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

    /// A region's cards: every card placed inside it, those in regions inside
    /// it too (as its right-click menu, Delete Region and the renderer count
    /// them, so a region of regions can be folded, fitted and asked about),
    /// and for a notebook's frame the notebook's cards not placed anywhere,
    /// which it draws too.
    private func cardsInRegion(_ id: String) -> [String] {
        let placed = map.refsInRegion(id)
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
            // Its own view per arrow (`.id`): a label typed into one arrow's
            // field is written to that arrow when another is clicked.
            KnowledgeMapEdgeLabelField(edgeID: id)
                .id(id)
            KnowledgeMapEdgeStyleControls(id: id, edge: edge)
            HStack {
                Spacer()
                Button("Delete Arrow", role: .destructive) { map.deleteEdge(id) }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
            }
        }
    }

    /// The colour every one of `refs` has, nil when none has one or they differ.
    private func sharedCardColor(of refs: [String]) -> String? {
        let colours = Set(refs.map { map.layout.placements[$0]?.color })
        guard colours.count == 1, let only = colours.first else { return nil }
        return only
    }

    /// The cards' ⋯: Add to Chat, how one opens, laying a paper out, the
    /// cards' colour (one of eight, or the kind's own), a paper's page or an
    /// Idea's words, fold, size, tidying, moving to another canvas, copying
    /// and taking off. The plane's own
    /// right-click menu offers the same through the same calls
    /// (`StudioViewModel+CanvasInspector.swift`).
    private func cardsMenu(refs: [String], placed: [String], pagedSource: String?) -> some View {
        Menu {
            Button("Add to Chat") { vm.addKnowledgeMapCardsToChat(refs, in: windowState) }
                .help("Give the chat beside the canvas these cards to work from, or open one with them")
                .accessibilityIdentifier("knowledgeMap.selection.addToChat")
            Divider()
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
            // A video or a recording can be laid out as its slides, with the
            // papers each cites hung under it.
            if refs.count == 1, let item = KnowledgeMap.ItemRef(refs[0]), item.kind == .source,
               vm.canLayOutKnowledgeMapTalk(item.id) {
                Button("Lay Out the Talk") {
                    Task { await vm.layOutKnowledgeMapTalkFromMenu(sourceID: item.id, in: windowState) }
                }
                .help("Its slides as a storyboard, each with the papers it cites from your library hung under it")
                .accessibilityIdentifier("knowledgeMap.selection.layOutTalk")
            }
            if !placed.isEmpty {
                KnowledgeMapColourMenu(
                    selected: sharedCardColor(of: placed),
                    defaultIsSelected: placed.allSatisfy { map.layout.placements[$0]?.color == nil }
                ) { hex in
                    vm.setKnowledgeMapCardColor(placed, to: hex)
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

    /// Answered, for the question Ideas of `refs`: its badge turns from ? to ✓
    /// on this canvas; the Idea itself is not touched.
    private func answeredToggle(_ questions: [String], isOn: Bool) -> some View {
        Toggle("Answered", isOn: Binding(
            get: { isOn },
            set: { vm.setKnowledgeMapAnswered(questions, answered: $0) }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .zoomedSystemFont(size: 12)
        .help("Mark the question answered or open again")
        .accessibilityIdentifier("knowledgeMap.selection.answered")
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
        let actions = vm.knowledgeMapCardActions(for: refs)
        return VStack(alignment: .leading, spacing: 10) {
            // The ways in wrap onto a second line when the card is too narrow
            // for them; the ⋯ keeps the trailing corner.
            FlowLayout(spacing: 10) {
                Button("Ask in Chat") { vm.requestChatAboutKnowledgeMapSelection(refs) }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                    .accessibilityIdentifier("knowledgeMap.selection.ask")
                if refs.count == 1 {
                    Button("Open") { Task { await vm.openKnowledgeMapItem(refs[0], in: windowState) } }
                        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4, opacity: 0.10))
                }
                KnowledgeMapAskSection(refs: refs) // Ask (WP-B1)
            }
            .padding(.trailing, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                cardsMenu(refs: refs, placed: placed, pagedSource: pagedSource)
            }
            if refs.count == 1, let idea = KnowledgeMap.ItemRef(refs[0]), idea.kind == .idea {
                ideaEvidence(ideaRef: refs[0], ideaID: idea.id)
            }
            // A question is open until the learner says it is answered.
            if case .markAnswered(let questions)? = actions.answered {
                answeredToggle(questions, isOn: false)
            } else if case .markOpen(let questions)? = actions.answered {
                answeredToggle(questions, isOn: true)
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
                    // What a lone card is on this canvas, under its title: the
                    // page a paper shows and why it is here.
                    if refs.count == 1 {
                        if let turn = actions.pageTurn {
                            KnowledgeMapPageTurner(turn: turn)
                        }
                        if actions.annotation != nil {
                            KnowledgeMapAnnotationField(ref: ref)
                                .id(ref)
                        }
                    }
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
                Text("Drop a source or Page on this idea, from the canvas or the Library, to link it.")
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
        .init("Add to the canvas", "/ at the pointer; right-click ▸ Add Here…"),
        .init("Find on the canvas, or add", "⌘F"),
        .init("Show or hide the Library", "L"),
        .init("Change the canvas by speaking", "Hold S and speak; or tap S, speak and pause; Esc stops"),
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
