import Foundation

/// Nudge Me Back on Track: while a learning bout runs or a block of the
/// learner's own is on the calendar, ForeverLM watches what is in front of
/// them on the Mac — any app, the browser included — and when they have
/// drifted off the goal for two minutes, says so once and logs the drift on
/// the day (product owner, 2026-11-08: "the app can monitor my computer
/// behavior and see when I'm going off track and getting distracted"; "but
/// what if i'm outside the app in the browser?"; "can this thing nudge me to
/// stay on track?").
///
/// The product owner's four choices, 2026-11-08:
/// - **Judge:** Apple's on-device model compares the app, its window's title
///   and the page's address with the goal (`FocusJudge`). Free and private,
///   and it knows a lecture on YouTube about the paper from the YouTube feed.
///   No list of distracting sites, no paid model on a timer.
/// - **When:** only while there is a stated goal to compare against — a bout
///   on the clock (`LearningBoutPhase.learning`), else a timed event on the
///   calendar that names nobody else (`FocusGoal.current`). A meeting with
///   other people is not judged.
/// - **Response:** one notification after `nudgeAfterSeconds` off track,
///   naming the goal, and the drift on the day's log as `.offTrack` spans
///   (the Activity pane, `get_day_activity`).
/// - **Sees:** the frontmost app, its focused window's title, and the page's
///   address in a browser, through Accessibility (`FrontWindowReader`). The
///   screen itself only with Read the Window Too (`readsScreenKey`, asked for
///   the same day: "can it monitor my mac screen?", "Yes, add screen
///   reading"), which reads the words in the window in front
///   (`FocusScreenReader`).
///
/// Device-local and off until the learner turns it on (Settings › Chat › Day,
/// or `set_day_settings nudge_back_on_track`): it asks macOS for
/// Accessibility, which only the learner can grant.
enum FocusWatch {
    static let settingKey = Prefs.Planner.nudgeBackOnTrack.name

    static var isEnabled: Bool {
        Preferences.value(Prefs.Planner.nudgeBackOnTrack)
    }

    static func setEnabled(_ enabled: Bool) {
        Preferences.set(enabled, for: Prefs.Planner.nudgeBackOnTrack)
        NotificationCenter.default.post(name: .focusWatchSettingDidChange, object: nil)
    }

    /// Read the Window Too: the judge also reads the words in the window in
    /// front. Device-local, off until switched on; needs Screen Recording.
    /// Does nothing while the watcher is off.
    static let readsScreenKey = Prefs.Planner.focusReadsScreen.name

    static var readsScreen: Bool {
        Preferences.value(Prefs.Planner.focusReadsScreen)
    }

    static func setReadsScreen(_ reads: Bool) {
        Preferences.set(reads, for: Prefs.Planner.focusReadsScreen)
        NotificationCenter.default.post(name: .focusWatchSettingDidChange, object: nil)
    }

    /// Off track this long without a break before the one nudge.
    static let nudgeAfterSeconds: TimeInterval = 120
    /// A drift shorter than this stays off the log: a glance at a message is
    /// not a distraction worth a line.
    static let minimumLoggedSeconds: TimeInterval = 60
    /// No keyboard or pointer input for this long and the learner is not at
    /// the Mac: a drift ends and nothing is judged until they are back.
    static let idleSeconds: TimeInterval = 180
    /// How often the watcher looks again while a goal stands and nothing has
    /// changed in front: the backstop for a page that changes without a new
    /// window title, and what lets the nudge come due. Switching apps,
    /// windows or tabs is seen at once.
    static let backstopSeconds: TimeInterval = 30

    static let nudgeTitlePrefix = "Back to: "
}

extension Notification.Name {
    /// The switch changed, in Settings or over MCP.
    static let focusWatchSettingDidChange = Notification.Name("ForeverLMFocusWatchSettingDidChange")
}

