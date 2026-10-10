import Foundation

// MARK: - Spend control for background AI, from a chat (2026-09-24)
//
// The sidebar row that asks about a bulk re-queue, and Settings › AI Usage's
// daily background cap, each have a chat equivalent (settings-need-mcp-parity):
// `get_background_ai_jobs` / `decide_background_ai_job` here, and the cap as
// the `billing.background_daily_cap_usd` entry of `get_app_settings` /
// `set_app_setting`. Decisions go through `notebookFileStorage`, the same
// StorageService call the sidebar's buttons make, never the MCP connection.
//
// Gathered by `settingsParityToolDefs` / `executeSettingsParityTool` in
// MCPTools+AppSettings.swift.

extension MCPToolRegistry {
    static var backgroundAISpendToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "get_background_ai_jobs",
                description: "List the bulk re-queues waiting for the learner before they spend: when an update or a bulk change puts more than \(BackgroundAIBulkQueue.learnerDecisionThreshold) sources into a paid background queue (source clean-up, Listen preparation, podcast ad clean-up), nothing in it runs until the learner decides, and the sources sidebar shows the same question. Each job has its id, the queue, the reason (what changed), how many sources it holds, how many of them the change affects (null when the change cannot say), and an estimate from the learner's own AI usage ledger — the average cost per source of that queue's task over the last \(BackgroundAIBulkQueue.costSampleWindowDays) days times the count, or null with cost_known false when the ledger has no priced history. Also reports today's background AI spend against the daily cap (billing.background_daily_cap_usd in get_app_settings). Put the count and estimate to the learner before calling decide_background_ai_job.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "decide_background_ai_job",
                description: "Answer one held bulk re-queue from get_background_ai_jobs, exactly as the sidebar's buttons do. decision run_all releases every held source to the queue's drain; run_affected releases only the sources the change affects and takes the rest out of the queue (refused when the job's affected count is null); skip takes them all out, and each keeps the text it has. run_all and run_affected spend money — read the estimate and ask the learner first. Returns how many sources were released and how many were dropped, and for a run the work_id cancel_ai_work stops it by: the sources the drain has not reached then wait here for a decision again.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "job_id": ["type": "string", "description": "The job's id from get_background_ai_jobs."],
                        "decision": ["type": "string", "enum": BackgroundAIBulkDecision.allCases.map(\.rawValue), "description": "run_all, run_affected or skip."],
                    ],
                    "required": ["job_id", "decision"],
                ]
            ),
        ]
    }

    static let backgroundAISpendReadOnlyToolNames: Set<String> = ["get_background_ai_jobs"]
}

extension MCPDataStore {
    func executeBackgroundAISpendTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "get_background_ai_jobs":
            return try await backgroundAIJobsPayload()
        case "decide_background_ai_job":
            return try await decideBackgroundAIJob(
                jobID: arguments["job_id"] as? String,
                decision: arguments["decision"] as? String
            )
        default:
            return nil
        }
    }

    private func backgroundAIJobsPayload() async throws -> String {
        let jobs = try await notebookFileStorage.pendingBackgroundAIBulkJobs()
        let day = BackgroundAIDailyCap.localDay(containing: Date())
        let spentToday = try await notebookFileStorage.backgroundAISpendUSD(from: day.start, to: day.end)
        let cap = BackgroundAIDailyCap.capUSD()
        var capPayload: [String: Any] = [
            "setting": "billing.background_daily_cap_usd",
            "spent_today_usd": spentToday,
            "cap_usd": cap.map { $0 as Any } ?? NSNull(),
            "reached": BackgroundAIDailyCap.status(spentUSD: spentToday, capUSD: cap).isReached,
        ]
        if cap == nil { capPayload["note"] = "No daily cap is set." }
        return try jsonString([
            "jobs": jobs.map(Self.backgroundAIJobJSON),
            "daily_cap": capPayload,
        ])
    }

    private static func backgroundAIJobJSON(_ job: BackgroundAIBulkJob) -> [String: Any] {
        [
            "job_id": job.id,
            "queue": job.queue.rawValue,
            "queue_name": job.queue.displayName,
            "reason": job.reason,
            "held_since": ISO8601DateFormatter().string(from: job.createdAt),
            "source_count": job.heldSourceCount,
            "affected_source_count": job.affectedSourceCount.map { $0 as Any } ?? NSNull(),
            "priced_by_task": job.queue.task.rawValue,
            "cost_known": job.estimatedUSD != nil,
            "estimated_usd": job.estimatedUSD.map { $0 as Any } ?? NSNull(),
            "estimated_affected_usd": job.estimatedAffectedUSD.map { $0 as Any } ?? NSNull(),
            "estimate_basis": [
                "window_days": BackgroundAIBulkQueue.costSampleWindowDays,
                "priced_sources_sampled": job.costSample.pricedSourceCount,
                "unpriced_sources_skipped": job.costSample.unpricedSourceCount,
                "per_source_usd": job.costSample.perSourceUSD.map { $0 as Any } ?? NSNull(),
            ] as [String: Any],
            "decisions": (job.canLimitToAffected
                ? BackgroundAIBulkDecision.allCases
                : [.runAll, .skip]).map(\.rawValue),
        ]
    }

    private func decideBackgroundAIJob(jobID rawJobID: String?, decision rawDecision: String?) async throws -> String {
        guard let jobID = rawJobID?.trimmingCharacters(in: .whitespacesAndNewlines), !jobID.isEmpty else {
            throw MCPError.invalidInput("Pass job_id from get_background_ai_jobs.")
        }
        guard let rawDecision, let decision = BackgroundAIBulkDecision(rawValue: rawDecision) else {
            throw MCPError.invalidInput("decision takes run_all, run_affected or skip.")
        }
        let outcome: KnowledgeStore.BackgroundAIBulkDecisionOutcome
        do {
            outcome = try await notebookFileStorage.decideBackgroundAIBulkJob(id: jobID, decision: decision)
        } catch KnowledgeStoreError.invalidData(let message) {
            throw MCPError.invalidInput(message)
        }
        var payload: [String: Any] = [
            "job_id": outcome.jobID,
            "queue": outcome.queue.rawValue,
            "decision": outcome.decision.rawValue,
            "released_source_count": outcome.releasedCount,
            "dropped_source_count": outcome.droppedCount,
        ]
        if outcome.decision != .skip, outcome.releasedCount > 0 {
            // The drain takes hours on a big queue; this is how it is stopped.
            payload["work_id"] = "queue-\(outcome.jobID)"
            payload["note"] = "cancel_ai_work with this work_id stops the run; what the drain has not reached waits here again."
        }
        return try jsonString(payload)
    }
}
