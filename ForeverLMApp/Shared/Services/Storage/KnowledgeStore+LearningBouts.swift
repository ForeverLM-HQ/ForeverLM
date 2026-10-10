import Foundation
import SQLite3

/// Storage for the Planner's timed learning bouts.
///
/// A bout is one stretch of learning with a clock on it, ending in a write-up
/// of what was learned and what is still unclear, which is what earns the break
/// that follows. The rows live with the day they belong to and travel inside
/// its `DayPlan` record, beside the blocks and the log.
///
/// Two rules hold this together and are enforced here rather than in a pane:
///
/// - **Only the learner ends a bout.** The timer running out sets nothing; it
///   is `endLearningBout` — the learner's own hand, from either client or over
///   MCP — that writes `ended_at`. This is the block invariant of
///   planner-design.md applied to the bout.
/// - **The break is earned, never given.** `startLearningBoutBreak` refuses a
///   bout that has no write-up, so there is no path to a break that skips the
///   reflection, in the app, in the browser, or from an assistant.
extension KnowledgeStore {

    // MARK: - Reads

    func loadLearningBout(_ id: String) throws -> LearningBout? {
        var bout: LearningBout?
        try queryBind("\(Self.learningBoutColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, id)
        }) { stmt in
            bout = self.learningBout(from: stmt)
        }
        return bout
    }

    /// A day's bouts, oldest first.
    func loadLearningBouts(dayPlanID: String) throws -> [LearningBout] {
        var bouts: [LearningBout] = []
        try queryBind("\(Self.learningBoutColumns) WHERE day_plan_id = ? ORDER BY started_at ASC, id ASC", bind: { stmt in
            self.bind(stmt, 1, dayPlanID)
        }) { stmt in
            if let bout = self.learningBout(from: stmt) { bouts.append(bout) }
        }
        return bouts
    }

    /// The bout the clients should be showing, wherever it started.
    ///
    /// Today and yesterday are both read, because a bout begun before midnight
    /// stays on the day it started and its break may well be taken on the next
    /// one. Two days of rows is a handful of records, so this is the cheap read
    /// the menu bar and the phone's snapshot can take on every refresh.
    func loadLiveLearningBout(now: Date = Date()) throws -> LearningBout? {
        let today = DayPlan.dateString(for: now)
        var candidates = try loadLearningBouts(dayPlanID: today)
        if let yesterday = DayPlan.dateString(today, offsetBy: -1) {
            candidates.append(contentsOf: try loadLearningBouts(dayPlanID: yesterday))
        }
        return LearningBout.live(in: candidates, now: now)
    }

    // MARK: - Writes

    /// Starts the clock on a bout, creating the day's plan when it is the
    /// first thing on it.
    ///
    /// Refused while another bout is live: a second timer would silently orphan
    /// the first one's write-up, and the learner meant to end one before
    /// starting the next.
    @discardableResult
    func startLearningBout(_ bout: LearningBout, now: Date = Date()) throws -> LearningBout {
        var saved = bout.normalized(now: now)
        guard DayPlan.isValidDateString(saved.dayPlanID) else {
            throw KnowledgeStoreError.invalidData("A learning bout needs a day, formatted YYYY-MM-DD.")
        }
        if let running = try loadLiveLearningBout(now: now) {
            throw KnowledgeStoreError.invalidData(
                "A bout is already running: \"\(running.title)\". End it before starting another."
            )
        }
        if saved.title.isEmpty, let blockID = saved.blockID, let block = try loadTimeBlock(blockID) {
            saved.title = block.title
            if saved.notebookID == nil { saved.notebookID = block.notebookID }
            if saved.sourceIDs.isEmpty { saved.sourceIDs = block.sourceIDs }
        }
        guard !saved.title.isEmpty else {
            throw KnowledgeStoreError.invalidData("A learning bout needs a title.")
        }
        saved.startedAt = now
        saved.endedAt = nil
        saved.writtenAt = nil
        saved.breakStartedAt = nil
        saved.breakEndedAt = nil
        saved.abandonedAt = nil
        saved.createdAt = now
        try exec("BEGIN IMMEDIATE")
        do {
            let plan = try ensureDayPlanRow(saved.dayPlanID, now: now)
            saved.dayPlanID = plan.id
            try writeLearningBoutRow(saved)
            try touchDayPlan(plan.id, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return saved
    }

    /// Stops the learning. The write-up is still owed, and the break is not
    /// earned until it is written.
    @discardableResult
    func endLearningBout(_ id: String, now: Date = Date()) throws -> LearningBout {
        try mutateLearningBout(id, now: now) { bout in
            guard bout.phase(now: now) == .learning else {
                throw KnowledgeStoreError.invalidData("Bout \(id) is not running.")
            }
            bout.endedAt = now
            bout.breakMinutes = LearningBout.earnedBreakMinutes(forMinutesLearned: bout.minutesLearned(now: now))
        }
    }

    /// Saves the write-up, which is the moment the break is earned.
    ///
    /// A bout still running is stopped by the same act — writing up is how a
    /// bout ends — and the block it was run against is marked done, because
    /// this is the learner saying the work happened, not the clock saying the
    /// time passed. A block already done, skipped, or superseded by a redraw is
    /// left exactly as it is.
    @discardableResult
    func writeUpLearningBout(
        _ id: String,
        learned: String,
        unclear: String?,
        breakMinutes: Int? = nil,
        now: Date = Date()
    ) throws -> LearningBout {
        guard LearningBout.isWriteUpComplete(learned: learned) else {
            throw KnowledgeStoreError.invalidData("A write-up needs what you learned.")
        }
        return try mutateLearningBout(id, now: now) { bout in
            guard bout.abandonedAt == nil else {
                throw KnowledgeStoreError.invalidData("Bout \(id) was abandoned.")
            }
            if bout.endedAt == nil { bout.endedAt = now }
            bout.learned = learned
            bout.unclear = unclear
            let earned = LearningBout.earnedBreakMinutes(forMinutesLearned: bout.minutesLearned(now: now))
            bout.breakMinutes = LearningBout.clampedBreakMinutes(breakMinutes ?? earned)
            if bout.writtenAt == nil { bout.writtenAt = now }
            try self.markBoutBlockDone(bout, now: now)
        }
    }

    /// Changes how long the earned break will be, before it starts.
    @discardableResult
    func setLearningBoutBreakMinutes(_ id: String, minutes: Int, now: Date = Date()) throws -> LearningBout {
        try mutateLearningBout(id, now: now) { bout in
            guard bout.breakStartedAt == nil else {
                throw KnowledgeStoreError.invalidData("Bout \(id) is already on its break.")
            }
            bout.breakMinutes = LearningBout.clampedBreakMinutes(minutes)
        }
    }

    /// Starts the earned break. Refused without a write-up: that is the whole
    /// point of the break being earned.
    @discardableResult
    func startLearningBoutBreak(_ id: String, minutes: Int? = nil, now: Date = Date()) throws -> LearningBout {
        try mutateLearningBout(id, now: now) { bout in
            guard bout.hasWriteUp, bout.writtenAt != nil else {
                throw KnowledgeStoreError.invalidData("Write up bout \(id) before taking its break.")
            }
            guard bout.breakStartedAt == nil else {
                throw KnowledgeStoreError.invalidData("Bout \(id) has already taken its break.")
            }
            if let minutes { bout.breakMinutes = LearningBout.clampedBreakMinutes(minutes) }
            if bout.breakMinutes <= 0 {
                bout.breakMinutes = LearningBout.earnedBreakMinutes(forMinutesLearned: bout.minutesLearned(now: now))
            }
            bout.breakStartedAt = now
        }
    }

    /// Ends the break. Its clock ran out and was acknowledged, the learner went
    /// back to work early, or — on a bout whose break was earned and never
    /// started — the break was declined. All three finish the bout, and the
    /// third is why this does not insist on a break being under way: going
    /// straight back to work is a real answer, and pretending a zero-length
    /// break happened would be a worse record of the day.
    @discardableResult
    func endLearningBoutBreak(_ id: String, now: Date = Date()) throws -> LearningBout {
        try mutateLearningBout(id, now: now) { bout in
            guard bout.writtenAt != nil else {
                throw KnowledgeStoreError.invalidData("Bout \(id) has no break to end.")
            }
            guard bout.breakEndedAt == nil else { return }
            bout.breakEndedAt = now
        }
    }

    /// Gives up on a bout without a write-up. Recorded rather than deleted, so
    /// the day's record stays honest about the hour that went nowhere.
    @discardableResult
    func abandonLearningBout(_ id: String, now: Date = Date()) throws -> LearningBout {
        try mutateLearningBout(id, now: now) { bout in
            guard bout.writtenAt == nil else {
                throw KnowledgeStoreError.invalidData("Bout \(id) is already written up.")
            }
            if bout.endedAt == nil { bout.endedAt = now }
            bout.abandonedAt = now
        }
    }

    /// Removes a bout outright. For a row started by mistake; the honest way to
    /// drop one that was really learned is to abandon it.
    func deleteLearningBout(_ id: String, now: Date = Date()) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            guard let bout = try loadLearningBout(id) else {
                try exec("ROLLBACK")
                throw KnowledgeStoreError.invalidData("No learning bout with id \(id).")
            }
            try execBind("DELETE FROM learning_bouts WHERE id = ?") { stmt in
                self.bind(stmt, 1, id)
            }
            try touchDayPlan(bout.dayPlanID, at: now)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// One transactional edit of a bout: load, change, write, and queue the
    /// day for sync. `change` may throw to refuse the edit, which rolls back.
    @discardableResult
    private func mutateLearningBout(
        _ id: String,
        now: Date,
        _ change: (inout LearningBout) throws -> Void
    ) throws -> LearningBout {
        try exec("BEGIN IMMEDIATE")
        do {
            guard var bout = try loadLearningBout(id) else {
                try exec("ROLLBACK")
                throw KnowledgeStoreError.invalidData("No learning bout with id \(id).")
            }
            try change(&bout)
            bout = bout.normalized(now: now)
            try writeLearningBoutRow(bout)
            try touchDayPlan(bout.dayPlanID, at: now)
            try exec("COMMIT")
            return bout
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// The write-up marks the bout's block done — the learner's own act, which
    /// is the only thing allowed to. Written in place: a status change is never
    /// a redraw, so it stays in the column it was drawn in.
    private func markBoutBlockDone(_ bout: LearningBout, now: Date) throws {
        guard let blockID = bout.blockID,
              var block = try loadTimeBlock(blockID),
              block.isCurrent,
              block.status == .planned else { return }
        block.status = .done
        block.updatedAt = now
        try writeTimeBlockRow(block)
    }

    // MARK: - Row plumbing

    static let learningBoutColumns = """
        SELECT id, day_plan_id, block_id, title, notebook_id, source_ids, planned_minutes,
               started_at, ended_at, learned, unclear, written_at,
               break_minutes, break_started_at, break_ended_at, abandoned_at,
               created_at, updated_at
        FROM learning_bouts
    """

    func writeLearningBoutRow(_ bout: LearningBout) throws {
        try execBind("""
            INSERT INTO learning_bouts (
                id, day_plan_id, block_id, title, notebook_id, source_ids, planned_minutes,
                started_at, ended_at, learned, unclear, written_at,
                break_minutes, break_started_at, break_ended_at, abandoned_at,
                created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                day_plan_id = excluded.day_plan_id,
                block_id = excluded.block_id,
                title = excluded.title,
                notebook_id = excluded.notebook_id,
                source_ids = excluded.source_ids,
                planned_minutes = excluded.planned_minutes,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                learned = excluded.learned,
                unclear = excluded.unclear,
                written_at = excluded.written_at,
                break_minutes = excluded.break_minutes,
                break_started_at = excluded.break_started_at,
                break_ended_at = excluded.break_ended_at,
                abandoned_at = excluded.abandoned_at,
                updated_at = excluded.updated_at
        """) { stmt in
            self.bind(stmt, 1, bout.id)
            self.bind(stmt, 2, bout.dayPlanID)
            self.bind(stmt, 3, bout.blockID)
            self.bind(stmt, 4, bout.title)
            self.bind(stmt, 5, bout.notebookID)
            self.bind(stmt, 6, bout.sourceIDsJSON)
            self.bind(stmt, 7, bout.plannedMinutes)
            self.bind(stmt, 8, bout.startedAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 9, bout.endedAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 10, bout.learned)
            self.bind(stmt, 11, bout.unclear)
            self.bind(stmt, 12, bout.writtenAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 13, bout.breakMinutes)
            self.bind(stmt, 14, bout.breakStartedAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 15, bout.breakEndedAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 16, bout.abandonedAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 17, bout.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 18, bout.updatedAt.timeIntervalSinceReferenceDate)
        }
    }

    func learningBout(from stmt: OpaquePointer?) -> LearningBout? {
        guard let id = string(stmt, 0), let dayPlanID = string(stmt, 1) else { return nil }
        return LearningBout(
            id: id,
            dayPlanID: dayPlanID,
            blockID: string(stmt, 2),
            title: string(stmt, 3) ?? "",
            notebookID: string(stmt, 4),
            sourceIDs: SourceIDList.normalized(Self.sourceIDList(fromJSON: string(stmt, 5))),
            plannedMinutes: Int(sqlite3_column_int(stmt, 6)),
            startedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 7)),
            endedAt: optionalDouble(stmt, 8).map { Date(timeIntervalSinceReferenceDate: $0) },
            learned: string(stmt, 9),
            unclear: string(stmt, 10),
            writtenAt: optionalDouble(stmt, 11).map { Date(timeIntervalSinceReferenceDate: $0) },
            breakMinutes: Int(sqlite3_column_int(stmt, 12)),
            breakStartedAt: optionalDouble(stmt, 13).map { Date(timeIntervalSinceReferenceDate: $0) },
            breakEndedAt: optionalDouble(stmt, 14).map { Date(timeIntervalSinceReferenceDate: $0) },
            abandonedAt: optionalDouble(stmt, 15).map { Date(timeIntervalSinceReferenceDate: $0) },
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 16)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 17))
        )
    }

    /// The stored JSON array of source ids; an unreadable or absent column
    /// reads as no sources rather than failing the row.
    static func sourceIDList(fromJSON json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }
}
