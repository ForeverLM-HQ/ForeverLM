import Foundation

/// One exchange lifted out of a memory review and handed to an ordinary chat.
///
/// A memory review is a graded conversation: the tutor asks, the learner
/// retrieves, the grader marks which ideas came back, and the chips steer to
/// the next contour. Sometimes what the learner wants after a grade is not the
/// next question but to *talk about this one* — why the answer was wrong, what
/// the idea they missed actually says — and that conversation does not belong
/// in the review, where it would be graded as another attempt and would move
/// the source's rung. So the exchange goes to a new chat beside the review,
/// the way a passage goes from the Reader or a Doc: as pending context under
/// the composer, persisted on the first exchange when the learner sends, and
/// never as words the learner typed.
///
/// The value is what the new chat needs to know about the exchange and nothing
/// the model could read back from storage: the words of the three turns, the
/// ideas the grader marked partial or missing by their statement (the ids mean
/// nothing to a chat), the sources the question stood on, and which review it
/// came from. Foundation only, so the same shape can travel to the phone.
struct MemoryReviewChatHandoff: Equatable, Sendable {
    /// One idea the grader did not hear back in full.
    struct MissedIdea: Equatable, Sendable {
        let statement: String
        let status: MemoryIdeaCoverage.Status
    }

    /// The review chat this came out of.
    let reviewSessionID: String
    /// How the review reads in the rail: its date, or the title the learner gave it.
    let reviewTitle: String
    /// The exchange the learner lifted out.
    let exchangeID: String
    let question: String
    let learnerAnswer: String?
    let evaluation: String?
    let missedIdeas: [MissedIdea]
    /// The sources the question stood on, or the review's when the exchange
    /// recorded none.
    let sourceIDs: [String]

    /// What the tutor is told about this context, once, ahead of the learner's
    /// first message. The review is graded and steered; this chat is neither.
    static let framing = """
    The learner lifted this exchange out of their memory review to talk it through here, \
    in an ordinary chat. Explain, answer their question, and go as deep as they like. \
    Do not grade them, do not score or mark ideas as recalled, and do not continue the \
    review or ask the next review question — the review is still open in its own chat.
    """

    /// The one line the pending-context chip shows: the tutor's question,
    /// which is what the learner will recognise this exchange by. The review's
    /// opening message is a briefing with the first contour as its last
    /// paragraph, so a multi-paragraph question is read by its last paragraph;
    /// the model still gets the whole message in `transcript`.
    var headline: String {
        let paragraphs = question
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = paragraphs.last else { return "An exchange from \(reviewTitle)" }
        return last
    }

    /// The exchange as the model reads it: three labelled turns, the ones the
    /// exchange has. A question the learner never answered is one line.
    var transcript: String {
        var lines: [String] = []
        let tutor = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tutor.isEmpty { lines.append("Tutor: \(tutor)") }
        if let answer = learnerAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            lines.append("Learner: \(answer)")
        }
        if let grade = evaluation?.trimmingCharacters(in: .whitespacesAndNewlines), !grade.isEmpty {
            lines.append("Grader: \(grade)")
        }
        return lines.joined(separator: "\n")
    }

    /// The block that goes into the first exchange's `context_content`, so the
    /// chat still knows what it is about when it is reopened next month.
    var contextualContent: String {
        var blocks = ["From the memory review \"\(reviewTitle)\":\n\(transcript)"]
        if !missedIdeas.isEmpty {
            let lines = missedIdeas.map { idea -> String in
                let mark = idea.status == .partial ? "partly recalled" : "not recalled"
                return "- \(idea.statement) (\(mark))"
            }
            blocks.append("Ideas the grader did not hear back in full:\n" + lines.joined(separator: "\n"))
        }
        blocks.append(Self.framing)
        return blocks.joined(separator: "\n\n")
    }

    /// The ideas an exchange's grade marked partial or missing, by statement,
    /// in the order the grade listed them. `ideaCoverage` is the exchange's
    /// stored `[MemoryIdeaCoverage]` JSON; an exchange that was never graded,
    /// or whose grade names ideas that have since been retired out of `ideas`,
    /// contributes nothing rather than an id.
    static func missedIdeas(coverageJSON: String?, ideas: [SourceIdea]) -> [MissedIdea] {
        guard let coverageJSON, let data = coverageJSON.data(using: .utf8),
              let coverage = try? JSONDecoder().decode([MemoryIdeaCoverage].self, from: data) else {
            return []
        }
        let statements = Dictionary(ideas.map { ($0.id, $0.statement) }, uniquingKeysWith: { first, _ in first })
        return coverage.compactMap { entry in
            guard entry.status != .produced,
                  let statement = statements[entry.ideaID]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !statement.isEmpty else { return nil }
            return MissedIdea(statement: statement, status: entry.status)
        }
    }

    /// Builds the handoff for one stored exchange of a review.
    ///
    /// - Parameters:
    ///   - reviewTitle: the review's stored title; a legacy "Memory · " title is
    ///     read as its date the way the rail reads it.
    ///   - ideas: the ideas of the exchange's sources, for the statements
    ///     behind the grade's ids.
    ///   - fallbackSourceIDs: the review's own sources, used when the exchange
    ///     recorded none of its own.
    init(
        exchange: ReviewExchangeRecord,
        reviewTitle: String,
        ideas: [SourceIdea],
        fallbackSourceIDs: [String],
        calendar: Calendar = .current
    ) {
        reviewSessionID = exchange.sessionID
        self.reviewTitle = MemoryReviewSession.displayTitle(
            storedTitle: reviewTitle, sessionID: exchange.sessionID, calendar: calendar
        )
        exchangeID = exchange.id
        question = exchange.question
        learnerAnswer = exchange.userAnswer
        evaluation = exchange.evaluation
        missedIdeas = Self.missedIdeas(coverageJSON: exchange.ideaCoverage, ideas: ideas)
        sourceIDs = exchange.sourceRefs.isEmpty ? fallbackSourceIDs : exchange.sourceRefs
    }

    init(
        reviewSessionID: String,
        reviewTitle: String,
        exchangeID: String,
        question: String,
        learnerAnswer: String?,
        evaluation: String?,
        missedIdeas: [MissedIdea],
        sourceIDs: [String]
    ) {
        self.reviewSessionID = reviewSessionID
        self.reviewTitle = reviewTitle
        self.exchangeID = exchangeID
        self.question = question
        self.learnerAnswer = learnerAnswer
        self.evaluation = evaluation
        self.missedIdeas = missedIdeas
        self.sourceIDs = sourceIDs
    }
}

extension ReaderSelectionExplanationRequest {
    /// The handoff as the request the chat pane already knows how to stage:
    /// the question is the chip's line, the exchange and the framing are the
    /// model-only context, and the exchange's sources become the chat's.
    init(reviewHandoff handoff: MemoryReviewChatHandoff) {
        self.init(
            sourceIDs: handoff.sourceIDs,
            selectedText: handoff.headline,
            contextTitle: "Memory review: \(handoff.reviewTitle)",
            reviewHandoff: handoff
        )
    }
}
