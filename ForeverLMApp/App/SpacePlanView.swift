#if os(macOS)
import EventKit
import SwiftUI
import os

// MARK: - The Plan in the Space
//
// Planning at three scales, as Cal Newport teaches it (docs-site/plan.md):
// the quarter's bigger picture, objectives and strategies are a Page
// (`PlanQuarter`); the week and the day are the Mac's Calendar, planned
// onto it with the quarter's plan in view and moved around as they go
// (product owner, 2026-11-07: "weekly planning is just putting stuff on the
// calendar for the week; we can always move it around").
//
// This place ties the three together by reading, never by a week record
// (product owner, 2026-11-07, of the flat list of quarters: "for each
// quarter we have weekly plans, and for each weekly plan we have daily
// plans … where we can click into it and then see the weekly plans"). A
// quarter opens in place to its objectives, each in a colour with the hours
// the calendar gives it, and its weeks, each a strip of seven days coloured
// by the objectives their blocks serve; a week opens to its days and their
// blocks under what the week is to deliver (the task lines of the quarter's
// Page, ticked here; product owner, 2026-11-13, of the calendar glyph's
// popover that used to show them: "week and quarter can be on a separate
// plan page"), and a day opens the Day pane. The quarter's Page opens from its
// Objectives. Its pill starts the chat that plans a quarter, a week or a day.

