import Foundation

// MARK: - Opening and closing a window's notebook
//
// While a window holds a notebook (`StudioWindowState.notebook`), the notebook
// workspace draws its Sources and Studio columns around the window's own
// tabbed panes (docs/notebooks-design.md, "The notebook workspace"). Every
// center-tab request goes to those panes as it does in a window with no
// notebook.

/// Where a chat belongs: its own notebook's workspace, or the library.
enum NotebookChatHome: Equatable {
    case notebook(String)
    case library
}

extension StudioViewModel {
    /// A notebook's chats in the rail's order — those filed in it and those
    /// on a Goal drawing on it (`reviewSessionGroups`) — for the notebook
    /// window's Chats menus and its guide, where the full rail's folder
    /// listed them before the rail became an icon strip in a notebook
    /// (docs/notebooks-design.md, "The rail"). Every one: the menus list them
    /// all, and the guide shows the latest and lists the rest on request.
    func notebookChats(notebookID: String) -> [ReviewSessionRecord] {
        guard let notebook = notebook(id: notebookID) else { return [] }
        return reviewSessionGroups(for: [notebook]).byNotebookID[notebookID] ?? []
    }

    /// The center tabs on screen in `windowState`: each pane's active tab.
    func visibleCenterTabs(in windowState: StudioWindowState) -> Set<StudioCenterTab> {
        Set(windowState.centerTabGroups.groups.map(\.activeTab))
    }

    /// Opens a Page beside what the learner is reading or watching, so the two
    /// are on screen together: in a pane beside the Reader.
    func openDocSideBySide(_ artifactID: String) async {
        if !artifacts.contains(where: { $0.id == artifactID }) { await loadArtifacts() }
        guard artifacts.contains(where: { $0.id == artifactID }) else {
            showToast("That page is no longer in your library")
            return
        }
        revealArtifact(artifactID, in: activeWindowState, beside: .reader)
    }

    /// Opens `notebookID` as the notebook of `destinationWindowState` (the
    /// window in scope when nil). The notebook workspace then draws its
    /// columns around that window's panes.
    ///
    /// A window that was not holding this notebook shows a chat in it: a
    /// saved chat of this notebook stays; otherwise the chat this window last
    /// had open in the notebook reopens (`StudioWindowState.notebookChats`);
    /// failing that an empty chat joins the notebook, and a saved chat filed
    /// elsewhere gives way to a fresh one. That fresh chat reads the
    /// notebook's ticked sources live and writes nothing until the learner
    /// acts in it (`pendingNotebookChatRequestID`).
    ///
    /// Opening writes nothing synced: the window's scene snapshot, which
    /// `get_app_context` reads through `MCPAppWindows`; the active Notebook
    /// (`activeNotebookId`), a preference on this Mac only that in-app
    /// choices fall back to; and this Mac's record of the notebook last
    /// worked in (`noteNotebookWork`), which the next new window opens in.
    /// An archived notebook, or a read-only team's, is opened to be read and
    /// does not move the active Notebook; an archived one is not stamped
    /// either.
    ///
    /// The window opens the notebook as it last left it, if it did
    /// (`StudioWindowState.notebookLeft`): its faces and folds.
    ///
    /// Every notebook opens in the window's own tabs: its Sources
    /// and Studio columns stand around the window's own panes, whose tabs —
    /// the Space, Pages, the Library, Chat — are dragged, split and closed as
    /// anywhere else (product owner, 2026-11-07: "the notebook should
    /// actually borrow the way we now have the tab set up in the main view").
    /// A window showing one pane that is not the chat shows the chat in it,
    /// what it showed staying one of its tabs, so the notebook opens on its
    /// conversation; a window of two panes or more is left as arranged.
    ///
    /// `startsNotebookChat` is false when the caller opens a chat of its own
    /// (a resumed chat's home, the rail's per-notebook New chat), or when the
    /// open comes from work finishing in the background, which must not swap
    /// the chat the learner is in (a Gemini Notebook import).
    func openNotebook(
        _ notebookID: String,
        in destinationWindowState: StudioWindowState? = nil,
        startsNotebookChat: Bool = true
    ) {
        let destination = destinationWindowState ?? activeWindowState
        if destination.isVoiceWorkspacePresented { destination.isVoiceWorkspacePresented = false }
        if destination.memoryReviewFocusSessionID != nil {
            leaveMemoryReviewFocus(in: destination)
        }
        let wasHolding = destination.NotebookID
        destination.NotebookID = notebookID
        let groups = destination.centerTabGroups.groups
        if groups.count == 1, groups[0].activeTab != .chat {
            activateCenterTab(.chat, in: destination)
        }
        if importableNotebook(notebookID) != nil, activeNotebookId != notebookID {
            activeNotebookId = notebookID
        }
        noteNotebookWork(notebookID)
        // An archived notebook is opened to be read; its chats are the
        // library's, as the rail files them.
        guard startsNotebookChat, wasHolding != notebookID,
              notebooks.contains(where: { $0.id == notebookID }) else { return }
        let current = destination.chatSessionID
        if let current, chatHome(forSessionID: current) == .notebook(notebookID) { return }
        if let remembered = destination.notebookChats[notebookID] {
            if chatHome(forSessionID: remembered) == .notebook(notebookID) {
                inWindow(destination) { requestResumeReviewSession(remembered) }
                return
            }
            // Deleted, or moved to another notebook: start over.
            destination.notebookChats[notebookID] = nil
        }
        // An empty chat joins the notebook by itself — the chat pane files an
        // idle chat in its window's notebook — so only a saved chat filed
        // elsewhere gives way to a fresh one. A running turn is parked, never
        // stopped (`StudioAssistantSessionStore.prepareForNewChat`).
        guard current != nil else { return }
        inWindow(destination) { requestNotebookChat(notebookID: notebookID) }
    }

