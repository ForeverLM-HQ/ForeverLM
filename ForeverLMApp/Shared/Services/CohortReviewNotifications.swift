import Foundation
import UserNotifications

/// The one notification ForeverLM sends, and only when asked to.
///
/// Notifications were retired wholesale once. This re-opens exactly one channel:
/// a single daily reminder that a review is ready, off until the learner turns
/// it on. `NotificationRetirement` keeps cancelling everything else.
enum CohortReviewNotifications {
    static let requestIdentifier = "com.foreverlm.cohort-review.daily"

    /// Default off. The learner opts in; they do not discover one waiting. The
    /// switch is `DailyReviewPreparation`'s: the notification says the review
    /// is ready, and preparation is what makes that true, so one setting owns
    /// both (docs/memory-design.md, "Daily preparation").
    static var isEnabled: Bool {
        DailyReviewPreparation.isEnabled
    }

    /// The hour preparation runs, which is the hour the reminder is for.
    static var preferredHour: Int {
        DailyReviewPreparation.hour
    }

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Re-asserts the schedule from current state. Since the card review
    /// (2026-10-01) `hasReviewReady` is whether the morning the reminder next
    /// fires on holds a card (`MemoryReviewPreparationRunner.refreshReminder`);
    /// it was whether the day's cohort of sources was empty.
    ///
    /// Safe to call on every activation, and deliberately called there: the
    /// one-time `NotificationRetirement` sweep removes all pending requests, so
    /// re-asserting is what keeps this channel alive if the two ever race.
    static func refresh(hasReviewReady: Bool) async {
        let center = UNUserNotificationCenter.current()
        guard isEnabled, hasReviewReady else {
            center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
            return
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Today's review is ready"
        content.body = "Your cards for today are waiting. Open Memory to start."
        content.sound = .default

        var components = DateComponents()
        components.hour = preferredHour
        components.minute = 0

        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        try? await center.add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
    }
}
