import Foundation
import OSLog
import UserNotifications

/// "Cards from what you finished" as a banner the morning after
/// (docs/memory-design.md, "The morning-after banner").
///
/// The banner is queued with the OS rather than delivered when this Mac
/// notices: the learner finishes a source tonight, and the hour that says it
/// is the next morning's, whether or not ForeverLM is running then. So the
/// queue is rebuilt from what is true whenever it could have changed — a
/// finish, drafts landing, cards kept or skipped, a settings change, an
/// activation — and a banner whose reason is gone (the pile cleared tonight,
/// the switch turned off) is taken down. `CardsToCheckBanner` decides; this
/// only talks to the notification centre.
@MainActor
final class CardsToCheckNotifications {
    static let shared = CardsToCheckNotifications()

    /// One queued banner at a time, so queuing again replaces it.
    static let identifier = "com.foreverlm.cardsToCheck.morning"
    static let categoryIdentifier = "com.foreverlm.cardsToCheck"
    static let stopAskingActionIdentifier = "com.foreverlm.cardsToCheck.stopAsking"
    /// The sources with no cards yet (finished or added), for the click that makes them.
    static let undraftedSourceIDsKey = "undraftedSourceIDs"

    private let logger = Logger(subsystem: "ForeverLM", category: "CardsToCheckBanner")
    private var hasRegisteredCategory = false
    private var hasAskedForPermission = false
    private var isRefreshing = false
    private var needsAnotherPass = false

    private init() {}

    /// Rebuilds the queue for the next morning from what `subject` reads now;
    /// no subject (or the nudges switched off) takes the banner down. A call
    /// that arrives while a pass runs asks for one more, reading the subject
    /// again, so the last word wins and passes never overlap.
    func refresh(subject: @MainActor () async -> CardsToCheckBanner.Subject?) async {
        guard !isRefreshing else {
            needsAnotherPass = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsAnotherPass = false
            let read = await subject()
            await apply(subject: read, now: Date())
        } while needsAnotherPass
    }

    private func apply(subject: CardsToCheckBanner.Subject?, now: Date) async {
        let center = UNUserNotificationCenter.current()
        let wanted = MemoryCardSettings.showsDraftNudges() ? subject : nil
        let fireAt = DailyReviewPreparation.nextPreparationInstant(after: now, hour: DailyReviewPreparation.hour)
        let outcome = CardsToCheckBanner.decide(
            subject: wanted,
            ledger: CardsToCheckBanner.loadLedger(),
            now: now,
            fireAt: fireAt
        )
        switch outcome.decision {
        case .cancel:
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            CardsToCheckBanner.save(outcome.ledger)
        case .schedule(let fireAt):
            guard let wanted, await ensurePermission() else {
                logger.info("Notifications are refused on this Mac; only the corner card says cards wait")
                return
            }
            await registerCategoryIfNeeded()
            let content = UNMutableNotificationContent()
            content.title = CardsToCheckBanner.heading(wanted)
            content.body = CardsToCheckBanner.body(wanted)
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [Self.undraftedSourceIDsKey: wanted.makeCardsSourceIDs]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            let request = UNNotificationRequest(
                identifier: Self.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            )
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            do {
                try await center.add(request)
                CardsToCheckBanner.save(outcome.ledger)
            } catch {
                logger.error("Could not queue the cards banner: \(error.localizedDescription)")
            }
        }
    }

    private func registerCategoryIfNeeded() async {
        guard !hasRegisteredCategory else { return }
        hasRegisteredCategory = true
        let stop = UNNotificationAction(
            identifier: Self.stopAskingActionIdentifier,
            title: "Don't Ask Again",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [stop],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        var all = await center.notificationCategories().filter { $0.identifier != Self.categoryIdentifier }
        all.insert(category)
        center.setNotificationCategories(all)
    }

    /// Asks macOS once, the first time a banner is actually wanted, as the
    /// plan-the-day question does.
    private func ensurePermission() async -> Bool {
        switch await NotificationPermission.current() {
        case .allowed:
            return true
        case .refused:
            return false
        case .notAsked:
            guard !hasAskedForPermission else { return false }
            hasAskedForPermission = true
            return await NotificationPermission.request() == .allowed
        }
    }
}
