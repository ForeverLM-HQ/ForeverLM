#if os(macOS)
import Foundation

// MARK: - Stopping paid work started over MCP (2026-09-27)
//
// The product owner: "please make sure there are cancel tools for each process that gets
// triggered via the mcp that costs money". The case that prompted it: an
// assistant called `generate_course_quizzes`, its own call timed out, and the
// writer went on for minutes on the learner's key — holding the store gate the
// whole time, so every other tool waited behind it — with nothing that could
// stop it. Only text-to-speech audio had a cancel tool.
//
// Two tools cover every such process: `list_running_ai_work` shows it and
// `cancel_ai_work` stops it. They reach work wherever it lives:
//
// - A tool call. Every call runs as a task of its own in `MCPRunningWork`,
//   listed until it answers, so a writer whose caller gave up can still be
//   stopped. Cancelling it aborts the request in flight (`URLSession` and the
//   AI layer honour cancellation) and the generators start nothing further.
// - Work a tool leaves running after it answers, such as a Teachable course's
//   transcripts, registers in `MCPRunningWork` with `startBackground`.
// - Work with a home of its own is stopped through that home, exactly as its
//   own Cancel does: explainer videos (`ExplainerVideoGenerationCoordinator`),
//   mnemonic readings made in the app (`MnemonicReadingCoordinator`; an
//   assistant's is a registered background task already), the
//   text-to-speech queue (`SourceAudioGenerationQueue`), scheduled task runs
//   (`ScheduledTaskRunner.stop`), and bulk re-queues released with
//   `decide_background_ai_job` (`KnowledgeStore.stopBackgroundAIBulkJob`).
//
// Both tools are off the store gate: a stop that queued behind the writer it
// is meant to stop would be no stop at all.

/// Tool calls in flight and the background work tools leave running, each
/// with the handle that cancels it.
final class MCPRunningWork: @unchecked Sendable {
    static let shared = MCPRunningWork()
    /// Paid assistant work gets this much room without a separate learner
    /// decision. The ledger stops the task after the request that reaches the
    /// ceiling, before its loop can start another paid request.
    static let defaultSpendLimitUSD = 3.0

    struct Entry: Sendable {
        enum Kind: String, Sendable {
            case toolCall = "tool_call"
            case background
        }

        let id: String
        let kind: Kind
        let tool: String
        let about: String?
        let startedAt: Date
        /// The latest stage or numeric progress reported by the tool.
        var detail: String? = nil
        /// Durable ledger cost recorded while this operation has been running.
        var spentUSD: Double = 0
        /// Nil for work that does not call a paid model or media provider.
        let spendLimitUSD: Double?
        var stopRequestedAt: Date?
        var stoppedBy: Stopper?
        fileprivate let cancel: @Sendable () -> Void
    }

    /// Who asked for a stop, so the answer to the assistant can say so.
    enum Stopper: String, Sendable {
        /// `cancel_ai_work`, from an assistant.
        case assistant
        /// A Stop in ForeverLM itself.
        case learner
        /// The durable usage ledger reached the amount the learner approved
        /// for this one operation.
        case spendLimit = "spend_limit"

        var answerPhrase: String {
            switch self {
            case .assistant: return "by cancel_ai_work"
            case .learner: return "by the learner in ForeverLM"
            case .spendLimit: return "at the operation's approved spend limit"
            }
        }
    }

