import Foundation

// MARK: - Cards and placements (docs/cloudkit-schema-design.md §10, the `MemoryItem` and `ScheduledSource` rows)

extension LegacyV2Mapping {
    /// The Card fields a deck's `cards.state.*` row feeds (§10): a Memory item gives its kept card, and
    /// leaves these to the row.
    static let cardStateFields: Set<String> = [
        "seedKey", "draft", "variants", "alwaysAsk", "madeBy", "draftedAt", "skippedAt", "supersedes", "splitFrom",
    ]

    /// An old MemoryItem: its Card (status `kept`, its kept wording from the item, its `legacy` columns).
    /// Its origin and deck read the card's state this Mac holds, which the deck's row feeds.
    static func memoryItem(_ payload: CloudKitMemoryItemPayload, context: LegacyMappingContext) throws -> LegacyV2Record {
        let rows = CardRows(item: payload.item, state: try context.heldCardState(payload.item.id))
        var fields = CardProjection.encodeRows(rows)
        for field in cardStateFields { fields.removeValue(forKey: field) }
        return LegacyV2Record(type: .card, id: payload.item.id, fields: fields, giving: .owns)
    }

    /// An old ScheduledSource: its Placement, keyed by its source's wire id (`pl:<wire id>`), as the
    /// activation re-keys generation 1's row (`rekeyPersonalStateRows`).
    static func placement(_ payload: CloudKitScheduledSourcePayload, record: LegacyRecord, context: LegacyMappingContext) throws -> LegacyV2Record {
        let placement = payload.placement
        let sourceID = try context.sourceWireID(placement.sourceID)
        let id = SyncIdentity.placementID(sourceID: sourceID)
        let rows = PlacementRows(
            id: id, sourceID: sourceID, plannedAt: placement.plannedAt.timeIntervalSinceReferenceDate,
            addedAt: placement.addedAt.timeIntervalSinceReferenceDate, completedAt: placement.completedAt?.timeIntervalSinceReferenceDate,
            isAutomatic: payload.isAutomatic, goalIDs: Set(payload.goalIDs)
        )
        var record = LegacyV2Record(type: .placement, id: id, fields: PlacementProjection.encodeRows(rows), giving: .owns)
        record.wholeFields = ["goalIDs"]
        return record
    }
}

// MARK: - Settings (the `Preference` row: a settings key or a `notebookCollection.*` row)

extension LegacyV2Mapping {
    /// An old Preference that is a Setting (`SyncedPreferenceKeys.isSetting`, a `notebookCollection.*`
    /// name included): its Setting, as `SettingProjection` encodes the row `savePreferenceRecord` writes.
    static func setting(_ payload: CloudKitPreferencePayload) -> LegacyV2Record? {
        guard SyncedPreferenceKeys.isSetting(payload.key) else { return nil }
        let row = SettingRow(key: payload.key, valueXML: payload.valuePlistXML, updatedAt: payload.updatedAt.timeIntervalSinceReferenceDate)
        return LegacyV2Record(type: .setting, id: payload.key, fields: SettingProjection.encodeRows(row), giving: .owns)
    }
}
