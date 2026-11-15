import Foundation
import OSLog
import UserNotifications
import WatchConnectivity
import WatchKit
import WidgetKit

/// The watch's whole state: the last day the phone sent, the cards answered
/// here since, and the link to the phone (`MobileWatchBridge` on its side).
///
/// A grade is kept on the watch at once and sent with `transferUserInfo`,
/// which the system holds until the phone takes it, so cards can be answered
/// with the phone out of reach. Listen and End Break need the phone in reach.
@MainActor
final class WatchStore: NSObject, ObservableObject {
    static let shared = WatchStore()

    @Published private(set) var day: WatchDay
    /// Cards answered on the watch today, by item id.
    @Published private(set) var answered: Set<String>
    /// Why the last command did not reach the phone; nil once one does.
    @Published private(set) var commandError: String?
    @Published private(set) var isSending = false

    private static let logger = Logger(subsystem: "com.foreverlm.watch", category: "WatchStore")
    private static let dayKey = "watch.day"
    private static let answeredKey = "watch.answered"
    private static let answeredDayKey = "watch.answered.day"
    private static let boutAlertID = "com.foreverlm.watch.bout.end"

    private let defaults = UserDefaults(suiteName: WatchGlanceStore.suiteName) ?? .standard

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    override private init() {
        let defaults = UserDefaults(suiteName: WatchGlanceStore.suiteName) ?? .standard
        let day = defaults.data(forKey: Self.dayKey)
            .flatMap { try? PropertyListDecoder().decode(WatchDay.self, from: $0) } ?? .empty
        self.day = day
        let answeredDay = defaults.string(forKey: Self.answeredDayKey)
        self.answered = answeredDay == day.dayKey ? Set(defaults.stringArray(forKey: Self.answeredKey) ?? []) : []
        super.init()
    }

    func start() {
        #if DEBUG
        if WatchSample.isOn {
            day = WatchSample.day()
            answered = []
            return
        }
        #endif
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: What the screens read

    /// Today's cards still to answer, in order.
    var cardsLeft: [WatchCard] {
        day.cards.filter { !answered.contains($0.itemID) }
    }

    var hasHeardFromPhone: Bool { day.updatedAt > .distantPast }

    var glance: WatchGlance {
        let left = cardsLeft
        let newLeft = left.filter(\.isNew).count
        return WatchGlance(
            dueLeft: left.count - newLeft,
            newLeft: newLeft,
            bout: day.bout,
            nowPlayingTitle: day.nowPlaying?.title,
            updatedAt: day.updatedAt
        )
    }

    // MARK: Cards

    /// Forgot or Remembered on a card whose back is shown.
    func grade(_ card: WatchCard, remembered: Bool) {
        guard !answered.contains(card.itemID) else { return }
        #if DEBUG
        if WatchSample.isOn {
            answered.insert(card.itemID)
            return
        }
        #endif
        let grade = WatchGrade(
            itemID: card.itemID,
            prompt: card.prompt,
            remembered: remembered,
            sittingKey: day.sittingKey,
            answeredAt: Date()
        )
        if let session, let data = WatchBridge.encode(grade) {
            session.transferUserInfo([WatchBridge.gradeKey: data])
        }
        answered.insert(card.itemID)
        saveAnswered()
        publishGlance()
        WKInterfaceDevice.current().play(remembered ? .success : .click)
    }

    // MARK: Commands

    func refresh() {
        send(.refresh)
    }

    func send(_ command: WatchCommand) {
        guard let session, session.activationState == .activated else { return }
        guard session.isReachable else {
            if command != .refresh {
                commandError = "Your iPhone is out of reach."
            }
            return
        }
        guard let data = WatchBridge.encode(command) else { return }
        isSending = true
        session.sendMessage([WatchBridge.commandKey: data]) { reply in
            let day = WatchBridge.decode(WatchDay.self, from: reply[WatchBridge.dayKey])
            Task { @MainActor in
                self.isSending = false
                self.commandError = nil
                if let day { self.apply(day) }
            }
        } errorHandler: { error in
            Task { @MainActor in
                self.isSending = false
                if command != .refresh {
                    self.commandError = "Your iPhone did not answer. \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Taking a day

    private func apply(_ newDay: WatchDay) {
        guard newDay.updatedAt >= day.updatedAt else { return }
        if newDay.dayKey != day.dayKey {
            answered = []
        }
        // A card the phone no longer deals was answered, here or elsewhere.
        answered.formIntersection(newDay.cards.map(\.itemID))
        day = newDay
        if let data = try? PropertyListEncoder().encode(newDay) {
            defaults.set(data, forKey: Self.dayKey)
        }
        saveAnswered()
        publishGlance()
        Task { await scheduleBoutAlert(newDay.bout) }
    }

    private func saveAnswered() {
        defaults.set(Array(answered), forKey: Self.answeredKey)
        defaults.set(day.dayKey, forKey: Self.answeredDayKey)
    }

    private func publishGlance() {
        WatchGlanceStore.save(glance)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A tap on the wrist when the learning part of a bout runs out. The
    /// break's end is the phone's own alarm, which reaches the watch when the
    /// phone is locked, so the watch does not add a second one.
    private func scheduleBoutAlert(_ bout: WatchBout?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.boutAlertID])
        guard let bout, !bout.isOnBreak, let endsAt = bout.endsAt, endsAt > Date() else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time for a break"
        content.body = bout.title
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: endsAt.timeIntervalSinceNow, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: Self.boutAlertID, content: content, trigger: trigger))
        } catch {
            Self.logger.error("The bout alert was not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let day = WatchBridge.decode(WatchDay.self, from: context[WatchBridge.dayKey])
        Task { @MainActor in
            if let day { self.apply(day) }
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let day = WatchBridge.decode(WatchDay.self, from: applicationContext[WatchBridge.dayKey]) else { return }
        Task { @MainActor in self.apply(day) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.refresh() }
    }
}
