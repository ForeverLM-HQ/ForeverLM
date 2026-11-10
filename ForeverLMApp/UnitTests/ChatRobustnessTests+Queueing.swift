// Chat robustness tests: queued-message pairing, streaming display and context breakdown.

import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

extension ChatRobustnessTests {
    // MARK: - Queued-message exchange pairing

    @Test("Queued messages pair with their own evaluations, oldest first")
    func queuedMessagesPairOldestFirst() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "s1", topic: "Pairing", sourceIDs: [])

        // Tutor asks; learner answers; a second message is queued mid-turn.
        try store.addReviewPrompt(sessionID: "s1", question: "Q1", sourceRefs: [])
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message one", sourceRefs: [])
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message two", sourceRefs: [])

        // Turn 1 completes: its evaluation must land on the row holding message
        // one — and must not overwrite that eagerly-persisted answer even though
        // the caller passes the latest user message.
        let firstSequence = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "message two", evaluation: "eval one",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        // Follow-up turn completes: pairs with message two.
        let secondSequence = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "message two", evaluation: "eval two",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )

        #expect(firstSequence == 1)
        #expect(secondSequence == 2)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "s1")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges.count == 2)
        #expect(exchanges[0].userAnswer == "message one")
        #expect(exchanges[0].evaluation == "eval one")
        #expect(exchanges[1].userAnswer == "message two")
        #expect(exchanges[1].evaluation == "eval two")
    }

    @Test("A reply stopped before it began closes its row, so the next reply pairs with its own message")
    func emptyStopClosesPendingRow() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "s1", topic: "Steering", sourceIDs: [])

        // Message one's turn is cut short by Send now on message two before it
        // produced any text; message two is admitted behind it.
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message one", sourceRefs: [])
        let closed = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "message one", evaluation: "",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message two", sourceRefs: [])

        // Message two's reply lands on message two, not on the stopped row.
        let answered = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "message two", evaluation: "the short answer",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )

        #expect(closed == 1)
        #expect(answered == 2)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "s1")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges.count == 2)
        #expect(exchanges[0].userAnswer == "message one")
        #expect(exchanges[0].evaluation == "")
        #expect(exchanges[1].userAnswer == "message two")
        #expect(exchanges[1].evaluation == "the short answer")
    }

    @Test("Evaluations never land on historical rows before the last evaluated exchange")
    func evaluationsSkipHistoricalRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "s1", topic: "History", sourceIDs: [])

        // An imported transcript row with an answer but no evaluation, followed
        // by a completed exchange.
        try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "old imported note", sourceRefs: [])
        try store.addReviewExchange(
            sessionID: "s1", question: "Q", answer: "A", evaluation: "E",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )

        // With nothing pending after the evaluated row, the historical row must
        // stay untouched and the caller falls back to a fresh exchange.
        let sequence = try store.answerPendingReviewExchange(
            sessionID: "s1", answer: "new answer", evaluation: "new eval",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        #expect(sequence == nil)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "s1")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges[0].userAnswer == "old imported note")
        #expect(exchanges[0].evaluation == nil)
    }

    @Test("A reply given a row answers that row, and only while it has no reply")
    func namedRowTakesTheReply() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(id: "s1", topic: "Pairing", sourceIDs: [])
        let stopped = try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message one", sourceRefs: [])
        let asked = try store.recordPendingReviewUserMessage(sessionID: "s1", answer: "message two", sourceRefs: [])
        #expect(stopped == 1)
        #expect(asked == 2)

        // Row one is older and open, but the reply names row two.
        let answered = try store.answerPendingReviewExchange(
            sessionID: "s1", sequence: asked, answer: "message two", evaluation: "reply to two",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )
        // A row that has its reply is not answered again.
        let again = try store.answerPendingReviewExchange(
            sessionID: "s1", sequence: asked, answer: "message two", evaluation: "a second reply",
            score: nil, knowledgeNote: nil, sourceRefs: []
        )

        #expect(answered == 2)
        #expect(again == nil)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "s1")
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
        #expect(exchanges.map(\.userAnswer) == ["message one", "message two"])
        #expect(exchanges.map(\.evaluation) == [nil, "reply to two"])
    }

    /// The chat as its rows keep it: each learner message, and the reply
    /// saved on its row.
    private static func storedPairs(_ storage: StorageService, sessionID: String) async throws -> [(answer: String?, reply: String?)] {
        try await storage.loadReviewSessionExchanges(sessionID: sessionID)
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map { (answer: $0.userAnswer, reply: $0.evaluation) }
    }

    private static let pairingConfig = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "z-ai/glm-5.3-flash")

    /// A quiz answer whose turn ran to its reply.
    @MainActor
    private static func answered(_ answer: String, reply: String, in manager: ReviewSessionManager, config: AITaskConfig) async throws {
        await manager.saveLearnerMessageForTesting(answer)
        manager.beginTurnForTesting()
        try await manager.finishTurnForTesting(reply: reply, config: config)
    }

    /// A quiz answer whose grade was cut short: the learner pressed ↑ on a
    /// message queued under it, and the turn ended having said nothing.
    @MainActor
    private static func cutShort(_ answer: String, in manager: ReviewSessionManager, config: AITaskConfig) async {
        await manager.saveLearnerMessageForTesting(answer)
        manager.beginTurnForTesting()
        await manager.stopTurnBeforeReplyForTesting(streamedRowShown: false, config: config)
    }

    @Test("A quiz grade cut short by Send now leaves its answer unanswered, and every later answer keeps its own reply")
    @MainActor
    func quizReplyPairsWithItsOwnAnswerAfterCutShortGrades() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuizReplyPairing_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let sessionID = CourseQuizSitting.sessionID(forQuizID: "cq-cristae")
        try await storage.createReviewSession(id: sessionID, topic: "Quiz: Cristae Architecture and State", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        let config = Self.pairingConfig
        await manager.openScriptedReviewForTesting(
            sessionID: sessionID,
            opening: "Quiz: Cristae Architecture and State · 15 questions\n\n**Question 1 of 15 · Recall**\n\nWhich major metabolic pathways named in the lecture occur in the mitochondrial matrix?"
        )

        // The start of the sitting of 2026-09-27, whose third and fifth
        // answers drew no saved reply.
        let q1FollowUp = "You have one pathway. What other major metabolic pathway named in the lecture also occurs there?"
        let q1Grade = "**Partly**\n\nYou missed beta-oxidation.\n\n**Question 2 of 15 · Explain**\n\nWhy is the inner mitochondrial membrane central to ATP production?"
        let sideAnswer = "**Beta-oxidation** breaks fatty acids down into acetyl-CoA.\n\n**Question 2 of 15 · Explain**\n\nWhy is the inner mitochondrial membrane central to ATP production?"
        let q2Grade = "**Right**\n\nThe electron-transport chain sits in the inner membrane.\n\n**Question 3 of 15 · Explain**\n\nWhy should the intermembrane space be treated as a distinct compartment?"
        let q3FollowUp = "**Question 3 · follow-up**\n\nWhat do those molecules do there?"
        let q3Grade = "**Right**\n\nThe space holds its own molecules and gradients.\n\n**Question 4 of 15 · Recall**\n\nWhat distinguishes a mitochondrial contact site?"
        try await Self.answered("tca cycle", reply: q1FollowUp, in: manager, config: config)
        try await Self.answered("not sure", reply: q1Grade, in: manager, config: config)
        await Self.cutShort("not sure", in: manager, config: config)
        try await Self.answered("what is beta oxidation used for btw? just following up on q1", reply: sideAnswer, in: manager, config: config)
        await Self.cutShort("that is where all the oxphos complexes are", in: manager, config: config)
        try await Self.answered("that is where the etc is", reply: q2Grade, in: manager, config: config)
        try await Self.answered("there are also molecules and gradients there", reply: q3FollowUp, in: manager, config: config)
        try await Self.answered("get exported and imported", reply: q3Grade, in: manager, config: config)

        let pairs = try await Self.storedPairs(storage, sessionID: sessionID)
        #expect(pairs.map { $0.answer } == [
            "tca cycle",
            "not sure",
            "not sure",
            "what is beta oxidation used for btw? just following up on q1",
            "that is where all the oxphos complexes are",
            "that is where the etc is",
            "there are also molecules and gradients there",
            "get exported and imported",
        ])
        #expect(pairs.map { $0.reply } == [q1FollowUp, q1Grade, nil, sideAnswer, nil, q2Grade, q3FollowUp, q3Grade])
        // The row times follow the conversation, as they do when each reply
        // is kept on the message it answers.
        let times = try await storage.loadReviewSessionExchanges(sessionID: sessionID)
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .compactMap { $0.answeredAt }
        #expect(times.count == 8)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("A chat turn stopped or failed before it replied never takes the next reply")
    @MainActor
    func turnWithoutReplyKeepsItsRowToItself() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatReplyPairing_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Cristae", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        let config = Self.pairingConfig

        // Stopped while it searched: the empty row is closed.
        await manager.saveLearnerMessageForTesting("find the cristae junction paper")
        manager.beginTurnForTesting()
        await manager.stopTurnBeforeReplyForTesting(streamedRowShown: true, config: config)
        // Stopped while a tool ran: the streamed row was already gone.
        await manager.saveLearnerMessageForTesting("the 2020 one")
        manager.beginTurnForTesting()
        await manager.stopTurnBeforeReplyForTesting(streamedRowShown: false, config: config)
        // Failed, and the learner sent something new instead of Retry.
        await manager.saveLearnerMessageForTesting("what is a crista junction?")
        manager.beginTurnForTesting()
        await manager.saveLearnerMessageForTesting("in one sentence")
        manager.beginTurnForTesting()
        let reply = "The narrow neck joining a crista to the inner boundary membrane."
        try await manager.finishTurnForTesting(reply: reply, config: config)

        let pairs = try await Self.storedPairs(storage, sessionID: "chat")
        #expect(pairs.map { $0.answer } == ["find the cristae junction paper", "the 2020 one", "what is a crista junction?", "in one sentence"])
        #expect(pairs.map { $0.reply } == ["", nil, nil, reply])
    }

    @Test("Retry answers the failed message's own row, and a message sent while a turn runs waits for its own reply")
    @MainActor
    func retryAndMidTurnMessageKeepTheirRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatRetryPairing_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Cristae", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)
        let config = Self.pairingConfig

        // A turn fails; Retry runs it again on the same message.
        await manager.saveLearnerMessageForTesting("one")
        manager.beginTurnForTesting()
        manager.beginTurnForTesting()
        try await manager.finishTurnForTesting(reply: "reply to one", config: config)
        // A message saved while the turn before it is still running.
        await manager.saveLearnerMessageForTesting("two")
        manager.beginTurnForTesting()
        await manager.saveLearnerMessageForTesting("three")
        try await manager.finishTurnForTesting(reply: "reply to two", config: config)
        manager.beginTurnForTesting()
        try await manager.finishTurnForTesting(reply: "reply to three", config: config)

        let pairs = try await Self.storedPairs(storage, sessionID: "chat")
        #expect(pairs.map { $0.answer } == ["one", "two", "three"])
        #expect(pairs.map { $0.reply } == ["reply to one", "reply to two", "reply to three"])
    }

    // MARK: - Streaming display

    @Test("Trailing partial tool-call tag fragments never flicker into the bubble")
    @MainActor
    func partialToolCallTagIsStrippedDuringStreaming() {
        #expect(ReviewSessionManager.strippingTrailingPartialToolCallTag("Let me check. <flm_tool_c")
            == "Let me check. ")
        #expect(ReviewSessionManager.strippingTrailingPartialToolCallTag("Almost done <")
            == "Almost done ")
        // Legitimate text is left alone.
        #expect(ReviewSessionManager.strippingTrailingPartialToolCallTag("a < b")
            == "a < b")
        // A complete tag is not this helper's job (removeToolCallBlocks owns it).
        let complete = "Check. <flm_tool_call>"
        #expect(ReviewSessionManager.strippingTrailingPartialToolCallTag(complete) == complete)
    }

    @Test("Leaked tool-name lines are dropped from lead-in text before a tool call")
    @MainActor
    func leakedToolNameLinesAreStripped() {
        // The bare tool name alone (the screenshot case) disappears entirely.
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            "start_review_session", toolNames: ["start_review_session"]) == "")
        // Decorated variants (backticks, colon) are still just debris.
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            "`start_review_session`:", toolNames: ["start_review_session"]) == "")
        // Real prose around the call survives, including prose mentioning the tool.
        let prose = "Let me start a review with start_review_session."
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            prose, toolNames: ["start_review_session"]) == prose)
        // Mixed: the debris line goes, the prose line stays.
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            "start_review_session\nStarting your quiz now.",
            toolNames: ["start_review_session"]) == "Starting your quiz now.")
        // No tool calls → nothing is touched.
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            "start_review_session", toolNames: []) == "start_review_session")
        // Blank lines carry markdown paragraph breaks and must survive.
        let paragraphs = "First thought.\n\nSecond thought."
        #expect(ReviewSessionManager.strippingLeakedToolNameLines(
            paragraphs, toolNames: ["start_review_session"]) == paragraphs)
    }

    @Test("Native tool results are shortened only when the actual model window is exceeded")
    @MainActor
    func nativeToolResultsTruncateInPlace() {
        let bigText = String(repeating: "y", count: 40_000)
        let turns: [AIChatTurn] = [
            .user("go"),
            .assistant(text: "", toolCalls: [AIToolCallRequest(id: "c1", name: "search_sources_semantic", argumentsJSON: "{}")]),
            .toolResults([AIToolResultPayload(callID: "c1", toolName: "search_sources_semantic", text: bigText, isError: false)]),
        ]
        // A tiny model window forces trimming.
        let config = AITaskConfig(provider: .cerebras, apiKey: "k", model: "llama3.1-8b")

        let trimmed = ReviewSessionManager.trimmedNativeToolResultTurnsForTesting(
            turns,
            systemPrompt: "SYSTEM",
            config: config
        )

        guard case .toolResults(let results) = trimmed[2] else {
            Issue.record("Tool results turn was dropped — pairing must be preserved")
            return
        }
        #expect(results.count == 1)
        #expect(results[0].callID == "c1")
        #expect(results[0].text.count < bigText.count)
        #expect(results[0].text.lowercased().contains("shortened"))
    }

    @Test("The newest complete paper is fed verbatim even when other input must shrink")
    @MainActor
    func newestFullPaperIsProtectedFromOverflowTrimming() {
        let paper = "# Complete paper\n\n" + String(repeating: "source evidence. ", count: 3_000)
        let olderSearch = String(repeating: "older search result ", count: 2_000)
        let turns: [AIChatTurn] = [
            .user("Read the paper."),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "search-call", name: "search_sources_semantic", argumentsJSON: "{}")
            ]),
            .toolResults([
                AIToolResultPayload(
                    callID: "search-call",
                    toolName: "search_sources_semantic",
                    text: olderSearch,
                    isError: false
                )
            ]),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "paper-call", name: "get_source_content", argumentsJSON: "{}")
            ]),
            .toolResults([
                AIToolResultPayload(
                    callID: "paper-call",
                    toolName: "get_source_content",
                    text: paper,
                    isError: false
                )
            ]),
        ]
        let config = AITaskConfig(provider: .cerebras, apiKey: "k", model: "llama3.1-8b")

        let trimmed = ReviewSessionManager.trimmedNativeToolResultTurnsForTesting(
            turns,
            systemPrompt: "SYSTEM",
            config: config
        )

        guard case .toolResults(let olderResults) = trimmed[2],
              case .toolResults(let paperResults) = trimmed[4] else {
            Issue.record("Tool result pairing was not preserved")
            return
        }
        #expect(olderResults[0].text.count < olderSearch.count)
        #expect(paperResults[0].text == paper)
    }

    @Test("A complete paper tool result stays verbatim when it fits the model window")
    @MainActor
    func fullPaperToolResultIsNotPrematurelyTruncated() {
        let paper = "# Gupta paper\n\n" + String(repeating: "complete source evidence. ", count: 8_000)
        let turns: [AIChatTurn] = [
            .user("Open the Gupta paper and answer from it."),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "paper-call", name: "get_source_content", argumentsJSON: "{\"source_id\":\"gupta\"}")
            ]),
            .toolResults([
                AIToolResultPayload(
                    callID: "paper-call",
                    toolName: "get_source_content",
                    text: paper,
                    isError: false
                )
            ]),
        ]
        let config = AITaskConfig(provider: .openai, apiKey: "k", model: "gpt-5.4")

        let kept = ReviewSessionManager.trimmedNativeToolResultTurnsForTesting(
            turns,
            systemPrompt: String(repeating: "instruction ", count: 4_000),
            toolCharacters: 40_000,
            config: config
        )

        guard case .toolResults(let results) = kept[2] else {
            Issue.record("Tool results turn was dropped")
            return
        }
        #expect(results.count == 1)
        #expect(results[0].text == paper)
        #expect(!results[0].text.lowercased().contains("truncat"))
        #expect(!results[0].text.lowercased().contains("shortened"))
    }

    // MARK: - Context breakdown (composer gauge)

    @Test("Context breakdown splits instructions, sources, tools, and conversation")
    @MainActor
    func contextBreakdownSplitsComponents() {
        let sourceText = String(repeating: "s", count: 8_000)
        let instructions = String(repeating: "i", count: 4_000)
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: instructions + sourceText,
            volatileSystem: String(repeating: "v", count: 400),
            sourceContext: sourceText,
            perSourceShares: [],
            conversationCharacters: 2_000,
            toolCharacters: 1_200,
            config: config
        )

        guard let breakdown else {
            Issue.record("Breakdown was never published")
            return
        }
        // 4 characters per token, and the source text must be charged to
        // sources rather than double-counted into instructions.
        #expect(breakdown.instructionTokens == 1_000)
        #expect(breakdown.sourceTokens == 2_000)
        #expect(breakdown.toolTokens == 300)
        #expect(breakdown.conversationTokens == 500)
        #expect(breakdown.volatileTokens == 100)
        #expect(breakdown.usedTokens == 3_900)
        #expect(breakdown.contextWindowTokens == 1_000_000)
        #expect(breakdown.freeTokens == 1_000_000 - 3_900)
    }

    @Test("Context breakdown never reports a negative or over-full window")
    @MainActor
    func contextBreakdownClampsToWindow() {
        // A tiny window plus an oversized conversation must clamp at 100% used
        // and zero free rather than going negative.
        let config = AITaskConfig(provider: .cerebras, apiKey: "k", model: "llama3.1-8b")

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: "SYSTEM",
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 4_000_000,
            toolCharacters: 0,
            config: config
        )

        guard let breakdown else {
            Issue.record("Breakdown was never published")
            return
        }
        #expect(breakdown.sourceTokens == 0)
        #expect(breakdown.freeTokens == 0)
        #expect(breakdown.usedFraction == 1.0)
    }

    @Test("The source catalog is charged to sources, not to instructions")
    @MainActor
    func contextBreakdownChargesCatalogToSources() {
        // A large Notebook pool produces a large catalog. Counting it as
        // instructions would render as an enormous system prompt beside an
        // empty "Attached sources" row — the opposite of what is happening.
        let manifest = String(repeating: "m", count: 6_000)
        let instructions = String(repeating: "i", count: 4_000)
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: instructions + manifest,
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 0,
            toolCharacters: 0,
            config: config,
            sourceManifest: manifest
        )

        guard let breakdown else {
            Issue.record("Breakdown was never published")
            return
        }
        #expect(breakdown.sourceTokens == 1_500)
        #expect(breakdown.instructionTokens == 1_000)
    }

    @Test("Per-source shares are captured for each attached source")
    @MainActor
    func perSourceSharesArePublished() {
        let shares = [
            ReviewSessionManager.ChatContextBreakdown.SourceShare(id: "a", title: "Alpha", characters: 480),
            ReviewSessionManager.ChatContextBreakdown.SourceShare(id: "b", title: "Beta", characters: 320),
        ]
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: "SYSTEM",
            volatileSystem: "",
            sourceContext: String(repeating: "s", count: 800),
            perSourceShares: shares,
            conversationCharacters: 0,
            toolCharacters: 0,
            config: config
        )

        #expect(breakdown?.perSource.map(\.id) == ["a", "b"])
        #expect(breakdown?.perSource.map(\.title) == ["Alpha", "Beta"])
        #expect(breakdown?.perSource.reduce(0) { $0 + breakdown!.tokens($1.characters) } == 200)
    }

    @Test("Provider-reported prompt tokens replace the char estimate")
    @MainActor
    func contextBreakdownCalibratesFromReportedUsage() {
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")
        // 8k characters total: the flat /4 guess says 2,000 tokens, but the
        // provider bills 2,500 across fresh input, cache reads, and writes.
        let usage = usageEvent(
            provider: config.provider.shortName,
            model: config.model,
            input: 500,
            cached: 1_500,
            cacheCreation: 500
        )

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: String(repeating: "i", count: 4_000),
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 4_000,
            toolCharacters: 0,
            config: config,
            usage: usage
        )

        guard let breakdown else {
            Issue.record("Breakdown was never published")
            return
        }
        #expect(breakdown.isCalibrated)
        #expect(breakdown.usedTokens == 2_500)
        #expect(breakdown.charactersPerToken == 3.2)
        // Components rescale to the measured ratio rather than staying at /4.
        #expect(breakdown.instructionTokens == 1_250)
        #expect(breakdown.conversationTokens == 1_250)
    }

    @Test("Usage recorded before the request was assembled is ignored")
    @MainActor
    func contextBreakdownIgnoresStaleUsage() {
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")
        // A previous round's much smaller request must not be reported as this
        // one's total just because it is the most recent event on record.
        let stale = usageEvent(
            provider: config.provider.shortName,
            model: config.model,
            input: 40,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: String(repeating: "i", count: 8_000),
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 0,
            toolCharacters: 0,
            config: config,
            usage: stale
        )

        #expect(breakdown?.isCalibrated == false)
        #expect(breakdown?.usedTokens == 2_000)
    }

    @Test("Usage from another model does not calibrate this request")
    @MainActor
    func contextBreakdownIgnoresOtherModelUsage() {
        let config = AITaskConfig(provider: .anthropic, apiKey: "k", model: "claude-sonnet-5")
        let other = usageEvent(provider: config.provider.shortName, model: "claude-opus-4-8", input: 9_000)

        let breakdown = ReviewSessionManager.contextBreakdownForTesting(
            stableSystem: String(repeating: "i", count: 8_000),
            volatileSystem: "",
            sourceContext: "",
            perSourceShares: [],
            conversationCharacters: 0,
            toolCharacters: 0,
            config: config,
            usage: other
        )

        #expect(breakdown?.isCalibrated == false)
        #expect(breakdown?.usedTokens == 2_000)
    }

    @Test("Prompt totals normalize Anthropic and OpenAI cache conventions")
    func promptTokensNormalizesCacheReporting() {
        // Anthropic reports input_tokens exclusive of cache reads and writes.
        let anthropic = usageEvent(
            provider: AIProvider.anthropic.shortName,
            model: "claude-sonnet-5",
            input: 100,
            cached: 900,
            cacheCreation: 200
        )
        #expect(ReviewSessionManager.promptTokens(of: anthropic) == 1_200)

        // OpenAI-style providers already fold cached reads into prompt_tokens,
        // so adding them again would double-count.
        let openAI = usageEvent(
            provider: AIProvider.openai.shortName,
            model: "gpt-5",
            input: 1_000,
            cached: 900
        )
        #expect(ReviewSessionManager.promptTokens(of: openAI) == 1_000)
    }
}
