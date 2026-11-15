import Foundation

// What the watch's complications draw, written by the watch app into its app
// group and read by the complications extension. The watch's own app group:
// the phone's container is on the phone.

struct WatchGlance: Codable, Equatable, Sendable {
    /// Today's cards not yet answered on the watch.
    let dueLeft: Int
    let newLeft: Int
    let bout: WatchBout?
    let nowPlayingTitle: String?
    let updatedAt: Date

    static let empty = WatchGlance(dueLeft: 0, newLeft: 0, bout: nil, nowPlayingTitle: nil, updatedAt: .distantPast)

    var cardsLeft: Int { dueLeft + newLeft }

    /// "6 due · 4 new", as the phone's widget says it.
    var cardsLine: String {
        switch (dueLeft > 0, newLeft > 0) {
        case (true, true): return "\(dueLeft) due · \(newLeft) new"
        case (true, false): return "\(dueLeft) due"
        case (false, true): return newLeft == 1 ? "1 new card" : "\(newLeft) new cards"
        case (false, false): return "No cards left"
        }
    }

    /// Whether the bout's clock is still ahead of `now`.
    func hasRunningBoutClock(now: Date = Date()) -> Bool {
        guard let endsAt = bout?.endsAt else { return false }
        return endsAt > now
    }
}

enum WatchGlanceStore {
    static let suiteName = "group.com.foreverlm"
    private static let key = "watch.glance"

    static func save(_ glance: WatchGlance) {
        guard let data = try? PropertyListEncoder().encode(glance) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: key)
    }

    static func load() -> WatchGlance {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: key),
              let glance = try? PropertyListDecoder().decode(WatchGlance.self, from: data) else {
            return .empty
        }
        return glance
    }
}
