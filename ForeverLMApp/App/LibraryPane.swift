import SwiftUI
import AppKit

extension Notification.Name {
    /// The View menu's Library (⇧⌘L): the full-window Library, in the window
    /// whose id is the object.
    static let openStudioLibrary = Notification.Name("openStudioLibrary")
}

// MARK: - The two places of the library, as the View menu names them

/// The View menu's ways to the shell's two library places, named once so the
/// menu, the rail and their tests agree: **Space** (⌘P), the Space's All list,
/// where every notebook is listed (the Notebooks home was ⌘P until 2026-10-09),
/// and **Library** (⇧⌘L), the full-window Library. Inside a notebook the
/// library is its Sources column's search.
enum StudioShellCommand: CaseIterable {
    case space
    case library

    var title: String {
        switch self {
        case .space: return "Space"
        case .library: return "Library"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .space: return "p"
        case .library: return "l"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .space: return .command
        case .library: return [.command, .shift]
        }
    }
}

// MARK: - The Sources list's two layouts

/// How the library's Sources list (`StudioSidebar`) lays itself out: compact
/// while the Library is docked narrow beside another pane, or across the
/// full-window Library, where its rows carry more of what each source is —
/// when it was added, the notebooks it is in — and a multi-selection gets a
/// bar of its own. One list either way: the same tabs, search, rows, menus,
/// imports and attention rows; only the layout differs.
enum SourcesListLayout: Equatable, Sendable {
    case sidebar
    case wide
}

private struct SourcesListLayoutKey: EnvironmentKey {
    static let defaultValue: SourcesListLayout = .sidebar
}

extension EnvironmentValues {
    var sourcesListLayout: SourcesListLayout {
        get { self[SourcesListLayoutKey.self] }
        set { self[SourcesListLayoutKey.self] = newValue }
    }
}

// MARK: - The full-window Library

/// The Library (decisions v5, 2; docs/notebooks-design.md, "The Library"): the
/// library's Sources list as a center pane, the window's one library list —
/// every kind's tab, search, the lists and their row menus, imports and
/// attention rows. Clicked in the rail it fills the window, with wider rows
/// that say when each source came in and which notebooks hold it, and a bar
/// for a multi-selection; dragged to the window's edge it docks beside the
/// pane in use and draws the compact list, whose rows drag into a chat or a
/// canvas. A center pane like any other: its close ×, Open Beside, Open in
/// Other Window; a source clicked in it opens in the Reader beside it
/// (`clearReaderSurfaces`). Opened from a notebook it leaves the notebook as
/// the home does; the notebook's rail row brings it back. It has no ‹ of its
/// own (product owner, 2026-10-12: "i don't want this back button for the
/// library anymore").
struct LibraryPane: View {
    /// Below this width the wide rows have no room for what they add.
    private static let wideLayoutMinimumWidth: CGFloat = 560

    @State private var isNarrow = false

