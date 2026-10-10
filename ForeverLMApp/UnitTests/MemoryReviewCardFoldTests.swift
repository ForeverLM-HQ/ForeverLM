import Foundation
import Testing
@testable import ForeverLM

#if os(macOS)

/// A memory review drawn as cards (`MemoryReviewCardFold`): one exchange a
/// card, detours kept on the card they were asked from, and the chat itself
/// never changed.
@MainActor
struct MemoryReviewCardFoldTests {

    private typealias Message = ReviewSessionManager.Message

    private func tutor(_ text: String) -> Message { Message(role: .assistant, content: text) }
    private func learner(_ text: String) -> Message { Message(role: .user, content: text) }
    private func aside(_ text: String) -> Message {
        Message(role: .user, content: text, contextualContent: ChatSideQuestion.contextContent(openQuestion: "What did it find?"))
    }

    private func contents(_ messages: [Message], _ card: MemoryReviewCardFold.Card) -> [String] {
        messages[card.range].map(\.content)
    }

    @Test("The opening is the first card; each answer starts a card holding what the tutor made of it")
    func oneExchangeACard() {
        let messages = [
            tutor("Today covers two papers. What did the first one find?"),
            learner("Complex I was the bottleneck."),
            tutor("Yes — and the second idea? Next question: why?"),
            learner("Because of ROS."),
            tutor("Close."),
        ]
        let cards = MemoryReviewCardFold.cards(messages)
        #expect(cards.count == 3)
        #expect(contents(messages, cards[0]) == ["Today covers two papers. What did the first one find?"])
        #expect(contents(messages, cards[1]) == ["Complex I was the bottleneck.", "Yes — and the second idea? Next question: why?"])
        #expect(contents(messages, cards[2]) == ["Because of ROS.", "Close."])
        #expect(cards.flatMap { Array($0.range) } == Array(messages.indices), "every message is on exactly one card")
    }

    @Test("A side question and its reply stay on the card they were asked from")
    func detoursStayOnTheirCard() {
        let messages = [
            tutor("What did it find?"),
            aside("Wait, what is PCr?"),
            tutor("Phosphocreatine — the quiz waits."),
            learner("It found a drop in PCr."),
            tutor("Right."),
        ]
        let cards = MemoryReviewCardFold.cards(messages)
        #expect(cards.count == 2)
        #expect(contents(messages, cards[0]) == ["What did it find?", "Wait, what is PCr?", "Phosphocreatine — the quiz waits."])
        #expect(contents(messages, cards[1]) == ["It found a drop in PCr.", "Right."])
    }

    @Test("A sent answer deals its card at once, and two messages with no reply between them share it")
    func pendingAnswerIsTheNewestCard() {
        let messages = [
            tutor("What did it find?"),
            learner("A drop in PCr."),
            learner("And in ATP, a little."),
        ]
        let cards = MemoryReviewCardFold.cards(messages)
        #expect(cards.count == 2)
        #expect(contents(messages, cards[1]) == ["A drop in PCr.", "And in ATP, a little."])

        let newest = MemoryReviewCardFold.thread(messages, selected: nil)
        #expect(newest.isNewest)
        #expect(newest.messages.map(\.content) == ["A drop in PCr.", "And in ATP, a little."])
    }

    @Test("Tool rows and blank turns never deal a card")
    func toolRowsAndBlanksDoNotCount() {
        let messages = [
            tutor("First question?"),
            Message(role: .tool, content: ""),
            learner("   "),
            learner("An answer."),
            Message(role: .tool, content: ""),
            tutor("Graded."),
        ]
        let cards = MemoryReviewCardFold.cards(messages)
        #expect(cards.count == 2)
        #expect(cards[1].range == 3..<6)
    }

    @Test("Each card knows the source the tutor is on by its end")
    func cardsCarryTheirSource() {
        let messages = [
            tutor("Today covers two.\n\n\(MemoryReviewSourceTurn.line(sourceID: "paper-a"))\nWhat did A find?"),
            learner("A found X."),
            tutor("Good."),
            learner("Next."),
            tutor("\(MemoryReviewSourceTurn.line(sourceID: "paper-b"))\nWhat did B find?"),
        ]
        let cards = MemoryReviewCardFold.cards(messages)
        #expect(cards.map(\.sourceID) == ["paper-a", "paper-a", "paper-b"])
        #expect(MemoryReviewCardFold.cards([tutor("Nothing is due today.")]).map(\.sourceID) == [nil])
    }

