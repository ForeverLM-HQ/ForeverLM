import Foundation

// MARK: - Spaces of pages
//
// The Space sidebar's spaces (docs/docs-design.md, "The Space"; the rows and
// their rules are `PageSpaces`). Every act writes the synced preference rows
// through `PreferenceStore` and reseeds `pageSpaces` from what it wrote, so
// the sidebar and the list redraw at once and the other devices follow
// through sync. Nothing here touches an Artifact record: a space is the
// learner's own grouping of pages.

/// The Mac's reads and writes of the space rows. The rows live in
/// `UserDefaults.standard`, mirrored into `user_preferences` and synced by
/// `PreferenceStore`; a test binds its own defaults (`overrideDefaults`), and
/// while bound, writes go to that suite and never to the sync rail.
enum PageSpaceRows {
    /// A test's own defaults, bound for the task that runs it (as
    /// `NotebookCollectionRows.overrideDefaults`).
    @TaskLocal static var overrideDefaults: DefaultsOverride? = nil

    /// A Sendable carrier for `overrideDefaults`; the suite is only ever
    /// touched by the task that bound it.
    struct DefaultsOverride: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private static var defaults: UserDefaults { overrideDefaults?.defaults ?? .standard }

    /// The spaces the rows hold now. The keys are built at runtime, so one
    /// scan of the defaults finds them; only the two prefixes are kept.
    static func read() -> PageSpaces {
        let rows = defaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix(PageSpaces.namePreferenceKeyPrefix)
                || key.hasPrefix(PageSpaces.membershipPreferenceKeyPrefix)
        }
        return PageSpaces(rows: rows)
    }

    /// Writes a space's name row; nil removes it.
    static func writeName(_ name: String?, spaceID: String) {
        write(name, forKey: PageSpaces.nameKey(spaceID: spaceID))
    }

    /// Writes a page's row; nil removes it, as no row means a page in no
    /// space.
    static func writeMembership(_ spaceID: String?, pageID: String) {
        write(spaceID, forKey: PageSpaces.membershipKey(pageID: pageID))
    }

    private static func write(_ value: String?, forKey key: String) {
        if let override = overrideDefaults {
            if let value {
                override.defaults.set(value, forKey: key)
            } else {
                override.defaults.removeObject(forKey: key)
            }
            return
        }
        // `PreferenceStore` drops a write that changes nothing, so the same
        // row written again never becomes a CloudKit save.
        if let value {
            PreferenceStore.set(value, forKey: key)
        } else {
            PreferenceStore.remove(forKey: key)
        }
    }
}

/// The Mac's reads and writes of the pin rows, as `PageSpaceRows` is for the
/// spaces: `UserDefaults.standard` mirrored into `user_preferences` and synced
/// by `PreferenceStore`; a test binds its own defaults.
enum PagePinRows {
    private static var defaults: UserDefaults { PageSpaceRows.overrideDefaults?.defaults ?? .standard }

    static func read() -> PagePins {
        let rows = defaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix(PagePins.preferenceKeyPrefix)
        }
        return PagePins(rows: rows)
    }

    /// Writes a page's row; nil removes it.
    static func write(_ value: String?, pageID: String) {
        let key = PagePins.key(pageID: pageID)
        if let override = PageSpaceRows.overrideDefaults {
            if let value {
                override.defaults.set(value, forKey: key)
            } else {
                override.defaults.removeObject(forKey: key)
            }
            return
        }
        if let value {
            PreferenceStore.set(value, forKey: key)
        } else {
            PreferenceStore.remove(forKey: key)
        }
    }
}

/// The Mac's reads and writes of the parent rows (`PageParents`), as
/// `PagePinRows` is for the pins: `UserDefaults.standard` mirrored into
/// `user_preferences` and synced by `PreferenceStore`; a test binds its own
/// defaults.
enum PageParentRows {
    private static var defaults: UserDefaults { PageSpaceRows.overrideDefaults?.defaults ?? .standard }

