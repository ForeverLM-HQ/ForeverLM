import SwiftUI

/// Listen, on the phone, from the wrist: what is playing with play, pause and
/// stop, and the narrated sources to start, today's first. The audio stays on
/// the iPhone (and its AirPods); the watch's own Now Playing works too.
struct WatchListenView: View {
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        List {
            if let playing = store.day.nowPlaying {
                Section {
                    WatchNowPlayingRow(playing: playing)
                }
            }
            if let error = store.commandError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            let today = store.day.listen.filter(\.isToday)
            let recent = store.day.listen.filter { !$0.isToday }
            if !today.isEmpty {
                Section("Today") {
                    ForEach(today) { row($0) }
                }
            }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { row($0) }
                }
            }
            if store.day.listen.isEmpty {
                Text(store.hasHeardFromPhone ? "No source has narration yet." : "Open ForeverLM on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Listen")
    }

    private func row(_ item: WatchListenItem) -> some View {
        Button {
            store.send(.play(sourceID: item.sourceID, title: item.title))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(3)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .disabled(store.isSending)
    }
}

private struct WatchNowPlayingRow: View {
    @EnvironmentObject private var store: WatchStore
    let playing: WatchNowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(playing.title)
                .font(.headline)
                .lineLimit(3)
            if playing.duration > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ProgressView(value: elapsed(at: context.date), total: playing.duration)
                }
            }
            HStack {
                Button {
                    store.send(playing.isPlaying ? .pause : .resume)
                } label: {
                    Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                // Each button its own style: inside a List row, buttons with
                // the default style take the whole row's tap together.
                .buttonStyle(.bordered)
                .accessibilityLabel(playing.isPlaying ? "Pause" : "Play")
                Button {
                    store.send(.stop)
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stop")
            }
            .disabled(store.isSending)
        }
    }

    /// The phone's position, run on by the watch while it plays.
    private func elapsed(at date: Date) -> Double {
        let running = playing.isPlaying ? date.timeIntervalSince(playing.readAt) : 0
        return min(playing.duration, max(0, playing.elapsed + running))
    }
}
