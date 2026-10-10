import Foundation

struct MobileSourceChatBenchmark: Equatable, Sendable {
    let sourceTitle: String
    let question: String
    let planningMilliseconds: Double
    let llmMilliseconds: Double
    let totalMilliseconds: Double
    let promptContextCharacters: Int
    let selectedPassageCount: Int
    let responseCharacters: Int
}

struct MobileDrivingVoiceBenchmark: Equatable, Sendable {
    let utterance: String
    let route: String
    let sourceResolutionStrategy: String
    let sourceResolutionMilliseconds: Double
    let sourceTextLoadMilliseconds: Double
    let firstModelTurnMilliseconds: Double?
    let totalMilliseconds: Double
    let selectedSourceTitle: String?
}

enum MobileBenchmarkClock {
    static func milliseconds(since start: Date, until end: Date = Date()) -> Double {
        max(0, end.timeIntervalSince(start) * 1_000)
    }
}