    /// The id of the registered work the current task belongs to: set around
    /// a tool call's body and a background task's, nil anywhere else. What an
    /// in-app progress banner reads to stop the call it shows.
    @TaskLocal static var currentCallID: String?

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Everything running, oldest first.
    var snapshot: [Entry] {
        lock.withLock { entries.values.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) } }
    }

    /// Keeps `list_running_ai_work` in step with the in-app progress banner.
    func setDetail(_ id: String, _ detail: String?) {
        lock.withLock {
            guard var entry = entries[id] else { return }
            entry.detail = detail
            entries[id] = entry
        }
    }

    /// Adds one durable usage row's accounted cost to its operation. A single
    /// provider request cannot be interrupted retroactively, so the request
    /// that crosses the ceiling finishes and is kept; cancellation prevents
    /// the workflow from launching another request. Known-cost batches quote
    /// their maximum before their first request as well.
    func recordSpend(_ costUSD: Double, for id: String?) {
        guard let id, costUSD.isFinite, costUSD > 0 else { return }
        let shouldStop: Bool = lock.withLock {
            guard var entry = entries[id], let limit = entry.spendLimitUSD else { return false }
            entry.spentUSD += costUSD
            let reached = entry.spentUSD >= limit && entry.stopRequestedAt == nil
            entries[id] = entry
            return reached
        }
        if shouldStop { _ = stop(id, by: .spendLimit) }
    }

    /// Runs one tool call as a task of its own, listed until it returns.
    /// `stoppedBy` says who stopped it through `stop`; a cancelled caller (the
    /// in-app chat's Stop) cancels it too, without counting as a stop here.
    func run<T>(
        toolCall tool: String,
        about: String?,
        spendLimitUSD: Double? = nil,
        _ body: @escaping () async -> T
    ) async -> (value: T, stoppedBy: Stopper?) {
        let id = Self.newID("call")
        let result = ResultBox<T>()
        // Do not let a very fast model call record spend before its entry is
        // installed. The stream is a one-shot start gate, not a poll.
        let (start, startContinuation) = AsyncStream<Void>.makeStream()
        // Inherits the caller's priority and task-locals, among them the
        // chat's `AIUsageAttribution`, so the ledger still files its rows.
        let task = Task {
            var iterator = start.makeAsyncIterator()
            _ = await iterator.next()
            result.value = await MCPRunningWork.$currentCallID.withValue(id) { await body() }
        }
        lock.withLock {
            entries[id] = Entry(
                id: id,
                kind: .toolCall,
                tool: tool,
                about: about,
                startedAt: Date(),
                spendLimitUSD: spendLimitUSD,
                cancel: { task.cancel() }
            )
        }
        startContinuation.yield()
        startContinuation.finish()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let stoppedBy = lock.withLock { entries.removeValue(forKey: id)?.stoppedBy }
        // The task always sets the box before it ends.
        return (result.value!, stoppedBy)
    }

    /// Starts work a tool leaves running after it answers, listed until it
    /// ends. Returns its work id for the tool's answer.
    @discardableResult
    func startBackground(
        tool: String,
        about: String?,
        spendLimitUSD: Double? = nil,
        _ body: @escaping @Sendable () async -> Void
    ) -> String {
        let id = Self.newID("task")
        // Held across the insert so the task cannot finish and remove an entry
        // that is not there yet.
        lock.lock()
        defer { lock.unlock() }
        let task = Task {
            await MCPRunningWork.$currentCallID.withValue(id) { await body() }
            self.finish(id)
        }
        let limit = spendLimitUSD ?? (MCPToolRegistry.paidWorkToolNames.contains(tool) ? Self.defaultSpendLimitUSD : nil)
        entries[id] = Entry(
            id: id,
            kind: .background,
            tool: tool,
            about: about,
            startedAt: Date(),
            spendLimitUSD: limit,
            cancel: { task.cancel() }
        )
        return id
    }

    /// Cancels the work with this id; the first to ask is who stopped it.
    /// Nil when nothing by that id is running.
    @discardableResult
    func stop(_ id: String, by stopper: Stopper) -> Entry? {
        let entry: Entry? = lock.withLock {
            guard var entry = entries[id] else { return nil }
            if entry.stopRequestedAt == nil {
                entry.stopRequestedAt = Date()
                entry.stoppedBy = stopper
                entries[id] = entry
            }
            return entry
        }
        // Outside the lock: cancelling runs the task's cancellation handlers
        // on this thread, and one of them may be another entry's.
        entry?.cancel()
        return entry
    }

    private func finish(_ id: String) {
        lock.withLock { _ = entries.removeValue(forKey: id) }
    }

    private static func newID(_ prefix: String) -> String {
        "\(prefix)-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// What a call is about, from the arguments that name its subject: the
    /// first of these present, so a list of running calls reads as more than
    /// tool names.
    static func about(_ arguments: [String: Any]) -> String? {
        let keys = [
            "course_id", "lecture_id", "source_id", "notebook_id", "task_id", "session_id", "job_id",
            "topic", "concept", "url", "prompt", "title",
        ]
        for key in keys {
            if let text = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return "\(key) \(text.count > 80 ? String(text.prefix(79)) + "…" : text)"
            }
        }
        for key in ["source_ids", "quiz_ids", "cited_paper_ids", "book_ids"] {
            if let ids = arguments[key] as? [String], !ids.isEmpty {
                return ids.count == 1 ? "\(key) \(ids[0])" : "\(ids.count) \(key)"
            }
        }
        return nil
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}

