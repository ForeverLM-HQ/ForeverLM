import Foundation
import SQLite3
import Testing
@testable import ForeverLM
#if canImport(AppKit) && canImport(PDFKit)
import AppKit
import PDFKit
#endif

@Suite("review chat resume")
@MainActor
struct ReviewChatResumeTests {
    @Test("Summarize mode starts with a summary prompt instead of a review")
    @MainActor
    func summarizeModeStartsWithSummaryPrompt() {
        let payload = ReviewSessionManager.initialPayloadForTesting(
            mode: .summarize,
            topic: "Selected sources",
            hasAttachedSource: true
        )

        #expect(payload.system.contains("source summarizer"))
        #expect(payload.system.contains("do not quiz the learner first"))
        #expect(payload.messages.first?.content.contains("Summarize the attached source material") == true)
        #expect(payload.messages.first?.content.contains("Start a review") == false)
    }

    @Test("Summarize mode uses already loaded source text")
    @MainActor
    func summarizeModeUsesAlreadyLoadedSourceText() {
        let payload = ReviewSessionManager.initialPayloadForTesting(
            mode: .summarize,
            topic: "Selected sources",
            hasAttachedSource: true,
            sourceContext: "Actual PDF text from the attached paper."
        )

        #expect(payload.system.contains("Source text loaded into this chat"))
        #expect(payload.system.contains("Actual PDF text from the attached paper."))
        #expect(payload.messages.first?.content.contains("Use the attached source text") == true)
        #expect(payload.messages.first?.content.contains("First retrieve") == false)
    }

    @Test("Review mode still starts with a review checklist")
    @MainActor
    func reviewModeStartsWithReviewPrompt() {
        let payload = ReviewSessionManager.initialPayloadForTesting(
            mode: .review,
            topic: "Selected sources",
            hasAttachedSource: true
        )

        #expect(payload.system.contains("review tutor"))
        #expect(payload.messages.first?.content.contains("Start a review") == true)
        #expect(payload.messages.first?.content.contains("compact checklist") == true)
    }

    @Test("memory companion keeps curriculum stable and target cursor volatile")
    func memoryCompanionPromptSeparatesCurriculumFromCursor() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = MemoryItem(
            id: "memory-1",
            kind: .concept,
            target: "Explain why spaced retrieval strengthens access",
            rubricJSON: #"{"criteria":["Distinguishes retrieval from rereading"]}"#,
            learnerContext: "Previously treated familiarity as recall",
            sources: [
                MemoryItemSource(
                    id: "anchor-1",
                    memoryItemID: "memory-1",
                    sourceID: "source-1",
                    excerpt: "Retrieval practice strengthens later access more than passive rereading.",
                    sourceSHA256: "hash-1",
                    sortIndex: 0
                ),
            ],
            createdAt: now,
            updatedAt: now
        )
        let plan = MemoryCompanionPlan(
            targets: [
                MemoryCompanionTarget(
                    memoryItem: item,
                    sourceID: "source-1",
                    reason: .struggle,
                    daysOverdue: 2
                ),
            ],
            topic: "Daily memory check",
            goalID: nil,
            generatedAt: now
        )

        let payload = ReviewSessionManager.memoryCompanionPromptForTesting(
            plan: plan,
            retry: true
        )

