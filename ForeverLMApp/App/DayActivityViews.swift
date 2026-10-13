import AppKit
import SwiftUI

extension StudioViewModel {
    /// Whether the Activity pane is open in the active window.
    var showActivityInReader: Bool {
        get { activeCenterTabs.contains(.activity) }
        set {
            if newValue {
                activateCenterTab(.activity)
            } else {
                deactivateCenterTab(.activity)
            }
        }
    }

    /// The Space sidebar's Day row and the Today menu: the day on a clock,
    /// the calendar beside the log, on today.
    func openActivityInReader() {
        activateCenterTab(.activity)
    }
}

// MARK: - Pane

/// The Activity center pane: what the app saw the learner do on one day —
/// the papers read, the episodes heard, the chats had, the Docs written —
/// drawn on a clock and nothing else.
///
/// Split out of the Planner on 2026-09-22 (the product owner: "the planner and the
/// tracker of what I've actually read … are now kind of intertwined … These
/// should just be two separate views"), and kept when the Planner went on
/// 2026-09-30: the day's plan is the Mac's Calendar now, and this pane is the
/// record the calendar cannot hold. It reads `DayModel.shared`.
/// See docs/planner-design.md, "The log is its own view".
struct DayActivityReaderPane: View {
    /// The pane's mark on the rail and its tab.
    static let systemImage = "chart.bar.doc.horizontal"

    @Environment(StudioViewModel.self) private var vm

