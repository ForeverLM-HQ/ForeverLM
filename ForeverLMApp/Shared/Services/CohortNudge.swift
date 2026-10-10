import CryptoKit
import Foundation
import UserNotifications

/// Whether to offer today's review, and why not when the answer is no.
enum CohortNudgeDecision: Equatable, Sendable {
    case offer(signature: String, count: Int)
    /// The learner already declined *this* material today.
    case dismissed(signature: String)
    case nothingDue
}

/// Deciding whether to speak up, and remembering when told not to.
///
/// Everything here is event-driven: readiness is derived when the app comes
/// forward or the library changes, and the one out-of-app nudge is scheduled
/// with the OS rather than polled for.
enum CohortNudge {

    // MARK: - Identity

    /// Identity of one day's suggestion.
    ///
    /// Deliberately keyed to the *material*, not to the idea of reviewing.
    /// Dismissing today must never be interpretable as "stop suggesting
    /// reviews" — tomorrow's cohort contains different sources, so it is a
    /// different suggestion and gets asked afresh.
    static func signature(for cohort: LearningCohort) -> String {
        let ids = cohort.sources.map(\.sourceID).sorted().joined(separator: "|")
        let digest = SHA256.hash(data: Data(ids.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Decision

    static func decide(cohort: LearningCohort) -> CohortNudgeDecision {
        guard !cohort.isEmpty else { return .nothingDue }
        let signature = signature(for: cohort)
        if isDismissed(signature: signature) { return .dismissed(signature: signature) }
        return .offer(signature: signature, count: cohort.sources.count)
    }

    // MARK: - Dismissal

    /// Device-local on purpose. "I don't want this right now" is a statement
    /// about the machine the learner is sitting at, and syncing it would mean a
    /// dismissal on the Mac silently swallowing the phone's morning nudge.
    private static let dismissedKey = "cohortReview.dismissedSignatures.v1"

    private static func dismissedEntries() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: dismissedKey) as? [String: Double] ?? [:]
    }

    static func isDismissed(signature: String) -> Bool {
        dismissedEntries()[signature] != nil
    }

    static func dismiss(signature: String, now: Date = Date()) {
        var entries = pruned(dismissedEntries(), now: now)
        entries[signature] = now.timeIntervalSinceReferenceDate
        UserDefaults.standard.set(entries, forKey: dismissedKey)
    }

    /// The restore path. Every dismissal must be undoable, or the learner has to
    /// guess whether they have permanently switched something off.
    static func restore(signature: String) {
        var entries = dismissedEntries()
        entries.removeValue(forKey: signature)
        UserDefaults.standard.set(entries, forKey: dismissedKey)
    }

    static func restoreAll() {
        UserDefaults.standard.removeObject(forKey: dismissedKey)
    }

    /// A dismissal only silences the day it was made. Keeping them forever would
    /// mean an identical cohort weeks later stayed silent for a decision the
    /// learner has long forgotten making.
    static func pruned(_ entries: [String: Double], now: Date) -> [String: Double] {
        let cutoff = Calendar.current.startOfDay(for: now).timeIntervalSinceReferenceDate
        return entries.filter { $0.value >= cutoff }
    }
}

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
