import Foundation

/// Which of a notebook's sources its chats read: its own sources, and those of
/// the context notebooks the learner put in (`NotebookChatContext`), minus
/// the boxes the learner unticked. Stored as two synced preference rows per
/// notebook, never on the Notebook record: the unticked sources
/// (`notebook.chatExcluded.<notebookID>`, a sorted `[String]`) and the context
/// notebooks put in (`notebook.chatContextNotebooks.<notebookID>`). A new
/// source arrives ticked, an untouched notebook has no rows and reads only
/// its own sources, and a team's copy never carries one member's ticks
/// (teams-design rule 7) — each member keys their own rows by the copy's id.
///
/// The ticks govern new chats (and a chat not yet sent). A chat under way keeps
/// the catalog it began with in `review_session_sources`.
///
/// Under generation 2 the same reads and writes go to the member's
/// `NotebookState` record instead (`NotebookStateStore`, schema v2 §5.6): an
/// untick stores the stamps of the Entry it names, so a re-add or a
/// re-approval from any device ticks the source again (bug b5). Generation 1
/// keeps the preference rows, `handOver` included (D40).
enum NotebookChatSelection {
    static let preferenceKeyPrefix = "notebook.chatExcluded."

    static func preferenceKey(notebookID: String) -> String {
        preferenceKeyPrefix + notebookID
    }

    /// A test's own defaults, bound for the task that runs it (as
    /// `ScreenRecordMode.overrideDefaults`). The rows otherwise live in
    /// `UserDefaults.standard`, which every test in the process shares with
    /// its neighbours and with the Dev build. While bound, writes go to the
    /// suite and never to the sync rail.
    @TaskLocal static var overrideDefaults: DefaultsOverride? = nil

    /// A Sendable carrier for `overrideDefaults`; the suite is only ever
    /// touched by the task that bound it.
    struct DefaultsOverride: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private static var defaults: UserDefaults { overrideDefaults?.defaults ?? .standard }

    /// The sources one notebook's chats leave out.
    static func excluded(notebookID: String) -> Set<String> {
        if NotebookStateStore.isActive { return NotebookStateStore.current().excluded[notebookID] ?? [] }
        return Set(defaults.stringArray(forKey: preferenceKey(notebookID: notebookID)) ?? [])
    }

    /// Every notebook's unticked sources by Notebook id. The keys are built at
    /// runtime, so one scan of the defaults finds them.
    static func exclusionsFromDefaults() -> [String: Set<String>] {
        if NotebookStateStore.isActive { return NotebookStateStore.current().excluded }
        return rowsFromDefaults(prefix: preferenceKeyPrefix)
    }

    /// The context notebooks one notebook's chats read (`NotebookChatContext`):
    /// the ids its row names, linked or not; a reader keeps them to the links.
    static func contextNotebookIDs(notebookID: String) -> Set<String> {
        if NotebookStateStore.isActive { return NotebookStateStore.current().contextNotebooks[notebookID] ?? [] }
        return Set(defaults.stringArray(forKey: NotebookChatContext.preferenceKey(notebookID: notebookID)) ?? [])
    }

    /// Every notebook's context notebooks put in, by Notebook id, in one scan.
    static func contextNotebooksFromDefaults() -> [String: Set<String>] {
        if NotebookStateStore.isActive { return NotebookStateStore.current().contextNotebooks }
        return rowsFromDefaults(prefix: NotebookChatContext.preferenceKeyPrefix)
    }

    /// One notebook's two rows as read.
    static func selection(notebookID: String) -> NotebookChatContext.Selection {
        NotebookChatContext.Selection(
            excluded: excluded(notebookID: notebookID),
            contextNotebookIDs: contextNotebookIDs(notebookID: notebookID)
        )
    }

    private static func rowsFromDefaults(prefix: String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let notebookID = String(key.dropFirst(prefix.count))
            guard !notebookID.isEmpty, let ids = value as? [String], !ids.isEmpty else { continue }
            result[notebookID] = Set(ids)
        }
        return result
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

