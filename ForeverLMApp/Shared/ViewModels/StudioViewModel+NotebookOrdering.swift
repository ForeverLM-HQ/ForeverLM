// Pinned and ordered notebooks, and the order of chats.

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

extension StudioViewModel {

    /// The rail's Pinned notebooks: the active ones the learner pinned, in
    /// `notebookOrder`, so a row dragged over another moves as it always did.
    var pinnedNotebooks: [LearningGoalRecord] {
        let pinned = Set(pinnedNotebookIDs)
        return notebooks.filter { pinned.contains($0.id) }
    }

    func isNotebookPinned(_ notebookID: String) -> Bool {
        pinnedNotebookIDs.contains(notebookID)
    }

    /// Pin or unpin one notebook. Ids of notebooks that no longer exist are
    /// dropped on the way through, so a deleted notebook does not leave its
    /// id in the synced list forever.
    func setNotebookPinned(_ notebookID: String, _ pinned: Bool) {
        let ids = NotebookPins.setting(
            notebookID,
            pinned: pinned,
            in: pinnedNotebookIDs,
            knownIDs: Set(learningGoals.map(\.id))
        )
        guard ids != pinnedNotebookIDs else { return }
        pinnedNotebookIDs = ids
    }

    func orderedNotebooks(_ unordered: [LearningGoalRecord]) -> [LearningGoalRecord] {
        let byID = Dictionary(uniqueKeysWithValues: unordered.map { ($0.id, $0) })
        var included = Set<String>()
        var ordered = notebookOrder.compactMap { notebookID -> LearningGoalRecord? in
            guard let notebook = byID[notebookID], included.insert(notebookID).inserted else { return nil }
            return notebook
        }
        ordered.append(contentsOf: unordered.filter { included.insert($0.id).inserted })
        return ordered
    }

    /// Move one visible Notebook to another row's position, matching the Courses
    /// panel's established drop-target behavior. Hidden archived ids follow active ids so
    /// restoring a Notebook never loses it from the persisted order entirely.
    func reorderNotebook(from sourceID: String, to destinationID: String) {
        guard sourceID != destinationID else { return }
        var activeIDs = notebooks.map(\.id)
        guard let sourceIndex = activeIDs.firstIndex(of: sourceID),
              let destinationIndex = activeIDs.firstIndex(of: destinationID) else { return }
        activeIDs.remove(at: sourceIndex)
        activeIDs.insert(sourceID, at: destinationIndex)
        let archivedIDs = archivedNotebooks.map(\.id).filter { !activeIDs.contains($0) }
        notebookOrder = activeIDs + archivedIDs
    }

    static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Applies `chatOrder` to an already-sorted run of chats. Chats the order does
    /// not name keep their incoming (newest-first) position ahead of the arranged
    /// ones; the rest follow in the arranged sequence.
    func orderedReviewSessions(_ unordered: [ReviewSessionRecord]) -> [ReviewSessionRecord] {
        guard !chatOrder.isEmpty else { return unordered }
        let rank = Dictionary(
            uniqueKeysWithValues: chatOrder.enumerated().map { ($0.element, $0.offset) }
        )
        // Only the arranged tail is rebuilt: pulling the named chats out in
        // `chatOrder` sequence keeps the unnamed ones in the caller's order
        // without a comparison sort over the whole run.
        var unnamed: [ReviewSessionRecord] = []
        var named: [(rank: Int, session: ReviewSessionRecord)] = []
        for session in unordered {
            if let position = rank[session.id] {
                named.append((position, session))
            } else {
                unnamed.append(session)
            }
        }
        guard !named.isEmpty else { return unordered }
        named.sort { $0.rank < $1.rank }
        return unnamed + named.map(\.session)
    }

    /// Move one chat to another chat's row in the navigation rail, matching the
    /// Notebook folders' established drop-target behavior: the dragged chat takes the
    /// destination row's slot and everything between shifts down.
    ///
    /// The arrangement is recorded over *every* loaded chat rather than over the
    /// section the drop happened in, so reordering inside one Notebook folder cannot
    /// disturb another folder's order, and a search-filtered rail cannot discard the
    /// position of a chat it is currently hiding. Ids of chats that no longer exist
    /// are dropped on the way through, which is what keeps this preference from
    /// growing forever.
    func reorderReviewSession(from sessionID: String, to destinationID: String) {
        guard sessionID != destinationID else { return }
        var ids = orderedReviewSessions(
            reviewSessionLinks.sorted { $0.createdAt > $1.createdAt }
        ).map(\.id)
        guard let sourceIndex = ids.firstIndex(of: sessionID),
              let destinationIndex = ids.firstIndex(of: destinationID) else { return }
        ids.remove(at: sourceIndex)
        ids.insert(sessionID, at: destinationIndex)
        chatOrder = ids
    }

}
