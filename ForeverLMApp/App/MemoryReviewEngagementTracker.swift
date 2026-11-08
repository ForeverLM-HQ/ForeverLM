import AppKit
import Observation
import OSLog

/// The Mac's clock on today's memory review, and the live source of today's
/// goal state for the rail, the Memory pane and the review itself.
///
/// What shows the review registers itself here while it is on screen: the
/// card review (`MemoryCardSessionView`), or a chat panel showing a day's
/// review chat. While at least one is, a heartbeat runs: every few seconds
/// the `MemoryReviewEngagementClock` decides whether the learner was engaged —
/// a key, click, or scroll within the grace period, or the presenter busy (a
/// tutor mid-reply), and the app frontmost either way — and credits the
/// interval. The total is written to this device's `memory_review_activity`
/// row every half minute and when the last presenter goes away, so the phone
/// and the other Mac see it on their next sync. The moment today crosses the
/// goal, `celebration` is set once and the presenter shows it.
///
/// Reads are cheap and the rail reads `snapshot` directly: today's progress
/// advances here between persists, so the badge counts down live rather than
/// on the next storage round trip.
@MainActor
@Observable
final class MemoryReviewEngagementTracker {
    static let shared = MemoryReviewEngagementTracker()

    struct Celebration: Equatable, Identifiable {
        let id: UUID
        let sessionID: String
        let goalMinutes: Int
        let streak: Int
    }

    /// Today against the goal, and the streak. Advanced live while a review
    /// is on screen; reloaded from the store on activation and after sync.
    private(set) var snapshot: MemoryReviewGoalSnapshot
    /// Set once when today's goal is met with a review on screen; the chat
    /// showing that session presents it and acknowledges it.
    private(set) var celebration: Celebration?
    /// Whether a review is on screen on this device right now. The rail's
    /// minutes are a clock on a running review, so this is what says whether
    /// there is a clock to show at all.
    private(set) var isReviewOnScreen = false
    /// Every day's minutes against the goal it was worked under, summed over
    /// devices, as of the last load. The Memory pane's grid reads it;
    /// today's entry is replaced by the live snapshot in `historyDays`, so a
    /// square being filled in as the review runs does not wait for a persist.
    private(set) var dayProgress: [String: MemoryReviewDayProgress] = [:]
    /// The days whose review chat the learner wrote in, as of the last load.
    /// The grid colours a day from this where it has no minutes; a chat the
    /// morning made and nobody sat is not in it.
    private(set) var answeredDays: Set<String> = []
    /// The end this Mac put to today's session, if it did. Kept in the app's
    /// defaults so a relaunch the same day still knows the session is over;
    /// a record from an earlier day is ignored and replaced.
    private(set) var sessionEnd: MemoryReviewSessionEnd?
    /// Whether a window has given itself over to the review — the commitment
    /// the Memory pane describes above Start Review. Made when the review
    /// takes the window, released when it is left; a quit while it stands is
    /// a leaving.
    private(set) var isCommitted = false
    /// The day this Mac's card review ran out of cards: every card due that
    /// day answered before the goal's minutes were spent, which makes the day
    /// done (`MemoryReviewCommitment.state`). Kept in the app's defaults, like
    /// `sessionEnd`; a record from an earlier day is ignored.
    private(set) var cardsFinishedDay: String?

    @ObservationIgnored private var storage: StorageService?
    @ObservationIgnored private var presenters: [UUID: Presenter] = [:]
    @ObservationIgnored private var clock = MemoryReviewEngagementClock()
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// This device's total for `today`, loaded from its row and advanced here.
    @ObservationIgnored private var deviceSecondsToday: TimeInterval = 0
    /// Every other device's total for `today`, as of the last load.
    @ObservationIgnored private var otherDevicesSecondsToday: TimeInterval = 0
    /// Days other than today that were complete as of the last load, for the
    /// streak when today crosses the line between loads.
    @ObservationIgnored private var completedOtherDays: Set<String> = []
    @ObservationIgnored private var secondsSincePersist: TimeInterval = 0
    /// Closed days whose total has not reached the store yet, by day. A day's
    /// row is written once it closes and nothing writes it again, so a failed
    /// write is kept here and retried with the next persist.
    @ObservationIgnored private var unsavedClosedDays: [String: MemoryReviewActivity] = [:]
    @ObservationIgnored private var today: String
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.foreverlm", category: "MemoryReviewGoal")

    /// Whatever is showing the review: a card review or a chat's manager,
    /// held weakly so one that goes away unannounced stops counting, and
    /// asked whether it is busy (a tutor mid-reply counts as engagement).
    private struct Presenter {
        weak var owner: AnyObject?
        let sessionID: String
        let isBusy: @MainActor () -> Bool
    }

