import SwiftUI

// MARK: - The Plan on the iPhone and iPad
//
// The Mac's Space › Plan (`SpacePlanPage`, docs-site/plan.md): a year's quarters, each opening its plan
// Page (`PlanQuarter`), made from the Mac's template the first time. The week and the day are the Mac's
// Calendar, which the Mac's `/plan` chat fills; the phone has no planning chat.

/// The Plan place: a stepper through years, and the year's quarters as rows.
struct MobilePlanList: View {
    /// The split view's open page; nil on a phone, where a row pushes the page.
    var selection: Binding<String?>? = nil

    @Environment(MobileSpaceStore.self) private var store
    @Environment(\.spaceNavigation) private var navigation
    @State private var actions = MobileSpaceActions()
    /// The year whose quarters are listed; nil for this year.
    @State private var shownYear: Int?

    private var thisQuarter: PlanQuarter { PlanQuarter.containing(Date()) }
    private var year: Int { shownYear ?? thisQuarter.year }

    var body: some View {
        List {
            Section {
                ForEach(1...4, id: \.self) { number in
                    row(PlanQuarter(year: year, quarter: number))
                }
            } header: {
                stepper
            }
        }
        .navigationTitle(MobileSpacePlace.plan.title)
        .spaceActions(actions)
        .accessibilityIdentifier("space.list.plan")
    }

    private func row(_ quarter: PlanQuarter) -> some View {
        let page = store.pages.first { $0.id == quarter.id }
        let isNow = quarter == thisQuarter
        return Button {
            actions.openPlan(quarter, store: store, navigation: navigation)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quarter.title)
                        .font(.body.weight(isNow ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(quarter.rangeText())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isNow {
                    Text("Now")
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
        .listRowBackground(selection?.wrappedValue == quarter.id ? Color.accentColor.opacity(0.15) : nil)
        .accessibilityIdentifier("space.plan.\(quarter.key)")
    }

    /// ‹ 2026 ›, and a way back to this year.
    private var stepper: some View {
        HStack(spacing: 12) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous year")
            Text(String(year))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next year")
            Spacer()
            if year != thisQuarter.year {
                Button("This Year") { shownYear = nil }
                    .font(.subheadline)
            }
        }
        .textCase(nil)
        .buttonStyle(.borderless)
    }

    private func step(_ count: Int) {
        let next = year + count
        shownYear = next == thisQuarter.year ? nil : next
    }
}
