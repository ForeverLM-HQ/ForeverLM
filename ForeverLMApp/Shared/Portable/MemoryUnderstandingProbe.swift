import Foundation

/// Going past recall once an idea has come back: the four understanding
/// probes (docs/memory-design.md, "Go deeper: understanding probes").
///
/// Recall says an idea came back; it does not say the learner understands it.
/// The product owner approved four probes on 2026-10-06, from a guide to understanding
/// anything: the principle behind the idea, said with no proper nouns
/// (abstraction), where else it applies (transfer), what evidence would prove
/// it wrong (falsification), and what it is like — a nearby idea from a source
/// in another notebook, and what the two share (analogy). They are asked only
/// once nothing is left to recall, one at a time and rotating, and never as a
/// gate: Go deeper and Next stay one press apart.
///
/// Two places ask them. The review chat's Go deeper asks one when the topic
/// (or source) has nothing missing or partial: the client works out which kind
/// comes next, which idea, and for an analogy the partner, and tells the tutor
/// beside the learner's words (`reviewNote`). The Mac's card review asks one
/// after Go Deeper on a remembered card (`CardQuestionRequest`).
///
/// An answer to a probe is graded on the probed idea with the probe's kind as
/// its operation (`MemoryQuestionOperation.principle` …), and that grade says
/// how deep the understanding went, never whether the idea came back: it sets
/// no status, veils no row and counts no miss (`MemoryReviewIdeaState.fold`),
/// and it moves no schedule (`MemoryLadderEvidence` hears each idea's first
/// grade of the day, which a probe never is: the grader refuses one before
/// the idea's recall).
///
/// Foundation-only, compiled by the Mac and the iPhone. The website runs no
/// memory review, so the WebAssembly build leaves it out with the review's
/// other portable files.
enum MemoryUnderstandingProbe {

    /// What a probe asks for, in the order they rotate.
    enum Kind: String, CaseIterable, Codable, Sendable {
        case principle
        case transfer
        case falsify
        case analogy

        /// The operation a grade of an answer to this probe records.
        var operation: MemoryQuestionOperation {
            switch self {
            case .principle: return .principle
            case .transfer: return .transfer
            case .falsify: return .falsify
            case .analogy: return .analogy
            }
        }

        /// The kind an operation names; nil for a recall's.
        init?(operation: MemoryQuestionOperation) {
            switch operation {
            case .principle: self = .principle
            case .transfer: self = .transfer
            case .falsify: self = .falsify
            case .analogy: self = .analogy
            case .recall, .explain, .contrast, .apply, .connect: return nil
            }
        }

        /// The card review's eyebrow over the question, after "GO DEEPER · ".
        var eyebrow: String {
            switch self {
            case .principle: return "THE PRINCIPLE"
            case .transfer: return "WHERE ELSE"
            case .falsify: return "WHAT WOULD PROVE IT WRONG"
            case .analogy: return "WHAT IT'S LIKE"
            }
        }

        /// What the probe asks for, in the words every tutor that asks one
        /// reads: the review chat's, MCP's conduct, and the card review's
        /// question writer.
        var tutorDescription: String {
            switch self {
            case .principle:
                return "the general rule behind the idea, said with no proper nouns — no people, places, organisms, "
                    + "products or papers — so it would still hold with every particular swapped out"
            case .transfer:
                return "where else the idea applies: a different field or situation, one the source never mentions, "
                    + "where the same mechanism or reasoning works, and what it would predict there"
            case .falsify:
                return "what evidence would prove the idea wrong: a concrete observation or result that, if it turned up, "
                    + "would break it, and why it would"
            case .analogy:
                return "what the idea is like: set beside a nearby idea from a source in another notebook, "
                    + "what the two share and where the likeness breaks"
            }
        }
    }

    /// The four kinds in one sentence, for conduct instructions.
    static let kindsLine = Kind.allCases
        .map { "\($0.rawValue.uppercased()) (\($0.tutorDescription))" }
        .joined(separator: "; ")

    // MARK: - Rotation

