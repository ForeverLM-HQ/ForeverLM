import Foundation

// MARK: - The notebook last worked in
//
// Every Studio window opens in the notebook the learner was last working in
// (decisions v5, 1; docs/notebooks-design.md, "Every window opens in a
// notebook"): a window restored at launch comes back holding its own, and a
// window that opens on its own — ⌘N, the Window menu, a second window for a
// link that names no notebook, the first window of a launch with nothing to
// restore — opens the last one, or shows the Space when there is none. The
// stamps (`NotebookRecency`) and the iPhone's Home's rules the Mac shares —
// its sorts, filter, Grid | List and the rail's sections — are in
// NotebooksHomeRules.swift.

/// Which notebook a Studio window that opens on its own opens in.
enum NotebookLaunch {
    /// The notebook last worked in on this Mac, while the open library holds
    /// it as an active notebook (`activeNotebookIDs`); nil — the Space — when
    /// no notebook was worked in here yet, or the last one was deleted,
    /// archived, merged away or belongs to another library. Before the
    /// library's notebooks are read (`activeNotebookIDs` nil, a launch's
    /// first window) the last one opens, the way a restored window's does:
    /// once they are read, a notebook the library does not hold closes and
    /// the window shows the Space, never a spinner.
    static func notebookForNewWindow(recency: NotebookRecency, activeNotebookIDs: Set<String>?) -> String? {
        guard let last = recency.mostRecent else { return nil }
        guard let activeNotebookIDs else { return last }
        return activeNotebookIDs.contains(last) ? last : nil
    }
}

/// A notebook record as the shared Home rules (the iPhone's, and the sorts the
/// Mac's recents use) read it.
extension LearningGoalRecord: NotebookHomeListing {
    var homeSourceCount: Int { approvedSourceIDs.count }
}

// MARK: - The Space's tabs

/// The tabs on the chrome line of the Space, the Courses list and Goals
/// (shell stage 4, 2026-10-01; the Notebooks home that led them went on
/// 2026-10-09, docs/notebooks-design.md, "The Notebooks home, retired"): the
/// **Space**, whose sidebar lists the courses and the places, and **Goals**,
/// what the learner wants to be true by a date. **Courses** is not a tab of
/// the bar but the pane the Space's Courses row opens, drawn beside the
/// Space's sidebar, so a Courses pane's tab is the Space's (`barTab`). Each
/// is its own pane — the Space (`.artifacts`), Courses (`.courses`, which
/// shows one course's page once a card is opened) and Goals (`.goals`) — so
/// each keeps its Open Beside, Open in Other Window and drag. The tab bar
/// swaps one pane for the other in place
/// (`StudioCenterTabGroups.showingSpaceTab`).
enum SpaceTab: String, CaseIterable, Identifiable, Sendable {
    case courses
    case space
    case goals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .courses: return "Courses"
        // ChatGPT's Space, copied on 2026-10-06 (docs/docs-design.md, "The
        // Space"): Pages, Sites, Images, Ideas and Google Drive under one tab.
        case .space: return "Space"
        case .goals: return "Goals"
        }
    }

    /// The tabs the chrome line shows (product owner, 2026-10-09: "perhaps that can
    /// just be in spaces", "also courses under spaces then"): the Space and
    /// Goals. Courses stays a pane, drawn beside the Space's sidebar, so a
    /// pane's way back is its own tab.
    static let barTabs: [SpaceTab] = [.space, .goals]

    /// The tab of the bar that is lit while this one is on show: the Space
    /// while Courses is.
    var barTab: SpaceTab {
        switch self {
        case .courses, .space: return .space
        case .goals: return self
        }
    }

    /// The pane the tab is.
    var centerTab: StudioCenterTab {
        switch self {
        case .courses: return .courses
        case .space: return .artifacts
        case .goals: return .goals
        }
    }

    /// The tab a pane is, or nil for a pane that is not the Space's.
    init?(centerTab: StudioCenterTab) {
        switch centerTab {
        case .courses: self = .courses
        case .artifacts: self = .space
        case .goals: self = .goals
        default: return nil
        }
    }
}

extension StudioCenterTabGroups {
    /// The arrangement once the Space's tab bar shows `tab`: in the pane
    /// showing one of the others, `tab` takes its place (`swapping`), so a tab
    /// click swaps the page under the pointer. Nil when no pane shows another
    /// tab: the caller then opens the tab by the ordinary rules
    /// (`activating`). The Courses pane counts only while it shows the list
    /// (`coursesShowsList`): a course's page is a document, which the Space
    /// does not replace.
    func showingSpaceTab(_ tab: SpaceTab, coursesShowsList: Bool = false) -> StudioCenterTabGroups? {
        var others: [StudioCenterTab] = [.artifacts, .goals]
        if coursesShowsList { others.append(.courses) }
        for other in others where other != tab.centerTab {
            if let layout = swapping(other, for: tab.centerTab) { return layout }
        }
        return nil
    }

    /// The arrangement once the pane showing `current` shows `next` in its
    /// place: `next` moves into that pane from wherever it was parked (a
    /// pane it alone held closes), and every other pane, and the pins, stay
    /// as they were. Nil when no pane shows `current`, or for `next` ==
    /// `current`.
    func swapping(_ current: StudioCenterTab, for next: StudioCenterTab) -> StudioCenterTabGroups? {
        guard next != current, var target = groups.firstIndex(where: { $0.activeTab == current }) else { return nil }
        var layout = self
        if let source = layout.groups.firstIndex(where: { $0.tabs.contains(next) }), source != target {
            layout.groups[source].tabs.removeAll { $0 == next }
            if layout.groups[source].tabs.isEmpty {
                layout.groups.remove(at: source)
                if source < target { target -= 1 }
            } else if !layout.groups[source].tabs.contains(layout.groups[source].activeTab) {
                layout.groups[source].activeTab = layout.groups[source].tabs[0]
            }
        }
        if !layout.groups[target].tabs.contains(next) {
            layout.groups[target].tabs.append(next)
        }
        layout.groups[target].activeTab = next
        return layout
    }
}

// MARK: - The full-window Library

/// What the Library view's bulk bar does to a multi-selection. Each goes to
/// the store API the row menus already use (`StudioViewModel
/// .performLibraryBulkAction(_:on:inBooksTab:)`); New Notebook with N Sources
/// and Remove… ask first, in the sidebar's own sheet and dialog.
enum LibraryBulkAction: Equatable, Sendable {
    /// Adds every selected source — each chapter of a selected book — to the
    /// notebook (`addSourcesToNotebookContext`).
    case addToNotebook(String)
    /// Marks the selection's unread sources read (`setArticleRead`).
    case markRead
    /// Marks the selection's sources unread.
    case markUnread
    /// Hides the selection — books as books — from the lists; chat, search
    /// and reviews still read it, and Hidden Items brings it back
    /// (`hideSidebarRemovalTargets`). The library's archive.
    case hide

    /// The bar's one read toggle, as the row menu decides it: Mark Read while
    /// any selected source that keeps a read state is unread, else Mark
    /// Unread; nothing for a selection with no read state to change.
    static func readToggle(readStates: [Bool]) -> LibraryBulkAction? {
        guard !readStates.isEmpty else { return nil }
        return readStates.contains(false) ? .markRead : .markUnread
    }
}
