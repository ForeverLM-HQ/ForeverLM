import Foundation

/// The grader's structured result for one contour recall: which of the
/// source's ideas came back, an overall score, whether the question was fit to
/// grade, and the operation it asked for.
///
/// Built only by `validate`, which checks every idea id against the ideas the
/// review actually carries. A model asserts idea ids; it never chooses them,
/// and a grade that names an idea the source does not have is refused whole
/// rather than trimmed, because a partial grade would move a rung on evidence
/// the learner never produced.
struct MemoryContourGrade: Equatable, Sendable {
    let sourceID: String
    let coverage: [MemoryIdeaCoverage]
    let score: Double
    let verdict: MemoryQuestionVerdict
    let operation: MemoryQuestionOperation
    let evaluation: String?

    /// What moves the source's rung. nil when the question was ambiguous: the
    /// answer is graded on the idea, but the schedule does not hear about it.
    var producedFractionForLadder: Double? {
        verdict == .ambiguous ? nil : MemoryIdeaCoverage.producedFraction(coverage)
    }

    var missingIdeaIDs: [String] {
        coverage.filter { $0.status != .produced }.map(\.ideaID)
    }

    enum ValidationError: Error, Equatable, Sendable {
        case missingSource
        case unknownSource(String)
        case sourceHasNoIdeas(String)
        case missingCoverage
        case foreignIdea(String)
        case duplicateIdea(String)
        case incompleteCoverage([String])
        case badStatus(String)
        /// Carries what arrived in `score`, so the model reads back exactly
        /// what to fix rather than a generic range rule.
        case badScore(received: String)
        case badVerdict(String)
        case badOperation(String)
        /// An understanding probe's operation on a grade that is a recall: a
        /// contour, a topic's opening, or an idea no recall has graded yet.
        /// `reason` says which, in the words the message reads back.
        case understandingBeforeRecall(operation: String, reason: String)
        case missingTopic
        case unknownTopic(String)
        case foreignTopicIdea(topicID: String, ideaID: String)
        case incompleteTopicCoverage(topicID: String, missing: [String])

        /// What the model reads back. Each says how to re-emit the call.
        var message: String {
            switch self {
            case .missingSource:
                return "Error: source_id is required and must be one of the sources in today's review."
            case .unknownSource(let id):
                return "Error: source_id \(id) is not in today's review. Grade only the sources listed in the briefing."
            case .sourceHasNoIdeas(let id):
                return "Error: source \(id) carries no ideas to grade against; do not call the grader for it."
            case .missingCoverage:
                return "Error: idea_coverage is required: one entry per idea of the source, each with idea_id and status."
            case .foreignIdea(let id):
                return "Error: idea \(id) does not belong to the graded source. Use the idea ids listed under that source in the briefing, exactly."
            case .duplicateIdea(let id):
                return "Error: idea \(id) appears twice in idea_coverage. Grade each idea once."
            case .incompleteCoverage(let ids):
                return "Error: idea_coverage must grade every idea of the source. Missing: \(ids.joined(separator: ", ")). Mark an idea the learner did not mention as missing."
            case .badStatus(let raw):
                return "Error: status \"\(raw)\" is not one of produced, partial, missing."
            case .badScore(let received):
                return "Error: score must be a finite number from 0.0 to 1.0; it arrived as \(received). "
                    + "When nothing came back, the score is 0.0, not null. "
                    + "Call grade_memory_contour again with the same idea_coverage and the score as a number; do not change the grade to make it pass."
            case .badVerdict(let raw):
                return "Error: question_verdict \"\(raw)\" is not one of sound, ambiguous."
            case .badOperation(let raw):
                let names = MemoryQuestionOperation.allCases.map(\.rawValue).joined(separator: ", ")
                return "Error: operation \"\(raw)\" is not one of \(names)."
            case .understandingBeforeRecall(let operation, let reason):
                return "Error: operation \"\(operation)\" grades an understanding probe, which goes past an idea that already came back, "
                    + "but \(reason). Grade a contour or a topic's opening answer as recall (connect for a connection), "
                    + "and an understanding probe only after the idea's recall, on the probed idea alone."
            case .missingTopic:
                return "Error: topic_id is required and must be one of the topics in today's review (topic-1, topic-2, …)."
            case .unknownTopic(let id):
                return "Error: topic_id \(id) is not in today's review. Grade only the topics listed under TOPICS in the briefing."
            case .foreignTopicIdea(let topicID, let ideaID):
                return "Error: idea \(ideaID) is not one of \(topicID)'s ideas. Use the idea ids listed under that topic in the briefing, exactly."
            case .incompleteTopicCoverage(let topicID, let missing):
                return "Error: the opening answer to \(topicID) must grade every idea the topic lists. Missing: \(missing.joined(separator: ", ")). Mark an idea the learner did not mention as missing."
            }
        }
    }

