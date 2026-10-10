import Foundation
import UserNotifications

/// Clears notifications registered by builds that still offered reminders.
///
/// Two live notification channels remain, and neither is a reminder. The macOS
/// update banner in AppUpdateController is delivered immediately rather than
/// scheduled and only after a check finds a new version, so it is never pending
/// when this one-time sweep runs. `LearningBoutAlarms` does schedule — a bout's
/// clock and its break — but it is the learner's own timer reporting that it
/// finished, and it is armed from the same launch task strictly *after* this
/// sweep, which is what keeps a first-run sweep from cancelling a bout the
/// learner had already started. The sweep does not run again afterwards.
enum NotificationRetirement {
    private static let completionKey = "retiredReminderNotificationsCleared.v1"

    static func cancelAll() {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        UserDefaults.standard.set(true, forKey: completionKey)
    }
}
