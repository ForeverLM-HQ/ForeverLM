import AppKit
import EventKit
import Foundation
import Observation
import OSLog

extension Notification.Name {
    /// Open the write-up for the bout that owes one, in the Studio window in
    /// front. Posted by the Now chip and the Today menu; the key window's
    /// `StudioView` presents the sheet.
    static let requestBoutWriteUp = Notification.Name("ForeverLMRequestBoutWriteUp")
    /// Ask what a new bout is for before its clock starts, in the Studio
    /// window in front. The `BoutStartRequest` rides in `userInfo["request"]`.
    static let requestBoutStart = Notification.Name("ForeverLMRequestBoutStart")
}

/// A bout about to start: everything but its goal, which the learner names in
/// the start sheet (product owner, 2026-10-12: "maybe set a goal for that
/// session explicitly"). The goal becomes the bout's title.
struct BoutStartRequest: Identifiable, Equatable {
    let id = UUID()
    /// The calendar event the bout runs, shown as context above the goal.
    var eventTitle: String?
    /// The length the start sheet opens on, which the learner may change:
    /// what is left of `eventTitle`'s event, or the default bout.
    var minutes: Int = LearningBout.defaultMinutes
    var notebookID: String?
    var sourceIDs: [String] = []
}

/// The learner's day on this Mac: today's calendar, the bout on the clock, and
/// the day the Activity pane shows.
///
/// The day is the Mac's Calendar: the Now
/// chip in every window reads today's events from here, the assistant plans by
/// writing events into the calendar, and nothing about the day's time is kept
/// anywhere else. What stays ForeverLM's own is what the calendar cannot hold —
/// the log of what the learner actually read, heard, chatted and wrote (the
/// Activity pane), and learning bouts with their write-ups — both still filed
/// per day in the `day_plans` rows they have always travelled in.
///
/// Every write goes through `StorageService` or `AppleCalendarService` off-main
/// and comes back through `refresh()` / `refreshCalendar()`, so an MCP write, a
/// change in the Calendar app, and an edit on the other Mac all republish the
/// same way. The clock ticks twice a minute — enough to move the chip's
/// minutes and to notice the day turning over.
@MainActor
@Observable
final class DayModel {
    static let shared = DayModel()

    // MARK: The Activity pane's day

    private(set) var selectedDate: String
    /// The calendar day the clock last saw. When it rolls over at midnight and
    /// the pane was on that day, the pane follows to the new one.
    private var knownToday: String
    /// The day the Activity pane shows: its log and its bouts.
    private(set) var detail: DayPlanDetail?
    private(set) var lastLoadErrorMessage: String?

    // MARK: Today

    /// Today's record whatever day the pane shows: the bouts the write-up
    /// sheet can be for.
    private(set) var todayDetail: DayPlanDetail?
    /// The bout with a clock on it, wherever it started — a bout begun before
    /// midnight is still the live one at ten past.
    private(set) var liveBout: LearningBout?

    /// Today's events on the calendars ForeverLM shows, all-day ones too.
    private(set) var todayEvents: [AppleCalendarEvent] = []
    /// The events of the day the pane shows, when that is not today: read with
    /// today's, for `otherDayEventsFor` only.
    private(set) var otherDayEvents: [AppleCalendarEvent] = []
    private(set) var otherDayEventsFor: String?
    /// The Mac's Calendar is on for ForeverLM and macOS granted it.
    private(set) var isCalendarOn = false
    /// macOS refused Calendar access and will not ask again.
    private(set) var isCalendarBlocked = false
    /// Why the last read of today's calendar failed, or nil.
    private(set) var calendarErrorMessage: String?
    /// The day `todayEvents` was last read for, so "Plan your day?" is never
    /// asked before today's calendar has been looked at.
    private var eventsReadFor: String?

    /// The day "Plan your day?" stands for on this Mac, or nil
    /// (`PlanTheDay.isOpen`). Every Studio window draws it as a card in its
    /// rail's footer, or in its bottom-left corner while the rail is hidden
    /// (`PlanTheDayCard`), so it waits there rather than going the way of a
    /// banner.
    private(set) var planTheDayAsk: String?

