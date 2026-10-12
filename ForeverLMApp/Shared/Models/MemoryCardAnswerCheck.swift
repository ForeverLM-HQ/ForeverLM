import Foundation

/// Check in the card review (docs/memory-design.md, "The answer is checked").
/// The product owner, 2026-10-11: "for flashcards; there should be an llm
/// based check i think; i should be forced to actually say the answer". The
/// learner's typed or said answer goes to the Card Answer Check task
/// (`AITask.cardAnswerCheck`, `Prompts.cardAnswerCheck`) with the card's
/// front, back, why and the passage it quotes, and nothing else; the verdict
/// that comes back decides the grade the learner confirms with one key or
/// overrides with one action, and what they choose is what is recorded.
///
/// Pure (Foundation only), so the Mac's review, the Canvas's review in place,
/// the iPhone's review and the tests read one set of rules; the sitting keeps
/// the check's state (`MemoryCardSitting.answerCheck`).
enum MemoryCardAnswerCheck {
    /// What the model made of the answer.
    enum Verdict: String, Codable, Equatable, Sendable, CaseIterable {
        case right
        case partly
        case wrong

        /// The grade the verdict gives. Only a right answer is Remembered: a
        /// card asks for its whole back, and the repo's conventions count a
        /// partial answer as a miss to come back to — a course-quiz answer
        /// graded partial becomes a Memory card at once, as an incorrect one
        /// does (docs/memory-design.md, "Cards: identity and Keep"). The
        /// learner overrides it with one action when the model is wrong.
        var remembers: Bool { self == .right }
    }

    /// What the check is sent: the card as it was asked, and the answer.
    struct Request: Equatable, Sendable {
        /// The wording the card was asked in.
        let front: String
        let back: String
        let why: [String]
        /// The passage of its source the card quotes, when it has one.
        let quote: String?
        /// What the learner typed or said.
        let answer: String
    }

    /// The model's verdict and its one line to the learner.
    struct Result: Equatable, Sendable {
        let verdict: Verdict
        let note: String
    }

    /// The reply's budget: a verdict and one short line.
    static let maxTokens = 400

    /// The user turn: the card, then the answer. The system prompt is fixed,
    /// so its head caches across cards.
    static func message(_ request: Request) -> String {
        var parts = [
            "Question: \(request.front)",
            "Answer on the card: \(request.back)",
        ]
        let why = request.why.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !why.isEmpty {
            parts.append("Why it is right: " + why.joined(separator: " "))
        }
        if let quote = request.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            parts.append("The passage it stands on: \(quote)")
        }
        parts.append("The learner's answer: \(request.answer)")
        return parts.joined(separator: "\n\n")
    }

    enum ReplyError: LocalizedError, Equatable {
        case unreadable

        var errorDescription: String? {
            "The model's verdict could not be read."
        }
    }

    /// The verdict in the model's reply: `{"verdict", "note"}`, the verdict
    /// one of right, partly or wrong and the note not empty. Anything else is
    /// no verdict, thrown, so the call asks the next backup model; never a
    /// verdict made up from a reply that has none.
    static func result(from reply: String) throws -> Result {
        struct Reply: Decodable {
            let verdict: String?
            let note: String?
        }
        guard let decoded: Reply = try? MemoryReviewPlanning.decodeJSON(reply),
              let raw = decoded.verdict?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let verdict = Verdict(rawValue: raw),
              let note = decoded.note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty else {
            throw ReplyError.unreadable
        }
        return Result(verdict: verdict, note: note)
    }

    /// The line a check that could not run shows on the card: the learner
    /// grades themselves.
    static func failureLine(_ reason: String) -> String {
        var reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return "Your answer could not be checked. Grade it yourself." }
        if let last = reason.last, !".!?".contains(last) { reason += "." }
        return "Your answer could not be checked: \(reason) Grade it yourself."
    }
}