    /// The boxes a notebook ticks again after sources joined notebooks:
    /// `arrivals` names, for each notebook that gained sources, the ids it
    /// holds now and did not before. A source arrives ticked in the notebook
    /// it joined, every one of them (adding a source asks for it), so an
    /// untick left behind when it last left — through any route, on any
    /// device — never outlives its return. The same holds for a source that
    /// joins a context notebook this notebook's chats read
    /// (`contextNotebookIDs`, the linked ones its row puts in): it arrives
    /// ticked here too, unless the notebook already showed it through its own
    /// sources or another context notebook it put in, whose box keeps its
    /// untick. A linked notebook that is not put in brings nothing.
    /// `approvedOf` gives another notebook's own sources.
    static func arrivalsToTick(
        in notebook: LearningGoalRecord,
        arrivals: [String: [String]],
        contextNotebookIDs: [String] = [],
        approvedOf: (String) -> [String]? = { _ in nil }
    ) -> [String] {
        var tick = arrivals[notebook.id] ?? []
        let reached = contextNotebookIDs.filter { arrivals[$0] != nil }
        if !reached.isEmpty {
            var heldOtherwise = Set(notebook.approvedSourceIDs)
            for id in contextNotebookIDs where arrivals[id] == nil {
                heldOtherwise.formUnion(approvedOf(id) ?? [])
            }
            tick += reached.flatMap { arrivals[$0] ?? [] }.filter { !heldOtherwise.contains($0) }
        }
        var seen = Set<String>()
        return tick.filter { seen.insert($0).inserted }
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

    /// The boxes `notebook` ticks after an inbound sync change: the arrivals
    /// `arrivalsToTick` names, less any the notebook's row may have unticked
    /// after the source joined. An untick certainly from before the join —
    /// left when the source last left the notebook, by any route on any
    /// device, which an older web or iPhone build never clears — goes; one
    /// that may be from after it stands, so adding a source on the phone and
    /// then unticking it, before this Mac heard of either, keeps the untick
    /// whatever else changed in the notebook meanwhile. Each join is its
    /// earliest possible date (`Arrival.joinedAt`), so a row written between
    /// that and the add is left alone too: never ticking is the safe side. A
    /// source joins the notebook's chats when it arrives in the notebook
    /// itself, or else with its first arrival among the context notebooks it
    /// put in: the earliest of their dates.
    /// `exclusionWrittenAt` is when the row was last written, on whatever
    /// device wrote it; nil, no date known, is older than every join.
    static func inboundArrivalsToTick(
        in notebook: LearningGoalRecord,
        arrivals: [String: [Arrival]],
        exclusionWrittenAt: Date?,
        contextNotebookIDs: [String] = [],
        approvedOf: (String) -> [String]? = { _ in nil }
    ) -> [String] {
        let tick = arrivalsToTick(
            in: notebook,
            arrivals: arrivals.mapValues { $0.map(\.sourceID) },
            contextNotebookIDs: contextNotebookIDs,
            approvedOf: approvedOf
        )
        guard let writtenAt = exclusionWrittenAt, !tick.isEmpty else { return tick }
        var joinedAt: [String: Date] = [:]
        for contextID in contextNotebookIDs {
            for arrival in arrivals[contextID] ?? [] {
                joinedAt[arrival.sourceID] = min(joinedAt[arrival.sourceID] ?? .distantFuture, arrival.joinedAt)
            }
        }
        for arrival in arrivals[notebook.id] ?? [] {
            joinedAt[arrival.sourceID] = arrival.joinedAt
        }
        return tick.filter { (joinedAt[$0] ?? .distantPast) > writtenAt }
    }

    /// Saves one notebook's exclusion. Empty removes the row: everything
    /// ticked is the default.
    static func write(_ excluded: [String], notebookID: String) {
        if NotebookStateStore.isActive { return NotebookStateStore.setExcluded(Set(excluded), notebookID: notebookID) }
        writeRow(excluded, key: preferenceKey(notebookID: notebookID))
    }

    /// Saves which context notebooks one notebook's chats read. Empty removes
    /// the row: none is the default.
    static func writeContextNotebooks(_ contextNotebookIDs: [String], notebookID: String) {
        if NotebookStateStore.isActive { return NotebookStateStore.setContextNotebooks(Set(contextNotebookIDs), notebookID: notebookID) }
        writeRow(contextNotebookIDs, key: NotebookChatContext.preferenceKey(notebookID: notebookID))
    }

    private static func writeRow(_ ids: [String], key: String) {
        if let override = overrideDefaults {
            if ids.isEmpty {
                override.defaults.removeObject(forKey: key)
            } else {
                override.defaults.set(ids, forKey: key)
            }
            return
        }
        if ids.isEmpty {
            PreferenceStore.remove(forKey: key)
        } else {
            PreferenceStore.set(ids, forKey: key)
        }
    }

    /// Drops a deleted notebook's rows.
    static func forget(notebookID: String) {
        write([], notebookID: notebookID)
        writeContextNotebooks([], notebookID: notebookID)
    }

    /// A split that removes its emptied parent hands the parent's rows to its
    /// heir, the new notebook that took the parent's chats, Docs and links
    /// (`CompanionGoalSplitResult.heirGoalID`), and drops the parent's. The
    /// heir's pool (`heirPool`, its linked pool after the split) is part of
    /// the parent's: its sources and the context notebooks it took over. So no
    /// source joins a pool here, and a box the learner left unticked in the
    /// parent stays unticked in the heir; the row is kept to that pool. The
    /// context notebooks the parent's chats read stay in for the heir while
    /// it still links to them (`heirLinks`), and a notebook whose chats read
    /// the parent read the heir instead (`repointContextNotebook`). A merge is
    /// different: the merged notebook's sources join the survivor's pool, so
    /// they arrive ticked and its unticked row is only forgotten
    /// (`merged(_:into:survivorLinks:)`).
    static func handOver(fromParent parentID: String, toHeir heirID: String, heirPool: [String], heirLinks: [String]) {
        guard parentID != heirID else { return }
        let carried = excluded(notebookID: parentID).intersection(heirPool).sorted()
        if !carried.isEmpty {
            write(carried, notebookID: heirID)
        }
        let context = NotebookChatContext.carried(
            contextNotebookIDs(notebookID: parentID),
            into: contextNotebookIDs(notebookID: heirID),
            links: heirLinks
        )
        if !context.isEmpty {
            writeContextNotebooks(context, notebookID: heirID)
        }
        forget(notebookID: parentID)
        repointContextNotebook(from: parentID, to: heirID)
    }

    /// A merged notebook's rows after a merge: its unticked row goes (its
    /// sources arrive in the survivor ticked); the context notebooks its chats
    /// read stay in for the survivor while it links to them (`survivorLinks`,
    /// after the merge moved the links over); and a notebook whose chats read
    /// the merged one read the survivor instead. Returns the context rows it
    /// wrote, by Notebook id (empty for a row removed), for a caller that
    /// mirrors them.
    @discardableResult
    static func merged(_ mergedID: String, into survivorID: String, survivorLinks: [String]) -> [String: Set<String>] {
        guard mergedID != survivorID else { return [:] }
        var written: [String: Set<String>] = [:]
        let current = contextNotebookIDs(notebookID: survivorID)
        let context = NotebookChatContext.carried(
            contextNotebookIDs(notebookID: mergedID),
            into: current,
            links: survivorLinks
        )
        if Set(context) != current {
            writeContextNotebooks(context, notebookID: survivorID)
            written[survivorID] = Set(context)
        }
        forget(notebookID: mergedID)
        written[mergedID] = []
        written.merge(repointContextNotebook(from: mergedID, to: survivorID)) { _, repointed in repointed }
        return written
    }

    /// Every notebook whose chats read `oldID` as a context notebook reads
    /// `newID` instead: a merge or a split moved the links to it, and this
    /// member's choice follows the link. A notebook never reads itself.
    /// Returns the rows it wrote, by Notebook id.
    @discardableResult
    static func repointContextNotebook(from oldID: String, to newID: String) -> [String: Set<String>] {
        guard oldID != newID else { return [:] }
        var written: [String: Set<String>] = [:]
        for (notebookID, ids) in contextNotebooksFromDefaults() where ids.contains(oldID) {
            var next = ids
            next.remove(oldID)
            if notebookID != newID { next.insert(newID) }
            writeContextNotebooks(next.sorted(), notebookID: notebookID)
            written[notebookID] = next
        }
        return written
    }
}
