import Foundation

// MARK: - Every window in a notebook, the Space as home, the full-window Library
//
// Shell stage 3 (docs/notebooks-design.md, "Every window opens in a
// notebook", "The full-window Library"). The product owner, 2026-10-01: "at any given
// time, I'm probably will be working in a notebook" — so a window opens in the
// notebook last worked in, the Space is where a window with none is (the
// Notebooks home went on 2026-10-09), and the whole library stays manageable
// in a view of its own.

extension StudioViewModel {

    // MARK: The notebook last worked in

    /// Notes that the learner worked in `notebookID` on this Mac — opened it
    /// in a window, sent a message in its chat, added a source to it — so
    /// the next window that opens on its own opens it and the rail's Recent
    /// order leads with it. Only an active notebook of the open library: an
    /// archived one is opened to be read, and one the library does not hold
    /// is nothing a window could open. Device-local (`NotebookRecency`);
    /// nothing synced is written.
    func noteNotebookWork(_ notebookID: String, at date: Date = Date()) {
        guard notebooks.contains(where: { $0.id == notebookID }) else { return }
        var recency = notebookRecency
        recency.note(notebookID, at: date)
        guard recency != notebookRecency else { return }
        notebookRecency = recency
        recency.save(to: notebookRecencyDefaults)
    }

    /// The notebook a window that opens on its own opens in
    /// (`NotebookLaunch`): the one last worked in on this Mac while the open
    /// library holds it, else nil for the Space. Before the
    /// library's notebooks are read, the last one, which closes onto the
    /// Space if it turns out to be gone (`closeNotebooksMissingFromLibrary`).
    func notebookForNewWindow() -> String? {
        NotebookLaunch.notebookForNewWindow(
            recency: notebookRecency,
            activeNotebookIDs: hasLoadedLearningGoalsOnce ? Set(notebooks.map(\.id)) : nil
        )
    }

    /// A brand-new Studio window — ⌘N, the Window menu, a second window for
    /// a link that names no notebook, the first window of a launch with no
    /// scene to restore — opens in the notebook last worked in, or shows the
    /// Space when there is none (decisions v5, 1). The window
    /// coordinator calls this as the window registers, before anything asked
    /// of the new window runs in it, so a source sent there opens in the
    /// notebook's document slot. A window restored with its own snapshot, or
    /// rebuilt from a saved workspace, never comes here: it comes back as it
    /// was. Writes nothing synced: the window's scene snapshot, and the
    /// notebook's stamp.
    func openNotebookOrSpaceInNewWindow(_ window: StudioWindowState) {
        guard window.notebook == nil, window.memoryReviewFocus == nil else { return }
        if let notebookID = notebookForNewWindow() {
            openNotebook(notebookID, in: window, keepsPanes: false)
        } else {
            presentSpace(in: window)
        }
    }

    // MARK: The Space is home

    /// The Space's All list in `destinationWindowState` (the window in scope
    /// when nil), as the learner asks for it — the View menu's Space (⌘P), a
    /// notebook's ‹ and its Close Notebook, the rail's Notebooks header, Siri's
    /// Show Notebooks, the MCP `open_in_app` target `space` — and wherever the
    /// app once showed the Notebooks home. A notebook the window holds leaves
    /// first, and its rail row or its row in the list brings it back as it was
    /// (`StudioWindowState.notebookLeft`).
    func showSpaceAll(in destinationWindowState: StudioWindowState? = nil) {
        showSpace(.all, in: destinationWindowState)
    }

    /// One place of the Space, shown in `destinationWindowState` (the window
    /// in scope when nil): the window remembers the place
    /// (`StudioWindowState.spaceDestinationKey`) and the Space takes a pane by
    /// the ordinary rules.
    func showSpace(_ place: SpaceDestination, in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        if destination.spaceDestinationKey != place.key { destination.spaceDestinationKey = place.key }
        activateCenterTab(.artifacts, in: destination)
    }

    /// The Space or its Courses list, as the Space's sidebar asks for one, in
    /// `destinationWindowState` (the window in scope when nil): the pane under
    /// the pointer, showing the other, shows `tab` in its place, every other
    /// pane and pin left as they were (`StudioCenterTabGroups.showingSpaceTab`).
    /// Courses shows the list of courses, so a course's page the window held
    /// gives way to it. With no such pane on screen — a notebook the
    /// window holds, the Space asked for from a menu — the tab opens by the
    /// ordinary rules, leaving a notebook as the Space does.
    func showSpaceTab(_ tab: SpaceTab, in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        if tab == .courses {
            destination.coursePageID = nil
        }
        if !destination.holdsNotebookSlot, destination.memoryReviewFocus == nil,
           let layout = destination.centerTabGroups.showingSpaceTab(tab, coursesShowsList: destination.coursePageID == nil) {
            if layout != destination.centerTabGroups { destination.centerTabGroups = layout }
            return
        }
        activateCenterTab(tab.centerTab, in: destination)
    }

    /// The Space the app puts in front of a window on its own: a brand-new
    /// window with no notebook to open, a notebook gone from under the window.
    /// Recorded in that window's scene snapshot alone
    /// (`activateCenterTabForThisWindowOnly`): the layout template, which
    /// syncs, follows only what the learner does. A window given over to the
    /// card review or Voice keeps it; the Space is underneath when it ends.
    func presentSpace(in window: StudioWindowState) {
        guard window.notebook == nil else { return }
        if window.spaceDestinationKey != SpaceDestination.all.key { window.spaceDestinationKey = SpaceDestination.all.key }
        window.activateCenterTabForThisWindowOnly(.artifacts)
    }

