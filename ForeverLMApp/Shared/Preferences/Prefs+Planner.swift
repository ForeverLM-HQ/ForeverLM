import Foundation

// Generated for step 0 of the typed settings layer from the key census; kept by hand from here on.
// A name is the stored string and is frozen (`UnitTests/Fixtures/preference-keys.golden.json`).

extension Prefs {
    /// The planner, Think first, the focus watcher and small per-Mac choices.
    enum Planner {
        /// The hours the Planner's clock draws. A statement about the learner's
        /// day, not the Mac it was said on, so it follows the account.
        static let dayStart = AccountKey<Int?>("planner.dayHours.start.v1")
        static let dayEnd = AccountKey<Int?>("planner.dayHours.end.v1")
        /// Think first's level for the whole library (`ThinkFirst`): how much the
        /// learner wants to be asked for their own line first is a choice about
        /// how they learn, not about the Mac they said it on.
        static let thinkFirstLevel = AccountKey<String?>("thinkFirst.level")
        static let suggestPlanningTheDay = DeviceKey<Bool>("planner.suggestPlanningTheDay", default: true, reason: "whether this Mac asks to plan the day; asked on the Mac being sat at")
        static let forcePlanningTheDay = DeviceKey<Bool>("planner.forcePlanningTheDay", default: false, reason: "a switch for checking the Plan your day ask on this Mac")
        static let planTheDayAskedOn = DeviceKey<String?>("planner.planTheDay.askedOn", reason: "the day this Mac last asked to plan the day")
        static let planTheDayAnsweredOn = DeviceKey<String?>("planner.planTheDay.answeredOn", reason: "the day this Mac's Plan your day ask was last answered")
        static let planTheDayChatOpenedOn = DeviceKey<String?>("planner.planTheDay.chatOpenedOn", reason: "the day this Mac last opened the planning chat")
        static let nudgeBackOnTrack = DeviceKey<Bool>("focus.nudgeBackOnTrack", default: false, reason: "whether this Mac watches for drift; it is about the screen being sat at")
        static let focusReadsScreen = DeviceKey<Bool>("focus.readScreen", default: false, reason: "whether this Mac may read its own screen for the drift watcher")
        /// Think first's tally of answered and skipped asks is measured where
        /// it happens, and the sources whose gist this Mac has asked about are
        /// this Mac's memory of asking; a take itself lives in the source's
        /// understanding document, which travels.
        static let thinkFirstCounts = DeviceKey<[String: Any]?>("thinkFirst.counts.v1", coding: .dictionary, reason: "how often each Think first moment was answered or skipped here")
        static let thinkFirstAskedSources = DeviceKey<[String]?>("thinkFirst.askedSources.v1", reason: "the sources whose gist this Mac has already asked about")
        static let activityPaneLayout = DeviceKey<String?>("activityPaneLayout", reason: "how this Mac's day activity pane is laid out")
        static let quickAssistantShortcut = DeviceKey<String?>("quickAssistant.shortcut", reason: "this Mac's keyboard shortcut for the quick assistant")
        static let calendarGroups = DeviceKey<Data?>("calendar.groups", reason: "which of this Mac's calendars belong to which group; calendars are named per Mac")
        /// Whether a journal check that finds new matches raises a banner. The
        /// journals themselves are followed per Mac, so the banner about what
        /// this Mac found is this Mac's decision too.
        static let journalsNotifyOnMatch = DeviceKey<Bool?>("journals.notifyOnMatch.v1", reason: "device-local like the journal feeds it announces; a banner is about the Mac that found the article")
        /// Whether this Mac holds off idle sleep for scheduled tasks: a
        /// decision about this Mac's power, which the other Mac makes for itself.
        static let keepMacAwakeForScheduledTasks = DeviceKey<Bool?>("scheduledTasks.keepMacAwake", reason: "device-local: whether this Mac stays awake for scheduled tasks")
        /// Taste, per device. Read straight from UserDefaults on the Mac and the
        /// iPhone alike (Settings → Appearance / Display); the phone has no
        /// synchronous view of the synced rows, and a logo's pace is not worth
        /// carrying across an account.
        static let loadingIndicatorSpeed = DeviceKey<Double?>("loadingIndicator.speed", reason: "device-local animation pace, read directly on both platforms")

        static let all: [AnyPreferenceKey] = [
            dayStart.erased,
            dayEnd.erased,
            thinkFirstLevel.erased,
            suggestPlanningTheDay.erased,
            forcePlanningTheDay.erased,
            planTheDayAskedOn.erased,
            planTheDayAnsweredOn.erased,
            planTheDayChatOpenedOn.erased,
            nudgeBackOnTrack.erased,
            focusReadsScreen.erased,
            thinkFirstCounts.erased,
            thinkFirstAskedSources.erased,
            activityPaneLayout.erased,
            quickAssistantShortcut.erased,
            calendarGroups.erased,
            journalsNotifyOnMatch.erased,
            keepMacAwakeForScheduledTasks.erased,
            loadingIndicatorSpeed.erased,
        ]
    }
}
