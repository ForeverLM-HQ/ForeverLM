#if os(macOS)
import SwiftUI

// MARK: - The Plan in the Space
//
// Planning at three scales, as Cal Newport teaches it (docs-site/plan.md): a
// quarter's big picture, objectives and strategies, a week's progress with
// the quarter's plan in view, and the day in time blocks with the week's plan
// in view. A quarter's and a week's plan are Pages (`PlanPeriod`); the day is
// the Mac's Calendar, which the `/plan` chat fills. This place lists the
// quarters of a year or the weeks of a quarter, each opening its Page (made
// from its template the first time), and its pill starts the planning chat
// for any of the three.

/// The Space's Plan place: the place head (title and the Plan pill), the
/// Quarter and Week scopes with a stepper through years or quarters, and the
/// periods as rows.
struct SpacePlanPage: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    /// This Mac's last scope, as the Board remembers its lens.
    @AppStorage("space.planScale") private var scaleRaw = PlanScale.quarter.rawValue
    /// The year whose quarters are listed; nil for this year.
    @State private var shownYear: Int?
    /// The quarter whose weeks are listed; nil for this quarter.
    @State private var shownQuarter: PlanPeriod?

    private var scale: PlanScale { PlanScale(rawValue: scaleRaw) ?? .quarter }
    private var isOwnLibrary: Bool { vm.activeTeamID == nil }

    private var thisQuarter: PlanPeriod { PlanPeriod.containing(Date(), scale: .quarter) }
    private var thisWeek: PlanPeriod { PlanPeriod.containing(Date(), scale: .week) }
    private var thisYear: Int {
        if case .quarter(let year, _) = thisQuarter { return year }
        return Calendar.current.component(.year, from: Date())
    }

    private var year: Int { shownYear ?? thisYear }
    private var quarter: PlanPeriod { shownQuarter ?? thisQuarter }

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
                HStack(spacing: 8) {
                    ForEach(PlanScale.allCases) { option in
                        SpaceScopePill(title: option.title, isSelected: scale == option) {
                            scaleRaw = option.rawValue
                        }
                    }
                    Spacer(minLength: 8)
                    if isOwnLibrary { stepper }
                }

                if !isOwnLibrary {
                    SpaceEmptyLine(systemImage: SpaceDestination.plan.symbolName, text: "Plans are in your own library")
                        .frame(maxWidth: .infinity)
                        .padding(.top, SpacePlaceMetrics.emptyTopPadding)
                } else {
                    rows
                        .padding(.top, 4)
                }
            }
            .spacePlaceColumn()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.plan")
    }

    // MARK: The list

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch scale {
            case .quarter:
                ForEach(1...4, id: \.self) { number in
                    row(.quarter(year: year, quarter: number), isNow: PlanPeriod.quarter(year: year, quarter: number) == thisQuarter)
                }
            case .week:
                // The week is planned with its quarter's plan in view, so the
                // quarter leads its weeks.
                row(quarter, isNow: quarter == thisQuarter, subtitle: "The quarter's plan")
                Divider()
                    .padding(.vertical, 6)
                ForEach(quarter.weeks()) { week in
                    row(week, isNow: week == thisWeek)
                }
            }
        }
    }

    private func row(_ period: PlanPeriod, isNow: Bool, subtitle: String? = nil) -> some View {
        let page = vm.artifacts.first { $0.id == period.id }
        return Button {
            Task { await vm.openPlan(period, in: windowState) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(period.title())
                        .zoomedSystemFont(size: 13.5, weight: isNow ? .semibold : .medium)
                        .foregroundStyle(.primary)
                    Text(subtitle ?? period.rangeText())
                        .zoomedSystemFont(size: 11.5)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if isNow {
                    Text(period.scale == .quarter ? "This quarter" : "This week")
                        .zoomedSystemFont(size: 11, weight: .medium)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
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
        // A period with no Page yet makes one, which a read-only library cannot.
        .disabled(page == nil && vm.isActiveLibraryReadOnly)
        .accessibilityIdentifier("space.plan.\(period.key)")
    }

    // MARK: Moving through time

    /// ‹ 2026 › over the quarters, ‹ Q4 2026 › over the weeks, and a way back
    /// to the present when away from it.
    private var stepper: some View {
        HStack(spacing: 4) {
            let isAway = scale == .quarter ? year != thisYear : quarter != thisQuarter
            if isAway {
                Button(scale == .quarter ? "This Year" : "This Quarter") {
                    shownYear = nil
                    shownQuarter = nil
                }
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
            .help(scale == .quarter ? "Previous year" : "Previous quarter")
            Text(scale == .quarter ? String(year) : quarter.title())
                .zoomedSystemFont(size: 12.5, weight: .medium)
                .monospacedDigit()
                .textSelection(.disabled)
                .frame(minWidth: 64)
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
                    .zoomedSystemFont(size: 12, weight: .semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.hoverWash(cornerRadius: 6, inset: 0))
            .help(scale == .quarter ? "Next year" : "Next quarter")
        }
    }

    private func step(_ count: Int) {
        switch scale {
        case .quarter:
            let next = year + count
            shownYear = next == thisYear ? nil : next
        case .week:
            guard let next = quarter.offset(by: count) else { return }
            shownQuarter = next == thisQuarter ? nil : next
        }
    }

    // MARK: Planning with the chat

    /// The Plan pill's card: the chat that plans a quarter, a week or a day,
    /// each the `/plan` command with its argument.
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
