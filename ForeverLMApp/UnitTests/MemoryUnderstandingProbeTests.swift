import Foundation
import Testing
@testable import ForeverLM

/// Go deeper past recall (docs/memory-design.md, "Go deeper: understanding
/// probes"): the four probes rotate, go on the idea probed least, find an
/// analogy's partner in another notebook, and an answer to one says how deep
/// the understanding went without ever taking back that the idea came back.
struct MemoryUnderstandingProbeTests {

    private typealias Probe = MemoryUnderstandingProbe
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func idea(_ sourceID: String, _ index: Int, wanted: Bool = false) -> SourceIdea {
        SourceIdea(
            id: SourceIdea.id(sourceID: sourceID, contentHash: "h", index: index),
            sourceID: sourceID, statement: "Idea \(index) of \(sourceID).",
            recallNote: "note", anchors: [], wanted: wanted,
            contentHash: "h", sortIndex: index, createdAt: now, updatedAt: now
        )
    }

    private func coverage(_ entries: [(String, MemoryIdeaCoverage.Status)]) -> String? {
        MemoryIdeaCoverage.encode(entries.map { MemoryIdeaCoverage(ideaID: $0.0, status: $0.1) })
    }

    private func exchange(
        _ sequence: Int,
        _ entries: [(String, MemoryIdeaCoverage.Status)],
        operation: String? = "recall"
    ) -> MemoryReviewSourceStatus.GradedExchange {
        MemoryReviewSourceStatus.GradedExchange(
            sequenceNumber: sequence,
            ideaCoverage: coverage(entries),
            questionVerdict: "sound",
            answeredAt: now.addingTimeInterval(Double(sequence) * 60),
            operation: operation
        )
    }

    // MARK: - The kinds

