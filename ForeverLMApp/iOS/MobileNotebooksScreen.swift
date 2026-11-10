import SwiftUI

/// The Notebooks screen: every notebook, the Mac's Notebooks home on the
/// phone (docs/notebooks-design.md, "iPhone"). Home is the compact rail —
/// Pinned, Recent, Collections — and its All notebooks, Uncategorized and
/// collection rows push this screen filtered to them.
///
/// - **Filter**: chips for All, Uncategorized (once a collection exists) and
///   each collection, in grey, the chosen one primary on a neutral capsule;
///   a long press on a collection renames or deletes it
///   (`NotebooksHomeFilter`). Since 2026-10-06 they carry no counts and no +
///   follows them: New Collection… is the ⋯'s (the product owner: "cleaner and fewer
///   buttons and bells and whistles").
/// - **⋯ in the toolbar**: Grid | List, Sort By — Recent, Name, Sources,
///   Uncategorized first, each in its natural direction, the chosen one again
///   turning it round as Files does (`NotebooksHomeOrder.clicking`) — and
///   New Collection…. Layout and order are this device's (the Mac's keys in
///   this phone's own defaults), never a synced row.
/// - **+ in the toolbar**: New notebook, made at once and opened, in the
///   collection shown (`createNotebook(inCollection:)`).
/// - **Grid** (the default): the notebook cards, two to a row on a phone and
///   the Mac's gallery on an iPad. **List**: a dense row per notebook — its
///   collections, sources and when it was last worked in under its name on
///   a phone, the Mac's five columns on an iPad, whose headers
///   sort (product owner, 2026-10-03: "maybe there should also be a list view for
///   these not just grid?").
///
/// A card or a row opens the notebook; its menu is Home's (`MobileNotebookMenuItems`),
/// and a row's leading swipe pins or unpins it.
struct MobileNotebooksScreen: View {
    /// Pushes a route on the shell's stack.
    let open: (MobileShellRoute) -> Void

    @EnvironmentObject private var vm: MobileAudioReviewViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject private var collectionStore = MobileNotebookCollectionsStore.shared
    @ObservedObject private var railStore = MobileNotebookRailStore.shared
    @StateObject private var menus = MobileNotebookMenuState()
    /// What the screen shows: all, Uncategorized or one collection. View
    /// state only, never synced.
    @State private var filter: NotebooksHomeFilter
    @AppStorage(NotebooksHomeLayout.preferenceKey) private var storedLayout = NotebooksHomeLayout.grid.rawValue
    @AppStorage(NotebooksHomeOrder.sortPreferenceKey) private var storedSort = NotebooksHomeSort.recent.rawValue
    @AppStorage(NotebooksHomeOrder.reversedPreferenceKey) private var storedReversed = false

    init(filter: NotebooksHomeFilter, open: @escaping (MobileShellRoute) -> Void) {
        _filter = State(initialValue: filter)
        self.open = open
    }

    private var layout: NotebooksHomeLayout { NotebooksHomeLayout(stored: storedLayout) }

    private var order: NotebooksHomeOrder {
        NotebooksHomeOrder(storedSort: storedSort, storedReversed: storedReversed)
    }

    /// The filter while what it names exists: a collection deleted here or
    /// elsewhere reads as All.
    private var shownFilter: NotebooksHomeFilter {
        filter.resolved(in: collectionStore.state)
    }

    private var recency: NotebookRecency {
        MobileNotebookRailRules.recency(opened: railStore.opened, lastChatAt: vm.lastNotebookChatAt)
    }

    private var notebooks: [MobileCloudNotebook] {
        let ordered = order.sort.ordered(
            vm.notebooks,
            recency: recency,
            collections: collectionStore.state,
            reversed: order.isReversed
        )
        return shownFilter.apply(ordered, collections: collectionStore.state)
    }

    /// A screen in regular width and height (an iPad, an iPhone Duo opened):
    /// the Mac's gallery, and the List's columns.
    private var isRoomy: Bool {
        MobileNotebookColumnLayout.usesGallery(
            isRegularWidth: horizontalSizeClass == .regular,
            isRegularHeight: verticalSizeClass == .regular
        )
    }

