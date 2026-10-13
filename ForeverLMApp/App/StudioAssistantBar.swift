import SwiftUI
import AppKit
import Observation

/// Builds a ReviewSessionManager wired to the ForeverLM app tools (the same tools
/// external MCP assistants use). Kept in the App layer so ReviewSessionManager itself
/// stays decoupled from MCPToolRegistry. Studio owns the manager so a conversation
/// survives panel collapse and pop-out window transitions.
enum StudioAssistantSession {
    @MainActor
    static func makeManager() -> ReviewSessionManager {
        ReviewSessionManager(
            appToolDefinitions: {
                MCPToolRegistry.shared.tools.map { tool in
                    ReviewSessionManager.AppToolDefinition(
                        name: tool.name,
                        description: tool.description,
                        inputSchemaJSON: jsonString(for: tool.inAppInputSchema)
                    )
                }
            },
            appToolExecutor: { name, arguments, hostSessionID in
                let data: Data?
                if JSONSerialization.isValidJSONObject(arguments) {
                    data = try? JSONSerialization.data(withJSONObject: arguments)
                } else {
                    data = nil
                }
                return await Task.detached(priority: .userInitiated) {
                    let detachedArguments: [String: Any]
                    if let data,
                       let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        detachedArguments = decoded
                    } else {
                        detachedArguments = [:]
                    }
                    let outcome = await MCPToolRegistry.shared.callToolDetailed(
                        name: name,
                        arguments: detachedArguments,
                        hostSessionID: hostSessionID
                    )
                    return ReviewSessionManager.AppToolResult(
                        text: outcome.text,
                        isError: outcome.isError
                    )
                }.value
            },
            // Each chat drives a Browser tab of its own (`ChatBrowsing`).
            browserAgent: StudioChatBrowserAgent()
        )
    }

    static func jsonString(for object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Which composer an unsent draft belongs to. A chat that has never been sent
/// has no session id yet, so its draft is filed under the Notebook the New chat
/// button opened it in — that is the composer the learner comes back to.
enum ChatDraftScope: Hashable {
    case newChat(notebookID: String?)
    case session(String)

    /// The scope as the archive files it.
    var archiveKey: String {
        switch self {
        case .newChat(let notebookID): return "new:\(notebookID ?? "")"
        case .session(let sessionID): return "chat:\(sessionID)"
        }
    }
}

/// Unsent composer text, per chat, kept across a relaunch. Codex's composer
/// recovers its drafts (`composer.draftRecovery.*`); ForeverLM's lived in
/// memory only, so a quit lost whatever was half typed. One archive serves
/// every window, so two windows on one chat share its draft.
///
/// Kept in this Mac's defaults, newest last: a draft is this Mac's unsent
/// words, not a record to sync, like the chats' read marks. A keystroke
/// writes memory; the defaults are written a moment after typing stops and
/// when the app quits. The oldest drafts beyond `limit` are let go, and a
/// draft longer than `characterLimit` stays in memory but is not written.
@MainActor
final class ChatDraftArchive {
    static let shared = ChatDraftArchive()

    struct Entry: Codable, Equatable, Sendable {
        let scope: String
        let text: String
    }

    static let defaultsKey = "chat.unsentDrafts"
    static let limit = 40
    static let characterLimit = 200_000
    static let saveDelay: Duration = .milliseconds(600)

    private let defaults: UserDefaults
    /// Oldest first.
    private var entries: [Entry]
    private var saveTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.decode(defaults.data(forKey: Self.defaultsKey))
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func text(for scope: ChatDraftScope) -> String {
        entries.last { $0.scope == scope.archiveKey }?.text ?? ""
    }

    func set(_ text: String, for scope: ChatDraftScope) {
        let next = Self.updating(entries, scope: scope.archiveKey, text: text)
        guard next != entries else { return }
        entries = next
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let kept = entries.filter { $0.text.count <= Self.characterLimit }
        if kept.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// `entries` with `scope`'s draft replaced by `text` at the newest end,
    /// or gone when `text` is empty, keeping the newest `limit`.
    nonisolated static func updating(_ entries: [Entry], scope: String, text: String) -> [Entry] {
        var next = entries.filter { $0.scope != scope }
        if !text.isEmpty { next.append(Entry(scope: scope, text: text)) }
        return Array(next.suffix(limit))
    }

    nonisolated static func decode(_ data: Data?) -> [Entry] {
        guard let data, let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }
}

/// Owns the selected Chat manager plus any managers that still have an
/// in-flight turn after the learner navigates elsewhere. A chat view is only a
/// projection of this store: changing panes must never be interpreted as Stop.
@Observable
@MainActor
final class StudioAssistantSessionStore {
    enum SessionActivation {
        /// The requested manager is now selected. Let the replacement chat
        /// view consume the still-pending navigation request.
        case switched
        /// The selected manager already owns this live or completed session.
        case alreadyLoaded
        /// A fresh manager is selected and must hydrate the persisted session.
        case needsResume
    }

    private(set) var activeManager: ReviewSessionManager
    private var backgroundManagers: [ReviewSessionManager] = []
    @ObservationIgnored private let managerFactory: @MainActor () -> ReviewSessionManager
    @ObservationIgnored private var pendingResumeSessionID: String?
    @ObservationIgnored private var preparedBlankRequestID: UUID?
    private(set) var requestedSessionID: String?
    /// A new chat another pane asked this one to open on handed-in context — an
    /// exchange lifted out of a memory review. Pane-scoped, unlike the
    /// app-wide selection request, so it lands in the pane that was asked and
    /// never in the review it came out of.
    private(set) var pendingNewChatHandoff: NewChatHandoff?
    /// Unsent composer text, kept per chat so navigating away and back does not
    /// throw away what the learner typed, nor does a quit (`ChatDraftArchive`).
    /// Deliberately not observed: it is written on every keystroke and read
    /// only when a composer is rebuilt.
    @ObservationIgnored private let drafts: ChatDraftArchive
    /// This panel's own zoom, as an offset from the app-wide step (`ChatZoom`).
    /// A trackpad pinch over the panel moves it and nothing else: the store is
    /// one per chat host, so a chat window on the other display keeps its own
    /// size, and the offset survives switching chats in this panel, which
    /// rebuilds the panel's content around another manager.
    var chatZoomOffset = 0
    /// Asks the composer of the page's side chat to take focus. That composer
    /// does not follow `StudioViewModel.reviewChatFocusRequestID`, which the
    /// docked pane's composer also answers.
    var composerFocusRequestID = UUID()

    init(
        managerFactory: @escaping @MainActor () -> ReviewSessionManager = StudioAssistantSession.makeManager,
        drafts: ChatDraftArchive = .shared
    ) {
        self.managerFactory = managerFactory
        self.drafts = drafts
        activeManager = managerFactory()
        Self.live.add(self)
    }

    /// Every store alive, in every window: what a list holding no store of its
    /// own — the Space's Chats — ends a deleted chat in.
    private static let live = NSHashTable<StudioAssistantSessionStore>.weakObjects()

    /// Ends the chat in every pane and window that has it open or still
    /// running, before its record goes: a turn left running would save back
    /// into the chat the learner just deleted.
    static func deleteSessionEverywhere(_ sessionID: String) {
        for store in live.allObjects {
            store.deleteSession(sessionID)
        }
    }

    var activeSessionID: String? { activeManager.currentSessionID }

    /// Whether a passage selected in the Reader opens a chat of its own
    /// rather than joining the one this pane shows. It joins only an idle
    /// composer, whatever that has staged; any conversation — even one about
    /// the same paper — is left as it is and the passage starts a new chat
    /// (product owner, 2026-09-19: "when i click chat, it should add to a new
    /// chat"; 2026-09-23, after a passage joined a chat about its own paper:
    /// "when i highlight something in a paper; the chat it opens should be a
    /// new chat").
    ///
    /// A chat still on its way into this pane counts as a conversation. A
    /// relaunch asks for the window's last chat, and when Chat is not on
    /// screen that request waits for the pane; the Chat press that brings
    /// the pane up then met an empty composer, joined it, and the old chat
    /// hydrated over the passage a moment later (2026-09-26: a passage from
    /// an article landed in the morning's unrelated chat as "Added 1 article
    /// to context").
    ///
    /// A walk is never an idle composer, though dealing its cards makes no
    /// chat and so no conversation. It takes a passage from what it walks —
    /// the composer under its card is where a question about that page goes
    /// (walkthrough-design.md) — and nothing else: a passage from another
    /// paper joined the card of a walk through an unrelated source (product owner,
    /// 2026-09-29: "When I highlight something like that, it should open a
    /// totally new chat, obviously"). What's New and Find directions are
    /// research, and never become a turn of the walk.
    func readerSelectionOpensNewChat(for request: ReaderSelectionExplanationRequest) -> Bool {
        if isOpeningChat { return true }
        if let walk = activeManager.walkthroughPlayback {
            guard !request.sendsAtOnce, !request.sourceIDs.isEmpty else { return true }
            return !walk.aboutSourceIDs.isSuperset(of: request.sourceIDs)
        }
        return activeManager.hasConversation
    }

    /// Whether a passage highlighted in a Doc (or a Site) joins the chat this
    /// pane shows instead of the new chat it asked for. It is the one
    /// exception to a passage opening a new chat, and it should be rare: the
    /// chat must already be a conversation working on that Doc. Rewriting a
    /// doc section by section is one conversation, and each next section
    /// belongs under the ones before it (product owner, 2026-09-29, highlighting a
    /// doc's next paragraph beside the chat rewriting its first: "if we're
    /// really working on the same article as was in the chat before, then
    /// highlighting the next section should be added to the same chat", "but
    /// typically a new chat shoudl be started", "only in this edge case").
    ///
    /// Working on the Doc means holding it — handed over with an earlier
    /// passage, dropped in, or added with Add to Chat — or having been
    /// started or joined by one of its passages before (`linkedDocIDs`, the
    /// chat's stored doc links, which outlive a reopen that forgets what was
    /// held). An idle composer is left to the new chat, which starts from the
    /// Doc's Notebook the way every Doc passage's chat does; a walk and a chat
    /// still on its way into the pane never take the passage.
    func docPassageJoinsOpenChat(
        _ request: ReaderSelectionExplanationRequest,
        linkedDocIDs: Set<String>
    ) -> Bool {
        guard let artifactID = request.artifactID, !artifactID.isEmpty,
              request.reviewHandoff == nil, request.sideQuestionHandoff == nil, !request.sendsAtOnce,
              !isOpeningChat,
              activeManager.walkthroughPlayback == nil,
              activeManager.hasConversation
        else { return false }
        return linkedDocIDs.contains(artifactID)
            || activeManager.contextDocs.contains { $0.id == artifactID }
    }

    /// Whether Walk Through plays the walk in a chat of its own rather than
    /// in this pane. A walk is a deck of cards with its own chat under each
    /// card, so it joins only an empty chat or one already playing it;
    /// joining a conversation, even one about the same paper, put the deck
    /// over an unrelated exchange (product owner, 2026-09-22: "it's like over the
    /// chat where I'm in, it's so weird").
    ///
    /// A chat still on its way into this pane counts as a conversation, as
    /// it does for a passage. After a relaunch the window asks for its last
    /// chat, and with Chat behind another tab that request waits for the
    /// pane; Walk Through, which brings the pane up, met an empty chat, the
    /// walk joined it, and the old chat landed under the walk's card
    /// (product owner, 2026-09-30, of a card drawn above a search across his
    /// sources: "a walkthrough got mixed with a chat").
    func walkthroughOpensNewChat(of subjectID: String) -> Bool {
        if isOpeningChat { return true }
        guard activeManager.hasConversation else { return false }
        return !activeManager.chatMessages.contains { $0.walkthroughStep?.sourceID == subjectID }
    }

    /// A chat is asked of this pane, or is being hydrated into it, and has
    /// not arrived yet. Hydrating covers a chat opened from the pane's own
    /// previous-chats list or a Resume suggestion, which resume this pane's
    /// manager without asking the store first.
    var isOpeningChat: Bool {
        requestedSessionID != nil || pendingResumeSessionID != nil || activeManager.isResumingSession
    }

    /// Context handed to a pane for a chat that does not exist yet. The id
    /// keys the pane's task so a second handoff with the same words still
    /// opens a second chat.
    struct NewChatHandoff: Identifiable {
        let id = UUID()
        /// A passage to stage under the new chat's composer; nil when the
        /// chat opens to play a walkthrough instead.
        let request: ReaderSelectionExplanationRequest?
        /// The source whose walkthrough the new chat plays from its first
        /// step (walkthrough-design.md, "the panel becomes a chat").
        var walkthroughSourceID: String? = nil
        /// A page's side chat opening: the page, its sources, the Notebook
        /// and a Prompt block's words ride along with `request`, the
        /// highlighted passage (docs/pages-side-chat-design.md).
        var opening: PageSideChatOpening? = nil
    }

    func requestOpen(sessionID: String) {
        requestedSessionID = sessionID
    }

    /// A walk to play once a chat is open: Walk Through on a walk whose
    /// questions already have a chat opens that chat, so each card's
    /// conversation is under it again (walkthrough-design.md, "the walk
    /// leaves the chat").
    @ObservationIgnored private var walkthroughAfterOpen: (sessionID: String, sourceID: String)?

    func requestOpen(sessionID: String, playingWalkthroughOf sourceID: String) {
        walkthroughAfterOpen = (sessionID, sourceID)
        requestOpen(sessionID: sessionID)
    }

    /// The walk to play now that `sessionID` is open, once.
    func takeWalkthroughAfterOpen(sessionID: String) -> String? {
        guard let pending = walkthroughAfterOpen, pending.sessionID == sessionID else { return nil }
        walkthroughAfterOpen = nil
        return pending.sourceID
    }

    /// Asks this pane to leave whatever it shows and open a blank chat with
    /// `request` staged under its composer.
    func requestNewChat(handingOff request: ReaderSelectionExplanationRequest) {
        // The handed-in context is the later intent: a chat still waiting to
        // open here gives way to it.
        requestedSessionID = nil
        walkthroughAfterOpen = nil
        pendingNewChatHandoff = NewChatHandoff(request: request)
    }

    /// Asks the page's side chat to leave whatever it shows and open a blank
    /// chat about the page, with the passage and the Prompt block's words
    /// staged under its composer.
    func requestNewChat(opening: PageSideChatOpening) {
        requestedSessionID = nil
        walkthroughAfterOpen = nil
        pendingNewChatHandoff = NewChatHandoff(request: opening.passage, opening: opening)
    }

    /// Asks this pane to leave whatever it shows and open a blank chat that
    /// plays `sourceID`'s walkthrough from its first step.
    func requestNewChat(playingWalkthroughOf sourceID: String) {
        // The walk is the later intent: a chat still waiting to open here
        // gives way to it.
        requestedSessionID = nil
        walkthroughAfterOpen = nil
        pendingNewChatHandoff = NewChatHandoff(request: nil, walkthroughSourceID: sourceID)
    }

    /// Lets go of the chat this store shows, which stays saved: a turn still
    /// running is parked and carries on, anything else is ended, and the store
    /// shows a blank chat. The page's side chat does this when its page closes
    /// and when another pane takes the chat it held.
    func closeActiveChat() {
        parkActiveManagerIfNeeded()
        activeManager = managerFactory()
        pendingResumeSessionID = nil
        requestedSessionID = nil
        pruneFinishedBackgroundManagers()
    }

    /// `closeActiveChat()` when this store shows `sessionID`; another pane
    /// opened it, and one chat is never drawn by two panels.
    func releaseChat(_ sessionID: String) {
        guard activeSessionID == sessionID else { return }
        closeActiveChat()
    }

    func didConsumeNewChatHandoff(id: UUID) {
        if pendingNewChatHandoff?.id == id {
            pendingNewChatHandoff = nil
        }
    }

    func didConsumeOpenRequest(sessionID: String) {
        if requestedSessionID == sessionID {
            requestedSessionID = nil
        }
    }

    func isRunning(sessionID: String) -> Bool {
        managers.first(where: { $0.currentSessionID == sessionID })?
            .hasGenerationWorkInFlight == true
    }

    /// Every session with generation work in flight, in one pass. The rail asks
    /// per row; answering per row scanned every manager per row and registered
    /// every row against every manager's generation flags. Compute this once
    /// per body instead and hand rows a plain membership test.
    var runningSessionIDs: Set<String> {
        Set(managers.compactMap {
            $0.hasGenerationWorkInFlight ? $0.currentSessionID : nil
        })
    }

    /// Selects an existing live manager when possible, otherwise installs a
    /// fresh manager for persisted-session hydration. The caller returns after
    /// `.switched`; SwiftUI recreates the chat content with the new manager and
    /// the unchanged request id, then calls this method again.
    func prepareToOpen(sessionID: String) -> SessionActivation {
        if activeManager.currentSessionID == sessionID {
            pendingResumeSessionID = nil
            return .alreadyLoaded
        }
        if pendingResumeSessionID == sessionID,
           activeManager.currentSessionID == nil {
            return .needsResume
        }

        if let index = backgroundManagers.firstIndex(where: { $0.currentSessionID == sessionID }) {
            let requested = backgroundManagers.remove(at: index)
            parkActiveManagerIfNeeded()
            activeManager = requested
            pendingResumeSessionID = nil
            pruneFinishedBackgroundManagers()
            return .switched
        }

        parkActiveManagerIfNeeded()
        activeManager = managerFactory()
        pendingResumeSessionID = sessionID
        pruneFinishedBackgroundManagers()
        return .switched
    }

    func didResume(sessionID: String) {
        if pendingResumeSessionID == sessionID {
            pendingResumeSessionID = nil
        }
        if requestedSessionID == sessionID {
            requestedSessionID = nil
        }
    }

    /// Prepares a blank manager without cancelling a running turn. Returns true
    /// when the manager changed and the replacement view should consume the
    /// same reset request.
    func prepareForNewChat(requestID: UUID) -> Bool {
        if preparedBlankRequestID == requestID {
            preparedBlankRequestID = nil
            return false
        }
        // A manager still hydrating a chat the new one superseded is left to
        // finish into nothing, as a running turn is parked: clearing it here
        // would only be undone when its transcript lands.
        guard activeManager.hasGenerationWorkInFlight || pendingResumeSessionID != nil else {
            pruneFinishedBackgroundManagers()
            return false
        }

        parkActiveManagerIfNeeded()
        activeManager = managerFactory()
        pendingResumeSessionID = nil
        preparedBlankRequestID = requestID
        pruneFinishedBackgroundManagers()
        return true
    }

    func draft(for scope: ChatDraftScope) -> String {
        drafts.text(for: scope)
    }

    func setDraft(_ text: String, for scope: ChatDraftScope) {
        drafts.set(text, for: scope)
    }

    /// Carries a draft to another scope, for a new chat that changes the Notebook
    /// it would start in while text is already in the composer.
    func moveDraft(from old: ChatDraftScope, to new: ChatDraftScope) {
        guard old != new else { return }
        let text = drafts.text(for: old)
        drafts.set("", for: old)
        setDraft(text, for: new)
    }

    func deleteSession(_ sessionID: String) {
        // Ending its running turn below is no reply that finished: the chat
        // is going, and its unread mark with it.
        ChatReadMarks.shared.forget(sessionID)
        drafts.set("", for: .session(sessionID))
        if activeManager.currentSessionID == sessionID {
            activeManager.endSession()
            activeManager = managerFactory()
        }
        backgroundManagers.removeAll { manager in
            guard manager.currentSessionID == sessionID else { return false }
            manager.endSession()
            return true
        }
        if pendingResumeSessionID == sessionID {
            pendingResumeSessionID = nil
        }
    }

    private var managers: [ReviewSessionManager] {
        [activeManager] + backgroundManagers
    }

    private func parkActiveManagerIfNeeded() {
        guard activeManager.hasGenerationWorkInFlight else {
            activeManager.endSession()
            return
        }
        guard !backgroundManagers.contains(where: { $0 === activeManager }) else { return }
        backgroundManagers.append(activeManager)
    }

    /// Finished background turns are already durable. Keep them until the next
    /// navigation event so their spinner can settle naturally, then release
    /// them; reopening hydrates the same transcript from SQLite.
    private func pruneFinishedBackgroundManagers() {
        backgroundManagers.removeAll { manager in
            guard !manager.hasGenerationWorkInFlight else { return false }
            manager.endSession()
            return true
        }
    }

#if DEBUG
    var backgroundManagersForTesting: [ReviewSessionManager] { backgroundManagers }
#endif
}

/// Persistent Chat surface hosted in Studio's right-hand panel.
struct StudioDockedAssistantPanel: View {
    let sessionStore: StudioAssistantSessionStore
    let onDismiss: () -> Void
    var onPopOut: (() -> Void)?
    var acceptsGlobalNavigationRequests = true
    /// How this pane opens a new chat beside itself on handed-in context. Only
    /// the primary docked pane has a neighbour to hand to; nil falls back to
    /// the app-wide request.
    var onOpenNewChatBeside: ((ReaderSelectionExplanationRequest) -> Void)?

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.studioPanelTrailingOverflow) private var trailingOverflow
    @Environment(\.studioCenterTabStripVisible) private var centerTabStripVisible
    @Environment(\.studioTitlebarBandHeight) private var titlebarBandHeight
    @Environment(\.studioChromeLineReservation) private var chromeReservation
    @Environment(\.studioPaneChromePlacement) private var placement

    var body: some View {
        InternalReviewPanel(
            sessionStore: sessionStore,
            onDismiss: onDismiss,
            onPopOut: onPopOut,
            fillsAvailableSpace: true,
            usesDockedHeaderChrome: true,
            headerTrailingChromeClearance: headerTrailingChromeClearance,
            // A sole chat takes the wider reading column: alone in the
            // center, or a notebook's chat with nothing in its document slot.
            expandsChatContent: windowState.notebook.map { $0.document == nil }
                ?? (windowState.centerTabGroups.groups.count == 1),
            acceptsGlobalNavigationRequests: acceptsGlobalNavigationRequests,
            ownerWindowID: windowState.id,
            onOpenNewChatBeside: onOpenNewChatBeside
        )
        // No top padding: the chat title header owns the top row, sized and
        // lifted to sit level with the reader's docked toolbar next door.
        .padding([.horizontal, .bottom], Self.hostInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            // The visible center strip owns the x at toolbar height. When the
            // strip is hidden, this fallback follows the chat title: into the
            // window's titlebar band when one exists, or onto the regular
            // in-flow header line in fullscreen.
            //
            // The x anchors to the content's trailing edge, but a column
            // narrower than its minimum content width clips that edge away, so
            // shift left by whatever the column is clipping to keep the button
            // visible and clickable at the panel's real right edge.
            //
            // Whether it sits on the chrome line, drops to the content row or
            // is not drawn at all is the group's decision, made once beside the
            // pin that shares this corner. Resolving it here with the close
            // button's width alone let the x stay on the line after the pin —
            // which needs the room for both controls — had already dropped.
            if !centerTabStripVisible && drawsCloseControl && placement != .hidden {
                GeometryReader { proxy in
                    closeButton
                        .studioPanelHeaderChrome(
                            height: titlebarBandHeight ?? StudioPanelChrome.headerHeight
                        )
                        .offset(
                            x: -trailingOverflow,
                            y: placement == .chromeLine ? -(titlebarBandHeight ?? 0) : 0
                        )
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height,
                            alignment: .topTrailing
                        )
                }
            }
        }
    }

    /// Closes the Chat pane entirely (nothing is left behind); ⇧⌘K reopens it.
    private var closeButton: some View {
        // A `Button` on the chrome line hands its mouse-down to the titlebar's
        // window drag; see `TitlebarBandHitSurfaceView`.
        TitlebarBandButton(
            help: "Close pane",
            accessibilityLabel: "Close pane",
            action: closePane
        ) {
            Image(systemName: "xmark")
                .zoomedSystemFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(
                    width: StudioPanelChrome.centerTabCloseButtonSize,
                    height: StudioPanelChrome.centerTabCloseButtonSize
                )
        }
    }

    private func closePane() {
        withAnimation(.easeInOut(duration: 0.22)) {
            onDismiss()
        }
    }

    /// Always drawn, even when Chat is the only pane; see
    /// `StudioTopBar.paneDrawsCloseControl`.
    private var drawsCloseControl: Bool {
        StudioTopBar.paneDrawsCloseControl(
            memoryReviewFocused: windowState.memoryReviewFocusSessionID != nil
        )
    }

    /// How far this panel's content sits inside the pane it fills.
    private static let hostInset: CGFloat = 12

    /// The line the chat header's own controls have to stay left of, measured
    /// from this panel's trailing edge.
    ///
    /// The pin, the pane close, and the Sources restore control are drawn over
    /// the pane's top-right corner, so nothing the header lays out can push
    /// them aside — the header gets out of their way instead. Every slot in
    /// `chromeReservation.total` is a control plus the shared gap that follows
    /// it, so the pane's padding plus that total lands exactly one gap left of
    /// the leftmost control. With the center tab strip visible the strip owns
    /// that line and the chat header sits below it, clear of all of them.
    private var headerTrailingChromeClearance: CGFloat {
        guard !centerTabStripVisible else { return 0 }
        return max(0, StudioPanelChrome.headerHorizontalPadding
            + trailingOverflow
            + chromeReservation.total
            - Self.hostInset)
    }
}

