// Chat tool surface, working indicator, thinking and written-page tests.

import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

// MARK: - Chat tool surface

/// Which app tools a chat can call is decided by two static sets. A study chat
/// — the chat on a Notebook or on a paper — is scoped hard, so anything a
/// learner says out loud there has to be listed by name; Slack was not, and a
/// Notebook chat asked about a PDF posted that week searched the library nine
/// times and never read the channel.
@Suite("Chat tool surface")
struct ChatToolSurfaceTests {
    @Test("A study chat can read Slack live and file a posted PDF onto its paper")
    func studyChatsReachSlack() {
        let study = ReviewSessionManager.studySurfaceToolNames
        #expect(study.contains("list_slack_channels"))
        #expect(study.contains("read_slack_channel"))
        #expect(study.contains("read_slack_thread"))
        #expect(study.contains("search_slack_messages"))
        #expect(study.contains("attach_pdf_to_paper"))
        #expect(study.contains("import_paper_from_url"))
    }

    @Test("A study chat asked to schedule its papers can put them on the Mac's Calendar")
    func studyChatsReachTheCalendar() {
        let study = ReviewSessionManager.studySurfaceToolNames
        // create_calendar_event is also what turns on the calendar guidance.
        #expect(study.isSuperset(of: [
            "get_calendar_events", "create_calendar_event", "update_calendar_event",
            "delete_calendar_event", "list_goals", "get_goal"
        ]))
        #expect(study.isDisjoint(with: ["get_day_plan", "add_time_block", "revise_day_plan"]))
    }

    @Test("Every chat can put what it names on the learner's screen")
    func everyChatCanOpenThings() {
        // 2026-10-11: asked to open a notebook, a chat said it had and nothing
        // moved. A study chat had no tool that opens anything.
        #expect(ReviewSessionManager.studySurfaceToolNames.isSuperset(of: ["open_in_app", "list_notebooks"]))
        #expect(ReviewSessionManager.chatExcludedToolNames.isDisjoint(with: ["open_in_app", "list_notebooks"]))
    }

    @Test("A chat may say it did something only when a tool did it, and opening is a tool")
    @MainActor
    func chatClaimsOnlyWhatAToolDid() {
        let openInApp = ReviewSessionManager.AppToolDefinition(
            name: "open_in_app", description: "Show one of the learner's things", inputSchemaJSON: "{\"type\":\"object\"}"
        )
        let listSources = ReviewSessionManager.AppToolDefinition(
            name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}"
        )
        // The chat on a paper, a study kind: open_in_app reaches it now.
        let study = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Ageing",
            hasAttachedSource: true,
            appTools: [openInApp, listSources],
            mode: .deepRead
        )
        #expect(study.contains("only when a tool call in this turn did it"))
        #expect(study.contains("call open_in_app with its id"))

        let agent = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Ageing",
            hasAttachedSource: false,
            appTools: [openInApp, listSources]
        )
        #expect(agent.contains("call open_in_app with its id"))

        // Without the tool the rule stands, and names no tool the chat lacks.
        let withoutOpening = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Ageing",
            hasAttachedSource: false,
            appTools: [listSources]
        )
        #expect(withoutOpening.contains("only when a tool call in this turn did it"))
        #expect(!withoutOpening.contains("open_in_app"))
    }

    @Test("A reading chat asked for audio of its book can narrate it, with a free model if asked")
    func studyChatsCanNarrate() {
        // 2026-11-17: asked for text to speech of a textbook with a free
        // model, the chat on the book said it could not make audio and
        // pointed at Terminal's `say`.
        #expect(ReviewSessionManager.studySurfaceToolNames.isSuperset(of: [
            "generate_source_audio", "get_source_audio_status",
            "cancel_source_audio_generation", "set_app_setting",
        ]))
    }

    @Test("Nothing the study surface lists is excluded from the agent chat")
    func studySurfaceIsNeverExcluded() {
        let overlap = ReviewSessionManager.studySurfaceToolNames
            .intersection(ReviewSessionManager.chatExcludedToolNames)
        #expect(overlap.isEmpty, "\(overlap.sorted())")
    }

    /// A catalog the size of the real one: the core tools plus filler whose
    /// schemas push the surface past the deferral budget.
    static let bigCatalog: [ReviewSessionManager.AppToolDefinition] = {
        let padding = String(repeating: "x", count: 900)
        let core = ["search_sources_semantic", "open_in_app", "list_notebooks"].map {
            ReviewSessionManager.AppToolDefinition(name: $0, description: "Core \($0)", inputSchemaJSON: "{\"type\":\"object\"}")
        }
        let filler = (0..<60).map { index in
            ReviewSessionManager.AppToolDefinition(
                name: "rare_tool_\(index)",
                description: "Rarely used action \(index). \(padding)",
                inputSchemaJSON: "{\"type\":\"object\"}"
            )
        }
        let audio = ReviewSessionManager.AppToolDefinition(
            name: "generate_audio_overview",
            description: "Make a podcast-style audio overview of sources. \(padding)",
            inputSchemaJSON: "{\"type\":\"object\",\"properties\":{\"source_ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}"
        )
        return core + filler + [audio]
    }()

    @Test("A chat over the full catalog sends the core tools whole and names the rest in load_app_tools")
    @MainActor
    func bigCatalogDefersTheLongTail() throws {
        let names = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false,
            appTools: Self.bigCatalog,
            hasSynthesisContext: false,
            mode: .assistant
        ).map(\.name)
        #expect(names.contains("search_sources_semantic"))
        #expect(names.contains("open_in_app"))
        #expect(!names.contains("rare_tool_0"))
        #expect(!names.contains("generate_audio_overview"))
        #expect(names.filter { $0 == "load_app_tools" }.count == 1)

        let loader = try #require(ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false,
            appTools: Self.bigCatalog,
            hasSynthesisContext: false,
            mode: .assistant
        ).first { $0.name == "load_app_tools" })
        #expect(loader.description.contains("generate_audio_overview"))
        #expect(loader.description.contains("rare_tool_59"))
        #expect(!loader.description.contains("open_in_app"))
    }

    @Test("A small tool surface is sent whole, with no loader")
    @MainActor
    func smallSurfaceSendsEverything() {
        let small = Self.bigCatalog.prefix(5).map {
            ReviewSessionManager.AppToolDefinition(name: $0.name, description: "Short", inputSchemaJSON: $0.inputSchemaJSON)
        }
        let names = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false,
            appTools: Array(small),
            hasSynthesisContext: false,
            mode: .assistant
        ).map(\.name)
        #expect(names.contains("rare_tool_1"))
        #expect(!names.contains("load_app_tools"))
    }

    @Test("A loaded tool joins the request after the core tools and stays for the chat")
    @MainActor
    func loadingAddsTheToolForLaterRounds() {
        let (results, specs) = ReviewSessionManager.toolSpecsAfterLoadingForTesting(
            appTools: Self.bigCatalog,
            loads: [
                ["names": ["rare_tool_7", "not_a_tool"]],
                ["query": "audio overview podcast"],
                ["names": ["open_in_app"]],
                ["names": ["still_not_a_tool"]],
            ]
        )
        let names = specs.map(\.name)
        #expect(results[0].isError == false)
        #expect(results[0].text.contains("rare_tool_7"))
        #expect(results[0].text.contains("Not tools here: not_a_tool"))
        #expect(results[1].text.contains("generate_audio_overview"))
        #expect(results[2].isError == false)
        #expect(results[2].text.contains("Already in your tool list"))
        #expect(results[3].isError)
        #expect(names.contains("rare_tool_7"))
        #expect(names.contains("generate_audio_overview"))
        #expect(!names.contains("rare_tool_8"))
        // Loaded tools come after the core ones, so the head of the list
        // the request already carried does not move.
        let core = names.firstIndex(of: "open_in_app") ?? .max
        let loaded = names.firstIndex(of: "rare_tool_7") ?? -1
        #expect(core < loaded)
    }

    @Test("A query finds deferred tools by name first, then by description")
    func loaderQueryRanksNamesFirst() {
        let found = ReviewSessionManager.appTools(
            matching: "audio overview",
            in: Self.bigCatalog,
            limit: 3
        ).map(\.name)
        #expect(found.first == "generate_audio_overview")
        #expect(ReviewSessionManager.appTools(matching: "of", in: Self.bigCatalog, limit: 3).isEmpty)
    }

    @Test("Every core tool is one the agent chat can carry")
    func coreToolsAreNeverExcluded() {
        let overlap = ReviewSessionManager.coreAppToolNames
            .intersection(ReviewSessionManager.chatExcludedToolNames)
        #expect(overlap.isEmpty, "\(overlap.sorted())")
    }

    @Test("A chat carries update_review_session, so moving it into a Notebook needs no load step")
    func updateReviewSessionTravelsWithTheCoreTools() {
        #expect(ReviewSessionManager.coreAppToolNames.contains("update_review_session"))
    }

    @Test("update_review_session needs no session_id: in chat it means this chat")
    func updateReviewSessionTakesNoRequiredSessionID() throws {
        let tool = try #require(MCPToolRegistry.shared.tools.first { $0.name == "update_review_session" })
        #expect(tool.inputSchema["required"] == nil)
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        #expect(properties["notebook_id"] != nil)
    }

    @Test("A notebook chat carries update_notebook, so renaming one needs no load step")
    func updateNotebookTravelsWithTheCoreTools() {
        #expect(ReviewSessionManager.coreAppToolNames.contains("update_notebook"))
    }
}

