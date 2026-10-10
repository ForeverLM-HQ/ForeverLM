import Foundation

// MARK: - Context notebooks (docs/notebook-model-design.md, "Context notebooks")

/// What a notebook's chats read once its context notebooks are counted, and
/// how a box changes the member's two rows. A notebook's **context
/// notebooks** are the notebooks it links to (`relatedNotebookIDs`, the Mac
/// inspector's "Uses context from"); the link is the notebook's own and
/// shared with it. Linking reads nothing by itself (product owner, 2026-10-02:
/// "every notebook surface, including chat, should use only that notebook's
/// own selected sources"): a context notebook's sources join the notebook's
/// chats only while the member has put it in, one synced preference row per
/// notebook (`notebook.chatContextNotebooks.<notebookID>`, the sorted ids put
/// in; no row is none), never on the Notebook record, so a team's copy carries
/// no member's choice. The other row, `notebook.chatExcluded.<notebookID>`
/// (`NotebookChatSelection`), keeps the unticked sources and works on top:
/// unticking one source of a context notebook that is in writes that row, as
/// unticking one of the notebook's own does. One level deep: a context
/// notebook's own context notebooks never join, so no chain of links reaches
/// further and none loops. What the Studio makes never reads a context
/// notebook's sources, in or out (`NotebookSourceLoader.notebookSourceIDs`).
///
/// Pure, ids in and ids out, so the Mac (`NotebookChatSelection`, its MCP
/// tools) and the iPhone (`MobileNotebookChatSelection`) share one rule, and
/// the web's twin in library-notebooks.js runs the same vectors
/// (docs-site/website/test/notebook-chat-context-vectors.json).
/// Foundation-only and compiled into the iPhone app too.
enum NotebookChatContext {
    static let preferenceKeyPrefix = "notebook.chatContextNotebooks."

    static func preferenceKey(notebookID: String) -> String {
        preferenceKeyPrefix + notebookID
    }

    /// A notebook the notebook links to, with its own approved sources in its
    /// study order. One per link, in link order: a linked notebook this
    /// device has no record of has no sources, and its id still counts as
    /// linked.
    struct ContextNotebook: Equatable, Sendable {
        let id: String
        let sourceIDs: [String]

        init(id: String, sourceIDs: [String]) {
            self.id = id
            self.sourceIDs = sourceIDs
        }
    }

    /// One member's two rows for one notebook, as read: the unticked sources
    /// and the context notebooks put in. An id either row names that is not
    /// in the pool, or not linked, reads as absent. The unticked row drops
    /// such an id when it is next written (`stored`); the context notebooks'
    /// row keeps it until a device unlinks it, because the link may be one
    /// this device has not heard of yet.
    struct Selection: Equatable, Sendable {
        var excluded: Set<String>
        var contextNotebookIDs: Set<String>

        init(excluded: Set<String> = [], contextNotebookIDs: Set<String> = []) {
            self.excluded = excluded
            self.contextNotebookIDs = contextNotebookIDs
        }
    }

    // MARK: Reading

    /// The context notebooks put into the chats, in link order.
    static func notebooksInChat(_ linked: [ContextNotebook], selection: Selection) -> [ContextNotebook] {
        linked.filter { selection.contextNotebookIDs.contains($0.id) }
    }

    /// What the chats draw on: the notebook's own sources, then each context
    /// notebook put in, in link order, each source once.
    static func chatPool(own: [String], linked: [ContextNotebook], selection: Selection) -> [String] {
        orderedUnique(own + notebooksInChat(linked, selection: selection).flatMap(\.sourceIDs))
    }

    /// Every source a box can stand for: the notebook's own, then every
    /// context notebook's, put in or not. The unticked row is kept to it, so
    /// a context notebook taken out of the chats keeps its sources' unticks
    /// until it is unlinked.
    static func linkedPool(own: [String], linked: [ContextNotebook]) -> [String] {
        orderedUnique(own + linked.flatMap(\.sourceIDs))
    }