    private init() {
        let now = Date()
        today = MemoryReviewGoal.dayKey(for: now)
        snapshot = .empty(day: today, goalSeconds: MemoryReviewGoal.goalSeconds(budgetMinutes: MemoryReviewBudget.minutes))
        sessionEnd = Self.loadSessionEnd(for: today)
        cardsFinishedDay = Self.loadCardsFinishedDay(for: today)
    }

    // MARK: - The commitment

    /// Where today's review stands: open, ended by the learner, or done.
    var state: MemoryReviewCommitment.State {
        MemoryReviewCommitment.state(snapshot: snapshot, end: sessionEnd, cardsFinished: cardsFinishedDay == today)
    }

    /// Every card today asked for is answered: the day is done, whatever the
    /// minutes say, and the commitment is released.
    func finishDayByCards() {
        isCommitted = false
        guard cardsFinishedDay != today else { return }
        cardsFinishedDay = today
        UserDefaults.standard.set(today, forKey: Self.cardsFinishedDefaultsKey)
        logger.info("Today's cards ran out; the day's review is done")
    }

    private static let cardsFinishedDefaultsKey = "memoryReview.cardsFinishedDay"

    private static func loadCardsFinishedDay(for day: String) -> String? {
        guard let stored = UserDefaults.standard.string(forKey: cardsFinishedDefaultsKey), stored == day else { return nil }
        return stored
    }

    /// Whether today's session was ended early. Over until tomorrow.
    var isTodayEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// Whether there is a clock to show: a review on screen on a day whose
    /// session is not over. The rail's minutes read this rather than bare
    /// presence, so a chat reopened after the session ended shows no clock.
    var isReviewUnderway: Bool {
        isReviewOnScreen && MemoryReviewCommitment.clockRuns(state)
    }

    /// The window gave itself over to the review. From here, leaving is
    /// ending, until the goal is met.
    func beginCommittedSession() {
        isCommitted = true
    }

    /// The learner left the review — the × by the clock, the pane moved on to
    /// another chat, the window closed, the app quit. While the goal is unmet
    /// this writes today's end and the day is over; once it is met it only
    /// releases the commitment. Idempotent.
    func endSession(now: Date = Date()) {
        isCommitted = false
        // A day whose cards ran out is done; leaving it ends nothing.
        guard cardsFinishedDay != today else { return }
        guard let end = MemoryReviewCommitment.end(snapshot: snapshot, now: now) else { return }
        guard sessionEnd?.applies(to: today) != true else { return }
        sessionEnd = end
        Self.saveSessionEnd(end)
        logger.info("Today's memory review ended after \(Int(end.activeSeconds)) s, short of the goal")
        Task { await persist(force: true) }
    }

    /// The review never began, or nothing it promised is left undone — a
    /// card review whose cards were all answered, or one that made no
    /// commitment — so the commitment is released without ending anything.
    func abandonCommitment() {
        isCommitted = false
    }

    private static let sessionEndDefaultsKey = "memoryReview.sessionEnd"

    private static func loadSessionEnd(for day: String) -> MemoryReviewSessionEnd? {
        guard let data = UserDefaults.standard.data(forKey: sessionEndDefaultsKey),
              let end = try? JSONDecoder().decode(MemoryReviewSessionEnd.self, from: data),
              end.applies(to: day) else { return nil }
        return end
    }

    private static func saveSessionEnd(_ end: MemoryReviewSessionEnd) {
        guard let data = try? JSONEncoder().encode(end) else { return }
        UserDefaults.standard.set(data, forKey: sessionEndDefaultsKey)
    }

    // MARK: - Configuration