// MARK: - Working indicator label

@Suite("Review chat working indicator label")
struct ReviewChatWorkingIndicatorLabelTests {
    @Test func namedWaitReplacesTheGenericPreparingLine() {
        #expect(
            ReviewChatWorkingIndicator.label(for: .preparing, detail: "Downloading PSW 2538")
                == "Downloading PSW 2538"
        )
        #expect(ReviewChatWorkingIndicator.label(for: .preparing, detail: "  ") == "Getting your sources ready")
        #expect(ReviewChatWorkingIndicator.label(for: .preparing, detail: nil) == "Getting your sources ready")
    }

    @Test func otherPhasesIgnoreTheDetail() {
        #expect(ReviewChatWorkingIndicator.label(for: .thinking, detail: "Downloading X") == "Thinking")
        #expect(ReviewChatWorkingIndicator.label(for: .writing, detail: "Downloading X") == "Writing")
        #expect(ReviewChatWorkingIndicator.label(for: .searching, detail: "Downloading X") == "Searching your library")
        #expect(ReviewChatWorkingIndicator.label(for: .planning, detail: "Downloading X") == "Planning today's review")
    }
}

struct ReviewChatWorkingIndicatorReasoningTests {
    @Test func nothingShownMeansNoLine() {
        #expect(ReviewChatWorkingIndicator.reasoningGlimpse("") == nil)
        #expect(ReviewChatWorkingIndicator.reasoningGlimpse(" \n ") == nil)
    }