extension MCPToolRegistry {
    static var runningWorkToolDefs: [MCPToolDef] {
        [
            MCPToolDef(
                name: "list_running_ai_work",
                description: "List the ForeverLM work running right now, above all what is spending money, so the learner can stop what they no longer want: tool calls still running on this Mac (a course's quizzes being written, a course, a walkthrough, a transcription — including a call whose assistant timed out waiting for it), explainer videos being filmed, mnemonic readings whose questions are being written, the text-to-speech audio queue, Teachable transcripts made in the background, scheduled task runs generating on this Mac, and bulk re-queues released with decide_background_ai_job that the background drains are still working through. Each registered entry has its work_id for cancel_ai_work, its kind, the tool that started it, what it is about, when it started, spends_money, current recorded spend and approved ceiling, and progress when the tool reports a current stage or count. Answers at once, even while a long call is still writing to the library.",
                inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
            ),
            MCPToolDef(
                name: "cancel_ai_work",
                description: "Stop work listed by list_running_ai_work: pass its work_ids, or all: true to stop everything it marks spends_money. The job_id generate_explainer_video returned is accepted as it is. A tool call aborts the model request in flight and starts nothing further; what it already saved stays, so generate_course_quizzes keeps the quizzes written so far and calling it again writes only the rest. An explainer video is discarded, though scenes already filmed were billed; a mnemonic reading keeps the questions of the sources already written, the rest waiting in it as pending; text-to-speech audio keeps its finished chunks; a scheduled task's chat keeps the reply so far and the run is recorded as stopped; a released bulk re-queue puts the sources the drain has not reached back on hold in get_background_ai_jobs, where skip drops them. Work running on another device is not reached. Returns what was stopped and what had already finished.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "work_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "work_id values from list_running_ai_work.",
                        ],
                        "all": [
                            "type": "boolean",
                            "description": "Stop everything list_running_ai_work marks spends_money. Defaults to false.",
                        ],
                    ],
                    "required": [] as [String],
                ]
            ),
        ]
    }

    static let runningWorkToolNames: Set<String> = ["list_running_ai_work", "cancel_ai_work"]

    /// Tools whose call itself spends money: a model, speech-to-text, an image
    /// or a video on the learner's balance or key. `list_running_ai_work`
    /// marks a running call of one `spends_money`, and `cancel_ai_work`'s
    /// `all` stops those. Every other call is listed while it runs too, so a
    /// tool missing here can still be stopped by its work_id.
    static let paidWorkToolNames: Set<String> = [
        "generate_course", "generate_course_quizzes", "add_course_quiz_pictures", "add_textbook_to_course",
        "generate_walkthrough", "generate_explainer", "generate_audio_overview", "generate_report", "generate_explainer_video", "generate_image",
        "draft_cards", "generate_mnemonic_reading", "ask_canvas",
        // Writes a source's reading levels when asked to (write_if_missing).
        "get_source_levels",
        "make_cards_from_canvas",
        "generate_source_audio",
        "transcribe_meeting_recording", "fetch_video_transcript", "import_teachable_course",
        "find_podcast_on_youtube", "import_podcast_youtube_transcript",
        "find_lecture_papers", "ingest_lecture_papers",
        "scan_video_for_cited_papers", "scan_meeting_for_mentioned_papers", "scan_article_for_linked_sources",
        "make_article_reading_view",
        "discover_sources",
        "extract_paper_metadata", "extract_article_metadata", "inspect_paper_figure",
        "download_papers_needing_attention", "recheck_paywalled_papers",
        "import_paper_from_url", "import_local_pdf_as_paper", "import_connector_paper", "import_video_cited_paper",
        "close_day", "run_settings_action",
        // An Atlas's skeleton call, and one concept's deepening.
        "make_atlas", "get_atlas",
    ]

    /// How a stopped call's answer begins: stopped by `cancel_ai_work`, the
    /// learner, its spend ceiling, or its caller while waiting for the gate.
    static let stoppedResultPrefix = "Error: Stopped"
}