// MARK: - The page's side chat

/// How `InternalReviewPanel` is drawn. `.pane` is the docked Chat pane, the
/// comparison pane and the pop-out window; `.pageSideChat` is ChatGPT's page
/// chat, the compact card floating over a page (docs/pages-side-chat-design.md).
enum ChatPanelPresentation {
    case pane
    case pageSideChat(PageSideChatPresentation)
}

/// What the card around a page's side chat hands the panel: the page it is
/// about, the room it has, this page's chats for the title's menu, and what the
/// header's controls do. The panel owns the conversation; the card owns where
/// it sits.
struct PageSideChatPresentation {
    let page: PageSideChatPage
    /// The page pane's height, for the share of it the transcript takes.
    let paneHeight: CGFloat
    /// The page's saved chats, newest first (`PageSideChatChats`).
    let chats: [ReviewSessionRecord]
    let onMinimize: () -> Void
    let onNewChat: () -> Void
    let onOpenChat: (String) -> Void
    /// Moves the open chat into the docked Chat pane.
    let onOpenInChat: () -> Void
}

/// The store a window's page side chat draws, and the question that keeps one
/// chat out of two panels. Nil where there is no Studio root to own a store,
/// and a page's chat then opens in the docked pane as it always did.
struct PageSideChatHosting: Equatable {
    let store: StudioAssistantSessionStore
    /// Whether a docked Chat pane of this window (the primary, the comparison
    /// pane, the pop-out window) shows this chat now.
    let isShownElsewhere: @MainActor (String) -> Bool

