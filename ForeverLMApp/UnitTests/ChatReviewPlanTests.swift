import Foundation
import Testing
@testable import ForeverLM

@Suite("A chat's review plan, kept beside the composer")
struct ChatReviewPlanTests {

    private static func samplePlan(detours: [String] = []) -> ChatReviewPlan {
        ChatReviewPlan(
            title: "Episode on mitochondria",
            topics: [
                .init(title: "What mitochondria do", status: .active, points: [
                    .init(text: "ATP, building blocks and signals", status: .done),
                    .init(text: "Why antioxidant trials fail", status: .partial),
                    .init(text: "Ferroptosis and GPX4", status: .todo),
                ]),
                .init(title: "Excess capacity", status: .todo, points: [
                    .init(text: "The ~70% threshold", status: .done),
                ]),
                .init(title: "Supplements", status: .done),
            ],
            openQuestion: "What gets released, and what does it activate?",
            detours: detours,
            parked: ["Fit with the mtDNA paper"]
        )
    }

    @Test("The stored line round-trips the whole plan and names its progress")
    func lineRoundTrips() throws {
        let plan = Self.samplePlan(detours: ["Lane on apoptosis", "Cytochrome c [in] Transformer"])
        let line = plan.markdownLine
        #expect(line.hasPrefix("[Review plan · Topic 1 of 3](foreverlm://chat-plan?state="))
        let parsed = try #require(ChatReviewPlan.parse(line: line))
        #expect(parsed == plan)
    }

    @Test("A stored reply keeps its prose, and the plan comes back off its head")
    func storingAndProse() throws {
        let plan = Self.samplePlan()
        let stored = ChatReviewPlan.storing("You have two of the three.\n\nNext question?", with: plan)
        #expect(ChatReviewPlan.prose(of: stored) == "You have two of the three.\n\nNext question?")
        #expect(ChatReviewPlan.parse(storedReply: stored) == plan)
        #expect(ChatReviewPlan.storing("Plain reply", with: nil) == "Plain reply")
        #expect(ChatReviewPlan.prose(of: "Plain reply\n") == "Plain reply\n", "a reply with no plan is untouched")
    }

    @Test("A link the reply wrote itself is prose, not a plan")
    func ordinaryLinksStayProse() {
        let reply = "[Review plan](https://example.org/plan)\n\nSee [the paper](foreverlm://source/src_1)."
        #expect(ChatReviewPlan.parse(storedReply: reply) == nil)
        #expect(ChatReviewPlan.prose(of: reply) == reply)
    }

    @Test("A reopened chat holds its last plan and lists the plans it replaced")
    func latestAndEarlier() {
        var first = Self.samplePlan()
        first.title = "Gozdecka paper and the mtDNA fit"
        var short = Self.samplePlan()
        short.title = "Episode, short plan"
        let current = Self.samplePlan()
        var ticked = current
        ticked.topics[0].points[1].status = .done
        let replies = [
            ChatReviewPlan.storing("a", with: first),
            "no plan here",
            ChatReviewPlan.storing("b", with: short),
            ChatReviewPlan.storing("c", with: current),
            ChatReviewPlan.storing("d", with: ticked),
        ]
        let found = ChatReviewPlan.latest(inStoredReplies: replies)
        #expect(found.plan == ticked)
        #expect(found.earlierTitles == ["Gozdecka paper and the mtDNA fit", "Episode, short plan"])
        #expect(ChatReviewPlan.latest(inStoredReplies: ["x", "y"]).plan == nil)
    }

