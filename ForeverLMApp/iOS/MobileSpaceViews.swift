import SwiftUI

// The Space on the iPhone and iPad (docs/docs-design.md, "The Space"; the product owner, 2026-10-07: "yes build
// the space on iphone too", "docs etc all has to work there too"): the Mac's Space sidebar as one list —
// New page, All, Pages, Sites, Pinned, Recents, the spaces and Trash at the foot — each place a list of
// its pages with a page's subpages under it, and a page open in the editor the Mac runs
// (`MobilePageScreen`). A phone pushes each on the shell's stack, as typed routes; a screen with the
// room draws the three side by side as a split view. Which pages a place lists, their order and their
// nesting are `MobileSpaceListing`'s; every act is the store's.

/// Whether the Space is drawn as a split view (sidebar, list, page) rather than pushed screen by
/// screen: a screen in regular width **and** regular height, as Home's gallery asks
/// (`MobileNotebookColumnLayout.usesGallery`). A large phone held sideways, regular width and compact
/// height, keeps the pushed screens; an iPhone Duo opened joins the iPad.
enum MobileSpaceLayout {
    static func usesSplitView(isRegularWidth: Bool, isRegularHeight: Bool) -> Bool {
        isRegularWidth && isRegularHeight
    }
}

/// Where the Space's screens open what the learner chose: on a phone the shell's stack, in the split
/// view its columns.
struct MobileSpaceNavigation {
    var openPage: (String) -> Void = { _ in }
    var openPlace: (MobileSpacePlace) -> Void = { _ in }
    /// A page put away (Move to Trash, Delete Forever) leaves the screen that shows it.
    var closePage: (String) -> Void = { _ in }
    /// The second page in the first's place, as a daily note steps to another day.
    var replacePage: (_ current: String, _ next: String) -> Void = { _, _ in }
}

extension MobileSpaceNavigation {
    /// The Space on a phone: each place and page pushed on the shell's stack.
    static func stack(_ path: Binding<[MobileShellRoute]>) -> MobileSpaceNavigation {
        MobileSpaceNavigation(
            openPage: { id in path.wrappedValue.append(.page(id)) },
            openPlace: { place in path.wrappedValue.append(.space(place)) },
            closePage: { id in
                if path.wrappedValue.last?.opensPage(id) == true { path.wrappedValue.removeLast() }
            },
            replacePage: { current, next in
                if path.wrappedValue.last?.opensPage(current) == true {
                    path.wrappedValue[path.wrappedValue.count - 1] = .page(next)
                } else {
                    path.wrappedValue.append(.page(next))
                }
            }
        )
    }
}

private struct MobileSpaceNavigationKey: EnvironmentKey {
    static let defaultValue = MobileSpaceNavigation()
}

private struct MobileSpaceNotebookTitlesKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    var spaceNavigation: MobileSpaceNavigation {
        get { self[MobileSpaceNavigationKey.self] }
        set { self[MobileSpaceNavigationKey.self] = newValue }
    }

    /// The notebooks the phone knows, by id: the column a page row names its notebook in, and what
    /// `[[` and `@` offer beside the pages.
    var spaceNotebookTitles: [String: String] {
        get { self[MobileSpaceNotebookTitlesKey.self] }
        set { self[MobileSpaceNotebookTitlesKey.self] = newValue }
    }
}

// MARK: - The Space on a phone

/// One step of the Space on the shell's stack: with no place the sidebar's list, with one that place's
/// pages.
struct MobileSpaceScreen: View {
    let place: MobileSpacePlace?

    var body: some View {
        if let place {
            MobileSpaceAvailability {
                MobileSpacePlaceList(place: place)
            }
        } else {
            MobileSpaceAvailability {
                MobileSpaceSidebar()
            }
            .navigationTitle("Space")
        }
    }
}

/// The Space once the phone can show it: a spinner while the replica is read the first time, and the
/// one sentence generation 1 gets, since its pages open only from the new iCloud store.
struct MobileSpaceAvailability<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(MobileSpaceStore.self) private var store
    @State private var hasRead = false

    var body: some View {
        Group {
            if store.isAvailable, hasRead || !store.pages.isEmpty {
                content()
            } else if !hasRead {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Not on This iPhone Yet", systemImage: "icloud.and.arrow.down")
                } description: {
                    Text(MobileSpaceError.unavailable.localizedDescription)
                }
                .accessibilityIdentifier("space.unavailable")
            }
        }
        .task {
            // Read once here unless a read already gave the pages: an empty list while the first read
            // runs would say "No pages yet" about a library still arriving.
            if !store.isAvailable || (store.isLoading && store.pages.isEmpty) { await store.refresh() }
            hasRead = true
        }
    }
}

