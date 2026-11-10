// Requests that open or reset the review chat in a window.

import Foundation
import CryptoKit
import Observation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif
import SwiftUI
import AppKit
import SQLite3
import WebKit
import Darwin

extension StudioViewModel {

    /// Opens a saved chat in the window in scope. Which workspace it opens in
    /// follows the chat (`applyChatHome`): one filed in a notebook opens that
    /// notebook here, a library chat leaves the window's notebook.
    func requestResumeReviewSession(_ sessionID: String) {
        applyChatHome(forSessionID: sessionID, in: chatRequestOriginWindow ?? activeWindowState)
        reviewChatResumeSessionID = sessionID
        reviewChatPanelMode = .chat
        isChatTabActive = true
    }

    func requestResetReviewChat() {
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatResetRequestID = UUID()
    }

    /// Start a tutor review of a Notebook's approved sources from outside the
    /// chat panel: seeds the context, links the notebook (so completing the
    /// session records against it), and auto-starts the session. The reset
    /// request runs before the auto-start request in the panel's task order,
    /// so the notebook link is in place when the session begins.
    func requestNotebookReview(_ notebookID: String) {
        guard let notebook = notebook(id: notebookID) else { return }
        // Every box unticked: there is nothing to review, and the idle
        // composer's Start review says so in the same words.
        let tally = notebookChatTally(notebook)
        if tally.inChat == 0, tally.total > 0 {
            showToast("Tick a source in \u{201C}\(notebook.title)\u{201D} to review it.")
            return
        }
        pendingReviewChatNotebookID = notebook.id
        setContextSources(notebookChatSourceIDs(notebook))
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatResetRequestID = UUID()
        reviewChatAutoStartRequestID = UUID()
    }

    /// Records which window the chat request being made is for, and says so
    /// whenever that is not the window the request was made in.
    ///
    /// The destination is the window in scope — the key Studio window, or the
    /// one an `inWindow` scope names (`chatRequestDestinationWindow`). Only a
    /// request from a window that is no Studio window at all (a popped-out
    /// Reader) lands elsewhere, in the Studio window used last. The chat then
    /// appears on a display the learner may not be looking at, and a click
    /// whose result shows up somewhere else looks like a click that did
    /// nothing — so the toast names where it went. Called from the request
    /// tokens' `didSet`, so every requester is covered.
    func stampChatRequestTargetWindow() {
        let origin = chatRequestOriginWindow
        let destination = chatRequestDestinationWindow(origin: origin)
        reviewChatTargetWindowID = destination.id
        chatRequestElsewhereNotice = chatOpenedElsewhereNotice(origin: origin, destination: destination)
        if let chatRequestElsewhereNotice {
            let replay = ChatRequestReplay(
                resumeSessionID: reviewChatResumeSessionID,
                resetsChat: reviewChatResetRequestID != nil,
                autoStarts: reviewChatAutoStartRequestID != nil,
                notebookID: pendingReviewChatNotebookID,
                draft: pendingReviewChatDraft
            )
            showToast("Opened in \(chatRequestElsewhereNotice)", action: .openHere { [weak self] window in
                self?.replayChatRequest(replay, in: window)
            })
        }
    }

    /// What a chat request asked for, captured while its tokens are still
    /// set, so the toast's Open here can ask again in another window after
    /// the pane over there has consumed and cleared them.
    struct ChatRequestReplay: Equatable {
        var resumeSessionID: String?
        var resetsChat: Bool
        var autoStarts: Bool
        var notebookID: String?
        var draft: String?
    }

    /// Makes the chat request `replay` again, this time for `window`, from
    /// the toast's Open here. The request went elsewhere because it came from
    /// a popped-out Reader, and the button is the learner naming this window
    /// instead: Chat is revealed here first, releasing a pin if it has to, so
    /// the restamped request lands here and raises no second toast. The request is made inside the window's scope
    /// rather than the key window's: the button was pressed in this window,
    /// but the registry's notion of key can lag the click.
    func replayChatRequest(_ replay: ChatRequestReplay, in window: StudioWindowState) {
        activateCenterTab(.chat, in: window)
        inWindow(window) {
            reviewChatPanelMode = .chat
            isChatTabActive = true
            if replay.resetsChat {
                pendingReviewChatNotebookID = replay.notebookID
                pendingReviewChatDraft = replay.draft
                reviewChatResetRequestID = UUID()
            }
            if let sessionID = replay.resumeSessionID {
                reviewChatResumeSessionID = sessionID
            }
            if replay.autoStarts {
                reviewChatAutoStartRequestID = UUID()
            }
            reviewChatTargetWindowID = window.id
        }
    }

    /// The window a chat request made in `origin` should show in: always
    /// `origin`, the window the click was made in. It never goes to another
    /// window that happens to show Chat already, since sending it there is
    /// what the context menu's Open in Other Window is for (product owner,
    /// 2026-09-22: "no actual click on anything should ever open the thing in
    /// the other ForeverLM window"). A nil origin (no Studio window is key, as
    /// from a popped-out Reader) starts from the Studio window used last.
    func chatRequestDestinationWindow(origin: StudioWindowState?) -> StudioWindowState {
        origin ?? activeWindowState
    }