    /// One window's hosting is its store: the closure captures that window's
    /// panes, which never change, so a rebuilt value is not a change and does
    /// not redraw every page under it.
    static func == (lhs: PageSideChatHosting, rhs: PageSideChatHosting) -> Bool {
        lhs.store === rhs.store
    }
}

private struct PageSideChatHostingKey: EnvironmentKey {
    static let defaultValue: PageSideChatHosting? = nil
}

extension EnvironmentValues {
    var pageSideChatHosting: PageSideChatHosting? {
        get { self[PageSideChatHostingKey.self] }
        set { self[PageSideChatHostingKey.self] = newValue }
    }
}

/// The page's side chat, drawn over its pane: a compact card at the bottom
/// right, or the pill it minimizes to. It belongs to the open page of its
/// window and goes at its ×, when the page closes or when another opens; the
/// chat stays saved, and the title's menu lists it under its page.
///
/// The editor asks for it through the page's chrome (`sideChatRequest`),
/// because only the editor holds the page's text and sources; the card hands
/// the editor's answer to its own store as a new chat.
struct PageSideChatLayer: View {
    let artifact: ArtifactRecord
    let section: ArtifactSection
    let chrome: ArtifactDocChromeBridge

    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState
    @Environment(\.pageSideChatHosting) private var hosting
    @SyncedStorage("uiZoomStep") private var uiZoomStep = UIZoom.defaultStep

