import Foundation
import SQLite3
import Testing
@testable import ForeverLM

@Suite("Scheduled Tasks")
struct ScheduledTaskTests {

    // MARK: - Occurrence arithmetic

    @Test("Daily tasks come due at the same wall clock every day")
    func dailyOccurrences() {
        let task = ScheduledTask(
            title: "Morning briefing",
            instruction: "What should I study today?",
            cadence: .daily,
            hour: 7,
            minute: 30,
            timeZoneID: "Europe/Amsterdam",
            startDate: date("2026-08-01T00:00:00", zone: "Europe/Amsterdam")
        )
        let next = task.nextOccurrence(after: date("2026-08-10T09:00:00", zone: "Europe/Amsterdam"))
        #expect(next == date("2026-08-11T07:30:00", zone: "Europe/Amsterdam"))

        let recent = task.mostRecentOccurrence(
            onOrBefore: date("2026-08-10T09:00:00", zone: "Europe/Amsterdam")
        )
        #expect(recent == date("2026-08-10T07:30:00", zone: "Europe/Amsterdam"))
    }

    @Test("Weekday tasks skip the weekend")
    func weekdayOccurrencesSkipWeekend() {
        let task = ScheduledTask(
            title: "Weekday review",
            instruction: "Quiz me.",
            cadence: .weekdays,
            hour: 8,
            timeZoneID: "Europe/Amsterdam"
        )
        // 2026-08-14 is a Friday; the next weekday occurrence is Monday the 17th.
        let next = task.nextOccurrence(after: date("2026-08-14T09:00:00", zone: "Europe/Amsterdam"))
        #expect(next == date("2026-08-17T08:00:00", zone: "Europe/Amsterdam"))
    }

    @Test("A monthly task on day 31 runs on the last day of a short month")
    func monthlyClampsToMonthLength() {
        let task = ScheduledTask(
            title: "Monthly digest",
            instruction: "Summarize the month.",
            cadence: .monthly,
            dayOfMonth: 31,
            hour: 18,
            timeZoneID: "Europe/Amsterdam",
            startDate: date("2026-02-01T00:00:00", zone: "Europe/Amsterdam")
        )
        let next = task.nextOccurrence(after: date("2026-02-01T00:00:00", zone: "Europe/Amsterdam"))
        #expect(next == date("2026-02-28T18:00:00", zone: "Europe/Amsterdam"))
    }

    @Test("The schedule is anchored to the task's time zone, not the reading device's")
    func occurrencesFollowTheTaskTimeZone() {
        var task = ScheduledTask(
            title: "Anchored",
            instruction: "Go.",
            cadence: .daily,
            hour: 8,
            timeZoneID: "Europe/Amsterdam"
        )
        let amsterdam = task.nextOccurrence(after: date("2026-08-10T00:00:00", zone: "UTC"))
        task.timeZoneID = "America/New_York"
        let newYork = task.nextOccurrence(after: date("2026-08-10T00:00:00", zone: "UTC"))
        #expect(amsterdam != newYork)
        #expect(amsterdam == date("2026-08-10T08:00:00", zone: "Europe/Amsterdam"))
        #expect(newYork == date("2026-08-10T08:00:00", zone: "America/New_York"))
    }

    @Test("A disabled task is never due, and Run now overrides the cadence")
    func dueOccurrenceRespectsEnablementAndRunNow() {
        let now = date("2026-08-10T09:00:00", zone: "Europe/Amsterdam")
        var task = ScheduledTask(
            title: "Briefing",
            instruction: "Go.",
            cadence: .daily,
            hour: 7,
            timeZoneID: "Europe/Amsterdam",
            isEnabled: false,
            createdAt: date("2026-08-01T00:00:00", zone: "Europe/Amsterdam")
        )
        #expect(task.dueOccurrence(now: now) == nil)

        task.isEnabled = true
        #expect(task.dueOccurrence(now: now)?.occurrence == date("2026-08-10T07:00:00", zone: "Europe/Amsterdam"))

        // Once today's occurrence is claimed the cadence is quiet again, but an
        // explicit Run now still produces its own occurrence.
        task.lastOccurrenceAt = date("2026-08-10T07:00:00", zone: "Europe/Amsterdam")
        #expect(task.dueOccurrence(now: now) == nil)
        task.runNowRequestedAt = now
        #expect(task.dueOccurrence(now: now)?.occurrence == now)
    }