    private(set) var nowMinute: Int
    /// The moment of the last tick: what the chip's minutes, a bout's clock
    /// and a break's end are measured against.
    private(set) var now: Date

    private let storage = StorageService()
    private let calendar = AppleCalendarService.shared
    private let logger = Logger(subsystem: "ForeverLM", category: "Day")
    private var clock: Timer?
    private var observers: [NSObjectProtocol] = []
    private var hasStarted = false
    private var calendarReadInFlight = false
    private var calendarReadQueued = false

    private init() {
        let now = Date()
        let today = DayPlan.dateString(for: now)
        selectedDate = today
        knownToday = today
        nowMinute = Self.minuteOfDay(now)
        self.now = now
    }

    // MARK: - Derived

    var todayString: String { DayPlan.dateString(for: Date()) }
    var isToday: Bool { selectedDate == todayString }

    var selectedDateValue: Date {
        DayPlan.startOfDay(selectedDate) ?? Calendar.current.startOfDay(for: Date())
    }

    /// Where the clock stands on today's calendar.
    var nowState: DayNowState {
        DayNow.state(events: todayEvents, calendarOn: isCalendarOn, now: now)
    }

    /// What the chip says: the bout if one is live, else the event the clock
    /// is in or one about to start; nil while nothing is happening, when the
    /// chip draws nothing.
    var nowPresentation: DayNowPresentation? {
        DayNow.presentation(state: nowState, bout: liveBout, now: now)
    }

    /// Today's events that hold a stretch of the day, by start.
    var timedEventsToday: [AppleCalendarEvent] {
        DayNow.timedEvents(todayEvents, on: now)
    }

    /// Today's all-day events that are not birthdays or cancelled.
    var allDayEventsToday: [AppleCalendarEvent] {
        DayNow.allDayEvents(todayEvents)
    }

    /// The calendar's events on the day the pane shows, all-day ones too:
    /// today's, or the other day's once they have been read.
    var selectedEvents: [AppleCalendarEvent] {
        if isToday { return todayEvents }
        return otherDayEventsFor == selectedDate ? otherDayEvents : []
    }

    /// The hours the Day pane's clock draws: the learner's day window
    /// (Settings › Chat › Day), widened to hold every event of the
    /// calendar. The log is not on the clock (its own view, Activity), so it
    /// widens nothing.
    func hourRange(dayStart: Int, dayEnd: Int) -> ClosedRange<Int> {
        DayNow.hourRange(DayPlanDetail.clockHourRange(dayStart: dayStart, dayEnd: dayEnd), holding: selectedEvents, on: selectedDateValue)
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        installObservers()
        armClock()
        Task { await refresh() }
        refreshCalendar()
    }

