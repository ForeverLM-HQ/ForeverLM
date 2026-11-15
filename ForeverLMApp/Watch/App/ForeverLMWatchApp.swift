import SwiftUI

// ForeverLM on the Apple Watch: today's cards, Listen on the phone, and the
// bout's clock. Everything comes from the iPhone app (`MobileWatchBridge`).

@main
struct ForeverLMWatchApp: App {
    @StateObject private var store = WatchStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchStore.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.refresh() }
        }
    }
}

/// Where a complication's tap lands.
enum WatchRoute: Hashable {
    case cards
    case listen

    init?(url: URL) {
        guard url.scheme == "foreverlm-watch" else { return nil }
        switch url.host {
        case "cards": self = .cards
        case "listen": self = .listen
        default: return nil
        }
    }
}

struct WatchHomeView: View {
    @EnvironmentObject private var store: WatchStore
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let bout = store.day.bout {
                    WatchBoutRow(bout: bout)
                }
                NavigationLink(value: WatchRoute.cards) {
                    WatchHomeRow(
                        symbol: "rectangle.on.rectangle.angled",
                        title: "Cards",
                        detail: store.hasHeardFromPhone ? store.glance.cardsLine : "Open ForeverLM on your iPhone"
                    )
                }
                NavigationLink(value: WatchRoute.listen) {
                    WatchHomeRow(
                        symbol: store.day.nowPlaying?.isPlaying == true ? "waveform" : "headphones",
                        title: "Listen",
                        detail: store.day.nowPlaying?.title ?? listenDetail
                    )
                }
            }
            .navigationTitle("ForeverLM")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .cards: WatchCardsView()
                case .listen: WatchListenView()
                }
            }
        }
        .onOpenURL { url in
            guard let route = WatchRoute(url: url) else { return }
            path = [route]
        }
    }

    private var listenDetail: String {
        let count = store.day.listen.count
        return count == 0 ? "Nothing narrated yet" : (count == 1 ? "1 source" : "\(count) sources")
    }
}

private struct WatchHomeRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The live bout: its clock, and Back to Work while resting.
private struct WatchBoutRow: View {
    @EnvironmentObject private var store: WatchStore
    let bout: WatchBout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bout.isOnBreak ? "Break" : bout.title)
                .font(.headline)
                .lineLimit(2)
            if let endsAt = bout.endsAt, endsAt > Date() {
                Text(timerInterval: Date()...endsAt, countsDown: true)
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(bout.isOnBreak ? .green : .orange)
            } else if bout.needsAttention {
                Text(bout.isOnBreak ? "Break earned" : "Write-up waiting on your iPhone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if bout.isOnBreak {
                Button("Back to Work") { store.send(.endBreak) }
                    .disabled(store.isSending)
            }
            if let error = store.commandError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
