import Foundation
import OSLog
import UserNotifications

/// "Plan your day?" as a notification — said at most once a morning, when the
/// learner sits down to a day with no plan while ForeverLM is not the app in
/// front (`PlanTheDay.isPutNow`). The card in the Studio window is the
/// question itself and waits there whatever happens to this banner, which is
/// gone in seconds, or never shown on a Mac that refuses ForeverLM's
/// notifications. The banner and Plan in Chat open the chat that plans the day
/// into the Mac's Calendar and answer the card; Don't Ask Again switches the
/// question off on this Mac, the same switch as Settings › General › Day.
///
/// Delivered immediately rather than scheduled: the day's clock
/// (`DayModel`) decides the moment, so nothing is ever pending to cancel.
@MainActor
final class PlanTheDayNotifications {
    static let shared = PlanTheDayNotifications()

    /// One request per day, so a repeat replaces itself.
    static let identifierPrefix = "com.foreverlm.planTheDay."
    static let categoryIdentifier = "com.foreverlm.planTheDay"
    static let planActionIdentifier = "com.foreverlm.planTheDay.plan"
    static let stopAskingActionIdentifier = "com.foreverlm.planTheDay.stopAsking"

    private let logger = Logger(subsystem: "ForeverLM", category: "PlanTheDay")
    private var hasRegisteredCategory = false
    private var hasAskedForPermission = false

    private init() {}

    /// Asks whether the learner wants to plan `date`. Never an error when
    /// notifications are refused: the card is still asking.
    func ask(date: String) async {
        guard PlanTheDay.isEnabled else { return }
        guard await ensurePermission() else {
            logger.info("Notifications are refused on this Mac; only the card asks to plan \(date)")
            return
        }
        registerCategoryIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = PlanTheDay.title
        content.body = PlanTheDay.detail
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + date,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Could not ask to plan \(date): \(error.localizedDescription)")
        }
    }

    private func registerCategoryIfNeeded() {
        guard !hasRegisteredCategory else { return }
        hasRegisteredCategory = true
        let plan = UNNotificationAction(
            identifier: Self.planActionIdentifier,
            title: "Plan in Chat",
            options: [.foreground]
        )
        let stop = UNNotificationAction(
            identifier: Self.stopAskingActionIdentifier,
            title: "Don't Ask Again",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [plan, stop],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var all = existing.filter { $0.identifier != Self.categoryIdentifier }
            all.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(all)
        }
    }

    /// Asks once, the first time the question is actually wanted, as the
    /// bout alarms do.
    private func ensurePermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            guard !hasAskedForPermission else { return false }
            hasAskedForPermission = true
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }
}