    /// Checks a `grade_memory_contour` call against the ideas the review knows.
    /// `ideasBySource` holds each review source's active ideas.
    static func validate(
        arguments: [String: Any],
        ideasBySource: [String: [SourceIdea]]
    ) -> Result<MemoryContourGrade, ValidationError> {
        guard let sourceID = (arguments["source_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty else {
            return .failure(.missingSource)
        }
        guard let ideas = ideasBySource[sourceID] else {
            return .failure(.unknownSource(sourceID))
        }
        guard !ideas.isEmpty else {
            return .failure(.sourceHasNoIdeas(sourceID))
        }
        guard let rawCoverage = arguments["idea_coverage"] as? [[String: Any]], !rawCoverage.isEmpty else {
            return .failure(.missingCoverage)
        }

        let knownIDs = Set(ideas.map(\.id))
        var seen = Set<String>()
        var coverage: [MemoryIdeaCoverage] = []
        for entry in rawCoverage {
            guard let ideaID = (entry["idea_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !ideaID.isEmpty else {
                return .failure(.missingCoverage)
            }
            guard knownIDs.contains(ideaID) else { return .failure(.foreignIdea(ideaID)) }
            guard seen.insert(ideaID).inserted else { return .failure(.duplicateIdea(ideaID)) }
            let rawStatus = (entry["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard let status = MemoryIdeaCoverage.Status(rawValue: rawStatus) else {
                return .failure(.badStatus(rawStatus))
            }
            coverage.append(MemoryIdeaCoverage(ideaID: ideaID, status: status))
        }
        let missing = ideas.map(\.id).filter { !seen.contains($0) }
        guard missing.isEmpty else { return .failure(.incompleteCoverage(missing)) }

        guard let score = ToolArgumentNumber.value(arguments["score"]), score.isFinite, (0...1).contains(score) else {
            return .failure(.badScore(received: ToolArgumentNumber.describe(arguments["score"])))
        }

        let verdict: MemoryQuestionVerdict
        if let rawVerdict = arguments["question_verdict"] as? String {
            let trimmed = rawVerdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let parsed = MemoryQuestionVerdict(rawValue: trimmed) else {
                return .failure(.badVerdict(trimmed))
            }
            verdict = parsed
        } else {
            verdict = .sound
        }

        let operation: MemoryQuestionOperation
        if let rawOperation = arguments["operation"] as? String {
            let trimmed = rawOperation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let parsed = MemoryQuestionOperation(rawValue: trimmed) else {
                return .failure(.badOperation(trimmed))
            }
            // A source is graded once, at its contour, so a contour grade is
            // always a recall; a probe past it is answered without the grader.
            guard !parsed.isUnderstanding else {
                return .failure(.understandingBeforeRecall(operation: trimmed, reason: "a contour is a recall"))
            }
            operation = parsed
        } else {
            // A contour is a free recall unless the tutor says otherwise.
            operation = .recall
        }

        let evaluation = (arguments["evaluation"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Stored in the source's own idea order so two devices write the same bytes.
        let order = Dictionary(uniqueKeysWithValues: ideas.enumerated().map { ($1.id, $0) })
        let ordered = coverage.sorted { (order[$0.ideaID] ?? 0) < (order[$1.ideaID] ?? 0) }

        return .success(MemoryContourGrade(
            sourceID: sourceID,
            coverage: ordered,
            score: score,
            verdict: verdict,
            operation: operation,
            evaluation: evaluation?.isEmpty == false ? evaluation : nil
        ))
    }
}

extension MemoryContourGrade {

    /// Checks a `grade_topic_recall` call against today's topics.
    ///
    /// The topic's opening answer grades every idea the topic cues, whichever
    /// source each belongs to. After that, Go deeper grades one probe at a
    /// time: any of the topic's ideas, usually the one probed, and an
    /// understanding probe (its kind as `operation`) only ideas a recall has
    /// already graded. A later grade
    /// updates the card's ledger and never moves a source's rung
    /// (`MemoryLadderEvidence`). `gradedIdeaIDs` are the ideas today's review
    /// has already graded. The result's `sourceID` is the topic id: the
    /// subject of the grade, which is what the review is on.
    static func validateTopic(
        arguments: [String: Any],
        topics: [MemoryReviewTopic],
        ideasByID: [String: SourceIdea],
        gradedIdeaIDs: Set<String>
    ) -> Result<MemoryContourGrade, ValidationError> {
        guard let topicID = (arguments["topic_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !topicID.isEmpty else {
            return .failure(.missingTopic)
        }
        guard let topic = topics.first(where: { $0.id == topicID }) else {
            return .failure(.unknownTopic(topicID))
        }
        let cued = topic.ideaIDs.filter { ideasByID[$0] != nil }
        guard !cued.isEmpty else { return .failure(.sourceHasNoIdeas(topicID)) }
        guard let rawCoverage = arguments["idea_coverage"] as? [[String: Any]], !rawCoverage.isEmpty else {
            return .failure(.missingCoverage)
        }
        let known = Set(cued)
        var seen = Set<String>()
        var coverage: [MemoryIdeaCoverage] = []
        for entry in rawCoverage {
            guard let ideaID = (entry["idea_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !ideaID.isEmpty else {
                return .failure(.missingCoverage)
            }
            guard known.contains(ideaID) else {
                return .failure(.foreignTopicIdea(topicID: topicID, ideaID: ideaID))
            }
            guard seen.insert(ideaID).inserted else { return .failure(.duplicateIdea(ideaID)) }
            let rawStatus = (entry["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard let status = MemoryIdeaCoverage.Status(rawValue: rawStatus) else {
                return .failure(.badStatus(rawStatus))
            }
            coverage.append(MemoryIdeaCoverage(ideaID: ideaID, status: status))
        }
        let isOpening = gradedIdeaIDs.isDisjoint(with: known)
        if isOpening {
            let missing = cued.filter { !seen.contains($0) }
            guard missing.isEmpty else {
                return .failure(.incompleteTopicCoverage(topicID: topicID, missing: missing))
            }
        }
        // Read before the score so an understanding probe sent as the
        // opening is told what it is, not only what its score lacks.
        let rawOperation = (arguments["operation"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let rawOperation, let parsed = MemoryQuestionOperation(rawValue: rawOperation), parsed.isUnderstanding {
            // An understanding probe goes past an idea that came back, so it
            // is graded only on ideas a recall already reached: never the
            // opening, never an idea of the topic no grade has seen.
            if isOpening {
                return .failure(.understandingBeforeRecall(operation: rawOperation, reason: "\(topicID)'s opening answer is a recall"))
            }
            if let unrecalled = coverage.first(where: { !gradedIdeaIDs.contains($0.ideaID) }) {
                return .failure(.understandingBeforeRecall(operation: rawOperation, reason: "idea \(unrecalled.ideaID) has had no recall graded yet"))
            }
        }
        guard let score = ToolArgumentNumber.value(arguments["score"]), score.isFinite, (0...1).contains(score) else {
            return .failure(.badScore(received: ToolArgumentNumber.describe(arguments["score"])))
        }
        let verdict: MemoryQuestionVerdict
        if let rawVerdict = arguments["question_verdict"] as? String {
            let trimmed = rawVerdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let parsed = MemoryQuestionVerdict(rawValue: trimmed) else { return .failure(.badVerdict(trimmed)) }
            verdict = parsed
        } else {
            verdict = .sound
        }
        let operation: MemoryQuestionOperation
        if let rawOperation {
            guard let parsed = MemoryQuestionOperation(rawValue: rawOperation) else { return .failure(.badOperation(rawOperation)) }
            operation = parsed
        } else {
            operation = topic.kind == .connection ? .connect : .recall
        }
        let evaluation = (arguments["evaluation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // In the topic's own order, so two devices write the same bytes.
        let order = Dictionary(uniqueKeysWithValues: cued.enumerated().map { ($1, $0) })
        return .success(MemoryContourGrade(
            sourceID: topicID,
            coverage: coverage.sorted { (order[$0.ideaID] ?? 0) < (order[$1.ideaID] ?? 0) },
            score: score,
            verdict: verdict,
            operation: operation,
            evaluation: evaluation?.isEmpty == false ? evaluation : nil
        ))
    }
}

/// Where one idea stands in today's review, for a topic card's ledger.
struct MemoryReviewIdeaState: Equatable, Sendable {
    /// The latest recall grade the idea got today.
    let status: MemoryIdeaCoverage.Status
    /// How many of today's recall grades marked it missing. Twice missing
    /// (the opening, then a probe on it) means the tutor re-taught it, and
    /// the ledger shows it instead of veiling it.
    let missCount: Int
    /// The understanding probes answered on it today
    /// (`MemoryUnderstandingProbe`), nil before the first. Kept apart from
    /// `status` and `missCount` on purpose: a probe goes past an idea that
    /// already came back, and an answer that falls short says how deep the
    /// understanding went, never that the idea did not come back. Before
    /// this, the latest grade won whatever it graded, so a principle probe
    /// answered poorly turned a produced idea into a missed one — a veiled
    /// row the learner had just recalled, and one miss from being
    /// re-taught.
    var understanding: Understanding? = nil

    struct Understanding: Equatable, Sendable {
        /// The latest probe's kind, as its grade's operation.
        let operation: MemoryQuestionOperation
        /// How far that answer went.
        let status: MemoryIdeaCoverage.Status
        /// How many probes the idea has had today.
        let count: Int
    }

    var isRevealed: Bool { status == .missing && missCount >= 2 }

    /// Every graded idea of a review, from its saved exchanges in order.
    static func states(from exchanges: [MemoryReviewSourceStatus.GradedExchange]) -> [String: MemoryReviewIdeaState] {
        var result: [String: MemoryReviewIdeaState] = [:]
        for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            fold(
                MemoryIdeaCoverage.decode(exchange.ideaCoverage),
                operation: exchange.operation.flatMap(MemoryQuestionOperation.init(rawValue:)),
                into: &result
            )
        }
        return result
    }

    /// One grade folded into the day's states, the one rule a resume and a
    /// live grade share. A recall grade sets an idea's status, the latest
    /// winning, and counts a miss. An understanding probe's grade touches
    /// only the idea's `understanding`, and only on an idea a recall already
    /// graded: it never sets a status, veils a row or counts a miss, and an
    /// idea it reaches first (which the grader refuses) gets no row from it.
    static func fold(
        _ coverage: [MemoryIdeaCoverage],
        operation: MemoryQuestionOperation?,
        into states: inout [String: MemoryReviewIdeaState]
    ) {
        for entry in coverage {
            let prior = states[entry.ideaID]
            if let operation, operation.isUnderstanding {
                guard var state = prior else { continue }
                state.understanding = Understanding(
                    operation: operation,
                    status: entry.status,
                    count: (state.understanding?.count ?? 0) + 1
                )
                states[entry.ideaID] = state
            } else {
                let misses = (prior?.missCount ?? 0) + (entry.status == .missing ? 1 : 0)
                states[entry.ideaID] = MemoryReviewIdeaState(
                    status: entry.status,
                    missCount: misses,
                    understanding: prior?.understanding
                )
            }
        }
    }
}

/// One row of a topic card's ledger: where one cued idea stands after the
/// grade, and whether the row may say what the idea is.
///
/// A missing idea is never read out (docs/memory-design.md, "Review by
/// topic"): its row is veiled, naming only the source it came from, until a
/// probe on it fails and the tutor re-teaches it. Only then does the ledger
/// show the statement, so the learner can find it again.
struct MemoryReviewLedgerRow: Equatable, Sendable {
    let ideaID: String
    let sourceID: String?
    let status: MemoryIdeaCoverage.Status
    /// The idea's statement when the row may show it; nil while veiled.
    let statement: String?

    var isVeiled: Bool { statement == nil }
}

extension MemoryReviewIdeaState {

    /// The ledger of a topic, one row per cued idea in the topic's order,
    /// once the topic has a grade. An idea no grade has reached yet gets no
    /// row, so a probe's subset never pads the list; empty before the
    /// topic's first grade.
    static func ledgerRows(
        topic: MemoryReviewTopic,
        states: [String: MemoryReviewIdeaState],
        ideasByID: [String: SourceIdea]
    ) -> [MemoryReviewLedgerRow] {
        topic.ideaIDs.compactMap { ideaID in
            guard let state = states[ideaID] else { return nil }
            let shown = state.status != .missing || state.isRevealed
            return MemoryReviewLedgerRow(
                ideaID: ideaID,
                sourceID: SourceIdea.sourceID(fromIdeaID: ideaID),
                status: state.status,
                statement: shown ? ideasByID[ideaID]?.statement : nil
            )
        }
    }
}

/// Where one topic stands in the session's stepper: not yet reached, the one
/// the tutor is on, or graded.
enum MemoryReviewTopicProgress: Equatable, Sendable {
    case waiting
    case current
    case finished

    /// One entry per topic, in the topics' order. The current topic is the
    /// one the tutor is asking about, graded or not, so a stepper accents it
    /// either way; any other topic with a status (its opening was graded) is
    /// finished.
    static func progress(
        topics: [MemoryReviewTopic],
        statuses: [String: MemoryReviewSourceStatus],
        currentID: String?
    ) -> [MemoryReviewTopicProgress] {
        topics.map { topic in
            if topic.id == currentID { return .current }
            return statuses[topic.id] != nil ? .finished : .waiting
        }
    }
}

/// One graded contour recall as the ladder sees it.
struct MemoryContourOutcome: Equatable, Sendable {
    let sourceID: String
    let sessionID: String
    let gradedAt: Date
    /// nil when the question was ambiguous; the ladder skips it.
    let producedFraction: Double?
}

/// Where one source stands in a day's memory review.
///
/// Presence is the completion: a source has a status only once its contour has
/// been graded in this review. Being asked about, opened or discussed is
/// activity, never completion — the same line the Schedule draws.
struct MemoryReviewSourceStatus: Equatable, Sendable {
    let sourceID: String
    /// The most recent graded contour for this source in this review.
    let coverage: [MemoryIdeaCoverage]
    /// The question was judged unfit to grade, so no fraction is claimed and
    /// no rung moved.
    let isAmbiguous: Bool
    let gradedAt: Date?

    var ideaCount: Int { coverage.count }
    var producedCount: Int { coverage.filter { $0.status == .produced }.count }
    var partialCount: Int { coverage.filter { $0.status == .partial }.count }

    /// What moved the rung, or nil for an ambiguous question.
    var producedFraction: Double? {
        isAmbiguous ? nil : MemoryIdeaCoverage.producedFraction(coverage)
    }

    /// One line for the strip's tooltip: what came back, in the grader's terms.
    var recallSummary: String {
        guard !coverage.isEmpty else { return "Reviewed" }
        if isAmbiguous {
            return "Reviewed — the question was ambiguous, so nothing was scored"
        }
        var parts = ["\(producedCount) of \(ideaCount) ideas recalled"]
        if partialCount > 0 {
            parts.append("\(partialCount) partly")
        }
        return parts.joined(separator: ", ")
    }

    /// The facts of a saved exchange the completion is rebuilt from. Any
    /// client's exchange record can supply them. `operation` is what the
    /// grade says the question asked for: an understanding probe's grade
    /// (`MemoryQuestionOperation.isUnderstanding`) completes nothing and is
    /// folded apart from recall (`MemoryReviewIdeaState.fold`).
    struct GradedExchange: Equatable, Sendable {
        let sequenceNumber: Int
        let ideaCoverage: String?
        let questionVerdict: String?
        let answeredAt: Date?
        var operation: String? = nil

        var isUnderstanding: Bool {
            operation.flatMap(MemoryQuestionOperation.init(rawValue:))?.isUnderstanding ?? false
        }
    }

    /// Rebuilds a review's per-source completion from its saved exchanges, so a
    /// review reopened this evening shows the same checkmarks it showed at
    /// lunch, on any device. A grade may span sources (a topic's), so each
    /// source takes its own ideas from it, and an idea's latest recall grade
    /// wins: an understanding probe's grade says how deep the understanding
    /// of an idea that came back went, so it neither completes nor undoes a
    /// checkmark. When `topics` are given, each topic with a graded idea gets
    /// a status too, keyed by its id, holding its ideas' latest grades.
    static func statuses(
        from exchanges: [GradedExchange],
        topics: [MemoryReviewTopic] = []
    ) -> [String: MemoryReviewSourceStatus] {
        var latest: [String: MemoryIdeaCoverage] = [:]
        var bySource: [String: [String]] = [:]
        var sourceVerdict: [String: Bool] = [:]
        var sourceGradedAt: [String: Date?] = [:]
        var ideaVerdict: [String: Bool] = [:]
        var ideaGradedAt: [String: Date?] = [:]
        for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) where !exchange.isUnderstanding {
            let ambiguous = exchange.questionVerdict == MemoryQuestionVerdict.ambiguous.rawValue
            for group in MemoryIdeaCoverage.bySource(MemoryIdeaCoverage.decode(exchange.ideaCoverage)) {
                for entry in group.coverage {
                    if latest[entry.ideaID] == nil {
                        bySource[group.sourceID, default: []].append(entry.ideaID)
                    }
                    latest[entry.ideaID] = entry
                    ideaVerdict[entry.ideaID] = ambiguous
                    ideaGradedAt[entry.ideaID] = .some(exchange.answeredAt)
                }
                sourceVerdict[group.sourceID] = ambiguous
                sourceGradedAt[group.sourceID] = .some(exchange.answeredAt)
            }
        }
        var result: [String: MemoryReviewSourceStatus] = [:]
        for (sourceID, ideaIDs) in bySource {
            result[sourceID] = MemoryReviewSourceStatus(
                sourceID: sourceID,
                coverage: ideaIDs.compactMap { latest[$0] },
                isAmbiguous: sourceVerdict[sourceID] ?? false,
                gradedAt: sourceGradedAt[sourceID] ?? nil
            )
        }
        for topic in topics {
            let graded = topic.ideaIDs.filter { latest[$0] != nil }
            guard !graded.isEmpty else { continue }
            func gradedAt(_ id: String) -> Date { (ideaGradedAt[id] ?? nil) ?? .distantPast }
            let newest = graded.max { gradedAt($0) < gradedAt($1) }
            result[topic.id] = MemoryReviewSourceStatus(
                sourceID: topic.id,
                coverage: graded.compactMap { latest[$0] },
                isAmbiguous: newest.flatMap { ideaVerdict[$0] } ?? false,
                gradedAt: newest.flatMap { ideaGradedAt[$0] ?? nil }
            )
        }
        return result
    }

    /// The facts of a saved exchange that say which source the tutor is on:
    /// the turn lines it wrote and the contour it graded. Any client's
    /// exchange record can supply them.
    struct SourceTurnExchange: Equatable, Sendable {
        let sequenceNumber: Int
        let question: String
        let ideaCoverage: String?
        let evaluation: String?
    }

    /// The source the tutor is asking about right now: the last
    /// `<flm_source_turn>` line it wrote, or, when it wrote none since, the
    /// last contour it graded. A grade landing mid-reply and a turn line later
    /// in the same reply resolve in the order they happened, so a reply that
    /// grades one source and opens the next is on the next.
    static func currentSourceID(
        from exchanges: [SourceTurnExchange],
        topics: [MemoryReviewTopic] = []
    ) -> String? {
        let topicByIdea = Dictionary(
            topics.flatMap { topic in topic.ideaIDs.map { ($0, topic.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        var current: String?
        for exchange in exchanges.sorted(by: { $0.sequenceNumber < $1.sequenceNumber }) {
            if let last = MemoryReviewSourceTurn.sourceIDs(in: exchange.question).last {
                current = last
            }
            if let graded = MemoryIdeaCoverage.decode(exchange.ideaCoverage).first {
                // A topic's grade keeps the review on the topic; a contour's
                // on its source.
                if let topicID = topicByIdea[graded.ideaID] {
                    current = topicID
                } else if let sourceID = SourceIdea.sourceID(fromIdeaID: graded.ideaID) {
                    current = sourceID
                }
            }
            if let evaluation = exchange.evaluation,
               let last = MemoryReviewSourceTurn.sourceIDs(in: evaluation).last {
                current = last
            }
        }
        return current
    }

    /// Whether the chat offers the Next and Go deeper chips: the source under
    /// discussion has had its contour graded. Before the grade a Next would
    /// skip the contour, which depth never does; after it, every reply on the
    /// source — the graded one, each probe's, and the tutor's closing offer to
    /// move on or stay — is a place the learner may steer from.
    static func offersSteer(currentSourceID: String?, statuses: [String: MemoryReviewSourceStatus]) -> Bool {
        guard let currentSourceID else { return false }
        return statuses[currentSourceID] != nil
    }
}
