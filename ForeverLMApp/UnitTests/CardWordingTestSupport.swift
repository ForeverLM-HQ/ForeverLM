import Foundation
import Testing
@testable import ForeverLM

/// The wording gate's model, canned (docs/memory-design.md, "A card stands on
/// its own"). It reads the cards out of the turn it is sent, as the model
/// would, and answers for each: a card whose question or answer holds one of
/// `pointing` does not stand alone, and its rewording is `rewording` of its
/// question (nil leaves the rewording pointing too). It records every turn,
/// so a test sees what was sent and how many calls were made.
final class CannedCardWording: CardWordingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storedChecks: [String] = []
    private var storedRewordings: [String] = []
    let pointing: [String]
    let rewording: @Sendable (String) -> String?
    /// Thrown by every call when set: the check cannot be made.
    let failure: Error?

    init(
        pointing: [String] = [],
        rewording: @escaping @Sendable (String) -> String? = { _ in nil },
        failure: Error? = nil
    ) {
        self.pointing = pointing
        self.rewording = rewording
        self.failure = failure
    }

    var checks: [String] { lock.withLock { storedChecks } }
    var rewordings: [String] { lock.withLock { storedRewordings } }

    func check(user: String, cardCount: Int, usage: AIUsageSource) async throws -> String {
        lock.withLock { storedChecks.append(user) }
        if let failure { throw failure }
        let cards = Self.cards(in: user)
        let verdicts = cards.enumerated().map { offset, card -> [String: Any] in
            let points = pointing.contains { card.question.localizedCaseInsensitiveContains($0) || card.answer.localizedCaseInsensitiveContains($0) }
            return ["card": offset + 1, "stands_alone": !points, "problem": points ? "asks about this lecture without naming it" : NSNull()]
        }
        return try Self.json(["cards": verdicts])
    }

    func reword(user: String, cardCount: Int, answersMayChange: Bool, usage: AIUsageSource) async throws -> String {
        lock.withLock { storedRewordings.append(user) }
        if let failure { throw failure }
        let cards = Self.cards(in: user)
        let entries = cards.enumerated().map { offset, card -> [String: Any] in
            var entry: [String: Any] = ["card": offset + 1, "front": rewording(card.question) ?? card.question]
            if answersMayChange { entry["back"] = card.answer }
            return entry
        }
        return try Self.json(["cards": entries])
    }

    /// The cards of a turn, as `CardWordingCheck` writes them.
    static func cards(in user: String) -> [(question: String, answer: String)] {
        var cards: [(question: String, answer: String)] = []
        var question: String?
        for line in user.components(separatedBy: "\n") {
            if line.hasPrefix("Question: ") {
                question = String(line.dropFirst("Question: ".count))
            } else if line.hasPrefix("Answer: "), let asked = question {
                cards.append((asked, String(line.dropFirst("Answer: ".count))))
                question = nil
            }
        }
        return cards
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Binds a passing wording check for every test of a suite that drafts or
/// saves cards with canned models, so its cards meet the gate as they would
/// in the app — checked — without a model.
struct CardWordingPassesTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await CardWordingGate.$backendOverride.withValue(CannedCardWording()) {
            try await function()
        }
    }
}

extension Trait where Self == CardWordingPassesTrait {
    /// Every card stands on its own: the wording gate passes it as written.
    static var cardWordingPasses: Self { Self() }
}
