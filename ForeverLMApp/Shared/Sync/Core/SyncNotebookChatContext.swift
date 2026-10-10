import Foundation

/// The chat-tick rule (§5.6, D16, bug b5) and a notebook's context (D52): which sources a notebook
/// surface reads, for one member. The Studio reads the notebook's own selected sources; a chat
/// (`contextMode = notebook`) also reads those of the listed notebooks the member ticked into
/// context, one level deep. A member's untick records the compared Entry's `state` and `approval`
/// stamps in `NotebookState.excluded`; a source is left out only while those stamps are unchanged, so
/// a re-add or a re-approval by anyone, from any device, ticks it again with no write to the member's
/// record and no comparison of two devices' clocks. Generation 1's rule is `NotebookChatContext`
/// (`Shared/Models`, over preference rows); this one reads records. The JS port is
/// `schema/js/chat-ticks.js`; vectors `schema/vectors/chat-ticks.json`.
enum SyncNotebookChatContext {
    /// An `Entry` as the rule reads it: its identity, its shared state and their stamps.
    struct Entry: Equatable, Sendable {
        let containerID: String
        let itemKind: String
        let itemID: String
        let state: String
        /// Absent (nil) means approved.
        let approval: String?
        let stateStamp: SyncStamp
        let approvalStamp: SyncStamp?

        init(containerID: String, itemKind: String, itemID: String, state: String, approval: String?,
             stateStamp: SyncStamp, approvalStamp: SyncStamp?) {
            self.containerID = containerID
            self.itemKind = itemKind
            self.itemID = itemID
            self.state = state
            self.approval = approval
            self.stateStamp = stateStamp
            self.approvalStamp = approvalStamp
        }

        /// From an Entry record; nil when it lacks the fields or the state stamp the rule needs.
        init?(_ envelope: SyncEnvelope) {
            guard envelope.recordType == .entry,
                  let containerID = envelope.fields["containerID"]?.stringValue,
                  let itemKind = envelope.fields["itemKind"]?.stringValue,
                  let itemID = envelope.fields["itemID"]?.stringValue,
                  let state = envelope.fields["state"]?.stringValue,
                  case .value(let stateStamp)? = envelope.stamps["state"]
            else { return nil }
            let approvalStamp: SyncStamp? = if case .value(let stamp)? = envelope.stamps["approval"] { stamp } else { nil }
            self.init(containerID: containerID, itemKind: itemKind, itemID: itemID, state: state,
                      approval: envelope.fields["approval"]?.stringValue, stateStamp: stateStamp, approvalStamp: approvalStamp)
        }

        var isInContext: Bool {
            itemKind == "source" && state == "active" && (approval == nil || approval == "approved")
        }
    }

    /// `stamps(e).state + "|" + (stamps(e).approval ?? "-")`, the value an untick stores.
    static func stampPair(_ entry: Entry) -> String {
        entry.stateStamp.rawValue + "|" + (entry.approvalStamp?.rawValue ?? "-")
    }

    /// `ctx(nb, m)`: the notebooks whose own sources a chat in `notebookID` also reads, sorted. Both
    /// lists are resolved before they are intersected (R6-m1), so a context notebook that was merged
    /// or moved keeps feeding the chat while the member's tick names the stub and the link the
    /// survivor, or the reverse; the notebook itself is dropped, so a context notebook merged into it
    /// adds nothing twice. `contextNotebooks` is `NotebookState(nb).contextNotebooks` and
    /// `relatedNotebookIDs` is `Notebook(nb).relatedNotebookIDs`, as their sets hold them (an element
    /// counts while its value is `true`); `resolve` is `resolveNotebook()` (§5.2) for an id, from where
    /// the client holds that notebook.
    static func contextNotebookIDs(notebookID: String, contextNotebooks: [String: SyncJSON],
                                   relatedNotebookIDs: [String: SyncJSON], resolve: (String) -> String) -> [String] {
        let home = resolve(notebookID)
        let ticked = Set(members(contextNotebooks).map(resolve))
        let listed = Set(members(relatedNotebookIDs).map(resolve))
        return ticked.intersection(listed).filter { notebook in notebook != home }.sorted()
    }

