import Combine
import Foundation
import UIKit

/// The phone's clock on today's memory review, and the goal state and days
/// the Memory screen and the review screen read. The same rules as the Mac's
/// `MemoryReviewEngagementTracker`: time counts while the review is on
/// screen, the app is active, and the learner did something within the grace
/// period or the tutor is mid-reply. The total is written to the review clock of
/// this phone's own ActivityLog every half minute and when the review leaves the
/// screen (§3.5.24).
@MainActor
final class MobileMemoryGoalModel: ObservableObject {
    static let shared = MobileMemoryGoalModel()

    struct Celebration: Equatable, Identifiable {
        let id: UUID
        let goalMinutes: Int
        let streak: Int
    }

    @Published private(set) var snapshot: MemoryReviewGoalSnapshot
    @Published private(set) var celebration: Celebration?
    /// Whether a load from iCloud has ever finished, so the Memory screen's
    /// history grid does not draw days whose minutes have not been read.
    @Published private(set) var hasLoaded = false
    /// Every day's minutes against the goal it was worked under, summed over
    /// devices, as of the last load: what the Memory screen's history grid
    /// reads, through `historyDays`.
    @Published private(set) var dayProgress: [String: MemoryReviewDayProgress] = [:]

    private var clock = MemoryReviewEngagementClock()
    private var heartbeat: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var isPresented = false
    private var isSceneActive = true
    private var tutorIsResponding = false
    private var deviceSecondsToday: TimeInterval = 0
    private var otherDevicesSecondsToday: TimeInterval = 0
    private var completedOtherDays: Set<String> = []
    private var secondsSincePersist: TimeInterval = 0
    private var goalSeconds: TimeInterval = MemoryReviewGoal.goalSeconds(budgetMinutes: MemoryReviewBudget.defaultMinutes)
    private var today: String

    init() {
        today = MemoryReviewGoal.dayKey(for: Date())
        snapshot = .empty(day: today, goalSeconds: goalSeconds)
    }

    // MARK: - Loading