    @Test func summariesQuoteTheirNewestHeading() {
        let summary = """
        **Recalling the exchanger**

        The paper calls it pending, so I should check NHE6 and NHE9.

        **Checking later identifications**

        LETM1 was proposed as a K+/H+ exchanger
        """
        #expect(ReviewChatWorkingIndicator.reasoningGlimpse(summary) == "Checking later identifications")
    }

    @Test func rawThinkingQuotesTheTailOfItsNewestParagraph() {
        #expect(
            ReviewChatWorkingIndicator.reasoningGlimpse("First idea.\n\nThe user asks whether **NHE** is known")
                == "The user asks whether NHE is known"
        )
        let long = String(repeating: "word ", count: 80) + "end"
        let glimpse = ReviewChatWorkingIndicator.reasoningGlimpse(long) ?? ""
        #expect(glimpse.hasPrefix("…word"))
        #expect(glimpse.hasSuffix("end"))
        #expect(glimpse.count <= 181)
    }
}

@Suite("Review chat thinking")
struct ReviewChatThinkingTests {
    @Test @MainActor func theFoldSaysHowLongTheModelThought() {
        func thought(_ duration: TimeInterval?) -> ReviewSessionManager.Message.ToolActivity {
            .init(kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
                  resultPreview: nil, reasoning: "…", thinkingDuration: duration)
        }
        #expect(ReviewChatWorkFold.title(steps: [thought(nil)], duration: nil) == "Thought")
        #expect(ReviewChatWorkFold.title(steps: [thought(0.3)], duration: nil) == "Thought for a moment")
        #expect(ReviewChatWorkFold.title(steps: [thought(8.4)], duration: nil) == "Thought for 8s")
        #expect(ReviewChatWorkFold.title(steps: [thought(59.6)], duration: nil) == "Thought for 1m")
        #expect(ReviewChatWorkFold.title(steps: [thought(96)], duration: nil) == "Thought for 1m 36s")
        // Two steps that only thought: the time each thought, added up.
        #expect(ReviewChatWorkFold.title(steps: [thought(30), thought(66)], duration: 500) == "Thought for 1m 36s")
        #expect(ReviewChatWorkFold.title(steps: [thought(30), thought(nil)], duration: 500) == "Thought")
    }

    @Test @MainActor func theFoldSaysHowLongTheReplyWorkedOrHowManyStepsItTook() {
        let search = ReviewSessionManager.Message.ToolActivity(
            toolName: "search_sources_semantic", detail: "q", state: .succeeded, resultPreview: nil
        )
        let thinking = ReviewSessionManager.Message.ToolActivity(
            kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
            resultPreview: nil, reasoning: "…", thinkingDuration: 8
        )
        #expect(ReviewChatWorkFold.title(steps: [thinking, search], duration: 137) == "Worked for 2m 17s")
        #expect(ReviewChatWorkFold.title(steps: [search], duration: 0.2) == "Worked for a moment")
        #expect(ReviewChatWorkFold.title(steps: [thinking, search], duration: nil) == "Worked · 1 step")
        #expect(ReviewChatWorkFold.title(steps: [search, search, search], duration: nil) == "Worked · 3 steps")
        #expect(ReviewChatWorkFold.durationText(3_840) == "1h 4m")
        #expect(ReviewChatWorkFold.durationText(7_200) == "2h")
    }

