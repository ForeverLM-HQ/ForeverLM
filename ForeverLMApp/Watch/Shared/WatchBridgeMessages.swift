import Foundation

// What the iPhone and the Apple Watch say to each other over WatchConnectivity.
// The watch holds no library of its own: the phone deals today's cards, says
// what can be listened to and what is playing, and passes on the bout's clock.
// The watch answers with grades and with commands for the phone's player.
//
// Compiled into the iPhone app and the watch app, so it uses plain values
// only: no model types of either side.

/// Everything the watch draws, as the phone last saw it.
struct WatchDay: Codable, Equatable, Sendable {
    /// The day the cards were dealt for (`MemoryReviewGoal.dayKey`). A new day
    /// clears what the watch remembers having answered.
    let dayKey: String
    /// The phone's card sitting key for the watch. Every grade carries it back,
    /// so an answer is written once per card whatever the transfer does.
    let sittingKey: String
    /// Today's cards, in the order they are asked.
    let cards: [WatchCard]
    let bout: WatchBout?
    /// Narrated sources the phone can play at once, today's first.
    let listen: [WatchListenItem]
    let nowPlaying: WatchNowPlaying?
    let updatedAt: Date

    static let empty = WatchDay(dayKey: "", sittingKey: "", cards: [], bout: nil, listen: [], nowPlaying: nil, updatedAt: .distantPast)
}

/// One card, as the watch shows it: the wording asked, then the back.
struct WatchCard: Codable, Equatable, Identifiable, Sendable {
    let itemID: String
    /// The wording asked: what the grade is recorded against.
    let prompt: String
    let back: String
    let why: [String]
    let sourceTitle: String?
    let isNew: Bool

    var id: String { itemID }
}

/// The learning bout's clock, as the phone's widget draws it.
struct WatchBout: Codable, Equatable, Sendable {
    let title: String
    /// When the clock runs out: the bout's own timer while learning, the
    /// break's while resting. Nil while the bout waits on its write-up.
    let endsAt: Date?
    let isOnBreak: Bool
    /// A write-up is owed, or a break was earned and not taken.
    let needsAttention: Bool
}

/// A source the phone has narration for.
struct WatchListenItem: Codable, Equatable, Identifiable, Sendable {
    let sourceID: String
    let title: String
    let subtitle: String?
    /// Placed on today's Schedule and not finished.
    let isToday: Bool

    var id: String { sourceID }
}

/// What the phone is playing.
struct WatchNowPlaying: Codable, Equatable, Sendable {
    let sourceID: String
    let title: String
    let isPlaying: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval
    /// When `elapsed` was read, so the watch can run the clock on by itself.
    let readAt: Date
}

/// Forgot or Remembered on the watch. Sent with `transferUserInfo`, which the
/// system keeps until the phone takes it, so a card answered with the phone
/// out of reach is still written.
struct WatchGrade: Codable, Equatable, Sendable {
    let itemID: String
    let prompt: String
    let remembered: Bool
    let sittingKey: String
    let answeredAt: Date
}

/// What the watch asks the phone to do now. Sent with `sendMessage`, which
/// needs the phone in reach; the reply is the fresh `WatchDay`.
enum WatchCommand: Codable, Equatable, Sendable {
    case refresh
    case play(sourceID: String, title: String)
    case pause
    case resume
    case stop
    case endBreak
}

enum WatchBridge {
    static let dayKey = "day"
    static let gradeKey = "grade"
    static let commandKey = "command"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? PropertyListEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let data = value as? Data else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }
}