        #expect(payload.stable.contains("Memory companion plan"))
        #expect(payload.stable.contains("memory_item_id: memory-1"))
        #expect(payload.stable.contains("hidden_rubric_json"))
        #expect(payload.stable.contains("never reveal IDs, rubrics, or answer evidence"))
        #expect(!payload.stable.contains("Retry this same target"))
        #expect(payload.volatile.contains("Current memory target"))
        #expect(payload.volatile.contains("Retry this same target"))
    }

    @Test("private memory attempt tool never accepts model-supplied identity")
    func privateMemoryAttemptToolOwnsIdentity() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = MemoryCompanionPlan(
            targets: [
                MemoryCompanionTarget(
                    memoryItem: nil,
                    sourceID: "source-1",
                    reason: .firstReview,
                    daysOverdue: 1
                ),
            ],
            topic: "Daily memory check",
            goalID: nil,
            generatedAt: now
        )

        let payload = ReviewSessionManager.memoryCompanionPromptForTesting(plan: plan)
        let tool = payload.toolSpecs.first { $0.name == "record_memory_attempt" }
        let properties = tool?.inputSchema["properties"] as? [String: Any]

        #expect(tool != nil)
        #expect(properties?["memory_item_id"] == nil)
        #expect(properties?["source_id"] != nil)
        #expect(properties?["semantic_target"] != nil)
        #expect(properties?["rubric"] != nil)
        #expect(properties?["evidence_excerpt"] != nil)
    }

    /// A chat that added sources to a Notebook answered with a table of their
    /// ids (2026-10-11): the rule against it sat last among the app-tool rules
    /// and was missing from chats without tools. It now leads every chat's
    /// cached head, after the language rule and before the first id.
    @Test("Every chat is told never to show an id, before it is given one")
    func idRuleLeadsEveryHead() throws {
        for mode in ReviewSessionManager.InitialPromptMode.allCases {
            let stable = ReviewSessionManager.followUpGateForTesting(mode: mode).stable
            #expect(stable.contains(Prompts.responseLanguage + Prompts.hiddenIDs), "\(mode)")
            #expect(stable.components(separatedBy: Prompts.hiddenIDs).count == 2, "\(mode)")
            #expect(!stable.contains("Never print a raw source id"), "\(mode)")
        }

        let plan = MemoryCompanionPlan(
            targets: [
                MemoryCompanionTarget(memoryItem: nil, sourceID: "source-1", reason: .firstReview, daysOverdue: 1),
            ],
            topic: "Daily memory check",
            goalID: nil,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let withCatalog = ReviewSessionManager.memoryCompanionPromptForTesting(plan: plan).stable
        let rule = try #require(withCatalog.range(of: Prompts.hiddenIDs))
        let catalog = try #require(withCatalog.range(of: "Attached source catalog:"))
        #expect(rule.upperBound <= catalog.lowerBound)

        let phone = MemoryReviewTutoring.systemPrompt(briefing: "B", localClockDescription: "Sunday, 2026-10-11, 09:00")
        #expect(phone.contains(Prompts.responseLanguage + Prompts.hiddenIDs))
        #expect(Prompts.replySideChat.contains(Prompts.hiddenIDs))
        #expect(Prompts.readerSideChat.contains(Prompts.hiddenIDs))
    }

    @Test("a later memory session receives structured prior struggle evidence")
    func memoryCompanionPromptIncludesPriorStruggle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = MemoryItem(
            id: "memory-struggle",
            kind: .concept,
            target: "Explain why retrieval precedes feedback",
            rubricJSON: #"{"criteria":["Names effortful retrieval","Explains targeted correction"]}"#,
            sources: [
                MemoryItemSource(
                    id: "anchor-struggle",
                    memoryItemID: "memory-struggle",
                    sourceID: "source-struggle",
                    excerpt: "Retrieval before feedback exposes a specific gap to correct.",
                    sourceSHA256: "hash-struggle",
                    sortIndex: 0
                ),
            ],
            createdAt: now,
            updatedAt: now
        )
        let attempt = MemoryAttempt(
            id: "attempt-struggle",
            memoryItemID: item.id,
            attemptType: .review,
            prompt: "Why retrieve before feedback?",
            learnerAnswer: "Feedback is useful.",
            feedback: "You omitted the diagnostic role of effortful retrieval.",
            score: 0.45,
            scheduleRating: .hard,
            gradeState: .graded,
            evidenceJSON: #"{"missing_rubric_elements":["Names effortful retrieval"],"misconception":"Treats feedback alone as the learning event","retrieval_quality":"hinted"}"#,
            attemptedAt: now.addingTimeInterval(60)
        )
        let projection = MemoryTutorStruggleProjector.project(item: item, attempts: [attempt])
        let plan = MemoryCompanionPlan(
            targets: [
                MemoryCompanionTarget(
                    memoryItem: item,
                    sourceID: "source-struggle",
                    reason: .struggle,
                    daysOverdue: 1
                ),
            ],
            topic: "Daily memory check",
            goalID: nil,
            generatedAt: now
        )

        let payload = ReviewSessionManager.memoryCompanionPromptForTesting(
            plan: plan,
            struggleProjections: [item.id: projection]
        )

        #expect(payload.stable.contains("prior_struggle_evidence"))
        #expect(payload.stable.contains("retrieval_quality: hinted"))
        #expect(payload.stable.contains("Names effortful retrieval"))
        #expect(payload.stable.contains("Treats feedback alone as the learning event"))
        #expect(payload.stable.contains("Feedback is useful."))
    }

    @Test("first-review cue is blocked until its app-owned source is loaded")
    func firstReviewRequiresLoadedSource() {
        let plan = MemoryCompanionPlan(
            targets: [
                MemoryCompanionTarget(
                    memoryItem: nil,
                    sourceID: "source-1",
                    reason: .firstReview,
                    daysOverdue: 0
                ),
            ],
            topic: "Daily memory check",
            goalID: nil,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(ReviewSessionManager.firstReviewSourceIDNeedingLoadForTesting(plan: plan) == "source-1")
        #expect(ReviewSessionManager.firstReviewSourceIDNeedingLoadForTesting(
            plan: plan,
            loadedSourceIDs: ["source-1"]
        ) == nil)
    }

    @Test("Switching from summarize to review keeps context but changes tutor prompt")
    @MainActor
    func summarizeChatCanSwitchToReviewPrompt() {
        let payload = ReviewSessionManager.switchedReviewPayloadForTesting(
            messages: [
                (role: "user", content: "Summarize this source."),
                (role: "assistant", content: "This source argues that retrieval practice improves long-term recall.")
            ],
            topic: "Selected sources",
            hasAttachedSource: true,
            sourceContext: "Retrieval practice study excerpt."
        )

        #expect(payload.system.contains("review tutor"))
        #expect(!payload.system.contains("source summarizer"))
        #expect(payload.system.contains("Retrieval practice study excerpt."))
        #expect(payload.messages.contains { $0.content.contains("This source argues that retrieval practice") })
        #expect(payload.messages.last?.content.contains("Let's switch to a review") == true)
    }

    @Test("Notebook notes tool instructions keep mutable notes out of the cached head")
    func notebookNotesToolInstructionsKeepNotesVolatile() {
        let prompt = ReviewSessionManager.synthesisToolInstructionForTesting(
            title: "Energy Debate",
            markdown: "# Energy Debate\n\n## Current Thesis\nOld argument to revise."
        )

        #expect(prompt.contains("current Notebook title and Notes Markdown appear near the end"))
        #expect(!prompt.contains("Old argument to revise."))
        #expect(prompt.contains("replace_synthesis"))
        #expect(prompt.contains("complete new Notes Markdown"))
        #expect(prompt.contains("skimmable sections"))
    }

    @Test("Notebook notes replacement tool call is parsed")
    func notebookNotesReplacementToolCallIsParsed() {
        let call = ReviewSessionManager.synthesisToolCallForTesting(
            ##"<flm_tool_call>{"tool":"replace_synthesis","markdown":"# Revised Notebook Notes\n\nIntegrated argument."}</flm_tool_call>"##
        )

        #expect(call?.action == .replace)
        #expect(call?.markdown.contains("Integrated argument.") == true)
    }

    @Test("Notebook notes tool calls are hidden from visible chat text")
    @MainActor
    func notebookNotesToolCallsAreHiddenFromVisibleChatText() {
        let response = ##"I'll update the Notebook notes now.<flm_tool_call>{"tool":"replace_synthesis","markdown":"# Revised\n\nBetter notes."}</flm_tool_call>"##

        let visible = ReviewSessionManager.displayableMessageContent(role: .assistant, content: response)

        #expect(visible == "I'll update the Notebook notes now.")
    }

    @Test("Source retrieval tool call is parsed")
    func sourceRetrievalToolCallIsParsed() {
        #expect(ReviewSessionManager.retrievalToolCallForTesting(
            #"<flm_tool_call>{"tool":"retrieve_sources","source_ids":["source-1"],"query":"mitochondrial aging","reason":"Need focused passages","max_sources":2}</flm_tool_call>"#
        ))
    }

    @Test("Source retrieval tool call supports full source mode")
    func sourceRetrievalToolCallSupportsFullSourceMode() {
        #expect(ReviewSessionManager.retrievalToolCallWantsFullTextForTesting(
            #"<flm_tool_call>{"tool":"retrieve_sources","source_ids":["source-1"],"mode":"full","cursor":16000,"reason":"User asked for the whole source","max_sources":1}</flm_tool_call>"#
        ))
        #expect(ReviewSessionManager.retrievalToolCallCursorForTesting(
            #"<flm_tool_call>{"tool":"retrieve_sources","source_ids":["source-1"],"mode":"full","cursor":16000}</flm_tool_call>"#
        ) == 16_000)
    }

    @Test("Full source retrieval pages advance to the actual end")
    func fullSourceRetrievalPagesAdvanceToEnd() {
        let content = "source-start|"
            + String(repeating: "a", count: 1_200)
            + "|source-middle|"
            + String(repeating: "b", count: 1_200)
            + "|source-tail"
        var cursor = 0
        var pages: [String] = []

        for _ in 0..<10 {
            let page = ReviewSessionManager.fullSourcePageForTesting(
                content: content,
                cursor: cursor,
                limit: 1_000
            )
            pages.append(page.text)
            guard let next = page.nextCursor else { break }
            #expect(next > cursor)
            cursor = next
        }

        #expect(pages.count > 1)
        #expect(pages.first?.contains("source-start|") == true)
        #expect(pages.last?.contains("|source-tail") == true)
        #expect(pages.last?.contains("End of source reached") == true)
        #expect(pages.allSatisfy { !$0.localizedCaseInsensitiveContains("truncated") })
    }

    #if canImport(AppKit) && canImport(PDFKit)
    @Test("Chat source context does not bypass canonical paper ingestion")
    @MainActor
    func chatSourceContextReadsLocalPDFTextBeforeStaleURLContent() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-chat-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let pdfURL = tempDir.appendingPathComponent("paper.pdf")
        try writeSearchablePDF("Actual PDF source text about mitochondrial ATP and aging.", to: pdfURL)

        var article = StudioArticle(
            url: "https://www.sciencedirect.com/science/article/pii/S1550413116306227",
            title: "Mammalian Mitochondria and Aging",
            sourceType: .paper,
            localFilePath: pdfURL.path
        )
        article.content = "ScienceDirect access page with captcha instead of article text."

        let context = await ReviewSessionManager.sourceContextContentForTesting(articles: [article])

        #expect(context.isEmpty)
        #expect(!context.contains("captcha"))
    }
    #endif

    @Test("output token retry prompt compacts retrieved source context")
    @MainActor
    func outputTokenRetryPromptCompactsRetrievedSourceContext() {
        let sourceContext = (1...8)
            .map { index in
                """
                ## Source \(index): Long Source \(index) (article, id: source-\(index))

                \(String(repeating: "source-\(index) detail ", count: 400))
                """
            }
            .joined(separator: "\n\n---\n\n")
        let system = """
        Tutor prompt.

        Source text loaded into this chat:

        \(sourceContext)
        """

        let retryPrompt = ReviewSessionManager.outputTokenRetryPromptForTesting(
            systemPrompt: system,
            sourceContext: sourceContext
        )

        #expect(retryPrompt.count < system.count)
        #expect(retryPrompt.contains("Source 1"))
        #expect(retryPrompt.contains("output token limit"))
        #expect(retryPrompt.contains("auto-compacted"))
    }

    @Test("initial prompt caps attached source text sent to provider")
    @MainActor
    func initialPromptCapsAttachedSourceTextSentToProvider() {
        let sourceContext = "source-start " + String(repeating: "source detail ", count: 40_000) + " source-tail"

        let payload = ReviewSessionManager.initialPayloadForTesting(
            mode: .summarize,
            topic: "Selected sources",
            hasAttachedSource: true,
            sourceContext: sourceContext
        )

        #expect(payload.system.contains("source-start"))
        #expect(!payload.system.contains("source-tail"))
        #expect(payload.system.contains("Attached source text truncated in this request"))
    }

    @Test("output token limit recovery keeps visible partial text")
    func outputTokenLimitRecoveryKeepsVisiblePartialText() {
        let partial = """
        Got it. Executing:

        - Remove obsolete sections
        <flm_tool_call>{"tool":"replace_synthesis","markdown":"# Updated
        """

        let finalized = ReviewSessionManager.finalizedVisibleResponseAfterOutputLimitForTesting(partial)

        #expect(finalized == "Got it. Executing:\n\n- Remove obsolete sections")
    }

    @Test("SSE accumulator preserves single-line provider events")
    func sseAccumulatorPreservesSingleLineProviderEvents() throws {
        let providers = ["openai", "groq", "xai", "gemini"]

        for provider in providers {
            let events = collectEvents(from: [
                #"data: {"id":"\#(provider)-chunk","choices":[{"delta":{"content":"Hello"}}]}"#,
                "",
                "data: [DONE]",
                "",
            ])

            #expect(events.count == 2)
            #expect(events[1] == "[DONE]")
            try expectJSONObject(events[0])
        }
    }

    @Test("SSE accumulator preserves Anthropic event metadata and data")
    func sseAccumulatorPreservesAnthropicEvent() throws {
        let events = collectEvents(from: [
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#,
            "",
        ])

        #expect(events.count == 1)
        try expectJSONObject(events[0])
    }

    @Test("SSE accumulator preserves xAI multi-line JSON events")
    func sseAccumulatorPreservesXAIMultilineJSONEvents() throws {
        let events = collectEvents(from: [
            "data: {",
            #"  "id": "xai-chunk","#,
            #"  "object": "chat.completion.chunk","#,
            #"  "model": "grok-3","#,
            #"  "choices": [{"index":0,"delta":{"content":"Hello","role":"assistant"}}]"#,
            "}",
            "",
            "data: [DONE]",
            "",
        ])

        #expect(events.count == 2)
        #expect(events[1] == "[DONE]")
        let json = try expectJSONObject(events[0])
        #expect(json["model"] as? String == "grok-3")
    }

    @Test("SSE accumulator splits adjacent Gemini JSON chunks")
    func sseAccumulatorSplitsAdjacentGeminiJSONChunks() throws {
        let events = collectEvents(from: [
            #"{"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"index":0}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":" world"}],"role":"model"},"index":0}]}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"."}],"role":"model"},"finishReason":"STOP","index":0}]}"#,
        ])

        #expect(events.count == 3)
        try events.forEach { try expectJSONObject($0) }
    }

    @Test("SSE accumulator splits adjacent data-prefixed JSON chunks without blank separators")
    func sseAccumulatorSplitsAdjacentDataPrefixedJSONChunksWithoutBlankSeparators() throws {
        let events = collectEvents(from: [
            #"data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"index":0}]}"#,
            #"data: {"candidates":[{"content":{"parts":[{"text":" world"}],"role":"model"},"index":0}]}"#,
            #"data: {"candidates":[{"content":{"parts":[{"text":"."}],"role":"model"},"finishReason":"STOP","index":0}]}"#,
        ])

        #expect(events.count == 3)
        try events.forEach { try expectJSONObject($0) }
    }

    @Test("SSE accumulator preserves Gemini object fragments")
    func sseAccumulatorPreservesGeminiObjectFragments() throws {
        let events = collectEvents(from: [
            #""candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"index":0}],"modelVersion":"gemini-2.5-flash""#,
        ])

        #expect(events.count == 1)
        #expect(AIStreamDeltaExtractor.text(fromRawDelta: events[0]) == "Hello")
    }

    @Test("stream chat from every managed provider travels OpenRouter end to end")
    func streamChatWorksEndToEndForEveryManagedProvider() async throws {
        // No own router key, so the account's shipped transport applies.
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        let service = AIService(session: ProviderStreamMockURLProtocol.mockSession())
        // A first-party lab is a model family, not a transport: the stub answers
        // only on OpenRouter's path, so a lab's own host would fail the case.
        let cases: [(provider: AIProvider, model: String, expected: String)] = [
            (.anthropic, "claude-sonnet-4-6", "OpenRouter answer."),
            (.openai, "gpt-5.5", "OpenRouter answer."),
            (.xai, "grok-4.3", "OpenRouter answer."),
            (.gemini, "gemini-2.5-flash", "OpenRouter answer."),
            (.openRouter, "anthropic/claude-sonnet-4", "OpenRouter answer."),
        ]

        for testCase in cases {
            let config = AITaskConfig(provider: testCase.provider, apiKey: "test-key", model: testCase.model)
            let stream = await service.streamChat(
                system: "Tutor prompt.",
                messages: [(role: "user", content: "Can you help me review this?")],
                config: config
            )

            var response = ""
            for try await delta in stream {
                response += delta
            }

            #expect(response == testCase.expected, "\(testCase.provider.rawValue)")
        }
    }

    @Test("paper attachment check keeps a bounded output budget")
    func paperAttachmentCheckKeepsBoundedOutputBudget() async throws {
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        let service = AIService(session: RouterRequestCaptureURLProtocol.mockSession())

        let shouldWarn = try await service.shouldWarnForPDFAttachment(
            source: AIUsageSource(id: "paper-1", type: "paper", title: "Selected Paper"),
            selectedPaperTitle: "A Useful Paper",
            pdfTitleCandidate: "A Useful Paper",
            config: AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6")
        )

        #expect(shouldWarn == false)
        let json = try capturedRouterRequest(system: Prompts.paperAttachmentCheck)
        // A one-word classifier must not inherit the 4,096-token reasoning floor:
        // OpenRouter checks available credits against this ceiling before running.
        #expect(json["max_tokens"] as? Int == 512)
    }

    @Test("before OpenRouter's catalog is read, Claude and GPT keep their labs' effort levels")
    func effortAndSpeedSupportGating() {
        // An empty table is a catalog never read (a first launch). Once it has
        // been read it decides every model (openRouterCatalogReasoningEfforts).
        AIModelCatalog.$openRouterReasoningEffortsOverride.withValue([:]) {
            // Anthropic: Opus 5 gets the full effort range. Speed is a property
            // of the route: on OpenRouter these models offer Fast once
            // OpenRouter's endpoint list for them is known (OpenRouterSpeedTierTests).
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .anthropic, model: "claude-opus-5")
                == [.low, .medium, .high, .extraHigh, .max])
            // Stored Opus 4.8 selections keep effort.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .anthropic, model: "claude-opus-4-8")
                == [.low, .medium, .high, .extraHigh, .max])
            // Sonnet 4.6 supports effort but not xhigh.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .anthropic, model: "claude-sonnet-4-6")
                == [.low, .medium, .high, .max])
            // Haiku has neither control.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .anthropic, model: "claude-haiku-4-5").isEmpty)
            // OpenAI reasoning models take low/medium/high.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openai, model: "gpt-5.5")
                == [.low, .medium, .high])
            // GPT-6 adds xhigh and max.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openai, model: "gpt-6-astra")
                == [.low, .medium, .high, .extraHigh, .max])
            // A model that is not on the reasoning line exposes nothing.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openai, model: "gpt-4o").isEmpty)
            // Groq GPT-OSS models take reasoning effort.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .groq, model: "openai/gpt-oss-120b")
                == [.low, .medium, .high])
            // Every other model waits for the catalog rather than a guess.
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .gemini, model: "gemini-3.8-flash").isEmpty)
            #expect(AIRequestOptionSupport.supportedEfforts(provider: .openRouter, model: "z-ai/glm-5.3-flash").isEmpty)
        }
    }

    @Test("chat delta sanitizer ignores raw role-only Groq chunks")
    @MainActor
    func chatDeltaSanitizerIgnoresRawRoleOnlyGroqChunks() {
        let roleOnlyChunk = #"{"object":"chat.completion.chunk","id":"chatcmpl-79fcfa96-e961-4830-bba9-058e555675d2","choices":[{"finish_reason":null,"delta":{"content":"","role":"assistant"},"logprobs":null,"index":0}],"created":1778368385,"x_groq":{"id":"req_01kr7g83z5fstrsavhvn3tq7p0","seed":1328038119},"system_fingerprint":"fp_5082008e34","model":"openai/gpt-oss-120b"}"#

        #expect(ReviewSessionManager.displayableAssistantDeltaForTesting(roleOnlyChunk) == nil)
    }

    @Test("chat delta sanitizer extracts text from raw Groq chunks")
    @MainActor
    func chatDeltaSanitizerExtractsTextFromRawGroqChunks() {
        let textChunk = #"{"object":"chat.completion.chunk","choices":[{"finish_reason":null,"delta":{"content":"Hello","role":"assistant"},"index":0}],"model":"openai/gpt-oss-120b"}"#

        #expect(ReviewSessionManager.displayableAssistantDeltaForTesting(textChunk) == "Hello")
    }

    @Test("chat delta sanitizer preserves newline-only text chunks")
    @MainActor
    func chatDeltaSanitizerPreservesNewlineOnlyTextChunks() {
        #expect(ReviewSessionManager.displayableAssistantDeltaForTesting("\n\n") == "\n\n")
    }

    @Test("chat delta sanitizer ignores raw role-only OpenAI chunks")
    @MainActor
    func chatDeltaSanitizerIgnoresRawRoleOnlyOpenAIChunks() {
        let roleOnlyChunk = #"{"model":"gpt-5.5-2026-04-23","service_tier":"default","choices":[{"index":0,"delta":{"content":"","role":"assistant","refusal":null},"finish_reason":null}],"obfuscation":"nME4v","id":"chatcmpl-DdlakFnnXlxDWWFI1SXt3ZoXgEcAo","created":1778370106,"system_fingerprint":null,"object":"chat.completion.chunk"}"#

        #expect(ReviewSessionManager.displayableAssistantDeltaForTesting(roleOnlyChunk) == nil)
    }

    @Test("chat delta sanitizer ignores raw Anthropic message starts")
    @MainActor
    func chatDeltaSanitizerIgnoresRawAnthropicMessageStarts() {
        let messageStart = #"{"type":"message_start","message":{"content":[],"id":"msg_01VrM8QtXruugv59m78KKiZW","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"output_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"service_tier":"standard","input_tokens":2184,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"inference_geo":"not_available"},"type":"message","stop_reason":null,"stop_sequence":null,"stop_details":null}}"#

        #expect(ReviewSessionManager.displayableAssistantDeltaForTesting(messageStart) == nil)
    }

    @Test("chat delta sanitizer ignores reversed Anthropic message starts")
    @MainActor
    func chatDeltaSanitizerIgnoresReversedAnthropicMessageStarts() {
        let messageStart = #"{"message":{"content":[],"id":"msg_01ST9BDAxZz6BCdHsxKamF7f","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"output_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"service_tier":"standard","input_tokens":2183,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"inference_geo":"not_available"},"type":"message","stop_reason":null,"stop_sequence":null,"stop_details":null},"type":"message_start"}"#

        #expect(ReviewSessionManager.displayableAssistantDeltaForTesting(messageStart) == nil)
        #expect(AIStreamDeltaExtractor.isNonTextRawEvent(messageStart))
    }

    @Test("chat delta sanitizer extracts text from raw Anthropic deltas")
    @MainActor
    func chatDeltaSanitizerExtractsTextFromRawAnthropicDeltas() {
        let textDelta = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#

        #expect(ReviewSessionManager.displayableAssistantDeltaForTesting(textDelta) == "Hello")
    }

    @Test("chat delta sanitizer ignores raw non-text Anthropic deltas")
    @MainActor
    func chatDeltaSanitizerIgnoresRawNonTextAnthropicDeltas() {
        let inputDelta = #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#

        #expect(ReviewSessionManager.displayableAssistantDeltaForTesting(inputDelta) == nil)
    }

    @Test("stream delta extractor handles OpenAI Responses text deltas")
    func streamDeltaExtractorHandlesOpenAIResponsesTextDeltas() throws {
        let json = try expectJSONObject(#"{"type":"response.output_text.delta","delta":"Hello"}"#)

        #expect(AIStreamDeltaExtractor.text(from: json) == "Hello")
    }

    @Test("stream delta extractor keeps Responses reasoning out of visible text")
    func streamDeltaExtractorIgnoresResponsesReasoningDeltas() throws {
        let summaryRaw = #"{"type":"response.reasoning_summary_text.delta","delta":"The user wants me to explain the attached article."}"#
        let reasoningRaw = #"{"type":"response.reasoning_text.delta","delta":"I should inspect the hidden source context."}"#

        let summary = try expectJSONObject(summaryRaw)
        let reasoning = try expectJSONObject(reasoningRaw)

        #expect(AIStreamDeltaExtractor.text(from: summary) == nil)
        #expect(AIStreamDeltaExtractor.text(from: reasoning) == nil)
        #expect(AIStreamDeltaExtractor.isNonTextRawEvent(summaryRaw))
        #expect(AIStreamDeltaExtractor.isNonTextRawEvent(reasoningRaw))
    }

    @Test("stream delta extractor reads the reasoning each provider shows")
    func streamDeltaExtractorReadsShownReasoning() throws {
        let events: [(String, String?)] = [
            (#"{"type":"response.reasoning_summary_text.delta","delta":"**Checking identity**"}"#, "**Checking identity**"),
            (#"{"type":"response.reasoning_text.delta","delta":"raw step"}"#, "raw step"),
            (#"{"type":"response.reasoning_summary_part.done"}"#, "\n\n"),
            (#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me recall NHE."}}"#, "Let me recall NHE."),
            (#"{"choices":[{"index":0,"delta":{"reasoning":"flat","reasoning_details":[{"type":"reasoning.summary","summary":"flat"}]}}]}"#, "flat"),
            (#"{"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.summary","summary":"From details"},{"type":"reasoning.encrypted","data":"xyz"}]}}]}"#, "From details"),
            (#"{"choices":[{"index":0,"delta":{"reasoning_content":"Thinking "}}]}"#, "Thinking "),
            (#"{"candidates":[{"content":{"parts":[{"text":"hidden plan","thought":true},{"text":"Answer"}]}}]}"#, "hidden plan"),
            (#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Answer"}}"#, nil),
            (#"{"type":"response.output_text.delta","delta":"Answer"}"#, nil),
            (#"{"choices":[{"index":0,"delta":{"content":"Answer"}}]}"#, nil),
        ]
        for (raw, expected) in events {
            #expect(AIStreamDeltaExtractor.reasoning(from: try expectJSONObject(raw)) == expected, "\(raw)")
        }
    }

    @Test("stream delta extractor keeps Responses tool arguments out of visible text")
    func streamDeltaExtractorIgnoresResponsesFunctionArgumentDeltas() throws {
        let raw = #"{"type":"response.function_call_arguments.delta","delta":"{\"source_id\":\"src_123\"}"}"#
        let json = try expectJSONObject(raw)

        #expect(AIStreamDeltaExtractor.text(from: json) == nil)
        #expect(AIStreamDeltaExtractor.isNonTextRawEvent(raw))
    }

    @Test("stream delta extractor handles OpenAI content parts")
    func streamDeltaExtractorHandlesOpenAIContentParts() throws {
        let json = try expectJSONObject(#"{"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":[{"type":"text","text":"Hello"},{"type":"text","text":" world"}]},"finish_reason":null}]}"#)

        #expect(AIStreamDeltaExtractor.text(from: json) == "Hello world")
    }

    @Test("stream delta extractor keeps provider reasoning out of visible text")
    func streamDeltaExtractorIgnoresReasoningContent() throws {
        let raw = #"{"choices":[{"index":0,"delta":{"reasoning_content":"First","role":"assistant"}}],"id":"47ad2632-c4ea-9632-81ca-83968f9862a5","model":"grok-3-mini","created":1778370177,"object":"chat.completion.chunk","system_fingerprint":"fp_eeaf5fb266"}"#
        let json = try expectJSONObject(raw)

        #expect(AIStreamDeltaExtractor.text(from: json) == nil)
        #expect(AIStreamDeltaExtractor.isNonTextRawEvent(raw))
    }

    @Test("completion validator flags provider token-limit stops")
    func completionValidatorFlagsProviderTokenLimitStops() throws {
        let anthropic = try expectJSONObject(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null}}"#)
        let openAI = try expectJSONObject(#"{"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":"length"}]}"#)
        let gemini = try expectJSONObject(#"{"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"MAX_TOKENS"}]}"#)

        #expect(AICompletionStopValidator.abnormalStopReason(in: anthropic) == "max_tokens")
        #expect(AICompletionStopValidator.abnormalStopReason(in: openAI) == "length")
        #expect(AICompletionStopValidator.abnormalStopReason(in: gemini) == "MAX_TOKENS")
    }

    @Test("completion token-limit error copy is context neutral")
    func completionTokenLimitErrorCopyIsContextNeutral() throws {
        let openAI = try expectJSONObject(#"{"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":"length"}]}"#)
        var message: String?

        do {
            try AICompletionStopValidator.throwIfStoppedAbnormally(openAI)
        } catch AIError.outputTokenLimit(let outputLimitMessage) {
            message = outputLimitMessage
        } catch {
            Issue.record("Expected outputTokenLimit, got \(error)")
        }

        #expect(message?.contains("output token limit") == true)
        #expect(message?.contains("In chat") == false)
        #expect(message?.contains("one-shot") == false)
    }

    @Test("non-streaming tasks keep token headroom for reasoning providers")
    func nonStreamingTasksKeepTokenHeadroomForReasoningProviders() {
        #expect(AIService.effectiveReasoningAwareMaxTokens(64, provider: .groq, model: "openai/gpt-oss-120b") == 4096)
        #expect(AIService.effectiveReasoningAwareMaxTokens(64, provider: .cerebras, model: "gpt-oss-120b") == 4096)
        #expect(AIService.effectiveReasoningAwareMaxTokens(64, provider: .gemini, model: "gemini-3.5-flash") == 4096)
        // OpenAI is inflated in its own adapter, so this must pass the request through
        // untouched or the multiplier lands twice.
        #expect(AIService.effectiveReasoningAwareMaxTokens(64, provider: .openai, model: "gpt-5.5") == 64)
    }

    @Test("a thinking model gets room to think and still answer")
    func thinkingModelGetsRoomToThinkAndAnswer() {
        // 900 is what SlideCitationService asks for. At the old 1024 floor Gemini 3.5 Flash
        // spent 960 tokens thinking and truncated its JSON on 14 of 29 slides.
        let requested = 900
        #expect(AIService.effectiveReasoningAwareMaxTokens(requested, provider: .gemini, model: "gemini-3.5-flash") == 7200)
        #expect(AIService.effectiveReasoningAwareMaxTokens(requested, provider: .anthropic, model: "claude-sonnet-5") == 7200)
        #expect(AIService.effectiveReasoningAwareMaxTokens(requested, provider: .xai, model: "grok-4.5") == 7200)
        #expect(AIService.effectiveReasoningAwareMaxTokens(requested, provider: .openRouter, model: "deepseek/deepseek-v4-flash") == 7200)
    }

    @Test("headroom never outgrows the model's own window")
    func headroomNeverOutgrowsTheWindow() {
        // llama-3.1-8b has an 8k window, so the multiplier has to give way to the context
        // budget rather than asking for more output than the window can return.
        #expect(AIService.effectiveReasoningAwareMaxTokens(900, provider: .cerebras, model: "llama3.1-8b") == 1740)
    }

    @Test("history compaction gets reasoning headroom on Muse Spark")
    func historyCompactionGetsReasoningHeadroomOnMuseSpark() {
        // The real failure spent 1,806 of the old 2,000-token ceiling on
        // reasoning and returned `finish_reason: length`. The requested summary
        // remains about 2k tokens, but the request itself must leave room to
        // think before producing it.
        #expect(
            AIService.effectiveReasoningAwareMaxTokens(
                2_000,
                provider: .meta,
                model: "muse-spark-1.2"
            ) == 16_000
        )
        #expect(
            AIService.effectiveReasoningAwareMaxTokens(
                2_000,
                provider: .openRouter,
                model: "meta/muse-spark-1.2"
            ) == 16_000
        )
    }

    @Test("completion validator accepts normal provider stops")
    func completionValidatorAcceptsNormalProviderStops() throws {
        let anthropic = try expectJSONObject(#"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}"#)
        let openAI = try expectJSONObject(#"{"object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)
        let gemini = try expectJSONObject(#"{"candidates":[{"content":{"parts":[{"text":"done"}]},"finishReason":"STOP"}]}"#)

        #expect(AICompletionStopValidator.abnormalStopReason(in: anthropic) == nil)
        #expect(AICompletionStopValidator.abnormalStopReason(in: openAI) == nil)
        #expect(AICompletionStopValidator.abnormalStopReason(in: gemini) == nil)
    }

    @Test("displayable message content extracts Gemini raw text")
    @MainActor
    func displayableMessageContentExtractsGeminiRawText() {
        let geminiChunk = #"{"responseId":"sMb_afXYNLDu_uMPqYLS-AU","candidates":[{"content":{"parts":[{"text":"Welcome to your review on \"What the hell is happening in China?\"\n\nHere's our review plan:\n\n### Review Plan\n"}],"role":"model"},"index":0}],"modelVersion":"gemini-2.5-flash","usageMetadata":{"promptTokensDetails":[{"tokenCount":2053,"modality":"TEXT"}],"totalTokenCount":3051,"promptTokenCount":2053,"thoughtsTokenCount":970,"serviceTier":"standard","candidatesTokenCount":28}}"#

        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: geminiChunk)?.hasPrefix("Welcome to your review") == true)
    }

    @Test("displayable message content extracts Gemini JSON fragments")
    @MainActor
    func displayableMessageContentExtractsGeminiJSONFragments() {
        let geminiFragment = #""candidates":[{"content":{"parts":[{"text":"Okay, I can help you review the article \"AI for Bio has a Fuzzy API problem.\" This article discusses"}],"role":"model"},"index":0}],"usageMetadata":{"promptTokensDetails":[{"tokenCount":4658,"modality":"TEXT"}],"totalTokenCount":5062,"promptTokenCount":4658,"thoughtsTokenCount":382,"serviceTier":"standard","candidatesTokenCount":22},"modelVersion":"gemini-2.5-flash","responseId":"m9L_aeTIMpPL_uMPvYqKqAU"}"#

        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: geminiFragment)?.hasPrefix("Okay, I can help you review") == true)
    }

    @Test("persisted raw provider metadata is skipped when rebuilding chat")
    @MainActor
    func persistedRawProviderMetadataIsSkippedWhenRebuildingChat() {
        let roleOnlyChunk = #"{"created":1778370210,"object":"chat.completion.chunk","choices":[{"finish_reason":null,"delta":{"content":"","role":"assistant"},"logprobs":null,"index":0}],"model":"openai/gpt-oss-120b","x_groq":{"id":"req_01kr7hzv18f4n88yzfe5t9ea31","seed":2000738003},"id":"chatcmpl-ae0ea411-c5b4-4a52-8722-23ea0c484304","system_fingerprint":"fp_4140daa9c2"}"#
        let messages = ReviewSessionManager.reconstructedMessagesForTesting(from: [
            exchange(sequenceNumber: 1, question: roleOnlyChunk, answer: "Retrying", evaluation: "Real answer")
        ])

        #expect(messages.map { $0.content } == ["Retrying", "Real answer"])
    }

    @Test("a reopened memory review rebuilds its source headings between the verdict and the next question")
    @MainActor
    func reopenedMemoryReviewRebuildsSourceHeadings() {
        let mito = StudioArticle(url: "https://example.com/mito", title: "Precision Mitochondria", sourceType: .paper)
        let life = StudioArticle(url: "https://example.com/life", title: "What is life?", sourceType: .book)
        let opening = "Today starts with mitochondria.\n\n<flm_source_turn id=\"\(mito.id)\"/>\nWhat was the paper about?"
        let verdictAndTurn = "You recovered the goal.\n\n<flm_source_turn id=\"\(life.id)\"/>\nWhat was the book about?"
        let exchanges = [
            exchange(sequenceNumber: 1, question: opening, answer: "we can engineer them", evaluation: verdictAndTurn),
            exchange(sequenceNumber: 2, question: verdictAndTurn, answer: "not sure", evaluation: "Nothing came back yet."),
        ]

        let rows = ReviewSessionManager.reconstructedTranscriptForTesting(from: exchanges, articles: [mito, life])

        #expect(rows.map(\.role) == ["assistant", "tool", "assistant", "user", "assistant", "tool", "assistant", "user", "assistant"])
        #expect(rows.map(\.sourceTurnID) == [nil, mito.id, nil, nil, nil, life.id, nil, nil, nil])
        #expect(rows.map(\.content) == [
            "Today starts with mitochondria.", "", "What was the paper about?",
            "we can engineer them",
            "You recovered the goal.", "", "What was the book about?",
            "not sure",
            "Nothing came back yet.",
        ])
        #expect(ReviewSessionManager.currentMemorySourceID(from: exchanges) == life.id)
        #expect(ReviewSessionManager.lastAssistantReplyText(from: exchanges) == "Nothing came back yet.")
        #expect(ReviewSessionManager.lastAssistantReplyText(from: [exchanges[0]]) == verdictAndTurn)
    }

    @Test("a reopened chat's last reply, which the next question and the grader read, leaves out its pages' and saved cards' lines")
    @MainActor
    func reopenedLastReplyLeavesOutTheStoredLines() {
        let page = ChatWrittenPage(id: "doc-1", title: "Cristae notes")
        let cards = ChatSavedCards(cardIDs: ["c-1", "c-2"], sourceIDs: ["src-1"])
        let reply = "I wrote it up.\n\nWhat do the cristae hold?"
        let stored = ChatWrittenPage.storing(ChatSavedCards.storing(reply, with: cards), with: [page])
        // An opening turn keeps its lines in the question.
        #expect(ReviewSessionManager.lastAssistantReplyText(from: [
            exchange(sequenceNumber: 1, question: stored, answer: nil, evaluation: nil),
        ]) == reply)
        #expect(ReviewSessionManager.lastAssistantReplyText(from: [
            exchange(sequenceNumber: 1, question: "Hi", answer: "write it up", evaluation: stored),
        ]) == reply)
        // A reply that is nothing but a page's line says nothing in words: the
        // question before it is the last thing said.
        #expect(ReviewSessionManager.lastAssistantReplyText(from: [
            exchange(sequenceNumber: 1, question: "Shall I?", answer: "yes", evaluation: page.markdownLine),
        ]) == "Shall I?")
    }

    @Test("a turn line naming a source outside the review is dropped and its neighbours merge")
    @MainActor
    func unknownSourceTurnIsDropped() {
        let known = StudioArticle(url: "https://example.com/known", title: "Known", sourceType: .article)
        let rows = ReviewSessionManager.reconstructedTranscriptForTesting(
            from: [exchange(sequenceNumber: 1, question: "Before.\n\n<flm_source_turn id=\"nope\"/>\nAfter.", answer: nil, evaluation: nil)],
            articles: [known]
        )
        #expect(rows.map(\.role) == ["assistant"])
        #expect(rows.first?.content == "Before.\n\nAfter.")
        #expect(ReviewSessionManager.displayableMessageContent(
            role: .assistant,
            content: "Before.\n\n<flm_source_turn id=\"nope\"/>\nAfter."
        ) == "Before.\n\nAfter.")
        #expect(ReviewSessionManager.displayableMessageContent(role: .assistant, content: "<flm_source_turn id=\"x\"/>") == nil)
    }

    @Test("a source heading is its own transcript entry, never folded into a tool disclosure")
    @MainActor
    func sourceHeadingStandsAlone() {
        let article = StudioArticle(url: "https://example.com/a", title: "A", sourceType: .article)
        let presentation = ReviewSessionManager.Message.ToolActivity.SourcePresentation(source: article)
        let search = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(toolName: "search_sources_semantic", detail: "q", state: .succeeded, resultPreview: nil)
        )
        let heading = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(
                kind: .sourceTurn,
                toolName: ReviewSessionManager.sourceTurnActivityName,
                detail: nil,
                sourcePresentation: presentation,
                state: .succeeded,
                resultPreview: nil,
                customTitle: "Now reviewing: A"
            )
        )
        let read = ReviewSessionManager.Message(
            role: .tool,
            content: "",
            toolActivity: .init(toolName: "get_source_content", detail: "A", state: .succeeded, resultPreview: nil)
        )
        let question = ReviewSessionManager.Message(role: .assistant, content: "What was it about?")

        let entries = ReviewChatTranscriptEntry.grouping([search, heading, read, question])

        #expect(entries.count == 4)
        #expect(entries[0].activities.map(\.toolName) == ["search_sources_semantic"])
        #expect(entries[1].sourceTurn?.id == article.id)
        #expect(entries[2].activities.map(\.toolName) == ["get_source_content"])
        #expect(entries[3].message?.content == "What was it about?")
        #expect(ReviewSessionManager.copiedAnswerText(from: [search, heading, question])
            .contains("Now reviewing: A"))
    }

    @Test("resumed payload skips raw provider metadata")
    @MainActor
    func resumedPayloadSkipsRawProviderMetadata() {
        let roleOnlyChunk = #"{"created":1778370210,"object":"chat.completion.chunk","choices":[{"finish_reason":null,"delta":{"content":"","role":"assistant"},"logprobs":null,"index":0}],"model":"openai/gpt-oss-120b","id":"chatcmpl-ae0ea411-c5b4-4a52-8722-23ea0c484304"}"#
        let payload = ReviewSessionManager.resumedPayloadForTesting(
            messages: [
                (role: "assistant", content: roleOnlyChunk),
                (role: "user", content: "Please continue."),
            ],
            systemPrompt: "Tutor prompt."
        )

        #expect(payload.messages.map { $0.content } == ["Please continue."])
    }

    @Test("an attached Doc reaches the prompt as identity and outline, never as a body copy")
    @MainActor
    func attachedDocReachesPromptWithoutItsBody() {
        let prompt = ReviewSessionManager.attachedDocsPromptForTesting(
            docs: [ChatDocAttachment(
                id: "artifact-a",
                title: "The Landscape of Mitochondrial Therapeutics",
                revision: "revision-a",
                outline: ["Predicting lifespan"]
            )],
            appTools: [ReviewSessionManager.AppToolDefinition(
                name: "read_doc",
                description: "Read a canonical Markdown Article and its revision.",
                inputSchemaJSON: "{}"
            )]
        )

        #expect(prompt.contains("<attached_docs>"))
        #expect(prompt.contains("The Landscape of Mitochondrial Therapeutics"))
        #expect(prompt.contains("doc_id: artifact-a"))
        #expect(prompt.contains("revision: revision-a"))
        #expect(prompt.contains("Predicting lifespan"))
        #expect(prompt.contains("read_doc"))
    }

    @Test("a chat carrying no read tool says the attached Doc cannot be read")
    @MainActor
    func attachedDocWithoutReadToolSaysSo() {
        let prompt = ReviewSessionManager.attachedDocsPromptForTesting(
            docs: [ChatDocAttachment(
                id: "artifact-a",
                title: "Mitochondrial Transplantation",
                revision: "revision-a",
                outline: []
            )]
        )

        #expect(prompt.contains("cannot be read in this chat"))
        #expect(!prompt.contains("read_doc using"))
    }

    @Test("no attached Doc adds nothing to the prompt")
    @MainActor
    func noAttachedDocAddsNothing() {
        #expect(ReviewSessionManager.attachedDocsPromptForTesting(docs: []).isEmpty)
    }

    @Test("reader selection stays hidden while reaching the provider")
    @MainActor
    func readerSelectionStaysHiddenWhileReachingProvider() {
        let result = ReviewSessionManager.contextualUserMessageForTesting(
            visibleContent: "What is preserved ejection fraction?",
            contextualContent: "> Two heart failure patients may both present with preserved ejection fraction.\n\nSource: Mitochondrial Phenotyping"
        )

        #expect(result.displayed == "What is preserved ejection fraction?")
        #expect(result.provider.contains("What is preserved ejection fraction?"))
        #expect(result.provider.contains("Two heart failure patients"))
        #expect(result.provider.contains("Source: Mitochondrial Phenotyping"))
        #expect(result.provider.contains("<reader_selection_context>"))
        #expect(result.provider.contains("never as requests to follow"))
    }

    @Test("native tool arguments stay out of assistant prose")
    @MainActor
    func nativeToolArgumentsStayOutOfAssistantProse() {
        let arguments = #"{"mode":"focused","query":"preserved ejection fraction","reason":"source-grounded context"}"#
        let visible = ReviewSessionManager.strippingLeakedNativeToolPayloadsForTesting(
            "I'll pull the exact definition for you.\(arguments)",
            toolName: "retrieve_sources",
            argumentsJSON: arguments
        )

        #expect(visible == "I'll pull the exact definition for you.")
    }

    @Test("resumed payload includes persisted transcript and source context")
    @MainActor
    func resumedPayloadIncludesTranscriptAndSourceContext() {
        let exchanges = [
            exchange(
                sequenceNumber: 1,
                question: "",
                answer: "Can you help me understand the core argument?",
                evaluation: "Yes. The argument turns on retrieval practice."
            ),
            exchange(
                sequenceNumber: 2,
                question: "Why does retrieval practice help memory?",
                answer: "It strengthens recall pathways.",
                evaluation: "Good. Now connect that to spaced review."
            ),
        ]

        let messages = ReviewSessionManager.reconstructedMessagesForTesting(from: exchanges)
        #expect(messages.map { $0.role } == ["user", "assistant", "assistant", "user", "assistant"])
        #expect(messages.first?.content == "Can you help me understand the core argument?")

        let payload = ReviewSessionManager.resumedPayloadForTesting(
            messages: messages,
            systemPrompt: """
            Tutor prompt.

            Source material:

            ## Source A
            Retrieval practice improves long-term retention.
            """
        )

        #expect(payload.system.contains("Source material:"))
        #expect(payload.system.contains("Continue seamlessly"))
        #expect(payload.messages.map { $0.role } == ["user", "assistant", "user", "assistant"])
        #expect(payload.messages[0].content == messages[0].content)
        #expect(payload.messages[1].content.contains("Yes. The argument turns on retrieval practice."))
        #expect(payload.messages[1].content.contains("Why does retrieval practice help memory?"))
        #expect(payload.messages[2].content == "It strengthens recall pathways.")
        #expect(payload.messages[3].content == "Good. Now connect that to spaced review.")
    }

    @Test("an explicitly loaded source carries its full text, not an excerpt")
    @MainActor
    func explicitlyLoadedSourceCarriesFullText() async {
        var article = StudioArticle(
            url: "https://example.com/full-source",
            title: "Full Source",
            sourceType: .article,
            id: "full-source"
        )
        article.content = "source-start " + String(repeating: "full source detail ", count: 2_200) + "source-tail"

        let context = await ReviewSessionManager.sourceContextContentForTesting(articles: [article])

        #expect(context.contains("## Source 1: Full Source"))
        #expect(context.contains("source-start"))
        #expect(context.contains("source-tail"))
        #expect(!context.contains("Source text truncated"))
        // The catalog rides in the retrieval instruction now, not at the head
        // of the loaded text — carrying it in both places sent it twice.
        #expect(!context.contains("Attached sources (1):"))
    }

    @Test("dropping a Notebook pool source loads it into chat context")
    @MainActor
    func droppingAttachedPoolSourceLoadsIt() async {
        var first = StudioArticle(
            url: "https://example.com/first",
            title: "First source",
            sourceType: .article,
            id: "first"
        )
        first.content = "first source body"
        var dropped = StudioArticle(
            url: "https://example.com/dropped",
            title: "Dropped source",
            sourceType: .article,
            id: "dropped"
        )
        dropped.content = "explicitly dropped body"

        let result = await ReviewSessionManager.droppedSourceContextForTesting(
            attachedArticles: [first, dropped],
            droppedArticles: [dropped]
        )

        #expect(result.loadedIDs == ["dropped"])
        #expect(result.context.contains("explicitly dropped body"))
        #expect(!result.context.contains("first source body"))
    }

    @Test("an idle composer drop remains loaded when the session attaches its pool")
    @MainActor
    func idleDropSurvivesSessionAttachment() async {
        var poolSource = StudioArticle(
            url: "https://example.com/pool",
            title: "Pool source",
            sourceType: .article,
            id: "pool"
        )
        poolSource.content = "catalog-only pool body"
        var dropped = StudioArticle(
            url: "https://example.com/idle-drop",
            title: "Idle drop",
            sourceType: .article,
            id: "idle-drop"
        )
        dropped.content = "idle drop survives"

        let result = await ReviewSessionManager.droppedSourceContextForTesting(
            attachedArticles: [poolSource, dropped],
            droppedArticles: [dropped],
            stageBeforeAttachment: true
        )

        #expect(result.loadedIDs == ["idle-drop"])
        #expect(result.context.contains("idle drop survives"))
        #expect(!result.context.contains("catalog-only pool body"))
    }

    @Test("loading several sources keeps every one of them whole when the budget allows")
    @MainActor
    func loadingSeveralSourcesKeepsEachWhole() async {
        let articles = (1...12).map { index in
            var article = StudioArticle(
                url: "https://example.com/source-\(index)",
                title: "Source \(index)",
                sourceType: .article,
                id: "source-\(index)"
            )
            if index == 1 {
                article.content = String(repeating: "long intro section ", count: 3_000)
            } else {
                article.content = "unique source-\(index) marker for source context fairness."
            }
            return article
        }

        let context = await ReviewSessionManager.sourceContextContentForTesting(articles: articles)

        #expect(context.contains("## Source 1: Source 1"))
        #expect(context.contains("## Source 9: Source 9"))
        #expect(context.contains("## Source 12: Source 12"))
        #expect(context.contains("unique source-12 marker"))
        #expect(context.count <= 200_000)
    }

    @Test("attaching a pool contributes catalog lines and no source text")
    @MainActor
    func attachingPoolContributesCatalogOnly() async {
        // The behavior the whole lazy-loading design rests on: attaching a
        // Notebook's sources must make them findable without putting a single
        // character of their text in the prompt.
        let articles = (1...40).map { index in
            var article = StudioArticle(
                url: "https://example.com/pool-\(index)",
                title: "Pool Source \(index)",
                sourceType: .article,
                id: "pool-\(index)"
            )
            article.content = "secret-body-\(index) " + String(repeating: "pool detail ", count: 500)
            return article
        }

        let manifest = await ReviewSessionManager.sourceManifestForTesting(articles: articles)

        #expect(manifest.contains("Attached sources (40):"))
        #expect(manifest.contains("Pool Source 1"))
        #expect(manifest.contains("Pool Source 40"))
        for index in 1...40 {
            #expect(!manifest.contains("secret-body-\(index)"))
        }
    }

    @Test("catalog lines carry the metadata the model selects on")
    @MainActor
    func catalogLinesCarrySelectionMetadata() async {
        var paper = StudioArticle(
            url: "https://example.com/paper",
            title: "Mitochondrial signal transduction",
            sourceType: .paper,
            id: "paper-1"
        )
        paper.author = "Martin Picard and Orian S. Shirihai"
        paper.journal = "Cell Metabolism"
        paper.publishedYear = "2022"
        paper.content = String(repeating: "mitochondrial detail ", count: 200)

        var chapter = StudioArticle(
            url: "https://example.com/chapter",
            title: "All Cells Use Proteins as Catalysts",
            sourceType: .book,
            id: "chapter-1"
        )
        chapter.parentGroup = "Molecular Biology of the Cell"
        chapter.content = String(repeating: "chapter detail ", count: 50)

        let manifest = await ReviewSessionManager.sourceManifestForTesting(articles: [paper, chapter])

        #expect(manifest.contains("Cell Metabolism"))
        #expect(manifest.contains("2022"))
        // Naming the book is what tells the model it can pull one chapter
        // instead of the entire textbook.
        #expect(manifest.contains("in Molecular Biology of the Cell"))
    }

    @Test("source manifest lists attached sources without requiring excerpts")
    @MainActor
    func sourceManifestListsAttachedSourcesWithoutRequiringExcerpts() async {
        let articles = (1...3).map { index in
            StudioArticle(
                url: "https://example.com/source-\(index)",
                title: "Source \(index)",
                sourceType: .article,
                id: "source-\(index)"
            )
        }

        let manifest = await ReviewSessionManager.sourceManifestForTesting(articles: articles)

        #expect(manifest.contains("Attached sources (3):"))
        #expect(manifest.contains("Source 1"))
        #expect(manifest.contains("source-3"))
        #expect(manifest.contains("no text available"))
    }

    @Test("a semantic hit centres the excerpt on the matched passage")
    @MainActor
    func semanticHitCentresExcerptOnMatchedPassage() {
        // The passage shares no literal terms with the question, which is the
        // ordinary case for a conceptual query and precisely where keyword
        // excerpting fails: it cannot find the answer, so it returns the top
        // of the document instead.
        let words = (0..<900).map { $0 == 500 ? "MARKERTOKEN" : "filler" }
        let content = words.joined(separator: " ")
        let question = "what does this source say about the mechanism"

        let centred = ReviewSessionManager.focusedExcerptForTesting(
            content: content,
            query: question,
            limit: 1_500,
            bestChunkID: "src::chunk::0005"
        )
        #expect(centred.contains("MARKERTOKEN"))
        #expect(centred.count <= 1_500)

        let keywordOnly = ReviewSessionManager.focusedExcerptForTesting(
            content: content,
            query: question,
            limit: 1_500,
            bestChunkID: nil
        )
        #expect(!keywordOnly.contains("MARKERTOKEN"))
        #expect(!keywordOnly.localizedCaseInsensitiveContains("truncated"))
        #expect(keywordOnly.contains("does not establish that the query is absent"))
        #expect(keywordOnly.count <= 1_500)
    }

    @Test("the ranker audits a named-source retrieval instead of deferring to it")
    @MainActor
    func namedSourceRetrievalIsAuditedAgainstTheRanker() {
        // The failure this guards: a model choosing from a catalog sees titles
        // and little else, so a chapter whose title does not imply its contents
        // is invisible to it. Naming ids used to bypass the ranker outright,
        // which made that guess final. Here the ranker put "replacement" second
        // and the model named three chapters it ranked below.
        let ranked = ["deadEnds", "replacement", "speculations", "bioengineering", "aging", "cells"]

        let leads = ReviewSessionManager.crossCheckSelectionForTesting(
            rankedIDs: ranked,
            requested: ["deadEnds", "bioengineering", "aging"],
            limit: 2
        )

        // Ranks above "aging", the worst-ranked source the model named.
        #expect(leads == ["replacement", "speculations"])
    }

    @Test("choosing the top of the ranking adds no leads")
    @MainActor
    func wellChosenRetrievalIsNotSecondGuessed() {
        let ranked = ["a", "b", "c", "d"]

        // Nothing outranks the model's worst pick, so the audit is silent and
        // a good choice costs no budget.
        #expect(ReviewSessionManager.crossCheckSelectionForTesting(
            rankedIDs: ranked,
            requested: ["a", "b"],
            limit: 2
        ).isEmpty)

        // The single best source is likewise left alone.
        #expect(ReviewSessionManager.crossCheckSelectionForTesting(
            rankedIDs: ranked,
            requested: ["a"],
            limit: 2
        ).isEmpty)
    }

    @Test("a named source the ranker cannot score leaves the whole ranking eligible")
    @MainActor
    func unscoredNamedSourceKeepsEveryLeadEligible() {
        // A source absent from the ranking did not match the query at all, so
        // it is no evidence the model chose well. The bar cannot be read off it.
        let leads = ReviewSessionManager.crossCheckSelectionForTesting(
            rankedIDs: ["a", "b", "c"],
            requested: ["unranked"],
            limit: 2
        )
        #expect(leads == ["a", "b"])

        // An empty ranking (no query, or embedding unavailable) adds nothing
        // rather than guessing.
        #expect(ReviewSessionManager.crossCheckSelectionForTesting(
            rankedIDs: [],
            requested: ["a"],
            limit: 2
        ).isEmpty)

        // A query-only retrieval has no named set to audit against.
        #expect(ReviewSessionManager.crossCheckSelectionForTesting(
            rankedIDs: ["a", "b"],
            requested: [],
            limit: 2
        ).isEmpty)
    }

    @Test("a stale chunk id falls back to keyword excerpting instead of failing")
    @MainActor
    func staleChunkIDFallsBackToKeywordExcerpt() {
        // The indexer resolves a source's text through its own path, so a
        // source re-extracted since indexing can produce a chunk index past
        // the end. That is a miss, not an error.
        let content = (0..<300).map { _ in "filler" }.joined(separator: " ")

        let excerpt = ReviewSessionManager.focusedExcerptForTesting(
            content: content,
            query: "filler",
            limit: 300,
            bestChunkID: "src::chunk::9999"
        )

        #expect(!excerpt.isEmpty)
        #expect(!excerpt.contains("centred on the passage"))
    }

    @Test("focused retrieval finds a late exact transcript term when the semantic index misses")
    @MainActor
    func focusedRetrievalFindsLateExactTranscriptTerm() {
        let prefix = String(repeating: "Earlier discussion about mitochondria and energy. ", count: 900)
        let discussion = "But to your point about supplements, I was a student when SS31 was discovered. The trials have mostly been negative."
        let suffix = String(repeating: " Later discussion about metabolism. ", count: 400)

        let excerpt = ReviewSessionManager.focusedExcerptForTesting(
            content: prefix + discussion + suffix,
            query: "SS-31 / elamipretide",
            limit: 1_500,
            bestChunkID: nil
        )

        #expect(excerpt.contains("SS31 was discovered"))
        #expect(excerpt.contains("trials have mostly been negative"))
        #expect(!excerpt.hasPrefix("Earlier discussion"))
        #expect(excerpt.count <= 1_500)
    }

    @Test("exact transcript identifiers outrank incidental prose matches")
    @MainActor
    func exactTranscriptIdentifiersOutrankIncidentalProseMatches() {
        let intro = "Martin Picard joins us. " + String(repeating: "General introduction. ", count: 500)
        let answer = "Hazel Szeto discovered SS31, which was later commercialized as a stealth peptide."
        let content = intro + answer + String(repeating: " Closing discussion. ", count: 300)

        let excerpt = ReviewSessionManager.focusedExcerptForTesting(
            content: content,
            query: "what does Picard say about SS-31?",
            limit: 1_200,
            bestChunkID: nil
        )

        #expect(excerpt.contains("Hazel Szeto discovered SS31"))
        #expect(!excerpt.hasPrefix("Martin Picard joins us"))
    }

    @Test("the catalog is byte-identical across rebuilds so it stays cached")
    @MainActor
    func catalogIsStableAcrossRebuilds() async {
        // The catalog sits in the cached stable prefix. Anything that renders
        // differently between turns — a timestamp, live read state — would
        // cost a full cache miss on every request of the session.
        var article = StudioArticle(
            url: "https://example.com/stable",
            title: "Stable Source",
            sourceType: .paper,
            id: "stable-1"
        )
        article.author = "A. Researcher"
        article.publishedYear = "2024"
        article.content = String(repeating: "stable detail ", count: 100)

        let first = await ReviewSessionManager.sourceManifestForTesting(articles: [article])
        let second = await ReviewSessionManager.sourceManifestForTesting(articles: [article])

        #expect(first == second)
    }

    @Test("assistant-first resumed transcript is normalized for every provider")
    @MainActor
    func assistantFirstResumedTranscriptIsNormalizedForEveryProvider() {
        let payload = ReviewSessionManager.resumedPayloadForTesting(
            messages: [
                (role: "assistant", content: "What is retrieval practice?"),
                (role: "user", content: "Trying to remember without looking."),
                (role: "assistant", content: "Good. Why does that help?"),
                (role: "user", content: "It strengthens recall."),
            ],
            systemPrompt: "Tutor prompt."
        )

        #expect(payload.messages.map { $0.role } == ["user", "assistant", "user", "assistant", "user"])
        #expect(payload.messages.first?.content.contains("Continue this existing ForeverLM chat") == true)
        #expect(payload.messages[1].content == "What is retrieval practice?")
        #expect(payload.messages.last?.content == "It strengthens recall.")
    }

    @Test("long resumed payload compacts older turns and keeps recent turns")
    @MainActor
    func longResumedPayloadCompactsOlderTurns() {
        let messages = (0..<24).map { index in
            (
                role: index.isMultiple(of: 2) ? "assistant" : "user",
                content: "turn-\(index)"
            )
        }

        let payload = ReviewSessionManager.resumedPayloadForTesting(
            messages: messages,
            systemPrompt: "Tutor prompt."
        )

        #expect(payload.system.contains("Earlier transcript compact:"))
        #expect(payload.system.contains("Tutor: turn-0"))
        #expect(payload.messages.count == 21)
        #expect(payload.messages.first?.role == "user")
        #expect(payload.messages.first?.content.contains("Continue this existing ForeverLM chat") == true)
        #expect(payload.messages[1].content == "turn-4")
        #expect(payload.messages.last?.content == "turn-23")
    }

    @Test("session links and exchanges preserve source IDs for later resume")
    func sessionLinksAndExchangesPreserveSourceIDs() throws {
        let store = try KnowledgeStore(inMemory: true)
        var article = StudioArticle(
            url: "https://example.com/source",
            title: "Source",
            sourceType: .article,
            id: "source-1"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.insertSourceIfNew(&article)

        try store.createReviewSession(
            id: "session-1",
            topic: "Source review",
            sourceIDs: [article.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.addReviewExchange(
            sessionID: "session-1",
            question: "What is the source about?",
            answer: "Retrieval practice.",
            evaluation: "Correct.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: [article.id],
            answeredAt: Date(timeIntervalSinceReferenceDate: 110)
        )

        let session = try #require(store.loadReviewSessionLinks().first { $0.id == "session-1" })
        #expect(session.sourceIDs == [article.id])

        let exchanges = try store.loadReviewSessionExchanges(sessionID: "session-1")
        #expect(exchanges.first?.sourceRefs == [article.id])
    }

    @Test("session title update is persisted")
    func sessionTitleUpdateIsPersisted() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "session-1",
            topic: "Selected sources",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        try store.updateReviewSessionTitle(sessionID: "session-1", title: "Mitochondrial aging")

        let session = try #require(store.loadReviewSessionLinks().first { $0.id == "session-1" })
        #expect(session.title == "Mitochondrial aging")
    }

    @Test("AI-suggested title replaces only the provisional echoed title")
    func suggestedTitleReplacesOnlyProvisionalTitle() throws {
        let store = try KnowledgeStore(inMemory: true)
        let echoed = "why do mitochondria decline with age"
        try store.createReviewSession(
            id: "session-1",
            topic: echoed,
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        // Renamed from the rail while the first reply was still streaming.
        try store.updateReviewSessionTitle(sessionID: "session-1", title: "Aging notes")

        let clobbered = try store.replaceProvisionalReviewSessionTitle(
            sessionID: "session-1",
            provisionalTitle: echoed,
            title: "Mitochondrial decline in aging"
        )
        #expect(clobbered == false)
        var session = try #require(store.loadReviewSessionLinks().first { $0.id == "session-1" })
        #expect(session.title == "Aging notes")

        // Without a rename the suggestion lands as before.
        try store.createReviewSession(
            id: "session-2",
            topic: echoed,
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let replaced = try store.replaceProvisionalReviewSessionTitle(
            sessionID: "session-2",
            provisionalTitle: echoed,
            title: "Mitochondrial decline in aging"
        )
        #expect(replaced == true)
        session = try #require(store.loadReviewSessionLinks().first { $0.id == "session-2" })
        #expect(session.title == "Mitochondrial decline in aging")
    }

    @Test("assistant-only first question is persisted for resume")
    @MainActor
    func assistantOnlyFirstQuestionIsPersistedForResume() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "session-1",
            topic: "Source review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        try store.addReviewPrompt(
            sessionID: "session-1",
            question: "Review plan\n\nQuestion 1: Why does this matter?",
            sourceRefs: ["source-1"]
        )

        let exchanges = try store.loadReviewSessionExchanges(sessionID: "session-1")
        #expect(exchanges.count == 1)
        #expect(exchanges[0].userAnswer == nil)
        #expect(exchanges[0].evaluation == nil)

        let messages = ReviewSessionManager.reconstructedMessagesForTesting(from: exchanges)
        #expect(messages.map { $0.role } == ["assistant"])
        #expect(messages.first?.content.contains("Question 1") == true)
    }

    @Test("memory review target queue survives a crash before its first grade")
    func memoryReviewQueueSurvivesCrashBeforeFirstGrade() throws {
        let store = try KnowledgeStore(inMemory: true)
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let dueExcerpt = "Retrieval strengthens later access more than passive rereading."
        var dueSource = StudioArticle(
            url: "https://example.com/due-review",
            title: "Due review source",
            id: "source-due"
        )
        dueSource.content = dueExcerpt
        dueSource.state = .ready
        try store.saveSource(dueSource)
        var firstReviewSource = StudioArticle(
            url: "https://example.com/first-review",
            title: "First review source",
            id: "source-first"
        )
        firstReviewSource.content = "A first-review source remains resolvable after a crash."
        firstReviewSource.state = .ready
        try store.saveSource(firstReviewSource)
        let item = MemoryItem(
            id: "memory-due",
            kind: .concept,
            target: "Explain why retrieval improves later access",
            rubricJSON: #"{"criteria":["Distinguishes retrieval from rereading"]}"#,
            sources: [
                MemoryItemSource(
                    id: "anchor-due",
                    memoryItemID: "memory-due",
                    sourceID: "source-due",
                    excerpt: dueExcerpt,
                    sourceSHA256: PaperContentPreparationService.sha256(dueExcerpt),
                    sortIndex: 0
                ),
            ],
            createdAt: now,
            updatedAt: now
        )
        try store.saveMemoryItem(item)
        let portableFirstReviewKey = MemoryTutorIdentity.portableSourceKey(
            sourceID: "source-first",
            normalizedURL: "https://example.com/first-review"
        )
        let targetIDs = [item.id, "first-review:\(portableFirstReviewKey)"]
        try store.createReviewSession(
            id: "memory-resume",
            topic: "Daily memory check",
            sourceIDs: ["source-due", "source-first"],
            cardIDs: targetIDs,
            startedAt: now
        )
        try store.addReviewPrompt(
            sessionID: "memory-resume",
            question: "Why is retrieval different from rereading?",
            sourceRefs: ["source-due"]
        )

        #expect(try store.loadReviewSessionCardIDs(sessionID: "memory-resume") == targetIDs)
        #expect(try store.deleteReviewSessionIfNoRecordedConversation("memory-resume") == false)
        #expect(try store.loadMemoryAttempts(sessionID: "memory-resume").isEmpty)

        let session = try #require(
            store.loadReviewSessionLinks().first { $0.id == "memory-resume" }
        )
        let storedItem = try #require(try store.loadMemoryItem(item.id))
        let restored = try #require(
            try ReviewSessionManager.restoredMemoryCompanionStateForTesting(
                targetIDs: targetIDs,
                items: [storedItem],
                attempts: [],
                session: session,
                firstReviewSourceIDsByPortableKey: [
                    portableFirstReviewKey: "source-first",
                ]
            )
        )
        #expect(restored.plan.targets.map(\.id) == [item.id, "first-review:source-first"])
        #expect(restored.plan.targets.map(\.reason) == [.due, .firstReview])
        #expect(restored.currentTargetIndex == 0)
        #expect(restored.needsRetry == false)

        #expect(throws: (any Error).self) {
            try ReviewSessionManager.restoredMemoryCompanionStateForTesting(
                targetIDs: ["missing-memory-item"],
                items: [],
                attempts: [],
                session: session
            )
        }
    }

    @Test("opening an abandoned review removes it and queues its sync deletion")
    func abandonedReviewIsRemovedAtomically() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "session-1",
            topic: "Source review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.addReviewPrompt(
            sessionID: "session-1",
            question: "Question 1: Why does this matter?",
            sourceRefs: []
        )

        let deleted = try store.deleteReviewSessionIfNoRecordedConversation("session-1")

        #expect(deleted)
        #expect(try store.loadReviewSessionLinks().contains { $0.id == "session-1" } == false)
        #expect(try store.loadReviewSessionExchanges(sessionID: "session-1").isEmpty)
        let change = try store.pendingSyncChanges().first {
            $0.entity == .reviewSession && $0.logicalKey == "session-1"
        }
        let metadata = try store.loadSyncMetadata(entity: .reviewSession, logicalKey: "session-1")
        #expect(change?.operation == .delete)
        #expect(metadata?.isDeleted == true)
    }

    @Test("explicit chat deletion removes its transcript and queues one sync tombstone")
    func explicitChatDeletionIsAtomic() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "session-1",
            topic: "Source review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.addReviewExchange(
            sessionID: "session-1",
            question: "What is retrieval practice?",
            answer: "Trying to remember without looking.",
            evaluation: "Correct.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: [],
            answeredAt: Date(timeIntervalSinceReferenceDate: 110)
        )

        try store.deleteReviewSession("session-1")

        #expect(try store.loadReviewSessionLinks().contains { $0.id == "session-1" } == false)
        #expect(try store.loadReviewSessionExchanges(sessionID: "session-1").isEmpty)
        let changes = try store.pendingSyncChanges().filter {
            $0.entity == .reviewSession && $0.logicalKey == "session-1"
        }
        let metadata = try store.loadSyncMetadata(entity: .reviewSession, logicalKey: "session-1")
        #expect(changes.count == 1)
        #expect(changes.first?.operation == .delete)
        #expect(metadata?.isDeleted == true)
    }

    @Test("reviews with a learner response are never auto-removed")
    func answeredReviewIsNotRemoved() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "session-1",
            topic: "Source review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.addReviewExchange(
            sessionID: "session-1",
            question: "What is retrieval practice?",
            answer: "Trying to remember without looking.",
            evaluation: "Correct.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: [],
            answeredAt: Date(timeIntervalSinceReferenceDate: 110)
        )

        let deleted = try store.deleteReviewSessionIfNoRecordedConversation("session-1")

        #expect(deleted == false)
        #expect(try store.loadReviewSessionLinks().contains { $0.id == "session-1" })
        #expect(try store.loadReviewSessionExchanges(sessionID: "session-1").count == 1)
    }

    @Test("a learner message awaiting a failed reply is never auto-removed")
    func pendingLearnerMessageIsNotRemoved() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "failed-reply",
            topic: "Source review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.recordPendingReviewUserMessage(
            sessionID: "failed-reply",
            answer: "My explanation should survive the provider error.",
            sourceRefs: [],
            answeredAt: Date(timeIntervalSinceReferenceDate: 110)
        )

        let deleted = try store.deleteReviewSessionIfNoRecordedConversation("failed-reply")

        #expect(deleted == false)
        let exchange = try #require(
            try store.loadReviewSessionExchanges(sessionID: "failed-reply").first
        )
        #expect(exchange.userAnswer == "My explanation should survive the provider error.")
        #expect(exchange.evaluation == nil)
    }

    @Test("external review links are never auto-removed")
    func externalReviewLinkIsNotRemoved() throws {
        let store = try KnowledgeStore(inMemory: true)
        let session = try store.saveReviewSessionLink(
            title: "External review",
            url: "https://chatgpt.com/share/example"
        )

        let deleted = try store.deleteReviewSessionIfNoRecordedConversation(session.id)

        #expect(deleted == false)
        #expect(try store.loadReviewSessionLinks().contains { $0.id == session.id })
    }

    @Test("answering first question updates pending exchange")
    @MainActor
    func answeringFirstQuestionUpdatesPendingExchange() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "session-1",
            topic: "Source review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.addReviewPrompt(
            sessionID: "session-1",
            question: "Question 1: What is retrieval practice?",
            sourceRefs: ["source-1"]
        )

        let sequence = try store.answerPendingReviewExchange(
            sessionID: "session-1",
            answer: "Trying to remember without looking.",
            evaluation: "Good. Now connect that to spaced review.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: ["source-1"],
            answeredAt: Date(timeIntervalSinceReferenceDate: 110)
        )

        #expect(sequence == 1)
        let exchanges = try store.loadReviewSessionExchanges(sessionID: "session-1")
        #expect(exchanges.count == 1)
        #expect(exchanges[0].userAnswer == "Trying to remember without looking.")
        #expect(exchanges[0].evaluation == "Good. Now connect that to spaced review.")

        let messages = ReviewSessionManager.reconstructedMessagesForTesting(from: exchanges)
        #expect(messages.map { $0.role } == ["assistant", "user", "assistant"])
    }

    @Test("forking a chat clones only through the selected response")
    func forkingChatUsesIndependentPersistedIdentities() throws {
        let store = try KnowledgeStore(inMemory: true)
        var article = StudioArticle(
            url: "https://example.com/retrieval",
            title: "Retrieval source",
            sourceType: .article,
            id: "source-1"
        )
        article.normalizedURL = URLNormalizer.normalize(article.url)
        try store.insertSourceIfNew(&article)
        try store.createReviewSession(
            id: "original-session",
            topic: "Retrieval practice",
            sourceIDs: [article.id],
            startedAt: Date(timeIntervalSinceReferenceDate: 100),
            modelProvider: "openai",
            modelID: "gpt-test",
            goalID: "notebook-1"
        )
        try store.addReviewExchange(
            sessionID: "original-session",
            question: "What is retrieval practice?",
            answer: "Recalling without looking.",
            evaluation: "Correct.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: [article.id],
            answeredAt: Date(timeIntervalSinceReferenceDate: 110)
        )
        try store.addReviewExchange(
            sessionID: "original-session",
            question: "Why space it?",
            answer: "To make recall effortful.",
            evaluation: "Exactly.",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: [article.id],
            answeredAt: Date(timeIntervalSinceReferenceDate: 120)
        )

        let originalExchanges = try store.loadReviewSessionExchanges(sessionID: "original-session")
        let fork = try store.forkReviewSession(
            sessionID: "original-session",
            throughExchangeID: try #require(originalExchanges.first?.id),
            field: .evaluation,
            createdAt: Date(timeIntervalSinceReferenceDate: 130)
        )

        #expect(fork.id != "original-session")
        #expect(fork.title == "Retrieval practice — fork")
        #expect(fork.status == "active")
        #expect(fork.exchangeCount == 1)
        #expect(fork.goalID == "notebook-1")
        #expect(fork.modelID == "gpt-test")
        #expect(fork.sourceIDs == [article.id])

        let forkedExchanges = try store.loadReviewSessionExchanges(sessionID: fork.id)
        #expect(forkedExchanges.count == 1)
        #expect(forkedExchanges[0].id != originalExchanges[0].id)
        #expect(forkedExchanges[0].question == originalExchanges[0].question)
        #expect(forkedExchanges[0].userAnswer == originalExchanges[0].userAnswer)
        #expect(forkedExchanges[0].evaluation == originalExchanges[0].evaluation)
        #expect(forkedExchanges[0].sourceRefs == [article.id])
        #expect(try store.loadReviewSessionExchanges(sessionID: "original-session").count == 2)

        let pendingChange = try store.pendingSyncChanges().first {
            $0.entity == .reviewSession && $0.logicalKey == fork.id
        }
        #expect(pendingChange?.operation == .save)
    }

    @Test("deleting an in-app chat message updates the persisted exchange")
    @MainActor
    func deletingInAppChatMessageUpdatesPersistedExchange() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "session-1",
            topic: "Source review",
            sourceIDs: [],
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        try store.addReviewExchange(
            sessionID: "session-1",
            question: "Question 1",
            answer: "Answer 1",
            evaluation: "Evaluation 1",
            score: nil,
            knowledgeNote: nil,
            sourceRefs: [],
            answeredAt: Date(timeIntervalSinceReferenceDate: 110)
        )

        let exchangeID = try #require(store.loadReviewSessionExchanges(sessionID: "session-1").first?.id)
        try store.deleteReviewExchangeMessage(
            sessionID: "session-1",
            exchangeID: exchangeID,
            field: .userAnswer
        )

        var exchanges = try store.loadReviewSessionExchanges(sessionID: "session-1")
        #expect(exchanges.count == 1)
        #expect(exchanges[0].question == "Question 1")
        #expect(exchanges[0].userAnswer == nil)
        #expect(exchanges[0].evaluation == "Evaluation 1")

        let messages = ReviewSessionManager.reconstructedMessagesForTesting(from: exchanges)
        #expect(messages.map { $0.role } == ["assistant", "assistant"])

        try store.deleteReviewExchangeMessage(
            sessionID: "session-1",
            exchangeID: exchangeID,
            field: .question
        )
        try store.deleteReviewExchangeMessage(
            sessionID: "session-1",
            exchangeID: exchangeID,
            field: .evaluation
        )

        exchanges = try store.loadReviewSessionExchanges(sessionID: "session-1")
        #expect(exchanges.isEmpty)
        #expect(try store.loadReviewSessionLinks().first { $0.id == "session-1" }?.exchangeCount == 0)
    }

    private func collectEvents(from lines: [String]) -> [String] {
        var accumulator = AIStreamEventAccumulator()
        var events: [String] = []
        for line in lines {
            if let dataLines = accumulator.consume(line) {
                events.append(dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let dataLines = accumulator.finish() {
            events.append(dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return events
    }

    @discardableResult
    private func expectJSONObject(_ event: String) throws -> [String: Any] {
        let data = try #require(event.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func exchange(
        sequenceNumber: Int,
        question: String,
        answer: String?,
        evaluation: String?,
        contextContent: String? = nil
    ) -> ReviewExchangeRecord {
        ReviewExchangeRecord(
            id: "exchange-\(sequenceNumber)",
            sessionID: "session-1",
            sequenceNumber: sequenceNumber,
            question: question,
            userAnswer: answer,
            evaluation: evaluation,
            score: nil,
            sourceRefs: ["source-1"],
            knowledgeNote: nil,
            answeredAt: Date(timeIntervalSinceReferenceDate: TimeInterval(sequenceNumber)),
            contextContent: contextContent
        )
    }

    private func capturedRouterRequest(system: String) throws -> [String: Any] {
        var matched: [String: Any]?
        for body in RouterRequestCaptureURLProtocol.requestBodies() {
            guard let json = try? expectJSONObject(body),
                  let first = (json["messages"] as? [[String: Any]])?.first,
                  first["role"] as? String == "system" else { continue }
            let systemText: String?
            if let text = first["content"] as? String {
                systemText = text
            } else if let blocks = first["content"] as? [[String: Any]] {
                systemText = blocks.compactMap { $0["text"] as? String }.joined()
            } else {
                systemText = nil
            }
            if systemText == system {
                matched = json
                break
            }
        }
        return try #require(matched)
    }
}

#if canImport(AppKit) && canImport(PDFKit)
private func writeSearchablePDF(_ text: String, to url: URL) throws {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "ForeverLMTests", code: 1)
    }

    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (text as NSString).draw(
        at: NSPoint(x: 72, y: 700),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black
        ]
    )
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()

    try data.write(to: url, options: .atomic)
}
#endif

private final class ProviderStreamMockURLProtocol: URLProtocol {
    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStreamMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ai.foreverlm.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body(for: url).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(for url: URL) -> String {
        switch url.path {
        case let path where path.hasPrefix("/v1/proxy/openrouter/"):
            return """
            data: {"object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"OpenRouter answer."},"finish_reason":null}]}

            data: [DONE]

            """
        default:
            return ""
        }
    }
}

private final class RouterRequestCaptureURLProtocol: URLProtocol {
    private static let capturedBodies = LockedRequestBodies()

    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouterRequestCaptureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func requestBodies() -> [String] {
        capturedBodies.values()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ai.foreverlm.com"
            && request.url?.path.hasPrefix("/v1/proxy/openrouter/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let bodyText = Self.bodyText(for: request)
        Self.capturedBodies.append(bodyText)

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": Self.responseContentType(for: bodyText)]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseBody(for: bodyText).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func responseContentType(for bodyText: String) -> String {
        "application/json"
    }

    private static func responseBody(for bodyText: String) -> String {
        let answer = bodyText.contains("PDF title candidate:") ? "ALLOW" : "OpenRouter answer."
        return #"{"choices":[{"index":0,"message":{"role":"assistant","content":"\#(answer)"},"finish_reason":"stop"}]}"#
    }

    private static func bodyText(for request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }

        guard let stream = request.httpBodyStream else {
            return ""
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class LockedRequestBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []

    func append(_ body: String) {
        lock.lock()
        bodies.append(body)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        let copy = bodies
        lock.unlock()
        return copy
    }
}

@Suite("Attached Site chat")
@MainActor
struct AttachedSiteChatTests {
    @Test("an attached ForeverLM Site is fixed through its files at the same address")
    func attachedForeverLMSiteUsesSiteTools() {
        let tools = ["read_doc", "edit_doc", "read_site_file", "save_site"].map {
            ReviewSessionManager.AppToolDefinition(name: $0, description: $0, inputSchemaJSON: "{}")
        }
        let prompt = ReviewSessionManager.attachedDocsPromptForTesting(
            docs: [ChatDocAttachment(
                id: "site-a",
                title: "Mitochondrial phenotyping",
                revision: "rendered-copy-revision",
                outline: ["Proximal mitochondrial and cellular layers"],
                linkedURL: "foreverlm-site://site-a/"
            )],
            appTools: tools
        )

        #expect(prompt.contains("site_id: site-a"))
        #expect(prompt.contains("site_url: foreverlm-site://site-a/"))
        #expect(prompt.contains("read_site_file"))
        #expect(prompt.contains("save_site"))
        #expect(prompt.contains("same site"))
        #expect(prompt.contains("Never call edit_doc or write_doc on a linked_page_id or site_id"))
    }
}

/// A chat holds the sources the learner attached to it, and it holds them
/// across a reopen. Leaving a chat ends its session and reopening one rebuilds
/// the manager from SQLite, so before schema 104 every reopened chat came back
/// with its sources as catalog only: the paper dropped into a chat at five
/// o'clock was, once the chat had been filed under a Notebook and opened again,
/// a title the model had to ask for, and the composer counted nothing in
/// context. The product owner (2026-09-09): "if a source was attached to a chat; and then
/// i move the chat to a notebook and want to continue chatting; that source
/// should continue to be attached". These pin the storage contract, the
/// migration, and the one decision a reopen makes.
@Suite("Reopened chat keeps its sources")
struct ReviewSessionLoadedSourcesTests {

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func userVersion(at root: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var version: Int32 = -1
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return version
    }

    /// The junction table keys sources by id, so a session's sources must be
    /// rows before the session is created.
    private static func saveSources(_ ids: [String], in store: KnowledgeStore) throws {
        for id in ids {
            var article = StudioArticle(
                url: "https://example.com/\(id)",
                title: "Source \(id)",
                sourceType: .article,
                discoveryOrigin: .manual,
                id: id
            )
            article.domain = "example.com"
            try store.saveSource(article)
        }
    }

    private static func exchange(_ number: Int, question: String = "", answer: String? = nil, reply: String?) -> ReviewExchangeRecord {
        ReviewExchangeRecord(
            id: "exchange-\(number)",
            sessionID: "session",
            sequenceNumber: number,
            question: question,
            userAnswer: answer,
            evaluation: reply,
            score: nil,
            sourceRefs: [],
            knowledgeNote: nil,
            answeredAt: nil,
            contextContent: nil
        )
    }

    // MARK: - What a reopen loads

    @Test("A remembered loaded set is what comes back, trimmed to what is still attached")
    func rememberedSetWins() {
        let reload = ReviewSessionManager.sourceIDsToReloadOnResume(
            remembered: ["src-paper", "src-detached"],
            attached: ["src-paper", "src-pool-1", "src-pool-2"],
            // The transcript cites a pool source; the record, not the
            // transcript, says what was loaded.
            exchanges: [Self.exchange(1, reply: "See [Pool](foreverlm://source/src-pool-1).")]
        )
        #expect(reload == ["src-paper"])
    }

    @Test("A remembered empty set reopens catalog-only even when the transcript cites")
    func rememberedEmptySetStaysEmpty() {
        let reload = ReviewSessionManager.sourceIDsToReloadOnResume(
            remembered: [],
            attached: ["src-pool-1", "src-pool-2"],
            exchanges: [Self.exchange(1, reply: "See [Pool](foreverlm://source/src-pool-1).")]
        )
        #expect(reload.isEmpty)
    }

    @Test("A chat from before the loaded set was kept reopens on what it cited")
    func legacyChatReopensOnCitations() {
        let reload = ReviewSessionManager.sourceIDsToReloadOnResume(
            remembered: nil,
            attached: ["src-a", "src-b", "src-c"],
            exchanges: [
                Self.exchange(1, reply: "Plan: respirometry, then PBMCs."),
                Self.exchange(2, answer: "oxygen consumption", reply: "Yes. [Methods](foreverlm://source/src-b?t=12) and [Other](foreverlm://source/src-elsewhere)."),
            ]
        )
        // Cited and attached: yes. Cited but not attached: no. Attached but
        // never cited in a chat of several: catalog.
        #expect(reload == ["src-b"])
    }

    @Test("A legacy chat with one attached source reopens holding it even when no turn linked it")
    func legacySingleSourceChatReopensLoaded() {
        let reload = ReviewSessionManager.sourceIDsToReloadOnResume(
            remembered: nil,
            attached: ["src-paper"],
            exchanges: [Self.exchange(1, answer: "quiz me on this", reply: "### Review plan\n- [ ] Defining dysfunction")]
        )
        #expect(reload == ["src-paper"])
    }

    @Test("A legacy Notebook pool that cited nothing stays catalog")
    func legacyPoolStaysCatalog() {
        let reload = ReviewSessionManager.sourceIDsToReloadOnResume(
            remembered: nil,
            attached: (1...20).map { "src-\($0)" },
            exchanges: [Self.exchange(1, answer: "what is this Notebook about?", reply: "It gathers methods papers.")]
        )
        #expect(reload.isEmpty)
    }

    // MARK: - Storage

    @Test("The store keeps the loaded set beside the chat, and tells never-recorded from nothing-loaded")
    func storeKeepsLoadedSet() throws {
        let root = try Self.temporaryRoot("loaded-sources")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KnowledgeStore(storeDirectory: root)
        try Self.saveSources(["src-a", "src-b"], in: store)
        try store.createReviewSession(id: "chat", topic: "Methods", sourceIDs: ["src-a", "src-b"])

        #expect(try store.loadReviewSessionLoadedSourceIDs(sessionID: "chat") == nil)

        try store.clearAllPendingSyncChanges()
        try store.updateReviewSessionLoadedSources(sessionID: "chat", sourceIDs: ["src-b", "src-a"])
        #expect(try store.loadReviewSessionLoadedSourceIDs(sessionID: "chat") == ["src-b", "src-a"])
        // Local state: nothing is queued for CloudKit by remembering it.
        #expect(try store.pendingSyncChanges().isEmpty)

        try store.updateReviewSessionLoadedSources(sessionID: "chat", sourceIDs: [])
        #expect(try store.loadReviewSessionLoadedSourceIDs(sessionID: "chat") == [])

        #expect(try store.loadReviewSessionLoadedSourceIDs(sessionID: "missing") == nil)
    }

 }

/// Schema 149: a chat keeps the effort and speed its last reply was asked
/// for beside the model, so reopening it — after a relaunch or a rebuild as
/// much as within one run — goes on with the whole route (product owner,
/// 2026-09-28).
@Suite("a reopened chat keeps its effort and speed")
struct ChatModelTuningPersistenceTests {
    private static let provider = AIProvider.openRouter.rawValue
    private static let opus = "anthropic/claude-opus-5"
    private static let sonnet = "anthropic/claude-sonnet-4-6"

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func scalar(at root: URL, _ sql: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            root.appendingPathComponent("knowledge.db").path, &database, SQLITE_OPEN_READONLY, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private static func route(
        _ model: String, effort: AIEffort?, speed: AISpeed?
    ) -> ReviewSessionModelRoute {
        ReviewSessionModelRoute(
            modelProvider: provider, modelID: model,
            modelEffort: effort?.rawValue, modelSpeed: speed?.rawValue
        )
    }

    private static func createChat(
        _ id: String, in store: KnowledgeStore, effort: AIEffort? = .high, speed: AISpeed? = .fast
    ) throws {
        try store.createReviewSession(
            id: id,
            topic: "Membrane potential",
            sourceIDs: [],
            modelProvider: provider,
            modelID: opus,
            modelEffort: effort?.rawValue,
            modelSpeed: speed?.rawValue
        )
    }

    // MARK: - Storage

    @Test("The row keeps the effort and speed with the model, and a reply on the default clears them")
    func rowKeepsTuningWithModel() throws {
        let store = try KnowledgeStore(inMemory: true)
        try Self.createChat("chat", in: store)
        #expect(try store.loadReviewSessionModelRoute(sessionID: "chat") == Self.route(Self.opus, effort: .high, speed: .fast))

        try store.updateReviewSessionModel(
            sessionID: "chat", modelProvider: Self.provider, modelID: Self.opus,
            modelEffort: AIEffort.low.rawValue, modelSpeed: nil
        )
        #expect(try store.loadReviewSessionModelRoute(sessionID: "chat") == Self.route(Self.opus, effort: .low, speed: nil))

        // A reply on another model at its default names nothing, and the old
        // pick does not linger beside a model it was never made on.
        try store.updateReviewSessionModel(
            sessionID: "chat", modelProvider: Self.provider, modelID: Self.sonnet,
            modelEffort: nil, modelSpeed: nil
        )
        #expect(try store.loadReviewSessionModelRoute(sessionID: "chat") == Self.route(Self.sonnet, effort: nil, speed: nil))

        #expect(try store.loadReviewSessionModelRoute(sessionID: "missing") == nil)
    }

    @Test("A fork goes on with the effort and speed of the chat it was cut from")
    func forkKeepsTuning() throws {
        let store = try KnowledgeStore(inMemory: true)
        try Self.createChat("chat", in: store)
        _ = try store.addReviewExchange(
            sessionID: "chat", question: "Why does TMRM drop?", answer: "Uncoupling.",
            evaluation: "Yes.", score: nil, knowledgeNote: nil, sourceRefs: []
        )
        let exchange = try #require(try store.loadReviewSessionExchanges(sessionID: "chat").first)

        let fork = try store.forkReviewSession(sessionID: "chat", throughExchangeID: exchange.id, field: .evaluation)

        #expect(try store.loadReviewSessionModelRoute(sessionID: fork.id) == Self.route(Self.opus, effort: .high, speed: .fast))
    }

    @Test("An imported exchange keeps the tuning while the model stays, and drops it with another model")
    func importedExchangesKeepTuningOnlyWithTheirModel() throws {
        let store = try KnowledgeStore(inMemory: true)
        try Self.createChat("chat", in: store)
        let turn = ReviewChatTurn(question: "And then?", answer: "It depolarises.", evaluation: nil)

        _ = try store.appendReviewChatExchanges(
            sessionID: "chat", turns: [turn], sourceIDs: [], summary: nil, overallScore: nil,
            modelProvider: nil, modelID: nil
        )
        #expect(try store.loadReviewSessionModelRoute(sessionID: "chat") == Self.route(Self.opus, effort: .high, speed: .fast))

        _ = try store.appendReviewChatExchanges(
            sessionID: "chat", turns: [turn], sourceIDs: [], summary: nil, overallScore: nil,
            modelProvider: AIProvider.anthropic.rawValue, modelID: "claude-fable-5-1"
        )
        let route = try #require(try store.loadReviewSessionModelRoute(sessionID: "chat"))
        #expect(route.modelID == "claude-fable-5-1")
        #expect(route.modelEffort == nil)
        #expect(route.modelSpeed == nil)
    }

    // MARK: - Sync

    @Test("The effort and speed ride the session record to the other Mac, a default included")
    func tuningRidesTheSessionRecord() throws {
        let here = try KnowledgeStore(inMemory: true)
        let there = try KnowledgeStore(inMemory: true)
        try Self.createChat("chat", in: here)

        let payload = try #require(try here.loadReviewSessionForSync("chat"))
        let data = try JSONEncoder().encode(payload)
        try there.saveReviewSessionRecord(JSONDecoder().decode(CloudKitReviewSessionPayload.self, from: data))
        #expect(try there.loadReviewSessionModelRoute(sessionID: "chat") == Self.route(Self.opus, effort: .high, speed: .fast))

        // Put back to the model's default, the record says so with an explicit
        // null, which the other Mac takes rather than keeping High.
        try here.updateReviewSessionModel(
            sessionID: "chat", modelProvider: Self.provider, modelID: Self.opus, modelEffort: nil, modelSpeed: nil
        )
        let cleared = try JSONEncoder().encode(try #require(try here.loadReviewSessionForSync("chat")))
        let object = try #require(try JSONSerialization.jsonObject(with: cleared) as? [String: Any])
        #expect(object["modelEffort"] is NSNull)
        #expect(object["modelSpeed"] is NSNull)
        try there.saveReviewSessionRecord(JSONDecoder().decode(CloudKitReviewSessionPayload.self, from: cleared))
        #expect(try there.loadReviewSessionModelRoute(sessionID: "chat") == Self.route(Self.opus, effort: nil, speed: nil))
    }

    @Test("A record from a Mac before schema 149 keeps the local tuning while its model is the same")
    func olderRecordKeepsLocalTuning() throws {
        let store = try KnowledgeStore(inMemory: true)
        try Self.createChat("chat", in: store)
        let data = try JSONEncoder().encode(try #require(try store.loadReviewSessionForSync("chat")))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "modelEffort")
        object.removeValue(forKey: "modelSpeed")

        let sameModel = try JSONDecoder().decode(
            CloudKitReviewSessionPayload.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(!sameModel.modelTuningFieldIsPresent)
        try store.saveReviewSessionRecord(sameModel)
        #expect(try store.loadReviewSessionModelRoute(sessionID: "chat") == Self.route(Self.opus, effort: .high, speed: .fast))

        object["modelID"] = Self.sonnet
        let otherModel = try JSONDecoder().decode(
            CloudKitReviewSessionPayload.self, from: JSONSerialization.data(withJSONObject: object)
        )
        try store.saveReviewSessionRecord(otherModel)
        #expect(try store.loadReviewSessionModelRoute(sessionID: "chat") == Self.route(Self.sonnet, effort: nil, speed: nil))
    }

    // MARK: - Restore

    @Test("A reopened chat takes back the effort and speed its model offers, and nothing else")
    func restorableTuningFollowsTheModel() {
        AIModelCatalog.$openRouterReasoningEffortsOverride.withValue([:]) {
            let opus = ReviewSessionManager.restorableTuning(
                provider: .anthropic, model: "claude-opus-5", effort: "xhigh", speed: "fast"
            )
            #expect(opus.effort == .extraHigh)
            #expect(opus.speed == .fast)

            // Haiku has no effort control, so a pick made on Opus is not sent.
            let haiku = ReviewSessionManager.restorableTuning(
                provider: .anthropic, model: "claude-haiku-4-5", effort: "high", speed: nil
            )
            #expect(haiku.effort == nil)
            #expect(haiku.speed == nil)

            // Standard is the absence of a speed; an unknown value is the default.
            let odd = ReviewSessionManager.restorableTuning(
                provider: .anthropic, model: "claude-opus-5", effort: "turbo", speed: "standard"
            )
            #expect(odd.effort == nil)
            #expect(odd.speed == nil)
        }
    }

    // MARK: - Schema 149

    /// A released library at `version`: today's shape without the two
    /// columns, and for 147 and 146 without what 148 and 147 added (the
    /// YouTube transcript check queue and `research_directions`). Dropping
    /// them rather than lowering the stamp is what makes each step run.
    private static func createReleasedLibrary(at root: URL, version: Int32, extraChats: Int = 0, extraSources: Int = 0) throws {
        let store = try KnowledgeStore(storeDirectory: root)
        var article = StudioArticle(url: "https://example.com/tmrm", title: "TMRM", sourceType: .article, id: "src-a")
        article.content = "Readable text."
        article.state = .ready
        try store.saveSource(article)
        try store.createReviewSession(
            id: "old-chat", topic: "Entropy", sourceIDs: ["src-a"],
            modelProvider: provider, modelID: opus
        )
        _ = try store.addReviewExchange(
            sessionID: "old-chat", question: "What is entropy?", answer: "A count of microstates.",
            evaluation: "Right idea.", score: 0.9, knowledgeNote: nil, sourceRefs: ["src-a"]
        )
        if extraSources > 0 || extraChats > 0 {
            try store.execForTesting("""
                BEGIN IMMEDIATE;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(extraSources))
                INSERT INTO sources (id, date_added, state, source_type, status)
                SELECT printf('source-%05d', n), n, 'ready', 'article', 'active' FROM seq WHERE \(extraSources) > 0;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(extraSources))
                INSERT INTO articles (source_id, url, normalized_url, title, domain)
                SELECT printf('source-%05d', n), printf('https://example.com/%05d', n),
                       printf('example.com/%05d', n), printf('Source %05d', n), 'example.com'
                FROM seq WHERE \(extraSources) > 0;
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(extraChats))
                INSERT INTO review_sessions (id, topic, started_at, model_provider, model_id)
                SELECT printf('chat-%05d', n), printf('Chat %05d', n), n, '\(provider)', '\(opus)'
                FROM seq WHERE \(extraChats) > 0;
                COMMIT;
            """)
        }
        try store.clearAllPendingSyncChanges()
        try store.execForTesting("""
            ALTER TABLE review_sessions DROP COLUMN model_speed;
            ALTER TABLE review_sessions DROP COLUMN model_effort;
            \(version < 148 ? "DROP INDEX IF EXISTS idx_youtube_transcript_check_order; DROP TABLE youtube_transcript_check_queue;" : "")
            \(version < 147 ? "DROP TABLE IF EXISTS research_directions;" : "")
            PRAGMA user_version = \(version);
        """)
    }

    private static let tuningColumns = """
        SELECT COUNT(*) FROM pragma_table_info('review_sessions') WHERE name IN ('model_effort', 'model_speed')
        """

    @Test(
        "A released store gains a chat's effort and speed and keeps every chat as it was",
        arguments: [Int32(146), Int32(147), Int32(148)]
    )
    func version149AddsColumns(from released: Int32) throws {
        let root = try Self.temporaryRoot("schema-v149-from-\(released)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.createReleasedLibrary(at: root, version: released)
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(released)")
        #expect(Self.scalar(at: root, Self.tuningColumns) == "0")

        let migrated = try KnowledgeStore(storeDirectory: root)
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(KnowledgeStore.schemaVersion)")
        #expect(KnowledgeStore.schemaVersion == 172)
        #expect(Self.scalar(at: root, Self.tuningColumns) == "2")

        // The chat is whole, on its model, at the model's default: no chat
        // kept a pick before the columns.
        #expect(try migrated.loadActiveSources().map(\.id) == ["src-a"], "sources stay visible")
        #expect(try migrated.loadReviewSessionLinks().map(\.id) == ["old-chat"])
        #expect(try migrated.loadReviewSessionExchanges(sessionID: "old-chat").count == 1)
        #expect(try migrated.loadReviewSessionModelRoute(sessionID: "old-chat") == Self.route(Self.opus, effort: nil, speed: nil))
        #expect(try migrated.pendingSyncChanges().isEmpty, "a schema-only migration republishes nothing")

        // And the columns take a pick straight away.
        try migrated.updateReviewSessionModel(
            sessionID: "old-chat", modelProvider: Self.provider, modelID: Self.opus,
            modelEffort: AIEffort.max.rawValue, modelSpeed: nil
        )
        #expect(try migrated.loadReviewSessionModelRoute(sessionID: "old-chat")?.modelEffort == "max")
    }

    @Test("A production-sized library with thousands of chats migrates to 149 in well under a second")
    func version149Scales() throws {
        let root = try Self.temporaryRoot("schema-v149-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.createReleasedLibrary(at: root, version: 148, extraChats: 5_000, extraSources: 20_000)

        let started = ContinuousClock.now
        let migrated = try KnowledgeStore(storeDirectory: root)
        let elapsed = started.duration(to: .now)
        // Two ALTER TABLE ADD COLUMNs with no default: no row is read or
        // rewritten, so the cost cannot follow the library.
        #expect(elapsed < .seconds(1))
        #expect(Self.scalar(at: root, "PRAGMA user_version") == "\(KnowledgeStore.schemaVersion)")
        var visible = 0
        try migrated.query("SELECT COUNT(*) FROM source_projection") { visible = Int(sqlite3_column_int($0, 0)) }
        #expect(visible == 20_001, "sources stay visible")
        #expect(Self.scalar(at: root, "SELECT COUNT(*) FROM review_sessions WHERE model_effort IS NULL AND model_speed IS NULL") == "5001")
    }
}

@Suite("A chat is told when an article's saved text is a stub")
struct ThinCaptureNoteTests {
    private func article(_ url: String, _ type: StudioSourceType) -> StudioArticle {
        StudioArticle(url: url, title: "AI for Bio Doesn’t Need More Data", sourceType: type)
    }

    @Test("A web article of about fifteen words carries the note; a full article does not")
    func notesAStub() throws {
        let page = article("https://substack.com/home/post/p-214954598", .article)
        let note = try #require(ReviewSessionManager.thinCaptureNote(for: page, storedLength: 95))
        #expect(note.contains("refetch_source_content"))
        #expect(note.contains("about 15 words"))
        #expect(ReviewSessionManager.thinCaptureNote(for: page, storedLength: 33_000) == nil)
    }

    @Test("No text at all, a paper, a book and a local file are left to their own routes")
    func leavesTheRest() {
        let web = article("https://example.com/post", .article)
        #expect(ReviewSessionManager.thinCaptureNote(for: web, storedLength: nil) == nil)
        #expect(ReviewSessionManager.thinCaptureNote(for: web, storedLength: 0) == nil)
        #expect(ReviewSessionManager.thinCaptureNote(for: article("https://example.com/p", .paper), storedLength: 90) == nil)
        #expect(ReviewSessionManager.thinCaptureNote(for: article("https://example.com/b", .book), storedLength: 90) == nil)
        #expect(ReviewSessionManager.thinCaptureNote(for: article("file:///tmp/a.txt", .article), storedLength: 90) == nil)
    }
}