    /// Idempotent. The first caller hands over the store; every caller gets a
    /// fresh read of today's rows and the streak.
    func configure(storage: StorageService) {
        if self.storage == nil {
            self.storage = storage
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            })
            observers.append(center.addObserver(
                forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.persist(force: true) }
            })
            // Quitting with the review still committed is leaving it: the
            // session is over for the day (product owner, 2026-09-19: "i can also
            // quit but then the memory session is over"). The end record is a
            // synchronous defaults write, so it lands before the process goes.
            observers.append(center.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCommitted else { return }
                    self.endSession()
                }
            })
            // Inbound sync is how the phone's minutes, and the other Mac's,
            // arrive; a migration's store change is read the same way.
            for name in [Notification.Name.cloudKitSyncRemoteStoreDidChange, .cloudKitSyncStoreDidChange] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.reload() }
                })
            }
        }
        reload()
    }

    /// Re-reads every device's rows. Coalesced: a burst of sync notifications
    /// costs one read.
    func reload() {
        guard let storage, reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            defer { self?.reloadTask = nil }
            let now = Date()
            do {
                let rows = try await storage.loadMemoryReviewActivities()
                let answered = try await storage.answeredMemoryReviewDays()
                self?.apply(rows: rows, answeredDays: answered, now: now)
            } catch {
                self?.logger.error("Failed to load memory review activity: \(error.localizedDescription)")
            }
        }
    }

    private func apply(rows: [MemoryReviewActivity], answeredDays: Set<String>, now: Date) {
        rolloverIfNeeded(now: now)
        self.answeredDays = answeredDays
        let deviceID = MemoryReviewActivityDevice.id
        let days = MemoryReviewProgress.days(from: rows)
        let stored = rows.first { $0.day == today && $0.deviceID == deviceID }?.activeSeconds ?? 0
        // Unsaved local time is never older than the stored row, so the larger
        // is the truth for this device.
        deviceSecondsToday = max(deviceSecondsToday, stored)
        otherDevicesSecondsToday = rows
            .filter { $0.day == today && $0.deviceID != deviceID }
            .reduce(0) { $0 + max(0, $1.activeSeconds) }
        completedOtherDays = Set(days.filter { $0.key != today && $0.value.isComplete }.map(\.key))
        dayProgress = days
        publishSnapshot(celebrateIfCrossed: false)
    }

    private func publishSnapshot(celebrateIfCrossed: Bool) {
        let wasComplete = snapshot.isTodayComplete
        let progress = MemoryReviewDayProgress(
            day: today,
            activeSeconds: deviceSecondsToday + otherDevicesSecondsToday,
            goalSeconds: MemoryReviewGoal.goalSeconds(budgetMinutes: MemoryReviewBudget.minutes)
        )
        var completed = completedOtherDays
        if progress.isComplete { completed.insert(today) }
        let next = MemoryReviewGoalSnapshot(
            today: progress,
            streak: MemoryReviewProgress.streak(completedDays: completed, today: today)
        )
        if next != snapshot { snapshot = next }
        if celebrateIfCrossed, !wasComplete, next.isTodayComplete,
           let sessionID = presenters.values.first?.sessionID {
            celebration = Celebration(
                id: UUID(),
                sessionID: sessionID,
                goalMinutes: Int(progress.goalSeconds / 60),
                streak: next.streak
            )
        }
    }

    /// The grid's days: the stored rows, with today taken from the live
    /// snapshot rather than from the last row written to the store.
    var historyDays: [String: MemoryReviewDayProgress] {
        var days = dayProgress
        days[today] = snapshot.today
        return days
    }

    func acknowledgeCelebration(_ id: UUID) {
        if celebration?.id == id { celebration = nil }
    }

    // MARK: - Presence

    /// A chat panel is showing this memory session. The heartbeat starts with
    /// the first presenter.
    ///
    /// `panel` identifies the view, not the session manager: moving the review
    /// between hosts — into the focused workspace and back out of it — builds a
    /// second panel around the same manager and tears the first one down, in
    /// that order. Keyed by the manager, the departing panel's dismissal would
    /// cancel the arriving panel's registration and stop the clock on a review
    /// that is still on screen.
    func present(_ manager: ReviewSessionManager, panel: UUID, sessionID: String, storage: StorageService) {
        present(owner: manager, panel: panel, sessionID: sessionID, storage: storage) { [weak manager] in
            manager?.isGenerating == true
        }
    }

    /// Something that is not a chat is showing the review: the card review,
    /// whose `sessionID` is its sitting's key (the celebration names it).
    /// `owner` is held weakly; `isBusy` says when time counts with no input
    /// from the learner, which for cards is never.
    func present(
        owner: AnyObject,
        panel: UUID,
        sessionID: String,
        storage: StorageService,
        isBusy: @escaping @MainActor () -> Bool = { false }
    ) {
        configure(storage: storage)
        let wasEmpty = presenters.isEmpty
        presenters[panel] = Presenter(owner: owner, sessionID: sessionID, isBusy: isBusy)
        if wasEmpty { startHeartbeat() }
        updateOnScreen()
    }

    /// The panel stopped showing a memory session, or went away. The last
    /// presenter's departure writes the total.
    func dismiss(panel: UUID) {
        guard presenters.removeValue(forKey: panel) != nil else { return }
        if presenters.isEmpty { stopHeartbeat() }
        updateOnScreen()
    }

    /// A panel that went away without saying so — its window closed — is not
    /// a review on screen, so presence is recomputed from live presenters.
    private func updateOnScreen() {
        let next = presenters.values.contains { $0.owner != nil }
        if next != isReviewOnScreen { isReviewOnScreen = next }
    }

    private func startHeartbeat() {
        clock.start(at: Date())
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { [weak self] event in
                if NSApp.isActive {
                    Task { @MainActor in self?.clock.noteActivity(at: Date()) }
                }
                return event
            }
        }
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MemoryReviewGoal.heartbeat))
                guard !Task.isCancelled else { return }
                await self?.tick(now: Date())
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        clock.stop()
        Task { await persist(force: true) }
    }

    // MARK: - The clock

    private func tick(now: Date) async {
        rolloverIfNeeded(now: now)
        presenters = presenters.filter { $0.value.owner != nil }
        if presenters.isEmpty {
            stopHeartbeat()
            updateOnScreen()
            return
        }
        updateOnScreen()
        // Behind another app, nothing counts and the interval restarts, so the
        // seconds spent away are never credited on return.
        guard NSApp.isActive else {
            clock.start(at: now)
            return
        }
        // A session ended early is over: a chat reopened to read it back
        // counts nothing, so there is no second session by the back door.
        guard MemoryReviewCommitment.clockRuns(state) else {
            clock.start(at: now)
            return
        }
        let tutorIsResponding = presenters.values.contains { $0.owner != nil && $0.isBusy() }
        let credited = clock.tick(at: now, tutorIsResponding: tutorIsResponding)
        guard credited > 0 else { return }
        deviceSecondsToday += credited
        secondsSincePersist += credited
        let wasComplete = snapshot.isTodayComplete
        publishSnapshot(celebrateIfCrossed: true)
        await persist(force: !wasComplete && snapshot.isTodayComplete)
    }

    /// The day changed under an open review: the old day's total is written
    /// before the counters start over.
    private func rolloverIfNeeded(now: Date) {
        let day = MemoryReviewGoal.dayKey(for: now)
        guard day != today else { return }
        let closingDay = today
        let closingSeconds = deviceSecondsToday
        if secondsSincePersist > 0, storage != nil {
            unsavedClosedDays[closingDay] = MemoryReviewActivity(
                day: closingDay,
                deviceID: MemoryReviewActivityDevice.id,
                activeSeconds: closingSeconds,
                goalSeconds: snapshot.today.goalSeconds,
                updatedAt: now
            )
            Task { await writeClosedDays() }
        }
        if snapshot.isTodayComplete { completedOtherDays.insert(closingDay) }
        today = day
        deviceSecondsToday = 0
        otherDevicesSecondsToday = 0
        secondsSincePersist = 0
        // Yesterday's end says nothing about today: a new day is a fresh
        // start, which is the whole point of ending being for the day.
        sessionEnd = nil
        cardsFinishedDay = nil
        publishSnapshot(celebrateIfCrossed: false)
        reload()
    }

    /// Writes this device's total when unsaved time has accrued. `force` is
    /// the leaving-the-screen and resigning-active case, which writes at once
    /// rather than waiting out the interval.
    private func persist(force: Bool) async {
        await writeClosedDays()
        guard let storage, secondsSincePersist > 0 else { return }
        if !force, secondsSincePersist < MemoryReviewGoal.persistInterval { return }
        let row = MemoryReviewActivity(
            day: today,
            deviceID: MemoryReviewActivityDevice.id,
            activeSeconds: deviceSecondsToday,
            goalSeconds: snapshot.today.goalSeconds,
            updatedAt: Date()
        )
        let unsaved = secondsSincePersist
        secondsSincePersist = 0
        do {
            try await storage.recordMemoryReviewActivity(row)
        } catch {
            logger.error("Failed to record memory review activity: \(error.localizedDescription)")
            // The row is the day's running total, so the next persist writes
            // these seconds too; until then they still count as unsaved. A
            // day that closed during the write is owed this row instead.
            if today == row.day {
                secondsSincePersist += unsaved
            } else if unsavedClosedDays[row.day] == nil {
                unsavedClosedDays[row.day] = row
            }
        }
    }

    /// Writes the closed days still owed to the store. Each row is the day's
    /// whole total, so writing one again is harmless.
    private func writeClosedDays() async {
        guard let storage, !unsavedClosedDays.isEmpty else { return }
        for (day, row) in unsavedClosedDays.sorted(by: { $0.key < $1.key }) {
            do {
                try await storage.recordMemoryReviewActivity(row)
                if unsavedClosedDays[day]?.activeSeconds == row.activeSeconds {
                    unsavedClosedDays[day] = nil
                }
            } catch {
                logger.error("Failed to record memory review activity for \(day): \(error.localizedDescription)")
            }
        }
    }
}