    /// The page the card is open for, and what it was last told about it.
    @State private var openPageID: String?
    @State private var page: PageSideChatPage?
    @State private var isMinimized = false
    @State private var chats: [ReviewSessionRecord] = []
    @State private var paneSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // The layer fills the pane to measure it; only the card takes
            // clicks, so the page underneath keeps every one it had.
            Color.clear.allowsHitTesting(false)
            if let hosting, let page, openPageID == artifact.id {
                ZStack(alignment: .bottomTrailing) {
                    // Minimizing keeps the panel mounted, so a passage waiting
                    // under its composer and a turn's streaming survive it:
                    // it takes no room and draws nothing. Not clipped, which
                    // would cut the composer's popups off at the card's edge.
                    card(hosting: hosting, page: page)
                        .frame(
                            width: isMinimized ? 0 : nil,
                            height: isMinimized ? 0 : nil,
                            alignment: .bottomTrailing
                        )
                        .opacity(isMinimized ? 0 : 1)
                        .allowsHitTesting(!isMinimized)
                        .accessibilityHidden(isMinimized)
                    if isMinimized { pill(hosting: hosting) }
                }
                .padding(PageSideChatLayout.edgeInset)
                .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: isMinimized)
        .animation(.easeInOut(duration: 0.18), value: openPageID)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            paneSize = size
        }
        .onChange(of: chrome.sideChatRequest) { _, opening in
            guard let opening else { return }
            chrome.sideChatRequest = nil
            open(opening)
        }
        // Another page opened: the card was this page's. Its chat is saved
        // and found again under the page; a turn still running carries on.
        .onChange(of: artifact.id) { old, _ in
            guard openPageID == old else { return }
            close()
        }
        // The page's chats come from the table the page's Discussion reads,
        // again whenever a send writes a link or the chat on screen changes.
        .task(id: [artifact.id, vm.artifactChatLinksRevision.uuidString, hosting?.store.activeSessionID ?? ""]) {
            chats = PageSideChatChats.sessions(from: await vm.artifactChatLinks(artifact.id))
        }
    }

    private func open(_ opening: PageSideChatOpening) {
        guard let hosting else { return }
        page = opening.page
        openPageID = artifact.id
        isMinimized = false
        // Add to Chat adds the page to a conversation: one already about this
        // page is brought forward, not replaced.
        if opening.joinsOpenChat, holdsConversationAboutPage(hosting.store, opening.page) {
            hosting.store.composerFocusRequestID = UUID()
            return
        }
        hosting.store.requestNewChat(opening: opening)
    }

    /// Whether the chat in the store is a conversation about `page`: it holds
    /// the page, or it is one of the chats the page lists.
    private func holdsConversationAboutPage(_ store: StudioAssistantSessionStore, _ page: PageSideChatPage) -> Bool {
        let manager = store.activeManager
        guard manager.hasConversation else { return false }
        if manager.contextDocs.contains(where: { $0.id == page.artifactID }) { return true }
        guard let sessionID = manager.currentSessionID else { return false }
        return chats.contains { $0.id == sessionID }
    }

    private func card(hosting: PageSideChatHosting, page: PageSideChatPage) -> some View {
        let zoom = ChatZoom.scale(appStep: uiZoomStep, offset: hosting.store.chatZoomOffset)
        let width = PageSideChatLayout.width(
            wanted: ReviewChatSideChatPopover.width(zoom: zoom),
            paneWidth: paneSize.width
        )
        let shape = RoundedRectangle(cornerRadius: PageSideChatLayout.cornerRadius, style: .continuous)
        return InternalReviewPanel(
            sessionStore: hosting.store,
            onDismiss: close,
            acceptsGlobalNavigationRequests: false,
            ownerWindowID: windowState.id,
            presentation: .pageSideChat(PageSideChatPresentation(
                page: page,
                paneHeight: paneSize.height,
                chats: chats,
                onMinimize: { isMinimized = true },
                onNewChat: { chrome.wholePageChatRequest = PageSideChatWholePageRequest(intent: .newChat) },
                onOpenChat: { openChat($0, hosting: hosting) },
                onOpenInChat: { openInChat(hosting: hosting) }
            ))
        )
        .frame(width: width)
        .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page chat")
        .accessibilityIdentifier("mac.pageSideChat")
    }

    private func pill(hosting: PageSideChatHosting) -> some View {
        let manager = hosting.store.activeManager
        let title: String = {
            guard let sessionID = manager.currentSessionID else { return "New chat" }
            return ChatHeaderTitle.title(
                sessionTitle: vm.reviewSessionLinks.first { $0.id == sessionID }?.title,
                topic: manager.topic,
                isProvisional: manager.titleIsProvisional
            )
        }()
        return HStack(spacing: 8) {
            Button {
                isMinimized = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left")
                        .font(.subheadline)
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if manager.hasGenerationWorkInFlight {
                        ProgressView().controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the page chat")
            .accessibilityLabel("Open the page chat: \(title)")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the page chat")
            .accessibilityLabel("Close the page chat")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 320)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
        .accessibilityIdentifier("mac.pageSideChatPill")
    }

    /// Takes the card off the page and lets go of its chat, as a side chat
    /// disappears (product owner, 2026-10-07: "more like a side chat, so one that
    /// disappears"): the chat stays saved and listed under the page, a turn
    /// still running is parked and carries on, and the page's next Chat opens
    /// a new one. Minimize is the way to keep the thread at hand.
    private func close() {
        hosting?.store.closeActiveChat()
        openPageID = nil
        page = nil
        isMinimized = false
    }

    /// Opens one of the page's chats in the card, or brings forward the docked
    /// pane that already shows it: one chat is never drawn by two panels.
    private func openChat(_ sessionID: String, hosting: PageSideChatHosting) {
        if hosting.isShownElsewhere(sessionID) {
            vm.inWindow(windowState) { vm.revealChat(beside: section.centerTab) }
            return
        }
        hosting.store.requestOpen(sessionID: sessionID)
    }

    /// Moves the open chat to the docked Chat pane, beside the page: the pane
    /// resumes it from storage and the card lets go. The panel offers this
    /// only between turns, because letting go of a running one would stop it.
    private func openInChat(hosting: PageSideChatHosting) {
        guard let sessionID = hosting.store.activeSessionID else { return }
        vm.inWindow(windowState) {
            vm.requestResumeReviewSession(sessionID)
            vm.revealChat(beside: section.centerTab)
        }
        close()
    }
}
