// The source sidebar's drop overlays and article rows.
import SwiftUI
import AppKit

extension StudioSidebar {
    // MARK: - File Drop Overlays

    var booksDropOverlay: some View {
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

    var papersDropOverlay: some View {
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

    func groupedCollectionArticleRow(_ article: StudioArticle, groupName: String) -> some View {
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
    func meetingSessionRow(
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
    func articleRow(_ article: StudioArticle, showsMeetingSeries: Bool = false) -> some View {
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

    var sidebarArticleInteractionHelp: String {
        vm.opensSidebarSourcesOnSingleClick
            ? "Click to open; drag to move"
            : "Double-click to open; drag to move"
    }

    /// A plain click or an arrow key opens the row when the Library opens
    /// sources on a single click.
    func openSidebarArticleFromRowClick(_ sourceID: String) {
        guard vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(sourceID)
    }

    /// A habitual second click must not start the same async open twice.
    private func openSidebarArticleFromDoubleClick(_ sourceID: String) {
        guard !vm.opensSidebarSourcesOnSingleClick else { return }
        openSidebarArticle(sourceID)
    }

    func openBookGroupFromDoubleClick(_ resumeSourceID: String) {
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
