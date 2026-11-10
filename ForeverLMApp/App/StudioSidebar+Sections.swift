import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension StudioSidebar {
    private var sidebarListIdentity: String {
        sidebar.showsRecent ? "recent" : sidebar.sidebarTab.rawValue
    }

    /// Escape leaves a multi-selection the way a click cannot: without opening
    /// anything. Anything else is left for the next responder.
    private func collapseMultiSelectionOnEscape() {
        guard let collapsed = SidebarSourceSelection.selectionAfterEscape(
            selection: windowState.sidebarSelectedSourceIDs,
            readerSourceID: sidebarReaderSourceID
        ) else { return }
        windowState.sidebarSelectedSourceIDs = collapsed
    }

    private func selectionHasVisibleRow(_ id: String) -> Bool {
        // An explainer has no row anywhere: it is read from its source's
        // Explain button or context menu (explainer-design.md); an audio
        // overview's carrier from its notebook.
        if let explainer = vm.articlesById[id], GeneratedExplainer.isSpokenScriptURL(explainer.url) {
            return false
        }
        guard windowVM.visibleSidebarSourceIDs.contains(id),
              let article = windowVM.activeTabArticles.first(where: { $0.id == id }) else { return false }
        switch sidebar.sidebarTab {
        case .books:
            // Books render as one cover row per group; chapters never have rows.
            return article.parentGroup == nil
        case .papers:
            if windowVM.activePapersWithPDF.contains(where: { $0.id == id }) { return true }
            if windowVM.activeProcessingPapers.contains(where: { $0.id == id }) { return isProcessingPapersExpanded }
            if windowVM.activePapersWithoutPDF.contains(where: { $0.id == id }) { return isPapersWithoutPDFExpanded }
            if windowVM.activePaywalledPapersWithoutPDF.contains(where: { $0.id == id }) { return isPaywalledPapersExpanded }
            return false
        case .videos:
            guard let group = article.parentGroup else { return true }
            return windowVM.inlineVideoPlaylistGroupNames.contains(group) || sidebar.expandedGroups.contains(group)
        default:
            if sidebar.sidebarTab == .meetings {
                // By date every session has a row of its own.
                if windowVM.meetingListOrder == .byDate { return true }
                guard let group = article.parentGroup else { return false }
                return sidebar.expandedGroups.contains(group)
            }
            return true
        }
    }

    /// Scroll the list to the source another panel just selected — following a
    /// chat citation, say. The view model has already switched to the owning tab,
    /// expanded the parent group, and grown pagination so the row exists; all that
    /// is left is bringing it on screen, where the row's selection wash
    /// makes it stand out.
    ///
    /// Driven by `.task(id:)` rather than `onChange` because switching tabs rebuilds
    /// the list (`.id(sidebarListIdentity)`), and a freshly created view never sees
    /// the change that created it.
    private func revealRequestedSource(using proxy: ScrollViewProxy) async {
        guard let request = vm.sidebarRevealRequest,
              let article = vm.articlesById[request.sourceID] else { return }

        // The Papers tab keeps its needs-attention and paywalled sections collapsed,
        // and the user can collapse Processing, so a linked paper in any of those
        // sections has no row until its section opens.
        if sidebar.sidebarTab == .papers {
            if windowVM.activeProcessingPapers.contains(where: { $0.id == request.sourceID }) {
                isProcessingPapersExpanded = true
            } else if windowVM.activePapersWithoutPDF.contains(where: { $0.id == request.sourceID }) {
                isPapersWithoutPDFExpanded = true
            } else if windowVM.activePaywalledPapersWithoutPDF.contains(where: { $0.id == request.sourceID }) {
                isPaywalledPapersExpanded = true
            }
        }

        // Book chapters get no row of their own, so their collection row is the
        // closest anchor the list can actually scroll to.
        let targetID = selectionHasVisibleRow(request.sourceID)
            ? request.sourceID
            : (article.parentGroup ?? request.sourceID)

        // Rows for a tab that just switched — or a section that just expanded —
        // don't exist on this runloop turn, so retry until a scroll lands.
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(120))
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            let animation: Animation? = attempt == 0 ? .easeInOut(duration: 0.2) : nil
            withAnimation(animation) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }

        vm.sidebarRevealRequest = nil
    }

    // MARK: - Extracted Subviews


    var sidebarTabBar: some View {
        sourceTabBarRows
            // Customize hangs from the row, which has no button of its own for
            // it; every tab's context menu offers it too.
            .popover(isPresented: $isSourceTabCustomizePresented, arrowEdge: .bottom) {
                SourceTypesCustomizePopover()
            }
    }

    @ViewBuilder
    private var sourceTabBarRows: some View {
        // Docked in Studio the compact tab bar rises into the hidden-titlebar
        // band: a row exactly the band's height, so the source-type icons sit
        // on the traffic lights' center line instead of in their own row below
        // a dead strip. The band is roomy enough (~52pt) for a full-size
        // icon+label stack — the row must not outgrow it, or the icons' center
        // drops below the lights' line and the bar reads as misaligned with the
        // other panels' headers. The roomy grid is taller still and keeps its
        // regular chrome (it rises anyway so the band space isn't wasted).
        if sourcesListLayout == .compact {
            compactSourceTabWords
        } else if sourcesListLayout == .wide {
            wideSourceTabBar
        } else if let band = titlebarBandHeight, sourceTabBarLayout != .roomy {
            GeometryReader { proxy in
                let presentation = compactSourceTabPresentation(availableWidth: proxy.size.width)
                let showLabels = showSourceTabLabels
                    && shouldShowSidebarTabLabels(
                        presentation.visible,
                        availableWidth: proxy.size.width
                    )
                HStack(spacing: 2) {
                    recentTabButton(showLabel: showLabels, isChip: false, inTitlebarBand: true)
                    ForEach(presentation.visible, id: \.self) { tab in
                        sidebarTabButton(
                            tab: tab,
                            showLabel: showLabels,
                            isRoomy: false,
                            inTitlebarBand: true
                        )
                    }
                    sourceTabBarTrailingControls(overflow: presentation.overflow)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .frame(height: band)
        } else {
            GeometryReader { proxy in
                if sourceTabBarLayout == .roomy {
                    let columns = Array(
                        repeating: GridItem(.flexible(minimum: 44), spacing: 4),
                        count: roomyTabColumnCount
                    )
                    HStack(alignment: .top, spacing: 4) {
                        LazyVGrid(columns: columns, alignment: .center, spacing: 4) {
                            ForEach(vm.visibleTabs, id: \.self) { tab in
                                // The roomy grid rises into the band too (it is
                                // taller than the band, so its lower rows hang
                                // below), which puts its top row under AppKit's
                                // titlebar drag exactly like the compact row.
                                sidebarTabButton(
                                    tab: tab,
                                    showLabel: showSourceTabLabels,
                                    isRoomy: true,
                                    inTitlebarBand: titlebarBandHeight != nil
                                )
                            }
                        }
                        sourceTabBarTrailingControls(overflow: [])
                    }
                } else {
                    let presentation = compactSourceTabPresentation(availableWidth: proxy.size.width)
                    let showLabels = showSourceTabLabels
                        && shouldShowSidebarTabLabels(
                            presentation.visible,
                            availableWidth: proxy.size.width
                        )
                    HStack(spacing: 0) {
                        recentTabButton(showLabel: showLabels, isChip: false)
                        ForEach(presentation.visible, id: \.self) { tab in
                            sidebarTabButton(
                                tab: tab,
                                showLabel: showLabels,
                                isRoomy: false
                            )
                        }
                        sourceTabBarTrailingControls(overflow: presentation.overflow)
                    }
                }
            }
            .frame(height: (sourceTabBarLayout == .roomy ? 78 : 42) * sourceTabIconSize.scale)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    /// The full-window Library's kinds: a row of chips from the leading edge,
    /// each type's icon beside its name, as the home's Docs tab lists its
    /// kinds (docs/design-mockups/library-view.svg). The panel's tabs share
    /// its width out evenly, which across a whole window left each type a
    /// small mark over a smaller name in a wide empty cell. A Library too
    /// narrow for every chip scrolls the row rather than hiding types behind
    /// a ⋯.
    private var wideSourceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                recentTabButton(showLabel: true, isChip: true)
                ForEach(vm.visibleTabs, id: \.self) { tab in
                    sidebarTabButton(
                        tab: tab,
                        showLabel: showSourceTabLabels,
                        isRoomy: false,
                        isChip: true
                    )
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// The kinds as words, inside a notebook's Sources column: one quiet row
    /// of the Space's scope pills, the chosen kind on a grey step, where the
    /// narrow list draws a bar of glyphs (2026-10-12, NotebookLM's column).
    /// Papers missing a PDF keep their count.
    private var compactSourceTabWords: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(vm.visibleTabs, id: \.self) { tab in
                    let badge = tab == .papers ? windowVM.papersWithoutPDFBadgeCount : 0
                    SpaceScopePill(
                        title: tab.rawValue,
                        isSelected: sidebar.sidebarTab == tab,
                        count: badge > 0 ? badge : nil
                    ) {
                        activateSidebarTab(tab)
                    }
                    .accessibilityIdentifier("notebook.sources.kind.\(tab.rawValue)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// When the tab bar hangs from the panel's top overlay (there is a
    /// titlebar band), this is how far it extends below the band: zero for the
    /// compact row, which is exactly the band's height, and the taller roomy
    /// grid's remainder otherwise. The sidebar reserves this much at the top of
    /// its in-flow content so the search row and list start below the bar.
    var sidebarTabBarOverhang: CGFloat {
        guard let band = titlebarBandHeight, sourceTabBarLayout == .roomy else { return 0 }
        let barHeight = 78 * sourceTabIconSize.scale + 12
        return max(0, barHeight - band)
    }

    /// Gives up focus, and optionally the query with it. The row itself stays
    /// on screen either way.
    func hideSourceSearch(clearingText: Bool) {
        // The field can hold text the lists have not taken up yet, so clear on
        // either; writing `searchText` empties the field with it.
        if clearingText && !(sidebar.searchText.isEmpty && sidebar.searchFieldText.isEmpty) {
            sidebar.searchText = ""
            windowVM.inWindow {
                $0.resetDisplayLimits()
                $0.pruneSelectionToVisibleSources()
            }
        }
        isSourceSearchFocused = false
    }

    private var roomyTabColumnCount: Int {
        max(1, (vm.visibleTabs.count + 1) / 2)
    }

    /// Keeps the selected type and as many leading pinned types as fit at a
    /// legible size. Remaining types move into an inline overflow menu instead
    /// of shrinking every icon into an ambiguous mark.
    private func compactSourceTabPresentation(
        availableWidth: CGFloat
    ) -> (visible: [StudioSidebarTab], overflow: [StudioSidebarTab]) {
        let all = vm.visibleTabs
        let comfortable = max(StudioDesign.Metrics.comfortableSourceTabWidth, 30)
        // Recent leads the row and takes one tab's room.
        let collapseWidth = StudioDesign.Metrics.chromeButtonWidth + 4 + comfortable
        // The ⋯ menu appears only when some type has no room, so its width is
        // reserved only once every pinned type no longer fits without it.
        let capacityWithoutMenu = max(1, Int((availableWidth - collapseWidth) / comfortable))
        guard all.count > capacityWithoutMenu else { return (all, []) }
        let menuWidth = StudioDesign.Metrics.chromeButtonWidth + 2
        let capacity = max(1, Int((availableWidth - collapseWidth - menuWidth) / comfortable))

        var visible = Array(all.prefix(capacity))
        if !visible.contains(sidebar.sidebarTab), all.contains(sidebar.sidebarTab) {
            visible[visible.count - 1] = sidebar.sidebarTab
        }
        let visibleSet = Set(visible)
        return (visible, all.filter { !visibleSet.contains($0) })
    }

    /// The trailing end of the tab bar: the ⋯ when some pinned types had no
    /// room. The product owner (2026-09-29): a ⋯ with nothing hidden behind it
    /// is not needed, so it no longer stands on the row just to hold Customize
    /// — every tab's context menu offers that.
    @ViewBuilder
    private func sourceTabBarTrailingControls(overflow: [StudioSidebarTab]) -> some View {
        if !overflow.isEmpty {
            sourceTabOverflowMenu(overflow)
        }
    }

    /// The ⋯ at the trailing end of the tab bar. It lists the pinned types the
    /// row had no room for, then Customize, which opens the popover where
    /// every source type is pinned, unpinned and reordered.
    ///
    /// Drawn as the chrome's icon buttons are: same glyph weight, grey,
    /// square and hover wash. A borderless Menu would let AppKit redraw the
    /// label as its own glyph, which is how a bright, heavier ⋯-in-a-circle
    /// ended up next to a grey sidebar icon; a button-style Menu keeps the
    /// label as written.
    private func sourceTabOverflowMenu(_ tabs: [StudioSidebarTab]) -> some View {
        Menu {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    windowVM.inWindow { $0.switchTab(to: tab) }
                    SourceSearchShortcutRouter.shared.noteSourcesInteraction()
                } label: {
                    Label(tab.rawValue, systemImage: tab.icon.isEmpty ? "square.grid.2x2" : tab.icon)
                }
            }
            Divider()
            Button {
                presentSourceTabCustomize()
            } label: {
                Label("Customize Source Types…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(
                    width: StudioDesign.Metrics.chromeButtonWidth,
                    height: StudioDesign.Metrics.chromeButtonHeight
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.hoverWash(
            cornerRadius: StudioDesign.Radius.control,
            inset: 0,
            opacity: 0.055
        ))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More source types")
        .help("More source types")
    }

    /// Customize is chosen from a menu (the ⋯ or a tab's context menu), so
    /// the popover waits one turn for that menu to finish closing.
    private func presentSourceTabCustomize() {
        Task { @MainActor in
            isSourceTabCustomizePresented = true
        }
    }

    @ViewBuilder
    private func sidebarTabButton(
        tab: StudioSidebarTab,
        showLabel: Bool,
        isRoomy: Bool,
        inTitlebarBand: Bool = false,
        isChip: Bool = false,
        fitScale: CGFloat = 1
    ) -> some View {
        let cornerRadius: CGFloat = isChip ? 7 : 6
        let isSelected = sidebar.sidebarTab == tab && !sidebar.showsRecent
        Button {
            activateSidebarTab(tab)
        } label: {
            // Monochrome, as ChatGPT's lists are (product owner, 2026-10-06; "Lists
            // are monochrome", docs/ui-design.md): every type's glyph and name
            // in grey, the selected one in the primary colour on a neutral
            // fill. The red count and dot stay: they are state that asks for
            // something.
            SidebarTabIcon(
                tab: tab,
                showLabel: showLabel,
                isRoomy: isRoomy,
                badgeCount: tab == .papers ? windowVM.papersWithoutPDFBadgeCount : 0,
                attentionLabel: tab == .xPosts ? vm.xPluginAttention : nil,
                monochrome: true,
                iconScale: sourceTabIconSize.scale * fitScale,
                isChip: isChip
            )
                .frame(
                    maxWidth: isChip ? nil : CGFloat.infinity,
                    minHeight: isRoomy ? 33 * sourceTabIconSize.scale : nil
                )
                .padding(.horizontal, isChip ? 10 : 0)
                .padding(.vertical, inTitlebarBand ? 5 : (isRoomy ? 5 : 6))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .background(
                    Color.primary.opacity(isSelected ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: cornerRadius, inset: 0))
        .accessibilityLabel(tab.rawValue)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Whenever the row hides labels (setting off, or a panel narrow enough
        // that the glyphs have scaled down), surface the tab name as a tooltip.
        // A red attention dot outranks the name: the dot says something is
        // wrong, and hovering it is how a learner finds out what.
        .help((tab == .xPosts ? vm.xPluginAttention : nil) ?? (showLabel ? "" : tab.rawValue))
        .onDrag {
            draggedSourceTab = tab
            return sidebarTabDragProvider(for: tab)
        }
        .contextMenu {
            tabContextMenu(tab: tab)
        }
        // What is hidden in this type, hanging from its tab: the list the
        // footer at the bottom of the sources opens, without scrolling a long
        // list to its end to reach it.
        .popover(
            isPresented: Binding(
                get: { hiddenItemsPopoverTab == tab },
                set: { if !$0, hiddenItemsPopoverTab == tab { hiddenItemsPopoverTab = nil } }
            ),
            arrowEdge: .bottom
        ) {
            HiddenItemsPage(model: HiddenItemsModel.build(for: tab, vm: vm, in: windowState))
        }
        .overlay {
            let isVisible = dragVisibility.isDragging
                && !dragVisibility.draggedArticleIds.isEmpty
                && (tab == .articles || tab == .papers)
            StudioDropZoneOverlay(
                isActive: false,
                isVisible: isVisible,
                title: "Move to \(tab.rawValue)",
                systemImage: tab.icon.isEmpty ? "arrow.down.doc" : tab.icon,
                cornerRadius: 7,
                inset: 0
            )
        }
        // Where a dragged source type would land. The drop takes this tab's
        // slot rather than opening a gap beside it, so the target tab itself is
        // what lights up.
        .overlay {
            if sourceTabDropTarget == tab, let dragged = draggedSourceTab, dragged != tab {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [.studioArticle, .studioSidebarTab],
            delegate: TabDropDelegate(
                tab: tab,
                vm: vm,
                draggedTab: $draggedSourceTab,
                dropTarget: $sourceTabDropTarget
            )
        )
        // In the titlebar band a SwiftUI .onDrag can't win against AppKit's
        // window-move tracking, so the tab's own mouse surface starts the
        // reorder drag there. Topmost overlay: it has to be the deepest hit
        // NSView to refuse the window drag.
        .overlay {
            if inTitlebarBand {
                StudioSourceTabDragHandle(
                    tab: tab,
                    toolTip: showLabel ? "Drag to reorder" : "\(tab.rawValue) — drag to reorder",
                    onActivate: { activateSidebarTab(tab) },
                    onDragBegan: { draggedSourceTab = tab },
                    onDragEnded: {
                        draggedSourceTab = nil
                        sourceTabDropTarget = nil
                    }
                )
                // The handle has no intrinsic size, and an AppKit view that
                // takes its ideal size here would hit-test as an empty rect.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Recent, ahead of the kinds: every source in one list, newest added
    /// first, whatever its kind (product owner, 2026-11-09: "not grouped by
    /// podcast, book, etc., but basically by date added"). Drawn as the kinds'
    /// own tabs are, a clock for a glyph.
    private func recentTabButton(showLabel: Bool, isChip: Bool, inTitlebarBand: Bool = false) -> some View {
        let cornerRadius: CGFloat = isChip ? 7 : 6
        let isSelected = sidebar.showsRecent
        return Button {
            guard !sidebar.showsRecent else { return }
            sidebar.recentDisplayLimit = 60
            windowState.sidebarSelectedSourceIDs = []
            sidebar.showsRecent = true
            SourceSearchShortcutRouter.shared.noteSourcesInteraction()
        } label: {
            Group {
                if isChip {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .zoomedSystemFont(size: 12)
                        Text("Recent")
                            .zoomedSystemFont(size: 12, weight: isSelected ? .medium : .regular)
                    }
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "clock")
                            .zoomedSystemFont(size: 14 * sourceTabIconSize.scale)
                        if showLabel {
                            Text("Recent")
                                .zoomedSystemFont(size: 9)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: isChip ? nil : CGFloat.infinity)
            .padding(.horizontal, isChip ? 10 : 0)
            .padding(.vertical, inTitlebarBand ? 5 : 6)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(
                Color.primary.opacity(isSelected ? 0.07 : 0),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: cornerRadius, inset: 0))
        .help("Recent: everything you've added, newest first")
        .accessibilityLabel("Recent")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("library.tab.recent")
    }

    private func activateSidebarTab(_ tab: StudioSidebarTab) {
        sidebar.showsRecent = false
        windowVM.inWindow { $0.switchTab(to: tab) }
        SourceSearchShortcutRouter.shared.noteSourcesInteraction()
    }

    @ViewBuilder
    private func tabContextMenu(tab: StudioSidebarTab) -> some View {
        if tab == .papers {
            if vm.isResolvingMissingPaperPDFs {
                Button {
                    vm.stopPaperPDFResolution()
                } label: {
                    Label("Stop Checking Papers", systemImage: "stop.circle")
                }
                .disabled(vm.isStoppingPaperPDFResolution)
            }
            Button {
                vm.downloadMissingPaperPDFs()
            } label: {
                Label("Try Papers Needing Attention", systemImage: "arrow.down.doc")
            }
            Button {
                vm.recheckPaywalledPaperPDFs()
            } label: {
                Label("Recheck Paywalled Papers", systemImage: "arrow.clockwise")
            }
            Button {
                Task {
                    let removed = await vm.checkForDuplicates()
                    vm.duplicateCheckResult = removed > 0
                        ? "Removed \(removed) duplicate\(removed == 1 ? "" : "s")"
                        : "No duplicates found"
                    try? await Task.sleep(for: .seconds(3))
                    if vm.duplicateCheckResult != nil {
                        vm.duplicateCheckResult = nil
                    }
                }
            } label: {
                Label("Check for Duplicates", systemImage: "doc.on.doc")
            }
            Button {
                Task { await vm.extractMissingPaperMetadata() }
            } label: {
                Label("Extract Metadata for Unknown Authors", systemImage: "sparkles")
            }
            Divider()
        }
        if tab == .articles {
            Button {
                Task { await vm.extractMissingArticleAuthors() }
            } label: {
                Label("Extract Missing Authors", systemImage: "sparkles")
            }
            Divider()
        }
        if tab == .videos {
            Button {
                Task { await vm.fetchMissingTranscripts() }
            } label: {
                Label("Fetch Missing Transcripts", systemImage: "captions.bubble")
            }
            Divider()
        }
        if tab == .meetings {
            Button {
                Task { await vm.fetchMissingZoomTranscripts() }
            } label: {
                Label("Fetch Missing Zoom Transcripts", systemImage: "captions.bubble")
            }
            Divider()
        }
        if tab == .podcasts {
            Button {
                Task { await vm.fetchMissingPodcastTranscripts() }
            } label: {
                Label("Fetch Missing Transcripts", systemImage: "captions.bubble")
            }
            Divider()
        }
        let hiddenCounts = HiddenItemsModel.footerCounts(for: tab, vm: vm)
        if hiddenCounts.groups + hiddenCounts.items > 0 {
            Button {
                // Chosen from a menu, so the popover waits one turn for the
                // menu to finish closing, as Customize does.
                Task { @MainActor in hiddenItemsPopoverTab = tab }
            } label: {
                Label("Show Hidden \(tab.rawValue)…", systemImage: "eye.slash")
            }
            Divider()
        }
        Toggle(isOn: $showSourceTabLabels) {
            Label("Show Labels", systemImage: "textformat")
        }
        Picker(selection: $sourceTabIconSize) {
            ForEach(SourceTabIconSize.allCases, id: \.self) { size in
                Text(size.title).tag(size)
            }
        } label: {
            Label("Icon Size", systemImage: "textformat.size")
        }
        Divider()
        Button {
            windowVM.inWindow { $0.hideTab(tab) }
        } label: {
            Label("Unpin \(tab.rawValue)", systemImage: "pin.slash")
        }
        .disabled(!vm.canUnpinTab(tab))
        Button {
            presentSourceTabCustomize()
        } label: {
            Label("Customize Source Types…", systemImage: "slider.horizontal.3")
        }
    }

    private func shouldShowSidebarTabLabels(
        _ tabs: [StudioSidebarTab]? = nil,
        availableWidth: CGFloat
    ) -> Bool {
        let tabs = tabs ?? vm.visibleTabs
        let tabCount = max(tabs.count, 1)
        let tabWidth = availableWidth / CGFloat(tabCount)
        let requiredWidth = tabs.map(\.minimumLabeledTabWidth).max() ?? 0
        return tabWidth >= requiredWidth
    }

    /// Binding into one of the sidebar source-list filters that also resets
    /// pagination when the selection changes.
    private func sourceFilterBinding<F: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<StudioSidebarStore, F>
    ) -> Binding<F> {
        Binding(
            get: { sidebar[keyPath: keyPath] },
            set: { newValue in
                guard sidebar[keyPath: keyPath] != newValue else { return }
                sidebar[keyPath: keyPath] = newValue
                windowVM.inWindow { $0.resetDisplayLimits() }
            }
        )
    }

    @ViewBuilder
    var sidebarSearchAndBanners: some View {
        if !(sourcesListHidesIdleSearch && sidebar.searchFieldText.isEmpty && sidebar.searchText.isEmpty) {
            sourceSearchRow
        }

        sidebarBanners
    }

    private var sourceSearchHelp: String {
        "Search \(windowVM.totalFilteredCount) \(sidebar.sidebarTab.itemNoun). "
            + "Start with title:, author:, journal:, year:, doi: or site: to search one field only."
    }

    /// The persistent source search row. ⌘F with focus in the sources column,
    /// or ⇧⌘F from anywhere (routed via `SourceSearchShortcutRouter`), focuses
    /// the field; the same shortcut clears and blurs it while it holds focus.
    ///
    /// One rounded field with the magnifier inside it, drawn as the Space's
    /// search is (product owner, 2026-10-06, "kind of like the chatgpt app"): a
    /// magnifier beside a bordered field drew the affordance twice.
    @ViewBuilder
    private var sourceSearchRow: some View {
        HStack(spacing: 8) {
            SourceSearchField(
                isFocused: $isSourceSearchFocused,
                help: sourceSearchHelp,
                onSubmit: {
                    windowVM.inWindow { $0.schedulePodcastCatalogSearchForCurrentQuery() }
                },
                onClear: { hideSourceSearch(clearingText: true) }
            )
            if sidebar.sidebarTab == .meetings {
                meetingsByDateToggle
            }
            // With the No Cards filter on (the card's Choose Sources turns it
            // on), Write Cards for the first ten, one source after another
            // (`requestWriteCards`): the Library's head, not the
            // notebook column's, whose own kinds row is its head ("one head
            // for every list").
            if sourcesListLayout == .wide, sidebar.sourceCardFilter == .withoutCards,
               let batch = StudioViewModel.sourceCardBatch(windowVM.filteredActiveItems) {
                SpaceDarkPillButton(title: "Write Cards for \(batch.count)", systemImage: nil, image: nil) {
                    windowVM.inWindow { $0.requestWriteCards(notebookID: sidebarNotebook?.notebookID, sourceIDs: batch) }
                }
                .help("Write a card for each of the first \(batch.count) sources without cards, one source at a time")
                .accessibilityIdentifier("library.cards.makeBatch")
            }
        }
        .onChange(of: sidebar.searchText) {
            // This window's field, this window's list — it fires in
            // every window whose text changed, key or not.
            windowVM.inWindow {
                $0.resetDisplayLimits()
                $0.pruneSelectionToVisibleSources()
                $0.schedulePodcastCatalogSearchForCurrentQuery()
            }
        }
        // The metadata filter that renders the list is synchronous; this is the
        // indexed pass that can see inside a source. It keys on the committed query,
        // which already waits for a pause in typing (`SourceSearchField`), so a fast
        // typist does not launch one database query per keystroke; `task(id:)`
        // cancels the in-flight search when the query or the tab moves on.
        .task(id: "\(sidebar.sidebarTab)\u{1}\(sidebar.searchText)") {
            await vm.refreshSidebarContentSearchMatches(in: windowState)
        }
        // Align the field with the first tab rather than sitting at the
        // default 16pt.
        .padding(.leading, 8)
        .padding(.trailing, 12)
        // A little air under the tab bar, so the field's edge does not run
        // into the tab labels above it.
        .padding(.top, 5)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    /// The Meetings tab's "By date": every session on its own row, newest
    /// first, rather than one row per series. A toggle beside the search, lit
    /// while on, as the notebook filter beside it is. Icon alone in the narrow
    /// Sources panel, where the label would crowd the field.
    private var meetingsByDateToggle: some View {
        let isOn = windowVM.meetingListOrder == .byDate
        return Button {
            withAnimation {
                windowVM.meetingListOrder = isOn ? .bySeries : .byDate
            }
        } label: {
            Group {
                if sourcesListLayout == .wide {
                    Label(MeetingListOrder.byDate.title, systemImage: "calendar")
                } else {
                    Image(systemName: "calendar")
                }
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isOn ? Color.accentColor.opacity(0.14) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule()))
        .fixedSize()
        .help(isOn ? "Group meetings by series" : "List every meeting by date, newest first")
        .accessibilityLabel(MeetingListOrder.byDate.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("library.meetings.byDate")
    }

    /// Filter chips and the transient status rows that sit under the search row.
    ///
    /// Every row here carries its own top inset rather than leaning on whatever
    /// happens to precede it. These are caption-sized grey text and they can end
    /// up directly beneath the source-type tab bar, where a flush row reads as a
    /// second label hanging off the icons rather than as its own status line —
    /// the inset is sized to clear the tab labels on its own, not to top up the
    /// search row's 4pt bottom pad. It lives on each row instead of the group so
    /// nothing reserves dead space when no banner is showing.
    @ViewBuilder
    private var sidebarBanners: some View {
        // A bulk re-queue into a paid queue waits here for the learner on
        // every tab: it spends on the whole library, not on one tab's sources.
        ForEach(vm.pendingBackgroundAIBulkJobs) { job in
            BackgroundAIBulkJobRow(job: job)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .transition(.opacity)
        }

        if sidebar.sidebarTab == .meetings,
           hasLoadedMeetingPluginHealth,
           let notice = meetingPluginNotice {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(meetingPluginActionTitle(for: notice)) {
                    performMeetingPluginAction(notice)
                }
                .buttonStyle(.hoverWash)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .transition(.opacity)
        }

        // A recording only Zoom can convert: the learner's call, made here,
        // never a background pass opening Zoom (see
        // StudioViewModel+ZoomLocalTranscripts).
        if sidebar.sidebarTab == .meetings {
            ForEach(vm.zoomLocalRecordingsAwaitingConversion) { recording in
                ZoomRecordingAwaitingConversionRow(recording: recording)
                    .padding(.horizontal)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }

        if sidebar.sidebarTab == .videos && vm.youtubePluginNeedsReconnect {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("YouTube disconnected — videos aren't syncing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reconnect") {
                    PluginsPlace.requestOpen(.youtube)
                }
                .buttonStyle(.hoverWash)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .transition(.opacity)
        }

        // The No Cards filter has no pill; its chip is how it is seen and
        // cleared, so the filter never narrows a list out of sight.
        let showsNoCardsChip = sidebar.sourceCardFilter != .all
        if windowVM.hasChippedSourceListFilters || showsNoCardsChip {
            ChipFlowLayout(spacing: 6) {
                if showsNoCardsChip {
                    ActiveFilterChip(title: SourceCardScope.withoutCards.title) {
                        withAnimation { sourceFilterBinding(\.sourceCardFilter).wrappedValue = .all }
                    }
                }
                if sidebar.sourceReadFilter != .all {
                    ActiveFilterChip(title: sidebar.sourceReadFilter.title) {
                        withAnimation { sourceFilterBinding(\.sourceReadFilter).wrappedValue = .all }
                    }
                }
                if sidebar.sourceReviewFilter != .all {
                    ActiveFilterChip(title: sidebar.sourceReviewFilter.title) {
                        withAnimation { sourceFilterBinding(\.sourceReviewFilter).wrappedValue = .all }
                    }
                }
                if sidebar.sourceContentFilter != .all {
                    ActiveFilterChip(title: sidebar.sourceContentFilter.title) {
                        withAnimation { sourceFilterBinding(\.sourceContentFilter).wrappedValue = .all }
                    }
                }
                if windowVM.activeSourceListFilterCount > 1 {
                    Button {
                        withAnimation {
                            windowVM.inWindow {
                                $0.clearSourceListFilters()
                                $0.resetDisplayLimits()
                            }
                        }
                    } label: {
                        Text("Clear")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.hoverWash)
                    .help("Clear all filters")
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .transition(.opacity)
        }

        if vm.loadingStep != nil,
           vm.loadingStepScope == nil || vm.loadingStepScope == sidebar.sidebarTab {
            StudioActivityStatusRow(
                message: "Syncing…",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .transition(.opacity)
        }

        if let result = vm.duplicateCheckResult {
            HStack(spacing: 6) {
                Image(systemName: result.hasPrefix("No") ? "checkmark.circle" : "trash.circle")
                    .foregroundStyle(result.hasPrefix("No") ? .green : .orange)
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .transition(.opacity)
        }

    }

    @ViewBuilder
    var sidebarList: some View {
        ScrollViewReader { proxy in
            sidebarSelectableList
                .task(id: vm.sidebarRevealRequest?.token) {
                    await revealRequestedSource(using: proxy)
                }
        }
        .onDrop(of: supportedBookImportDropTypes, isTargeted: $isBooksDropTargeted) { providers in
            handleBookFileDrop(providers)
        }
        .onDrop(of: [.fileURL, .pdf], isTargeted: $isPapersDropTargeted) { providers in
            handlePaperFileDrop(providers)
        }
        .overlay {
            if isBooksDropTargeted && !isAddBookButtonDropTargeted && sidebar.sidebarTab == .books {
                booksDropOverlay
            } else if isPapersDropTargeted && sidebar.sidebarTab == .papers {
                papersDropOverlay
            }
        }
        .background(
            OverscrollRefresh {
                guard !vm.isLoadingQueue else { return }
                Task { await vm.refreshTab(sidebar.sidebarTab) }
            } onSilentRefresh: {
                vm.syncTabPluginsOnEvent(sidebar.sidebarTab)
            }
        )
        .id(sidebarListIdentity)
    }

    @ViewBuilder
    var libraryLoadFailureView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(vm.libraryLoadErrorMessage ?? "ForeverLM couldn't open your library.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Try Again") {
                Task { await vm.loadQueue() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isLoadingQueue)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Sources list: a `ScrollView` + `LazyVStack`, not SwiftUI's `List`.
    /// `List` re-diffed every row whenever its content changed and measured
    /// each row's height as it scrolled in, so a long tab stalled for a second
    /// or more at a time (product owner, 2026-11-08: "very glitchy and slow. It
    /// needs to be super fast"). The lazy list builds only the rows on screen
    /// and keeps its own selection: a click opens, ⌘-click toggles, ⇧-click
    /// selects a run, ↑ ↓ move, Delete removes, Escape collapses a
    /// multi-selection. A series or playlist folds open as rows of the same
    /// list (`lazyGroupHeader`), so a long one stays lazy too.
    private var sidebarSelectableList: some View {
        sidebarLazyList
    }

    private var sidebarLazyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sidebar.showsRecent {
                        recentListContent
                    } else {
                        sidebarListContent
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .focusable()
            .focused($isLazySourceListFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                moveLazySelection(
                    down: press.key == .downArrow,
                    extending: press.modifiers.contains(.shift),
                    proxy: proxy
                )
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                let selection = windowState.sidebarSelectedSourceIDs
                guard !selection.isEmpty else { return .ignored }
                requestSourceRemoval(selection)
                return .handled
            }
            .onExitCommand(perform: collapseMultiSelectionOnEscape)
        }
    }

    /// The list's selectable rows in the order they are drawn, for ⇧-click
    /// runs and the arrow keys: what `sidebarArticlesSections` lays out, read
    /// only when one of those happens, never in a body. A book's row stands
    /// for the chapter it selects (`bookRowSelectionID`); a folded series or
    /// playlist has none.
    private var lazyListRowIDs: [String] {
        if sidebar.showsRecent {
            return recentListArticles.map(\.id)
        }
        switch sidebar.sidebarTab {
        case .papers:
            var ids: [String] = []
            if isProcessingPapersExpanded { ids += windowVM.activeProcessingPapers.map(\.id) }
            if isPapersWithoutPDFExpanded { ids += windowVM.activePapersWithoutPDF.map(\.id) }
            ids += windowVM.activePapersWithPDF.map(\.id)
            if isPaywalledPapersExpanded { ids += windowVM.activePaywalledPapersWithoutPDF.map(\.id) }
            return ids
        case .podcasts:
            return windowVM.activeProcessingPodcasts.map(\.id) + windowVM.activePodcastsNotProcessing.map(\.id)
        case .books:
            let grouped = Dictionary(grouping: windowVM.activeTabArticles, by: \.parentGroup)
            return (grouped[nil] ?? []).map(\.id) + windowVM.filteredBookGroupNames.map { groupName in
                bookRowSelectionID(groupName: groupName, items: grouped[groupName] ?? [])
            }
        case .meetings:
            if windowVM.listsMeetingsByDate { return windowVM.activeTabArticles.map(\.id) }
            let grouped = Dictionary(grouping: windowVM.activeTabArticles, by: \.parentGroup)
            return windowVM.filteredMeetingGroupNames
                .filter { sidebar.expandedGroups.contains($0) }
                .flatMap { (grouped[$0] ?? []).sorted { $0.dateAdded > $1.dateAdded }.map(\.id) }
        case .videos:
            let processing = windowVM.activeProcessingVideos
            let processingIDs = Set(processing.map(\.id))
            let listed = windowVM.activeTabArticles.filter { !processingIDs.contains($0.id) }
            let grouped = Dictionary(grouping: listed, by: \.parentGroup)
            let inPlaylists = windowVM.filteredVideoPlaylistGroupNames
                .filter { sidebar.expandedGroups.contains($0) }
                .flatMap { (grouped[$0] ?? []).map(\.id) }
            let flat = windowVM.inWindow { vm in listed.filter { vm.isFlatVideoRow($0) } }.map(\.id)
            return processing.map(\.id) + inPlaylists + flat
        default:
            return windowVM.activeTabArticles.map(\.id)
        }
    }

    /// The chapter a book's row selects and opens: the one the book would
    /// resume. A search or metadata filter can match a book's own record while
    /// none of its chapters match, so the unfiltered chapters come before the
    /// group's name, which opens nothing.
    private func bookRowSelectionID(groupName: String, items: [StudioArticle]) -> String {
        vm.resumeBookChapter(for: groupName)?.id
            ?? items.first?.id
            ?? vm.bookSourceArticles(for: groupName).first?.id
            ?? groupName
    }

    /// A series' or playlist's row in the list: a chevron, its label, a click
    /// anywhere on it folding it open or shut. Its rows follow it as rows of
    /// the same lazy list rather than inside a `DisclosureGroup`, whose content
    /// is built whole the moment it opens.
    private func lazyGroupHeader(groupName: String, items: [StudioArticle], itemCount: Int) -> some View {
        let isExpanded = sidebarGroupExpansionBinding(groupName: groupName, items: items)
        return HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .zoomedSystemFont(size: 10, weight: .semibold)
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
            expandableGroupLabel(groupName: groupName, itemCount: itemCount)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: isExpanded.wrappedValue ? "Collapse" : "Expand") {
            isExpanded.wrappedValue.toggle()
        }
    }

    /// A click on a row. A plain one opens the row, which selects it
    /// alone; ⌘ and ⇧ change the selection and open nothing.
    private func handleLazyRowClick(_ sourceID: String) {
        guard !SidebarRowControlPress.claims(sourceID) else { return }
        isLazySourceListFocused = true
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let command = flags.contains(.command)
        guard command || flags.contains(.shift) else {
            lazyListAnchorSourceID = sourceID
            lazyListCursorSourceID = sourceID
            // A plain click on a row of a multi-selection collapses it to the
            // row, as a Mac list does on mouse-up, so the open goes ahead.
            windowState.sidebarSelectedSourceIDs = [sourceID]
            openSidebarArticleFromRowClick(sourceID)
            return
        }
        windowState.sidebarSelectedSourceIDs = SidebarSourceSelection.selectionAfterModifiedClick(
            on: sourceID,
            selection: windowState.sidebarSelectedSourceIDs,
            anchor: lazyListAnchorSourceID,
            displayOrder: lazyListRowIDs,
            command: command
        )
        lazyListCursorSourceID = sourceID
        if command { lazyListAnchorSourceID = sourceID }
    }

    /// ↑ or ↓ in the list: the next row is selected and opened, as in a Mac
    /// list; with ⇧ the run from the anchor grows instead.
    private func moveLazySelection(down: Bool, extending: Bool, proxy: ScrollViewProxy) {
        let order = lazyListRowIDs
        let selection = windowState.sidebarSelectedSourceIDs
        let current = lazyListCursorSourceID.flatMap { selection.contains($0) ? $0 : nil }
            ?? (down ? order.last(where: selection.contains) : order.first(where: selection.contains))
        guard let next = SidebarSourceSelection.rowAfterArrow(from: current, in: order, down: down) else { return }
        lazyListCursorSourceID = next
        if extending {
            let anchor = lazyListAnchorSourceID ?? current ?? next
            lazyListAnchorSourceID = anchor
            windowState.sidebarSelectedSourceIDs = SidebarSourceSelection.range(from: anchor, to: next, in: order)
        } else {
            lazyListAnchorSourceID = next
            windowState.sidebarSelectedSourceIDs = [next]
            openSidebarArticleFromRowClick(next)
        }
        proxy.scrollTo(next)
    }

    /// The menu a row's right-click shows: the selection's when the row is part
    /// of it, the row's own otherwise, as a Mac list decides.
    @ViewBuilder
    private func lazyRowContextMenu(for sourceID: String) -> some View {
        let selection = windowState.sidebarSelectedSourceIDs
        sidebarArticleContextMenu(for: selection.contains(sourceID) ? selection : [sourceID])
    }

    /// The menu for a right-click on `selectedIDs`, built only for the row under
    /// the pointer (`LazySourceRowChrome`): SwiftUI builds a `.contextMenu`'s
    /// items in the row's body, and every row building this one would multiply
    /// the work by every row that scrolls in.
    @ViewBuilder
    private func sidebarArticleContextMenu(for selectedIDs: Set<String>) -> some View {
        let orderedIDs = windowVM.inWindow { $0.sourceIDsInCurrentDisplayOrder(selectedIDs) }
        // A Books-tab row stands for its book. It selects the chapter the book
        // would resume, which is what arrives here, so the menu is the book's —
        // or, for several covers, the actions that fit all of them.
        let bookTargets = sidebar.sidebarTab == .books && !sidebar.showsRecent
            ? vm.sidebarRemovalTargets(for: selectedIDs, expandingBooks: true)
            : StudioViewModel.SidebarRemovalTargets()
        if bookTargets.bookGroups.count > 1 {
            let count = bookTargets.bookGroups.count
            let bookGroups = bookTargets.bookGroups
            NotebookMenuSection(
                notebook: sidebarNotebook,
                target: .books(bookGroups),
                newNotebookTitle: NotebookMembershipMenu.newNotebookTitle(bookCount: count)
            ) {
                createNotebook(with: bookGroups.flatMap { vm.sourceIDsForGroupInOrder($0) })
            }
            Button {
                Task { await vm.hideSidebarRemovalTargets(bookTargets) }
            } label: {
                Label("Hide \(count) Books", systemImage: "eye.slash")
            }
            Button(role: .destructive) {
                requestSourceRemoval(selectedIDs)
            } label: {
                Label("Remove \(count) Books…", systemImage: "trash")
            }
        } else if let group = bookTargets.bookGroups.first {
            groupContextMenuItems(groupName: group, itemCount: vm.bookSourceArticles(for: group).count)
        } else if let articleID = orderedIDs.first,
           let article = vm.articlesById[articleID] {
            articleContextMenu(article, selectedArticleIDs: selectedIDs)
        }
    }

    /// Recent's rows as drawn: every kind newest added first, searched by the
    /// Library's search, up to `recentDisplayLimit`.
    private var recentListArticles: [StudioArticle] {
        Array(vm.recentlyAddedSources(matching: sidebar.searchText).prefix(sidebar.recentDisplayLimit))
    }

    /// The Recent list: the sources under Today, Yesterday, This Week and
    /// Earlier, as the iPhone's To Read heads them (`ToReadList.sections`),
    /// each row the kinds' own row with its menu, drag and selection.
    @ViewBuilder
    private var recentListContent: some View {
        let all = vm.recentlyAddedSources(matching: sidebar.searchText)
        let shown = Array(all.prefix(sidebar.recentDisplayLimit))
        if shown.isEmpty {
            Text(sidebar.searchText.isEmpty ? "Nothing added yet." : "No sources match.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ForEach(ToReadList.sections(shown, dateAdded: \.dateAdded, now: Date()), id: \.section) { group in
                Text(group.section.title)
                    .zoomedSystemFont(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .padding(.top, group.section == .today ? 4 : 14)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.items) { article in
                    articleRow(article)
                }
            }
            if all.count > shown.count {
                Button {
                    sidebar.recentDisplayLimit += 60
                } label: {
                    HStack {
                        Spacer()
                        Text("Show More (\(all.count - shown.count) remaining)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
            }
        }
    }

    @ViewBuilder
    private var sidebarListContent: some View {
            if sidebar.sidebarTab == .xPosts, !vm.isXOAuthSignedIn {
                Section {
                    Button {
                        Task { await vm.signInWithX() }
                    } label: {
                        HStack(spacing: 6) {
                            if vm.isConnectingX {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 12, height: 12)
                            } else {
                                XLogoShape()
                                    .fill(.foreground, style: FillStyle(eoFill: true))
                                    .frame(width: 12, height: 12)
                            }
                            Text(vm.isConnectingX ? "Connecting to X…" : "Connect to X")
                        }
                    }
                    // The sign-in window is hosted by a system agent that can be
                    // slow to launch; the row says so instead of looking dead.
                    .disabled(vm.isConnectingX)
                }
            } else if sidebar.sidebarTab == .xPosts, let attention = vm.xPluginAttention {
                // The red dot on the tab says something went wrong; this row is
                // where it says what. A failed sync used to announce itself with
                // a toast that vanished before it was read; now it waits here,
                // with the fix beside it, until a sync goes through.
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(attention)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        // A failure a new sign-in might clear offers one beside
                        // the retry; "try again later" alone left the learner
                        // no way out of a token X had stopped honouring.
                        if !vm.xPluginNeedsReauth, vm.xPluginOffersReconnect {
                            Button("Reconnect") {
                                Task { await vm.signInWithX() }
                            }
                            .controlSize(.small)
                            .disabled(vm.isSyncingXBookmarks || vm.isConnectingX)
                        }
                        Button(vm.xPluginNeedsReauth ? "Reconnect" : "Try Again") {
                            Task {
                                if vm.xPluginNeedsReauth {
                                    await vm.signInWithX()
                                } else {
                                    await vm.syncXBookmarks()
                                }
                            }
                        }
                        .controlSize(.small)
                        // A retry inside X's rate-limit window is another
                        // refused request; the message names when the
                        // window reopens and the sync runs itself then.
                        .disabled(vm.isSyncingXBookmarks || vm.isConnectingX || (!vm.xPluginNeedsReauth && vm.isXSyncPaused))
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("X bookmarks need attention")
                }
            }
            if sidebar.sidebarTab == .books {
                Section {
                    // The button stays while a book imports: another book
                    // picked or dropped now waits its turn behind it.
                    Button {
                        Task {
                            let urls = await FilePanel.open { panel in
                                panel.allowedContentTypes = supportedBookImportContentTypes
                                panel.allowsMultipleSelection = true
                                panel.message = "Select books (PDF, EPUB, or DRM-free Kindle) to import"
                            }
                            await importBooks(urls)
                        }
                    } label: {
                        Label("Add Book…", systemImage: "book.closed.fill")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green.opacity(0.8))
                    .controlSize(.small)
                    .overlay {
                        StudioDropZoneOverlay(
                            isActive: isAddBookButtonDropTargeted,
                            title: "Import book",
                            systemImage: "book.closed.fill",
                            cornerRadius: 6,
                            inset: 0
                        )
                    }
                    .onDrop(of: supportedBookImportDropTypes, isTargeted: $isAddBookButtonDropTargeted) { providers in
                        handleBookFileDrop(providers)
                    }
                    if !vm.bookImportStatus.isEmpty || vm.bookImportsPending > 0 {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(bookImportProgressLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
            }

            if sidebar.sidebarTab == .papers {
                Section {
                    Button {
                        Task {
                            let urls = await FilePanel.open { panel in
                                panel.allowedContentTypes = [.pdf]
                                panel.allowsMultipleSelection = true
                                panel.message = "Select one or more paper PDFs to import"
                            }
                            guard !urls.isEmpty else { return }
                            var failures: [String] = []
                            for url in urls {
                                do {
                                    try await vm.importPDF(
                                        from: url.path,
                                        selectInReader: false
                                    )
                                } catch {
                                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                                }
                            }
                            if !failures.isEmpty {
                                vm.errorMessage = failures.joined(separator: "\n")
                            }
                        }
                    } label: {
                        Label("Upload PDFs…", systemImage: "doc.fill")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple.opacity(0.8))
                    .controlSize(.small)
                    .overlay {
                        StudioDropZoneOverlay(
                            isActive: isUploadPapersButtonDropTargeted,
                            title: "Import as new paper",
                            systemImage: "doc.badge.plus",
                            cornerRadius: 6,
                            inset: 0
                        )
                    }
                    .onDrop(of: [.fileURL, .pdf], isTargeted: $isUploadPapersButtonDropTargeted) { providers in
                        handlePaperFileDrop(providers)
                    }
                }
            }

            // A linked Drive folder is what makes a broken connection matter
            // here; a learner who only imports local recordings is never nagged.
            if sidebar.sidebarTab == .meetings,
               vm.meetingMetadata.values.contains(where: { $0.driveFolderURL?.isEmpty == false }) {
                Section {
                    GoogleDriveHealthBanner(
                        accountID: nil,
                        isWorking: isGoogleDriveWorking,
                        reconnect: startGoogleDriveMeetingImport
                    )
                }
            }

            if sidebar.sidebarTab == .meetings, !showsMeetingsEmptyHelp {
                Section {
                    // Side by side where the column has room, stacked where it
                    // does not: two labels that cannot shrink ran past a narrow
                    // Library column and were cut at both its edges.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            addMeetingFolderButton
                            addRecordingButton
                            liveMeetingButton
                        }
                        VStack(spacing: 8) {
                            addMeetingFolderButton
                            addRecordingButton
                            liveMeetingButton
                        }
                    }
                }
            }

            if sidebar.sidebarTab == .videos {
                Section {
                    Button {
                        alertText = ""
                        activeAlert = .addYouTubeVideo
                    } label: {
                        Label("Add Video…", systemImage: "play.rectangle.fill")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red.opacity(0.8))
                    .controlSize(.small)
                }
            }

            if !vm.paperVersionConflicts.isEmpty && sidebar.sidebarTab == .papers {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                            let count = vm.paperVersionConflicts.count
                            Text("\(count) paper\(count == 1 ? "" : "s") have multiple versions saved.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Fix Sources") {
                            Task { await vm.fixPaperVersionConflicts() }
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }

            let tabDiscoveryWarnings = vm.discoveryWarnings(for: sidebar.sidebarTab)
            if !tabDiscoveryWarnings.isEmpty {
                let accessWarnings = tabDiscoveryWarnings.filter { isFullDiskAccessWarning($0) }
                let otherWarnings = tabDiscoveryWarnings.filter { !isFullDiskAccessWarning($0) }

                if !accessWarnings.isEmpty {
                    Section {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Full Disk Access needed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button("Open Settings") {
                                openFullDiskAccessSettings()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(vm.isLoadingQueue)
                        }
                    }
                }

                let showOtherWarnings = (isBrowserReadingListTab || sidebar.sidebarTab == .podcasts) && !otherWarnings.isEmpty

                if showOtherWarnings {
                Section {
                    if showOtherWarnings {
                    ForEach(otherWarnings, id: \.self) { warning in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Button("Refresh") {
                                    Task { await vm.loadQueue() }
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    }
                }
                }
            }

            if showsMeetingsEmptyHelp {
                meetingsEmptyHelp
            }

            sidebarArticlesSections
    }

    /// A genuinely empty Meetings tab needs a way forward. Search and filter
    /// misses keep their ordinary empty-list behavior: sending someone into
    /// plugin setup when their meetings are merely hidden would be wrong —
    /// and a provider filter that matches nothing is a filter miss, not an
    /// empty library, so it is checked here alongside search.
    private var showsMeetingsEmptyHelp: Bool {
        sidebar.sidebarTab == .meetings
            && sidebar.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !windowVM.hasActiveSourceListFilters
            && windowVM.tabTotalCount == 0
            && windowVM.filteredMeetingGroupNames.isEmpty
            && !vm.isLoadingQueue
    }

    /// The empty Meetings tab names every provider that can fill it, not just
    /// the one with a button. Google Drive is the only provider ForeverLM can
    /// connect from here — Read AI and other plugins push meetings in over
    /// MCP — but an empty state that mentioned Drive alone would read as "this
    /// tab is Google Drive", which is exactly the impression the split tabs
    /// left and this tab exists to correct.
    ///
    /// It wears the Space's empty state (`SpaceEmptyLine`'s sizes, the dark
    /// pill under the line), not `ContentUnavailableView`, whose large grey
    /// description and blue button read as a different app in this pane.
    private var meetingsEmptyHelp: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image("MeetingsIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("No meetings yet")
                        .zoomedSystemFont(size: 13, weight: .semibold)
                        .foregroundStyle(.primary)
                    Text(
                        isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                            ? "Reconnect to read the files inside this meeting folder."
                            : isGoogleDriveSignedIn
                            ? "Choose the folder that holds your meeting recordings and transcripts."
                            : "Connect Google Drive, or import a folder of recordings from this Mac."
                    )
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            }

            HStack(spacing: 8) {
                SpaceDarkPillButton(
                    title: isGoogleDriveWorking
                        ? "Waiting for Google… Cancel"
                        : (isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                            ? "Reconnect Google Drive"
                            : (isGoogleDriveSignedIn ? "Choose Meeting Folder" : "Connect Google Drive")),
                    systemImage: nil,
                    image: nil,
                    action: startGoogleDriveMeetingImport
                )
                if isGoogleDriveWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            // Every provider that fills this tab, quiet under the one action.
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    ForEach(MeetingProvider.allCases) { provider in
                        MeetingProviderMark(provider: provider, size: 14)
                    }
                }
                Text("Google Drive, Read AI, Zoom and local folders all land here.")
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    /// The Meetings tab's primary action, filling its row where it has room.
    private var addMeetingFolderButton: some View {
        Button(action: startGoogleDriveMeetingImport) {
            Label(
                isGoogleDriveWorking
                    ? "Waiting for Google… Cancel"
                    : (isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                        ? "Reconnect Google Drive…"
                        : "Add Meeting Folder…"),
                systemImage: isGoogleDriveWorking ? "xmark.circle" : "folder.badge.plus"
            )
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue.opacity(0.8))
        .controlSize(.small)
    }

    /// Followed the Zoom tab down here when the tabs merged: pasting a
    /// recording link is how one provider's sessions arrive, not a place of its
    /// own.
    private var addRecordingButton: some View {
        Button {
            alertText = ""
            zoomPasscodeText = ""
            activeAlert = .addZoomRecording
        } label: {
            Label("Add Recording…", systemImage: "video.badge.plus")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// A meeting happening now, transcribed on this Mac as it is said
    /// (`LiveMeetingPane`); Chat › Live Meeting opens the same pane.
    private var liveMeetingButton: some View {
        Button {
            vm.openLiveMeeting()
        } label: {
            Label("Live Meeting", systemImage: "waveform")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func startGoogleDriveMeetingImport() {
        // While Google's page is open the same button stops waiting for it.
        guard !isGoogleDriveWorking else {
            Task { await GoogleDriveService.shared.cancelPendingConnection() }
            return
        }
        isGoogleDriveWorking = true
        Task {
            defer { isGoogleDriveWorking = false }
            do {
                try await vm.connectAndImportGoogleDriveMeetings(
                    reconnectOnly: isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                )
            } catch GoogleDriveServiceError.noFolderSelected {
                // Closing Google's picker is a normal cancellation.
            } catch is CancellationError {
                // The sidebar or app closed while the browser flow was open.
            } catch {
                vm.errorMessage = error.localizedDescription
                vm.showToast(error.localizedDescription)
            }
        }
    }

    private func handleBookFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard sidebar.sidebarTab == .books else { return false }
        isAddBookButtonDropTargeted = false
        isBooksDropTargeted = false
        let candidates = providers.compactMap { provider -> (NSItemProvider, BookDropRepresentation)? in
            guard let representation = bookDropRepresentation(for: provider) else { return nil }
            return (provider, representation)
        }
        guard !candidates.isEmpty else {
            presentBookDropError("Drop a PDF, EPUB, or DRM-free Kindle book.")
            return true
        }
        if vm.bookImportsPending == 0 {
            vm.bookImportStatus = candidates.count == 1 ? "Opening dropped book…" : "Opening dropped books…"
        }
        for (provider, representation) in candidates {
            switch representation {
            case .fileURL:
                loadDroppedBookURL(from: provider)
            case .content(let typeIdentifier):
                loadDroppedBookFileRepresentation(from: provider, typeIdentifier: typeIdentifier)
            }
        }
        return true
    }

    /// The line under Add Book: what the running import is doing, and how
    /// many more books wait behind it.
    private var bookImportProgressLine: String {
        let status = vm.bookImportStatus.isEmpty ? "Waiting to import…" : vm.bookImportStatus
        let waiting = vm.bookImportsPending - 1
        guard waiting > 0 else { return status }
        return "\(status)\n\(waiting) more \(waiting == 1 ? "book" : "books") waiting"
    }

    /// Imports each picked book in turn, saying at the end which ones failed.
    private func importBooks(_ urls: [URL]) async {
        let runs = urls.map { ($0, vm.enqueueBookImport(from: $0.path)) }
        var failures: [String] = []
        for (url, run) in runs {
            do {
                try await run.value
            } catch {
                failures.append(urls.count == 1
                    ? error.localizedDescription
                    : "\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard !failures.isEmpty else { return }
        vm.errorMessage = failures.joined(separator: "\n")
        vm.showBookImportError = true
    }

    private enum BookDropRepresentation {
        case fileURL
        case content(String)
    }

    private func bookDropRepresentation(for provider: NSItemProvider) -> BookDropRepresentation? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return .fileURL
        }
        guard let typeIdentifier = supportedBookImportContentTypes
            .map(\.identifier)
            .first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { return nil }
        return .content(typeIdentifier)
    }

    private func loadDroppedBookURL(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
            if let url = droppedFileURL(from: item) {
                importDroppedBook(at: url)
                return
            }

            if let typeIdentifier = supportedBookImportContentTypes
                .map(\.identifier)
                .first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
                loadDroppedBookFileRepresentation(
                    from: provider,
                    typeIdentifier: typeIdentifier,
                    priorErrorDescription: error?.localizedDescription
                )
                return
            }

            let detail = error.map { ": \($0.localizedDescription)" } ?? ""
            Task { @MainActor in
                presentBookDropError("ForeverLM couldn’t read the dropped book from Finder\(detail).")
            }
        }
    }

    private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
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
        guard let url, url.isFileURL else { return nil }
        return url
    }

    /// Some Finder drops vend only their concrete content type (for example
    /// `org.idpf.epub-container`) and no `public.file-url`. The provider-owned
    /// URL disappears when this callback returns, so stage it before starting
    /// the asynchronous importer.
    private func loadDroppedBookFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        priorErrorDescription: String? = nil
    ) {
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, error in
            guard let temporaryURL else {
                let cause = error?.localizedDescription ?? priorErrorDescription
                let detail = cause.map { ": \($0)" } ?? ""
                Task { @MainActor in
                    presentBookDropError("ForeverLM couldn’t open the dropped book\(detail).")
                }
                return
            }

            do {
                let sourceExtension = temporaryURL.pathExtension.lowercased()
                let preferredExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? ""
                let fileExtension = sourceExtension.isEmpty ? preferredExtension : sourceExtension
                // The book's folder and its stored copy are named after the
                // file, so the staged copy keeps the dropped file's own name,
                // in a folder of its own. A UUID for a name gave the book a
                // folder called "ForeverLM-Dropped-Book-…".
                let stagingDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ForeverLM-Dropped-Book-\(UUID().uuidString)", isDirectory: true)
                let droppedName = temporaryURL.deletingPathExtension().lastPathComponent
                var stagedURL = stagingDirectory
                    .appendingPathComponent(droppedName.isEmpty ? "Book" : droppedName)
                if !fileExtension.isEmpty {
                    stagedURL.appendPathExtension(fileExtension)
                }
                try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: temporaryURL, to: stagedURL)
                importDroppedBook(at: stagedURL, removeAfterImport: true, stagingDirectory: stagingDirectory)
            } catch {
                Task { @MainActor in
                    presentBookDropError("ForeverLM couldn’t copy the dropped book: \(error.localizedDescription)")
                }
            }
        }
    }

    private func importDroppedBook(at url: URL, removeAfterImport: Bool = false, stagingDirectory: URL? = nil) {
        Task { @MainActor in
            defer {
                if removeAfterImport {
                    let staged = stagingDirectory ?? url
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: staged)
                    }
                }
            }
            do {
                try await vm.importBook(from: url.path)
            } catch {
                presentBookDropError("Couldn’t import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func presentBookDropError(_ message: String) {
        // A book still importing keeps its progress line.
        if vm.bookImportsPending == 0 { vm.bookImportStatus = "" }
        vm.errorMessage = message
        vm.showBookImportError = true
    }

    /// Drops onto empty space in the Papers tab or onto the "Upload PDFs…"
    /// button import each dropped PDF as a new paper source — a "dropbox" for
    /// freshly downloaded papers. Drops onto an existing paper row are handled
    /// by ArticleRow's own onDrop (attach to that paywalled paper) and never
    /// reach here.
    private func handlePaperFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard sidebar.sidebarTab == .papers else { return false }
        return PaperFileDrop.load(
            providers,
            deliver: { url, displayName, staged in
                PaperIngestionDiagnostics.recordDropAccepted(filename: displayName)
                importDroppedPaperPDF(at: url, displayName: displayName, stagedFile: staged)
            },
            fail: { filename, message in
                presentPaperDropError(filename: filename, message: message)
            }
        )
    }

    private func importDroppedPaperPDF(
        at url: URL,
        displayName: String,
        stagedFile: PaperDropStager.StagedFile? = nil
    ) {
        Task { @MainActor in
            defer {
                if let stagedFile {
                    PaperDropStager.cleanup(stagedFile)
                }
            }
            do {
                let sourceID = try await vm.importPDF(
                    from: url.path,
                    selectInReader: false
                )
                PaperIngestionDiagnostics.recordDropImported(
                    filename: displayName,
                    sourceID: sourceID
                )
                // Name the paper, not the file: a drop that arrived without a
                // filename would otherwise announce "Imported Dropped Paper.pdf".
                let importedTitle = vm.articles.first(where: { $0.id == sourceID })?.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                vm.showToast("Imported \(importedTitle?.isEmpty == false ? importedTitle! : displayName)")
            } catch {
                presentPaperDropError(filename: displayName, error: error)
            }
        }
    }

    private func presentPaperDropError(filename: String?, error: Error) {
        presentPaperDropError(filename: filename, message: error.localizedDescription)
    }

    private func presentPaperDropError(filename: String?, message: String) {
        let displayName = PaperDropStager.safePDFFilename(filename)
        PaperIngestionDiagnostics.recordDropFailure(filename: displayName, message: message)
        Task { @MainActor in
            vm.showToast("Couldn’t import \(displayName): \(message)")
        }
    }

    @ViewBuilder
    private var sidebarArticlesSections: some View {
        let activeItems = windowVM.activeTabArticles
        let processingVideos = sidebar.sidebarTab == .videos ? windowVM.activeProcessingVideos : []
        let processingVideoIDs = Set(processingVideos.map(\.id))
        let listedItems = sidebar.sidebarTab == .videos
            ? activeItems.filter { !processingVideoIDs.contains($0.id) }
            : activeItems
        let hasGroupedContent = (sidebar.sidebarTab == .meetings && !windowVM.filteredMeetingGroupNames.isEmpty)
            || (sidebar.sidebarTab == .books && !windowVM.filteredBookGroupNames.isEmpty)
            || (sidebar.sidebarTab == .videos && !windowVM.filteredVideoPlaylistGroupNames.isEmpty)
        if windowVM.listsMeetingsByDate {
            // Every session in order, with the series it belongs to on the row.
            Section {
                ForEach(activeItems) { article in
                    meetingSessionRow(article, groupName: article.parentGroup, showsSeries: true)
                }
            }
            if windowVM.hasMoreItems {
                Button {
                    windowVM.inWindow { $0.showMore() }
                } label: {
                    HStack {
                        Spacer()
                        Text("Show More (\(windowVM.remainingItemCount) remaining)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
            }
        } else if !activeItems.isEmpty || hasGroupedContent {
            let grouped = Dictionary(grouping: listedItems, by: { $0.parentGroup })

            if sidebar.sidebarTab == .books || sidebar.sidebarTab == .meetings || sidebar.sidebarTab == .videos {
                let ungrouped: [StudioArticle] = {
                    if sidebar.sidebarTab == .meetings {
                        return []
                    }
                    if sidebar.sidebarTab == .videos {
                        // `activeTabArticles` already paged these flat rows; the
                        // same predicate keeps the layout and the page in step.
                        return windowVM.inWindow { vm in listedItems.filter { vm.isFlatVideoRow($0) } }
                    }
                    return grouped[nil] ?? []
                }()
                let groupNames: [String] = {
                    if sidebar.sidebarTab == .meetings {
                        return windowVM.filteredMeetingGroupNames
                    }
                    if sidebar.sidebarTab == .videos {
                        let processingGroupNames = Set(processingVideos.compactMap(\.parentGroup))
                        return windowVM.filteredVideoPlaylistGroupNames.filter { groupName in
                            !(grouped[groupName, default: []].isEmpty && processingGroupNames.contains(groupName))
                        }
                    }
                    if sidebar.sidebarTab == .books {
                        return windowVM.filteredBookGroupNames
                    }
                    return Set(grouped.compactMap { k, _ in k }).sorted()
                }()

                if sidebar.sidebarTab == .videos && !processingVideos.isEmpty {
                    Section {
                        ForEach(processingVideos) { article in
                            articleRow(article)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing (\(windowVM.activeProcessingVideosTotalCount))")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    }
                }

                if sidebar.sidebarTab != .videos {
                    ForEach(ungrouped) { article in
                        articleRow(article)
                    }
                }

                ForEach(groupNames, id: \.self) { groupName in
                    let items = grouped[groupName] ?? []
                    let itemCount = items.count
                    if sidebar.sidebarTab == .books {
                        // A book cover stands in for all of its chapters: it
                        // selects and opens the one the book would resume, and
                        // shows selected while any of them is.
                        let selectionID = bookRowSelectionID(groupName: groupName, items: items)
                        courseOrBookGroupLabel(groupName: groupName, itemCount: itemCount)
                        .contentShape(Rectangle())
                        .onDrop(of: [.studioArticle, .studioGroup] + supportedBookImportDropTypes, isTargeted: nil) { providers in
                            handleGroupedCollectionDrop(providers, groupName: groupName)
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            openBookGroupFromDoubleClick(selectionID)
                        })
                        // A group of its own for the help, as on a source row,
                        // so the notebook mark keeps its own.
                        .accessibilityElement(children: .contain)
                        .help(sidebarArticleInteractionHelp)
                        .onDrag {
                            let sourceIDs = vm.sourceIDsForGroupInOrder(groupName)
                            StudioDragVisibility.shared.begin(
                                articleIDs: sourceIDs,
                                groupName: groupName
                            )
                            return groupDragProvider(
                                for: StudioGroupTransfer(groupName: groupName, sourceIDs: sourceIDs)
                            )
                        }
                        // The label carries the book's own menu.
                        .modifier(LazySourceRowChrome(
                            highlightIDs: Set(items.map(\.id)).union([selectionID]),
                            rowID: selectionID,
                            onClick: { handleLazyRowClick(selectionID) },
                            menu: nil as (() -> EmptyView)?
                        ))
                    } else {
                        lazyGroupHeader(groupName: groupName, items: items, itemCount: itemCount)
                        if sidebar.expandedGroups.contains(groupName) {
                            Group {
                                if sidebar.sidebarTab == .meetings {
                                    ForEach(items.sorted { $0.dateAdded > $1.dateAdded }) { article in
                                        meetingSessionRow(article, groupName: groupName)
                                    }
                                } else {
                                    ForEach(items) { article in
                                        groupedCollectionArticleRow(article, groupName: groupName)
                                    }
                                }
                                if itemCount == 0 {
                                    Text("Drag sources here")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 8)
                                }
                            }
                            .padding(.leading, 16)
                        }
                    }
                }

                if sidebar.sidebarTab == .videos {
                    ForEach(ungrouped) { article in
                        articleRow(article)
                    }
                }

            } else if sidebar.sidebarTab == .podcasts {
                let processing = windowVM.activeProcessingPodcasts
                let available = windowVM.activePodcastsNotProcessing

                if !processing.isEmpty {
                    Section {
                        ForEach(processing) { article in
                            articleRow(article)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing (\(windowVM.activeProcessingPodcastsTotalCount))")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                    }
                }

                if !available.isEmpty {
                    Section {
                        ForEach(available) { article in
                            articleRow(article)
                        }
                    }
                }

            } else if sidebar.sidebarTab == .papers {
                let withPDF = windowVM.activePapersWithPDF
                let processing = windowVM.activeProcessingPapers
                let withoutPDF = windowVM.activePapersWithoutPDF
                let paywalled = windowVM.activePaywalledPapersWithoutPDF

                if windowVM.unavailableRecordedPDFCount > 0 {
                    Label(
                        "\(windowVM.unavailableRecordedPDFCount) PDFs waiting for iCloud",
                        systemImage: "icloud.and.arrow.down"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("These papers' PDFs are on record but their files aren't available on this Mac yet — usually iCloud Drive hasn't downloaded them. They stay out of Papers Needing Attention so they aren't re-downloaded from publishers.")
                }

                if !processing.isEmpty {
                    Section {
                        if isProcessingPapersExpanded {
                            ForEach(processing) { article in
                                articleRow(article)
                            }
                        }
                    } header: {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isProcessingPapersExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isProcessingPapersExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .frame(width: 10)
                                ProgressView()
                                    .controlSize(.small)
                                Text(processingPapersHeaderTitle)
                                    .font(.caption.weight(.semibold))
                                if !paperBatchProgressCaption.isEmpty {
                                    Text(paperBatchProgressCaption)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverWash)
                        .help(isProcessingPapersExpanded ? "Collapse processing papers" : "Expand processing papers")
                        .textCase(nil)
                    }
                }

                if !withoutPDF.isEmpty {
                    Section {
                        if isPapersWithoutPDFExpanded {
                            ForEach(withoutPDF) { article in
                                articleRow(article)
                            }

                            if windowVM.hasMorePapersWithoutPDF {
                                showMorePapersButton(
                                    remainingCount: windowVM.remainingPapersWithoutPDFCount,
                                    action: { windowVM.inWindow { $0.showMorePapersWithoutPDF() } }
                                )
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isPapersWithoutPDFExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isPapersWithoutPDFExpanded ? "chevron.down" : "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 10)
                                    Text(papersNeedingAttentionHeaderTitle)
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverWash)

                            paperBatchButton(
                                kind: .missingPDFs,
                                idleTitle: nil,
                                idleIcon: "arrow.down.doc",
                                idleHelp: "Retry all papers needing attention",
                                start: vm.downloadMissingPaperPDFs
                            )

                            Spacer(minLength: 0)
                        }
                        .textCase(nil)
                    }
                }

                if !withPDF.isEmpty {
                    Section {
                        ForEach(withPDF) { article in
                            articleRow(article)
                        }

                        if windowVM.hasMorePapersWithPDF {
                            showMorePapersButton(
                                remainingCount: windowVM.remainingPapersWithPDFCount,
                                action: { windowVM.inWindow { $0.showMorePapersWithPDF() } }
                            )
                        }
                    }
                }

                if !paywalled.isEmpty {
                    Section {
                        if isPaywalledPapersExpanded {
                            ForEach(paywalled) { article in
                                articleRow(article)
                            }

                            if windowVM.hasMorePaywalledPapersWithoutPDF {
                                showMorePapersButton(
                                    remainingCount: windowVM.remainingPaywalledPapersWithoutPDFCount,
                                    action: { windowVM.inWindow { $0.showMorePaywalledPapersWithoutPDF() } }
                                )
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isPaywalledPapersExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isPaywalledPapersExpanded ? "chevron.down" : "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .frame(width: 10)
                                    Text(paywalledPapersHeaderTitle)
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.hoverWash)

                            paperBatchButton(
                                kind: .paywallRecheck,
                                idleTitle: "Recheck all",
                                idleIcon: "arrow.clockwise",
                                idleHelp: "Recheck marked paywalled papers for freely available PDFs",
                                start: vm.recheckPaywalledPaperPDFs
                            )

                            Spacer(minLength: 0)
                        }
                        .textCase(nil)
                    }
                }

            } else {
                Section {
                    ForEach(activeItems) { article in
                        articleRow(article)
                    }
                }
            }

            // Grey, with the button's hover wash: a list's own control, not a
            // link (Lists are monochrome, docs/ui-design.md).
            if windowVM.hasMoreItems {
                Button {
                    windowVM.inWindow { $0.showMore() }
                } label: {
                    HStack {
                        Spacer()
                        Text("Show More (\(windowVM.remainingItemCount) remaining)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
            }
        }

        HiddenItemsFooter(tab: sidebar.sidebarTab, searchText: sidebar.searchText)
    }

    private func showMorePapersButton(
        remainingCount: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text("Show More (\(remainingCount) remaining)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
    }

    /// Trailing control for a paper-batch section header. The same button starts
    /// the batch and cancels it: while its own batch is running there is nothing
    /// else the learner can do from here, and a separate Cancel would sit idle in
    /// the header the rest of the time.
    @ViewBuilder
    private func paperBatchButton(
        kind: StudioViewModel.PaperPDFResolutionKind,
        idleTitle: String?,
        idleIcon: String,
        idleHelp: String,
        start: @escaping () -> Void
    ) -> some View {
        let isRunning = vm.paperPDFResolutionKind == kind
        let isStopping = isRunning && vm.isStoppingPaperPDFResolution
        Button {
            if isRunning {
                vm.stopPaperPDFResolution()
            } else {
                start()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isRunning ? "stop.circle" : idleIcon)
                if isRunning {
                    Text(isStopping ? "Stopping…" : "Cancel")
                } else if let idleTitle {
                    Text(idleTitle)
                }
            }
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, isRunning || idleTitle != nil ? 5 : 0)
            .frame(minWidth: 18, minHeight: 18)
        }
        .buttonStyle(.hoverWash)
        .controlSize(.small)
        .foregroundStyle(isRunning ? Color.accentColor : .secondary)
        // Only the batch's own button stays live: the other one would start a
        // second pass that `downloadMissingPaperPDFs` refuses anyway.
        .disabled(isStopping || (vm.isResolvingMissingPaperPDFs && !isRunning))
        .help(isRunning ? "Stop after the paper being checked right now" : idleHelp)
    }

    /// Progress caption for the Processing header. Cancel keeps the per-paper
    /// phase captions running until the current paper lands, so the stopping
    /// state has to win here or the click would look like it did nothing.
    private var paperBatchProgressCaption: String {
        if vm.isStoppingPaperPDFResolution {
            return "Stopping after the current paper…"
        }
        return vm.paperDownloadStep
    }

    private var papersNeedingAttentionHeaderTitle: String {
        let count = windowVM.activePapersWithoutPDFTotalCount
        return "Papers that need attention (\(count))"
    }

    private var processingPapersHeaderTitle: String {
        let count = windowVM.activeProcessingPapersTotalCount
        return "Processing (\(count))"
    }

    private var paywalledPapersHeaderTitle: String {
        let count = windowVM.activePaywalledPapersWithoutPDFTotalCount
        return "Marked paywalled (\(count))"
    }

    /// Whether to show a prominent access prompt instead of the source list.
    var showFullAccessPrompt: Bool {
        if sidebar.sidebarTab == .podcasts,
           vm.needsPodcastAccess,
           !vm.podcastAccessPromptDismissed {
            return windowVM.tabTotalCount == 0
        }
        if isBrowserReadingListTab,
           vm.needsBrowserAccess,
           !vm.browserAccessPromptDismissed {
            return windowVM.tabTotalCount == 0
        }
        return false
    }

    private var isBrowserReadingListTab: Bool {
        sidebar.sidebarTab == .articles || sidebar.sidebarTab == .papers
    }

    /// Prominent prompt when protected browser or podcast data needs access.
    @ViewBuilder
    var fullAccessPrompt: some View {
        VStack {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "lock.shield")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(fullAccessPromptHeading)
                            .font(.headline)
                        Text(fullAccessPromptTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Text(fullAccessPromptMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Label(fullAccessSettingsStep, systemImage: "1.circle.fill")
                    if isDevelopmentBuild {
                        Text(fullAccessBundlePath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 22)
                    }
                    Label(fullAccessRelaunchStep, systemImage: "2.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let detail = fullAccessPromptErrorDetail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        openFullDiskAccessSettings()
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        relaunchApp()
                    } label: {
                        Label("Relaunch \(ForeverLMRuntimeIdentity.displayName)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)

                    if isDevelopmentBuild {
                        Button {
                            revealAppInFinder()
                        } label: {
                            Label("Reveal App", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .help("Show the running \(ForeverLMRuntimeIdentity.displayName) app in Finder so it can be added to the Full Disk Access list.")
                    }

                    Spacer()

                    Button("Dismiss") {
                        clearFullAccessWarning()
                    }
                    .buttonStyle(.hoverWash)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fullAccessPromptTitle: String {
        if sidebar.sidebarTab == .podcasts {
            return "Needed for Apple Podcasts"
        }
        if isBrowserReadingListTab {
            return "Needed for reading lists"
        }
        return "Permission required"
    }

    private var fullAccessPromptHeading: String {
        "Full Disk Access"
    }

    private var fullAccessPromptMessage: String {
        if isDevelopmentBuild {
            let source = sidebar.sidebarTab == .podcasts ? "Apple Podcasts" : "browser reading-list data"
            return "DevLM can't read \(source). macOS treats it as a separate signed app from the production ForeverLM copy in Applications, so production access does not cover Dev."
        }

        if sidebar.sidebarTab == .podcasts {
            return "ForeverLM needs Full Disk Access to read your Apple Podcasts database and transcript cache directly."
        }

        let accessWarnings = vm.discoveryWarnings(for: sidebar.sidebarTab).filter { $0.contains("access is blocked") }
        let needsSafari = accessWarnings.contains { $0.contains("Safari") }
        let needsChrome = accessWarnings.contains { $0.contains("Chrome") }
        let needsBrave = accessWarnings.contains { $0.contains("Brave") }
        let features: [String] = {
            var items: [String] = []
            if needsSafari { items.append("Safari") }
            if needsChrome { items.append("Chrome") }
            if needsBrave { items.append("Brave") }
            return items
        }()

        if features.isEmpty {
            return "ForeverLM needs Full Disk Access to read browser reading-list data directly."
        }
        return "ForeverLM needs Full Disk Access to read your \(features.joined(separator: " and ")) reading-list data directly."
    }

    /// macOS never lists an app under Full Disk Access on its own — a blocked
    /// read fails silently instead of prompting — so there is no switch to turn
    /// on until the app is added with the "+" button.
    private var fullAccessSettingsStep: String {
        if isDevelopmentBuild {
            return "Click \"Reveal App\", then add that exact DevLM app in Full Disk Access with the \"+\" button. Leave the production ForeverLM entry enabled too."
        }
        return "Click \"Open Settings\" — it jumps straight to the Full Disk Access pane. ForeverLM is not listed there until you add it with the \"+\" button."
    }

    private var fullAccessRelaunchStep: String {
        if isDevelopmentBuild {
            return "If Settings offers \"Quit & Reopen\", choose \"Later\". Return here and click \"Relaunch \(ForeverLMRuntimeIdentity.displayName)\" so this exact signed build restarts with access."
        }
        return "Click \"Relaunch ForeverLM\" — macOS applies Full Disk Access only when the app starts, so a rescan alone can't pick it up."
    }

    /// The First Run app reads the production steps: it stands in for a new
    /// learner, who has no Dev copy to tell apart from the installed one.
    private var isDevelopmentBuild: Bool {
        ForeverLMRuntimeIdentity.isDevelopment && !ForeverLMRuntimeIdentity.isFirstRun
    }

    /// The exact bundle to add in Full Disk Access. Development builds can live
    /// in Xcode's DerivedData or a repository-local custom build directory.
    private var fullAccessBundlePath: String {
        Bundle.main.bundleURL.path
    }

    private func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// The underlying read error (e.g. the Bookmarks.plist permission failure),
    /// shown as a small footnote instead of inside the main explanation.
    private var fullAccessPromptErrorDetail: String? {
        for warning in vm.discoveryWarnings(for: sidebar.sidebarTab) where warning.contains("access is blocked") {
            if let range = warning.range(of: "Last read error: ") {
                return String(warning[range.upperBound...])
            }
        }
        return nil
    }

    private func isFullDiskAccessWarning(_ warning: String) -> Bool {
        warning.contains("access is blocked")
            || warning.contains("Full Disk Access")
            || warning.contains("relaunch ForeverLM")
    }

    private func clearFullAccessWarning() {
        if sidebar.sidebarTab == .podcasts {
            vm.dismissPodcastAccessPrompt()
        } else if isBrowserReadingListTab {
            vm.dismissBrowserAccessPrompt()
        }
    }

    private func relaunchApp() {
        FullDiskAccess.relaunch()
    }

    private func openFullDiskAccessSettings() {
        FullDiskAccess.openSettings()
    }

    /// A book file dropped on a Books-tab row imports it. Sources and groups
    /// dropped on a collection used to join it as a course; courses have their
    /// own pane now (courses-design.md), where a drop still does that.
    private func handleGroupedCollectionDrop(_ providers: [NSItemProvider], groupName: String) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if sidebar.sidebarTab == .books {
                    handled = handleBookFileDrop([provider]) || handled
                }
                continue
            }
        }
        return handled
    }

    private func sidebarGroupExpansionBinding(
        groupName: String,
        items: [StudioArticle]
    ) -> Binding<Bool> {
        Binding(
            get: { sidebar.expandedGroups.contains(groupName) },
            set: { isExpanded in
                if isExpanded {
                    sidebar.expandedGroups.insert(groupName)
                } else {
                    sidebar.expandedGroups.remove(groupName)
                    // Clear selection if the selected item is inside this collapsing group.
                    let itemIDs = Set(items.map(\.id))
                    if !windowState.sidebarSelectedSourceIDs.isDisjoint(with: itemIDs) {
                        windowState.sidebarSelectedSourceIDs.subtract(itemIDs)
                    }
                }
            }
        )
    }

    private func expandableGroupLabel(groupName: String, itemCount: Int) -> some View {
        // The hover lives in its own view, so the count can show under the
        // pointer without re-running the list's body.
        SourceGroupRowHover { isHovered in
            courseOrBookGroupLabel(groupName: groupName, itemCount: itemCount, countRevealed: isHovered)
        }
            .onDrop(of: [.studioArticle, .studioGroup] + supportedBookImportDropTypes, isTargeted: nil) { providers in
                handleGroupedCollectionDrop(providers, groupName: groupName)
            }
            .onDrag {
                let sourceIDs = vm.sourceIDsForGroupInOrder(groupName)
                StudioDragVisibility.shared.begin(
                    articleIDs: sourceIDs,
                    groupName: groupName
                )
                return groupDragProvider(
                    for: StudioGroupTransfer(groupName: groupName, sourceIDs: sourceIDs)
                )
            }
    }

    /// A collection row's label. The count of
    /// a series or playlist shows only while `countRevealed` (the pointer is
    /// over the row): a column of numbers down the list was noise
    /// (product owner, 2026-10-06, "kind of like the chatgpt app"; ChatGPT's rows
    /// carry no counts).
    @ViewBuilder
    private func courseOrBookGroupLabel(
        groupName: String,
        itemCount: Int,
        countRevealed: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            // A playlist or a book with no cover of its own draws its kind's
            // glyph in grey: colour is for covers and for state that needs
            // the learner (Lists are monochrome, docs/ui-design.md).
            if sidebar.sidebarTab == .videos {
                Image(systemName: "play.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
            } else if sidebar.sidebarTab == .meetings {
                MeetingFolderIcon(imageURL: vm.meetingFolderImageURL(groupName))
            } else if let coverPath = vm.bookCoverPaths[groupName] {
                BookCoverThumbnail(pdfPath: coverPath)
            } else {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(groupDisplayName(groupName))
                    .zoomedSystemFont(size: 13, weight: .medium)
                    .lineLimit(2)
                if sidebar.sidebarTab == .videos {
                    if let refreshedAt = vm.videoPlaylistMetadata[groupName]?.lastRefreshedAt {
                        Text("Refreshed \(refreshedAt.formatted(date: .abbreviated, time: .omitted))")
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                } else if sidebar.sidebarTab == .meetings {
                    // How often the series recurs. The provider marks moved up
                    // beside the name, so this line exists only when there is
                    // recurrence to report.
                    if let subtitle = vm.meetingDisplaySubtitle(groupName) {
                        Text(subtitle)
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if metadataVisibility.isVisible(.subtitle, for: .book),
                       let subtitle = vm.bookDisplaySubtitle(groupName) {
                        Text(subtitle)
                            .zoomedSystemFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    let bookParts: [String] = {
                        var p: [String] = []
                        if metadataVisibility.isVisible(.author, for: .book),
                           let a = vm.bookDisplayAuthor(groupName) { p.append(a) }
                        if metadataVisibility.isVisible(.edition, for: .book),
                           let e = vm.bookDisplayEdition(groupName) { p.append(e) }
                        if metadataVisibility.isVisible(.format, for: .book),
                           let f = vm.bookFormat(groupName) { p.append(f) }
                        if metadataVisibility.isVisible(.kind, for: .book),
                           let k = vm.bookDisplayKind(groupName) { p.append(k) }
                        return p
                    }()
                    if !bookParts.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(bookParts.enumerated()), id: \.offset) { index, part in
                                if index > 0 {
                                    Text("·").foregroundStyle(.tertiary)
                                }
                                Text(part)
                            }
                        }
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .id("\(String(describing: vm.videoPlaylistMetadata[groupName]))-\(String(describing: vm.meetingMetadata[groupName]))")
            Spacer()
            if vm.refreshingVideoPlaylistIDs.contains(groupName) {
                ProgressView()
                    .controlSize(.small)
            }
            if vm.transcribingMeetingGroupNames.contains(groupName) {
                ProgressView()
                    .controlSize(.small)
            }
            // A book added on this Mac reads while its details and chapters
            // are still being found.
            if sidebar.sidebarTab == .books, let status = vm.finishingBookStatus[groupName] {
                ProgressView()
                    .controlSize(.small)
                    .help(status)
            }
            if sidebar.sidebarTab == .meetings {
                let providers = MeetingProvider.marks(for: vm.meetingGroupProviders(groupName))
                HStack(spacing: 3) {
                    groupItemCount(itemCount, alignment: .trailing, isRevealed: countRevealed)
                    if !providers.isEmpty {
                        MeetingProviderBadges(providers: providers)
                    }
                }
            } else if sidebar.sidebarTab == .books {
                BookAudiobookBadge(
                    chapterIDs: vm.bookChapterArticlesInOrder(for: groupName)
                        .filter(ArticleSpeechContent.canAttemptRead)
                        .map(\.id)
                )
            } else {
                groupItemCount(itemCount, alignment: .trailing, isRevealed: countRevealed)
            }
        }
        .contextMenu {
            groupContextMenuItems(groupName: groupName, itemCount: itemCount)
        }
    }

    /// The whole-group actions of a playlist, meeting-group or book row.
    /// Shared by the row's own right-click menu and, on the Books tab, by the
    /// selection's menu: a book row selects its resume chapter, so without
    /// this a right-click on several covers could surface chapter actions
    /// instead of Hide Book and Remove Book.
    @ViewBuilder
    private func groupContextMenuItems(groupName: String, itemCount: Int) -> some View {
        NotebookMenuSection(
            notebook: sidebarNotebook,
            target: sidebar.sidebarTab == .books ? .books([groupName]) : .collection(groupName)
        )
        // A book row opens the chapter it resumes at; this sends that chapter
        // to the other window instead.
        if sidebar.sidebarTab == .books,
           let chapter = vm.resumeBookChapter(for: groupName) ?? vm.bookSourceArticles(for: groupName).first {
            OtherWindowSourceMenuItem(chapter)
            Divider()
        }
        if assistantIntegrationsEnabled {
            // Add all items in this group to MCP context
            Button {
                vm.addSourcesToContext(vm.sourceIDsForGroupInOrder(groupName))
            } label: {
                Label("Add All to MCP Context", systemImage: "sparkles")
            }
        }

        // Show all review sessions linked to any item in this group
        let groupItemIds = vm.sourceIdsForGroup(groupName)
        let groupSessionCount = vm.reviewSessionLinks.filter { !Set($0.sourceIDs).isDisjoint(with: groupItemIds) }.count
        Button {
            vm.showReviewSessionsForGroup(groupName)
        } label: {
            Label(groupSessionCount > 0 ? "Show Review Sessions (\(groupSessionCount))" : "Show Review Sessions",
                  systemImage: "brain.head.profile")
        }
        Button {
            Task { await vm.scheduleGroup(groupName) }
        } label: {
            Label("Add Group to Schedule", systemImage: "calendar")
        }
        Divider()

        if sidebar.sidebarTab == .videos {
            Button {
                Task { await vm.refreshVideoPlaylist(groupName: groupName) }
            } label: {
                Label("Refresh Playlist", systemImage: "arrow.clockwise")
            }
            .disabled(vm.refreshingVideoPlaylistIDs.contains(groupName))
            Button {
                alertText = vm.videoPlaylistDisplayName(groupName)
                activeAlert = .renameVideoPlaylist(groupName)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                Task { await vm.setVideoPlaylistHidden(groupName, hidden: true) }
            } label: {
                Label("Hide Playlist", systemImage: "eye.slash")
            }
            Divider()
            Button(role: .destructive) {
                activeAlert = .removeVideoPlaylist(groupName)
            } label: {
                Label("Remove Playlist", systemImage: "trash")
            }
        } else if sidebar.sidebarTab == .meetings {
            // Recordings whose transcript has never been made. Until now the
            // only way to start one was to open each recording in the reader
            // and wait there, which is a poor fit for a folder of forty.
            let isTranscribingGroup = vm.transcribingMeetingGroupNames.contains(groupName)
            let untranscribed = vm.meetingSessionIDsNeedingTranscript(inGroup: groupName)
            if isTranscribingGroup || !untranscribed.isEmpty {
                Button {
                    Task { await vm.transcribeMeetingSessions(untranscribed, groupName: groupName) }
                } label: {
                    Label(
                        isTranscribingGroup
                            ? "Getting Transcripts…"
                            : "Get Transcripts (\(untranscribed.count))",
                        systemImage: "text.bubble"
                    )
                }
                .disabled(isTranscribingGroup)
                .help("Transcribe every recording in this folder that has no transcript yet")
                Divider()
            }
            Button {
                alertText = vm.meetingDisplayName(groupName)
                activeAlert = .renameMeeting(groupName)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            let mergeTargets = vm.visibleMeetingGroupNames.filter { $0 != groupName }
            if !mergeTargets.isEmpty {
                Menu {
                    ForEach(mergeTargets, id: \.self) { target in
                        Button(vm.meetingDisplayName(target)) {
                            activeAlert = .mergeMeeting(source: groupName, target: target)
                        }
                    }
                } label: {
                    Label("Merge Into", systemImage: "arrow.triangle.merge")
                }
            }
            // One sitting, one session: a standup a free Zoom account cut in
            // two arrives as two sessions of one day. New pairs fold as they
            // land; this folds the ones already there.
            let sameDaySurplus = vm.sameDayMeetingSessionSurplus(for: groupName)
            if sameDaySurplus > 0 {
                Button {
                    activeAlert = .mergeSameDayMeetingSessions(groupName)
                } label: {
                    Label("Merge Same-Day Sessions (\(sameDaySurplus))", systemImage: "arrow.triangle.merge")
                }
                .help("Fold the sessions that share a day into one session per day")
            }
            Button {
                meetingScheduleTarget = MeetingScheduleTarget(groupName: groupName)
            } label: {
                Label(vm.meetingMetadata[groupName]?.schedule == nil ? "Schedule…" : "Edit Schedule…", systemImage: "clock")
            }
            Button {
                alertText = vm.meetingFolderImageURL(groupName) ?? ""
                activeAlert = .editMeetingFolderImage(groupName)
            } label: {
                Label("Set Folder Image…", systemImage: "photo")
            }
            if vm.meetingFolderImageURL(groupName) != nil {
                Button {
                    vm.setMeetingFolderImageURL(nil, for: groupName)
                } label: {
                    Label("Use Default Image", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                Task { await vm.setMeetingHidden(groupName, hidden: true) }
            } label: {
                Label("Hide Meeting Group", systemImage: "eye.slash")
            }
            Divider()
            Button(role: .destructive) {
                activeAlert = .removeMeeting(groupName)
            } label: {
                Label("Delete Meeting Group", systemImage: "trash")
            }
        } else {
            // Cached-only: this menu is built with the group row, and the
            // uncached lookup enumerates an iCloud-backed book directory.
            if let epubURL = vm.cachedOriginalEPUBURL(forBookGroup: groupName) {
                Button {
                    if assistantIntegrationsEnabled {
                        vm.addSourcesToContext(vm.sourceIDsForGroupInOrder(groupName))
                    }
                    openEPUBInAppleBooks(epubURL)
                } label: {
                    Label("Open EPUB in Apple Books", systemImage: "book.pages")
                }
            }
            // One click narrates the whole book. Generating chapter by
            // chapter was the only route, and a forty-chapter book made
            // that forty clicks and forty price dialogs.
            let audiobookProgress = audioQueue.progress(forGroup: groupName)
            Button {
                Task { await startAudiobookGeneration(forBookGroup: groupName) }
            } label: {
                Label(
                    audiobookProgress.remaining > 0
                        ? "Generating Audiobook… (\(audiobookProgress.remaining) left)"
                        : "Generate Audiobook",
                    systemImage: "headphones"
                )
            }
            .disabled(audiobookProgress.remaining > 0)
            .help("Generate text-to-speech audio for every chapter that does not have it yet")
            // A book's walkthrough is one a chapter (product owner, 2026-09-19:
            // "books (or chapters thereof)"): this writes the chapters that
            // have none, one after another, steps only — one writing call a
            // chapter, no animations — so a forty-chapter book is one click
            // and a bounded bill. A chapter's own Write Walkthrough draws them.
            let walkthroughRemaining = walkthroughCoordinator.batchRemaining(forGroup: groupName)
            Button {
                let chapters = vm.bookChapterArticlesInOrder(for: groupName)
                Task { await walkthroughCoordinator.generateMissing(for: chapters, group: groupName, in: vm) }
            } label: {
                Label(
                    walkthroughRemaining > 0
                        ? "Writing Walkthroughs… (\(walkthroughRemaining) left)"
                        : "Write Walkthroughs for All Chapters",
                    systemImage: "figure.walk.motion"
                )
            }
            .disabled(walkthroughRemaining > 0)
            .help("Write a step-by-step walkthrough for every chapter that does not have one yet; steps only, no animations")
            Divider()
            Button {
                Task { await vm.setBookHidden(groupName, hidden: true) }
            } label: {
                Label("Hide Book", systemImage: "eye.slash")
            }
            Button {
                alertText = vm.bookDisplayName(groupName)
                activeAlert = .renameBook(groupName)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                alertText = vm.bookDisplayAuthor(groupName) ?? ""
                activeAlert = .editBookAuthor(groupName)
            } label: {
                Label(vm.bookDisplayAuthor(groupName) != nil ? "Edit Author" : "Add Author", systemImage: "person")
            }
            Button {
                alertText = vm.bookDisplaySubtitle(groupName) ?? ""
                activeAlert = .editBookSubtitle(groupName)
            } label: {
                Label(vm.bookDisplaySubtitle(groupName) != nil ? "Edit Subtitle" : "Add Subtitle", systemImage: "text.quote")
            }
            Button {
                alertText = vm.bookDisplayEdition(groupName) ?? ""
                activeAlert = .editBookEdition(groupName)
            } label: {
                Label(vm.bookDisplayEdition(groupName) != nil ? "Edit Edition" : "Add Edition", systemImage: "books.vertical")
            }
            Button {
                alertText = vm.bookDisplayKind(groupName) ?? ""
                activeAlert = .editBookKind(groupName)
            } label: {
                Label(vm.bookDisplayKind(groupName) != nil ? "Edit Category" : "Set Category", systemImage: "tag")
            }
            Divider()
            Button {
                chapterManagerTarget = ManageChaptersTarget(groupName: groupName)
            } label: {
                Label("Manage Chapters…", systemImage: "list.bullet.rectangle")
            }
            // A book is the same book only when it is the same file, so a
            // fresh copy of a damaged book, or the book on a Mac its file
            // never reached, becomes this book's file only when asked for here.
            Button {
                Task { await replaceBookFile(groupName) }
            } label: {
                Label("Replace Book File…", systemImage: "doc.badge.arrow.up")
            }
            .help("Use another copy of this book's file; its chapters are found again in it")
            Button(role: .destructive) {
                activeAlert = .deleteBook(groupName)
            } label: {
                Label("Remove Book", systemImage: "trash")
            }
        }
    }

    /// Asks for the file that is to be this book's, and imports it as the book.
    private func replaceBookFile(_ bookID: String) async {
        let urls = await FilePanel.open { panel in
            panel.allowedContentTypes = supportedBookImportContentTypes
            panel.allowsMultipleSelection = false
            panel.message = "Select the file for “\(vm.bookDisplayName(bookID))” (PDF, EPUB, or DRM-free Kindle)"
        }
        guard let url = urls.first else { return }
        do {
            try await vm.importBook(from: url.path, replacingBookID: bookID)
        } catch {
            vm.errorMessage = error.localizedDescription
            vm.showBookImportError = true
        }
    }

    private func groupItemCount(_ itemCount: Int, alignment: Alignment, isRevealed: Bool) -> some View {
        Text("\(itemCount)")
            .zoomedSystemFont(size: 11)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // A fixed width keeps counts stable as their digit length changes.
            // Meeting provider marks follow this column, so their trailing edge
            // stays aligned at the right of every collection row. The column
            // keeps its width while the count is hidden, so neither the marks
            // nor a two-line title move when the pointer arrives.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 22, alignment: alignment)
            .opacity(isRevealed ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isRevealed)
    }

    private func groupDisplayName(_ groupName: String) -> String {
        if sidebar.sidebarTab == .videos { return vm.videoPlaylistDisplayName(groupName) }
        if sidebar.sidebarTab == .meetings { return vm.meetingDisplayName(groupName) }
        return vm.bookDisplayName(groupName)
    }

    func openEPUBInAppleBooks(_ epubURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        if let booksURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") {
            NSWorkspace.shared.open([epubURL], withApplicationAt: booksURL, configuration: config)
        } else {
            NSWorkspace.shared.open(epubURL)
        }
    }

    // MARK: - File Drop Overlays

    private var booksDropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 5]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .zoomedSystemFont(size: 40, weight: .light)
                    Text("Drop book to import")
                        .font(.headline)
                    Text("PDF, EPUB, and DRM-free Kindle files use the Add Book flow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }

    private var papersDropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 5]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .zoomedSystemFont(size: 40, weight: .light)
                    Text("Drop PDFs to import as papers")
                        .font(.headline)
                    Text("Drop onto a paywalled paper to attach its PDF instead")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }

    private func groupedCollectionArticleRow(_ article: StudioArticle, groupName: String) -> some View {
        Group {
            if sidebar.sidebarTab == .videos {
                videoPlaylistArticleRow(article, groupName: groupName)
            } else {
                articleRow(article)
            }
        }
        .dropDestination(for: StudioArticleTransfer.self) { transfers, _ in
            guard let t = transfers.first, t.articleId != article.id else { return false }
            Task { await vm.reorderArticleInGroup(t.articleId, before: article.id, inGroup: groupName) }
            return true
        }
    }

    /// One meeting session: the session row itself, with the files that made it
    /// up (recording, notes, transcript, chat) nested beneath. The artifacts are
    /// not sources — they are the session's parts — so they get a lighter row
    /// than `articleRow`, and open the session in the reader at their own part of
    /// it rather than selecting a source of their own. See `MeetingArtifactRow`.
    ///
    /// `showsSeries` is the by-date list, where no series header stands above the
    /// row to say which meeting it belongs to: the row says it itself, and a
    /// session has no place among its series' sessions to be dropped into.
    ///
    /// The files are a row of their own *beside* the session row, opened by the
    /// session row's own chevron, so the list stays one flat run of rows.
    @ViewBuilder
    private func meetingSessionRow(
        _ article: StudioArticle,
        groupName: String?,
        showsSeries: Bool = false
    ) -> some View {
        let artifacts = (vm.meetingArtifactsBySourceId[article.id] ?? [])
            .sorted { ($0.kind.sortRank, $0.sortIndex) < ($1.kind.sortRank, $1.sortIndex) }
        let sessionKey = "meeting-session:\(article.id)"
        let isExpanded = !artifacts.isEmpty && sidebar.expandedGroups.contains(sessionKey)

        Group {
            if showsSeries {
                articleRow(article, showsMeetingSeries: true)
            } else if let groupName {
                groupedCollectionArticleRow(article, groupName: groupName)
            }
        }
        // Padding and an overlay rather than an HStack: every session keeps the
        // chevron's room, so sessions with files and without line up.
        .padding(.leading, MeetingSessionChevron.width)
        .overlay(alignment: .leading) {
            if !artifacts.isEmpty {
                MeetingSessionChevron(
                    isExpanded: isExpanded,
                    title: vm.displayTitle(for: article)
                ) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if isExpanded {
                            sidebar.expandedGroups.remove(sessionKey)
                        } else {
                            sidebar.expandedGroups.insert(sessionKey)
                        }
                    }
                }
            }
        }

        if isExpanded {
            MeetingArtifactStack {
                ForEach(artifacts) { artifact in
                    MeetingArtifactRow(artifact: artifact)
                }
            }
            // Under the session's icon, where the outline's own indent used
            // to put it.
            .padding(.leading, MeetingSessionChevron.width)
        }
    }

    private func videoPlaylistArticleRow(_ article: StudioArticle, groupName: String) -> some View {
        var displayArticle = article
        let trimmedTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? article.title : trimmedTitle
        if let sortIndex = article.courseSortIndex, sortIndex >= 0 {
            displayArticle.title = StudioViewModel.numberedOutlineRowTitle(title, number: sortIndex + 1)
        } else {
            displayArticle.title = title
        }

        return ArticleRow(article: displayArticle, metadataVisibility: metadataVisibility)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                openSidebarArticleFromDoubleClick(article.id)
            })
            // The help goes on a group of its own: on the plain row it
            // replaced the help of every button in it (read state, Reviewed,
            // Edit metadata, Mark as paywalled).
            .accessibilityElement(children: .contain)
            .help(sidebarArticleInteractionHelp)
            .modifier(PaperPDFDropTargetModifier(article: article))
            .modifier(SourceRowDragModifier(
                itemProvider: {
                    articleDragProvider(
                        for: article,
                        selectedArticleIds: sourceIDsForArticleDrag(startingWith: article)
                    )
                },
                preview: {
                    SourceDragPreview(
                        title: displayArticle.title,
                        subtitle: nil,
                        sourceType: article.sourceType,
                        isMissing: article.state == .error
                    )
                }
            ))
            .modifier(LazySourceRowChrome(
                highlightIDs: [article.id],
                rowID: article.id,
                onClick: { handleLazyRowClick(article.id) },
                menu: { lazyRowContextMenu(for: article.id) }
            ))
    }

    /// A source's row: its selection and click-to-open (`LazySourceRowChrome`),
    /// the paper PDF drop target, and the drag that carries it to a chat, a
    /// Notebook or another window. A source's explainer, when it has one, is an
    /// ordinary source in storage but has no row in the sidebar at all
    /// (explainer-design.md): it is read from the source's Explain button or
    /// its context menu.
    private func articleRow(_ article: StudioArticle, showsMeetingSeries: Bool = false) -> some View {
        ArticleRow(
            article: article,
            metadataVisibility: metadataVisibility,
            showsMeetingSeries: showsMeetingSeries
        )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                openSidebarArticleFromDoubleClick(article.id)
            })
            // A group of its own for the help, as in the playlist row above.
            .accessibilityElement(children: .contain)
            .help(sidebarArticleInteractionHelp)
            .modifier(PaperPDFDropTargetModifier(article: article))
            .modifier(sourceRowDragModifier(for: article))
            .modifier(LazySourceRowChrome(
                highlightIDs: [article.id],
                rowID: article.id,
                onClick: { handleLazyRowClick(article.id) },
                menu: { lazyRowContextMenu(for: article.id) }
            ))
    }

    private func sourceRowDragModifier(for article: StudioArticle) -> some ViewModifier {
        SourceRowDragModifier(
            itemProvider: {
                articleDragProvider(
                    for: article,
                    selectedArticleIds: sourceIDsForArticleDrag(startingWith: article)
                )
            },
            preview: {
                SourceDragPreview(
                    title: vm.displayTitle(for: article),
                    subtitle: nil,
                    sourceType: article.sourceType,
                    isMissing: article.state == .error
                )
            }
        )
    }

    private var sidebarArticleInteractionHelp: String {
        vm.opensSidebarSourcesOnSingleClick
            ? "Click to open; drag to move"
            : "Double-click to open; drag to move"
    }

    /// Quote the whole book once, then hand every chapter that still needs
    /// audio to the batch queue in reading order, so the book becomes
    /// listenable from the front while the rest fills in behind it.
    func startAudiobookGeneration(forBookGroup groupName: String) async {
        guard let plan = await articleSpeech.audiobookPlan(forBookGroup: groupName) else {
            // Nothing to do is the common case here — every chapter already has
            // audio — and it is worth saying, because the menu item cannot know
            // that without pricing the book.
            vm.showToast(
                MacArticleSpeechSettings.provider.isCloudProvider
                    ? "Every chapter of this book already has audio"
                    : "Choose a file-generating voice in Text-to-Speech settings first"
            )
            return
        }
        if plan.isBillable, !ArticleSpeechService.confirmAudiobookGeneration(plan) { return }
        let outcome = audioQueue.enqueue(plan.chapters, allowsUnsupportedLanguages: false)
        guard !outcome.queued.isEmpty else {
            vm.showToast("This book's chapters are already being generated")
            return
        }
        let noun = outcome.queued.count == 1 ? "chapter" : "chapters"
        vm.showToast("Generating \(outcome.queued.count) \(noun) of \(plan.title)")
    }

    /// A plain click or an arrow key opens the row when the Library opens
    /// sources on a single click.
    private func openSidebarArticleFromRowClick(_ sourceID: String) {
        guard vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(sourceID)
    }

    /// A habitual second click must not start the same async open twice.
    private func openSidebarArticleFromDoubleClick(_ sourceID: String) {
        guard !vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(sourceID)
    }

    private func openBookGroupFromDoubleClick(_ resumeSourceID: String) {
        guard !vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(resumeSourceID)
    }

    private func openSidebarArticle(_ sourceID: String) {
        // The row's tap gesture also sees a click on a control inside the
        // row; that click was the control's.
        guard !SidebarRowControlPress.claims(sourceID) else { return }
        // A click that extended or toggled the selection is selection, not
        // navigation: opening here would write one row back over it.
        guard SidebarSourceSelection.rowTapOpens(
            sourceID: sourceID,
            selection: windowState.sidebarSelectedSourceIDs,
            usesMultiSelectModifier: isSourceMultiSelectModifierActive()
        ), vm.articlesById[sourceID] != nil else { return }
        guard pendingSidebarOpenSourceID != sourceID else { return }
        pendingSidebarOpenSourceID = sourceID
        windowState.sidebarSelectedSourceIDs = [sourceID]
        vm.readerPoppedOut = false
        Task {
            // This window, by name: the registry's key window can still be the
            // one used before the click that focused this one.
            await vm.selectArticle(sourceID, in: windowState, revealingReader: true)
            if pendingSidebarOpenSourceID == sourceID {
                pendingSidebarOpenSourceID = nil
            }
        }
    }

    /// What a drag that starts on this row picks up: the whole selection, in
    /// display order, when the row is part of one; otherwise the row alone.
    private func sourceIDsForArticleDrag(startingWith article: StudioArticle) -> [String] {
        SidebarSourceSelection.dragSourceIDs(
            startingWith: article.id,
            selection: windowState.sidebarSelectedSourceIDs,
            displayOrder: { ids in windowVM.inWindow { $0.sourceIDsInCurrentDisplayOrder(ids) } }
        )
    }
}

// MARK: - Source search field

/// The Sources search field.
///
/// It takes every keystroke into `searchFieldText`; the lists filter on
/// `searchText`, which follows once typing pauses. Filtering the whole library,
/// and redrawing a list of hundreds of papers, on each keystroke made typing lag
/// behind the fingers (product owner, 2026-10-10). It is its own view for the
/// same reason: the sidebar around it reads only the committed query, so a
/// keystroke redraws this field and nothing else.
private struct SourceSearchField: View {
    @Environment(StudioSidebarStore.self) private var sidebar
    var isFocused: FocusState<Bool>.Binding
    let help: String
    /// Return, after the query is committed.
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        @Bindable var sidebar = sidebar
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .zoomedSystemFont(size: 11.5, weight: .medium)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search \(sidebar.sidebarTab.itemNoun)", text: $sidebar.searchFieldText)
                .textFieldStyle(.plain)
                .zoomedSystemFont(size: 12.5)
                // AppKit's text field reports an intrinsic minimum width from the
                // placeholder, so let long source-count placeholders compress in
                // narrow source columns.
                .frame(minWidth: 0)
                .focused(isFocused)
                .onSubmit {
                    // Return applies the query without waiting out the pause.
                    commit()
                    onSubmit()
                }
                .onKeyPress(.escape) {
                    onClear()
                    return .handled
                }
                .accessibilityLabel("Search \(sidebar.sidebarTab.itemNoun)")
                .help(help)
            // The scope the query is confined to, so "title:" is visibly doing
            // something before the list changes.
            if let field = StudioViewModel.SidebarSearchQuery(parsing: sidebar.searchFieldText).field {
                Text(field.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    // Selectable text cannot carry its own AX label on macOS;
                    // see AGENTS.md, "Text that speaks for itself".
                    .textSelection(.disabled)
                    .accessibilityLabel("Searching \(field.label.lowercased()) only")
            }
            if !sidebar.searchFieldText.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.hoverWash(in: Circle(), inset: -3))
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        // Grows with the app's text size rather than clipping it.
        .padding(.vertical, 6)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(isFocused.wrappedValue ? 0.22 : 0.12), lineWidth: 1)
        }
        // Clearing applies at once; anything else waits for a pause.
        .task(id: sidebar.searchFieldText) {
            if !sidebar.searchFieldText.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            commit()
        }
    }

    /// Hands the field's text to the lists. It copies the field as it is now,
    /// not as it was when the pause began, so a keystroke landing just as the
    /// pause ends is never written back over (`searchText` puts the field in
    /// step with whatever it is given).
    private func commit() {
        guard sidebar.searchText != sidebar.searchFieldText else { return }
        sidebar.searchText = sidebar.searchFieldText
    }
}

// MARK: - Pull-to-refresh

/// Fires refresh callbacks when the user reaches or pulls past the top of the list
/// that this view backs. SwiftUI's `.refreshable` has no scroll-driven trigger on
/// macOS, so we observe the underlying `NSScrollView`'s clip-view bounds. The view
/// is invisible and sits behind the list, so it never intercepts clicks; it just
/// locates the scroll view and watches it.
///
/// A deliberate pull (fingers on the trackpad, gesture phase, no momentum) fires
/// `onRefresh` — the full refresh with loading UI. An ordinary upward scroll that
/// reaches the top fires `onSilentRefresh`: scrolling to the top is the user asking
/// "is there anything new?", so it should sync immediately — but through a quiet
/// path that shows no loading UI and republishes the list only when something
/// actually changed.
private struct OverscrollRefresh: NSViewRepresentable {
    /// How far the content must be pulled past the top before a refresh fires.
    var threshold: CGFloat = 64
    var onRefresh: () -> Void
    var onSilentRefresh: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = TrackerView()
        view.threshold = threshold
        view.onRefresh = onRefresh
        view.onSilentRefresh = onSilentRefresh
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TrackerView else { return }
        view.threshold = threshold
        view.onRefresh = onRefresh
        view.onSilentRefresh = onSilentRefresh
    }

    final class TrackerView: NSView {
        var threshold: CGFloat = 64
        var onRefresh: (() -> Void)?
        var onSilentRefresh: (() -> Void)?

        private weak var clipView: NSClipView?
        private var observer: NSObjectProtocol?
        private var scrollEventMonitor: Any?
        private var armed = true
        private var isUserDragScrolling = false
        /// Starts false so constructing a List already positioned at the top is
        /// not mistaken for a user refresh. It becomes true only after this List
        /// has actually been scrolled down.
        private var hasScrolledAwayFromTop = false
        private var setupAttempts = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            teardown()
            guard window != nil else { return }
            setupAttempts = 0
            scheduleSetup()
        }

        private func scheduleSetup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.attemptSetup()
            }
        }

        private func attemptSetup() {
            guard observer == nil, window != nil else { return }
            if let scrollView = locateScrollView() {
                let clip = scrollView.contentView
                clip.postsBoundsChangedNotifications = true
                clipView = clip
                hasScrolledAwayFromTop = clip.bounds.origin.y > 1
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip,
                    queue: .main
                ) { [weak self] _ in
                    self?.handleScroll()
                }
                scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.trackScrollPhases(of: event)
                    return event
                }
            } else if setupAttempts < 8 {
                setupAttempts += 1
                scheduleSetup()
            }
        }

        /// Older mouse wheels report no phases, but they also can't rubber-band, so
        /// they never reach the overscroll region and the flag's state is irrelevant.
        private func trackScrollPhases(of event: NSEvent) {
            if event.momentumPhase != [] {
                isUserDragScrolling = false
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    finishScrollGesture()
                }
            } else if event.phase == .began || event.phase == .changed {
                isUserDragScrolling = true
            } else if event.phase == .ended || event.phase == .cancelled {
                isUserDragScrolling = false
                finishScrollGesture()
            }
        }

        private func finishScrollGesture() {
            guard let offset = clipView?.bounds.origin.y, offset <= 1 else { return }
            // A top-reaching silent refresh disarms a later elastic crossing in
            // the same gesture. Re-arm only when that gesture has settled, so a
            // new deliberate pull from the top can still request a full refresh.
            armed = true
        }

        private func handleScroll() {
            guard let clipView else { return }
            let offset = clipView.bounds.origin.y
            if offset <= -threshold {
                guard armed else { return }
                if isUserDragScrolling {
                    armed = false
                    onRefresh?()
                } else if let onSilentRefresh {
                    armed = false
                    onSilentRefresh()
                }
            } else if offset > 1 {
                hasScrolledAwayFromTop = true
                armed = true
            } else if offset <= 0, hasScrolledAwayFromTop {
                // Reaching the real top is enough. Requiring a 64-point elastic
                // bounce meant normal upward scrolling never synced plugins.
                hasScrolledAwayFromTop = false
                armed = false
                onSilentRefresh?()
            }
        }

        /// Finds the table-backed scroll view whose frame contains this (invisible)
        /// backing view's center — i.e. the list we're behind, ignoring any other
        /// scroll views elsewhere in the window.
        private func locateScrollView() -> NSScrollView? {
            guard let root = window?.contentView else { return nil }
            let frameInWindow = convert(bounds, to: nil)
            guard frameInWindow.width > 0, frameInWindow.height > 0 else { return nil }
            let center = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
            var match: NSScrollView?
            func walk(_ view: NSView) {
                // The list's vertical scroll view; the innermost one wins.
                if let scrollView = view as? NSScrollView, scrollView.hasVerticalScroller {
                    let frame = scrollView.convert(scrollView.bounds, to: nil)
                    if frame.contains(center) { match = scrollView }
                }
                for subview in view.subviews { walk(subview) }
            }
            walk(root)
            return match
        }

        private func teardown() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let scrollEventMonitor {
                NSEvent.removeMonitor(scrollEventMonitor)
                self.scrollEventMonitor = nil
            }
            clipView = nil
            armed = true
            isUserDragScrolling = false
            hasScrolledAwayFromTop = false
        }

        deinit { teardown() }
    }
}

/// What a row of the Sources list adds around the row itself: the
/// selection's grey wash, the hairline under a full row, the click that
/// selects and opens, and the row's menu.
///
/// `highlightIDs` are the sources whose selection lights the row (a book's
/// row lights for any of its chapters); `rowID` is the one a click selects.
/// The menu is built only while the pointer is over the row: SwiftUI builds a
/// `.contextMenu`'s items in the row's body, so a menu on every row would be
/// built again for each row that scrolls in, and a right-click always lands
/// on a hovered row. A row whose own label carries its menu passes none.
private struct LazySourceRowChrome<MenuContent: View>: ViewModifier {
    let highlightIDs: Set<String>
    let rowID: String
    let onClick: () -> Void
    let menu: (() -> MenuContent)?

    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    @Environment(\.sourcesListLayout) private var sourcesListLayout
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let isSelected = !(windowState?.sidebarSelectedSourceIDs.isDisjoint(with: highlightIDs) ?? true)
        return content
            .padding(.vertical, sourcesListLayout == .compact ? 1 : 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.10 : 0))
                    .padding(.horizontal, -6)
            }
            .overlay(alignment: .bottom) {
                if sourcesListLayout != .compact && !isSelected {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                        .padding(.leading, 46)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 1).onEnded { onClick() })
            .onHover { isHovered = $0 }
            .contextMenu {
                if isHovered, let menu { menu() }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .id(rowID)
    }
}

/// A series or playlist row's label, handed whether the pointer is over it,
/// with the hover kept in its own view so a hover never re-runs the list's
/// body. The whole row counts, whitespace included.
private struct SourceGroupRowHover<Content: View>: View {
    @ViewBuilder let content: (_ isHovered: Bool) -> Content

    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// Indents a session's artifacts under it and hangs a hairline rail down the
/// left, so the files read as parts of the meeting above rather than siblings.
/// The chevron that shows or hides a meeting session's files. The session row
/// draws it itself (see `meetingSessionRow`), like a series' own chevron
/// (`lazyGroupHeader`).
private struct MeetingSessionChevron: View {
    static let width: CGFloat = 16

    let isExpanded: Bool
    let title: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .zoomedSystemFont(size: 10, weight: .semibold)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: Self.width, height: Self.width)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 4, inset: 0, opacity: 0.10))
        .help(isExpanded ? "Hide this meeting's files" : "Show this meeting's files")
        .accessibilityLabel(isExpanded ? "Hide the files of \(title)" : "Show the files of \(title)")
    }
}

private struct MeetingArtifactStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(spacing: 1) {
            content
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
        }
        .padding(.leading, 8)
    }
}

/// A single file belonging to a meeting session.
///
/// The row opens the session in ForeverLM's own reader, at this file's part of
/// it — the transcript Google wrote is already ingested, so a click that left
/// for Google Docs was giving up search, highlights, review, listening, the
/// papers a meeting mentioned, and the slides in its recording, all to show text
/// ForeverLM already had. Drive stays one click away in the hover button beside
/// the row, which is also where a file whose text never made it into the session
/// lands, so a click is never swallowed.
private struct MeetingArtifactRow: View {
    let artifact: MeetingArtifact

    @Environment(StudioViewModel.self) private var vm
    @State private var isHovering = false
    @State private var isOpening = false

    /// Where this file exists outside ForeverLM, if anywhere.
    private enum ExternalCopy {
        case webPage(URL)
        case fileOnDisk(URL)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: artifact.kind.iconName)
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(artifact.kind.label)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
        .disabled(!canOpen)
        .overlay(alignment: .trailing) {
            // Drawn over the row rather than inside it, so appearing on hover
            // never reflows the label beside it.
            if isHovering, let external = externalCopy {
                Button {
                    open(external)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .zoomedSystemFont(size: 9)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.hoverWash(inset: -3))
                .help(externalHelp(for: external))
            }
        }
        .onHover { isHovering = $0 }
        .help(artifact.title)
        .contextMenu {
            if canOpen {
                Button(action: open) {
                    Label("Open in ForeverLM", systemImage: "book")
                }
                OtherWindowSourceMenuItem(sourceID: artifact.sourceId)
            }
            if let external = externalCopy {
                Button {
                    open(external)
                } label: {
                    Label(externalHelp(for: external), systemImage: "arrow.up.forward.square")
                }
            }
        }
    }

    /// The kinds ForeverLM shows in place stay live even with no external copy at
    /// all: an on-device transcript has neither a Drive URL nor a file on disk,
    /// and used to render as a permanently disabled row under the recording it
    /// was made from.
    private var canOpen: Bool {
        switch artifact.kind {
        case .transcript, .notes, .chat, .recording:
            return true
        case .attachment:
            return externalCopy != nil
        }
    }

    private var externalCopy: ExternalCopy? {
        if let url = artifact.url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty,
           let resolved = URL(string: url) {
            return .webPage(resolved)
        }
        if let path = artifact.localFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return .fileOnDisk(URL(fileURLWithPath: path))
        }
        return nil
    }

    private func externalHelp(for external: ExternalCopy) -> String {
        switch external {
        case .webPage(let url):
            return url.host?.contains("google.com") == true
                ? "Open in Google Drive"
                : "Open in browser"
        case .fileOnDisk:
            return "Reveal in Finder"
        }
    }

    private func open() {
        guard !isOpening else { return }
        isOpening = true
        Task {
            let openedInReader = await vm.openMeetingArtifactInReader(artifact)
            isOpening = false
            guard !openedInReader else { return }
            // This file's text never reached the session document — a Doc the
            // plugin could not export, a deck attached to the invite — so the
            // external copy is the only place it exists.
            if let external = externalCopy {
                open(external)
            } else {
                vm.showToast("ForeverLM has no copy of this \(artifact.kind.label.lowercased()) to open.")
            }
        }
    }

    private func open(_ external: ExternalCopy) {
        switch external {
        case .webPage(let url):
            WebLinkOpening.open(url)
        case .fileOnDisk(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// A meeting folder's sidebar tile: the image chosen for that folder, or the
/// shared meetings icon when none is.
///
/// The chosen image is drawn `.fill`, so a logo that is not
/// square crops to the tile instead of floating in a half-empty one. A failed
/// or still-loading fetch shows the default icon rather than a gap — the header
/// is chrome, and an empty square there reads as a broken folder.
private struct MeetingFolderIcon: View {
    let imageURL: String?

    var body: some View {
        Group {
            if let imageURL, let url = URL(string: imageURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        defaultIcon
                    }
                }
            } else {
                defaultIcon
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var defaultIcon: some View {
        Image("MeetingsIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
    }
}

/// The provider marks for one meeting series.
///
/// Meetings is a single tab over several providers, so a row has to say which
/// one it came from. A series that draws on more than one shows more than one
/// mark — the split Google Drive and Read AI tabs listed that series twice
/// instead, once under each, which is the duplication this replaces.
struct MeetingProviderBadges: View {
    let providers: [MeetingProvider]
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(providers) { provider in
                MeetingProviderMark(provider: provider, size: size)
                    .help("Synced with \(provider.displayName)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard !providers.isEmpty else { return "" }
        return "From " + ListFormatter.localizedString(
            byJoining: providers.map(\.displayName)
        )
    }
}

/// One provider's brand mark, falling back to an SF Symbol for providers with
/// no logo of their own — a folder on this Mac is not a brand.
struct MeetingProviderMark: View {
    let provider: MeetingProvider
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let asset = provider.iconAsset {
                Image(asset)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
            } else {
                Image(systemName: provider.icon)
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(provider.color)
            }
        }
        .frame(width: size, height: size)
        .help(provider.displayName)
    }
}

// MARK: - Meeting plugin notice

extension StudioSidebar {
    /// What the Meetings tab should say about a plugin that has gone quiet,
    /// if anything. Read AI meetings only ever arrive through a plugin, so
    /// having any is reason to expect one; a Zoom link can also be added by
    /// hand, so Zoom expects one only once a plugin has pushed some.
    private var meetingPluginNotice: MeetingPluginNotice? {
        MeetingPluginNotice.resolve(
            providersInUse: vm.meetingProvidersInUse,
            expectsSync: { candidate in
                candidate == .readAI || vm.articles.contains {
                    $0.sourceType == .meeting
                        && MeetingProvider.forOrigin($0.discoveryOrigin) == candidate
                        && $0.connectorLabel.map { candidate.matches(connectorLabel: $0) } == true
                }
            },
            plugins: meetingPluginSummaries.map {
                MeetingPluginNotice.Plugin(name: $0.name, trouble: $0.attentionSummary)
            },
            hasMCPAddress: meetingPluginSetupAddress != nil
        )
    }

    private func meetingPluginActionTitle(for notice: MeetingPluginNotice) -> String {
        notice.action == .copySetupPrompt && didCopyMeetingPluginSetupPrompt
            ? "Copied"
            : notice.actionTitle
    }

    /// The one thing the notice offers. Copying hands over the guide's recipe
    /// with the user's MCP address and the provider filled in — the same
    /// contract Plugins › Build Your Own copies, opening with a
    /// request to find and reconnect the plugin that used to run before
    /// building another — and the toast says where it goes next, since a copy
    /// is invisible on its own.
    private func performMeetingPluginAction(_ notice: MeetingPluginNotice) {
        switch notice.action {
        case .copySetupPrompt:
            guard let address = meetingPluginSetupAddress else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(
                UserPluginSetupPrompt.text(mcpURL: address, for: notice.provider),
                forType: .string
            )
            didCopyMeetingPluginSetupPrompt = true
            vm.showToast(
                "Setup prompt copied. Paste it into Claude, ChatGPT, or any coding assistant — it finds and reconnects your \(notice.provider.displayName) plugin, or builds one if none is left, and you approve it once in ForeverLM."
            )
            Task {
                try? await Task.sleep(for: .seconds(2))
                didCopyMeetingPluginSetupPrompt = false
            }
        case .openBuildYourOwn, .showPluginStatus:
            PluginsPlace.requestOpen(.yourPlugins)
        }
    }
}

// MARK: - Zoom recording awaiting conversion

/// One Zoom recording on this Mac that only Zoom can convert, with the two
/// things the learner can say about it. **Convert in Zoom** is their own
/// double-click made once — Zoom converts once its unknown-source dialog is
/// answered, by ForeverLM when it may use Accessibility (macOS asks at the
/// first click when it may not), and the watcher files and transcribes the
/// result; **Ignore** leaves the
/// recording in the folder and takes it off the tab, for a meeting that did
/// not happen. Shared by the Meetings tab, which shows the ones not ignored,
/// and Settings › Sources, which shows all of them so an Ignore can be undone.
struct ZoomRecordingAwaitingConversionRow: View {
    @Environment(StudioViewModel.self) private var vm
    let recording: StudioViewModel.ZoomLocalRecordingAwaitingConversion

    private var isIgnored: Bool {
        vm.zoomLocalRecordingIgnoredFolders.contains(recording.folder.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isIgnored ? "waveform.slash" : "waveform.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(isIgnored ? Color.secondary : .orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Spacer()
                Button(isIgnored ? "Stop Ignoring" : "Ignore") {
                    vm.setZoomLocalRecordingIgnored(recording, !isIgnored)
                }
                .accessibilityLabel(isIgnored ? "Stop ignoring this recording" : "Ignore this recording")
                Button("Convert in Zoom") { convert() }
                    .accessibilityLabel("Convert this recording in Zoom")
            }
            .buttonStyle(.hoverWash)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("zoom-recording-awaiting-conversion")
    }

    private var message: String {
        let when = recording.folder.startedAt.formatted(date: .abbreviated, time: .shortened)
        return isIgnored
            ? "Ignored: the Zoom recording of \(recording.title), \(when)."
            : "Zoom hasn't converted its recording of \(recording.title), \(when). Convert it to file and transcribe the meeting, or ignore it."
    }

    private func convert() {
        if vm.convertZoomLocalRecordingInZoom(recording) {
            vm.showToast(AXIsProcessTrusted()
                ? "Zoom is converting the recording. ForeverLM files and transcribes it when Zoom is done."
                : "Allow ForeverLM under Accessibility and it answers Zoom's question about unknown sources for you.")
        } else {
            vm.showToast("Nothing on this Mac opens Zoom recordings. Convert it from Zoom's Recorded tab instead.")
        }
    }
}
