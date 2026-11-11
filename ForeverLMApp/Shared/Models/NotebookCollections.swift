import Foundation

// MARK: - Collections of notebooks
//
// Gemini Notebook's Collections, in ForeverLM (product owner, 2026-10-02: "similar
// to gemini notebook, we need to be able to add notebooks to collections"):
// a named group of notebooks the learner makes from a notebook's Add to
// Collection ▸ in the Space (on the Notebooks home until 2026-10-09), each
// notebook in any number of them. docs/notebooks-design.md, "Collections".
//
// Not the schema-v2 `Collection` (a book, show, channel or meeting series a
// source belongs to): this is the learner's own grouping of notebooks, and
// the code says `NotebookCollection` so the two never share a name.

/// One collection of notebooks: its id and its name. A leading emoji in the
/// name is its icon, as a notebook's is (`NotebookTitle`).
struct NotebookCollection: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
}

/// One card of the home's Collections tab: a collection and the notebooks
/// it holds among those the home lists, in the home's order (last worked in
/// first), so its count and the first few notebooks it shows agree with
/// what its chip would show.
struct NotebookCollectionSummary: Identifiable, Equatable, Sendable {
    let collection: NotebookCollection
    let notebookIDs: [String]

    var id: String { collection.id }
}

/// The learner's collections, as two kinds of synced preference row keep
/// them (`SyncedPreferenceKeys.syncedPrefixes`):
///
/// - `notebookCollection.<collectionID>`: the collection's name, a String.
///   One row per collection, so renaming one never touches another.
/// - `notebook.collections.<notebookID>`: the collections one notebook is in,
///   a sorted `[String]` of collection ids; no row when it is in none. One
///   row per notebook, as `notebook.chatExcluded.<notebookID>` is, so adding
///   two notebooks to one collection on two devices at once keeps both.
///
/// Per member, never on the Notebook record: a team's notebook is in the
/// collections of each member who put it there, keyed by the copy's id
/// (teams-design rule 7). A row naming a collection whose name row is gone
/// — deleted on a device that did not know the notebook — is read past, so a
/// deleted collection never comes back. Foundation-only: the Mac, the iPhone
/// and the macOS unit tests compile this one file; the web's twin is in
/// library-notebooks.js.
struct NotebookCollections: Equatable, Sendable {
    static let namePreferenceKeyPrefix = Prefs.Families.notebookCollectionName.prefix
    /// What every collection id starts with: `nbc-` and a lowercased UUID.
    static let idPrefix = "nbc-"
    /// The longest name kept; a longer one is cut there.
    static let nameCharacterLimit = 80

    /// Each collection's name, by id.
    private(set) var names: [String: String]
    /// The collection ids each notebook's row lists, by Notebook id, a
    /// deleted collection's id included until the row is written again.
    private(set) var memberships: [String: Set<String>]