    var body: some View {
        let shown = notebooks
        let recency = self.recency
        List {
            Section {
                if shown.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("notebooks.empty")
                } else if layout == .grid {
                    grid(shown, recency: recency)
                } else {
                    ForEach(shown) { notebook in
                        listRow(notebook, recency: recency)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                    if !collectionStore.state.isEmpty {
                        chips
                    }
                    if layout == .list, isRoomy, !shown.isEmpty {
                        MobileNotebookListHeader(order: order) { key in
                            setOrder(order.clicking(key))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                viewMenu
                newNotebookButton
            }
        }
        .notebookMenus(menus)
        .onChange(of: menus.madeCollection) { _, made in
            // A collection made from the ⋯'s New Collection… is shown at once.
            if let made { filter = .collection(made.id) }
        }
        .refreshable {
            await vm.load()
        }
    }

    // MARK: Title and empty

    private var title: String {
        switch shownFilter {
        case .all: return "Notebooks"
        case .uncategorized: return "Uncategorized"
        case .collection(let id):
            return collectionStore.state.collection(id).map(MobileNotebookCollectionLabel.text) ?? "Notebooks"
        }
    }

    private var emptyText: String {
        switch shownFilter {
        case .all: return "No notebooks yet"
        case .uncategorized: return "Every notebook is in a collection"
        case .collection: return "No notebooks in this collection"
        }
    }

    // MARK: The toolbar's menu

    /// Grid | List, Sort By and New Collection…, as Files' ⋯ offers its view.
    private var viewMenu: some View {
        Menu {
            Picker("View", selection: layoutBinding) {
                ForEach(NotebooksHomeLayout.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.inline)

            Section("Sort By") {
                ForEach(NotebooksHomeSort.allCases) { key in
                    Button {
                        setOrder(order.clicking(key))
                    } label: {
                        if key == order.sort {
                            Label(key.title, systemImage: order.isAscending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(key.title)
                        }
                    }
                    .accessibilityIdentifier("notebooks.sort.\(key.rawValue)")
                }
            }

            Section {
                Button("New Collection…", systemImage: "rectangle.stack.badge.plus") {
                    menus.promptForCollectionName(.new(notebookID: nil))
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("View options")
        .accessibilityValue("\(layout.title), sorted by \(order.sort.title)")
        .accessibilityIdentifier("notebooks.viewMenu")
    }

    /// New notebook: made at once and opened, in the collection the screen
    /// shows, as the Mac's home files it; ForeverLM names it.
    private var newNotebookButton: some View {
        Button {
            let collectionID = shownFilter.collectionID
            Task {
                guard let id = await vm.createNotebook(inCollection: collectionID) else { return }
                open(.notebook(id))
            }
        } label: {
            Image(systemName: "plus")
        }
        .disabled(vm.isMutatingLibrary)
        .accessibilityLabel("New notebook")
        .accessibilityIdentifier("notebooks.newNotebook")
    }

    private var layoutBinding: Binding<NotebooksHomeLayout> {
        Binding(
            get: { layout },
            set: { option in withAnimation(.easeInOut(duration: 0.18)) { storedLayout = option.rawValue } }
        )
    }

    private func setOrder(_ next: NotebooksHomeOrder) {
        withAnimation(.easeInOut(duration: 0.18)) {
            storedSort = next.sort.rawValue
            storedReversed = next.isReversed
        }
    }

    // MARK: The filter

    /// All, Uncategorized and each collection.
    private var chips: some View {
        let collections = collectionStore.state
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileDesign.Spacing.xSmall) {
                MobileNotebookCollectionChip(label: "All", isSelected: shownFilter == .all) {
                    filter = .all
                }
                .accessibilityIdentifier("notebooks.filter.all")

                MobileNotebookCollectionChip(label: "Uncategorized", isSelected: shownFilter == .uncategorized) {
                    filter = .uncategorized
                }
                .accessibilityIdentifier("notebooks.filter.uncategorized")

                ForEach(collections.ordered) { collection in
                    MobileNotebookCollectionChip(
                        label: MobileNotebookCollectionLabel.text(collection),
                        isSelected: shownFilter == .collection(collection.id)
                    ) {
                        filter = .collection(collection.id)
                    }
                    .contextMenu { MobileCollectionMenuItems(collection: collection, menus: menus) }
                    .accessibilityIdentifier("home.collections.collection")
                }
            }
            .textCase(nil)
        }
        // Scrolled chips run on to the screen's edges rather than being cut
        // at the header's inset.
        .scrollClipDisabled()
        .accessibilityIdentifier("notebooks.filter")
    }

    // MARK: Grid

    private func grid(_ shown: [MobileCloudNotebook], recency: NotebookRecency) -> some View {
        let compact = !isRoomy
        return LazyVGrid(
            columns: [GridItem(
                .adaptive(
                    minimum: compact
                        ? MobileNotebookColumnLayout.compactGalleryCardMinimumWidth
                        : MobileNotebookColumnLayout.galleryCardMinimumWidth,
                    maximum: MobileNotebookColumnLayout.galleryCardMaximumWidth
                ),
                spacing: compact ? MobileDesign.Spacing.medium : MobileNotebookColumnLayout.galleryCardSpacing,
                alignment: .top
            )],
            alignment: .leading,
            spacing: compact ? MobileDesign.Spacing.medium : MobileNotebookColumnLayout.galleryCardSpacing
        ) {
            ForEach(shown) { notebook in
                card(notebook, recency: recency, compact: compact)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("notebooks.grid")
    }

    private func card(_ notebook: MobileCloudNotebook, recency: NotebookRecency, compact: Bool) -> some View {
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
            },
            isCompact: compact
        )
        .contextMenu { MobileNotebookMenuItems(notebook: notebook, menus: menus) }
    }

    // MARK: List

    /// The list's count: what the phone holds of the notebook with a book's
    /// chapters as one, or the synced record's count while none of its
    /// sources has arrived yet.
    private func listedSourceCount(_ notebook: MobileCloudNotebook) -> Int {
        let held = vm.notebookSourceCount(in: notebook)
        return held == 0 ? notebook.approvedSourceCount : held
    }

    private func listRow(_ notebook: MobileCloudNotebook, recency: NotebookRecency) -> some View {
        let isPinned = railStore.isPinned(notebook.id)
        return NavigationLink(value: MobileShellRoute.notebook(notebook.id)) {
            MobileNotebookListRow(
                notebook: notebook,
                collections: collectionStore.state.collections(ofNotebook: notebook.id),
                sourceCount: listedSourceCount(notebook),
                workedAt: recency.lastWorkedAt(notebook.id, updatedAt: notebook.updatedAt),
                isPinned: isPinned,
                showsColumns: isRoomy
            )
        }
        .contextMenu { MobileNotebookMenuItems(notebook: notebook, menus: menus) }
        .swipeActions(edge: .leading) {
            Button {
                Task { await vm.setNotebook(notebook.id, pinned: !isPinned) }
            } label: {
                Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .accessibilityIdentifier("notebooks.listRow")
    }
}

// MARK: - The List's parts

/// The List's columns on an iPad, the Mac's:
/// Notebook takes the rest.
enum MobileNotebookListColumn {
    static let collections: CGFloat = 190
    static let sources: CGFloat = 64
    static let updated: CGFloat = 100
    static let status: CGFloat = 110
}

/// The List's header on an iPad: Notebook, Collections, Sources and Updated
/// sort on a tap — the shown one turns round, its chevron saying which way —
/// and Status reads.
private struct MobileNotebookListHeader: View {
    let order: NotebooksHomeOrder
    let onSort: (NotebooksHomeSort) -> Void

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            // The row's mark.
            Color.clear.frame(width: 32, height: 1)
            button("Notebook", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            button("Collections", key: .uncategorized)
                .frame(width: MobileNotebookListColumn.collections, alignment: .leading)
            button("Sources", key: .sources)
                .frame(width: MobileNotebookListColumn.sources, alignment: .trailing)
            button("Updated", key: .recent)
                .frame(width: MobileNotebookListColumn.updated, alignment: .leading)
            Text("Status")
                .frame(width: MobileNotebookListColumn.status, alignment: .leading)
                .foregroundStyle(.secondary)
        }
        .font(.footnote.weight(.semibold))
        .textCase(nil)
        // The row's disclosure chevron.
        .padding(.trailing, MobileDesign.Spacing.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Columns")
    }

    private func button(_ title: String, key: NotebooksHomeSort) -> some View {
        let isSorted = order.sort == key
        return Button {
            onSort(key)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .foregroundStyle(isSorted ? Color.primary : Color.secondary)
                if isSorted {
                    Image(systemName: order.isAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(minHeight: MobileDesign.Metrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Sort by \(title.lowercased())")
        .accessibilityValue(isSorted ? (order.isAscending ? "Ascending" : "Descending") : "")
        .accessibilityIdentifier("notebooks.list.sort.\(key.rawValue)")
    }
}

/// One notebook in the List: its mark (its cover drawn bare, else its emoji
/// on its colour), its name with a pin when pinned, then on a phone one
/// line under the name — its collections, "12 sources" and when it was
/// last worked in — and on an iPad the Mac's columns.
private struct MobileNotebookListRow: View {
    let notebook: MobileCloudNotebook
    let collections: [NotebookCollection]
    let sourceCount: Int
    let workedAt: Date
    let isPinned: Bool
    let showsColumns: Bool

    var body: some View {
        let title = NotebookTitle(notebook.title)
        let name = title.text.isEmpty ? "Untitled notebook" : title.text
        HStack(spacing: MobileDesign.Spacing.medium) {
            // The notebook's cover once the phone holds it, with nothing behind it; its emoji on its
            // colour until then (D53), as the Mac's List row.
            MobileNotebookIconView(notebookID: notebook.id, size: 32, cornerRadius: 8, plate: NotebookTint.color(for: notebook.id)) {
                Text(title.displayIcon)
                    .font(.body)
            }
            .accessibilityHidden(true)

            if showsColumns {
                nameLine(name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                collectionsCell
                    .frame(width: MobileNotebookListColumn.collections, alignment: .leading)
                Text(sourceCount.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: MobileNotebookListColumn.sources, alignment: .trailing)
                Text(updatedText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: MobileNotebookListColumn.updated, alignment: .leading)
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: MobileNotebookListColumn.status, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    nameLine(name)
                    Text(compactLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .font(showsColumns ? .subheadline : .body)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func nameLine(_ name: String) -> some View {
        HStack(spacing: MobileDesign.Spacing.xSmall + 2) {
            Text(name)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Pinned")
            }
        }
    }

    /// One or two collections as chips, more as a count.
    @ViewBuilder
    private var collectionsCell: some View {
        if let count = NotebookListCollections.countText(collections) {
            Text(count)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: MobileDesign.Spacing.xSmall) {
                ForEach(NotebookListCollections.chips(collections), id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
        }
    }

    private var updatedText: String {
        let when = NotebookCardLine.when(workedAt, now: Date(), calendar: .current, locale: .current)
        return when.prefix(1).uppercased() + when.dropFirst()
    }

    private var statusText: String {
        // The phone lists only active notebooks, and which of them a team
        // holds a copy of is read from the team's own zone, live, by Share:
        // Status says Empty here, and Archived and Shared on the Mac.
        NotebookListStatus.text(isArchived: notebook.isArchived, isShared: false, sourceCount: sourceCount)
    }

    /// "Acme Journal Club · 12 sources · Yesterday". "No sources" says what the
    /// Status column's Empty does.
    private var compactLine: String {
        let names = NotebookListCollections.chips(collections).joined(separator: ", ")
        let count = sourceCount
        return [
            NotebookListCollections.countText(collections) ?? (names.isEmpty ? nil : names),
            count == 0 ? "No sources" : (count == 1 ? "1 source" : "\(count.formatted()) sources"),
            updatedText,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
