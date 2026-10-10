import Foundation

// MARK: - Lists in the Space
//
// The learner's lists of goals and of ideas, items in the Space beside their
// pages, sites and canvases (docs/docs-design.md, "Lists in the Space"; the
// rows and their rules are `SpaceLists`). Every act writes the synced
// preference rows through `PreferenceStore` and reseeds `spaceLists` from
// what it wrote, so the Space redraws at once and the other devices follow
// through sync. Nothing here touches a goal's or an idea's record: a list is
// the learner's grouping of them. A list files in a space and pins through
// the page rows (`page.space.<id>`, `page.pinned.<id>`), as a canvas does.

/// The Mac's reads and writes of the list rows, as `PageSpaceRows` is for the
/// spaces; a test binds `PageSpaceRows.overrideDefaults`.
enum SpaceListRows {
    private static var defaults: UserDefaults { PageSpaceRows.overrideDefaults?.defaults ?? .standard }

    static func read() -> SpaceLists {
        let rows = defaults.dictionaryRepresentation().filter { key, _ in
            key.hasPrefix(SpaceLists.listPreferenceKeyPrefix) || key.hasPrefix(SpaceLists.itemPreferenceKeyPrefix)
        }
        return SpaceLists(rows: rows)
    }

    /// Writes a list's row; nil removes it.
    static func writeList(_ list: SpaceList?, listID: String) {
        write(list.map(SpaceLists.rowValue), forKey: SpaceLists.listKey(listID: listID))
    }

    /// Writes a record's row; nil removes it, as no row means a goal or an
    /// idea in no list.
    static func writeItem(_ listID: String?, recordID: String) {
        write(listID, forKey: SpaceLists.itemKey(recordID: recordID))
    }

    private static func write(_ value: String?, forKey key: String) {
        if let override = PageSpaceRows.overrideDefaults {
            if let value {
                override.defaults.set(value, forKey: key)
            } else {
                override.defaults.removeObject(forKey: key)
            }
            return
        }
        // `PreferenceStore` drops a write that changes nothing.
        if let value {
            PreferenceStore.set(value, forKey: key)
        } else {
            PreferenceStore.remove(forKey: key)
        }
    }
}

extension StudioViewModel {
    /// The lists the Space lists: the learner's own, in My Library. A team's
    /// library lists none: its members' lists are each their own.
    var listedSpaceLists: [SpaceList] {
        activeTeamID == nil ? spaceLists.all : []
    }

    /// The learner's lists that are pinned and not in Trash, the newest pin
    /// first: the Space sidebar's Pinned, beside the pinned pages.
    var pinnedSpaceLists: [SpaceList] {
        guard activeTeamID == nil else { return [] }
        return pagePins.orderedPageIDs.compactMap { id in
            guard let list = spaceLists.list(id), !list.isTrashed else { return nil }
            return list
        }
    }

    /// The goals in a list, in the Goals tab's order.
    func goals(inSpaceList listID: String) -> [LearningGoalRecord] {
        allGoals.filter { spaceLists.listID(of: $0.id) == listID }
    }

    /// The ideas in a list, newest first.
    func ideas(inSpaceList listID: String) -> [IdeaRecord] {
        ideas.filter { spaceLists.listID(of: $0.id) == listID }.sorted(by: IdeaRecord.listOrder)
    }

    /// How many goals or ideas a list holds, and the latest time one of them
    /// changed: its row in the Space says the one and sorts by the other.
    func spaceListContents(_ list: SpaceList) -> (count: Int, updatedAt: Date) {
        let dates: [Date]
        switch list.kind {
        case .goals: dates = goals(inSpaceList: list.id).map(\.updatedAt)
        case .ideas: dates = ideas(inSpaceList: list.id).map(\.updatedAt)
        }
        return (dates.count, max(list.updatedAt, dates.max() ?? list.updatedAt))
    }

    /// The list a goal or an idea is in, while it is in use.
    func spaceList(ofRecord recordID: String) -> SpaceList? {
        spaceLists.listID(of: recordID).flatMap { spaceLists.list($0) }
    }

    /// The lists of a kind a goal or an idea can be filed in: the learner's
    /// own, not in Trash.
    func spaceListsAccepting(_ kind: SpaceList.Kind) -> [SpaceList] {
        listedSpaceLists.filter { $0.kind == kind && !$0.isTrashed }
    }

    /// Makes a list of `kind` named `name` — in the space `spaceID` when one
    /// is given — holding `recordIDs`, and returns it. No network: the rows
    /// are local first and sync after.
    @discardableResult
    func createSpaceList(
        _ kind: SpaceList.Kind,
        named name: String? = nil,
        inPageSpace spaceID: String? = nil,
        holding recordIDs: [String] = [],
        now: Date = Date()
    ) -> SpaceList {
        let list = writeSpaceList(SpaceList(
            id: SpaceLists.newListID(),
            kind: kind,
            name: name.flatMap(SpaceLists.cleanedName) ?? kind.newName,
            createdAt: now,
            updatedAt: now,
            trashedAt: nil
        ))
        if let spaceID { filePages([list.id], inPageSpace: spaceID) }
        if !recordIDs.isEmpty { fileRecords(recordIDs, inSpaceList: list.id) }
        return list
    }

