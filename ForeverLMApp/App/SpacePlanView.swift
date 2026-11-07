#if os(macOS)
import EventKit
import SwiftUI

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
// blocks, and a day opens the Day pane. The quarter's Page opens from its
// Objectives. Its pill starts the chat that plans a quarter, a week or a day.

/// The Space's Plan place: the place head (title and the Plan pill), a
/// stepper through years, and the year's quarters, one of them open to its
/// objectives and weeks.
struct SpacePlanPage: View {
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
    /// Bumped when the calendar changes under the place, to read it again.
    @State private var calendarChanges = 0

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
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in calendarChanges += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConnectionChanged)) { _ in calendarChanges += 1 }
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
                                .fill(Self.objectiveColor(index))
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
                        .fill(Self.blockColor(block))
                        .frame(height: Self.stripHeight * min(1, CGFloat(block.minutes) / CGFloat(Self.fullDayMinutes)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .frame(width: 7, height: Self.stripHeight)
        .clipped()
    }

    // MARK: A week's days

    private func weekDays(_ week: PlanWeek) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(week.days) { day in
                dayRow(day)
            }
        }
    }

    /// A day: its name, and its blocks by time; a click opens it in the
    /// Day pane. Blocks toward the quarter lead in their objective's colour,
    /// the rest of the calendar (meetings, errands) stays grey.
    private func dayRow(_ day: PlanDay) -> some View {
        let isToday = PlanDate.string(for: Date(), calendar: weekCalendar) == day.date
        return Button {
            openDay(day.date)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Self.dayText(day.start, calendar: weekCalendar))
                    .zoomedSystemFont(size: 12, weight: isToday ? .semibold : .medium)
                    .foregroundStyle(isToday ? Color.accentColor : .secondary)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    if day.blocks.isEmpty {
                        Text("Nothing on the calendar")
                            .zoomedSystemFont(size: 12)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(day.blocks) { block in
                        blockLine(block)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverWash(cornerRadius: 7, inset: 0))
        .help("Open \(Self.dayText(day.start, calendar: weekCalendar)) in Day")
        .accessibilityIdentifier("space.plan.day.\(day.date)")
    }

    private func blockLine(_ block: PlanBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeText(block.start))
                .zoomedSystemFont(size: 11.5)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 58, alignment: .leading)
            Circle()
                .fill(block.servesQuarter ? Self.blockColor(block) : Color.clear)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(block.title)
                .zoomedSystemFont(size: 12.5)
                .foregroundStyle(block.servesQuarter ? HierarchicalShapeStyle.primary : .secondary)
                .lineLimit(1)
            Text(PlanQuarterWeeks.hoursText(block.minutes))
                .zoomedSystemFont(size: 11)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
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

    static func blockColor(_ block: PlanBlock) -> Color {
        block.objective.map(objectiveColor) ?? Color.secondary.opacity(0.6)
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
#endif