extension MCPDataStore {
    func executeRunningWorkTool(name: String, arguments: [String: Any]) async throws -> String? {
        switch name {
        case "list_running_ai_work":
            return try await listRunningAIWork()
        case "cancel_ai_work":
            return try await cancelAIWork(
                workIDs: arguments["work_ids"] as? [String] ?? [],
                all: arguments["all"] as? Bool ?? false
            )
        default:
            return nil
        }
    }

    /// One piece of running work and how it is stopped.
    private struct RunningAIWork {
        enum Home {
            case registry
            case explainerVideo(jobID: String)
            case mnemonicReading(readingID: String)
            case textToSpeechAudio
            case scheduledTask(taskID: String)
            case backgroundQueue(jobID: String)
        }

        let workID: String
        /// Other ids an assistant may hold for the same work: the job_id a
        /// tool returned.
        var aliases: Set<String> = []
        let home: Home
        let spendsMoney: Bool
        var payload: [String: Any]
    }

    /// What the main-actor homes are running, copied out as plain values.
    private struct MainActorHomes: Sendable {
        struct Video: Sendable {
            let id: String
            let concept: String
            let stage: String
            let model: String
            let startedAt: Date
            let estimatedCostUSD: Double?
        }

        struct Audio: Sendable {
            let generating: Int
            let queued: Int
            let titles: [String]
            let startedAt: Date
        }

        struct Reading: Sendable {
            let id: String
            let title: String
            let progress: String
            let startedAt: Date
        }

        let videos: [Video]
        let readings: [Reading]
        let audio: Audio?
        let scheduled: [(id: String, title: String)]

        @MainActor
        static func current() -> MainActorHomes {
            let videos = ExplainerVideoGenerationCoordinator.shared.jobs.map { job in
                Video(
                    id: job.id,
                    concept: job.concept,
                    stage: job.stage.label,
                    model: job.model.name,
                    startedAt: job.startedAt,
                    estimatedCostUSD: GeneratedExplainerVideo.estimatedCostUSD(length: job.length, model: job.model, resolution: job.resolution)
                )
            }
            let active = SourceAudioGenerationQueue.shared.items.filter { $0.status.isActive }
            // Narrations the learner started in the app (Listen, a source's
            // Generate Audio) are not queue entries, but they spend money and
            // can hang, so they are listed and stoppable too.
            let outsideQueue = ArticleSpeechService.shared.backgroundGenerationSourceIDs
                .subtracting(active.map(\.sourceID))
            var audio: Audio?
            if !active.isEmpty || !outsideQueue.isEmpty {
                let generating = active.filter { $0.status == .generating }
                var titles = (generating.isEmpty ? active : generating).prefix(3).map(\.title)
                if !outsideQueue.isEmpty {
                    titles.append("\(outsideQueue.count) started in the app")
                }
                audio = Audio(
                    generating: generating.count + outsideQueue.count,
                    queued: active.count - generating.count,
                    titles: titles,
                    startedAt: active.map(\.enqueuedAt).min() ?? Date()
                )
            }
            let runner = ScheduledTaskRunner.shared
            let titles = Dictionary(runner.details.map { ($0.task.id, $0.task.title) }, uniquingKeysWith: { first, _ in first })
            // A reading an assistant started is its background task's entry
            // already; only those made in the app are listed here.
            let readings = MnemonicReadingCoordinator.shared.runs.filter { $0.workID == nil }.map { run in
                Reading(id: run.id, title: run.title, progress: run.progress.label, startedAt: run.startedAt)
            }
            return MainActorHomes(
                videos: videos,
                readings: readings,
                audio: audio,
                scheduled: runner.runningTaskIDs.sorted().map { ($0, titles[$0] ?? $0) }
            )
        }
    }

