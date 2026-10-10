import Foundation
import OSLog

/// MCP control surface for recurring scheduled tasks.
///
/// An external assistant gets exactly what the app's Tasks pane gets: create,
/// inspect, edit, pause, run now, and delete. Everything goes through the same
/// `KnowledgeStore` APIs the UI uses, so SQLite, `sync_metadata`, and
/// `sync_changes` stay consistent and a task made in Claude is indistinguishable
/// from one made in the app.
extension MCPDataStore {

    // MARK: - Reads

    func listScheduledTasks(includeRuns: Bool = false) throws -> String {
        let store = try knowledgeStore()
        // Screen record mode (admin only): a task made during the take, or one
        // filed under the recording Notebook. Nil scope lists every task, as
        // before.
        let screenScope = screenRecordScope()
        let parents: [String: String] = try screenScope == nil ? [:] : screenRecordParentNotebookIDs()
        let details = try store.loadScheduledTaskDetails().filter { detail in
            guard let screenScope else { return true }
            return screenScope.allowsItem(
                createdAt: detail.task.createdAt,
                notebookIDs: screenRecordNotebookIDs(linkedTo: [detail.task.notebookID], parents: parents)
            )
        }
        let notebookTitles = try scheduledTaskNotebookTitles(store: store)
        let payload: [String: Any] = [
            "count": details.count,
            "tasks": details.map {
                scheduledTaskPayload(
                    $0,
                    notebookTitles: notebookTitles,
                    includeRuns: includeRuns
                )
            },
        ]
        return try jsonString(payload)
    }

    func getScheduledTask(taskID: String?) throws -> String {
        let store = try knowledgeStore()
        let id = try requiredScheduledTaskID(taskID)
        guard let task = try store.loadScheduledTask(id) else {
            throw MCPError.notFound("No scheduled task with id \(id).")
        }
        let detail = ScheduledTaskDetail(
            task: task,
            runs: try store.loadScheduledTaskRuns(taskID: id)
        )
        var payload = scheduledTaskPayload(
            detail,
            notebookTitles: try scheduledTaskNotebookTitles(store: store),
            includeRuns: true
        )
        payload["failure_handling"] = Self.scheduledTaskFailureHandling
        return try jsonString(payload)
    }

    /// What a run does before a receipt says failed, for an assistant asked
    /// why a task did not produce its chat.
    static let scheduledTaskFailureHandling = "Before a run fails, the chat retries a dropped connection or a short rate limit, then moves through the Chat model's backups in order (set_ai_task_settings target backups, backups_for chat) while the failure is one another model could get past; a receipt whose chat a backup wrote says so in message. A run that still fails in a way time may fix (a rate limit, an overloaded model, no connection) is tried again on the same receipt, in the same chat while the Mac that failed it stays open: up to \(ScheduledTaskRetry.maximumAttempts) tries, the next after 5, 15, 45 and 120 minutes, never sooner than the provider's own Retry-After and never later than 12 hours after it was due. attempt says which try a receipt describes and retry_at when the next is due. No balance, a refused key, a model that is not offered and a Stop are final at once. Runs happen only on a Mac that is awake with ForeverLM open: tasks.keep_mac_awake (get_app_settings) keeps this Mac from idling to sleep while a task is due within 12 hours and it is plugged in; a run in progress always does."

    // MARK: - Writes

    func createScheduledTask(
        title: String?,
        instruction: String?,
        cadence: String?,
        hour: Int?,
        minute: Int?,
        weekday: Int?,
        dayOfMonth: Int?,
        date: String?,
        timeZone: String?,
        notebookID: String?,
        sourceIDs: [String],
        enabled: Bool?
    ) throws -> String {
        let store = try knowledgeStore()
        let trimmedTitle = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw MCPError.invalidInput("A scheduled task needs a title.")
        }
        let trimmedInstruction = (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw MCPError.invalidInput(
                "A scheduled task needs an instruction — the message ForeverLM should send when it runs."
            )
        }
        let resolvedCadence = try scheduledTaskCadence(cadence) ?? .daily
        let resolvedNotebookID = try validatedScheduledTaskNotebookID(notebookID, store: store)

