import Foundation

// MARK: - Collections of notebooks
//
// The learner's collections of notebooks, grouped in the Space's All (Group by
// Collection), on the iPhone's Home and over MCP (docs/notebooks-design.md,
// "Collections"; the rows and their rules are `NotebookCollections`). Every
// act writes the synced preference rows through `PreferenceStore` and reseeds
// `notebookCollections` from what it wrote, so the Space redraws at once and
// the other devices follow through sync. Nothing here touches a Notebook
// record: a collection is the learner's own grouping.

/// The Mac's reads and writes of the collection rows. The rows live in
/// `UserDefaults.standard`, mirrored into `user_preferences` and synced by
/// `PreferenceStore`; a test binds its own defaults (`overrideDefaults`), and
/// while bound, writes go to that suite and never to the sync rail.
enum NotebookCollectionRows {
    /// A test's own defaults, bound for the task that runs it (as
    /// `PageSpaceRows.overrideDefaults`).
    @TaskLocal static var overrideDefaults: DefaultsOverride? = nil

    /// A Sendable carrier for `overrideDefaults`; the suite is only ever
    /// touched by the task that bound it.
    struct DefaultsOverride: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private static var defaults: UserDefaults { overrideDefaults?.defaults ?? .standard }

    /// The collections the rows hold now. The keys are built at runtime, so
    /// one scan of the defaults finds them; only the two prefixes are kept.
    static func read() -> NotebookCollections {
        // Generation 2: memberships are the member's `NotebookState.collections`; the names stay
        // `notebookCollection.*` Settings (schema v2 §3.5.3, §3.5.20).
        let names = NotebookCollections(
            rows: PageSpaceRows.storedRows(of: Prefs.Families.notebookCollectionName, in: defaults)
        ).names
        return NotebookCollections(names: names, memberships: NotebookStateStore.current().collections)
    }

    /// Writes a collection's name row; nil removes it.
    static func writeName(_ name: String?, collectionID: String) {
        write(name, for: Prefs.Families.notebookCollectionName.key(collectionID))
    }

    /// Writes a notebook's row; an empty list removes it, as no row means a
    /// notebook in no collection.
    static func writeMembership(_ ids: [String], notebookID: String) {
        NotebookStateStore.setCollections(Set(ids), notebookID: notebookID)
    }

    /// Drops a deleted notebook's row.
    static func forget(notebookID: String) {
        writeMembership([], notebookID: notebookID)
    }

    /// A merge folds `mergedID` into `survivorID`: the survivor is in every
    /// collection either was in, and the merged notebook's row goes.
    static func merge(_ mergedID: String, into survivorID: String) {
        let state = read()
        if let row = state.membershipRowAfterMerging(mergedID, into: survivorID) {
            writeMembership(row, notebookID: survivorID)
        }
        forget(notebookID: mergedID)
    }

    private static func write(_ value: Any?, for key: AccountKey<Any?>) {
        PageSpaceRows.writeRow(value, for: key, override: overrideDefaults?.defaults)
    }
}

extension StudioViewModel {

    /// Every collection, by name. In Screen record mode only those holding
    /// a notebook on screen: a collection's name is the learner's own.
    var orderedNotebookCollections: [NotebookCollection] {
        let ordered = notebookCollections.ordered
        guard screenRecordScope != nil else { return ordered }
        let counts = notebookCollectionCounts
        return ordered.filter { (counts[$0.id] ?? 0) > 0 }
    }

    /// How many of the open library's active notebooks are in each
    /// collection, by collection id.
    var notebookCollectionCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for notebook in notebooks {
            for collection in notebookCollections.collections(ofNotebook: notebook.id) {
                counts[collection.id, default: 0] += 1
            }
        }
        return counts
    }


    /// Makes a collection named `name` holding `notebookIDs`, and returns it;
    /// nil for a name with nothing in it.
    @discardableResult
    func createNotebookCollection(named name: String, adding notebookIDs: [String] = []) -> NotebookCollection? {
        guard let cleaned = NotebookCollections.cleanedName(name) else { return nil }
        let id = NotebookCollections.newCollectionID()
        NotebookCollectionRows.writeName(cleaned, collectionID: id)
        var state = notebookCollections.settingName(cleaned, for: id)
        for notebookID in notebookIDs where !notebookID.isEmpty {
            let row = state.membershipRow(notebookID: notebookID, setting: id, isMember: true)
            NotebookCollectionRows.writeMembership(row, notebookID: notebookID)
            state = state.settingMembership(row, for: notebookID)
        }
        notebookCollections = state
        return NotebookCollection(id: id, name: cleaned)
    }

    /// Renames a collection. A name with nothing in it, or a collection
    /// gone since, changes nothing.
    func renameNotebookCollection(_ collectionID: String, to name: String) {
        guard notebookCollections.collection(collectionID) != nil,
              let cleaned = NotebookCollections.cleanedName(name) else { return }
        NotebookCollectionRows.writeName(cleaned, collectionID: collectionID)
        notebookCollections = notebookCollections.settingName(cleaned, for: collectionID)
    }

    /// Deletes a collection: its name row, and its id from every notebook
    /// row this Mac holds. The notebooks stay as they are.
    func deleteNotebookCollection(_ collectionID: String) {
        var state = notebookCollections
        for (notebookID, row) in state.membershipRowsAfterDeleting(collectionID) {
            NotebookCollectionRows.writeMembership(row, notebookID: notebookID)
            state = state.settingMembership(row, for: notebookID)
        }
        NotebookCollectionRows.writeName(nil, collectionID: collectionID)
        notebookCollections = state.settingName(nil, for: collectionID)
    }

    /// Puts a notebook in a collection, or takes it out.
    func setNotebook(_ notebookID: String, inCollection collectionID: String, isMember: Bool) {
        guard !notebookID.isEmpty, notebookCollections.collection(collectionID) != nil else { return }
        guard notebookCollections.contains(notebookID, in: collectionID) != isMember else { return }
        let row = notebookCollections.membershipRow(notebookID: notebookID, setting: collectionID, isMember: isMember)
        NotebookCollectionRows.writeMembership(row, notebookID: notebookID)
        notebookCollections = notebookCollections.settingMembership(row, for: notebookID)
    }

    /// A deleted notebook leaves every collection.
    func forgetNotebookCollections(of notebookID: String) {
        guard notebookCollections.memberships[notebookID] != nil else { return }
        NotebookCollectionRows.forget(notebookID: notebookID)
        notebookCollections = notebookCollections.settingMembership([], for: notebookID)
    }

}
