import SwiftUI
import WidgetKit

private struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: MobileTodayWidgetSnapshot
}

private struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(
            date: Date(),
            snapshot: MobileTodayWidgetSnapshot(
                pendingCount: 3,
                nextTitle: "Continue learning",
                memoryDueCount: 6,
                memoryNewCount: 4,
                boutTitle: "GDF15 and the hindbrain",
                boutEndsAt: Date().addingTimeInterval(9 * 60),
                isOnBreak: true,
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(date: Date(), snapshot: MobileTodayWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let snapshot = MobileTodayWidgetSnapshotStore.load()
        let entry = TodayEntry(date: now, snapshot: snapshot)
        // A running clock draws itself — `Text(timerInterval:)` ticks without
        // the extension being woken — so the only reason to come back is to
        // stop drawing it. Ask for the moment it runs out, and otherwise keep
        // the ordinary half-hour.
        let ordinary = Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1_800)
        let nextRefresh: Date
        if let endsAt = snapshot.boutEndsAt, endsAt > now {
            nextRefresh = min(ordinary, endsAt.addingTimeInterval(1))
        } else {
            nextRefresh = ordinary
        }
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

private struct TodayWidgetView: View {
    let entry: TodayEntry

    var body: some View {
        Link(destination: destination) {
            VStack(alignment: .leading, spacing: 8) {
                if entry.snapshot.hasRunningBoutClock(now: entry.date) {
                    boutClock
                } else {
                    day
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// The bout's own clock, drawn in place of the day's counts while one is
    /// running. `Text(timerInterval:)` ticks in the widget without the
    /// extension being woken for it, which is what makes a ten-minute break
    /// something the phone can actually show.
    @ViewBuilder
    private var boutClock: some View {
        let endsAt = entry.snapshot.boutEndsAt ?? entry.date
        Label(
            entry.snapshot.isOnBreak ? "Break" : "Learning",
            systemImage: entry.snapshot.isOnBreak ? "cup.and.saucer" : "timer"
        )
        .font(.headline)
        .foregroundStyle(entry.snapshot.isOnBreak ? Color.green : Color.accentColor)
        Text(timerInterval: entry.date...endsAt, countsDown: true)
            .font(.system(.title, design: .rounded, weight: .semibold))
            .monospacedDigit()
        Text(entry.snapshot.boutTitle ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    @ViewBuilder
    private var day: some View {
        Label(title, systemImage: entry.snapshot.memoryCardCount > 0 ? "brain.head.profile" : "calendar")
            .font(.headline)
        Text(primaryCount.formatted())
            .font(.system(.title, design: .rounded, weight: .semibold))
            .monospacedDigit()
        Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var destination: URL {
        if entry.snapshot.hasRunningBoutClock(now: entry.date) || entry.snapshot.boutNeedsAttention {
            return URL(string: "foreverlm://today")!
        }
        return URL(string: entry.snapshot.memoryCardCount > 0 ? "foreverlm://review" : "foreverlm://today")!
    }

    private var title: String {
        entry.snapshot.memoryCardCount > 0 ? "Memory Review" : "Today"
    }

    private var primaryCount: Int {
        entry.snapshot.memoryCardCount > 0 ? entry.snapshot.memoryCardCount : entry.snapshot.pendingCount
    }

    private var statusText: String {
        if entry.snapshot.memoryCardCount > 0 {
            // What the count is made of, never a card: a card's target is its answer.
            return entry.snapshot.memoryLine
        }
        if entry.snapshot.boutNeedsAttention, let title = entry.snapshot.boutTitle {
            return "Write up “\(title)”"
        }
        if entry.snapshot.pendingCount == 0 { return "Nothing pending" }
        return entry.snapshot.nextTitle ?? "Open your learning plan"
    }

}

struct ForeverLMTodayWidget: Widget {
    let kind = "ForeverLMTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's Learning")
        .description("The bout or break counting down, or what today's memory review holds.")
        // The Lock Screen families matter more than the Home ones here: a break
        // is taken away from the desk, and the phone that shows it is usually
        // locked and face up on a table.
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct ForeverLMWidgetBundle: WidgetBundle {
    var body: some Widget {
        ForeverLMTodayWidget()
    }
}