/// What the learner set out to do, which what is in front is judged against.
struct FocusGoal: Equatable, Sendable {
    enum Origin: Equatable, Hashable, Sendable {
        case bout(id: String)
        case event(key: String)

        /// How a notification carries it: "bout:<id>", "event:<key>".
        var key: String {
            switch self {
            case .bout(let id): return "bout:" + id
            case .event(let key): return "event:" + key
            }
        }
    }

    let origin: Origin
    let title: String
    /// More words about the goal: the bout's sources, the event's notes.
    let context: [String]

    /// The goal standing now: the bout on the clock, else the calendar block
    /// the clock is in when it is the learner's own (timed, holding time,
    /// nobody else on it). Nil while there is nothing to compare against.
    static func current(
        bout: LearningBout?,
        boutSourceTitles: [String] = [],
        event: AppleCalendarEvent?,
        now: Date
    ) -> FocusGoal? {
        if let bout, bout.phase(now: now) == .learning {
            let title = bout.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return FocusGoal(origin: .bout(id: bout.id), title: title, context: boutSourceTitles.filter { !$0.isEmpty })
            }
        }
        guard let event, !event.isAllDay, !event.hasOtherPeople, !event.isFree, !event.isCancelled, !event.isDeclined,
              event.start <= now, now < event.end else { return nil }
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let notes = (event.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return FocusGoal(origin: .event(key: event.occurrenceKey), title: title, context: notes.isEmpty ? [] : [String(notes.prefix(400))])
    }
}

/// What the learner said is not a distraction, with the nudge's Not a
/// Distraction (product owner, 2026-11-08: "Yes, add it", to "Add 'Not a
/// distraction' to the nudge so it learns your false alarms?"). It holds for
/// the goal it was said under — the bout, or the calendar block — and goes
/// with it: YouTube allowed for a bout on a lecture is not allowed for every
/// bout after. Kept by site or app (`FocusScene.targetID`), the way the log
/// and the nudge name what was in front.
struct FocusAllowances: Equatable {
    private(set) var goal: FocusGoal.Origin?
    private(set) var targetIDs: Set<String> = []

    mutating func allow(_ targetID: String, for goal: FocusGoal.Origin) {
        if self.goal != goal {
            self.goal = goal
            targetIDs = []
        }
        targetIDs.insert(targetID)
    }

    func allows(_ scene: FocusScene, for goal: FocusGoal) -> Bool {
        self.goal == goal.origin && targetIDs.contains(scene.targetID)
    }
}

/// What was in front: the app, its focused window's title, and in a browser
/// the page's address.
struct FocusScene: Equatable, Hashable, Sendable {
    let appName: String
    let bundleID: String
    let windowTitle: String?
    /// The page in front, when the app is a browser and said.
    let url: URL?

    init(appName: String, bundleID: String, windowTitle: String? = nil, url: URL? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.windowTitle = (title?.isEmpty ?? true) ? nil : title
        self.url = url
    }

    /// The site, without `www.`.
    var host: String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What the log's span is about: the site when a page is in front, else
    /// the app. Two tabs of one site are one thing on the day.
    var targetID: String { host ?? bundleID }

    /// How the log and the nudge name it: "x.com", "Music", "Brave Browser".
    var displayName: String { host ?? appName }

    /// The address the judge reads: host and path, never the query, which is
    /// where search terms and tokens live.
    var pageText: String? {
        guard let host else { return nil }
        let path = url?.path ?? ""
        return path.isEmpty || path == "/" ? host : host + String(path.prefix(120))
    }

    /// Two looks that would get the same verdict: the same app, site and
    /// window title.
    var verdictKey: String {
        [bundleID, pageText ?? "", String((windowTitle ?? "").prefix(200))].joined(separator: "\u{1F}")
    }
}

