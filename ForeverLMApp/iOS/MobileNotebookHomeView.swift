import SwiftUI

/// The glyph the phone draws for notebooks where no one notebook's emoji
/// fits (an empty Home, a header that takes a symbol): the Mac rail's All
/// notebooks glyph. A notebook is not a folder.
enum MobileNotebookGlyph {
    static let symbolName = "square.grid.2x2"
    /// Uncategorized's, the Mac rail's.
    static let uncategorizedSymbolName = "tray"
}

/// What Home's search looks through: the whole library, or the notebooks.
enum MobileHomeSearchScope: String, CaseIterable, Hashable {
    case library
    case notebooks

    var title: String {
        switch self {
        case .library: return "Library"
        case .notebooks: return "Notebooks"
        }
    }
}

/// Home (since 2026-11-09, `MobileHomeDashboard`): today's cards with Review
/// and By Voice, Voice, the notebooks at
/// hand as cover cards — pinned first, then the ones last worked in — with See
/// All for the Notebooks screen (`MobileNotebooksScreen`, collections and all),
/// and the library as a row of chips at the foot. A running bout and today's
/// plan sit above it while there is one; courses under it.
///
/// Search finds notebooks, or sources across the library — by their words
/// first and by meaning when the words find little. Home has no top bar: New
/// notebook is the + by Notebooks, Settings the gear beside Search at the foot
/// (`MobileHomeBottomBar`).
struct MobileNotebookHomeView: View {
    /// Pushes a route on the shell's stack: a notebook just made opens at once.
    let open: (MobileShellRoute) -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The Planner's bout, when one is running on a Mac.
    @ObservedObject private var boutTimer = MobileLearningBoutTimer.shared
    /// The learner's collections of notebooks, as this phone last read them.
    @ObservedObject private var collectionStore = MobileNotebookCollectionsStore.shared
    /// The pins, the learner's notebook order and the notebooks opened here.
    @ObservedObject private var railStore = MobileNotebookRailStore.shared
    /// The notebook last opened on this phone (`MobileLastNotebookStore`).
    @AppStorage(MobileNotebookResume.defaultsKey) private var lastOpenedID = ""
    @StateObject private var menus = MobileNotebookMenuState()
    /// The Space, whose row shows once the phone's pages can open here (generation 2).
    @Environment(MobileSpaceStore.self) private var spaceStore
    /// New Page or Daily Notes from the Spaces chip's menu could not make its page.
    @State private var spaceFailure: String?
    /// Today's cards as the Memory screen counts them (practice included);
    /// nil until read.
    @State private var cardCounts: MemoryCardDayCounts?
    @State private var query = ""
    @State private var scope: MobileHomeSearchScope = .library
    /// The meaning ranking's answer for the query it was run on.
    @State private var semantic: (query: String, sources: [MobileCloudSource]) = ("", [])
    @State private var isRankingByMeaning = false
    /// New notebook's sheet.
    @State private var editor: MobileNotebookEditorDestination?
    /// The sources a finished review covered, which a course's progress
    /// counts as finished.
    @State private var reviewedSourceIDs: Set<String> = []

    /// How many of today's pending items the plan card lists before it counts
    /// the rest. Matches the Mac's Today card.
    private static let todayPlanMaxRows = 3

    private var isSearching: Bool {
        !MobileSourceListSearch.terms(in: query).isEmpty
    }

    /// When each notebook was last worked in: opened here, its latest chat,
    /// its record's own change.
    private var recency: NotebookRecency {
        MobileNotebookRailRules.recency(opened: railStore.opened, lastChatAt: vm.lastNotebookChatAt)
    }

    /// The notebooks last worked in first: what a search lists them by.
    private var orderedNotebooks: [MobileCloudNotebook] {
        NotebooksHomeSort.recent.ordered(vm.notebooks, recency: recency)
    }