    @Test("The phone and the Mac deal by one rule: an answer after a reply starts a card, and nothing else does")
    func sharedDealingRule() {
        let turns: [MemoryReviewCardDealing.Turn] = [
            .reply(turnsTo: "a"), .other, .answer, .answer, .reply(turnsTo: nil), .other, .reply(turnsTo: "b"), .answer,
        ]
        let cards = MemoryReviewCardDealing.cards(turns)
        #expect(cards.map(\.range) == [0..<2, 2..<7, 7..<8])
        #expect(cards.map(\.sourceID) == ["a", "b", "b"])
        // A learner turn first (nothing on the Mac hides the opening) is the
        // first card, not a card before it.
        #expect(MemoryReviewCardDealing.cards([.answer, .reply(turnsTo: nil)]).map(\.range) == [0..<2])
        #expect(MemoryReviewCardDealing.cards([]).isEmpty)
    }

    @Test("Back and Next move one card and land on nil at the newest")
    func stepping() {
        #expect(MemoryReviewCardDealing.step(nil, by: -1, count: 3) == 1)
        #expect(MemoryReviewCardDealing.step(1, by: -1, count: 3) == 0)
        #expect(MemoryReviewCardDealing.step(0, by: -1, count: 3) == 0)
        #expect(MemoryReviewCardDealing.step(1, by: 1, count: 3) == nil)
        #expect(MemoryReviewCardDealing.step(nil, by: 1, count: 3) == nil)
        #expect(MemoryReviewCardDealing.step(nil, by: -1, count: 0) == nil)
    }

    @Test("A chosen card is shown as a record; a choice out of range falls back to the newest")
    func selection() {
        let messages = [tutor("Q1?"), learner("A1."), tutor("Q2?")]
        let first = MemoryReviewCardFold.thread(messages, selected: 0)
        #expect(!first.isNewest)
        #expect(first.messages.map(\.content) == ["Q1?"])

        #expect(MemoryReviewCardFold.resolvedIndex(nil, count: 2) == 1)
        #expect(MemoryReviewCardFold.resolvedIndex(7, count: 2) == 1)
        #expect(MemoryReviewCardFold.resolvedIndex(0, count: 0) == nil)

        // A review still being planned has no card; the whole (empty) chat
        // is the newest, so the working line has somewhere to stand.
        let empty = MemoryReviewCardFold.thread([], selected: nil)
        #expect(empty.isNewest)
        #expect(empty.messages.isEmpty)
    }

    // MARK: - A review by topic

    /// The heading row the manager writes where the tutor turned to a topic.
    private func topicTurn(_ id: String, title: String = "A topic") -> Message {
        Message(
            role: .tool,
            content: "",
            toolActivity: .init(
                kind: .sourceTurn,
                toolName: ReviewSessionManager.sourceTurnActivityName,
                detail: id,
                sourcePresentation: nil,
                state: .succeeded,
                resultPreview: nil,
                customTitle: title
            )
        )
    }

    @Test("A review by topic deals one card per topic, from turn row to turn row")
    func oneTopicACard() {
        let messages = [
            tutor("Today covers two topics."),
            topicTurn("topic-1"),
            tutor("What turns a cell into a cancer cell?"),
            learner("Mutations, then selection."),
            tutor("Both stories came back."),
            learner("Next."),
            topicTurn("topic-2"),
            tutor("What does an uncoupler do?"),
            learner("Lets protons through."),
        ]
        let cards = MemoryReviewCardFold.cards(messages, byTopic: true)
        #expect(cards.map(\.range) == [0..<6, 6..<9])
        #expect(cards.map(\.sourceID) == ["topic-1", "topic-2"])
        #expect(cards.flatMap { Array($0.range) } == Array(messages.indices), "every message is on exactly one card")
        // The same chat dealt the old way is still one exchange a card.
        #expect(MemoryReviewCardFold.cards(messages).count == 4)

        let record = MemoryReviewCardFold.thread(messages, selected: 0, byTopic: true)
        #expect(!record.isNewest)
        #expect(record.sourceID == "topic-1")
        let newest = MemoryReviewCardFold.thread(messages, selected: nil, byTopic: true)
        #expect(newest.isNewest)
        #expect(newest.sourceID == "topic-2")
    }

    @Test("A turn line still streaming as text starts the topic's card too")
    func streamingTurnStartsACard() {
        let messages = [
            topicTurn("topic-1"),
            tutor("First question?"),
            learner("Next."),
            tutor("\(MemoryReviewSourceTurn.line(sourceID: "topic-2"))\nSecond question?"),
        ]
        let cards = MemoryReviewCardFold.cards(messages, byTopic: true)
        #expect(cards.map(\.range) == [0..<3, 3..<4])
        #expect(cards.map(\.sourceID) == ["topic-1", "topic-2"])
    }