// MARK: - The sidebar

/// The Mac's Space sidebar as one list, in its order: **New page** (and **Daily Notes**, the Mac's
/// ⇧⌘D, which opens today's note), **All**, **Pages**, **Sites** and **Google Drive** while it holds a
/// linked Google Doc, then **Pinned**, **Recents** (the first few this device opened), **Spaces** (the
/// learner's own, then the teams, and New Space…) and **Trash** at the foot. A search finds pages in
/// every place by name. On a phone each row is a link pushed on the shell's stack; in the split view a
/// place is the sidebar's selection.
struct MobileSpaceSidebar: View {
    /// The split view's lit place; nil on a phone.
    var selection: Binding<MobileSpacePlace?>? = nil

    @Environment(MobileSpaceStore.self) private var store
    @Environment(MobileSpaceRecents.self) private var recents
    @Environment(\.spaceNavigation) private var navigation
    @State private var actions = MobileSpaceActions()
    @State private var query = ""

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        List(selection: selection) {
            if isSearching {
                searchResults
            } else {
                Section {
                    Button {
                        actions.newPage(store: store, navigation: navigation, inSpace: selection?.wrappedValue?.pageSpaceID)
                    } label: {
                        Label("New page", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("space.sidebar.newPage")
                    Button {
                        actions.openDailyNote(DailyNote.dayKey(for: Date()), store: store, navigation: navigation)
                    } label: {
                        Label("Daily Notes", systemImage: "calendar")
                    }
                    .accessibilityIdentifier("space.sidebar.dailyNotes")
                }
                Section {
                    ForEach(places, id: \.self) { place in
                        placeRow(place)
                    }
                }
                pinnedSection
                recentsSection
                spacesSection
                Section {
                    placeRow(.trash)
                }
            }
        }
        .searchable(text: $query, prompt: "Search pages")
        .refreshable { await store.refresh() }
        .spaceActions(actions)
        .accessibilityIdentifier("space.sidebar")
    }

    /// All, Pages, Sites, and Google Drive while a Google Doc is linked: the phone links none, so an
    /// empty Drive would only ever say so.
    private var places: [MobileSpacePlace] {
        MobileSpacePlace.places.filter { place in
            place != .drive || store.pages.contains { !$0.isTrashed && $0.spaceKind == .googleDoc }
        }
    }

    @ViewBuilder
    private func placeRow(_ place: MobileSpacePlace) -> some View {
        let label = Label {
            Text(MobileSpacePlaceTitle.title(place, store: store))
        } icon: {
            MobileSpacePlaceGlyph(place: place, store: store)
        }
        Group {
            if selection != nil {
                label.tag(place)
            } else {
                NavigationLink(value: MobileShellRoute.space(place)) { label }
            }
        }
        .accessibilityIdentifier("space.sidebar.\(place.key)")
    }

    @ViewBuilder
    private func pageRow(_ page: MobileSpacePage, identifier: String) -> some View {
        let label = Label {
            Text(MobileSpacePageTitle.display(page))
                .lineLimit(1)
        } icon: {
            MobileSpacePageGlyph(page: page)
        }
        Group {
            if selection != nil {
                Button { navigation.openPage(page.id) } label: { label }
                    .tint(.primary)
            } else {
                NavigationLink(value: MobileShellRoute.page(page.id)) { label }
            }
        }
        .spaceRowActions(page)
        .accessibilityIdentifier(identifier)
    }

    /// ChatGPT's **Pinned**, newest pin first, above Recents.
    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = MobileSpaceListing.pinned(store.pages, organization: store.organization)
        if !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned) { page in
                    pageRow(page, identifier: "space.sidebar.pinned.\(page.id)")
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        let shown = recents.shown(among: store.pages)
        if !shown.isEmpty {
            Section("Recents") {
                ForEach(shown) { page in
                    pageRow(page, identifier: "space.sidebar.recent.\(page.id)")
                }
            }
        }
    }

