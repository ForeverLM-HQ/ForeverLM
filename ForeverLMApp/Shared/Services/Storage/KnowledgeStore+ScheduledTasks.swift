import Foundation
import SQLite3

/// Storage for recurring scheduled tasks and their run receipts.
///
/// The definition and its receipts sync together as one record. They are not
/// two entities because a receipt is meaningless without its task and a task
/// whose history says "never run" on the second Mac reads as a broken feature.
extension KnowledgeStore {

    // MARK: - Reads

    func loadScheduledTasks() throws -> [ScheduledTask] {
        var tasks: [ScheduledTask] = []
        try query("\(Self.scheduledTaskColumns) ORDER BY created_at ASC") { stmt in
            if let task = self.scheduledTask(from: stmt) { tasks.append(task) }
        }
        return tasks
    }

    func loadScheduledTask(_ taskID: String) throws -> ScheduledTask? {
        var task: ScheduledTask?
        try queryBind("\(Self.scheduledTaskColumns) WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, taskID)
        }) { stmt in
            task = self.scheduledTask(from: stmt)
        }
        return task
    }

    func loadScheduledTaskRuns(taskID: String, limit: Int = ScheduledTask.retainedRunCount) throws -> [ScheduledTaskRun] {
        var runs: [ScheduledTaskRun] = []
        try queryBind("""
            SELECT id, task_id, occurrence_at, started_at, finished_at, status, session_id, message, device_name,
                   attempt, retry_at
            FROM scheduled_task_runs
            WHERE task_id = ?
            ORDER BY occurrence_at DESC
            LIMIT ?
        """, bind: { stmt in
            self.bind(stmt, 1, taskID)
            self.bind(stmt, 2, max(1, limit))
        }) { stmt in
            if let run = self.scheduledTaskRun(from: stmt) { runs.append(run) }
        }
        return runs
    }

    /// Every task with its retained receipts, in one pass. The list is small by
    /// nature, so a client can render the whole surface without a second query
    /// per row.
    func loadScheduledTaskDetails() throws -> [ScheduledTaskDetail] {
        let tasks = try loadScheduledTasks()
        guard !tasks.isEmpty else { return [] }
        var runsByTask: [String: [ScheduledTaskRun]] = [:]
        try query("""
            SELECT id, task_id, occurrence_at, started_at, finished_at, status, session_id, message, device_name,
                   attempt, retry_at
            FROM scheduled_task_runs
            ORDER BY occurrence_at DESC
        """) { stmt in
            guard let run = self.scheduledTaskRun(from: stmt) else { return }
            var existing = runsByTask[run.taskID] ?? []
            guard existing.count < ScheduledTask.retainedRunCount else { return }
            existing.append(run)
            runsByTask[run.taskID] = existing
        }
        return tasks.map { ScheduledTaskDetail(task: $0, runs: runsByTask[$0.id] ?? []) }
    }

    func hasScheduledTask(_ taskID: String) throws -> Bool {
        var found = false
        try queryBind("SELECT 1 FROM scheduled_tasks WHERE id = ? LIMIT 1", bind: { stmt in
            self.bind(stmt, 1, taskID)
        }) { _ in
            found = true
        }
        return found
    }

    // MARK: - Writes

    /// Insert or replace a task from a local edit, republishing it to CloudKit.
    @discardableResult
    func saveScheduledTask(_ task: ScheduledTask) throws -> ScheduledTask {
        let normalized = task.normalized()
        guard !normalized.title.isEmpty else {
            throw KnowledgeStoreError.invalidData("A scheduled task needs a name.")
        }
        guard !normalized.instruction.isEmpty else {
            throw KnowledgeStoreError.invalidData("A scheduled task needs an instruction to send.")
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try writeScheduledTaskRow(normalized)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return normalized
    }

    func deleteScheduledTask(_ taskID: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("DELETE FROM scheduled_tasks WHERE id = ?") { stmt in
                self.bind(stmt, 1, taskID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Detaches a deleted Notebook from every task that filed its chats there.
    /// The tasks keep running; their output simply lands in the general Chats
    /// section, exactly as Schedule placements keep their source when a Notebook
    /// that tagged them is deleted.
    @discardableResult
    func detachScheduledTasksFromNotebook(_ notebookID: String) throws -> Int {
        var affected: [String] = []
        try queryBind("SELECT id FROM scheduled_tasks WHERE notebook_id = ?", bind: { stmt in
            self.bind(stmt, 1, notebookID)
        }) { stmt in
            if let id = self.string(stmt, 0) { affected.append(id) }
        }
        guard !affected.isEmpty else { return 0 }
        let now = Date()
        try execBind("""
            UPDATE scheduled_tasks
            SET notebook_id = NULL, updated_at = ?
            WHERE notebook_id = ?
        """) { stmt in
            self.bind(stmt, 1, now.timeIntervalSinceReferenceDate)
            self.bind(stmt, 2, notebookID)
        }
        return affected.count
    }

    /// Requests an immediate extra run. The runner treats the request instant as
    /// its own occurrence, so it can never be mistaken for, or swallowed by, the
    /// scheduled one.
    func requestScheduledTaskRunNow(_ taskID: String, at date: Date = Date()) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            // Under generation 2 a task another Mac runs is asked of that Mac.
            if try hasScheduledTask(taskID), try requestRunOnRunnerMacForGeneration2(taskID, at: date) {
                try exec("COMMIT")
                return
            }
            try execBind("""
                UPDATE scheduled_tasks
                SET run_now_requested_at = ?, updated_at = ?
                WHERE id = ?
            """) { stmt in
                self.bind(stmt, 1, date.timeIntervalSinceReferenceDate)
                self.bind(stmt, 2, date.timeIntervalSinceReferenceDate)
                self.bind(stmt, 3, taskID)
            }
            guard sqlite3_changes(db) > 0 else {
                try exec("ROLLBACK")
                throw KnowledgeStoreError.invalidData("No scheduled task with id \(taskID).")
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Atomically takes ownership of one occurrence.
    ///
    /// Returns the receipt when this device won and nil when the occurrence was
    /// already claimed — by an earlier launch, or by another Mac whose record
    /// arrived first. The `UNIQUE(task_id, occurrence_at)` constraint is what
    /// makes "exactly one chat per morning" true rather than merely likely.
    func claimScheduledTaskOccurrence(
        taskID: String,
        occurrenceAt: Date,
        status: ScheduledTaskRunStatus = .running,
        message: String? = nil,
        deviceName: String? = nil,
        now: Date = Date()
    ) throws -> ScheduledTaskRun? {
        var claimed: ScheduledTaskRun?
        try exec("BEGIN IMMEDIATE")
        do {
            guard let task = try loadScheduledTask(taskID) else {
                try exec("ROLLBACK")
                return nil
            }
            if let lastOccurrenceAt = task.lastOccurrenceAt, occurrenceAt <= lastOccurrenceAt {
                try exec("ROLLBACK")
                return nil
            }
            // Under generation 2 one Mac runs each task (`Automation.runnerDeviceID`).
            guard try scheduledTaskRunsHere(taskID) else {
                try exec("ROLLBACK")
                return nil
            }

            let run = ScheduledTaskRun(
                taskID: taskID,
                occurrenceAt: occurrenceAt,
                startedAt: now,
                finishedAt: status == .running ? nil : now,
                status: status,
                message: message,
                deviceName: deviceName
            )
            // A losing racer hits the UNIQUE constraint here and gets nil, not a
            // thrown error: two devices claiming the same instant is expected,
            // not exceptional.
            var inserted = true
            do {
                try insertScheduledTaskRun(run)
            } catch {
                inserted = false
            }
            guard inserted else {
                try exec("ROLLBACK")
                return nil
            }
            try takeRingSlotForGeneration2(runID: run.id, taskID: taskID)
            // A newer occurrence supersedes an older one still waiting for
            // its next try: Run now, or tomorrow's run, must not be followed
            // by a second chat answering yesterday's.
            try execBind("""
                UPDATE scheduled_task_runs
                SET retry_at = NULL
                WHERE task_id = ? AND retry_at IS NOT NULL AND occurrence_at < ?
            """) { stmt in
                self.bind(stmt, 1, taskID)
                self.bind(stmt, 2, occurrenceAt.timeIntervalSinceReferenceDate)
            }

            try execBind("""
                UPDATE scheduled_tasks
                SET last_occurrence_at = ?,
                    last_run_at = ?,
                    last_run_status = ?,
                    run_now_requested_at = CASE
                        WHEN run_now_requested_at IS NOT NULL AND run_now_requested_at <= ? THEN NULL
                        ELSE run_now_requested_at
                    END
                WHERE id = ?
            """) { stmt in
                self.bind(stmt, 1, occurrenceAt.timeIntervalSinceReferenceDate)
                self.bind(stmt, 2, now.timeIntervalSinceReferenceDate)
                self.bind(stmt, 3, status.rawValue)
                self.bind(stmt, 4, occurrenceAt.timeIntervalSinceReferenceDate)
                self.bind(stmt, 5, taskID)
            }
            try pruneScheduledTaskRuns(taskID: taskID)
            try exec("COMMIT")
            claimed = run
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return claimed
    }

    /// Records the outcome of a claimed run. `retryAt` on a failed run is when
    /// it is tried again (`ScheduledTaskRetry`); nil settles it.
    func finishScheduledTaskRun(
        runID: String,
        status: ScheduledTaskRunStatus,
        sessionID: String?,
        message: String?,
        retryAt: Date? = nil,
        finishedAt: Date = Date()
    ) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            var taskID: String?
            try queryBind("SELECT task_id FROM scheduled_task_runs WHERE id = ? LIMIT 1", bind: { stmt in
                self.bind(stmt, 1, runID)
            }) { stmt in
                taskID = self.string(stmt, 0)
            }
            guard let taskID else {
                try exec("ROLLBACK")
                return
            }
            try execBind("""
                UPDATE scheduled_task_runs
                SET status = ?, session_id = ?, message = ?, finished_at = ?, retry_at = ?
                WHERE id = ?
            """) { stmt in
                self.bind(stmt, 1, status.rawValue)
                self.bind(stmt, 2, sessionID)
                self.bind(stmt, 3, message)
                self.bind(stmt, 4, finishedAt.timeIntervalSinceReferenceDate)
                self.bind(stmt, 5, status == .failed ? retryAt?.timeIntervalSinceReferenceDate : nil)
                self.bind(stmt, 6, runID)
            }
            try execBind("""
                UPDATE scheduled_tasks
                SET last_run_status = ?, last_run_at = ?
                WHERE id = ?
            """) { stmt in
                self.bind(stmt, 1, status.rawValue)
                self.bind(stmt, 2, finishedAt.timeIntervalSinceReferenceDate)
                self.bind(stmt, 3, taskID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Atomically takes the next try of a failed run whose `retry_at` has
    /// come. Returns the receipt as it now reads — `running`, its attempt one
    /// higher, no retry pending — or nil when there is nothing to take: the
    /// try is not due, another launch took it, a newer run superseded it, or
    /// the task was paused. The receipt keeps its first `started_at`.
    func claimScheduledTaskRetry(runID: String, now: Date = Date()) throws -> ScheduledTaskRun? {
        var claimed: ScheduledTaskRun?
        try exec("BEGIN IMMEDIATE")
        do {
            try execBind("""
                UPDATE scheduled_task_runs
                SET status = 'running',
                    attempt = attempt + 1,
                    retry_at = NULL,
                    finished_at = NULL
                WHERE id = ?
                  AND status = 'failed'
                  AND retry_at IS NOT NULL
                  AND retry_at <= ?
                  AND EXISTS (
                        SELECT 1 FROM scheduled_tasks t
                        WHERE t.id = scheduled_task_runs.task_id AND t.is_enabled = 1
                  )
            """) { stmt in
                self.bind(stmt, 1, runID)
                self.bind(stmt, 2, now.timeIntervalSinceReferenceDate)
            }
            guard sqlite3_changes(db) > 0 else {
                try exec("ROLLBACK")
                return nil
            }
            try queryBind("""
                SELECT id, task_id, occurrence_at, started_at, finished_at, status, session_id, message, device_name,
                       attempt, retry_at
                FROM scheduled_task_runs
                WHERE id = ?
                LIMIT 1
            """, bind: { stmt in
                self.bind(stmt, 1, runID)
            }) { stmt in
                claimed = self.scheduledTaskRun(from: stmt)
            }
            guard let run = claimed else {
                try exec("ROLLBACK")
                return nil
            }
            try execBind("""
                UPDATE scheduled_tasks
                SET last_run_status = 'running', last_run_at = ?
                WHERE id = ?
            """) { stmt in
                self.bind(stmt, 1, now.timeIntervalSinceReferenceDate)
                self.bind(stmt, 2, run.taskID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        return claimed
    }

    /// Settles a failed run whose next try will not be made — it came due
    /// while ForeverLM was closed or the Mac slept past the catch-up window —
    /// and says so on the receipt, after the failure it already carries.
    func abandonScheduledTaskRetry(runID: String, note: String, now: Date = Date()) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            var taskID: String?
            try queryBind("""
                SELECT task_id FROM scheduled_task_runs
                WHERE id = ? AND status = 'failed' AND retry_at IS NOT NULL
                LIMIT 1
            """, bind: { stmt in
                self.bind(stmt, 1, runID)
            }) { stmt in
                taskID = self.string(stmt, 0)
            }
            guard taskID != nil else {
                try exec("ROLLBACK")
                return
            }
            try execBind("""
                UPDATE scheduled_task_runs
                SET retry_at = NULL,
                    message = CASE
                        WHEN message IS NULL OR message = '' THEN ?
                        ELSE message || ' ' || ?
                    END
                WHERE id = ?
            """) { stmt in
                self.bind(stmt, 1, note)
                self.bind(stmt, 2, note)
                self.bind(stmt, 3, runID)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// A run left `running` by a quit or crash is not evidence that anything is
    /// still generating. Called once at launch so the surface never shows a
    /// spinner nothing is behind.
    ///
    /// `deviceName` is this Mac's: a run another Mac is generating right now arrives here as `running`
    /// too, and its receipt is that Mac's to settle, never this launch's. A receipt with no device name
    /// (written before they were kept) is settled by whichever launch finds it.
    @discardableResult
    func failInterruptedScheduledTaskRuns(now: Date = Date(), deviceName: String? = nil) throws -> Int {
        var interrupted: [String] = []
        let own = deviceName.map { _ in " AND (device_name IS NULL OR device_name = ?)" } ?? ""
        try queryBind("SELECT DISTINCT task_id FROM scheduled_task_runs WHERE status = 'running'\(own)", bind: { stmt in
            if let deviceName { self.bind(stmt, 1, deviceName) }
        }) { stmt in
            if let id = self.string(stmt, 0) { interrupted.append(id) }
        }
        guard !interrupted.isEmpty else { return 0 }
        try execBind("""
            UPDATE scheduled_task_runs
            SET status = 'failed',
                finished_at = ?,
                message = COALESCE(message, 'ForeverLM closed before this run finished.')
            WHERE status = 'running'\(own.isEmpty ? "" : " AND (device_name IS NULL OR device_name = ?)")
        """) { stmt in
            self.bind(stmt, 1, now.timeIntervalSinceReferenceDate)
            if let deviceName { self.bind(stmt, 2, deviceName) }
        }
        for taskID in interrupted {
            try execBind("UPDATE scheduled_tasks SET last_run_status = 'failed' WHERE id = ? AND last_run_status = 'running'") { stmt in
                self.bind(stmt, 1, taskID)
            }
        }
        return interrupted.count
    }

    // MARK: - CloudKit

    // MARK: - Row plumbing

    private static let scheduledTaskColumns = """
        SELECT id, title, instruction, notebook_id, source_ids, cadence, weekday, day_of_month,
               hour, minute, time_zone, start_date, is_enabled, created_at, updated_at,
               last_occurrence_at, last_run_at, last_run_status, run_now_requested_at
        FROM scheduled_tasks
    """

    private func writeScheduledTaskRow(_ task: ScheduledTask) throws {
        try execBind("""
            INSERT INTO scheduled_tasks (
                id, title, instruction, notebook_id, source_ids, cadence, weekday, day_of_month,
                hour, minute, time_zone, start_date, is_enabled, created_at, updated_at,
                last_occurrence_at, last_run_at, last_run_status, run_now_requested_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                instruction = excluded.instruction,
                notebook_id = excluded.notebook_id,
                source_ids = excluded.source_ids,
                cadence = excluded.cadence,
                weekday = excluded.weekday,
                day_of_month = excluded.day_of_month,
                hour = excluded.hour,
                minute = excluded.minute,
                time_zone = excluded.time_zone,
                start_date = excluded.start_date,
                is_enabled = excluded.is_enabled,
                updated_at = excluded.updated_at,
                last_occurrence_at = excluded.last_occurrence_at,
                last_run_at = excluded.last_run_at,
                last_run_status = excluded.last_run_status,
                run_now_requested_at = excluded.run_now_requested_at
        """) { stmt in
            self.bind(stmt, 1, task.id)
            self.bind(stmt, 2, task.title)
            self.bind(stmt, 3, task.instruction)
            self.bind(stmt, 4, task.notebookID)
            self.bind(stmt, 5, self.jsonString(from: task.sourceIDs))
            self.bind(stmt, 6, task.cadence.rawValue)
            self.bind(stmt, 7, task.weekday)
            self.bind(stmt, 8, task.dayOfMonth)
            self.bind(stmt, 9, task.hour)
            self.bind(stmt, 10, task.minute)
            self.bind(stmt, 11, task.timeZoneID)
            self.bind(stmt, 12, task.startDate?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 13, task.isEnabled ? 1 : 0)
            self.bind(stmt, 14, task.createdAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 15, task.updatedAt.timeIntervalSinceReferenceDate)
            self.bind(stmt, 16, task.lastOccurrenceAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 17, task.lastRunAt?.timeIntervalSinceReferenceDate)
            self.bind(stmt, 18, task.lastRunStatus?.rawValue)
            self.bind(stmt, 19, task.runNowRequestedAt?.timeIntervalSinceReferenceDate)
        }
    }

    private func insertScheduledTaskRun(_ run: ScheduledTaskRun) throws {
        try execBind("""
            INSERT INTO scheduled_task_runs (
                id, task_id, occurrence_at, started_at, finished_at, status, session_id, message, device_name,
                attempt, retry_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """) { stmt in
            self.bindScheduledTaskRun(stmt, run)
        }
    }

    private func bindScheduledTaskRun(_ stmt: OpaquePointer?, _ run: ScheduledTaskRun) {
        bind(stmt, 1, run.id)
        bind(stmt, 2, run.taskID)
        bind(stmt, 3, run.occurrenceAt.timeIntervalSinceReferenceDate)
        bind(stmt, 4, run.startedAt.timeIntervalSinceReferenceDate)
        bind(stmt, 5, run.finishedAt?.timeIntervalSinceReferenceDate)
        bind(stmt, 6, run.status.rawValue)
        bind(stmt, 7, run.sessionID)
        bind(stmt, 8, run.message)
        bind(stmt, 9, run.deviceName)
        bind(stmt, 10, run.attempt)
        bind(stmt, 11, run.retryAt?.timeIntervalSinceReferenceDate)
    }

    /// Keeps the receipt list bounded so one long-lived daily task cannot grow
    /// its CloudKit payload without limit.
    private func pruneScheduledTaskRuns(taskID: String) throws {
        try execBind("""
            DELETE FROM scheduled_task_runs
            WHERE task_id = ?
              AND id NOT IN (
                    SELECT id FROM scheduled_task_runs
                    WHERE task_id = ?
                    ORDER BY occurrence_at DESC
                    LIMIT ?
              )
        """) { stmt in
            self.bind(stmt, 1, taskID)
            self.bind(stmt, 2, taskID)
            self.bind(stmt, 3, ScheduledTask.retainedRunCount)
        }
    }

    private func scheduledTask(from stmt: OpaquePointer?) -> ScheduledTask? {
        guard let id = string(stmt, 0),
              let title = string(stmt, 1),
              let instruction = string(stmt, 2) else { return nil }
        return ScheduledTask(
            id: id,
            title: title,
            instruction: instruction,
            notebookID: string(stmt, 3),
            sourceIDs: decodeStringArray(json: string(stmt, 4)) ?? [],
            cadence: ScheduledTaskCadence(rawValue: string(stmt, 5) ?? "") ?? .daily,
            weekday: optionalInt(stmt, 6),
            dayOfMonth: optionalInt(stmt, 7),
            hour: Int(sqlite3_column_int(stmt, 8)),
            minute: Int(sqlite3_column_int(stmt, 9)),
            timeZoneID: string(stmt, 10),
            startDate: optionalDouble(stmt, 11).map { Date(timeIntervalSinceReferenceDate: $0) },
            isEnabled: sqlite3_column_int(stmt, 12) != 0,
            createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 13)),
            updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 14)),
            lastOccurrenceAt: optionalDouble(stmt, 15).map { Date(timeIntervalSinceReferenceDate: $0) },
            lastRunAt: optionalDouble(stmt, 16).map { Date(timeIntervalSinceReferenceDate: $0) },
            lastRunStatus: string(stmt, 17).flatMap(ScheduledTaskRunStatus.init(rawValue:)),
            runNowRequestedAt: optionalDouble(stmt, 18).map { Date(timeIntervalSinceReferenceDate: $0) }
        )
    }

    private func scheduledTaskRun(from stmt: OpaquePointer?) -> ScheduledTaskRun? {
        guard let id = string(stmt, 0), let taskID = string(stmt, 1) else { return nil }
        return ScheduledTaskRun(
            id: id,
            taskID: taskID,
            occurrenceAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2)),
            startedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3)),
            finishedAt: optionalDouble(stmt, 4).map { Date(timeIntervalSinceReferenceDate: $0) },
            status: ScheduledTaskRunStatus(rawValue: string(stmt, 5) ?? "") ?? .failed,
            sessionID: string(stmt, 6),
            message: string(stmt, 7),
            deviceName: string(stmt, 8),
            attempt: optionalInt(stmt, 9) ?? 1,
            retryAt: optionalDouble(stmt, 10).map { Date(timeIntervalSinceReferenceDate: $0) }
        )
    }
}
