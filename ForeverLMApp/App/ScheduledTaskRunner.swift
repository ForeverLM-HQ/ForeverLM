import AppKit
import Foundation
import IOKit.ps
import Observation
import OSLog

/// Runs scheduled tasks when they come due.
///
/// A run is deliberately nothing more than a chat turn the app sends on the
/// learner's behalf: same manager, same app tool surface, same persistence,
/// same cost ledger. The output is therefore an ordinary conversation in the
/// rail that the learner can read, continue, rename, or delete — not a private
/// artifact of an automation subsystem.
///
/// **Where a run happens.** Whichever signed-in client is open when the task
/// comes due. Nothing runs on a server, so a Mac that was closed all morning
/// catches up on launch inside `ScheduledTask.catchUpWindow` and records a
/// visible `skipped` receipt for anything older.
///
/// **A run tries hard before it fails** (product owner, 2026-09-27: a task turned
/// on overnight, "especially if it's on a free model", should not simply
/// error out). Inside one try, the chat's own turn retries a dropped
/// connection or a short rate limit, and then the run moves through the Chat
/// model's backups (`AIBackupModels.chatConfigs`) while the failure is one
/// another model could get past. A try that still fails in a way time may fix
/// is tried again later on the same receipt (`ScheduledTaskRetry`), in the
/// same chat when this Mac kept it open.
///
/// **Timing is event-driven.** One timer is armed for the single next due
/// instant across every task and every pending retry, and re-armed on the
/// events that can invalidate it: waking, activation, a clock change, a local
/// edit, and an inbound sync. There is no polling loop.
@MainActor
@Observable
final class ScheduledTaskRunner {
    static let shared = ScheduledTaskRunner()

    private(set) var details: [ScheduledTaskDetail] = []
    /// Task IDs currently generating on *this* device.
    private(set) var runningTaskIDs: Set<String> = []
    /// Whether this Mac stays awake while a task is due
    /// (`ScheduledTaskWakePolicy`): the Tasks pane's ⋯ › Keep This Mac
    /// Awake for Tasks (its header's cup button until 2026-10-06), and
    /// `tasks.keep_mac_awake` over MCP. This Mac only.
    private(set) var keepsMacAwake = UserDefaults.standard.bool(forKey: ScheduledTaskWakePolicy.keepMacAwakeKey)
    /// The chat each running task is generating in, so `stop` can end it.
    @ObservationIgnored private var runningManagers: [String: ReviewSessionManager] = [:]
    /// Runs `stop` ended, recorded as stopped rather than as a finished chat.
    @ObservationIgnored private var stoppedTaskIDs: Set<String> = []
    /// The chat a failed try left open, by receipt id, so the next try goes
    /// on in it the way the chat's Retry would: the same transcript, tools and
    /// sources. Held only while the app runs; after a relaunch the next try
    /// starts a new chat, and the failed one stays in the rail as it was.
    @ObservationIgnored private var chatsAwaitingRetry: [String: RetainedChat] = [:]
    private let wakeKeeper = ScheduledTaskWakeKeeper()
    private(set) var lastLoadErrorMessage: String?

    /// Resolves attached source IDs into the article objects Chat needs.
    /// Studio installs this at launch; without it a task still runs, just with
    /// no attached sources rather than with silently wrong ones.
    var articleProvider: (([String]) -> [StudioArticle])?
    /// Whether a given goal ID names a Notebook, so a run can scope its source
    /// reads the way an ordinary Notebook chat does.
    var notebookLookup: ((String) -> Bool)?

    private let storage = StorageService()
    private let logger = Logger(subsystem: "ForeverLM", category: "ScheduledTasks")
    private var timer: Timer?
    private var isDraining = false
    private var hasStarted = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Lifecycle

