import AppKit
import ApplicationServices
import EventKit
import Observation
import OSLog
import UserNotifications

/// Nudge Me Back on Track, running (`FocusWatch` holds the rules and the
/// product owner's words): while a goal stands, it looks at what is in front
/// whenever that changes, asks `FocusJudge` whether it serves the goal, and
/// feeds the verdict to a `FocusDriftTracker`, which says when to nudge and
/// what to put on the day's log.
///
/// Event-driven: the frontmost app changing (`NSWorkspace`), its focused
/// window or that window's title changing (an Accessibility observer on the
/// app in front, so a new browser tab is seen at once), the day's bout or
/// calendar changing, the switch, waking. A `FocusWatch.backstopSeconds`
/// timer runs only while a goal stands, as the backstop for a page that
/// changes without a new title and for the nudge coming due.
///
/// Nothing is judged and nothing runs while the switch is off, no goal
/// stands, the learner is idle, or Accessibility or Apple Intelligence is
/// missing; `status` says which, for Settings and `get_day_settings`.
@MainActor
@Observable
final class FocusWatcher {
    static let shared = FocusWatcher()

    enum Status: Equatable, Sendable {
        /// The switch is off.
        case off
        /// On, with no bout running and no block of the learner's own on the
        /// calendar now.
        case waiting
        /// Watching what is in front against the goal.
        case watching(goal: String)
        /// On, but macOS has not granted Accessibility, without which the
        /// window titles and pages cannot be read.
        case needsAccessibility
        /// On, but the on-device judge cannot run here.
        case judgeUnavailable(String)

        /// One line for the Settings row and MCP.
        var summary: String {
            switch self {
            case .off: return "Off."
            case .waiting: return "On; it watches while a bout runs or a block of your own is on the calendar."
            case .watching(let goal): return "Watching what is in front against “\(goal)”."
            case .needsAccessibility: return "Needs Accessibility, in System Settings › Privacy & Security, to read window titles and pages."
            case .judgeUnavailable(let reason): return reason
            }
        }

        var mcpValue: String {
            switch self {
            case .off: return "off"
            case .waiting: return "waiting_for_a_goal"
            case .watching: return "watching"
            case .needsAccessibility: return "needs_accessibility"
            case .judgeUnavailable: return "apple_intelligence_unavailable"
            }
        }
    }

    private(set) var status: Status = .off
    /// The last thing the judge could not answer, said once in the log; a
    /// failed look changes nothing on the clock.
    @ObservationIgnored private(set) var lastJudgeError: String?

    @ObservationIgnored private var tracker = FocusDriftTracker()
    @ObservationIgnored private var goal: FocusGoal?
    /// What the learner said is not a distraction, for the goal standing.
    @ObservationIgnored private var allowances = FocusAllowances()
    /// The off-track spans logged under the goal standing, by site or app, so
    /// Not a Distraction can take them back off the day.
    @ObservationIgnored private var loggedSpanIDs: [String: Set<String>] = [:]
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var backstop: Timer?
    @ObservationIgnored private var isLooking = false
    @ObservationIgnored private var looksAgain = false
    @ObservationIgnored private var windowObserver: AXObserver?
    @ObservationIgnored private var windowObserverPID: pid_t?
    @ObservationIgnored private var titleChangeDebounce: Task<Void, Never>?

