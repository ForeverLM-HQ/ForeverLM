import SwiftUI

// MARK: - The Plan on the iPhone and iPad
//
// The Mac's Space › Plan (`SpacePlanPage`, docs-site/plan.md): the quarters of a year or the weeks of
// a quarter, each opening its plan Page (`PlanPeriod`), made from the Mac's template the first time.
// The day is the Mac's Calendar, which the Mac's `/plan` chat fills; the phone has no planning chat.

/// The Plan place: Quarter | Week, a stepper through years or quarters, and the periods as rows.
struct MobilePlanList: View {
    /// The split view's open page; nil on a phone, where a row pushes the page.
    var selection: Binding<String?>? = nil

    @Environment(MobileSpaceStore.self) private var store
    @Environment(\.spaceNavigation) private var navigation
    @State private var actions = MobileSpaceActions()
    /// This device's last scope, as the Mac's `space.planScale`.
    @AppStorage("ios.space.planScale") private var scaleRaw = PlanScale.quarter.rawValue
    /// The year whose quarters are listed; nil for this year.
    @State private var shownYear: Int?
    /// The quarter whose weeks are listed; nil for this quarter.
    @State private var shownQuarter: PlanPeriod?

    private var scale: PlanScale { PlanScale(rawValue: scaleRaw) ?? .quarter }
    private var thisQuarter: PlanPeriod { PlanPeriod.containing(Date(), scale: .quarter) }
    private var thisWeek: PlanPeriod { PlanPeriod.containing(Date(), scale: .week) }
    private var thisYear: Int {
        if case .quarter(let year, _) = thisQuarter { return year }
        return Calendar.current.component(.year, from: Date())
    }
    private var year: Int { shownYear ?? thisYear }
    private var quarter: PlanPeriod { shownQuarter ?? thisQuarter }

    var body: some View {
        List {
            Section {
                Picker("Scale", selection: $scaleRaw) {
                    ForEach(PlanScale.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("space.plan.scale")
            }
            Section {
                switch scale {
                case .quarter:
                    ForEach(1...4, id: \.self) { number in
                        let period = PlanPeriod.quarter(year: year, quarter: number)
                        row(period, isNow: period == thisQuarter)
                    }
                case .week:
                    // The week is planned with its quarter's plan in view, so the quarter leads.
                    row(quarter, isNow: quarter == thisQuarter, subtitle: "The quarter's plan")
                    ForEach(quarter.weeks()) { week in
                        row(week, isNow: week == thisWeek)
                    }
                }
            } header: {
                stepper
            }
        }
        .navigationTitle(MobileSpacePlace.plan.title)
        .spaceActions(actions)
        .accessibilityIdentifier("space.list.plan")
    }

    private func row(_ period: PlanPeriod, isNow: Bool, subtitle: String? = nil) -> some View {
        let page = store.pages.first { $0.id == period.id }
        return Button {
            actions.openPlan(period, store: store, navigation: navigation)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(period.title())
                        .font(.body.weight(isNow ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(subtitle ?? period.rangeText())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isNow {
                    Text(period.scale == .quarter ? "Now" : "This week")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text(page.map { MobileSpaceDateText.short($0.editedAt) } ?? "Not planned")
                    .font(.footnote)
                    .foregroundStyle(page == nil ? HierarchicalShapeStyle.tertiary : .secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .listRowBackground(selection?.wrappedValue == period.id ? Color.accentColor.opacity(0.15) : nil)
        .accessibilityIdentifier("space.plan.\(period.key)")
    }

    /// ‹ 2026 › over the quarters, ‹ Q4 2026 › over the weeks, and a way back to the present.
    private var stepper: some View {
        HStack(spacing: 12) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel(scale == .quarter ? "Previous year" : "Previous quarter")
            Text(scale == .quarter ? String(year) : quarter.title())
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel(scale == .quarter ? "Next year" : "Next quarter")
            Spacer()
            if scale == .quarter ? year != thisYear : quarter != thisQuarter {
                Button(scale == .quarter ? "This Year" : "This Quarter") {
                    shownYear = nil
                    shownQuarter = nil
                }
                .font(.subheadline)
            }
        }
        .textCase(nil)
        .buttonStyle(.borderless)
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
}