    /// Closes the notebook `destinationWindowState` (the window in scope when
    /// nil) holds; its panes come back as they were. What a library chat
    /// opening in the window does; the learner's own Close Notebook and ‹
    /// land on the Space (`showSpaceAll`).
    func closeNotebook(in destinationWindowState: StudioWindowState? = nil) {
        let destination = destinationWindowState ?? activeWindowState
        guard destination.notebook != nil else { return }
        destination.notebook = nil
    }

    /// Closes, in every window, a notebook the open library does not hold:
    /// deleted on another device, or another library's once a team opened or
    /// closed. Each of those windows shows the Space
    /// (`leaveNotebookForSpace`), never a spinner. Only once the library's
    /// Notebooks have been read: before that a window restored at launch, or
    /// a new one opening the notebook last worked in, holds a notebook whose
    /// record is on its way, and must not close what it is about to show.
    func closeNotebooksMissingFromLibrary() {
        guard hasLoadedLearningGoalsOnce else { return }
        let held = Set(allNotebooks.map(\.id))
        for state in allWindowStates {
            guard let notebookID = state.NotebookID, !held.contains(notebookID) else { continue }
            leaveNotebookForSpace(in: state)
        }
    }

    /// Whether `goal`'s own library refuses edits: a team notebook the owner
    /// shared read-only. Read from the notebook's team, not from whichever
    /// library is open.
    func isNotebookReadOnly(_ goal: LearningGoalRecord) -> Bool {
        guard let teamID = goal.teamID else { return false }
        return team(id: teamID).map { !$0.canEdit } ?? true
    }

    /// A fresh chat in the notebook, reading its ticked sources as they stand
    /// and writing nothing until the learner acts in it.
    private func requestNotebookChat(notebookID: String) {
        pendingReviewChatNotebookID = notebookID
        pendingReviewChatDraft = nil
        reviewChatPanelMode = .chat
        let requestID = UUID()
        reviewChatResetRequestID = requestID
        pendingNotebookChatRequestID = requestID
    }

    /// The notebook a New chat made in `windowState` (the window in scope
    /// when nil) is filed in: the active notebook it holds. Nil for a window
    /// holding none, or an archived one, whose chats are the library's.
    func newChatNotebookID(in windowState: StudioWindowState? = nil) -> String? {
        let window = windowState ?? chatRequestOriginWindow ?? activeWindowState
        return window.NotebookID.flatMap { id in notebooks.contains { $0.id == id } ? id : nil }
    }

    /// New chat, from the rail, its drag, `/new`, another window's menu or a
    /// walk's leave: in a window holding a notebook, a chat in that notebook
    /// with its ticked sources; elsewhere a library chat. In an archived
    /// notebook's window the chat is unfiled and the window stays where it
    /// is: the learner asked for a chat, not to leave what they are reading.
    func requestNewChat() {
        let window = chatRequestOriginWindow ?? activeWindowState
        if let notebookID = newChatNotebookID(in: window) {
            requestBlankReviewChat(notebookID: notebookID)
        } else if window.notebook != nil {
            startBlankReviewChat(notebookID: nil)
        } else {
            requestBlankReviewChat()
        }
    }

    /// The notebook a saved chat belongs in (`NotebookWorkspace.home`), or
    /// the library. Nil while the chat's record is not loaded, when nothing
    /// is known about where it is filed.
    func chatHome(forSessionID sessionID: String) -> NotebookChatHome? {
        guard let session = reviewSessionLinks.first(where: { $0.id == sessionID }) else { return nil }
        guard !MemoryReviewSession.isMemorySession(session.id) else { return .library }
        var parentNotebookByGoalID: [String: String] = [:]
        for goal in learningGoals where goal.isGoal {
            if let parent = goal.parentNotebookID, !parent.isEmpty { parentNotebookByGoalID[goal.id] = parent }
        }
        let home = NotebookWorkspace.home(
            ofChatFiledUnder: session.goalID,
            notebookIDs: Set(notebooks.map(\.id)),
            parentNotebookByGoalID: parentNotebookByGoalID
        )
        return home.map(NotebookChatHome.notebook) ?? .library
    }

