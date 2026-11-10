import Foundation
import SQLite3

/// `meeting_action_items` (schema 113): what each meeting session's
/// transcript asked someone to do, keyed to the session and its series. The
/// rows ride the series' `MeetingGroup` record beside its artifacts; inbound
/// they union by id with `done_at` kept once set (planner-design.md, "A
/// meeting series on the clock").
extension KnowledgeStore {

    private static let actionItemColumns = "id, group_id, source_id, position, text, owner, due_hint, done_at, created_at, updated_at"

    private func actionItem(from stmt: OpaquePointer?) -> MeetingActionItem? {
        guard let id = string(stmt, 0), let groupID = string(stmt, 1), let sourceID = string(stmt, 2), let text = string(stmt, 4) else { return nil }
        var item = MeetingActionItem(
            groupID: groupID,
            sourceID: sourceID,
            position: Int(sqlite3_column_int(stmt, 3)),
            text: text,
            owner: string(stmt, 5),
            dueHint: string(stmt, 6),
            doneAt: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7)),
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 9))
        )
        // The stored id is the truth even if the app's rule ever changes.
        if item.id != id { item = MeetingActionItem(groupID: groupID, sourceID: sourceID, position: item.position, text: text, owner: item.owner, dueHint: item.dueHint, doneAt: item.doneAt, createdAt: item.createdAt, updatedAt: item.updatedAt) }
        return item
    }

    /// Every item of a series, session by session in the order it was
    /// extracted; or one session's items.
    func loadMeetingActionItems(groupID: String? = nil, sourceID: String? = nil) throws -> [MeetingActionItem] {
        var clauses: [String] = []
        var params: [String] = []
        if let groupID { clauses.append("group_id = ?"); params.append(groupID) }
        if let sourceID { clauses.append("source_id = ?"); params.append(sourceID) }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        var items: [MeetingActionItem] = []
        try queryBind("""
            SELECT \(Self.actionItemColumns)
            FROM meeting_action_items
            \(whereClause)
            ORDER BY created_at, source_id, position
        """, bind: { stmt in
            for (index, param) in params.enumerated() { bind(stmt, index + 1, param) }
        }) { stmt in
            if let item = actionItem(from: stmt) { items.append(item) }
        }
        return items
    }

    func loadMeetingActionItem(_ id: String) throws -> MeetingActionItem? {
        var found: MeetingActionItem?
        try queryBind("SELECT \(Self.actionItemColumns) FROM meeting_action_items WHERE id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            found = actionItem(from: stmt)
        }
        return found
    }

    /// Whether a session's transcript has been read for action items. An
    /// empty transcript records nothing, so the extractor also keeps its own
    /// per-launch memory; this is the durable half.
    func hasMeetingActionItems(sourceID: String) throws -> Bool {
        var count = 0
        try queryBind("SELECT COUNT(*) FROM meeting_action_items WHERE source_id = ?", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count > 0
    }

    private func upsertActionItem(_ item: MeetingActionItem) throws {
        try execBind("""
            INSERT INTO meeting_action_items (\(Self.actionItemColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                group_id = excluded.group_id,
                position = excluded.position,
                text = excluded.text,
                owner = excluded.owner,
                due_hint = excluded.due_hint,
                done_at = COALESCE(meeting_action_items.done_at, excluded.done_at),
                updated_at = MAX(meeting_action_items.updated_at, excluded.updated_at)
        """) { stmt in
            bind(stmt, 1, item.id)
            bind(stmt, 2, item.groupID)
            bind(stmt, 3, item.sourceID)
            sqlite3_bind_int(stmt, 4, Int32(item.position))
            bind(stmt, 5, item.text)
            bind(stmt, 6, item.owner)
            bind(stmt, 7, item.dueHint)
            if let doneAt = item.doneAt { sqlite3_bind_double(stmt, 8, doneAt.timeIntervalSinceReferenceDate) } else { sqlite3_bind_null(stmt, 8) }
            sqlite3_bind_double(stmt, 9, item.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 10, item.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    /// The extractor's write: one session's items, replacing whatever an
    /// earlier read of the same session produced, then the series' record
    /// is queued for sync.
    func saveMeetingActionItems(_ items: [MeetingActionItem], groupID: String, sourceID: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM meeting_action_items WHERE source_id = ?") { stmt in
                bind(stmt, 1, sourceID)
            }
            for item in items where item.sourceID == sourceID {
                try upsertActionItem(item)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The learner's tick. Done is set once and stays set; `done: false` is
    /// honoured locally so a slip can be undone before it syncs, and the
    /// union rule means it only sticks while no other copy has the tick.
    @discardableResult
    func setMeetingActionItemDone(_ id: String, done: Bool, at now: Date = Date()) throws -> MeetingActionItem {
        guard var item = try loadMeetingActionItem(id) else {
            throw KnowledgeStoreError.invalidData("Action item not found: \(id)")
        }
        item.doneAt = done ? (item.doneAt ?? now) : nil
        item.updatedAt = now
        try execBind("UPDATE meeting_action_items SET done_at = ?, updated_at = ? WHERE id = ?") { stmt in
            if let doneAt = item.doneAt { sqlite3_bind_double(stmt, 1, doneAt.timeIntervalSinceReferenceDate) } else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
            bind(stmt, 3, id)
        }
        return item
    }

    func deleteMeetingActionItems(groupID: String) throws {
        try execBind("DELETE FROM meeting_action_items WHERE group_id = ?") { stmt in
            bind(stmt, 1, groupID)
        }
    }
}