    static func read() -> PageParents {
        let rows = defaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix(PageParents.preferenceKeyPrefix)
        }
        return PageParents(rows: rows)
    }

    /// Writes a child's row; nil removes it.
    static func write(_ parentID: String?, pageID: String) {
        let key = PageParents.key(pageID: pageID)
        if let override = PageSpaceRows.overrideDefaults {
            if let parentID {
                override.defaults.set(parentID, forKey: key)
            } else {
                override.defaults.removeObject(forKey: key)
            }
            return
        }
        if let parentID {
            PreferenceStore.set(parentID, forKey: key)
        } else {
            PreferenceStore.remove(forKey: key)
        }
    }
}

extension StudioViewModel {

    // MARK: Subpages
    //
    // A page's parent is a synced preference row (`PageParents`), per member.
    // Every act re-reads the rows before it writes and reseeds `pageParents`
    // from what it wrote, so the lists redraw at once and the other devices
    // follow through sync. Nothing here touches an Artifact record.

    /// Whether a record can be a parent or a child: one of the learner's own
    /// Markdown pages in My Library. Not a team's page, a member's draft of
    /// one, a linked Google Doc or site, a reading, an animation, an audio
    /// overview or a daily note (a daily note is reached by its day).
    func canNestPage(_ artifact: ArtifactRecord) -> Bool {
        activeTeamID == nil
            && canFileInPageSpace(artifact)
            && artifact.section == .docs
            && !artifact.isLinked
            && !artifact.isMnemonicReading
            && !DailyNote.isDailyNoteID(artifact.id)
    }

    /// The pages that can be a parent now: nestable and not in Trash, in the
    /// library's order. The pages a parent row can name and still be read.
    var nestablePages: [ArtifactRecord] {
        artifacts.filter { !$0.isArchived && canNestPage($0) }
    }

    /// The nestable pages as a tree, in the library's order.
    var pageTree: PageParents.Tree {
        pageParents.tree(among: nestablePages.map(\.id))
    }

    /// The page a page is nested under; nil when it is top-level, or its
    /// parent is gone, in Trash or not one of the learner's own pages.
    func pageParent(of artifactID: String) -> ArtifactRecord? {
        guard let parentID = pageParents.rawParentID(ofPage: artifactID) else { return nil }
        let live = Set(nestablePages.map(\.id))
        guard live.contains(artifactID), live.contains(parentID),
              pageTree.parentID(ofPage: artifactID) == parentID else { return nil }
        return artifacts.first { $0.id == parentID }
    }

    /// The pages above a page, the top one first and the parent last: what the
    /// trail over an open page names. Read row by row from this page up, so an
    /// open page never builds the whole tree.
    func pageAncestors(of artifactID: String) -> [ArtifactRecord] {
        guard let page = artifacts.first(where: { $0.id == artifactID }), canNestPage(page) else { return [] }
        let chain = pageParents.ancestorIDs(ofPage: artifactID) { id in
            guard let candidate = artifacts.first(where: { $0.id == id }) else { return false }
            return !candidate.isArchived && canNestPage(candidate)
        }
        return chain.compactMap { id in artifacts.first { $0.id == id } }
    }