    /// The learner's spaces by name (a leading emoji is the row's icon), then the teams, which are the
    /// shared spaces, and New Space…. A space's own rows rename and delete it.
    private var spacesSection: some View {
        Section("Spaces") {
            ForEach(store.organization.spaces) { space in
                placeRow(.space(space.id))
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") { actions.beginRenameSpace(space) }
                        Button("Delete Space…", systemImage: "trash", role: .destructive) { actions.deletingSpace = space }
                    }
            }
            ForEach(store.teams) { team in
                placeRow(.team(team.id))
            }
            Button {
                actions.beginNewSpace(moving: [])
            } label: {
                Label("New Space…", systemImage: "plus")
            }
            .accessibilityIdentifier("space.sidebar.newSpace")
        }
    }

    /// Every place's pages by name, from All, the daily notes too: a search is the learner asking for
    /// something by its name.
    @ViewBuilder
    private var searchResults: some View {
        let found = MobileSpaceListing.pages(in: .all, from: store.pages, organization: store.organization, query: query)
        if found.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(found) { page in
                    pageRow(page, identifier: "space.search.\(page.id)")
                }
            }
        }
    }
}

// MARK: - A place's pages

/// What one place lists, as the Mac's Space list draws it: each page with its tile, its name, its
/// notebook and ChatGPT's short date, newest made first (Date Created, so an edit never moves a page;
/// the ⋯ sorts by Last Activity or Name); in All, Pages and a space a page with subpages has a chevron
/// and its subpages under it while open. A search narrows the list by name and flattens it. Tap opens
/// the page; the row's menu and swipes hold the rest.
struct MobileSpacePlaceList: View {
    let place: MobileSpacePlace
    /// The split view's open page; nil on a phone, where every row is a link.
    var selection: Binding<String?>? = nil

    @Environment(MobileSpaceStore.self) private var store
    @Environment(\.spaceNavigation) private var navigation
    @Environment(\.spaceNotebookTitles) private var notebookTitles
    @Environment(\.dismiss) private var dismiss
    @State private var actions = MobileSpaceActions()
    @State private var query = ""
    /// Which pages show their subpages: this device's, as the Mac's `space.pagesExpanded` is.
    @AppStorage(MobileSpaceExpansion.defaultsKey) private var expandedRaw = ""
    @AppStorage("ios.space.sort") private var sortRaw = MobileSpaceSort.standard.rawValue

    private var sort: MobileSpaceSort { MobileSpaceSort(rawValue: sortRaw) ?? .standard }
    private var title: String { MobileSpacePlaceTitle.title(place, store: store) }

