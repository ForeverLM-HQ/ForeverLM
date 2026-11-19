import Foundation

/// Memory Check by Voice: today's cards, then today's memory review, as one
/// spoken conversation on OpenAI Realtime, so the whole check can be done
/// walking down the street with the phone in a pocket (product owner,
/// 2026-11-09: "the memory check also fully via voice … so i can do it on my
/// way to the gym in the morning"; "imagine i'm walking on the street and
/// talking to it").
///
/// The review half is the typed review's tutor on the typed review's record:
/// the same briefing and system prompt (`MemoryReviewTutoring.systemPrompt`),
/// the same graders (`grade_memory_contour`, `grade_topic_recall`), validated
/// and acknowledged by the same code, and every graded answer saved as an
/// exchange on the day's review, so the Mac and the typed review on the phone
/// carry on from it. What a screen does in the typed review becomes a tool
/// here, because nothing is on screen: the Next and Go deeper chips are
/// `learner_steered`, the `<flm_source_turn>` heading line is `turn_to`. Voice
/// stays one realtime model with no transcription (product owner, 2026-11-07),
/// so a learner's answer is saved as the model's own account of it, the
/// grader's `learner_said`, the way a source talk's `record_answer` is.
enum RealtimeVoiceMemoryCheck {
    static let title = "Memory Check"

    static let startReviewToolName = "start_memory_review"
    static let steerToolName = "learner_steered"
    static let turnToolName = "turn_to"
    /// Added to both graders: what the learner said, as the model heard it.
    static let learnerSaidField = "learner_said"

    /// A spoken answer as the review saves it: the model's account of the
    /// learner's words, marked as spoken so no reader takes it for a quote.
    static func savedAnswer(learnerSaid: String) -> String {
        let said = learnerSaid.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? RealtimeVoiceTurn.spokenMark : "\(RealtimeVoiceTurn.spokenMark) \(said)"
    }

    /// What the review half is working from.
    struct Review: Sendable {
        /// The day's briefing (plan and material), as the typed review reads it.
        let briefing: String
        /// The review so far, in the typed review's history shape; empty
        /// before anything was asked.
        let history: [(role: String, content: String)]
        let byTopic: Bool
    }