        var task = ScheduledTask(
            title: trimmedTitle,
            instruction: trimmedInstruction,
            notebookID: resolvedNotebookID,
            sourceIDs: try validatedScheduledTaskSourceIDs(sourceIDs, store: store),
            cadence: resolvedCadence,
            weekday: weekday,
            dayOfMonth: dayOfMonth,
            hour: hour ?? 8,
            minute: minute ?? 0,
            timeZoneID: try validatedScheduledTaskTimeZone(timeZone),
            startDate: try scheduledTaskStartDate(date, timeZoneID: timeZone),
            isEnabled: enabled ?? true
        )
        if resolvedCadence == .once, task.startDate == nil {
            throw MCPError.invalidInput("A one-off task needs a date (YYYY-MM-DD).")
        }
        task = try store.saveScheduledTask(task)
        notifyScheduledTasksChanged()
        return try jsonString(scheduledTaskSummaryPayload(task, action: "created"))
    }

    func updateScheduledTask(
        taskID: String?,
        title: String?,
        instruction: String?,
        cadence: String?,
        hour: Int?,
        minute: Int?,
        weekday: Int?,
        dayOfMonth: Int?,
        date: String?,
        timeZone: String?,
        notebookID: String?,
        clearNotebook: Bool,
        sourceIDs: [String]?,
        enabled: Bool?
    ) throws -> String {
        let store = try knowledgeStore()
        let id = try requiredScheduledTaskID(taskID)
        guard var task = try store.loadScheduledTask(id) else {
            throw MCPError.notFound("No scheduled task with id \(id).")
        }

        // Omitted means "leave it alone"; only an explicitly supplied value
        // changes anything, so a caller updating the time cannot silently
        // detach the Notebook or drop the attached sources.
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.title = title
        }
        if let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.instruction = instruction
        }
        if let resolvedCadence = try scheduledTaskCadence(cadence) { task.cadence = resolvedCadence }
        if let hour { task.hour = hour }
        if let minute { task.minute = minute }
        if let weekday { task.weekday = weekday }
        if let dayOfMonth { task.dayOfMonth = dayOfMonth }
        if let startDate = try scheduledTaskStartDate(date, timeZoneID: timeZone ?? task.timeZoneID) {
            task.startDate = startDate
        }
        if let resolved = try validatedScheduledTaskTimeZone(timeZone) { task.timeZoneID = resolved }
        if clearNotebook {
            task.notebookID = nil
        } else if let resolvedNotebookID = try validatedScheduledTaskNotebookID(notebookID, store: store) {
            task.notebookID = resolvedNotebookID
        }
        if let sourceIDs {
            task.sourceIDs = try validatedScheduledTaskSourceIDs(sourceIDs, store: store)
        }
        if let enabled { task.isEnabled = enabled }
        task.updatedAt = Date()

        let saved = try store.saveScheduledTask(task)
        notifyScheduledTasksChanged()
        return try jsonString(scheduledTaskSummaryPayload(saved, action: "updated"))
    }

    func deleteScheduledTask(taskID: String?) throws -> String {
        let store = try knowledgeStore()
        let id = try requiredScheduledTaskID(taskID)
        guard let task = try store.loadScheduledTask(id) else {
            throw MCPError.notFound("No scheduled task with id \(id).")
        }
        try store.deleteScheduledTask(id)
        notifyScheduledTasksChanged()
        return try jsonString([
            "deleted": true,
            "task_id": id,
            "title": task.title,
            "note": "Chats this task already produced were kept.",
        ] as [String: Any])
    }

    /// Queues an extra run. The task runs on whichever signed-in client is open
    /// — normally the Mac hosting this plugin, right away.
    func runScheduledTaskNow(taskID: String?) throws -> String {
        let store = try knowledgeStore()
        let id = try requiredScheduledTaskID(taskID)
        guard let task = try store.loadScheduledTask(id) else {
            throw MCPError.notFound("No scheduled task with id \(id).")
        }
        let requestedAt = Date()
        try store.requestScheduledTaskRunNow(id, at: requestedAt)
        notifyScheduledTasksChanged()
        return try jsonString([
            "queued": true,
            "task_id": id,
            "title": task.title,
            "requested_at": ISO8601DateFormatter().string(from: requestedAt),
            "work_id": "scheduled-\(id)",
            "note": "The run starts on an open, signed-in ForeverLM client and appears as a new chat. While it generates on this Mac, cancel_ai_work with this work_id stops it.",
        ] as [String: Any])
    }

    // MARK: - Payloads

    private func scheduledTaskPayload(
        _ detail: ScheduledTaskDetail,
        notebookTitles: [String: String],
        includeRuns: Bool
    ) -> [String: Any] {
        let task = detail.task
        var payload: [String: Any] = [
            "task_id": task.id,
            "title": task.title,
            "instruction": task.instruction,
            "cadence": task.cadence.rawValue,
            "schedule": task.scheduleSummary,
            "hour": task.hour,
            "minute": task.minute,
            "time_zone": task.resolvedTimeZone.identifier,
            "enabled": task.isEnabled,
            "source_ids": task.sourceIDs,
            "created_at": ISO8601DateFormatter().string(from: task.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: task.updatedAt),
        ]
        if let weekday = task.weekday { payload["weekday"] = weekday }
        if let dayOfMonth = task.dayOfMonth { payload["day_of_month"] = dayOfMonth }
        if let notebookID = task.notebookID {
            payload["notebook_id"] = notebookID
            payload["notebook_title"] = notebookTitles[notebookID] ?? "(deleted notebook)"
        }
        if let next = task.upcomingOccurrence() {
            payload["next_run_at"] = ISO8601DateFormatter().string(from: next)
        }
        if let lastRunAt = task.lastRunAt {
            payload["last_run_at"] = ISO8601DateFormatter().string(from: lastRunAt)
        }
        if let status = task.lastRunStatus { payload["last_run_status"] = status.rawValue }
        if includeRuns {
            payload["runs"] = detail.runs.map { run -> [String: Any] in
                var entry: [String: Any] = [
                    "run_id": run.id,
                    "occurrence_at": ISO8601DateFormatter().string(from: run.occurrenceAt),
                    "status": run.status.rawValue,
                    // Which try the receipt describes, from 1; a failed run a
                    // later try may get past says when that try is due.
                    "attempt": run.attempt,
                    "max_attempts": ScheduledTaskRetry.maximumAttempts,
                ]
                if task.isEnabled, run.isAwaitingRetry, let retryAt = run.retryAt {
                    entry["retry_at"] = ISO8601DateFormatter().string(from: retryAt)
                }
                if let sessionID = run.sessionID { entry["session_id"] = sessionID }
                if let message = run.message { entry["message"] = message }
                if let deviceName = run.deviceName { entry["device"] = deviceName }
                if let finishedAt = run.finishedAt {
                    entry["finished_at"] = ISO8601DateFormatter().string(from: finishedAt)
                }
                return entry
            }
        }
        return payload
    }

    private func scheduledTaskSummaryPayload(_ task: ScheduledTask, action: String) -> [String: Any] {
        var payload: [String: Any] = [
            action: true,
            "task_id": task.id,
            "title": task.title,
            "schedule": task.scheduleSummary,
            "enabled": task.isEnabled,
            "time_zone": task.resolvedTimeZone.identifier,
        ]
        if let next = task.upcomingOccurrence() {
            payload["next_run_at"] = ISO8601DateFormatter().string(from: next)
        }
        if let notebookID = task.notebookID { payload["notebook_id"] = notebookID }
        if !task.sourceIDs.isEmpty { payload["source_ids"] = task.sourceIDs }
        return payload
    }

    // MARK: - Validation

    private func requiredScheduledTaskID(_ taskID: String?) throws -> String {
        let trimmed = (taskID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPError.invalidInput("task_id is required.") }
        return trimmed
    }

    private func scheduledTaskCadence(_ raw: String?) throws -> ScheduledTaskCadence? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let cadence = ScheduledTaskCadence(rawValue: normalized) else {
            let allowed = ScheduledTaskCadence.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPError.invalidInput("Unknown cadence \"\(raw)\". Use one of: \(allowed).")
        }
        return cadence
    }

    private func validatedScheduledTaskTimeZone(_ raw: String?) throws -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TimeZone(identifier: trimmed) != nil else {
            throw MCPError.invalidInput("Unknown time zone \"\(trimmed)\". Use an IANA identifier such as Europe/Amsterdam.")
        }
        return trimmed
    }

    /// Dates are structure, not meaning, so they are parsed deterministically
    /// and rejected when malformed rather than guessed at.
    private func scheduledTaskStartDate(_ raw: String?, timeZoneID: String?) throws -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        guard let date = formatter.date(from: trimmed) else {
            throw MCPError.invalidInput("date must be formatted YYYY-MM-DD.")
        }
        return date
    }

    private func validatedScheduledTaskNotebookID(_ raw: String?, store: KnowledgeStore) throws -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try store.loadLearningGoal(trimmed) != nil else {
            throw MCPError.invalidInput("No Notebook with id \(trimmed).")
        }
        return trimmed
    }

    private func validatedScheduledTaskSourceIDs(_ raw: [String], store: KnowledgeStore) throws -> [String] {
        var seen = Set<String>()
        var resolved: [String] = []
        for value in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            // A cheap existence check on purpose: materializing the full sync
            // payload for every attached source would turn task creation into
            // real work for no gain.
            guard try store.sourceExists(trimmed) else {
                throw MCPError.invalidInput("No source with id \(trimmed).")
            }
            resolved.append(trimmed)
        }
        return resolved
    }

    private func scheduledTaskNotebookTitles(store: KnowledgeStore) throws -> [String: String] {
        var titles: [String: String] = [:]
        for goal in try store.loadLearningGoals() {
            titles[goal.id] = goal.title
        }
        return titles
    }

    /// Wakes the in-app runner so an MCP write takes effect immediately instead
    /// of waiting for the next activation. Same process, so this is a direct
    /// event rather than a poll.
    private func notifyScheduledTasksChanged() {
        NotificationCenter.default.post(name: .scheduledTasksDidChange, object: nil)
    }
}
