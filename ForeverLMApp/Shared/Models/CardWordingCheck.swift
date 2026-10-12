import Foundation

/// A card stands on its own (docs/memory-design.md, "A card stands on its
/// own"). The product owner, 2026-10-11, of a card that asked "In this
/// lecture, what structural feature of cardiolipin …" with no lecture named:
/// "that should not be allowed to happen". A card is asked weeks later, away
/// from its source, among cards from every source, so its question and its
/// answer never point at their source without naming it.
///
/// The writers are told so (`Prompts.cardStandsAloneRule`), and the rule is
/// held at the gate too: every card face written by a model or an assistant
/// passes `CardWordingGate` before it is saved. Whether a face points at its
/// source is a judgement about human-written text, so a model makes it
/// (AGENTS.md: an LLM call over string parsing), batched — one call checks
/// every card of a drafting pass. This file is the pure half: the turns the
/// model is sent and how its replies are read.
enum CardWordingCheck {
    /// One card as the check reads it: its question and answer, and the
    /// title of the source it is from, which a rewording may name.
    struct Face: Equatable, Sendable {
        let front: String
        let back: String
        let sourceTitle: String
    }

    /// The check's word on one card.
    struct Verdict: Equatable, Sendable {
        let standsAlone: Bool
        /// What it points at, for a card that does not stand alone.
        let problem: String?
    }

    /// A failing card's rewording: its new question, and its new answer when
    /// the answer may change.
    struct Rewording: Equatable, Sendable {
        let front: String
        let back: String?
    }

    /// What the gate made of one card.
    enum Outcome: Equatable, Sendable {
        /// It stood on its own as written.
        case passed
        /// It did not, and its rewording, checked again, does: save this.
        case reworded(front: String, back: String)
        /// It did not, and its rewording did not either: it is not saved.
        case failed(reason: String)
    }

    /// The most cards one call reads: a drafting pass's cards fit in one,
    /// and an MCP save of a hundred takes a few.
    static let batchSize = 40

    /// A reply's budget for `count` cards.
    static func maxTokens(cardCount count: Int) -> Int {
        max(300, min(8_000, 120 + count * 110))
    }

    // MARK: The turns

    /// The check's user turn: every card, numbered from one, with its
    /// source's title. The system prompt is fixed (`Prompts.cardWordingCheck`).
    static func checkMessage(_ faces: [Face]) -> String {
        faces.enumerated().map { offset, face in
            """
            Card \(offset + 1), from \u{201C}\(face.sourceTitle)\u{201D}
            Question: \(face.front)
            Answer: \(face.back)
            """
        }.joined(separator: "\n\n")
    }

    /// The rewording's user turn: the failing cards, each with what is wrong,
    /// renumbered from one, and whether their answers may change.
    static func rewordMessage(_ failing: [(face: Face, problem: String)], answersMayChange: Bool) -> String {
        let rule = answersMayChange
            ? "The answers may change too, only where they point at the source unnamed."
            : "The answers may not change: return only each question, leaving \"back\" out."
        let cards = failing.enumerated().map { offset, entry in
            """
            Card \(offset + 1), from \u{201C}\(entry.face.sourceTitle)\u{201D}
            Question: \(entry.face.front)
            Answer: \(entry.face.back)
            What is wrong: \(entry.problem)
            """
        }.joined(separator: "\n\n")
        return rule + "\n\n" + cards
    }

    // MARK: The replies

    enum ReplyError: LocalizedError, Equatable {
        /// The reply is not the shape asked for, or leaves a card out.
        case unreadable

        var errorDescription: String? {
            "The model's check of the cards' wording could not be read."
        }
    }

    /// The verdicts in a check's reply, by card number from one. Every card
    /// asked about must be answered; a reply that leaves one out, or that is
    /// not the shape asked for, throws, so the call asks the next backup model
    /// and nothing is taken on a guess.
    static func verdicts(from reply: String, count: Int) throws -> [Int: Verdict] {
        struct Reply: Decodable {
            struct Card: Decodable {
                let card: Int
                let standsAlone: Bool
                let problem: String?

                enum CodingKeys: String, CodingKey {
                    case card
                    case standsAlone = "stands_alone"
                    case problem
                }
            }
            let cards: [Card]
        }
        guard let decoded: Reply = try? MemoryReviewPlanning.decodeJSON(reply) else { throw ReplyError.unreadable }
        var verdicts: [Int: Verdict] = [:]
        for card in decoded.cards where (1...max(count, 1)).contains(card.card) && verdicts[card.card] == nil {
            let problem = card.problem?.trimmingCharacters(in: .whitespacesAndNewlines)
            verdicts[card.card] = Verdict(
                standsAlone: card.standsAlone,
                problem: problem?.isEmpty == false ? problem : nil
            )
        }
        guard verdicts.count == count else { throw ReplyError.unreadable }
        return verdicts
    }

    /// The rewordings in a reply, by card number from one. Every card asked
    /// about must have a question that is not empty; an answer is read only
    /// when answers may change, and one left out keeps the card's.
    static func rewordings(from reply: String, count: Int, answersMayChange: Bool) throws -> [Int: Rewording] {
        struct Reply: Decodable {
            struct Card: Decodable {
                let card: Int
                let front: String?
                let back: String?
            }
            let cards: [Card]
        }
        guard let decoded: Reply = try? MemoryReviewPlanning.decodeJSON(reply) else { throw ReplyError.unreadable }
        var rewordings: [Int: Rewording] = [:]
        for card in decoded.cards where (1...max(count, 1)).contains(card.card) && rewordings[card.card] == nil {
            guard let front = card.front?.trimmingCharacters(in: .whitespacesAndNewlines), !front.isEmpty else { continue }
            let back = answersMayChange
                ? card.back?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyWording
                : nil
            rewordings[card.card] = Rewording(front: front, back: back)
        }
        guard rewordings.count == count else { throw ReplyError.unreadable }
        return rewordings
    }

    /// The reason a card that failed twice is not saved, in the words a
    /// drafting summary and an MCP refusal say it.
    static func failureReason(_ problem: String?) -> String {
        let what = problem.map { " (\($0))" } ?? ""
        return "It points at its source without naming it\(what), and a rewording did not fix that. A card must name what it is about."
    }
}

private extension String {
    var nonEmptyWording: String? { isEmpty ? nil : self }
}