    /// The Activity pane has come to the front. It always opens on the actual
    /// today: this model lives as long as the process, and a Mac app stays
    /// open for days.
    func paneDidAppear() {
        start()
        goToToday()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        // A bout, a chat or an MCP write lands in this process but not
        // through this class.
        observers.append(center.addObserver(forName: .dayPlansDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in await DayModel.shared.refresh() }
        })
        // A bout or a sitting from the other Mac.
        observers.append(center.addObserver(forName: .cloudKitSyncRemoteStoreDidChange, object: nil, queue: .main) { notification in
            let rawValues = notification.userInfo?[CloudKitSyncNotificationInfo.affectedEntitiesKey] as? [String] ?? []
            let entities = Set(rawValues.compactMap(CloudKitSyncEntity.init(rawValue:)))
            let requiresFullRefresh = notification.userInfo?[CloudKitSyncNotificationInfo.requiresFullRefreshKey] as? Bool ?? false
            guard requiresFullRefresh || entities.contains(.dayPlan) else { return }
            Task { @MainActor in await DayModel.shared.refresh() }
        })
        // The Mac's Calendar changed under us — an event added, moved or
        // removed in the Calendar app, by the assistant, or synced down from
        // an account. EventKit says so at once.
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in DayModel.shared.refreshCalendar() }
        })
        // Turning the calendar on or off, or choosing its calendars, in
        // Settings or over MCP.
        observers.append(center.addObserver(forName: .pluginConnectionChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in DayModel.shared.refreshCalendar() }
        })
        // Coming back after a lock or a sleep, the clock has moved, and a
        // meeting added on the phone should be asked for from its account.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                DayModel.shared.tick()
                DayModel.shared.refreshCalendar()
                await AppleCalendarService.shared.refreshAccounts()
            }
        })
        observers.append(center.addObserver(forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in DayModel.shared.tick() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DayModel.shared.tick() }
        })
    }

    private func armClock() {
        clock?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor in DayModel.shared.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func tick() {
        let now = Date()
        nowMinute = Self.minuteOfDay(now)
        self.now = now
        observePlanTheDay(now: now)
        let today = DayPlan.dateString(for: now)
        guard today != knownToday else { return }
        let next = Self.selection(afterDayChange: selectedDate, from: knownToday, to: today)
        knownToday = today
        refreshCalendar()
        if next != selectedDate {
            select(date: next)
        } else {
            Task { await refresh() }
        }
    }

    /// The day to show once the calendar has moved from `previousToday` to
    /// `today`. A pane left on today follows the clock to the new day; a pane
    /// deliberately on another day stays there.
    nonisolated static func selection(afterDayChange selected: String, from previousToday: String, to today: String) -> String {
        selected == previousToday ? today : selected
    }

    private static func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    // MARK: - Loading

    /// Reads the day the pane shows, today's record and the live bout.
    func refresh() async {
        let date = selectedDate
        do {
            let loaded = try await storage.loadDayPlan(date)
            let today = todayString
            let todayLoaded = date == today ? loaded : try await storage.loadDayPlan(today)
            let bout = try await storage.loadLiveLearningBout()
            guard date == selectedDate else { return }
            // Screen record mode (admin only) shows the take's log, not the
            // learner's diary.
            let scope = await storage.screenRecordScope()
            detail = loaded.map { scope?.scoped($0) ?? $0 }
            todayDetail = todayLoaded.map { scope?.scoped($0) ?? $0 }
            liveBout = bout
            lastLoadErrorMessage = nil
        } catch {
            lastLoadErrorMessage = error.localizedDescription
            logger.error("Failed to load the day \(date): \(error.localizedDescription)")
        }
        tick()
    }

    /// Reads today's calendar again. Silent: only a failure is said, on the
    /// chip's popover. Reads that arrive while one is running fold into one
    /// more read after it, so a burst of `EKEventStoreChanged` costs two.
    func refreshCalendar() {
        guard !calendarReadInFlight else {
            calendarReadQueued = true
            return
        }
        calendarReadInFlight = true
        let today = todayString
        Task {
            defer {
                calendarReadInFlight = false
                if calendarReadQueued {
                    calendarReadQueued = false
                    refreshCalendar()
                }
            }
            let service = calendar
            let state = await Task.detached(priority: .utility) {
                (on: service.isConnected, blocked: service.isBlockedBySystem)
            }.value
            isCalendarOn = state.on
            isCalendarBlocked = state.blocked
            guard state.on else {
                todayEvents = []
                otherDayEvents = []
                otherDayEventsFor = nil
                calendarErrorMessage = nil
                eventsReadFor = today
                tick()
                return
            }
            do {
                todayEvents = try await events(on: today)
                calendarErrorMessage = nil
            } catch {
                calendarErrorMessage = error.localizedDescription
                logger.error("Reading today's calendar failed: \(error.localizedDescription)")
            }
            eventsReadFor = today
            // The Day pane on another day reads that day's calendar too.
            let other = selectedDate
            if other != today {
                do {
                    let read = try await events(on: other)
                    otherDayEvents = read
                    otherDayEventsFor = other
                } catch {
                    logger.error("Reading \(other)'s calendar failed: \(error.localizedDescription)")
                }
            }
            tick()
        }
    }

    /// The shown calendars' events on one day, past the screen-record take's
    /// scope when that is on.
    private func events(on date: String) async throws -> [AppleCalendarEvent] {
        guard let dayStart = DayPlan.startOfDay(date),
              let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        var events = try await calendar.shownEvents(from: dayStart, to: dayEnd)
        if let scope = await storage.screenRecordScope() {
            events = events.filter(scope.allowsCalendarEvent)
        }
        return events
    }

    func select(date: String) {
        guard DayPlan.isValidDateString(date), date != selectedDate else { return }
        selectedDate = date
        detail = nil
        if date != todayString { refreshCalendar() }
        Task { await refresh() }
    }

    func shift(days: Int) {
        guard let next = DayPlan.dateString(selectedDate, offsetBy: days) else { return }
        select(date: next)
    }

    func goToToday() {
        select(date: todayString)
    }

    // MARK: - The log

    /// Takes a sitting off the log: every span it was built from goes
    /// (product owner, 2026-09-20: "please let me delete things here too").
    func deleteSitting(_ sitting: DayActivitySitting) async throws {
        try await storage.deleteDayActivities(sitting.spans.map(\.id))
        await refresh()
    }

    // MARK: - Plan your day?

    /// "Plan your day?" (product owner, 2026-09-22 and 2026-09-27). While it is
    /// morning and today's calendar holds nothing the learner planned, the
    /// card stands in every Studio window until they answer it
    /// (`PlanTheDay.isOpen`). The first tick they are at the Mac, the
    /// question counts as put: seen, with ForeverLM in front, or else said
    /// once as a notification (`PlanTheDay.isPutNow`).
    private func observePlanTheDay(now: Date) {
        let today = DayPlan.dateString(for: now)
        // A calendar not read yet looks like an empty day; say nothing about
        // it until it has been read.
        guard eventsReadFor == today else {
            if planTheDayAsk != nil { planTheDayAsk = nil }
            return
        }
        let isOpen = PlanTheDay.isOpen(
            events: todayEvents,
            calendarOn: isCalendarOn,
            nowMinute: nowMinute,
            dayHours: PlannerDayHours.window,
            answeredToday: PlanTheDay.Ledger.wasAnswered(on: today)
        )
        let ask = isOpen ? today : nil
        if planTheDayAsk != ask { planTheDayAsk = ask }
        let askedToday = PlanTheDay.Ledger.wasAsked(on: today)
        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!
        )
        // Forced: the chat that plans the day opens by itself, in the window
        // in front, the first time the learner is at the Mac with it open.
        if PlanTheDay.opensChatNow(
            isOpen: isOpen,
            forced: PlanTheDay.isForced,
            openedToday: PlanTheDay.Ledger.chatWasOpened(on: today),
            appIsInFront: NSApp.isActive,
            secondsSinceInput: secondsSinceInput
        ) {
            PlanTheDay.Ledger.markChatOpened(on: today)
            logger.info("Opening the planning chat for \(today): forced, nothing planned")
            NotificationCenter.default.post(name: .requestPlanTheDayChat, object: nil)
        }
        guard isOpen, !askedToday else { return }
        guard PlanTheDay.isPutNow(isOpen: isOpen, askedToday: askedToday, secondsSinceInput: secondsSinceInput) else { return }
        PlanTheDay.Ledger.markAsked(on: today)
        // In front, the card is already before them. A banner is for a
        // learner who is somewhere else.
        guard !NSApp.isActive else {
            logger.info("Asked to plan \(today) by the card: nothing planned")
            return
        }
        logger.info("Asking to plan \(today) by notification: nothing planned, ForeverLM not in front")
        Task { await PlanTheDayNotifications.shared.ask(date: today) }
    }

    /// The learner answered "Plan your day?" on this Mac — went to plan it,
    /// from the card or the notification, or closed the card. It is not asked
    /// again today; a new day asks afresh.
    func answerPlanTheDay() {
        PlanTheDay.Ledger.markAnswered(on: planTheDayAsk ?? todayString)
        // Forced, the question outlives the answer: it stands until the
        // calendar holds a plan (`PlanTheDay.isOpen`).
        if !PlanTheDay.isForced { planTheDayAsk = nil }
    }

    /// Don't Ask Again, from the card or the notification: the Settings
    /// switch, turned off.
    func stopAskingToPlanTheDay() {
        PlanTheDay.setEnabled(false)
        planTheDayAsk = nil
    }
}

