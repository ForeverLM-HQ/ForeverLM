import SwiftUI

// MARK: - Chip Flow Layout

/// Left-aligned wrapping layout for filter chips.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxRowWidth = max(maxRowWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? maxRowWidth : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Filter Chip

/// A removable capsule chip shown under the search bar while a filter is active.
struct ActiveFilterChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverWash(in: Capsule()))
        .help("Remove this filter")
    }
}

// MARK: - Hidden Items Model

/// View-layer snapshot of everything hidden on the current sidebar tab, in a
/// shape shared by all tabs: hidden groups (shows, courses, books, playlists)
/// that may expose per-episode overrides, plus individually hidden items.
/// A source, and a hidden book, opens in the Reader from its row and stays
/// hidden; Unhide is the row's second action.
struct HiddenItemsModel {
    struct ItemEntry: Identifiable {
        let id: String
        let title: String
        let unhide: () async -> Void
        /// Removes the item from the library; nil when the row is unhide-only.
        let remove: (() async -> Void)?
        /// Opens the item in the Reader, still hidden; nil when it has nothing to open.
        var open: (() async -> Void)? = nil
    }

    struct GroupEntry: Identifiable {
        let id: String
        let title: String
        /// Hidden child items grouped beneath this row.
        let hiddenEpisodes: [ItemEntry]
        /// Unhides the group itself, or every hidden item under it when the
        /// group is not hidden and only collects them; nil when neither applies.
        let unhide: (() async -> Void)?
        /// What the group's unhide button says: "Unhide" for a hidden group,
        /// "Show all" when it reveals the items beneath instead.
        var unhideTitle = "Unhide"
        /// The row's leading glyph when the group has no items under it. A
        /// blocked show is not hidden — it was never imported — so it says so
        /// rather than borrowing the eye.
        var icon = "eye.slash"
        /// Removes the whole group from the library; nil when the row is
        /// unhide-only.
        let remove: (() async -> Void)?
        /// Opens the group in the Reader, still hidden, as a book opens from
        /// the Books list; nil for a group that is a folder of things (a show,
        /// a channel, a playlist, a meeting group).
        var open: (() async -> Void)? = nil
    }

    let groupsTitle: String
    let itemsTitle: String
    let groups: [GroupEntry]
    let items: [ItemEntry]

    var isEmpty: Bool { groups.isEmpty && items.isEmpty }
    var searchableCount: Int {
        groups.count + items.count + groups.reduce(0) { $0 + $1.hiddenEpisodes.count }
    }

