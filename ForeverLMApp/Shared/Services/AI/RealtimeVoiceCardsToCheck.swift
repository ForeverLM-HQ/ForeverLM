import Foundation

/// Check Cards by Voice: the drafts that wait in To Check, gone through out
/// loud on OpenAI Realtime (product owner, 2026-11-14, asked whether the To
/// Check cards can be gone through in the car by voice, then: "please enable
/// this so that i can approve them etc using voice"). It is To Check as the
/// screen deals it: a card is asked before it is judged (2026-10-15: "even for
/// 'to check' cards i should still be quizzed on them; not just see the
/// answer"), then Keep, Edit or Skip, and every decision is the learner's,
/// said aloud and written with `decide_card`. No speech-to-text or
/// text-to-speech around it, as in every voice conversation.
enum RealtimeVoiceCardsToCheck {
    /// One card to check as the model reads it.
    struct Card: Equatable, Sendable {
        /// The card's id, which `decide_card` names.
        let id: String
        let front: String
        let back: String
        let why: String
        /// The source's title, when the card has one.
        let source: String?
        /// The id of the source, for Keep All and Skip All on it.
        let sourceID: String
    }

    static let title = "Check Cards"
    static let listToolName = "get_cards_to_check"
    static let decideToolName = "decide_card"
    /// How many cards the instructions carry; the rest come by `get_cards_to_check`.
    static let cardsInInstructions = 12

    static func instructions(cards: [Card], waiting: Int, scopeTitle: String) -> String {
        var parts: [String] = []
        parts.append("""
        You are ForeverLM, going through the learner's cards to check out loud: cards drafted from what they read \
        that wait for their say before they join their memory review, from \(scopeTitle). This is a live spoken \
        conversation, like a friend going through a stack of index cards with them.

        How it goes:
        - One card at a time, in the order below. Say the card's question naturally, keeping its meaning, and say \
        in a few words which source it is from when that helps. Then stop and wait for their answer. Never give \
        the answer before they have tried.
        - When they have answered, or said "I don't know", say the card's answer in one sentence and, in a few \
        words, how their answer compared. Then ask whether to keep it, change it or skip it.
        - Every decision is theirs. Call decide_card only after they have said keep, skip or what to change, in \
        words that clearly mean it ("keep it", "yes", "skip", "drop it"). Silence, a hesitation, a question or \
        "hmm" is not a decision: wait or answer them. Never decide a card on your own judgment.
        - Keep means decide_card with action keep. Skip means action skip, which drops the card for good. They \
        may skip before answering, for a card that is wrong on its face.
        - To change a card, they say the new words. Say the changed card back in a sentence, and on their yes \
        call decide_card with action keep and the new front, back or why they gave; leave out what they did not \
        change. Never invent words they did not say.
        - "Keep the rest of this paper" or "skip everything from this source" is action keep_source or skip_source \
        with the card's source_id. Say first that it covers every card still waiting from that source, and do it \
        only on their yes.
        - A decision is written once; if they want it undone, say it can be undone in To Check on the phone or \
        Mac, and carry on.
        - Speak briefly: one to three short sentences a turn. No lists, markdown, URLs or ids out loud.
        - Reply in the language the learner speaks; keep each card's meaning when you translate it.
        - Say a card's source by its title only when it helps ("from the paper on …"); never "this lecture".
        - When the cards below are done\(waiting > cards.count ? " and more wait, call get_cards_to_check for the next ones" : ""); \
        when none are left, say in one sentence how many they kept and skipped and ask whether they are done.
        - When they say they are done or goodbye, say a one-sentence goodbye, then call end_conversation.
        """)
        let header = waiting > cards.count
            ? "Cards to check, the first \(cards.count) of \(waiting) waiting:"
            : "Cards to check, \(cards.count) waiting:"
        parts.append(header)
        parts.append("<cards>\n\(cardList(cards))\n</cards>")
        return parts.joined(separator: "\n\n")
    }

    static func kickoff(waiting: Int) -> String {
        "(The learner just started Check Cards by Voice. Say in one short sentence that \(waiting == 1 ? "one card waits" : "\(waiting) cards wait") for their say, then ask the first card's question.)"
    }

    static func cardList(_ cards: [Card]) -> String {
        cards.enumerated().map { index, card in
            var lines = [
                "\(index + 1). card_id: \(card.id)",
                "   question: \(RealtimeVoiceCardReview.clipped(card.front))",
                "   answer: \(RealtimeVoiceCardReview.clipped(card.back))",
            ]
            if !card.why.isEmpty { lines.append("   why: \(RealtimeVoiceCardReview.clipped(card.why))") }
            if let source = card.source, !source.isEmpty { lines.append("   source: \(source) (source_id: \(card.sourceID))") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// What `get_cards_to_check` answers.
    static func listOutput(_ cards: [Card], waiting: Int) -> String {
        guard !cards.isEmpty else {
            if waiting == 0 {
                return #"{"cards":[],"note":"No cards are waiting to be checked. Say so."}"#
            }
            return #"{"cards":[],"note":"Every card still waiting was already dealt in this conversation. Finish those, then say how many they kept and skipped."}"#
        }
        let rows = cards.map { card -> [String: Any] in
            var row: [String: Any] = [
                "card_id": card.id,
                "question": RealtimeVoiceCardReview.clipped(card.front),
                "answer": RealtimeVoiceCardReview.clipped(card.back),
                "source_id": card.sourceID,
            ]
            if !card.why.isEmpty { row["why"] = RealtimeVoiceCardReview.clipped(card.why) }
            if let source = card.source, !source.isEmpty { row["source"] = source }
            return row
        }
        let object: [String: Any] = ["cards": rows, "waiting": waiting]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"cards":[]}"#
    }

    static func listTool(description: String) -> [String: Any] {
        RealtimeVoiceAssistant.function(
            listToolName,
            description,
            properties: ["limit": ["type": "integer", "description": "How many cards, 1 to 20; 10 if left out."]]
        )
    }

    static let decideTool: [String: Any] = RealtimeVoiceAssistant.function(
        decideToolName,
        "Writes the learner's decision on a card to check, only after they said it aloud: keep makes it a card of their memory review (first asked the day after), skip drops it for good, keep_source or skip_source does that for every card still waiting from the card's source. Pass front, back or why with keep only for words the learner gave to change the card.",
        properties: [
            "card_id": ["type": "string", "description": "The card's card_id (with keep_source or skip_source, any card of that source)."],
            "action": [
                "type": "string",
                "enum": ["keep", "skip", "keep_source", "skip_source"],
                "description": "What the learner decided.",
            ],
            "front": ["type": "string", "description": "With keep: the question in the learner's new words."],
            "back": ["type": "string", "description": "With keep: the answer in the learner's new words."],
            "why": ["type": "string", "description": "With keep: why the answer is right, in the learner's new words."],
        ],
        required: ["card_id", "action"]
    )
}
