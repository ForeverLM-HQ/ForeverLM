import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension StudioSidebar {
    private var sidebarListIdentity: String {
        sidebar.sidebarTab.rawValue
    }

    /// The one selection binding the Sources list has. AppKit owns the
    /// conventions on it (click, shift-range, command-toggle, drag from a
    /// selected row); `SidebarSourceSelection` decides what this window keeps
    /// and which write was a click that opens the source.
    private func sidebarSelection(visibleSourceIDs: Set<String>) -> Binding<Set<String>> {
        Binding(
            get: {
                let visible = windowState.sidebarSelectedSourceIDs.intersection(visibleSourceIDs)
                if visible.isEmpty,
                   let readerID = sidebarReaderSourceID,
                   visibleSourceIDs.contains(readerID) {
                    // A rebuilt list lands on the row the Reader shows.
                    return [readerID]
                }
                return visible
            },
            set: { newSelection in
                if newSelection.isEmpty {
                    if isSpuriousListDeselection() { return }
                    closeReaderForListDeselection()
                    return
                }
                guard let resolution = SidebarSourceSelection.resolve(
                    listSelection: newSelection,
                    previousSelection: windowState.sidebarSelectedSourceIDs,
                    usesMultiSelectModifier: isSourceMultiSelectModifierActive(),
                    isKnownSource: { vm.articlesById[$0] != nil }
                ) else { return }
                // A press on a row's own control (its notebook +, its read
                // state) belongs to the control: the row is neither selected
                // nor opened under it.
                if let sourceID = resolution.opensSource, SidebarRowControlPress.claims(sourceID) { return }
                if isSidebarSelectionFromMousePress, let sourceID = resolution.opensSource {
                    // AppKit writes the selection on mouse-down, which can
                    // come before the control under the pointer notes its
                    // press. So a plain click's selection waits for mouse-up
                    // with its open, and the claim is asked again then
                    // (`completeDeferredSidebarOpenOnMouseUp`); a drag keeps
                    // it at once (`keepDeferredSidebarSelectionForDrag`).
                    deferredSidebarSelection = resolution.selection
                    deferredSidebarOpenSourceID = sourceID
                    return
                }
                windowState.sidebarSelectedSourceIDs = resolution.selection
                guard let sourceID = resolution.opensSource else { return }
                openSidebarArticleFromSingleClick(sourceID)
            }
        )
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

    /// The user clicked past every row. This is the only path that closes the reader off a
    /// selection change: pruning empties the same set when a tab or search filters the open
    /// source out of view, and that must leave what is being read alone.
    private func closeReaderForListDeselection() {
        vm.closeReader(in: windowState)
    }

    /// Whether an empty selection pushed back by the List should be ignored.
    ///
    /// Recreating the sidebar — expanding the sources panel from its collapsed
    /// rail, or swapping between the single- and multi-select Lists — builds a
    /// fresh List. If the selected source has no row at that moment (its
    /// disclosure group starts collapsed, book chapters never get rows), AppKit
    /// cannot represent the
    /// selection and SwiftUI writes an empty selection back through the binding.
    /// Treating that as a user deselection closed the reader. Only accept an
    /// empty selection when the selected source has a row the user could
    /// actually have deselected.
    private func isSpuriousListDeselection() -> Bool {
        guard let id = sidebarReaderSourceID ?? windowState.sidebarSelectedSourceIDs.first else { return false }
        return !selectionHasVisibleRow(id)
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
                guard let group = article.parentGroup else { return false }
                return sidebar.expandedGroups.contains(group)
            }
            return true
        }
    }

    /// Scroll the list to the source another panel just selected — following a
    /// chat citation, say. The view model has already switched to the owning tab,
    /// expanded the parent group, and grown pagination so the row exists; all that
    /// is left is bringing it on screen, where the List's own selection highlight
    /// makes it stand out.
    ///
    /// Driven by `.task(id:)` rather than `onChange` because switching tabs rebuilds
    /// the List (`.id(sidebarListIdentity)`), and a freshly created view never sees
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


    @ViewBuilder
    var sidebarTabBar: some View {
        // Docked in Studio the compact tab bar rises into the hidden-titlebar
        // band: a row exactly the band's height, so the source-type icons sit
        // on the traffic lights' center line instead of in their own row below
        // a dead strip. The band is roomy enough (~52pt) for a full-size
        // icon+label stack — the row must not outgrow it, or the icons' center
        // drops below the lights' line and the bar reads as misaligned with the
        // other panels' headers. The roomy grid is taller still and keeps its
        // regular chrome (it rises anyway so the band space isn't wasted).
        if sourcesListLayout == .wide {
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
            .padding(.leading, sourcesHeaderLeadingInset)
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
            .padding(.leading, sourcesHeaderLeadingInset)
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
    /// a ⋯, and the Customize popover hangs from the row, since the Library
    /// has no Hide sources toggle for it to hang from.
    private var wideSourceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
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
        .popover(isPresented: $isSourceTabCustomizePresented, arrowEdge: .bottom) {
            SourceTypesCustomizePopover()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
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

    /// Compact collapse control at the trailing end of the source-type tab bar,
    /// styled to mirror the navigation-rail toggle in the window's top-left
    /// chrome. Collapses the Sources panel away entirely; the matching
    /// `SourcesPanelExpandToggle` in the top-right chrome brings it back. It
    /// is not drawn in the full-window Library, a center pane with its own ×.
    struct SourcesPanelCollapseToggle: View {
        @Environment(StudioViewModel.self) private var vm
        @Environment(StudioWindowState.self) private var windowState
        @Environment(\.sourcesListLayout) private var sourcesListLayout

        var body: some View {
            if windowState.notebook == nil, sourcesListLayout == .sidebar {
                StudioChromeIconButton(
                    systemImage: "sidebar.right",
                    label: "Hide sources"
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        vm.inWindow(windowState) {
                            vm.togglePanelCollapsed(StudioPanel.sources.rawValue)
                        }
                    }
                }
            }
        }
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
        let collapseWidth = StudioDesign.Metrics.chromeButtonWidth + 4
        let comfortable = max(StudioDesign.Metrics.comfortableSourceTabWidth, 30)
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
    /// room, then the Hide sources toggle. The product owner (2026-09-29): a ⋯ with
    /// nothing hidden behind it is not needed, so it no longer stands on the
    /// row just to hold Customize — every tab's context menu offers that. The
    /// Customize popover hangs from the toggle, which is always there, so it
    /// opens whether or not the ⋯ is.
    @ViewBuilder
    private func sourceTabBarTrailingControls(overflow: [StudioSidebarTab]) -> some View {
        if !overflow.isEmpty {
            sourceTabOverflowMenu(overflow)
        }
        SourcesPanelCollapseToggle()
            .popover(isPresented: $isSourceTabCustomizePresented, arrowEdge: .bottom) {
                SourceTypesCustomizePopover()
            }
    }

    /// The ⋯ at the trailing end of the tab bar. It lists the pinned types the
    /// row had no room for, then Customize, which opens the popover where
    /// every source type is pinned, unpinned and reordered.
    ///
    /// Drawn as the Hide sources toggle beside it is: same glyph weight, grey,
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
        let isSelected = sidebar.sidebarTab == tab
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

    private func activateSidebarTab(_ tab: StudioSidebarTab) {
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
        sourceSearchRow

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
            if sourcesListLayout == .wide {
                notInAnyNotebookToggle
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
        .padding(.leading, sourcesHeaderLeadingInset)
        .padding(.leading, 8)
        .padding(.trailing, 12)
        // A little air under the tab bar, so the field's edge does not run
        // into the tab labels above it.
        .padding(.top, 5)
        .padding(.bottom, 4)
        .transition(.opacity)
    }

    /// The full-window Library's "Not in any notebook": only the sources no
    /// notebook of the open library holds (`SourceNotebookFilter`). A toggle
    /// beside the search, lit while on; its chip under the search clears it
    /// too, and stays in the Sources panel if the Library closes with it on.
    private var notInAnyNotebookToggle: some View {
        let isOn = sidebar.sourceNotebookFilter == .notInAnyNotebook
        return Button {
            withAnimation {
                sourceFilterBinding(\.sourceNotebookFilter).wrappedValue = isOn ? .all : .notInAnyNotebook
            }
        } label: {
            Label(SourceNotebookFilter.notInAnyNotebook.title, systemImage: "folder.badge.minus")
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
        .help(isOn ? "Show every source" : "Show only the sources no notebook holds")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("library.filter.notInAnyNotebook")
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
                    NotificationCenter.default.post(
                        name: .requestOpenStudioSettings,
                        object: SettingsPane.youtubePlugin
                    )
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

        if windowVM.hasActiveSourceListFilters {
            ChipFlowLayout(spacing: 6) {
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
                if sidebar.sourceNotebookFilter != .all {
                    ActiveFilterChip(title: sidebar.sourceNotebookFilter.title) {
                        withAnimation { sourceFilterBinding(\.sourceNotebookFilter).wrappedValue = .all }
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

    @ViewBuilder
    private var sidebarSelectableList: some View {
        // AppKit may read a List selection binding hundreds of times while
        // answering one accessibility action query. Snapshot the visible IDs
        // once per SwiftUI evaluation instead of rebuilding/filtering the full
        // sidebar array inside every binding read.
        let visibleSourceIDs = windowVM.visibleSidebarSourceIDs
        // One List, bound to a set, whatever the keyboard is doing. Swapping
        // in a single-selection List when shift went up is what used to throw
        // a multi-selection away before it could be dragged anywhere.
        List(selection: sidebarSelection(visibleSourceIDs: visibleSourceIDs)) {
            sidebarListContent
        }
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            sidebarArticleContextMenu(for: selectedIDs)
        }
        .onExitCommand(perform: collapseMultiSelectionOnEscape)
    }

    /// A List-level context menu is constructed when AppKit actually requests a
    /// menu. Attaching the full nested menu to every row makes SwiftUI evaluate
    /// it while measuring automatic row heights, multiplying the work by every
    /// visible source and turning ordinary layout into a main-thread stall.
    @ViewBuilder
    private func sidebarArticleContextMenu(for selectedIDs: Set<String>) -> some View {
        let orderedIDs = windowVM.inWindow { $0.sourceIDsInCurrentDisplayOrder(selectedIDs) }
        // A Books-tab row stands for its book. Its tag is the chapter the book
        // would resume, which is what List hands over here, so the menu is the
        // book's — or, for several covers, the actions that fit all of them.
        let bookTargets = sidebar.sidebarTab == .books
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
                    if vm.bookImportStatus.isEmpty {
                        Button {
                            Task {
                                let urls = await FilePanel.open { panel in
                                    panel.allowedContentTypes = supportedBookImportContentTypes
                                    panel.message = "Select a book (PDF, EPUB, or DRM-free Kindle) to import"
                                }
                                guard let url = urls.first else { return }
                                do {
                                    try await vm.importBook(from: url.path)
                                } catch {
                                    vm.errorMessage = error.localizedDescription
                                    vm.showBookImportError = true
                                }
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
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(vm.bookImportStatus)
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
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }

            if sidebar.sidebarTab == .meetings, !showsMeetingsEmptyHelp {
                Section {
                    HStack(spacing: 8) {
                        Button(action: startGoogleDriveMeetingImport) {
                            Label(
                                isGoogleDriveSignedIn
                                    && !hasGoogleDriveFolderReadAccess
                                    ? "Reconnect Google Drive…"
                                    : "Add Meeting Folder…",
                                systemImage: "folder.badge.plus"
                            )
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue.opacity(0.8))
                        .controlSize(.small)
                        .disabled(isGoogleDriveWorking)

                        // Followed the Zoom tab down here when the tabs merged:
                        // pasting a recording link is how one provider's
                        // sessions arrive, not a place of its own.
                        Button {
                            alertText = ""
                            zoomPasscodeText = ""
                            activeAlert = .addZoomRecording
                        } label: {
                            Label("Add Recording…", systemImage: "video.badge.plus")
                                .font(.subheadline.weight(.medium))
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
    private var meetingsEmptyHelp: some View {
        ContentUnavailableView {
            VStack(spacing: 10) {
                Image("MeetingsIcon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                Text("No meetings yet")
                    .font(.headline)
            }
        } description: {
            VStack(spacing: 8) {
                Text(
                    isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                        ? "Reconnect to read the files inside this meeting folder."
                        : isGoogleDriveSignedIn
                        ? "Choose the folder that contains your meeting recordings and transcripts."
                        : "Connect Google Drive, or import a folder of recordings from this Mac."
                )
                HStack(spacing: 6) {
                    ForEach(MeetingProvider.allCases) { provider in
                        MeetingProviderMark(provider: provider, size: 13)
                    }
                    Text("Google Drive, Read AI, Zoom, and local folders all land here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button(
                isGoogleDriveSignedIn && !hasGoogleDriveFolderReadAccess
                    ? "Reconnect Google Drive"
                    : (isGoogleDriveSignedIn ? "Choose Meeting Folder" : "Connect Google Drive"),
                action: startGoogleDriveMeetingImport
            )
            .buttonStyle(.borderedProminent)
            .disabled(isGoogleDriveWorking)

            if isGoogleDriveWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func startGoogleDriveMeetingImport() {
        guard !isGoogleDriveWorking else { return }
        isGoogleDriveWorking = true
        Task {
            defer { isGoogleDriveWorking = false }
            do {
                try await vm.connectAndImportGoogleDriveMeetings()
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
        guard candidates.count == 1, let candidate = candidates.first else {
            presentBookDropError("Drop one book at a time.")
            return true
        }

        vm.bookImportStatus = "Opening dropped book…"
        switch candidate.1 {
        case .fileURL:
            loadDroppedBookURL(from: candidate.0)
        case .content(let typeIdentifier):
            loadDroppedBookFileRepresentation(from: candidate.0, typeIdentifier: typeIdentifier)
        }
        return true
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
        vm.bookImportStatus = ""
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
        if !activeItems.isEmpty || hasGroupedContent {
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
                        .onDelete { offsets in
                            requestSourceRemoval(Set(offsets.map { processingVideos[$0].id }))
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
                        let itemIds = Set(items.map(\.id))
                        // A book cover stands in for all of its chapters. Give
                        // List the concrete chapter the book should resume so
                        // native selection opens a real source instead of using
                        // the enclosing ForEach's group-name identity. A search
                        // or metadata filter can match a book's own record while
                        // none of its chapters match, so fall back to the
                        // unfiltered chapter list before that identity: a row
                        // tagged with a group name can never open anything.
                        let selectionID = vm.resumeBookChapter(for: groupName)?.id
                            ?? items.first?.id
                            ?? vm.bookSourceArticles(for: groupName).first?.id
                            ?? groupName
                        // The hover lives in its own view, so the cover's +
                        // can show under the pointer without re-running this body.
                        NotebookHoverRow(isActive: sidebarNotebook != nil) { isHovered in
                            courseOrBookGroupLabel(
                                groupName: groupName,
                                itemCount: itemCount,
                                notebookRowHovered: isHovered,
                                notebookRowTag: selectionID
                            )
                        }
                        .tag(selectionID)
                        .contentShape(Rectangle())
                        .onDrop(of: [.studioArticle, .studioGroup] + supportedBookImportDropTypes, isTargeted: nil) { providers in
                            handleGroupedCollectionDrop(providers, groupName: groupName)
                        }
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            openBookGroupFromRowClick(selectionID)
                        })
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
                        .listRowBackground(!windowState.sidebarSelectedSourceIDs.isDisjoint(with: itemIds) ? Color.accentColor.opacity(0.14) : Color.clear)
                    } else {
                        DisclosureGroup(isExpanded: sidebarGroupExpansionBinding(
                            groupName: groupName,
                            items: items
                        )) {
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
                        } label: {
                            expandableGroupLabel(groupName: groupName, itemCount: itemCount)
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
                        .onDelete { offsets in
                            requestSourceRemoval(Set(offsets.map { processing[$0].id }))
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
                        .onDelete { offsets in
                            requestSourceRemoval(Set(offsets.map { available[$0].id }))
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
                            .onDelete { offsets in
                                requestSourceRemoval(Set(offsets.map { withoutPDF[$0].id }))
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
                        .onDelete { offsets in
                            requestSourceRemoval(Set(offsets.map { withPDF[$0].id }))
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
                            .onDelete { offsets in
                                requestSourceRemoval(Set(offsets.map { paywalled[$0].id }))
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
                    .onDelete { offsets in
                        requestSourceRemoval(Set(offsets.map { activeItems[$0].id }))
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

    /// A collection row's label. A book cover also carries the notebook mark
    /// while the list marks one: `notebookRowHovered` shows its +, and a press
    /// on it claims `notebookRowTag`, the chapter the cover opens. The count of
    /// a series or playlist shows only while `countRevealed` (the pointer is
    /// over the row): a column of numbers down the list was noise
    /// (product owner, 2026-10-06, "kind of like the chatgpt app"; ChatGPT's rows
    /// carry no counts).
    @ViewBuilder
    private func courseOrBookGroupLabel(
        groupName: String,
        itemCount: Int,
        notebookRowHovered: Bool = false,
        notebookRowTag: String? = nil,
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
                // A cover stands for its chapters (the ids its drag carries),
                // so it can be partly in the notebook.
                if let notebook = sidebarNotebook {
                    let chapterIDs = vm.sourceIDsForGroupInOrder(groupName)
                    NotebookMembershipMark(
                        sourceIDs: chapterIDs,
                        notebook: notebook,
                        isRowHovered: notebookRowHovered,
                        rowControlIDs: chapterIDs + [notebookRowTag ?? groupName]
                    )
                    .fixedSize()
                }
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
    /// List's selection menu: a book row is tagged with its resume chapter, so
    /// without this a right-click there could surface chapter actions instead
    /// of Hide Book and Remove Book.
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
            Button(role: .destructive) {
                activeAlert = .deleteBook(groupName)
            } label: {
                Label("Remove Book", systemImage: "trash")
            }
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
    @ViewBuilder
    private func meetingSessionRow(_ article: StudioArticle, groupName: String) -> some View {
        let artifacts = (vm.meetingArtifactsBySourceId[article.id] ?? [])
            .sorted { ($0.kind.sortRank, $0.sortIndex) < ($1.kind.sortRank, $1.sortIndex) }
        let sessionKey = "meeting-session:\(article.id)"

        if artifacts.isEmpty {
            groupedCollectionArticleRow(article, groupName: groupName)
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { sidebar.expandedGroups.contains(sessionKey) },
                set: { isExpanded in
                    if isExpanded {
                        sidebar.expandedGroups.insert(sessionKey)
                    } else {
                        sidebar.expandedGroups.remove(sessionKey)
                    }
                }
            )) {
                MeetingArtifactStack {
                    ForEach(artifacts) { artifact in
                        MeetingArtifactRow(artifact: artifact)
                    }
                }
            } label: {
                groupedCollectionArticleRow(article, groupName: groupName)
            }
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

        return ArticleRow(article: displayArticle, metadataVisibility: metadataVisibility, notebook: sidebarNotebook)
            .tag(article.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    requestSourceRemoval([article.id])
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                openSidebarArticleFromRowClick(article.id)
            })
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
    }

    /// A source's row: its selection tag, the swipe to remove, click-to-open,
    /// the paper PDF drop target, and the drag that carries it to a chat, a
    /// Notebook or another window. A source's explainer, when it has one, is an
    /// ordinary source in storage but has no row in the sidebar at all
    /// (explainer-design.md): it is read from the source's Explain button or
    /// its context menu.
    private func articleRow(_ article: StudioArticle) -> some View {
        ArticleRow(article: article, metadataVisibility: metadataVisibility, notebook: sidebarNotebook)
            .tag(article.id)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    requestSourceRemoval([article.id])
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                openSidebarArticleFromRowClick(article.id)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                openSidebarArticleFromDoubleClick(article.id)
            })
            // A group of its own for the help, as in the playlist row above.
            .accessibilityElement(children: .contain)
            .help(sidebarArticleInteractionHelp)
            .modifier(PaperPDFDropTargetModifier(article: article))
            .modifier(sourceRowDragModifier(for: article))
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

    /// Whether the List selection change being handled came from the mouse
    /// pressing a row. The binding setter runs synchronously inside AppKit's
    /// handling of that event, so the current event is the press itself. Arrow
    /// keys and programmatic writes arrive under some other event, or none.
    private var isSidebarSelectionFromMousePress: Bool {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged: true
        default: false
        }
    }

    /// The press that selected a row ended without becoming a drag: open now.
    /// The row's own tap gesture usually fires for the same mouse-up and is
    /// coalesced by `openSidebarArticle`; this path covers the presses that
    /// gesture never sees, such as the row's vertical inset.
    ///
    /// The selection the press made waits here too, and both stand down when
    /// the press turned out to be a row control's (`SidebarRowControlPress`):
    /// its note may land after AppKit's mouse-down selection write, never
    /// after the mouse-up.
    func completeDeferredSidebarOpenOnMouseUp() {
        guard let sourceID = deferredSidebarOpenSourceID else { return }
        let selection = deferredSidebarSelection
        deferredSidebarOpenSourceID = nil
        deferredSidebarSelection = nil
        guard !SidebarRowControlPress.claims(sourceID) else { return }
        if let selection { windowState.sidebarSelectedSourceIDs = selection }
        guard !dragVisibility.isDragging else { return }
        openSidebarArticleFromSingleClick(sourceID)
    }

    /// The press that became a drag is not a click: it must not open the row
    /// on mouse-up. The selection it made stays, as it does in every macOS
    /// list, unless the press was a row control's; a multi-selection it
    /// started from stays whole (AppKit leaves it so on mouse-down).
    func keepDeferredSidebarSelectionForDrag() {
        let sourceID = deferredSidebarOpenSourceID
        let selection = deferredSidebarSelection
        deferredSidebarOpenSourceID = nil
        deferredSidebarSelection = nil
        guard let sourceID, let selection, !SidebarRowControlPress.claims(sourceID) else { return }
        windowState.sidebarSelectedSourceIDs = selection
    }

    /// List selection is navigation on the first click in every center layout.
    /// Shift-click stays selection-only for the explicit multi-select path.
    private func openSidebarArticleFromSingleClick(_ sourceID: String) {
        guard vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(sourceID)
    }

    /// Treat the visible row as the authoritative click target. AppKit may send
    /// the row gesture without updating native List selection when the pointer is
    /// over row whitespace, an embedded control, an already-selected row, or a
    /// newly inserted row. Opening here makes the visual hit area and the actual
    /// selection area identical; `openSidebarArticle` coalesces the ordinary List
    /// callback when AppKit sends both.
    private func openSidebarArticleFromRowClick(_ sourceID: String) {
        guard vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(sourceID)
    }

    /// A habitual second click must not start the same async open twice.
    private func openSidebarArticleFromDoubleClick(_ sourceID: String) {
        guard !vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(sourceID)
    }

    /// A book cover is a click target like any other row: opening it opens the
    /// chapter the row is tagged with. Gating this on the cover already being
    /// selected left the click dead whenever AppKit sent the row gesture without
    /// updating native List selection — over row whitespace, a newly inserted
    /// row — because the selection binding, the only other opener, never ran.
    /// `openSidebarArticle` coalesces the duplicate when AppKit sends both.
    private func openBookGroupFromRowClick(_ resumeSourceID: String) {
        guard vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(resumeSourceID)
    }

    private func openBookGroupFromDoubleClick(_ resumeSourceID: String) {
        guard !vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(resumeSourceID)
    }

    private func openSidebarArticle(_ sourceID: String) {
        // The row's tap gesture, and the deferred mouse-up open, also see a
        // click on a control inside the row; that click was the control's.
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
    /// AppKit has already made a row outside the selection the selection on
    /// mouse-down, so the highlight matches what is being dragged either way.
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

/// Fires refresh callbacks when the user reaches or pulls past the top of the List
/// that this view backs. SwiftUI's `.refreshable` has no scroll-driven trigger on
/// macOS, so we observe the underlying `NSScrollView`'s clip-view bounds. The view
/// is invisible and sits behind the List, so it never intercepts clicks; it just
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

        /// Legacy mouse wheels report no phases, but they also can't rubber-band, so
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
        /// backing view's center — i.e. the List we're behind, ignoring any other
        /// scroll views elsewhere in the window.
        private func locateScrollView() -> NSScrollView? {
            guard let root = window?.contentView else { return nil }
            let frameInWindow = convert(bounds, to: nil)
            guard frameInWindow.width > 0, frameInWindow.height > 0 else { return nil }
            let center = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
            var match: NSScrollView?
            func walk(_ view: NSView) {
                if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView {
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
            NSWorkspace.shared.open(url)
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
    /// contract Settings → Plugins → Build Your Own copies, opening with a
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
        case .openPluginSettings, .showPluginStatus:
            NotificationCenter.default.post(
                name: .requestOpenStudioSettings,
                object: SettingsPane.userPlugins
            )
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