// MARK: - Bouts

/// The learner's timer.
///
/// A bout is a stretch of learning with a clock on it; it ends in a write-up of
/// what was learned and what is still unclear; and the write-up earns the break
/// that follows. Every one of these goes through `StorageService` and comes
/// back through `refresh()`, so the chip, the Today menu, an MCP call from a
/// chat and the other Mac all republish the same way.
extension DayModel {

    var isBoutRunning: Bool { liveBout?.phase() == .learning }

    /// The bout `id` names, among the live one and today's.
    func bout(withID id: String) -> LearningBout? {
        if let liveBout, liveBout.id == id { return liveBout }
        return todayDetail?.bouts.first { $0.id == id }
    }

    /// A bout on the event the day is in, waiting for its goal: its length is
    /// what is left of the event (`startBout` clamps it to the shortest bout).
    /// `notebookID` and `sourceIDs` are the notebook and the library sources
    /// the block is for — the ones its notes or URL link
    /// (`foreverlm://notebook/…`, `foreverlm://source/…`), as the library
    /// resolves them (`DayNowPopover`) — so the bout's write-up names them.
    func startRequest(forEvent event: AppleCalendarEvent, notebookID: String?, sourceIDs: [String]) -> BoutStartRequest {
        let minutesLeft = Int((event.end.timeIntervalSince(Date()) / 60).rounded(.down))
        return BoutStartRequest(
            eventTitle: DayNow.displayTitle(event),
            minutes: minutesLeft,
            notebookID: notebookID,
            sourceIDs: SourceIDList.normalized(sourceIDs)
        )
    }