    private let model = DayModel.shared
    @AppStorage(PlannerDayHours.startKey) private var dayStartHour: Int = PlannerDayHours.defaultStart
    @AppStorage(PlannerDayHours.endKey) private var dayEndHour: Int = PlannerDayHours.defaultEnd
    @AppStorage(DayActivityLayout.storageKey) private var layout: DayActivityLayout = .clock
    @State private var actionErrorMessage: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand { vm.showActivityInReader = false }
            .studioChromeLineHeader(opaque: true) {
                toolbar
                    .padding(.horizontal, 16)
                    .background(WindowDragBlocker())
            }
            .studioCenterTabCloseChrome(for: .activity)
            .alert(
                "Day",
                isPresented: Binding(
                    get: { actionErrorMessage != nil },
                    set: { if !$0 { actionErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { actionErrorMessage = nil }
            } message: {
                Text(actionErrorMessage ?? "")
            }
            // Opens on the actual today.
            .task { model.paneDidAppear() }
    }

    // MARK: Toolbar

    /// The chrome line holds the day and its arrows (History's title in
    /// History) and the ⋯; the layout is the ⋯'s View section and the day's
    /// totals open the content (Quiet chrome, docs/ui-design.md; the product owner,
    /// 2026-10-06: "make the app more slick; kind of like the chatgpt app").
    private var toolbar: some View {
        HStack(spacing: 6) {
            if layout == .history {
                Text(DayActivityLayout.history.title)
                    .zoomedSystemFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                    .textSelection(.disabled)
            } else {
                dayNavigation
            }

            Spacer(minLength: 8)

            moreMenu
        }
    }

    /// Everything else the pane does, from one ⋯: **View** Clock, By Source
    /// or History, remembered per Mac (`activity.layout` over MCP).
    @ViewBuilder
    private var moreMenu: some View {
        if #available(macOS 14.4, *) {
            TitlebarBandButton(
                help: "More",
                accessibilityLabel: "More",
                accessibilityValue: layout.title,
                accessibilityIdentifier: "studio.activity.more",
                action: {},
                menu: { NSHostingMenu(rootView: moreMenuItems) }
            ) {
                RowMoreActionsLabel()
            }
        } else {
            Menu {
                moreMenuItems
            } label: {
                RowMoreActionsLabel()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .hoverHighlight()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityIdentifier("studio.activity.more")
        }
    }

    private var moreMenuItems: some View {
        Section("View") {
            ForEach(DayActivityLayout.allCases) { option in
                Button {
                    layout = option
                } label: {
                    if option == layout {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dayNavigation: some View {
            Button { model.shift(days: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.hoverWash)
            .help("Previous day")
            .accessibilityLabel("Previous day")

            Text(DayActivityText.dayTitle(for: model.selectedDateValue, isToday: model.isToday))
                .zoomedSystemFont(size: 13, weight: .semibold)
                .lineLimit(1)
                .accessibilityIdentifier("studio.activity.date")

            Button { model.shift(days: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.hoverWash)
            .help("Next day")
            .accessibilityLabel("Next day")

            if !model.isToday {
                Button("Today") { model.goToToday() }
                    .buttonStyle(.hoverWash)
                    .zoomedSystemFont(size: 12, weight: .medium)
            }
    }

    /// The day's minutes by kind, then the glances left off the clock:
    /// "Reading 1h 40m · Chat 25m · 3 glances under 2 minutes". Nil when
    /// nothing is logged.
    private var totalsLine: String? {
        guard let detail = model.detail, !detail.activities.isEmpty else { return nil }
        let parts = [DayActivityText.loggedSummary(detail), DayActivityText.glancesSummary(activityGroups)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if layout == .history {
            ActivityHistoryListView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.lastLoadErrorMessage {
            ContentUnavailableView {
                Label("The day could not be loaded", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                calendarNote
                allDayLine
                dayTotals
                if layout == .bySource {
                    DayActivityBySourceView(
                        activityGroups: activityGroups,
                        nowMinute: model.isToday ? model.nowMinute : nil,
                        onOpen: { group in open(group) },
                        onDelete: { sitting in
                            Task { await perform { try await model.deleteSitting(sitting) } }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DayActivityTimelineView(
                        activityGroups: activityGroups,
                        events: model.selectedEvents,
                        day: model.selectedDateValue,
                        hourRange: model.hourRange(dayStart: dayStartHour, dayEnd: dayEndHour),
                        focusHour: max(model.hourRange(dayStart: dayStartHour, dayEnd: dayEndHour).lowerBound, model.focusHourRange.lowerBound),
                        nowMinute: model.isToday ? model.nowMinute : nil,
                        onOpen: { group in open(group) },
                        onDelete: { sitting in
                            Task { await perform { try await model.deleteSitting(sitting) } }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// What the calendar needs before it can be on the clock: a quiet line
    /// with the one action, only while it is off or refused.
    @ViewBuilder
    private var calendarNote: some View {
        if !model.isCalendarOn && layout == .clock {
            HStack(spacing: 6) {
                Text(model.isCalendarBlocked ? "Calendar access is off in macOS." : "Your calendar is not shown here.")
                    .foregroundStyle(.secondary)
                Button(model.isCalendarBlocked ? "Open Privacy & Security…" : "Turn On Calendar…") {
                    if model.isCalendarBlocked {
                        AppleCalendarService.openPrivacySettings()
                    } else {
                        PluginsPlace.requestOpen(.appleCalendar)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .zoomedSystemFont(size: 11)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .textSelection(.disabled)
            .accessibilityIdentifier("studio.day.calendarOff")
        }
    }

    /// The day's all-day events, one line above the clock: they hold no hour.
    @ViewBuilder
    private var allDayLine: some View {
        let events = DayNow.allDayEvents(model.selectedEvents)
        if !events.isEmpty && layout == .clock {
            HStack(spacing: 10) {
                ForEach(events, id: \.occurrenceKey) { event in
                    Button { AppleCalendarService.openInCalendarApp(event) } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(event.calendarColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(DayNow.displayTitle(event))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("All day · \(DayNow.displayTitle(event))")
                }
                Spacer(minLength: 0)
            }
            .zoomedSystemFont(size: 11)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .accessibilityIdentifier("studio.day.allDay")
        }
    }

    /// The day's totals, the content's first line: on the chrome line until
    /// 2026-10-06. An empty clock says "Nothing logged."; By Source says it
    /// in its own empty state.
    @ViewBuilder
    private var dayTotals: some View {
        if let line = totalsLine ?? (layout == .clock ? "Nothing logged." : nil) {
            Text(line)
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .help(line)
                .textSelection(.disabled)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .accessibilityIdentifier("studio.activity.totals")
        }
    }

    /// The day's log by what it was spent on. A chat about exactly one source
    /// joins that source, so the paper and the conversation about it read as
    /// one thing; the chat's sources come from the review-session records.
    private var activityGroups: [DayActivityGroup] {
        let activities = model.detail?.activities ?? []
        guard !activities.isEmpty else { return [] }
        return DayPlanDetail.activityGroups(activities, chatSources: vm.dayChatSources(for: activities))
    }

    private func perform(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    /// Opens what a group records: the source in the Reader beside this
    /// pane, the chat in the chat panel, the Doc in Docs.
    private func open(_ group: DayActivityGroup) {
        Task {
            switch group.kind {
            case .reading, .listening, .watching:
                await vm.openLinkedSourceInReader(group.targetID, beside: .activity)
            case .chat:
                await vm.open(.chat(group.targetID))
            case .doc:
                await vm.open(.doc(group.targetID))
            }
        }
    }
}

// MARK: - Timeline

/// The log on a clock: hour rules and a now line, and one card per sitting
/// at its clock time, the full width of the clock. Sittings that overlap in
/// time share the width, one column each (`DayActivityClock`).
struct DayActivityTimelineView: View {
    let activityGroups: [DayActivityGroup]
    /// The Mac's Calendar on this day: the timed ones are a lane of their own
    /// beside the log, drawn on the same hours.
    var events: [AppleCalendarEvent] = []
    var day: Date = Date()
    let hourRange: ClosedRange<Int>
    /// Where the clock opens when nothing is logged yet.
    let focusHour: Int
    let nowMinute: Int?
    let onOpen: (DayActivityGroup) -> Void
    let onDelete: (DayActivitySitting) -> Void

    @State private var didScrollToFocus = false

    private static let hourHeight = DayActivityClock.hourHeight
    private static let gutterWidth = DayActivityClock.gutterWidth
    private var pointsPerMinute: CGFloat { Self.hourHeight / 60 }
    private var rangeStartMinute: Int { hourRange.lowerBound * 60 }
    private var totalHeight: CGFloat { CGFloat(hourRange.count - 1) * Self.hourHeight }
    private var sittings: [DayActivitySitting] { DayPlanDetail.activitySittings(activityGroups) }
    private var timedEvents: [AppleCalendarEvent] { DayNow.timedEvents(events, on: day) }

    /// The calendar lane's share of the clock: nothing on a day with no timed
    /// event, else two fifths, never narrower than a title can be read in.
    private func calendarLaneWidth(_ width: CGFloat) -> CGFloat {
        guard !timedEvents.isEmpty else { return 0 }
        return min(max(120, (width - Self.gutterWidth) * 0.4), max(0, width - Self.gutterWidth - 120))
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .topLeading) {
                        scrollAnchors
                        hourRules(width: width)
                        calendarCards(width: width)
                        sittingCards(width: width)
                        if let nowMinute, nowMinute >= rangeStartMinute, nowMinute <= hourRange.upperBound * 60 {
                            nowLine(width: width, minute: nowMinute)
                        }
                    }
                }
                .frame(height: totalHeight + 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .onAppear {
                guard !didScrollToFocus else { return }
                didScrollToFocus = true
                withAnimation(nil) { scrollProxy.scrollTo(Self.anchorID(hour: openingHour), anchor: .top) }
            }
            // The log arrives after the pane, and the day can change under
            // it: open on the new day's first card rather than where the
            // last one left off.
            .onChange(of: openingHour) { _, hour in
                withAnimation(nil) { scrollProxy.scrollTo(Self.anchorID(hour: hour), anchor: .top) }
            }
        }
    }

    private var openingHour: Int {
        let first = Self.openingHour(sittings: sittings, hourRange: hourRange, fallback: focusHour)
        guard let firstEvent = timedEvents.first else { return first }
        // Opens on whichever begins first, the day's first card or its first
        // meeting; the fallback hour only stands in for an empty day.
        let eventHour = min(max(hourRange.lowerBound, DayNow.minuteSpan(of: firstEvent, on: day).start / 60), max(hourRange.lowerBound, hourRange.upperBound - 1))
        return sittings.isEmpty ? eventHour : min(first, eventHour)
    }

    /// The hour the clock opens on: the hour of the day's first card. The
    /// clock's range is the learner's whole day, so opening on its first hour
    /// put eight empty hours of log above the first card (product owner, 2026-09-23:
    /// "any way to show this better?"). With nothing logged, `fallback`. Pure.
    static func openingHour(sittings: [DayActivitySitting], hourRange: ClosedRange<Int>, fallback: Int) -> Int {
        let hour = sittings.map(\.startMinute).min().map { $0 / 60 } ?? fallback
        return min(max(hourRange.lowerBound, hour), max(hourRange.lowerBound, hourRange.upperBound - 1))
    }

    static func anchorID(hour: Int) -> String { "activity-hour-\(hour)" }

    private var scrollAnchors: some View {
        VStack(spacing: 0) {
            ForEach(Array(hourRange.lowerBound..<hourRange.upperBound), id: \.self) { hour in
                Color.clear
                    .frame(width: 1, height: Self.hourHeight)
                    .id(Self.anchorID(hour: hour))
            }
        }
        .offset(y: 8)
        .allowsHitTesting(false)
    }

    private func y(for minute: Int) -> CGFloat {
        CGFloat(minute - rangeStartMinute) * pointsPerMinute + 8
    }

    private func hourRules(width: CGFloat) -> some View {
        ForEach(Array(hourRange), id: \.self) { hour in
            HStack(alignment: .top, spacing: 6) {
                Text(DayPlan.clockString(minute: hour * 60))
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: Self.gutterWidth - 10, alignment: .trailing)
                    .offset(y: -6)
                Rectangle()
                    .fill(Color.primary.opacity(hour == hourRange.lowerBound ? 0 : 0.08))
                    .frame(height: 1)
            }
            .frame(width: width, alignment: .leading)
            .offset(y: y(for: hour * 60))
        }
    }

    private func sittingCards(width: CGFloat) -> some View {
        let sittings = self.sittings
        let minimumMinutes = Int((DayActivityClock.sittingCardMinimumHeight / pointsPerMinute).rounded(.up))
        let layout = DayPlanDetail.activityLayout(sittings, minimumMinutes: minimumMinutes)
        let laneWidth = calendarLaneWidth(width)
        let hostWidth = max(40, width - Self.gutterWidth - 10 - laneWidth)
        let groupsByID = Dictionary(activityGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ForEach(sittings) { sitting in
            let column = DayActivityClock.sittingColumnFrame(placed: layout[sitting.id], hostWidth: hostWidth)
            let height = max(DayActivityClock.sittingCardMinimumHeight, CGFloat(sitting.durationMinutes) * pointsPerMinute - 2)
            DaySittingCard(
                sitting: sitting,
                width: column.width,
                height: height,
                drawnStartMinute: sitting.startMinute,
                pointsPerMinute: pointsPerMinute,
                onOpen: {
                    if let group = groupsByID[sitting.groupID] { onOpen(group) }
                },
                onDelete: { onDelete(sitting) },
                group: groupsByID[sitting.groupID]
            )
            .offset(x: Self.gutterWidth + 4 + laneWidth + column.x, y: y(for: sitting.startMinute))
        }
    }

    /// The calendar's timed events, in the lane left of the log. Overlapping
    /// ones share the lane, one column each, as the log's sittings do.
    private func calendarCards(width: CGFloat) -> some View {
        let events = timedEvents
        let laneWidth = calendarLaneWidth(width)
        let spans = Dictionary(uniqueKeysWithValues: events.map { ($0.occurrenceKey, DayNow.minuteSpan(of: $0, on: day)) })
        let minimumMinutes = Int((DayActivityClock.sittingCardMinimumHeight / pointsPerMinute).rounded(.up))
        let layout = DayPlanDetail.activityLayout(
            placing: events.map { ($0.occurrenceKey, spans[$0.occurrenceKey]?.start ?? 0, spans[$0.occurrenceKey]?.end ?? 0) },
            minimumMinutes: minimumMinutes
        )
        return ForEach(events, id: \.occurrenceKey) { event in
            let span = spans[event.occurrenceKey] ?? (start: 0, end: 0)
            let column = DayActivityClock.sittingColumnFrame(placed: layout[event.occurrenceKey], hostWidth: max(40, laneWidth - 8))
            DayCalendarEventCard(
                event: event,
                width: column.width,
                height: max(DayActivityClock.sittingCardMinimumHeight, CGFloat(span.end - span.start) * pointsPerMinute - 2)
            )
            .offset(x: Self.gutterWidth + 4 + column.x, y: y(for: span.start))
        }
    }

    private func nowLine(width: CGFloat, minute: Int) -> some View {
        HStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            Rectangle().fill(Color.red.opacity(0.85)).frame(height: 1.5)
        }
        .frame(width: max(0, width - Self.gutterWidth + 4))
        .offset(x: Self.gutterWidth - 4, y: y(for: minute) - 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Calendar event card

/// One event of the Mac's Calendar on the Day pane's clock: what the day held
/// for the learner, in its calendar's colour. The calendar stays the ground
/// truth, so a click opens the event in the Calendar app, and the menu joins
/// its call; nothing here writes an event.
struct DayCalendarEventCard: View {
    let event: AppleCalendarEvent
    let width: CGFloat
    let height: CGFloat

    private var tint: Color {
        event.calendarColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .secondary
    }
    private var showsText: Bool { DayActivityClock.sittingCardShowsText(height: height) }

    var body: some View {
        Button {
            AppleCalendarService.openInCalendarApp(event)
        } label: {
            HStack(alignment: showsText ? .top : .center, spacing: 4) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 2)
                    .padding(.vertical, showsText ? 2 : 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(DayNow.displayTitle(event))
                        .zoomedSystemFont(size: showsText ? 11 : 9, weight: .medium)
                        .lineLimit(height > 30 ? 2 : 1)
                    if height > 26 {
                        Text(DayNow.rangeText(event))
                            .zoomedSystemFont(size: 10)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, showsText ? 2 : 0)
            .frame(width: width, height: height, alignment: showsText ? .topLeading : .leading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.14)))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .textSelection(.disabled)
        }
        .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0, opacity: 0.12))
        .contextMenu {
            Button("Open in Calendar") { AppleCalendarService.openInCalendarApp(event) }
            if let link = event.joinLink {
                Button(link.label) { NSWorkspace.shared.open(link.url) }
            }
        }
        .help("\(DayNow.displayTitle(event))\n\(DayNow.rangeText(event))\(event.calendarTitle.isEmpty ? "" : " · \(event.calendarTitle)")")
        .accessibilityLabel("\(DayNow.displayTitle(event)), \(DayNow.rangeText(event))")
        .accessibilityIdentifier("studio.day.event")
    }
}

// MARK: - Sitting card

/// One sitting of the day's log: a thing, the kind that took most of it,
/// and when. The minutes actually logged are banded darker inside the card,
/// so a sitting joined across a gap shows the gap. Clicking it opens the
/// thing — the paper in the Reader, the chat in the chat panel, the Doc in
/// Docs. The card says what happened and nothing about any plan.
struct DaySittingCard: View {
    let sitting: DayActivitySitting
    let width: CGFloat
    let height: CGFloat
    /// The minute the card's top stands for, so the bands fall on the clock.
    let drawnStartMinute: Int
    let pointsPerMinute: CGFloat
    let onOpen: () -> Void
    /// Every sitting can be taken off the log (product owner, 2026-09-20: "please
    /// let me delete things here too").
    let onDelete: () -> Void
    /// What a click opens, for the menu's Open in Other Window.
    var group: DayActivityGroup? = nil

    private var summary: String { DayActivityText.sittingSummary(sitting) }

    private var clockRange: String {
        "\(DayPlan.clockString(minute: sitting.startMinute)) to \(DayPlan.clockString(minute: sitting.endMinute))"
    }
    private var isWide: Bool { width >= 180 }
    /// A card under the text height is one centred line — icon, title and,
    /// when wide, its clock — at a size a fourteen-point bar holds.
    private var showsText: Bool { DayActivityClock.sittingCardShowsText(height: height) }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: showsText ? .top : .center, spacing: 4) {
                Rectangle()
                    .fill(sitting.kind.tint)
                    .frame(width: 2)
                    .padding(.vertical, showsText ? 2 : 3)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Image(systemName: sitting.kind.systemImage)
                            .zoomedSystemFont(size: showsText ? (isWide ? 9 : 8) : 8)
                            .foregroundStyle(sitting.kind.tint)
                        Text(sitting.title)
                            .zoomedSystemFont(size: showsText ? (isWide ? 11 : 10) : 9, weight: .medium)
                            .lineLimit(height > 30 ? 2 : 1)
                        if !showsText && isWide {
                            Text(clockRange)
                                .zoomedSystemFont(size: 9)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }
                    }
                    if height > 26 {
                        Text(summary)
                            .zoomedSystemFont(size: isWide ? 10 : 9)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, showsText ? 2 : 0)
            .frame(width: width, height: height, alignment: showsText ? .topLeading : .leading)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .background(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(sitting.kind.tint.opacity(0.08))
                    ForEach(sitting.spans) { span in
                        Rectangle()
                            .fill(span.kind.tint.opacity(0.18))
                            .frame(width: width, height: max(2, CGFloat(span.durationMinutes) * pointsPerMinute))
                            .offset(y: CGFloat(span.startMinute - drawnStartMinute) * pointsPerMinute)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            )
            .textSelection(.disabled)
        }
        .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0, opacity: 0.12))
        .contextMenu {
            if let group {
                switch group.kind {
                case .reading, .listening, .watching:
                    OtherWindowSourceMenuItem(sourceID: group.targetID)
                case .chat:
                    OtherWindowMenuItem(.chat(group.targetID))
                case .doc:
                    OtherWindowMenuItem(.doc(group.targetID))
                }
                Divider()
            }
            // No confirmation (product owner, 2026-09-21): the log is this Mac's
            // observation of the day, not the plan or the library.
            Button("Delete", role: .destructive, action: onDelete)
                .help("Take this sitting off the day's log. What you read stays.")
                .accessibilityIdentifier("studio.activity.log.delete")
        }
        .help("\(sitting.title)\n\(summary)")
        .accessibilityLabel("\(sitting.kind.displayName), \(sitting.title), \(clockRange)")
        .accessibilityIdentifier("studio.activity.log")
    }
}

// MARK: - By source

/// How the Activity pane draws the day. Remembered per Mac.
enum DayActivityLayout: String, CaseIterable, Identifiable {
    /// A clock, a card per sitting.
    case clock
    /// One row per thing, its sittings along the day.
    case bySource
    /// Every day's time spent, newest first, a month at a time. Settings ›
    /// History until 2026-09-24.
    case history

    static let storageKey = "activityPaneLayout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "Clock"
        case .bySource: "By Source"
        case .history: "History"
        }
    }

    /// The value `get_app_settings` / `set_app_setting` use for
    /// `activity.layout`: snake case, as the MCP catalog spells its values.
    var mcpValue: String {
        switch self {
        case .clock: "clock"
        case .bySource: "by_source"
        case .history: "history"
        }
    }

    /// What the pane will draw: the stored choice, the clock when none.
    static var stored: DayActivityLayout {
        UserDefaults.standard.string(forKey: storageKey).flatMap(DayActivityLayout.init(rawValue:)) ?? .clock
    }
}

/// The day's log by thing: one row per source, chat or Doc — the groups the
/// clock's cards come from — titled once on the left with its minutes, and
/// its sittings drawn as bars along a time axis to the right, the logged
/// minutes banded darker inside each. Longest first, as the groups come.
///
/// Added 2026-09-23 beside the clock (product owner, on a Wednesday of fourteen
/// things: "any way to show this better?"). On the clock a paper returned to
/// four times was four cards each repeating a two-line title, and a burst of
/// short sittings split the clock four ways until every title was cut. Here
/// a return is another bar on the same row, and a day of a dozen things fits
/// without scrolling. The axis spans the hours the log covers, not the
/// learner's whole day. Glances stay off it, as they stay off the clock.
struct DayActivityBySourceView: View {
    let activityGroups: [DayActivityGroup]
    let nowMinute: Int?
    let onOpen: (DayActivityGroup) -> Void
    let onDelete: (DayActivitySitting) -> Void

    static let rowHeight: CGFloat = 30
    static let axisHeight: CGFloat = 22
    static let barHeight: CGFloat = 16
    /// Hour labels closer than this skip hours.
    static let minimumLabelSpacing: CGFloat = 40

    private var rows: [DayActivityGroup] { activityGroups.filter { !$0.isGlance } }

    var body: some View {
        let rows = self.rows
        if let hours = Self.axisHours(rows.flatMap(\.sittings)) {
            GeometryReader { proxy in
                let geometry = Geometry(width: proxy.size.width, hours: hours)
                VStack(spacing: 0) {
                    axis(geometry)
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            hourRules(geometry, height: CGFloat(rows.count) * Self.rowHeight)
                            VStack(spacing: 0) {
                                ForEach(rows) { group in
                                    row(group, geometry)
                                }
                            }
                            if let nowMinute, nowMinute >= hours.lowerBound * 60, nowMinute <= hours.upperBound * 60 {
                                Rectangle()
                                    .fill(Color.red.opacity(0.85))
                                    .frame(width: 1.5, height: CGFloat(rows.count) * Self.rowHeight)
                                    .offset(x: geometry.x(for: nowMinute) - 0.75)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(width: proxy.size.width, alignment: .topLeading)
                        .padding(.bottom, 24)
                    }
                }
            }
            .padding(.top, 8)
        } else if activityGroups.isEmpty {
            // One line (product owner, 2026-10-06, "fewer … bells and whistles").
            // A day of glances alone draws nothing here: the totals line
            // above already counts them.
            Text("Nothing logged.")
                .foregroundStyle(.secondary)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    /// Where things go across the pane's width.
    struct Geometry {
        let width: CGFloat
        let hours: ClosedRange<Int>

        var titleWidth: CGFloat { DayActivityBySourceView.titleWidth(for: width) }
        var trackX: CGFloat { titleWidth + 12 }
        var trackWidth: CGFloat { max(40, width - trackX - 16) }
        var pointsPerMinute: CGFloat { trackWidth / CGFloat(max(60, (hours.upperBound - hours.lowerBound) * 60)) }

        func x(for minute: Int) -> CGFloat {
            trackX + CGFloat(minute - hours.lowerBound * 60) * pointsPerMinute
        }
    }

    /// The whole hours the log covers: from the hour of the first sitting to
    /// the hour after the last one ends, at least one hour. Nil with no
    /// sittings. Pure.
    static func axisHours(_ sittings: [DayActivitySitting]) -> ClosedRange<Int>? {
        guard let start = sittings.map(\.startMinute).min(),
              let end = sittings.map(\.endMinute).max() else { return nil }
        let first = max(0, start / 60)
        let last = min(24, Int((Double(end) / 60).rounded(.up)))
        return first...max(last, first + 1)
    }

    /// A third of the pane for the titles, within reason. Pure.
    static func titleWidth(for width: CGFloat) -> CGFloat {
        min(340, max(150, width * 0.32))
    }

    /// Every how many hours the axis labels an hour, so labels stay
    /// `minimumLabelSpacing` apart. Pure.
    static func labelStride(pointsPerHour: CGFloat) -> Int {
        guard pointsPerHour > 0 else { return 1 }
        return max(1, Int((minimumLabelSpacing / pointsPerHour).rounded(.up)))
    }

    private func labelledHours(_ geometry: Geometry) -> [Int] {
        let step = Self.labelStride(pointsPerHour: geometry.pointsPerMinute * 60)
        return Array(stride(from: geometry.hours.lowerBound, through: geometry.hours.upperBound, by: step))
    }

    private func axis(_ geometry: Geometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(labelledHours(geometry), id: \.self) { hour in
                Text(DayPlan.clockString(minute: hour * 60))
                    .zoomedSystemFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .frame(width: 40)
                    .offset(x: geometry.x(for: hour * 60) - 20)
            }
        }
        .frame(width: geometry.width, height: Self.axisHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func hourRules(_ geometry: Geometry, height: CGFloat) -> some View {
        ForEach(Array(geometry.hours), id: \.self) { hour in
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1, height: height)
                .offset(x: geometry.x(for: hour * 60))
        }
        .allowsHitTesting(false)
    }

    private func row(_ group: DayActivityGroup, _ geometry: Geometry) -> some View {
        ZStack(alignment: .leading) {
            Button { onOpen(group) } label: {
                HStack(spacing: 5) {
                    Image(systemName: group.kind.systemImage)
                        .zoomedSystemFont(size: 10)
                        .foregroundStyle(group.kind.tint)
                        .frame(width: 14)
                    Text(group.title)
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(DayActivityText.durationText(group.totalMinutes))
                        .zoomedSystemFont(size: 10)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 6)
                .frame(width: geometry.titleWidth, height: Self.rowHeight - 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0, opacity: 0.12))
            .padding(.leading, 6)
            .help("\(group.title)\n\(DayActivityText.groupSummary(group))")
            .contextMenu { otherWindowItem(group) }
            .accessibilityLabel("\(group.kind.displayName), \(group.title), \(DayActivityText.groupSummary(group))")
            .accessibilityIdentifier("studio.activity.bySource.row")

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .frame(width: geometry.trackWidth, height: Self.barHeight + 4)
                .offset(x: geometry.trackX)
                .allowsHitTesting(false)

            ForEach(group.sittings) { sitting in
                bar(sitting, group: group, geometry: geometry)
                    .offset(x: geometry.x(for: sitting.startMinute))
            }
        }
        .frame(width: geometry.width, height: Self.rowHeight, alignment: .leading)
    }

    private func bar(_ sitting: DayActivitySitting, group: DayActivityGroup, geometry: Geometry) -> some View {
        let ppm = geometry.pointsPerMinute
        let width = max(4, CGFloat(sitting.durationMinutes) * ppm)
        let summary = DayActivityText.sittingSummary(sitting)
        return Button { onOpen(group) } label: {
            ZStack(alignment: .leading) {
                Rectangle().fill(sitting.kind.tint.opacity(0.22))
                ForEach(sitting.spans) { span in
                    Rectangle()
                        .fill(span.kind.tint.opacity(0.75))
                        .frame(width: max(1.5, CGFloat(span.durationMinutes) * ppm))
                        .offset(x: CGFloat(span.startMinute - sitting.startMinute) * ppm)
                }
            }
            .frame(width: width, height: Self.barHeight, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(sitting.title)\n\(summary)")
        .contextMenu {
            otherWindowItem(group)
            Divider()
            Button("Delete", role: .destructive) { onDelete(sitting) }
                .help("Take this sitting off the day's log. What you read stays.")
                .accessibilityIdentifier("studio.activity.log.delete")
        }
        .accessibilityLabel("\(sitting.kind.displayName), \(sitting.title), \(summary)")
        .accessibilityIdentifier("studio.activity.bySource.sitting")
    }

    @ViewBuilder
    private func otherWindowItem(_ group: DayActivityGroup) -> some View {
        switch group.kind {
        case .reading, .listening, .watching:
            OtherWindowSourceMenuItem(sourceID: group.targetID)
        case .chat:
            OtherWindowMenuItem(.chat(group.targetID))
        case .doc:
            OtherWindowMenuItem(.doc(group.targetID))
        }
    }
}
