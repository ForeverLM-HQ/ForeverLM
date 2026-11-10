// ScheduleChatNavigationTests: new chat and the chat-home rule in a notebook window.

import Testing
import Foundation
import UniformTypeIdentifiers
import AppKit
import SQLite3
@testable import ForeverLM

// MARK: - New chat and the chat-home rule in a notebook window

extension ScheduleChatNavigationTests {
    private static let notebookNow = Date(timeIntervalSince1970: 1_790_000_000)

    /// A notebook of the library the test host has open.
    private static func notebook(_ id: String, teamID: String?, archived: Bool = false) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: "Notebook \(id)",
            startAt: notebookNow,
            endAt: LearningGoalRecord.openEndedEndAt,
            createdAt: notebookNow,
            updatedAt: notebookNow,
            status: archived ? LearningGoalStatus.archived.rawValue : LearningGoalStatus.active.rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            teamID: teamID
        )
    }

    /// A timebound Goal drawing on `notebookID`.
    private static func goal(_ id: String, in notebookID: String, teamID: String?) -> LearningGoalRecord {
        LearningGoalRecord(
            id: id,
            title: "Goal \(id)",
            startAt: notebookNow,
            endAt: notebookNow.addingTimeInterval(7 * 86_400),
            createdAt: notebookNow,
            updatedAt: notebookNow,
            status: LearningGoalStatus.active.rawValue,
            items: [],
            kind: LearningGoalRecord.companionKind,
            parentNotebookID: notebookID,
            teamID: teamID
        )
    }

    private static func chat(_ id: String, filedUnder goalID: String?) -> ReviewSessionRecord {
        ReviewSessionRecord(
            id: id,
            title: "Chat \(id)",
            createdAt: notebookNow,
            status: "completed",
            sourceIDs: [],
            goalID: goalID
        )
    }

    @Test("New chat in a notebook window is the notebook's; a library chat leaves the notebook; an archived one's stays put")
    func newChatInANotebookWindowIsTheNotebooks() {
        let restoreTemplate = capturedStudioWindowTemplate()
        defer { restoreTemplate() }
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", teamID: vm.activeTeamID),
            Self.notebook("shelved", teamID: vm.activeTeamID, archived: true),
        ]
        let notebookWindow = StudioWindowState()
        notebookWindow.notebook = NotebookWorkspace(notebookID: "bio")
        let libraryWindow = StudioWindowState()

        // New chat — the rail, /new, a walk's leave — names the window's notebook.
        vm.inWindow(notebookWindow) { vm.requestNewChat() }
        #expect(vm.pendingReviewChatNotebookID == "bio")
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.pendingNotebookChatRequestID == nil, "an explicit New chat seeds its context at once")
        #expect(vm.newChatNotebookID(in: notebookWindow) == "bio")

        vm.inWindow(libraryWindow) { vm.requestNewChat() }
        #expect(vm.pendingReviewChatNotebookID == nil)
        #expect(vm.newChatNotebookID(in: libraryWindow) == nil)

        // A chat asked for with no Notebook — Plan the Day, Getting Started,
        // a scheduled task — is a library chat, and leaves the notebook as
        // opening a library chat does.
        vm.inWindow(notebookWindow) { vm.requestBlankReviewChat() }
        #expect(vm.pendingReviewChatNotebookID == nil)
        #expect(notebookWindow.notebook == nil)

        // In an archived notebook New chat is unfiled, and the window stays.
        notebookWindow.notebook = NotebookWorkspace(notebookID: "shelved")
        vm.inWindow(notebookWindow) { vm.requestNewChat() }
        #expect(vm.pendingReviewChatNotebookID == nil, "an archived notebook's chats are the library's")
        #expect(notebookWindow.NotebookID == "shelved")
        #expect(vm.newChatNotebookID(in: notebookWindow) == nil)

        // A notebook named outright still wins over the window's.
        vm.inWindow(libraryWindow) { vm.requestBlankReviewChat(notebookID: "bio") }
        #expect(vm.pendingReviewChatNotebookID == "bio")
    }

    @Test("A chat filed in a notebook opens that notebook in this window; a library chat leaves it")
    func savedChatOpensInItsHome() {
        let restoreTemplate = capturedStudioWindowTemplate()
        let priorActiveNotebookID = ActiveNotebookPreference.notebookID
        defer {
            restoreTemplate()
            ActiveNotebookPreference.notebookID = priorActiveNotebookID
        }
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", teamID: vm.activeTeamID),
            Self.notebook("neuro", teamID: vm.activeTeamID),
            Self.notebook("shelved", teamID: vm.activeTeamID, archived: true),
            Self.goal("goal-in-bio", in: "bio", teamID: vm.activeTeamID),
        ]
        vm.reviewSessionLinks = [
            Self.chat("bio-chat", filedUnder: "bio"),
            Self.chat("goal-chat", filedUnder: "goal-in-bio"),
            Self.chat("loose-chat", filedUnder: nil),
            Self.chat("shelved-chat", filedUnder: "shelved"),
            Self.chat(MemoryReviewSession.sessionID(for: Self.notebookNow), filedUnder: "bio"),
        ]
        let window = StudioWindowState()

        // From the library: the chat's notebook opens here, with this chat in
        // it rather than a fresh one.
        vm.inWindow(window) { vm.requestResumeReviewSession("bio-chat") }
        #expect(window.NotebookID == "bio")
        #expect(vm.reviewChatResumeSessionID == "bio-chat")
        #expect(vm.pendingNotebookChatRequestID == nil)

        // A chat on a Goal belongs to the notebook the Goal draws on.
        window.notebook = NotebookWorkspace(notebookID: "neuro")
        vm.inWindow(window) { vm.requestResumeReviewSession("goal-chat") }
        #expect(window.NotebookID == "bio")

        // A library chat leaves the notebook; so do an archived notebook's
        // chats and a day's memory review, which the rail lists outside
        // every notebook.
        for libraryChat in ["loose-chat", "shelved-chat", MemoryReviewSession.sessionID(for: Self.notebookNow)] {
            window.notebook = NotebookWorkspace(notebookID: "neuro")
            vm.inWindow(window) { vm.requestResumeReviewSession(libraryChat) }
            #expect(window.notebook == nil, "\(libraryChat)")
            #expect(vm.reviewChatResumeSessionID == libraryChat)
        }

        // A chat whose record is not loaded leaves the window as it is.
        window.notebook = NotebookWorkspace(notebookID: "neuro")
        vm.inWindow(window) { vm.requestResumeReviewSession("not-loaded") }
        #expect(window.NotebookID == "neuro")
    }

    @Test("Opening a notebook over a library chat asks for a fresh notebook chat and writes nothing synced")
    func openingANotebookStartsItsChatWithoutWriting() {
        let restoreTemplate = capturedStudioWindowTemplate()
        let priorActiveNotebookID = ActiveNotebookPreference.notebookID
        defer {
            restoreTemplate()
            ActiveNotebookPreference.notebookID = priorActiveNotebookID
        }
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", teamID: vm.activeTeamID),
            Self.notebook("neuro", teamID: vm.activeTeamID),
        ]
        vm.reviewSessionLinks = [
            Self.chat("loose-chat", filedUnder: nil),
            Self.chat("bio-chat", filedUnder: "bio"),
        ]
        let contextBefore = vm.contextSourceIds
        let window = StudioWindowState()

        // An empty chat: the pane files it in the notebook itself, so no
        // request goes out.
        vm.reviewChatResetRequestID = nil
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(window.NotebookID == "bio")
        #expect(vm.reviewChatResetRequestID == nil)

        // The notebook's own chat stays.
        window.notebook = nil
        window.chatSessionID = "bio-chat"
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(vm.reviewChatResetRequestID == nil)

        // A library chat gives way to a fresh notebook chat that reads the
        // ticks live: the request names it, and the context is untouched.
        window.notebook = nil
        window.chatSessionID = "loose-chat"
        vm.inWindow(window) { vm.openNotebookInReader("neuro") }
        #expect(window.NotebookID == "neuro")
        #expect(vm.pendingReviewChatNotebookID == "neuro")
        #expect(vm.reviewChatResetRequestID != nil)
        #expect(vm.pendingNotebookChatRequestID == vm.reviewChatResetRequestID)
        #expect(vm.contextSourceIds == contextBefore)
        // The active Notebook, a preference on this Mac only, names the
        // notebook last opened.
        #expect(vm.activeNotebookId == "neuro")

        // Opening the notebook the window already holds asks for nothing.
        let request = vm.reviewChatResetRequestID
        vm.inWindow(window) { vm.openNotebookInReader("neuro") }
        #expect(vm.reviewChatResetRequestID == request)
    }

    @Test("Coming back to a notebook in a window reopens the chat it last had open there; a deleted one starts over")
    func reopeningANotebookReopensItsLastChat() {
        let restoreTemplate = capturedStudioWindowTemplate()
        let priorActiveNotebookID = ActiveNotebookPreference.notebookID
        defer {
            restoreTemplate()
            ActiveNotebookPreference.notebookID = priorActiveNotebookID
        }
        let vm = makeViewModel()
        vm.learningGoals = [
            Self.notebook("bio", teamID: vm.activeTeamID),
            Self.notebook("neuro", teamID: vm.activeTeamID),
        ]
        vm.reviewSessionLinks = [
            Self.chat("bio-chat", filedUnder: "bio"),
            Self.chat("neuro-chat", filedUnder: "neuro"),
            Self.chat("loose-chat", filedUnder: nil),
        ]
        let window = StudioWindowState()

        // The window notes the notebook's chat while it holds the notebook;
        // a library chat is never noted.
        window.notebook = NotebookWorkspace(notebookID: "bio")
        window.chatSessionID = "loose-chat"
        vm.rememberNotebookChat(in: window)
        #expect(window.notebookChats.isEmpty)
        window.chatSessionID = "bio-chat"
        vm.rememberNotebookChat(in: window)
        #expect(window.notebookChats == ["bio": "bio-chat"])
        // Kept in the window's scene snapshot only.
        #expect(StudioWindowState(snapshot: window.snapshot).notebookChats == ["bio": "bio-chat"])

        // Away to a library chat, then back: the notebook's chat reopens,
        // and no fresh chat is asked for.
        window.notebook = nil
        window.chatSessionID = "loose-chat"
        vm.reviewChatResetRequestID = nil
        vm.reviewChatResumeSessionID = nil
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(window.NotebookID == "bio")
        #expect(vm.reviewChatResumeSessionID == "bio-chat")
        #expect(vm.reviewChatResetRequestID == nil)

        // An empty chat gives way to it too.
        window.notebook = nil
        window.chatSessionID = nil
        vm.reviewChatResumeSessionID = nil
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(vm.reviewChatResumeSessionID == "bio-chat")

        // Deleted since: forgotten, and the notebook starts over.
        window.notebook = nil
        window.chatSessionID = "loose-chat"
        vm.reviewSessionLinks.removeAll { $0.id == "bio-chat" }
        vm.reviewChatResumeSessionID = nil
        vm.inWindow(window) { vm.openNotebookInReader("bio") }
        #expect(window.notebookChats["bio"] == nil)
        #expect(vm.reviewChatResumeSessionID == nil)
        #expect(vm.pendingNotebookChatRequestID == vm.reviewChatResetRequestID)
        #expect(vm.reviewChatResetRequestID != nil)
    }
}