    @Test @MainActor func anOpenFoldDrawsEachRunOfToolCallsAsOneCard() {
        let search = ReviewSessionManager.Message.ToolActivity(
            toolName: "search_sources_semantic", detail: "q", state: .succeeded, resultPreview: nil
        )
        let thinking = ReviewSessionManager.Message.ToolActivity(
            kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
            resultPreview: nil, reasoning: "…", thinkingDuration: 8
        )
        let segments = ReviewChatWorkFold.segments(of: [search, search, thinking, search])
        #expect(segments.map(\.isThinking) == [false, true, false])
        #expect(segments.map { $0.steps.map(\.index) } == [[0, 1], [2], [3]])
    }

    /// One reply, as a native-tools turn leaves it: the first step's message
    /// (empty: it only called tools), its thinking, two calls, the answer's
    /// thinking and the answer. Times are the rows' own clocks.
    @MainActor
    private static func workedReply(
        start: Date,
        page: ChatWrittenPage? = nil
    ) -> [ReviewSessionManager.Message] {
        typealias Message = ReviewSessionManager.Message
        let firstStep = Message(role: .assistant, content: "", createdAt: start)
        let firstThought = Message(role: .tool, content: "", createdAt: start.addingTimeInterval(8), toolActivity: .init(
            kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
            resultPreview: nil, reasoning: "Find the cristae paper.", thinkingDuration: 8
        ))
        let search = Message(role: .tool, content: "", createdAt: start.addingTimeInterval(9), toolActivity: .init(
            toolName: "search_sources_semantic", detail: "cristae", state: .succeeded, resultPreview: nil
        ))
        let write = Message(role: .tool, content: "", createdAt: start.addingTimeInterval(40), toolActivity: .init(
            toolName: "create_doc", detail: page?.title, state: .succeeded, resultPreview: nil, writtenPage: page
        ))
        // The answer's step began at 117 s; its first words landed at 137 s.
        let answer = Message(role: .assistant, content: "Cristae fold to hold more of the chain.", createdAt: start.addingTimeInterval(117))
        let answerThought = Message(role: .tool, content: "", createdAt: start.addingTimeInterval(137), toolActivity: .init(
            kind: .thinking, toolName: ReviewSessionManager.thinkingActivityName, state: .succeeded,
            resultPreview: nil, reasoning: "Lead with the fold.", thinkingDuration: 20
        ))
        return [firstStep, firstThought, search, write, answerThought, answer]
    }