    @Test("A slot that passed before the task was made is not caught up")
    func dueOccurrenceIgnoresSlotsBeforeCreation() {
        // A weekly Sunday 09:00 task made at 10:44 that Sunday: the 09:00 slot
        // is inside the catch-up window, but it was never missed.
        let created = date("2026-11-08T10:44:00", zone: "America/New_York")
        let task = ScheduledTask(
            title: "Prep",
            instruction: "Go.",
            cadence: .weekly,
            weekday: 1,
            hour: 9,
            timeZoneID: "America/New_York",
            createdAt: created
        )
        #expect(task.dueOccurrence(now: created.addingTimeInterval(60)) == nil)
        #expect(task.upcomingOccurrence(now: created) == date("2026-11-15T09:00:00", zone: "America/New_York"))

        // The next Sunday's slot is due as usual, and caught up if missed.
        let nextSlot = date("2026-11-15T09:00:00", zone: "America/New_York")
        #expect(task.dueOccurrence(now: nextSlot)?.occurrence == nextSlot)
        #expect(task.dueOccurrence(now: nextSlot.addingTimeInterval(3600))?.occurrence == nextSlot)
    }

    @Test("An occurrence older than the catch-up window is stale")
    func staleOccurrences() {
        let task = ScheduledTask(title: "Briefing", instruction: "Go.", cadence: .daily)
        let now = Date()
        #expect(!task.isStale(occurrence: now.addingTimeInterval(-3600), now: now))
        #expect(task.isStale(occurrence: now.addingTimeInterval(-60 * 60 * 24), now: now))
    }

    @Test("A one-off task stops coming due after it runs")
    func onceCadenceRetires() {
        let day = date("2026-08-10T00:00:00", zone: "Europe/Amsterdam")
        var task = ScheduledTask(
            title: "One-off",
            instruction: "Go.",
            cadence: .once,
            hour: 9,
            timeZoneID: "Europe/Amsterdam",
            startDate: day
        )
        let scheduled = date("2026-08-10T09:00:00", zone: "Europe/Amsterdam")
        #expect(task.upcomingOccurrence(now: date("2026-08-10T08:00:00", zone: "Europe/Amsterdam")) == scheduled)
        task.lastOccurrenceAt = scheduled
        #expect(task.upcomingOccurrence(now: date("2026-08-10T10:00:00", zone: "Europe/Amsterdam")) == nil)
    }

    @Test("Normalizing drops cadence-irrelevant components")
    func normalizationDropsIrrelevantComponents() {
        let task = ScheduledTask(
            title: "  Digest  ",
            instruction: "  Go.  ",
            sourceIDs: ["a", "  "],
            cadence: .daily,
            weekday: 4,
            dayOfMonth: 12,
            hour: 99,
            minute: -3
        ).normalized()
        #expect(task.title == "Digest")
        #expect(task.instruction == "Go.")
        #expect(task.weekday == nil)
        #expect(task.dayOfMonth == nil)
        #expect(task.hour == 23)
        #expect(task.minute == 0)
        #expect(task.sourceIDs == ["a"])
    }

    // MARK: - Storage

    @Test("A task is saved, listed, and deleted")
    func taskPersistenceTracksSync() throws {
        let root = temporaryRoot("ScheduledTaskPersistence")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)

        let saved = try store.saveScheduledTask(
            ScheduledTask(title: "Briefing", instruction: "What should I study today?")
        )
        #expect(try store.loadScheduledTasks().map(\.id) == [saved.id])
        #expect(try store.hasScheduledTask(saved.id))

