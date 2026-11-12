import BackgroundTasks
import Foundation
import OSLog
import UserNotifications

/// Prepares today's memory review chat on the phone, and sends the daily
/// reminder.
///
/// The phone's half of the daily preparation (docs/memory-design.md). The
/// switch is the account's; the hour is this phone's. iOS grants background
/// refresh opportunistically, so three things cooperate: a refresh task asked
/// for at the hour, the first foreground after the hour as the path that
/// always works, and the daily reminder as the backstop. The reminder opens
/// today's cards, which prepare nothing, and Review by Voice reviews the cards
/// too. Whichever
/// device prepares first wins: the day's session id is the claim, and a
/// phone that finds the record already there simply opens it.
@MainActor
final class MobileMemoryReviewScheduler: ObservableObject {
    static let shared = MobileMemoryReviewScheduler()

    static let refreshTaskIdentifier = "com.foreverlm.mobile.memory-review.prepare"
    nonisolated static let notificationIdentifier = "com.foreverlm.mobile.memory-review.ready"
    /// The reminder's category, which carries Memory Check by Voice.
    nonisolated static let notificationCategory = "com.foreverlm.mobile.memory-review"
    /// The reminder's Memory Check by Voice action: today's cards and review
    /// out loud, so the check starts from the Lock Screen with nothing else
    /// to tap.
    nonisolated static let reviewByVoiceAction = "com.foreverlm.mobile.memory-review.voice"

    /// What this phone last did about the day's review, for Settings.
    @Published private(set) var lastAttemptDay: String?
    @Published private(set) var lastAttemptMessage: String?
    @Published private(set) var isPreparing = false

    private var didRegister = false

    private init() {
        lastAttemptDay = Preferences.value(Prefs.Memory.dailyPreparationLastAttemptDay)
        lastAttemptMessage = Preferences.value(Prefs.Memory.dailyPreparationLastAttemptMessage)
    }

    // MARK: - Settings

    var hour: Int {
        get {
            DailyReviewPreparationTiming.clampHour(
                Preferences.value(Prefs.Memory.dailyPreparationHour)
                    ?? DailyReviewPreparationKeys.defaultHour
            )
        }
        set { Preferences.set(DailyReviewPreparationTiming.clampHour(newValue), for: Prefs.Memory.dailyPreparationHour) }
    }

    /// The synced switch, read through the account's preference rows.
    func isEnabled() async -> Bool {
        (try? await MobileModelPreferenceStore.shared.valueOrDefault(for: Prefs.Memory.dailyPreparationEnabled)) ?? false
    }

    // MARK: - Registration

    private let notificationDelegate = MobileMemoryReviewNotificationDelegate()

    /// Must run before the app finishes launching; the app's `init` calls it.
    func register() {
        guard !didRegister else { return }
        didRegister = true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.notificationCategory,
                actions: [
                    UNNotificationAction(
                        identifier: Self.reviewByVoiceAction,
                        title: "Memory Check by Voice",
                        options: [.foreground],
                        icon: UNNotificationActionIcon(systemImageName: "waveform")
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
        Task { await Self.carryVoiceActionOnPendingReminder() }
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
        var exists = false
        do {
            exists = try await MobileMemoryReviewStore.shared.fetch(sessionID: sessionID) != nil
        } catch {
            Logger(subsystem: "com.foreverlm.mobile", category: "MemoryReviewScheduler")
                .error("Looking for today's prepared review failed: \(error.localizedDescription, privacy: .public)")
        }
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
            await Self.refreshReminder(hour: hour)
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
        Preferences.set(day, for: Prefs.Memory.dailyPreparationLastAttemptDay)
        Preferences.set(message, for: Prefs.Memory.dailyPreparationLastAttemptMessage)
    }

    // MARK: - Reminder

    static func requestNotificationAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// A reminder scheduled before the reminder had its voice action repeats
    /// without it until the next refresh, which may come after the morning's
    /// reminder: give it the category now, keeping its trigger.
    private static func carryVoiceActionOnPendingReminder() async {
        let center = UNUserNotificationCenter.current()
        guard let pending = await center.pendingNotificationRequests()
            .first(where: { $0.identifier == notificationIdentifier }),
              pending.content.categoryIdentifier != notificationCategory,
              let content = pending.content.mutableCopy() as? UNMutableNotificationContent else { return }
        content.categoryIdentifier = notificationCategory
        do {
            try await center.add(UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: pending.trigger))
        } catch {
            Logger(subsystem: "com.foreverlm.mobile", category: "MemoryReviewScheduler")
                .error("Adding the voice action to the pending reminder failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The daily quiz reminder, on for every signed-in phone (product owner,
    /// 2026-11-09: "make sure there are push notifications every day for me to
    /// do my daily quiz"), not only while "Have today's review ready" is on:
    /// asks iOS once, then keeps the reminder at the hour. Turning it off is
    /// iOS's own Settings › Notifications.
    static func ensureDailyReminder(hour: Int) async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = await requestNotificationAuthorization()
        }
        await refreshReminder(hour: hour)
    }

    /// One daily reminder at the hour, the same channel the Mac keeps. Tapping
    /// it opens today's card review over every notebook; its action starts
    /// Memory Check by Voice.
    static func refreshReminder(hour: Int) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time for today's quiz"
        content.body = "Tap to go through today's cards, or do them by voice."
        content.sound = .default
        content.categoryIdentifier = notificationCategory
        var components = DateComponents()
        components.hour = DailyReviewPreparationTiming.clampHour(hour)
        components.minute = 0
        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        do {
            try await center.add(request)
        } catch {
            Logger(subsystem: "com.foreverlm.mobile", category: "MemoryReviewScheduler")
                .error("Scheduling the daily review reminder failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Tapping the reminder opens today's card review; its Memory Check by
/// Voice action runs the cards and today's review out loud instead. The phone sends no other
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
        guard response.notification.request.identifier == MobileMemoryReviewScheduler.notificationIdentifier else { return }
        switch response.actionIdentifier {
        case MobileMemoryReviewScheduler.reviewByVoiceAction:
            // Queued like Siri's command: the shell runs it once it is up,
            // whether the action launched the app or found it running.
            await MainActor.run {
                MobileSiriCommandCenter.shared.enqueue(.voiceMemoryCheck())
            }
        case UNNotificationDefaultActionIdentifier:
            // Held for the shell rather than posted: a tap that launched the app
            // arrives before the shell is on screen to hear it.
            await MainActor.run {
                MobileAudioReviewViewModel.shared.pendingDeepLink = .review
            }
        default:
            return
        }
    }
}
