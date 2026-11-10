import Foundation
import SQLite3

/// Time spent on the day's memory review, one row per device per day
/// (`memory_review_activity`, schema 91), summed by `MemoryReviewProgress`
/// into today's progress and the streak. See docs/memory-design.md, "The
/// daily goal and the streak".
extension KnowledgeStore {

    static let memoryReviewActivityColumns = "id, day, device_id, active_seconds, goal_seconds, updated_at"

    // MARK: - Reading

    func loadMemoryReviewActivities() throws -> [MemoryReviewActivity] {
        var rows: [MemoryReviewActivity] = []
        try query("""
            SELECT \(Self.memoryReviewActivityColumns)
            FROM memory_review_activity
            ORDER BY day, device_id
        """) { stmt in
            if let row = self.memoryReviewActivity(from: stmt) { rows.append(row) }
        }
        return rows
    }

    /// The days whose memory review chat holds an answer from the learner —
    /// the day keys `MemoryReviewSession.sessionID(for:)` names. The history
    /// grid colours a day from this when it has no activity row: a chat the
    /// morning preparation made and nobody sat is one exchange with an empty
    /// answer, and is not here.
    func answeredMemoryReviewDays() throws -> Set<String> {
        var days: Set<String> = []
        try queryBind("""
            SELECT DISTINCT session_id
            FROM review_exchanges
            WHERE session_id LIKE ?
              AND TRIM(COALESCE(user_answer, '')) <> ''
        """, bind: { stmt in
            bind(stmt, 1, MemoryReviewSession.idPrefix + "%")
        }) { stmt in
            if let id = self.string(stmt, 0), let day = MemoryReviewSession.dayKey(fromSessionID: id) {
                days.insert(day)
            }
        }
        return days
    }

    func loadMemoryReviewActivity(_ id: String) throws -> MemoryReviewActivity? {
        var row: MemoryReviewActivity?
        try queryBind("""
            SELECT \(Self.memoryReviewActivityColumns)
            FROM memory_review_activity
            WHERE id = ?
            LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, id)
        }) { stmt in
            row = self.memoryReviewActivity(from: stmt)
        }
        return row
    }

    private func memoryReviewActivity(from stmt: OpaquePointer?) -> MemoryReviewActivity? {
        guard let day = string(stmt, 1), let deviceID = string(stmt, 2) else { return nil }
        return MemoryReviewActivity(
            day: day,
            deviceID: deviceID,
            activeSeconds: sqlite3_column_double(stmt, 3),
            goalSeconds: sqlite3_column_double(stmt, 4),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5))
        )
    }

    // MARK: - Writing

    /// This device's row for the day, replaced whole. The caller holds the
    /// running total, so a write is the total so far, never an increment —
    /// replaying the same write is harmless.
    func recordMemoryReviewActivity(_ activity: MemoryReviewActivity) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try upsertMemoryReviewActivityRow(activity)
            noteStoreChanged()
            // Generation 2: the clock in this Mac's own activity log (§3.5.24).
            try recordOwnReviewActivity(activity)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func upsertMemoryReviewActivityRow(_ activity: MemoryReviewActivity) throws {
        try execBind("""
            INSERT INTO memory_review_activity (\(Self.memoryReviewActivityColumns))
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                day = excluded.day,
                device_id = excluded.device_id,
                active_seconds = excluded.active_seconds,
                goal_seconds = excluded.goal_seconds,
                updated_at = excluded.updated_at
        """) { stmt in
            bind(stmt, 1, activity.id)
            bind(stmt, 2, activity.day)
            bind(stmt, 3, activity.deviceID)
            sqlite3_bind_double(stmt, 4, activity.activeSeconds)
            sqlite3_bind_double(stmt, 5, activity.goalSeconds)
            sqlite3_bind_double(stmt, 6, activity.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    // MARK: - Sync

}
