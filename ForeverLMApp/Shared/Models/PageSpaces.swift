import Foundation

// MARK: - Spaces of pages
//
// ChatGPT's spaces, in ForeverLM's Space (product owner, 2026-10-06: "make sure the
// docs etc work equally nicely and have feature parity. perhaps we also need
// a 'spaces' equivalent"): a named group of pages around a topic or a team,
// "such as a design studio or a research project", made in the Space
// sidebar. docs/docs-design.md, "The Space".
//
// Not the sync design's `Space` (a zone a team's records live in,
// docs/cloudkit-schema-design.md D4): this is the learner's own grouping of
// pages, and the code says `PageSpace` so the two never share a name.

/// One of the learner's spaces of pages: its id and its name. A leading emoji
/// in the name is its icon, as a notebook's is (`NotebookTitle`).
///
/// A PageSpace is the learner's own grouping of pages, not a sync zone: it is
/// two kinds of preference row (`PageSpaces`), and nothing about it is on the
/// pages' records or in a zone of its own. The shared spaces are the teams.
struct PageSpace: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
}

/// The learner's spaces of pages, as two kinds of synced preference row keep
/// them (`SyncedPreferenceKeys.syncedPrefixes`):
///
/// - `pageSpace.<spaceID>`: the space's name, a String. One row per space, so
///   renaming one never touches another.
/// - `page.space.<artifactID>`: the one space the page is in, a String space
///   id; no row when it is in none. A page is in at most one space, as a file
///   is in one folder. One row per page, so moving two pages on two devices
///   at once keeps both moves.
///
/// Per member, keyed by the record's id and never on the Artifact record
/// (teams-design rule 7), so no schema changes. A row naming a space whose
/// name row is gone — deleted on a device that did not know the page — is
/// read past, so a deleted space never comes back. Foundation-only, beside
/// `NotebookTitle` (NotebookIcon.swift) for the order: the Mac and the macOS
/// unit tests compile it; the web's twin reads the same rows.
struct PageSpaces: Equatable, Sendable {
    static let namePreferenceKeyPrefix = "pageSpace."
    static let membershipPreferenceKeyPrefix = "page.space."
    /// What every space id starts with: `psp-` and a lowercased UUID.
    static let idPrefix = "psp-"
    /// The longest name kept; a longer one is cut there.
    static let nameCharacterLimit = 80

    /// One page's row as an act leaves it: the space it names, nil when the
    /// row goes.
    struct MembershipRow: Equatable, Sendable {
        let pageID: String
        let spaceID: String?
    }

    /// Each space's name, by id.
    private(set) var names: [String: String]
    /// The space each page's row names, by Artifact id, a deleted space's id
    /// included until the row is written again.
    private(set) var memberships: [String: String]

