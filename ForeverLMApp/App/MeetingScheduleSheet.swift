import SwiftUI

struct MeetingScheduleTarget: Identifiable {
    let groupName: String
    var id: String { groupName }
}

/// When a meeting series meets, so the Planner draws it (planner-design.md,
/// "A meeting series on the clock"): the weekdays, the start, the length and
/// the zone the clock is read in. Save writes the series' record; Remove
/// clears the schedule and takes the occurrences off the clock.
struct MeetingScheduleSheet: View {
    let groupName: String

    @Environment(StudioViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var weekdays: Set<Int> = Set(MeetingSchedule.workdays)
    @State private var start = Date()
    @State private var durationMinutes = 15
    @State private var timezone = TimeZone.current.identifier
    @State private var loaded = false

    private static let durations = [15, 30, 45, 60, 90, 120]

    private var weekdaySymbols: [String] {
        var calendar = Calendar.current
        calendar.locale = .current
        return calendar.veryShortStandaloneWeekdaySymbols
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudioDesign.Spacing.large) {
            Text(vm.meetingDisplayName(groupName))
                .zoomedSystemFont(size: 15, weight: .semibold)
                .lineLimit(1)

            HStack(spacing: StudioDesign.Spacing.xSmall) {
                ForEach(1...7, id: \.self) { weekday in
                    Toggle(isOn: Binding(
                        get: { weekdays.contains(weekday) },
                        set: { on in if on { weekdays.insert(weekday) } else { weekdays.remove(weekday) } }
                    )) {
                        Text(weekdaySymbols[weekday - 1])
                            .zoomedSystemFont(size: 12, weight: .medium)
                            .frame(width: 22)
                    }
                    .toggleStyle(.button)
                    .accessibilityIdentifier("studio.meetingSchedule.weekday.\(weekday)")
                }
            }

            Grid(alignment: .leading, horizontalSpacing: StudioDesign.Spacing.medium, verticalSpacing: StudioDesign.Spacing.small) {
                GridRow {
                    Text("Starts").foregroundStyle(.secondary)
                    DatePicker("", selection: $start, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityIdentifier("studio.meetingSchedule.start")
                }
                GridRow {
                    Text("Length").foregroundStyle(.secondary)
                    Picker("", selection: $durationMinutes) {
                        ForEach(Self.durations, id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes) min" : minutes == 60 ? "1 hour" : minutes % 60 == 0 ? "\(minutes / 60) hours" : "\(minutes / 60) h \(minutes % 60) min").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .accessibilityIdentifier("studio.meetingSchedule.duration")
                }
                GridRow {
                    Text("Time zone").foregroundStyle(.secondary)
                    Picker("", selection: $timezone) {
                        ForEach(Self.timezoneChoices(including: timezone), id: \.self) { identifier in
                            Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .accessibilityIdentifier("studio.meetingSchedule.timezone")
                }
            }

            HStack {
                if vm.meetingMetadata[groupName]?.schedule != nil {
                    Button("Remove Schedule", role: .destructive) {
                        Task { await vm.setMeetingSchedule(nil, groupName: groupName) }
                        dismiss()
                    }
                    .accessibilityIdentifier("studio.meetingSchedule.remove")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await vm.setMeetingSchedule(schedule, groupName: groupName) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!schedule.isValid)
                .accessibilityIdentifier("studio.meetingSchedule.save")
            }
        }
        .padding(StudioDesign.Spacing.large)
        .frame(width: 400)
        .onAppear(perform: load)
    }

    private var schedule: MeetingSchedule {
        let components = Calendar.current.dateComponents([.hour, .minute], from: start)
        return MeetingSchedule(
            weekdays: Array(weekdays),
            startMinute: (components.hour ?? 0) * 60 + (components.minute ?? 0),
            durationMinutes: durationMinutes,
            timezone: timezone
        )
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let existing = vm.meetingMetadata[groupName]?.schedule
        let startMinute = existing?.startMinute ?? 9 * 60
        weekdays = Set(existing?.weekdays ?? MeetingSchedule.workdays)
        durationMinutes = existing.map { Self.durations.contains($0.durationMinutes) ? $0.durationMinutes : 15 } ?? 15
        timezone = existing?.timezone ?? vm.meetingMetadata[groupName]?.timezone ?? TimeZone.current.identifier
        if TimeZone(identifier: timezone) == nil { timezone = TimeZone.current.identifier }
        start = Calendar.current.date(bySettingHour: startMinute / 60, minute: startMinute % 60, second: 0, of: Date()) ?? Date()
    }

    /// The learner's zone, the series' own, and the zones the library's
    /// series already name — short enough to pick from, never a guess.
    static func timezoneChoices(including current: String) -> [String] {
        var choices = [TimeZone.current.identifier, current, "America/Los_Angeles", "America/New_York", "Europe/London", "Europe/Amsterdam", "Asia/Tokyo"]
        choices = choices.filter { TimeZone(identifier: $0) != nil }
        var seen = Set<String>()
        return choices.filter { seen.insert($0).inserted }
    }
}
