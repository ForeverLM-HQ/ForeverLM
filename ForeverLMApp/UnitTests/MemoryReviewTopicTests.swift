import Foundation
import Testing
@testable import ForeverLM

/// A memory review planned by topic (docs/memory-design.md, "Review by
/// topic"): the planner groups today's ideas into topics across sources, code
/// validates and numbers them, the briefing carries them and gives them back,
/// one grade covers a topic's ideas across its sources, and the ladder hears
/// each idea's first grade of the day.
struct MemoryReviewTopicTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func source(_ id: String, title: String? = nil, type: String = "paper") -> CohortSource {
        CohortSource(
            sourceID: id, title: title ?? id.capitalized, sourceType: type, role: .spine,
            consumedAt: now, lastDiscussedAt: nil, reviewCount: 0, confidence: .complete,
            bridgeTo: nil, reason: "test"
        )
    }

    private func idea(_ sourceID: String, _ index: Int, wanted: Bool = false) -> SourceIdea {
        SourceIdea(
            id: SourceIdea.id(sourceID: sourceID, contentHash: "h", index: index),
            sourceID: sourceID, statement: "Idea \(index) of \(sourceID).",
            recallNote: "note", anchors: [], wanted: wanted,
            contentHash: "h", sortIndex: index, createdAt: now, updatedAt: now
        )
    }

    private func brief(_ source: CohortSource, ideas: [SourceIdea]) -> CohortSourceBrief {
        CohortSourceBrief(
            source: source, guide: nil, highlights: [], understanding: nil,
            understandingHasLearnerEdits: false, exemplarQuestions: [], ideas: ideas, depth: .standard
        )
    }

    private func cohort(_ sources: [CohortSource]) -> LearningCohort {
        LearningCohort(assembledAt: now, windowDays: 10, sources: sources, unfinished: [], droppedSpine: 0, droppedSpacing: 0)
    }

    /// Two papers and a chat, with ideas: the fixture every topic test plans over.
    private func fixture() -> (cohort: LearningCohort, briefs: [CohortSourceBrief]) {
        let a = source("src-a", title: "Uncouplers")
        let b = source("src-b", title: "Proton leak")
        let chat = source("chat-1", title: "Why cells go rogue", type: ReviewableChat.sourceType)
        let briefs = [
            brief(a, ideas: [idea("src-a", 0, wanted: true), idea("src-a", 1)]),
            brief(b, ideas: [idea("src-b", 0), idea("src-b", 1)]),
            brief(chat, ideas: [idea("chat-1", 0)]),
        ]
        return (cohort([a, b, chat]), briefs)
    }

    private func coverage(_ entries: [(String, MemoryIdeaCoverage.Status)]) -> String? {
        MemoryIdeaCoverage.encode(entries.map { MemoryIdeaCoverage(ideaID: $0.0, status: $0.1) })
    }

    // MARK: - Planner output

    @Test("Planner JSON with topics decodes as drafts, and validation numbers what survives")
    func plannerTopicsDecodeAndValidate() throws {
        let (cohort, briefs) = fixture()
        let a0 = idea("src-a", 0).id, a1 = idea("src-a", 1).id, b0 = idea("src-b", 0).id, c0 = idea("chat-1", 0).id
        let json = """
        {"opening": "Uncoupling and leak.",
         "topics": [
           {"title": "How uncouplers dissipate the gradient", "kind": "new", "idea_ids": ["\(a0)", " \(b0) ", "ghost::idea::x::9", "\(a0)"], "intent": "Push on the mechanism."},
           {"title": "  ", "kind": "new", "idea_ids": ["\(a1)"], "intent": "no title"},
           {"title": "Only already-claimed ideas", "kind": "due", "idea_ids": ["\(a0)", "\(b0)"]},
           {"title": "Rogue cells", "kind": "CONNECTION", "idea_ids": ["\(c0)", "\(a1)"], "intent": "Meet in the middle."},
           {"title": "Unknown kind", "kind": "sideways", "idea_ids": ["src-b::idea::h::1"]}
         ]}
        """
        let plan = try JSONDecoder().decode(CohortSessionPlan.self, from: Data(json.utf8))
        #expect(plan.topics.isEmpty, "a decoded plan carries drafts until it is validated")
        #expect(plan.topicDrafts.count == 5)
        #expect(plan.moves.isEmpty)

        let validated = plan.validated(against: cohort, briefs: briefs)
        #expect(validated.topics.map(\.id) == ["topic-1", "topic-2", "topic-3"])
        #expect(validated.topics.map(\.title) == ["How uncouplers dissipate the gradient", "Rogue cells", "Unknown kind"])
        #expect(validated.topics.map(\.kind) == [.new, .connection, .new])
        // Trimmed, foreign dropped, a second use of an idea dropped.
        #expect(validated.topics[0].ideaIDs == [a0, b0])
        #expect(validated.topics[0].sourceIDs == ["src-a", "src-b"])
        #expect(validated.topics[1].ideaIDs == [c0, a1])
        #expect(validated.topics[1].intent == "Meet in the middle.")
        #expect(validated.topics[2].intent == "")
        // One move per topic, so the strip order and the opening source hold.
        #expect(validated.moves.map(\.kind) == [.explain, .connect, .explain])
        #expect(validated.moves[0].sourceIDs == ["src-a", "src-b"])
        #expect(validated.moves[1].sourceIDs == ["chat-1", "src-a"])
        #expect(validated.opening == "Uncoupling and leak.")
        #expect(validated.topicDrafts.isEmpty)

        // A validated plan encodes its numbered topics, and decodes them back
        // as drafts that validate to the same thing.
        let data = try JSONEncoder().encode(validated)
        let again = try JSONDecoder().decode(CohortSessionPlan.self, from: data).validated(against: cohort, briefs: briefs)
        #expect(again.topics == validated.topics)
    }

    @Test("A topic cues at most eight ideas, and a plan with no surviving topic falls back to its moves")
    func topicCapAndFallback() {
        let big = source("src-big")
        let ideas = (0..<12).map { idea("src-big", $0) }
        let plan = CohortSessionPlan(
            opening: "o", moves: [],
            topicDrafts: [CohortTopicDraft(title: "Everything", kind: nil, ideaIDs: ideas.map(\.id), intent: nil)]
        )
        let validated = plan.validated(against: cohort([big]), briefs: [brief(big, ideas: ideas)])
        #expect(validated.topics.count == 1)
        #expect(validated.topics[0].ideaIDs.count == MemoryReviewTopic.maxIdeas)
        #expect(validated.topics[0].kind == .new)

        let noTopics = CohortSessionPlan(
            opening: "o",
            moves: [CohortMove(kind: .recall, sourceIDs: ["src-big"], intent: "old style")],
            topicDrafts: [CohortTopicDraft(title: "Nothing real", kind: "new", ideaIDs: ["ghost::idea::h::0"], intent: nil)]
        )
        let fallback = noTopics.validated(against: cohort([big]), briefs: [brief(big, ideas: ideas)])
        #expect(fallback.topics.isEmpty)
        #expect(fallback.moves.map(\.intent) == ["old style"])
    }

    @Test("Topic ids are positional, and a source id is never one")
    func topicIDs() {
        #expect(MemoryReviewTopic.id(position: 3) == "topic-3")
        #expect(MemoryReviewTopic.isTopicID("topic-1"))
        #expect(!MemoryReviewTopic.isTopicID("topic-"))
        #expect(!MemoryReviewTopic.isTopicID("topic-x"))
        #expect(!MemoryReviewTopic.isTopicID("src-a"))
        #expect(!MemoryReviewTopic.isTopicID(SourceIdea.id(sourceID: "topic-1", contentHash: "h", index: 0)))
    }

    @Test("The number of topics follows the budget: four and a connection at fifteen minutes")
    func topicCountFollowsBudget() {
        #expect(MemoryReviewTutoring.topicCount(budgetMinutes: 15) == 4)
        #expect(MemoryReviewTutoring.topicCount(budgetMinutes: 30) == 9)
        #expect(MemoryReviewTutoring.topicCount(budgetMinutes: 5) == 2)
        #expect(MemoryReviewTutoring.topicCount(budgetMinutes: 120) == 12)
        let message = MemoryReviewTutoring.plannerUserMessage(cohort: fixture().cohort, briefs: fixture().briefs, recentSessionSummaries: [], budgetMinutes: 15)
        #expect(message.contains("TOPICS TO PLAN: 4 topics for a 15 minutes review"))
        #expect(message.contains("\"topics\": [{\"title\""))
        #expect(!message.contains("\"moves\""))
    }

    // MARK: - Briefing

    @Test("The briefing lists the topics with their ideas and gives them back, less a removed source's ideas")
    func briefingCarriesTopics() {
        let (cohort, briefs) = fixture()
        let a0 = idea("src-a", 0).id, b0 = idea("src-b", 0).id, c0 = idea("chat-1", 0).id, a1 = idea("src-a", 1).id
        let topics = [
            MemoryReviewTopic(id: "topic-1", title: "How uncouplers dissipate the gradient", kind: .new, ideaIDs: [a0, b0], intent: "Push on the mechanism."),
            MemoryReviewTopic(id: "topic-2", title: "Rogue cells", kind: .connection, ideaIDs: [c0, a1], intent: ""),
        ]
        let plan = CohortSessionPlan(opening: "Uncoupling and leak.", moves: [
            CohortMove(kind: .explain, sourceIDs: ["src-a", "src-b"], intent: "t1"),
            CohortMove(kind: .connect, sourceIDs: ["chat-1", "src-a"], intent: "t2"),
        ], topics: topics)
        let briefing = MemoryReviewTutoring.briefing(cohort: cohort, briefs: briefs, plan: plan, startedAt: now, budgetMinutes: 15)

        #expect(briefing.contains(MemoryReviewTutoring.topicConductInstructions))
        #expect(!briefing.contains(MemoryReviewTutoring.conductInstructions))
        #expect(briefing.contains("every topic gets its opening question"))
        #expect(briefing.contains(MemoryReviewTutoring.topicsHeading))
        #expect(briefing.contains("TOPIC [topic-1] new — How uncouplers dissipate the gradient\nPush on: Push on the mechanism.\n- [\(a0)] Idea 0 of src-a. (THEY HIGHLIGHTED THIS) (from Uncouplers)\n- [\(b0)] Idea 0 of src-b. (from Proton leak)"))
        #expect(briefing.contains("TOPIC [topic-2] connection — Rogue cells\n- [\(c0)]"))
        #expect(MemoryReviewTutoring.topics(inBriefing: briefing) == topics)
        #expect(MemoryReviewTutoring.openingRequest(forBriefing: briefing) == MemoryReviewTutoring.topicOpeningRequest)
        // The sources are still listed after the topics, so a resume finds both.
        #expect(MemoryReviewTutoring.sourceIDs(inBriefing: briefing) == ["src-a", "src-b", "chat-1"])

        // Taking a source out of the day takes its ideas out of every topic; a
        // topic left with nothing goes.
        let removed = MemoryReviewTutoring.briefing(briefing, removingSource: "chat-1")
        let after = MemoryReviewTutoring.topics(inBriefing: removed)
        #expect(after.map(\.id) == ["topic-1", "topic-2"])
        #expect(after[1].ideaIDs == [a1])
        let bothGone = MemoryReviewTutoring.briefing(removed, removingSource: "src-a")
        #expect(MemoryReviewTutoring.topics(inBriefing: bothGone).map(\.id) == ["topic-1"])

        // A briefing planned source by source has no topics and the old opening.
        let old = MemoryReviewTutoring.briefing(cohort: cohort, briefs: briefs, plan: CohortSessionPlan(opening: "o", moves: plan.moves), startedAt: now)
        #expect(old.contains(MemoryReviewTutoring.conductInstructions))
        #expect(MemoryReviewTutoring.topics(inBriefing: old).isEmpty)
        #expect(MemoryReviewTutoring.openingRequest(forBriefing: old) == MemoryReviewTutoring.openingRequest)
        #expect(MemoryReviewTutoring.topics(inBriefing: nil).isEmpty)
    }

    @Test("The topic grader names every field the validator reads, and the turn instruction names the topic id")
    func topicToolShape() {
        let tool = MemoryReviewTutoring.gradeTopicRecallTool
        #expect(tool.name == "grade_topic_recall")
        let properties = tool.parameters.properties ?? [:]
        #expect(Set(properties.keys) == ["topic_id", "idea_coverage", "score", "question_verdict", "operation", "evaluation"])
        #expect(tool.parameters.required == ["topic_id", "idea_coverage", "score"])
        #expect(properties["idea_coverage"]?.items?.properties?["status"]?.allowedValues == ["produced", "partial", "missing"])
        #expect(AIToolSpec(portable: tool).name == "grade_topic_recall")
        #expect(MemoryReviewSourceTurn.topicInstruction.contains("<\(MemoryReviewSourceTurn.tagName) id=\"TOPIC_ID\"/>"))
        #expect(MemoryReviewTutoring.topicConductInstructions.contains(MemoryReviewSourceTurn.topicInstruction))
        #expect(MemoryReviewTutoring.topicConductInstructions.contains("grade_topic_recall"))
    }

    // MARK: - Grading

    @Test("A topic's opening grade covers every idea it lists, across sources; a probe grades a subset")
    func validateTopicGrade() throws {
        let a0 = idea("src-a", 0), a1 = idea("src-a", 1), b0 = idea("src-b", 0)
        let ideasByID = Dictionary(uniqueKeysWithValues: [a0, a1, b0].map { ($0.id, $0) })
        let topics = [
            MemoryReviewTopic(id: "topic-1", title: "T", kind: .new, ideaIDs: [a0.id, b0.id], intent: ""),
            MemoryReviewTopic(id: "topic-2", title: "C", kind: .connection, ideaIDs: [a1.id], intent: ""),
        ]
        func validate(_ arguments: [String: Any], graded: Set<String> = []) -> Result<MemoryContourGrade, MemoryContourGrade.ValidationError> {
            MemoryContourGrade.validateTopic(arguments: arguments, topics: topics, ideasByID: ideasByID, gradedIdeaIDs: graded)
        }

        // The opening: every idea, in the topic's order whatever order arrived.
        let opening = try validate([
            "topic_id": " topic-1 ", "score": 0.5,
            "idea_coverage": [["idea_id": b0.id, "status": "missing"], ["idea_id": a0.id, "status": "produced"]],
        ]).get()
        #expect(opening.sourceID == "topic-1")
        #expect(opening.coverage.map(\.ideaID) == [a0.id, b0.id])
        #expect(opening.operation == .recall)
        #expect(opening.verdict == .sound)

        // An opening that leaves an idea out is sent back with the names.
        guard case .failure(let incomplete) = validate([
            "topic_id": "topic-1", "score": 1, "idea_coverage": [["idea_id": a0.id, "status": "produced"]],
        ]) else { Issue.record("an incomplete opening was accepted"); return }
        #expect(incomplete.message.contains(b0.id))
        #expect(incomplete.message.contains("every idea the topic lists"))

        // Once the topic has been graded, a probe may grade one idea.
        let probe = try validate([
            "topic_id": "topic-1", "score": 1, "idea_coverage": [["idea_id": b0.id, "status": "produced"]],
        ], graded: [a0.id, b0.id]).get()
        #expect(probe.coverage.map(\.ideaID) == [b0.id])

        // A connection's default operation is connect.
        let connection = try validate([
            "topic_id": "topic-2", "score": 0, "idea_coverage": [["idea_id": a1.id, "status": "missing"]],
        ]).get()
        #expect(connection.operation == .connect)

        // The rest is refused with a message that says how to re-emit.
        guard case .failure(let noTopic) = validate(["score": 1, "idea_coverage": [["idea_id": a0.id, "status": "produced"]]]) else { Issue.record("no topic accepted"); return }
        #expect(noTopic.message.contains("topic_id is required"))
        guard case .failure(let unknown) = validate(["topic_id": "topic-9", "score": 1, "idea_coverage": [["idea_id": a0.id, "status": "produced"]]]) else { Issue.record("unknown topic accepted"); return }
        #expect(unknown.message.contains("topic-9"))
        guard case .failure(let foreign) = validate(["topic_id": "topic-2", "score": 1, "idea_coverage": [["idea_id": a0.id, "status": "produced"]]]) else { Issue.record("foreign idea accepted"); return }
        #expect(foreign.message.contains("not one of topic-2's ideas"))
        guard case .failure(let badScore) = validate(["topic_id": "topic-2", "score": "high", "idea_coverage": [["idea_id": a1.id, "status": "produced"]]]) else { Issue.record("bad score accepted"); return }
        #expect(badScore.message.contains("score"))

        let acknowledgement = MemoryReviewTutoring.topicGradeAcknowledgement(grade: opening, topic: topics[0], isOpening: true)
        #expect(acknowledgement.contains("Recorded: 1 of 2 ideas produced, score 0.50."))
        #expect(acknowledgement.contains("Go deeper or Next topic"))
        #expect(acknowledgement.contains("without naming or paraphrasing any idea graded missing"))
        let probed = MemoryReviewTutoring.topicGradeAcknowledgement(grade: probe, topic: topics[0], isOpening: false)
        #expect(probed.contains("Nothing in this answer is left missing or partial"))
    }

    // MARK: - What the grades mean afterwards

    @Test("The ladder hears each idea's first grade of the day, per source, so a probe re-grade moves nothing")
    func ladderEvidence() {
        let a0 = idea("src-a", 0).id, a1 = idea("src-a", 1).id, b0 = idea("src-b", 0).id, b1 = idea("src-b", 1).id
        let t0 = now
        let exchanges = [
            // The topic's opening: two of a's ideas and one of b's, at once.
            MemoryGradedExchange(sessionID: "s1", sequenceNumber: 1,
                                 ideaCoverage: coverage([(a0, .produced), (a1, .missing), (b0, .partial)]),
                                 questionVerdict: "sound", answeredAt: t0),
            // Go deeper: a1 comes back now. The day's evidence for a stays 0.5.
            MemoryGradedExchange(sessionID: "s1", sequenceNumber: 2,
                                 ideaCoverage: coverage([(a1, .produced)]),
                                 questionVerdict: "sound", answeredAt: t0.addingTimeInterval(60)),
            // A later topic cues b's other idea: b's outcome grows, once.
            MemoryGradedExchange(sessionID: "s1", sequenceNumber: 3,
                                 ideaCoverage: coverage([(b1, .produced)]),
                                 questionVerdict: "sound", answeredAt: t0.addingTimeInterval(120)),
            // Another day, an ambiguous question: contributes nothing.
            MemoryGradedExchange(sessionID: "s2", sequenceNumber: 1,
                                 ideaCoverage: coverage([(a0, .missing), (a1, .missing)]),
                                 questionVerdict: "ambiguous", answeredAt: t0.addingTimeInterval(86_400)),
        ]
        let outcomes = MemoryLadderEvidence.outcomes(exchanges)
        #expect(outcomes.map(\.sourceID) == ["src-a", "src-b", "src-a"])
        #expect(outcomes[0].sessionID == "s1")
        #expect(outcomes[0].producedFraction == 0.5)
        #expect(outcomes[0].gradedAt == t0)
        #expect(outcomes[1].producedFraction == 0.75, "partial b0 and produced b1: (0.5 + 1) / 2")
        #expect(outcomes[2].sessionID == "s2")
        #expect(outcomes[2].producedFraction == nil)

        // The phone's candidate builder reads the same rule.
        let contours = MemoryReviewCandidates.gradedContours(sessionID: "s1", exchanges: exchanges)
        #expect(contours.map(\.sourceID) == ["src-a", "src-b"])
        #expect(contours.map(\.producedFraction) == [0.5, 0.75])
    }

    @Test("Statuses come per source from a topic's grade, and per topic; the review stays on the topic it graded")
    func statusesByTopic() {
        let a0 = idea("src-a", 0).id, a1 = idea("src-a", 1).id, b0 = idea("src-b", 0).id
        let topics = [
            MemoryReviewTopic(id: "topic-1", title: "T", kind: .new, ideaIDs: [a0, b0], intent: ""),
            MemoryReviewTopic(id: "topic-2", title: "U", kind: .due, ideaIDs: [a1], intent: ""),
        ]
        let exchanges = [
            MemoryReviewSourceStatus.GradedExchange(sequenceNumber: 1, ideaCoverage: coverage([(a0, .missing), (b0, .produced)]), questionVerdict: "sound", answeredAt: now),
            MemoryReviewSourceStatus.GradedExchange(sequenceNumber: 2, ideaCoverage: coverage([(a0, .produced)]), questionVerdict: "sound", answeredAt: now.addingTimeInterval(60)),
        ]
        let statuses = MemoryReviewSourceStatus.statuses(from: exchanges, topics: topics)
        #expect(Set(statuses.keys) == ["src-a", "src-b", "topic-1"])
        #expect(statuses["src-a"]?.coverage == [MemoryIdeaCoverage(ideaID: a0, status: .produced)], "the latest grade of an idea wins")
        #expect(statuses["src-b"]?.coverage == [MemoryIdeaCoverage(ideaID: b0, status: .produced)])
        #expect(statuses["topic-1"]?.coverage == [MemoryIdeaCoverage(ideaID: a0, status: .produced), MemoryIdeaCoverage(ideaID: b0, status: .produced)])
        #expect(statuses["topic-1"]?.gradedAt == now.addingTimeInterval(60))
        #expect(statuses["topic-2"] == nil, "a topic with no graded idea has no status yet")

        let states = MemoryReviewIdeaState.states(from: exchanges)
        #expect(states[a0] == MemoryReviewIdeaState(status: .produced, missCount: 1))
        #expect(states[b0] == MemoryReviewIdeaState(status: .produced, missCount: 0))
        #expect(!(states[a0]?.isRevealed ?? true))
        let twiceMissed = MemoryReviewIdeaState.states(from: [
            exchanges[0],
            MemoryReviewSourceStatus.GradedExchange(sequenceNumber: 2, ideaCoverage: coverage([(a0, .missing)]), questionVerdict: "sound", answeredAt: now),
        ])
        #expect(twiceMissed[a0]?.isRevealed == true)

        let turns = [
            MemoryReviewSourceStatus.SourceTurnExchange(sequenceNumber: 1, question: "<flm_source_turn id=\"topic-1\"/>\nWhat happens?", ideaCoverage: nil, evaluation: nil),
            MemoryReviewSourceStatus.SourceTurnExchange(sequenceNumber: 2, question: "Graded.", ideaCoverage: coverage([(a0, .produced), (b0, .produced)]), evaluation: nil),
        ]
        #expect(MemoryReviewSourceStatus.currentSourceID(from: turns, topics: topics) == "topic-1")
        #expect(MemoryReviewSourceStatus.currentSourceID(from: turns) == "src-a", "without topics a grade is on its source")
    }

    @Test("A review planned by topic is dealt one card per topic")
    func topicCards() {
        typealias Turn = MemoryReviewCardDealing.Turn
        let turns: [Turn] = [
            .reply(turnsTo: nil),          // 0 the opening line
            .turn(to: "topic-1"),          // 1 heading
            .reply(turnsTo: nil),          // 2 the question
            .answer,                       // 3
            .reply(turnsTo: nil),          // 4 graded reply
            .answer,                       // 5 Go deeper
            .reply(turnsTo: nil),          // 6 probe
            .answer,                       // 7 Next
            .reply(turnsTo: "topic-2"),    // 8 closes topic 1, turns to 2 in one reply
            .answer,                       // 9
            .other,                        // 10
        ]
        let cards = MemoryReviewCardDealing.topicCards(turns)
        #expect(cards.map(\.sourceID) == ["topic-1", "topic-2"])
        #expect(cards.map(\.range) == [0..<8, 8..<11])
        #expect(MemoryReviewCardDealing.topicCards([]).isEmpty)
        #expect(MemoryReviewCardDealing.topicCards([.reply(turnsTo: nil)]) == [MemoryReviewCardDealing.Card(range: 0..<1, sourceID: nil)])
    }

    // MARK: - The phone

    /// The model's JSON, read back the way the phone's grading step reads it:
    /// through JSONSerialization, so the score arrives as a number object.
    private func arguments(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The phone's grading step checks a topic grade as the Mac does: the opening needs every idea, a probe a subset, and the acknowledgement knows which")
    func phoneTopicGradeValidation() throws {
        let a0 = idea("src-a", 0).id, a1 = idea("src-a", 1).id, b0 = idea("src-b", 0).id
        let topic = MemoryReviewTopic(id: "topic-1", title: "Uncoupling", kind: .new, ideaIDs: [a0, b0], intent: "")
        let ideasByID = [a0: idea("src-a", 0), a1: idea("src-a", 1), b0: idea("src-b", 0)]
        let subset = try arguments([
            "topic_id": "topic-1",
            "idea_coverage": [["idea_id": a0, "status": "missing"]],
            "score": 0,
        ])

        // Nothing graded yet, so this answer is the opening and must cover the topic.
        #expect(
            MemoryContourGrade.validateTopic(arguments: subset, topics: [topic], ideasByID: ideasByID, gradedIdeaIDs: [])
                == .failure(.incompleteTopicCoverage(topicID: "topic-1", missing: [b0]))
        )
        let full = try arguments([
            "topic_id": "topic-1",
            "idea_coverage": [["idea_id": b0, "status": "partial"], ["idea_id": a0, "status": "missing"]],
            "score": 0.25,
        ])
        let opening = try MemoryContourGrade.validateTopic(arguments: full, topics: [topic], ideasByID: ideasByID, gradedIdeaIDs: []).get()
        #expect(opening.sourceID == "topic-1", "the grade is on the topic, which is what the review is on")
        #expect(opening.coverage.map(\.ideaID) == [a0, b0], "stored in the topic's order")
        let openingWords = MemoryReviewTutoring.topicGradeAcknowledgement(grade: opening, topic: topic, isOpening: true)
        #expect(openingWords.contains("Recorded: 0 of 2 ideas produced, score 0.25."))
        #expect(openingWords.contains("Next topic"))

        // Once the opening is saved, the same subset is a probe, and the
        // phone tells the two apart by the ideas its record has graded.
        let saved = [MemoryReviewSourceStatus.GradedExchange(
            sequenceNumber: 1, ideaCoverage: MemoryIdeaCoverage.encode(opening.coverage), questionVerdict: "sound", answeredAt: now
        )]
        let graded = Set(MemoryReviewIdeaState.states(from: saved).keys)
        let probe = try MemoryContourGrade.validateTopic(arguments: subset, topics: [topic], ideasByID: ideasByID, gradedIdeaIDs: graded).get()
        #expect(probe.coverage == [MemoryIdeaCoverage(ideaID: a0, status: .missing)])
        let isOpening = graded.isDisjoint(with: Set(topic.ideaIDs))
        #expect(!isOpening)
        #expect(MemoryReviewTutoring.topicGradeAcknowledgement(grade: probe, topic: topic, isOpening: isOpening).contains("re-teach"))
    }

    @Test("A topic card's ledger veils what did not come back until a probe reveals it, and the stepper follows the grades")
    func phoneLedgerAndStepper() {
        let a0 = idea("src-a", 0).id, a1 = idea("src-a", 1).id, b0 = idea("src-b", 0).id
        let topics = [
            MemoryReviewTopic(id: "topic-1", title: "T", kind: .new, ideaIDs: [a0, b0], intent: ""),
            MemoryReviewTopic(id: "topic-2", title: "U", kind: .due, ideaIDs: [a1], intent: ""),
        ]
        let ideasByID = [a0: idea("src-a", 0), a1: idea("src-a", 1), b0: idea("src-b", 0)]
        let opening = MemoryReviewSourceStatus.GradedExchange(
            sequenceNumber: 1, ideaCoverage: coverage([(b0, .partial), (a0, .missing)]), questionVerdict: "sound", answeredAt: now
        )

        var states = MemoryReviewIdeaState.states(from: [opening])
        var rows = MemoryReviewIdeaState.ledgerRows(topic: topics[0], states: states, ideasByID: ideasByID)
        #expect(rows.map(\.ideaID) == [a0, b0], "in the topic's order, not the grade's")
        #expect(rows[0] == MemoryReviewLedgerRow(ideaID: a0, sourceID: "src-a", status: .missing, statement: nil))
        #expect(rows[0].isVeiled)
        #expect(rows[1] == MemoryReviewLedgerRow(ideaID: b0, sourceID: "src-b", status: .partial, statement: "Idea 0 of src-b."))
        #expect(MemoryReviewIdeaState.ledgerRows(topic: topics[1], states: states, ideasByID: ideasByID).isEmpty, "no rows before a grade")

        // A probe on the missing idea fails: the tutor re-taught it, so the row shows it.
        let probe = MemoryReviewSourceStatus.GradedExchange(
            sequenceNumber: 2, ideaCoverage: coverage([(a0, .missing)]), questionVerdict: "sound", answeredAt: now.addingTimeInterval(60)
        )
        states = MemoryReviewIdeaState.states(from: [opening, probe])
        rows = MemoryReviewIdeaState.ledgerRows(topic: topics[0], states: states, ideasByID: ideasByID)
        #expect(rows[0].statement == "Idea 0 of src-a.")
        #expect(rows[0].status == .missing)

        let statuses = MemoryReviewSourceStatus.statuses(from: [opening, probe], topics: topics)
        #expect(MemoryReviewTopicProgress.progress(topics: topics, statuses: statuses, currentID: "topic-1") == [.current, .waiting])
        #expect(MemoryReviewTopicProgress.progress(topics: topics, statuses: statuses, currentID: "topic-2") == [.finished, .current])
        #expect(MemoryReviewTopicProgress.progress(topics: topics, statuses: statuses, currentID: nil) == [.finished, .waiting])
    }

    @Test("The phone deals topic cards from replies that carry their turn, so a streaming reply stays on its card until its turn line lands")
    func phoneTopicPaging() {
        typealias Turn = MemoryReviewCardDealing.Turn
        var turns: [Turn] = [
            .reply(turnsTo: "topic-1"),   // the opener, its turn line stripped onto the message
            .answer,
            .reply(turnsTo: nil),         // the graded reply
            .answer,                      // Next topic
            .reply(turnsTo: nil),         // streaming; no turn line yet
        ]
        var cards = MemoryReviewCardDealing.topicCards(turns)
        #expect(cards.map(\.sourceID) == ["topic-1"])
        #expect(cards.map(\.range) == [0..<5])

        turns[4] = .reply(turnsTo: "topic-2")
        cards = MemoryReviewCardDealing.topicCards(turns)
        #expect(cards.map(\.sourceID) == ["topic-1", "topic-2"])
        #expect(cards.map(\.range) == [0..<4, 4..<5], "the steer stays on the topic it closes")
    }