    /// **New ▸ Goals** or **Ideas**: makes a list — in the space the Space
    /// has lit, when it has one — and shows it in the window's Space.
    func makeAndOpenSpaceList(_ kind: SpaceList.Kind, inPageSpace spaceID: String?, in destinationWindowState: StudioWindowState?) {
        let list = createSpaceList(kind, inPageSpace: spaceID)
        openSpaceList(list.id, in: destinationWindowState)
    }

    /// Shows a list in the window's Space: a list is a place there, whose
    /// page is the goals or ideas it holds.
    func openSpaceList(_ listID: String, in destinationWindowState: StudioWindowState? = nil) {
        let window = destinationWindowState ?? activeWindowState
        let key = SpaceDestination.list(listID).key
        if window.spaceDestinationKey != key { window.spaceDestinationKey = key }
        openArtifactsInReader(in: window)
    }

    /// Renames a list. A name with nothing in it, the same name, or a list
    /// gone since changes nothing.
    func renameSpaceList(_ listID: String, to name: String, now: Date = Date()) {
        refreshSpaceListsFromRows()
        guard let list = spaceLists.list(listID),
              let cleaned = SpaceLists.cleanedName(name),
              cleaned != list.name else { return }
        writeSpaceList(SpaceList(
            id: list.id, kind: list.kind, name: cleaned,
            createdAt: list.createdAt, updatedAt: now, trashedAt: list.trashedAt
        ))
    }

    /// **Move to Trash**: the lists leave the Space's lists and wait in
    /// Trash; their goals and ideas stay where they are.
    func moveSpaceListsToTrash(_ listIDs: [String], now: Date = Date()) {
        refreshSpaceListsFromRows()
        let moving = listIDs.compactMap { spaceLists.list($0) }.filter { !$0.isTrashed }
        guard !moving.isEmpty else { return }
        for list in moving {
            writeSpaceList(SpaceList(
                id: list.id, kind: list.kind, name: list.name,
                createdAt: list.createdAt, updatedAt: now, trashedAt: now
            ))
        }
        showToast(moving.count == 1 ? "Moved to Trash" : "Moved \(moving.count) lists to Trash")
    }

    /// **Restore**: the lists come back, holding what they held.
    func restoreSpaceLists(_ listIDs: [String], now: Date = Date()) {
        refreshSpaceListsFromRows()
        for list in listIDs.compactMap({ spaceLists.list($0) }) where list.isTrashed {
            writeSpaceList(SpaceList(
                id: list.id, kind: list.kind, name: list.name,
                createdAt: list.createdAt, updatedAt: now, trashedAt: nil
            ))
        }
    }

    /// **Delete Forever**: the lists' rows go, with every row this Mac holds
    /// that files a goal or an idea in them, their place in a space and their
    /// pin. The goals and ideas stay, in Goals and Ideas. Only a list in
    /// Trash is deleted, as only a page in Trash is.
    func deleteSpaceListsForever(_ listIDs: [String]) {
        refreshSpaceListsFromRows()
        let deleting = listIDs.filter { spaceLists.list($0)?.isTrashed == true }
        guard !deleting.isEmpty else { return }
        for listID in deleting {
            let rows = spaceLists.itemRowsAfterDeleting(listID)
            for row in rows {
                SpaceListRows.writeItem(row.listID, recordID: row.recordID)
            }
            SpaceListRows.writeList(nil, listID: listID)
            spaceLists = spaceLists.applying(rows).setting(nil, for: listID)
            setPagePinned(listID, pinned: false)
            SpaceRecents.shared.forget(.list, id: listID)
        }
        forgetPageSpaces(of: deleting)
    }

    /// Files goals or ideas in a list (nil: in none), each in that one list
    /// only, and returns how many moved. A list gone since takes nothing.
    @discardableResult
    func fileRecords(_ recordIDs: [String], inSpaceList listID: String?) -> Int {
        refreshSpaceListsFromRows()
        if let listID, spaceLists.list(listID) == nil { return 0 }
        let rows = spaceLists.itemRowsAfterFiling(recordIDs, in: listID)
        for row in rows {
            SpaceListRows.writeItem(row.listID, recordID: row.recordID)
        }
        if !rows.isEmpty { spaceLists = spaceLists.applying(rows) }
        return rows.count
    }

    /// **Move to List ▸**: the goals or ideas go to the list, or out of
    /// every list (nil), and a toast says where.
    func moveRecords(_ recordIDs: [String], toSpaceList listID: String?) {
        let leaving = recordIDs.lazy.compactMap { self.spaceList(ofRecord: $0) }.first
        guard fileRecords(recordIDs, inSpaceList: listID) > 0 else { return }
        if let listID, let list = spaceLists.list(listID) {
            showToast("Moved to \(list.name)")
        } else if let leaving {
            showToast("Removed from \(leaving.name)")
        }
    }

    /// Writes a list's row and keeps the list as the row reads back, so the
    /// copy here equals the one read from the rows later: a date goes
    /// through seconds since 1970, which can move it by a fraction.
    @discardableResult
    private func writeSpaceList(_ list: SpaceList) -> SpaceList {
        let stored = SpaceLists.list(id: list.id, rowValue: SpaceLists.rowValue(list)) ?? list
        SpaceListRows.writeList(stored, listID: stored.id)
        spaceLists = spaceLists.setting(stored, for: stored.id)
        return stored
    }

    /// The rows as stored now, before an act writes over them: a list
    /// deleted on another device must not be written back from this Mac's.
    func refreshSpaceListsFromRows() {
        let stored = SpaceListRows.read()
        if stored != spaceLists { spaceLists = stored }
    }
}
