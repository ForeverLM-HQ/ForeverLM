import AppKit
import SwiftUI

// MARK: - The chip

/// The day, in the footer of every Studio window's navigation rail and in the
/// toolbar of every pop-out Reader window, while something is happening: the
/// event the clock is in on the Mac's Calendar and how long is left, one
/// starting within the quarter hour (`DayNow.upcomingMinutes`), or the bout
/// on the clock. A quiet hour draws nothing (product owner, 2026-10-06: "cleaner
/// and fewer buttons and bells and whistles"); until then the chip said
/// *Free until 14:00* or *Nothing more today* all day. The menu bar's Today
/// menu is the way on whatever the hour: Plan the Day in Chat, Open
/// Calendar, Start Pomodoro Timer… and Activity.
///
/// Since 2026-09-30 the day is the Mac's Calendar (the product owner: "the mac calendar
/// is what gets shown in the bottom left"). There is no Planner behind the
/// chip: its popover lists today's events, opens any of them in the Calendar
/// app, joins a call from its link, starts a bout, and opens the chat that
/// plans the day by writing events into the calendar. Since shell stage 4 it
/// is also a way to Activity, the day's record, which left the rail's top
/// rows (`DayNowMenuRow.activity`). A hairline along its foot shows how far
/// through the event the clock is. `StudioView` starts the day's model, so
/// the chip has a clock to read before it first draws.
struct DayNowChip: View {
    enum Style {
        /// A row in the navigation rail's footer, above the account, the
        /// full width of the rail (product owner, 2026-09-19: "maybe better to put
        /// it above this? in the bottom left").
        case rail
        /// In a pop-out Reader window's real toolbar, which has no rail.
        case toolbar
    }

    let style: Style
    /// The dot and the minutes only, for a band with a few points to spare.
    var compact = false
    /// A calendar glyph alone, centred, for the 52-point icon strip, where
    /// even the minutes do not fit; the help says the rest. Unlike the full
    /// chip it is always there, with the tone's dot on its corner while
    /// something is happening, and its popover is the day's schedule.
    var iconOnly = false
    /// The room the chip may take; nil for as much as its text needs.
    var maxWidth: CGFloat? = nil

