import Foundation

/// Which of a notebook's sources its chats read: its own sources, and those of
/// the context notebooks the learner put in (`NotebookChatContext`), minus
/// the boxes the learner unticked. Kept in the member's `NotebookState` record
/// (`NotebookStateStore`, schema v2 §5.6), never on the Notebook record: a new
/// source arrives ticked, an untouched notebook has no state and reads only
/// its own sources, and a team's copy never carries one member's ticks
/// (teams-design rule 7). An untick stores the stamps of the Entry it names,
/// so a re-add or a re-approval from any device ticks the source again.
///
/// The ticks govern new chats (and a chat not yet sent). A chat under way keeps
/// the catalog it began with in `review_session_sources`.
enum NotebookChatSelection {
    static let preferenceKeyPrefix = Prefs.Families.notebookChatExcluded.prefix
    static func preferenceKey(notebookID: String) -> String {
        preferenceKeyPrefix + notebookID
    }

    /// The sources one notebook's chats leave out.
    static func excluded(notebookID: String) -> Set<String> {
        NotebookStateStore.current().excluded[notebookID] ?? []
    }

    /// Every notebook's unticked sources by Notebook id.
    static func exclusionsFromDefaults() -> [String: Set<String>] {
        NotebookStateStore.current().excluded
    }

    /// The context notebooks one notebook's chats read (`NotebookChatContext`):
    /// the ids its row names, linked or not; a reader keeps them to the links.
    static func contextNotebookIDs(notebookID: String) -> Set<String> {
        NotebookStateStore.current().contextNotebooks[notebookID] ?? []
    }

    /// Every notebook's context notebooks put in, by Notebook id.
    static func contextNotebooksFromDefaults() -> [String: Set<String>] {
        NotebookStateStore.current().contextNotebooks
    }

    /// One notebook's two rows as read.
    static func selection(notebookID: String) -> NotebookChatContext.Selection {
        NotebookChatContext.Selection(
            excluded: excluded(notebookID: notebookID),
            contextNotebookIDs: contextNotebookIDs(notebookID: notebookID)
        )
    }

    /// A notebook's context notebooks as the pool reads them: one per link,
    /// in link order, each with its own approved sources, or none for a
    /// notebook this Mac has no record of (`approvedOf` answers nil). One
    /// level deep: what a context notebook links to never comes in.
    static func contextNotebooks(
        of notebook: LearningGoalRecord,
        approvedOf: (String) -> [String]?
    ) -> [NotebookChatContext.ContextNotebook] {
        (notebook.relatedNotebookIDs ?? []).filter { $0 != notebook.id }.map { id in
            NotebookChatContext.ContextNotebook(id: id, sourceIDs: approvedOf(id) ?? [])
        }
    }

    /// The pool in its own (study) order, minus the unticked.
    static func chatSourceIDs(pool: [String], excluded: Set<String>) -> [String] {
        excluded.isEmpty ? pool : pool.filter { !excluded.contains($0) }
    }

    /// The exclusion after ticking (`inChat`) or unticking `sourceIDs`, kept to
    /// current pool members so a source removed and added back comes back
    /// ticked. Sorted, so writing the same set again is a no-op for
    /// `PreferenceStore`.
    static func updated(_ current: Set<String>, setting sourceIDs: [String], inChat: Bool, pool: [String]) -> [String] {
        var next = current
        if inChat {
            next.subtract(sourceIDs)
        } else {
            next.formUnion(sourceIDs)
        }
        return next.intersection(pool).sorted()
    }

    /// The context notebooks `notebook`'s chats read, in link order: the
    /// linked ones `putIn` (its `notebook.chatContextNotebooks` row) names.
    static func contextNotebookIDs(of notebook: LearningGoalRecord, putIn: Set<String>) -> [String] {
        guard !putIn.isEmpty else { return [] }
        return (notebook.relatedNotebookIDs ?? []).filter { $0 != notebook.id && putIn.contains($0) }
    }

    /// A source a notebook holds after an inbound sync change and did not
    /// before it, and the earliest it can have joined (`inboundArrivals`).
    struct Arrival: Equatable, Sendable {
        let sourceID: String
        /// No later than the add itself: a row written before it is certainly
        /// older than the add, one written at or after it may not be.
        let joinedAt: Date
    }

    /// What an inbound sync change brought each notebook: the sources it holds
    /// (approved) in `after` and did not in `before`, and the earliest each
    /// can have joined. A source new to the notebook joined when its item was
    /// added (`addedAt`). One whose item was already there — removed, which
    /// every client records as a rejected item that a re-add approves again
    /// with its first `addedAt`, or only suggested — was approved after the
    /// version this Mac held, so no earlier than that version's `updatedAt`.
    /// Never the notebook's own `updatedAt` in `after`: that is the latest it
    /// can have joined, and any later edit (another add, a rename) would make
    /// an untick written after the re-add look older than it. Only notebooks
    /// in `before` are compared: one new to this Mac leaves nothing of this
    /// Mac's behind, and a row that came with it was written by the device
    /// that unticked in it.
    static func inboundArrivals(before: [LearningGoalRecord], after: [LearningGoalRecord]) -> [String: [Arrival]] {
        let previousByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: [Arrival]] = [:]
        for notebook in after {
            guard let previous = previousByID[notebook.id] else { continue }
            let held = Set(previous.approvedSourceIDs)
            let listed = Set(previous.items.map(\.sourceID))
            var seen = Set<String>()
            var arrivals: [Arrival] = []
            for item in notebook.items where item.isApproved && !held.contains(item.sourceID) {
                guard seen.insert(item.sourceID).inserted else { continue }
                let joinedAt = listed.contains(item.sourceID) ? previous.updatedAt : item.addedAt
                arrivals.append(Arrival(sourceID: item.sourceID, joinedAt: joinedAt))
            }
            if !arrivals.isEmpty { result[notebook.id] = arrivals }
        }
        return result
    }

    /// Saves one notebook's exclusion. Empty is the default: everything ticked.
    static func write(_ excluded: [String], notebookID: String) {
        NotebookStateStore.setExcluded(Set(excluded), notebookID: notebookID)
    }

    /// Saves which context notebooks one notebook's chats read. None is the default.
    static func writeContextNotebooks(_ contextNotebookIDs: [String], notebookID: String) {
        NotebookStateStore.setContextNotebooks(Set(contextNotebookIDs), notebookID: notebookID)
    }

    /// Drops a deleted notebook's ticks and context notebooks.
    static func forget(notebookID: String) {
        write([], notebookID: notebookID)
        writeContextNotebooks([], notebookID: notebookID)
    }
}
