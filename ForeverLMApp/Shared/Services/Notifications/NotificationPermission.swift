import AppKit
import Foundation
import UserNotifications

/// Whether macOS lets ForeverLM post notifications on this Mac.
///
/// Every notification service asks macOS on its own before it posts
/// (`LearningBoutAlarms`, `PlanTheDayNotifications`,
/// `CohortReviewNotifications`, the feeds' match
/// banner, the price watch, the update banner), and each one takes a refusal
/// as silence by design: the request is dropped and nothing is said. That
/// made a Mac where macOS refuses them look exactly like one where it allows
/// them. On the product owner's, from at least 2026-09-20 to 2026-09-27, neither
/// ForeverLM nor ForeverLM Dev posted a single notification while every
/// switch read as on. So the answer is now said where the switches that need
/// it are, in Settings › Background › Memory review (`NotificationSettingsNote`), and over MCP in
/// `get_day_settings` (`notifications_status`). Undoing a
/// refusal stays the learner's, in System Settings; the app only opens the
/// right page.
enum NotificationPermission: String, Equatable, Sendable {
    /// Authorized or provisional: a request reaches Notification Center.
    case allowed
    /// Denied. macOS drops every request and asking again shows nothing;
    /// only the learner can undo it, in System Settings › Notifications.
    case refused
    /// Never answered on this Mac: the next request shows macOS's prompt.
    case notAsked = "not_asked"

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional:
            self = .allowed
        case .notDetermined:
            self = .notAsked
        case .denied:
            self = .refused
        @unknown default:
            // The services post only when authorized or provisional, so a
            // status a later macOS adds reads the way they treat it.
            self = .refused
        }
    }

    /// macOS's answer now. A round trip to the notification daemon, so it is
    /// awaited from a task, never read in a view body.
    static func current() async -> NotificationPermission {
        NotificationPermission(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// Asks macOS, as Allow Notifications does, and returns its answer. Only
    /// a Mac never asked shows the prompt, and this waits while the prompt
    /// waits on the learner; a Mac that refused answers at once and shows
    /// nothing.
    @discardableResult
    static func request() async -> NotificationPermission {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return NotificationPermission(await center.notificationSettings().authorizationStatus)
    }

    /// System Settings › Notifications, as `x-apple.systempreferences:` names
    /// its extension.
    static let systemSettingsPane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    /// System Settings › Notifications on this app's own entry. `?id=` and
    /// the bundle id is the form Apple's own notification settings intents
    /// build on macOS 27 (`NotificationsSettingsIntents.appex`); without an
    /// id the pane opens on its list. `Bundle.main` is what makes a Dev
    /// build open ForeverLM Dev's entry, never the installed app's.
    static func systemSettingsURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let url = URL(string: systemSettingsPane + "?id=" + bundleIdentifier) else {
            return URL(string: systemSettingsPane)
        }
        return url
    }

    /// Open System Settings. The learner turns the switch there; the app
    /// never can.
    @MainActor
    static func openSystemSettings() {
        guard let url = systemSettingsURL() else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The one line Settings › Background › Memory review draws about macOS's answer, and the card
/// it sits in: an orange "macOS has ForeverLM's notifications turned off."
/// with Open System Settings, or Allow Notifications on a Mac never asked.
///
/// Drawn once, never under every switch that needs it. It goes under the
/// memory review's switch when today's review is readied with its
/// reminder, and nowhere while macOS allows them, has not
/// answered yet, or nothing switched on needs them: a refusal nothing is
/// missing asks for no action. "Plan your day?" is not counted, because its
/// card asks without a notification, and a bout's alarms have no switch to
/// sit under.
struct NotificationSettingsNote: Equatable, Sendable {
    enum Card: Equatable, Sendable {
        case memoryReview
    }

    /// `.refused` or `.notAsked`; never `.allowed`.
    let permission: NotificationPermission
    let card: Card

    static func placement(
        permission: NotificationPermission?,
        preparesDailyReview: Bool
    ) -> NotificationSettingsNote? {
        guard let permission, permission != .allowed else { return nil }
        if preparesDailyReview {
            return NotificationSettingsNote(permission: permission, card: .memoryReview)
        }
        return nil
    }
}