    /// The notebook `window` holds is gone — archived or deleted, here or on
    /// another device, or another library's once the open library changed —
    /// and the window shows the Space in its place.
    func leaveNotebookForSpace(in window: StudioWindowState) {
        guard window.notebook != nil else { return }
        window.notebook = nil
        presentSpace(in: window)
    }

    // MARK: The rail's notebooks

    /// What `window`'s rail lists about notebooks (`NotebookRail`): Pinned,
    /// Recent, Uncategorized's count, the collections, and the notebook the
    /// window holds — or, on the full rail, the one it last left — when it is
    /// none of those. In Screen record mode only what the take may show.
    func notebookRail(in window: StudioWindowState) -> NotebookRail {
        let openID = window.notebook?.notebookID ?? window.notebookLeft?.notebookID
        let open = openID.flatMap { id in allNotebooks.first { $0.id == id } }
        return NotebookRail(
            notebooks: notebooks,
            pinned: Set(pinnedNotebookIDs),
            recency: notebookRecency,
            collections: notebookCollections,
            openNotebookID: open?.id,
            shownCollectionIDs: screenRecordScope == nil ? nil : Set(orderedNotebookCollections.map(\.id))
        )
    }

    // MARK: The Library

    /// The Library in `destinationWindowState` (the window in
    /// scope when nil): the rail's Library row and ⇧⌘L. A notebook the
    /// window holds leaves the way it does for the Space
    /// (`.library` routes `.leave`), and its rail row brings it back.
    func openLibraryView(in destinationWindowState: StudioWindowState? = nil) {
        activateCenterTab(.library, in: destinationWindowState ?? activeWindowState)
    }

    /// The notebooks of the open library holding the Sources row `rowID`, by
    /// title: a source's In Notebooks (`SourceNotebooksMenuSection`). Reads
    /// the membership index (`notebookMemberSourceIDsByNotebook`), so only
    /// the menus that ask depend on it; screen record mode keeps an unfilmed
    /// notebook off screen.
    func notebooksHolding(_ rowID: String) -> [SidebarNotebook] {
        let counted = notebooksCountedForLibrary()
        return notebookMemberSourceIDsByNotebook
            .compactMap { notebookID, members -> SidebarNotebook? in
                guard members.contains(rowID),
                      counted(notebookID),
                      let title = notebookTitlesByNotebook[notebookID] else { return nil }
                return SidebarNotebook(notebookID: notebookID, title: title)
            }
            .sorted { lhs, rhs in
                let order = NotebookTitle(lhs.title).text.localizedStandardCompare(NotebookTitle(rhs.title).text)
                return order == .orderedSame ? lhs.notebookID < rhs.notebookID : order == .orderedAscending
            }
    }

    /// Whether a notebook counts as holding the Library's sources: one of the
    /// open library's (a team's notebooks belong to the team's library), and
    /// filmed while Screen record mode is on.
    private func notebooksCountedForLibrary() -> (String) -> Bool {
        let filmed: Set<String>? = isScreenRecordModeActive ? Set(notebooks.map(\.id)) : nil
        let teams = notebookTeamIDsByNotebook
        let activeTeamID = activeTeamID
        return { notebookID in
            teams[notebookID] == activeTeamID && (filmed?.contains(notebookID) ?? true)
        }
    }

    /// The sources a Library selection stands for, in display order: on the
    /// Books tab a row stands for its book, so for every chapter of it.
    func libraryBulkSourceIDs(for rowIDs: Set<String>, inBooksTab: Bool) -> [String] {
        let targets = sidebarRemovalTargets(for: rowIDs, expandingBooks: inBooksTab)
        let loose = sourceIDsInCurrentDisplayOrder(Set(targets.sourceIDs))
        return targets.bookGroups.flatMap { sourceIDsForGroupInOrder($0) } + loose
    }

    /// The read states the bulk bar's toggle reads (`LibraryBulkAction
    /// .readToggle`): each selected source that keeps one. None on the Books
    /// tab, where a row stands for a whole book.
    func libraryBulkReadStates(for rowIDs: Set<String>, inBooksTab: Bool) -> [Bool] {
        guard !inBooksTab else { return [] }
        return rowIDs.compactMap { articlesById[$0] }.filter(\.cachedSupportsReadTracking).map(\.isRead)
    }

    /// The Library's bulk bar, through the store APIs its rows' menus use.
    /// `rowIDs` is the selection as the Sources list tags it (`inBooksTab`:
    /// its rows stand for books), in the order `window`'s list shows it (the
    /// window in scope when nil).
    func performLibraryBulkAction(
        _ action: LibraryBulkAction,
        on rowIDs: Set<String>,
        inBooksTab: Bool,
        in window: StudioWindowState? = nil
    ) async {
        switch action {
        case .addToNotebook(let notebookID):
            // Read before the first await: the display order is the window's.
            let ids = inWindow(window ?? activeWindowState) {
                libraryBulkSourceIDs(for: rowIDs, inBooksTab: inBooksTab)
            }
            guard !ids.isEmpty else { return }
            await addSourcesToNotebookContext(ids, notebookID: notebookID)
        case .markRead, .markUnread:
            let read = action == .markRead
            let targets = rowIDs
                .compactMap { articlesById[$0] }
                .filter { $0.cachedSupportsReadTracking && $0.isRead != read }
                .map(\.id)
            guard !targets.isEmpty else { return }
            for id in targets {
                await setArticleRead(id, read: read, showsToast: false)
            }
            let noun = targets.count == 1 ? "1 source" : "\(targets.count) sources"
            showToast("Marked \(noun) as \(read ? "read" : "unread")")
        case .hide:
            let targets = sidebarRemovalTargets(for: rowIDs, expandingBooks: inBooksTab)
            guard !targets.isEmpty else { return }
            await hideSidebarRemovalTargets(targets)
        }
    }
}
