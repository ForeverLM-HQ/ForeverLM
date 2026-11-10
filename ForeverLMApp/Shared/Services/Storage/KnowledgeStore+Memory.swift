import Foundation
import SQLite3

extension KnowledgeStore {

    // MARK: - Memory items

    func saveMemoryItem(_ item: MemoryItem) throws {
        try validateMemoryItem(item)
        try exec("BEGIN IMMEDIATE")
        do {
            try upsertMemoryItemRows(item)
            try rebuildMemorySchedule(memoryItemID: item.id)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Saves `item` only when no item has its id, and records `attempt` (its
    /// first attempt, when given) on whichever item holds the id, all in one
    /// transaction: an item made with its first answer is never left without
    /// it, and an item already stored is never overwritten (a card kept twice,
    /// on two Macs). Both are checked before anything is written. Returns the
    /// item already stored, unchanged, or nil when `item` was saved.
    @discardableResult
    func saveMemoryItemIfAbsent(_ item: MemoryItem, recording attempt: MemoryAttempt? = nil) throws -> MemoryItem? {
        try validateMemoryItem(item)
        if let attempt {
            try validateMemoryAttempt(attempt)
            guard attempt.memoryItemID == item.id else {
                throw KnowledgeStoreError.invalidData(
                    "Memory attempt \(attempt.id) answers \(attempt.memoryItemID), not the item \(item.id) it is saved with."
                )
            }
        }
        try exec("BEGIN IMMEDIATE")
        do {
            let existing = try loadMemoryItem(item.id)
            var changed = false
            if existing == nil {
                try upsertMemoryItemRows(item)
                changed = true
            }
            if let attempt, try insertMemoryAttemptIfNew(attempt) {
                changed = true
            }
            if changed {
                try rebuildMemorySchedule(memoryItemID: item.id)
            }
            try exec("COMMIT")
            return existing
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Saves `item` and retires `retiredID` in one transaction, so an item
    /// replaced by a new one (a card started over,
    /// `KnowledgeStore.startMemoryCardOver`) never leaves both active, or
    /// neither. Retiring is the one change an item takes after it is made:
    /// status is outside its curriculum fingerprint.
    func saveMemoryItem(_ item: MemoryItem, retiring retiredID: String, at retiredAt: Date) throws {
        try validateMemoryItem(item)
        guard item.id != retiredID else {
            throw KnowledgeStoreError.invalidData("Memory item \(item.id) cannot replace itself.")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE memory_items
                SET status = ?, updated_at = ?
                WHERE id = ? AND status <> ?
            """) { statement in
                bind(statement, 1, MemoryItemStatus.retired.rawValue)
                sqlite3_bind_double(statement, 2, retiredAt.timeIntervalSinceReferenceDate)
                bind(statement, 3, retiredID)
                bind(statement, 4, MemoryItemStatus.retired.rawValue)
            }
            try upsertMemoryItemRows(item)
            try rebuildMemorySchedule(memoryItemID: item.id)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadMemoryItem(_ id: String) throws -> MemoryItem? {
        var stored: (
            kind: MemoryItemKind,
            target: String,
            rubricJSON: String,
            learnerContext: String?,
            goalID: String?,
            status: MemoryItemStatus,
            createdAt: Date,
            updatedAt: Date,
            ideaID: String?
        )?

        try queryBind("""
            SELECT kind, target, rubric_json, learner_context, goal_id, status, created_at, updated_at, idea_id
            FROM memory_items
            WHERE id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, id)
        }) { statement in
            guard
                let kindRaw = self.string(statement, 0),
                let kind = MemoryItemKind(rawValue: kindRaw),
                let target = self.string(statement, 1),
                let rubricJSON = self.string(statement, 2),
                let statusRaw = self.string(statement, 5),
                let status = MemoryItemStatus(rawValue: statusRaw)
            else {
                throw KnowledgeStoreError.invalidData("Memory item \(id) contains an unsupported kind or status.")
            }
            stored = (
                kind,
                target,
                rubricJSON,
                self.string(statement, 3),
                self.string(statement, 4),
                status,
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 7)),
                self.string(statement, 8)
            )
        }

        guard let stored else { return nil }
        return MemoryItem(
            id: id,
            kind: stored.kind,
            target: stored.target,
            rubricJSON: stored.rubricJSON,
            learnerContext: stored.learnerContext,
            goalID: stored.goalID,
            status: stored.status,
            sources: try loadMemoryItemSources(memoryItemID: id),
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            ideaID: stored.ideaID
        )
    }

    func loadMemoryItems(
        status: MemoryItemStatus? = nil,
        goalID: String? = nil
    ) throws -> [MemoryItem] {
        var ids: [String] = []
        try queryBind("""
            SELECT id
            FROM memory_items
            WHERE (? IS NULL OR status = ?)
              AND (? IS NULL OR goal_id = ?)
            ORDER BY updated_at DESC, id
        """, bind: { statement in
            bind(statement, 1, status?.rawValue)
            bind(statement, 2, status?.rawValue)
            bind(statement, 3, goalID)
            bind(statement, 4, goalID)
        }) { statement in
            if let id = self.string(statement, 0) {
                ids.append(id)
            }
        }
        return try ids.compactMap { try loadMemoryItem($0) }
    }

    func loadMemoryItemsForSession(_ sessionID: String) throws -> [MemoryItem] {
        var ids: [String] = []
        try queryBind("""
            SELECT ma.memory_item_id
            FROM memory_attempts ma
            JOIN memory_items mi ON mi.id = ma.memory_item_id
            WHERE ma.session_id = ?
            GROUP BY ma.memory_item_id
            ORDER BY MIN(ma.attempted_at), ma.memory_item_id
        """, bind: { statement in
            bind(statement, 1, sessionID)
        }) { statement in
            if let id = self.string(statement, 0) {
                ids.append(id)
            }
        }
        return try ids.compactMap { try loadMemoryItem($0) }
    }

    func loadAllMemoryItemIDs() throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM memory_items ORDER BY id") { statement in
            if let id = self.string(statement, 0) {
                ids.append(id)
            }
        }
        return ids
    }

    func setMemoryItemStatus(
        id: String,
        status: MemoryItemStatus,
        updatedAt: Date = Date()
    ) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE memory_items
                SET status = ?, updated_at = ?
                WHERE id = ?
            """) { statement in
                bind(statement, 1, status.rawValue)
                sqlite3_bind_double(statement, 2, updatedAt.timeIntervalSinceReferenceDate)
                bind(statement, 3, id)
            }
            var changedRowCount = 0
            try query("SELECT changes()") { statement in
                changedRowCount = Int(sqlite3_column_int64(statement, 0))
            }
            guard changedRowCount == 1 else {
                throw KnowledgeStoreError.invalidData("Memory item \(id) does not exist.")
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// User-facing deletion removes the aggregate and its attempts.
    func deleteMemoryItem(_ id: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM memory_items WHERE id = ?") { statement in
                bind(statement, 1, id)
            }
            try execBind("DELETE FROM memory_attempts WHERE memory_item_id = ?") { statement in
                bind(statement, 1, id)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Immutable attempts

    /// Inserts an immutable attempt. An identical replay is idempotent; reusing an
    /// ID for different content fails loudly instead of rewriting learning history.
    @discardableResult
    func recordMemoryAttempt(_ attempt: MemoryAttempt) throws -> Bool {
        try validateMemoryAttempt(attempt)
        try exec("BEGIN IMMEDIATE")
        do {
            let inserted = try insertMemoryAttemptIfNew(attempt)
            if inserted {
                try rebuildMemorySchedule(memoryItemID: attempt.memoryItemID)
            }
            try exec("COMMIT")
            return inserted
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func loadMemoryAttempt(_ id: String) throws -> MemoryAttempt? {
        var attempt: MemoryAttempt?
        try queryBind("""
            SELECT memory_item_id, session_id, exchange_id, attempt_type, prompt,
                   learner_answer, feedback, score, schedule_rating, grade_state,
                   grading_error, evidence_json, attempted_at, model_provider,
                   model_id, model_metadata_json
            FROM memory_attempts
            WHERE id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, id)
        }) { statement in
            guard
                let memoryItemID = self.string(statement, 0),
                let attemptTypeRaw = self.string(statement, 3),
                let attemptType = MemoryAttemptType(rawValue: attemptTypeRaw),
                let prompt = self.string(statement, 4),
                let learnerAnswer = self.string(statement, 5),
                let gradeStateRaw = self.string(statement, 9),
                let gradeState = MemoryGradeState(rawValue: gradeStateRaw)
            else {
                throw KnowledgeStoreError.invalidData("Memory attempt \(id) contains an unsupported type or grade state.")
            }
            let rating: MemoryScheduleRating?
            if let raw = self.string(statement, 8) {
                guard let decoded = MemoryScheduleRating(rawValue: raw) else {
                    throw KnowledgeStoreError.invalidData("Memory attempt \(id) contains an unsupported schedule rating.")
                }
                rating = decoded
            } else {
                rating = nil
            }
            attempt = MemoryAttempt(
                id: id,
                memoryItemID: memoryItemID,
                sessionID: self.string(statement, 1),
                exchangeID: self.string(statement, 2),
                attemptType: attemptType,
                prompt: prompt,
                learnerAnswer: learnerAnswer,
                feedback: self.string(statement, 6),
                score: self.optionalDouble(statement, 7),
                scheduleRating: rating,
                gradeState: gradeState,
                gradingError: self.string(statement, 10),
                evidenceJSON: self.string(statement, 11),
                attemptedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 12)),
                modelProvider: self.string(statement, 13),
                modelID: self.string(statement, 14),
                modelMetadataJSON: self.string(statement, 15)
            )
        }
        return attempt
    }

    func loadMemoryAttempts(
        memoryItemID: String? = nil,
        sessionID: String? = nil
    ) throws -> [MemoryAttempt] {
        var ids: [String] = []
        try queryBind("""
            SELECT id
            FROM memory_attempts
            WHERE (? IS NULL OR memory_item_id = ?)
              AND (? IS NULL OR session_id = ?)
            ORDER BY attempted_at, id
        """, bind: { statement in
            bind(statement, 1, memoryItemID)
            bind(statement, 2, memoryItemID)
            bind(statement, 3, sessionID)
            bind(statement, 4, sessionID)
        }) { statement in
            if let id = self.string(statement, 0) {
                ids.append(id)
            }
        }
        return try ids.compactMap { try loadMemoryAttempt($0) }
    }

    private func memoryAttemptItemID(id: String) throws -> String? {
        var memoryItemID: String?
        try queryBind(
            "SELECT memory_item_id FROM memory_attempts WHERE id = ? LIMIT 1",
            bind: { statement in bind(statement, 1, id) }
        ) { statement in
            memoryItemID = self.string(statement, 0)
        }
        return memoryItemID
    }

    /// Sources for concepts the learner actually attempted in one session. This
    /// deliberately ignores the session's broader launch queue: a learner may
    /// stop after the first prompt, and untouched concepts must remain due.
    func reviewedMemorySourceIDs(sessionID: String) throws -> [String] {
        var sourceIDs: [String] = []
        try queryBind("""
            SELECT DISTINCT mis.source_id
            FROM memory_attempts ma INDEXED BY idx_memory_attempts_session
            JOIN memory_item_sources mis ON mis.memory_item_id = ma.memory_item_id
            WHERE ma.session_id = ?
              AND ma.grade_state = 'graded'
            ORDER BY mis.source_id
        """, bind: { statement in
            bind(statement, 1, sessionID)
        }) { statement in
            if let sourceID = self.string(statement, 0) {
                sourceIDs.append(sourceID)
            }
        }
        return sourceIDs
    }

    func memoryStruggleProjection(
        memoryItemID: String,
        limit: Int = 3
    ) throws -> MemoryStruggleProjection? {
        guard let item = try loadMemoryItem(memoryItemID) else { return nil }
        let boundedLimit = Swift.max(0, limit)
        guard boundedLimit > 0 else {
            return MemoryTutorStruggleProjector.project(
                item: item,
                attempts: [],
                limit: 0
            )
        }
        var attemptIDs: [String] = []
        try queryBind("""
            SELECT id
            FROM memory_attempts INDEXED BY idx_memory_attempts_item_date
            WHERE memory_item_id = ?
              AND (
                    grade_state = 'failed'
                 OR (grade_state = 'graded' AND schedule_rating IN ('again', 'hard'))
              )
            ORDER BY attempted_at DESC, id
            LIMIT ?
        """, bind: { statement in
            bind(statement, 1, memoryItemID)
            sqlite3_bind_int64(statement, 2, Int64(boundedLimit))
        }) { statement in
            if let attemptID = self.string(statement, 0) {
                attemptIDs.append(attemptID)
            }
        }
        return MemoryTutorStruggleProjector.project(
            item: item,
            attempts: try attemptIDs.compactMap { try loadMemoryAttempt($0) },
            limit: boundedLimit
        )
    }

    func deleteMemoryAttempt(_ id: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            guard let memoryItemID = try memoryAttemptItemID(id: id) else {
                try exec("COMMIT")
                return
            }
            try execBind("DELETE FROM memory_attempts WHERE id = ?") { statement in
                bind(statement, 1, id)
            }
            try rebuildMemorySchedule(memoryItemID: memoryItemID)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Schedule projection and daily plan

    func loadMemorySchedule(memoryItemID: String) throws -> MemorySchedule? {
        var schedule: MemorySchedule?
        try queryBind("""
            SELECT due_at, last_attempt_at, last_success_at, stability, difficulty,
                   repetition_count, lapse_count, algorithm_version
            FROM memory_schedules
            WHERE memory_item_id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, memoryItemID)
        }) { statement in
            schedule = MemorySchedule(
                memoryItemID: memoryItemID,
                dueAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0)),
                lastAttemptAt: self.optionalDouble(statement, 1).map(Date.init(timeIntervalSinceReferenceDate:)),
                lastSuccessAt: self.optionalDouble(statement, 2).map(Date.init(timeIntervalSinceReferenceDate:)),
                stability: sqlite3_column_double(statement, 3),
                difficulty: sqlite3_column_double(statement, 4),
                repetitionCount: Int(sqlite3_column_int64(statement, 5)),
                lapseCount: Int(sqlite3_column_int64(statement, 6)),
                algorithmVersion: Int(sqlite3_column_int64(statement, 7))
            )
        }
        return schedule
    }

    @discardableResult
    func rebuildMemorySchedule(memoryItemID: String) throws -> MemorySchedule? {
        guard let item = try loadMemoryItem(memoryItemID) else {
            try execBind("DELETE FROM memory_schedules WHERE memory_item_id = ?") { statement in
                bind(statement, 1, memoryItemID)
            }
            return nil
        }
        let schedule = MemoryTutorScheduler.schedule(
            item: item,
            attempts: try loadMemoryAttempts(memoryItemID: memoryItemID)
        )
        try saveMemoryScheduleProjection(schedule)
        return schedule
    }

    /// One batch of `rebuildStaleMemorySchedules`.
    struct MemoryScheduleRebuildBatch: Equatable, Sendable {
        /// Rows brought up to the current scheduler.
        var rebuilt = 0
        /// Items whose row could not be rebuilt (an item this build cannot
        /// read), left as they were for the caller to log. A later launch
        /// tries them again.
        var skippedIDs: [String] = []
        /// Where the next batch starts (`after:`); nil once this batch reached
        /// the last stale row.
        var nextAfterID: String?
    }

    /// Rebuilds the schedule rows an older `MemoryTutorScheduler` wrote, a batch
    /// of `limit` in id order after `afterID`, in one short transaction. Each
    /// rebuilt row carries the current `algorithmVersion`. An item that cannot
    /// be rebuilt is skipped and named, never allowed to roll back the rest of
    /// its batch, and the batch's `nextAfterID` moves past it, so the caller's
    /// loop ends even when such an item stays stale. The caller runs it at
    /// `.utility` after launch (`runDeferredMemoryScheduleRebuild`).
    @discardableResult
    func rebuildStaleMemorySchedules(after afterID: String? = nil, limit: Int) throws -> MemoryScheduleRebuildBatch {
        let limit = max(1, limit)
        var ids: [String] = []
        try queryBind("""
            SELECT memory_item_id
            FROM memory_schedules
            WHERE algorithm_version < ?
              AND (? IS NULL OR memory_item_id > ?)
            ORDER BY memory_item_id
            LIMIT ?
        """, bind: { statement in
            sqlite3_bind_int64(statement, 1, Int64(MemoryTutorScheduler.algorithmVersion))
            bind(statement, 2, afterID)
            bind(statement, 3, afterID)
            sqlite3_bind_int64(statement, 4, Int64(limit))
        }) { statement in
            if let id = self.string(statement, 0) {
                ids.append(id)
            }
        }
        var batch = MemoryScheduleRebuildBatch(nextAfterID: ids.count == limit ? ids.last : nil)
        guard !ids.isEmpty else { return batch }
        try exec("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try exec("SAVEPOINT memory_schedule_rebuild")
                do {
                    try rebuildMemorySchedule(memoryItemID: id)
                    try exec("RELEASE SAVEPOINT memory_schedule_rebuild")
                    batch.rebuilt += 1
                } catch {
                    try exec("ROLLBACK TO SAVEPOINT memory_schedule_rebuild")
                    try exec("RELEASE SAVEPOINT memory_schedule_rebuild")
                    batch.skippedIDs.append(id)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return batch
    }

    /// Today's card review over every item this library may ask: active, outside
    /// any sync conflict, anchored only on sources the library has (within
    /// `restrictToSourceIDs` and the screen-record scope when either applies).
    /// The order, the new-card allowance and the budget are
    /// `MemoryCardQueue.today`'s, the same function the iPhone runs.
    func memoryCardQueueToday(
        now: Date,
        budgetMinutes: Int?,
        newPerDay: Int,
        deadlines: [MemoryCardDeadline],
        restrictToSourceIDs requestedSourceIDs: Set<String>? = nil,
        calendar: Calendar = .current
    ) throws -> MemoryCardQueue.Today {
        let reviewable = try reviewableMemoryItems(restrictToSourceIDs: requestedSourceIDs)
        return MemoryCardQueue.today(
            items: reviewable.items,
            attempts: reviewable.attempts,
            now: now,
            budgetMinutes: budgetMinutes,
            newPerDay: newPerDay,
            deadlines: deadlines,
            calendar: calendar
        )
    }

    /// Every item the card review may ask, with its whole attempt history:
    /// active, outside any sync conflict, and anchored only on sources the
    /// library has (within `restrictToSourceIDs` and the screen-record scope
    /// when either applies), in id order. What `memoryCardQueueToday` and the
    /// card review's snapshot (`memoryCardReviewSnapshot`) both deal from.
    func reviewableMemoryItems(
        restrictToSourceIDs requestedSourceIDs: Set<String>? = nil
    ) throws -> (items: [MemoryItem], attempts: [MemoryAttempt]) {
        let recordingCutoff = screenRecordScope()?.cutoff
        let restrictToSourceIDs = try screenRecordNarrowedMemorySourceIDs(requestedSourceIDs)
        if let restrictToSourceIDs, restrictToSourceIDs.isEmpty { return ([], []) }
        let sourceIDs = restrictToSourceIDs.map { Array($0).sorted() }
        var ids: [String] = []
        try queryBind("""
            SELECT mi.id
            FROM memory_items mi
            WHERE mi.status = 'active'
              \(reviewableMemoryAnchorPredicate(sourceIDs: sourceIDs))
              \(recordingCutoff == nil ? "" : "AND mi.created_at >= ?")
            ORDER BY mi.id
        """, bind: { statement in
            for (index, sourceID) in (sourceIDs ?? []).enumerated() {
                bind(statement, index + 1, sourceID)
            }
            if let recordingCutoff {
                sqlite3_bind_double(statement, Int32((sourceIDs?.count ?? 0) + 1), recordingCutoff.timeIntervalSinceReferenceDate)
            }
        }) { statement in
            if let id = self.string(statement, 0) {
                ids.append(id)
            }
        }
        var items: [MemoryItem] = []
        var attempts: [MemoryAttempt] = []
        for id in ids {
            guard let item = try loadMemoryItem(id) else { continue }
            items.append(item)
            attempts.append(contentsOf: try loadMemoryAttempts(memoryItemID: id))
        }
        return (items, attempts)
    }

    /// Source-level intake must not recreate a deterministic first-review item
    /// for material represented anywhere in the memory graph. Retired items are
    /// included: retirement is an intentional stop signal, not permission to
    /// recreate the same curriculum identity.
    func activeMemoryItemSourceIDs(
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> Set<String> {
        if let restrictToSourceIDs, restrictToSourceIDs.isEmpty { return [] }
        let restricted = restrictToSourceIDs.map { Array($0).sorted() }
        let predicate: String
        if let restricted {
            predicate = "AND mis.source_id IN (\(Array(repeating: "?", count: restricted.count).joined(separator: ",")))"
        } else {
            predicate = ""
        }
        var sourceIDs = Set<String>()
        try queryBind("""
            SELECT DISTINCT mis.source_id
            FROM memory_item_sources mis INDEXED BY idx_memory_item_sources_source
            JOIN memory_items mi ON mi.id = mis.memory_item_id
            WHERE 1 = 1
              \(predicate)
            ORDER BY mis.source_id
        """, bind: { statement in
            guard let restricted else { return }
            for (index, sourceID) in restricted.enumerated() {
                bind(statement, index + 1, sourceID)
            }
        }) { statement in
            if let sourceID = self.string(statement, 0) {
                sourceIDs.insert(sourceID)
            }
        }
        return sourceIDs
    }

    func dueMemoryItems(
        now: Date,
        limit: Int,
        restrictToSourceIDs: Set<String>? = nil
    ) throws -> [DueMemoryItem] {
        try dueMemoryItems(
            now: now,
            limit: limit,
            goalID: nil,
            restrictToSourceIDs: restrictToSourceIDs
        )
    }

    /// Screen record mode (admin only) narrows every memory-review pick —
    /// the in-app Memory review, voice, and the MCP `memory_review` and
    /// `daily_review` alike — to the sources the take may show. With the mode
    /// off this returns `restrictToSourceIDs` unchanged, nil included; with it
    /// on, nil becomes the explicit set of shown sources, so a memory anchored
    /// on a source outside the scope is never picked.
    func screenRecordNarrowedMemorySourceIDs(_ restrictToSourceIDs: Set<String>?) throws -> Set<String>? {
        guard let scope = screenRecordScope() else { return restrictToSourceIDs }
        if let restrictToSourceIDs, restrictToSourceIDs.isEmpty { return [] }
        var shown: Set<String> = []
        try queryBind("""
            SELECT id, date_added, source_type, url, parent_group, domain, discovery_origin
            FROM source_projection
        """, bind: { _ in }) { stmt in
            guard let id = self.string(stmt, 0) else { return }
            if let restrictToSourceIDs, !restrictToSourceIDs.contains(id) { return }
            let addedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            if scope.allowsSource(
                id: id, addedAt: addedAt,
                kind: self.string(stmt, 2), url: self.string(stmt, 3), group: self.string(stmt, 4),
                show: self.string(stmt, 5),
                origin: self.string(stmt, 6).flatMap { DiscoveryOrigin(rawValue: $0) }
            ) {
                shown.insert(id)
            }
        }
        return shown
    }

    /// Items whose interval has run out, struggles first. A new item (no graded
    /// attempt yet) is never due here: the card queue introduces new items under
    /// the day's allowance (`memoryCardQueueToday`).
    func dueMemoryItems(
        now: Date,
        limit: Int,
        goalID: String?,
        restrictToSourceIDs requestedSourceIDs: Set<String>? = nil
    ) throws -> [DueMemoryItem] {
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return [] }
        let recordingCutoff = screenRecordScope()?.cutoff
        let restrictToSourceIDs = try screenRecordNarrowedMemorySourceIDs(requestedSourceIDs)
        if let restrictToSourceIDs, restrictToSourceIDs.isEmpty { return [] }

        let sourceIDs = restrictToSourceIDs.map { Array($0).sorted() }
        let sourcePredicate = reviewableMemoryAnchorPredicate(sourceIDs: sourceIDs)

        var ids: [String] = []
        let sql = """
            SELECT ms.memory_item_id
            FROM memory_schedules ms INDEXED BY idx_memory_schedules_due
            JOIN memory_items mi ON mi.id = ms.memory_item_id
            WHERE ms.due_at <= ?
              AND ms.repetition_count > 0
              AND mi.status = 'active'
              AND (? IS NULL OR mi.goal_id = ?)
              \(sourcePredicate)
              \(recordingCutoff == nil ? "" : "AND mi.created_at >= ?")
            ORDER BY
                CASE WHEN (
                    COALESCE(TRIM(mi.learner_context), '') <> ''
                    OR ms.lapse_count > 0
                    OR ms.difficulty > 0.5
                ) THEN 0 ELSE 1 END,
                ms.due_at,
                ms.memory_item_id
            LIMIT ?
        """
        try queryBind(sql, bind: { statement in
            var index: Int32 = 1
            sqlite3_bind_double(statement, index, now.timeIntervalSinceReferenceDate)
            index += 1
            bind(statement, Int(index), goalID)
            index += 1
            bind(statement, Int(index), goalID)
            index += 1
            if let sourceIDs {
                for sourceID in sourceIDs {
                    bind(statement, Int(index), sourceID)
                    index += 1
                }
            }
            if let recordingCutoff {
                sqlite3_bind_double(statement, index, recordingCutoff.timeIntervalSinceReferenceDate)
                index += 1
            }
            sqlite3_bind_int64(statement, index, Int64(boundedLimit))
        }) { statement in
            if let id = self.string(statement, 0) {
                ids.append(id)
            }
        }

        return try ids.compactMap { id in
            guard
                let item = try loadMemoryItem(id),
                let schedule = try loadMemorySchedule(memoryItemID: id)
            else { return nil }
            let secondsOverdue = max(0, now.timeIntervalSince(schedule.dueAt))
            return DueMemoryItem(
                item: item,
                schedule: schedule,
                daysOverdue: Int(secondsOverdue / MemoryTutorScheduler.secondsPerDay)
            )
        }
    }

    /// The anchor half of every "may this item be asked" query: the item has at
    /// least one anchor, and every anchor names a source the library has, active
    /// and not in a hidden collection, inside `sourceIDs` when given. Binds one
    /// parameter per id in `sourceIDs`, in order.
    private func reviewableMemoryAnchorPredicate(sourceIDs: [String]?) -> String {
        if let sourceIDs {
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ",")
            return """
                AND EXISTS (
                    SELECT 1
                    FROM memory_item_sources anchor_any
                    WHERE anchor_any.memory_item_id = mi.id
                )
                AND NOT EXISTS (
                    SELECT 1
                    FROM memory_item_sources anchor_out_of_scope
                    WHERE anchor_out_of_scope.memory_item_id = mi.id
                      AND anchor_out_of_scope.source_id NOT IN (\(placeholders))
                )
                AND NOT EXISTS (
                    SELECT 1
                    FROM memory_item_sources anchor_unavailable
                    WHERE anchor_unavailable.memory_item_id = mi.id
                      AND NOT EXISTS (
                          SELECT 1
                          FROM source_projection available_source
                          WHERE available_source.id = anchor_unavailable.source_id
                            AND available_source.status = 'active'
                            AND available_source.is_collection_hidden = 0
                      )
                )
            """
        } else {
            return """
                AND EXISTS (
                    SELECT 1
                    FROM memory_item_sources anchor_any
                    WHERE anchor_any.memory_item_id = mi.id
                )
                AND NOT EXISTS (
                    SELECT 1
                    FROM memory_item_sources anchor_missing
                    WHERE anchor_missing.memory_item_id = mi.id
                      AND NOT EXISTS (
                          SELECT 1
                          FROM source_projection available_source
                          WHERE available_source.id = anchor_missing.source_id
                            AND available_source.status = 'active'
                            AND available_source.is_collection_hidden = 0
                      )
                )
            """
        }
    }

    // MARK: - Intake and atomic chat linkage

    func canonicalMemorySourceSnapshot(sourceID: String) throws -> MemorySourceSnapshot {
        guard let content = try loadSourceContent(sourceID),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData(
                "Source \(sourceID) has no canonical text to ground a memory item."
            )
        }
        return MemorySourceSnapshot(
            sourceID: sourceID,
            content: content,
            sourceSHA256: PaperContentPreparationService.sha256(content)
        )
    }

    /// Portable, deterministic identity for source-global first-review intake.
    /// Source IDs can be remapped by CloudKit, so callers must not derive a
    /// curriculum identity from the local ID when DOI/URL identity is present.
    func portableMemorySourceKey(sourceID: String) throws -> String {
        guard let identity = try sourceIdentities(for: [sourceID]).first else {
            throw KnowledgeStoreError.invalidData("Source \(sourceID) does not exist.")
        }
        return MemoryTutorIdentity.portableSourceKey(
            sourceID: sourceID,
            normalizedURL: identity.normalizedURL ?? identity.url.map(URLNormalizer.normalize),
            doi: identity.doi,
            publishedDOI: identity.publishedDOI
        )
    }

    /// Resolves an opaque portable first-review key only within an already
    /// validated/bounded session source relationship. Ambiguity fails closed.
    func resolveMemorySourceID(
        portableSourceKey: String,
        restrictToSourceIDs sourceIDs: [String]
    ) throws -> String? {
        let candidates = try stableMemoryReviewSourceIDs(sourceIDs)
        var matches: [String] = []
        for sourceID in candidates {
            if try portableMemorySourceKey(sourceID: sourceID) == portableSourceKey {
                matches.append(sourceID)
            }
        }
        guard matches.count <= 1 else {
            throw KnowledgeStoreError.invalidData(
                "Portable memory source identity is ambiguous inside this review session."
            )
        }
        return matches.first
    }

    /// Validates excerpt grounding and hashes the complete canonical source while
    /// still on the storage actor. Only the compact proof crosses back to UI code.
    func validatedMemorySourceAnchor(
        sourceID: String,
        excerpt: String
    ) throws -> MemorySourceAnchorValidation {
        let trimmedExcerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExcerpt.isEmpty else {
            throw KnowledgeStoreError.invalidData("A memory source excerpt cannot be empty.")
        }
        guard let content = try loadSourceContent(sourceID),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData(
                "Source \(sourceID) has no canonical text to ground a memory item."
            )
        }
        guard MemoryGroundingText(content).contains(trimmedExcerpt) else {
            throw KnowledgeStoreError.invalidData(
                "The memory excerpt is not present in source \(sourceID)'s canonical text."
            )
        }
        return MemorySourceAnchorValidation(
            sourceID: sourceID,
            excerpt: trimmedExcerpt,
            sourceSHA256: PaperContentPreparationService.sha256(content),
            portableSourceKey: try portableMemorySourceKey(sourceID: sourceID)
        )
    }

    /// Repairs anchors that arrived before their Source record. Portable identity
    /// columns remain beside the anchor until a matching source exists; each source
    /// save invokes this targeted, indexed reconciliation inside its own transaction.
    @discardableResult
    func reconcileMemoryItemSourceAnchors(forSourceID sourceID: String) throws -> Int {
        guard let incoming = try sourceIdentities(for: [sourceID]).first else { return 0 }
        let doiCandidates = dictUnique(
            [incoming.doi, incoming.publishedDOI].compactMap(normalizedMemoryDOI)
        )
        let normalizedURL = cleanIdentityValue(incoming.normalizedURL)
            ?? cleanIdentityValue(incoming.url).map(URLNormalizer.normalize)

        // Keep every lookup as one equality predicate over one explicit index.
        // An OR spanning URL and DOI columns (or LOWER(column)) makes SQLite scan
        // every anchor for every incoming Source, turning initial sync quadratic.
        var candidatesByAnchorID: [String: String] = [:]
        func collectCandidates(sql: String, value: String) throws {
            try queryBind(sql, bind: { statement in
                bind(statement, 1, value)
                bind(statement, 2, sourceID)
            }) { statement in
                guard let anchorID = self.string(statement, 0),
                      let currentSourceID = self.string(statement, 1) else { return }
                candidatesByAnchorID[anchorID] = currentSourceID
            }
        }
        for doi in doiCandidates {
            try collectCandidates(
                sql: """
                    SELECT id, source_id
                    FROM memory_item_sources INDEXED BY idx_memory_item_sources_identity_doi
                    WHERE source_doi = ? AND source_id <> ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = memory_item_sources.source_id
                      )
                """,
                value: doi
            )
            try collectCandidates(
                sql: """
                    SELECT id, source_id
                    FROM memory_item_sources INDEXED BY idx_memory_item_sources_identity_published_doi
                    WHERE source_published_doi = ? AND source_id <> ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = memory_item_sources.source_id
                      )
                """,
                value: doi
            )
        }
        if let normalizedURL {
            try collectCandidates(
                sql: """
                    SELECT id, source_id
                    FROM memory_item_sources INDEXED BY idx_memory_item_sources_identity_url
                    WHERE source_normalized_url = ? AND source_id <> ?
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sources AS exact_source
                          WHERE exact_source.id = memory_item_sources.source_id
                      )
                """,
                value: normalizedURL
            )
        }

        var changed = 0
        for (anchorID, currentSourceID) in candidatesByAnchorID.sorted(by: { $0.key < $1.key }) {
            guard sourceID != currentSourceID else { continue }
            try execBind("""
                UPDATE memory_item_sources
                SET source_id = ?
                WHERE id = ?
            """) { statement in
                bind(statement, 1, sourceID)
                bind(statement, 2, anchorID)
            }
            changed += 1
        }
        return changed
    }

    /// Completes a pending exchange and records the corresponding memory event
    /// in one SQLite transaction. If `item` is supplied, the new/updated item
    /// and its source anchors join the same correctness boundary.
    ///
    /// `sequence` names the exchange: the row the learner's answer was saved
    /// to (`recordPendingReviewUserMessage`). Without it the exchange is the
    /// oldest pending row after the last evaluated one. After a turn that
    /// saved no reply that is the earlier turn's row, and the answer check
    /// below refuses the attempt.
    @discardableResult
    func completePendingReviewExchangeAndRecordMemoryAttempt(
        sessionID: String,
        sequence: Int? = nil,
        answer: String,
        evaluation: String,
        knowledgeNote: String?,
        sourceRefs: [String],
        item: MemoryItem? = nil,
        expectedExistingItem: MemoryItem? = nil,
        attempt: MemoryAttempt,
        answeredAt: Date = Date()
    ) throws -> MemoryAttempt {
        guard attempt.learnerAnswer == answer else {
            throw KnowledgeStoreError.invalidData("The memory attempt answer does not match the chat exchange answer.")
        }
        guard attempt.feedback == evaluation else {
            throw KnowledgeStoreError.invalidData("The memory attempt feedback does not match the chat exchange evaluation.")
        }
        if let existingSessionID = attempt.sessionID, existingSessionID != sessionID {
            throw KnowledgeStoreError.invalidData("The memory attempt is linked to a different chat session.")
        }
        if let item {
            guard item.id == attempt.memoryItemID else {
                throw KnowledgeStoreError.invalidData("The memory item and attempt IDs do not match.")
            }
            try validateMemoryItem(item)
        }
        if let expectedExistingItem {
            guard item == nil else {
                throw KnowledgeStoreError.invalidData(
                    "A memory attempt cannot both create and optimistic-lock the same curriculum."
                )
            }
            guard expectedExistingItem.id == attempt.memoryItemID else {
                throw KnowledgeStoreError.invalidData(
                    "The expected memory curriculum and attempt IDs do not match."
                )
            }
            try validateMemoryItem(expectedExistingItem)
        }

        try exec("BEGIN IMMEDIATE")
        do {
            guard let pending = try pendingMemoryExchange(sessionID: sessionID, sequence: sequence) else {
                throw KnowledgeStoreError.invalidData("No pending review exchange is available for this memory attempt.")
            }
            if let persistedAnswer = pending.userAnswer, persistedAnswer != answer {
                throw KnowledgeStoreError.invalidData(
                    "The pending chat exchange answer does not match the immutable memory attempt."
                )
            }
            let pendingQuestionIsEmpty = pending.question
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard pendingQuestionIsEmpty || pending.question == attempt.prompt else {
                throw KnowledgeStoreError.invalidData(
                    "The pending chat exchange prompt does not match the immutable memory attempt."
                )
            }
            if let suppliedExchangeID = attempt.exchangeID, suppliedExchangeID != pending.id {
                throw KnowledgeStoreError.invalidData("The memory attempt is linked to a different chat exchange.")
            }
            let linkedAttempt = attempt.linked(sessionID: sessionID, exchangeID: pending.id)
            try validateMemoryAttempt(linkedAttempt)

            if let item {
                if let existing = try loadMemoryItem(item.id) {
                    guard MemoryTutorIdentity.hasSameImmutableCurriculum(existing, item) else {
                        throw KnowledgeStoreError.invalidData(
                            "Memory item ID \(item.id) already belongs to different intake content."
                        )
                    }
                } else {
                    try upsertMemoryItemRows(item)
                }
            } else if try loadMemoryItem(attempt.memoryItemID) == nil {
                throw KnowledgeStoreError.invalidData("Memory item \(attempt.memoryItemID) does not exist.")
            }
            if let expectedExistingItem {
                guard let canonicalItem = try loadMemoryItem(expectedExistingItem.id),
                      MemoryTutorIdentity.hasSameImmutableCurriculum(
                        canonicalItem,
                        expectedExistingItem
                      ) else {
                    throw KnowledgeStoreError.invalidData(
                        "Memory item \(expectedExistingItem.id) changed after this review prompt was prepared."
                    )
                }
            }

            let refsJSON = jsonString(from: sourceRefs)
            try execBind("""
                UPDATE review_exchanges
                SET question = CASE WHEN TRIM(question) = '' THEN ? ELSE question END,
                    user_answer = COALESCE(user_answer, ?),
                    evaluation = ?,
                    score = ?,
                    source_refs = ?,
                    knowledge_note = ?,
                    answered_at = ?
                WHERE id = ?
                  AND session_id = ?
            """) { statement in
                bind(statement, 1, linkedAttempt.prompt)
                bind(statement, 2, answer)
                bind(statement, 3, evaluation)
                bind(statement, 4, linkedAttempt.score)
                bind(statement, 5, refsJSON)
                bind(statement, 6, knowledgeNote)
                sqlite3_bind_double(statement, 7, answeredAt.timeIntervalSinceReferenceDate)
                bind(statement, 8, pending.id)
                bind(statement, 9, sessionID)
            }
            var changedRowCount = 0
            try query("SELECT changes()") { statement in
                changedRowCount = Int(sqlite3_column_int64(statement, 0))
            }
            guard changedRowCount == 1 else {
                throw KnowledgeStoreError.invalidData("The pending review exchange changed before it could be recorded.")
            }
            noteStoreChanged()

            _ = try insertMemoryAttemptIfNew(linkedAttempt)
            try rebuildMemorySchedule(memoryItemID: linkedAttempt.memoryItemID)
            try exec("COMMIT")
            return linkedAttempt
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Creates a transcript exchange and immutable memory attempt in one commit,
    /// while leaving the session active. The exchange ID is derived from the
    /// caller-supplied attempt ID, never from model-written text, so a retry is
    /// idempotent and cannot duplicate the prompt.
    @discardableResult
    func recordMemoryAttemptCreatingReviewExchange(
        sessionID: String,
        sourceRefs: [String],
        item: MemoryItem? = nil,
        expectedExistingItem: MemoryItem? = nil,
        attempt: MemoryAttempt
    ) throws -> MemoryAttempt {
        try validateMemoryAttempt(attempt)
        if let item {
            try validateMemoryItem(item)
            guard item.id == attempt.memoryItemID else {
                throw KnowledgeStoreError.invalidData(
                    "A newly discovered memory item must own the attempt recorded with it."
                )
            }
        }
        if let expectedExistingItem {
            guard item == nil else {
                throw KnowledgeStoreError.invalidData(
                    "A memory attempt cannot both create and optimistic-lock the same curriculum."
                )
            }
            try validateMemoryItem(expectedExistingItem)
            guard expectedExistingItem.id == attempt.memoryItemID else {
                throw KnowledgeStoreError.invalidData(
                    "The expected memory curriculum and attempt IDs do not match."
                )
            }
        }
        guard attempt.sessionID == nil, attempt.exchangeID == nil else {
            throw KnowledgeStoreError.invalidData(
                "Creating a review exchange requires an as-yet unlinked memory attempt."
            )
        }
        guard attempt.gradeState != .pending else {
            throw KnowledgeStoreError.invalidData("A pending grade cannot create a completed transcript exchange.")
        }
        if item == nil, try loadMemoryItem(attempt.memoryItemID) == nil {
            throw KnowledgeStoreError.invalidData("Memory item \(attempt.memoryItemID) does not exist.")
        }

        try exec("BEGIN IMMEDIATE")
        do {
            try requireReviewSession(sessionID)
            if let item {
                if let existing = try loadMemoryItem(item.id) {
                    guard MemoryTutorIdentity.hasSameImmutableCurriculum(existing, item) else {
                        throw KnowledgeStoreError.invalidData(
                            "Memory item ID \(item.id) already belongs to different intake content."
                        )
                    }
                } else {
                    try upsertMemoryItemRows(item)
                }
            }
            if let expectedExistingItem {
                guard let canonicalItem = try loadMemoryItem(expectedExistingItem.id),
                      MemoryTutorIdentity.hasSameImmutableCurriculum(
                        canonicalItem,
                        expectedExistingItem
                      ) else {
                    throw KnowledgeStoreError.invalidData(
                        "Memory item \(expectedExistingItem.id) changed after this review prompt was prepared."
                    )
                }
            }
            let linkedAttempt = try createOrValidateMemoryExchange(
                sessionID: sessionID,
                sourceRefs: sourceRefs,
                attempt: attempt
            )
            _ = try insertMemoryAttemptIfNew(linkedAttempt)
            try rebuildMemorySchedule(memoryItemID: linkedAttempt.memoryItemID)
            noteStoreChanged()
            try exec("COMMIT")
            return linkedAttempt
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Completes an imported/MCP review as one SQLite correctness boundary. The
    /// transcript, optional concept intake and attempts, Schedule completion,
    /// companion quiz counters, deterministic gaps, and session completion either
    /// all commit or all roll back. Session completion is the final write and the
    /// idempotency marker: an exact retry validates durable rows without advancing
    /// counters or schedules a second time.
    func completeReviewSessionAndRecordMemoryAttempts(
        sessionID: String,
        overallScore: Double?,
        summary: String,
        endedAt: Date = Date(),
        exportedTranscript: String? = nil,
        transcriptKnowledgeNote: String? = nil,
        sessionSourceIDs: [String] = [],
        reviewedSourceIDs: [String]? = nil,
        scheduleReviewDate: Date? = nil,
        companionGoalID: String? = nil,
        companionQuizDate: String? = nil,
        companionGaps: [LearningGoalGap] = [],
        createIfMissing: ReviewSessionRecoverySeed? = nil,
        items: [MemoryItem] = [],
        expectedCurriculumFingerprints: [String: String] = [:],
        attempts: [MemoryAttempt]
    ) throws {
        if let overallScore, !overallScore.isFinite || overallScore < 0 || overallScore > 1 {
            throw KnowledgeStoreError.invalidData("review session scores must be between 0 and 1.")
        }
        // Parse potentially long exported text before opening the write
        // transaction. The transaction below only validates and inserts rows.
        let exportedTranscriptTurns = exportedTranscript.map {
            ReviewTranscriptParser.turns(from: $0)
        }
        let completionSourceIDs = try stableMemoryReviewSourceIDs(sessionSourceIDs)
        if let createIfMissing {
            guard !createIfMissing.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnowledgeStoreError.invalidData("A recovered review session requires a topic.")
            }
            let recoverySourceIDs = try stableMemoryReviewSourceIDs(createIfMissing.sourceIDs)
            guard recoverySourceIDs == completionSourceIDs else {
                throw KnowledgeStoreError.invalidData(
                    "Recovered review session sources must exactly match review completion sources."
                )
            }
        }
        let requestedReviewedSourceIDs: [String]?
        if let reviewedSourceIDs {
            requestedReviewedSourceIDs = try stableMemoryReviewSourceIDs(reviewedSourceIDs)
        } else {
            requestedReviewedSourceIDs = nil
        }
        let effectiveReviewedSourceIDs = requestedReviewedSourceIDs ?? completionSourceIDs
        guard Set(effectiveReviewedSourceIDs).isSubset(of: Set(completionSourceIDs)) else {
            throw KnowledgeStoreError.invalidData(
                "Reviewed sources must be a subset of the review session's source relationship."
            )
        }
        if companionGoalID == nil {
            guard companionQuizDate == nil, companionGaps.isEmpty else {
                throw KnowledgeStoreError.invalidData(
                    "Companion quiz state and gaps require the review session's goal ID."
                )
            }
        } else {
            guard let companionQuizDate,
                  !companionQuizDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnowledgeStoreError.invalidData(
                    "A companion review completion requires its quiz date."
                )
            }
        }
        var intakeItemsByID: [String: MemoryItem] = [:]
        for item in items {
            try validateMemoryItem(item)
            if let duplicate = intakeItemsByID[item.id],
               !MemoryTutorIdentity.hasSameImmutableCurriculum(duplicate, item) {
                throw KnowledgeStoreError.invalidData(
                    "Memory item ID \(item.id) is reused for different intake content."
                )
            }
            intakeItemsByID[item.id] = item
        }
        for attempt in attempts {
            try validateMemoryAttempt(attempt)
            guard attempt.gradeState != .pending else {
                throw KnowledgeStoreError.invalidData(
                    "A pending grade cannot complete a memory review session."
                )
            }
            if intakeItemsByID[attempt.memoryItemID] == nil,
               try loadMemoryItem(attempt.memoryItemID) == nil {
                throw KnowledgeStoreError.invalidData(
                    "Memory item \(attempt.memoryItemID) does not exist."
                )
            }
            if let linkedSessionID = attempt.sessionID {
                guard linkedSessionID == sessionID else {
                    throw KnowledgeStoreError.invalidData(
                        "Memory attempt \(attempt.id) points to a different session."
                    )
                }
            }
        }
        let referencedItemIDs = Set(attempts.map(\.memoryItemID))
        if let unrelatedExpectedID = expectedCurriculumFingerprints.keys.first(where: {
            !referencedItemIDs.contains($0)
        }) {
            throw KnowledgeStoreError.invalidData(
                "Expected curriculum \(unrelatedExpectedID) has no attempt in this review."
            )
        }
        if let emptyFingerprintID = expectedCurriculumFingerprints.first(where: {
            $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.key {
            throw KnowledgeStoreError.invalidData(
                "Expected curriculum \(emptyFingerprintID) has an empty fingerprint."
            )
        }
        if let orphan = intakeItemsByID.keys.first(where: { !referencedItemIDs.contains($0) }) {
            throw KnowledgeStoreError.invalidData(
                "Memory item \(orphan) cannot be created without an attempt in the same review."
            )
        }
        var gapIDs = Set<String>()
        for gap in companionGaps {
            try validateMemoryReviewGap(
                gap,
                sessionID: sessionID,
                goalID: companionGoalID,
                sourceIDs: Set(effectiveReviewedSourceIDs)
            )
            guard gapIDs.insert(gap.id).inserted else {
                throw KnowledgeStoreError.invalidData(
                    "Companion gap ID \(gap.id) appears more than once in one review completion."
                )
            }
        }

        try exec("BEGIN IMMEDIATE")
        do {
            if try memoryReviewSessionStateIfExists(sessionID: sessionID) == nil {
                guard let createIfMissing else {
                    throw KnowledgeStoreError.invalidData("review session \(sessionID) does not exist.")
                }
                try execBind("""
                    INSERT INTO review_sessions (
                        id, topic, started_at, status, overall_score,
                        exchange_count, source_ids, card_ids,
                        model_provider, model_id, goal_id
                    ) VALUES (?, ?, ?, 'active', NULL, 0, ?, ?, ?, ?, ?)
                """) { statement in
                    bind(statement, 1, sessionID)
                    bind(statement, 2, createIfMissing.topic)
                    sqlite3_bind_double(
                        statement,
                        3,
                        createIfMissing.startedAt.timeIntervalSinceReferenceDate
                    )
                    bind(statement, 4, jsonString(from: completionSourceIDs))
                    bind(statement, 5, jsonString(from: createIfMissing.cardIDs))
                    bind(statement, 6, createIfMissing.modelProvider)
                    bind(statement, 7, createIfMissing.modelID)
                    bind(statement, 8, createIfMissing.goalID)
                }
                try replaceReviewSessionSources(
                    sessionID: sessionID,
                    sourceIDs: completionSourceIDs
                )
                try keepChatShapeForGeneration2(sessionID: sessionID, kind: .memory)
                noteStoreChanged()
            }
            let session = try memoryReviewSessionState(sessionID: sessionID)
            if let createIfMissing {
                guard session.topic == createIfMissing.topic,
                      session.sourceIDs == completionSourceIDs,
                      session.cardIDs == createIfMissing.cardIDs,
                      session.modelProvider == createIfMissing.modelProvider,
                      session.modelID == createIfMissing.modelID,
                      session.goalID == createIfMissing.goalID else {
                    throw KnowledgeStoreError.invalidData(
                        "Recovered review identity conflicts with an existing review session."
                    )
                }
                // The first stored start time remains authoritative. Transport
                // retries naturally observe a later wall clock and must not
                // conflict solely because of that timestamp.
            }
            if scheduleReviewDate != nil || companionGoalID != nil || !completionSourceIDs.isEmpty {
                guard Set(session.sourceIDs) == Set(completionSourceIDs) else {
                    throw KnowledgeStoreError.invalidData(
                        "Review completion sources do not exactly match review session \(sessionID)."
                    )
                }
            }
            if let companionGoalID {
                guard session.goalID == companionGoalID else {
                    throw KnowledgeStoreError.invalidData(
                        "Review completion goal does not match review session \(sessionID)."
                    )
                }
            }

            let isReplay = session.status == "completed"
            if isReplay {
                guard session.overallScore == overallScore,
                      session.summary == summary,
                      session.endedAt == endedAt else {
                    throw KnowledgeStoreError.invalidData(
                        "Completed review session \(sessionID) cannot be replayed with a different score, summary, or completion time."
                    )
                }
            }

            for item in intakeItemsByID.values.sorted(by: { $0.id < $1.id }) {
                if let existing = try loadMemoryItem(item.id) {
                    guard MemoryTutorIdentity.hasSameImmutableCurriculum(existing, item) else {
                        throw KnowledgeStoreError.invalidData(
                            "Memory item ID \(item.id) already belongs to different intake content."
                        )
                    }
                } else if isReplay {
                    throw KnowledgeStoreError.invalidData(
                        "Completed review \(sessionID) is missing memory item \(item.id)."
                    )
                } else {
                    try upsertMemoryItemRows(item)
                    try rebuildMemorySchedule(memoryItemID: item.id)
                }
            }
            for (itemID, expectedFingerprint) in expectedCurriculumFingerprints.sorted(
                by: { $0.key < $1.key }
            ) {
                guard let canonicalItem = try loadMemoryItem(itemID),
                      MemoryTutorIdentity.immutableCurriculumFingerprint(
                        canonicalItem
                      ) == expectedFingerprint else {
                    throw KnowledgeStoreError.invalidData(
                        "Memory item \(itemID) changed after this review session was prepared."
                    )
                }
            }
            var changedItemIDs = Set<String>()
            for attempt in attempts.sorted(by: {
                if $0.attemptedAt != $1.attemptedAt { return $0.attemptedAt < $1.attemptedAt }
                return $0.id < $1.id
            }) {
                let linkedAttempt: MemoryAttempt
                if isReplay {
                    linkedAttempt = attempt.exchangeID == nil
                        ? attempt.linked(
                            sessionID: sessionID,
                            exchangeID: "\(sessionID)::memory-attempt::\(attempt.id)"
                        )
                        : attempt
                    guard let existing = try loadMemoryAttempt(linkedAttempt.id),
                          existing == linkedAttempt else {
                        throw KnowledgeStoreError.invalidData(
                            "Completed review \(sessionID) is missing immutable memory attempt \(linkedAttempt.id)."
                        )
                    }
                    try requireReviewExchange(
                        linkedAttempt.exchangeID ?? "",
                        sessionID: sessionID,
                        matching: linkedAttempt
                    )
                } else if let exchangeID = attempt.exchangeID {
                    try requireReviewExchange(
                        exchangeID,
                        sessionID: sessionID,
                        matching: attempt
                    )
                    linkedAttempt = attempt
                } else {
                    guard let item = try loadMemoryItem(attempt.memoryItemID) else {
                        throw KnowledgeStoreError.invalidData(
                            "Memory item \(attempt.memoryItemID) does not exist."
                        )
                    }
                    linkedAttempt = try createOrValidateMemoryExchange(
                        sessionID: sessionID,
                        sourceRefs: item.sources.map(\.sourceID),
                        attempt: attempt
                    )
                }
                if try insertMemoryAttemptIfNew(linkedAttempt) {
                    changedItemIDs.insert(linkedAttempt.memoryItemID)
                }
            }
            for itemID in changedItemIDs.sorted() {
                try rebuildMemorySchedule(memoryItemID: itemID)
            }
            if requestedReviewedSourceIDs != nil {
                let durableAttemptSourceIDs = try reviewedMemorySourceIDs(sessionID: sessionID)
                guard Set(durableAttemptSourceIDs) == Set(effectiveReviewedSourceIDs) else {
                    throw KnowledgeStoreError.invalidData(
                        "Reviewed sources must exactly match the sources grounded by this session's memory attempts."
                    )
                }
            }
            if let exportedTranscript,
               !exportedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var sourceRefs = Set(completionSourceIDs)
                for attempt in attempts {
                    if let item = try loadMemoryItem(attempt.memoryItemID) {
                        sourceRefs.formUnion(item.sources.map(\.sourceID))
                    }
                }
                try createOrValidateExportedMemoryTranscript(
                    sessionID: sessionID,
                    transcript: exportedTranscript,
                    turns: exportedTranscriptTurns ?? [],
                    knowledgeNote: transcriptKnowledgeNote,
                    sourceRefs: sourceRefs.sorted(),
                    recordedAt: endedAt,
                    allowInsert: !isReplay
                )
            }

            if isReplay {
                try insertOrValidateMemoryReviewGaps(
                    companionGaps,
                    sessionID: sessionID,
                    goalID: companionGoalID,
                    recordedAt: endedAt,
                    allowInsert: false
                )
            } else {
                if let scheduleReviewDate {
                    for sourceID in effectiveReviewedSourceIDs {
                        try recordScheduledSourceReviewRows(
                            sourceID: sourceID,
                            on: scheduleReviewDate,
                            recordedAt: endedAt
                        )
                    }
                }
                if let companionGoalID, let companionQuizDate {
                    try recordCompanionQuizRows(
                        goalID: companionGoalID,
                        sourceIDs: effectiveReviewedSourceIDs,
                        score: overallScore,
                        quizDate: companionQuizDate,
                        recordedAt: endedAt
                    )
                    try insertOrValidateMemoryReviewGaps(
                        companionGaps,
                        sessionID: sessionID,
                        goalID: companionGoalID,
                        recordedAt: endedAt,
                        allowInsert: true
                    )
                }
                // Keep this final: status='completed' is what makes a retry a
                // validation-only no-op for every side effect above.
                try completeReviewSession(
                    sessionID: sessionID,
                    overallScore: overallScore,
                    summary: summary,
                    endedAt: endedAt
                )
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Internal helpers

    private func loadMemoryItemSources(memoryItemID: String) throws -> [MemoryItemSource] {
        var sources: [MemoryItemSource] = []
        try queryBind("""
            SELECT id, source_id, locator_json, excerpt, source_sha256, sort_index
            FROM memory_item_sources
            WHERE memory_item_id = ?
            ORDER BY sort_index, id
        """, bind: { statement in
            bind(statement, 1, memoryItemID)
        }) { statement in
            guard
                let id = self.string(statement, 0),
                let sourceID = self.string(statement, 1),
                let excerpt = self.string(statement, 3),
                let sourceSHA256 = self.string(statement, 4)
            else {
                throw KnowledgeStoreError.invalidData("Memory item \(memoryItemID) contains an invalid source anchor.")
            }
            sources.append(MemoryItemSource(
                id: id,
                memoryItemID: memoryItemID,
                sourceID: sourceID,
                locatorJSON: self.string(statement, 2),
                excerpt: excerpt,
                sourceSHA256: sourceSHA256,
                sortIndex: Int(sqlite3_column_int64(statement, 5))
            ))
        }
        return sources
    }

    private func loadStoredMemorySourceIdentitiesByAnchorID(
        memoryItemID: String
    ) throws -> [String: CloudKitSourceIdentityPayload] {
        var identities: [String: CloudKitSourceIdentityPayload] = [:]
        try queryBind("""
            SELECT id, source_id, source_url, source_normalized_url, source_doi,
                   source_published_doi
            FROM memory_item_sources
            WHERE memory_item_id = ?
        """, bind: { statement in
            bind(statement, 1, memoryItemID)
        }) { statement in
            guard let anchorID = self.string(statement, 0),
                  let sourceID = self.string(statement, 1) else { return }
            let url = self.string(statement, 2)
            let normalizedURL = self.string(statement, 3)
            let doi = self.string(statement, 4)
            let publishedDOI = self.string(statement, 5)
            guard url != nil || normalizedURL != nil || doi != nil || publishedDOI != nil else {
                return
            }
            identities[anchorID] = CloudKitSourceIdentityPayload(
                sourceID: sourceID,
                url: url,
                normalizedURL: normalizedURL,
                doi: doi,
                publishedDOI: publishedDOI
            )
        }
        return identities
    }

    private func upsertMemoryItemRows(
        _ item: MemoryItem,
        portableIdentitiesByAnchorID incomingIdentities: [String: CloudKitSourceIdentityPayload] = [:]
    ) throws {
        var portableIdentities = try loadStoredMemorySourceIdentitiesByAnchorID(memoryItemID: item.id)
        portableIdentities.merge(incomingIdentities) { _, incoming in incoming }
        try execBind("""
            INSERT INTO memory_items (
                id, kind, target, rubric_json, learner_context, goal_id,
                status, created_at, updated_at, idea_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                target = excluded.target,
                rubric_json = excluded.rubric_json,
                learner_context = excluded.learner_context,
                goal_id = excluded.goal_id,
                status = excluded.status,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                -- A pre-v89 client round-tripping an item sends no idea; keep
                -- the one already known rather than erase it.
                idea_id = COALESCE(excluded.idea_id, memory_items.idea_id)
        """) { statement in
            bind(statement, 1, item.id)
            bind(statement, 2, item.kind.rawValue)
            bind(statement, 3, item.target)
            bind(statement, 4, item.rubricJSON)
            bind(statement, 5, item.learnerContext)
            bind(statement, 6, item.goalID)
            bind(statement, 7, item.status.rawValue)
            sqlite3_bind_double(statement, 8, item.createdAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 9, item.updatedAt.timeIntervalSinceReferenceDate)
            bind(statement, 10, item.ideaID)
        }
        try execBind("DELETE FROM memory_item_sources WHERE memory_item_id = ?") { statement in
            bind(statement, 1, item.id)
        }
        for source in item.sources.sorted(by: {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.id < $1.id
        }) {
            try execBind("""
                INSERT INTO memory_item_sources (
                    id, memory_item_id, source_id, locator_json, excerpt,
                    source_sha256, source_url, source_normalized_url, source_doi,
                    source_published_doi, sort_index
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
                let identity = portableIdentities[source.id]
                bind(statement, 1, source.id)
                bind(statement, 2, item.id)
                bind(statement, 3, source.sourceID)
                bind(statement, 4, source.locatorJSON)
                bind(statement, 5, source.excerpt)
                bind(statement, 6, source.sourceSHA256)
                bind(statement, 7, identity?.url)
                bind(statement, 8, identity?.normalizedURL ?? identity?.url.map(URLNormalizer.normalize))
                bind(statement, 9, normalizedMemoryDOI(identity?.doi))
                bind(statement, 10, normalizedMemoryDOI(identity?.publishedDOI))
                sqlite3_bind_int64(statement, 11, Int64(source.sortIndex))
            }
        }
        try removeAttemptsGivenToOtherWording(item)
    }

    /// An answer can arrive from another device before the card it was given
    /// to, and the card that then arrives can carry different wording (the
    /// kept wording won; this device's became a card of its own). An answer
    /// given to other wording says nothing about this card, so it leaves the
    /// card's attempts and cannot move its schedule. The answer itself stays
    /// in its sitting, which is where sync keeps it.
    private func removeAttemptsGivenToOtherWording(
        _ item: MemoryItem
    ) throws {
        let expectedFingerprint = MemoryTutorIdentity.immutableCurriculumFingerprint(item)
        try execBind("""
            DELETE FROM memory_attempts
            WHERE memory_item_id = ?
              AND parent_curriculum_fingerprint IS NOT NULL
              AND parent_curriculum_fingerprint <> ?
        """) { statement in
            bind(statement, 1, item.id)
            bind(statement, 2, expectedFingerprint)
        }
    }

    private func insertMemoryAttemptIfNew(
        _ attempt: MemoryAttempt,
        parentCurriculumFingerprint suppliedFingerprint: String? = nil,
        recordedHere: Bool = true
    ) throws -> Bool {
        let resolvedFingerprint: String?
        if let suppliedFingerprint {
            resolvedFingerprint = suppliedFingerprint
        } else {
            resolvedFingerprint = try loadMemoryItem(attempt.memoryItemID).map {
                MemoryTutorIdentity.immutableCurriculumFingerprint($0)
            }
        }
        if let existing = try loadMemoryAttempt(attempt.id) {
            guard existing == attempt else {
                throw KnowledgeStoreError.invalidData(
                    "Memory attempt ID \(attempt.id) already belongs to different immutable content."
                )
            }
            let storedFingerprint = try loadMemoryAttemptParentCurriculumFingerprint(
                id: attempt.id
            )
            if let storedFingerprint, let resolvedFingerprint {
                guard storedFingerprint == resolvedFingerprint else {
                    throw KnowledgeStoreError.invalidData(
                        "Memory attempt ID \(attempt.id) is already bound to a different parent curriculum."
                    )
                }
            } else if storedFingerprint == nil, let resolvedFingerprint {
                try execBind("""
                    UPDATE memory_attempts
                    SET parent_curriculum_fingerprint = ?
                    WHERE id = ? AND parent_curriculum_fingerprint IS NULL
                """) { statement in
                    bind(statement, 1, resolvedFingerprint)
                    bind(statement, 2, attempt.id)
                }
            }
            return false
        }
        try execBind("""
            INSERT INTO memory_attempts (
                id, memory_item_id, session_id, exchange_id, attempt_type, prompt,
                learner_answer, feedback, score, schedule_rating, grade_state,
                grading_error, evidence_json, attempted_at, model_provider,
                model_id, model_metadata_json, parent_curriculum_fingerprint
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { statement in
            bind(statement, 1, attempt.id)
            bind(statement, 2, attempt.memoryItemID)
            bind(statement, 3, attempt.sessionID)
            bind(statement, 4, attempt.exchangeID)
            bind(statement, 5, attempt.attemptType.rawValue)
            bind(statement, 6, attempt.prompt)
            bind(statement, 7, attempt.learnerAnswer)
            bind(statement, 8, attempt.feedback)
            bind(statement, 9, attempt.score)
            bind(statement, 10, attempt.scheduleRating?.rawValue)
            bind(statement, 11, attempt.gradeState.rawValue)
            bind(statement, 12, attempt.gradingError)
            bind(statement, 13, attempt.evidenceJSON)
            sqlite3_bind_double(statement, 14, attempt.attemptedAt.timeIntervalSinceReferenceDate)
            bind(statement, 15, attempt.modelProvider)
            bind(statement, 16, attempt.modelID)
            bind(statement, 17, attempt.modelMetadataJSON)
            bind(statement, 18, resolvedFingerprint)
        }
        // Generation 2: an attempt made here is an answer in this device's Sitting (§3.5.23).
        if recordedHere {
            try recordSittingAnswer(attempt, curriculumFingerprint: resolvedFingerprint)
        }
        return true
    }

    func loadMemoryAttemptParentCurriculumFingerprint(id: String) throws -> String? {
        var fingerprint: String?
        try queryBind("""
            SELECT parent_curriculum_fingerprint
            FROM memory_attempts
            WHERE id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, id)
        }) { statement in
            fingerprint = self.string(statement, 0)
        }
        return fingerprint
    }

    private func saveMemoryScheduleProjection(_ schedule: MemorySchedule) throws {
        try execBind("""
            INSERT INTO memory_schedules (
                memory_item_id, due_at, last_attempt_at, last_success_at,
                stability, difficulty, repetition_count, lapse_count,
                algorithm_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(memory_item_id) DO UPDATE SET
                due_at = excluded.due_at,
                last_attempt_at = excluded.last_attempt_at,
                last_success_at = excluded.last_success_at,
                stability = excluded.stability,
                difficulty = excluded.difficulty,
                repetition_count = excluded.repetition_count,
                lapse_count = excluded.lapse_count,
                algorithm_version = excluded.algorithm_version
        """) { statement in
            bind(statement, 1, schedule.memoryItemID)
            sqlite3_bind_double(statement, 2, schedule.dueAt.timeIntervalSinceReferenceDate)
            bind(statement, 3, schedule.lastAttemptAt?.timeIntervalSinceReferenceDate)
            bind(statement, 4, schedule.lastSuccessAt?.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 5, schedule.stability)
            sqlite3_bind_double(statement, 6, schedule.difficulty)
            sqlite3_bind_int64(statement, 7, Int64(schedule.repetitionCount))
            sqlite3_bind_int64(statement, 8, Int64(schedule.lapseCount))
            sqlite3_bind_int64(statement, 9, Int64(schedule.algorithmVersion))
        }
    }

    private struct MemoryReviewSessionState {
        let topic: String
        let startedAt: Date
        let endedAt: Date?
        let status: String
        let overallScore: Double?
        let summary: String?
        let sourceIDs: [String]
        let cardIDs: [String]
        let modelProvider: String?
        let modelID: String?
        let goalID: String?
    }

    private func memoryReviewSessionStateIfExists(
        sessionID: String
    ) throws -> MemoryReviewSessionState? {
        var result: MemoryReviewSessionState?
        try queryBind("""
            SELECT topic, started_at, status, ended_at, overall_score, summary,
                   source_ids, card_ids, model_provider, model_id, goal_id
            FROM review_sessions
            WHERE id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, sessionID)
        }) { statement in
            guard let topic = self.string(statement, 0),
                  let status = self.string(statement, 2) else { return }
            result = MemoryReviewSessionState(
                topic: topic,
                startedAt: Date(
                    timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)
                ),
                endedAt: sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)),
                status: status,
                overallScore: self.optionalDouble(statement, 4),
                summary: self.string(statement, 5),
                sourceIDs: self.decodeStringArray(json: self.string(statement, 6)) ?? [],
                cardIDs: self.decodeStringArray(json: self.string(statement, 7)) ?? [],
                modelProvider: self.string(statement, 8),
                modelID: self.string(statement, 9),
                goalID: self.string(statement, 10)
            )
        }
        return result
    }

    private func memoryReviewSessionState(sessionID: String) throws -> MemoryReviewSessionState {
        guard let result = try memoryReviewSessionStateIfExists(sessionID: sessionID) else {
            throw KnowledgeStoreError.invalidData("review session \(sessionID) does not exist.")
        }
        return result
    }

    func stableMemoryReviewSourceIDs(_ sourceIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for sourceID in sourceIDs {
            guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnowledgeStoreError.invalidData("Review completion source IDs cannot be empty.")
            }
            if seen.insert(sourceID).inserted {
                result.append(sourceID)
            }
        }
        return result
    }

    func validateMemoryReviewGap(
        _ gap: LearningGoalGap,
        sessionID: String,
        goalID: String?,
        sourceIDs: Set<String>
    ) throws {
        guard let goalID,
              gap.goalID == goalID,
              gap.sessionID == sessionID else {
            throw KnowledgeStoreError.invalidData(
                "Every companion gap must point to the exact review session and goal being completed."
            )
        }
        guard !gap.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !gap.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData("Companion gap identity and summary are required.")
        }
        guard ["open", "improving", "resolved"].contains(gap.status) else {
            throw KnowledgeStoreError.invalidData("Companion gap status is unsupported: \(gap.status)")
        }
        if let severity = gap.severity,
           !severity.isFinite || severity < 0 || severity > 1 {
            throw KnowledgeStoreError.invalidData("Companion gap severity must be between 0 and 1.")
        }
        if let sourceID = gap.sourceID, !sourceIDs.contains(sourceID) {
            throw KnowledgeStoreError.invalidData(
                "Companion gap source \(sourceID) is not attached to this review session."
            )
        }
        guard gap.firstSeenAt.timeIntervalSinceReferenceDate.isFinite,
              gap.lastSeenAt.timeIntervalSinceReferenceDate.isFinite,
              gap.firstSeenAt <= gap.lastSeenAt else {
            throw KnowledgeStoreError.invalidData("Companion gap timestamps are invalid.")
        }
        if gap.status == "resolved" {
            guard let resolvedAt = gap.resolvedAt,
                  resolvedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw KnowledgeStoreError.invalidData("A resolved companion gap requires resolved_at.")
            }
        } else if gap.resolvedAt != nil {
            throw KnowledgeStoreError.invalidData(
                "An open or improving companion gap cannot have resolved_at."
            )
        }
    }

    func insertOrValidateMemoryReviewGaps(
        _ gaps: [LearningGoalGap],
        sessionID: String,
        goalID: String?,
        recordedAt: Date,
        allowInsert: Bool
    ) throws {
        if !allowInsert {
            var storedGapIDs: [String] = []
            try queryBind("""
                SELECT id
                FROM learning_goal_gaps
                WHERE session_id = ?
                ORDER BY id
            """, bind: { statement in
                bind(statement, 1, sessionID)
            }) { statement in
                if let id = self.string(statement, 0) { storedGapIDs.append(id) }
            }
            let requestedGapIDs = gaps.map(\.id).sorted()
            guard storedGapIDs == requestedGapIDs else {
                throw KnowledgeStoreError.invalidData(
                    "Completed review \(sessionID) must replay the exact companion gap set."
                )
            }
        }
        guard !gaps.isEmpty, let goalID else { return }
        var insertedAny = false
        for gap in gaps.sorted(by: { $0.id < $1.id }) {
            var existing: (
                goalID: String,
                summary: String,
                sourceID: String?,
                status: String,
                severity: Double?,
                sessionID: String?,
                firstSeenAt: Date,
                lastSeenAt: Date,
                resolvedAt: Date?
            )?
            try queryBind("""
                SELECT goal_id, summary, source_id, status, severity, session_id,
                       first_seen_at, last_seen_at, resolved_at
                FROM learning_goal_gaps
                WHERE id = ?
                LIMIT 1
            """, bind: { statement in
                bind(statement, 1, gap.id)
            }) { statement in
                guard let storedGoalID = self.string(statement, 0),
                      let storedSummary = self.string(statement, 1),
                      let storedStatus = self.string(statement, 3) else { return }
                existing = (
                    storedGoalID,
                    storedSummary,
                    self.string(statement, 2),
                    storedStatus,
                    self.optionalDouble(statement, 4),
                    self.string(statement, 5),
                    Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6)),
                    Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 7)),
                    sqlite3_column_type(statement, 8) == SQLITE_NULL
                        ? nil
                        : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8))
                )
            }
            if let existing {
                guard existing.goalID == goalID,
                      existing.summary == gap.summary,
                      existing.sourceID == gap.sourceID,
                      existing.status == gap.status,
                      existing.severity == gap.severity,
                      existing.sessionID == sessionID,
                      existing.firstSeenAt == gap.firstSeenAt,
                      existing.lastSeenAt == gap.lastSeenAt,
                      existing.resolvedAt == gap.resolvedAt else {
                    throw KnowledgeStoreError.invalidData(
                        "Deterministic companion gap ID \(gap.id) already contains different content."
                    )
                }
                continue
            }
            guard allowInsert else {
                throw KnowledgeStoreError.invalidData(
                    "Completed review \(sessionID) is missing companion gap \(gap.id)."
                )
            }
            try saveLearningGoalGap(gap, goalID: goalID)
            insertedAny = true
        }
        if insertedAny {
            try touchLearningGoal(goalID, at: recordedAt)
        }
    }

    private func requireReviewSession(_ sessionID: String) throws {
        var exists = false
        try queryBind("SELECT 1 FROM review_sessions WHERE id = ? LIMIT 1", bind: { statement in
            bind(statement, 1, sessionID)
        }) { _ in
            exists = true
        }
        guard exists else {
            throw KnowledgeStoreError.invalidData("review session \(sessionID) does not exist.")
        }
    }

    private func requireReviewExchange(
        _ exchangeID: String,
        sessionID: String,
        matching attempt: MemoryAttempt? = nil
    ) throws {
        var stored: (question: String, answer: String?, evaluation: String?, score: Double?)?
        try queryBind("""
            SELECT question, user_answer, evaluation, score
            FROM review_exchanges
            WHERE id = ? AND session_id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, exchangeID)
            bind(statement, 2, sessionID)
        }) { statement in
            guard let question = self.string(statement, 0) else { return }
            stored = (
                question,
                self.string(statement, 1),
                self.string(statement, 2),
                self.optionalDouble(statement, 3)
            )
        }
        guard let stored else {
            throw KnowledgeStoreError.invalidData(
                "Memory attempt points to an exchange outside review session \(sessionID)."
            )
        }
        if let attempt {
            let expectedEvaluation = attempt.feedback ?? attempt.gradingError
            guard stored.question == attempt.prompt,
                  stored.answer == attempt.learnerAnswer,
                  stored.evaluation == expectedEvaluation,
                  stored.score == attempt.score else {
                throw KnowledgeStoreError.invalidData(
                    "Memory attempt \(attempt.id) does not match its linked transcript exchange."
                )
            }
        }
    }

    private func createOrValidateMemoryExchange(
        sessionID: String,
        sourceRefs: [String],
        attempt: MemoryAttempt
    ) throws -> MemoryAttempt {
        let exchangeID = "\(sessionID)::memory-attempt::\(attempt.id)"
        let linkedAttempt = attempt.linked(sessionID: sessionID, exchangeID: exchangeID)
        let evaluation = attempt.feedback ?? attempt.gradingError
        let refsJSON = jsonString(from: sourceRefs)

        var existing: (
            sessionID: String,
            question: String,
            answer: String?,
            evaluation: String?,
            score: Double?,
            sourceRefsJSON: String,
            answeredAt: Date?
        )?
        try queryBind("""
            SELECT session_id, question, user_answer, evaluation, score,
                   source_refs, answered_at
            FROM review_exchanges
            WHERE id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, exchangeID)
        }) { statement in
            guard
                let storedSessionID = self.string(statement, 0),
                let question = self.string(statement, 1),
                let storedRefs = self.string(statement, 5)
            else { return }
            existing = (
                storedSessionID,
                question,
                self.string(statement, 2),
                self.string(statement, 3),
                self.optionalDouble(statement, 4),
                storedRefs,
                self.optionalDouble(statement, 6).map {
                    Date(timeIntervalSinceReferenceDate: $0)
                }
            )
        }
        if let existing {
            guard existing.sessionID == sessionID,
                  existing.question == attempt.prompt,
                  existing.answer == attempt.learnerAnswer,
                  existing.evaluation == evaluation,
                  existing.score == attempt.score,
                  existing.sourceRefsJSON == refsJSON,
                  existing.answeredAt == attempt.attemptedAt else {
                throw KnowledgeStoreError.invalidData(
                    "The deterministic exchange for memory attempt \(attempt.id) contains different immutable content."
                )
            }
            return linkedAttempt
        }

        var nextSequence = 1
        try queryBind("""
            SELECT COALESCE(MAX(sequence_number), 0) + 1
            FROM review_exchanges
            WHERE session_id = ?
        """, bind: { statement in
            bind(statement, 1, sessionID)
        }) { statement in
            nextSequence = Int(sqlite3_column_int64(statement, 0))
        }
        try execBind("""
            INSERT INTO review_exchanges (
                id, session_id, sequence_number, question, user_answer,
                evaluation, score, source_refs, knowledge_note, answered_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
        """) { statement in
            bind(statement, 1, exchangeID)
            bind(statement, 2, sessionID)
            sqlite3_bind_int64(statement, 3, Int64(nextSequence))
            bind(statement, 4, attempt.prompt)
            bind(statement, 5, attempt.learnerAnswer)
            bind(statement, 6, evaluation)
            bind(statement, 7, attempt.score)
            bind(statement, 8, refsJSON)
            sqlite3_bind_double(statement, 9, attempt.attemptedAt.timeIntervalSinceReferenceDate)
        }
        try execBind("""
            UPDATE review_sessions
            SET exchange_count = MAX(exchange_count, ?)
            WHERE id = ?
        """) { statement in
            sqlite3_bind_int64(statement, 1, Int64(nextSequence))
            bind(statement, 2, sessionID)
        }
        return linkedAttempt
    }

    private func createOrValidateExportedMemoryTranscript(
        sessionID: String,
        transcript: String,
        turns rawTurns: [ReviewChatTurn],
        knowledgeNote: String?,
        sourceRefs: [String],
        recordedAt: Date,
        allowInsert: Bool = true
    ) throws {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceRefsJSON = jsonString(from: sourceRefs)
        let legacyExchangeID = "\(sessionID)::memory-export"
        var legacy: (
            sessionID: String,
            transcript: String?,
            evaluation: String?,
            sourceRefsJSON: String,
            knowledgeNote: String?
        )?
        try queryBind("""
            SELECT session_id, user_answer, evaluation, source_refs,
                   knowledge_note
            FROM review_exchanges
            WHERE id = ?
            LIMIT 1
        """, bind: { statement in
            bind(statement, 1, legacyExchangeID)
        }) { statement in
            guard
                let storedSessionID = self.string(statement, 0),
                let storedSourceRefs = self.string(statement, 3)
            else { return }
            legacy = (
                storedSessionID,
                self.string(statement, 1),
                self.string(statement, 2),
                storedSourceRefs,
                self.string(statement, 4)
            )
        }
        // Reviews saved by earlier builds used one opaque `Review transcript`
        // exchange. Accept that exact durable row on replay; the transcript UI
        // expands its role-labelled contents without mutating user data.
        if let legacy {
            guard legacy.sessionID == sessionID,
                  legacy.transcript == normalizedTranscript,
                  legacy.evaluation == "",
                  legacy.sourceRefsJSON == sourceRefsJSON,
                  legacy.knowledgeNote == knowledgeNote else {
                throw KnowledgeStoreError.invalidData(
                    "The exported memory transcript already contains different immutable content."
                )
            }
            return
        }

        let turns = rawTurns.filter { turn in
            let question = turn.question?.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = turn.answer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let evaluation = turn.evaluation?.trimmingCharacters(in: .whitespacesAndNewlines)
            return question?.isEmpty == false || answer?.isEmpty == false || evaluation?.isEmpty == false
        }

        var nextSequence = 1
        try queryBind("""
            SELECT COALESCE(MAX(sequence_number), 0) + 1
            FROM review_exchanges
            WHERE session_id = ?
        """, bind: { statement in
            bind(statement, 1, sessionID)
        }) { statement in
            nextSequence = Int(sqlite3_column_int64(statement, 0))
        }

        var insertedAnyTurn = false
        for (index, turn) in turns.enumerated() {
            let exchangeID = "\(sessionID)::memory-export::\(index + 1)"
            let question = turn.question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let answer = turn.answer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let evaluation = turn.evaluation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let turnKnowledgeNote = index == 0 ? knowledgeNote : nil
            var existing: (
                sessionID: String,
                question: String,
                answer: String?,
                evaluation: String?,
                sourceRefsJSON: String,
                knowledgeNote: String?
            )?
            try queryBind("""
                SELECT session_id, question, user_answer, evaluation,
                       source_refs, knowledge_note
                FROM review_exchanges
                WHERE id = ?
                LIMIT 1
            """, bind: { statement in
                bind(statement, 1, exchangeID)
            }) { statement in
                guard let storedSessionID = self.string(statement, 0),
                      let storedQuestion = self.string(statement, 1),
                      let storedSourceRefs = self.string(statement, 4) else { return }
                existing = (
                    storedSessionID,
                    storedQuestion,
                    self.string(statement, 2),
                    self.string(statement, 3),
                    storedSourceRefs,
                    self.string(statement, 5)
                )
            }
            if let existing {
                guard existing.sessionID == sessionID,
                      existing.question == question,
                      existing.answer == answer,
                      existing.evaluation == evaluation,
                      existing.sourceRefsJSON == sourceRefsJSON,
                      existing.knowledgeNote == turnKnowledgeNote else {
                    throw KnowledgeStoreError.invalidData(
                        "The exported transcript already contains different immutable turn content."
                    )
                }
                continue
            }
            guard allowInsert else {
                throw KnowledgeStoreError.invalidData(
                    "Completed review \(sessionID) is missing exported transcript turn \(index + 1)."
                )
            }
            try execBind("""
                INSERT INTO review_exchanges (
                    id, session_id, sequence_number, question, user_answer,
                    evaluation, score, source_refs, knowledge_note, answered_at
                ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
            """) { statement in
                bind(statement, 1, exchangeID)
                bind(statement, 2, sessionID)
                sqlite3_bind_int64(statement, 3, Int64(nextSequence + index))
                bind(statement, 4, question)
                bind(statement, 5, answer)
                bind(statement, 6, evaluation)
                bind(statement, 7, sourceRefsJSON)
                bind(statement, 8, turnKnowledgeNote)
                sqlite3_bind_double(statement, 9, recordedAt.timeIntervalSinceReferenceDate)
            }
            insertedAnyTurn = true
        }
        if insertedAnyTurn {
            let lastSequence = nextSequence + max(0, turns.count - 1)
            try execBind("""
                UPDATE review_sessions
                SET exchange_count = MAX(exchange_count, ?)
                WHERE id = ?
            """) { statement in
                sqlite3_bind_int64(statement, 1, Int64(lastSequence))
                bind(statement, 2, sessionID)
            }
        }
    }

    private func pendingMemoryExchange(
        sessionID: String,
        sequence: Int?
    ) throws -> (id: String, sequence: Int, question: String, userAnswer: String?)? {
        var result: (id: String, sequence: Int, question: String, userAnswer: String?)?
        let sql = sequence == nil
            ? """
            SELECT id, sequence_number, question, user_answer
            FROM review_exchanges
            WHERE session_id = ?
              AND evaluation IS NULL
              AND sequence_number > COALESCE((
                  SELECT MAX(sequence_number)
                  FROM review_exchanges
                  WHERE session_id = ?
                    AND evaluation IS NOT NULL
              ), 0)
            ORDER BY sequence_number
            LIMIT 1
            """
            : """
            SELECT id, sequence_number, question, user_answer
            FROM review_exchanges
            WHERE session_id = ?
              AND sequence_number = ?
              AND evaluation IS NULL
            """
        try queryBind(sql, bind: { statement in
            bind(statement, 1, sessionID)
            if let sequence {
                sqlite3_bind_int(statement, 2, Int32(sequence))
            } else {
                bind(statement, 2, sessionID)
            }
        }) { statement in
            guard let id = self.string(statement, 0),
                  let question = self.string(statement, 2) else { return }
            result = (
                id,
                Int(sqlite3_column_int64(statement, 1)),
                question,
                self.string(statement, 3)
            )
        }
        return result
    }

    private func validateMemoryItem(_ item: MemoryItem) throws {
        guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData("Memory item identity cannot be empty.")
        }
        guard !item.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData("Memory item target cannot be empty.")
        }
        try validateJSONObject(item.rubricJSON, field: "rubric")
        guard !item.sources.isEmpty else {
            throw KnowledgeStoreError.invalidData("A memory item requires at least one source anchor.")
        }
        var sourceIDs = Set<String>()
        var sortIndexes = Set<Int>()
        for source in item.sources {
            guard source.memoryItemID == item.id else {
                throw KnowledgeStoreError.invalidData("A memory source anchor points to a different memory item.")
            }
            guard !source.id.isEmpty, sourceIDs.insert(source.id).inserted else {
                throw KnowledgeStoreError.invalidData("Memory source anchor identities must be non-empty and unique.")
            }
            guard !source.sourceID.isEmpty,
                  !source.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !source.sourceSHA256.isEmpty else {
                throw KnowledgeStoreError.invalidData("Memory source anchors require source identity, excerpt, and source hash.")
            }
            guard source.sortIndex >= 0, sortIndexes.insert(source.sortIndex).inserted else {
                throw KnowledgeStoreError.invalidData("Memory source anchor sort indexes must be unique and non-negative.")
            }
            if let locatorJSON = source.locatorJSON {
                try validateJSON(locatorJSON, field: "source locator")
            }
        }
    }

    private func validateMemoryAttempt(_ attempt: MemoryAttempt) throws {
        guard !attempt.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !attempt.memoryItemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData("Memory attempt and item identities cannot be empty.")
        }
        guard !attempt.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeStoreError.invalidData("Memory attempt prompt cannot be empty.")
        }
        guard (attempt.sessionID == nil) == (attempt.exchangeID == nil) else {
            throw KnowledgeStoreError.invalidData("Memory attempt chat linkage requires both session and exchange IDs.")
        }
        if let score = attempt.score, !score.isFinite || score < 0 || score > 1 {
            throw KnowledgeStoreError.invalidData("Memory attempt scores must be between 0 and 1.")
        }
        switch attempt.gradeState {
        case .graded:
            guard attempt.score != nil,
                  attempt.scheduleRating != nil,
                  attempt.gradingError == nil,
                  !attempt.learnerAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KnowledgeStoreError.invalidData(
                    "A graded memory attempt requires an answer, score, and schedule rating, without an error."
                )
            }
        case .failed:
            guard let error = attempt.gradingError,
                  !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  attempt.score == nil,
                  attempt.scheduleRating == nil else {
                throw KnowledgeStoreError.invalidData(
                    "A failed memory attempt requires an error, no score, and cannot advance the schedule."
                )
            }
        case .pending:
            guard attempt.score == nil, attempt.scheduleRating == nil else {
                throw KnowledgeStoreError.invalidData("A pending memory attempt cannot have a score or advance the schedule.")
            }
        }
        if let evidenceJSON = attempt.evidenceJSON {
            try validateJSON(evidenceJSON, field: "attempt evidence")
        }
        if let modelMetadataJSON = attempt.modelMetadataJSON {
            try validateJSONObject(modelMetadataJSON, field: "model metadata")
        }
    }

    private func validateJSONObject(_ value: String, field: String) throws {
        let object = try decodeJSON(value, field: field)
        guard object is [String: Any] else {
            throw KnowledgeStoreError.invalidData("Memory \(field) must be a JSON object.")
        }
    }

    private func validateJSON(_ value: String, field: String) throws {
        _ = try decodeJSON(value, field: field)
    }

    private func decodeJSON(_ value: String, field: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])
        } catch {
            throw KnowledgeStoreError.invalidData("Memory \(field) is not valid JSON: \(error.localizedDescription)")
        }
    }

    private func normalizedMemoryDOI(_ value: String?) -> String? {
        cleanIdentityValue(value)?.lowercased()
    }
}