    @Test("A topic card's opening is the prose after the turn, with what came before it as preamble")
    func openingOfATopicCard() {
        let settled = [tutor("Today covers two topics."), topicTurn("topic-1"), tutor("What turns a cell rogue?")]
        #expect(MemoryReviewTopicCardFold.opening(in: settled) == .init(
            topicID: "topic-1", preamble: "Today covers two topics.", question: "What turns a cell rogue?"
        ))
        let streaming = [tutor("Good.\n\n\(MemoryReviewSourceTurn.line(sourceID: "topic-2"))\nWhat does an uncoupler do?")]
        #expect(MemoryReviewTopicCardFold.opening(in: streaming) == .init(
            topicID: "topic-2", preamble: "Good.", question: "What does an uncoupler do?"
        ))
        // The turn line has arrived and the question has not.
        #expect(MemoryReviewTopicCardFold.opening(in: [topicTurn("topic-3")])?.question == "")
        // A reply with no turn is a reply, drawn as one.
        #expect(MemoryReviewTopicCardFold.opening(in: [tutor("Both stories came back.")]) == nil)
    }

    @Test("The newest topic card's foot follows the last two turns: field, reading, steers")
    func footOfATopicCard() {
        typealias Fold = MemoryReviewTopicCardFold
        let question = [topicTurn("topic-1"), tutor("What turns a cell rogue?")]
        #expect(Fold.foot(question, isNewest: true, isGraded: false, isBusy: false) == .answer)
        // Sent, being graded.
        let sent = question + [learner("Mutations, then selection.")]
        #expect(Fold.foot(sent, isNewest: true, isGraded: false, isBusy: true) == .reading)
        // Sent, nothing back, tutor idle: the field again, so it can be resent.
        #expect(Fold.foot(sent, isNewest: true, isGraded: false, isBusy: false) == .answer)
        // Graded and replied to: the two steers.
        let graded = sent + [tutor("Both stories came back.")]
        #expect(Fold.foot(graded, isNewest: true, isGraded: true, isBusy: false) == .steer)
        // Replied to without a grade landing: the field, not a steer.
        #expect(Fold.foot(graded, isNewest: true, isGraded: false, isBusy: false) == .answer)
        // Go deeper: the probe is a question again, and the wait for it is
        // the working line, not "Reading your answer".
        let deeper = graded + [learner(MemoryReviewTutoring.steerMessage(.deeper))]
        #expect(Fold.foot(deeper, isNewest: true, isGraded: true, isBusy: true) == .none)
        let probe = deeper + [tutor("Which story did Levin tell?")]
        #expect(Fold.foot(probe, isNewest: true, isGraded: true, isBusy: false) == .answer)
        // A side question and its reply leave the open question open.
        let detour = question + [aside("What is a clone?"), tutor("A lineage from one cell.")]
        #expect(Fold.foot(detour, isNewest: true, isGraded: false, isBusy: false) == .answer)
        // "I don't remember" is an answer, graded like one.
        let miss = question + [learner(MemoryReviewTutoring.dontRememberMessage), tutor("Nothing came back; that is fine.")]
        #expect(Fold.foot(miss, isNewest: true, isGraded: true, isBusy: false) == .steer)
        // An older card carries nothing of its own.
        #expect(Fold.foot(graded, isNewest: false, isGraded: true, isBusy: false) == .none)
        #expect(Fold.foot([], isNewest: true, isGraded: false, isBusy: false) == .none)
        // The stepper's words are steers, so the card after them waits for an answer.
        #expect(Fold.isSteer(learner(Fold.takeNowMessage(title: "Proton leak"))))
        #expect(Fold.isSteer(learner(Fold.deeperOnMessage(title: "Proton leak"))))
        #expect(Fold.isSteer(learner(Fold.skipMessage(title: "Proton leak"))))
        #expect(!Fold.isSteer(learner("Let's see, a clone is a lineage.")))
    }

    @Test("The ledger has a row per graded idea in the topic's order, and a missing idea stays veiled until re-taught")
    func ledgerRows() {
        let topic = MemoryReviewTopic(
            id: "topic-1",
            title: "When a cell stops listening",
            kind: .new,
            ideaIDs: ["src-a::idea::0", "src-b::idea::0", "src-a::idea::1", "src-c::idea::0"],
            intent: "push on the voltage half"
        )
        let states: [String: MemoryReviewIdeaState] = [
            "src-a::idea::0": .init(status: .produced, missCount: 0),
            "src-b::idea::0": .init(status: .missing, missCount: 1),
            "src-a::idea::1": .init(status: .partial, missCount: 0),
            // src-c::idea::0 has not been graded: no row.
        ]
        let statements = [
            "src-a::idea::0": "Cancer is evolution inside the body.",
            "src-b::idea::0": "A cancer cell leaves the electrical network.",
            "src-a::idea::1": "It takes many independent hits.",
        ]
        let rows = MemoryReviewTopicCardFold.ledgerRows(topic: topic, states: states) { statements[$0] }
        #expect(rows.map(\.ideaID) == ["src-a::idea::0", "src-b::idea::0", "src-a::idea::1"])
        #expect(rows.map(\.sourceID) == ["src-a", "src-b", "src-a"])
        #expect(rows.map(\.status) == [.produced, .missing, .partial])
        #expect(rows.map(\.isVeiled) == [false, true, false])
        #expect(rows[0].statement == "Cancer is evolution inside the body.")
        #expect(rows[1].statement == nil, "a missing idea is never read out")
        #expect(rows[2].statement == "It takes many independent hits.")

        // Missed twice, the tutor re-taught it: the row shows it.
        let reTaught = states.merging(["src-b::idea::0": .init(status: .missing, missCount: 2)]) { _, new in new }
        let revealed = MemoryReviewTopicCardFold.ledgerRows(topic: topic, states: reTaught) { statements[$0] }
        #expect(revealed[1].isVeiled == false)
        #expect(revealed[1].statement == "A cancer cell leaves the electrical network.")

        #expect(MemoryReviewTopicCardFold.ledgerRows(topic: topic, states: [:]) { statements[$0] }.isEmpty)
    }

    @Test("A source-by-source review is dealt a card per source, a chat's turn row included")
    func sourceCardsDealtBySource() {
        // A chat has no library record, so its settled turn row carries the
        // id in `detail`, the way a topic's does.
        let messages = [
            tutor("Today covers a paper and yesterday's chat."),
            topicTurn("src-paper"),
            tutor("What did the paper find?"),
            learner("Complex I was the bottleneck."),
            tutor("Yes."),
            learner("Next."),
            topicTurn("chat-yesterday", title: "Bioelectric voltage and cancer"),
            tutor("What did you take away from the chat?"),
        ]
        let cards = MemoryReviewCardFold.cards(messages, byTopic: true)
        #expect(cards.map(\.range) == [0..<6, 6..<8])
        #expect(cards.map(\.sourceID) == ["src-paper", "chat-yesterday"])
        #expect(messages[6].toolActivity?.turnTargetID == "chat-yesterday")
    }

    @Test("A question asked without a turn line is still the card's question, after its preamble")
    func untitledOpening() {
        typealias Fold = MemoryReviewTopicCardFold
        let opening = [tutor(
            "Today's review covers the bioelectric thread you flagged.\n\n"
                + "What did you take away from yesterday's chat, in your own words?"
        )]
        #expect(Fold.untitledOpening(in: opening) == .init(
            topicID: "",
            preamble: "Today's review covers the bioelectric thread you flagged.",
            question: "What did you take away from yesterday's chat, in your own words?"
        ))
        #expect(Fold.untitledOpening(in: [tutor("Why does it depolarize?")])?.preamble == nil)
        // Prose that asks nothing, and block markdown, are drawn as replies.
        #expect(Fold.untitledOpening(in: [tutor("Both stories came back.")]) == nil)
        #expect(Fold.untitledOpening(in: [tutor("Two things:\n\n- voltage\n- coupling\n\nWhich came first?")]) == nil)
        #expect(Fold.untitledOpening(in: [tutor("Steps:\n\n1. read\n2. recall\n\nReady?")]) == nil)
        // A turn line makes it a titled opening, which `opening(in:)` reads.
        #expect(Fold.untitledOpening(in: [tutor("\(MemoryReviewSourceTurn.line(sourceID: "src-a"))\nWhat did it find?")]) == nil)
    }

    @Test("A source's card subject names its noun, its own face, and a ledger in the order given")
    func sourceSubject() {
        let source = MemoryReviewCardSubject(sourceID: "src-a", title: "Chapter 20: Cancer", ideaIDs: ["src-a::idea::1", "src-a::idea::0"])
        #expect(!source.isTopic)
        #expect(source.sourceIDs == ["src-a"])
        #expect(MemoryReviewCardSubject.noun([source], plural: false) == "source")
        #expect(MemoryReviewCardSubject.noun([source, source], plural: true) == "sources")
        let topic = MemoryReviewCardSubject(topic: MemoryReviewTopic(
            id: "topic-1", title: "Voltage", kind: .weak, ideaIDs: ["src-b::idea::0"], intent: ""
        ))
        #expect(topic.isTopic)
        #expect(topic.sourceIDs == ["src-b"])
        #expect(MemoryReviewCardSubject.noun([topic], plural: true) == "topics")

        let states: [String: MemoryReviewIdeaState] = [
            "src-a::idea::0": .init(status: .produced, missCount: 0),
            "src-a::idea::1": .init(status: .partial, missCount: 0),
        ]
        let rows = MemoryReviewTopicCardFold.ledgerRows(ideaIDs: source.ideaIDs, states: states) { _ in "idea" }
        #expect(rows.map(\.ideaID) == ["src-a::idea::1", "src-a::idea::0"])
    }
}
#endif
