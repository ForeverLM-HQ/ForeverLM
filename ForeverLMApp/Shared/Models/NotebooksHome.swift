import Foundation

// MARK: - Where a window opens
//
// A window restored at launch comes back holding its own notebook. A window
// that opens on its own — ⌘N, the Window menu, a second window for a link that
// names no notebook, the first window of a launch with nothing to restore —
// shows the Space, never a notebook picked for the learner: the last one worked
// in can be a crowded place to land (product owner, 2026-11-10: "i don't want
// it by default to open this busy busy notebook"). The stamps
// (`NotebookRecency`) still order the rail's Recent, and the iPhone's Home's
// rules the Mac shares — its sorts, filter, Grid | List and the rail's
// sections — are in NotebooksHomeRules.swift.

/// A notebook record as the shared Home rules (the iPhone's, and the sorts the
/// Mac's recents use) read it.
extension LearningGoalRecord: NotebookHomeListing {
    var homeSourceCount: Int { approvedSourceIDs.count }
}

// MARK: - The Space's panes

/// The two panes the Space's sidebar swaps in place (shell stage 4;
/// docs/notebooks-design.md, "The Notebooks home, retired"): the **Space**
/// (`.artifacts`), its places beside the sidebar, and **Courses**
/// (`.courses`), the list of courses the sidebar's Courses row opens, drawn
/// beside the same sidebar, which shows one course's page once a card is
/// opened. Each is its own pane, so each keeps its Open Beside, Open in Other
/// Window and drag; a sidebar click swaps one for the other in place
/// (`StudioCenterTabGroups.showingSpaceTab`).
///
/// The chrome line over them once held a tab bar, Space | Goals. It went on
/// 2026-10-10 (product owner: "i don't think it makes sense to have space and
/// goals … goals can perhaps just be visible via chat; same with ideas
/// perhaps"): the sidebar's header names the Space, and the chat lists, sets
/// and changes Goals and Ideas (`list_goals`, `create_learning_goal`,
/// `list_ideas`, `create_idea`).
enum SpaceTab: Sendable {
    case courses
    case space

    /// The pane the tab is.
    var centerTab: StudioCenterTab {
        switch self {
        case .courses: return .courses
        case .space: return .artifacts
        }
    }
}

extension StudioCenterTabGroups {
    /// The arrangement once the Space shows `tab`: in the pane showing the
    /// other, `tab` takes its place (`swapping`), so a sidebar click swaps the
    /// page under the pointer. Nil when no pane shows the other: the caller
    /// then opens the tab by the ordinary rules (`activating`). The Courses
    /// pane counts only while it shows the list (`coursesShowsList`): a
    /// course's page is a document, which the Space does not replace.
    func showingSpaceTab(_ tab: SpaceTab, coursesShowsList: Bool = false) -> StudioCenterTabGroups? {
        var others: [StudioCenterTab] = [.artifacts]
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
