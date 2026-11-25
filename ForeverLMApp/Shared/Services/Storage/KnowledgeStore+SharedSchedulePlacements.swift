// KnowledgeStore: shared Schedule placements and source activity days.
import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - Shared Schedule Placements

    /// A source's calendar placement (one per source). nil if the source is not scheduled.
    func scheduledSourceID(forSource sourceID: String) throws -> String? {
        var id: String?
        let keys = try personalStateSourceKeys(sourceID)
        try queryBind("SELECT id FROM scheduled_sources WHERE source_id IN (\(Array(repeating: "?", count: keys.count).joined(separator: ", "))) LIMIT 1", bind: { stmt in
            for (offset, key) in keys.enumerated() { bind(stmt, offset + 1, key) }
        }) { stmt in
            id = self.string(stmt, 0)
        }
        return id
    }

    func scheduledSourceGoalCount(placementID: String) throws -> Int {
        var count = 0
        try queryBind("SELECT COUNT(*) FROM scheduled_source_goals WHERE scheduled_source_id = ?", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    /// Every Goal and Notebook a source's placement is tagged with.
    func scheduledSourceGoalIDs(sourceID: String) throws -> [String] {
        guard let placementID = try scheduledSourceID(forSource: sourceID) else { return [] }
        var ids: [String] = []
        try queryBind("SELECT goal_id FROM scheduled_source_goals WHERE scheduled_source_id = ? ORDER BY added_at ASC", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            if let goalID = self.string(stmt, 0) { ids.append(goalID) }
        }
        return ids
    }

    /// Next free order-offset for a placement landing on `day`, so same-day placements stay distinct.
    func nextScheduledSourceOrder(day: Date, excludingSourceID sourceID: String) throws -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(MemoryTutorScheduler.secondsPerDay)
        var existing: [Date] = []
        try queryBind("""
            SELECT planned_at FROM scheduled_sources
            WHERE source_id != ? AND planned_at >= ? AND planned_at < ?
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_double(stmt, 2, dayStart.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 3, dayEnd.timeIntervalSinceReferenceDate)
        }) { stmt in
            existing.append(Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0)))
        }
        guard let maxOffset = existing.map({ Int($0.timeIntervalSince(dayStart).rounded(.down)) }).max() else { return 0 }
        return min(maxOffset + 1, 86_399)
    }

    /// Create the placement row for a source if it does not exist yet. Returns its id.
    /// Does not emit sync changes — callers do, after COMMIT.
    func ensureScheduledSourcePlacement(sourceID: String, plannedAt: Date, now: Date) throws -> String {
        if let existing = try scheduledSourceID(forSource: sourceID) { return existing }
        // Generation 2: the row is the Placement record's, `pl:<source wire id>` on the wire id
        // (§3.5.21), so every Mac and copy names one placement per work.
        let key = try personalStateSourceKey(sourceID)
        let id = SyncIdentity.placementID(sourceID: key)
        try insertScheduledSourcePlacement(id: id, sourceID: key, plannedAt: plannedAt, now: now)
        return id
    }

    private func insertScheduledSourcePlacement(id: String, sourceID: String, plannedAt: Date, now: Date) throws {
        let plannedDay = Calendar.current.startOfDay(for: plannedAt)
        let order = try nextScheduledSourceOrder(day: plannedDay, excludingSourceID: sourceID)
        let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
        try execBind("""
            INSERT INTO scheduled_sources (id, source_id, planned_at, added_at, completed_at, created_at, updated_at)
            VALUES (?, ?, ?, ?, NULL, ?, ?)
        """) { stmt in
            bind(stmt, 1, id)
            bind(stmt, 2, sourceID)
            sqlite3_bind_double(stmt, 3, encoded.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 5, now.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 6, now.timeIntervalSinceReferenceDate)
        }
    }

    func sourceActivityMask(_ kinds: Set<SourceActivityKind>) -> Int64 {
        kinds.reduce(into: Int64(0)) { mask, kind in
            guard let index = SourceActivityKind.allCases.firstIndex(of: kind) else { return }
            mask |= Int64(1) << Int64(index)
        }
    }

    private func sourceActivityKinds(mask: Int64) -> Set<SourceActivityKind> {
        Set(SourceActivityKind.allCases.enumerated().compactMap { index, kind in
            (mask & (Int64(1) << Int64(index))) == 0 ? nil : kind
        })
    }

    func readSourceActivityDay(_ stmt: OpaquePointer?) -> SourceActivityDay? {
        guard let id = string(stmt, 0), let sourceID = string(stmt, 1) else { return nil }
        return SourceActivityDay(
            id: id,
            sourceID: sourceID,
            dayStart: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
            firstActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            lastActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
            kinds: sourceActivityKinds(mask: sqlite3_column_int64(stmt, 5)),
            completedKinds: sourceActivityKinds(mask: sqlite3_column_int64(stmt, 6)),
            maxFraction: SourceActivityDay.clampFraction(sqlite3_column_double(stmt, 7)),
            engagedSeconds: SourceActivityDay.clampSeconds(sqlite3_column_double(stmt, 8))
        )
    }

    /// The learner's consumption history, newest day first: what was read,
    /// listened to, watched, discussed, or reviewed on each day, joined to the
    /// source it happened on.
    ///
    /// Reads `source_activity_days` directly rather than going through
    /// placements: every activity row belongs here regardless of whether the
    /// source was ever planned, and a plan with no activity is not history.
    /// Archived and hidden sources keep their rows — the day still happened.
    /// `since` keeps to days starting at or after it (the History pane reads
    /// the same window of days as the log it lays these beside).
    func loadSourceConsumptionHistory(limit: Int = 500, since: Date? = nil) throws -> [SourceConsumptionEntry] {
        var rows: [SourceConsumptionEntry] = []
        let boundedLimit = min(max(limit, 1), 5_000)
        try queryBind("""
            SELECT sad.id, sad.source_id, sad.day_start, sad.first_activity_at, sad.last_activity_at,
                   sad.kinds, sad.completed_kinds, sad.max_fraction,
                   sp.title, sp.source_type, sp.domain,
                   COALESCE(sp.parent_group_title, sp.parent_group) AS group_title,
                   sp.status, sad.engaged_seconds
            FROM source_activity_days sad
            LEFT JOIN source_projection sp ON sp.id = sad.source_id
            WHERE sad.day_start >= ?
            ORDER BY sad.day_start DESC, sad.last_activity_at DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, since?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude)
            sqlite3_bind_int(stmt, 2, Int32(boundedLimit))
        }) { stmt in
            guard let id = self.string(stmt, 0), let sourceID = self.string(stmt, 1) else { return }
            rows.append(
                SourceConsumptionEntry(
                    id: id,
                    sourceID: sourceID,
                    dayStart: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
                    firstActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
                    lastActivityAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4)),
                    kinds: self.sourceActivityKinds(mask: sqlite3_column_int64(stmt, 5)),
                    completedKinds: self.sourceActivityKinds(mask: sqlite3_column_int64(stmt, 6)),
                    maxFraction: SourceActivityDay.clampFraction(sqlite3_column_double(stmt, 7)),
                    title: self.string(stmt, 8),
                    sourceType: self.string(stmt, 9),
                    domain: self.string(stmt, 10),
                    groupTitle: self.string(stmt, 11),
                    isArchived: self.string(stmt, 12) == "archived",
                    engagedSeconds: SourceActivityDay.clampSeconds(sqlite3_column_double(stmt, 13))
                )
            )
        }
        return rows
    }

    /// The sources the learner spent real time with since `since`, newest
    /// first: what "Read next" measures the rest of the library against.
    /// A source whose days add up to less than a glance
    /// (`DayPlan.activityGlanceMinutes`) is left out unless something on it
    /// was finished, so a paper opened and closed does not steer the picks.
    /// Rows from before schema 94 carry no measured seconds; their activity
    /// span stands in, as it does on the History pane.
    func recentReadingSourceIDs(since: Date, limit: Int) throws -> [String] {
        var ids: [String] = []
        try queryBind("""
            SELECT source_id
            FROM source_activity_days
            WHERE day_start >= ?
            GROUP BY source_id
            HAVING SUM(CASE WHEN engaged_seconds > 0 THEN engaged_seconds
                            ELSE MAX(0, last_activity_at - first_activity_at) END) >= ?
                OR MAX(completed_kinds) > 0
            ORDER BY MAX(last_activity_at) DESC
            LIMIT ?
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, since.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, Double(DayPlan.activityGlanceMinutes * 60))
            sqlite3_bind_int(stmt, 3, Int32(max(limit, 1)))
        }) { stmt in
            if let id = self.string(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Every source the learner has already been into: any recorded activity
    /// day, a `read_at` stamp, or a consumed mark. "Read next" offers only
    /// sources outside this set.
    func touchedSourceIDs() throws -> Set<String> {
        var ids = Set<String>()
        ids.formUnion(try readOrConsumedSourceIDs())
        try query("SELECT source_id FROM source_activity_days") { stmt in
            if let id = self.string(stmt, 0) { ids.insert(id) }
        }
        return ids
    }

    func loadSourceActivityDays(sourceID: String? = nil) throws -> [SourceActivityDay] {
        var rows: [SourceActivityDay] = []
        if let sourceID {
            try queryBind("""
                SELECT id, source_id, day_start, first_activity_at, last_activity_at,
                       kinds, completed_kinds, max_fraction, engaged_seconds
                FROM source_activity_days
                WHERE source_id = ?
                ORDER BY day_start ASC
            """, bind: { stmt in
                bind(stmt, 1, sourceID)
            }) { stmt in
                if let row = self.readSourceActivityDay(stmt) { rows.append(row) }
            }
        } else {
            try query("""
                SELECT id, source_id, day_start, first_activity_at, last_activity_at,
                       kinds, completed_kinds, max_fraction, engaged_seconds
                FROM source_activity_days
                ORDER BY day_start ASC
            """) { stmt in
                if let row = self.readSourceActivityDay(stmt) { rows.append(row) }
            }
        }
        return rows
    }

    func sourceActivityDayCount(sourceID: String) throws -> Int {
        var count = 0
        try queryBind("SELECT COUNT(*) FROM source_activity_days WHERE source_id = ?", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    func scheduledSourceHasActivity(placementID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM source_activity_days WHERE scheduled_source_id = ? LIMIT 1", bind: { stmt in
            bind(stmt, 1, placementID)
        }) { _ in found = true }
        return found
    }

    func scheduledSourceIsAutomatic(placementID: String) throws -> Bool {
        var automatic = false
        try queryBind(
            "SELECT is_automatic FROM scheduled_sources WHERE id = ? LIMIT 1",
            bind: { stmt in bind(stmt, 1, placementID) }
        ) { stmt in
            automatic = sqlite3_column_int(stmt, 0) != 0
        }
        return automatic
    }

    func setScheduledSourceAutomatic(
        placementID: String,
        isAutomatic: Bool
    ) throws {
        try execBind(
            "UPDATE scheduled_sources SET is_automatic = ? WHERE id = ?",
            { stmt in
                sqlite3_bind_int(stmt, 1, isAutomatic ? 1 : 0)
                bind(stmt, 2, placementID)
            }
        )
    }

    func convertPlacementToAutomaticHistory(
        placementID: String,
        sourceID: String,
        at changedAt: Date
    ) throws {
        var latestActivityAt: Date?
        try queryBind("""
            SELECT last_activity_at FROM source_activity_days
            WHERE scheduled_source_id = ?
            ORDER BY last_activity_at DESC LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, placementID)
        }) { stmt in
            latestActivityAt = Date(
                timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0)
            )
        }
        guard let latestActivityAt else { return }
        let latestDay = Calendar.current.startOfDay(for: latestActivityAt)
        let order = try nextScheduledSourceOrder(
            day: latestDay,
            excludingSourceID: sourceID
        )
        let plannedAt = learningGoalItemPlannedDate(latestDay, order: order)
        try execBind("""
            UPDATE scheduled_sources
            SET planned_at = ?, updated_at = ?, is_automatic = 1
            WHERE id = ?
        """) { stmt in
            sqlite3_bind_double(stmt, 1, plannedAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, changedAt.timeIntervalSinceReferenceDate)
            bind(stmt, 3, placementID)
        }
    }

    @discardableResult
    func recordSourceActivityDayRows(
        placementID: String,
        sourceID: String,
        kind: SourceActivityKind,
        occurredAt: Date,
        completed: Bool,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) throws -> Bool {
        let dayStart = Calendar.current.startOfDay(for: occurredAt)
        let portableSourceKey = try portableMemorySourceKey(sourceID: sourceID)
        let activityID = MemoryTutorIdentity.sourceActivityDayID(
            portableSourceKey: portableSourceKey,
            dayStart: dayStart
        )
        // Another copy of the work (a team copy) may hold the day's id; the day's row becomes this copy's.
        try adoptSourceActivityDayRow(id: activityID, sourceID: sourceID, dayStart: dayStart.timeIntervalSinceReferenceDate)
        var existed = false
        try queryBind("""
            SELECT 1 FROM source_activity_days
            WHERE source_id = ? AND day_start = ? LIMIT 1
        """, bind: { stmt in
            bind(stmt, 1, sourceID)
            sqlite3_bind_double(stmt, 2, dayStart.timeIntervalSinceReferenceDate)
        }) { _ in existed = true }
        let kindMask = sourceActivityMask([kind])
        let completedMask = completed ? kindMask : 0
        // Engaged seconds accrue: each heartbeat or playback tick adds its
        // slice to the day's total. The cross-device merge in
        // `replaceSourceActivityDays` takes MAX instead, so a synced total is
        // never added to itself.
        try execBind("""
            INSERT INTO source_activity_days (
                id, scheduled_source_id, source_id, day_start,
                first_activity_at, last_activity_at, kinds, completed_kinds, max_fraction,
                engaged_seconds
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_id, day_start) DO UPDATE SET
                scheduled_source_id = excluded.scheduled_source_id,
                first_activity_at = MIN(source_activity_days.first_activity_at, excluded.first_activity_at),
                last_activity_at = MAX(source_activity_days.last_activity_at, excluded.last_activity_at),
                kinds = source_activity_days.kinds | excluded.kinds,
                completed_kinds = source_activity_days.completed_kinds | excluded.completed_kinds,
                max_fraction = MAX(source_activity_days.max_fraction, excluded.max_fraction),
                engaged_seconds = MIN(86400, source_activity_days.engaged_seconds + excluded.engaged_seconds)
        """) { stmt in
            bind(stmt, 1, activityID)
            bind(stmt, 2, placementID)
            bind(stmt, 3, sourceID)
            sqlite3_bind_double(stmt, 4, dayStart.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 5, occurredAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 6, occurredAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_int64(stmt, 7, kindMask)
            sqlite3_bind_int64(stmt, 8, completedMask)
            sqlite3_bind_double(stmt, 9, SourceActivityDay.clampFraction(fraction ?? 0))
            sqlite3_bind_double(stmt, 10, SourceActivityDay.clampSeconds(engagedSeconds))
        }
        // Generation 2: the same slice in this Mac's own activity log (§3.5.24).
        try recordOwnSourceActivity(
            sourceID: sourceID, kind: kind, completed: completed, fraction: fraction, engagedSeconds: engagedSeconds, at: occurredAt
        )
        return !existed
    }

    /// Put learner activity on the calendar without requiring a manual plan. A
    /// source keeps its explicit goal-backed plan, while its per-day activity is
    /// recorded independently. A placement created only by automatic activity
    /// follows the most recent activity day so the main Schedule opens on what
    /// the learner is actually doing now.
    @discardableResult
    func recordScheduledSourceActivity(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) throws -> Bool {
        let now = Date()
        try exec("BEGIN IMMEDIATE")
        do {
            let inserted = try recordScheduledSourceActivityRows(
                sourceID: sourceID,
                on: day,
                kind: kind,
                recordedAt: now,
                fraction: fraction,
                engagedSeconds: engagedSeconds
            )
            try exec("COMMIT")
            return inserted
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Transaction-free form used when creating a review session and its
    /// initial calendar entries must either all commit or all roll back.
    @discardableResult
    func recordScheduledSourceActivityRows(
        sourceID: String,
        on day: Date,
        kind: SourceActivityKind,
        recordedAt: Date,
        fraction: Double? = nil,
        engagedSeconds: Double = 0
    ) throws -> Bool {
        let existingPlacementID = try scheduledSourceID(forSource: sourceID)
        let placementID = try ensureScheduledSourcePlacement(
            sourceID: sourceID,
            plannedAt: day,
            now: recordedAt
        )
        if existingPlacementID == nil {
            try setScheduledSourceAutomatic(placementID: placementID, isAutomatic: true)
        }
        let inserted = try recordSourceActivityDayRows(
            placementID: placementID,
            sourceID: sourceID,
            kind: kind,
            occurredAt: day,
            completed: false,
            fraction: fraction,
            engagedSeconds: engagedSeconds
        )
        // An automatic entry follows the most recent activity day. A play
        // recorded after the fact (Apple Podcasts' history) can be older than
        // a day already logged, and then leaves the entry where it is.
        let plannedDay = Calendar.current.startOfDay(for: day)
        let latestDay = try latestSourceActivityDayStart(sourceID: sourceID) ?? plannedDay
        if try scheduledSourceIsAutomatic(placementID: placementID), latestDay <= plannedDay {
            let order = try nextScheduledSourceOrder(day: plannedDay, excludingSourceID: sourceID)
            let encoded = learningGoalItemPlannedDate(plannedDay, order: order)
            try execBind("UPDATE scheduled_sources SET planned_at = ?, updated_at = ? WHERE id = ?") { stmt in
                sqlite3_bind_double(stmt, 1, encoded.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(stmt, 2, recordedAt.timeIntervalSinceReferenceDate)
                bind(stmt, 3, placementID)
            }
        }
        return inserted
    }

    /// The start of the latest day `sourceID` has activity on, if any.
    private func latestSourceActivityDayStart(sourceID: String) throws -> Date? {
        var latest: Date?
        try queryBind("SELECT MAX(day_start) FROM source_activity_days WHERE source_id = ?", bind: { stmt in
            bind(stmt, 1, sourceID)
        }) { stmt in
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
            latest = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
        }
        return latest
    }

}
