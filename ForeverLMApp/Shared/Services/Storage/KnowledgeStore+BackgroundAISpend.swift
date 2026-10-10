import Foundation
import SQLite3

// MARK: - Bulk re-queues held for the learner (schema 135)
//
// `background_ai_bulk_jobs` holds one pending decision per paid queue, and
// `background_ai_bulk_job_sources` the sources it holds. Both are local-only,
// like the queues they gate: each Mac drains its own queues, so each Mac asks.
// A held source keeps its ordinary queue row; the drains' candidate queries
// pass over it (`bulkHoldExclusion`) until the learner decides. A later
// single-source enqueue moves the row's `enqueued_at` past `held_at`, which
// releases it, so a paper the learner re-fetches is cleaned as usual.

extension KnowledgeStore {
    /// Runs `enqueue`, then holds every source it newly placed or re-armed in
    /// `queue` for the learner's decision when there are more of them than
    /// `BackgroundAIBulkQueue.learnerDecisionThreshold`. Fewer drain as before.
    ///
    /// Set-based and bounded by the queue: one copy of the queue's ids into a
    /// temporary table before, one insert of the difference after. Safe inside
    /// the migration transaction, which is where historical re-queues run.
    @discardableResult
    func holdingBulkRequeue(
        into queue: BackgroundAIBulkQueue,
        reason: String,
        affectedSources: BulkRequeueAffectedSources,
        _ enqueue: () throws -> Int
    ) throws -> Int {
        let table = queue.tableName
        try exec("DROP TABLE IF EXISTS temp.background_ai_bulk_requeue_before")
        try exec("""
            CREATE TEMP TABLE background_ai_bulk_requeue_before AS
            SELECT source_id, enqueued_at FROM \(table)
        """)
        try exec("""
            CREATE INDEX temp.background_ai_bulk_requeue_before_source
            ON background_ai_bulk_requeue_before(source_id)
        """)
        defer { try? exec("DROP TABLE IF EXISTS temp.background_ai_bulk_requeue_before") }

        let result = try enqueue()
        let heldAt = Date().timeIntervalSinceReferenceDate

        var jobID: String?
        try queryBind("""
            SELECT id FROM background_ai_bulk_jobs
            WHERE queue = ? AND status = 'pending'
            LIMIT 1
        """, bind: { stmt in
            self.bind(stmt, 1, queue.rawValue)
        }) { stmt in
            jobID = self.string(stmt, 0)
        }
        let createdJob = jobID == nil
        let id = jobID ?? UUID().uuidString
        if createdJob {
            try execBind("""
                INSERT INTO background_ai_bulk_jobs (id, queue, reason, created_at, status)
                VALUES (?, ?, ?, ?, 'pending')
            """) { stmt in
                self.bind(stmt, 1, id)
                self.bind(stmt, 2, queue.rawValue)
                self.bind(stmt, 3, reason)
                sqlite3_bind_double(stmt, 4, heldAt)
            }
        } else {
            try execBind("UPDATE background_ai_bulk_jobs SET reason = ? WHERE id = ?") { stmt in
                self.bind(stmt, 1, reason)
                self.bind(stmt, 2, id)
            }
        }

        let affectedExpression: String
        switch affectedSources {
        case .unknown:
            affectedExpression = "NULL"
        case .matching(let sql):
            affectedExpression = "CASE WHEN (\(sql)) THEN 1 ELSE 0 END"
        }
        try execBind("""
            INSERT INTO background_ai_bulk_job_sources (job_id, source_id, affected, held_at)
            SELECT ?1, q.source_id, \(affectedExpression), ?2
            FROM \(table) q
            JOIN sources s ON s.id = q.source_id
            LEFT JOIN paper_content_preparations pp ON pp.source_id = s.id
            LEFT JOIN article_content_preparations ap ON ap.source_id = s.id
            LEFT JOIN temp.background_ai_bulk_requeue_before b ON b.source_id = q.source_id
            -- Never a source whose ingestion waits on this queue: adding a
            -- source is the learner's own request.
            WHERE s.state IN ('ready', 'error')
              AND (b.source_id IS NULL OR b.enqueued_at IS NOT q.enqueued_at)
            ON CONFLICT(job_id, source_id) DO UPDATE SET
                affected = CASE
                    WHEN background_ai_bulk_job_sources.affected IS NULL
                      OR excluded.affected IS NULL THEN NULL
                    ELSE MAX(background_ai_bulk_job_sources.affected, excluded.affected)
                END,
                held_at = excluded.held_at
        """) { stmt in
            self.bind(stmt, 1, id)
            sqlite3_bind_double(stmt, 2, heldAt)
        }

        var memberCount = 0
        try queryBind("SELECT COUNT(*) FROM background_ai_bulk_job_sources WHERE job_id = ?", bind: { stmt in
            self.bind(stmt, 1, id)
        }) { stmt in
            memberCount = Int(sqlite3_column_int64(stmt, 0))
        }
        if createdJob, memberCount <= BackgroundAIBulkQueue.learnerDecisionThreshold {
            try deleteBackgroundAIBulkJobRows(id)
        } else if memberCount > 0 {
            logger.notice("Held \(memberCount, privacy: .public) source(s) in \(queue.rawValue, privacy: .public) for the learner's decision: \(reason, privacy: .public)")
        }
        return result
    }

