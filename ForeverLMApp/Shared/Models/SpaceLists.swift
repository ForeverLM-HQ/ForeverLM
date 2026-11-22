import Foundation

// MARK: - Lists in the Space
//
// Lists in a Space hold Ideas. Goals belong to Planning and are visible in
// the quarter selected by their deadline. The retired `goals` raw value is
// kept only so an older synced preference row decodes; `SpaceLists.init`
// drops it, so it never becomes a second, hidden home for Goals.

/// One of the learner's lists: its id, what it holds, its name and dates.
struct SpaceList: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Compatibility-only: old builds synced this value. New reads drop
        /// it and no creation surface accepts it.
        case goals
        case ideas

        /// What a new list of the kind is called.
        var newName: String {
            switch self {
            case .goals: return "Goals"
            case .ideas: return "Ideas"
            }
        }

        /// One of what it holds, and many.
        var noun: String {
            switch self {
            case .goals: return "goal"
            case .ideas: return "idea"
            }
        }

        var pluralNoun: String {
            switch self {
            case .goals: return "goals"
            case .ideas: return "ideas"
            }
        }

        /// The glyph its rows, cards and menus use.
        var symbolName: String {
            switch self {
            case .goals: return "target"
            case .ideas: return "lightbulb"
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    let createdAt: Date
    /// When the row was last written: a rename, Trash, Restore.
    let updatedAt: Date
    /// When it went to Trash; nil while it is in use.
    let trashedAt: Date?

    var isTrashed: Bool { trashedAt != nil }
}

/// The learner's lists, as two kinds of synced preference row keep them
/// (`SyncedPreferenceKeys.syncedPrefixes`):
///
/// - `spaceList.<listID>`: the list itself, a JSON String
///   `{"kind": "goals", "name": "…", "created": s, "at": s, "trashed": s}`
///   (seconds since 1970; `at` its last write; `trashed` absent while it is
///   in use). One row per list, so renaming one never touches another; the
///   newer write of a row wins whole.
/// - `spaceListItem.<recordID>`: the one list a goal or an idea is in, a
///   String list id; no row when it is in none. One row per record, so two
///   devices filing two goals at once keep both. A row naming a list whose
///   own row is gone is read past, so a deleted list never comes back.
///
/// Per member, keyed by the record's id and never on the record, so no
/// schema change. Foundation-only, like `PageSpaces`: the Mac and the macOS
/// unit tests compile it.
struct SpaceLists: Equatable, Sendable {
    /// What every list id starts with: `lst-` and a lowercased UUID.
    static let idPrefix = "lst-"

    /// One record's row as an act leaves it: the list it names, nil when the
    /// row goes.
    struct ItemRow: Equatable, Sendable {
        let recordID: String
        let listID: String?
    }

    /// Every list, by id.
    private(set) var lists: [String: SpaceList]
    /// The list each record's row names, by record id, a deleted list's id
    /// included until the row is written again.
    private(set) var memberships: [String: String]

    init(lists: [String: SpaceList] = [:], memberships: [String: String] = [:]) {
        let visible = lists.filter { $0.value.kind == .ideas }
        self.lists = visible
        self.memberships = memberships.filter {
            !$0.key.isEmpty && !$0.value.isEmpty && visible[$0.value] != nil
        }
    }

    /// The lists in a set of preference rows: every row under the two
    /// prefixes, the rest ignored. A list row that does not read, or a
    /// membership that is not a non-empty String, is no row.
    init(rows: [String: Any]) {
        var lists: [String: SpaceList] = [:]
        var memberships: [String: String] = [:]
        for (key, value) in rows {
            if let recordID = Self.recordID(fromItemKey: key) {
                guard let listID = value as? String else { continue }
                let trimmed = listID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { memberships[recordID] = trimmed }
            } else if let id = Self.listID(fromListKey: key), let list = Self.list(id: id, rowValue: value) {
                lists[id] = list
            }
        }
        self.init(lists: lists, memberships: memberships)
    }

    // MARK: Keys

    static func listKey(listID: String) -> String { Prefs.Families.spaceList.prefix + listID }

    static func itemKey(recordID: String) -> String { Prefs.Families.spaceListItem.prefix + recordID }

    static func listID(fromListKey key: String) -> String? {
        guard key.hasPrefix(Prefs.Families.spaceList.prefix) else { return nil }
        let id = String(key.dropFirst(Prefs.Families.spaceList.prefix.count))
        return id.isEmpty ? nil : id
    }

    static func recordID(fromItemKey key: String) -> String? {
        guard key.hasPrefix(Prefs.Families.spaceListItem.prefix) else { return nil }
        let id = String(key.dropFirst(Prefs.Families.spaceListItem.prefix.count))
        return id.isEmpty ? nil : id
    }

    static func newListID() -> String {
        idPrefix + UUID().uuidString.lowercased()
    }

    /// A name as it is kept, as a space's is (`PageSpaces.cleanedName`).
    static func cleanedName(_ raw: String) -> String? {
        PageSpaces.cleanedName(raw)
    }

    // MARK: The list row

    private struct Row: Codable {
        var kind: SpaceList.Kind
        var name: String
        var created: Double
        var at: Double
        var trashed: Double?
    }

    /// The row's value for a list: JSON text with sorted keys, so the same
    /// list written again is no write.
    static func rowValue(_ list: SpaceList) -> String {
        let row = Row(
            kind: list.kind,
            name: list.name,
            created: list.createdAt.timeIntervalSince1970,
            at: list.updatedAt.timeIntervalSince1970,
            trashed: list.trashedAt?.timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(row) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The list a row holds; nil for a value that does not read, a kind this
    /// build does not know, or a name with nothing in it.
    static func list(id: String, rowValue value: Any?) -> SpaceList? {
        let data: Data
        switch value {
        case let text as String: data = Data(text.utf8)
        case let raw as Data: data = raw
        default: return nil
        }
        guard let row = try? JSONDecoder().decode(Row.self, from: data),
              let name = cleanedName(row.name) else { return nil }
        return SpaceList(
            id: id,
            kind: row.kind,
            name: name,
            createdAt: Date(timeIntervalSince1970: row.created),
            updatedAt: Date(timeIntervalSince1970: row.at),
            trashedAt: row.trashed.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: Reading

    func list(_ id: String) -> SpaceList? { lists[id] }

    /// Every list, newest first, then by id.
    var all: [SpaceList] {
        lists.values.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id < rhs.id
        }
    }

    /// The list a record is in; nil when it is in none, or its row names a
    /// deleted list (read past).
    func listID(of recordID: String) -> String? {
        guard let listID = memberships[recordID], lists[listID] != nil else { return nil }
        return listID
    }

    /// The records of `recordIDs` in the list, in the order given.
    func recordIDs(_ recordIDs: [String], in listID: String) -> [String] {
        guard lists[listID] != nil else { return [] }
        return recordIDs.filter { memberships[$0] == listID }
    }

    // MARK: Rows after an act
    //
    // Each returns what rows become; nothing here writes. The Mac's
    // `PreferenceStore` does, through `SpaceListRows`.

    /// The rows a filing writes: each record of `recordIDs` (once) whose row
    /// would change, naming `listID` (nil: out of every list).
    func itemRowsAfterFiling(_ recordIDs: [String], in listID: String?) -> [ItemRow] {
        var seen: Set<String> = []
        var rows: [ItemRow] = []
        for recordID in recordIDs where !recordID.isEmpty && seen.insert(recordID).inserted {
            guard memberships[recordID] != listID else { continue }
            rows.append(ItemRow(recordID: recordID, listID: listID))
        }
        return rows
    }

    /// The rows a list's deletion removes: every record row this device
    /// holds that names it.
    func itemRowsAfterDeleting(_ listID: String) -> [ItemRow] {
        memberships
            .filter { $0.value == listID }
            .keys
            .sorted()
            .map { ItemRow(recordID: $0, listID: nil) }
    }

    // MARK: Applying

    /// This state after a list row is written (nil: removed).
    func setting(_ list: SpaceList?, for listID: String) -> SpaceLists {
        var copy = self
        copy.lists[listID] = list
        return copy
    }

    /// This state after each record row is written.
    func applying(_ rows: [ItemRow]) -> SpaceLists {
        var copy = self
        for row in rows {
            copy.memberships[row.recordID] = row.listID.flatMap { $0.isEmpty ? nil : $0 }
        }
        return copy
    }
}