/// The drift clock, pure so it can be tested: fed one verdict at a time, it
/// says when to nudge and which stretches go on the log.
///
/// A drift starts at the first look judged off track and ends at the first
/// one judged on track, or when the watcher pauses (the learner idle, the goal
/// over, the switch off). It nudges once, `FocusWatch.nudgeAfterSeconds`
/// after it started. Once it has lasted `FocusWatch.minimumLoggedSeconds`,
/// each thing it was spent on is logged from the moment it came to the front,
/// widened at least a minute at a time while it stays, and closed at its end;
/// the log's writer (`recordDayActivitySpan`) joins a re-logged stretch to
/// the span it already drew, so the repeats draw one span.
struct FocusDriftTracker: Equatable {
    enum Effect: Equatable {
        case nudge(FocusScene)
        case log(FocusScene, from: Date, to: Date)
    }

    /// One thing the drift was spent on, from when it came to the front to
    /// when something else did.
    struct Stretch: Equatable {
        let scene: FocusScene
        let from: Date
        let to: Date
    }

    struct Drift: Equatable {
        let startedAt: Date
        var nudged: Bool
        /// The thing in front now and since when.
        var scene: FocusScene
        var sceneSince: Date
        /// How far the current thing has been logged.
        var loggedThrough: Date?
        /// Things the drift was spent on before it had lasted long enough to
        /// log: they go on the log once it has.
        var unlogged: [Stretch] = []
    }

    private(set) var drift: Drift?

    var isDrifting: Bool { drift != nil }

    mutating func observe(onTrack: Bool, scene: FocusScene, at moment: Date) -> [Effect] {
        if onTrack { return close(at: moment) }
        guard var current = drift else {
            drift = Drift(startedAt: moment, nudged: false, scene: scene, sceneSince: moment, loggedThrough: nil)
            return []
        }
        var effects: [Effect] = []
        let isLogging = moment.timeIntervalSince(current.startedAt) >= FocusWatch.minimumLoggedSeconds
        if current.scene.targetID != scene.targetID {
            if moment > current.sceneSince {
                current.unlogged.append(Stretch(scene: current.scene, from: current.sceneSince, to: moment))
            }
            current.scene = scene
            current.sceneSince = moment
            current.loggedThrough = nil
        } else {
            // Same thing, perhaps a new tab title: keep the newest words.
            current.scene = scene
        }
        if isLogging {
            effects += current.unlogged.map { .log($0.scene, from: $0.from, to: $0.to) }
            current.unlogged = []
            if moment > current.sceneSince,
               current.loggedThrough.map({ moment.timeIntervalSince($0) >= 60 }) ?? true {
                effects.append(.log(current.scene, from: current.sceneSince, to: moment))
                current.loggedThrough = moment
            }
        }
        if !current.nudged, moment.timeIntervalSince(current.startedAt) >= FocusWatch.nudgeAfterSeconds {
            current.nudged = true
            effects.append(.nudge(current.scene))
        }
        drift = current
        return effects
    }

    /// The learner said `targetID` is not a distraction: the drift ends, and
    /// what it held of anything else is logged as `close` would; the time on
    /// `targetID` is not.
    mutating func forgive(_ targetID: String, at moment: Date) -> [Effect] {
        close(at: moment).filter {
            if case .log(let scene, _, _) = $0 { return scene.targetID != targetID }
            return true
        }
    }

    /// Ends a drift: the learner is back on track, went idle, the goal ended
    /// or the watcher stopped. What it held is logged to `moment`, when it
    /// lasted long enough to log at all.
    mutating func close(at moment: Date) -> [Effect] {
        guard let current = drift else { return [] }
        drift = nil
        guard moment.timeIntervalSince(current.startedAt) >= FocusWatch.minimumLoggedSeconds else { return [] }
        var effects = current.unlogged.map { Effect.log($0.scene, from: $0.from, to: $0.to) }
        if moment > current.sceneSince {
            effects.append(.log(current.scene, from: current.sceneSince, to: moment))
        }
        return effects
    }
}