    @Test("The probes are operations of their own, past the five recall ones the planner moves by")
    func kindsAreOperations() {
        for kind in Probe.Kind.allCases {
            #expect(kind.operation.isUnderstanding)
            #expect(Probe.Kind(operation: kind.operation) == kind)
            #expect(!kind.eyebrow.isEmpty && !kind.tutorDescription.isEmpty)
        }
        #expect(MemoryQuestionOperation.recallCases == [.recall, .explain, .contrast, .apply, .connect])
        #expect(MemoryQuestionOperation.recallCases.map(\.rawValue) == CohortMoveKind.allCases.map(\.rawValue),
                "the planner never plans a probe: nothing has come back when it plans")
        #expect(MemoryQuestionOperation.allCases.filter(\.isUnderstanding).map(\.rawValue) == ["principle", "transfer", "falsify", "analogy"])
        #expect(Probe.Kind(operation: .connect) == nil)
        #expect(Probe.Kind.principle.tutorDescription.contains("no proper nouns"))
        #expect(Probe.Kind.analogy.tutorDescription.contains("another notebook"))
        #expect(Probe.kindsLine.hasPrefix("PRINCIPLE ("))
    }

    @Test("The kinds rotate after the last one asked, the analogy only with a partner")
    func rotation() {
        #expect(Probe.rotation(after: nil, includesAnalogy: true) == [.principle, .transfer, .falsify, .analogy])
        #expect(Probe.rotation(after: .principle, includesAnalogy: true) == [.transfer, .falsify, .analogy, .principle])
        #expect(Probe.rotation(after: .analogy, includesAnalogy: true) == [.principle, .transfer, .falsify, .analogy])
        #expect(Probe.rotation(after: .transfer, includesAnalogy: false) == [.falsify, .principle, .transfer])
        #expect(Probe.next(after: .falsify, includesAnalogy: true) == .analogy)
        #expect(Probe.next(after: .falsify, includesAnalogy: false) == .principle, "no partner: the analogy is skipped")
        #expect(Probe.next(after: nil, includesAnalogy: false) == .principle)

        // A reopened review reads the last kind back off its saved grades.
        #expect(Probe.lastKind(operations: ["recall", nil, "transfer", "recall", "explain"]) == .transfer)
        #expect(Probe.lastKind(operations: ["recall", "connect"]) == nil)
        #expect(Probe.lastKind(operations: []) == nil)
    }

    // MARK: - When, and on which idea

    @Test("Go deeper turns to understanding once everything graded came back, on the idea probed least, wanted first")
    func whenAndWhich() {
        let a0 = idea("src-a", 0).id, a1 = idea("src-a", 1).id, b0 = idea("src-b", 0).id
        var states = MemoryReviewIdeaState.states(from: [exchange(1, [(a0, .produced), (a1, .partial), (b0, .produced)])])
        #expect(!Probe.isRecalled(ideaIDs: [a0, a1, b0], states: states), "a partial idea is still chased")
        #expect(!Probe.isRecalled(ideaIDs: [a0], states: [:]), "nothing graded yet")
        #expect(!Probe.isRecalled(ideaIDs: [], states: states))

        states = MemoryReviewIdeaState.states(from: [
            exchange(1, [(a0, .produced), (a1, .partial), (b0, .produced)]),
            exchange(2, [(a1, .produced)]),
        ])
        #expect(Probe.isRecalled(ideaIDs: [a0, a1, b0], states: states))
        #expect(Probe.isRecalled(ideaIDs: [a0, a1, b0, "src-c::idea::h::0"], states: states),
                "an idea the grader never cued does not hold the rest back")

        #expect(Probe.probeTarget(ideaIDs: [a0, a1, b0], wanted: [], states: states) == a0)
        #expect(Probe.probeTarget(ideaIDs: [a0, a1, b0], wanted: [b0], states: states) == b0, "wanted first")
        states = MemoryReviewIdeaState.states(from: [
            exchange(1, [(a0, .produced), (a1, .produced), (b0, .produced)]),
            exchange(2, [(b0, .partial)], operation: "principle"),
        ])
        #expect(Probe.probeTarget(ideaIDs: [a0, a1, b0], wanted: [b0], states: states) == a0, "the idea probed least comes first")
        #expect(Probe.probeTarget(ideaIDs: [], wanted: [], states: states) == nil)
    }

    // MARK: - The fold

    @Test("An understanding grade never veils, demotes or counts a miss against an idea that came back")
    func understandingNeverDemotes() {
        let a0 = idea("src-a", 0).id, b0 = idea("src-b", 0).id
        let topic = MemoryReviewTopic(id: "topic-1", title: "Uncoupling", kind: .new, ideaIDs: [a0, b0], intent: "")
        let ideasByID = [a0: idea("src-a", 0), b0: idea("src-b", 0)]
        let opening = exchange(1, [(a0, .produced), (b0, .produced)])
        let poorPrinciple = exchange(2, [(a0, .missing)], operation: "principle")
        let partialFalsify = exchange(3, [(a0, .partial)], operation: "falsify")

        let states = MemoryReviewIdeaState.states(from: [opening, poorPrinciple, partialFalsify])
        #expect(states[a0]?.status == .produced, "the recall stands")
        #expect(states[a0]?.missCount == 0, "a probe answered poorly is no miss")
        #expect(states[a0]?.understanding == .init(operation: .falsify, status: .partial, count: 2))
        #expect(states[b0] == MemoryReviewIdeaState(status: .produced, missCount: 0))

        // Neither ledger veils the row: the topic card's and the phone's.
        let rows = MemoryReviewIdeaState.ledgerRows(topic: topic, states: states, ideasByID: ideasByID)
        #expect(rows.map(\.status) == [.produced, .produced])
        #expect(rows.allSatisfy { !$0.isVeiled })

        // The checkmarks hear only the recall.
        let statuses = MemoryReviewSourceStatus.statuses(from: [opening, poorPrinciple], topics: [topic])
        #expect(statuses["topic-1"]?.coverage.map(\.status) == [.produced, .produced])
        #expect(statuses["src-a"]?.coverage == [MemoryIdeaCoverage(ideaID: a0, status: .produced)])
        #expect(statuses["topic-1"]?.gradedAt == now.addingTimeInterval(60), "the probe is not the topic's last grade")

        // An understanding grade that reached an idea first gives it no row.
        let stray = MemoryReviewIdeaState.states(from: [exchange(1, [(a0, .produced)], operation: "analogy")])
        #expect(stray.isEmpty)

        // A recall after a probe keeps what the probes said.
        let later = MemoryReviewIdeaState.states(from: [opening, poorPrinciple, exchange(3, [(a0, .partial)])])
        #expect(later[a0]?.status == .partial)
        #expect(later[a0]?.understanding?.count == 1)

        // The ladder hears each idea's first grade, which a probe never is.
        let ladder = MemoryLadderEvidence.outcomes([
            MemoryGradedExchange(sessionID: "s1", sequenceNumber: 1, ideaCoverage: opening.ideaCoverage, questionVerdict: "sound", answeredAt: now),
            MemoryGradedExchange(sessionID: "s1", sequenceNumber: 2, ideaCoverage: poorPrinciple.ideaCoverage, questionVerdict: "sound", answeredAt: now.addingTimeInterval(60)),
        ])
        #expect(ladder.first { $0.sourceID == "src-a" }?.producedFraction == 1)
    }

    @Test("A live grade folds the way a resume does")
    func liveFoldMatchesResume() {
        let a0 = idea("src-a", 0).id
        var live: [String: MemoryReviewIdeaState] = [:]
        MemoryReviewIdeaState.fold([MemoryIdeaCoverage(ideaID: a0, status: .produced)], operation: .recall, into: &live)
        MemoryReviewIdeaState.fold([MemoryIdeaCoverage(ideaID: a0, status: .missing)], operation: .transfer, into: &live)
        let resumed = MemoryReviewIdeaState.states(from: [exchange(1, [(a0, .produced)]), exchange(2, [(a0, .missing)], operation: "transfer")])
        #expect(live == resumed)
        #expect(live[a0]?.status == .produced)
    }

    // MARK: - The grader

    @Test("The grader takes an understanding probe's kind only past an idea's recall")
    func graderRules() throws {
        let a0 = idea("src-a", 0), b0 = idea("src-b", 0)
        let topic = MemoryReviewTopic(id: "topic-1", title: "T", kind: .new, ideaIDs: [a0.id, b0.id], intent: "")
        let ideasByID = [a0.id: a0, b0.id: b0]
        func validate(_ arguments: [String: Any], graded: Set<String>) -> Result<MemoryContourGrade, MemoryContourGrade.ValidationError> {
            MemoryContourGrade.validateTopic(arguments: arguments, topics: [topic], ideasByID: ideasByID, gradedIdeaIDs: graded)
        }
        let opening: [String: Any] = [
            "topic_id": "topic-1", "score": 1, "operation": "principle",
            "idea_coverage": [["idea_id": a0.id, "status": "produced"], ["idea_id": b0.id, "status": "produced"]],
        ]
        guard case .failure(let asOpening) = validate(opening, graded: []) else { Issue.record("a probe graded the opening"); return }
        #expect(asOpening.message.contains("topic-1's opening answer is a recall"))

        let probe: [String: Any] = [
            "topic_id": "topic-1", "score": 0.5, "operation": "Falsify",
            "idea_coverage": [["idea_id": a0.id, "status": "partial"]],
        ]
        let graded = try validate(probe, graded: [a0.id, b0.id]).get()
        #expect(graded.operation == .falsify)
        #expect(graded.coverage == [MemoryIdeaCoverage(ideaID: a0.id, status: .partial)])

        // Past the opening, but on an idea no recall reached.
        guard case .failure(let unrecalled) = validate(probe, graded: [b0.id]) else { Issue.record("a probe graded an unrecalled idea"); return }
        #expect(unrecalled.message.contains("idea \(a0.id) has had no recall graded yet"))

        // The analogy's partner is never the topic's, so it is never graded.
        var partnerGrade = probe
        partnerGrade["idea_coverage"] = [["idea_id": "src-z::idea::h::0", "status": "produced"]]
        guard case .failure(.foreignTopicIdea) = validate(partnerGrade, graded: [a0.id, b0.id]) else { Issue.record("a partner idea was graded"); return }

        // A contour is a recall.
        let contour: [String: Any] = [
            "source_id": "src-a", "score": 1, "operation": "transfer",
            "idea_coverage": [["idea_id": a0.id, "status": "produced"]],
        ]
        guard case .failure(let onContour) = MemoryContourGrade.validate(arguments: contour, ideasBySource: ["src-a": [a0]]) else {
            Issue.record("a probe graded a contour"); return
        }
        #expect(onContour.message.contains("a contour is a recall"))

        // The unknown-operation message names every operation there is.
        var unknown = probe
        unknown["operation"] = "summarize"
        guard case .failure(let bad) = validate(unknown, graded: [a0.id, b0.id]) else { Issue.record("an unknown operation passed"); return }
        #expect(bad.message.contains("recall, explain, contrast, apply, connect, principle, transfer, falsify, analogy"))
    }

    @Test("The tutor hears that a topic came back whole, and that a probe's grade only says how deep")
    func acknowledgements() {
        let a0 = idea("src-a", 0).id, b0 = idea("src-b", 0).id
        let topic = MemoryReviewTopic(id: "topic-1", title: "T", kind: .new, ideaIDs: [a0, b0], intent: "")
        func grade(_ entries: [(String, MemoryIdeaCoverage.Status)], _ operation: MemoryQuestionOperation) -> MemoryContourGrade {
            MemoryContourGrade(
                sourceID: "topic-1",
                coverage: entries.map { MemoryIdeaCoverage(ideaID: $0.0, status: $0.1) },
                score: 1, verdict: .sound, operation: operation, evaluation: nil
            )
        }
        let whole = MemoryReviewTutoring.topicGradeAcknowledgement(
            grade: grade([(a0, .produced), (b0, .produced)], .recall), topic: topic, isOpening: true
        )
        #expect(whole.contains("the whole topic has come back"))
        #expect(whole.contains("Go deeper now goes past recall"))
        #expect(whole.contains("without pressing it"))

        let priorStates = MemoryReviewIdeaState.states(from: [exchange(1, [(a0, .produced), (b0, .partial)])])
        let lastOne = MemoryReviewTutoring.topicGradeAcknowledgement(
            grade: grade([(b0, .produced)], .recall), topic: topic, isOpening: false, priorStates: priorStates
        )
        #expect(lastOne.contains("the whole topic has come back"), "the probe brought the last idea back")
        let stillOpen = MemoryReviewTutoring.topicGradeAcknowledgement(
            grade: grade([(a0, .produced)], .recall), topic: topic, isOpening: false,
            priorStates: MemoryReviewIdeaState.states(from: [exchange(1, [(a0, .missing), (b0, .partial)])])
        )
        #expect(stillOpen.contains("Nothing in this answer is left missing or partial; say so in a clause."))
        #expect(!stillOpen.contains("Go deeper now goes past recall"))

        let probed = MemoryReviewTutoring.topicGradeAcknowledgement(
            grade: grade([(a0, .missing)], .principle), topic: topic, isOpening: false, priorStates: priorStates
        )
        #expect(probed.hasPrefix("Recorded the principle probe as missing."))
        #expect(probed.contains("not whether the idea came back"))
        #expect(probed.contains("no score and no flattery"))
        #expect(!probed.contains("re-teach"))
    }

    @Test("The review chat's note names the probe, the idea, the partner and how to grade it")
    func reviewNote() {
        let partner = Probe.AnalogyPartner(sourceID: "src-z", sourceTitle: "Cities as organisms", notebookTitle: "Urbanism", statement: "Cities scale sublinearly in infrastructure.")
        let note = Probe.reviewNote(kind: .analogy, ideaID: "src-a::idea::h::0", topicID: "topic-2", partner: partner)
        #expect(note.hasPrefix("[ForeverLM] Everything here came back"))
        #expect(note.contains("Ask ONE ANALOGY probe on idea [src-a::idea::h::0]"))
        #expect(note.contains("from Cities as organisms, in the notebook Urbanism: \"Cities scale sublinearly in infrastructure.\""))
        #expect(note.contains("grade_topic_recall for topic-2"))
        #expect(note.contains("operation \"analogy\""))

        let bySource = Probe.reviewNote(kind: .principle, ideaID: "src-a::idea::h::0", topicID: nil, partner: partner)
        #expect(bySource.contains("do not call the grader"))
        #expect(!bySource.contains("Cities as organisms"), "only an analogy names a partner")
    }

    // MARK: - The partner

    @Test("The Mac's partner is the nearest source in another notebook, with an idea to lend")
    func macPartner() {
        let research = Probe.Notebook(id: "nb-1", title: "Mitochondria")
        let cities = Probe.Notebook(id: "nb-2", title: "Urbanism")
        let notebooks: [String: [Probe.Notebook]] = [
            "src-a": [research],
            "near-same": [research, cities],
            "near-none": [],
            "near-untitled": [cities],
            "near-no-ideas": [cities],
            "near-excluded": [cities],
            "far": [cities],
        ]
        let titles = ["near-same": "Same", "near-no-ideas": "No ideas", "near-excluded": "Hidden show", "far": "Cities as organisms"]
        let ideas = [
            "near-same": [idea("near-same", 0)],
            "near-untitled": [idea("near-untitled", 0)],
            "near-excluded": [idea("near-excluded", 0)],
            "far": [idea("far", 0), idea("far", 1, wanted: true)],
        ]
        let partner = Probe.analogyPartner(
            ranked: ["src-a", "near-same", "near-none", "near-untitled", "near-no-ideas", "near-excluded", "far"],
            anchors: ["src-a"],
            notebooksBySource: notebooks,
            titles: titles,
            ideasBySource: ideas,
            excluded: ["near-excluded"]
        )
        #expect(partner == Probe.AnalogyPartner(sourceID: "far", sourceTitle: "Cities as organisms", notebookTitle: "Urbanism", statement: "Idea 1 of far."))

        // An anchor in no notebook: any source in a notebook is another one.
        #expect(Probe.isInAnotherNotebook([cities], than: []))
        #expect(!Probe.isInAnotherNotebook([], than: []))
        #expect(!Probe.isInAnotherNotebook([research, cities], than: ["nb-1"]))

        // Rankings from several anchors merge by rank, never by score.
        #expect(Probe.interleaved([["a", "b", "c"], ["x", "a"], []]) == ["a", "x", "b", "c"])
    }

    @Test("The phone's partner is another topic's idea that came back, from another notebook")
    func phonePartner() {
        let a0 = idea("src-a", 0), b0 = idea("src-b", 0), b1 = idea("src-b", 1, wanted: true), c0 = idea("src-c", 0)
        let topics = [
            MemoryReviewTopic(id: "topic-1", title: "Uncoupling", kind: .new, ideaIDs: [a0.id], intent: ""),
            MemoryReviewTopic(id: "topic-2", title: "Same notebook", kind: .new, ideaIDs: [c0.id], intent: ""),
            MemoryReviewTopic(id: "topic-3", title: "Cities", kind: .due, ideaIDs: [b0.id, b1.id], intent: ""),
        ]
        let ideasByID = [a0.id: a0, b0.id: b0, b1.id: b1, c0.id: c0]
        let notebooks: [String: [Probe.Notebook]] = [
            "src-a": [.init(id: "nb-1", title: "Mitochondria")],
            "src-b": [.init(id: "nb-2", title: "Urbanism")],
            "src-c": [.init(id: "nb-1", title: "Mitochondria")],
        ]
        let titles = ["src-b": "Cities as organisms", "src-c": "Respiration"]
        var states = MemoryReviewIdeaState.states(from: [
            exchange(1, [(a0.id, .produced)]), exchange(2, [(c0.id, .produced)]), exchange(3, [(b0.id, .produced), (b1.id, .missing)]),
        ])
        var partner = Probe.analogyPartner(
            forTopic: topics[0], among: topics, ideasByID: ideasByID, states: states, notebooksBySource: notebooks, titles: titles
        )
        #expect(partner?.statement == b0.statement, "the wanted idea did not come back, so it is never read out")
        #expect(partner?.notebookTitle == "Urbanism")

        states = MemoryReviewIdeaState.states(from: [exchange(1, [(a0.id, .produced)]), exchange(2, [(c0.id, .produced)])])
        partner = Probe.analogyPartner(
            forTopic: topics[0], among: topics, ideasByID: ideasByID, states: states, notebooksBySource: notebooks, titles: titles
        )
        #expect(partner == nil, "a topic not asked yet lends nothing, and the same notebook is no analogy")
    }

    // MARK: - The card review's calls

    @Test("The card question writer is told the kinds in order and the partner only for an analogy, and its JSON is read strictly")
    func cardQuestion() throws {
        let partner = Probe.AnalogyPartner(sourceID: "far", sourceTitle: "Cities as organisms", notebookTitle: "Urbanism", statement: "Cities scale sublinearly.")
        let request = Probe.CardQuestionRequest(
            front: "What couples respiration to ATP synthesis?", back: "A proton gradient.", why: ["Mitchell's chemiosmosis."],
            sourceTitle: "Mitochondria", kinds: Probe.rotation(after: .principle, includesAnalogy: true), partner: partner
        )
        let message = Probe.cardQuestionMessage(request)
        #expect(message.contains("Front: What couples respiration to ATP synthesis?"))
        #expect(message.contains("Why: Mitchell's chemiosmosis."))
        #expect(message.contains("Source: Mitochondria"))
        let order = ["- transfer:", "- falsify:", "- analogy:", "- principle:"].compactMap { message.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted(), "the kinds in rotation order")
        #expect(message.contains("Cities scale sublinearly."))
        let withoutAnalogy = Probe.CardQuestionRequest(
            front: "Q", back: "A", why: [], sourceTitle: nil, kinds: [.principle, .transfer, .falsify], partner: partner
        )
        #expect(!Probe.cardQuestionMessage(withoutAnalogy).contains("Cities"))

        let kinds = request.kinds
        #expect(try Probe.cardQuestion(from: #"{"kind": "none"}"#, offered: kinds) == nil)
        #expect(try Probe.cardQuestion(from: "Here:\n```json\n{\"kind\": \"Falsify\", \"question\": \" What result would break it? \"}\n```", offered: kinds)
            == Probe.CardQuestion(kind: .falsify, text: "What result would break it?"))
        #expect(throws: Probe.ResponseError.unreadable) { try Probe.cardQuestion(from: #"{"kind": "analogy", "question": "Like?"}"#, offered: [.principle]) }
        #expect(throws: Probe.ResponseError.unreadable) { try Probe.cardQuestion(from: #"{"kind": "principle", "question": "  "}"#, offered: kinds) }
        #expect(throws: Probe.ResponseError.unreadable) { try Probe.cardQuestion(from: #"{"kind": "summary", "question": "Why?"}"#, offered: kinds) }
        #expect(throws: Probe.ResponseError.unreadable) { try Probe.cardQuestion(from: "no JSON here", offered: kinds) }

        let reply = Probe.CardReplyRequest(
            front: "Q", back: "A", why: [], sourceTitle: nil,
            question: Probe.CardQuestion(kind: .analogy, text: "How is a cell like a city?"),
            answer: "Both pay to keep a gradient.", partner: partner
        )
        let replyMessage = Probe.cardReplyMessage(reply)
        #expect(replyMessage.contains("THE QUESTION: How is a cell like a city?"))
        #expect(replyMessage.hasSuffix("THE LEARNER'S ANSWER:\nBoth pay to keep a gradient."))
        #expect(replyMessage.contains("Cities scale sublinearly."))
        #expect(try Probe.cardReply(from: "  It got the gradient.  ") == "It got the gradient.")
        #expect(throws: Probe.ResponseError.unreadable) { try Probe.cardReply(from: " \n ") }
    }
}

#if os(macOS)
/// The card deck's ledger reads the same states.
@MainActor
struct MemoryUnderstandingProbeLedgerTests {
    @Test("The Mac card's ledger never veils an idea a probe was answered poorly on")
    func cardLedger() {
        let a0 = "src-a::idea::h::0"
        var states: [String: MemoryReviewIdeaState] = [:]
        MemoryReviewIdeaState.fold([MemoryIdeaCoverage(ideaID: a0, status: .produced)], operation: .recall, into: &states)
        MemoryReviewIdeaState.fold([MemoryIdeaCoverage(ideaID: a0, status: .missing)], operation: .principle, into: &states)
        MemoryReviewIdeaState.fold([MemoryIdeaCoverage(ideaID: a0, status: .missing)], operation: .analogy, into: &states)
        let rows = MemoryReviewTopicCardFold.ledgerRows(ideaIDs: [a0], states: states) { _ in "The idea." }
        #expect(rows.map(\.status) == [.produced])
        #expect(rows.first?.isVeiled == false)
        #expect(rows.first?.statement == "The idea.")
    }
}
#endif
