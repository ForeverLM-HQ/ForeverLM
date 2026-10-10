import Foundation

// MARK: - Domain-prefix preferences (docs/cloudkit-schema-design.md §10, the `Preference` row)

extension LegacyV2Mapping {
    /// An old Preference row of a domain prefix: the member's fields it feeds, through the parsers the
    /// activation runs (`deriveNotebookStates`). A settings key is the Setting it owns (`setting`).
    static func mapPreference(_ payload: CloudKitPreferencePayload, context: LegacyMappingContext, into mapping: inout LegacyMapping) throws {
        if let setting = setting(payload) {
            mapping.records.append(setting)
            return
        }
        let value = payload.valuePlistXML.isEmpty ? nil : PreferenceStore.decodePlist(payload.valuePlistXML)
        let key = payload.key
        if let (prefix, field) = notebookStatePrefixes.first(where: { key.hasPrefix($0.prefix) }) {
            let notebookID = String(key.dropFirst(prefix.count))
            guard !notebookID.isEmpty else { return }
            let list = (value as? [String]) ?? []
            var row = NotebookStateRow(notebookID: notebookID)
            switch field {
            case "excluded":
                // An untick names the stamps of the Entry it was made against, as this Mac holds them or as the
                // Entry has them now; until every one can be named, the field is held back whole, as the
                // projection holds it back. A source in no Entry of the notebook is not an untick.
                row.excluded = try context.excludedPairs(notebookID: notebookID, sources: list)
            case "contextNotebooks":
                row.contextNotebooks = Set(list)
            default:
                row.collections = Set(list)
            }
            mapping.records.append(notebookState(row, giving: field))
            return
        }
        if key.hasPrefix(LectureQuizScore.courseQuizPreferenceKeyPrefix) || key.hasPrefix(LectureQuizScore.preferenceKeyPrefix) {
            if let sitting = quizScoreSitting(key: key, valuePlistXML: payload.valuePlistXML) { mapping.records.append(sitting) }
            return
        }
        if key.hasPrefix(MemoryCardDeckState.preferenceKeyPrefix) {
            mapping.records += cardDeckStates(key: key, valuePlistXML: payload.valuePlistXML)
            return
        }
        if key.hasPrefix(LearnerProfile.courseFocusPreferenceKeyPrefix) {
            if let focus = courseFocus(key: key, value: value) { mapping.records.append(focus) }
            return
        }
        if key.hasPrefix(ListeningPositionSync.preferenceKeyPrefix) {
            if let listen = try listenPosition(key: key, value: value, context: context) { mapping.records.append(listen) }
            return
        }
        if key.hasPrefix(ConnectorHealthMap.prefix) {
            if let health = try connectorHealth(key: key, value: value, context: context) { mapping.records.append(health) }
            return
        }
        switch key {
        case SourceDiscovery.blockedPodcastShowsPreferenceKey:
            mapping.records += try blockedShowMarks(names: (value as? [String]) ?? [], updatedAt: payload.updatedAt, context: context)
        case "studio.projectOrder":
            let order = (value as? [String]) ?? []
            let keys = (try? FractionalIndex.keys(between: nil, and: nil, count: order.count)) ?? []
            for (index, notebookID) in order.enumerated() where index < keys.count {
                var row = NotebookStateRow(notebookID: notebookID)
                row.sidebarKey = keys[index]
                mapping.records.append(notebookState(row, giving: "sidebarKey"))
            }
        case NotebookPins.preferenceKey, "studio.navigation.expandedProjectIDs.v1":
            // A row lists the pinned (or expanded) notebooks; every other notebook is not.
            guard value != nil else { return }
            let listed = Set((value as? [String]) ?? [])
            let field = key == NotebookPins.preferenceKey ? "pinned" : "expanded"
            for notebookID in Set(try context.notebookIDs()).union(listed).sorted() {
                var row = NotebookStateRow(notebookID: notebookID)
                if field == "pinned" { row.pinned = listed.contains(notebookID) } else { row.expanded = listed.contains(notebookID) }
                mapping.records.append(notebookState(row, giving: field))
            }
        default:
            break
        }
    }

    /// The `notebook.*` prefixes whose rows feed one NotebookState field each.
    static let notebookStatePrefixes: [(prefix: String, field: String)] = [
        (NotebookChatSelection.preferenceKeyPrefix, "excluded"),
        (NotebookChatContext.preferenceKeyPrefix, "contextNotebooks"),
        (NotebookCollections.membershipPreferenceKeyPrefix, "collections"),
    ]

