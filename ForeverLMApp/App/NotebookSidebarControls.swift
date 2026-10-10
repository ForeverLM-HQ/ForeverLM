import SwiftUI

// The Sources sidebar's notebook marks. While a window works in a notebook
// (`StudioViewModel.sidebarNotebook(in:)`), each row carries a trailing mark:
// a check on the notebook's sources, a + under the pointer on the rest, and a
// half circle on a book only some of whose chapters are in. The right-click
// menu leads with Add to / Remove from the notebook. Only these views read
// the membership index, so a + re-runs the marks, never the sidebar's body
// and its List.

// MARK: - Row controls that do not open the row

/// The Sources rows whose own control the pointer is pressing or just let
/// go. A List row opens its source from three places that all see a click on
/// a control inside it: the row's tap gesture, AppKit's selection write on
/// mouse-down, and the deferred open on mouse-up. Each asks here first, so a
/// row's + (or its read-state button) never opens or selects that row.
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

// MARK: - The trailing mark

/// One row's notebook mark. Reads the membership index, and whether the
/// notebook takes sources, itself, so the row that hosts it, and the List
/// around that, never depend on either.
struct NotebookMembershipMark: View {
    @Environment(StudioViewModel.self) private var vm
    /// What the row stands for, named as the Sources list names it.
    let sourceIDs: [String]
    let notebook: SidebarNotebook
    let isRowHovered: Bool
    /// The ids a press on the mark claims (`SidebarRowControlPress`); the
    /// row's own tag among them.
    var rowControlIDs: [String]? = nil

    var body: some View {
        let membership = vm.notebookMembership(of: sourceIDs, in: notebook.notebookID)
        // A notebook that takes no sources (a read-only team's, an archived
        // one) shows its state with no button.
        let takesSources = vm.importableNotebook(notebook.notebookID) != nil
        NotebookMembershipButton(
            membership: membership,
            notebookTitle: notebook.title,
            isRowHovered: isRowHovered,
            rowControlIDs: rowControlIDs ?? sourceIDs,
            toggle: takesSources ? { toggle(from: membership) } : nil
        )
    }

    /// The check takes the row out; the + and the half circle bring in what
    /// is missing. Quiet: the mark changing is the answer, and a failure still
    /// says so.
    private func toggle(from membership: NotebookMembershipState) {
        let notebookID = notebook.notebookID
        let ids = sourceIDs
        Task {
            if membership == .all {
                await vm.removeSourcesFromNotebook(ids, notebookID: notebookID, announce: false)
            } else {
                await vm.addSourcesToNotebookContext(ids, notebookID: notebookID, announce: false)
            }
        }
    }
}

/// The mark itself, from plain values: a + that shows under the row's
/// pointer, a check that turns into a minus under its own, or a half circle.
/// `toggle` nil (a read-only library) draws the state with no button. The
/// slot is kept while empty, so the read-state column beside it stays aligned.
struct NotebookMembershipButton: View {
    let membership: NotebookMembershipState
    let notebookTitle: String
    let isRowHovered: Bool
    let rowControlIDs: [String]
    let toggle: (() -> Void)?

    @State private var isHovered = false
    /// Set by a click until the pointer leaves: the + just pressed shows the
    /// check it became, not the minus a hovered check offers.
    @State private var holdsCheckUnderPointer = false

    private var systemImage: String {
        switch membership {
        case .none: return "plus.circle"
        case .some: return "circle.lefthalf.filled"
        case .all:
            let offersRemove = isHovered && !holdsCheckUnderPointer && toggle != nil
            return offersRemove ? "minus.circle" : "checkmark.circle.fill"
        }
    }

    private var help: String {
        guard toggle != nil else { return "In \(notebookTitle)" }
        return membership == .all ? "Remove from \(notebookTitle)" : "Add to \(notebookTitle)"
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .zoomedSystemFont(size: 12, weight: .medium)
            .foregroundStyle(membership == .none ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            .frame(width: 18, height: 18)
            .contentShape(Circle())
    }

    var body: some View {
        if let toggle {
            // The + is built only under the row's pointer, the hidden icon
            // holding its slot: a button at opacity 0 is still a live
            // control, and while an assistive app reads the screen SwiftUI
            // walks every control in the window for each one an update
            // builds (2026-10-03). The right-click leads with Add to.
            if membership != .none || isRowHovered {
                Button {
                    holdsCheckUnderPointer = membership != .all
                    toggle()
                } label: {
                    icon
                }
                .buttonStyle(RowControlButtonStyle(
                    sourceIDs: rowControlIDs,
                    wash: .hoverWash(cornerRadius: 6, inset: -2)
                ))
                .onHover { hovering in
                    isHovered = hovering
                    if !hovering { holdsCheckUnderPointer = false }
                }
                .help(help)
                .accessibilityLabel(help)
            } else {
                icon
                    .hidden()
                    // The button may go before its own hover exit arrives;
                    // a stale hover would show the next check as a minus.
                    .onAppear {
                        isHovered = false
                        holdsCheckUnderPointer = false
                    }
            }
        } else if membership == .none {
            Color.clear
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            icon
                .help(help)
                .accessibilityElement()
                .accessibilityLabel(help)
        }
    }
}

/// A row-wide hover for a row that is not an `ArticleRow` (a book cover), so
/// its + can show under the pointer without `@State` on the sidebar, whose
/// body would re-run on every hover. Tracks nothing while `isActive` is false.
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
