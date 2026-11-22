import SwiftUI
import AppKit

extension Notification.Name {
    /// The View menu's Library (⇧⌘L): the full-window Library, in the window
    /// whose id is the object.
    static let openStudioLibrary = Notification.Name("openStudioLibrary")
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
    /// Inside a notebook's Sources column (`NotebookLibraryBrowser`): one
    /// line a source and the kinds as words, as NotebookLM's column reads.
    /// Otherwise the narrow list.
    case compact
}

private struct SourcesListLayoutKey: EnvironmentKey {
    static let defaultValue: SourcesListLayout = .sidebar
}

private struct SourcesListHidesIdleSearchKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sourcesListLayout: SourcesListLayout {
        get { self[SourcesListLayoutKey.self] }
        set { self[SourcesListLayoutKey.self] = newValue }
    }

    /// The list draws no search row of its own while nothing is typed in it:
    /// inside a notebook's Sources column, whose own field searches
    /// (`NotebookLibraryBrowser`). Words already in the window's Library
    /// search keep the row, so a filter is never applied out of sight.
    var sourcesListHidesIdleSearch: Bool {
        get { self[SourcesListHidesIdleSearchKey.self] }
        set { self[SourcesListHidesIdleSearchKey.self] = newValue }
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
///
/// One list, with no To Read or Follow up scopes beside it (product owner,
/// 2026-11-07: "Ideally just one, and somehow differentiate otherwise, like
/// how many cards there are"). Each row says where its source stands: an
/// unread title in the primary colour and a read one in grey with its mark,
/// and one quiet word for its cards, whose click lists them and the
/// passages still waiting to be followed up (`SourceCardsTrailer`). A source
/// with nothing of these left is done, and reads quietest.
struct LibraryPane: View {
    /// Below this width the wide rows have no room for what they add.
    private static let wideLayoutMinimumWidth: CGFloat = 560

    @Environment(StudioViewModel.self) private var vm
    @State private var isNarrow = false
    @WindowStorage(Prefs.Studio.zoomStep, default: UIZoom.defaultStep) private var uiZoomStep
    /// The Library's own zoom, an offset from the app-wide step like a chat's
    /// (`ChatZoom`): pinch over it, or ⌘=/⌘-/⌘0 after a click in it, and the
    /// sidebar and the other panes keep their size. Not persisted.
    @State private var zoomOffset = 0

    var body: some View {
        NavigationStack {
            StudioSidebar()
                .equatable()
        }
        .dynamicTypeSize(ChatZoom.size(appStep: uiZoomStep, offset: zoomOffset))
        .environment(\.uiZoomScale, ChatZoom.scale(appStep: uiZoomStep, offset: zoomOffset))
        .background {
            ChatZoomShortcutTarget(
                step: { delta in
                    guard let next = ChatZoom.offset(stepping: delta, appStep: uiZoomStep, offset: zoomOffset) else { return false }
                    zoomOffset = next
                    return true
                },
                reset: { zoomOffset = 0 },
                capturesKeyboard: true
            )
        }
        // The kind tabs draw in flow under the pane's chrome line.
        .environment(\.studioTitlebarBandHeight, nil)
        .environment(\.sourcesListLayout, isNarrow ? .sidebar : .wide)
        // The rows' flags read the open marks, read from storage each time
        // the Library opens for what arrived by sync since; the Reader keeps
        // them in step while it is open (`applyLocally`).
        .task { await vm.reloadFollowUpMarks() }
        .onGeometryChange(for: Bool.self, of: { $0.size.width < Self.wideLayoutMinimumWidth }) { isNarrow = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .studioPaneNameHeader("Library")
        .studioCenterTabCloseChrome(for: .library)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
        .accessibilityIdentifier("library.pane")
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
    @State private var isPickingBulkNotebook = false
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
        let inBooks = sidebar.sidebarTab == .books && !sidebar.showsRecent
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
                Button {
                    isPickingBulkNotebook = true
                } label: {
                    Label("Add to Notebook", systemImage: "folder.badge.plus")
                        .zoomedSystemFont(size: 12)
                }
                .buttonStyle(.hoverWash)
                .popover(isPresented: $isPickingBulkNotebook, arrowEdge: .top) {
                    NotebookPickerPopover(
                        placeholder: "Search notebooks",
                        notebooks: notebooks,
                        pick: { perform(.addToNotebook($0.id), on: selection, inBooks: inBooks) },
                        close: { isPickingBulkNotebook = false }
                    )
                    .environment(vm)
                }
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