    /// The condition a drain's candidate query adds so held sources wait.
    /// `queueAlias` names the queue table's alias in that query.
    static func bulkHoldExclusion(_ queue: BackgroundAIBulkQueue, queueAlias: String = "q") -> String {
        """
        NOT EXISTS (
            SELECT 1
            FROM background_ai_bulk_job_sources hold
            JOIN background_ai_bulk_jobs job ON job.id = hold.job_id
            WHERE hold.source_id = \(queueAlias).source_id
              AND job.queue = '\(queue.rawValue)'
              AND job.status = 'pending'
              AND \(queueAlias).enqueued_at <= hold.held_at
        )
        """
    }

    private func deleteBackgroundAIBulkJobRows(_ jobID: String) throws {
        try execBind("DELETE FROM background_ai_bulk_job_sources WHERE job_id = ?") { stmt in
            self.bind(stmt, 1, jobID)
        }
        try execBind("DELETE FROM background_ai_bulk_jobs WHERE id = ?") { stmt in
            self.bind(stmt, 1, jobID)
        }
    }

    /// Every decision still waiting, with the count it holds and the ledger's
    /// estimate. A job whose sources have all been released (deleted, archived,
    /// re-queued one by one) is retired here rather than shown as zero.
    func pendingBackgroundAIBulkJobs(now: Date = Date()) throws -> [BackgroundAIBulkJob] {
        var rows: [(id: String, queue: BackgroundAIBulkQueue, reason: String, createdAt: Date)] = []
        try query("""
            SELECT id, queue, reason, created_at
            FROM background_ai_bulk_jobs
            WHERE status = 'pending'
            ORDER BY created_at, id
        """) { stmt in
            guard let id = self.string(stmt, 0),
                  let rawQueue = self.string(stmt, 1),
                  let queue = BackgroundAIBulkQueue(rawValue: rawQueue) else { return }
            rows.append((
                id,
                queue,
                self.string(stmt, 2) ?? "",
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            ))
        }

        var jobs: [BackgroundAIBulkJob] = []
        let since = now.addingTimeInterval(-Double(BackgroundAIBulkQueue.costSampleWindowDays) * 86_400)
        for row in rows {
            var held = 0
            var affected = 0
            var unknownAffected = 0
            try queryBind("""
                SELECT COUNT(*),
                       COALESCE(SUM(CASE WHEN hold.affected = 1 THEN 1 ELSE 0 END), 0),
                       COALESCE(SUM(CASE WHEN hold.affected IS NULL THEN 1 ELSE 0 END), 0)
                FROM background_ai_bulk_job_sources hold
                JOIN \(row.queue.tableName) q ON q.source_id = hold.source_id
                WHERE hold.job_id = ?
                  AND q.enqueued_at <= hold.held_at
            """, bind: { stmt in
                self.bind(stmt, 1, row.id)
            }) { stmt in
                held = Int(sqlite3_column_int64(stmt, 0))
                affected = Int(sqlite3_column_int64(stmt, 1))
                unknownAffected = Int(sqlite3_column_int64(stmt, 2))
            }
            guard held > 0 else {
                try execBind("""
                    UPDATE background_ai_bulk_jobs
                    SET status = 'released', decided_at = ?
                    WHERE id = ?
                """) { stmt in
                    sqlite3_bind_double(stmt, 1, now.timeIntervalSinceReferenceDate)
                    self.bind(stmt, 2, row.id)
                }
                try execBind("DELETE FROM background_ai_bulk_job_sources WHERE job_id = ?") { stmt in
                    self.bind(stmt, 1, row.id)
                }
                continue
            }
            jobs.append(BackgroundAIBulkJob(
                id: row.id,
                queue: row.queue,
                reason: row.reason,
                createdAt: row.createdAt,
                heldSourceCount: held,
                affectedSourceCount: unknownAffected > 0 ? nil : affected,
                costSample: try backgroundAICostSample(task: row.queue.task, since: since, until: now)
            ))
        }
        return jobs
    }

