#if os(macOS)
import SwiftUI

// MARK: - The Plan in the Space
//
// Planning at three scales, as Cal Newport teaches it (docs-site/plan.md):
// the quarter's bigger picture, objectives and strategies are a Page
// (`PlanQuarter`); the week and the day are the Mac's Calendar, planned
// onto it with the quarter's plan in view and moved around as they go
// (product owner, 2026-11-07: "weekly planning is just putting stuff on the
// calendar for the week; we can always move it around"). This place lists a
// year's quarters, each opening its Page (made from its template the first
// time), and its pill starts the chat that plans a quarter, a week or a day.

/// The Space's Plan place: the place head (title and the Plan pill), a
/// stepper through years, and the year's quarters as rows.
struct SpacePlanPage: View {
    @Environment(StudioViewModel.self) private var vm
    @Environment(StudioWindowState.self) private var windowState: StudioWindowState?

    /// The year whose quarters are listed; nil for this year.
    @State private var shownYear: Int?

    private var isOwnLibrary: Bool { vm.activeTeamID == nil }
    private var thisQuarter: PlanQuarter { PlanQuarter.containing(Date()) }
    private var year: Int { shownYear ?? thisQuarter.year }

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
                            row(PlanQuarter(year: year, quarter: number))
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.plan")
    }

    // MARK: The list

    private func row(_ quarter: PlanQuarter) -> some View {
        let page = vm.artifacts.first { $0.id == quarter.id }
        let isNow = quarter == thisQuarter
        return Button {
            Task { await vm.openPlan(quarter, in: windowState) }
        } label: {
            HStack(spacing: 12) {
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
                    Text("This quarter")
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
        // A quarter with no Page yet makes one, which a read-only library cannot.
        .disabled(page == nil && vm.isActiveLibraryReadOnly)
        .accessibilityIdentifier("space.plan.\(quarter.key)")
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