    @Test("The tool's arguments become a trimmed plan")
    func fromToolArguments() throws {
        let arguments: [String: Any] = [
            "title": "  Episode  ",
            "topics": [
                ["title": "Functions", "status": "active", "points": [
                    ["text": " ATP ", "status": "done"],
                    ["text": "   ", "status": "todo"],
                ]],
                ["title": "Metformin", "status": "todo", "points": []],
            ],
            "open_question": "  ",
            "detours": ["Lane on apoptosis", ""],
        ]
        let plan = try ChatReviewPlan.fromToolArguments(arguments)
        #expect(plan.title == "Episode")
        #expect(plan.topics[0].points == [.init(text: "ATP", status: .done)])
        #expect(plan.openQuestion == nil)
        #expect(plan.detours == ["Lane on apoptosis"])
        #expect(plan.parked.isEmpty)
        #expect(plan.isOnDetour)
        #expect(plan.progressLabel == "Topic 1 of 2")
    }

    @Test("A plan the tool cannot keep is refused with a reason")
    func refusals() {
        func refused(_ arguments: [String: Any]) -> Bool {
            (try? ChatReviewPlan.fromToolArguments(arguments)) == nil
        }
        #expect(refused(["title": "", "topics": [["title": "A", "status": "todo", "points": []]]]))
        #expect(refused(["title": "T", "topics": []]))
        #expect(refused(["title": "T", "topics": [
            ["title": "A", "status": "active", "points": []],
            ["title": "B", "status": "active", "points": []],
        ]]), "two active topics")
        #expect(refused(["title": "T", "topics": [["title": "A", "status": "partial", "points": []]]]), "partial is a point's status")
        #expect(refused(["title": "T", "topics": [["title": "A", "status": "todo", "points": [["text": "p", "status": "active"]]]]]))
        #expect(refused(["title": "T", "topics": [["title": "A", "status": "someday", "points": []]]]))
    }

    @Test("The tutor reads every point, the open question, the detours and what is parked")
    func turnContext() {
        let context = Self.samplePlan(detours: ["Lane on apoptosis"]).turnContext
        #expect(context.contains("1. [>] What mitochondria do"))
        #expect(context.contains("   - [~] Why antioxidant trials fail"))
        #expect(context.contains("3. [x] Supplements"))
        #expect(context.contains("Open question: What gets released, and what does it activate?"))
        #expect(context.contains("Detours, outermost first: Lane on apoptosis"))
        #expect(context.contains("Parked for later: Fit with the mtDNA paper"))
        #expect(Self.samplePlan().turnContext.contains("none — the chat is on the plan"))
    }

    @Test("With no topic active the label counts what is done")
    func doneLabel() {
        let plan = ChatReviewPlan(title: "T", topics: [
            .init(title: "A", status: .done),
            .init(title: "B", status: .skipped),
            .init(title: "C", status: .todo),
        ])
        #expect(plan.progressLabel == "2 of 3 done")
    }

    @Test("Clearing the plan ends it on reopen, and it is listed as an earlier plan")
    func clearedLine() {
        let plan = Self.samplePlan()
        let replies = [
            ChatReviewPlan.storing("a", with: plan),
            "b\n\n" + ChatReviewPlan.clearedLine,
        ]
        let found = ChatReviewPlan.latest(inStoredReplies: replies)
        #expect(found.plan == nil)
        #expect(found.earlierTitles == ["Episode on mitochondria"])
        #expect(ChatReviewPlan.prose(of: replies[1]) == "b")
        var next = plan
        next.title = "Second pass"
        let again = ChatReviewPlan.latest(inStoredReplies: replies + [ChatReviewPlan.storing("c", with: next)])
        #expect(again.plan == next)
        #expect(again.earlierTitles == ["Episode on mitochondria"])
    }

    @Test("A number the model put in front of a topic is left off")
    func topicNumbers() throws {
        #expect(ChatReviewPlan.withoutLeadingNumber("1. What mitochondria do") == "What mitochondria do")
        #expect(ChatReviewPlan.withoutLeadingNumber("12) Supplements") == "Supplements")
        #expect(ChatReviewPlan.withoutLeadingNumber("5-HT signalling") == "5-HT signalling")
        #expect(ChatReviewPlan.withoutLeadingNumber("2024 trials") == "2024 trials")
        let plan = try ChatReviewPlan.fromToolArguments([
            "title": "T",
            "topics": [["title": "3. Metformin", "status": "todo", "points": []]],
        ])
        #expect(plan.topics[0].title == "Metformin")
        let stored = ChatReviewPlan.Topic(title: "2. Is dysfunction inevitable?", status: .todo)
        #expect(stored.displayTitle == "Is dysfunction inevitable?")
    }

    @Test("A topic's progress counts partial points as half")
    func progress() {
        let topic = Self.samplePlan().topics[0]
        #expect(abs(topic.progress - 0.5) < 0.0001)
        #expect(ChatReviewPlan.Topic(title: "x", status: .done).progress == 1)
        #expect(Self.samplePlan().totalPoints == 4)
        #expect(Self.samplePlan().donePoints == 2)
    }

    @Test("A point keeps its answer and picture, and a stored line without them still reads")
    func answersRoundTrip() throws {
        var plan = Self.samplePlan()
        plan.topics[0].points[0].answer = "ATP is only one output; the same machinery makes building blocks and signals."
        plan.topics[0].points[0].image = "foreverlm://image/generated/img_1"
        let parsed = try #require(ChatReviewPlan.parse(line: plan.markdownLine))
        #expect(parsed == plan)
        #expect(parsed.topics[0].points[0].hasAnswer)
        #expect(!parsed.topics[0].points[1].hasAnswer)
        // A line written before points had answers is the same bytes it was.
        #expect(!Self.samplePlan().markdownLine.contains("answer"))
        let context = plan.turnContext
        #expect(context.contains("     answer: ATP is only one output"))
        #expect(context.contains("     picture: foreverlm://image/generated/img_1"))
    }

    @Test("The tool takes an answer and a picture address, bare or as a Markdown line")
    func answersFromTool() throws {
        let plan = try ChatReviewPlan.fromToolArguments([
            "title": "T",
            "topics": [["title": "A", "status": "active", "points": [
                ["text": "p1", "status": "done", "answer": "  Settled.  ", "image": "![Figure 2](foreverlm://image/source/src_1?page=3)"],
                ["text": "p2", "status": "partial", "answer": "  ", "image": "https://example.org/x.png"],
            ]]],
        ])
        #expect(plan.topics[0].points[0].answer == "Settled.")
        #expect(plan.topics[0].points[0].image == "foreverlm://image/source/src_1?page=3")
        #expect(plan.topics[0].points[1].answer == nil)
        #expect(plan.topics[0].points[1].image == nil, "only the app's own picture addresses are kept")
        let long = String(repeating: "a", count: ChatReviewPlan.maxAnswerLength + 1)
        #expect((try? ChatReviewPlan.fromToolArguments([
            "title": "T",
            "topics": [["title": "A", "status": "active", "points": [["text": "p", "status": "done", "answer": long]]]],
        ])) == nil)
    }

    @Test("A rewrite that leaves an answer off keeps the one the point had")
    func answersKeptAcrossRewrites() {
        var before = Self.samplePlan()
        before.topics[0].points[0].answer = "First answer."
        before.topics[0].points[0].image = "foreverlm://image/generated/img_1"
        before.topics[1].points[0].answer = "Threshold answer."
        var after = Self.samplePlan()
        after.topics[0].points[1].status = .done
        after.topics[0].points[1].answer = "New answer."
        after.topics[1].title = "Spare capacity"
        let kept = after.keepingAnswers(from: before)
        #expect(kept.topics[0].points[0].answer == "First answer.")
        #expect(kept.topics[0].points[0].image == "foreverlm://image/generated/img_1")
        #expect(kept.topics[0].points[1].answer == "New answer.")
        #expect(kept.topics[1].points[0].answer == "Threshold answer.", "a renamed topic still finds its point by text")
        #expect(kept.topics[0].points[2].answer == nil)
        var replaced = after
        replaced.topics[0].points[0].answer = "Rewritten."
        #expect(replaced.keepingAnswers(from: before).topics[0].points[0].answer == "Rewritten.")
        #expect(after.keepingAnswers(from: nil) == after)
    }
}