    /// How many rows the page would show for `query`: groups whose title or
    /// any hidden child matches, plus matching items. The same rule the page's
    /// own filter applies, so the footer's count and the page agree.
    func matchCount(for query: String) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return searchableCount }
        let groupMatches = groups.filter { group in
            group.title.localizedCaseInsensitiveContains(trimmed)
                || group.hiddenEpisodes.contains { $0.title.localizedCaseInsensitiveContains(trimmed) }
        }.count
        let itemMatches = items.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }.count
        return groupMatches + itemMatches
    }

    /// Whether `group` is in the list for `query` only because one of its
    /// hidden episodes matches, its own title not matching. The page opens
    /// such a group, since the row the search found is the one beneath it.
    func matchesOnlyThroughEpisodes(_ group: GroupEntry, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !group.title.localizedCaseInsensitiveContains(trimmed) else { return false }
        return group.hiddenEpisodes.contains { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    /// The hidden episodes `group` lists for `query`: all of them when there
    /// is no query or the group's own title matches, otherwise only those the
    /// query found, so an expanded match is not buried among its siblings.
    func episodes(of group: GroupEntry, matching query: String) -> [ItemEntry] {
        guard matchesOnlyThroughEpisodes(group, query: query) else { return group.hiddenEpisodes }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return group.hiddenEpisodes.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    /// The nouns a tab's footer counts in: the grouping a whole collection is
    /// hidden by, and the single thing hidden on its own.
    static func footerNouns(for tab: StudioSidebarTab) -> (group: String?, item: String) {
        switch tab {
        case .podcasts: return ("show", "episode")
        case .videos: return ("channel or playlist", "video")
        case .books: return ("book", "chapter")
        case .meetings: return ("meeting group", "session")
        case .papers: return (nil, "paper")
        case .articles: return (nil, "article")
        default: return (nil, "source")
        }
    }

    /// "3 hidden shows", "1 hidden show, 2 episodes", "2 hidden episodes".
    /// Empty when nothing is hidden, so the caller can drop the row.
    static func footerTitle(groupCount: Int, groupNoun: String?, itemCount: Int, itemNoun: String) -> String {
        func plural(_ noun: String, _ count: Int) -> String {
            guard count != 1 else { return noun }
            if noun.hasSuffix(" or playlist") { return noun.replacingOccurrences(of: " or playlist", with: "s or playlists") }
            return noun + "s"
        }
        switch (groupCount > 0 ? groupNoun : nil, itemCount > 0) {
        case (let group?, true):
            return "\(groupCount) hidden \(plural(group, groupCount)), \(itemCount) \(plural(itemNoun, itemCount))"
        case (let group?, false):
            return "\(groupCount) hidden \(plural(group, groupCount))"
        case (nil, true):
            return "\(itemCount) hidden \(plural(itemNoun, itemCount))"
        case (nil, false):
            return ""
        }
    }

    /// What the footer and its page may name while Screen record mode is on
    /// (`ScreenRecordScope`): only what the take may show, as the list above
    /// them does. A hidden source is named when `isVisibleInRecordingMode`
    /// lets it through; a hidden show, channel, playlist, book or meeting
    /// folder, or a blocked show, only while it holds a source the take may
    /// show, since its name is the learner's own even when everything in it
    /// is filtered out (`visibleMeetingGroupNames` keeps a meeting folder the
    /// same way). Off the take everything hidden is named.
    private struct RecordingFilter {
        private struct Shown {
            var sourceIDs: Set<String> = []
            /// Shows by name; books, playlists and meeting folders by group id.
            var groups: Set<String> = []
            var channels: [String] = []
        }

        /// What of the tab the take may show, hidden or not; nil off the take.
        private let shown: Shown?

        @MainActor
        init(tab: StudioSidebarTab, vm: StudioViewModel) {
            guard vm.isScreenRecordModeActive else {
                shown = nil
                return
            }
            var shown = Shown()
            for article in vm.activeArticles
            where vm.sourceBelongsToTab(article, tab: tab) && vm.isVisibleInRecordingMode(article) {
                shown.sourceIDs.insert(article.id)
                switch tab {
                case .podcasts:
                    shown.groups.insert(article.domain)
                case .meetings:
                    if let group = article.parentGroup { shown.groups.insert(vm.canonicalMeetingGroupID(group)) }
                default:
                    if let group = article.parentGroup { shown.groups.insert(group) }
                }
                if tab == .videos, article.isYouTubeURL, let channel = vm.videoChannelName(for: article) {
                    shown.channels.append(channel)
                }
            }
            self.shown = shown
        }

        func admits(_ article: StudioArticle) -> Bool {
            shown?.sourceIDs.contains(article.id) ?? true
        }

        func admitsGroup(_ group: String) -> Bool {
            shown?.groups.contains(group) ?? true
        }

        func admitsChannel(_ channel: String) -> Bool {
            shown?.channels.contains { $0.localizedCaseInsensitiveCompare(channel) == .orderedSame } ?? true
        }
    }

    /// Hidden groups and lone items for `tab`, counted the way the footer
    /// reads them out.
    @MainActor
    static func footerCounts(for tab: StudioSidebarTab, vm: StudioViewModel) -> (groups: Int, items: Int) {
        let shown = RecordingFilter(tab: tab, vm: vm)
        switch tab {
        case .podcasts:
            // A show being removed is blocked for its Undo window too; the
            // banner owns it until then, not this footer.
            let shows = Set(vm.hiddenPodcastShowNames).union(vm.blockedPodcastShows.filter {
                !vm.hasPendingDeletion(forDeletionKey: StudioViewModel.podcastShowRemovalKey($0))
            })
            return (shows.filter(shown.admitsGroup).count, vm.hiddenPodcastEpisodeArticles.filter(shown.admits).count)
        case .books:
            return (
                vm.hiddenBookGroupNames.filter(shown.admitsGroup).count,
                vm.hiddenBookChapterArticles.filter(shown.admits).count
            )
        case .videos:
            return (
                vm.hiddenVideoPlaylistGroupNames.filter(shown.admitsGroup).count
                    + vm.hiddenYouTubeChannelNames.filter(shown.admitsChannel).count,
                vm.hiddenSourceArticles(for: .videos).filter(shown.admits).count
            )
        case .meetings:
            return (
                vm.hiddenMeetingGroupNames.filter(shown.admitsGroup).count,
                vm.hiddenSourceArticles(for: tab).filter(shown.admits).count
            )
        default:
            return (0, vm.hiddenSourceArticles(for: tab).filter(shown.admits).count)
        }
    }

    /// `windowState` is the window whose Reader a row opens in; nil is the
    /// key window.
    @MainActor
    static func build(
        for tab: StudioSidebarTab,
        vm: StudioViewModel,
        in windowState: StudioWindowState? = nil
    ) -> HiddenItemsModel {
        let shown = RecordingFilter(tab: tab, vm: vm)
        func opening(_ sourceID: String) -> () async -> Void {
            { await vm.openHiddenSource(sourceID, in: windowState) }
        }
        switch tab {
        case .podcasts:
            let hiddenShowNames = Set(vm.hiddenPodcastShowNames)
            let blockedShowNames = vm.blockedPodcastShows.filter {
                !vm.hasPendingDeletion(forDeletionKey: StudioViewModel.podcastShowRemovalKey($0))
            }
            let individuallyHiddenEpisodes = Dictionary(
                grouping: vm.hiddenPodcastEpisodeArticles.filter(shown.admits),
                by: \.domain
            )
            // A blocked show usually has nothing under it — that is the point of
            // blocking — so it would appear nowhere if the list were built from
            // rows alone, and the learner would have no way to let it back in.
            let showNames = hiddenShowNames
                .union(individuallyHiddenEpisodes.keys)
                .union(blockedShowNames)
                .filter(shown.admitsGroup)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            return HiddenItemsModel(
                groupsTitle: "Shows",
                itemsTitle: "Episodes",
                groups: showNames.map { showName in
                    let isShowHidden = hiddenShowNames.contains(showName)
                    let isShowBlocked = blockedShowNames.contains(showName)
                    let episodes = (
                        isShowHidden
                            ? vm.hiddenPodcastEpisodes(forShow: showName)
                            : individuallyHiddenEpisodes[showName, default: []]
                    )
                    .filter(shown.admits)
                    .sorted(by: vm.podcastEpisodeMenuOrder)
                    // Blocked wins the button: a show that is both was removed,
                    // and unhiding it without importing it again would hand back
                    // an empty row. Written out rather than nested in a ternary
                    // so the optional closure type stays inferable.
                    let unhideShow: (() async -> Void)?
                    if isShowBlocked {
                        unhideShow = {
                            if isShowHidden {
                                await vm.setPodcastShowHidden(showName, hidden: false)
                            }
                            await vm.unblockPodcastShow(showName)
                        }
                    } else if isShowHidden {
                        unhideShow = { await vm.setPodcastShowHidden(showName, hidden: false) }
                    } else if episodes.isEmpty {
                        unhideShow = nil
                    } else {
                        unhideShow = { await vm.revealPodcastEpisodes(episodes.map(\.id)) }
                    }
                    return GroupEntry(
                        id: showName,
                        title: showName.isEmpty ? "Unknown Show" : showName,
                        hiddenEpisodes: episodes.map { episode in
                            ItemEntry(
                                id: episode.id,
                                title: episode.title,
                                unhide: {
                                    if isShowHidden {
                                        await vm.setPodcastEpisodeVisibleOverride(episode.id, visible: true)
                                    } else {
                                        await vm.setPodcastEpisodeHidden(episode.id, hidden: false)
                                    }
                                },
                                remove: { await vm.removeSelected([episode.id]) },
                                open: opening(episode.id)
                            )
                        },
                        unhide: unhideShow,
                        unhideTitle: isShowBlocked
                            ? "Import Again"
                            : isShowHidden ? "Unhide" : "Show all",
                        icon: isShowBlocked && !isShowHidden ? "nosign" : "eye.slash",
                        remove: isShowHidden
                            ? { await vm.removeHiddenPodcastShow(showName) }
                            : nil
                    )
                },
                items: []
            )
        case .meetings:
            return HiddenItemsModel(
                groupsTitle: "Meeting Groups",
                itemsTitle: "Sessions",
                groups: vm.hiddenMeetingGroupNames.filter(shown.admitsGroup).map { groupName in
                    GroupEntry(
                        id: groupName,
                        title: vm.meetingDisplayName(groupName),
                        hiddenEpisodes: [],
                        // A group is listed here because it was hidden, or
                        // because a removal was interrupted before it finished
                        // and left it hidden. One still inside its Undo window
                        // is not listed — the banner is its affordance. Unhiding
                        // unarchives the sessions too: a removal can leave them
                        // archived, and a group that came back without them would
                        // come back empty.
                        unhide: { await vm.restoreMeetingGroup(groupName) },
                        // Delete for good, sessions included — the same path the
                        // sidebar's Delete takes once its Undo window closes.
                        remove: { await vm.removeMeetingGroup(name: groupName) }
                    )
                },
                items: vm.hiddenSourceArticles(for: tab).filter(shown.admits).map { article in
                    unhideEntry(for: article, vm: vm, open: opening(article.id))
                }
            )
        case .books:
            return HiddenItemsModel(
                groupsTitle: "Books",
                itemsTitle: "Chapters",
                // A hidden book opens as a book does, and lists its chapters
                // beneath, each one opening on its own; Show brings one
                // chapter back into the Books list, Unhide the whole book.
                groups: vm.hiddenBookGroupNames.filter(shown.admitsGroup).map { groupName in
                    GroupEntry(
                        id: groupName,
                        title: vm.bookDisplayName(groupName),
                        hiddenEpisodes: vm.bookChapterArticlesInOrder(for: groupName).filter(shown.admits).map { chapter in
                            ItemEntry(
                                id: chapter.id,
                                title: chapter.title,
                                unhide: { await vm.setSourceHidden(chapter.id, hidden: false) },
                                remove: { await vm.removeSelected([chapter.id]) },
                                open: opening(chapter.id)
                            )
                        },
                        unhide: { await vm.setBookHidden(groupName, hidden: false) },
                        remove: nil,
                        open: { await vm.openHiddenBook(groupName, in: windowState) }
                    )
                },
                items: vm.hiddenBookChapterArticles.filter(shown.admits).map { article in
                    ItemEntry(
                        id: article.id,
                        title: article.title,
                        unhide: { await vm.setSourceHidden(article.id, hidden: false) },
                        remove: { await vm.removeSelected([article.id]) },
                        open: opening(article.id)
                    )
                }
            )
        case .videos:
            let playlistGroups = vm.hiddenVideoPlaylistGroupNames.filter(shown.admitsGroup).map { groupName in
                GroupEntry(
                    id: "playlist:\(groupName)",
                    title: vm.videoPlaylistDisplayName(groupName),
                    hiddenEpisodes: [],
                    unhide: { await vm.setVideoPlaylistHidden(groupName, hidden: false) },
                    remove: nil
                )
            }
            let channelGroups = vm.hiddenYouTubeChannelNames.filter(shown.admitsChannel).map { channelName in
                GroupEntry(
                    id: "channel:\(channelName)",
                    title: channelName,
                    hiddenEpisodes: vm.hiddenYouTubeVideos(forChannel: channelName).filter(shown.admits).map { video in
                        ItemEntry(
                            id: video.id,
                            title: video.title,
                            unhide: { await vm.setYouTubeVideoVisibleOverride(video.id, visible: true) },
                            remove: { await vm.removeSelected([video.id]) },
                            open: opening(video.id)
                        )
                    },
                    unhide: { await vm.setYouTubeChannelHidden(channelName, hidden: false) },
                    remove: nil
                )
            }
            return HiddenItemsModel(
                groupsTitle: "Channels & Playlists",
                itemsTitle: "Videos",
                groups: channelGroups + playlistGroups,
                items: vm.hiddenSourceArticles(for: .videos).filter(shown.admits).map { article in
                    unhideEntry(for: article, vm: vm, open: opening(article.id))
                }
            )
        default:
            return HiddenItemsModel(
                groupsTitle: "Groups",
                itemsTitle: "Items",
                groups: [],
                items: vm.hiddenSourceArticles(for: tab).filter(shown.admits).map { article in
                    unhideEntry(for: article, vm: vm, open: opening(article.id))
                }
            )
        }
    }

    @MainActor
    private static func unhideEntry(
        for article: StudioArticle,
        vm: StudioViewModel,
        open: @escaping () async -> Void
    ) -> ItemEntry {
        ItemEntry(
            id: article.id,
            title: article.title,
            unhide: {
                if article.sourceType == .podcast {
                    await vm.setPodcastEpisodeHidden(article.id, hidden: false)
                } else {
                    await vm.setSourceHidden(article.id, hidden: false)
                }
            },
            remove: { await vm.removeSelected([article.id]) },
            open: open
        )
    }
}

// MARK: - Hidden Items Page

/// Searchable list of hidden groups and items with unhide actions. Expands
/// under the `HiddenItemsFooter` at the bottom of a sources list (`isInline`),
/// or stands as a page of its own; `onBack` is for a
/// host that stacks it behind another page, and nil draws no back control.
/// Clicking a row that can open (a source, a book) reads it in the Reader and
/// closes the list; it stays hidden.
struct HiddenItemsPage: View {
    let model: HiddenItemsModel
    let onBack: (() -> Void)?
    /// Drawn straight into a list under its footer: every hidden group and
    /// item as rows of that list, which scrolls them, with no header, no
    /// height cap of its own, and no dismissing on open (there is no popover).
    let isInline: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    /// Groups the user opened or closed by hand, over the default that opens a
    /// group the search reached only through its episodes. Cleared when the
    /// query changes, since the default changes with it.
    @State private var expansionOverrides: [String: Bool] = [:]
    /// Measured height of the list, so the popover can follow it. A popover
    /// sizes its content once when it opens; a `ScrollView` left to size
    /// itself never asks it to grow, so expanding a group would draw the
    /// episodes below the popover's edge.
    @State private var listHeight: CGFloat?
    /// The list scrolls once it is taller than this.
    private let maxListHeight: CGFloat = 360

    init(model: HiddenItemsModel, initialQuery: String = "", isInline: Bool = false, onBack: (() -> Void)? = nil) {
        self.model = model
        self.onBack = onBack
        self.isInline = isInline
        _query = State(initialValue: initialQuery)
    }

    private var filteredGroups: [HiddenItemsModel.GroupEntry] {
        guard !trimmedQuery.isEmpty else { return model.groups }
        return model.groups.filter { group in
            group.title.localizedCaseInsensitiveContains(trimmedQuery)
                || group.hiddenEpisodes.contains {
                    $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                }
        }
    }

    private var filteredItems: [HiddenItemsModel.ItemEntry] {
        guard !trimmedQuery.isEmpty else { return model.items }
        return model.items.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isExpanded(_ group: HiddenItemsModel.GroupEntry) -> Bool {
        expansionOverrides[group.id] ?? model.matchesOnlyThroughEpisodes(group, query: trimmedQuery)
    }

    var body: some View {
        if isInline {
            inlineRows
        } else {
            popoverBody
        }
    }

    /// The rows themselves, as rows of the list the footer ends: the search
    /// field when there are many, then the groups and the lone items.
    @ViewBuilder
    private var inlineRows: some View {
        if model.searchableCount > 8 || !query.isEmpty {
            searchField
                .padding(.bottom, 4)
        }
        if !filteredGroups.isEmpty {
            sectionHeader(model.groupsTitle)
            ForEach(filteredGroups) { group in
                groupRow(group)
            }
        }
        if !filteredItems.isEmpty {
            sectionHeader(model.itemsTitle)
            ForEach(filteredItems) { item in
                itemRow(item, indented: false)
            }
        }
        if filteredGroups.isEmpty && filteredItems.isEmpty && !model.isEmpty {
            Text("No matches")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search hidden items", text: $query)
                .textFieldStyle(.plain)
                .font(.subheadline)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash)
                    .help("Back to filters")
                }
                Text("Hidden Items")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.leading, onBack == nil ? 14 : 10)
            .padding(.trailing, 10)
            .padding(.top, 10)

            if model.searchableCount > 8 || !query.isEmpty {
                searchField
            }

            if model.isEmpty {
                Text("Nothing is hidden")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !filteredGroups.isEmpty {
                            sectionHeader(model.groupsTitle)
                            ForEach(filteredGroups) { group in
                                groupRow(group)
                            }
                        }
                        if !filteredItems.isEmpty {
                            sectionHeader(model.itemsTitle)
                            ForEach(filteredItems) { item in
                                itemRow(item, indented: false)
                            }
                        }
                        if filteredGroups.isEmpty && filteredItems.isEmpty {
                            Text("No matches")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                    .padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: listHeight.map { min($0, maxListHeight) })
            }
        }
        .padding(.bottom, 4)
        .onChange(of: trimmedQuery) { expansionOverrides = [:] }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func groupRow(_ group: HiddenItemsModel.GroupEntry) -> some View {
        let episodes = model.episodes(of: group, matching: trimmedQuery)
        let isExpanded = isExpanded(group)
        HStack(spacing: 6) {
            if episodes.isEmpty {
                Image(systemName: group.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            } else {
                Button {
                    expansionOverrides[group.id] = !isExpanded
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverWash)
                .help(isExpanded ? "Hide the \(model.itemsTitle.lowercased())" : "Show the hidden \(model.itemsTitle.lowercased())")
            }

            rowTitle(group.title, font: .subheadline, style: .primary, open: group.open)

            if let unhide = group.unhide {
                unhideButton(title: group.unhideTitle) {
                    await unhide()
                }
            }
            if let remove = group.remove {
                removeButton(help: "Remove \(group.title) and all its items", action: remove)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)

        if isExpanded {
            ForEach(episodes) { episode in
                itemRow(episode, indented: true, actionTitle: "Show")
            }
        }
    }

    private func itemRow(
        _ item: HiddenItemsModel.ItemEntry,
        indented: Bool,
        actionTitle: String = "Unhide"
    ) -> some View {
        HStack(spacing: 6) {
            rowTitle(
                item.title,
                font: indented ? .caption : .subheadline,
                style: indented ? .secondary : .primary,
                open: item.open
            )
            unhideButton(title: actionTitle) {
                await item.unhide()
            }
            if let remove = item.remove {
                removeButton(help: "Remove from library", action: remove)
            }
        }
        .padding(.leading, indented ? 38 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
    }

    /// A row's title, filling the row up to its buttons. A row that opens
    /// something is a button that reads it in the Reader and closes the list.
    @ViewBuilder
    private func rowTitle(
        _ title: String,
        font: Font,
        style: HierarchicalShapeStyle,
        open: (() async -> Void)?
    ) -> some View {
        let label = Text(title)
            .font(font)
            .foregroundStyle(style)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let open {
            Button {
                if !isInline { dismiss() }
                Task { await open() }
            } label: {
                label
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 4, inset: -2))
            .help("Open in the Reader; it stays hidden")
        } else {
            label
        }
    }

    private func unhideButton(title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
    }

    private func removeButton(help: String, action: @escaping () async -> Void) -> some View {
        Button(role: .destructive) {
            Task { await action() }
        } label: {
            Image(systemName: "trash")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash)
        .help(help)
    }
}

// MARK: - Hidden Items Footer

/// The quiet last row of a sources list: how many of this tab's shows, groups
/// or sources are hidden, and the way back to them. Hidden things left the list
/// from here, so this is where they are found again, and the row is absent when
/// nothing is hidden. While the search field has text it says how many hidden
/// items match instead, so a search that comes up short because the thing was
/// hidden says so rather than looking like a miss; expanding the row then
/// carries the search along, and lists every hidden show, book or source
/// beneath it.
struct HiddenItemsFooter: View {
    let tab: StudioSidebarTab
    let searchText: String

    @Environment(StudioViewModel.self) private var vm
    /// The window a row opens its source in.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    /// The hidden things are listed under the row, all of them.
    @State private var isExpanded = false
    /// Hidden rows matching the search, or nil while no search is typed. Built
    /// off the main render path: the podcasts model walks every hidden show's
    /// episodes, which is not work for a body that re-runs on each keystroke.
    @State private var matchCount: Int?

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let counts = HiddenItemsModel.footerCounts(for: tab, vm: vm)
        if counts.groups + counts.items > 0 {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Spacer()
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                    Text(title(counts: counts))
                        .font(.caption)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer()
                }
                .foregroundStyle(matchCount.map { $0 > 0 } == true ? Color.accentColor : Color.secondary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: -2))
            .help(isExpanded ? "Hide the hidden \(tab.rawValue)" : "Show what is hidden in \(tab.rawValue)")
            .accessibilityLabel("Hidden items")
            .accessibilityValue(title(counts: counts))
            .accessibilityAddTraits(.isButton)
            .task(id: "\(tab.rawValue)\u{1}\(trimmedQuery)") {
                guard !trimmedQuery.isEmpty else {
                    matchCount = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                matchCount = HiddenItemsModel.build(for: tab, vm: vm).matchCount(for: trimmedQuery)
            }
            if isExpanded {
                HiddenItemsPage(
                    model: HiddenItemsModel.build(for: tab, vm: vm, in: windowState),
                    initialQuery: trimmedQuery,
                    isInline: true
                )
            }
        }
    }

    private func title(counts: (groups: Int, items: Int)) -> String {
        if !trimmedQuery.isEmpty, let matchCount {
            switch matchCount {
            case 0: return "Nothing hidden matches"
            case 1: return "1 hidden item matches"
            default: return "\(matchCount) hidden items match"
            }
        }
        let nouns = HiddenItemsModel.footerNouns(for: tab)
        return HiddenItemsModel.footerTitle(
            groupCount: counts.groups,
            groupNoun: nouns.group,
            itemCount: counts.items,
            itemNoun: nouns.item
        )
    }
}

// MARK: - Customize Source Types

/// Every source type in tab-bar order, each with a pin checkmark, its icon and
/// a reorder handle: the one place a type is pinned, unpinned or moved. Opened
/// from the tab bar's ⋯ menu and from a tab's context menu. Pinning state is
/// `StudioViewModel.hiddenTabs`, the order `tabOrder`, so the tab bar, Settings
/// and the plugin auto-pin logic all see the same result.
struct SourceTypesCustomizePopover: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    /// The type being dragged by its handle, and the row it would take the slot
    /// of. The drop reads the first, as the tab bar does, because the pasteboard
    /// payload only resolves in a later callback.
    @State private var draggedTab: StudioSidebarTab?
    @State private var dropTarget: StudioSidebarTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Customize")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 3))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            VStack(spacing: 1) {
                ForEach(vm.tabOrder, id: \.self) { tab in
                    SourceTypeCustomizeRow(
                        tab: tab,
                        draggedTab: $draggedTab,
                        dropTarget: $dropTarget
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 260)
    }
}

