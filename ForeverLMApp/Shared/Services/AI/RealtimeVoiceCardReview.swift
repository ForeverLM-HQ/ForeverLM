import Foundation

/// Review by Voice: today's cards, reviewed out loud on OpenAI Realtime, the
/// same conversation as voice mode (`RealtimeVoiceController`) with a brief of
/// its own. The cards due go straight into the instructions, so the model asks
/// the first one without a tool call; it judges each spoken answer and records
/// it with `grade_card`, which writes a Forgot or Remembered exactly as the
/// card review does. Voice is one
/// realtime model, no speech-to-text or text-to-speech around it (product
/// owner, 2026-11-07: "Should all just call the real-time voice API, not do any
/// sneaky text-to-speech or speech-to-text"). The personal assistant offers the
/// same two tools, so "my cards" works there too.
enum RealtimeVoiceCardReview {
    /// One card as the model reads it.
    struct Card: Equatable, Sendable {
        /// The memory item id, which `grade_card` names.
        let id: String
        let question: String
        let answer: String
        /// The source's title, when the card has one.
        let source: String?
    }

    static let title = "Card Review"
    static let dueCardsToolName = "get_due_cards"
    static let gradeCardToolName = "grade_card"
    /// How many cards the instructions carry; the rest come by `get_due_cards`.
    static let cardsInInstructions = 20
    /// A question or an answer is kept to this many characters out loud.
    static let fieldBudget = 600

    static func instructions(cards: [Card], dueToday: Int, scopeTitle: String) -> String {
        var parts: [String] = []
        parts.append("""
        You are ForeverLM, running the learner's card review out loud: spaced repetition, today's cards due in \
        \(scopeTitle). This is a live spoken conversation, like a friend quizzing them from a deck of index cards.

        How it goes:
        - Ask one card at a time, in the order below. Say its question naturally, keeping its meaning, then stop and \
        wait for their answer. Never give the answer before they have tried.
        - Judge the answer by meaning, not wording: they remembered it when their answer has the card's point.
        - Then say plainly whether they had it and give the card's answer in one sentence, call grade_card with \
        what they said and remembered true or false, and ask the next card's question.
        - They may pause to think mid-answer. If what you heard sounds unfinished, wait or ask them to go on; never \
        grade half an answer.
        - "I don't know", "pass" or "tell me" is not remembered: give the answer, grade it false, move on.
        - If they ask about a card, answer in a sentence or two, then carry on. A grade is recorded once; say so if \
        they want it changed, and carry on.
        - Speak briefly: one to three short sentences a turn. No lists, markdown, URLs or ids out loud.
        - Reply in the language the learner speaks; keep each card's meaning when you translate it.
        - Say a card's source by its title only when it helps ("from the paper on …"); never "this lecture".
        - When the cards below are done\(dueToday > cards.count ? " and more are due, call get_due_cards for the next ones" : ""); \
        when none are left, say how it went in one sentence (how many they had out of how many) and ask whether \
        they are done.
        - When they say they are done or goodbye, say a one-sentence goodbye, then call end_conversation.
        """)
        let header = dueToday > cards.count
            ? "Today's cards, the first \(cards.count) of \(dueToday) due:"
            : "Today's cards, \(cards.count) due:"
        parts.append(header)
        parts.append("<cards>\n\(cardList(cards))\n</cards>")
        return parts.joined(separator: "\n\n")
    }

    static func kickoff(cardCount: Int) -> String {
        "(The learner just started Review by Voice. Say in one short sentence that you have \(cardCount == 1 ? "one card" : "\(cardCount) cards") for them, then ask the first card's question.)"
    }

    /// The cards as the instructions list them.
    static func cardList(_ cards: [Card]) -> String {
        cards.enumerated().map { index, card in
            var lines = [
                "\(index + 1). card_id: \(card.id)",
                "   question: \(clipped(card.question))",
                "   answer: \(clipped(card.answer))",
            ]
            if let source = card.source, !source.isEmpty { lines.append("   source: \(source)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// What `get_due_cards` answers.
    static func dueCardsOutput(_ cards: [Card], dueToday: Int) -> String {
        guard !cards.isEmpty else {
            if dueToday == 0 {
                return #"{"cards":[],"note":"No cards are due today. Say so, and say how the review went if you ran one; otherwise offer to quiz them on something they read."}"#
            }
            return #"{"cards":[],"note":"Every card still due was already dealt in this conversation. Finish those, then say how the review went."}"#
        }
        let rows = cards.map { card -> [String: Any] in
            var row: [String: Any] = ["card_id": card.id, "question": clipped(card.question), "answer": clipped(card.answer)]
            if let source = card.source, !source.isEmpty { row["source"] = source }
            return row
        }
        let object: [String: Any] = ["cards": rows, "due_today": dueToday]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"cards":[]}"#
    }

    static func dueCardsTool(description: String) -> [String: Any] {
        RealtimeVoiceAssistant.function(
            dueCardsToolName,
            description,
            properties: ["limit": ["type": "integer", "description": "How many cards, 1 to 20; 10 if left out."]]
        )
    }

    static let gradeCardTool: [String: Any] = RealtimeVoiceAssistant.function(
        gradeCardToolName,
        "Records whether the learner remembered a card, which moves it on their review schedule. Remembered only when their answer had the card's point.",
        properties: [
            "card_id": ["type": "string", "description": "The card's card_id."],
            "learner_said": [
                "type": "string",
                "description": "What the learner said in answer, in substance: one or two sentences, as close to their own words as you heard them. \"I don't know\" when they passed.",
            ],
            "remembered": ["type": "boolean", "description": "true when they had it, false when they did not."],
        ],
        required: ["card_id", "learner_said", "remembered"]
    )

    /// A graded card as the saved chat keeps it: the card's question and what
    /// the model heard the learner say, laid on their "(spoken)" line
    /// (`RealtimeVoiceExchange.exchanges(from:answers:)`). It carries no
    /// score: the card's own schedule holds the grade, and a chat's score is
    /// read as the recall of the source it is filed with, which a deck of
    /// cards is not. Nil when the model gave no words.
    static func answerRecord(question: String, learnerSaid: String?, remembered: Bool, at date: Date) -> RealtimeVoiceAnswerRecord? {
        let said = (learnerSaid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return nil }
        return RealtimeVoiceAnswerRecord(
            question: question,
            learnerSaid: said,
            verdict: remembered ? .hadIt : .missed,
            gap: nil,
            recordedAt: date,
            countsTowardScore: false
        )
    }

    static func clipped(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > fieldBudget else { return flat }
        return String(flat.prefix(fieldBudget)) + "…"
    }
}