    /// Called once from Studio's launch task.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        installObservers()
        Task {
            // A run left mid-flight by a quit is not still running. Settle those
            // receipts before anything reads them, so the surface never shows a
            // spinner with nothing behind it.
            _ = try? await storage.failInterruptedScheduledTaskRuns(deviceName: Self.deviceName)
            await refresh()
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        // Waking, coming forward, and a moved clock are the three ways an armed
        // timer stops describing reality.
        for (notificationCenter, name) in [
            (workspace, NSWorkspace.didWakeNotification),
            (center, NSApplication.didBecomeActiveNotification),
            (center, NSNotification.Name.NSSystemClockDidChange),
            (center, NSNotification.Name.NSSystemTimeZoneDidChange),
        ] {
            observers.append(notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in ScheduledTaskRunner.shared.scheduleRefresh() }
            })
        }

        // An MCP write lands in the same process but not through this class.
        observers.append(center.addObserver(
            forName: .scheduledTasksDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ScheduledTaskRunner.shared.scheduleRefresh() }
        })

        // An edit made on the other Mac — a task disabled, its time changed, or
        // its morning already claimed — must reach the armed timer here.
        observers.append(center.addObserver(
            forName: .cloudKitSyncRemoteStoreDidChange, object: nil, queue: .main
        ) { notification in
            let rawValues = notification.userInfo?[CloudKitSyncNotificationInfo.affectedEntitiesKey]
                as? [String] ?? []
            let entities = Set(rawValues.compactMap(CloudKitSyncEntity.init(rawValue:)))
            let requiresFullRefresh = notification.userInfo?[
                CloudKitSyncNotificationInfo.requiresFullRefreshKey
            ] as? Bool ?? false
            guard requiresFullRefresh || entities.contains(.scheduledTask) else { return }
            Task { @MainActor in ScheduledTaskRunner.shared.scheduleRefresh() }
        })
    }

    private func scheduleRefresh() {
        Task { await refresh() }
    }

    // MARK: - State

    /// Reloads definitions and receipts off-main, republishes, and re-arms.
    func refresh() async {
        do {
            let loaded = try await storage.loadScheduledTaskDetails()
            lastLoadErrorMessage = nil
            publish(loaded)
        } catch {
            lastLoadErrorMessage = error.localizedDescription
            logger.error("Failed to load scheduled tasks: \(error.localizedDescription)")
        }
        await drainDueTasks()
        armTimer()
        updateWakeHold()
    }

    /// The next instant anything is due on this Mac: an occurrence, or the
    /// next try of a run this Mac failed.
    var nextOccurrence: Date? {
        nextDue()?.at
    }

    private func nextDue(now: Date = Date()) -> (at: Date, title: String)? {
        let device = Self.deviceName
        return details.compactMap { detail -> (at: Date, title: String)? in
            let candidates = [
                detail.task.upcomingOccurrence(now: now),
                detail.upcomingRetry(deviceName: device, after: now),
            ].compactMap { $0 }
            return candidates.min().map { ($0, detail.task.title) }
        }.min { $0.at < $1.at }
    }

    func isRunning(taskID: String) -> Bool { runningTaskIDs.contains(taskID) }

    // MARK: - Editing

    @discardableResult
    func save(_ task: ScheduledTask) async throws -> ScheduledTask {
        let saved = try await storage.saveScheduledTask(task)
        await refresh()
        return saved
    }

    func delete(taskID: String) async throws {
        try await storage.deleteScheduledTask(taskID)
        await refresh()
    }

    func setEnabled(_ isEnabled: Bool, taskID: String) async throws {
        guard var task = details.first(where: { $0.task.id == taskID })?.task else { return }
        task.isEnabled = isEnabled
        task.updatedAt = Date()
        try await save(task)
    }

    func runNow(taskID: String) async throws {
        try await storage.requestScheduledTaskRunNow(taskID)
        await refresh()
    }

    /// Stops a run generating on this Mac, as the chat's Stop button does: the
    /// reply so far is kept and the run is recorded as stopped. False when the
    /// task is not running here, or is between two turns with nothing to stop.
    /// `cancel_ai_work` is the caller.
    @discardableResult
    func stop(taskID: String) -> Bool {
        guard let manager = runningManagers[taskID], manager.canStopGeneration else { return false }
        stoppedTaskIDs.insert(taskID)
        manager.stopGeneration()
        return true
    }

    /// The Tasks pane's Keep This Mac Awake for Tasks: whether this Mac holds off idle sleep
    /// while a task is due (`ScheduledTaskWakePolicy`). Never syncs.
    func setKeepsMacAwake(_ keepsMacAwake: Bool) {
        UserDefaults.standard.set(keepsMacAwake, forKey: ScheduledTaskWakePolicy.keepMacAwakeKey)
        self.keepsMacAwake = keepsMacAwake
        updateWakeHold()
    }

    // MARK: - Timer

    private func armTimer() {
        timer?.invalidate()
        timer = nil
        guard let next = nextOccurrence else { return }
        // A negative or zero interval means something already came due while we
        // were computing; `drainDueTasks` has already had its chance, so arm a
        // minimal delay rather than spinning.
        let interval = max(next.timeIntervalSinceNow, 1)
        let scheduled = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in ScheduledTaskRunner.shared.scheduleRefresh() }
        }
        // Fire while the learner is dragging a scroller or holding a menu open;
        // a briefing that waits for an idle run loop is a briefing that is late.
        RunLoop.main.add(scheduled, forMode: .common)
        scheduled.tolerance = 30
        timer = scheduled
    }

    // MARK: - Keeping the Mac awake

    /// Hands the keeper what it decides from: what is generating here, what
    /// comes due next, and the learner's switch.
    func updateWakeHold() {
        let runningTitle: String? = runningTaskIDs.isEmpty ? nil : (
            details.first { runningTaskIDs.contains($0.task.id) }?.task.title ?? "a scheduled task"
        )
        wakeKeeper.update(
            runningTitle: runningTitle,
            nextDue: nextDue(),
            keepsMacAwake: keepsMacAwake
        )
    }

    // MARK: - Running

    /// Runs every task that is due, one at a time.
    ///
    /// Serial on purpose: a Mac opened after a long weekend can have several
    /// tasks due at once, and three simultaneous tool-using conversations would
    /// compete for the same rate limits and the same balance.
    private func drainDueTasks(now: Date = Date()) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        let device = Self.deviceName
        var settledStaleRetry = false
        for detail in details {
            // A try that would come too late is settled, whichever Mac failed
            // it: that Mac would settle it the same way.
            for run in detail.runs where run.isAwaitingRetry && detail.task.isStale(occurrence: run.occurrenceAt, now: now) {
                try? await storage.abandonScheduledTaskRetry(
                    runID: run.id,
                    note: "Not tried again: ForeverLM was not open when the next try was due."
                )
                settledStaleRetry = true
            }
            if let due = detail.task.dueOccurrence(now: now) {
                await runIfClaimed(task: detail.task, occurrence: due.occurrence, now: now)
            } else if let retry = detail.dueRetry(deviceName: device, now: now),
                      !detail.task.isStale(occurrence: retry.occurrenceAt, now: now) {
                await retryIfClaimed(task: detail.task, run: retry)
            }
        }
        if settledStaleRetry { await reloadDetails() }
    }

    private func runIfClaimed(task: ScheduledTask, occurrence: Date, now: Date) async {
        // An occurrence too old to be useful is retired with a visible receipt.
        // Generating Monday's briefing on Wednesday is worse than saying it was
        // missed.
        if task.isStale(occurrence: occurrence, now: now) {
            _ = try? await storage.claimScheduledTaskOccurrence(
                taskID: task.id,
                occurrenceAt: occurrence,
                status: .skipped,
                message: "ForeverLM was not open when this was due.",
                deviceName: Self.deviceName
            )
            return
        }

        // Managed AI needs the Apple identity. Without it the run would fail on
        // every attempt, so leave the occurrence unclaimed: signing in inside
        // the catch-up window still produces the chat.
        guard ManagedAI.isSignedIn else { return }

        guard let run = try? await storage.claimScheduledTaskOccurrence(
            taskID: task.id,
            occurrenceAt: occurrence,
            deviceName: Self.deviceName
        ) else {
            // Already claimed — by an earlier launch of this app, or by another
            // Mac whose record arrived first. Not an error.
            return
        }
        await execute(task: task, run: run)
    }

    /// The next try of a run this Mac failed, once its time has come. Signed
    /// out, it waits, exactly as an unclaimed occurrence does.
    private func retryIfClaimed(task: ScheduledTask, run: ScheduledTaskRun) async {
        guard ManagedAI.isSignedIn else { return }
        // The chat the failed try left open was continued, deleted or
        // otherwise changed since: someone is dealing with it, and a second
        // answer from a stale copy of it would only get in their way.
        if let retained = chatsAwaitingRetry[run.id], !(await chatIsAsItWasLeft(retained)) {
            chatsAwaitingRetry[run.id] = nil
            retained.manager.endSession()
            try? await storage.abandonScheduledTaskRetry(
                runID: run.id,
                note: "Not tried again: its chat changed after the failed try."
            )
            await reloadDetails()
            return
        }
        guard let claimed = try? await storage.claimScheduledTaskRetry(runID: run.id) else {
            // Taken by an earlier launch, superseded by a newer run, or the
            // task was paused since. Not an error.
            return
        }
        await execute(task: task, run: claimed)
    }

    /// One try at a claimed receipt, and its outcome written back.
    private func execute(task: ScheduledTask, run: ScheduledTaskRun) async {
        // Taken before the reload below, which releases chats whose receipt
        // no longer waits: this one is running now.
        let retained = chatsAwaitingRetry.removeValue(forKey: run.id)
        runningTaskIDs.insert(task.id)
        await reloadDetails()
        updateWakeHold()

        let outcome = await generate(task: task, run: run, continuing: retained)
        runningTaskIDs.remove(task.id)
        do {
            try await storage.finishScheduledTaskRun(
                runID: run.id,
                status: outcome.status,
                sessionID: outcome.sessionID,
                message: outcome.message,
                retryAt: outcome.retryAt
            )
        } catch {
            logger.error("Failed to record scheduled task outcome: \(error.localizedDescription)")
        }
        if let retryAt = outcome.retryAt {
            logger.notice(
                "Scheduled task \(task.id, privacy: .public) failed its try \(run.attempt); trying again at \(retryAt, privacy: .public)"
            )
        }
        await reloadDetails()
        updateWakeHold()
    }

    private struct RunOutcome {
        var status: ScheduledTaskRunStatus
        var sessionID: String?
        var message: String?
        var retryAt: Date?
    }

    /// A failed try's chat, held for the next try.
    private struct RetainedChat {
        let manager: ReviewSessionManager
        let sessionID: String
        /// What the chat held when the try failed. Any other count at the next
        /// try means someone went on in the chat by hand, and answering it
        /// again from this stale copy would write around them.
        let exchangeCount: Int
    }

    private func generate(
        task: ScheduledTask,
        run: ScheduledTaskRun,
        continuing retained: RetainedChat?
    ) async -> RunOutcome {
        let chain = await ScheduledRunModelChain.resolve()
        // A held chat was checked unchanged just before the claim.
        let continuesChat = retained != nil
        let manager = retained?.manager ?? StudioAssistantSession.makeManager()

        runningManagers[task.id] = manager
        manager.modelOverride = nil
        if continuesChat {
            await manager.retryLastGeneration()
        } else {
            let articles = articleProvider?(task.sourceIDs) ?? []
            let notebookScopeID: String? = {
                guard let notebookID = task.notebookID else { return nil }
                return notebookLookup?(notebookID) == true ? notebookID : nil
            }()
            await manager.sendMessage(
                task.instruction,
                topic: task.title,
                articles: articles,
                initialMode: .assistant,
                goalID: task.notebookID,
                notebookScopeID: notebookScopeID
            )
        }

        // The backups, in order, while the failure is one another model could
        // get past. Each goes on in the same chat, as Retry would.
        var errors: [Error] = []
        var failedModelNames: [String] = []
        var answeringBackup: Int?
        var nextBackup = 0
        while Self.turnFailed(manager), !stoppedTaskIDs.contains(task.id) {
            let turnError = manager.lastGenerationError
            if let turnError { errors.append(turnError) }
            let failedName = nextBackup == 0 ? chain.primaryName : chain.backupNames[nextBackup - 1]
            failedModelNames.append(failedName)
            guard nextBackup < chain.backups.count,
                  let movable = turnError, AIBackupModels.shouldTryBackup(after: movable),
                  manager.canRetryLastGeneration else { break }
            logger.notice(
                "Scheduled task \(task.id, privacy: .public): \(failedName, privacy: .public) failed, trying backup \(chain.backupNames[nextBackup], privacy: .public): \(movable.localizedDescription, privacy: .public)"
            )
            manager.modelOverride = chain.backups[nextBackup]
            nextBackup += 1
            await manager.retryLastGeneration()
            if !Self.turnFailed(manager) { answeringBackup = nextBackup - 1 }
        }
        runningManagers[task.id] = nil
        // The next try walks the chain from the top again.
        manager.modelOverride = nil

        let sessionID = manager.currentSessionID ?? run.sessionID

        if stoppedTaskIDs.remove(task.id) != nil {
            manager.endSession()
            return RunOutcome(status: .failed, sessionID: sessionID, message: "Stopped before it finished.")
        }

        // AI failures are surfaced, never smoothed over: a run that could not
        // reach the model is a failed run with the provider's own message on
        // it, and names the backups that failed with it.
        if let failure = manager.errorMessage, !failure.isEmpty {
            let chainError = errors.isEmpty ? nil : AIBackupModels.chainFailure(errors)
            var message = chainError?.localizedDescription ?? failure
            if failedModelNames.count > 1 {
                message += " Backups tried: \(failedModelNames.dropFirst().joined(separator: ", "))."
            }
            let retryAt = ScheduledTaskRetry.retryAt(
                afterAttempt: run.attempt,
                isRetryable: chainError.map(AITransientErrorClassifier.isTransient) ?? false,
                retryAfter: chainError.flatMap(AITransientErrorClassifier.retryAfterSeconds),
                occurrenceAt: run.occurrenceAt,
                now: Date()
            )
            if retryAt != nil, let liveSessionID = manager.currentSessionID, manager.canRetryLastGeneration {
                let exchangeCount = (try? await storage.loadReviewSessionExchanges(sessionID: liveSessionID).count) ?? -1
                chatsAwaitingRetry[run.id] = RetainedChat(
                    manager: manager,
                    sessionID: liveSessionID,
                    exchangeCount: exchangeCount
                )
            } else {
                manager.endSession()
            }
            return RunOutcome(status: .failed, sessionID: sessionID, message: message, retryAt: retryAt)
        }
        manager.endSession()

        guard let sessionID else {
            return RunOutcome(
                status: .failed,
                sessionID: nil,
                message: "The run produced no chat."
            )
        }
        // A backup that answered is said on the receipt: the learner chose
        // the Default Model, and the chat was written by another.
        let note = answeringBackup.map { index in
            let why = (errors.first?.localizedDescription).map { ": \($0)" } ?? "."
            return "\(chain.backupNames[index]) answered as a backup after \(failedModelNames.first ?? chain.primaryName) failed\(why)"
        }
        return RunOutcome(status: .succeeded, sessionID: sessionID, message: note)
    }

    private static func turnFailed(_ manager: ReviewSessionManager) -> Bool {
        !(manager.errorMessage ?? "").isEmpty
    }

    /// Whether a held chat can take the next try: still the chat that
    /// failed, still offering Retry, and not continued by hand since.
    private func chatIsAsItWasLeft(_ retained: RetainedChat) async -> Bool {
        guard retained.manager.currentSessionID == retained.sessionID,
              retained.manager.canRetryLastGeneration,
              let count = try? await storage.loadReviewSessionExchanges(sessionID: retained.sessionID).count
        else { return false }
        return count == retained.exchangeCount
    }

    /// Republishes definitions and receipts without re-entering the drain.
    private func reloadDetails() async {
        guard let loaded = try? await storage.loadScheduledTaskDetails() else { return }
        publish(loaded)
    }

    private func publish(_ loaded: [ScheduledTaskDetail]) {
        guard loaded != details else { return }
        details = loaded
        releaseChatsNoLongerAwaitingRetry()
    }

    /// A held chat goes once its receipt stops waiting: the try was
    /// superseded by a newer run, settled, or its task deleted. One whose
    /// receipt is running keeps its place, since its try is under way.
    private func releaseChatsNoLongerAwaitingRetry() {
        guard !chatsAwaitingRetry.isEmpty else { return }
        let held = Set(details.flatMap(\.runs).filter { $0.isAwaitingRetry || $0.status == .running }.map(\.id))
        for (runID, chat) in chatsAwaitingRetry where !held.contains(runID) {
            chat.manager.endSession()
            chatsAwaitingRetry[runID] = nil
        }
    }

    private static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