    struct BackgroundAIBulkDecisionOutcome: Equatable, Sendable {
        let jobID: String
        let queue: BackgroundAIBulkQueue
        let decision: BackgroundAIBulkDecision
        /// Sources left in the queue to drain.
        let releasedCount: Int
        /// Sources taken out of the queue unrun.
        let droppedCount: Int
    }

    /// Applies the learner's choice. Run all releases every held source; run
    /// affected releases those the change reaches and takes the rest out of
    /// the queue; skip takes them all out. A skipped source keeps the text it
    /// has, as if the re-queue had never happened.
    func decideBackgroundAIBulkJob(
        id: String,
        decision: BackgroundAIBulkDecision,
        now: Date = Date()
    ) throws -> BackgroundAIBulkDecisionOutcome {
        try exec("BEGIN IMMEDIATE")
        do {
            var queue: BackgroundAIBulkQueue?
            try queryBind("""
                SELECT queue FROM background_ai_bulk_jobs
                WHERE id = ? AND status = 'pending'
            """, bind: { stmt in
                self.bind(stmt, 1, id)
            }) { stmt in
                queue = self.string(stmt, 0).flatMap(BackgroundAIBulkQueue.init(rawValue:))
            }
            guard let queue else {
                throw KnowledgeStoreError.invalidData("No bulk re-queue \(id) is waiting for a decision.")
            }
            let table = queue.tableName
            if decision == .runAffected {
                var unknown = 0
                try queryBind("""
                    SELECT COUNT(*) FROM background_ai_bulk_job_sources
                    WHERE job_id = ? AND affected IS NULL
                """, bind: { stmt in
                    self.bind(stmt, 1, id)
                }) { stmt in
                    unknown = Int(sqlite3_column_int64(stmt, 0))
                }
                guard unknown == 0 else {
                    throw KnowledgeStoreError.invalidData(
                        "This change cannot say which sources it affects; choose run_all or skip."
                    )
                }
            }

            let dropFilter: String?
            switch decision {
            case .runAll: dropFilter = nil
            case .runAffected: dropFilter = "hold.affected = 0"
            case .skip: dropFilter = "1"
            }
            var dropped = 0
            if let dropFilter {
                try execBind("""
                    DELETE FROM \(table)
                    WHERE EXISTS (
                        SELECT 1 FROM background_ai_bulk_job_sources hold
                        WHERE hold.job_id = ?
                          AND hold.source_id = \(table).source_id
                          AND \(table).enqueued_at <= hold.held_at
                          AND \(dropFilter)
                    )
                """) { stmt in
                    self.bind(stmt, 1, id)
                }
                dropped = Int(sqlite3_changes(db))
            }
            var released = 0
            try queryBind("""
                SELECT COUNT(*)
                FROM background_ai_bulk_job_sources hold
                JOIN \(table) q ON q.source_id = hold.source_id
                WHERE hold.job_id = ?
                  AND q.enqueued_at <= hold.held_at
            """, bind: { stmt in
                self.bind(stmt, 1, id)
            }) { stmt in
                released = Int(sqlite3_column_int64(stmt, 0))
            }
            // A run keeps its members while the drain works through them, so
            // the learner can still stop it (`stopBackgroundAIBulkJob`); a
            // member stops counting once the drain has taken its queue row.
            // Skipped sources left the queue above and are forgotten now.
            if decision == .skip {
                try execBind("DELETE FROM background_ai_bulk_job_sources WHERE job_id = ?") { stmt in
                    self.bind(stmt, 1, id)
                }
            }
            try execBind("""
                UPDATE background_ai_bulk_jobs
                SET status = ?, decided_at = ?
                WHERE id = ?
            """) { stmt in
                self.bind(stmt, 1, decision.rawValue)
                sqlite3_bind_double(stmt, 2, now.timeIntervalSinceReferenceDate)
                self.bind(stmt, 3, id)
            }
            try exec("COMMIT")
            return BackgroundAIBulkDecisionOutcome(
                jobID: id,
                queue: queue,
                decision: decision,
                releasedCount: released,
                droppedCount: dropped
            )
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Stopping a released run (2026-09-27)
    //
    // The product owner: "make sure there are cancel tools for each process that gets
    // triggered via the mcp that costs money". A run_all or run_affected
    // decision is such a process: it hands every held source to a paid drain
    // that takes hours. Stopping it puts what the drain has not reached back on
    // hold, so the learner decides again (skip drops it) and nothing is lost.

    /// A released bulk re-queue the drain is still working through.
    struct RunningBackgroundAIBulkJob: Equatable, Sendable {
        let id: String
        let queue: BackgroundAIBulkQueue
        let reason: String
        let decision: BackgroundAIBulkDecision
        let decidedAt: Date?
        /// Released sources still waiting in the queue.
        let remainingSourceCount: Int
    }

    /// Every released run with sources left to drain. A run the drain has
    /// finished forgets its members here, so the next read skips it.
    func runningBackgroundAIBulkJobs() throws -> [RunningBackgroundAIBulkJob] {
        var rows: [(id: String, queue: BackgroundAIBulkQueue, reason: String, decision: BackgroundAIBulkDecision, decidedAt: Date?)] = []
        try query("""
            SELECT id, queue, reason, status, decided_at
            FROM background_ai_bulk_jobs job
            WHERE status IN ('\(BackgroundAIBulkDecision.runAll.rawValue)', '\(BackgroundAIBulkDecision.runAffected.rawValue)')
              AND EXISTS (SELECT 1 FROM background_ai_bulk_job_sources hold WHERE hold.job_id = job.id)
            ORDER BY decided_at, id
        """) { stmt in
            guard let id = self.string(stmt, 0),
                  let queue = self.string(stmt, 1).flatMap(BackgroundAIBulkQueue.init(rawValue:)),
                  let decision = self.string(stmt, 3).flatMap(BackgroundAIBulkDecision.init(rawValue:)) else { return }
            let decidedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            rows.append((id, queue, self.string(stmt, 2) ?? "", decision, decidedAt))
        }

        var running: [RunningBackgroundAIBulkJob] = []
        for row in rows {
            let remaining = try remainingBulkJobSourceCount(jobID: row.id, queue: row.queue)
            guard remaining > 0 else {
                try execBind("DELETE FROM background_ai_bulk_job_sources WHERE job_id = ?") { stmt in
                    self.bind(stmt, 1, row.id)
                }
                continue
            }
            running.append(RunningBackgroundAIBulkJob(
                id: row.id,
                queue: row.queue,
                reason: row.reason,
                decision: row.decision,
                decidedAt: row.decidedAt,
                remainingSourceCount: remaining
            ))
        }
        return running
    }

    struct BackgroundAIBulkStopOutcome: Equatable, Sendable {
        let jobID: String
        let queue: BackgroundAIBulkQueue
        /// The pending decision that now holds what was left: this job again,
        /// or the queue's newer pending job it was folded into. Nil when the
        /// drain had already finished.
        let heldJobID: String?
        let heldSourceCount: Int
    }

    /// Stops a released run: the sources the drain has not reached are held
    /// for the learner's decision again, in `get_background_ai_jobs` and the
    /// sidebar. A source the drain has already picked up finishes.
    func stopBackgroundAIBulkJob(id: String) throws -> BackgroundAIBulkStopOutcome {
        try exec("BEGIN IMMEDIATE")
        do {
            var found: (queue: BackgroundAIBulkQueue, decision: BackgroundAIBulkDecision?)?
            try queryBind("SELECT queue, status FROM background_ai_bulk_jobs WHERE id = ?", bind: { stmt in
                self.bind(stmt, 1, id)
            }) { stmt in
                guard let queue = self.string(stmt, 0).flatMap(BackgroundAIBulkQueue.init(rawValue:)) else { return }
                found = (queue, self.string(stmt, 1).flatMap(BackgroundAIBulkDecision.init(rawValue:)))
            }
            guard let found, found.decision == .runAll || found.decision == .runAffected else {
                throw KnowledgeStoreError.invalidData("No released bulk re-queue \(id) is draining.")
            }
            let table = found.queue.tableName
            // Forget what the drain has finished; what is left is the hold.
            try execBind("""
                DELETE FROM background_ai_bulk_job_sources
                WHERE job_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM \(table) q
                      WHERE q.source_id = background_ai_bulk_job_sources.source_id
                        AND q.enqueued_at <= background_ai_bulk_job_sources.held_at
                  )
            """) { stmt in
                self.bind(stmt, 1, id)
            }
            let remaining = try remainingBulkJobSourceCount(jobID: id, queue: found.queue)
            guard remaining > 0 else {
                try exec("COMMIT")
                return BackgroundAIBulkStopOutcome(jobID: id, queue: found.queue, heldJobID: nil, heldSourceCount: 0)
            }

            var pendingID: String?
            try queryBind("""
                SELECT id FROM background_ai_bulk_jobs
                WHERE queue = ? AND status = 'pending'
                LIMIT 1
            """, bind: { stmt in
                self.bind(stmt, 1, found.queue.rawValue)
            }) { stmt in
                pendingID = self.string(stmt, 0)
            }
            let heldJobID: String
            if let pendingID {
                // One pending decision per queue: a newer bulk re-queue is
                // already waiting, so the rest joins it.
                try execBind("""
                    INSERT INTO background_ai_bulk_job_sources (job_id, source_id, affected, held_at)
                    SELECT ?1, source_id, affected, held_at
                    FROM background_ai_bulk_job_sources
                    WHERE job_id = ?2
                    ON CONFLICT(job_id, source_id) DO UPDATE SET
                        affected = CASE
                            WHEN background_ai_bulk_job_sources.affected IS NULL
                              OR excluded.affected IS NULL THEN NULL
                            ELSE MAX(background_ai_bulk_job_sources.affected, excluded.affected)
                        END,
                        held_at = MAX(background_ai_bulk_job_sources.held_at, excluded.held_at)
                """) { stmt in
                    self.bind(stmt, 1, pendingID)
                    self.bind(stmt, 2, id)
                }
                try execBind("DELETE FROM background_ai_bulk_job_sources WHERE job_id = ?") { stmt in
                    self.bind(stmt, 1, id)
                }
                heldJobID = pendingID
            } else {
                try execBind("""
                    UPDATE background_ai_bulk_jobs
                    SET status = 'pending', decided_at = NULL
                    WHERE id = ?
                """) { stmt in
                    self.bind(stmt, 1, id)
                }
                heldJobID = id
            }
            let held = try remainingBulkJobSourceCount(jobID: heldJobID, queue: found.queue)
            try exec("COMMIT")
            return BackgroundAIBulkStopOutcome(jobID: id, queue: found.queue, heldJobID: heldJobID, heldSourceCount: held)
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// A job's members whose queue row is still the one it held.
    private func remainingBulkJobSourceCount(jobID: String, queue: BackgroundAIBulkQueue) throws -> Int {
        var count = 0
        try queryBind("""
            SELECT COUNT(*)
            FROM background_ai_bulk_job_sources hold
            JOIN \(queue.tableName) q ON q.source_id = hold.source_id
            WHERE hold.job_id = ?
              AND q.enqueued_at <= hold.held_at
        """, bind: { stmt in
            self.bind(stmt, 1, jobID)
        }) { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    // MARK: - Ledger reads

    /// The rows the spend controls read: the ones this account's devices
    /// wrote as each call returned (`server_ledger_id IS NULL`), own-key calls
    /// included. Not the proxy's mirror: it is imported only on events such as
    /// opening Settings › AI Usage, so it lags by hours, and it repeats calls
    /// these rows already carry.
    private static let spendControlRowPredicate = "server_ledger_id IS NULL"

    /// What recent history says one source of `task` costs: per source, the
    /// sum of its calls for the task in the window, averaged over the sources
    /// whose every call is priced.
    func backgroundAICostSample(task: AITask, since: Date, until: Date) throws -> BackgroundAICostSample {
        var sample = BackgroundAICostSample.empty
        try queryBind("""
            SELECT SUM(cost), SUM(CASE WHEN cost IS NULL THEN 1 ELSE 0 END)
            FROM (
                SELECT subject_id, \(Self.aiUsageEventCostExpression) AS cost
                FROM ai_usage_events
                WHERE \(Self.spendControlRowPredicate)
                  AND task = ?
                  AND subject_id IS NOT NULL
                  AND subject_id != ''
                  AND created_at >= ?
                  AND created_at < ?
            )
            GROUP BY subject_id
        """, bind: { stmt in
            self.bind(stmt, 1, task.rawValue)
            sqlite3_bind_double(stmt, 2, since.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 3, until.timeIntervalSinceReferenceDate)
        }) { stmt in
            if sqlite3_column_int64(stmt, 1) > 0 {
                sample.unpricedSourceCount += 1
            } else {
                sample.pricedSourceCount += 1
                sample.pricedTotalUSD += sqlite3_column_double(stmt, 0)
            }
        }
        return sample
    }

    /// Dollars background tasks spent in `[start, end)`. An unpriced call adds
    /// nothing it cannot prove; the count of such calls is the Usage pane's to
    /// report.
    func backgroundAISpendUSD(from start: Date, to end: Date) throws -> Double {
        let tasks = AITask.backgroundWorkTaskIDs
        let placeholders = tasks.map { _ in "?" }.joined(separator: ", ")
        var spent = 0.0
        try queryBind("""
            SELECT COALESCE(SUM(\(Self.aiUsageEventCostExpression)), 0)
            FROM ai_usage_events
            WHERE \(Self.spendControlRowPredicate)
              AND created_at >= ?
              AND created_at < ?
              AND task IN (\(placeholders))
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, start.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 2, end.timeIntervalSinceReferenceDate)
            for (offset, task) in tasks.enumerated() {
                self.bind(stmt, offset + 3, task)
            }
        }) { stmt in
            spent = sqlite3_column_double(stmt, 0)
        }
        return spent
    }
}
