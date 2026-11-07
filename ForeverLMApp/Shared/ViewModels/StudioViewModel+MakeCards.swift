#if os(macOS)
import Foundation

// MARK: - Memory as cards: Make Cards

// docs/memory-design.md, "Drafting" and notebooks-design.md, "Studio". Make
// Cards is said in the chat (product owner, 2026-11-06: "I think that should
// always be in the chat"): the Reader's Make Cards (its source), the
// notebook's Studio Cards tile (its ticked sources), the Library's rows and
// its Make Cards for N open a fresh chat with those sources and "Make cards
// from …" typed but unsent, so the learner adds how many or what for in their
// own words. The chat drafts the cards itself (`save_card_drafts`) or has
// ForeverLM draft them, priced first (`draft_cards`). They wait in Memory's
// To Check, which the chat's reply opens; the Reader's toolbar says "Cards ·
// N to check" for its source until they are gone through.

extension StudioViewModel {

    // MARK: The chat

    /// Make Cards: a fresh chat on `sourceIDs`, in the active window, with
    /// the request typed but unsent (`makeCardsChatDraft`). `notebookID` is
    /// the notebook the chat is filed in — its decided cards are the
    /// drafter's exemplars — and nil from a Reader outside a notebook, which
    /// files it where the window files new chats.
    func requestMakeCardsChat(notebookID: String?, sourceIDs: [String]) {
        var seen = Set<String>()
        let ids = sourceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else {
            showToast("Tick a source to make cards from")
            return
        }
        let titles = ids.compactMap { id in articlesById[id].map { displayTitle(for: $0) } }
        pendingReviewChatNotebookID = notebookID.flatMap { notebook(id: $0)?.id }
        setContextSources(ids)
        pendingReviewChatDraft = Self.makeCardsChatDraft(titles: titles, sourceCount: ids.count)
        reviewChatPanelMode = .chat
        showAssistantOverlay = true
        reviewChatResetRequestID = UUID()
        reviewChatFocusRequestID = UUID()
    }

    /// The notebook's Studio Cards tile's Make Cards…, and the Notebook
    /// menu's Make ▸ Make Cards…: the notebook's ticked sources.
    func requestNotebookMakeCardsChat(notebookID: String) {
        requestMakeCardsChat(notebookID: notebookID, sourceIDs: notebookStudioSourceIDs(notebookID))
    }

    /// The Reader's Make Cards…: its source, in the notebook `windowState`
    /// holds when the source is one of the notebook's.
    func requestReaderMakeCardsChat(sourceID: String, in windowState: StudioWindowState) {
        let notebookID = windowState.notebook?.notebookID
        let inNotebook = notebookID.map { notebookHolds($0, sourceID: sourceID) } ?? false
        inWindow(windowState) {
            requestMakeCardsChat(notebookID: inNotebook ? notebookID : nil, sourceIDs: [sourceID])
        }
    }