    /// The pages directly under a page, in the library's order.
    func subpages(of artifactID: String) -> [ArtifactRecord] {
        let tree = pageTree
        let byID = Dictionary(artifacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tree.childIDs(of: artifactID).compactMap { byID[$0] }
    }

    /// The pages **Move to Page…** offers for a page: every other nestable
    /// page that is not hidden and not under it (a page is never its own
    /// ancestor), by name.
    func pageParentCandidates(for artifactID: String) -> [ArtifactRecord] {
        let tree = pageTree
        let below = Set(tree.descendantIDs(of: artifactID))
        return nestablePages
            .filter { $0.id != artifactID && !$0.isHidden && !below.contains($0.id) }
            .sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }

    /// **Move to Page…**, **Remove from Parent** and a new subpage: puts a page
    /// under another (nil: top-level again) and returns whether a row was
    /// written. Refused for a page or a parent that cannot nest, and for a
    /// parent that would make the page its own ancestor. No network: the row is
    /// local first and syncs after.
    @discardableResult
    func setPageParent(_ artifactID: String, to parentID: String?, announce: Bool = true) -> Bool {
        refreshPageParentsFromRows()
        guard let child = artifacts.first(where: { $0.id == artifactID }), canNestPage(child) else { return false }
        let ordered = nestablePages.map(\.id)
        let rows = pageParents.rowsAfterSettingParent(parentID, for: artifactID, among: ordered)
        guard !rows.isEmpty else { return false }
        let leaving = pageParent(of: artifactID)
        for row in rows {
            PageParentRows.write(row.parentID, pageID: row.pageID)
        }
        pageParents = pageParents.applying(rows)
        if announce {
            if let parentID, let parent = artifacts.first(where: { $0.id == parentID }) {
                showToast("Moved under \(parent.title)")
            } else if let leaving {
                showToast("Removed from \(leaving.title)")
            }
        }
        return true
    }

    /// A page made inside another (the editor's Page row, a page menu's New
    /// Subpage): nested under it, and in the parent's space when the parent has
    /// one, so it lists beside it. Nothing is said: the page opens next.
    func nestNewPage(_ artifactID: String, under parentID: String) {
        guard setPageParent(artifactID, to: parentID, announce: false) else { return }
        if let space = pageSpace(ofPage: parentID) {
            filePages([artifactID], inPageSpace: space.id)
        }
    }

    /// **New Subpage**: an empty page nested under `parentID`, in the parent's
    /// space, and returns it; nil when it could not be made (the error banner
    /// says why).
    func createSubpage(of parentID: String) async -> ArtifactRecord? {
        guard let parent = artifacts.first(where: { $0.id == parentID }), canNestPage(parent) else { return nil }
        do {
            let snapshot = try await createArtifact(
                title: ArtifactPlaceholderTitle.current,
                homeNotebookID: nil,
                linkedNotebookIDs: [],
                pageSpaceID: pageSpace(ofPage: parentID)?.id
            )
            nestNewPage(snapshot.artifact.id, under: parentID)
            return snapshot.artifact
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Pages deleted for good leave their parent, and the pages that were
    /// under them come out to the top.
    func forgetPageParents(of artifactIDs: [String]) {
        let rows = pageParents.rowsAfterForgetting(artifactIDs)
        guard !rows.isEmpty else { return }
        for row in rows {
            PageParentRows.write(nil, pageID: row.pageID)
        }
        pageParents = pageParents.applying(rows)
    }

    /// The rows as stored now, before an act writes over them (a nest or an
    /// un-nest made on another device reaches `UserDefaults` after the refresh
    /// that follows its sync round).
    func refreshPageParentsFromRows() {
        let stored = PageParentRows.read()
        if stored != pageParents { pageParents = stored }
    }

    /// Whether the learner pinned this page.
    func isPagePinned(_ artifactID: String) -> Bool {
        pagePins.isPinned(artifactID)
    }

    /// **Pin** and **Unpin** on a page's menu. Only the learner's own pages
    /// pin: a team's page is the team's. No network: the row is local first
    /// and syncs after.
    func setPagePinned(_ artifactID: String, pinned: Bool, now: Date = Date()) {
        let stored = PagePinRows.read()
        if stored != pagePins { pagePins = stored }
        if pinned {
            guard !pagePins.isPinned(artifactID) else { return }
            let value = PagePins.rowValue(at: now)
            PagePinRows.write(value, pageID: artifactID)
            pagePins = pagePins.setting(Int(value), for: artifactID)
        } else {
            guard pagePins.isPinned(artifactID) else { return }
            PagePinRows.write(nil, pageID: artifactID)
            pagePins = pagePins.setting(nil, for: artifactID)
        }
    }

    /// The learner's own pages that are pinned and still listed, the newest
    /// pin first: not in Trash, not hidden, not a team's draft copy.
    var pinnedPages: [ArtifactRecord] {
        guard activeTeamID == nil else { return [] }
        let byID = Dictionary(artifacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pagePins.orderedPageIDs.compactMap { id in
            guard let artifact = byID[id],
                  artifact.teamID == nil,
                  !artifact.isArchived, !artifact.isHidden,
                  !TeamContentIdentity.isDraftArtifactID(artifact.id) else { return nil }
            return artifact
        }
    }

    /// The spaces the Space sidebar lists, by name: My Library's alone (a
    /// team is a shared space of its own). In Screen record mode only those
    /// holding a page, canvas or list on screen: a space's name is the
    /// learner's own. `artifacts` is narrowed as it loads, and the canvases
    /// and lists as they are listed.
    var orderedPageSpaces: [PageSpace] {
        guard activeTeamID == nil else { return [] }
        let ordered = pageSpaces.ordered
        guard screenRecordScope != nil else { return ordered }
        let shownIDs = artifacts.map(\.id) + listedCanvases.map(\.id) + listedSpaceLists.map(\.id)
        let holding = Set(shownIDs.compactMap { pageSpaces.spaceID(ofPage: $0) })
        return ordered.filter { holding.contains($0.id) }
    }

    /// The space a page is in, nil when in none.
    func pageSpace(ofPage artifactID: String) -> PageSpace? {
        pageSpaces.space(ofPage: artifactID)
    }

    /// The open library's records in the space, in the library's order.
    func pageSpaceArtifacts(in spaceID: String) -> [ArtifactRecord] {
        artifacts.filter { pageSpaces.spaceID(ofPage: $0.id) == spaceID }
    }

    /// Whether a record can be put in a space: the learner's own page, linked
    /// Google Doc, site or reading in My Library, as the Space lists them
    /// (`SpaceCatalog`). An animation, an audio overview, a card deck, a
    /// reading a notebook holds and a team's record cannot.
    func canFileInPageSpace(_ artifact: ArtifactRecord) -> Bool {
        activeTeamID == nil
            && artifact.teamID == nil
            && !TeamContentIdentity.isDraftArtifactID(artifact.id)
            && artifact.section != .animations
            && !artifact.isCardDeck
            && !isAudioOverview(artifact)
            && !isListedOnlyInItsNotebook(artifact)
    }

    /// Makes a space named `name`, moves `artifactIDs` into it, and returns
    /// it; nil for a name with nothing in it. No network: the rows are local
    /// first and sync after.
    @discardableResult
    func createPageSpace(named name: String, moving artifactIDs: [String] = []) -> PageSpace? {
        guard let cleaned = PageSpaces.cleanedName(name) else { return nil }
        let id = PageSpaces.newSpaceID()
        PageSpaceRows.writeName(cleaned, spaceID: id)
        pageSpaces = pageSpaces.settingName(cleaned, for: id)
        let space = PageSpace(id: id, name: cleaned)
        if !artifactIDs.isEmpty {
            movePages(artifactIDs, toPageSpace: id)
        }
        return space
    }

    /// Renames a space. A name with nothing in it, or a space gone since,
    /// changes nothing.
    func renamePageSpace(_ spaceID: String, to name: String) {
        refreshPageSpacesFromRows()
        guard pageSpaces.space(spaceID) != nil,
              let cleaned = PageSpaces.cleanedName(name) else { return }
        PageSpaceRows.writeName(cleaned, spaceID: spaceID)
        pageSpaces = pageSpaces.settingName(cleaned, for: spaceID)
    }

    /// Deletes a space: its name row, and every page row this Mac holds that
    /// names it. The pages stay, in All.
    func deletePageSpace(_ spaceID: String) {
        refreshPageSpacesFromRows()
        let rows = pageSpaces.membershipRowsAfterDeleting(spaceID)
        for row in rows {
            PageSpaceRows.writeMembership(row.spaceID, pageID: row.pageID)
        }
        PageSpaceRows.writeName(nil, spaceID: spaceID)
        pageSpaces = pageSpaces.applying(rows).settingName(nil, for: spaceID)
    }

    /// Puts pages in a space (nil: in none), each page in that one space
    /// only, and returns how many moved. A space gone since takes nothing,
    /// and a team's library has none of the learner's spaces to file into.
    @discardableResult
    func filePages(_ artifactIDs: [String], inPageSpace spaceID: String?) -> Int {
        refreshPageSpacesFromRows()
        if let spaceID, activeTeamID != nil || pageSpaces.space(spaceID) == nil { return 0 }
        let rows = pageSpaces.membershipRowsAfterMoving(artifactIDs, to: spaceID)
        for row in rows {
            PageSpaceRows.writeMembership(row.spaceID, pageID: row.pageID)
        }
        if !rows.isEmpty { pageSpaces = pageSpaces.applying(rows) }
        return rows.count
    }

    /// **Move to Space ▸**: the pages go to the space, or out of every space
    /// (nil), and a toast says where.
    func movePages(_ artifactIDs: [String], toPageSpace spaceID: String?) {
        let leaving = artifactIDs.lazy.compactMap { self.pageSpaces.space(ofPage: $0) }.first
        guard filePages(artifactIDs, inPageSpace: spaceID) > 0 else { return }
        if let spaceID, let space = pageSpaces.space(spaceID) {
            showToast("Moved to \(NotebookTitle(space.name).text)")
        } else if let leaving {
            showToast("Removed from \(NotebookTitle(leaving.name).text)")
        }
    }

    /// Pages deleted for good leave their space.
    func forgetPageSpaces(of artifactIDs: [String]) {
        let known = artifactIDs.filter { pageSpaces.memberships[$0] != nil }
        guard !known.isEmpty else { return }
        for pageID in known {
            PageSpaceRows.writeMembership(nil, pageID: pageID)
        }
        pageSpaces = pageSpaces.applying(known.map { PageSpaces.MembershipRow(pageID: $0, spaceID: nil) })
    }

    /// The rows as stored now, before an act writes over them. A space
    /// deleted on another device reaches `UserDefaults` after the refresh
    /// that follows its sync round, so the cache can still hold it; renaming
    /// or filing into it from that cache would write its name row back and
    /// bring a deleted space back on every device.
    func refreshPageSpacesFromRows() {
        let stored = PageSpaceRows.read()
        if stored != pageSpaces { pageSpaces = stored }
    }

    /// A remote preference change touching the grouping rows — the Space's
    /// spaces of pages or the collections of notebooks — reseeds them, so
    /// one deleted elsewhere leaves this Mac's lists as soon as its row goes
    /// (`PreferenceStore.didChangeRemotely`; an empty set means "anything
    /// may have changed").
    func reloadGroupingRows(afterRemoteChangeOf keys: Set<String>) {
        let prefixes = [
            PageSpaces.namePreferenceKeyPrefix,
            PageSpaces.membershipPreferenceKeyPrefix,
            PagePins.preferenceKeyPrefix,
            PageParents.preferenceKeyPrefix,
            NotebookCollections.namePreferenceKeyPrefix,
            NotebookCollections.membershipPreferenceKeyPrefix,
            // A canvas is its layout row: one made, renamed or put in Trash
            // on another Mac lists here once it lands.
            KnowledgeMap.layoutKeyPrefix,
            SpaceLists.listPreferenceKeyPrefix,
            SpaceLists.itemPreferenceKeyPrefix,
        ]
        guard keys.isEmpty || keys.contains(where: { key in prefixes.contains(where: key.hasPrefix) }) else { return }
        refreshCanvasesFromRows()
        refreshSpaceListsFromRows()
        refreshPageSpacesFromRows()
        let pins = PagePinRows.read()
        if pins != pagePins { pagePins = pins }
        refreshPageParentsFromRows()
        let collections = NotebookCollectionRows.read()
        if collections != notebookCollections { notebookCollections = collections }
    }
}