    /// `studio(nb, m)`: the notebook's own selected sources, sorted. Every Studio maker and its counts
    /// read this, never a context notebook's sources. `notebookID` is already resolved
    /// (`NotebookResolution`), and `excluded` is that notebook's `NotebookState.excluded`.
    static func studioSourceIDs(notebookID: String, entries: [Entry], excluded: [String: SyncJSON]) -> [String] {
        sourceIDs(notebookID: notebookID, contextNotebookIDs: [], entries: entries, excluded: excluded)
    }

    /// `chat(nb, m)`: the notebook's own selected sources and those of its context notebooks
    /// (`contextNotebookIDs(…)`), sorted. One level deep: a context notebook's own context notebooks
    /// never join. A source left out stays out only while `excluded` names the stamps of its
    /// `comparedEntry(for:…)`.
    static func chatSourceIDs(notebookID: String, contextNotebookIDs: [String], entries: [Entry],
                              excluded: [String: SyncJSON]) -> [String] {
        sourceIDs(notebookID: notebookID, contextNotebookIDs: contextNotebookIDs, entries: entries, excluded: excluded)
    }

    /// `e_s`: the Entry an exclusion of `sourceID` is compared with, which is the one an untick names:
    /// the source's own Entry in the notebook, else its Entry in the context notebook with the smallest
    /// id. So filing a context notebook's source into the notebook ticks it again too. Nil when neither
    /// holds the source in context.
    static func comparedEntry(for sourceID: String, notebookID: String, contextNotebookIDs: [String] = [],
                              entries: [Entry]) -> Entry? {
        holders(notebookID: notebookID, contextNotebookIDs: contextNotebookIDs, entries: entries)[sourceID]
            .flatMap { compared($0, notebookID: notebookID) }
    }

    /// The `NotebookState.excluded` change that unticks `entry`'s source. The Entry must be the one
    /// `comparedEntry(for:…)` names, with the stamps the device holds now, a pending change's pinned
    /// stamp included (§5.6).
    static func untick(_ entry: Entry) -> RecordPatch.Change {
        .elements([entry.itemID: .string(stampPair(entry))])
    }

    /// The change that ticks `sourceID` again.
    static func tick(_ sourceID: String) -> RecordPatch.Change {
        .elements([sourceID: .null])
    }

    private static func sourceIDs(notebookID: String, contextNotebookIDs: [String], entries: [Entry],
                                  excluded: [String: SyncJSON]) -> [String] {
        holders(notebookID: notebookID, contextNotebookIDs: contextNotebookIDs, entries: entries).compactMap { sourceID, held in
            guard let entry = compared(held, notebookID: notebookID) else { return nil }
            return excluded[sourceID]?.stringValue == stampPair(entry) ? nil : sourceID
        }.sorted()
    }

    /// Source id → container id → the Entry that container holds in context, for the notebook and its
    /// context notebooks. A container holds one Entry per source (`en:<containerID>:source:<itemID>`).
    private static func holders(notebookID: String, contextNotebookIDs: [String], entries: [Entry]) -> [String: [String: Entry]] {
        let containers = Set(contextNotebookIDs).union([notebookID])
        var holders: [String: [String: Entry]] = [:]
        for entry in entries where entry.isInContext && containers.contains(entry.containerID) {
            holders[entry.itemID, default: [:]][entry.containerID] = entry
        }
        return holders
    }

    private static func compared(_ held: [String: Entry], notebookID: String) -> Entry? {
        if let own = held[notebookID] { return own }
        return held.keys.min().flatMap { held[$0] }
    }

    /// The elements a set field holds: the keys whose value is `true` (`false` marks a removal).
    private static func members(_ set: [String: SyncJSON]) -> [String] {
        set.compactMap { element, value in value == .bool(true) ? element : nil }
    }
}