    init(names: [String: String] = [:], memberships: [String: String] = [:]) {
        self.names = names.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        self.memberships = memberships.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    /// The spaces in a set of preference rows: every row under the two
    /// prefixes, the rest ignored (`UserDefaults.dictionaryRepresentation()`
    /// on the Mac). A name or a membership that is not a non-empty String is
    /// no row.
    init(rows: [String: Any]) {
        var names: [String: String] = [:]
        var memberships: [String: String] = [:]
        for (key, value) in rows {
            if let id = Self.spaceID(fromNameKey: key) {
                guard let name = value as? String else { continue }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { names[id] = trimmed }
            } else if let pageID = Self.pageID(fromMembershipKey: key) {
                guard let spaceID = value as? String else { continue }
                let trimmed = spaceID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { memberships[pageID] = trimmed }
            }
        }
        self.init(names: names, memberships: memberships)
    }

    // MARK: Keys

    static func nameKey(spaceID: String) -> String {
        namePreferenceKeyPrefix + spaceID
    }

    static func membershipKey(pageID: String) -> String {
        membershipPreferenceKeyPrefix + pageID
    }

    static func spaceID(fromNameKey key: String) -> String? {
        guard key.hasPrefix(namePreferenceKeyPrefix) else { return nil }
        let id = String(key.dropFirst(namePreferenceKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    static func pageID(fromMembershipKey key: String) -> String? {
        guard key.hasPrefix(membershipPreferenceKeyPrefix) else { return nil }
        let id = String(key.dropFirst(membershipPreferenceKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// A new space's id.
    static func newSpaceID() -> String {
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

    /// Every space, by name (a leading emoji aside), then by id, so two
    /// spaces never trade places between two reads.
    var ordered: [PageSpace] {
        names
            .map { PageSpace(id: $0.key, name: $0.value) }
            .sorted(by: Self.nameOrder)
    }

    var isEmpty: Bool { names.isEmpty }

    func space(_ spaceID: String) -> PageSpace? {
        names[spaceID].map { PageSpace(id: spaceID, name: $0) }
    }

    /// The space a page is in; nil when it is in none, or its row names a
    /// deleted space (read past).
    func spaceID(ofPage pageID: String) -> String? {
        guard let spaceID = memberships[pageID], names[spaceID] != nil else { return nil }
        return spaceID
    }

    func space(ofPage pageID: String) -> PageSpace? {
        spaceID(ofPage: pageID).flatMap { space($0) }
    }

    /// The pages of `pageIDs` in the space, in the order given.
    func pageIDs(_ pageIDs: [String], in spaceID: String) -> [String] {
        guard names[spaceID] != nil else { return [] }
        return pageIDs.filter { memberships[$0] == spaceID }
    }

    static func nameOrder(_ lhs: PageSpace, _ rhs: PageSpace) -> Bool {
        let order = NotebookTitle(lhs.name).text.localizedStandardCompare(NotebookTitle(rhs.name).text)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    // MARK: Rows after an act
    //
    // Each returns what rows become; nothing here writes. The Mac's
    // `PreferenceStore` does, through `PageSpaceRows`.

    /// The rows a move writes: each page of `pageIDs` (once, in the order
    /// given) whose row would change, naming `spaceID` (nil: out of every
    /// space, the row goes). A page already there writes nothing; a page whose
    /// row names a deleted space has that row rewritten.
    func membershipRowsAfterMoving(_ pageIDs: [String], to spaceID: String?) -> [MembershipRow] {
        var seen: Set<String> = []
        var rows: [MembershipRow] = []
        for pageID in pageIDs where !pageID.isEmpty && seen.insert(pageID).inserted {
            guard memberships[pageID] != spaceID else { continue }
            rows.append(MembershipRow(pageID: pageID, spaceID: spaceID))
        }
        return rows
    }

    /// The rows a space's deletion removes: every page row this device holds
    /// that names it, by page id.
    func membershipRowsAfterDeleting(_ spaceID: String) -> [MembershipRow] {
        memberships
            .filter { $0.value == spaceID }
            .keys
            .sorted()
            .map { MembershipRow(pageID: $0, spaceID: nil) }
    }

    // MARK: Applying

    /// This state after a name row is written (nil: removed).
    func settingName(_ name: String?, for spaceID: String) -> PageSpaces {
        var copy = self
        copy.names[spaceID] = name.flatMap { $0.isEmpty ? nil : $0 }
        return copy
    }

    /// This state after a page's row is written (nil: removed).
    func settingMembership(_ spaceID: String?, for pageID: String) -> PageSpaces {
        var copy = self
        copy.memberships[pageID] = spaceID.flatMap { $0.isEmpty ? nil : $0 }
        return copy
    }

    /// This state after each row is written.
    func applying(_ rows: [MembershipRow]) -> PageSpaces {
        rows.reduce(self) { $0.settingMembership($1.spaceID, for: $1.pageID) }
    }
}

// MARK: - Pinned pages

/// The pages the learner pinned, as one synced preference row each
/// (`SyncedPreferenceKeys.syncedPrefixes`): ChatGPT's **Pin** on a page's menu
/// (product owner, 2026-10-07: full parity with Codex's Pages).
///
/// `page.pinned.<artifactID>`: the second the page was pinned, as a String of
/// whole seconds since 1970. One row per page, so two devices pinning two
/// pages at once keep both; no row is an unpinned page. The newest pin lists
/// first. Per member, keyed by the record's id and never on the Artifact
/// record (teams-design rule 7), so no schema changes. Foundation-only, like
/// `PageSpaces`.
struct PagePins: Equatable, Sendable {
    static let preferenceKeyPrefix = "page.pinned."

    /// The moment each pinned page was pinned, by Artifact id.
    private(set) var pinnedAt: [String: Int]

    init(pinnedAt: [String: Int] = [:]) {
        self.pinnedAt = pinnedAt.filter { !$0.key.isEmpty }
    }

    /// The pins in a set of preference rows: every row under the prefix, the
    /// rest ignored. A value that is not a whole number of seconds, as a
    /// String or a number, is no row.
    init(rows: [String: Any]) {
        var pins: [String: Int] = [:]
        for (key, value) in rows {
            guard let pageID = Self.pageID(fromKey: key) else { continue }
            if let text = value as? String, let seconds = Int(text.trimmingCharacters(in: .whitespaces)) {
                pins[pageID] = seconds
            } else if let number = value as? NSNumber {
                pins[pageID] = number.intValue
            }
        }
        self.init(pinnedAt: pins)
    }

    static func key(pageID: String) -> String {
        preferenceKeyPrefix + pageID
    }

    static func pageID(fromKey key: String) -> String? {
        guard key.hasPrefix(preferenceKeyPrefix) else { return nil }
        let id = String(key.dropFirst(preferenceKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// The value a pin row holds for a moment.
    static func rowValue(at date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }

    func isPinned(_ pageID: String) -> Bool {
        pinnedAt[pageID] != nil
    }

    /// The pinned pages' ids, the newest pin first; the id breaks a tie so
    /// the order is the same on every device.
    var orderedPageIDs: [String] {
        pinnedAt.sorted { left, right in
            left.value != right.value ? left.value > right.value : left.key < right.key
        }.map(\.key)
    }

    /// This state after a page's row is written (nil: removed).
    func setting(_ seconds: Int?, for pageID: String) -> PagePins {
        var copy = self
        copy.pinnedAt[pageID] = seconds
        return copy
    }
}

// MARK: - Subpages

/// Which page sits under which: ChatGPT's "Nest subpages under parent pages"
/// (product owner, 2026-10-07: full parity with Codex's Pages), as one synced
/// preference row per child (`SyncedPreferenceKeys.syncedPrefixes`).
///
/// `page.parent.<childArtifactID>`: the parent's Artifact id, a String. One
/// row per child, so two devices nesting two pages at once keep both; no row
/// is a top-level page. Per member, keyed by the record's id and never on the
/// Artifact record (teams-design rule 7), so no schema changes. Only the
/// learner's own Markdown pages nest, under another of their own: a team's
/// library has no parent rows. Foundation-only, like `PageSpaces`.
///
/// What a row names is read, never trusted. A parent that is not among the
/// pages asked about (gone, in Trash, hidden from the list) leaves its
/// children top-level, and the row stays: restoring the parent brings the
/// children back under it. A cycle two devices made at once (A under B on one,
/// B under A on the other) is cut at the same page everywhere: the smallest
/// id of the cycle reads as top-level.
struct PageParents: Equatable, Sendable {
    static let preferenceKeyPrefix = "page.parent."
    /// How many levels the lists indent and the trail names; a deeper page is
    /// stored as deep as it is and drawn at this level.
    static let displayDepthLimit = 6

    /// One page's row as an act leaves it: the parent it names, nil when the
    /// row goes.
    struct Row: Equatable, Sendable {
        let pageID: String
        let parentID: String?
    }

    /// The parent each row names, by child Artifact id, a gone parent's id
    /// included until the row is written again.
    private(set) var parentIDs: [String: String]

    init(parentIDs: [String: String] = [:]) {
        self.parentIDs = parentIDs.filter { !$0.key.isEmpty && !$0.value.isEmpty && $0.key != $0.value }
    }

    /// The parents in a set of preference rows: every row under the prefix,
    /// the rest ignored. A value that is not a non-empty String, or that
    /// names the page itself, is no row.
    init(rows: [String: Any]) {
        var parents: [String: String] = [:]
        for (key, value) in rows {
            guard let pageID = Self.pageID(fromKey: key), let text = value as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parents[pageID] = trimmed }
        }
        self.init(parentIDs: parents)
    }

    static func key(pageID: String) -> String {
        preferenceKeyPrefix + pageID
    }

    static func pageID(fromKey key: String) -> String? {
        guard key.hasPrefix(preferenceKeyPrefix) else { return nil }
        let id = String(key.dropFirst(preferenceKeyPrefix.count))
        return id.isEmpty ? nil : id
    }

    var isEmpty: Bool { parentIDs.isEmpty }

    /// The parent a page's row names, whether or not that page still lists.
    func rawParentID(ofPage pageID: String) -> String? {
        parentIDs[pageID]
    }

    /// This state after a page's row is written (nil: removed).
    func settingParent(_ parentID: String?, for pageID: String) -> PageParents {
        var copy = self
        copy.parentIDs[pageID] = parentID.flatMap { $0.isEmpty || $0 == pageID ? nil : $0 }
        return copy
    }

    /// This state after each row is written.
    func applying(_ rows: [Row]) -> PageParents {
        rows.reduce(self) { $0.settingParent($1.parentID, for: $1.pageID) }
    }

    // MARK: Reading

    /// The pages of `orderedIDs` as a tree: a page is under its row's parent
    /// when that parent is one of `orderedIDs` too, else top-level. The order
    /// given is the order siblings and roots keep.
    func tree(among orderedIDs: [String]) -> Tree {
        Tree(parentIDs: parentIDs, orderedIDs: orderedIDs)
    }

    /// A page's ancestors, the top one first and the parent last, reading the
    /// rows page by page: for the one page open, where building the whole tree
    /// would be too much. `isLive` says whether an id is a page that can be a
    /// parent (listed, not in Trash); the chain stops at the first that is not,
    /// and at a repeat, so a cycle never loops.
    func ancestorIDs(ofPage pageID: String, isLive: (String) -> Bool) -> [String] {
        var chain: [String] = []
        var seen: Set<String> = [pageID]
        var current = pageID
        while let parent = parentIDs[current], isLive(parent), seen.insert(parent).inserted {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// The ancestors the trail above an open page names: at most `limit`, the
    /// nearest ones, and whether more were left off the top.
    static func trail(_ chain: [String], limit: Int = displayDepthLimit) -> (ids: [String], isTruncated: Bool) {
        guard chain.count > limit else { return (chain, false) }
        return (Array(chain.suffix(limit)), true)
    }

    // MARK: Rows after an act
    //
    // Each returns what rows become; nothing here writes. The Mac's
    // `PreferenceStore` does, through `PageParentRows`.

    /// The rows nesting a page under `parentID` writes (nil: out from under
    /// its parent, the row goes). None when the move is refused (`canSetParent`
    /// on the tree of `orderedIDs`: a parent that is not a listed page, the
    /// page itself, or one of its own descendants) or changes nothing.
    func rowsAfterSettingParent(_ parentID: String?, for pageID: String, among orderedIDs: [String]) -> [Row] {
        guard !pageID.isEmpty else { return [] }
        guard tree(among: orderedIDs).canSetParent(parentID, for: pageID) else { return [] }
        guard parentIDs[pageID] != parentID else { return [] }
        return [Row(pageID: pageID, parentID: parentID)]
    }

    /// The rows a page's deletion for good removes: its own, and the rows of
    /// the pages that were under it, which would name an id that can never
    /// come back. By page id.
    func rowsAfterForgetting(_ pageIDs: [String]) -> [Row] {
        let gone = Set(pageIDs)
        return parentIDs
            .filter { gone.contains($0.key) || gone.contains($0.value) }
            .keys
            .sorted()
            .map { Row(pageID: $0, parentID: nil) }
    }

    // MARK: The tree

    /// A set of pages read as a tree (`tree(among:)`): each page's resolved
    /// parent, its children in the order given, and the questions the lists,
    /// the menus and the trail ask.
    struct Tree: Equatable, Sendable {
        /// One row of the list a tree flattens to.
        struct ListRow: Equatable, Sendable {
            let id: String
            /// How far in the row is drawn, at most `displayDepthLimit`.
            let level: Int
            let hasChildren: Bool
            let isExpanded: Bool
        }

        /// The pages, in the order given, each once.
        let orderedIDs: [String]
        private let parentOf: [String: String]
        private let childrenOf: [String: [String]]

        init(parentIDs: [String: String], orderedIDs: [String]) {
            var seen: Set<String> = []
            let ordered = orderedIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
            var resolved: [String: String] = [:]
            for id in ordered {
                if let parent = parentIDs[id], parent != id, seen.contains(parent) { resolved[id] = parent }
            }
            // Two devices can each nest one page under the other. Cut every
            // cycle at its smallest id, the same page on every device.
            var settled: [String: Bool] = [:] // true: walked and settled; false: on the walk now
            for start in ordered where settled[start] == nil {
                var walk: [String] = []
                var node: String? = start
                while let current = node, settled[current] == nil {
                    settled[current] = false
                    walk.append(current)
                    node = resolved[current]
                }
                if let current = node, settled[current] == false, let at = walk.firstIndex(of: current),
                   let breaker = walk[at...].min() {
                    resolved[breaker] = nil
                }
                for id in walk { settled[id] = true }
            }
            var children: [String: [String]] = [:]
            for id in ordered {
                if let parent = resolved[id] { children[parent, default: []].append(id) }
            }
            self.orderedIDs = ordered
            self.parentOf = resolved
            self.childrenOf = children
        }

        /// The pages with no parent in the set, in order.
        var rootIDs: [String] {
            orderedIDs.filter { parentOf[$0] == nil }
        }

        /// The page a page is under; nil for a top-level page, or one the set
        /// does not hold.
        func parentID(ofPage pageID: String) -> String? {
            parentOf[pageID]
        }

        /// The pages directly under a page, in order.
        func childIDs(of pageID: String) -> [String] {
            childrenOf[pageID] ?? []
        }

        func hasChildren(_ pageID: String) -> Bool {
            childrenOf[pageID] != nil
        }

        /// A page's ancestors, the top one first and the parent last.
        func ancestorIDs(ofPage pageID: String) -> [String] {
            var chain: [String] = []
            var current = pageID
            while let parent = parentOf[current] {
                chain.append(parent)
                current = parent
            }
            return chain.reversed()
        }

        /// How many pages are above a page: 0 for a top-level one.
        func depth(ofPage pageID: String) -> Int {
            var depth = 0
            var current = pageID
            while let parent = parentOf[current] {
                depth += 1
                current = parent
            }
            return depth
        }

        /// Every page under a page, at any depth, nearest first.
        func descendantIDs(of pageID: String) -> [String] {
            var found: [String] = []
            var queue = childIDs(of: pageID)
            var index = 0
            while index < queue.count {
                let next = queue[index]
                index += 1
                found.append(next)
                queue.append(contentsOf: childIDs(of: next))
            }
            return found
        }

        /// Whether a page may be put under `parentID` (nil: top-level, always
        /// fine). A page never becomes its own ancestor: not under itself, and
        /// not under a page that is under it. The parent must be one of the
        /// set's pages.
        func canSetParent(_ parentID: String?, for pageID: String) -> Bool {
            guard let parentID else { return true }
            guard parentID != pageID, orderedIDs.contains(parentID) else { return false }
            return !descendantIDs(of: pageID).contains(parentID)
        }

        /// The tree as the rows a list draws, depth first: a page, then its
        /// children when it is in `expanded`, each level in order. A page
        /// deeper than `displayDepthLimit` is drawn at that level.
        func listRows(expanded: Set<String>) -> [ListRow] {
            var rows: [ListRow] = []
            rows.reserveCapacity(orderedIDs.count)
            var stack: [(id: String, depth: Int)] = rootIDs.reversed().map { ($0, 0) }
            while let (id, depth) = stack.popLast() {
                let hasChildren = childrenOf[id] != nil
                let isExpanded = hasChildren && expanded.contains(id)
                rows.append(ListRow(
                    id: id,
                    level: min(depth, PageParents.displayDepthLimit),
                    hasChildren: hasChildren,
                    isExpanded: isExpanded
                ))
                if isExpanded {
                    for child in childIDs(of: id).reversed() { stack.append((child, depth + 1)) }
                }
            }
            return rows
        }
    }
}