    /// The sources a new chat reads: the chat pool in its order, minus the
    /// unticked.
    static func chatSourceIDs(own: [String], linked: [ContextNotebook], selection: Selection) -> [String] {
        chatPool(own: own, linked: linked, selection: selection).filter { !selection.excluded.contains($0) }
    }

    /// Whether a new chat reads `sourceID`: it is in the chat pool and its
    /// box is ticked.
    static func isInChat(_ sourceID: String, own: [String], linked: [ContextNotebook], selection: Selection) -> Bool {
        guard !selection.excluded.contains(sourceID) else { return false }
        if own.contains(sourceID) { return true }
        return notebooksInChat(linked, selection: selection).contains { $0.sourceIDs.contains(sourceID) }
    }

    /// A context notebook's box: nil while it is out of the chats, else how
    /// many of its sources are ticked of how many it has. `counts` narrows
    /// both to the sources a caller shows (the Mac counts only sources a chat
    /// could read).
    static func tally(
        of notebookID: String,
        linked: [ContextNotebook],
        selection: Selection,
        counts: (String) -> Bool = { _ in true }
    ) -> (ticked: Int, total: Int)? {
        guard selection.contextNotebookIDs.contains(notebookID),
              let notebook = linked.first(where: { $0.id == notebookID }) else { return nil }
        let shown = orderedUnique(notebook.sourceIDs).filter(counts)
        return (shown.filter { !selection.excluded.contains($0) }.count, shown.count)
    }

    // MARK: Changing

    /// The rows after ticking (`inChat`) or unticking `sourceIDs`, the boxes
    /// beside sources. Unticking only adds to the unticked row. Ticking takes
    /// a source in the chat pool out of it; a source only a context notebook
    /// that is out holds puts that notebook in with that source alone — its
    /// other sources the chats did not already read come in unticked — so a
    /// box ticked inside a group the chats do not read does what it shows.
    /// `contextNotebookID` names the group whose box was ticked; without one,
    /// the first context notebook holding the source, in link order. A
    /// source neither the notebook nor any context notebook holds changes
    /// nothing.
    static func settingSources(
        _ sourceIDs: [String],
        inChat: Bool,
        through contextNotebookID: String? = nil,
        own: [String],
        linked: [ContextNotebook],
        selection: Selection
    ) -> Selection {
        var next = selection
        let requested = orderedUnique(sourceIDs)
        guard inChat else {
            next.excluded.formUnion(requested)
            return next
        }
        let poolBefore = Set(chatPool(own: own, linked: linked, selection: selection))
        var joining: [ContextNotebook] = []
        for sourceID in requested where !poolBefore.contains(sourceID) {
            guard !joining.contains(where: { $0.sourceIDs.contains(sourceID) }) else { continue }
            let holder = linked.first { $0.id == contextNotebookID && $0.sourceIDs.contains(sourceID) }
                ?? linked.first { !selection.contextNotebookIDs.contains($0.id) && $0.sourceIDs.contains(sourceID) }
            if let holder { joining.append(holder) }
        }
        let wanted = Set(requested)
        for notebook in joining {
            next.contextNotebookIDs.insert(notebook.id)
            next.excluded.formUnion(notebook.sourceIDs.filter { !poolBefore.contains($0) && !wanted.contains($0) })
        }
        next.excluded.subtract(requested)
        return next
    }

