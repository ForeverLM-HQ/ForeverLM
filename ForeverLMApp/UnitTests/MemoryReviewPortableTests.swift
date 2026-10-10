import Foundation
import Testing
@testable import ForeverLM

/// The memory review's portable core: what every client compiles so the
/// review reads the same on the Mac, the phone, and in voice.
@Suite("Memory review portable core")
struct MemoryReviewPortableTests {

    private func candidate(_ id: String, consumedDaysAgo: Int, reviewCount: Int = 0, lastDiscussedDaysAgo: Int? = nil, now: Date) -> CohortCandidate {
        CohortCandidate(
            sourceID: id,
            title: id.capitalized,
            sourceType: "article",
            consumedAt: now.addingTimeInterval(-Double(consumedDaysAgo) * 86_400),
            confidence: .complete,
            reviewCount: reviewCount,
            lastDiscussedAt: lastDiscussedDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) }
        )
    }

    @Test("A source-turn line splits a reply into prose, heading, prose")
    func sourceTurnSplitsReply() {
        let reply = """
        Exactly: editing repairs mtDNA in place, transfer supplies a whole organelle.

        <flm_source_turn id="source-b"/>
        In one to three sentences, what was *What Is Life?* about?
        """
        #expect(MemoryReviewSourceTurn.split(reply) == [
            .text("Exactly: editing repairs mtDNA in place, transfer supplies a whole organelle."),
            .turn(sourceID: "source-b"),
            .text("In one to three sentences, what was *What Is Life?* about?"),
        ])
        #expect(MemoryReviewSourceTurn.sourceIDs(in: reply) == ["source-b"])
        #expect(MemoryReviewSourceTurn.stripped(reply) == """
        Exactly: editing repairs mtDNA in place, transfer supplies a whole organelle.

        In one to three sentences, what was *What Is Life?* about?
        """)
    }

    @Test("The opening turn line, quote style, and closing tags are all tolerated")
    func sourceTurnVariants() {
        #expect(MemoryReviewSourceTurn.split("<flm_source_turn id='a'/>\nWhat was it about?") == [
            .turn(sourceID: "a"), .text("What was it about?"),
        ])
        #expect(MemoryReviewSourceTurn.split("<flm_source_turn id=\"a\"></flm_source_turn>Q") == [
            .turn(sourceID: "a"), .text("Q"),
        ])
        #expect(MemoryReviewSourceTurn.split("<flm_source_turn id=a>Q") == [.turn(sourceID: "a"), .text("Q")])
        // No id: debris, not a heading.
        #expect(MemoryReviewSourceTurn.split("Before <flm_source_turn/> after") == [.text("Before  after")])
        #expect(MemoryReviewSourceTurn.split("Plain reply.") == [.text("Plain reply.")])
        #expect(MemoryReviewSourceTurn.split("   ") == [])
        #expect(MemoryReviewSourceTurn.line(sourceID: "x") == "<flm_source_turn id=\"x\"/>")
    }

    @Test("A tag still arriving is cut from the streamed text and never typed out")
    func partialSourceTurnIsHidden() {
        #expect(MemoryReviewSourceTurn.strippingTrailingPartialTag("Good. <flm_sou") == "Good. ")
        #expect(MemoryReviewSourceTurn.strippingTrailingPartialTag("Good. <flm_source_turn id=\"a") == "Good. ")
        #expect(MemoryReviewSourceTurn.strippingTrailingPartialTag("Good. <flm_source_turn id=\"a\"/>") == "Good. <flm_source_turn id=\"a\"/>")
        #expect(MemoryReviewSourceTurn.strippingTrailingPartialTag("x < y") == "x < y")
        #expect(MemoryReviewSourceTurn.strippingTrailingPartialTag("<b>bold</b>") == "<b>bold</b>")
    }

    @Test("The tutor is told to write the turn line, and reminded after every grade")
    func tutorIsToldAboutTheTurnLine() {
        #expect(MemoryReviewTutoring.conductInstructions.contains("<flm_source_turn id=\"SOURCE_ID\"/>"))
        let grade = MemoryContourGrade(
            sourceID: "s",
            coverage: [MemoryIdeaCoverage(ideaID: "s::1", status: .produced)],
            score: 1,
            verdict: .sound,
            operation: .recall,
            evaluation: nil
        )
        #expect(MemoryReviewTutoring.gradeAcknowledgement(grade: grade, depth: .quick).contains("flm_source_turn"))
    }

    @Test("The tutor asks before leaving a source, at every depth, and the chips gate on the current source's grade")
    func tutorAsksBeforeLeavingASource() {
        let conduct = MemoryReviewTutoring.conductInstructions
        #expect(conduct.contains("You never leave a source on your own."))
        #expect(conduct.contains("whether they want to move on or stay on this one"))
        #expect(conduct.contains("Next is the only thing that takes you to the next source"))
        #expect(!conduct.contains("quick moves on to the next source's contour"))
        for depth in MemoryReviewDepth.allCases {
            #expect(depth.tutorInstruction.contains("ask whether to move on"), "\(depth)")
            #expect(depth.tutorInstruction.hasSuffix("and wait"), "\(depth)")
        }
        let grade = MemoryContourGrade(
            sourceID: "s",
            coverage: [MemoryIdeaCoverage(ideaID: "s::1", status: .produced)],
            score: 1, verdict: .sound, operation: .recall, evaluation: nil
        )
        let acknowledgement = MemoryReviewTutoring.gradeAcknowledgement(grade: grade, depth: .quick)
        #expect(acknowledgement.contains("Do not turn to another source until they say Next"))

        // The screenshot case (2026-09-21): source A graded and probed, then
        // the reply that answered the last probe turned to source B unasked.
        // The chips belong to a graded current source, so they show through
        // A's probes and vanish the moment B's contour is open and ungraded.
        let coverageA = MemoryIdeaCoverage.encode([MemoryIdeaCoverage(ideaID: "A::idea::1", status: .produced)])
        let opener = "Today.\n\n<flm_source_turn id=\"A\"/>\nWhat was A about?"
        let gradedReply = "Good. Now, why does the pump matter?"
        let probeReply = "Exactly. One more: what would PAB below baseline mean?"
        let closingOffer = "Not quite; PAB would lower demand. That is A. Move on, or stay here a little longer?"
        let turnToB = "Not quite.\n\n<flm_source_turn id=\"B\"/>\nWhat was B about?"
        typealias X = MemoryReviewSourceStatus.SourceTurnExchange
        let contour = X(sequenceNumber: 1, question: opener, ideaCoverage: coverageA, evaluation: gradedReply)
        let probe = X(sequenceNumber: 2, question: gradedReply, ideaCoverage: nil, evaluation: probeReply)
        let offer = X(sequenceNumber: 3, question: probeReply, ideaCoverage: nil, evaluation: closingOffer)
        let unasked = X(sequenceNumber: 3, question: probeReply, ideaCoverage: nil, evaluation: turnToB)

        func offers(_ exchanges: [X]) -> Bool {
            let statuses = MemoryReviewSourceStatus.statuses(from: exchanges.map {
                .init(sequenceNumber: $0.sequenceNumber, ideaCoverage: $0.ideaCoverage, questionVerdict: nil, answeredAt: nil)
            })
            return MemoryReviewSourceStatus.offersSteer(
                currentSourceID: MemoryReviewSourceStatus.currentSourceID(from: exchanges),
                statuses: statuses
            )
        }
        #expect(!offers([X(sequenceNumber: 1, question: opener, ideaCoverage: nil, evaluation: nil)]))
        #expect(offers([contour]))
        #expect(offers([contour, probe]))
        #expect(offers([contour, probe, offer]))
        #expect(MemoryReviewSourceStatus.currentSourceID(from: [contour, probe, unasked]) == "B")
        #expect(!offers([contour, probe, unasked]))
        #expect(!MemoryReviewSourceStatus.offersSteer(currentSourceID: nil, statuses: [:]))
    }

    @Test("Spine and spacing roles come from the selection, with the reasons the tutor reads")
    func rolesFromSelection() {
        let now = Date()
        let selection = CohortSelector.select(
            candidates: [
                candidate("fresh", consumedDaysAgo: 1, now: now),
                candidate("stale", consumedDaysAgo: 40, reviewCount: 1, lastDiscussedDaysAgo: 30, now: now),
            ],
            now: now
        )
        let (sources, claimed) = MemoryReviewPlanning.sources(from: selection, now: now)
        #expect(sources.map(\.sourceID) == ["fresh", "stale"])
        #expect(sources.map(\.role) == [.spine, .spacing])
        #expect(claimed == ["fresh", "stale"])
        #expect(sources[0].reason.contains("not reviewed yet"))
        #expect(sources[1].reason.contains("due at"))
    }

    @Test("A day with nothing due offers the longest-untouched material and says so")
    func backlogCohort() {
        let now = Date()
        let cohort = MemoryReviewPlanning.backlogCohort(
            candidates: [
                candidate("recent", consumedDaysAgo: 2, reviewCount: 1, lastDiscussedDaysAgo: 1, now: now),
                candidate("old", consumedDaysAgo: 90, reviewCount: 1, lastDiscussedDaysAgo: 5, now: now),
            ],
            unfinished: [],
            now: now
        )
        #expect(cohort.isBacklogOnly)
        #expect(cohort.sources.first?.sourceID == "old")
        #expect(cohort.sources.first?.reason.hasPrefix("Nothing is due today.") == true)
    }

    @Test("The briefing carries the conduct, the plan in order, and every source's ideas with their ids")
    func briefingShape() {
        let now = Date()
        let source = CohortSource(
            sourceID: "src-a", title: "Axolotls", sourceType: "article", role: .spine,
            consumedAt: now, lastDiscussedAt: nil, reviewCount: 0, confidence: .complete,
            bridgeTo: nil, reason: "Taken in today, not reviewed yet."
        )
        let idea = SourceIdea(
            id: SourceIdea.id(sourceID: "src-a", contentHash: "h", index: 0),
            sourceID: "src-a", statement: "Axolotls regenerate limbs without scarring.",
            recallNote: "regeneration; no scar", anchors: [], wanted: true,
            contentHash: "h", sortIndex: 0, createdAt: now, updatedAt: now
        )
        let cohort = LearningCohort(assembledAt: now, windowDays: 10, sources: [source], unfinished: [], droppedSpine: 0, droppedSpacing: 0)
        let brief = CohortSourceBrief(
            source: source, guide: nil, highlights: ["a highlight"], understanding: nil,
            understandingHasLearnerEdits: false, exemplarQuestions: [], ideas: [idea], depth: .quick
        )
        let plan = CohortSessionPlan(opening: "Today starts with axolotls.", moves: [
            CohortMove(kind: .recall, sourceIDs: ["src-a"], intent: "What the piece was about."),
        ])
        let briefing = MemoryReviewTutoring.briefing(cohort: cohort, briefs: [brief], plan: plan, startedAt: now, budgetMinutes: 30)
        #expect(briefing.hasPrefix("TODAY'S MEMORY REVIEW"))
        #expect(briefing.contains(MemoryReviewTutoring.conductInstructions))
        #expect(briefing.contains("PLANNER'S OPENING LINE: Today starts with axolotls."))
        #expect(briefing.contains("1. recall [src-a] — What the piece was about."))
        #expect(briefing.contains("- [\(idea.id)] Axolotls regenerate limbs without scarring. (THEY HIGHLIGHTED THIS)"))
        #expect(briefing.contains("quick: the contour only"))
        // The learner's own daily budget, not a constant.
        #expect(briefing.contains("TIME BUDGET: about 30 minutes"))
        let defaulted = MemoryReviewTutoring.briefing(cohort: cohort, briefs: [brief], plan: plan, startedAt: now)
        #expect(defaulted.contains("TIME BUDGET: about \(MemoryReviewBudget.label(MemoryReviewBudget.defaultMinutes))"))
    }

    @Test("A briefing gives back the ids of the sources it lists, chats included, and nothing else")
    func briefingSourceIDs() {
        let now = Date()
        let article = CohortSource(
            sourceID: "src-a", title: "Axolotls", sourceType: "article", role: .spine,
            consumedAt: now, lastDiscussedAt: nil, reviewCount: 0, confidence: .complete,
            bridgeTo: nil, reason: "Taken in today, not reviewed yet."
        )
        let chat = CohortSource(
            sourceID: "chat-1", title: "Mitochondrial methods", sourceType: ReviewableChat.sourceType, role: .spine,
            consumedAt: now, lastDiscussedAt: nil, reviewCount: 0, confidence: .complete,
            bridgeTo: nil, reason: "A conversation they had yesterday."
        )
        let idea = SourceIdea(
            id: SourceIdea.id(sourceID: "chat-1", contentHash: "h", index: 0),
            sourceID: "chat-1", statement: "TMRM reports membrane potential.",
            recallNote: "cationic dye", anchors: [], wanted: false,
            contentHash: "h", sortIndex: 0, createdAt: now, updatedAt: now
        )
        let cohort = LearningCohort(assembledAt: now, windowDays: 10, sources: [chat, article], unfinished: [], droppedSpine: 0, droppedSpacing: 0)
        let briefs = [
            CohortSourceBrief(source: chat, guide: "### [not-a-source] a heading quoted from the chat", highlights: [], understanding: nil,
                              understandingHasLearnerEdits: false, exemplarQuestions: [], ideas: [idea], depth: .standard),
            CohortSourceBrief(source: article, guide: nil, highlights: [], understanding: nil,
                              understandingHasLearnerEdits: false, exemplarQuestions: [], ideas: [], depth: .quick),
        ]
        let plan = CohortSessionPlan(opening: "Start with the conversation.", moves: [
            CohortMove(kind: .recall, sourceIDs: ["chat-1"], intent: "What they worked out."),
            CohortMove(kind: .contrast, sourceIDs: ["chat-1", "src-a"], intent: "Sharpen the distinctions."),
        ])
        let briefing = MemoryReviewTutoring.briefing(cohort: cohort, briefs: briefs, plan: plan, startedAt: now)

        // Headers only: the moves' [id] lists and the ideas' [id] lines are not
        // sources, and a guide that happens to quote a header is inside a line.
        #expect(MemoryReviewTutoring.sourceIDs(inBriefing: briefing) == ["chat-1", "src-a"])
        #expect(MemoryReviewTutoring.sourceIDs(inBriefing: "") == [])
        #expect(MemoryReviewTutoring.sourceIDs(inBriefing: "### [dup] A\n### [dup] A again\n### [] blank") == ["dup"])
    }

    @Test("Removing a source from a briefing drops its section and records the removal for the tutor and for a resume")
    func briefingRemovalDropsSectionAndRecordsIt() {
        let briefing = [
            "TODAY'S MEMORY REVIEW",
            "",
            "MOVES, in order:",
            "1. explain [src-a] [src-b] — Put them in friction.",
            "",
            "SOURCES",
            "",
            "### [src-a] Sarcolemmal potentials — measured in vivo — spine",
            "Type: paper. Taken in 1d ago.",
            "IDEAS (grade the contour against these; use the ids exactly):",
            "- [src-a::idea::1] First idea.",
            "",
            "### [src-b] Atlas — spine (drawn against src-a)",
            "Type: paper.",
            "",
        ].joined(separator: "\n")

        let once = MemoryReviewTutoring.briefing(briefing, removingSource: "src-a")
        // The section is gone, ideas included; the neighbour and the plan stay.
        #expect(!once.contains("### [src-a]"))
        #expect(!once.contains("src-a::idea::1"))
        #expect(once.contains("### [src-b] Atlas — spine (drawn against src-a)"))
        #expect(once.contains("1. explain [src-a] [src-b]"))
        // The title is read off the header, up to the role dash, keeping its own dash.
        #expect(once.contains(MemoryReviewTutoring.removedSourcesHeading))
        #expect(once.hasSuffix("REMOVED [src-a] Sarcolemmal potentials — measured in vivo\n"))
        #expect(MemoryReviewTutoring.removedSourceIDs(inBriefing: once) == ["src-a"])
        #expect(MemoryReviewTutoring.sourceIDs(inBriefing: once) == ["src-b"])

        // A second removal joins the same list under one heading, with the title given.
        let twice = MemoryReviewTutoring.briefing(once, removingSource: "src-b", title: "Atlas of Lysosomal Aging")
        #expect(twice.components(separatedBy: MemoryReviewTutoring.removedSourcesHeading).count == 2)
        #expect(MemoryReviewTutoring.removedSourceIDs(inBriefing: twice) == ["src-a", "src-b"])
        #expect(twice.contains("REMOVED [src-b] Atlas of Lysosomal Aging"))
        #expect(MemoryReviewTutoring.sourceIDs(inBriefing: twice) == [])
        #expect(twice.contains("1. explain [src-a] [src-b]"))

        // Removing again, or removing what was never listed, records once and never twice.
        #expect(MemoryReviewTutoring.briefing(twice, removingSource: "src-b") == twice)
        let stranger = MemoryReviewTutoring.briefing(twice, removingSource: "src-c")
        #expect(MemoryReviewTutoring.removedSourceIDs(inBriefing: stranger) == ["src-a", "src-b", "src-c"])
        #expect(stranger.contains("REMOVED [src-c] src-c"))
        #expect(MemoryReviewTutoring.briefing(stranger, removingSource: "  ") == stranger)
        #expect(MemoryReviewTutoring.removedSourceIDs(inBriefing: "") == [])
    }

    @Test("Before any turn line or grade, the open question is about the first move still in play")
    func openingMoveNamesTheSourceUnderDiscussion() {
        let briefing = [
            "TODAY'S MEMORY REVIEW",
            "",
            "PLANNER'S OPENING LINE: Start with the conversation.",
            "",
            MemoryReviewTutoring.movesHeading,
            "1. recall [chat-1] — What they worked out — and why [it] mattered.",
            "2. contrast [src-a] [src-b] — Sharpen the distinctions.",
            "",
            "SOURCES",
            "",
            "### [chat-1] Lysosomal aging talk — spine",
            "### [src-a] Atlas — spine",
            "### [src-b] Flux — spine",
            "",
        ].joined(separator: "\n")
        // The intent's own brackets are not ids.
        #expect(MemoryReviewTutoring.openingMoveSourceIDs(inBriefing: briefing) == ["chat-1"])

        // Removing the opening source moves the opening to the next move that
        // still names something; removing one of a pair leaves the other.
        let withoutChat = MemoryReviewTutoring.briefing(briefing, removingSource: "chat-1")
        #expect(MemoryReviewTutoring.openingMoveSourceIDs(inBriefing: withoutChat) == ["src-a", "src-b"])
        let withoutAtlas = MemoryReviewTutoring.briefing(withoutChat, removingSource: "src-a")
        #expect(MemoryReviewTutoring.openingMoveSourceIDs(inBriefing: withoutAtlas) == ["src-b"])
        let nothingLeft = MemoryReviewTutoring.briefing(withoutAtlas, removingSource: "src-b")
        #expect(MemoryReviewTutoring.openingMoveSourceIDs(inBriefing: nothingLeft) == [])

        // A briefing with no move list, or none at all, names nothing.
        #expect(MemoryReviewTutoring.openingMoveSourceIDs(inBriefing: "SOURCES\n\n### [src-a] Atlas") == [])
        #expect(MemoryReviewTutoring.openingMoveSourceIDs(inBriefing: "") == [])
    }

    @Test("The strip takes the day's sources in the order the plan's moves name them, and names chats from the briefing")
    func stripFollowsThePlanAndNamesChats() {
        let briefing = [
            MemoryReviewTutoring.movesHeading,
            "1. recall [chat-1] — What they worked out.",
            "2. connect [src-b] [src-a] — Reconcile [the two].",
            "3. explain [src-b] — Again, and [src-z] is not material.",
            "",
            "SOURCES",
            "",
            "### [src-a] Chapter 2: Cell Chemistry — spine",
            "### Reaction free energy",
            "### [src-b] Flux — a model — spine",
            "### [chat-1] Walkthrough for the inflammasome paper — spine",
            "### [src-c] Unplanned — spacing",
            "",
        ].joined(separator: "\n")
        // Selector order is src-a, src-b, chat-1, src-c; the plan opens on the
        // chat, and a source no move names keeps its place after the rest.
        #expect(MemoryReviewTutoring.planOrdered(["src-a", "src-b", "chat-1", "src-c"], inBriefing: briefing)
            == ["chat-1", "src-b", "src-a", "src-c"])
        #expect(MemoryReviewTutoring.planOrdered(["src-a", "src-c"], inBriefing: nil) == ["src-a", "src-c"])

        let titles = MemoryReviewTutoring.sourceTitles(inBriefing: briefing)
        #expect(titles["chat-1"] == "Walkthrough for the inflammasome paper")
        // Only the last " — " separates the role; a title may carry its own.
        #expect(titles["src-b"] == "Flux — a model")
        #expect(titles.count == 4)
    }

    @Test("The portable SHA-256 is CryptoKit's, so web-minted idea ids match the Mac's")
    func portableDigestMatchesCryptoKit() {
        // FIPS 180-4 vectors: the empty message, "abc", and a two-block message.
        #expect(PortableSHA256.hexDigest(of: []) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(PortableSHA256.hexDigest(of: Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(PortableSHA256.hexDigest(of: Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // And against the real thing, over text long enough to cross a block.
        let text = String(repeating: "Axolotls regenerate limbs without scarring. ", count: 40)
        #expect(PortableSHA256.hexDigest(of: Array(text.utf8)) == SourceIdeaDrafting.contentHash(text))
    }

    @Test("The grader tool names every field the validator reads")
    func gradeToolShape() {
        let tool = MemoryReviewTutoring.gradeMemoryContourTool
        #expect(tool.name == "grade_memory_contour")
        let properties = tool.parameters.properties ?? [:]
        #expect(Set(properties.keys) == ["source_id", "idea_coverage", "score", "question_verdict", "operation", "evaluation"])
        #expect(tool.parameters.required == ["source_id", "idea_coverage", "score"])
        #expect(properties["idea_coverage"]?.items?.properties?["status"]?.allowedValues == ["produced", "partial", "missing"])
        // A contour is a recall: an understanding probe's kind is the topic
        // grader's alone, and only once an idea came back.
        #expect(properties["operation"]?.allowedValues == MemoryQuestionOperation.recallCases.map(\.rawValue))
        #expect(MemoryReviewTutoring.gradeTopicRecallTool.parameters.properties?["operation"]?.allowedValues
            == MemoryQuestionOperation.allCases.map(\.rawValue))
        // The Mac wraps the same definition into its native tool spec.
        let spec = AIToolSpec(portable: tool)
        #expect(spec.name == "grade_memory_contour")
        #expect((spec.inputSchema["required"] as? [String]) == ["source_id", "idea_coverage", "score"])
    }

    @Test("The grade acknowledgement says what came back and carries the source's depth")
    func gradeAcknowledgement() {
        let grade = MemoryContourGrade(
            sourceID: "src-a",
            coverage: [
                MemoryIdeaCoverage(ideaID: "a", status: .produced),
                MemoryIdeaCoverage(ideaID: "b", status: .missing),
            ],
            score: 0.5, verdict: .ambiguous, operation: .recall, evaluation: nil
        )
        let text = MemoryReviewTutoring.gradeAcknowledgement(grade: grade, depth: .deep)
        #expect(text.hasPrefix("Recorded: 1 of 2 ideas produced, score 0.50."))
        #expect(text.contains("judged ambiguous"))
        #expect(text.contains("deep: the contour, then the planner's full move list"))
        #expect(MemoryReviewTutoring.steerMessage(.next) == "Next.")
        #expect(MemoryReviewTutoring.steerMessage(.deeper) == "Go deeper.")
    }

    @Test("The system prompt is the review tutor with the briefing as the daily focus")
    func systemPrompt() {
        let prompt = MemoryReviewTutoring.systemPrompt(briefing: "THE BRIEFING", localClockDescription: "Friday, 2026-09-04, 09:00 (Europe/Amsterdam)")
        #expect(prompt.hasPrefix(Prompts.reviewTutor))
        #expect(prompt.contains("Daily review focus for this session:\nTHE BRIEFING"))
        #expect(prompt.hasSuffix("Local date and time: Friday, 2026-09-04, 09:00 (Europe/Amsterdam)"))
    }

    @Test("Malformed planner output is refused whole rather than patched")
    func decodeRefusesMalformed() throws {
        let plan: CohortSessionPlan = try MemoryReviewPlanning.decodeJSON(
            "Sure! {\"opening\": \"Hi\", \"moves\": [{\"kind\": \"recall\", \"source_ids\": [\"s\"], \"intent\": \"x\"}]} done"
        )
        #expect(plan.moves.count == 1)
        #expect(throws: MemoryReviewPlanning.DecodingFailure.invalidResponse) {
            let _: CohortSessionPlan = try MemoryReviewPlanning.decodeJSON("{\"opening\": \"Hi\", \"moves\": [{\"kind\": \"dance\"}]}")
        }
    }

    @Test("Ideas drafted on the phone get the ids the Mac would give the same text")
    func draftingIdentity() {
        let hash = SourceIdeaDrafting.contentHash("some text")
        #expect(hash == PaperContentPreparationService.sha256("some text"))
        let ideas = SourceIdeaDrafting.ideas(
            from: [
                SourceIdeaDraft(statement: "One idea.", recallNote: "a", anchors: []),
                SourceIdeaDraft(statement: " one idea. ", recallNote: "dup", anchors: []),
                SourceIdeaDraft(statement: "Two idea.", recallNote: "b", anchors: []),
            ],
            sourceID: "src", contentHash: hash, highlights: []
        )
        #expect(ideas.map(\.statement) == ["One idea.", "Two idea."])
        #expect(ideas.map(\.id) == [
            SourceIdea.id(sourceID: "src", contentHash: hash, index: 0),
            SourceIdea.id(sourceID: "src", contentHash: hash, index: 1),
        ])
    }

    // MARK: - A chat is not the whole source

    private func chatOnlyFixture(
        depth: Double,
        discussedAt: Date?,
        confidence: SourceConsumptionConfidence = .substantial,
        now: Date = Date()
    ) -> (source: CohortSource, ideas: [SourceIdea]) {
        let source = CohortSource(
            sourceID: "src-tca", title: "A non-canonical TCA cycle", sourceType: "paper", role: .spine,
            consumedAt: now, lastDiscussedAt: discussedAt, reviewCount: 0, confidence: confidence,
            bridgeTo: nil, reason: "Taken in within the last day, not reviewed yet.",
            engagement: CohortEngagement(
                engagedSeconds: 40, depth: depth, chatDiscussedAt: discussedAt, annotationCount: 0
            )
        )
        let ideas = (0..<3).map { index in
            SourceIdea(
                id: SourceIdea.id(sourceID: "src-tca", contentHash: "h", index: index),
                sourceID: "src-tca", statement: "Idea \(index).", recallNote: "note \(index)",
                anchors: [], wanted: false, contentHash: "h", sortIndex: index,
                createdAt: now, updatedAt: now
            )
        }
        return (source, ideas)
    }

    @Test("A source in the review only because it was chatted about is asked about only what the chat engaged")
    func chatOnlySourceIsNarrowedToWhatWasDiscussed() {
        let now = Date()
        let fixture = chatOnlyFixture(depth: 0, discussedAt: now, now: now)
        let split = CohortSourceBrief.gradableIdeas(
            fixture.ideas,
            discussedIdeaIDs: [fixture.ideas[1].id],
            engagement: fixture.source.engagement,
            confidence: fixture.source.confidence
        )
        #expect(split.gradable.map(\.id) == [fixture.ideas[1].id])
        #expect(split.context.map(\.id) == [fixture.ideas[0].id, fixture.ideas[2].id])
    }

    @Test("Reading the source keeps every idea in play, however much was also said about it in a chat")
    func readSourceIsNotNarrowedByItsChat() {
        let now = Date()
        // Past `substantialFraction`: the learner went through the text itself,
        // so the whole text is fair game whatever the conversation covered.
        let fixture = chatOnlyFixture(depth: 0.79, discussedAt: now, now: now)
        let split = CohortSourceBrief.gradableIdeas(
            fixture.ideas,
            discussedIdeaIDs: [fixture.ideas[1].id],
            engagement: fixture.source.engagement,
            confidence: fixture.source.confidence
        )
        #expect(split.gradable.count == 3)
        #expect(split.context.isEmpty)
    }

    @Test("A finished source is never narrowed, and a source with nothing recorded keeps all its ideas")
    func narrowingFallsBackToEveryIdea() {
        let now = Date()
        let finished = chatOnlyFixture(depth: 0, discussedAt: now, confidence: .complete, now: now)
        #expect(CohortSourceBrief.gradableIdeas(
            finished.ideas, discussedIdeaIDs: [], engagement: finished.source.engagement,
            confidence: finished.source.confidence
        ).gradable.count == 3)

        // A document written before schema 129 records nothing. "Nothing known"
        // must not read as "nothing to ask".
        let unrecorded = chatOnlyFixture(depth: 0, discussedAt: now, now: now)
        let split = CohortSourceBrief.gradableIdeas(
            unrecorded.ideas, discussedIdeaIDs: [], engagement: unrecorded.source.engagement,
            confidence: unrecorded.source.confidence
        )
        #expect(split.gradable.count == 3)
        #expect(split.context.isEmpty)

        // A source never discussed at all is not chat-only however shallow.
        let unread = chatOnlyFixture(depth: 0.1, discussedAt: nil, now: now)
        #expect(CohortSourceBrief.gradableIdeas(
            unread.ideas, discussedIdeaIDs: [unread.ideas[0].id],
            engagement: unread.source.engagement, confidence: unread.source.confidence
        ).gradable.count == 3)
    }

    @Test("The briefing says how far they got, lists the ideas it will grade, and marks the rest as not yet met")
    func briefingSeparatesGradableIdeasFromContext() {
        let now = Date()
        let fixture = chatOnlyFixture(depth: 0.41, discussedAt: now, now: now)
        let split = CohortSourceBrief.gradableIdeas(
            fixture.ideas, discussedIdeaIDs: [fixture.ideas[0].id],
            engagement: fixture.source.engagement, confidence: fixture.source.confidence
        )
        let brief = CohortSourceBrief(
            source: fixture.source, guide: nil, highlights: [], understanding: nil,
            understandingHasLearnerEdits: false, exemplarQuestions: [],
            ideas: split.gradable, contextIdeas: split.context, depth: .standard
        )
        let cohort = LearningCohort(
            assembledAt: now, windowDays: 10, sources: [fixture.source],
            unfinished: [], droppedSpine: 0, droppedSpacing: 0
        )
        let plan = CohortSessionPlan(opening: "Start there.", moves: [
            CohortMove(kind: .recall, sourceIDs: ["src-tca"], intent: "What they took from the conversation."),
        ])
        let briefing = MemoryReviewTutoring.briefing(cohort: cohort, briefs: [brief], plan: plan, startedAt: now)

        #expect(briefing.contains("GOT 41% OF THE WAY IN — ask only about the part they reached."))
        #expect(briefing.contains("- [\(fixture.ideas[0].id)] Idea 0."))
        #expect(briefing.contains(MemoryReviewTutoring.contextIdeasHeading))
        // The ideas it will not ask about are listed by statement and never by
        // id, so a model reaching for one cannot name it in a grade.
        #expect(briefing.contains("- Idea 1."))
        #expect(!briefing.contains(fixture.ideas[1].id))
        #expect(!briefing.contains(fixture.ideas[2].id))
    }

    @Test("A resume reads back exactly the ideas the briefing put in play")
    func resumeReadsGradableIdeasOffTheBriefing() {
        let now = Date()
        let fixture = chatOnlyFixture(depth: 0, discussedAt: now, now: now)
        let brief = CohortSourceBrief(
            source: fixture.source, guide: nil, highlights: [], understanding: nil,
            understandingHasLearnerEdits: false, exemplarQuestions: [],
            ideas: [fixture.ideas[1]], contextIdeas: [fixture.ideas[0], fixture.ideas[2]], depth: .standard
        )
        let cohort = LearningCohort(
            assembledAt: now, windowDays: 10, sources: [fixture.source],
            unfinished: [], droppedSpine: 0, droppedSpacing: 0
        )
        let plan = CohortSessionPlan(opening: "Start there.", moves: [
            CohortMove(kind: .recall, sourceIDs: ["src-tca"], intent: "What was said."),
        ])
        let briefing = MemoryReviewTutoring.briefing(cohort: cohort, briefs: [brief], plan: plan, startedAt: now)

        #expect(MemoryReviewTutoring.gradableIdeaIDs(inBriefing: briefing) == [fixture.ideas[1].id])
        // The store still holds all three; the review grades one.
        let narrowed = ReviewSessionManager.gradableIdeas(["src-tca": fixture.ideas], briefing: briefing)
        #expect(narrowed["src-tca"]?.map(\.id) == [fixture.ideas[1].id])
        // A briefing from before the split listed every idea, so every idea
        // stays gradable; no briefing at all changes nothing.
        #expect(ReviewSessionManager.gradableIdeas(["src-tca": fixture.ideas], briefing: nil)["src-tca"]?.count == 3)
        #expect(ReviewSessionManager.gradableIdeas(["src-tca": fixture.ideas], briefing: "no ideas here")["src-tca"]?.count == 3)
    }

    @Test("The closer's discussed ids are held to the ideas the source really has, and merge with what earlier chats reached")
    func discussedIdeaIDsAreValidatedAndMerged() {
        let now = Date()
        let fixture = chatOnlyFixture(depth: 0, discussedAt: now, now: now)
        let result = CohortCloseResult(
            sessionSummary: "A short conversation.",
            sources: [
                CohortCloseResult.SourceUpdate(
                    sourceID: "src-tca", understandingMarkdown: "They asked one thing.",
                    openThreadCount: 1,
                    discussedIdeaIDs: [fixture.ideas[2].id, "invented-id", fixture.ideas[2].id]
                ),
                CohortCloseResult.SourceUpdate(
                    sourceID: "src-elsewhere", understandingMarkdown: "Never touched.", openThreadCount: 0
                ),
            ]
        )
        let validated = result.validated(
            against: ["src-tca"],
            ideaIDsBySource: ["src-tca": Set(fixture.ideas.map(\.id))]
        )
        #expect(validated.sources.count == 1)
        #expect(validated.sources[0].discussedIdeaIDs == [fixture.ideas[2].id])

        // An earlier chat reached idea 0; this one reached idea 2. Both are met,
        // and the merged set keeps the source's own order.
        let brief = CohortSourceBrief(
            source: fixture.source, guide: nil, highlights: [], understanding: nil,
            understandingHasLearnerEdits: false, exemplarQuestions: [],
            ideas: fixture.ideas, discussedIdeaIDs: [fixture.ideas[0].id]
        )
        #expect(DayClosePass.mergedDiscussedIdeaIDs(
            known: brief, adding: validated.sources[0].discussedIdeaIDs
        ) == [fixture.ideas[0].id, fixture.ideas[2].id])
        // A source whose ideas were never listed to the closer keeps what it had.
        #expect(DayClosePass.mergedDiscussedIdeaIDs(known: nil, adding: ["x"]) == nil)
    }
}
