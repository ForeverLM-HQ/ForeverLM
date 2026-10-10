import Foundation

// MARK: - Memory as cards: going through the cards to check
//
// docs/memory-design.md, "Cards to check". Drafted cards wait in To Check —
// the Memory pane's second section, over every notebook or narrowed to one —
// until the learner keeps, edits or skips them; the items from before cards
// are offered there once. A notebook's Studio says its cards on its Cards
// row ("42 kept · 6 due · 9 to check"), which opens To Check narrowed to the
// notebook in the document slot while any wait, else its Review.

extension StudioViewModel {
    /// To Check over `scope`, in the window in scope (or
    /// `destinationWindowState`): the Memory pane on its To Check section —
    /// inside a window holding a notebook, the notebook's document slot, the
    /// notebook left as it was. The Studio's Cards row asks for its notebook;
    /// ForeverLM's own drafting opens it when the cards it was asked for are
    /// ready.
    func openCardsToCheck(scope: MemoryReviewScope, in destinationWindowState: StudioWindowState? = nil) {
        openMemoryPane(scope: scope, section: .toCheck, in: destinationWindowState)
    }

    /// A notebook's cards for its Studio's Cards row — "42 kept · 6 due · 9
    /// to check" — in one read (`memoryCardReviewSnapshot` with its listings
    /// and its cards to check), the notebook asked through homing's
    /// `NotebookMembership` (`MemoryCardScope`: its sources, a team copy
    /// resolved to the learner's own, an item filed under it or one of its
    /// Goals). Reading writes nothing. Nil when the read failed, so the row
    /// keeps what it showed rather than saying zero.
    func notebookCardCounts(notebookID: String) async -> NotebookCardCounts? {
        do {
            return try await memoryCardReviewSnapshot(scope: .notebook(notebookID), includesListings: true).notebookCounts
        } catch {
            logger.error("Failed to read a notebook's cards: \(error.localizedDescription)")
            return nil
        }
    }

    /// The Studio's Cards row: the notebook's Memory pane in the window in
    /// scope — To Check while cards wait there, else its Review, with the
    /// notebook's Start Review.
    func openNotebookCards(notebookID: String, counts: NotebookCardCounts?, in destinationWindowState: StudioWindowState? = nil) {
        let section: MemoryPaneSection = (counts?.toCheck ?? 0) > 0 ? .toCheck : .review
        openMemoryPane(scope: .notebook(notebookID), section: section, in: destinationWindowState)
    }

    /// Writes what the learner decided in To Check — Keep, Edit then Keep,
    /// Skip, Keep All, Skip All, Keep N Cards (`MemoryCardTriageWriter`) —
    /// then reads the pane's numbers again. A decision storage refused is
    /// said in a toast, and its card stays to check.
    @discardableResult
    func triageCardsToCheck(_ decisions: [MemoryCardTriageDecision]) async -> MemoryCardTriageResult {
        guard !decisions.isEmpty else { return MemoryCardTriageResult() }
        let result = await MemoryCardTriageWriter.apply(decisions, storage: storage)
        memoryCardRevision &+= 1
        await refreshMemoryCardCounts()
        if let failure = result.failed.first {
            showToast(result.failed.count == 1
                ? "A card stayed to check. \(failure.reason)"
                : "\(result.failed.count) cards stayed to check. \(failure.reason)")
        }
        return result
    }
}
