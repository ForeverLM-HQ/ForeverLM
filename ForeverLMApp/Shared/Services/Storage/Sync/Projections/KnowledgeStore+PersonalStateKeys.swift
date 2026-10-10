import Foundation

// MARK: - Per-member rows on the source's wire id (docs/cloudkit-schema-design.md §4.3, D18)

extension KnowledgeStore {
    /// The id a per-member row about a source is kept under: the source's wire id under generation 2,
    /// so a team copy and the personal copy share one highlight list and one Schedule placement; the
    /// caller's id under generation 1, which keys every row by the local id.
    func personalStateSourceKey(_ sourceID: String) throws -> String {
        guard syncGeneration == .two else { return sourceID }
        return try scalarText("SELECT wire_key FROM sources WHERE id = ?", [.text(sourceID)]) ?? sourceID
    }

    /// The ids a reader matches per-member rows of a source by: the source's own id, and under generation
    /// 2 its wire id too when that differs (a team copy), since the activation re-keys such rows.
    func personalStateSourceKeys(_ sourceID: String) throws -> [String] {
        let key = try personalStateSourceKey(sourceID)
        return key == sourceID ? [sourceID] : [sourceID, key]
    }

    /// The local row a per-member record's source key names: the source whose id or wire id it is, the
    /// personal copy first when a team's copy shares the wire id. Nil when this Mac holds no such source.
    func localSourceID(forWireKey key: String) throws -> String? {
        try scalarText("""
            SELECT id FROM sources WHERE id = ?1 OR wire_key = ?1
            ORDER BY (id = ?1) DESC, (team_id IS NULL) DESC, id LIMIT 1
        """, [.text(key)])
    }
}