private struct SourceTypeCustomizeRow: View {
    @Environment(StudioViewModel.self) private var vm
    let tab: StudioSidebarTab
    @Binding var draggedTab: StudioSidebarTab?
    @Binding var dropTarget: StudioSidebarTab?

    private var isPinned: Bool { !vm.hiddenTabs.contains(tab) }
    /// The last pinned type cannot be unpinned; pinning back is always allowed.
    private var canToggle: Bool { !isPinned || vm.canUnpinTab(tab) }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if isPinned {
                    vm.hideTab(tab)
                } else {
                    vm.showTab(tab)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isPinned ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                    // The glyph the tab strip draws, so a type reads the same
                    // in both places.
                    SidebarTabIcon(tab: tab, showLabel: false, monochrome: true, iconScale: 16 / 22)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                    Text(tab.rawValue)
                        .foregroundStyle(isPinned ? Color.primary : Color.secondary)
                    Spacer(minLength: 8)
                }
                .padding(.leading, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .disabled(!canToggle)
            .help(canToggle ? "" : "The tab bar keeps at least one pinned source")
            .accessibilityLabel(tab.rawValue)
            .accessibilityValue(isPinned ? "Pinned" : "Unpinned")

            // The handle is the drag source, outside the button so a row whose
            // toggle is disabled can still be moved.
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
                .help("Drag to reorder")
                .accessibilityLabel("Reorder \(tab.rawValue)")
                .onDrag {
                    draggedTab = tab
                    return sidebarTabDragProvider(for: tab)
                }
        }
        // Where the dragged type would land: it takes this row's slot, so the
        // row itself lights up, as the tab bar's does.
        .overlay {
            if dropTarget == tab, let dragged = draggedTab, dragged != tab {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [.studioSidebarTab],
            delegate: SourceTypeRowDropDelegate(
                tab: tab,
                vm: vm,
                draggedTab: $draggedTab,
                dropTarget: $dropTarget
            )
        )
    }
}

/// Reorders source types dropped on a Customize row. Only the tab payload is
/// accepted; a dragged source has no meaning here.
private struct SourceTypeRowDropDelegate: DropDelegate {
    let tab: StudioSidebarTab
    let vm: StudioViewModel
    @Binding var draggedTab: StudioSidebarTab?
    @Binding var dropTarget: StudioSidebarTab?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.studioSidebarTab])
    }

    func dropEntered(info: DropInfo) {
        dropTarget = tab
    }

    func dropExited(info: DropInfo) {
        if dropTarget == tab { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        if let source = draggedTab {
            draggedTab = nil
            vm.reorderTab(from: source, to: tab)
            return true
        }
        let providers = info.itemProviders(for: [.studioSidebarTab])
        for provider in providers {
            StudioSidebarTabDrop.loadString(from: provider) { raw in
                guard let dragged = StudioSidebarTab(rawValue: raw) else { return }
                Task { @MainActor in
                    vm.reorderTab(from: dragged, to: tab)
                }
            }
        }
        return !providers.isEmpty
    }
}