    /// Where the chat went, for the learner, when it is not the window the
    /// request was made in; nil when it shows in place. Only Studio windows on
    /// the registry count: the fallback scene tests and launch helpers navigate
    /// through is not a window on anyone's desk. From a window that is no
    /// Studio window the chat has always gone elsewhere, but with one Studio
    /// window open there is nowhere else it could have gone, so that says
    /// nothing; with two or more, it is one of several.
    private func chatOpenedElsewhereNotice(
        origin: StudioWindowState?,
        destination: StudioWindowState
    ) -> String? {
        let registered = StudioWindowRegistry.shared.states
        guard registered.contains(where: { $0 === destination }) else { return nil }
        if let origin {
            guard origin !== destination, registered.contains(where: { $0 === origin }) else { return nil }
            return Self.otherWindowDescription(otherWindowCount: registered.count - 1)
        }
        guard registered.count > 1 else { return nil }
        return Self.otherWindowDescription(otherWindowCount: registered.count)
    }

    /// "The other" is only honest while exactly one other Studio window is
    /// open; a second makes it one of several.
    static func otherWindowDescription(otherWindowCount: Int) -> String {
        otherWindowCount > 1 ? "another ForeverLM window" : "the other ForeverLM window"
    }

    /// Whether a primary Chat pane hosted in the window `ownerWindowID` should
    /// act on the pending global chat requests. A pane that does not know its
    /// window, and a request made before any was stamped, keep the old
    /// behaviour of accepting everything.
    func chatPaneAcceptsGlobalRequests(ownerWindowID: UUID?) -> Bool {
        guard let ownerWindowID, let reviewChatTargetWindowID else { return true }
        return ownerWindowID == reviewChatTargetWindowID
    }

    /// Pass a `notebookID` to start the fresh chat linked to that Notebook with the
    /// sources ticked in its pool as context (`notebookChatSourceIDs`). Nil
    /// asks for a library chat — Plan the Day, Getting Started, a scheduled
    /// task, a Goal chat with no Notebook — and a window holding a notebook
    /// leaves it first, as opening a library chat does (the chat-home rule,
    /// `applyChatHome`). New chat buttons ask through `requestNewChat`, which
    /// names the window's notebook.
    func requestBlankReviewChat(notebookID: String? = nil) {
        if notebookID == nil {
            closeNotebook(in: chatRequestOriginWindow ?? activeWindowState)
        }
        startBlankReviewChat(notebookID: notebookID)
    }

    /// The fresh chat `requestBlankReviewChat` and `requestNewChat` ask for,
    /// in whatever workspace the window is in: linked to `notebookID` with its
    /// ticked sources as context, or fully blank and unlinked.
    func startBlankReviewChat(notebookID: String?) {
        if let notebookID, let notebook = notebook(id: notebookID) {
            pendingReviewChatNotebookID = notebook.id
            setContextSources(notebookChatSourceIDs(notebook))
        } else {
            pendingReviewChatNotebookID = nil
            clearSourceContext()
        }
        reviewChatPanelMode = .chat
        isChatTabActive = true
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
    }

    /// Open a fresh chat with the new-task template already typed but unsent.
    /// A scheduled task is a sentence ("every weekday at 7:30, quiz me on what I
    /// read yesterday"), not a set of fields, so the Tasks pane's "+" hands the
    /// learner to chat: the assistant asks for whatever the instruction and
    /// cadence still need and calls create_scheduled_task itself. The editor
    /// sheet stays for changing a task that already exists.
    func requestNewScheduledTaskChat() {
        pendingReviewChatDraft = "Set up a recurring scheduled task for me. Ask me what it should do and when it should run, then create it."
        requestBlankReviewChat()
    }

    /// Open a fresh chat that makes an animation. With a source, the chat
    /// starts with that source in context and the request typed but unsent —
    /// the source menu's Animate…; without one, the Animations home's button
    /// opens a blank chat with the request typed and the learner adds the
    /// source with /source. The chat draws the animation and saves it with
    /// save_animation, linked to the source (docs/animations-design.md).
    func requestAnimationChat(sourceID: String? = nil) {
        if let sourceID, let article = articles.first(where: { $0.id == sourceID }) {
            pendingReviewChatNotebookID = nil
            setContextSources([sourceID])
            pendingReviewChatDraft = Self.animationChatDraft(sourceTitle: displayTitle(for: article))
            reviewChatPanelMode = .chat
            isChatTabActive = true
            reviewChatResetRequestID = UUID()
            reviewChatFocusRequestID = UUID()
        } else {
            pendingReviewChatDraft = Self.animationChatDraft(sourceTitle: nil)
            requestBlankReviewChat()
        }
    }

    /// The unsent opening line for a chat that makes an animation. It names
    /// the source when there is one and leaves the mechanism to the learner:
    /// what to animate is the one thing only they can say.
    static func animationChatDraft(sourceTitle: String?) -> String {
        if let sourceTitle, !sourceTitle.isEmpty {
            return "Make an interactive animation of how the mechanism in \u{201C}\(sourceTitle)\u{201D} works — every step labelled and placed where it happens, with a toggle for each condition the paper compares — and save it with save_animation linked to this source. Animate: "
        }
        return "Make an interactive animation of how something works — every step labelled and placed where it happens, with a toggle for each condition compared — and save it with save_animation linked to the sources you draw it from. Animate: "
    }

    /// Opens the day-planning conversation with `request` unsent in the
    /// composer. The text is `ReviewSlashCommandParser.planDayRequest`, so the
    /// Today menu, the Now chip, "Plan your day?" and `/plan` all open the
    /// same conversation under the same rules rather than near-copies.
    func requestPlanDayChat(request: String) {
        pendingReviewChatDraft = request
        pendingPlanDayDraft = request
        requestBlankReviewChat()
    }

    /// Reveal the previous-sessions list inside the open Chat panel (popover).
    func revealReviewSessionSidebar() {
        reviewSessionsRevealRequestID = UUID()
    }

}