    var body: some View {
        let shown = MobileSpaceListing.pages(in: place, from: store.pages, organization: store.organization, query: query, sort: sort)
        let nests = MobileSpaceListing.nests(place, query: query, organization: store.organization)
        let entries = MobileSpaceListing.entries(shown, nests: nests, organization: store.organization,
                                                 expanded: MobileSpaceExpansion.ids(expandedRaw))
        // Every row keeps the chevron's column while any has one, so the tiles line up.
        let reservesDisclosure = nests && entries.contains { $0.hasChildren }
        List(selection: selection) {
            ForEach(entries) { entry in
                row(entry, reservesDisclosure: reservesDisclosure)
            }
        }
        .overlay {
            if entries.isEmpty { emptyState }
        }
        .animation(.easeInOut(duration: 0.2), value: entries.map(\.id))
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Search by name")
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                listMenu
                if offersNewPage {
                    Button {
                        actions.newPage(store: store, navigation: navigation, inSpace: place.pageSpaceID)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New page")
                    .accessibilityIdentifier("space.list.newPage")
                }
            }
        }
        .spaceActions(actions)
        // A space deleted here or on another device: the list shows All in its place, as the Mac's does.
        .onChange(of: isGoneSpace) { _, gone in
            guard gone else { return }
            if selection != nil { navigation.openPlace(.all) } else { dismiss() }
        }
        .accessibilityIdentifier("space.list.\(place.key)")
    }

    private var isGoneSpace: Bool {
        guard let id = place.pageSpaceID, store.isAvailable else { return false }
        return store.organization.space(id) == nil
    }

    /// New page files in a space while it is the place, as the Mac's New ▾ › Page does; Sites, Google
    /// Drive, a team and Trash make none.
    private var offersNewPage: Bool {
        switch place {
        case .all, .pages, .space: return true
        case .sites, .drive, .trash, .team: return false
        }
    }

    @ViewBuilder
    private func row(_ entry: MobileSpaceListing.Entry, reservesDisclosure: Bool) -> some View {
        let content = MobileSpacePageRow(
            page: entry.page,
            detail: detail(entry.page),
            level: entry.level,
            reservesDisclosure: reservesDisclosure,
            disclosure: entry.hasChildren ? MobileSpacePageRow.Disclosure(isExpanded: entry.isExpanded) { toggle(entry.page.id) } : nil,
            isSelected: selection?.wrappedValue == entry.page.id
        )
        Group {
            if selection != nil {
                content.tag(entry.page.id)
            } else {
                NavigationLink(value: MobileShellRoute.page(entry.page.id)) { content }
            }
        }
        .spaceRowActions(entry.page)
        .accessibilityIdentifier("space.item.\(entry.page.id)")
    }

    private func toggle(_ pageID: String) {
        var ids = MobileSpaceExpansion.ids(expandedRaw)
        if ids.remove(pageID) == nil { ids.insert(pageID) }
        expandedRaw = MobileSpaceExpansion.raw(ids)
    }

    /// The row's second line: the notebook the page is in, else the team it is shared with, then its
    /// short date — when it went to Trash, in Trash.
    private func detail(_ page: MobileSpacePage) -> String {
        var parts: [String] = []
        if let notebookID = page.notebookIDs.first, let name = notebookTitles[notebookID] {
            parts.append(name)
        } else if let teamID = page.teamID, place != .team(teamID), let team = store.teams.first(where: { $0.id == teamID }) {
            parts.append(team.name)
        }
        parts.append(MobileSpaceDateText.short(MobileSpaceListing.date(of: page, in: place, sort: sort)))
        return parts.joined(separator: " · ")
    }

    /// Sort By, a space's Rename… and Delete Space…, and Trash's Empty Trash…, as the Mac's view menu
    /// and its place's pill hold them.
    private var listMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortRaw) {
                ForEach(MobileSpaceSort.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            if let id = place.pageSpaceID, let space = store.organization.space(id) {
                Section {
                    Button("Rename…", systemImage: "pencil") { actions.beginRenameSpace(space) }
                    Button("Delete Space…", systemImage: "trash", role: .destructive) { actions.deletingSpace = space }
                }
            }
            if place == .trash {
                let trashed = store.pages.filter { $0.isTrashed && $0.isOwn }
                Section {
                    Button("Empty Trash…", systemImage: "trash.slash", role: .destructive) { actions.deletingForever = trashed }
                        .disabled(trashed.isEmpty)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("View options")
        .accessibilityValue("Sorted by \(sort.title)")
        .accessibilityIdentifier("space.list.menu")
    }

    /// Short, in the Mac's words: a search that found nothing, an empty Trash or place, and New Page
    /// where a page can be made.
    @ViewBuilder
    private var emptyState: some View {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            switch place {
            case .trash:
                ContentUnavailableView("Trash is empty", systemImage: "trash")
            case .drive:
                ContentUnavailableView("No Google Docs linked", systemImage: "externaldrive")
            case .sites:
                ContentUnavailableView("No sites yet", systemImage: "globe")
            case .team(let id):
                ContentUnavailableView("Nothing shared with \(store.teams.first { $0.id == id }?.name ?? "this space") yet",
                                       systemImage: "person.2")
            case .space, .pages, .all:
                ContentUnavailableView {
                    Label(place == .all ? "Nothing here yet" : "No pages yet",
                          systemImage: place.pageSpaceID == nil ? "doc.text" : "square.stack")
                } actions: {
                    Button("New Page") {
                        actions.newPage(store: store, navigation: navigation, inSpace: place.pageSpaceID)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

// MARK: - Rows

/// One page in a list: its tile in its kind's colour, its name with a team's and a draft's marks, and
/// a quiet second line. A page with subpages leads with a chevron; a subpage is indented under it.
struct MobileSpacePageRow: View {
    struct Disclosure {
        let isExpanded: Bool
        let toggle: () -> Void
    }

    let page: MobileSpacePage
    var detail: String? = nil
    var level = 0
    var reservesDisclosure = false
    var disclosure: Disclosure? = nil
    /// The split view's open page, drawn on the accent: its tile and chevron in white.
    var isSelected = false

    /// How far each level of subpage is drawn in, and the chevron's column.
    private static let indentPerLevel: CGFloat = 16
    private static let disclosureWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 12) {
            if reservesDisclosure || level > 0 {
                HStack(spacing: 0) {
                    Color.clear.frame(width: CGFloat(level) * Self.indentPerLevel, height: 1)
                    if let disclosure {
                        Button(action: disclosure.toggle) {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
                                .frame(width: Self.disclosureWidth, height: MobileDesign.Metrics.minimumTouchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .tint(isSelected ? .white : Color(uiColor: .secondaryLabel))
                        .accessibilityLabel(disclosure.isExpanded ? "Hide subpages of \(MobileSpacePageTitle.display(page))"
                                                                  : "Show subpages of \(MobileSpacePageTitle.display(page))")
                        .accessibilityIdentifier("space.item.\(page.id).disclosure")
                    } else {
                        Color.clear.frame(width: Self.disclosureWidth, height: 1)
                    }
                }
            }
            MobileSpaceTile(page: page, onAccent: isSelected)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(MobileSpacePageTitle.display(page))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if page.teamID != nil {
                        Image(systemName: "person.2")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Shared")
                    }
                    if page.isDraft {
                        Text("Draft")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// A page's tile: its kind's glyph on a soft square of the kind's colour, as the Mac's list draws it —
/// blue for a page, as ChatGPT's — and a calendar for a daily note.
struct MobileSpaceTile: View {
    let page: MobileSpacePage
    var size: CGFloat = 34
    /// Drawn on a selected row's accent, where the kind's colour would vanish.
    var onAccent = false

    var body: some View {
        let tint = onAccent ? Color.white : MobileSpaceKindStyle.tint(page)
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.opacity(onAccent ? 0.22 : 0.13))
            .overlay {
                Image(systemName: MobileSpaceKindStyle.symbol(page))
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(tint)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A page's glyph alone, monochrome like the sidebar's other icons.
struct MobileSpacePageGlyph: View {
    let page: MobileSpacePage

    var body: some View {
        Image(systemName: MobileSpaceKindStyle.symbol(page))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// A place's icon in the sidebar: the place's glyph, a space's leading emoji (else a quiet stack), and
/// a team's first letter on a soft square.
struct MobileSpacePlaceGlyph: View {
    let place: MobileSpacePlace
    let store: MobileSpaceStore

    var body: some View {
        switch place {
        case .space(let id):
            if let icon = store.organization.space(id).flatMap({ NotebookTitle($0.name).icon }) {
                Text(icon)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: place.symbolName)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        case .team(let id):
            let name = store.teams.first { $0.id == id }?.name ?? ""
            Text(String(name.prefix(1)).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
        default:
            Image(systemName: place.symbolName)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Words and marks

/// A place's name: its own for a place, a space's without its emoji, a team's.
enum MobileSpacePlaceTitle {
    @MainActor
    static func title(_ place: MobileSpacePlace, store: MobileSpaceStore) -> String {
        switch place {
        case .space(let id):
            return store.organization.space(id).map { NotebookTitle($0.name).text } ?? place.title
        case .team(let id):
            return store.teams.first { $0.id == id }?.name ?? place.title
        default:
            return place.title
        }
    }
}

/// What a row and the page call a page: its title, or Untitled Page while it has none.
enum MobileSpacePageTitle {
    static func display(_ page: MobileSpacePage) -> String {
        let trimmed = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? MobileSpaceListing.untitledTitle : trimmed
    }

    /// Whether a title is the placeholder a new page is given (and the name pages had before they
    /// were called pages), which the page's title field shows as its placeholder.
    static func isPlaceholder(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == MobileSpaceListing.untitledTitle || trimmed == "Untitled Doc"
    }
}

/// Each kind's colour and glyph, the Mac's (`SpaceKindStyle`).
enum MobileSpaceKindStyle {
    static func tint(_ page: MobileSpacePage) -> Color {
        switch page.spaceKind {
        case .page: return Color(red: 0.03, green: 0.54, blue: 0.93)
        case .googleDoc: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .site: return .teal
        case .reading: return .purple
        }
    }

    static func symbol(_ page: MobileSpacePage) -> String {
        if page.isDailyNote { return "calendar" }
        switch page.spaceKind {
        case .page: return "doc.text.fill"
        case .googleDoc: return "doc.richtext"
        case .site: return "globe"
        case .reading: return "text.book.closed.fill"
        }
    }
}

/// ChatGPT's short dates, the Mac's (`SpaceDateText`): "now", "8m", "8h", "2d", then the day.
enum MobileSpaceDateText {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// Which pages show their subpages in a list: this device's own arrangement, kept as ids one to a
/// line, and opened when New Subpage makes a page under one.
enum MobileSpaceExpansion {
    static let defaultsKey = "ios.space.pagesExpanded.v1"

    static func ids(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    static func raw(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n")
    }

    static func expand(_ pageID: String, defaults: UserDefaults = .standard) {
        var current = ids(defaults.string(forKey: defaultsKey) ?? "")
        guard current.insert(pageID).inserted else { return }
        defaults.set(raw(current), forKey: defaultsKey)
    }
}

// MARK: - The split view

/// What the Space opens with when the split view is presented: a place, and a page open in it.
struct MobileSpaceCoverRequest: Identifiable, Equatable {
    let id = UUID()
    var place: MobileSpacePlace = .all
    var pageID: String?
}

/// The Space on a screen with room, the app's one split view: the sidebar of places, the place's
/// pages, and the open page, as the Mac draws the sidebar beside a list or a page. A link to another
/// page opens it in the page's column; one to a source or a notebook closes the Space and follows it
/// in the shell, where the Reader and the notebooks live.
struct MobileSpaceSplitView: View {
    /// Closes the Space; nil in the harness, which has nothing under it.
    var onClose: (() -> Void)?
    /// A link the Space does not open itself, followed under it.
    var onFollow: (MobileDeepLink) -> Void = { _ in }

    @Environment(MobileSpaceStore.self) private var store
    @State private var place: MobileSpacePlace?
    @State private var pageID: String?

    init(request: MobileSpaceCoverRequest = MobileSpaceCoverRequest(), onClose: (() -> Void)? = nil,
         onFollow: @escaping (MobileDeepLink) -> Void = { _ in }) {
        self.onClose = onClose
        self.onFollow = onFollow
        _place = State(initialValue: request.place)
        _pageID = State(initialValue: request.pageID)
    }

    var body: some View {
        NavigationSplitView {
            MobileSpaceAvailability {
                MobileSpaceSidebar(selection: $place)
            }
            .navigationTitle("Space")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("space.close")
                    }
                }
            }
        } content: {
            if let place, store.isAvailable {
                MobileSpacePlaceList(place: place, selection: $pageID)
                    .id(place)
            }
        } detail: {
            if let pageID {
                MobilePageScreen(pageID: pageID)
                    .id(pageID)
            } else {
                Text("No page open")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.spaceNavigation, MobileSpaceNavigation(
            openPage: { id in open(id) },
            openPlace: { next in place = next },
            closePage: { id in if pageID == id { pageID = nil } },
            replacePage: { _, next in open(next) }
        ))
        .environment(\.openURL, OpenURLAction { url in follow(url) })
        .task {
            // Opened on a page (today's note from Home): its place is the one that lists it.
            if let pageID { open(pageID) }
        }
    }

    /// A page opened from a row, a link or New page: its place stays lit while it lists the page, else
    /// the place the page is listed under (`MobileSpacePlace.listing`).
    private func open(_ id: String) {
        pageID = id
        guard let page = store.pages.first(where: { $0.id == id }) else { return }
        if let place, MobileSpaceListing.lists(place, page, organization: store.organization) { return }
        place = MobileSpacePlace.listing(page, within: place, organization: store.organization)
    }

    private func follow(_ url: URL) -> OpenURLAction.Result {
        guard let link = MobileDeepLink.parse(url) else {
            // An Idea or a chat is the Mac's; the web goes to the browser.
            return url.scheme?.lowercased() == MobileDeepLink.productScheme ? .handled : .systemAction
        }
        if case .doc(let id) = link {
            open(id)
        } else {
            onFollow(link)
        }
        return .handled
    }
}