        try store.deleteScheduledTask(saved.id)
        #expect(try store.loadScheduledTasks().isEmpty)
    }

    @Test("A task with no title or no instruction is rejected")
    func emptyTasksAreRejected() throws {
        let root = temporaryRoot("ScheduledTaskValidation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)

        #expect(throws: (any Error).self) {
            _ = try store.saveScheduledTask(ScheduledTask(title: "   ", instruction: "Go."))
        }
        #expect(throws: (any Error).self) {
            _ = try store.saveScheduledTask(ScheduledTask(title: "Briefing", instruction: "  "))
        }
    }

    @Test("One occurrence can only be claimed once")
    func occurrencesAreClaimedExactlyOnce() throws {
        let root = temporaryRoot("ScheduledTaskClaim")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let task = try store.saveScheduledTask(
            ScheduledTask(title: "Briefing", instruction: "Go.")
        )
        let occurrence = date("2026-08-10T07:00:00", zone: "Europe/Amsterdam")

        let first = try store.claimScheduledTaskOccurrence(
            taskID: task.id,
            occurrenceAt: occurrence,
            deviceName: "Mac A"
        )
        #expect(first != nil)
        // The second device loses. Not an error — just no work to do.
        let second = try store.claimScheduledTaskOccurrence(
            taskID: task.id,
            occurrenceAt: occurrence,
            deviceName: "Mac B"
        )
        #expect(second == nil)
        #expect(try store.loadScheduledTaskRuns(taskID: task.id).count == 1)
        #expect(try store.loadScheduledTask(task.id)?.lastOccurrenceAt == occurrence)

        try store.finishScheduledTaskRun(
            runID: try #require(first).id,
            status: .succeeded,
            sessionID: "session-1",
            message: nil
        )
        let run = try #require(try store.loadScheduledTaskRuns(taskID: task.id).first)
        #expect(run.status == .succeeded)
        #expect(run.sessionID == "session-1")
        #expect(try store.loadScheduledTask(task.id)?.lastRunStatus == .succeeded)
    }

    @Test("Run now is cleared by the claim it produced")
    func runNowIsClearedOnClaim() throws {
        let root = temporaryRoot("ScheduledTaskRunNow")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let task = try store.saveScheduledTask(
            ScheduledTask(title: "Briefing", instruction: "Go.")
        )
        let requestedAt = Date()
        try store.requestScheduledTaskRunNow(task.id, at: requestedAt)
        #expect(try store.loadScheduledTask(task.id)?.runNowRequestedAt != nil)

        _ = try store.claimScheduledTaskOccurrence(taskID: task.id, occurrenceAt: requestedAt)
        #expect(try store.loadScheduledTask(task.id)?.runNowRequestedAt == nil)
    }

    @Test("A run interrupted by a quit is settled, not left spinning")
    func interruptedRunsAreFailedAtLaunch() throws {
        let root = temporaryRoot("ScheduledTaskInterrupted")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let task = try store.saveScheduledTask(
            ScheduledTask(title: "Briefing", instruction: "Go.")
        )
        _ = try store.claimScheduledTaskOccurrence(taskID: task.id, occurrenceAt: Date())
        #expect(try store.loadScheduledTaskRuns(taskID: task.id).first?.status == .running)

        #expect(try store.failInterruptedScheduledTaskRuns() == 1)
        #expect(try store.loadScheduledTaskRuns(taskID: task.id).first?.status == .failed)
        #expect(try store.loadScheduledTask(task.id)?.lastRunStatus == .failed)
    }

    @Test("A launch settles its own interrupted runs and never another Mac's run that is still generating")
    func interruptedRunsAreSettledPerDevice() throws {
        let root = temporaryRoot("ScheduledTaskInterruptedDevice")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let task = try store.saveScheduledTask(ScheduledTask(title: "Briefing", instruction: "Go."))
        let now = Date()
        _ = try store.claimScheduledTaskOccurrence(taskID: task.id, occurrenceAt: now.addingTimeInterval(-7_200), deviceName: "Studio Mac")
        _ = try store.claimScheduledTaskOccurrence(taskID: task.id, occurrenceAt: now.addingTimeInterval(-3_600), deviceName: "Laptop")

        #expect(try store.failInterruptedScheduledTaskRuns(deviceName: "Laptop") == 1)
        let runs = try store.loadScheduledTaskRuns(taskID: task.id)
        #expect(runs.first { $0.deviceName == "Laptop" }?.status == .failed)
        #expect(runs.first { $0.deviceName == "Studio Mac" }?.status == .running, "the other Mac's run is its own to settle")
    }

    @Test("Receipts stay bounded so one long-lived task cannot grow without limit")
    func receiptsArePruned() throws {
        let root = temporaryRoot("ScheduledTaskPruning")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let task = try store.saveScheduledTask(
            ScheduledTask(title: "Briefing", instruction: "Go.")
        )
        let start = date("2026-01-01T07:00:00", zone: "UTC")
        for day in 0..<(ScheduledTask.retainedRunCount + 5) {
            _ = try store.claimScheduledTaskOccurrence(
                taskID: task.id,
                occurrenceAt: start.addingTimeInterval(Double(day) * 86_400)
            )
        }
        #expect(try store.loadScheduledTaskRuns(taskID: task.id, limit: 1_000).count
            == ScheduledTask.retainedRunCount)
    }

    @Test("Deleting a Notebook detaches its tasks instead of deleting them")
    func notebookDeletionDetachesTasks() async throws {
        let root = temporaryRoot("ScheduledTaskNotebookDeletion")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let notebook = try await storage.createCompanionGoal(
            title: "Immunology",
            topic: "Immunology",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )
        let task = try await storage.saveScheduledTask(
            ScheduledTask(
                title: "Immunology briefing",
                instruction: "Go.",
                notebookID: notebook.id
            )
        )

        try await storage.deleteLearningGoal(notebook.id, cascadeChildGoals: true)
        let survivor = try await storage.loadScheduledTask(task.id)
        #expect(survivor != nil)
        #expect(survivor?.notebookID == nil)
    }

     // MARK: - Retries

    @Test("A failure a later try may get past is tried again after 5, 15, 45 and 120 minutes, five tries in all")
    func retryScheduleBacksOff() throws {
        let occurrence = date("2026-08-10T02:00:00", zone: "UTC")
        var now = occurrence
        var waits: [TimeInterval] = []
        for attempt in 1..<ScheduledTaskRetry.maximumAttempts {
            let next = try #require(ScheduledTaskRetry.retryAt(
                afterAttempt: attempt,
                isRetryable: true,
                retryAfter: nil,
                occurrenceAt: occurrence,
                now: now
            ))
            waits.append(next.timeIntervalSince(now))
            now = next
        }
        #expect(waits == [300, 900, 2_700, 7_200])
        #expect(ScheduledTaskRetry.maximumAttempts == 5)
        #expect(ScheduledTaskRetry.retryAt(
            afterAttempt: ScheduledTaskRetry.maximumAttempts,
            isRetryable: true,
            retryAfter: nil,
            occurrenceAt: occurrence,
            now: now
        ) == nil)
    }

    @Test("A final failure, a server wait past the window, or a try that would come too late is not made")
    func retryRefusals() {
        let occurrence = date("2026-08-10T02:00:00", zone: "UTC")
        #expect(ScheduledTaskRetry.retryAt(
            afterAttempt: 1, isRetryable: false, retryAfter: nil, occurrenceAt: occurrence, now: occurrence
        ) == nil)
        // The server's own wait is never cut short…
        #expect(ScheduledTaskRetry.retryAt(
            afterAttempt: 1, isRetryable: true, retryAfter: 3_600, occurrenceAt: occurrence, now: occurrence
        ) == occurrence.addingTimeInterval(3_600))
        // …and one it puts past the catch-up window means no try at all.
        #expect(ScheduledTaskRetry.retryAt(
            afterAttempt: 1, isRetryable: true, retryAfter: 13 * 3_600, occurrenceAt: occurrence, now: occurrence
        ) == nil)
        let late = occurrence.addingTimeInterval(ScheduledTask.catchUpWindow - 60)
        #expect(ScheduledTaskRetry.retryAt(
            afterAttempt: 1, isRetryable: true, retryAfter: nil, occurrenceAt: occurrence, now: late
        ) == nil)
    }

    @Test("A receipt past its first try says which")
    func ordinalTries() {
        #expect(ScheduledTaskRetry.ordinalTry(2) == "2nd try")
        #expect(ScheduledTaskRetry.ordinalTry(3) == "3rd try")
        #expect(ScheduledTaskRetry.ordinalTry(4) == "4th try")
        #expect(ScheduledTaskRetry.ordinalTry(11) == "11th try")
        #expect(ScheduledTaskRetry.ordinalTry(21) == "21st try")
    }

    @Test("Only the Mac that failed a run tries it again, once due, while the task is on")
    func dueRetryBelongsToTheFailingMac() {
        var task = ScheduledTask(title: "Night", instruction: "Go.")
        let run = ScheduledTaskRun(
            taskID: task.id,
            occurrenceAt: date("2026-08-10T02:00:00", zone: "UTC"),
            status: .failed,
            deviceName: "Mac A",
            attempt: 1,
            retryAt: date("2026-08-10T02:05:00", zone: "UTC")
        )
        var detail = ScheduledTaskDetail(task: task, runs: [run])
        let now = date("2026-08-10T02:10:00", zone: "UTC")
        #expect(detail.dueRetry(deviceName: "Mac A", now: now)?.id == run.id)
        #expect(detail.dueRetry(deviceName: "Mac B", now: now) == nil)
        #expect(detail.dueRetry(deviceName: "Mac A", now: date("2026-08-10T02:04:00", zone: "UTC")) == nil)
        #expect(detail.upcomingRetry(deviceName: "Mac A", after: date("2026-08-10T02:04:00", zone: "UTC"))
            == date("2026-08-10T02:05:00", zone: "UTC"))
        // A try already due is not "upcoming": one that cannot be taken yet
        // (signed out) must not re-arm the timer every second.
        #expect(detail.upcomingRetry(deviceName: "Mac A", after: now) == nil)
        #expect(detail.upcomingRetry(deviceName: "Mac B", after: date("2026-08-10T02:04:00", zone: "UTC")) == nil)

        task.isEnabled = false
        detail.task = task
        #expect(detail.dueRetry(deviceName: "Mac A", now: now) == nil)
        #expect(detail.upcomingRetry(deviceName: "Mac A", after: date("2026-08-10T02:04:00", zone: "UTC")) == nil)
    }

    @Test("The Mac stays awake for a run in progress always, and before one only when asked and plugged in")
    func wakePolicy() {
        let now = date("2026-08-09T22:00:00", zone: "UTC")
        let soon = (at: date("2026-08-10T02:00:00", zone: "UTC"), title: "Night")
        #expect(ScheduledTaskWakePolicy.hold(
            runningTitle: "Night", nextDue: nil, keepsMacAwake: false, isOnPower: false, now: now
        ) == .running(title: "Night"))
        #expect(ScheduledTaskWakePolicy.hold(
            runningTitle: nil, nextDue: soon, keepsMacAwake: true, isOnPower: true, now: now
        ) == .waiting(title: "Night", dueAt: soon.at))
        #expect(ScheduledTaskWakePolicy.hold(
            runningTitle: nil, nextDue: soon, keepsMacAwake: false, isOnPower: true, now: now
        ) == .none)
        // A laptop on battery is left to sleep.
        #expect(ScheduledTaskWakePolicy.hold(
            runningTitle: nil, nextDue: soon, keepsMacAwake: true, isOnPower: false, now: now
        ) == .none)

        // A run further off than the lookahead holds nothing yet, and says
        // when to look again.
        let far = (at: now.addingTimeInterval(ScheduledTaskWakePolicy.lookahead + 3_600), title: "Weekly")
        #expect(ScheduledTaskWakePolicy.hold(
            runningTitle: nil, nextDue: far, keepsMacAwake: true, isOnPower: true, now: now
        ) == .none)
        #expect(ScheduledTaskWakePolicy.reconsiderAt(nextDue: far.at, keepsMacAwake: true, now: now)
            == now.addingTimeInterval(3_600))
        #expect(ScheduledTaskWakePolicy.reconsiderAt(nextDue: far.at, keepsMacAwake: false, now: now) == nil)
        #expect(ScheduledTaskWakePolicy.reconsiderAt(nextDue: soon.at, keepsMacAwake: true, now: now) == nil)

        // Each Mac decides for itself.
        #expect(!SyncedPreferenceKeys.isSynced(ScheduledTaskWakePolicy.keepMacAwakeKey))
    }

    @Test("A failed run's next try is taken once, when due, on the same receipt")
    func retryIsClaimedOnTheSameReceipt() throws {
        let root = temporaryRoot("ScheduledTaskRetryClaim")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let task = try store.saveScheduledTask(ScheduledTask(title: "Night", instruction: "Go."))
        let occurrence = date("2026-08-10T02:00:00", zone: "UTC")
        let first = try #require(try store.claimScheduledTaskOccurrence(
            taskID: task.id,
            occurrenceAt: occurrence,
            deviceName: "Mac A",
            now: occurrence
        ))
        #expect(first.attempt == 1)

        let retryAt = occurrence.addingTimeInterval(300)
        try store.finishScheduledTaskRun(
            runID: first.id,
            status: .failed,
            sessionID: "session-1",
            message: "Rate limit exceeded (429).",
            retryAt: retryAt,
            finishedAt: occurrence.addingTimeInterval(30)
        )
        var run = try #require(try store.loadScheduledTaskRuns(taskID: task.id).first)
        #expect(run.isAwaitingRetry)
        #expect(run.retryAt == retryAt)

        #expect(try store.claimScheduledTaskRetry(runID: first.id, now: retryAt.addingTimeInterval(-1)) == nil)
        let second = try #require(try store.claimScheduledTaskRetry(runID: first.id, now: retryAt))
        #expect(second.id == first.id)
        #expect(second.attempt == 2)
        #expect(second.status == .running)
        #expect(second.retryAt == nil)
        #expect(second.finishedAt == nil)
        #expect(second.startedAt == first.startedAt)
        #expect(second.sessionID == "session-1")
        #expect(try store.loadScheduledTask(task.id)?.lastRunStatus == .running)
        // Taken once: a second launch, or a second pass, finds nothing.
        #expect(try store.claimScheduledTaskRetry(runID: first.id, now: retryAt) == nil)

        try store.finishScheduledTaskRun(
            runID: first.id,
            status: .succeeded,
            sessionID: "session-1",
            message: nil,
            retryAt: retryAt.addingTimeInterval(900)
        )
        run = try #require(try store.loadScheduledTaskRuns(taskID: task.id).first)
        #expect(run.status == .succeeded)
        #expect(run.attempt == 2)
        // A next try means nothing on a run that did not fail.
        #expect(run.retryAt == nil)
        // One morning, one receipt.
        #expect(try store.loadScheduledTaskRuns(taskID: task.id).count == 1)
    }

    @Test("A paused task, a given-up try, or a newer run settles a waiting retry")
    func waitingRetriesAreSettled() throws {
        let root = temporaryRoot("ScheduledTaskRetrySettle")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        let task = try store.saveScheduledTask(ScheduledTask(title: "Night", instruction: "Go."))
        let occurrence = date("2026-08-10T02:00:00", zone: "UTC")
        let first = try #require(try store.claimScheduledTaskOccurrence(taskID: task.id, occurrenceAt: occurrence))
        let retryAt = occurrence.addingTimeInterval(300)
        try store.finishScheduledTaskRun(
            runID: first.id, status: .failed, sessionID: nil, message: "Overloaded.", retryAt: retryAt
        )

        // Paused, the try waits untaken.
        var paused = try #require(try store.loadScheduledTask(task.id))
        paused.isEnabled = false
        try store.saveScheduledTask(paused)
        #expect(try store.claimScheduledTaskRetry(runID: first.id, now: retryAt) == nil)
        paused.isEnabled = true
        try store.saveScheduledTask(paused)

        // Given up on, it says why after the failure it already carries.
        try store.abandonScheduledTaskRetry(runID: first.id, note: "Not tried again: ForeverLM was closed.")
        let settled = try #require(try store.loadScheduledTaskRuns(taskID: task.id).first)
        #expect(settled.retryAt == nil)
        #expect(settled.status == .failed)
        #expect(settled.message == "Overloaded. Not tried again: ForeverLM was closed.")
        #expect(try store.claimScheduledTaskRetry(runID: first.id, now: retryAt) == nil)

        // A newer run retires an older one's waiting try, so Run now or the
        // next morning is never followed by a second chat for the old one.
        let nextDay = occurrence.addingTimeInterval(86_400)
        let second = try #require(try store.claimScheduledTaskOccurrence(taskID: task.id, occurrenceAt: nextDay))
        try store.finishScheduledTaskRun(
            runID: second.id, status: .failed, sessionID: nil, message: "Overloaded.", retryAt: nextDay.addingTimeInterval(300)
        )
        _ = try #require(try store.claimScheduledTaskOccurrence(taskID: task.id, occurrenceAt: nextDay.addingTimeInterval(60)))
        let superseded = try #require(try store.loadScheduledTaskRuns(taskID: task.id).first { $0.id == second.id })
        #expect(superseded.retryAt == nil)
        #expect(try store.claimScheduledTaskRetry(runID: second.id, now: nextDay.addingTimeInterval(300)) == nil)
    }

    @Test("A receipt written before retries decodes as its only try, and a new one round-trips")
    func receiptPayloadsAcrossBuilds() throws {
        let older = """
            {"id":"run-1","taskID":"task-1","occurrenceAt":800000000,"status":"failed","message":"Overloaded."}
            """
        let run = try JSONDecoder().decode(ScheduledTaskRun.self, from: Data(older.utf8))
        #expect(run.attempt == 1)
        #expect(run.retryAt == nil)
        #expect(!run.isAwaitingRetry)

        let waiting = ScheduledTaskRun(
            taskID: "task-1",
            occurrenceAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            status: .failed,
            attempt: 3,
            retryAt: Date(timeIntervalSinceReferenceDate: 800_002_700)
        )
        let decoded = try JSONDecoder().decode(ScheduledTaskRun.self, from: JSONEncoder().encode(waiting))
        #expect(decoded == waiting)
        #expect(decoded.isAwaitingRetry)
    }

    @Test("A production-sized library with years of receipts migrates to 146 in well under a second")
    func migrationTo146Scales() throws {
        let root = temporaryRoot("ScheduledTaskMigration146Scale")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try KnowledgeStore(storeDirectory: root)
            try store.execForTesting("BEGIN IMMEDIATE")
            try store.execForTesting("""
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000)
                INSERT INTO articles (source_id, url, normalized_url, title, domain)
                SELECT printf('source-%05d', n), printf('https://example.com/%05d', n),
                       printf('example.com/%05d', n), printf('Source %05d', n), 'example.com' FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 50)
                INSERT INTO scheduled_tasks (id, title, instruction, created_at, updated_at)
                SELECT printf('task-%02d', n), printf('Task %02d', n), 'Go.', 0, 0 FROM seq;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000)
                INSERT INTO scheduled_task_runs (id, task_id, occurrence_at, started_at, status)
                SELECT printf('run-%04d', n), printf('task-%02d', 1 + n % 50), n * 86400.0, n * 86400.0, 'succeeded' FROM seq;
                COMMIT;
            """)
            try Self.reshapeToVersion145(store)
        }

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = started.duration(to: .now)
        // Two ALTER TABLE ADD COLUMNs with constant defaults: no row is read
        // or rewritten, so the cost cannot follow the library.
        #expect(elapsed < .seconds(1))
        #expect(sqliteScalar(at: root, "PRAGMA user_version") == Int(KnowledgeStore.schemaVersion))
        #expect(scalar(migrated, "SELECT COUNT(*) FROM source_projection") == 20_000, "sources stay visible")
        #expect(scalar(migrated, "SELECT COUNT(*) FROM scheduled_task_runs WHERE attempt = 1 AND retry_at IS NULL") == 1_000)
    }

    /// The released v145 shape: `scheduled_task_runs` as schema 72 created
    /// it, without `attempt` and `retry_at`. Dropping the columns rather than
    /// lowering the stamp is what makes the forward step run its ALTERs.
    private static func reshapeToVersion145(_ store: KnowledgeStore) throws {
        try store.execForTesting("ALTER TABLE scheduled_task_runs DROP COLUMN retry_at")
        try store.execForTesting("ALTER TABLE scheduled_task_runs DROP COLUMN attempt")
        try store.execForTesting("PRAGMA user_version = 145")
    }

    private static let retryColumns = """
        SELECT COUNT(*) FROM pragma_table_info('scheduled_task_runs') WHERE name IN ('attempt', 'retry_at')
        """

    private func sqliteScalar(at root: URL, _ sql: String) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path, &database, SQLITE_OPEN_READONLY, nil
        ) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(database) }
        return sqliteScalar(database, sql)
    }

    // MARK: - Helpers

    /// The real version-71 shape. Version 72 adds two brand-new tables and
    /// changes nothing else, so dropping exactly those two tables reproduces the
    /// released schema rather than approximating it.
    private func makeVersion71Fixture(sourceCount: Int) throws -> URL {
        let root = temporaryRoot("ScheduledTaskV71Fixture")
        let store = try KnowledgeStore(storeDirectory: root)
        try store.execForTesting("BEGIN IMMEDIATE")
        do {
            try store.execForTesting("""
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(sourceCount)
                )
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq;
                WITH RECURSIVE seq(n) AS (
                    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(sourceCount)
                )
                INSERT INTO articles (source_id, url, normalized_url, title, domain)
                SELECT printf('source-%05d', n), printf('https://example.com/%05d', n),
                       printf('example.com/%05d', n), printf('Source %05d', n),
                       'example.com' FROM seq;
                INSERT INTO learning_goals (id, title, start_at, end_at, created_at, updated_at, status)
                VALUES ('notebook-a', 'Immunology', 0, 0, 0, 0, 'active');
                DROP TABLE scheduled_task_runs;
                DROP TABLE scheduled_tasks;
                PRAGMA user_version = 71;
                COMMIT;
            """)
        } catch {
            try? store.execForTesting("ROLLBACK")
            throw error
        }
        return root
    }

    private func temporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString)", isDirectory: true)
    }

    private func scalar(_ store: KnowledgeStore, _ sql: String) -> Int {
        var value = 0
        try? store.query(sql) { value = Int(sqlite3_column_int64($0, 0)) }
        return value
    }

    private func sqliteScalar(_ database: OpaquePointer?, _ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func date(_ value: String, zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: zone)
        return formatter.date(from: value)!
    }
}