#if os(macOS)
    @Test("cohort_review carries today's prepared topics, trimmed to the cohort it assembled")
    func mcpTopicsPayload() {
        let (cohort, briefs) = fixture()
        let a0 = idea("src-a", 0).id, a1 = idea("src-a", 1).id, b0 = idea("src-b", 0).id, c0 = idea("chat-1", 0).id
        let plan = CohortSessionPlan(opening: "Today", moves: [], topics: [
            MemoryReviewTopic(id: "topic-1", title: "Uncoupling", kind: .new, ideaIDs: [a0, b0], intent: "Push on the leak"),
            MemoryReviewTopic(id: "topic-2", title: "Rogue cells", kind: .connection, ideaIDs: [c0, a1], intent: ""),
        ])
        let briefing = MemoryReviewTutoring.briefing(cohort: cohort, briefs: briefs, plan: plan)

        let whole = MCPDataStore.cohortTopicsPayload(briefing: briefing, cohortSourceIDs: ["src-a", "src-b", "chat-1"])
        #expect(whole.map { $0["topic_id"] as? String } == ["topic-1", "topic-2"])
        #expect(whole[0]["idea_ids"] as? [String] == [a0, b0])
        #expect(whole[0]["source_ids"] as? [String] == ["src-a", "src-b"])
        #expect(whole[0]["kind"] as? String == "new")
        #expect(whole[0]["intent"] as? String == "Push on the leak")
        #expect(whole[1]["intent"] == nil)

        // A goal-scoped call without src-b keeps the topic on what it has.
        let scoped = MCPDataStore.cohortTopicsPayload(briefing: briefing, cohortSourceIDs: ["src-a"])
        #expect(scoped.map { $0["idea_ids"] as? [String] } == [[a0], [a1]])
        #expect(scoped.map { $0["source_ids"] as? [String] } == [["src-a"], ["src-a"]])

        #expect(MCPDataStore.cohortTopicsPayload(briefing: nil, cohortSourceIDs: ["src-a"]).isEmpty)
        #expect(MCPDataStore.cohortTopicsPayload(briefing: "SOURCES\n", cohortSourceIDs: ["src-a"]).isEmpty, "a review planned source by source carries none")
    }
#endif
}
