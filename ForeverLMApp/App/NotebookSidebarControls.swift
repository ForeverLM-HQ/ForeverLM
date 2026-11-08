import SwiftUI

// The Sources sidebar's notebook controls. While a window works in a
// notebook (`StudioViewModel.sidebarNotebook(in:)`), a row's right-click menu
// leads with Add to / Remove from that notebook. The rows carry no mark for
// it: a check or + on every row was one more thing to read past (product
// owner, 2026-11-08: "those like select things and pluses ... that's also
// confusing").

// MARK: - Row controls that do not open the row

/// The Sources rows whose own control the pointer is pressing or just let
/// go. A List row opens its source from three places that all see a click on
/// a control inside it: the row's tap gesture, AppKit's selection write on
/// mouse-down, and the deferred open on mouse-up. Each asks here first, so a
/// row's own control (its read-state mark, its card count) never opens or
/// selects that row.
struct SidebarRowControlPress: Equatable {
    let sourceIDs: Set<String>
    let pressedAt: Date
    var releasedAt: Date?

    /// How long after the release the row's own handlers still stand down:
    /// they answer the same mouse-up, some of them a runloop turn later.
    static let releaseGrace: TimeInterval = 0.5
    /// A press whose release never arrived (its row left the list under the
    /// pointer) stops claiming the row after this.
    static let longestPress: TimeInterval = 30

    func claims(_ sourceID: String, at now: Date) -> Bool {
        guard sourceIDs.contains(sourceID) else { return false }
        if let releasedAt {
            return now.timeIntervalSince(releasedAt) < Self.releaseGrace
        }
        return now.timeIntervalSince(pressedAt) < Self.longestPress
    }

    /// The press a row control last noted. One pointer, so one press.
    @MainActor private static var latest: SidebarRowControlPress?

    @MainActor static func note(pressed: Bool, sourceIDs: [String], at now: Date = Date()) {
        if pressed {
            latest = SidebarRowControlPress(sourceIDs: Set(sourceIDs), pressedAt: now)
        } else if latest?.sourceIDs == Set(sourceIDs), latest?.releasedAt == nil {
            latest?.releasedAt = now
        }
    }

    /// Whether a click on `sourceID`'s row was its control's, not the row's.
    @MainActor static func claims(_ sourceID: String, at now: Date = Date()) -> Bool {
        latest?.claims(sourceID, at: now) ?? false
    }
}

/// The hover wash, plus a note on press that the click belongs to the control
/// (`SidebarRowControlPress`), for a button inside a Sources row. Mouse-down
/// comes before every mouse-up handler, so the note is there in time whatever
/// order AppKit and SwiftUI answer the release in.
struct RowControlButtonStyle: ButtonStyle {
    /// The rows this control sits in: one source, or a book's chapters and the
    /// chapter its cover is tagged with.
    let sourceIDs: [String]
    var wash: HoverWashButtonStyle = .hoverWash

    func makeBody(configuration: Configuration) -> some View {
        wash.makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, isPressed in
                SidebarRowControlPress.note(pressed: isPressed, sourceIDs: sourceIDs)
            }
    }
}

// MARK: - Row hover

/// A row-wide hover for a row that is not an `ArticleRow`, so a control can
/// show under the pointer without `@State` on its host, whose body would
/// re-run on every hover. Tracks nothing while `isActive` is false.
struct NotebookHoverRow<Content: View>: View {
    let isActive: Bool
    @ViewBuilder let content: (_ isHovered: Bool) -> Content

    @State private var isHovered = false

    var body: some View {
        content(isActive && isHovered)
            .onHover { hovering in
                guard isActive || isHovered else { return }
                isHovered = hovering
            }
    }
}

// MARK: - The right-click menu's lead

/// What a Sources right-click acts on, as the menu names it.
enum NotebookMenuTarget: Equatable {
    /// The clicked source, or the selection it is part of.
    case sources([String])
    /// Book covers, by group name: each stands for its chapters.
    case books([String])
    /// A meeting series or a playlist, by group name.
    case collection(String)
}

/// One item of the menu's notebook lead.
struct NotebookMembershipMenuItem: Identifiable, Equatable {
    enum Action: Equatable {
        case add
        case remove
    }

    let action: Action
    let title: String
    /// The rows the item adds (those not yet in) or removes (those in).
    let sourceIDs: [String]

    var id: Action { action }
    var systemImage: String { action == .add ? "plus.circle" : "minus.circle" }
}

/// The titles and targets of the menu's notebook lead, from plain values.
enum NotebookMembershipMenu {
    /// The rows a menu acts on, resolved to source ids.
    enum Rows: Equatable {
        case sources([String])
        /// Each book's chapters.
        case books([[String]])
        case collection([String])
    }