    /// Re-reads the goal and every device's rows. Coalesced.
    func reload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            defer { self?.reloadTask = nil }
            guard let self else { return }
            let now = Date()
            do {
                // The goal is a Setting and the minutes are the ActivityLog fold of every device, read
                // from the replica (§3.5.24, WP19b).
                guard let session = await MobileSyncSession.startIfEnabled() else { return }
                let budget: SyncJSON? = try? await session.projection.setting(MemoryReviewBudget.preferenceKey)
                // The Setting holds typed JSON (`{t: int, v: …}`), not a bare number.
                let minutes = (MobileSettingValue.plist(budget) as? NSNumber)?.intValue ?? MemoryReviewBudget.defaultMinutes
                let rows = try await MobileReadModels.reviewActivity(
                    session.projection, goalSecondsNow: MemoryReviewGoal.goalSeconds(budgetMinutes: minutes), now: now
                )
                apply(rows: rows, goalMinutes: minutes, deviceID: session.coordinator.deviceID, now: now)
                hasLoaded = true
            } catch {
                // Stay on what was known; a failed read must not flash the
                // grid off and on.
            }
        }
    }

    private func apply(rows: [MemoryReviewActivity], goalMinutes: Int, deviceID: String, now: Date) {
        rolloverIfNeeded(now: now)
        goalSeconds = MemoryReviewGoal.goalSeconds(budgetMinutes: goalMinutes)
        let days = MemoryReviewProgress.days(from: rows)
        let stored = rows.first { $0.day == today && $0.deviceID == deviceID }?.activeSeconds ?? 0
        deviceSecondsToday = max(deviceSecondsToday, stored)
        otherDevicesSecondsToday = rows
            .filter { $0.day == today && $0.deviceID != deviceID }
            .reduce(0) { $0 + max(0, $1.activeSeconds) }
        completedOtherDays = Set(days.filter { $0.key != today && $0.value.isComplete }.map(\.key))
        if days != dayProgress { dayProgress = days }
        publishSnapshot(celebrateIfCrossed: false)
    }

    /// The history grid's days: the loaded rows, with today taken from the
    /// live snapshot rather than from the last row written, so a square being
    /// filled in as the review runs does not wait for a persist (the Mac's
    /// `MemoryReviewEngagementTracker.historyDays`).
    var historyDays: [String: MemoryReviewDayProgress] {
        var days = dayProgress
        days[snapshot.today.day] = snapshot.today
        return days
    }

    private func publishSnapshot(celebrateIfCrossed: Bool) {
        let wasComplete = snapshot.isTodayComplete
        let progress = MemoryReviewDayProgress(
            day: today,
            activeSeconds: deviceSecondsToday + otherDevicesSecondsToday,
            goalSeconds: goalSeconds
        )
        var completed = completedOtherDays
        if progress.isComplete { completed.insert(today) }
        let next = MemoryReviewGoalSnapshot(
            today: progress,
            streak: MemoryReviewProgress.streak(completedDays: completed, today: today)
        )
        if next != snapshot { snapshot = next }
        if celebrateIfCrossed, !wasComplete, next.isTodayComplete, isPresented {
            celebration = Celebration(id: UUID(), goalMinutes: Int(goalSeconds / 60), streak: next.streak)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func acknowledgeCelebration(_ id: UUID) {
        if celebration?.id == id { celebration = nil }
    }

    // MARK: - Presence and activity

    /// The review screen came on. The heartbeat runs until `dismiss`.
    func present() {
        guard !isPresented else { return }
        isPresented = true
        reload()
        clock.start(at: Date())
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MemoryReviewGoal.heartbeat))
                guard !Task.isCancelled else { return }
                await self?.tick(now: Date())
            }
        }
    }

    /// The review screen went away. Writes the total.
    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        heartbeat?.cancel()
        heartbeat = nil
        clock.stop()
        Task { await persist(force: true) }
    }

    /// A key, a send, a chip, a scroll.
    func noteActivity() {
        guard isSceneActive else { return }
        clock.noteActivity(at: Date())
    }

    func setTutorResponding(_ responding: Bool) {
        tutorIsResponding = responding
    }

    /// Backgrounded, nothing counts; the interval restarts on return, and the
    /// total so far is written in case the app is killed while away.
    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            clock.start(at: Date())
            reload()
        } else {
            Task { await persist(force: true) }
        }
    }

    private func tick(now: Date) async {
        rolloverIfNeeded(now: now)
        guard isPresented else { return }
        guard isSceneActive else {
            clock.start(at: now)
            return
        }
        let credited = clock.tick(at: now, tutorIsResponding: tutorIsResponding)
        guard credited > 0 else { return }
        deviceSecondsToday += credited
        secondsSincePersist += credited
        let wasComplete = snapshot.isTodayComplete
        publishSnapshot(celebrateIfCrossed: true)
        await persist(force: !wasComplete && snapshot.isTodayComplete)
    }

    private func rolloverIfNeeded(now: Date) {
        let day = MemoryReviewGoal.dayKey(for: now)
        guard day != today else { return }
        if secondsSincePersist > 0 {
            let (day, seconds, goal) = (today, deviceSecondsToday, goalSeconds)
            Task { await Self.save(day: day, seconds: seconds, goalSeconds: goal, at: now) }
        }
        if snapshot.isTodayComplete { completedOtherDays.insert(today) }
        today = day
        deviceSecondsToday = 0
        otherDevicesSecondsToday = 0
        secondsSincePersist = 0
        publishSnapshot(celebrateIfCrossed: false)
        reload()
    }

    private func persist(force: Bool) async {
        guard secondsSincePersist > 0 else { return }
        if !force, secondsSincePersist < MemoryReviewGoal.persistInterval { return }
        secondsSincePersist = 0
        await Self.save(day: today, seconds: deviceSecondsToday, goalSeconds: goalSeconds, at: Date())
    }

    /// This device's minutes of a day: the review clock of its own ActivityLog (§3.5.24), which the replica
    /// sends with the log's 5-minute debounce.
    private static func save(day: String, seconds: TimeInterval, goalSeconds: TimeInterval, at date: Date) async {
        try? await save(day: day, seconds: seconds, goalSeconds: goalSeconds, at: date, writer: { await MobileRecordWriter.current() })
    }

    nonisolated static func save(day: String, seconds: TimeInterval, goalSeconds: TimeInterval, at date: Date,
                                 writer: () async -> MobileRecordWriter?) async throws {
        guard let writer = await writer() else { return }
        try await writer.transaction { try $0.recordReviewSeconds(day: day, seconds: seconds, goalSeconds: goalSeconds, at: date) }
    }
}
