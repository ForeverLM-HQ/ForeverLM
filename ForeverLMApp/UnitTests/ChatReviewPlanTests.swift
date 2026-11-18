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
}
