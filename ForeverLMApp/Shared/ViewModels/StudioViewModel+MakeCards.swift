#if os(macOS)
import Foundation

// MARK: - Memory as cards: Make Cards
//
// docs/memory-design.md, "Drafting" and notebooks-design.md, "Studio". Make
// Cards asks first and makes on the second press, as every Studio tile does:
// the Reader's Make Cards (its source) and the notebook's Studio Cards tile
// (its ticked sources) open a one-line sheet — Cards: Auto · 10 · 20 · 40;
// Focus; "15 sources · 11 not opened here"; the price — whose Make drafts
// the cards (`makeCards`). They arrive kept by default in Memory's To Check,
// which opens beside the Reader once they are ready and never over a chat or
// the source (`CardDraftsPlacement`); the Reader's toolbar says "Cards · N to
// check" for its source until they are gone through.

extension StudioViewModel {

    // MARK: The sheet

    /// Make Cards' first press: the sheet for `sourceIDs`, in the active
    /// window (`MakeCardsSheet`). `notebookID` is the notebook the cards are
    /// made in — its decided cards are the drafter's exemplars, and To Check
    /// opens narrowed to it — and nil from a Reader outside a notebook.
    func presentMakeCards(notebookID: String?, sourceIDs: [String]) {
        var seen = Set<String>()
        let ids = sourceIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else {
            showToast("Tick a source to make cards from")
            return
        }
        CardDraftingCoordinator.shared.present(MakeCardsTarget(
            notebookID: notebookID,
            sourceIDs: ids,
            windowID: activeWindowState.id
        ))
    }

    /// The notebook's Studio Cards tile's Make Cards…, and the Notebook
    /// menu's Make ▸ Make Cards…: the notebook's ticked sources.
    func presentNotebookMakeCards(notebookID: String) {
        presentMakeCards(notebookID: notebookID, sourceIDs: notebookStudioSourceIDs(notebookID))
    }

    /// The Reader's Make Cards…: its source, in the notebook `windowState`
    /// holds when the source is one of the notebook's.
    func presentReaderMakeCards(sourceID: String, in windowState: StudioWindowState) {
        let notebookID = windowState.notebook?.notebookID
        let inNotebook = notebookID.map { notebookHolds($0, sourceID: sourceID) } ?? false
        inWindow(windowState) {
            presentMakeCards(notebookID: inNotebook ? notebookID : nil, sourceIDs: [sourceID])
        }
    }

    /// Whether `notebookID`'s sources include `sourceID`, a team's copy of it
    /// counted as the learner's own source.
    func notebookHolds(_ notebookID: String, sourceID: String) -> Bool {
        guard let holder = notebook(id: notebookID) else { return false }
        let members = Set(holder.approvedSourceIDs.map(canonicalSourceID))
        return members.contains(canonicalSourceID(sourceID))
    }

    /// The sheet's sources line: "15 sources · 11 not opened here".
    static func makeCardsSourcesLine(sourceCount: Int, notOpened: Int) -> String {
        var line = sourceCount == 1 ? "1 source" : "\(sourceCount) sources"
        if notOpened > 0 { line += " · \(notOpened) not opened here" }
        return line
    }

    // MARK: Pricing and making

    /// What `makeCards` would draft and what it would cost, read and planned
    /// off the main actor, on the learner's Card Drafting route as it stands.
    /// Throws when no model is configured or the sources cannot be read.
    func makeCardsPlan(
        notebookID: String?,
        sourceIDs: [String],
        count: MemoryCardRequestCount,
        focus: String?
    ) async throws -> CardDraftingPlan {
        let request = CardDraftingRequest(
            notebookID: notebookID,
            sourceIDs: sourceIDs,
            count: count,
            focus: focus,
            trigger: .requested
        )
        let materials = try await CardDraftingCoordinator.load(request, storage: storage)
        return try await CardDraftingCoordinator.plan(materials, count: request.count, focus: request.focus)
    }

    /// Make Cards: drafts cards from `sourceIDs` — each source's whole text,
    /// its free walkthrough questions first — into Memory's To Check, where
    /// the learner keeps, edits or skips them, and opens To Check
    /// in the active window when the cards are ready, where it covers neither
    /// a chat nor the source (or a toast offers it). The caller has shown the
    /// learner the price: the Make Cards sheet does (`makeCardsPlan`).
    /// Learner-started, so the background cap never pauses it, though the
    /// ledger counts it. Nil when nothing could be planned, it was stopped,
    /// or it failed (said in a toast).
    @discardableResult
    func makeCards(
        notebookID: String?,
        sourceIDs: [String],
        count: MemoryCardRequestCount,
        focus: String?
    ) async -> CardDraftingResult? {
        let windowID = activeWindowState.id
        let plan: CardDraftingPlan
        do {
            plan = try await makeCardsPlan(notebookID: notebookID, sourceIDs: sourceIDs, count: count, focus: focus)
        } catch {
            showToast(error.localizedDescription)
            return nil
        }
        return await CardDraftingCoordinator.shared.make(plan, windowID: windowID, in: self)
    }

    /// The sheet's Make: the plan it priced, drafted, its cards opened in
    /// the window it was asked from.
    @discardableResult
    func makeCards(_ plan: CardDraftingPlan, windowID: UUID?) async -> CardDraftingResult? {
        await CardDraftingCoordinator.shared.make(plan, windowID: windowID, in: self)
    }

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