    @discardableResult
    func startBout(
        title: String,
        minutes: Int = LearningBout.defaultMinutes,
        notebookID: String? = nil,
        sourceIDs: [String] = []
    ) async throws -> LearningBout {
        let saved = try await storage.startLearningBout(LearningBout(
            dayPlanID: todayString,
            blockID: nil,
            title: title,
            notebookID: notebookID,
            sourceIDs: sourceIDs,
            plannedMinutes: LearningBout.clampedMinutes(minutes)
        ))
        await refresh()
        return saved
    }

    /// Stops the learning. The write-up is owed from here.
    @discardableResult
    func endBout(_ id: String) async throws -> LearningBout {
        let saved = try await storage.endLearningBout(id)
        await refresh()
        return saved
    }

    /// Saves the write-up, which is what earns the break.
    @discardableResult
    func writeUpBout(_ id: String, learned: String, unclear: String?, breakMinutes: Int? = nil) async throws -> LearningBout {
        let saved = try await storage.writeUpLearningBout(id, learned: learned, unclear: unclear, breakMinutes: breakMinutes)
        await refresh()
        return saved
    }

    @discardableResult
    func startBreak(_ id: String, minutes: Int? = nil) async throws -> LearningBout {
        let saved = try await storage.startLearningBoutBreak(id, minutes: minutes)
        await refresh()
        return saved
    }

    @discardableResult
    func endBreak(_ id: String) async throws -> LearningBout {
        let saved = try await storage.endLearningBoutBreak(id)
        await refresh()
        return saved
    }

    /// Lets a bout go without a write-up. Recorded, not deleted.
    @discardableResult
    func abandonBout(_ id: String) async throws -> LearningBout {
        let saved = try await storage.abandonLearningBout(id)
        await refresh()
        return saved
    }

    /// Asks the Studio window in front to open the write-up sheet.
    func requestWriteUp() {
        NotificationCenter.default.post(name: .requestBoutWriteUp, object: nil)
    }

    /// Asks the Studio window in front to ask for the bout's goal, then start it.
    func requestStart(_ request: BoutStartRequest = BoutStartRequest()) {
        NotificationCenter.default.post(name: .requestBoutStart, object: nil, userInfo: ["request": request])
    }
}
