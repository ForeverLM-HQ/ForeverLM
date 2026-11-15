import SwiftUI
import WidgetKit

// The watch face's complications and Smart Stack card: today's cards left,
// and the bout's clock while one runs. Drawn from the glance the watch app
// writes (`WatchGlanceStore`); a tap opens the cards.

struct WatchGlanceEntry: TimelineEntry {
    let date: Date
    let glance: WatchGlance
}

struct WatchGlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchGlanceEntry {
        WatchGlanceEntry(date: Date(), glance: WatchGlance(dueLeft: 6, newLeft: 4, bout: nil, nowPlayingTitle: nil, updatedAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchGlanceEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : WatchGlanceEntry(date: Date(), glance: WatchGlanceStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchGlanceEntry>) -> Void) {
        let now = Date()
        let glance = WatchGlanceStore.load()
        var entries = [WatchGlanceEntry(date: now, glance: glance)]
        // One more entry once the bout's clock runs out, so a finished
        // countdown is not left on the face.
        if let endsAt = glance.bout?.endsAt, endsAt > now {
            entries.append(WatchGlanceEntry(date: endsAt.addingTimeInterval(1), glance: glance))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct WatchGlanceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchGlanceEntry

    private var glance: WatchGlance { entry.glance }
    private var runningClock: Date? {
        glance.hasRunningBoutClock(now: entry.date) ? glance.bout?.endsAt : nil
    }

    var body: some View {
        content
            .widgetURL(URL(string: "foreverlm-watch://cards"))
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            if let endsAt = runningClock {
                VStack(spacing: 0) {
                    Image(systemName: glance.bout?.isOnBreak == true ? "cup.and.saucer" : "timer")
                        .font(.caption)
                    Text(timerInterval: entry.date...endsAt, countsDown: true)
                        .font(.caption2.monospacedDigit())
                        .multilineTextAlignment(.center)
                }
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.caption)
                    Text("\(glance.cardsLeft)")
                        .font(.title3.weight(.semibold))
                }
                .widgetAccentable()
            }
        case .accessoryCorner:
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.title3)
                .widgetLabel("\(glance.cardsLeft) cards")
        case .accessoryInline:
            if let endsAt = runningClock {
                Text(timerInterval: entry.date...endsAt, countsDown: true)
            } else {
                Text(glance.cardsLine)
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Text("ForeverLM")
                    .font(.headline)
                    .widgetAccentable()
                Text(glance.cardsLine)
                if let endsAt = runningClock, let bout = glance.bout {
                    HStack(spacing: 4) {
                        Text(bout.isOnBreak ? "Break" : "Bout")
                        Text(timerInterval: entry.date...endsAt, countsDown: true)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                } else if let playing = glance.nowPlayingTitle {
                    Label(playing, systemImage: "headphones")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct ForeverLMWatchComplications: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ForeverLMWatchGlance", provider: WatchGlanceProvider()) { entry in
            WatchGlanceView(entry: entry)
        }
        .configurationDisplayName("ForeverLM")
        .description("Today's cards and your bout's clock.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