    init(names: [String: String] = [:], memberships: [String: Set<String>] = [:]) {
        self.names = names.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        self.memberships = memberships.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    /// The collections in a set of preference rows: every row under the two
    /// prefixes, the rest ignored (`UserDefaults.dictionaryRepresentation()`
    /// on the Mac, the rows the phone fetched). A name that is not a
    /// non-empty String, or a membership that is not a String array, is no
    /// row.
    init(rows: [String: Any]) {
        var names: [String: String] = [:]
        var memberships: [String: Set<String>] = [:]
        for (key, value) in rows {
            if let id = Self.collectionID(fromNameKey: key) {
                guard let name = value as? String else { continue }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { names[id] = trimmed }
            } else if let notebookID = Self.notebookID(fromMembershipKey: key) {
                guard let ids = value as? [String] else { continue }
                let kept = Set(ids.filter { !$0.isEmpty })
                if !kept.isEmpty { memberships[notebookID] = kept }
            }
        }
        self.init(names: names, memberships: memberships)
    }

    // MARK: Keys

    static func nameKey(collectionID: String) -> String {
        namePreferenceKeyPrefix + collectionID
    }

    static func membershipKey(notebookID: String) -> String {
        Prefs.Families.notebookCollectionMembership.prefix + notebookID
    }

    static func collectionID(fromNameKey key: String) -> String? {
        guard key.hasPrefix(namePreferenceKeyPrefix) else { return nil }
        let id = String(key.dropFirst(namePreferenceKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    static func notebookID(fromMembershipKey key: String) -> String? {
        guard key.hasPrefix(Prefs.Families.notebookCollectionMembership.prefix) else { return nil }
        let id = String(key.dropFirst(Prefs.Families.notebookCollectionMembership.prefix.count))
        return id.isEmpty ? nil : id
    }

    /// A new collection's id.
    static func newCollectionID() -> String {
        idPrefix + UUID().uuidString.lowercased()
    }

    /// A name as it is kept: whitespace and line breaks folded to single
    /// spaces, trimmed, at most `nameCharacterLimit` characters; nil when
    /// nothing is left.
    static func cleanedName(_ raw: String) -> String? {
        let folded = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !folded.isEmpty else { return nil }
        return String(folded.prefix(nameCharacterLimit)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Reading

    /// Every collection, by name (a leading emoji aside), then by id, so two
    /// collections never trade places between two reads.
    var ordered: [NotebookCollection] {
        names
            .map { NotebookCollection(id: $0.key, name: $0.value) }
            .sorted(by: Self.nameOrder)
    }

    var isEmpty: Bool { names.isEmpty }

    func collection(_ collectionID: String) -> NotebookCollection? {
        names[collectionID].map { NotebookCollection(id: collectionID, name: $0) }
    }

    /// The collections a notebook is in, by name; a deleted collection's id
    /// left in its row is read past.
    func collections(ofNotebook notebookID: String) -> [NotebookCollection] {
        (memberships[notebookID] ?? [])
            .compactMap(collection)
            .sorted(by: Self.nameOrder)
    }

    func contains(_ notebookID: String, in collectionID: String) -> Bool {
        names[collectionID] != nil && memberships[notebookID]?.contains(collectionID) == true
    }

    /// The notebooks of `notebookIDs` in the collection, in the order given.
    func notebookIDs(_ notebookIDs: [String], in collectionID: String) -> [String] {
        guard names[collectionID] != nil else { return [] }
        return notebookIDs.filter { memberships[$0]?.contains(collectionID) == true }
    }

    /// The Collections tab's cards: every collection, by name, each with the
    /// notebooks of `notebookIDs` it holds, in the order given. An empty
    /// collection is a card too.
    func summaries(of notebookIDs: [String]) -> [NotebookCollectionSummary] {
        ordered.map { collection in
            NotebookCollectionSummary(collection: collection, notebookIDs: self.notebookIDs(notebookIDs, in: collection.id))
        }
    }

    static func nameOrder(_ lhs: NotebookCollection, _ rhs: NotebookCollection) -> Bool {
        let order = NotebookTitle(lhs.name).text.localizedStandardCompare(NotebookTitle(rhs.name).text)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    // MARK: Rows after an act
    //
    // Each returns what a row becomes; an empty membership means the row is
    // removed. Nothing here writes: the Mac's `PreferenceStore`, the phone's
    // preference store and the web's `savePreference` do, through these.

    /// The notebook's row once it is put in (`isMember`) or taken out of the
    /// collection. Only that id moves: an id this device does not know a
    /// name for yet may be a collection made on another device whose name
    /// row has not arrived, so it is kept.
    func membershipRow(notebookID: String, setting collectionID: String, isMember: Bool) -> [String] {
        var ids = memberships[notebookID] ?? []
        if isMember {
            ids.insert(collectionID)
        } else {
            ids.remove(collectionID)
        }
        return ids.sorted()
    }

    /// The rows a collection's deletion rewrites: every notebook row this
    /// device holds that lists it, without it (empty: the row goes).
    func membershipRowsAfterDeleting(_ collectionID: String) -> [String: [String]] {
        var rows: [String: [String]] = [:]
        for (notebookID, ids) in memberships where ids.contains(collectionID) {
            rows[notebookID] = ids.subtracting([collectionID]).sorted()
        }
        return rows
    }

    /// The survivor's row after a merge folds `mergedID` into it: in every
    /// collection either was in. Nil when it changes nothing.
    func membershipRowAfterMerging(_ mergedID: String, into survivorID: String) -> [String]? {
        let merged = memberships[mergedID] ?? []
        let survivor = memberships[survivorID] ?? []
        guard !merged.isSubset(of: survivor) else { return nil }
        return survivor.union(merged).sorted()
    }

    // MARK: Applying

    /// This state after a name row is written (nil: removed).
    func settingName(_ name: String?, for collectionID: String) -> NotebookCollections {
        var copy = self
        copy.names[collectionID] = name.flatMap { $0.isEmpty ? nil : $0 }
        return copy
    }

    /// This state after a notebook's row is written (empty: removed).
    func settingMembership(_ ids: [String], for notebookID: String) -> NotebookCollections {
        var copy = self
        let kept = Set(ids.filter { !$0.isEmpty })
        copy.memberships[notebookID] = kept.isEmpty ? nil : kept
        return copy
    }
}