    var body: some View {
        NavigationStack {
            StudioSidebar()
                .equatable()
        }
        // The kind tabs draw in flow under the pane's chrome line.
        .environment(\.studioTitlebarBandHeight, nil)
        .environment(\.sourcesListLayout, isNarrow ? .sidebar : .wide)
        .onGeometryChange(for: Bool.self, of: { $0.size.width < Self.wideLayoutMinimumWidth }) { isNarrow = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .studioChromeLineHeader { header }
        .studioCenterTabCloseChrome(for: .library)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
        .accessibilityIdentifier("library.pane")
    }

    /// The pane's name.
    private var header: some View {
        HStack(spacing: 6) {
            Text("Library")
                .zoomedSystemFont(size: 13, weight: .semibold)
                .lineLimit(1)
                .textSelection(.disabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - The bulk bar

/// The Library's bar for a multi-selection (two rows or more; one row has its
/// own menu): Add to Notebook ▸, New Notebook with N Sources…, Mark Read or
/// Mark Unread, Hide and Remove…, each what the row menu does to a selection,
/// through the same store APIs (`StudioViewModel.performLibraryBulkAction`).
/// Hide is the library's archive — chat, search and reviews still read a
/// hidden source, and Hidden Items brings it back; Remove… asks first, as the
/// list's Delete key does. A view of its own that reads the selection itself,
/// so a click in the list never re-runs the list around it.
struct LibraryBulkBar: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(StudioSidebarStore.self) private var sidebar
    /// The sidebar's New Notebook sheet, for the sources the selection stands for.
    let onNewNotebook: ([String]) -> Void
    /// The sidebar's Remove… dialog, for the selection's rows.
    let onRemove: (Set<String>) -> Void

    var body: some View {
        let selection = windowState.sidebarSelectedSourceIDs
        if selection.count > 1 {
            bar(selection)
                .transition(.opacity)
        }
    }

    private func bar(_ selection: Set<String>) -> some View {
        let inBooks = sidebar.sidebarTab == .books
        let readToggle = LibraryBulkAction.readToggle(
            readStates: vm.libraryBulkReadStates(for: selection, inBooksTab: inBooks)
        )
        let takesNotebooks = !vm.isActiveLibraryReadOnly
        let notebooks = vm.notebooks.filter { vm.importableNotebook($0.id) != nil }
        let books = inBooks ? vm.sidebarRemovalTargets(for: selection, expandingBooks: true).bookGroups.count : 0
        let newNotebookTitle = books > 1
            ? NotebookMembershipMenu.newNotebookTitle(bookCount: books)
            : NotebookMembershipMenu.newNotebookTitle(sourceCount: selection.count)
        return HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .zoomedSystemFont(size: 12, weight: .semibold)
                .monospacedDigit()
                .textSelection(.disabled)
            if takesNotebooks {
                Menu {
                    ForEach(notebooks) { notebook in
                        Button(NotebookTitle(notebook.title).text) {
                            perform(.addToNotebook(notebook.id), on: selection, inBooks: inBooks)
                        }
                    }
                } label: {
                    Label("Add to Notebook", systemImage: "folder.badge.plus")
                        .zoomedSystemFont(size: 12)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHighlight()
                .disabled(notebooks.isEmpty)
                .help("Add the selected sources to a notebook")
                .accessibilityIdentifier("library.bulk.addToNotebook")
                if let newNotebookTitle {
                    // "N selected" already gives the count, and the bar's
                    // labels stay on one line.
                    barButton("New Notebook", systemImage: "plus.rectangle.on.folder", identifier: "library.bulk.newNotebook") {
                        let ids = vm.inWindow(windowState) {
                            vm.libraryBulkSourceIDs(for: selection, inBooksTab: inBooks)
                        }
                        onNewNotebook(ids)
                    }
                    .help(newNotebookTitle)
                }
            }
            if let readToggle {
                barButton(
                    readToggle == .markRead ? "Mark Read" : "Mark Unread",
                    systemImage: readToggle == .markRead ? "checkmark.circle" : "circle",
                    identifier: "library.bulk.read"
                ) {
                    perform(readToggle, on: selection, inBooks: inBooks)
                }
            }
            barButton("Hide", systemImage: "eye.slash", identifier: "library.bulk.hide") {
                perform(.hide, on: selection, inBooks: inBooks)
            }
            .help("Take these off the lists. Chat, search and reviews still use them, and Hidden Items brings them back.")
            barButton("Remove…", systemImage: "trash", identifier: "library.bulk.remove") {
                onRemove(selection)
            }
            Spacer(minLength: 0)
            Button {
                windowState.sidebarSelectedSourceIDs = []
            } label: {
                Image(systemName: "xmark")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help("Clear the selection")
            .accessibilityLabel("Clear the selection")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(selection.count) selected")
        .accessibilityIdentifier("library.bulk")
    }

    private func barButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .zoomedSystemFont(size: 12)
                .lineLimit(1)
        }
        .buttonStyle(.hoverWash)
        .accessibilityIdentifier(identifier)
    }

    private func perform(_ action: LibraryBulkAction, on selection: Set<String>, inBooks: Bool) {
        let window = windowState
        Task { await vm.performLibraryBulkAction(action, on: selection, inBooksTab: inBooks, in: window) }
    }
}

/// What a wide row adds under its metadata: when the source came into the
/// library, shown while the pointer is over the row (product owner, 2026-10-06,
/// "kind of like the chatgpt app": a date down every row was one more column
/// to read past). The line keeps its height either way, so a row does not
/// grow under the pointer. A podcast episode or a meeting already says its
/// date. The notebooks holding the source are on its right-click menu, In
/// Notebooks, not on the row (product owner, 2026-10-03: "maybe no need to show by
/// default in which notebook a source exists").
struct LibraryRowDetails: View {
    let article: StudioArticle
    var isRowHovered = false

    private var showsAddedDate: Bool {
        article.sourceType != .podcast && article.sourceType != .meeting
    }

    var body: some View {
        if showsAddedDate {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text("Added \(article.dateAdded.formatted(date: .abbreviated, time: .omitted))")
                    .zoomedSystemFont(size: 10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.disabled)
                    .opacity(isRowHovered ? 1 : 0)
            }
        }
    }
}