    /// "Add to X" / "Remove from X" for one source or book; "Add 3 to X" /
    /// "Remove 2 from X" for a selection; "Add 2 Books to X" for covers;
    /// "Add All to X" for a series or playlist. A mixed selection gets both.
    static func items(for rows: Rows, members: Set<String>, notebookTitle: String) -> [NotebookMembershipMenuItem] {
        var items: [NotebookMembershipMenuItem] = []
        switch rows {
        case .sources(let ids):
            let outIDs = ids.filter { !members.contains($0) }
            let inIDs = ids.filter { members.contains($0) }
            if !outIDs.isEmpty {
                let title = ids.count == 1 ? "Add to \(notebookTitle)" : "Add \(outIDs.count) to \(notebookTitle)"
                items.append(NotebookMembershipMenuItem(action: .add, title: title, sourceIDs: outIDs))
            }
            if !inIDs.isEmpty {
                let title = ids.count == 1 ? "Remove from \(notebookTitle)" : "Remove \(inIDs.count) from \(notebookTitle)"
                items.append(NotebookMembershipMenuItem(action: .remove, title: title, sourceIDs: inIDs))
            }
        case .books(let books):
            let chapters = books.filter { !$0.isEmpty }
            let booksMissing = chapters.filter { !$0.allSatisfy(members.contains) }
            let booksHolding = chapters.filter { $0.contains(where: members.contains) }
            let outIDs = booksMissing.flatMap { $0.filter { !members.contains($0) } }
            let inIDs = booksHolding.flatMap { $0.filter { members.contains($0) } }
            if !outIDs.isEmpty {
                let title = chapters.count == 1
                    ? "Add to \(notebookTitle)"
                    : "Add \(bookCount(booksMissing.count)) to \(notebookTitle)"
                items.append(NotebookMembershipMenuItem(action: .add, title: title, sourceIDs: outIDs))
            }
            if !inIDs.isEmpty {
                let title = chapters.count == 1
                    ? "Remove from \(notebookTitle)"
                    : "Remove \(bookCount(booksHolding.count)) from \(notebookTitle)"
                items.append(NotebookMembershipMenuItem(action: .remove, title: title, sourceIDs: inIDs))
            }
        case .collection(let ids):
            let outIDs = ids.filter { !members.contains($0) }
            let inIDs = ids.filter { members.contains($0) }
            if !outIDs.isEmpty {
                items.append(NotebookMembershipMenuItem(action: .add, title: "Add All to \(notebookTitle)", sourceIDs: outIDs))
            }
            if !inIDs.isEmpty {
                items.append(NotebookMembershipMenuItem(action: .remove, title: "Remove All from \(notebookTitle)", sourceIDs: inIDs))
            }
        }
        return items
    }

    /// "New Notebook with 3 Sources" for a multi-selection, "Open in New
    /// Notebook" for one row (product owner, 2026-10-03: "there should also be a
    /// open in new notebook here"); nil for none. No ellipsis: the notebook
    /// is made at once, with no form (`NotebookNaming`).
    static func newNotebookTitle(sourceCount: Int) -> String? {
        switch sourceCount {
        case ..<1: nil
        case 1: "Open in New Notebook"
        default: "New Notebook with \(sourceCount) Sources"
        }
    }

    /// "New Notebook with 2 Books" for several covers.
    static func newNotebookTitle(bookCount count: Int) -> String? {
        count > 1 ? "New Notebook with \(bookCount(count))" : nil
    }

    private static func bookCount(_ count: Int) -> String {
        count == 1 ? "1 Book" : "\(count) Books"
    }
}

/// The lead of a Sources right-click menu: Add to / Remove from the window's
/// working notebook, while it takes sources (`importableNotebook`), then New
/// Notebook with a multi-selection, closed by a divider when it drew
/// anything. Nothing in a read-only library. Reads the membership here, when
/// the menu is built, not in the sidebar's body.
struct NotebookMenuSection: View {
    @Environment(StudioViewModel.self) private var vm
    let notebook: SidebarNotebook?
    let target: NotebookMenuTarget
    /// "New Notebook with 3 Sources", or nil where the menu offers none.
    var newNotebookTitle: String? = nil
    var newNotebook: () -> Void = {}

    private var membershipItems: [NotebookMembershipMenuItem] {
        guard let notebook, vm.importableNotebook(notebook.notebookID) != nil else { return [] }
        let rows: NotebookMembershipMenu.Rows = switch target {
        case .sources(let ids): .sources(ids)
        case .books(let groupNames): .books(groupNames.map { vm.sourceIDsForGroupInOrder($0) })
        case .collection(let groupName): .collection(vm.sourceIDsForGroupInOrder(groupName))
        }
        return NotebookMembershipMenu.items(
            for: rows,
            members: vm.notebookMemberSourceIDsByNotebook[notebook.notebookID] ?? [],
            notebookTitle: notebook.title
        )
    }

    var body: some View {
        if !vm.isActiveLibraryReadOnly {
            let items = membershipItems
            ForEach(items) { item in
                Button {
                    perform(item)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            if let newNotebookTitle {
                Button(action: newNotebook) {
                    Label(newNotebookTitle, systemImage: "folder.badge.plus")
                }
            }
            if !items.isEmpty || newNotebookTitle != nil {
                Divider()
            }
        }
    }

    /// Adds go through the shared add path, which copies a source into a team
    /// notebook's team; removes find the team's copies the rows stand for. A
    /// course or playlist is linked whole, and unlinked by Remove All, as a
    /// course dropped on the notebook is (`addGroupToNotebook`).
    private func perform(_ item: NotebookMembershipMenuItem) {
        guard let notebookID = notebook?.notebookID else { return }
        let ids = item.sourceIDs
        let target = target
        Task {
            switch (item.action, target) {
            case (.add, .collection(let groupName)):
                await vm.addGroupToNotebook(groupName, notebookID: notebookID)
            case (.add, _):
                await vm.addSourcesToNotebookContext(ids, notebookID: notebookID)
            case (.remove, .collection(let groupName)):
                await vm.removeGroupFromNotebook(groupName, rowIDs: ids, notebookID: notebookID)
            case (.remove, _):
                await vm.removeSourcesFromNotebook(ids, notebookID: notebookID)
            }
        }
    }
}