    @ObservationIgnored private let storage = StorageService()
    @ObservationIgnored private let judge = FocusJudge.shared
    @ObservationIgnored private let logger = Logger(subsystem: "ForeverLM", category: "FocusWatch")

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent; called with the day's model when the first Studio window
    /// appears.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let center = NotificationCenter.default
        for name in [Notification.Name.focusWatchSettingDidChange, .dayPlansDidChange, .EKEventStoreChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // The day's model republishes the bout or the calendar first.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    FocusWatcher.shared.look()
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in FocusWatcher.shared.look() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in FocusWatcher.shared.look() }
            })
        }
        look()
    }

    // MARK: - Looking

    /// Looks at what is in front now and acts on the verdict. Looks asked
    /// for while one is running fold into one more after it.
    func look() {
        guard !isLooking else {
            looksAgain = true
            return
        }
        isLooking = true
        Task {
            await lookOnce()
            isLooking = false
            if looksAgain {
                looksAgain = false
                look()
            }
        }
    }

    private func lookOnce() async {
        let now = Date()
        guard FocusWatch.isEnabled else {
            stopWatching(status: .off, at: now)
            return
        }
        guard FrontWindowReader.isTrusted else {
            stopWatching(status: .needsAccessibility, at: now)
            return
        }
        if case .unavailable(let reason) = FocusJudge.availability() {
            stopWatching(status: .judgeUnavailable(reason), at: now)
            return
        }
        guard let current = currentGoal(now: now) else {
            stopWatching(status: .waiting, at: now)
            return
        }
        if goal != current {
            // A new goal: whatever drifted from the old one ends here.
            apply(tracker.close(at: now))
            goal = current
            loggedSpanIDs = [:]
        }
        publish(.watching(goal: current.title))
        armBackstop()
        guard Self.secondsSinceInput() < FocusWatch.idleSeconds else {
            apply(tracker.close(at: now))
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        observeWindows(of: front)
        let scene: FocusScene
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // ForeverLM itself is the work, except a page in its own Browser.
            guard let page = Self.inAppBrowserScene() else {
                apply(tracker.observe(onTrack: true, scene: Self.foreverLMScene, at: now))
                return
            }
            scene = page
        } else {
            let pid = front.processIdentifier
            let name = front.localizedName ?? front.bundleIdentifier ?? "An app"
            let bundleID = front.bundleIdentifier ?? name
            scene = await Task.detached(priority: .utility) {
                FrontWindowReader.scene(pid: pid, appName: name, bundleID: bundleID)
            }.value
        }
        if allowances.allows(scene, for: current) {
            apply(tracker.observe(onTrack: true, scene: scene, at: now))
            return
        }
        let onTrack: Bool
        do {
            onTrack = try await judge.isOnTrack(scene, goal: current)
            lastJudgeError = nil
        } catch {
            // No verdict: the clock stands as it was. Said once per error.
            if lastJudgeError != error.localizedDescription {
                lastJudgeError = error.localizedDescription
                logger.error("Could not judge what is in front: \(error.localizedDescription)")
            }
            return
        }
        // The goal may have ended while the judge thought.
        guard goal == current, FocusWatch.isEnabled else { return }
        apply(tracker.observe(onTrack: onTrack, scene: scene, at: Date()))
    }

    private func stopWatching(status newStatus: Status, at moment: Date) {
        apply(tracker.close(at: moment))
        goal = nil
        loggedSpanIDs = [:]
        publish(newStatus)
        backstop?.invalidate()
        backstop = nil
        removeWindowObserver()
    }

    /// Only a change redraws the Settings row: a look comes every half minute.
    private func publish(_ newStatus: Status) {
        if status != newStatus { status = newStatus }
    }

    /// The goal standing now: the bout on the clock, else the calendar block
    /// the clock is in (`FocusGoal.current`).
    private func currentGoal(now: Date) -> FocusGoal? {
        let day = DayModel.shared
        let bout = day.liveBout
        let titles: [String] = (bout?.sourceIDs ?? []).compactMap { id in
            guard let studio = AppModelBridge.studio, let article = studio.articlesById[id] else { return nil }
            return studio.displayTitle(for: article)
        }
        return FocusGoal.current(bout: bout, boutSourceTitles: titles, event: day.nowState.currentEvent, now: now)
    }

    private func armBackstop() {
        guard backstop == nil else { return }
        let timer = Timer(timeInterval: FocusWatch.backstopSeconds, repeats: true) { _ in
            Task { @MainActor in FocusWatcher.shared.look() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        backstop = timer
    }

    // MARK: - Acting

    private func apply(_ effects: [FocusDriftTracker.Effect]) {
        for effect in effects {
            switch effect {
            case .nudge(let scene):
                guard let goal else { continue }
                Task { await FocusNudges.shared.nudge(goal: goal, scene: scene) }
            case .log(let scene, let from, let to):
                let origin = goal?.origin
                Task {
                    do {
                        let span = try await storage.recordDayActivitySpan(
                            kind: .offTrack,
                            targetID: scene.targetID,
                            title: scene.displayName,
                            from: from,
                            to: to
                        )
                        if let span, origin == goal?.origin {
                            loggedSpanIDs[scene.targetID, default: []].insert(span.id)
                        }
                    } catch {
                        logger.error("Could not log time off track: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Not a distraction

    /// The nudge's Not a Distraction: `targetID` is allowed for the rest of
    /// the goal the nudge named, the drift ends without its time there, and
    /// what was logged of it under that goal comes off the day. A nudge from
    /// a goal that has since ended changes nothing.
    func notADistraction(targetID: String, goalKey: String) {
        guard let goal, goal.origin.key == goalKey else {
            logger.info("Not a distraction pressed for a goal that has ended; nothing to change")
            return
        }
        allowances.allow(targetID, for: goal.origin)
        apply(tracker.forgive(targetID, at: Date()))
        let ids = Array(loggedSpanIDs.removeValue(forKey: targetID) ?? [])
        if !ids.isEmpty {
            Task {
                do {
                    try await storage.deleteDayActivities(ids)
                    NotificationCenter.default.post(name: .dayPlansDidChange, object: nil)
                } catch {
                    logger.error("Could not take the forgiven time off the day: \(error.localizedDescription)")
                }
            }
        }
        look()
    }

    // MARK: - ForeverLM's own windows

    private static let foreverLMScene = FocusScene(appName: "ForeverLM", bundleID: Bundle.main.bundleIdentifier ?? "ForeverLM")

    /// The page ForeverLM's own Browser shows in the window in front, when
    /// that window's panes show the Browser; nil otherwise.
    private static func inAppBrowserScene() -> FocusScene? {
        let registry = StudioWindowRegistry.shared
        guard !registry.detachedWindowIsKey, let state = registry.activeState,
              state.centerTabGroups.groups.contains(where: { $0.activeTab == .browser }),
              let tab = BrowserWorkspace.existing(forWindow: state.id)?.activeTab,
              let url = tab.url, url.scheme?.hasPrefix("http") == true else { return nil }
        return FocusScene(appName: "ForeverLM Browser", bundleID: foreverLMScene.bundleID, windowTitle: tab.title, url: url)
    }

    // MARK: - Idle

    private static func secondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: - The window in front

    /// Follows the app in front's focused window and its title, so a new tab
    /// or window is looked at as it comes rather than at the backstop.
    private func observeWindows(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != windowObserverPID else { return }
        removeWindowObserver()
        windowObserverPID = pid
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        Task.detached(priority: .utility) {
            // Registering messages the other app, which may be busy.
            guard let observer = Self.makeWindowObserver(pid: pid, refcon: refcon) else { return }
            await MainActor.run {
                let watcher = FocusWatcher.shared
                guard watcher.windowObserverPID == pid, watcher.windowObserver == nil else { return }
                watcher.windowObserver = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
    }

    nonisolated private static func makeWindowObserver(pid: pid_t, refcon: UnsafeMutableRawPointer) -> AXObserver? {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            Task { @MainActor in FocusWatcher.shared.windowDidChange() }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, FrontWindowReader.messagingTimeout)
        for name in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification, kAXMainWindowChangedNotification] {
            _ = AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        return observer
    }

    private func removeWindowObserver() {
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .defaultMode)
        }
        windowObserver = nil
        windowObserverPID = nil
        titleChangeDebounce?.cancel()
        titleChangeDebounce = nil
    }

    /// Titles change in bursts (a page loading, a counter ticking); one look
    /// a second after the burst settles.
    private func windowDidChange() {
        titleChangeDebounce?.cancel()
        titleChangeDebounce = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            FocusWatcher.shared.look()
        }
    }
}

/// The nudge: one notification per drift, naming the goal. Delivered at once,
/// replacing an earlier nudge still on screen.
@MainActor
final class FocusNudges {
    static let shared = FocusNudges()

    // Read by the notification delegate, which is not on the main actor.
    nonisolated static let identifier = "com.foreverlm.focusNudge"
    nonisolated static let categoryIdentifier = "com.foreverlm.focusNudge"
    nonisolated static let notADistractionActionIdentifier = "com.foreverlm.focusNudge.notADistraction"
    nonisolated static let targetIDKey = "targetID"
    nonisolated static let goalKey = "goal"

    private let logger = Logger(subsystem: "ForeverLM", category: "FocusWatch")
    private var hasAskedForPermission = false
    private var hasRegisteredCategory = false

    private init() {}

    func nudge(goal: FocusGoal, scene: FocusScene) async {
        guard await ensurePermission() else {
            logger.info("Notifications are refused on this Mac; the drift is logged without a nudge")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = FocusWatch.nudgeTitlePrefix + goal.title
        let minutes = Int(FocusWatch.nudgeAfterSeconds / 60)
        content.body = "\(scene.displayName) has had your last \(minutes) minutes."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.targetIDKey: scene.targetID, Self.goalKey: goal.origin.key]
        await registerCategoryIfNeeded()
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Could not nudge: \(error.localizedDescription)")
        }
    }

    /// Not a Distraction, answered without bringing ForeverLM forward.
    private func registerCategoryIfNeeded() async {
        guard !hasRegisteredCategory else { return }
        hasRegisteredCategory = true
        let action = UNNotificationAction(identifier: Self.notADistractionActionIdentifier, title: "Not a Distraction", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [action], intentIdentifiers: [], options: [])
        let center = UNUserNotificationCenter.current()
        var all = await center.notificationCategories().filter { $0.identifier != Self.categoryIdentifier }
        all.insert(category)
        center.setNotificationCategories(all)
    }

    /// Asks once, the first time a nudge is due, as the bout alarms do.
    private func ensurePermission() async -> Bool {
        switch await NotificationPermission.current() {
        case .allowed:
            return true
        case .notAsked:
            guard !hasAskedForPermission else { return false }
            hasAskedForPermission = true
            return await NotificationPermission.request() == .allowed
        case .refused:
            return false
        }
    }
}
