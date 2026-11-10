// The source sidebar's tab bar: tab buttons, overflow menu and context menus.
import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension StudioSidebar {
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
    func sourceFilterBinding<F: Equatable>(
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
}