    @Test @MainActor func aReplyFoldsEveryStepIntoOneLineAboveItsAnswer() throws {
        let page = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let messages = Self.workedReply(start: Date(timeIntervalSince1970: 1_800_000_000), page: page)
        let items = ReviewChatAnswerLayout.items(messages)

        #expect(items.count == 2)
        guard case .work(let work) = try #require(items.first) else {
            Issue.record("the reply does not open with its work: \(items)")
            return
        }
        #expect(work.id == messages[1].id)
        #expect(work.steps.map(\.toolName) == [
            ReviewSessionManager.thinkingActivityName, "search_sources_semantic", "create_doc", ReviewSessionManager.thinkingActivityName,
        ])
        #expect(work.pages == [page])
        #expect(work.answerHasBegun)
        // From the first step's start to the answer's first words.
        #expect(work.duration == 137)
        #expect(ReviewChatWorkFold.title(steps: work.steps, duration: work.duration) == "Worked for 2m 17s")
        guard case .entry(let entry) = items[1] else {
            Issue.record("the answer is not drawn after the work: \(items)")
            return
        }
        #expect(entry.message?.content == "Cristae fold to hold more of the chain.")
    }

    @Test @MainActor func aReplyStillWorkingHasNoAnswerAndNoTimeUntilItThinks() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let messages = Self.workedReply(start: start)
        // Stopped after its calls, before the answer's step: no row says when
        // the last call ended.
        let stopped = Array(messages[0...3])
        #expect(ReviewChatAnswerLayout.workDuration(stopped) == nil)
        guard case .work(let work)? = ReviewChatAnswerLayout.items(stopped).first else {
            Issue.record("no work drawn")
            return
        }
        #expect(!work.answerHasBegun)
        #expect(ReviewChatWorkFold.title(steps: work.steps, duration: work.duration) == "Worked · 2 steps")
        // Ending on thinking, the end is when that thinking ended.
        #expect(ReviewChatAnswerLayout.workDuration(Array(messages[0...1])) == 8)
        // An answer whose step did not think ends when its step began.
        #expect(ReviewChatAnswerLayout.workDuration(Array(messages[0...3]) + [messages[5]]) == 117)
    }

    @Test @MainActor func onATopicCardTheWorkHoldsNoThinking() {
        let messages = Self.workedReply(start: Date(timeIntervalSince1970: 1_800_000_000))
        guard case .work(let work)? = ReviewChatAnswerLayout.items(messages, showsThinking: false).first else {
            Issue.record("no work drawn")
            return
        }
        #expect(work.steps.map(\.toolName) == ["search_sources_semantic", "create_doc"])
        #expect(work.id == messages[2].id)
        // A reply that only thought draws no fold there at all.
        let thoughtOnly = [messages[4], messages[5]]
        #expect(ReviewChatAnswerLayout.items(thoughtOnly, showsThinking: false).count == 1)
        #expect(ReviewChatAnswerLayout.items(thoughtOnly).count == 2)
    }

    @Test @MainActor func rowsThatStandAloneStayOutOfTheFold() {
        typealias Message = ReviewSessionManager.Message
        let cards = ChatSavedCards(cardIDs: ["c-1"], sourceIDs: ["src-1"])
        let saved = Message(role: .tool, content: "", toolActivity: .init(
            toolName: "save_card_drafts", detail: cards.label, state: .succeeded, resultPreview: nil, savedCards: cards
        ))
        let page = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let reopenedPage = Message(role: .tool, content: "", toolActivity: .init(
            toolName: ChatWrittenPage.cardRowName, detail: page.title, state: .succeeded, resultPreview: nil,
            customTitle: "Page", writtenPage: page
        ))
        let turn = Message(role: .tool, content: "", toolActivity: .init(
            kind: .sourceTurn, toolName: ReviewSessionManager.sourceTurnActivityName, detail: "topic-1",
            state: .succeeded, resultPreview: nil, customTitle: "Respiration"
        ))
        let answer = Message(role: .assistant, content: "Made from the passage.")
        let items = ReviewChatAnswerLayout.items([reopenedPage, saved, turn, answer])

        #expect(items.count == 4)
        guard case .pages(_, let pages) = items[0] else {
            Issue.record("a reopened reply's page is not a card: \(items)")
            return
        }
        #expect(pages == [page])
        guard case .entry(let cardsEntry) = items[1], case .entry(let turnEntry) = items[2] else {
            Issue.record("standalone rows were folded: \(items)")
            return
        }
        #expect(cardsEntry.savedCards == cards)
        #expect(turnEntry.activities.first?.kind == .sourceTurn)
        #expect(ReviewChatAnswerLayout.workDuration([reopenedPage, saved, turn, answer]) == nil)
    }

    /// Retry asks a failed turn again in the same answer block: the failed
    /// attempt's rows stay, its failure with them, but the retried reply is
    /// timed and carded by its own attempt (`Message.isFromFailedAttempt`).
    @Test @MainActor func aRetriedReplyIsTimedAndCardedByItsOwnAttempt() throws {
        typealias Message = ReviewSessionManager.Message
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let failedPage = ChatWrittenPage(id: "doc-0", title: "First try")
        var failed = [
            Message(role: .tool, content: "", createdAt: start, toolActivity: .init(
                toolName: "create_doc", detail: failedPage.title, state: .succeeded, resultPreview: nil, writtenPage: failedPage
            )),
            Message(role: .tool, content: "", createdAt: start.addingTimeInterval(5), toolActivity: .init(
                toolName: "search_sources_semantic", detail: "q", state: .failed, resultPreview: "timed out"
            )),
            Message(role: .assistant, content: "Let me look that up.", createdAt: start.addingTimeInterval(6)),
        ]
        for index in failed.indices { failed[index].isFromFailedAttempt = true }
        // Retried ten minutes later.
        let page = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let retried = Self.workedReply(start: start.addingTimeInterval(600), page: page)

        guard case .work(let work)? = ReviewChatAnswerLayout.items(failed + retried).first else {
            Issue.record("no work drawn")
            return
        }
        #expect(work.steps.count == 6)
        #expect(work.steps.filter { $0.state == .failed }.count == 1)
        #expect(work.pages == [page])
        #expect(work.duration == 137)
        #expect(work.answerHasBegun)

        // Retrying, before the new attempt has a step or a word: the failed
        // attempt's words are not its answer, and its page is not its card.
        let retrying = failed + [retried[0]]
        guard case .work(let pending)? = ReviewChatAnswerLayout.items(retrying).first else {
            Issue.record("no work drawn while retrying")
            return
        }
        #expect(!pending.answerHasBegun)
        #expect(pending.pages.isEmpty)
        #expect(pending.duration == nil)
    }

    @Test func thinkingSplitsIntoItsParagraphs() {
        let summary = "**Recalling the exchanger**\n\nThe paper calls it pending,\nso check NHE6.\n\n\n  \n**Checking later identifications**\n\n"
        #expect(ReviewChatReasoningText.paragraphs(summary) == [
            "**Recalling the exchanger**",
            "The paper calls it pending,\nso check NHE6.",
            "**Checking later identifications**"
        ])
        #expect(ReviewChatReasoningText.paragraphs(" \n\n ").isEmpty)
    }

    @Test func thinkingHidesTheSourceIDsItNamesSourcesBy() {
        let id = "src_5c74571a89d8c4c689ede19bc4eb69e0f9df2a322868f7d934bda82a8fe3b81a"
        let reasoning = """
        The most relevant ones would be:
        1. The Peter Attia Drive episode #46 (\(id))
        2. The Feldman Protocol episode (id: `\(id)`, \(id)).
        3. His own video, \(id), on mitochondria
        4. The Mind & Matter episode (src_0e8af68b09629b49b4f54997b9
        """
        #expect(ReviewChatReasoningText.paragraphs(reasoning) == ["""
        The most relevant ones would be:
        1. The Peter Attia Drive episode #46
        2. The Feldman Protocol episode.
        3. His own video, on mitochondria
        4. The Mind & Matter episode
        """])
        #expect(ReviewChatWorkingIndicator.reasoningGlimpse("Reading \(id) now") == "Reading now")
        #expect(ReviewChatReasoningText.withoutSourceIDs("No ids here.  Two spaces stay.") == "No ids here.  Two spaces stay.")
    }

    @Test @MainActor func aThinkingRowStandsAloneAndStaysOutOfTheCopy() {
        let search = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(toolName: "search_sources_semantic", detail: "q", state: .succeeded, resultPreview: nil)
        )
        let thinking = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(
                kind: .thinking,
                toolName: ReviewSessionManager.thinkingActivityName,
                state: .succeeded,
                reasoning: "The therapeutic approach is mitochondrial transplantation.",
                thinkingDuration: 96
            )
        )
        let read = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(toolName: "get_source_content", detail: "A", state: .succeeded, resultPreview: nil)
        )
        let answer = ReviewSessionManager.Message(role: .assistant, content: "Transplanted mitochondria help.")

        let entries = ReviewChatTranscriptEntry.grouping([search, thinking, read, answer])

        #expect(entries.count == 4)
        #expect(entries[0].thinking == nil)
        #expect(entries[1].thinking?.reasoning == "The therapeutic approach is mitochondrial transplantation.")
        #expect(entries[2].activities.map(\.toolName) == ["get_source_content"])
        #expect(entries[3].message?.content == "Transplanted mitochondria help.")
        #expect(ReviewSessionManager.copiedAnswerText(from: [thinking, answer]) == "Transplanted mitochondria help.")
    }
}

/// A page a chat's tool wrote: a card under the reply's work, kept with the
/// reply as one link line so a reopened chat draws it again
/// (docs/chat-design.md, "Pages a chat writes").
@Suite("Chat written pages")
struct ChatWrittenPageTests {
    static let created = #"{"doc":{"id":"doc-1","title":"Cristae notes","kind":"markdown","is_archived":false,"is_hidden":false},"revision":"r1","message":"Created Doc ‘Cristae notes’."}"#

    @Test func aPageToolsResultNamesThePage() {
        #expect(ChatWrittenPage.parse(toolName: "create_doc", result: Self.created) == ChatWrittenPage(id: "doc-1", title: "Cristae notes"))
        for tool in ["write_doc", "edit_doc", "update_doc"] {
            #expect(ChatWrittenPage.parse(toolName: tool, result: Self.created)?.id == "doc-1")
        }
        // Not a page tool, not a page, gone to the Trash, hidden, or no result.
        #expect(ChatWrittenPage.parse(toolName: "read_doc", result: Self.created) == nil)
        #expect(ChatWrittenPage.parse(toolName: "update_doc", result: Self.created.replacingOccurrences(of: #""kind":"markdown""#, with: #""kind":"animation""#)) == nil)
        #expect(ChatWrittenPage.parse(toolName: "update_doc", result: Self.created.replacingOccurrences(of: #""is_archived":false"#, with: #""is_archived":true"#)) == nil)
        #expect(ChatWrittenPage.parse(toolName: "update_doc", result: Self.created.replacingOccurrences(of: #""is_hidden":false"#, with: #""is_hidden":true"#)) == nil)
        #expect(ChatWrittenPage.parse(toolName: "write_doc", result: "Error: Nothing was saved.") == nil)
    }

    static let archived = created.replacingOccurrences(of: #""is_archived":false"#, with: #""is_archived":true"#)
    static let hidden = created.replacingOccurrences(of: #""is_hidden":false"#, with: #""is_hidden":true"#)
    static let deleted = #"{"status":"deleted","doc":{"id":"doc-1","title":"Cristae notes","kind":"markdown","is_archived":false,"is_hidden":false},"message":"Moved Doc ‘Cristae notes’ to the Trash."}"#

    @Test func aCallThatPutsAPageAwayNamesIt() {
        #expect(ChatWrittenPage.removedID(toolName: "update_doc", result: Self.archived) == "doc-1")
        #expect(ChatWrittenPage.removedID(toolName: "update_doc", result: Self.hidden) == "doc-1")
        #expect(ChatWrittenPage.removedID(toolName: "delete_doc", result: Self.deleted) == "doc-1")
        // A page still there, a call that writes no page, or no result.
        #expect(ChatWrittenPage.removedID(toolName: "update_doc", result: Self.created) == nil)
        #expect(ChatWrittenPage.removedID(toolName: "read_doc", result: Self.archived) == nil)
        #expect(ChatWrittenPage.removedID(toolName: "delete_doc", result: "Error: Doc not found: doc-1.") == nil)
    }

    @Test func aPageWrittenTwiceIsOneCardUnderItsLastTitle() {
        let first = ChatWrittenPage(id: "doc-1", title: "Draft")
        let other = ChatWrittenPage(id: "doc-2", title: "Other")
        let renamed = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let pages = ChatWrittenPage.adding(renamed, to: ChatWrittenPage.adding(other, to: [first]))
        #expect(pages == [renamed, other])
    }

    @Test func theStoredLineRoundTripsAndOnlyItSplits() {
        let page = ChatWrittenPage(id: "doc 1(x)", title: "Notes [draft] (v2) \\ end")
        let stored = ChatWrittenPage.storing("I wrote it up.\n\nRead it when you can.", with: [page])
        #expect(stored.hasPrefix("[Notes \\[draft\\] (v2) \\\\ end](foreverlm://doc/doc%201%28x%29?card=page)"))
        #expect(ChatWrittenPage.split(stored) == [.page(page), .text("I wrote it up.\n\nRead it when you can.")])
        #expect(ChatWrittenPage.prose(of: stored) == "I wrote it up.\n\nRead it when you can.")
        #expect(StudioEntityLink.parse(destination: page.destination) == .doc("doc 1(x)"))
        #expect(ChatWrittenPage.storing("Done.", with: []) == "Done.")

        // A page link the reply wrote itself stays prose: inline, or a line
        // of its own without the card's query.
        let inline = "See [Cristae notes](foreverlm://doc/doc-1?card=page) for more."
        #expect(ChatWrittenPage.split(inline) == [.text(inline)])
        let ownLine = "[Cristae notes](foreverlm://doc/doc-1)"
        #expect(ChatWrittenPage.split(ownLine) == [.text(ownLine)])
        #expect(ChatWrittenPage.split("[a page](https://example.com/doc/1?card=page)") == [.text("[a page](https://example.com/doc/1?card=page)")])
    }

    static let savedAnimation = #"{"status":"saved","animation_id":"anim-1","site_id":"anim-1","url":"foreverlm-site://anim-1/","doc":{"id":"anim-1","title":"Seahorse trace","kind":"animation","is_archived":false,"is_hidden":false},"message":"Saved."}"#

    @Test("An animation save_animation saved is a card that plays it, stored as its own line (product owner, 2026-11-08: \"make sure they can be rendered from a chat also\")")
    func anAnimationIsACardThatPlays() {
        let animation = ChatWrittenPage.parse(toolName: "save_animation", result: Self.savedAnimation)
        #expect(animation == ChatWrittenPage(id: "anim-1", title: "Seahorse trace", kind: .animation))
        #expect(animation?.animationURL == LinkedPage.localSiteURL(artifactID: "anim-1"))
        // A page tool naming an animation, or save_animation naming a page, is no card.
        #expect(ChatWrittenPage.parse(toolName: "update_doc", result: Self.savedAnimation) == nil)
        #expect(ChatWrittenPage.parse(toolName: "save_animation", result: Self.created) == nil)
        #expect(ChatWrittenPage.parse(toolName: "create_doc", result: Self.created)?.animationURL == nil)

        // Stored as `card=animation`, and split back into the same card.
        let page = ChatWrittenPage(id: "doc-1", title: "Notes")
        let stored = ChatWrittenPage.storing("I made an animation.", with: [page, animation!])
        #expect(stored.contains("[Seahorse trace](foreverlm://doc/anim-1?card=animation)"))
        #expect(ChatWrittenPage.split(stored) == [.page(page), .page(animation!), .text("I made an animation.")])
        #expect(ChatWrittenPage.prose(of: "[Seahorse trace](foreverlm://doc/anim-1?card=animation)\n\nDone.") == "Done.")
        // A card value no build draws stays prose.
        let unknown = "[Seahorse trace](foreverlm://doc/anim-1?card=film)"
        #expect(ChatWrittenPage.split(unknown) == [.text(unknown)])

        // delete_animation in the same turn takes the card away.
        let deleted = #"{"status":"deleted","animation_id":"anim-1","message":"Removed."}"#
        #expect(ChatWrittenPage.removedID(toolName: "delete_animation", result: deleted) == "anim-1")
        #expect(ChatWrittenPage.removedID(toolName: "delete_animation", result: "Error: No animation of yours is named anim-1.") == nil)
        #expect(ChatWrittenPage.removedID(toolName: "save_animation", result: Self.savedAnimation) == nil)
    }

    private static let config = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "z-ai/glm-5.3-flash")

    @Test("A page a turn wrote is a card under its work, stored at the head of its reply, and a card again when the chat reopens")
    @MainActor
    func turnStoresAndReopensItsPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatWrittenPage_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Mitochondria", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        await manager.saveLearnerMessageForTesting("write this up as a page")
        manager.beginTurnForTesting()

        let row = try #require(manager.completeToolForTesting("create_doc", result: Self.created))
        let page = try #require(row.toolActivity?.writtenPage)
        #expect(page == ChatWrittenPage(id: "doc-1", title: "Cristae notes"))
        #expect(row.toolActivity?.detail == "Cristae notes")
        // A step of the work, with its page as a card under the fold.
        guard case .work(let work)? = ReviewChatAnswerLayout.items(manager.chatMessages.filter { $0.role != .user }).first else {
            Issue.record("the call is not drawn as the reply's work")
            return
        }
        #expect(work.pages == [page])

        let reply = try #require(try await manager.settleReplyForTesting("I wrote it up.", config: Self.config))
        // The row shows the prose alone and is still stamped with its exchange.
        #expect(reply.content == "I wrote it up.")
        #expect(reply.exchangeID != nil)
        let exchanges = try await storage.loadReviewSessionExchanges(sessionID: "chat")
        let stored = try #require(exchanges.first?.evaluation)
        #expect(stored == page.markdownLine + "\n\nI wrote it up.")

        let reopened = ReviewSessionManager.reconstructedWrittenPagesForTesting(from: exchanges)
        #expect(reopened.map(\.role) == ["user", "tool", "assistant"])
        #expect(reopened[1].page == page)
        #expect(reopened[2].content == "I wrote it up.")

        // The next turn wrote none: its reply carries no line.
        await manager.saveLearnerMessageForTesting("thanks")
        manager.beginTurnForTesting()
        _ = try await manager.settleReplyForTesting("You're welcome.", config: Self.config)
        let next = try await storage.loadReviewSessionExchanges(sessionID: "chat")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(next.last?.evaluation == "You're welcome.")
    }

    @Test("A page its own turn moved to the Trash or hid keeps no card and no stored line")
    @MainActor
    func aPagePutAwayInItsTurnLeavesNoCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatWrittenPage_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Mitochondria", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        await manager.saveLearnerMessageForTesting("draft two pages, then bin the first")
        manager.beginTurnForTesting()

        let created = try #require(manager.completeToolForTesting("create_doc", result: Self.created))
        let kept = ChatWrittenPage(id: "doc-2", title: "Kept")
        _ = manager.completeToolForTesting("write_doc", result: #"{"doc":{"id":"doc-2","title":"Kept","kind":"markdown"}}"#)
        _ = manager.completeToolForTesting("delete_doc", result: Self.deleted)
        #expect(manager.chatMessages.first { $0.id == created.id }?.toolActivity?.writtenPage == nil)
        guard case .work(let work)? = ReviewChatAnswerLayout.items(manager.chatMessages.filter { $0.role != .user }).first else {
            Issue.record("the calls are not drawn as the reply's work")
            return
        }
        #expect(work.pages == [kept])
        _ = try await manager.settleReplyForTesting("Done.", config: Self.config)
        let first = try await storage.loadReviewSessionExchanges(sessionID: "chat")
        #expect(first.first?.evaluation == kept.markdownLine + "\n\nDone.")

        // Hidden by a later call of its turn: the same.
        await manager.saveLearnerMessageForTesting("make one more, then hide it")
        manager.beginTurnForTesting()
        let again = try #require(manager.completeToolForTesting("create_doc", result: Self.created))
        _ = manager.completeToolForTesting("update_doc", result: Self.hidden)
        #expect(manager.chatMessages.first { $0.id == again.id }?.toolActivity?.writtenPage == nil)
        _ = try await manager.settleReplyForTesting("Hidden.", config: Self.config)
        let next = try await storage.loadReviewSessionExchanges(sessionID: "chat")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(next.last?.evaluation == "Hidden.")
    }
}
