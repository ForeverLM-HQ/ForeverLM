#if os(macOS)
import Foundation

// MARK: - Memory as cards: writing a source's card

// docs/memory-design.md, "Writing a source's card" (`WrittenCard.swift`).
// Make Cards opens the source in the Reader with the Memory pane beside it
// showing a blank card; the learner writes it, takes its passage from the
// Reader's selection, and Save keeps it. With several sources (the
// Library's Write Cards for N, a notebook's ticked sources, the morning
// banner's) Next Source moves the Reader on. Nothing here calls a model.

extension StudioViewModel {

    // MARK: The way in

    /// Write cards for `sourceIDs`, one source at a time, in the window in
    /// scope: the first opens in the Reader with the card beside it.
    func requestWriteCards(notebookID: String?, sourceIDs: [String]) {
        let window = activeWindowState
        let readable = sourceIDs.filter { id in
            articlesById[id].map(CardsToolbarButton.canMakeCards(from:)) ?? false
        }
        guard let session = CardWritingSession(sourceIDs: readable, notebookID: notebookID) else {
            showToast(sourceIDs.isEmpty ? "Tick a source to write its card" : "These sources have no text to write a card from")
            return
        }
        window.cardWriting = session
        Task { await showWritingSource(in: window) }
    }

    /// The Reader's Write Card: its source, in the notebook the window holds
    /// when the source is one of its.
    func requestReaderWriteCard(sourceID: String, in windowState: StudioWindowState) {
        let notebookID = windowState.notebook?.notebookID
        let inNotebook = notebookID.map { notebookHolds($0, sourceID: sourceID) } ?? false
        inWindow(windowState) {
            requestWriteCards(notebookID: inNotebook ? notebookID : nil, sourceIDs: [sourceID])
        }
    }

    /// The notebook's Studio Cards tile and the Notebook menu's Make ▸ Make
    /// Cards: the notebook's ticked sources.
    func requestNotebookWriteCards(notebookID: String) {
        requestWriteCards(notebookID: notebookID, sourceIDs: notebookStudioSourceIDs(notebookID))
    }

    // MARK: Moving through the sources

    /// The session's source in the window's Reader, and the card beside it.
    private func showWritingSource(in window: StudioWindowState) async {
        guard let sourceID = window.cardWriting?.sourceID else { return }
        await selectArticle(sourceID, in: window, revealingReader: true)
        revealCenterTab(.memory, beside: .reader, in: window)
    }

    /// Next Source: the session moves on and the Reader follows.
    func writeCardsNextSource(in window: StudioWindowState) async {
        guard var session = window.cardWriting, session.advance() else { return }
        window.cardWriting = session
        await showWritingSource(in: window)
    }

    /// Done: the Memory pane goes back to its sections.
    func endCardWriting(in window: StudioWindowState) {
        if window.cardWriting != nil { window.cardWriting = nil }
    }

    /// The session's source, for the card's heading.
    func writingSourceTitle(_ session: CardWritingSession) -> String {
        articlesById[session.sourceID].map { displayTitle(for: $0) } ?? "This source"
    }

    // MARK: The passage

    /// The Reader's selection in the session's source, as the card's
    /// passage. Nil when nothing is selected there.
    func writingPassageFromSelection(_ session: CardWritingSession) -> String? {
        guard let selection = activeReaderSelection,
              canonicalSourceID(selection.sourceID) == canonicalSourceID(session.sourceID)
        else { return nil }
        return WrittenCardInput.passage(fromSelection: selection.text)
    }

    // MARK: Saving

    /// Keeps the card the learner wrote on the session's source. Nil when it
    /// was kept; else what to tell them, and nothing is saved.
    func saveWrittenCard(_ input: WrittenCardInput, in window: StudioWindowState) async -> String? {
        guard let session = window.cardWriting else { return "No source is open to write a card for." }
        guard let card = input.card() else { return input.missing?.help }
        let sourceID = canonicalSourceID(session.sourceID)
        let passage = input.passage.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await storage.validatedMemorySourceAnchor(sourceID: sourceID, excerpt: passage)
        } catch {
            return "That passage is not in the source's saved text. Select it again in the Reader and press Use Selection."
        }
        do {
            try await storage.keepMemoryCard(card, sourceID: sourceID, quote: passage)
        } catch {
            logger.error("Failed to keep a written card: \(error.localizedDescription)")
            return "The card was not saved. \(error.localizedDescription)"
        }
        if var current = window.cardWriting, current.sourceID == session.sourceID {
            current.noteSaved()
            window.cardWriting = current
        }
        memoryCardRevision &+= 1
        await refreshMemoryCardCounts()
        return nil
    }
}
#endif
