import Foundation
import OSLog
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

/// The bout's clock on the phone: read it, draw it, alarm on it.
///
/// **What this can and cannot do, plainly.** The break is started on the Mac,
/// and iOS gives a phone no way to hear about that unless the app is woken by a
/// push. The App ID has the Push Notifications capability now; the app gains
/// `aps-environment` and the `remote-notification` background mode with the
/// schema-v2 sync that registers for them (docs/cloudkit-schema-design.md, D36),
/// and nothing here subscribes to the bout.
///
/// So this refreshes on every event the phone *does* get for free — becoming
/// active, the existing background-refresh task, and the learner opening the
/// app — and everything downstream of that first read is exact: the widget's
/// countdown ticks by itself, and the break's end is a local notification the
/// phone will fire with the screen off. The gap is only the first read: until
/// the phone has looked once, it does not know a break began. A
/// `CKQuerySubscription` and a silent push would close that gap, and nothing
/// else here has to change.
@MainActor
final class MobileLearningBoutTimer: ObservableObject {
    static let shared = MobileLearningBoutTimer()

    /// Stable, so a refresh replaces the alarm rather than stacking another.
    static let breakAlarmIdentifier = "com.foreverlm.mobile.bout.break"

    @Published private(set) var bout: LearningBout?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?

    private let store: MobileLearningBoutStore
    private var observers: [NSObjectProtocol] = []
    private var hasStarted = false
    private var refreshTask: Task<Void, Never>?
    /// The last read, so becoming active twice in a second is one fetch.
    private var lastRefresh: Date?
    private static let cooldown: TimeInterval = 20

    init(store: MobileLearningBoutStore = .shared) {
        self.store = store
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in MobileLearningBoutTimer.shared.refresh() }
        })
        refresh(force: true)
    }

    /// Reads the live bout and republishes everything that depends on it. Safe
    /// to call from anywhere and often; the cooldown keeps it to one fetch.
    func refresh(force: Bool = false) {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.cooldown { return }
        lastRefresh = Date()
        refreshTask?.cancel()
        refreshTask = Task { [store] in
            isRefreshing = true
            defer { isRefreshing = false }
            do {
                let live = try await store.fetchLive()
                guard !Task.isCancelled else { return }
                bout = live
                lastErrorMessage = nil
                publish(live)
            } catch is CancellationError {
                return
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// The background-refresh task's entry point, so a phone that iOS wakes for
    /// other reasons picks the break up without being opened. Awaits the read
    /// rather than firing and forgetting, because the task is told it is done.
    func refreshInBackground() async {
        refresh(force: true)
        await refreshTask?.value
    }

    // MARK: - Actions

    /// Back to work, from wherever the learner is standing. The only field the
    /// phone writes, and one the Mac's merge can neither lose nor reverse.
    func endBreak() async {
        guard let bout else { return }
        do {
            let updated = try await store.endBreak(bout)
            self.bout = updated.phase().isLive ? updated : nil
            publish(self.bout)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Publishing

    /// The widget's snapshot and the break's alarm, together, because they are
    /// two views of the same fact and must never disagree.
    private func publish(_ bout: LearningBout?) {
        let phase = bout?.phase()
        let clock: Date?
        switch phase {
        case .learning: clock = bout?.timerEndsAt
        case .resting: clock = bout?.breakEndsAt
        default: clock = nil
        }
        MobileTodayWidgetSnapshotStore.saveBout(
            title: (phase?.isLive ?? false) ? bout?.title : nil,
            endsAt: clock,
            isOnBreak: phase == .resting,
            needsAttention: phase == .writing || phase == .earned
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "ForeverLMTodayWidget")
        MobileWatchBridge.shared.scheduleRefresh()
        Task { await scheduleBreakAlarm(endsAt: phase == .resting ? clock : nil) }
    }

    /// One pending alarm at most, for a break that is still ahead. Everything
    /// else — a break ended, declined, or already over — cancels it, so the
    /// phone never buzzes about a rest that finished while it was in a pocket.
    private func scheduleBreakAlarm(endsAt: Date?) async {
        let center = UNUserNotificationCenter.current()
        guard let endsAt, endsAt > Date() else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.breakAlarmIdentifier])
            return
        }
        // Piggybacks on the permission the daily review already asks for; if it
        // was never granted the clock is simply silent, which is not an error.
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Break over"
        content.body = "Back to it."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.breakAlarmIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, endsAt.timeIntervalSinceNow),
                repeats: false
            )
        )
        do {
            try await center.add(request)
        } catch {
            Logger(subsystem: "com.foreverlm.mobile", category: "LearningBoutTimer")
                .error("Scheduling the break reminder failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - The card

/// The bout on the phone's Home: the break's countdown and the way to end it,
/// or the clock a Mac is running, or the write-up the learner owes.
///
/// Never a way to *start* a bout. Learning is started where the learning
/// happens, and a phone that could start one would quietly become the place
/// bouts are kept — which is the Mac's job, and the Planner's.
struct MobileLearningBoutCard: View {
    @ObservedObject var timer: MobileLearningBoutTimer

    var body: some View {
        if let bout = timer.bout, bout.phase().isLive {
            card(bout)
        }
    }

    @ViewBuilder
    private func card(_ bout: LearningBout) -> some View {
        let phase = bout.phase()
        VStack(alignment: .leading, spacing: 8) {
            Label(Self.heading(phase), systemImage: Self.icon(phase))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint(phase))
            if let endsAt = clock(bout, phase: phase), endsAt > Date() {
                Text(timerInterval: Date()...endsAt, countsDown: true)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(bout.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if phase == .resting {
                Button("Back to work") {
                    Task { await timer.endBreak() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if phase == .writing || phase == .earned {
                Text(phase == .writing
                     ? "Write it up on your Mac to earn the break."
                     : "Your break is waiting on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(tint(phase).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func clock(_ bout: LearningBout, phase: LearningBoutPhase) -> Date? {
        switch phase {
        case .learning: return bout.timerEndsAt
        case .resting: return bout.breakEndsAt
        default: return nil
        }
    }

    private func tint(_ phase: LearningBoutPhase) -> Color {
        switch phase {
        case .resting, .earned: return .green
        case .writing: return .orange
        default: return .accentColor
        }
    }

    static func heading(_ phase: LearningBoutPhase) -> String {
        switch phase {
        case .learning: return "Learning"
        case .writing: return "Write it up"
        case .earned: return "Break earned"
        case .resting: return "Break"
        case .complete, .abandoned: return "Done"
        }
    }

    static func icon(_ phase: LearningBoutPhase) -> String {
        switch phase {
        case .learning: return "timer"
        case .writing: return "square.and.pencil"
        case .earned, .resting: return "cup.and.saucer"
        case .complete, .abandoned: return "checkmark.circle"
        }
    }
}