    @Environment(StudioViewModel.self) private var vm
    /// The Studio window the chip is in; nil in a pop-out Reader's toolbar.
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?
    private let model = DayModel.shared
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        let presentation = model.nowPresentation
        // The icon strip's chip is always there: a calendar glyph that opens
        // the day (product owner, 2026-10-09: "day should be a popup thing above
        // the MD circle in the bottom left; what you can click and it will
        // expand to show the schedule"). Every other style still draws only
        // while something is happening.
        if presentation != nil || iconOnly {
            chip(presentation)
                // A rail row sits at the window's foot, so its popover opens
                // beside the rail rather than under the row.
                .popover(isPresented: $isPresented, arrowEdge: style == .rail ? .trailing : .bottom) {
                    DayNowPopover(model: model, windowState: windowState, dismiss: { isPresented = false })
                        .environment(vm)
                        // So Activity's Open in Other Window names the others.
                        .environment(windowState)
                }
                // The chip leaves when the hour goes quiet, its popover with
                // it; the next time it comes it comes closed.
                .onDisappear { isPresented = false }
                .task { model.start() }
        }
    }

    private func chip(_ presentation: DayNowPresentation?) -> some View {
        Button {
            isPresented.toggle()
        } label: {
            if iconOnly {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    // The tone's dot rides the glyph's corner while something
                    // is happening, as the notifications bell's does.
                    .overlay(alignment: .topTrailing) {
                        if let presentation {
                            DayNowDot(tone: presentation.tone)
                                .scaleEffect(0.8)
                                .offset(x: 4, y: -3)
                        }
                    }
                    .frame(width: 36, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                            .fill(isHovered || isPresented
                                  ? StudioDesign.selectionFill(isSelected: isPresented, isHovered: isHovered)
                                  : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous))
            } else if let presentation {
                rowLabel(presentation)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .modifier(RailHelpOrTooltip(text: help(presentation), isCompact: iconOnly))
        .accessibilityLabel(help(presentation))
        .accessibilityIdentifier("studio.now")
    }

    private func rowLabel(_ presentation: DayNowPresentation) -> some View {
            HStack(spacing: 6) {
                DayNowDot(tone: presentation.tone)
                if compact {
                    Text(presentation.compactText)
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text(presentation.title)
                        .zoomedSystemFont(size: 12, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if style == .rail {
                        // The minutes keep the rail row's trailing edge, the
                        // way Voice keeps the account row's.
                        Spacer(minLength: 4)
                    }
                    if let detail = presentation.detail {
                        Text(detail)
                            .zoomedSystemFont(size: 11)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: style == .rail ? 32 : StudioDesign.Metrics.chromeButtonHeight)
            .frame(maxWidth: style == .rail ? .infinity : maxWidth, alignment: .leading)
            .fixedSize(horizontal: style != .rail && maxWidth == nil, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                    .fill(isHovered || isPresented
                          ? StudioDesign.selectionFill(isSelected: isPresented, isHovered: isHovered)
                          : Color.clear)
            )
            // How far through the event the clock is, as a hairline along
            // the chip's foot. Only an event has a length; a bout says its
            // own minutes.
            .overlay(alignment: .bottomLeading) {
                if !compact, presentation.tone == .event, let fraction = eventProgress {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: max(2, geo.size.width * fraction), height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous))
    }

    private var eventProgress: CGFloat? {
        guard let event = model.nowState.currentEvent,
              let fraction = DayNow.progress(of: event, now: model.now) else { return nil }
        return CGFloat(fraction)
    }

    private func help(_ presentation: DayNowPresentation?) -> String {
        guard let presentation else { return "Today's schedule" }
        var text = presentation.tone == .upcoming ? "Next: \(presentation.title)" : "Now: \(presentation.title)"
        if let detail = presentation.detail { text += " · \(detail)" }
        return text
    }
}

/// The chip's dot: the tone in one glyph.
struct DayNowDot: View {
    let tone: DayNowTone

    var body: some View {
        switch tone {
        case .event:
            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
        case .upcoming:
            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: 8, height: 8)
        case .bout:
            Image(systemName: "timer")
                .zoomedSystemFont(size: 10, weight: .semibold)
                .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - The popover

/// The day, opened from the chip: the bout on the clock, the event the hour is
/// in, today's schedule, the plans the day serves (this quarter's and this
/// week's, `PlanGlance`), and the ways on — plan the day in a chat, start a
/// bout, open the Calendar app.
private struct DayNowPopover: View {
    let model: DayModel
    /// The chip's Studio window, where Activity opens: a click stays in the
    /// window it was made in. Nil in a pop-out Reader's toolbar, where the
    /// Studio window in front takes it.
    let windowState: StudioWindowState?
    let dismiss: () -> Void

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.uiZoomScale) private var uiZoomScale
    @State private var errorMessage: String?
    /// This quarter's and this week's plans, read each time the popover
    /// opens; nil until read, and in a team's library, which keeps none.
    @State private var plans: PlanGlance?

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.medium) {
            if let bout = model.liveBout, bout.phase(now: model.now) != .complete, bout.phase(now: model.now) != .abandoned {
                LearningBoutCard(
                    bout: bout,
                    now: model.now,
                    onEnd: { run { _ = try await model.endBout(bout.id) } },
                    onWriteUp: {
                        dismiss()
                        model.requestWriteUp()
                    },
                    onStartBreak: { run { _ = try await model.startBreak(bout.id) } },
                    onEndBreak: { run { _ = try await model.endBreak(bout.id) } },
                    onAbandon: { run { _ = try await model.abandonBout(bout.id) } }
                )
            }
            heading
            if let message = errorMessage ?? model.calendarErrorMessage {
                Text(message)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if model.isCalendarOn {
                allDaySection
                scheduleSection
            }
            plansSection
            VStack(alignment: .leading, spacing: 0) {
                menuRows
            }
            .padding(.horizontal, -menuRowInset)
        }
        .task {
            do {
                plans = try await vm.loadPlanGlance()
            } catch {
                errorMessage = "Could not read your plans: \(error.localizedDescription)"
            }
        }
        .padding(StudioDesign.Spacing.large)
        .frame(width: 320)
        // A group of its own: on a plain container the identifier replaced
        // every control's inside.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio.now.popover")
    }

    // MARK: Heading

    @ViewBuilder
    private var heading: some View {
        switch model.nowState {
        case .inEvent(let event):
            eventSection(event)
        case .beforeFirst(let next):
            quietHeading("The day starts at \(DayNow.clockString(next.start))", detail: "Next: \(DayNow.displayTitle(next))")
        case .between(let next):
            if let next {
                quietHeading("Free until \(DayNow.clockString(next.start))", detail: "Next: \(DayNow.displayTitle(next))")
            } else {
                quietHeading("Nothing more today", detail: nil)
            }
        case .empty:
            quietHeading("Nothing on the calendar today", detail: nil)
        case .calendarOff:
            quietHeading(
                "The Mac's Calendar is off",
                detail: model.isCalendarBlocked
                    ? "macOS refused ForeverLM's Calendar access. Allow it in Privacy & Security, then turn Calendar on."
                    : "Turn it on and your day — and what the assistant plans — shows here."
            )
        }
    }

    private func quietHeading(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .zoomedSystemFont(size: 14, weight: .semibold)
                .monospacedDigit()
            if let detail {
                Text(detail)
                    .zoomedSystemFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The event the clock is in: its title, its hours and calendar, and what
    /// can be done with it.
    @ViewBuilder
    private func eventSection(_ event: AppleCalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DayNow.displayTitle(event))
                .zoomedSystemFont(size: 14, weight: .semibold)
                .lineLimit(2)
            Text(eventStanding(event))
                .zoomedSystemFont(size: 11)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        HStack(spacing: StudioDesign.Spacing.small) {
            if let link = event.joinLink {
                action(link.label, identifier: "studio.now.join", prominent: true) {
                    NSWorkspace.shared.open(link.url)
                    dismiss()
                }
            }
            if model.liveBout == nil {
                action("Start Pomodoro Timer…", identifier: "studio.now.startBout", prominent: event.joinLink == nil) {
                    // The block's notebook — the one it names, or the one made
                    // from it this session, never a title match — and its
                    // sources as the library holds them.
                    let notebookID = vm.boutNotebookID(forBlockNotebook: event.notebookID, blockKey: event.occurrenceKey)
                    let sourceIDs = vm.librarySourceIDs(forBlockLinks: event.sourceIDs)
                    dismiss()
                    model.requestStart(model.startRequest(forEvent: event, notebookID: notebookID, sourceIDs: sourceIDs))
                }
            }
            action("Open in Calendar", identifier: "studio.now.openEvent") {
                AppleCalendarService.openInCalendarApp(event)
                dismiss()
            }
        }
        notebookAction(event)
    }

    /// The notebook a block of work is for, opened from here: the one its
    /// notes or URL link (`foreverlm://notebook/…`), or the one made from it
    /// before. A block that links sources and no notebook offers to make one
    /// of them instead. The event is never written: the calendar is the
    /// learner's.
    @ViewBuilder
    private func notebookAction(_ event: AppleCalendarEvent) -> some View {
        if let notebook = blockNotebook(event) {
            action("Open Notebook", identifier: "studio.now.openNotebook") {
                vm.openNotebookInReader(notebook.id)
                dismiss()
            }
            .help("Open \u{201C}\(notebook.title)\u{201D}")
        } else if !vm.librarySourceIDs(forBlockLinks: event.sourceIDs).isEmpty {
            action("Make Notebook from This Block", identifier: "studio.now.makeNotebook") {
                let title = DayNow.displayTitle(event)
                let sourceIDs = event.sourceIDs
                let blockKey = event.occurrenceKey
                Task { await vm.makeNotebook(fromBlockTitled: title, sourceIDs: sourceIDs, blockKey: blockKey) }
                dismiss()
            }
            .help("A notebook named \u{201C}\(DayNow.displayTitle(event))\u{201D} with this block's sources")
        }
    }

    /// The block's own notebook (the one it names, or the one made from it
    /// this session, as a bout files under), else one titled as the block
    /// that holds its sources, so the chip does not offer to make a second.
    private func blockNotebook(_ event: AppleCalendarEvent) -> LearningGoalRecord? {
        if let id = vm.boutNotebookID(forBlockNotebook: event.notebookID, blockKey: event.occurrenceKey),
           let notebook = vm.notebooks.first(where: { $0.id == id }) {
            return notebook
        }
        return vm.notebookMade(fromBlockTitled: DayNow.displayTitle(event), sourceIDs: event.sourceIDs)
    }

    private func eventStanding(_ event: AppleCalendarEvent) -> String {
        var parts = ["\(DayNow.rangeText(event))", DayNow.remainingText(until: event.end, now: model.now)]
        if !event.calendarTitle.isEmpty { parts.append(event.calendarTitle) }
        return parts.joined(separator: " · ")
    }

    // MARK: The day's schedule

    /// Past this many rows the schedule scrolls rather than growing the
    /// popover past the window.
    private let scheduleVisibleRows = 9
    private let scheduleRowHeight: CGFloat = 24

    /// Today's all-day events, one line: a trip, a holiday, a deadline.
    @ViewBuilder
    private var allDaySection: some View {
        let events = model.allDayEventsToday
        if !events.isEmpty {
            Text("All day: " + events.map(DayNow.displayTitle).joined(separator: ", "))
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("studio.now.allDay")
        }
    }

    /// Today's events by the clock: the one the clock is in washed in the
    /// accent, a line where the clock stands between events, what is behind
    /// in grey. A row opens the event in the Calendar app. A long day
    /// scrolls, starting at now.
    @ViewBuilder
    private var scheduleSection: some View {
        let events = model.timedEventsToday
        let state = model.nowState
        let rows = DayNow.scheduleRows(events: events, state: state, now: model.now)
        if !rows.isEmpty {
            let list = VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .event(let event): scheduleEventRow(event, isNow: state.currentEvent?.occurrenceKey == event.occurrenceKey)
                    case .now: scheduleNowRow
                    }
                }
            }
            Group {
                if rows.count > scheduleVisibleRows {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) { list }
                            .frame(height: CGFloat(scheduleVisibleRows) * scheduleRowHeight * uiZoomScale)
                            .onAppear {
                                let anchor = state.currentEvent?.occurrenceKey ?? DayNowScheduleRow.now.id
                                proxy.scrollTo(anchor, anchor: .center)
                            }
                    }
                } else {
                    list
                }
            }
            .padding(.horizontal, -menuRowInset)
            // A group of its own, so each row keeps its identifier.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.now.schedule")
            Divider()
        }
    }

    private func scheduleEventRow(_ event: AppleCalendarEvent, isNow: Bool) -> some View {
        let isBehind = event.end <= model.now
        return Button {
            AppleCalendarService.openInCalendarApp(event)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Text(DayNow.clockString(event.start))
                    .zoomedSystemFont(size: 11, weight: isNow ? .semibold : .regular)
                    .monospacedDigit()
                    .foregroundStyle(isNow ? Color.accentColor : Color.secondary)
                    .fixedSize()
                Circle()
                    .fill(event.calendarColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? Color.secondary)
                    .frame(width: 6, height: 6)
                Text(DayNow.displayTitle(event))
                    .zoomedSystemFont(size: 12, weight: isNow ? .semibold : .regular)
                    .foregroundStyle(isBehind ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, menuRowInset)
            .frame(height: scheduleRowHeight * uiZoomScale)
            .background(
                RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                    .fill(isNow ? Color.accentColor.opacity(0.13) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0, opacity: 0.1))
        .help("\(DayNow.rangeText(event)) · \(DayNow.displayTitle(event))\(event.calendarTitle.isEmpty ? "" : " · \(event.calendarTitle)")")
        .accessibilityIdentifier("studio.now.schedule.event")
        .id(event.occurrenceKey)
    }

    /// Where the clock stands: the time, and a hairline to the row's end.
    private var scheduleNowRow: some View {
        HStack(spacing: 8) {
            Text(DayPlan.clockString(minute: model.nowMinute))
                .zoomedSystemFont(size: 11, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Capsule()
                .fill(Color.accentColor.opacity(0.7))
                .frame(height: 1.5)
        }
        .padding(.horizontal, menuRowInset)
        .frame(height: scheduleRowHeight * uiZoomScale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now, \(DayPlan.clockString(minute: model.nowMinute))")
        .accessibilityIdentifier("studio.now.schedule.now")
        .id(DayNowScheduleRow.now.id)
    }

    // MARK: The plans above the day

    /// The quarter's objectives and what the week makes progress on, with its
    /// line for today: what the day is for, as Newport plans it (product
    /// owner, 2026-11-07, at this popover: "i need to see the quarterly plan
    /// etc also here"). A plan's heading opens its Page; one not yet planned
    /// starts the chat that plans it.
    @ViewBuilder
    private var plansSection: some View {
        if let plans {
            VStack(alignment: .leading, spacing: 4) {
                planPart(plans.quarter, systemImage: "target", emptyText: "No objectives written yet")
                planPart(plans.week, systemImage: "calendar", emptyText: "Nothing written for this week yet")
                if let today = plans.today {
                    planLine("Today: \(today)", emphasized: true)
                        .accessibilityIdentifier("studio.now.plan.today")
                }
            }
            .padding(.horizontal, -menuRowInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studio.now.plans")
            Divider()
        }
    }

    @ViewBuilder
    private func planPart(_ part: PlanGlance.Part, systemImage: String, emptyText: String) -> some View {
        let isQuarter = part.period.scale == .quarter
        Button {
            if part.exists {
                let period = part.period
                let window = windowState
                Task { await vm.openPlan(period, in: window) }
            } else {
                vm.requestPlanDayChat(request: ReviewSlashCommandParser.planDayRequest(isQuarter ? "quarter" : "week"))
            }
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(part.period.title())
                    .zoomedSystemFont(size: 12.5, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !part.exists {
                    Text("Plan in Chat…")
                        .zoomedSystemFont(size: 11)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, menuRowInset)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0, opacity: 0.1))
        .help(part.exists ? "Open \(part.period.title())" : "Plan \(isQuarter ? "this quarter" : "this week") in a chat")
        .accessibilityIdentifier(isQuarter ? "studio.now.plan.quarter" : "studio.now.plan.week")
        if part.exists {
            if part.lines.isEmpty {
                planLine(emptyText, emphasized: false)
            } else {
                ForEach(Array(part.lines.enumerated()), id: \.offset) { _, line in
                    planLine("• \(line)", emphasized: false)
                }
            }
        }
    }

    /// A line under a plan's heading, in the heading's text column.
    private func planLine(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .zoomedSystemFont(size: 11.5, weight: emphasized ? .medium : .regular)
            .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, menuRowInset + 24)
            .padding(.trailing, menuRowInset)
    }

    // MARK: What can be done

    @ViewBuilder
    private var menuRows: some View {
        let rows = DayNowMenuRow.rows(
            calendarOn: model.isCalendarOn,
            calendarBlocked: model.isCalendarBlocked,
            boutRunning: model.liveBout != nil,
            inEvent: model.nowState.currentEvent != nil
        )
        ForEach(rows, id: \.self) { row in
            menuRow(row)
        }
    }

    @ViewBuilder
    private func menuRow(_ row: DayNowMenuRow) -> some View {
        switch row {
        case .planDay:
            let plansTomorrow = model.nowMinute >= DayPlan.planTomorrowFromHour * 60
            menuRow(
                plansTomorrow ? "Plan Tomorrow in Chat…" : "Plan the Day in Chat…",
                systemImage: "calendar.badge.plus",
                identifier: "studio.now.planDay"
            ) {
                vm.requestPlanDayChat(request: ReviewSlashCommandParser.planDayRequest(plansTomorrow ? "tomorrow" : "today"))
                dismiss()
            }
        case .startBout:
            menuRow("Start Pomodoro Timer…", systemImage: "timer", detail: DayNow.durationText(LearningBout.defaultMinutes), identifier: "studio.now.startBout") {
                dismiss()
                model.requestStart()
            }
        case .openCalendar:
            menuRow("Open Calendar", systemImage: "calendar", identifier: "studio.now.openCalendar") {
                AppleCalendarService.openCalendarApp()
                dismiss()
            }
        case .openPrivacySettings:
            menuRow("Open Privacy & Security…", systemImage: "lock", identifier: "studio.now.privacy") {
                AppleCalendarService.openPrivacySettings()
                dismiss()
            }
        case .turnOnCalendar:
            menuRow("Turn On Calendar…", systemImage: "calendar.badge.checkmark", identifier: "studio.now.turnOnCalendar") {
                PluginsPlace.requestOpen(.appleCalendar)
                dismiss()
            }
        case .activity:
            // The day's record, in this window; its right-click opens it in
            // another, as every opener's does.
            menuRow("Day", systemImage: DayActivityReaderPane.systemImage, identifier: "studio.now.activity") {
                if let windowState {
                    vm.inWindow(windowState) { vm.openDayPane() }
                } else {
                    vm.openDayPane()
                }
                dismiss()
            }
            .help("Your calendar on a clock")
            .opensInOtherWindow(StudioWindowDestination.activity)
        }
    }

    /// How far a menu row's wash reaches past the popover's text column, so
    /// the icons line up with the heading and the wash still has room.
    private let menuRowInset: CGFloat = 8

    private func menuRow(
        _ title: String,
        systemImage: String,
        detail: String? = nil,
        identifier: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text(title)
                    .zoomedSystemFont(size: 13)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .zoomedSystemFont(size: 11)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, menuRowInset)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0, opacity: 0.1))
        .accessibilityIdentifier(identifier)
    }

    // MARK: Plumbing

    private func action(_ title: String, identifier: String, prominent: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .zoomedSystemFont(size: 11, weight: .medium)
                .padding(.horizontal, StudioDesign.Spacing.small)
                .padding(.vertical, StudioDesign.Spacing.xSmall)
        }
        .buttonStyle(.hoverWash(cornerRadius: StudioDesign.Radius.control, inset: 0, opacity: 0.14))
        .background(
            RoundedRectangle(cornerRadius: StudioDesign.Radius.control, style: .continuous)
                .fill(Color.accentColor.opacity(prominent ? 0.18 : 0.1))
        )
        .accessibilityIdentifier(identifier)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
