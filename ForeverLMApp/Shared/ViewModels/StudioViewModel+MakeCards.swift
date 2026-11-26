#if os(macOS)
import Foundation

// MARK: - Memory as cards: drafts and the cards a chat saved

// docs/memory-design.md, "Drafting". A source's card is the learner's to
// write (`StudioViewModel+WriteCards.swift`); a model drafts cards only when
// the learner asks a chat for them (`save_card_drafts`, or `draft_cards`
// priced first). Those drafts wait in Memory's To Check, which the chat's
// reply opens; the Reader's toolbar says "Cards · N to check" for its source
// until they are gone through.

extension StudioViewModel {

    /// Whether `notebookID`'s sources include `sourceID`, a team's copy of it
    /// counted as the learner's own source.
    func notebookHolds(_ notebookID: String, sourceID: String) -> Bool {
        guard let holder = notebook(id: notebookID) else { return false }
        let members = Set(holder.approvedSourceIDs.map(canonicalSourceID))
        return members.contains(canonicalSourceID(sourceID))
    }

    // MARK: Runs

    // MARK: Where the drafts open

    /// Opens To Check over `scope` in `window` where it covers neither a chat
    /// nor the source (`CardDraftsPlacement`): a pane of its own, or one
    /// showing neither a chat nor the Reader. False, with nothing changed,
    /// when no place does.
    @discardableResult
    func placeCardDrafts(scope: MemoryReviewScope, in window: StudioWindowState) -> Bool {
        switch CardDraftsPlacement.place(
            panes: window.centerTabGroups,
            isInMemoryFocus: window.memoryReviewFocus != nil
        ) {
        case .none:
            return false
        case .memoryOnScreen:
            break
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

    /// A chat's saved cards, from its Open button or a `foreverlm://cards`
    /// link: To Check at the first of its cards still to check.
    func openChatSavedCards(_ cards: ChatSavedCards, in window: StudioWindowState? = nil) async {
        let window = window ?? activeWindowState
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
