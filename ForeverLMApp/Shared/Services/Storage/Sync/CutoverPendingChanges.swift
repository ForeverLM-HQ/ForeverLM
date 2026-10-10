import Foundation

/// The old-world changes this Mac kept (docs/cloudkit-schema-design.md §13.5, first kind of pending change):
/// a record whose undrained `sync_changes` row survived the catch-up won its per-record rule (an old record
/// whose change tag was unchanged counts as won, R8-m2), so its rows are this Mac's own edit, dated with that
/// row's `changed_at`. They go to the outbox as an insert at that time, which the engine's inbound merge
/// then treats as any pending change: a field that differs from the server's takes the local value only
/// when its stamp is the later, and the rest take the server's. Run once, before the engine's first
/// inbound apply writes the server's values over these rows; the seeder's own pass dates the same rows the
/// same way (`SeedRowReader.timeSQL`).
///
/// A Doc's or a Notes Doc's body is decided apart from this: by `document.md` against `document.base.md`,
/// or the notes against the notes base, when the body arrives (`DocBodyMaterializer`, R8-1), so a rename or
/// a filing alone never counts as an edit of a body.
enum CutoverPendingChanges {
    static let journalScope = "reconcile.pendingCaptured"

    /// Writes an outbox row for every row of a record with a pending old-world change. Returns how many.
    @discardableResult
    static func capture(in connection: SQLiteConnection, registry: ProjectionRegistry, now: Date = Date()) throws -> Int {
        let replica = ReplicaStore(connection: connection)
        guard try replica.engineState(journalScope) == nil else { return 0 }
        let hasOldTables = try connection.scalarInteger(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sync_changes'"
        ) == 1
        var captured = 0
        if hasOldTables {
            let reader = SeedRowReader(connection: connection, registry: registry, fallbackTime: now.timeIntervalSinceReferenceDate)
            try connection.executeScript("BEGIN IMMEDIATE")
            do {
                for table in SeedTable.tables(in: registry) {
                    guard let merged = registry.merged(table.name), let link = try reader.pendingLink(for: table) else { continue }
                    try connection.execute("""
                        INSERT INTO ck_outbox_fields (source_table, local_key, column, dirty_at)
                        SELECT ?, \(OutboxTriggerSQL.localKey(merged.localKey, "t")), '__row', c.changed_at FROM \(OutboxTriggerSQL.quoted(table.name)) AS t
                        JOIN sync_changes c ON c.entity_type = \(OutboxTriggerSQL.literal(link.entity)) AND c.logical_key = t.\(OutboxTriggerSQL.quoted(link.column))
                            AND c.operation = 'save'
                        WHERE true ON CONFLICT(source_table, local_key, column) DO NOTHING
                    """, [.text(table.name)])
                    captured += connection.changedRowCount
                }
                try connection.executeScript("COMMIT")
            } catch {
                try? connection.executeScript("ROLLBACK")
                throw error
            }
        }
        try replica.setEngineState(journalScope, Data("\(now.timeIntervalSinceReferenceDate)".utf8), now: now)
        return captured
    }
}

extension SeedRowReader {
    /// The old record a table's row belongs to, as `sync_changes` names it: the entity and the column that
    /// holds its logical key. Nil for a table no old record owns.
    func pendingLink(for table: SeedTable) throws -> (entity: String, column: String)? {
        try oldRecord(of: table)
    }
}
