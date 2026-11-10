// The source sidebar's article sections and paper batch buttons.
import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension StudioSidebar {
    @ViewBuilder
    var sidebarArticlesSections: some View {
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
}
