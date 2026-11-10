// The source sidebar's search row, banners and lazy source list.
import SwiftUI
import AppKit

extension StudioSidebar {
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
    func bookRowSelectionID(groupName: String, items: [StudioArticle]) -> String {
        vm.resumeBookChapter(for: groupName)?.id
            ?? items.first?.id
            ?? vm.bookSourceArticles(for: groupName).first?.id
            ?? groupName
    }

    /// A series' or playlist's row in the list: a chevron, its label, a click
    /// anywhere on it folding it open or shut. Its rows follow it as rows of
    /// the same lazy list rather than inside a `DisclosureGroup`, whose content
    /// is built whole the moment it opens.
    func lazyGroupHeader(groupName: String, items: [StudioArticle], itemCount: Int) -> some View {
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
    func handleLazyRowClick(_ sourceID: String) {
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
    func lazyRowContextMenu(for sourceID: String) -> some View {
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
}