    /// The instructions: the voice rules, the cards (when any are due), and
    /// the typed review's own system prompt with its briefing.
    static func instructions(
        cards: [RealtimeVoiceCardReview.Card],
        dueCards: Int,
        review: Review,
        localClockDescription: String
    ) -> String {
        var parts: [String] = []
        parts.append(voiceRules(byTopic: review.byTopic))
        if cards.isEmpty {
            parts.append("""
            PART ONE, TODAY'S CARDS: none are due. Call \(startReviewToolName) before you say anything, then open \
            the memory review.
            """)
        } else {
            parts.append(cardRules(cardCount: cards.count, dueCards: dueCards))
            let header = dueCards > cards.count
                ? "Today's cards, the first \(cards.count) of \(dueCards) due:"
                : "Today's cards, \(cards.count) due:"
            parts.append("\(header)\n<cards>\n\(RealtimeVoiceCardReview.cardList(cards))\n</cards>")
        }
        parts.append("PART TWO, TODAY'S MEMORY REVIEW. Everything below is the typed review's tutor brief; the voice rules above win wherever it speaks of a screen, chips, typing or turn lines.")
        parts.append(MemoryReviewTutoring.systemPrompt(briefing: review.briefing, localClockDescription: localClockDescription))
        if review.history.contains(where: { $0.role == "user" }) {
            parts.append("""
            THE REVIEW SO FAR (earlier today, typed or spoken). Carry on from its last tutor line: do not open \
            again, and ask that last question again in your own words when you get to the review.
            \(historyText(review.history))
            """)
        } else if let opening = review.history.last(where: { $0.role == "assistant" })?.content {
            parts.append("""
            THE REVIEW'S OPENING, written when it was prepared. When you get to the review, open with it in your \
            own words, spoken, and wait for the answer:
            \(MemoryReviewSourceTurn.stripped(opening))
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The hidden first learner turn.
    static func kickoff(cardCount: Int, resumingReview: Bool) -> String {
        if cardCount > 0 {
            return "(The learner just started their memory check by voice. Say in one short sentence that you have \(cardCount == 1 ? "one card" : "\(cardCount) cards") and then today's review, then ask the first card's question.)"
        }
        return resumingReview
            ? "(The learner just started their memory check by voice. No cards are due. Call \(startReviewToolName), then pick the review up where it stands.)"
            : "(The learner just started their memory check by voice. No cards are due. Call \(startReviewToolName), then open today's review.)"
    }

    private static func voiceRules(byTopic: Bool) -> String {
        let grader = byTopic ? MemoryReviewTutoring.gradeTopicRecallTool.name : MemoryReviewTutoring.gradeMemoryContourTool.name
        let unit = byTopic ? "topic" : "source"
        return """
        You are ForeverLM, running the learner's daily memory check OUT LOUD. They are walking, often outdoors, \
        with the phone in a pocket: nothing is on a screen, there are no chips, cards or headings, and they \
        cannot type. It has two parts in this order: today's cards, then today's memory review.

        Voice rules for the whole conversation:
        - This is live speech. One to three short sentences a turn; one question at a time, then stop and wait. \
        No lists, markdown, URLs, ids or tags out loud, ever.
        - Reply in the language the learner speaks.
        - If you did not catch an answer (wind, traffic), say so briefly and ask them to say it again; never \
        grade what you did not hear.
        - "I don't know", "I don't remember", "pass" or "tell me" is an answer and is graded as one.
        - When they say they are done, stop, or goodbye: say a one-sentence goodbye (in the review, after its \
        close if there is time), then call end_conversation.

        In the review (part two):
        - Call \(startReviewToolName) once, when the cards are done or skipped, before you say anything about \
        the review.
        - The typed review writes a <\(MemoryReviewSourceTurn.tagName) …/> line when it turns to a \(unit). \
        Never say or write that line. Call \(turnToolName) with the \(unit)'s id instead, just before its first \
        question, the first one included.
        - When you call \(grader), always fill \(learnerSaidField): their answer in their own words, as closely \
        as you heard it, in one to three sentences. Nothing is transcribed; this is what is saved as their \
        answer. Grade first, then speak your reply.
        - The chips are words now. When the learner says "next", "move on", "go deeper", "stay on this", \
        "tell me more" or the like, call \(steerToolName) with next or deeper before you reply, and follow \
        what it returns. When a turn would end by waiting for a chip, end it by asking, in a few words, whether \
        to go deeper or move on.
        """
    }

    private static func cardRules(cardCount: Int, dueCards: Int) -> String {
        let more = dueCards > cardCount
            ? " When these are done and more are due, call get_due_cards for the next ones."
            : ""
        return """
        PART ONE, TODAY'S CARDS (spaced repetition, like a friend quizzing them from index cards):
        - Ask one card at a time, in the order below. Put its question in your own words: keep its spirit and \
        meaning, not its exact wording, add a little context from its source when that helps, then wait. Never \
        give the answer before they have tried.
        - Judge by meaning, not wording: they remembered it when their answer has the card's point. Say plainly \
        whether they had it, give the card's answer in one sentence, call grade_card, then ask the next card.
        - A grade is recorded once; if they ask about a card, answer in a sentence or two and carry on.
        - If they say to delete or remove a card, call delete_card with its card_id (only on their clear word, \
        never because it was hard), say in a few words that it is gone and they can say undo (undo_delete_card brings it back), do not grade it, and ask the next card.
        - Say where a card comes from in a few words, its source_kind first ("from a podcast episode on …") and \
        its title when it helps; never "this lecture".\(more)
        - When no card is left (or they ask to skip the cards), say how the cards went in one sentence (how many \
        they had out of how many), then call \(startReviewToolName) and go on to the review.
        """
    }

    private static func historyText(_ history: [(role: String, content: String)]) -> String {
        history.map { turn in
            let who = turn.role == "user" ? "Learner" : "Tutor"
            return "\(who): \(turn.content)"
        }.joined(separator: "\n")
    }

    // MARK: - Tools

    static let startReviewTool: [String: Any] = RealtimeVoiceAssistant.function(
        startReviewToolName,
        "Marks the start of today's memory review, after the cards. Call it once, before you say anything about the review."
    )

    static let steerTool: [String: Any] = RealtimeVoiceAssistant.function(
        steerToolName,
        "The learner said Next (move on) or Go deeper (stay on this one), in any words. Call it before replying; follow what it returns.",
        properties: [
            "steer": ["type": "string", "enum": ["next", "deeper"], "description": "next to move on, deeper to stay."],
        ],
        required: ["steer"]
    )

    static func turnTool(byTopic: Bool) -> [String: Any] {
        RealtimeVoiceAssistant.function(
            turnToolName,
            byTopic
                ? "The review is turning to a topic: call it just before the topic's first question, with its id exactly as the briefing gives it (topic-1, topic-2, …)."
                : "The review is turning to a source: call it just before the source's first question, with its id exactly as the briefing gives it.",
            properties: ["id": ["type": "string", "description": byTopic ? "The topic id." : "The source id."]],
            required: ["id"]
        )
    }

    /// The typed review's grader in Realtime's shape, with `learner_said`
    /// required beside its own fields.
    static func gradeTool(byTopic: Bool) -> [String: Any] {
        let definition = byTopic ? MemoryReviewTutoring.gradeTopicRecallTool : MemoryReviewTutoring.gradeMemoryContourTool
        let request = definition.requestDictionary
        var parameters = (request["parameters"] as? [String: Any]) ?? ["type": "object"]
        var properties = (parameters["properties"] as? [String: Any]) ?? [:]
        properties[learnerSaidField] = [
            "type": "string",
            "description": "What the learner said, in their words as closely as you heard them, one to three sentences. Saved as their answer.",
        ]
        parameters["properties"] = properties
        parameters["required"] = ((parameters["required"] as? [String]) ?? []) + [learnerSaidField]
        return [
            "type": "function",
            "name": definition.name,
            "description": (request["description"] as? String ?? "") + " Fill learner_said with what they said.",
            "parameters": parameters,
        ]
    }
}

/// What the review's record is told, worked out from the conversation as it
/// goes: the turns of the typed review, rebuilt from the voice one. A graded
/// answer or a steer is a turn; its reply is everything ForeverLM said after
/// it, up to the next turn (or the end), so a turn is saved once its reply is
/// known, one step behind, and the last one when the conversation ends.
/// ForeverLM's lines are indexes into the controller's transcript, read when
/// a turn is saved, by which time their words are final.
struct RealtimeVoiceMemoryCheckLedger: Sendable {
    /// One write to the day's review.
    enum Write: Equatable, Sendable {
        /// The opening question of a review nothing was asked in yet.
        case opening(question: String)
        case turn(answer: String, reply: String, grade: MemoryContourGrade?, steer: MemoryReviewSteer?)
    }

    struct Pending: Equatable, Sendable {
        let answer: String
        let grade: MemoryContourGrade?
        let steer: MemoryReviewSteer?
    }

    /// The reply of a turn the conversation ended on.
    static let stoppedHere = "(The spoken review stopped here.)"

    /// Whether the record had a question in it when the call began.
    let reviewHadQuestion: Bool
    private(set) var reviewStart: Int?
    private var segmentStart: Int?
    private(set) var pending: Pending?
    private var openingSaved = false
    /// `turn_to` calls: the transcript index the heading line goes before.
    private var turnMarks: [(index: Int, id: String)] = []

    init(reviewHadQuestion: Bool) {
        self.reviewHadQuestion = reviewHadQuestion
    }

    var hasStarted: Bool { reviewStart != nil }

    /// `start_memory_review`: what ForeverLM says from here on is the review's.
    mutating func startReview(at index: Int) {
        guard reviewStart == nil else { return }
        reviewStart = index
        segmentStart = index
    }

    /// `turn_to`: the heading line goes before what is said from here.
    mutating func turn(to id: String, at index: Int) {
        // A turn before the start marks the start: the model went straight in.
        if reviewStart == nil { startReview(at: index) }
        turnMarks.append((index, id))
    }

    /// A graded answer or a steer arrives at `index`: the turn before it is
    /// saved, now that its reply is known. Called before the new turn is
    /// checked, so the record it is checked against has the one before it.
    mutating func close(at index: Int, transcript: [RealtimeVoiceTurn]) -> [Write] {
        if reviewStart == nil { startReview(at: index) }
        let said = text(from: segmentStart ?? 0, to: index, transcript: transcript)
        defer {
            pending = nil
            segmentStart = index
        }
        if let pending {
            // A turn with nothing said after it (the call ended on the grade)
            // still saves its answer and grade; its reply says where it stopped,
            // since the record asks it as the next question.
            return [.turn(answer: pending.answer, reply: said.isEmpty ? Self.stoppedHere : said, grade: pending.grade, steer: pending.steer)]
        }
        // Before the first turn: an empty review's opening question. A review
        // that had one heard it asked again, which is not saved twice.
        guard !reviewHadQuestion, !openingSaved, !said.isEmpty else { return [] }
        openingSaved = true
        return [.opening(question: said)]
    }

    /// The turn that `close` made room for, saved by the next `close`.
    mutating func begin(_ next: Pending) {
        pending = next
    }

    /// The conversation ended: the last turn, with what was said after it.
    mutating func finish(transcript: [RealtimeVoiceTurn]) -> [Write] {
        guard reviewStart != nil else { return [] }
        return close(at: transcript.count, transcript: transcript)
    }

    /// ForeverLM's lines in `[from, to)`, with a heading line before the
    /// first line each `turn_to` precedes.
    func text(from start: Int, to end: Int, transcript: [RealtimeVoiceTurn]) -> String {
        guard start < end else { return "" }
        var pieces: [String] = []
        for index in start..<min(end, transcript.count) {
            for mark in turnMarks where mark.index == index {
                pieces.append(MemoryReviewSourceTurn.line(sourceID: mark.id))
            }
            let turn = transcript[index]
            guard turn.role == .tutor else { continue }
            let line = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { pieces.append(line) }
        }
        // A turn called after the last line said in range still heads what follows.
        for mark in turnMarks where mark.index >= transcript.count && mark.index >= start && mark.index < end {
            pieces.append(MemoryReviewSourceTurn.line(sourceID: mark.id))
        }
        // A heading line with nothing after it heads nothing.
        while let last = pieces.last, last.hasPrefix("<\(MemoryReviewSourceTurn.tagName)") {
            pieces.removeLast()
        }
        return pieces.joined(separator: "\n\n")
    }
}