/// The models one try walks: the chat's Default Model, then its backups.
/// Resolved off the main actor, since each backup's key is a Keychain read.
private struct ScheduledRunModelChain: Sendable {
    let primaryName: String
    let backups: [AITaskConfig]
    let backupNames: [String]

    static func resolve() async -> ScheduledRunModelChain {
        await Task.detached(priority: .userInitiated) {
            let backups = AIBackupModels.chatConfigs()
            return ScheduledRunModelChain(
                primaryName: AIModelCatalog.defaultEntry?.displayName ?? "The Default Model",
                backups: backups,
                backupNames: backups.map { AIModelCatalog.displayName(provider: $0.provider, modelID: $0.model) }
            )
        }.value
    }
}

// MARK: - Keeping the Mac awake

/// Holds off idle sleep as `ScheduledTaskWakePolicy` decides, through a
/// user-initiated `ProcessInfo` activity: that keeps the system awake with
/// the display allowed to sleep, and keeps App Nap from stretching the
/// runner's timer. It shows in `pmset -g assertions` under its reason.
/// Re-decides when the Mac moves between battery and power, and at the
/// moment a far-off run comes inside the lookahead.
@MainActor
final class ScheduledTaskWakeKeeper {
    nonisolated init() {}

    private var activity: NSObjectProtocol?
    private var current: ScheduledTaskWakePolicy.Hold = .none
    private var reconsiderTimer: Timer?
    private var powerSourceLoop: CFRunLoopSource?