    /// One NotebookState field as the projection encodes it, with the notebook id every feeder gives. A
    /// notebook's collections are given whole: an id its row stops listing leaves the set (R6-p1).
    static func notebookState(_ row: NotebookStateRow, giving field: String) -> LegacyV2Record {
        let encoded = NotebookStateProjection.encodeRows(row)
        var fields: [String: SyncJSON] = ["notebookID": .string(row.notebookID)]
        if let value = encoded[field] { fields[field] = value }
        var record = LegacyV2Record(
            type: .notebookState, id: SyncIdentity.notebookStateID(notebookID: row.notebookID), fields: fields, giving: .creates
        )
        // A row lists the whole of its field: an id it stops listing (a re-tick, a source taken out of context,
        // a notebook left out of a collection) leaves the record (R6-p1, R8-m7, F6).
        if field == "collections" || field == "contextNotebooks" || field == "excluded" { record.wholeFields = [field] }
        if field == "excluded", encoded["excluded"] != nil {
            // An untick is hashed by the source alone, not by the stamps of its Entry: those move with the
            // Entry's own edits and differ between Macs, and an old row's rewrite must not put back an untick
            // the member released since.
            for source in row.excluded.keys { record.hashOverrides["excluded/\(source)"] = LegacyFieldHashes.hash(.bool(true)) }
        }
        return record
    }

    /// What an old record's deletion gives, when its logical key is known: a deleted `notebook.collections.*`,
    /// `notebook.chatExcluded.*` or `notebook.chatContextNotebooks.*` row is the empty list, which is how
    /// generation 1 writes one (R7-m1, F6), so every id the base lists for it leaves, and a deleted
    /// `course.focus.*` row clears the focus it alone feeds. Any other deletion gives nothing here; what an
    /// old record owned is removed by the base's owner flags, and nothing it fed is withdrawn (§13.6).
    ///
    /// The late import knows a deleted record only by its name and what the base listed of it: `deletionRecords`
    /// reads the same from the base, since nothing but the record's digest is left of its logical key.
    static func mapDeletion(entity: CloudKitSyncEntity, logicalKey: String) -> LegacyMapping {
        var mapping = LegacyMapping(entity: entity, logicalKey: logicalKey)
        guard entity == .preference else { return mapping }
        if let (prefix, field) = notebookStatePrefixes.first(where: { logicalKey.hasPrefix($0.prefix) }), logicalKey.count > prefix.count {
            var emptied = notebookState(NotebookStateRow(notebookID: String(logicalKey.dropFirst(prefix.count))), giving: field)
            emptied.giving = .clears  // an emptied list never makes a NotebookState
            mapping.records.append(emptied)
        }
        let focus = LearnerProfile.courseFocusPreferenceKeyPrefix
        if logicalKey.hasPrefix(focus), logicalKey.count > focus.count {
            mapping.records.append(enrollmentFocus(courseID: String(logicalKey.dropFirst(focus.count)), focus: nil))
        }
        return mapping
    }

    /// What a deleted old record gives, from the base's entry for it: for every NotebookState the entry lists
    /// elements of (`collections/`, `contextNotebooks/`, `excluded/`), that field emptied, and for an
    /// Enrollment it lists a `focus` of, the focus cleared (F8). Both are `clears`: they change a record that
    /// is there and never make one.
    static func deletionRecords(base: MigrationBaseEntry) -> [LegacyV2Record] {
        var records: [LegacyV2Record] = []
        for (key, record) in base.records.sorted(by: { $0.key < $1.key }) where !record.owned {
            guard let colon = key.firstIndex(of: ":") else { continue }
            let id = String(key[key.index(after: colon)...])
            switch key[..<colon] {
            case SyncRecordType.notebookState.rawValue:
                let prefix = SyncIdentity.notebookStateID(notebookID: "")
                guard id.hasPrefix(prefix) else { continue }
                let notebookID = String(id.dropFirst(prefix.count))
                for (_, field) in notebookStatePrefixes where record.hashes.keys.contains(where: { $0.hasPrefix("\(field)/") }) {
                    var emptied = notebookState(NotebookStateRow(notebookID: notebookID), giving: field)
                    emptied.giving = .clears
                    records.append(emptied)
                }
            case SyncRecordType.enrollment.rawValue:
                let prefix = SyncIdentity.enrollmentID(courseID: "")
                guard id.hasPrefix(prefix), record.hashes["focus"] != nil else { continue }
                records.append(enrollmentFocus(courseID: String(id.dropFirst(prefix.count)), focus: nil))
            default:
                continue
            }
        }
        return records
    }
}