/// The Space's Plan place: the place head (title and the Plan pill), a
/// stepper through years, and the year's quarters, one of them open to its
/// objectives and weeks.
struct SpacePlanPage: View {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "SpacePlan")
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    /// The year whose quarters are listed; nil for this year.
    @State private var shownYear: Int?
    /// The quarter open to its weeks; this quarter at first, none once closed.
    @State private var openQuarter: PlanQuarter? = PlanQuarter.containing(Date())
    /// The week open to its days, by its Monday; this week at first.
    @State private var openWeek: Date? = PlanQuarterWeeks.weekCalendar().dateInterval(of: .weekOfYear, for: Date())?.start
    /// The open quarter as last read, and the read's failure.
    @State private var overview: PlanOverview?
    @State private var loadError: String?
    /// Ticks clicked and not yet read back from the quarter's Page, by
    /// deliverable, so a click shows at once; and a tick's failed save.
    @State private var pendingTicks: [String: Bool] = [:]
    @State private var tickError: String?
    /// Bumped when the calendar changes under the place, to read it again.
    @State private var calendarChanges = 0
    /// How the open week's events look in the Calendar app: each one's
    /// calendar colour, its group's colour, and its link into the app.
    @State private var eventLooks: [String: PlanEventLook] = [:]
    /// The learner's groups and every calendar's colour, so an objective
    /// that names a group wears its colour (`CalendarGroup`).
    @State private var groupLook = PlanGroupLook()
    /// A Goal is made from Plan now; its deadline places it in one quarter.
    @State private var goalQuarter: PlanQuarter?

    private var isOwnLibrary: Bool { vm.activeTeamID == nil }
    private var thisQuarter: PlanQuarter { PlanQuarter.containing(Date()) }
    private var year: Int { shownYear ?? thisQuarter.year }
    private var weekCalendar: Calendar { PlanQuarterWeeks.weekCalendar() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    SpacePlaceTitle(title: SpaceDestination.plan.title)
                    Spacer(minLength: 12)
                    if isOwnLibrary, !vm.isActiveLibraryReadOnly {
                        SpaceDarkPillMenu(title: "Plan", sections: planMenuSections)
                            .accessibilityIdentifier("space.plan.start")
                    }
                }
                if isOwnLibrary {
                    HStack(spacing: 8) {
                        Spacer(minLength: 8)
                        stepper
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(1...4, id: \.self) { number in
                            let quarter = PlanQuarter(year: year, quarter: number)
                            row(quarter)
                            if openQuarter == quarter {
                                quarterDetail(quarter)
                                    .padding(.leading, 30)
                                    .padding(.trailing, 10)
                                    .padding(.top, 6)
                                    .padding(.bottom, 18)
                            }
                        }
                    }
                    .padding(.top, 4)
                } else {
                    SpaceEmptyLine(systemImage: SpaceDestination.plan.symbolName, text: "Plans are in your own library")
                        .frame(maxWidth: .infinity)
                        .padding(.top, SpacePlaceMetrics.emptyTopPadding)
                }
            }
            .spacePlaceColumn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: readKey) { await read() }
        .task(id: lookKey) { await readLooks() }
        .task {
            await vm.loadLearningGoals()
            if !vm.hasLoadedArtifactsOnce { await vm.loadArtifacts() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in calendarChanges += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in calendarChanges += 1 }
        .sheet(item: $goalQuarter) { quarter in
            SetGoalSheet(presetDeadline: defaultGoalDeadline(in: quarter)) { title, deadline, notebookID, artifactID in
                Task {
                    await vm.createGoal(title: title, deadline: deadline, notebookID: notebookID, artifactID: artifactID)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.plan")
    }

    // MARK: Reading the open quarter

    /// What the open quarter's reading depends on: the quarter, its Page's
    /// last edit and the calendar's changes.
    private var readKey: String {
        guard isOwnLibrary, let quarter = openQuarter else { return "" }
        let edited = vm.artifacts.first { $0.id == quarter.id }?.updatedAt.timeIntervalSince1970 ?? 0
        return "\(quarter.key)|\(edited)|\(calendarChanges)"
    }

    private var lookKey: String {
        "\(openWeek?.timeIntervalSince1970 ?? 0)|\(calendarChanges)"
    }

    /// The groups and calendar colours, and the open week's events as the
    /// Calendar app draws them. Read apart from the quarter, so the quarter's
    /// reading stays the same on the phone.
    private func readLooks() async {
        let service = AppleCalendarService.shared
        guard isOwnLibrary, service.isConnected else {
            eventLooks = [:]
            groupLook = PlanGroupLook()
            return
        }
        let groups = service.groups
        let calendars: [AppleCalendarListEntry]
        do {
            calendars = try await service.calendars()
        } catch {
            Self.logger.error("Reading the calendars failed: \(error.localizedDescription, privacy: .public)")
            calendars = []
        }
        var colors: [String: CalendarColor] = [:]
        for calendar in calendars { colors[calendar.id] = calendar.color }
        var looks: [String: PlanEventLook] = [:]
        if let monday = openWeek, let end = weekCalendar.date(byAdding: .day, value: 7, to: monday) {
            let events: [AppleCalendarEvent]
            do {
                events = try await service.shownEvents(from: monday, to: end)
            } catch {
                Self.logger.error("Reading the week's calendar events failed: \(error.localizedDescription, privacy: .public)")
                events = []
            }
            for event in events {
                let group = CalendarGroups.group(calendarID: event.calendarID, title: event.title, notes: event.notes, in: groups)
                looks[event.occurrenceKey] = PlanEventLook(
                    calendarColor: event.calendarColor,
                    groupColor: group.flatMap { colors[$0.calendarID] },
                    calendarAppURL: event.calendarAppURL
                )
            }
        }
        guard !Task.isCancelled else { return }
        eventLooks = looks
        groupLook = PlanGroupLook(groups: groups, colors: colors)
    }

    private func read() async {
        guard isOwnLibrary, let quarter = openQuarter else { return }
        do {
            let read = try await vm.loadPlanOverview(quarter)
            guard !Task.isCancelled, openQuarter == quarter else { return }
            overview = read
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }

    // MARK: The quarters

    private func row(_ quarter: PlanQuarter) -> some View {
        let page = vm.artifacts.first { $0.id == quarter.id }
        let isNow = quarter == thisQuarter
        let isOpen = openQuarter == quarter
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                openQuarter = isOpen ? nil : quarter
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 10, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(quarter.title)
                        .zoomedSystemFont(size: 13.5, weight: isNow ? .semibold : .medium)
                        .foregroundStyle(.primary)
                    Text(quarter.rangeText())
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if isNow {
                    nowTag("This quarter")
                }
                Text(page.map { "Edited \(SpaceDateText.short($0.updatedAt))" } ?? "Not planned")
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(page == nil ? HierarchicalShapeStyle.tertiary : .secondary)
                    .monospacedDigit()
                    .frame(minWidth: 84, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 8, inset: 0))
        .contextMenu {
            Button(page == nil ? "Write \(quarter.title)'s Plan" : "Open \(quarter.title)'s Plan") { openPage(quarter) }
                .disabled(page == nil && vm.isActiveLibraryReadOnly)
        }
        .accessibilityIdentifier("space.plan.\(quarter.key)")
    }

    private func nowTag(_ text: String) -> some View {
        Text(text)
            .zoomedSystemFont(size: 11, weight: .medium)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }

    private func openPage(_ quarter: PlanQuarter) {
        Task { await vm.openPlan(quarter, in: windowState) }
    }

    // MARK: An open quarter

    @ViewBuilder
    private func quarterDetail(_ quarter: PlanQuarter) -> some View {
        let shown = overview?.quarter == quarter ? overview : nil
        VStack(alignment: .leading, spacing: 18) {
            objectivesCard(quarter, shown)
            goalsSection(quarter)
            if let loadError, shown == nil {
                Text("Could not read \(quarter.title): \(loadError)")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
            } else if let shown {
                weeksSection(shown)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Every structured Goal is visible from Planning. Its deadline is the
    /// single source of truth for which quarter owns it; moving the deadline
    /// moves the row, with no hidden list or second plan link to maintain.
    private func goalsSection(_ quarter: PlanQuarter) -> some View {
        let goals = vm.allGoals.filter { quarter.contains($0.endAt) }
        return VStack(alignment: .leading, spacing: StudioDesign.Spacing.small) {
            HStack(spacing: 8) {
                sectionLabel("Goals")
                Spacer(minLength: 8)
                if !vm.isActiveLibraryReadOnly, defaultGoalDeadline(in: quarter) != nil {
                    Button("New Goal", systemImage: "plus") { goalQuarter = quarter }
                        .buttonStyle(.hoverWash)
                        .accessibilityIdentifier("space.plan.newGoal")
                }
            }
            .padding(.horizontal, 10)

            if goals.isEmpty {
                Text("No goals this quarter")
                    .zoomedSystemFont(size: 12.5)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(goals) { goal in
                    GoalRow(goal: goal)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.plan.goals")
    }

    /// Tomorrow for this quarter, or its first day when planning ahead. A
    /// past quarter offers no impossible new deadline.
    private func defaultGoalDeadline(in quarter: PlanQuarter) -> Date? {
        let calendar = PlanQuarter.gregorian()
        let today = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let start = quarter.start(), let end = quarter.end(), end > tomorrow else { return nil }
        return max(start, tomorrow)
    }

    /// The quarter's objectives, each in its colour with the hours its
    /// weeks give it; the whole card opens the Page.
    private func objectivesCard(_ quarter: PlanQuarter, _ shown: PlanOverview?) -> some View {
        let canWrite = !vm.isActiveLibraryReadOnly
        let exists = shown?.exists ?? vm.artifacts.contains { $0.id == quarter.id }
        let objectives = shown?.objectives ?? []
        let minutes = shown?.minutesByObjective ?? [:]
        return Button {
            openPage(quarter)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    sectionLabel("Objectives")
                    Spacer(minLength: 8)
                    Text(exists ? "Open Plan" : "Write Plan")
                        .zoomedSystemFont(size: 11.5, weight: .medium)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right")
                        .zoomedSystemFont(size: 9.5, weight: .semibold)
                        .foregroundStyle(.tertiary)
                }
                if objectives.isEmpty {
                    Text(exists ? "No objectives written yet" : "\(quarter.title) has no plan yet")
                        .zoomedSystemFont(size: 12.5)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(objectives.enumerated()), id: \.offset) { index, objective in
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Circle()
                                .fill(objectiveColor(index))
                                .frame(width: 7, height: 7)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            Text(objective)
                                .zoomedSystemFont(size: 12.5)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 12)
                            Text(minutes[index].map(PlanQuarterWeeks.hoursText) ?? "—")
                                .zoomedSystemFont(size: 11.5)
                                .foregroundStyle(minutes[index] == nil ? HierarchicalShapeStyle.tertiary : .secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.hoverWash(cornerRadius: 10, inset: 0))
        .disabled(!exists && !canWrite)
        .help(exists ? "Open \(quarter.title)'s plan" : "Write \(quarter.title)'s plan")
        .accessibilityIdentifier("space.plan.objectives")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .zoomedSystemFont(size: 10.5, weight: .semibold)
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }

    // MARK: The weeks

    @ViewBuilder
    private func weeksSection(_ shown: PlanOverview) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Weeks")
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            if !shown.calendarOn {
                Text("Turn on the Mac's Calendar in Plugins to see each week's plan here.")
                    .zoomedSystemFont(size: 12)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            ForEach(shown.weeks) { week in
                weekRow(week)
                if openWeek == week.start {
                    weekDeliverables(week, in: shown)
                        .padding(.leading, 30)
                    weekDays(week)
                        .padding(.leading, 30)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private func weekRow(_ week: PlanWeek) -> some View {
        let now = Date()
        let isThisWeek = week.contains(now, calendar: weekCalendar)
        let isNextWeek = weekCalendar.date(byAdding: .day, value: 7, to: now).map { week.contains($0, calendar: weekCalendar) } ?? false
        let isPast = !isThisWeek && week.start < now
        let isOpen = openWeek == week.start
        let planned = week.plannedBlocks.count
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                openWeek = isOpen ? nil : week.start
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                Text(Self.weekRangeText(week, calendar: weekCalendar))
                    .zoomedSystemFont(size: 12.5, weight: isThisWeek ? .semibold : .regular)
                    .foregroundStyle(isPast ? HierarchicalShapeStyle.secondary : .primary)
                    .monospacedDigit()
                    .frame(minWidth: 110, alignment: .leading)
                if isThisWeek {
                    nowTag("This week")
                } else if isNextWeek {
                    Text("Next week")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                weekStrip(week)
                Text(planned == 0 ? "Not planned" : "\(planned) \(planned == 1 ? "block" : "blocks") · \(PlanQuarterWeeks.hoursText(week.plannedMinutes))")
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(planned == 0 ? HierarchicalShapeStyle.tertiary : .secondary)
                    .monospacedDigit()
                    .frame(minWidth: 110, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .opacity(isPast && !isOpen ? 0.75 : 1)
        .accessibilityIdentifier("space.plan.week.\(PlanDate.string(for: week.start, calendar: weekCalendar))")
    }

    /// The week's seven days as small columns, each filled by the hours its
    /// blocks give the quarter, in their objectives' colours (a block that
    /// links the plan but names no objective in grey). Eight hours fill one.
    private func weekStrip(_ week: PlanWeek) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(week.days) { day in
                dayColumn(day)
            }
        }
        .frame(height: Self.stripHeight)
        .accessibilityHidden(true)
    }

    private static let stripHeight: CGFloat = 18
    private static let fullDayMinutes = 8 * 60

    private func dayColumn(_ day: PlanDay) -> some View {
        let planned = day.blocks.filter(\.servesQuarter)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            VStack(spacing: 0) {
                ForEach(planned.reversed()) { block in
                    Rectangle()
                        .fill(blockColor(block))
                        .frame(height: Self.stripHeight * min(1, CGFloat(block.minutes) / CGFloat(Self.fullDayMinutes)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .frame(width: 7, height: Self.stripHeight)
        .clipped()
    }

    // MARK: A week

    /// What the open week is to deliver: each task line of the quarter's
    /// Page with its box, its due day, and its objective's colour. A box
    /// ticks the line in the Page (`setPlanDeliverable`).
    @ViewBuilder
    private func weekDeliverables(_ week: PlanWeek, in shown: PlanOverview) -> some View {
        let items = shown.deliverables[week.start] ?? []
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items) { deliverable in
                    deliverableRow(deliverable, week: week, in: shown)
                }
                if let tickError {
                    Text(tickError)
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("space.plan.week.deliverables")
        }
    }

    private func deliverableRow(_ deliverable: PlanDeliverable, week: PlanWeek, in shown: PlanOverview) -> some View {
        let isDone = pendingTicks[deliverable.id] ?? deliverable.isDone
        let objective = deliverable.objective.flatMap { shown.objectives.indices.contains($0) ? $0 : nil }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                toggle(deliverable, to: !isDone, week: week, quarter: shown.quarter)
            } label: {
                Image(systemName: isDone ? "checkmark.square.fill" : "square")
                    .zoomedSystemFont(size: 13)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverWash(cornerRadius: 5, inset: 0))
            .disabled(vm.isActiveLibraryReadOnly)
            .help(isDone ? "Mark as not delivered" : "Mark as delivered")
            .accessibilityLabel(isDone ? "Delivered" : "Not delivered")
            .accessibilityIdentifier("space.plan.deliverable.tick")
            Text(deliverable.text)
                .zoomedSystemFont(size: 12.5)
                .strikethrough(isDone)
                .foregroundStyle(isDone ? Color.secondary : Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let objective {
                Circle()
                    .fill(objectiveColor(objective))
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .help(shown.objectives[objective])
                    .accessibilityLabel(shown.objectiveNames[objective])
            }
            Spacer(minLength: 12)
            if let due = deliverable.due {
                Text(due)
                    .zoomedSystemFont(size: 11.5)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.plan.deliverable")
    }

    private func toggle(_ deliverable: PlanDeliverable, to done: Bool, week: PlanWeek, quarter: PlanQuarter) {
        pendingTicks[deliverable.id] = done
        Task {
            do {
                try await vm.setPlanDeliverable(deliverable, done: done, weekOf: week.start, quarter: quarter)
                tickError = nil
                await read()
            } catch {
                tickError = "Could not save the tick in \(quarter.title): \(error.localizedDescription)"
            }
            pendingTicks[deliverable.id] = nil
        }
    }

    /// An open week drawn as the Calendar app's week view draws it, every
    /// event in its calendar's colour (a group's work in its group's), with
    /// the way into the Calendar app itself.
    private func weekDays(_ week: PlanWeek) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button {
                    openInCalendarApp(week)
                } label: {
                    Label("Open in Calendar", systemImage: "calendar")
                        .zoomedSystemFont(size: 11.5, weight: .medium)
                }
                .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                .foregroundStyle(.secondary)
                .help("Shows this week in the Calendar app")
                .accessibilityIdentifier("space.plan.week.openCalendar")
            }
            PlanWeekGrid(
                week: week,
                calendar: weekCalendar,
                color: gridColor,
                openDay: openDay,
                openBlock: openBlock
            )
        }
    }

    /// The Calendar app, at one of the week's events so it shows that week;
    /// with none, the app as it is. (Calendar takes no link to a date, and
    /// scripting it needs an Apple Events grant ForeverLM does not ask for.)
    private func openInCalendarApp(_ week: PlanWeek) {
        let now = Date()
        let blocks = week.days.flatMap(\.blocks)
        let shown = blocks.first { $0.end > now } ?? blocks.first
        if let url = shown.flatMap({ eventLooks[$0.id]?.calendarAppURL }) {
            NSWorkspace.shared.open(url)
        } else {
            AppleCalendarService.openCalendarApp()
        }
    }

    private func openBlock(_ block: PlanBlock) {
        if let url = eventLooks[block.id]?.calendarAppURL {
            NSWorkspace.shared.open(url)
        } else {
            openDay(PlanDate.string(for: block.start, calendar: weekCalendar))
        }
    }

    private func openDay(_ date: String) {
        DayModel.shared.select(date: date)
        if let windowState {
            vm.inWindow(windowState) { vm.openDayPane() }
        } else {
            vm.openDayPane()
        }
    }

    // MARK: Words and colours

    /// The objectives' colours, by their place in the plan.
    private static let objectivePalette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

    static func objectiveColor(_ index: Int) -> Color {
        objectivePalette[index % objectivePalette.count]
    }

    /// An objective's colour: its group's calendar colour when it names a
    /// group ("Guild grant draft" is the Guild's), else its family's by
    /// place, so two objectives of one family share a colour
    /// (`PlanOverview.colorSlot`).
    private func objectiveColor(_ index: Int) -> Color {
        let objectives = overview?.objectives ?? []
        guard objectives.indices.contains(index),
              let color = groupLook.color(naming: objectives[index]) else {
            return Self.objectiveColor(overview?.colorSlot(index) ?? index)
        }
        return Color(cgColor: color.cgColor)
    }

    /// A planned block's colour in the strip and the day list: its group's,
    /// else its objective's.
    private func blockColor(_ block: PlanBlock) -> Color {
        if let color = eventLooks[block.id]?.groupColor ?? groupLook.color(naming: block.title) {
            return Color(cgColor: color.cgColor)
        }
        return block.objective.map(objectiveColor) ?? Color.secondary.opacity(0.6)
    }

    /// A block in the week grid: its group's colour, else its objective's
    /// when it serves the quarter, else its own calendar's, as the Calendar
    /// app draws it.
    private func gridColor(_ block: PlanBlock) -> Color {
        if let color = eventLooks[block.id]?.groupColor { return Color(cgColor: color.cgColor) }
        if block.servesQuarter { return blockColor(block) }
        if let color = eventLooks[block.id]?.calendarColor { return Color(cgColor: color.cgColor) }
        return Color.secondary
    }

    /// "Nov 9 – 15", or "Sep 28 – Oct 4" across a month.
    static func weekRangeText(_ week: PlanWeek, calendar: Calendar) -> String {
        guard let last = calendar.date(byAdding: .day, value: 6, to: week.start) else { return "" }
        let first = DateFormatter()
        first.calendar = calendar
        first.timeZone = calendar.timeZone
        first.setLocalizedDateFormatFromTemplate("MMMd")
        let sameMonth = calendar.component(.month, from: week.start) == calendar.component(.month, from: last)
        let end = DateFormatter()
        end.calendar = calendar
        end.timeZone = calendar.timeZone
        end.setLocalizedDateFormatFromTemplate(sameMonth ? "d" : "MMMd")
        return "\(first.string(from: week.start)) – \(end.string(from: last))"
    }

    /// "Mon 9".
    static func dayText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEd")
        return formatter.string(from: date)
    }

    /// "9:00 AM" or "09:00", as the Mac tells time.
    static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Moving through years

    /// ‹ 2026 ›, and a way back to this year when away from it.
    private var stepper: some View {
        HStack(spacing: 4) {
            if year != thisQuarter.year {
                Button("This Year") { shownYear = nil }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: -4))
                    .zoomedSystemFont(size: 12, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help("Previous year")
            Text(String(year))
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .monospacedDigit()
                .textSelection(.disabled)
                .frame(minWidth: 44)
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help("Next year")
        }
    }

    private func step(_ count: Int) {
        let next = year + count
        shownYear = next == thisQuarter.year ? nil : next
    }

    // MARK: Planning with the chat

    /// The Plan pill's card: the chat that plans the quarter (its Page), the
    /// week or the day (the calendar), each the `/plan` command.
    private var planMenuSections: [[SpaceMenuItem]] {
        let plansTomorrow = Calendar.current.component(.hour, from: Date()) >= DayPlan.planTomorrowFromHour
        return [
            [
                SpaceMenuItem(id: "space.plan.quarter", title: "Plan This Quarter", systemImage: "target") {
                    startPlanningChat("quarter")
                },
                SpaceMenuItem(id: "space.plan.week", title: "Plan This Week", systemImage: "calendar") {
                    startPlanningChat("week")
                },
                SpaceMenuItem(
                    id: "space.plan.day",
                    title: plansTomorrow ? "Plan Tomorrow" : "Plan Today",
                    systemImage: "calendar.day.timeline.left"
                ) {
                    startPlanningChat(plansTomorrow ? "tomorrow" : "today")
                },
            ],
        ]
    }

    private func startPlanningChat(_ argument: String) {
        vm.requestPlanDayChat(request: ReviewSlashCommandParser.planDayRequest(argument))
    }
}
/// How one event of the open week looks in the Calendar app.
struct PlanEventLook: Equatable {
    var calendarColor: CalendarColor?
    /// Its group's colour: the group whose calendar holds it, or whose words
    /// it names.
    var groupColor: CalendarColor?
    var calendarAppURL: URL?
}

/// The learner's groups with every calendar's colour.
struct PlanGroupLook: Equatable {
    var groups: [CalendarGroup] = []
    var colors: [String: CalendarColor] = [:]

    /// The colour of the group `text` names; nil when it names none.
    func color(naming text: String) -> CalendarColor? {
        CalendarGroups.group(title: text, notes: nil, in: groups).flatMap { colors[$0.calendarID] }
    }
}

/// A week as the Calendar app's week view draws it: seven columns of hours,
/// each event a block in its colour at its time, side by side where events
/// overlap. A day's heading opens it in the Day pane; a block opens in the
/// Calendar app.
struct PlanWeekGrid: View {
    let week: PlanWeek
    let calendar: Calendar
    let color: (PlanBlock) -> Color
    let openDay: (String) -> Void
    let openBlock: (PlanBlock) -> Void

    private static let hourHeight: CGFloat = 30
    private static let gutter: CGFloat = 40
    private static let headerHeight: CGFloat = 24

    var body: some View {
        let hours = hourRange
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gutter, height: Self.headerHeight)
                ForEach(week.days) { day in
                    let isToday = PlanDate.string(for: Date(), calendar: calendar) == day.date
                    Button {
                        openDay(day.date)
                    } label: {
                        Text(SpacePlanPage.dayText(day.start, calendar: calendar))
                            .zoomedSystemFont(size: 11.5, weight: isToday ? .semibold : .medium)
                            .foregroundStyle(isToday ? Color.accentColor : .secondary)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: Self.headerHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
                    .help("Open \(SpacePlanPage.dayText(day.start, calendar: calendar)) in Day")
                    .accessibilityIdentifier("space.plan.day.\(day.date)")
                }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(hours, id: \.self) { hour in
                        Text(Self.hourText(hour, calendar: calendar))
                            .zoomedSystemFont(size: 9.5)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .frame(width: Self.gutter - 6, height: Self.hourHeight, alignment: .topTrailing)
                            .offset(y: -6)
                    }
                }
                .frame(width: Self.gutter, alignment: .trailing)
                ForEach(week.days) { day in
                    dayColumn(day, hours: hours)
                }
            }
            .frame(height: CGFloat(hours.count) * Self.hourHeight)
            .clipped()
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.plan.weekGrid")
    }

    /// The hours drawn: eight in the morning to seven at night, stretched to
    /// hold every event of the week.
    private var hourRange: Range<Int> {
        var first = 8
        var last = 19
        for day in week.days {
            for block in day.blocks {
                first = min(first, minute(of: block.start, in: day) / 60)
                last = max(last, Int((Double(endMinute(of: block, in: day)) / 60).rounded(.up)))
            }
        }
        return max(0, first)..<min(24, max(last, first + 1))
    }

    private func minute(of date: Date, in day: PlanDay) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return date < day.start ? 0 : (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The minute a block ends, held to its own day.
    private func endMinute(of block: PlanBlock, in day: PlanDay) -> Int {
        guard let next = calendar.date(byAdding: .day, value: 1, to: day.start), block.end < next else { return 24 * 60 }
        return max(minute(of: block.start, in: day) + 15, minute(of: block.end, in: day))
    }

    private func dayColumn(_ day: PlanDay, hours: Range<Int>) -> some View {
        let lanes = Self.lanes(day.blocks.map { (id: $0.id, start: $0.start, end: $0.end) })
        let top = hours.lowerBound * 60
        let isToday = PlanDate.string(for: Date(), calendar: calendar) == day.date
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Path { path in
                    for index in 0...hours.count {
                        let y = CGFloat(index) * Self.hourHeight
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                }
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                if isToday {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.04))
                }
                ForEach(day.blocks) { block in
                    let lane = lanes[block.id] ?? (index: 0, count: 1)
                    let laneWidth = width / CGFloat(lane.count)
                    let start = minute(of: block.start, in: day)
                    let y = CGFloat(start - top) / 60 * Self.hourHeight
                    let height = max(14, CGFloat(endMinute(of: block, in: day) - start) / 60 * Self.hourHeight)
                    blockView(block, height: height)
                        .frame(width: max(8, laneWidth - 3), height: height - 2)
                        .offset(x: CGFloat(lane.index) * laneWidth + 2, y: y + 1)
                }
                if isToday {
                    let now = minute(of: Date(), in: day)
                    if now >= top, now < hours.upperBound * 60 {
                        Rectangle()
                            .fill(Color.red.opacity(0.8))
                            .frame(width: width, height: 1.5)
                            .offset(y: CGFloat(now - top) / 60 * Self.hourHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func blockView(_ block: PlanBlock, height: CGFloat) -> some View {
        let tint = color(block)
        let time = "\(SpacePlanPage.timeText(block.start)) – \(SpacePlanPage.timeText(block.end))"
        return Button {
            openBlock(block)
        } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(block.title)
                        .zoomedSystemFont(size: 10.5, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(height >= 40 ? 2 : 1)
                    if height >= 44 {
                        Text(time)
                            .zoomedSystemFont(size: 9.5)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, height >= 24 ? 2 : 0)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tint.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(block.title)\n\(time)")
        .accessibilityLabel("\(block.title), \(time)")
    }

    /// Side-by-side lanes for overlapping events, as the Calendar app lays
    /// them: each event takes the first lane free at its start, and every
    /// event of an overlapping run shares the run's lane count.
    static func lanes(_ events: [(id: String, start: Date, end: Date)]) -> [String: (index: Int, count: Int)] {
        let sorted = events.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var result: [String: (index: Int, count: Int)] = [:]
        var run: [(id: String, lane: Int)] = []
        var laneEnds: [Date] = []
        var runEnd = Date.distantPast
        func closeRun() {
            for member in run { result[member.id] = (member.lane, max(1, laneEnds.count)) }
            run = []
            laneEnds = []
        }
        for event in sorted {
            if event.start >= runEnd { closeRun() }
            let end = max(event.end, event.start.addingTimeInterval(15 * 60))
            if let free = laneEnds.firstIndex(where: { $0 <= event.start }) {
                laneEnds[free] = end
                run.append((event.id, free))
            } else {
                laneEnds.append(end)
                run.append((event.id, laneEnds.count - 1))
            }
            runEnd = max(runEnd, end)
        }
        closeRun()
        return result
    }

    /// "9 AM" or "09:00", as the Mac tells time.
    static func hourText(_ hour: Int, calendar: Calendar) -> String {
        guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else { return "" }
        return date.formatted(.dateTime.hour())
    }
}
#endif