    func update(
        runningTitle: String?,
        nextDue: (at: Date, title: String)?,
        keepsMacAwake: Bool,
        now: Date = Date()
    ) {
        if keepsMacAwake { watchPowerSource() }
        let hold = ScheduledTaskWakePolicy.hold(
            runningTitle: runningTitle,
            nextDue: nextDue,
            keepsMacAwake: keepsMacAwake,
            isOnPower: Self.isOnPower,
            now: now
        )
        apply(hold)

        reconsiderTimer?.invalidate()
        reconsiderTimer = nil
        if hold == .none,
           let at = ScheduledTaskWakePolicy.reconsiderAt(nextDue: nextDue?.at, keepsMacAwake: keepsMacAwake, now: now) {
            let timer = Timer(fire: at, interval: 0, repeats: false) { _ in
                Task { @MainActor in ScheduledTaskRunner.shared.updateWakeHold() }
            }
            timer.tolerance = 60
            RunLoop.main.add(timer, forMode: .common)
            reconsiderTimer = timer
        }
    }

    private func apply(_ hold: ScheduledTaskWakePolicy.Hold) {
        guard hold != current else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        current = hold
        let reason: String
        switch hold {
        case .none:
            return
        case .running(let title):
            // Straight quotes: `pmset -g assertions` prints curly ones as
            // bytes that are not UTF-8.
            reason = "ForeverLM is running the scheduled task \"\(title)\""
        case .waiting(let title, let dueAt):
            reason = "ForeverLM keeps this Mac awake for the scheduled task \"\(title)\" at \(Self.clock.string(from: dueAt))"
        }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: reason)
    }

    /// On the power adapter, or on a Mac with no battery. A snapshot that
    /// cannot be read counts as power: every desktop Mac reads as power.
    private static var isOnPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    /// Plugging in or unplugging changes the answer for a waiting run.
    private func watchPowerSource() {
        guard powerSourceLoop == nil,
              let loop = IOPSNotificationCreateRunLoopSource({ _ in
                  Task { @MainActor in ScheduledTaskRunner.shared.updateWakeHold() }
              }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
        powerSourceLoop = loop
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