    /// The kinds in the order they come next: from the one after `last`
    /// round the cycle, `last` itself coming back only at the end, and the
    /// analogy left out when there is no partner to set the idea beside.
    /// Never empty. The first one is the next probe; the card review hands
    /// the whole list to its question writer, which takes the first that fits
    /// the card.
    static func rotation(after last: Kind?, includesAnalogy: Bool) -> [Kind] {
        let cycle = Kind.allCases
        let start = last.flatMap { cycle.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let ordered = cycle.indices.map { cycle[(start + $0) % cycle.count] }
        return includesAnalogy ? ordered : ordered.filter { $0 != .analogy }
    }

    /// The probe after `last`.
    static func next(after last: Kind?, includesAnalogy: Bool) -> Kind {
        rotation(after: last, includesAnalogy: includesAnalogy)[0]
    }

    /// The kind of the newest understanding grade among a review's saved
    /// operations, given oldest first; nil before any.
    static func lastKind(operations: [String?]) -> Kind? {
        for raw in operations.reversed() {
            if let operation = raw.flatMap(MemoryQuestionOperation.init(rawValue:)), let kind = Kind(operation: operation) {
                return kind
            }
        }
        return nil
    }

    // MARK: - Which idea

    /// Whether everything of `ideaIDs` that was asked came back in full: at
    /// least one was graded today, and every graded one's latest recall grade
    /// is produced. What turns Go deeper from chasing what did not come back
    /// into an understanding probe. An idea no grade reached (one whose text
    /// was not loaded when the topic opened, so the grader never cued it)
    /// does not hold the rest back; a topic not opened yet is not recalled.
    static func isRecalled(ideaIDs: [String], states: [String: MemoryReviewIdeaState]) -> Bool {
        let graded = ideaIDs.compactMap { states[$0] }
        return !graded.isEmpty && graded.allSatisfy { $0.status == .produced }
    }

    /// The idea a probe goes deeper on: the one of `ideaIDs` probed least
    /// today, wanted ideas (anchored on what the learner highlighted) before
    /// the rest, then in the order given. Nil for no ideas.
    static func probeTarget(ideaIDs: [String], wanted: Set<String>, states: [String: MemoryReviewIdeaState]) -> String? {
        ideaIDs.enumerated().min { lhs, rhs in
            let probedL = states[lhs.element]?.understanding?.count ?? 0
            let probedR = states[rhs.element]?.understanding?.count ?? 0
            if probedL != probedR { return probedL < probedR }
            let wantedL = wanted.contains(lhs.element), wantedR = wanted.contains(rhs.element)
            if wantedL != wantedR { return wantedL }
            return lhs.offset < rhs.offset
        }?.element
    }

    // MARK: - The analogy's partner

    /// A notebook a source belongs to.
    struct Notebook: Equatable, Sendable {
        let id: String
        let title: String
    }

    /// The nearby idea an analogy sets the probed idea beside: one of a source's
    /// extracted ideas, from a source in another notebook.
    struct AnalogyPartner: Equatable, Sendable {
        let sourceID: String
        let sourceTitle: String
        let notebookTitle: String
        let statement: String
    }

    /// Whether a source held by `notebooks` sits in another notebook than the
    /// probed idea's: it is in at least one, and in none of `anchorNotebookIDs`.
    /// A source in no notebook has none to name, so it is never a partner.
    static func isInAnotherNotebook(_ notebooks: [Notebook], than anchorNotebookIDs: Set<String>) -> Bool {
        !notebooks.isEmpty && notebooks.allSatisfy { !anchorNotebookIDs.contains($0.id) }
    }

    /// The idea a partner source lends: a wanted one first, else its first in
    /// extraction order.
    static func partnerIdea(_ ideas: [SourceIdea]) -> SourceIdea? {
        ideas.first(where: \.wanted) ?? ideas.first
    }

    /// Several rankings merged rank by rank — every list's first, then every
    /// list's second — each id once. Apple's on-device embedder is
    /// anisotropic, so scores from two query vectors cannot be compared: the
    /// merge keeps ranks and never looks at a score (the bridges' rule,
    /// `StorageService.selectBridges`).
    static func interleaved(_ rankings: [[String]]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()
        let depth = rankings.map(\.count).max() ?? 0
        for rank in 0..<depth {
            for ranking in rankings where rank < ranking.count {
                if seen.insert(ranking[rank]).inserted { merged.append(ranking[rank]) }
            }
        }
        return merged
    }

    /// The Mac's partner: the first of `ranked` — sources nearest the
    /// probed idea's, by their source embeddings — that is not one of the
    /// `anchors`, is outside the knowledge boundary's `excluded`, has a
    /// title to name (an active, visible source), sits in another notebook
    /// than every anchor, and has an idea to lend.
    static func analogyPartner(
        ranked: [String],
        anchors: [String],
        notebooksBySource: [String: [Notebook]],
        titles: [String: String],
        ideasBySource: [String: [SourceIdea]],
        excluded: Set<String>
    ) -> AnalogyPartner? {
        let anchorSet = Set(anchors)
        let anchorNotebooks = Set(anchors.flatMap { notebooksBySource[$0] ?? [] }.map(\.id))
        for sourceID in ranked where !anchorSet.contains(sourceID) && !excluded.contains(sourceID) {
            guard let title = titles[sourceID],
                  let notebooks = notebooksBySource[sourceID],
                  isInAnotherNotebook(notebooks, than: anchorNotebooks),
                  let idea = partnerIdea(ideasBySource[sourceID] ?? []) else { continue }
            return AnalogyPartner(sourceID: sourceID, sourceTitle: title, notebookTitle: notebooks[0].title, statement: idea.statement)
        }
        return nil
    }

    /// The iPhone's partner, which has no vector index: an idea of another of
    /// today's topics whose source sits in another notebook than every source
    /// of `topic`. Only an idea that came back in full today is lent — an
    /// analogy names its partner, and a missing idea is never read out, nor
    /// one a later topic has yet to ask. Topics in their order, a topic's
    /// wanted ideas first. Nil when no topic offers one: the rotation then
    /// leaves the analogy out.
    static func analogyPartner(
        forTopic topic: MemoryReviewTopic,
        among topics: [MemoryReviewTopic],
        ideasByID: [String: SourceIdea],
        states: [String: MemoryReviewIdeaState],
        notebooksBySource: [String: [Notebook]],
        titles: [String: String]
    ) -> AnalogyPartner? {
        let anchors = Set(topic.ideaIDs.compactMap(SourceIdea.sourceID(fromIdeaID:)))
        let anchorNotebooks = Set(anchors.flatMap { notebooksBySource[$0] ?? [] }.map(\.id))
        for other in topics where other.id != topic.id {
            let ideas = other.ideaIDs.compactMap { ideasByID[$0] }
            let ordered = ideas.filter(\.wanted) + ideas.filter { !$0.wanted }
            for idea in ordered where !anchors.contains(idea.sourceID) && states[idea.id]?.status == .produced {
                guard let title = titles[idea.sourceID],
                      let notebooks = notebooksBySource[idea.sourceID],
                      isInAnotherNotebook(notebooks, than: anchorNotebooks) else { continue }
                return AnalogyPartner(sourceID: idea.sourceID, sourceTitle: title, notebookTitle: notebooks[0].title, statement: idea.statement)
            }
        }
        return nil
    }

    // MARK: - The review chat

    /// What the review chat's tutor is told beside the learner's "Go deeper."
    /// when everything on the card came back: the probe, the idea, the
    /// partner, and how the answer is graded. `topicID` is the topic the
    /// grade is for; nil in a review planned source by source, whose contour
    /// is graded once and whose probes are answered without the grader.
    static func reviewNote(
        kind: Kind,
        ideaID: String,
        topicID: String?,
        partner: AnalogyPartner?
    ) -> String {
        var parts: [String] = [
            "[ForeverLM] Everything here came back, so this Go deeper goes past recall into understanding.",
            "Ask ONE \(kind.rawValue.uppercased()) probe on idea [\(ideaID)]: \(kind.tutorDescription).",
        ]
        if kind == .analogy, let partner {
            parts.append(
                "The nearby idea is from \(partner.sourceTitle), in the notebook \(partner.notebookTitle): \"\(partner.statement)\" "
                    + "Name it in your question, since it is not theirs to recall, and ask what the two share."
            )
        }
        parts.append(
            "Compose the wording yourself under the question rules, never reusing a question already asked about this idea, "
                + "and say nothing about their answer before they give it."
        )
        if let topicID {
            parts.append(
                "When they answer, call grade_topic_recall for \(topicID) with one idea_coverage entry, [\(ideaID)] alone, "
                    + "and operation \"\(kind.operation.rawValue)\": produced when the answer gets there, partial when it gets part of the way, "
                    + "missing when it does not. That grade says how deep their understanding goes; it never takes back that the idea came back."
            )
        } else {
            parts.append("When they answer, do not call the grader: this source's contour is already graded.")
        }
        parts.append(
            "Then reply in two or three sentences, what their answer got and what it missed or could add, with no score and no flattery, and stop."
        )
        return parts.joined(separator: " ")
    }

    /// What the tutor is told once an understanding probe's grade is
    /// accepted, in place of a recall's acknowledgement.
    static func gradeAcknowledgement(kind: Kind, grade: MemoryContourGrade) -> String {
        let status = grade.coverage.first?.status.rawValue ?? "missing"
        return "Recorded the \(kind.rawValue) probe as \(status). It says how deep their understanding goes, not whether the idea came back: "
            + "it veils nothing and moves no schedule. Reply in two or three sentences: what their answer got, then what it missed or could add, "
            + "with no score and no flattery. Then stop: ask no new question and do not move on. "
            + "The learner chooses Go deeper, for a probe of another kind, or Next topic."
    }

    // MARK: - The card review

    /// What the card review's question writer is given for one card.
    struct CardQuestionRequest: Equatable, Sendable {
        let front: String
        let back: String
        let why: [String]
        let sourceTitle: String?
        /// The kinds in rotation order; the writer takes the first that fits.
        let kinds: [Kind]
        /// The nearby idea an analogy would use; nil leaves the analogy out of
        /// `kinds`.
        let partner: AnalogyPartner?
    }

    /// The question the card review asks after Go Deeper.
    struct CardQuestion: Equatable, Sendable {
        let kind: Kind
        let text: String
    }

    /// What the card review's reply writer is given: the card, the question,
    /// and the learner's answer.
    struct CardReplyRequest: Equatable, Sendable {
        let front: String
        let back: String
        let why: [String]
        let sourceTitle: String?
        let question: CardQuestion
        let answer: String
        let partner: AnalogyPartner?
    }

    /// A writer's response that cannot be read as what was asked for.
    enum ResponseError: Error, Equatable, LocalizedError {
        case unreadable

        var errorDescription: String? {
            "The model's answer could not be read."
        }
    }

    /// The question writer's user message (`Prompts.goDeeperQuestion` is its
    /// system prompt).
    static func cardQuestionMessage(_ request: CardQuestionRequest) -> String {
        var lines = cardLines(front: request.front, back: request.back, why: request.why, sourceTitle: request.sourceTitle)
        lines.append("")
        lines.append("KINDS, in the order to try (take the first that fits this card):")
        for kind in request.kinds {
            lines.append("- \(kind.rawValue): \(kind.tutorDescription)")
        }
        if request.kinds.contains(.analogy), let partner = request.partner {
            lines.append("")
            lines.append("THE NEARBY IDEA, for analogy, from \(partner.sourceTitle) in the notebook \(partner.notebookTitle):")
            lines.append(partner.statement)
        }
        return lines.joined(separator: "\n")
    }

    /// The question in a writer's JSON response: `{"kind": …, "question": …}`,
    /// or nil for `{"kind": "none"}` (the card is a bare fact no kind fits).
    /// A kind that was not offered, or an empty question, is unreadable.
    static func cardQuestion(from response: String, offered kinds: [Kind]) throws -> CardQuestion? {
        struct Payload: Decodable {
            let kind: String
            let question: String?
        }
        let payload: Payload
        do {
            payload = try MemoryReviewPlanning.decodeJSON(response)
        } catch {
            throw ResponseError.unreadable
        }
        let rawKind = payload.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawKind == "none" { return nil }
        guard let kind = Kind(rawValue: rawKind), kinds.contains(kind) else { throw ResponseError.unreadable }
        let text = (payload.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ResponseError.unreadable }
        return CardQuestion(kind: kind, text: text)
    }

    /// The reply writer's user message (`Prompts.goDeeperReply`).
    static func cardReplyMessage(_ request: CardReplyRequest) -> String {
        var lines = cardLines(front: request.front, back: request.back, why: request.why, sourceTitle: request.sourceTitle)
        lines.append("")
        lines.append("THE PROBE: \(request.question.kind.rawValue), \(request.question.kind.tutorDescription)")
        if request.question.kind == .analogy, let partner = request.partner {
            lines.append("The nearby idea, from \(partner.sourceTitle) in the notebook \(partner.notebookTitle): \(partner.statement)")
        }
        lines.append("THE QUESTION: \(request.question.text)")
        lines.append("")
        lines.append("THE LEARNER'S ANSWER:")
        lines.append(request.answer)
        return lines.joined(separator: "\n")
    }

    /// The reply, trimmed; an empty one is unreadable.
    static func cardReply(from response: String) throws -> String {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ResponseError.unreadable }
        return text
    }

    private static func cardLines(front: String, back: String, why: [String], sourceTitle: String?) -> [String] {
        var lines = ["THE CARD", "Front: \(front)", "Back: \(back)"]
        let reasons = why.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !reasons.isEmpty { lines.append("Why: \(reasons.joined(separator: " "))") }
        if let sourceTitle, !sourceTitle.isEmpty { lines.append("Source: \(sourceTitle)") }
        return lines
    }
}