    /// The unsent opening of a Make Cards chat: the source by name when there
    /// is one, else how many. It ends on a space, so what the learner types
    /// next — "about ten, on the methods" — reads on from it.
    static func makeCardsChatDraft(titles: [String], sourceCount: Int) -> String {
        if sourceCount == 1, let title = titles.first?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "Make cards from \u{201C}\(title)\u{201D}. "
        }
        return sourceCount == 1 ? "Make cards from this source. " : "Make cards from these \(sourceCount) sources. "
    }

    /// Whether `notebookID`'s sources include `sourceID`, a team's copy of it
    /// counted as the learner's own source.
    func notebookHolds(_ notebookID: String, sourceID: String) -> Bool {
        guard let holder = notebook(id: notebookID) else { return false }
        let members = Set(holder.approvedSourceIDs.map(canonicalSourceID))
        return members.contains(canonicalSourceID(sourceID))
    }

    // MARK: Runs

    /// Stops cards being made; the sources already drafted keep theirs.
    func cancelMakingCards(_ runID: String) {
        CardDraftingCoordinator.shared.cancel(runID)
    }

    // MARK: Where the drafts open

    /// Opens To Check over `scope` in `window` where it covers neither a chat
    /// nor the source (`CardDraftsPlacement`): its empty document slot or the
    /// chat's place while the chat is hidden, in a notebook; a pane of its
    /// own, or one showing neither a chat nor the Reader, otherwise. False,
    /// with nothing changed, when no place does.
    @discardableResult
    func placeCardDrafts(scope: MemoryReviewScope, in window: StudioWindowState) -> Bool {
        switch CardDraftsPlacement.place(
            notebook: window.holdsNotebookSlot ? window.notebook : nil,
            panes: window.centerTabGroups,
            isInMemoryFocus: window.memoryReviewFocus != nil
        ) {
        case .none:
            return false
        case .memoryOnScreen:
            break
        case .notebook(let next):
            if window.notebook != next { window.notebook = next }
        case .panes(let layout):
            if window.centerTabGroups != layout { window.centerTabGroups = layout }
        }
        // Guarded: an @Observable write notifies even when nothing changed.
        if window.memoryPaneScope != scope { window.memoryPaneScope = scope }
        if window.memoryPaneSection != .toCheck { window.memoryPaneSection = .toCheck }
        return true
    }

    // MARK: The cards a chat saved

    /// What a chat's saved cards stand at now, for the cards the reply draws
    /// (`StorageService.chatSavedCards`). Nil when the read failed, so the
    /// reply keeps what it showed.
    func chatSavedCards(_ cards: ChatSavedCards) async -> [ChatSavedCard]? {
        do {
            return try await storage.chatSavedCards(cards)
        } catch {
            logger.error("Failed to read a chat's saved cards: \(error.localizedDescription)")
            return nil
        }
    }

    /// A chat's saved card in To Check, which opens as the Reader's Cards
    /// count opens it — beside the Reader, never over the chat or the source,
    /// narrowed to the window's notebook when the source is one of its — with
    /// `cardID` selected and scrolled to.
    func openChatSavedCard(sourceID: String, cardID: String?, in window: StudioWindowState) {
        if window.memoryPaneFocusCardID != cardID { window.memoryPaneFocusCardID = cardID }
        openCardsToCheckBesideReader(sourceID: sourceID, in: window)
    }

    /// A `foreverlm://cards` link clicked outside the chat's own drawing of
    /// it: To Check at the first of its cards still to check.
    func openChatSavedCards(_ cards: ChatSavedCards) async {
        let window = activeWindowState
        let read = await chatSavedCards(cards) ?? []
        let first = read.first { $0.toCheck != nil } ?? read.first
        guard let sourceID = first?.sourceID ?? cards.sourceIDs.first else {
            openCardsToCheck(scope: .allNotebooks, in: window)
            return
        }
        openChatSavedCard(sourceID: sourceID, cardID: first?.toCheck?.cardID, in: window)
    }

    // MARK: The Reader's count

    /// Cards waiting in To Check on `sourceID`, for the Reader's toolbar
    /// ("Cards · N to check"), from the counts' one read
    /// (`refreshMemoryCardCounts`); a team's copy counts the learner's own
    /// source's cards.
    func memoryCardsToCheck(sourceID: String) -> Int {
        memoryCardsToCheckBySource[canonicalSourceID(sourceID)] ?? memoryCardsToCheckBySource[sourceID] ?? 0
    }

    /// The Reader toolbar's "Cards · N to check" and the ⋯ menu's Cards to
    /// Check: To Check beside the Reader where it covers neither a chat nor
    /// the source, else beside the Reader by the window's ordinary rule (the
    /// learner asked for it), narrowed to the window's notebook when the
    /// source is one of its.
    func openCardsToCheckBesideReader(sourceID: String, in window: StudioWindowState) {
        let notebookID = window.notebook?.notebookID
        let scope: MemoryReviewScope = notebookID.flatMap { notebookHolds($0, sourceID: sourceID) ? .notebook($0) : nil }
            ?? .allNotebooks
        guard !placeCardDrafts(scope: scope, in: window) else { return }
        if window.memoryPaneScope != scope { window.memoryPaneScope = scope }
        if window.memoryPaneSection != .toCheck { window.memoryPaneSection = .toCheck }
        revealCenterTab(.memory, beside: .reader, in: window)
    }
}
#endif
