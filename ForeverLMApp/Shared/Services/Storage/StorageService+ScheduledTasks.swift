import Foundation

/// Off-main access to scheduled tasks.
///
/// Everything here is a thin pass-through to `KnowledgeStore` plus the right
/// sync urgency: definition edits are small user intent and push immediately so
/// a second Mac stops running a task the learner just disabled; claims and run
/// receipts follow soon after, because losing a few seconds on a receipt costs
/// nothing and the record is written on a hot path.
extension StorageService {

    func loadScheduledTaskDetails() throws -> [ScheduledTaskDetail] {
        try notebookFilesKnowledgeStore().loadScheduledTaskDetails()
    }

    func loadScheduledTask(_ taskID: String) throws -> ScheduledTask? {
        try notebookFilesKnowledgeStore().loadScheduledTask(taskID)
    }

    func loadScheduledTaskRuns(taskID: String) throws -> [ScheduledTaskRun] {
        try notebookFilesKnowledgeStore().loadScheduledTaskRuns(taskID: taskID)
    }

    @discardableResult
    func saveScheduledTask(_ task: ScheduledTask) throws -> ScheduledTask {
        let saved = try notebookFilesKnowledgeStore().saveScheduledTask(task)
        scheduleImmediateCloudKitSyncForScheduledTasks()
        return saved
    }

    func deleteScheduledTask(_ taskID: String) throws {
        try notebookFilesKnowledgeStore().deleteScheduledTask(taskID)
        scheduleImmediateCloudKitSyncForScheduledTasks()
    }

    func requestScheduledTaskRunNow(_ taskID: String, at date: Date = Date()) throws {
        try notebookFilesKnowledgeStore().requestScheduledTaskRunNow(taskID, at: date)
        scheduleImmediateCloudKitSyncForScheduledTasks()
    }

    func claimScheduledTaskOccurrence(
        taskID: String,
        occurrenceAt: Date,
        status: ScheduledTaskRunStatus = .running,
        message: String? = nil,
        deviceName: String? = nil
    ) throws -> ScheduledTaskRun? {
        let claimed = try notebookFilesKnowledgeStore().claimScheduledTaskOccurrence(
            taskID: taskID,
            occurrenceAt: occurrenceAt,
            status: status,
            message: message,
            deviceName: deviceName
        )
        // A claim is the one write another device must see quickly: it is what
        // stops the same morning producing a second chat over there.
        if claimed != nil { scheduleImmediateCloudKitSyncForScheduledTasks() }
        return claimed
    }

    func finishScheduledTaskRun(
        runID: String,
        status: ScheduledTaskRunStatus,
        sessionID: String?,
        message: String?,
        retryAt: Date? = nil
    ) throws {
        try notebookFilesKnowledgeStore().finishScheduledTaskRun(
            runID: runID,
            status: status,
            sessionID: sessionID,
            message: message,
            retryAt: retryAt
        )
        scheduleSoonCloudKitSyncForScheduledTasks()
    }

    func claimScheduledTaskRetry(runID: String) throws -> ScheduledTaskRun? {
        let claimed = try notebookFilesKnowledgeStore().claimScheduledTaskRetry(runID: runID)
        // Like an occurrence's claim: the other Mac should see the try taken.
        if claimed != nil { scheduleImmediateCloudKitSyncForScheduledTasks() }
        return claimed
    }

    func abandonScheduledTaskRetry(runID: String, note: String) throws {
        try notebookFilesKnowledgeStore().abandonScheduledTaskRetry(runID: runID, note: note)
        scheduleSoonCloudKitSyncForScheduledTasks()
    }

    @discardableResult
    func failInterruptedScheduledTaskRuns(deviceName: String? = nil) throws -> Int {
        let count = try notebookFilesKnowledgeStore().failInterruptedScheduledTaskRuns(deviceName: deviceName)
        if count > 0 { scheduleSoonCloudKitSyncForScheduledTasks() }
        return count
    }

    @discardableResult
    func detachScheduledTasksFromNotebook(_ notebookID: String) throws -> Int {
        let count = try notebookFilesKnowledgeStore().detachScheduledTasksFromNotebook(notebookID)
        if count > 0 { scheduleImmediateCloudKitSyncForScheduledTasks() }
        return count
    }
}