    private func runningAIWork() async throws -> [RunningAIWork] {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        func seconds(since date: Date) -> Int { max(0, Int(now.timeIntervalSince(date))) }

        var work: [RunningAIWork] = MCPRunningWork.shared.snapshot.map { entry -> RunningAIWork in
            let spends = entry.kind == .background || MCPToolRegistry.paidWorkToolNames.contains(entry.tool)
            var payload: [String: Any] = [
                "work_id": entry.id,
                "kind": entry.kind.rawValue,
                "tool": entry.tool,
                "started_at": formatter.string(from: entry.startedAt),
                "running_seconds": seconds(since: entry.startedAt),
                "spends_money": spends,
            ]
            if let about = entry.about { payload["about"] = about }
            if let detail = entry.detail { payload["progress"] = detail }
            if entry.spentUSD > 0 { payload["recorded_spend_usd"] = entry.spentUSD }
            if let limit = entry.spendLimitUSD { payload["approved_spend_usd"] = limit }
            if let requested = entry.stopRequestedAt {
                payload["stop_requested_at"] = formatter.string(from: requested)
            }
            if let stopper = entry.stoppedBy { payload["stopped_by"] = stopper.rawValue }
            return RunningAIWork(workID: entry.id, home: .registry, spendsMoney: spends, payload: payload)
        }

        let homes = await MainActor.run { MainActorHomes.current() }

        for job in homes.videos {
            var payload: [String: Any] = [
                "work_id": "video-\(job.id)",
                "kind": "explainer_video",
                "tool": "generate_explainer_video",
                "about": job.concept,
                "stage": job.stage,
                "started_at": formatter.string(from: job.startedAt),
                "running_seconds": seconds(since: job.startedAt),
                "spends_money": true,
                "model": job.model,
            ]
            if let cost = job.estimatedCostUSD { payload["estimated_cost_usd"] = cost }
            work.append(RunningAIWork(workID: "video-\(job.id)", aliases: [job.id], home: .explainerVideo(jobID: job.id), spendsMoney: true, payload: payload))
        }

        for reading in homes.readings {
            let workID = "reading-\(reading.id)"
            work.append(RunningAIWork(workID: workID, aliases: [reading.id], home: .mnemonicReading(readingID: reading.id), spendsMoney: true, payload: [
                "work_id": workID,
                "kind": "mnemonic_reading",
                "tool": "generate_mnemonic_reading",
                "about": reading.title,
                "reading_id": reading.id,
                "progress": reading.progress,
                "started_at": formatter.string(from: reading.startedAt),
                "running_seconds": seconds(since: reading.startedAt),
                "spends_money": true,
            ]))
        }

        if let audio = homes.audio {
            work.append(RunningAIWork(workID: "audio", home: .textToSpeechAudio, spendsMoney: true, payload: [
                "work_id": "audio",
                "kind": "read_aloud_audio",
                "tool": "generate_source_audio",
                "about": "\(audio.generating) generating, \(audio.queued) queued: \(audio.titles.joined(separator: "; "))",
                "started_at": formatter.string(from: audio.startedAt),
                "running_seconds": seconds(since: audio.startedAt),
                "spends_money": true,
                "detail": "get_source_audio_status lists every source; cancel_source_audio_generation stops single ones.",
            ]))
        }

        for task in homes.scheduled {
            let workID = "scheduled-\(task.id)"
            work.append(RunningAIWork(workID: workID, aliases: [task.id], home: .scheduledTask(taskID: task.id), spendsMoney: true, payload: [
                "work_id": workID,
                "kind": "scheduled_task_run",
                "tool": "run_scheduled_task_now",
                "about": task.title,
                "task_id": task.id,
                "spends_money": true,
            ]))
        }

        for job in try await notebookFileStorage.runningBackgroundAIBulkJobs() {
            let workID = "queue-\(job.id)"
            var payload: [String: Any] = [
                "work_id": workID,
                "kind": "background_queue",
                "tool": "decide_background_ai_job",
                "about": "\(job.queue.displayName): \(job.remainingSourceCount.formatted()) source\(job.remainingSourceCount == 1 ? "" : "s") left (\(job.decision.rawValue)); \(job.reason)",
                "job_id": job.id,
                "queue": job.queue.rawValue,
                "remaining_source_count": job.remainingSourceCount,
                "spends_money": true,
            ]
            if let decidedAt = job.decidedAt {
                payload["started_at"] = formatter.string(from: decidedAt)
                payload["running_seconds"] = seconds(since: decidedAt)
            }
            work.append(RunningAIWork(workID: workID, aliases: [job.id], home: .backgroundQueue(jobID: job.id), spendsMoney: true, payload: payload))
        }
        return work
    }