    var body: some View {
        List {
            if isSearching {
                searchResults
            } else {
                todaySection
                dashboard
                coursesSection
            }
        }
        // Flat rows on the page itself, not boxes on grey (2026-10-11).
        .listStyle(.plain)
        .listRowSeparator(.hidden)
        .modifier(MobileHomeHidesDisclosure())
        .listRowSpacing(2)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .searchable(text: $query, prompt: "Search library and notebooks")
        .modifier(MobileHomeBottomBar())
        .searchScopes($scope) {
            ForEach(MobileHomeSearchScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .task(id: semanticKey) { await rankByMeaningIfNeeded() }
        .task(id: vm.memoryCardsRevision) {
            reviewedSourceIDs = await MobileCloudSourceCatalog.shared.currentReviewedSourceIDs()
            cardCounts = await vm.cardReviewRead(scope: .allNotebooks).counts
        }

        .sheet(item: $editor) { destination in
            MobileNotebookEditorSheet(mode: destination.mode)
        }
        .notebookMenus(menus)
        .refreshable {
            await vm.load()
        }
        .task {
            if !spaceStore.isAvailable { await spaceStore.refresh() }
        }
        .alert("Couldn’t Open the Page", isPresented: Binding(
            get: { spaceFailure != nil },
            set: { if !$0 { spaceFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(spaceFailure ?? "")
        }
    }

    // MARK: - Sections

    /// The bout's clock while one runs, and today's plan when anything is
    /// planned: above the dashboard, while there is one.
    @ViewBuilder
    private var todaySection: some View {
        Section {
            if let bout = boutTimer.bout, bout.phase().isLive {
                MobileLearningBoutCard(timer: boutTimer)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if !todayPendingItems.isEmpty {
                MobileTodayPlanCard(
                    items: todayPendingItems,
                    maxRows: Self.todayPlanMaxRows,
                    onMarkDone: { item in
                        Task { _ = await vm.markScheduleSourceDone(sourceID: item.source.id) }
                    },
                    onQuiz: { item in
                        Task {
                            await vm.startReviewQuiz(
                                sourceID: item.source.id,
                                utterance: item.source.title
                            )
                        }
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .listRowSeparator(.hidden)
        .listSectionSpacing(MobileDesign.Spacing.medium)
    }

    /// Today's plan: the sources someone deliberately placed on today and has
    /// not finished. A placement the app wrote by itself to anchor activity
    /// (`isAutomatic`) is consumption history, not a plan.
    private var todayPendingItems: [MobileScheduledCatalogItem] {
        vm.scheduleItems.filter {
            !$0.isAutomatic && Calendar.current.isDateInToday($0.plannedAt) && !$0.isCompleted
        }
    }

    /// The dashboard (`MobileHomeDashboard`) over this phone's library.
    private var dashboard: some View {
        let shown = homeNotebooks
        return MobileHomeDashboard(
            cards: homeCardCounts,
            notebooks: shown.items,
            hasMoreNotebooks: shown.hasMore,
            isSyncing: vm.notebooks.isEmpty && vm.syncStatus != nil,
            showsSpaces: spaceStore.isAvailable,
            columns: usesGallery ? 3 : 2,
            actions: MobileHomeActions(
                open: open,
                reviewByVoice: {
                    Task { await MobileRealtimeVoice.startCardReview(scope: .allNotebooks, scopeTitle: "All notebooks") }
                },
                talk: {
                    Task { await MobileRealtimeVoice.startAssistant(setting: .phone) }
                },
                newNotebook: createNotebook,
                newPage: {
                    openSpacePage { try await spaceStore.createPage(title: "", markdown: "", spaceID: nil, parentID: nil) }
                },
                dailyNote: {
                    openSpacePage { try await spaceStore.ensureDailyNote(dayKey: DailyNote.dayKey(for: Date())) }
                },
                playOverview: { sourceID in
                    Task { await vm.toggleTextToSpeech(sourceID: sourceID) }
                }
            )
        ) { notebook in
            MobileNotebookMenuItems(notebook: notebook, menus: menus)
        }
    }

    /// Today's cards as the Memory screen reads them, or, until that read
    /// lands, the widget's count; nil while nothing has synced.
    private var homeCardCounts: MemoryCardDayCounts? {
        guard !vm.allSources.isEmpty else { return nil }
        if let cardCounts {
            return MemoryCardDayCounts(due: cardCounts.due, new: cardCounts.new, practice: cardCounts.practice, toCheck: vm.cardsToCheckTotal)
        }
        return MemoryCardDayCounts(today: vm.todayMemoryCards, practice: 0, toCheck: vm.cardsToCheckTotal)
    }

    /// The notebooks on Home: the pinned ones, then the ones last worked in
    /// (the rail's order), then the rest by recency, up to a row or two of
    /// cards; See All lists every one.
    private var homeNotebooks: (items: [MobileHomeNotebookItem], hasMore: Bool) {
        let recency = self.recency
        let rail = MobileNotebookRailRules.rail(
            notebooks: vm.notebooks,
            pinnedIDs: railStore.pinnedIDs,
            order: railStore.notebookOrder,
            recency: recency,
            collections: collectionStore.state,
            lastOpenedID: lastOpenedID.isEmpty ? nil : lastOpenedID
        )
        let byID = Dictionary(vm.notebooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let ordered = (rail.pinnedIDs + rail.recentIDs + [rail.openNotebookID].compactMap { $0 } + orderedNotebooks.map(\.id))
            .filter { seen.insert($0).inserted }
            .compactMap { byID[$0] }
        let limit = usesGallery ? 6 : 4
        let items = ordered.prefix(limit).map { notebook in
            let overview = vm.audioOverviews(inNotebook: notebook.id).first
            return MobileHomeNotebookItem(
                notebook: notebook,
                sourceCount: vm.notebookSourceCount(in: notebook),
                lastActivity: recency.lastWorkedAt(notebook.id, updatedAt: notebook.updatedAt),
                overviewSourceID: overview?.carrier.id,
                overviewIsPlaying: overview.map { vm.currentItem?.id == $0.carrier.id && vm.isPlaying } ?? false,
                isPreparingOverview: overview.map { vm.isPreparingAudio(sourceID: $0.carrier.id) } ?? false
            )
        }
        return (items, ordered.count > items.count)
    }

    /// A screen in regular width and height (an iPad, an iPhone Duo opened)
    /// draws three notebook cards to a row (`MobileNotebookColumnLayout.usesGallery`);
    /// a phone two.
    private var usesGallery: Bool {
        MobileNotebookColumnLayout.usesGallery(
            isRegularWidth: horizontalSizeClass == .regular,
            isRegularHeight: verticalSizeClass == .regular
        )
    }

    /// Courses beside the notebooks (docs/notebooks-design.md, "Courses
    /// beside notebooks on screen"; the product owner, 2026-10-03: a course lives in no
    /// notebook): every course in the library, with how far the learner is
    /// and the notebooks that follow it, each opening the course's page.
    @ViewBuilder
    private var coursesSection: some View {
        let rows = MobileCoursesHome.rows(
            courses: Array(vm.collections.coursesByID.values),
            sources: MobileSourceListing.listed(vm.allSources),
            reviewedSourceIDs: reviewedSourceIDs,
            notebooks: orderedNotebooks
        )
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    NavigationLink(value: MobileShellRoute.course(row.course.id)) {
                        MobileCourseHomeRow(row: row)
                    }
                    .accessibilityIdentifier("home.course.\(row.course.id)")
                }
            } header: {
                MobileHomeSectionHeader("Courses")
            }
            .accessibilityIdentifier("home.courses")
        }
    }

    /// Makes or finds a page of the Space and opens it.
    private func openSpacePage(_ make: @escaping @MainActor () async throws -> MobileSpacePage) {
        Task {
            do {
                open(.page(try await make().id))
            } catch {
                spaceFailure = error.localizedDescription
            }
        }
    }

    /// A notebook's row: its mark, title and line, no button of its own
    /// (2026-10-06). Its menu and its trailing swipe play its audio overview.
    private func notebookRow(_ notebook: MobileCloudNotebook, recency: NotebookRecency) -> some View {
        let overview = vm.audioOverviews(inNotebook: notebook.id).first
        let isPlaying = overview.map { vm.currentItem?.id == $0.carrier.id && vm.isPlaying } ?? false
        return NavigationLink(value: MobileShellRoute.notebook(notebook.id)) {
            MobileNotebookCard(
                notebook: notebook,
                sourceCount: vm.notebookSourceCount(in: notebook),
                lastActivity: recency.lastWorkedAt(notebook.id, updatedAt: notebook.updatedAt)
            )
        }
        .accessibilityIdentifier("browser.notebookRow")
        .contextMenu { MobileNotebookMenuItems(notebook: notebook, menus: menus) }
        .swipeActions(edge: .trailing) {
            // A full swipe plays the overview when there is one.
            if let overview {
                Button {
                    Task { await vm.toggleTextToSpeech(sourceID: overview.carrier.id) }
                } label: {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .tint(.accentColor)
            }
        }
    }

    /// New notebook: made at once, with no form, and opened; ForeverLM names
    /// it from its sources and chats (`NotebookNaming`).
    private func createNotebook() {
        Task {
            guard let id = await vm.createNotebook() else { return }
            open(.notebook(id))
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchResults: some View {
        switch scope {
        case .notebooks:
            let matches = MobileHomeSearch.notebooks(orderedNotebooks, matching: query)
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            } else {
                let recency = self.recency
                Section {
                    ForEach(matches) { notebook in
                        notebookRow(notebook, recency: recency)
                    }
                }
            }
        case .library:
            let results = libraryResults
            if results.isEmpty, !isRankingByMeaning {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(results) { source in
                        MobileBrowserSourceLink(source: source)
                    }
                    if isRankingByMeaning {
                        HStack(spacing: MobileDesign.Spacing.small) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Searching by meaning…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var searchableSources: [MobileCloudSource] {
        MobileSourceListing.listed(vm.allSources)
    }

    private var lexicalResults: [MobileCloudSource] {
        MobileSourceListSearch.filter(searchableSources, query: query) { source in
            guard let group = source.parentGroup else { return nil }
            return vm.collections.booksByID[group]?.title ?? vm.collections.coursesByID[group]?.title
        }
    }

    private var libraryResults: [MobileCloudSource] {
        let lexical = lexicalResults
        let meaning = semantic.query == query ? semantic.sources : []
        return MobileHomeSearch.merged(lexical: lexical, semantic: meaning)
    }

    /// Changes whenever a meaning search would answer something else.
    private var semanticKey: String {
        scope == .library && isSearching ? query : ""
    }

    /// Ranks the library by meaning for a query the words found little for,
    /// after a short pause in typing, off the main actor (the first ranking
    /// embeds every title once).
    private func rankByMeaningIfNeeded() async {
        guard scope == .library, isSearching else {
            isRankingByMeaning = false
            return
        }
        let current = query
        guard MobileHomeSearch.needsSemantic(lexicalCount: lexicalResults.count) else {
            isRankingByMeaning = false
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, current == query else { return }
        isRankingByMeaning = true
        let candidates = searchableSources
        let ranked = await MobileSemanticSourceSearch.search(for: current, in: candidates, limit: 20)
        guard !Task.isCancelled, current == query else { return }
        semantic = (current, ranked)
        isRankingByMeaning = false
    }
}

/// One course on Home, as its card on the Mac's Courses tab reads: its
/// title, its institution, its progress bar and "3 of 12 lectures finished",
/// and the notebooks that follow it. Its glyph and bar are grey since
/// 2026-10-06 ("Lists are monochrome", docs/ui-design.md).
private struct MobileCourseHomeRow: View {
    let row: MobileCoursesHome.Row

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "graduationcap")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: MobileDesign.Metrics.compactArtworkSize, height: MobileDesign.Metrics.compactArtworkSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.course.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let institution = row.course.institution?.trimmingCharacters(in: .whitespacesAndNewlines), !institution.isEmpty {
                    Text(institution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if row.progress.total > 0 {
                    ProgressView(value: row.progress.fractionFinished)
                        .tint(.secondary)
                        .accessibilityHidden(true)
                    Text(row.progress.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let line = row.notebooksLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
        .accessibilityElement(children: .combine)
    }
}

/// One chip in the Notebooks screen's filter row: its name in grey, and in
/// the primary colour on a neutral capsule while it is the filter, as the
/// Mac's chips are since 2026-10-06 ("Lists are monochrome",
/// docs/ui-design.md); it was filled with the accent and carried its count
/// of notebooks before.
struct MobileNotebookCollectionChip: View {
    static let height: CGFloat = 34
    /// Taps above and below the capsule still land on it: a 44-point target.
    static let verticalHitPadding: CGFloat = (MobileDesign.Metrics.minimumTouchTarget - height) / 2

    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .lineLimit(1)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, MobileDesign.Spacing.medium)
                .frame(height: Self.height)
                .background(
                    isSelected ? Color(uiColor: .secondarySystemGroupedBackground) : Color.clear,
                    in: Capsule()
                )
                .padding(.vertical, Self.verticalHitPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One notebook on Home: its cover drawn bare, else its emoji (the Mac's
/// `NotebookTitle.displayIcon`) on its colour, its title and "12 sources · 2
/// hr ago". The round button that played its audio overview or talked with
/// it went on 2026-10-06; its menu and swipe carry both.
struct MobileNotebookCard: View {
    let notebook: MobileCloudNotebook
    let sourceCount: Int
    let lastActivity: Date

    var body: some View {
        let title = NotebookTitle(notebook.title)
        HStack(alignment: .center, spacing: 14) {
            // The notebook's cover once the phone holds it, with nothing behind it; its emoji on its
            // colour until then (D53).
            MobileNotebookIconView(
                notebookID: notebook.id,
                size: 48,
                cornerRadius: 12,
                plate: NotebookTint.color(for: notebook.id)
            ) {
                Text(title.displayIcon)
                    .font(.title2)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.text.isEmpty ? "Untitled notebook" : title.text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
    }

    private var subtitle: String {
        Self.line(notebook: notebook, sourceCount: sourceCount, lastActivity: lastActivity)
    }

    /// "12 sources · 2 hr ago", "Sources syncing" while none of a notebook's
    /// sources has reached the phone, and "0 sources" for an empty one, as
    /// the Mac's card counts it (its "No sources yet" went on 2026-10-06).
    static func line(notebook: MobileCloudNotebook, sourceCount: Int, lastActivity: Date) -> String {
        let count: String
        if sourceCount == 0, !notebook.sourceIDs.isEmpty {
            count = "Sources syncing"
        } else {
            count = sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
        }
        guard lastActivity > .distantPast else { return count }
        return "\(count) · \(lastActivity.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))"
    }
}

/// A gallery card's ▶ (or ⏸) for the notebook's audio overview, a spinner
/// while that audio is being made, as the Mac's card draws it
/// (`NotebookCardPlayButton`). A card with no overview draws nothing here:
/// the waveform that talked with the notebook went on 2026-10-06.
private struct MobileNotebookCardPlayButton: View {
    let overviewIsPlaying: Bool
    let isPreparingOverview: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            Group {
                if isPreparingOverview {
                    ProgressView()
                        .controlSize(.small)
                        .frame(
                            width: MobileDesign.Metrics.minimumTouchTarget,
                            height: MobileDesign.Metrics.minimumTouchTarget
                        )
                } else {
                    MobileCircularActionLabel(systemImage: overviewIsPlaying ? "pause.fill" : "play.fill")
                }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(overviewIsPlaying ? "Pause audio overview" : "Play audio overview")
        .accessibilityIdentifier("home.notebook.playOverview")
    }
}

extension NotebookTint {
    /// The notebook's tint as a colour that follows light and dark mode.
    static func color(for notebookID: String) -> Color {
        let index = index(for: notebookID)
        return Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark[index] : light[index]
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// One notebook in Home's gallery on iPad, the Mac's `NotebookGalleryCard`,
/// drawn as NotebookLM draws its own: a card in the notebook's soft colour
/// (`NotebookTint`), its emoji large in the corner, its name under it and
/// "12 sources · 2 hr ago", and ▶ in its bottom-right corner while it has an
/// audio overview. The same data as the phone's row (`MobileNotebookCard`)
/// and the same menu; a tap opens the notebook. Since 2026-10-06, as the
/// Mac's card, it draws no pin (Pinned on Home and the menu's Unpin say it)
/// and no waveform. On a phone's Notebooks screen the
/// card is drawn smaller (`isCompact`), two to a row.
struct MobileNotebookGalleryCard: View {
    let notebook: MobileCloudNotebook
    let sourceCount: Int
    let lastActivity: Date
    let overviewIsPlaying: Bool
    let hasOverview: Bool
    let isPreparingOverview: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void
    var isCompact = false

    /// The Mac card's corner.
    private static let cornerRadius: CGFloat = 16
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        let title = NotebookTitle(notebook.title)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                MobileNotebookIconView(notebookID: notebook.id, size: isCompact ? 36 : 44, cornerRadius: 10) {
                    Text(title.displayIcon)
                        .font(.system(size: isCompact ? 28 : 34))
                }
                .accessibilityHidden(true)

                Spacer(minLength: MobileDesign.Spacing.medium)

                Text(title.text.isEmpty ? "Untitled notebook" : title.text)
                    .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCompact {
                    // The round button sits in the top-right corner, beside the
                    // emoji, so every card's name rests on its foot.
                    Text(MobileNotebookCard.line(notebook: notebook, sourceCount: sourceCount, lastActivity: lastActivity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                } else {
                    Text(MobileNotebookCard.line(notebook: notebook, sourceCount: sourceCount, lastActivity: lastActivity))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // The round button sits in the bottom-right corner.
                        .padding(.trailing, hasOverview ? MobileDesign.Metrics.minimumTouchTarget + MobileDesign.Spacing.small : 0)
                        .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget - MobileDesign.Spacing.small, alignment: .bottomLeading)
                }
            }
            .padding(isCompact ? MobileDesign.Spacing.medium : MobileDesign.Spacing.large)
            .frame(maxWidth: .infinity, minHeight: isCompact ? 132 : 176, alignment: .topLeading)
            .background(NotebookTint.color(for: notebook.id), in: shape)
            .contentShape(shape)
            .contentShape(.hoverEffect, shape)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("browser.notebookRow")
        .overlay(alignment: isCompact ? .topTrailing : .bottomTrailing) {
            if hasOverview {
                MobileNotebookCardPlayButton(
                    overviewIsPlaying: overviewIsPlaying,
                    isPreparingOverview: isPreparingOverview,
                    onPlay: onPlay
                )
                .padding(isCompact ? MobileDesign.Spacing.xSmall : MobileDesign.Spacing.small)
            }
        }
    }
}


// MARK: - Home's chrome

/// A section's title on Home: small, grey and as typed, over flat rows (the plain list draws its own
/// headers large and bold).
struct MobileHomeSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, MobileDesign.Spacing.small)
    }
}

/// Rows that push a screen draw no chevron on Home: the row is the control.
private struct MobileHomeHidesDisclosure: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.4, *) {
            content.navigationLinkIndicatorVisibility(.hidden)
        } else {
            content
        }
    }
}

/// iOS 26 draws Search as a bar at the bottom; earlier systems keep Search in the navigation bar.
struct MobileHomeBottomBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbar {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { MobileHomeSettingsLink() }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .bottomBar) { MobileHomeSettingsLink() }
            }
        }
    }
}

/// Settings, the gear beside Search at Home's foot: Home has no top bar
/// (product owner, 2026-11-09: the settings and plus buttons at the top waste
/// space).
struct MobileHomeSettingsLink: View {
    var body: some View {
        NavigationLink(value: MobileShellRoute.settings) {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("home.settings")
    }
}
