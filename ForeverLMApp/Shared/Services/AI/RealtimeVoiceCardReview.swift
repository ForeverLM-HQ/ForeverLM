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
        /// When the card was made, when known.
        var createdAt: Date? = nil
    }

    static let title = "Card Review"
    static let dueCardsToolName = "get_due_cards"
    static let gradeCardToolName = "grade_card"
    static let deleteCardToolName = "delete_card"
    static let undoDeleteCardToolName = "undo_delete_card"
    static let cardsByDateToolName = "get_cards_by_date"
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
        - Today's cards are only a slice of their deck. For a subject, a paper or a card they remember, call \
        search_cards: it searches every kept card, and what it returns can be asked and graded like the others. \
        For "what do I have cards on", call list_card_topics and name a few topics, never the whole list.
        - If they say to delete or remove a card ("delete this card", "I don't like this card, get rid of it"), \
        call delete_card with its card_id, say in a few words that it is gone and that they can say "undo" to get it \
        back, and ask the next card's question; do not grade a deleted card. A card that is merely hard or that \
        they forgot is not a deletion: only their clear word is. If they say undo, bring it back, or that they \
        did not mean it, call undo_delete_card, then ask that card's question again.
        - For cards made on a day ("the cards I made yesterday"), call get_cards_by_date, then go through what it \
        returns one card at a time like today's cards, grading each with grade_card.
        - If they want to go through their cards to check, use get_cards_to_check and decide_card: ask each \
        question, and decide only when they clearly say keep, change or skip.
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

    static let deleteCardTool: [String: Any] = RealtimeVoiceAssistant.function(
        deleteCardToolName,
        "Deletes a card: it is never asked again (its past answers are kept), unless the learner says undo, which undo_delete_card answers. Call it only when the learner clearly says to delete or remove the card, never because they forgot it or found it hard. Do not grade a card you delete.",
        properties: ["card_id": ["type": "string", "description": "The card's card_id."]],
        required: ["card_id"]
    )

    static let undoDeleteCardTool: [String: Any] = RealtimeVoiceAssistant.function(
        undoDeleteCardToolName,
        "Brings back a card deleted in this conversation, when the learner says undo, bring it back or that they did not mean it. With no card_id it brings back the card deleted last.",
        properties: ["card_id": ["type": "string", "description": "The deleted card's card_id; leave out for the last one deleted."]]
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

// MARK: - The whole card library, by voice

/// Today's queue is a time-budgeted slice of the deck (about 30 cards), so the
/// voice conversation also reaches every kept card: `search_cards` finds them
/// by what they say or the source they come from, and `list_card_topics` says
/// which sources hold how many (product owner, 2026-11-15: voice "doesn't have
/// access to all flashcards; only 30 at a time", asking to search them, list
/// some by topic and go through the cards to check).
extension RealtimeVoiceCardReview {
    static let searchCardsToolName = "search_cards"
    static let listTopicsToolName = "list_card_topics"
    static let searchResultCap = 20
    static let topicCap = 40

    /// A kept card anywhere in the library, due or not.
    struct LibraryCard: Equatable, Sendable {
        let card: Card
        let dueToday: Bool
    }

    /// Cards whose question, answer or source title holds every word of the
    /// query, ignoring case and accents. An empty query matches all.
    static func search(_ cards: [LibraryCard], query: String) -> [LibraryCard] {
        let words = foldedWords(query)
        guard !words.isEmpty else { return cards }
        return cards.filter { entry in
            let haystack = foldedText("\(entry.card.question) \(entry.card.answer) \(entry.card.source ?? "")")
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The sources holding the cards, biggest first, as the topics a learner
    /// would name.
    static func topics(_ cards: [LibraryCard]) -> [(title: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in cards {
            let title = (entry.card.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            counts[title.isEmpty ? "Other cards" : title, default: 0] += 1
        }
        return counts.map { (title: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title < $1.title }
    }

    /// The first moment of the day a spoken date means: `daysAgo` (0 today, 1
    /// yesterday) or `date` as yyyy-MM-dd, in the learner's time zone. Nil
    /// when neither is given or the date does not read.
    static func startOfDay(daysAgo: Int?, date: String?, now: Date, calendar: Calendar = .current) -> Date? {
        if let daysAgo, daysAgo >= 0 {
            return calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))
        }
        let parts = (date ?? "").trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        return day.map { calendar.startOfDay(for: $0) }
    }

    /// The cards made on the day starting at `start`, oldest first, with
    /// `days` days in the span (1 for one day).
    static func made(_ cards: [LibraryCard], from start: Date, days: Int = 1, calendar: Calendar = .current) -> [LibraryCard] {
        guard let end = calendar.date(byAdding: .day, value: max(days, 1), to: start) else { return [] }
        return cards.filter { entry in
            guard let made = entry.card.createdAt else { return false }
            return made >= start && made < end
        }
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func cardsByDateTool() -> [String: Any] {
        RealtimeVoiceAssistant.function(
            cardsByDateToolName,
            "The learner's kept cards made on a day, oldest first, due or not: for \"the cards I made yesterday\". Give days_ago (0 today, 1 yesterday, 2 the day before) or date as yyyy-MM-dd; days spans more than one day from there. Cards it returns can be asked and graded with grade_card, or deleted.",
            properties: [
                "days_ago": ["type": "integer", "description": "0 for today, 1 for yesterday, and so on. Use this or date."],
                "date": ["type": "string", "description": "The day as yyyy-MM-dd, when they name a date."],
                "days": ["type": "integer", "description": "How many days the span covers from that day, 1 if left out."],
                "offset": ["type": "integer", "description": "Cards to skip, to reach the rest when more were made than shown."],
                "limit": ["type": "integer", "description": "How many cards, 1 to 20; 10 if left out."],
            ]
        )
    }

    static func searchOutput(_ matches: [LibraryCard], limit: Int, offset: Int = 0) -> String {
        guard !matches.isEmpty else {
            return #"{"cards":[],"matches":0,"note":"No kept card matches. Say so and offer to try other words or list the topics."}"#
        }
        let shown = matches.dropFirst(min(max(offset, 0), matches.count)).prefix(limit)
        guard !shown.isEmpty else {
            return #"{"cards":[],"matches":\#(matches.count),"note":"Nothing is left after that offset. Say that was all of them."}"#
        }
        let rows = shown.map { entry -> [String: Any] in
            var row: [String: Any] = [
                "card_id": entry.card.id,
                "question": clipped(entry.card.question),
                "answer": clipped(entry.card.answer),
                "due_today": entry.dueToday,
            ]
            if let source = entry.card.source, !source.isEmpty { row["source"] = source }
            if let made = entry.card.createdAt { row["made_on"] = dayString(made) }
            return row
        }
        let object: [String: Any] = ["cards": rows, "matches": matches.count, "shown": shown.count]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"cards":[]}"#
    }

    static func topicsOutput(_ cards: [LibraryCard]) -> String {
        let all = topics(cards)
        let rows = all.prefix(topicCap).map { ["topic": $0.title, "cards": $0.count] as [String: Any] }
        let object: [String: Any] = ["topics": rows, "topics_in_all": all.count, "cards_in_all": cards.count]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"topics":[]}"#
    }

    static func searchCardsTool() -> [String: Any] {
        RealtimeVoiceAssistant.function(
            searchCardsToolName,
            "Searches ALL the learner's kept cards, not only today's, by words in the question, the answer or the source's title. Use it when they ask about a subject, a paper or a card they remember. Cards it returns can be asked and graded with grade_card.",
            properties: [
                "query": ["type": "string", "description": "Words to look for; every word must appear. Empty lists cards in no particular order."],
                "limit": ["type": "integer", "description": "How many cards, 1 to 20; 10 if left out."],
            ],
            required: ["query"]
        )
    }

    static func listTopicsTool() -> [String: Any] {
        RealtimeVoiceAssistant.function(
            listTopicsToolName,
            "Lists the sources the learner's kept cards come from, with how many cards each holds, biggest first. Use it when they ask what topics or subjects they have cards on. Name a few aloud, not all.",
            properties: ["query": ["type": "string", "description": "Optional words to narrow the topics to cards matching them."]]
        )
    }

    private static func foldedText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func foldedWords(_ text: String) -> [String] {
        foldedText(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