    private func listRunningAIWork() async throws -> String {
        let work = try await runningAIWork()
        var payload: [String: Any] = [
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "work": work.map(\.payload),
            "spending_count": work.filter(\.spendsMoney).count,
        ]
        if work.isEmpty { payload["message"] = "Nothing is running." }
        return try jsonString(payload)
    }

    private func cancelAIWork(workIDs: [String], all: Bool) async throws -> String {
        let requested = workIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard all || !requested.isEmpty else {
            throw MCPError.invalidInput("Pass work_ids from list_running_ai_work, or all: true to stop everything that is spending money.")
        }
        let running = try await runningAIWork()
        var targets: [RunningAIWork] = []
        var notRunning: [String] = []
        if all {
            targets = running.filter(\.spendsMoney)
        }
        for id in requested {
            if let match = running.first(where: { $0.workID == id || $0.aliases.contains(id) }) {
                if !targets.contains(where: { $0.workID == match.workID }) { targets.append(match) }
            } else {
                notRunning.append(id)
            }
        }

        var results: [[String: Any]] = []
        for target in targets {
            var result: [String: Any] = [
                "work_id": target.workID,
                "kind": target.payload["kind"] ?? NSNull(),
                "tool": target.payload["tool"] ?? NSNull(),
            ]
            switch target.home {
            case .registry:
                if MCPRunningWork.shared.stop(target.workID, by: .assistant) != nil {
                    result["status"] = "stopping"
                    result["message"] = "The request in flight is aborted and nothing further is started. What it already saved stays."
                } else {
                    result["status"] = "already_finished"
                }
            case .explainerVideo(let jobID):
                await MainActor.run { ExplainerVideoGenerationCoordinator.shared.cancel(jobID) }
                result["status"] = "stopping"
                result["message"] = "The video is discarded. Scenes already filmed were billed."
            case .mnemonicReading(let readingID):
                await MainActor.run { MnemonicReadingCoordinator.shared.cancel(readingID) }
                result["status"] = "stopping"
                result["message"] = "The sources written before the stop keep their questions; the rest wait in the reading, pending."
            case .textToSpeechAudio:
                let stopped = await MainActor.run { SourceAudioGenerationQueue.shared.cancel(sourceIDs: nil) }
                result["status"] = stopped.cancelled.isEmpty ? "already_finished" : "stopped"
                result["cancelled_source_ids"] = stopped.cancelled.sorted()
                result["message"] = "Finished audio chunks stay cached, so generating these sources again later costs nothing for those parts."
            case .scheduledTask(let taskID):
                let stopped = await MainActor.run { ScheduledTaskRunner.shared.stop(taskID: taskID) }
                result["status"] = stopped ? "stopped" : "not_stoppable_now"
                result["message"] = stopped
                    ? "The chat keeps the reply so far; the run is recorded as stopped."
                    : "The run is between turns or has just finished; list again and retry if it is still running."
            case .backgroundQueue(let jobID):
                do {
                    let outcome = try await notebookFileStorage.stopBackgroundAIBulkJob(id: jobID)
                    result["status"] = outcome.heldSourceCount > 0 ? "stopped" : "already_finished"
                    result["held_source_count"] = outcome.heldSourceCount
                    if let held = outcome.heldJobID {
                        result["held_job_id"] = held
                        result["message"] = "\(outcome.heldSourceCount.formatted()) source\(outcome.heldSourceCount == 1 ? "" : "s") the drain had not reached wait again in get_background_ai_jobs (job \(held)): decide_background_ai_job with skip drops them, run_all runs them. A source the drain had already picked up finishes."
                    }
                } catch KnowledgeStoreError.invalidData(let message) {
                    result["status"] = "already_finished"
                    result["message"] = message
                }
            }
            results.append(result)
        }

        var payload: [String: Any] = [
            "stopped": results,
            "stopped_count": results.filter { ["stopping", "stopped"].contains($0["status"] as? String ?? "") }.count,
        ]
        if !notRunning.isEmpty {
            payload["not_running"] = notRunning
            payload["note"] = "Not running on this Mac: finished already, never started, or running on another device."
        }
        if targets.isEmpty { payload["message"] = "Nothing matching was running." }
        return try jsonString(payload)
    }
}
#endif
