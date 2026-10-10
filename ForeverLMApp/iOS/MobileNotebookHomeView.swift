import SwiftUI

/// The glyph the phone draws for notebooks where no one notebook's emoji
/// fits (an empty Home, a header that takes a symbol): the Mac rail's All
/// notebooks glyph. A notebook is not a folder.
enum MobileNotebookGlyph {
    static let symbolName = "square.grid.2x2"
    /// Uncategorized's, the Mac rail's.
    static let uncategorizedSymbolName = "tray"
}

/// What Home's search looks through: the notebooks, or the whole library.
enum MobileHomeSearchScope: String, CaseIterable, Hashable {
    case notebooks
    case library

    var title: String {
        switch self {
        case .notebooks: return "Notebooks"
        case .library: return "Library"
        }
    }
}

/// Home: the Mac's compact rail as one list (docs/notebooks-design.md,
/// "iPhone" and "A compact rail"), what is due today above it and Memory,
/// the Space and the whole library one row each below. The product owner, 2026-10-03, of a rail
/// listing ~52 notebooks: "is it even still good design to have all these
/// notebooks in the left sidebar as well?" So Home lists the notebooks at
/// hand — **Pinned**, **Recent** (the last six worked in, and the notebook
/// last opened here when it is neither) — then **All notebooks** and
/// **Uncategorized** (once a collection exists) and **Collections**, which
/// push the Notebooks screen (`MobileNotebooksScreen`) with every notebook,
/// or the ones they name, in Grid or List.
///
/// A notebook row opens the notebook; its menu and its trailing swipe play
/// the notebook's audio overview or talk in it, and its menu has Pin. Since
/// 2026-10-06 the rows draw no round button, the links no count and no
/// accent square (the product owner: "cleaner and fewer buttons and bells and
/// whistles"). Search finds notebooks, or sources across the library — by
/// their words first and by meaning when the words find little. New
/// notebook is the toolbar's +; voice and Settings are the toolbar's too
/// (the shell's `homeRoot`).
struct MobileNotebookHomeView: View {
    /// Pushes a route on the shell's stack: a notebook just made opens at once.
    let open: (MobileShellRoute) -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject private var live = MobileVoiceConversationController.shared
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
    /// New Page or Daily Notes from the Spaces row's menu could not make its page.
    @State private var spaceFailure: String?
    @State private var query = ""
    @State private var scope: MobileHomeSearchScope = .notebooks
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
                notebookSections
                coursesSection
                librarySection
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search notebooks and library")
        .searchScopes($scope) {
            ForEach(MobileHomeSearchScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .task(id: semanticKey) { await rankByMeaningIfNeeded() }
        .task(id: vm.memoryCardsRevision) {
            reviewedSourceIDs = await MobileCloudSourceCatalog.shared.currentReviewedSourceIDs()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                newNotebookButton
            }
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

    /// The bout's clock while one runs, Memory in one line while cards wait
    /// ("6 due · 4 new", the widget's count), and today's plan when anything
    /// is planned.
    @ViewBuilder
    private var todaySection: some View {
        Section {
            if let bout = boutTimer.bout, bout.phase().isLive {
                MobileLearningBoutCard(timer: boutTimer)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            // The Mac's Memory strip: a tap opens Memory, whose Start Review
            // starts. Drawn only while something is due, new or to check
            // (the Mac's since 2026-10-06); the Memory row under the
            // notebooks is the way in otherwise.
            if let line = vm.memoryTodayLine {
                MobileMemoryStrip(line: line) {
                    open(.memory)
                }
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

    /// The rail: Pinned, Recent, All notebooks and Uncategorized, and the
    /// collections (`NotebookRail`); or, with no notebooks yet, why.
    @ViewBuilder
    private var notebookSections: some View {
        if vm.notebooks.isEmpty {
            Section {
                // An empty list during the first sync is a pass still running,
                // not an account without notebooks.
                if let status = vm.syncStatus {
                    ContentUnavailableView {
                        Label("Syncing your library", systemImage: "arrow.triangle.2.circlepath")
                    } description: {
                        Text("\(status.stepText). Notebooks appear here as they arrive.")
                    }
                    .accessibilityIdentifier("notebooks.syncing")
                } else {
                    ContentUnavailableView {
                        Label("No Notebooks", systemImage: MobileNotebookGlyph.symbolName)
                    } description: {
                        Text("Make one with +.")
                    }
                }
            } header: {
                Text("Notebooks")
            }
        } else {
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

            if !rail.pinnedIDs.isEmpty {
                Section("Pinned") {
                    notebooks(rail.pinnedIDs.compactMap { byID[$0] }, recency: recency)
                }
                .accessibilityIdentifier("home.pinned")
            }

            // The open notebook's row ends Recent.
            let recent = (rail.recentIDs + [rail.openNotebookID].compactMap { $0 }).compactMap { byID[$0] }
            if !recent.isEmpty {
                Section("Recent") {
                    notebooks(recent, recency: recency)
                }
                .accessibilityIdentifier("home.recent")
            }

            // No counts beside them (2026-10-06, the Mac rail's): the screen
            // they open lists the notebooks.
            Section {
                NavigationLink(value: MobileShellRoute.notebooks(.all)) {
                    MobileHomeLinkLabel(
                        systemImage: MobileNotebookGlyph.symbolName,
                        title: "All notebooks"
                    )
                }
                .accessibilityIdentifier("home.allNotebooks")
                // Before a collection exists Uncategorized is every notebook.
                if !collectionStore.state.isEmpty {
                    NavigationLink(value: MobileShellRoute.notebooks(.uncategorized)) {
                        MobileHomeLinkLabel(
                            systemImage: MobileNotebookGlyph.uncategorizedSymbolName,
                            title: "Uncategorized"
                        )
                    }
                    .accessibilityIdentifier("home.uncategorized")
                }
            }

            if !rail.collections.isEmpty {
                Section("Collections") {
                    collectionsContent(recency: recency)
                }
                .accessibilityIdentifier("home.collections")
            }
        }
    }

    /// Notebooks as Home draws them: rows on a phone, the Mac's gallery on
    /// a roomy screen (`usesGallery`).
    @ViewBuilder
    private func notebooks(_ notebooks: [MobileCloudNotebook], recency: NotebookRecency) -> some View {
        if usesGallery {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(
                        minimum: MobileNotebookColumnLayout.galleryCardMinimumWidth,
                        maximum: MobileNotebookColumnLayout.galleryCardMaximumWidth
                    ),
                    spacing: MobileNotebookColumnLayout.galleryCardSpacing,
                    alignment: .top
                )],
                alignment: .leading,
                spacing: MobileNotebookColumnLayout.galleryCardSpacing
            ) {
                ForEach(notebooks) { notebook in
                    notebookCard(notebook, recency: recency)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(notebooks) { notebook in
                notebookRow(notebook, recency: recency)
            }
        }
    }

    /// A card per collection, by name, each with the notebooks it holds in
    /// Recent's order; a tap pushes the Notebooks screen showing them. A
    /// phone lists them; a roomy screen draws the gallery.
    @ViewBuilder
    private func collectionsContent(recency: NotebookRecency) -> some View {
        let ordered = NotebooksHomeSort.recent.ordered(vm.notebooks, recency: recency).map(\.id)
        let summaries = collectionStore.state.summaries(of: ordered)
        if usesGallery {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(
                        minimum: MobileNotebookColumnLayout.galleryCardMinimumWidth,
                        maximum: MobileNotebookColumnLayout.galleryCardMaximumWidth
                    ),
                    spacing: MobileNotebookColumnLayout.galleryCardSpacing,
                    alignment: .top
                )],
                alignment: .leading,
                spacing: MobileNotebookColumnLayout.galleryCardSpacing
            ) {
                ForEach(summaries) { summary in
                    MobileNotebookCollectionCard(summary: summary, previewIcons: previewIcons(summary), isGallery: true) {
                        open(.notebooks(.collection(summary.id)))
                    }
                    .contextMenu { MobileCollectionMenuItems(collection: summary.collection, menus: menus) }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(summaries) { summary in
                MobileNotebookCollectionCard(summary: summary, previewIcons: previewIcons(summary), isGallery: false) {
                    open(.notebooks(.collection(summary.id)))
                }
                .contextMenu { MobileCollectionMenuItems(collection: summary.collection, menus: menus) }
            }
        }
    }

    /// The emojis of the first few notebooks a collection holds.
    private func previewIcons(_ summary: NotebookCollectionSummary) -> [MobileNotebookCollectionCard.PreviewIcon] {
        summary.notebookIDs.prefix(MobileNotebookCollectionCard.previewLimit).compactMap { notebookID in
            vm.notebooks.first { $0.id == notebookID }.map {
                MobileNotebookCollectionCard.PreviewIcon(id: $0.id, icon: NotebookTitle($0.title).displayIcon)
            }
        }
    }

    /// A screen in regular width and height (an iPad, an iPhone Duo opened)
    /// shows the notebooks as the Mac's gallery
    /// (`MobileNotebookColumnLayout.usesGallery`); a phone keeps the list.
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
            Section("Courses") {
                ForEach(rows) { row in
                    NavigationLink(value: MobileShellRoute.course(row.course.id)) {
                        MobileCourseHomeRow(row: row)
                    }
                    .accessibilityIdentifier("home.course.\(row.course.id)")
                }
            }
            .accessibilityIdentifier("home.courses")
        }
    }

    /// Memory, the Mac rail's row, the way in while the strip above is not
    /// drawn (nothing due, new or to check), the Space, and the whole
    /// library. No count under Library (2026-10-06): the screen it opens
    /// counts.
    private var librarySection: some View {
        Section {
            NavigationLink(value: MobileShellRoute.memory) {
                MobileHomeLinkLabel(systemImage: MemoryReviewSession.sidebarIcon, title: "Memory")
            }
            .accessibilityIdentifier("home.memoryRow")
            if spaceStore.isAvailable {
                spaceRow
            }
            NavigationLink(value: MobileShellRoute.library) {
                MobileHomeLinkLabel(systemImage: "books.vertical", title: "Library")
            }
            .accessibilityIdentifier("home.sources")
        }
    }

    /// The Mac rail's **Spaces** row (docs/docs-design.md, "The Space"): the
    /// learner's pages, sites and spaces. A phone pushes the Space; a screen
    /// with the room opens it as a split view over Home, so the row is a
    /// button there. Its menu makes a page, or opens today's daily note (the
    /// Mac's Daily Notes, ⇧⌘D), without a row of its own on Home.
    @ViewBuilder
    private var spaceRow: some View {
        let label = MobileHomeLinkLabel(systemImage: "square.on.square", title: "Spaces")
        Group {
            if MobileSpaceLayout.usesSplitView(isRegularWidth: horizontalSizeClass == .regular,
                                               isRegularHeight: verticalSizeClass == .regular) {
                Button { open(.space(nil)) } label: { label.contentShape(Rectangle()) }
            } else {
                NavigationLink(value: MobileShellRoute.space(nil)) { label }
            }
        }
        .contextMenu {
            Button("New Page", systemImage: "square.and.pencil") {
                openSpacePage { try await spaceStore.createPage(title: "", markdown: "", spaceID: nil, parentID: nil) }
            }
            Button("Daily Notes", systemImage: "calendar") {
                openSpacePage { try await spaceStore.ensureDailyNote(dayKey: DailyNote.dayKey(for: Date())) }
            }
        }
        .accessibilityIdentifier("home.space")
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
    /// (2026-10-06). Its menu and its trailing swipe play its audio overview
    /// or talk in it.
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
            Button {
                menus.talk(in: notebook, live: live)
            } label: {
                Label("Talk", systemImage: "waveform")
            }
            .tint(.gray)
            .disabled(live.isActive)
        }
    }

    /// One notebook in the gallery: the row's data and actions on the Mac's
    /// card, ▶ in its corner while it has an audio overview, as the Mac's
    /// card draws it; Talk is its menu's.
    private func notebookCard(_ notebook: MobileCloudNotebook, recency: NotebookRecency) -> some View {
        let overview = vm.audioOverviews(inNotebook: notebook.id).first
        return MobileNotebookGalleryCard(
            notebook: notebook,
            sourceCount: vm.notebookSourceCount(in: notebook),
            lastActivity: recency.lastWorkedAt(notebook.id, updatedAt: notebook.updatedAt),
            overviewIsPlaying: overview.map { vm.currentItem?.id == $0.carrier.id && vm.isPlaying } ?? false,
            hasOverview: overview != nil,
            isPreparingOverview: overview.map { vm.isPreparingAudio(sourceID: $0.carrier.id) } ?? false,
            onOpen: { open(.notebook(notebook.id)) },
            onPlay: {
                guard let overview else { return }
                Task { await vm.toggleTextToSpeech(sourceID: overview.carrier.id) }
            }
        )
        .contextMenu { MobileNotebookMenuItems(notebook: notebook, menus: menus) }
    }

    /// New notebook: made at once, with no form, and opened; ForeverLM names
    /// it from its sources and chats (`NotebookNaming`).
    private func createNotebook() {
        Task {
            guard let id = await vm.createNotebook() else { return }
            open(.notebook(id))
        }
    }

    /// New notebook, the toolbar's +, which opens the notebook it made. It
    /// floated as an accent capsule over the list until 2026-10-06.
    private var newNotebookButton: some View {
        Button {
            createNotebook()
        } label: {
            Image(systemName: "plus")
        }
        .disabled(vm.isMutatingLibrary)
        .accessibilityLabel("New notebook")
        .accessibilityIdentifier("home.newNotebook")
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

/// A row of Home that opens a list or a screen — All notebooks,
/// Uncategorized, Memory, Library: its glyph in grey and its title. Until
/// 2026-10-06 the glyph sat on a soft accent square and a count or a line
/// went with it (the product owner: "cleaner and fewer buttons and bells and
/// whistles"; "Lists are monochrome", docs/ui-design.md).
private struct MobileHomeLinkLabel: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(
                    width: MobileDesign.Metrics.compactArtworkSize,
                    height: MobileDesign.Metrics.compactArtworkSize
                )
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
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
        HStack(alignment: .center, spacing: 12) {
            // The notebook's cover once the phone holds it, with nothing behind it; its emoji on its
            // colour until then (D53).
            MobileNotebookIconView(
                notebookID: notebook.id,
                size: MobileDesign.Metrics.compactArtworkSize,
                cornerRadius: 10,
                plate: NotebookTint.color(for: notebook.id)
            ) {
                Text(title.displayIcon)
                    .font(.title3)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title.text.isEmpty ? "Untitled notebook" : title.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
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
/// the waveform that talked with the notebook went on 2026-10-06, and Talk
/// is the card's menu's.
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

/// One collection in Home's Collections, the Mac's
/// `NotebookCollectionCard`: a stack of notebook cards in the collection's
/// own soft colour (`NotebookTint`, from its id) with its emoji (a leading
/// emoji in its name, else the one its words choose), its name, how many
/// notebooks it holds and the emojis of the first few. A phone draws it as a
/// row, an iPad as a gallery card; a tap pushes the Notebooks screen showing
/// its notebooks.
struct MobileNotebookCollectionCard: View {
    /// One notebook's emoji in the card's preview.
    struct PreviewIcon: Identifiable, Equatable {
        let id: String
        let icon: String
    }

    /// How many notebooks' emojis the card shows.
    static let previewLimit = 4

    let summary: NotebookCollectionSummary
    let previewIcons: [PreviewIcon]
    let isGallery: Bool
    let onOpen: () -> Void

    private static let cornerRadius: CGFloat = 16

    private var countLine: String {
        switch summary.notebookIDs.count {
        case 0: return "No notebooks"
        case 1: return "1 notebook"
        case let count: return "\(count) notebooks"
        }
    }

    var body: some View {
        let title = NotebookTitle(summary.collection.name)
        let name = title.text.isEmpty ? "Untitled collection" : title.text
        Button(action: onOpen) {
            if isGallery {
                gallery(title: title, name: name)
            } else {
                row(title: title, name: name)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(countLine)")
        .accessibilityIdentifier("home.collections.card")
    }

    private func row(title: NotebookTitle, name: String) -> some View {
        let tint = NotebookTint.color(for: summary.id)
        let square = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(alignment: .center, spacing: 12) {
            Text(title.displayIcon)
                .font(.title3)
                .frame(width: MobileDesign.Metrics.compactArtworkSize, height: MobileDesign.Metrics.compactArtworkSize)
                .background(tint, in: square)
                // A second card behind it: a collection is a stack.
                .background(alignment: .top) {
                    square.fill(tint.opacity(0.55))
                        .padding(.horizontal, 5)
                        .offset(y: -4)
                }
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(countLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            preview
        }
        .padding(.vertical, MobileDesign.Spacing.xSmall)
        .contentShape(Rectangle())
    }

    private func gallery(title: NotebookTitle, name: String) -> some View {
        let tint = NotebookTint.color(for: summary.id)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Text(title.displayIcon)
                .font(.system(size: 34))
                .accessibilityHidden(true)

            Spacer(minLength: MobileDesign.Spacing.medium)

            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(countLine)
                    .lineLimit(1)
                Spacer(minLength: 0)
                preview
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, MobileDesign.Spacing.xSmall)
        }
        .padding(MobileDesign.Spacing.large)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(tint, in: shape)
        // Two cards peek out above it, so a collection reads as a stack.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                shape.fill(tint.opacity(0.35))
                    .padding(.horizontal, 22)
                    .offset(y: -12)
                shape.fill(tint.opacity(0.65))
                    .padding(.horizontal, 11)
                    .offset(y: -6)
            }
            .accessibilityHidden(true)
        }
        .padding(.top, 12)
        .contentShape(shape)
        .contentShape(.hoverEffect, shape)
        .hoverEffect(.highlight)
    }

    /// The first few notebooks' emojis, each on its own notebook's colour,
    /// overlapping as a stack does. A cover keeps the colour: its circle
    /// holds it inset, as the Mac's stack does.
    private var preview: some View {
        HStack(spacing: -6) {
            ForEach(previewIcons) { item in
                MobileNotebookIconView(notebookID: item.id, size: 24, cornerRadius: nil) {
                    Text(item.icon)
                        .font(.caption)
                        .frame(width: 24, height: 24)
                }
                .background(NotebookTint.color(for: item.id), in: Circle())
                .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
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
/// and no waveform (Talk is the menu's). On a phone's Notebooks screen the
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
                    // Too narrow to share a line with the round button: the
                    // line sits above the button's row.
                    Text(MobileNotebookCard.line(notebook: notebook, sourceCount: sourceCount, lastActivity: lastActivity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                    if hasOverview {
                        Color.clear
                            .frame(height: MobileDesign.Metrics.minimumTouchTarget - MobileDesign.Spacing.small)
                    }
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
            .frame(maxWidth: .infinity, minHeight: isCompact ? 150 : 176, alignment: .topLeading)
            .background(NotebookTint.color(for: notebook.id), in: shape)
            .contentShape(shape)
            .contentShape(.hoverEffect, shape)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("browser.notebookRow")
        .overlay(alignment: .bottomTrailing) {
            if hasOverview {
                MobileNotebookCardPlayButton(
                    overviewIsPlaying: overviewIsPlaying,
                    isPreparingOverview: isPreparingOverview,
                    onPlay: onPlay
                )
                .padding(MobileDesign.Spacing.small)
            }
        }
    }
}
