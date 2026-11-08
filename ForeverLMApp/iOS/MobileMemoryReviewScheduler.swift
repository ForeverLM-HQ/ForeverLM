import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Prepares today's memory review chat on the phone, and sends the daily
/// reminder.
///
/// The phone's half of the daily preparation (docs/memory-design.md). The
/// switch is the account's; the hour is this phone's. iOS grants background
/// refresh opportunistically, so three things cooperate: a refresh task asked
/// for at the hour, the first foreground after the hour as the path that
/// always works, and the daily reminder as the backstop. Since the phone's
/// card review (2026-10-02) the reminder opens today's cards, which prepare
/// nothing, and since 2026-11-08 Review by Voice reviews the cards too. Whichever
/// device prepares first wins: the day's session id is the claim, and a
/// phone that finds the record already there simply opens it.
@MainActor
final class MobileMemoryReviewScheduler: ObservableObject {
    static let shared = MobileMemoryReviewScheduler()

    static let refreshTaskIdentifier = "com.foreverlm.mobile.memory-review.prepare"
    nonisolated static let notificationIdentifier = "com.foreverlm.mobile.memory-review.ready"
    private static let lastAttemptDayKey = "memoryReview.dailyPreparation.lastAttemptDay.v1"
    private static let lastAttemptMessageKey = "memoryReview.dailyPreparation.lastAttemptMessage.v1"

    /// What this phone last did about the day's review, for Settings.
    @Published private(set) var lastAttemptDay: String?
    @Published private(set) var lastAttemptMessage: String?
    @Published private(set) var isPreparing = false

    private var didRegister = false

    private init() {
        lastAttemptDay = UserDefaults.standard.string(forKey: Self.lastAttemptDayKey)
        lastAttemptMessage = UserDefaults.standard.string(forKey: Self.lastAttemptMessageKey)
    }

    // MARK: - Settings

    var hour: Int {
        get {
            DailyReviewPreparationTiming.clampHour(
                UserDefaults.standard.object(forKey: DailyReviewPreparationKeys.hour) as? Int
                    ?? DailyReviewPreparationKeys.defaultHour
            )
        }
        set { UserDefaults.standard.set(DailyReviewPreparationTiming.clampHour(newValue), forKey: DailyReviewPreparationKeys.hour) }
    }

    /// The synced switch, read through the account's preference rows.
    func isEnabled() async -> Bool {
        (try? await MobileModelPreferenceStore.shared.bool(forKey: DailyReviewPreparationKeys.enabled)) ?? false
    }

    // MARK: - Registration

    private let notificationDelegate = MobileMemoryReviewNotificationDelegate()

    /// Must run before the app finishes launching; the app's `init` calls it.
    func register() {
        guard !didRegister else { return }
        didRegister = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { @MainActor in
                let prepared = await MobileMemoryReviewScheduler.shared.prepareIfDue()
                // The phone is awake anyway, so take the chance to read the
                // bout's clock: without a push there is no other moment a
                // break started on the Mac can reach a phone in a pocket.
                await MobileLearningBoutTimer.shared.refreshInBackground()
                MobileMemoryReviewScheduler.shared.scheduleNextRefresh()
                refresh.setTaskCompleted(success: prepared != .failed)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    /// Asks iOS for a wake-up at the next hour. Called whenever the hour or the
    /// switch changes and after every run; iOS decides whether to honor it.
    func scheduleNextRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
        Task {
            guard await isEnabled() else { return }
            let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
            request.earliestBeginDate = DailyReviewPreparationTiming.nextPreparationInstant(after: Date(), hour: hour)
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    // MARK: - Running

    enum Outcome: Equatable {
        case prepared
        case nothingToDo
        case failed
    }

    /// Foreground and background alike: prepare when the day's hour has passed
    /// and no device has made today's chat.
    @discardableResult
    func prepareIfDue(now: Date = Date()) async -> Outcome {
        guard !isPreparing else { return .nothingToDo }
        guard await isEnabled() else { return .nothingToDo }
        guard ManagedAI.isSignedIn else { return .nothingToDo }
        let sessionID = MemoryReviewSession.sessionID(for: now)
        let exists = ((try? await MobileMemoryReviewStore.shared.fetch(sessionID: sessionID)) ?? nil) != nil
        let decision = DailyReviewPreparationTiming.decide(
            now: now,
            isEnabled: true,
            hour: hour,
            todaysSessionExists: exists,
            lastAttemptDay: lastAttemptDay
        )
        guard decision == .prepare else { return .nothingToDo }
        return await prepare(now: now)
    }

    /// Settings' "Prepare now".
    func prepareNow(now: Date = Date()) async -> Outcome {
        guard !isPreparing else { return .nothingToDo }
        return await prepare(now: now)
    }

    private func prepare(now: Date) async -> Outcome {
        isPreparing = true
        defer { isPreparing = false }
        let day = DailyReviewPreparationTiming.dayKey(for: now)
        do {
            let record = try await MobileMemoryReviewPreparer.shared.prepare(now: now)
            recordAttempt(day: day, message: nil)
            await Self.refreshReminder(enabled: true, hour: hour)
            _ = record
            return .prepared
        } catch {
            recordAttempt(day: day, message: error.localizedDescription)
            return .failed
        }
    }

    private func recordAttempt(day: String, message: String?) {
        lastAttemptDay = day
        lastAttemptMessage = message
        UserDefaults.standard.set(day, forKey: Self.lastAttemptDayKey)
        if let message {
            UserDefaults.standard.set(message, forKey: Self.lastAttemptMessageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastAttemptMessageKey)
        }
    }

    // MARK: - Reminder

    static func requestNotificationAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// One daily reminder at the hour, the same channel the Mac keeps. Tapping
    /// it opens today's card review over every notebook.
    static func refreshReminder(enabled: Bool, hour: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        guard enabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time for today's review"
        content.body = "Open Memory to go through today's cards."
        content.sound = .default
        var components = DateComponents()
        components.hour = DailyReviewPreparationTiming.clampHour(hour)
        components.minute = 0
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        try? await center.add(request)
    }
}

/// Tapping the reminder opens today's card review. The phone sends no other
/// notification.
final class MobileMemoryReviewNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == MobileMemoryReviewScheduler.notificationIdentifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        // Held for the shell rather than posted: a tap that launched the app
        // arrives before the shell is on screen to hear it.
        await MainActor.run {
            MobileAudioReviewViewModel.shared.pendingDeepLink = .review
        }
    }
}
