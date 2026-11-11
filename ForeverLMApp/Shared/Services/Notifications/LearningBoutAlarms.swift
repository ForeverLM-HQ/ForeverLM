import Foundation
import OSLog
import UserNotifications

/// The bout's two alarms: the clock running out, and the break running out.
///
/// This is the one live *scheduled* notification channel on the Mac, and it is
/// deliberately not a reminder. A reminder is the app deciding the learner
/// should do something; these two are the learner's own timer telling them it
/// finished, which is the entire point of putting a clock on the bout at all —
/// a countdown you have to keep looking at is not a timer. Nothing is ever
/// scheduled for a bout the learner did not start.
///
/// The alarms never change anything: the bout stays `learning` past its end and
/// `resting` past the break's, exactly as a block is never marked done by the
/// clock. They say the time is up and leave the deciding where it belongs.
@MainActor
final class LearningBoutAlarms {
    static let shared = LearningBoutAlarms()

    /// Stable, so rescheduling replaces rather than stacks.
    static let boutIdentifier = "com.foreverlm.bout.timer"
    static let breakIdentifier = "com.foreverlm.bout.break"

    private let storage = StorageService()
    private let logger = Logger(subsystem: "ForeverLM", category: "BoutAlarms")
    private var observers: [NSObjectProtocol] = []
    private var hasStarted = false
    /// Asked for once a bout actually needs an alarm, never at launch: the app
    /// should not open with a permission prompt for a feature nobody started.
    private var hasAskedForPermission = false

    private init() {}

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .learningBoutDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in await LearningBoutAlarms.shared.reschedule() }
        })
        // A bout started, written up or rested on the other Mac.
        observers.append(center.addObserver(forName: .cloudKitSyncRemoteStoreDidChange, object: nil, queue: .main) { notification in
            let rawValues = notification.userInfo?[CloudKitSyncNotificationInfo.affectedEntitiesKey] as? [String] ?? []
            let entities = Set(rawValues.compactMap(CloudKitSyncEntity.init(rawValue:)))
            let requiresFullRefresh = notification.userInfo?[CloudKitSyncNotificationInfo.requiresFullRefreshKey] as? Bool ?? false
            guard requiresFullRefresh || entities.contains(.dayPlan) else { return }
            Task { @MainActor in await LearningBoutAlarms.shared.reschedule() }
        })
        Task { await reschedule() }
    }

    /// Reads the live bout and leaves exactly the alarms it calls for pending.
    ///
    /// Always both sides: a bout written up early has to *cancel* the clock's
    /// alarm, or the Mac buzzes about a bout that finished twenty minutes ago.
    func reschedule() async {
        let bout: LearningBout?
        do {
            bout = try await storage.loadLiveLearningBout()
        } catch {
            logger.error("Could not read the live bout for its alarms: \(error.localizedDescription)")
            return
        }
        let center = UNUserNotificationCenter.current()
        guard let bout else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.boutIdentifier, Self.breakIdentifier])
            return
        }
        let now = Date()
        var wanted: [(id: String, fireAt: Date, title: String, body: String)] = []
        switch bout.phase(now: now) {
        case .learning where bout.timerEndsAt > now:
            wanted.append((
                Self.boutIdentifier,
                bout.timerEndsAt,
                "Bout finished",
                "“\(bout.title)” is up. Write down what you learned — and what you still don’t understand."
            ))
        case .resting:
            if let endsAt = bout.breakEndsAt, endsAt > now {
                wanted.append((
                    Self.breakIdentifier,
                    endsAt,
                    "Break over",
                    "Back to it."
                ))
            }
        default:
            break
        }
        let unwanted = [Self.boutIdentifier, Self.breakIdentifier].filter { id in
            !wanted.contains { $0.id == id }
        }
        center.removePendingNotificationRequests(withIdentifiers: unwanted)
        guard !wanted.isEmpty else { return }
        guard await ensurePermission() else {
            logger.notice("Notifications are not allowed on this Mac; the bout's alarm is silent")
            return
        }
        for alarm in wanted {
            let content = UNMutableNotificationContent()
            content.title = alarm.title
            content.body = alarm.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: alarm.id,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, alarm.fireAt.timeIntervalSince(now)),
                    repeats: false
                )
            )
            do {
                try await center.add(request)
            } catch {
                logger.error("Could not set the \(alarm.id) alarm: \(error.localizedDescription)")
            }
        }
    }

    /// Asks once, the first time an alarm is actually wanted. A refusal is not
    /// an error: the timer still runs, it is only silent, so nothing
    /// interrupts the bout and nothing asks again this launch. The refusal is
    /// logged; the timer's alarms have no switch of their own to be said under.
    private func ensurePermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            guard !hasAskedForPermission else { return false }
            hasAskedForPermission = true
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.error("Asking for notification permission failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        default:
            return false
        }
    }
}