    /// The rows after a context notebook's own box. Ticking one that is out
    /// puts it into the chats and nothing more (`puttingIn`): a source of it
    /// the learner unticked stays unticked, the box reading mixed, so it
    /// comes back as it was left. Ticking one already in, its box mixed or
    /// unticked, ticks every source of it, as a book's box ticks its
    /// chapters. Unticking takes it out and leaves its sources' boxes as they
    /// were for when it comes back in. Ids that are not linked are ignored
    /// when ticking.
    static func settingContextNotebooks(
        _ contextNotebookIDs: [String],
        inChat: Bool,
        linked: [ContextNotebook],
        selection: Selection
    ) -> Selection {
        var next = selection
        guard inChat else {
            next.contextNotebookIDs.subtract(contextNotebookIDs)
            return next
        }
        let named = Set(contextNotebookIDs)
        for notebook in linked where named.contains(notebook.id) {
            if selection.contextNotebookIDs.contains(notebook.id) {
                next.excluded.subtract(notebook.sourceIDs)
            } else {
                next.contextNotebookIDs.insert(notebook.id)
            }
        }
        return next
    }

    /// The rows after Add a Notebook to Context: each named context notebook
    /// put into the chats, its sources' boxes as they were, and one already
    /// in left as it is. Ids that are not linked are ignored.
    static func puttingIn(_ contextNotebookIDs: [String], linked: [ContextNotebook], selection: Selection) -> Selection {
        var next = selection
        let named = Set(contextNotebookIDs)
        for notebook in linked where named.contains(notebook.id) {
            next.contextNotebookIDs.insert(notebook.id)
        }
        return next
    }

    /// The rows that make the chats read exactly `sourceIDs` and every source
    /// of the context notebooks `contextNotebookIDs` names: every other
    /// source unticked, every other context notebook taken out, and a named
    /// source only a context notebook holds puts that notebook in (one
    /// already in first, else the first linked) with that source alone.
    /// What MCP `set_notebook_source_selection` mode only does.
    static func keepingOnly(
        sourceIDs: [String],
        contextNotebookIDs: [String],
        own: [String],
        linked: [ContextNotebook],
        selection: Selection
    ) -> Selection {
        let namedIDs = Set(contextNotebookIDs)
        let named = linked.filter { namedIDs.contains($0.id) }
        let namedSources = Set(named.flatMap(\.sourceIDs))
        let ownSet = Set(own)
        var context = Set(named.map(\.id))
        for sourceID in orderedUnique(sourceIDs) where !ownSet.contains(sourceID) && !namedSources.contains(sourceID) {
            guard !linked.contains(where: { context.contains($0.id) && $0.sourceIDs.contains(sourceID) }) else { continue }
            let holder = linked.first { selection.contextNotebookIDs.contains($0.id) && $0.sourceIDs.contains(sourceID) }
                ?? linked.first { $0.sourceIDs.contains(sourceID) }
            if let holder { context.insert(holder.id) }
        }
        let keep = Set(sourceIDs).union(namedSources)
        return Selection(
            excluded: Set(linkedPool(own: own, linked: linked).filter { !keep.contains($0) }),
            contextNotebookIDs: context
        )
    }

    /// The two rows as they are written: sorted, so writing the same set
    /// again changes nothing, and the unticked kept to the linked pool. The
    /// context notebooks are written as they are, a notebook this device does
    /// not know is linked included: its links can lag another device's, and
    /// a box ticked here must not drop a notebook put in there. An id leaves
    /// that row only where a device unlinks the notebook (Take Out of
    /// Context, a changed list of links, a delete, merge or split), and the
    /// readers pass over one that is not linked. An empty array removes its
    /// row.
    static func stored(
        _ selection: Selection,
        own: [String],
        linked: [ContextNotebook]
    ) -> (excluded: [String], contextNotebookIDs: [String]) {
        let pool = Set(linkedPool(own: own, linked: linked))
        return (
            selection.excluded.intersection(pool).sorted(),
            selection.contextNotebookIDs.sorted()
        )
    }

    /// The context notebooks a notebook's heir or survivor keeps putting in:
    /// those in `carried` it still links to, beside its own, sorted. A split
    /// hands the emptied parent's choice to the heir that took its links; a
    /// merge hands the merged notebook's to the survivor that took them.
    static func carried(_ carried: Set<String>, into current: Set<String>, links: [String]) -> [String] {
        current.union(carried.intersection(links)).sorted()
    }

    private static func orderedUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