    /// The chat-home rule, applied before a saved chat opens in `destination`:
    /// a chat filed in a notebook opens in that notebook's workspace in this
    /// window, and a library chat leaves whatever notebook the window holds.
    /// A chat whose record is not loaded leaves the window as it is.
    func applyChatHome(forSessionID sessionID: String, in destination: StudioWindowState) {
        switch chatHome(forSessionID: sessionID) {
        case .notebook(let notebookID):
            openNotebook(notebookID, in: destination, startsNotebookChat: false)
        case .library:
            closeNotebook(in: destination)
        case nil:
            break
        }
    }

    /// Files the saved chat `sessionID` in the notebook `notebookID`, or in
    /// none, and opens it in `window` where it now lives (`applyChatHome`):
    /// in that notebook, or out of the one the window holds. The chat already
    /// open there stays as it is (`showAlreadyLoadedSession`). The chat's own
    /// notebook picker above the composer asks this way (product owner,
    /// 2026-10-03: one-off chats "unassigned to a notebook; similarly to how
    /// we have that ability in codex to 'not work in a notebook'").
    func refileChat(_ sessionID: String, inNotebook notebookID: String?, in window: StudioWindowState) async {
        await moveReviewSession(sessionID, toNotebook: notebookID)
        inWindow(window) { requestResumeReviewSession(sessionID) }
    }

    /// The sources a notebook made from the chat `sessionID` starts with:
    /// those the chat was given, those its replies link and those it read —
    /// the open chat's own (`openChatSourceIDs`) first, then its record's —
    /// each once, and only while the library holds it. Every one, as
    /// `create_notebook` from a chat takes them (product owner, 2026-10-17:
    /// "Add every source the chat linked or read, with no cap").
    func notebookSourceIDs(fromChat sessionID: String, openChatSourceIDs: [String] = []) async -> [String] {
        let given = reviewSessionLinks.first { $0.id == sessionID }?.sourceIDs ?? []
        let linked = (try? await storage.chatDiscussedSourceIDs(sessionID: sessionID)) ?? []
        let read = (try? await storage.loadReviewSessionLoadedSourceIDs(sessionID: sessionID)) ?? nil
        var seen = Set<String>()
        return (openChatSourceIDs + given + linked + (read ?? []))
            .filter { articlesById[$0] != nil && seen.insert($0).inserted }
    }

    /// A notebook made from a chat (product owner, 2026-10-03: "imagine i just
    /// start in regular chat exploring some ideas and then we can turn it
    /// into a notebook"): made at once, unnamed, holding the chat's sources
    /// (`notebookSourceIDs(fromChat:)`), with the chat filed in it, so
    /// ForeverLM names it from them and the chat (`NotebookNaming`).
    /// `window` then opens the notebook with the chat in it, as opening the
    /// chat would: the chat it shows stays as it is, and one picked from a
    /// list elsewhere is resumed there.
    @discardableResult
    func createNotebook(
        fromChat sessionID: String,
        openChatSourceIDs: [String] = [],
        in window: StudioWindowState
    ) async -> LearningGoalRecord? {
        let sourceIDs = await notebookSourceIDs(fromChat: sessionID, openChatSourceIDs: openChatSourceIDs)
        guard let created = await createUnnamedNotebook() else { return nil }
        // "Created notebook" is the toast; the sources arriving is part of it.
        await addSourcesToNotebookContext(sourceIDs, notebookID: created.id, announce: false)
        await moveReviewSession(sessionID, toNotebook: created.id)
        // The Pages the chat wrote come along, as they do through
        // `create_notebook` (`StorageService.fileChatPages`).
        do {
            if try await !storage.fileChatPages(sessionID: sessionID, inNotebook: created.id).isEmpty {
                await loadArtifacts()
            }
        } catch {
            logger.error("Filing a chat's Pages in the notebook made from it failed: \(error.localizedDescription)")
        }
        inWindow(window) { requestResumeReviewSession(sessionID) }
        return created
    }

    /// Notes the chat `windowState` shows as the one its notebook reopens
    /// with there, when that chat is filed in the notebook. A library chat,
    /// or one whose record is not loaded yet, is not noted.
    func rememberNotebookChat(in windowState: StudioWindowState) {
        guard let notebookID = windowState.NotebookID,
              let sessionID = windowState.chatSessionID,
              chatHome(forSessionID: sessionID) == .notebook(notebookID),
              windowState.notebookChats[notebookID] != sessionID else { return }
        windowState.notebookChats[notebookID] = sessionID
    }
}
