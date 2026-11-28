// Chat robustness tests: transient errors, history digest, native tool calls and prompts.

import AppKit
import Foundation
import Testing
import WebKit
@testable import ForeverLM

extension ChatRobustnessTests {
    // MARK: - Transient error classification

    @Test("Network blips are transient")
    func networkErrorsAreTransient() {
        #expect(AITransientErrorClassifier.isTransient(URLError(.timedOut)))
        #expect(AITransientErrorClassifier.isTransient(URLError(.networkConnectionLost)))
        #expect(AITransientErrorClassifier.isTransient(URLError(.cannotConnectToHost)))
        #expect(AITransientErrorClassifier.isTransient(URLError(.notConnectedToInternet)))
        #expect(AITransientErrorClassifier.isTransient(URLError(.dnsLookupFailed)))
    }

    @Test("User-initiated cancellation is never transient")
    func cancellationIsNotTransient() {
        #expect(!AITransientErrorClassifier.isTransient(URLError(.cancelled)))
        #expect(!AITransientErrorClassifier.isTransient(CancellationError()))
    }

    @Test("Rate limits and overloaded providers are transient")
    func providerPressureIsTransient() {
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("Anthropic chat request failed (429).")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("Anthropic chat request failed (529).")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("OpenAI request failed (503).")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("overloaded_error: Overloaded")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("Rate limit reached for requests")))
        #expect(AITransientErrorClassifier.isTransient(AIError.apiError("The server had an internal error while processing your request.")))
    }

    @Test("Permanent failures are not retried")
    func permanentFailuresAreNotTransient() {
        #expect(!AITransientErrorClassifier.isTransient(AIError.apiError("Anthropic chat request failed (401).")))
        #expect(!AITransientErrorClassifier.isTransient(AIError.apiError("invalid x-api-key")))
        #expect(!AITransientErrorClassifier.isTransient(AIError.apiError("Anthropic chat request failed (400).")))
        #expect(!AITransientErrorClassifier.isTransient(AIError.missingAPIKey))
        #expect(!AITransientErrorClassifier.isTransient(AIError.invalidResponse))
        #expect(!AITransientErrorClassifier.isTransient(AIError.outputTokenLimit("hit max_tokens")))
    }

    @Test("Quota refusals are told apart from connection failures")
    func rateLimitsAreDistinguishedFromNetworkErrors() {
        // Retried, but on the server's timescale and never described as a
        // connection problem — the two are separate questions.
        #expect(AITransientErrorClassifier.isRateLimited(
            AIError.httpError(status: 429, message: "Too many ForeverLM AI requests this hour.", retryAfterSeconds: 900)
        ))
        #expect(AITransientErrorClassifier.isRateLimited(AIError.apiError("Anthropic chat request failed (429).")))
        #expect(AITransientErrorClassifier.isRateLimited(AIError.apiError("Rate limit reached for requests")))

        #expect(!AITransientErrorClassifier.isRateLimited(URLError(.networkConnectionLost)))
        #expect(!AITransientErrorClassifier.isRateLimited(AIError.apiError("OpenAI request failed (503).")))
        #expect(!AITransientErrorClassifier.isRateLimited(AIError.apiError("overloaded_error: Overloaded")))
    }

    @Test("Retry-After survives on the typed error so backoff can honour it")
    func retryAfterIsCarriedOnTypedErrors() {
        let error = AIError.httpError(status: 429, message: "Too many requests.", retryAfterSeconds: 1_800)
        #expect(AITransientErrorClassifier.retryAfterSeconds(error) == 1_800)
        // A wait this long outlasts the retry budget, so the chat loop surfaces
        // the server's message instead of sleeping through three attempts.
        #expect(1_800 > AITransientErrorClassifier.maximumRetryAfterWait)
        // A 429 carrying no hint has nothing to key that decision on, so it
        // keeps the ordinary backoff — upstream provider limits clear in seconds.
        #expect(AITransientErrorClassifier.retryAfterSeconds(AIError.apiError("429")) == nil)
    }

    @Test("Managed proxy credit errors preserve their structured identity")
    func managedCreditsEmptyEnvelope() throws {
        let data = Data(#"{"error":{"code":"credits_empty","message":"ForeverLM AI credits are empty — top up in Settings to continue."}}"#.utf8)
        let error = try #require(ManagedAI.serviceError(from: data))

        #expect(error.code == "credits_empty")
        #expect(error.message.contains("top up in Settings"))
    }

    @Test("Background work has explicit text and multimodal default routes")
    func backgroundDefaultRoutesAreExplicit() {
        #expect(KeychainService.defaultBackgroundTaskRoute.provider == .openRouter)
        #expect(KeychainService.defaultBackgroundTaskRoute.model == AIModelDefaults.openRouterFreeRouter)
        #expect(KeychainService.defaultBackgroundMultimodalTaskRoute.provider == .openRouter)
        #expect(
            KeychainService.defaultBackgroundMultimodalTaskRoute.model
                == AIModelDefaults.openRouterFreeRouter
        )
        #expect(KeychainService.modelSupportsVision(
            provider: .openRouter,
            model: AIModelDefaults.openRouterFreeRouter
        ) == true)
        #expect(KeychainService.modelSupportsVision(
            provider: .gemini,
            model: AIModelDefaults.latestGemini
        ) == true)
        #expect(KeychainService.modelSupportsVision(
            provider: .openRouter,
            model: AIModelDefaults.defaultOpenRouter
        ) == false)
    }

    // MARK: - Rolling history digest in the chat payload

    private func alternatingMessages(count: Int) -> [(role: String, content: String)] {
        (0..<count).map { index in
            (
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "TURN-\(index) message body"
            )
        }
    }

    @Test("Digest carries folded turns; compact transcript covers the unfolded rest")
    @MainActor
    func digestAndUnfoldedRemainderShareTheEarlierTranscript() {
        let payload = ReviewSessionManager.historyDigestPayloadForTesting(
            messages: alternatingMessages(count: 26),
            digest: "DIGEST-MARKER: learner is studying spaced repetition.",
            coveredMessageCount: 4,
            systemPrompt: "SYSTEM"
        )

        #expect(payload.system.contains("DIGEST-MARKER"))
        #expect(payload.system.contains("Turns since that summary:"))
        // Turns 4 and 5 aged out of the recent window but are not folded yet —
        // the deterministic compact must still carry them.
        #expect(payload.system.contains("TURN-4"))
        #expect(payload.system.contains("TURN-5"))
        // Folded turns are represented only by the digest.
        #expect(!payload.system.contains("TURN-0"))
        // The recent window still goes to the provider verbatim.
        #expect(payload.messages.contains { $0.content.contains("TURN-25") })
    }

    @Test("Fully folded older history is carried by the digest alone")
    @MainActor
    func fullyFoldedHistoryUsesDigestOnly() {
        let payload = ReviewSessionManager.historyDigestPayloadForTesting(
            messages: alternatingMessages(count: 26),
            digest: "DIGEST-MARKER only.",
            coveredMessageCount: 6,
            systemPrompt: "SYSTEM"
        )

        #expect(payload.system.contains("DIGEST-MARKER"))
        #expect(!payload.system.contains("Turns since that summary:"))
    }

    @Test("Without a digest the deterministic compact covers all older turns")
    @MainActor
    func emptyDigestFallsBackToDeterministicCompact() {
        let payload = ReviewSessionManager.historyDigestPayloadForTesting(
            messages: alternatingMessages(count: 26),
            digest: "",
            coveredMessageCount: 0,
            systemPrompt: "SYSTEM"
        )

        #expect(payload.system.contains("Earlier transcript compact:"))
        #expect(payload.system.contains("TURN-0"))
        #expect(!payload.system.contains("Turns since that summary:"))
    }

    // MARK: - Tool-result trim fallback

    @Test("Trim keeps the most recent whole entries and drops the oldest")
    @MainActor
    func trimKeepsRecentEntriesDropsOldest() {
        let separator = "\n\n---\n\n"
        let context = ["OLDEST-ENTRY", "MIDDLE-ENTRY", "RECENT-ENTRY"].joined(separator: separator)

        let trimmed = ReviewSessionManager.trimmedToolResultEntriesForTesting(context, budget: 140)

        #expect(trimmed.contains("[Earlier tool results dropped because the complete request exceeded this model's context window.]"))
        #expect(trimmed.contains("RECENT-ENTRY"))
        #expect(trimmed.contains("MIDDLE-ENTRY"))
        #expect(!trimmed.contains("OLDEST-ENTRY"))
    }

    @Test("A single oversized entry keeps its identifying head")
    @MainActor
    func oversizedSingleEntryKeepsTail() {
        let entry = "HEAD-" + String(repeating: "x", count: 100) + "-TAIL"

        let trimmed = ReviewSessionManager.trimmedToolResultEntriesForTesting(entry, budget: 135)

        #expect(trimmed.contains("HEAD-"))
        #expect(!trimmed.contains("-TAIL"))
    }

    // MARK: - Typed HTTP errors

    @Test("HTTP failures classify by status code, not message wording")
    func httpErrorsClassifyByStatus() {
        #expect(AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 429, message: "custom provider wording", retryAfterSeconds: nil)))
        #expect(AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 529, message: "anything", retryAfterSeconds: nil)))
        #expect(AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 503, message: "anything", retryAfterSeconds: nil)))
        #expect(!AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 401, message: "rate limit mentioned but auth failed", retryAfterSeconds: nil)))
        #expect(!AITransientErrorClassifier.isTransient(
            AIError.httpError(status: 400, message: "bad request", retryAfterSeconds: nil)))
    }

    @Test("Retry-After hint is surfaced from typed HTTP errors")
    func retryAfterHintSurfaces() {
        #expect(AITransientErrorClassifier.retryAfterSeconds(
            AIError.httpError(status: 429, message: "slow down", retryAfterSeconds: 12)) == 12)
        #expect(AITransientErrorClassifier.retryAfterSeconds(
            AIError.apiError("slow down")) == nil)
    }

    @Test("Retry-After header parses delta-seconds and HTTP-dates")
    func retryAfterHeaderParses() throws {
        let url = try #require(URL(string: "https://api.example.com"))
        let seconds = try #require(HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "7"]
        ))
        #expect(AIService.retryAfterSeconds(from: seconds) == 7)

        let none = try #require(HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil, headerFields: [:]
        ))
        #expect(AIService.retryAfterSeconds(from: none) == nil)

        let malformed = try #require(HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "not-a-date"]
        ))
        #expect(AIService.retryAfterSeconds(from: malformed) == nil)
    }

    // MARK: - Context-overflow classification

    @Test("Context-window overflows are recognized as recoverable")
    func contextOverflowIsRecognized() {
        #expect(AITransientErrorClassifier.isContextOverflow(
            AIError.httpError(status: 400, message: "prompt is too long: 210000 tokens > 200000 maximum", retryAfterSeconds: nil)))
        #expect(AITransientErrorClassifier.isContextOverflow(
            AIError.httpError(status: 400, message: "This model's maximum context length is 128000 tokens.", retryAfterSeconds: nil)))
        #expect(AITransientErrorClassifier.isContextOverflow(
            AIError.apiError("context_length_exceeded: reduce your prompt")))
        #expect(!AITransientErrorClassifier.isContextOverflow(
            AIError.httpError(status: 401, message: "context length irrelevant, invalid key", retryAfterSeconds: nil)))
        #expect(!AITransientErrorClassifier.isContextOverflow(
            AIError.httpError(status: 400, message: "invalid tool schema", retryAfterSeconds: nil)))
    }

    // MARK: - Native tool support

    @Test("Native-tool rejections are recognized for text-protocol fallback")
    func nativeToolRejectionRecognized() {
        #expect(AINativeToolSupport.isNativeToolRejection(
            AIError.httpError(status: 400, message: "tools is not supported for this model", retryAfterSeconds: nil)))
        #expect(AINativeToolSupport.isNativeToolRejection(
            AIError.httpError(status: 422, message: "unknown parameter: 'tools'", retryAfterSeconds: nil)))
        // Server errors are transient, not a protocol rejection.
        #expect(!AINativeToolSupport.isNativeToolRejection(
            AIError.httpError(status: 500, message: "tools backend crashed", retryAfterSeconds: nil)))
        // Tool-unrelated 4xx must not disable native tools.
        #expect(!AINativeToolSupport.isNativeToolRejection(
            AIError.httpError(status: 400, message: "temperature must be between 0 and 2", retryAfterSeconds: nil)))
    }

    @Test("A malformed tool round-trip is not read as a missing capability")
    func malformedToolRoundTripIsNotANativeToolRejection() {
        // The 400 that stranded sessions on the text protocol: it names an item
        // of the conversation we sent, and says "function_call" and "invalid"
        // while doing it. The fix is a better request, not a worse protocol.
        #expect(!AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400,
            message: "Item 'fc_049a726c405dbe46006a963a3b56fc87d1ad5b46d254ac4c00' of type 'function_call' was provided without its required 'reasoning' item: 'rs_049a726c405dbe46006a963a39687087d186afccbcb4a5ac77'. (all 2 candidates failed: openai:gpt-5.6-sol:flex 400 invalid_request_error) [AI provider stream request failed (400)]",
            retryAfterSeconds: nil
        )))
        #expect(!AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400,
            message: "Invalid value for 'tool_call_id': no tool call with that id was found.",
            retryAfterSeconds: nil
        )))
        // A schema we built wrongly is our bug too, not a capability gap.
        #expect(!AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400,
            message: "Invalid schema for function 'search_sources_semantic': 'date_from' is not of type object.",
            retryAfterSeconds: nil
        )))
        // The bare word "tool" in unrelated prose decides nothing.
        #expect(!AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400,
            message: "The requested toolkit image is not available in this region.",
            retryAfterSeconds: nil
        )))
        // Real refusals still land, however each provider words them.
        #expect(AINativeToolSupport.isNativeToolRejection(AIError.httpError(
            status: 400, message: "tool_choice is not supported by this model", retryAfterSeconds: nil)))
        #expect(AINativeToolSupport.isNativeToolRejection(AIError.apiError(
            "This model does not support function calling.")))
    }

    // MARK: - Native tool-call stream accumulation

    @Test("OpenAI-style tool_calls deltas accumulate arguments by index")
    func openAIStyleToolCallAccumulates() {
        var accumulator = AIToolCallStreamAccumulator()
        accumulator.consume([
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0,
                    "id": "call_x1",
                    "function": ["name": "get_schedule", "arguments": "{\"da"],
                ]]],
            ]],
        ])
        accumulator.consume([
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0,
                    "function": ["arguments": "te\": \"2026-07-16\"}"],
                ]]],
            ]],
        ])
        accumulator.consume([
            "choices": [["finish_reason": "tool_calls", "delta": [:]]],
        ])

        #expect(accumulator.sawToolUseStop)
        let calls = accumulator.toolCalls
        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_x1")
        #expect(calls.first?.name == "get_schedule")
        #expect(calls.first?.arguments["date"] as? String == "2026-07-16")
    }

    @Test("A call with no argument bytes is told apart from an explicit {} and from cut-off JSON")
    func emptyToolCallsAreClassified() {
        let spec = AIToolSpec(
            name: "search_sources_keyword",
            description: "x",
            inputSchema: ["type": "object", "properties": [:] as [String: Any], "required": ["keywords"]]
        )
        func calls(arguments: String?, finish: String? = nil) -> [AIToolCallRequest] {
            var accumulator = AIToolCallStreamAccumulator()
            var function: [String: Any] = ["name": "search_sources_keyword"]
            if let arguments { function["arguments"] = arguments }
            accumulator.consume(["choices": [["delta": ["tool_calls": [["index": 0, "id": "c1", "function": function]]]]]])
            if let finish { accumulator.consume(["choices": [["finish_reason": finish, "delta": [:]]]]) }
            return accumulator.toolCalls
        }

        #expect(calls(arguments: nil).first?.unusableArguments(for: spec) == .noArgumentBytes(required: ["keywords"]))
        #expect(calls(arguments: "{}").first?.unusableArguments(for: spec) == .emptyObject(required: ["keywords"]))
        #expect(calls(arguments: "{\"keywords\": [\"mt").first?.unusableArguments(for: spec) == .malformedJSON)
        #expect(calls(arguments: "{\"keywords\": [\"mt", finish: "length").first?.unusableArguments(for: spec) == .cutOffForLength)
        #expect(calls(arguments: "{\"keywords\": [\"mtDNA\"]}").first?.unusableArguments(for: spec) == nil)
        // A tool with nothing required is never refused for having no arguments.
        let bare = AIToolSpec(name: "search_sources_keyword", description: "x", inputSchema: ["type": "object"])
        #expect(calls(arguments: nil).first?.unusableArguments(for: bare) == nil)
        // Some arguments with one missing is left to the tool's own error.
        #expect(calls(arguments: "{\"limit\": 5}").first?.unusableArguments(for: spec) == nil)
    }

    @Test("Malformed tool arguments degrade to an empty dictionary, not a crash")
    func malformedToolArgumentsDegradeGracefully() {
        let call = AIToolCallRequest(id: "call_1", name: "list_sources", argumentsJSON: "{broken json")
        #expect(call.arguments.isEmpty)
    }

    // MARK: - Native tool protocol payloads

    @Test("OpenAI-style messages carry tool role replies with matching call ids")
    func openAIStyleToolMessagePairing() {
        let call = AIToolCallRequest(id: "call_9", name: "get_app_context", argumentsJSON: "{}")
        let messages = AIService.openAIStyleToolMessages(system: "SYSTEM", turns: [
            .user("What's my context?"),
            .assistant(text: "", toolCalls: [call]),
            .toolResults([AIToolResultPayload(callID: "call_9", toolName: "get_app_context", text: "Notebook X", isError: true)]),
        ])

        #expect(messages.first?["role"] as? String == "system")
        let assistant = messages[2]
        let toolCalls = assistant["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.first?["id"] as? String == "call_9")
        let toolReply = messages[3]
        #expect(toolReply["role"] as? String == "tool")
        #expect(toolReply["tool_call_id"] as? String == "call_9")
    }

    @Test("A learner turn with pictures becomes image parts on the OpenRouter shape")
    func attachedPicturesBecomeImageParts() {
        let picture = AIChatImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), mediaType: "image/jpeg")
        let turns: [AIChatTurn] = [
            .user("What is this?", images: [picture]),
            .assistant(text: "A JPEG header.", toolCalls: []),
            .user("", images: [picture]),
        ]

        // OpenAI-style chat completions: image_url parts then a text part.
        let openAI = AIService.openAIStyleToolMessages(system: "S", turns: turns)
        let openAIParts = openAI[1]["content"] as? [[String: Any]]
        #expect(openAIParts?[0]["type"] as? String == "image_url")
        #expect((openAIParts?[0]["image_url"] as? [String: Any])?["url"] as? String == picture.dataURL)
        #expect(openAIParts?[1]["text"] as? String == "What is this?")
        #expect((openAI[3]["content"] as? [[String: Any]])?.count == 1)

        // A turn without pictures is still the plain string every route sent before.
        #expect(AIService.openAIStyleToolMessages(system: "S", turns: [.user("Just text")])[1]["content"] as? String == "Just text")
        #expect(AIService.projectedCharacterCount(of: turns) > AIChatImage.projectedCharacterCount * 2)
    }

    // MARK: - Native mode prompt and specs

    @Test("Native system prompt drops the text tool-call protocol")
    @MainActor
    func nativePromptOmitsTextProtocol() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            synthesisTitle: "Notebook"
        )

        #expect(!prompt.contains("<flm_tool_call>"))
        #expect(!prompt.contains("input_schema:"))
        #expect(prompt.contains("<attached_sources>"))
        #expect(prompt.contains("add_to_synthesis"))
        #expect(prompt.contains("read-before-write"))
        #expect(prompt.contains("- Never name a tool or tell the learner which tool you would call; say what you did or what they can do in the app."))
    }

    @Test("A chat on one source tells the model not to cite that source")
    @MainActor
    func singleSourceChatDoesNotCiteItsSource() {
        let tools: [ReviewSessionManager.AppToolDefinition] = [
            .init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}"),
        ]
        let one = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria",
            hasAttachedSource: true,
            appTools: tools
        )
        #expect(one.contains("This chat is about that one attached source"))
        #expect(one.contains("Do not cite it"))
        #expect(one.contains("The one exception is a chat opened on a single attached source"))

        let two = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria",
            hasAttachedSource: true,
            attachedSourceCount: 2,
            appTools: tools
        )
        #expect(!two.contains("This chat is about that one attached source"))
        #expect(two.contains("Cite a source from the learner's library"))

        let none = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria",
            hasAttachedSource: false,
            appTools: tools
        )
        #expect(!none.contains("This chat is about that one attached source"))
    }

    @Test("Chat on a route with a native web engine has web search attached directly")
    @MainActor
    func chatPromptWithNativeWebSearch() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            webSearch: .native
        )

        #expect(prompt.contains("ForeverLM app tools available"))
        #expect(prompt.contains("Live web search is available: the provider's web_search tool is attached"))
        #expect(prompt.contains("search the library first"))
        // 2026-09-09: a question about "the last Huberman Lab podcast" went to the
        // web although the episode was in the library, because the prompt framed
        // the web as the place for external-sounding questions.
        #expect(prompt.contains("Search the web only if the library has nothing applicable"))
        #expect(prompt.contains("holds podcasts, videos, articles, books and papers"))
        #expect(!prompt.contains("Web search is unavailable"))
        #expect(!prompt.contains("request_web_search"))
        #expect(!prompt.contains("Deep Research is enabled"))
        #expect(prompt.contains("targeted paper, title, author, keyword, or topic lookup"))
        #expect(prompt.contains("Call list_sources only when the learner explicitly asks"))
    }

    @Test("Chat on an Exa-fallback route reaches the web through request_web_search")
    @MainActor
    func chatPromptWithOnRequestWebSearch() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            webSearch: .onRequest
        )

        #expect(prompt.contains("Live web search is available on request"))
        #expect(prompt.contains("call request_web_search with one focused query"))
        #expect(prompt.contains("Only if the library has nothing applicable"))
        #expect(!prompt.contains("Web search is unavailable"))
        #expect(!prompt.contains("Deep Research is enabled"))
    }

    @Test("Chat on a route without a billable web engine says so and points at the model picker")
    @MainActor
    func chatPromptWithoutWebSearch() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")]
        )

        #expect(prompt.contains("Web search is unavailable on this model route"))
        #expect(prompt.contains("pick another model in the composer"))
        #expect(!prompt.contains("request_web_search"))
        #expect(!prompt.contains("choose Deep Research"))
    }

    @Test("Chat offers to add papers the library lacks when it carries the importer")
    @MainActor
    func chatPromptOffersToImportPapers() {
        let importer = ReviewSessionManager.AppToolDefinition(
            name: "import_paper_from_url",
            description: "Import a paper",
            inputSchemaJSON: "{\"type\":\"object\"}"
        )
        let withImporter = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: false,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}"), importer],
            webSearch: .native
        )
        #expect(withImporter.contains("Papers outside the library"))
        #expect(withImporter.contains("say so and offer to add it"))
        #expect(withImporter.contains("call import_paper_from_url"))
        #expect(withImporter.contains("Never ask the learner to paste a URL"))

        let withoutImporter = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Cells",
            hasAttachedSource: false,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            webSearch: .native
        )
        #expect(!withoutImporter.contains("Papers outside the library"))
    }

    @Test("Chat web access follows the engine on the route the request travels")
    @MainActor
    func chatWebSearchAccessFollowsRoute() {
        typealias Manager = ReviewSessionManager
        // First-party routes carry the provider's own tool; idle it is free.
        #expect(Manager.webSearchAccess(selectedProvider: .anthropic, routedProvider: .anthropic, routedModel: "claude-sonnet-5") == .native)
        #expect(Manager.webSearchAccess(selectedProvider: .openai, routedProvider: .openai, routedModel: "gpt-5.6-sol") == .native)
        #expect(Manager.webSearchAccess(selectedProvider: .xai, routedProvider: .xai, routedModel: "grok-4") == .native)
        // Under the OpenRouter transport policy the slug decides the engine:
        // native for the labs OpenRouter documents, Exa (one billed search per
        // request) for everything else — so those ask first.
        #expect(Manager.webSearchAccess(selectedProvider: .openai, routedProvider: .openRouter, routedModel: "openai/gpt-5.6-sol") == .native)
        #expect(Manager.webSearchAccess(selectedProvider: .anthropic, routedProvider: .openRouter, routedModel: "anthropic/claude-sonnet-5") == .native)
        #expect(Manager.webSearchAccess(selectedProvider: .openRouter, routedProvider: .openRouter, routedModel: "deepseek/deepseek-v3.2") == .onRequest)
        #expect(Manager.webSearchAccess(selectedProvider: .nvidia, routedProvider: .openRouter, routedModel: "nvidia/nemotron-3-super") == .onRequest)
        // Gemini's search allowance is account-wide, whatever the transport.
        #expect(Manager.webSearchAccess(selectedProvider: .gemini, routedProvider: .gemini, routedModel: "gemini-3-pro") == .unavailable)
        #expect(Manager.webSearchAccess(selectedProvider: .gemini, routedProvider: .openRouter, routedModel: "google/gemini-3-pro") == .unavailable)
    }

    @Test("Deep Research uses its research prompt and enables live web search")
    @MainActor
    func deepResearchPromptEnablesWebSearch() {
        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "mtDNA mutations and CHIP",
            hasAttachedSource: false,
            mode: .deepResearch,
            webSearch: .native
        )

        #expect(prompt.contains("ForeverLM's research agent"))
        #expect(prompt.contains("interactive Deep Research chat"))
        #expect(prompt.contains("Research notes: <topic>"))
        #expect(prompt.contains("fetch_web_page"))
        #expect(prompt.contains("Deep Research is enabled"))
        #expect(prompt.contains("attached to every step of this turn"))
        #expect(!prompt.contains("Web search is unavailable"))
        #expect(!prompt.contains("Live web search is available:"))
        #expect(!prompt.contains("request_web_search"))
    }

    @Test("Reading modes encode selective and comprehensive source-reading contracts")
    @MainActor
    func readingModePromptsStayDistinct() {
        let shallow = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "AlphaGo",
            hasAttachedSource: true,
            mode: .shallowRead
        )
        let deep = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "AlphaGo",
            hasAttachedSource: true,
            mode: .deepRead
        )

        #expect(shallow.contains("acquire the gestalt"))
        #expect(shallow.contains("Be deliberately selective"))
        #expect(shallow.contains("Distinguish what the source claims"))
        #expect(!shallow.contains("Work in layers"))
        #expect(deep.contains("Work in layers"))
        #expect(deep.contains("mechanisms step by step"))
        #expect(deep.contains("what remains unread or unresolved"))
        #expect(!deep.contains("live web-search tool proactively"))
    }

    @Test("An unknown figure label sends the model to show_source_image, not the web")
    @MainActor
    func figureLabelNotFoundPointsAtShowSourceImage() {
        // The real case: a paper whose main figures are indexed, asked for a
        // supplementary label that is printed in a file the library does not
        // hold. Listing the labels and stopping there let the model conclude
        // the picture was not on this Mac and search the web for it.
        let labelled = ReviewSessionManager.figureLabelNotFoundMessage(
            requested: "Figure S17",
            availableLabels: ["Figure 1", "Figure 2", "Figure 8"]
        )
        #expect(labelled.contains("Figure S17 was not found"))
        #expect(labelled.contains("Figure 1, Figure 2, Figure 8"))
        #expect(labelled.contains("show_source_image"))
        #expect(labelled.contains("page"))
        #expect(labelled.contains("Do not search the web"))

        // The branch that already named the fallback keeps naming it.
        let unlabelled = ReviewSessionManager.figureLabelNotFoundMessage(
            requested: "Figure 3",
            availableLabels: []
        )
        #expect(unlabelled.contains("no structurally labelled figures"))
        #expect(unlabelled.contains("show_source_image"))
        #expect(!unlabelled.contains("labelled figures are:"))
    }

    @Test("Asking for a panel crops the figure to that panel")
    @MainActor
    func paperFigurePanelCropZoomsToThePanel() {
        // Figure 1 of the single-cell mtDNA paper as the vision pass stored it:
        // a figure rectangle and one rectangle per lettered panel. Before this,
        // panel_label picked the panel's explanation but the picture stayed the
        // whole figure, so "zoom in on 1A" could not be answered with a picture.
        let figureRect = PaperFigureRect(x: 0.16, y: 0.04, width: 0.68, height: 0.6)
        let panelA = PaperFigurePanel(
            id: "fig-panel-1", label: "A", explanation: "Workflow schematic.",
            rect: PaperFigureRect(x: 0.1646, y: 0.0401, width: 0.2139, height: 0.2659)
        )
        let panelB = PaperFigurePanel(
            id: "fig-panel-2", label: "B", explanation: "Read fraction distribution.",
            rect: PaperFigureRect(x: 0.3516, y: 0.041, width: 0.1568, height: 0.1304)
        )
        let unmeasured = PaperFigurePanel(id: "fig-panel-3", label: "C", explanation: "Histogram.", rect: nil)
        let analysis = PaperFigureAnalysis(
            summary: "Validation of single-cell mtDNA sequencing.",
            visualEvidence: [],
            figureRect: figureRect,
            panels: [panelA, panelB, unmeasured],
            analysisVersion: PaperFigureAnalysis.currentVersion,
            generatedAt: Date()
        )

        // Every spelling the model uses for a panel finds the bare letter.
        for spelling in ["A", "a", "(a)", "1a", "Figure 1A", "Fig. 1a", "panel a"] {
            #expect(ReviewSessionManager.paperFigurePanel(labelled: spelling, in: analysis)?.id == panelA.id, "\(spelling)")
        }
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "b", in: analysis)?.id == panelB.id)
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "", in: analysis) == nil)
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "Figure 1", in: analysis) == nil)
        #expect(ReviewSessionManager.paperFigurePanel(labelled: "z", in: analysis) == nil)

        // The crop is the panel's rectangle when it has one, the figure's when
        // it does not, and never widens to the page.
        #expect(ReviewSessionManager.paperFigureCrop(analysis: analysis, panel: panelA) == panelA.rect)
        #expect(ReviewSessionManager.paperFigureCrop(analysis: analysis, panel: unmeasured) == figureRect)
        #expect(ReviewSessionManager.paperFigureCrop(analysis: analysis, panel: nil) == figureRect)

        // The tool tells the model that panel_label zooms, so a panel-by-panel
        // walk through a figure is one call per panel rather than a guess.
        let specs = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true, appTools: [], hasSynthesisContext: false
        )
        let inspect = specs.first { $0.name == "inspect_paper_figure" }
        #expect(inspect?.description.contains("cropped to that panel") == true)
        // The model is handed the figure itself, and the learner sees it under
        // the step rather than outlined in the Reader or copied into the reply
        // (product owner, 2026-11-27).
        #expect(inspect?.description.contains("returned to you as a picture") == true)
        #expect(inspect?.description.contains("under this step in the chat") == true)
        #expect(inspect?.description.contains("Do not put an image line of the figure in the reply") == true)
        let properties = inspect?.inputSchema["properties"] as? [String: Any]
        let panelProperty = properties?["panel_label"] as? [String: Any]
        #expect((panelProperty?["description"] as? String)?.contains("zoomed") == true)
    }

    @Test("The picture tools take any library source and are offered without an attached source")
    @MainActor
    func pictureToolsReachTheWholeLibrary() {
        // The 2026-09-12 case: the paper was in the library, a search had just
        // found it, and both tools refused its ID as "not attached" until the
        // model gave up and opened the publisher's page in the browser.
        let detached = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [], hasSynthesisContext: false
        )
        let names = detached.map(\.name)
        #expect(names.contains("inspect_paper_figure"))
        #expect(names.contains("show_source_image"))
        #expect(!names.contains("retrieve_sources"))
        #expect(!names.contains("extract_video_slides"))

        let inspect = detached.first { $0.name == "inspect_paper_figure" }
        #expect(inspect?.description.contains("does not have to be attached") == true)
        #expect(inspect?.description.contains("never open the publisher's page") == true)
        let inspectSource = (inspect?.inputSchema["properties"] as? [String: Any])?["source_id"] as? [String: Any]
        #expect((inspectSource?["description"] as? String)?.contains("search result") == true)

        let show = detached.first { $0.name == "show_source_image" }
        #expect(show?.description.contains("need not be attached") == true)

        let message = ReviewSessionManager.sourceNotInLibraryMessage("abc")
        #expect(message.contains("abc is not a source in this library"))
        #expect(message.contains("search_sources_semantic"))
        #expect(message.contains("need not be attached"))
    }

    @Test("extract_video_slides is the chat's own tool once sources are attached, and the MCP twin steps aside")
    @MainActor
    func extractVideoSlidesIsNativeWithAttachedSources() {
        let mcpTwin = ReviewSessionManager.AppToolDefinition(
            name: "extract_video_slides",
            description: "MCP: Capture a library video's slide frames.",
            inputSchemaJSON: "{\"type\":\"object\"}"
        )
        // With a source attached the chat defines the tool itself: it resolves
        // the id against the attached pool and returns the deck listing. The MCP
        // definition of the same name is dropped, because two tools sharing a
        // name is a request the providers refuse.
        let attached = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true, appTools: [mcpTwin], hasSynthesisContext: false
        )
        let attachedExtract = attached.filter { $0.name == "extract_video_slides" }
        #expect(attachedExtract.count == 1)
        #expect(attachedExtract.first?.description.contains("Show slides") == true)
        #expect(attachedExtract.first?.description.contains("show_source_image") == true)
        #expect((attachedExtract.first?.inputSchema["required"] as? [String]) == ["source_id"])
        // Without attached sources there is nothing for the chat's version to
        // capture, so the MCP tool is the one on offer — still exactly once.
        let detached = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false, appTools: [mcpTwin], hasSynthesisContext: false
        )
        let detachedExtract = detached.filter { $0.name == "extract_video_slides" }
        #expect(detachedExtract.count == 1)
        #expect(detachedExtract.first?.description.hasPrefix("MCP:") == true)
    }

    @Test("Native tool specs cover retrieval, synthesis, and app tools")
    @MainActor
    func nativeToolSpecsCoverAllSurfaces() {
        let specs = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true,
            appTools: [.init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}")],
            hasSynthesisContext: true
        )

        let names = specs.map(\.name)
        #expect(names.contains("retrieve_sources"))
        #expect(names.contains("inspect_paper_figure"))
        #expect(names.contains("show_source_image"))
        #expect(names.contains("fetch_web_page"))
        #expect(!names.contains("request_web_search"))

        let showImage = specs.first { $0.name == "show_source_image" }
        let imageProperties = showImage?.inputSchema["properties"] as? [String: Any]
        #expect(imageProperties?["query"] != nil)
        #expect(imageProperties?["page"] != nil)
        #expect(imageProperties?["slide"] != nil)
        // Any moment of a video, not only its captured slides, and a crop in on it.
        #expect(imageProperties?["at"] != nil)
        #expect(imageProperties?["crop"] != nil)
        #expect((showImage?.inputSchema["required"] as? [String]) == ["source_id"])

        let generateImage = specs.first { $0.name == "generate_image" }
        let generateProperties = generateImage?.inputSchema["properties"] as? [String: Any]
        #expect(generateProperties?["prompt"] != nil)
        #expect(generateProperties?["title"] != nil, "a new picture is named, not captioned by its prompt")
        #expect((generateProperties?["shape"] as? [String: Any])?["enum"] as? [String] == ["square", "landscape", "portrait"])
        #expect((generateProperties?["quality"] as? [String: Any])?["enum"] as? [String] == ["low", "medium", "high"])
        #expect((generateImage?.inputSchema["required"] as? [String]) == ["prompt"])
        #expect(generateImage?.description.contains("show_source_image") == true)
        let listImages = specs.first { $0.name == "list_generated_images" }
        #expect(listImages != nil)
        #expect((listImages?.inputSchema["properties"] as? [String: Any])?["query"] != nil)
        #expect(listImages?.description.contains("generate_image") == true)
        #expect(generateProperties?["revises"] != nil, "a change to a drawn picture is its next version")
        // The agent chat gets every MCP tool not excluded; the MCP image tools
        // would put a second generate_image in the request beside the chat's own.
        #expect(ReviewSessionManager.chatExcludedToolNames.isSuperset(of: MCPDataStore.imageToolNames))
        #expect(names.contains("add_to_synthesis"))
        #expect(names.contains("replace_synthesis"))
        #expect(names.contains("list_sources"))

        let retrieval = specs.first { $0.name == "retrieve_sources" }
        let properties = retrieval?.inputSchema["properties"] as? [String: Any]
        #expect(properties?["cursor"] != nil)
        #expect(retrieval?.description.contains("continuation cursor") == true)
    }

    @Test("Deep Research receives provider web search directly, without an app shim")
    @MainActor
    func deepResearchToolSpecsOmitWebShim() {
        let names = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: false,
            appTools: [],
            hasSynthesisContext: false,
            mode: .deepResearch,
            webSearch: .native
        ).map(\.name)

        #expect(!names.contains("request_web_search"))
    }

    @Test("request_web_search is offered only where the route's engine searches unconditionally")
    @MainActor
    func webSearchShimFollowsRouteAccess() {
        func specs(_ access: ReviewSessionManager.WebSearchAccess) -> [AIToolSpec] {
            ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: false,
                appTools: [],
                hasSynthesisContext: false,
                webSearch: access
            )
        }

        #expect(!specs(.native).map(\.name).contains("request_web_search"))
        #expect(!specs(.unavailable).map(\.name).contains("request_web_search"))

        let shim = specs(.onRequest).first { $0.name == "request_web_search" }
        #expect(shim != nil)
        #expect((shim?.inputSchema["required"] as? [String]) == ["query"])
        #expect(shim?.description.contains("targeted library lookup") == true)
    }

    @Test("Study prompt kinds carry only the scoped app-tool surface")
    @MainActor
    func studyModesScopeAppTools() {
        let appTools: [ReviewSessionManager.AppToolDefinition] = [
            .init(name: "list_sources", description: "List sources", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "get_source_content", description: "Read a source", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "import_paper_from_url", description: "Import a paper", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "delete_source", description: "Delete a source", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "end_review_session", description: "End a review", inputSchemaJSON: "{\"type\":\"object\"}"),
        ]

        for mode in [
            ReviewSessionManager.InitialPromptMode.review,
            .summarize,
            .shallowRead,
            .deepRead,
        ] {
            let names = ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: true,
                appTools: appTools,
                hasSynthesisContext: true,
                mode: mode
            ).map(\.name)

            // Reading the attached sources stays available in every mode.
            #expect(names.contains("retrieve_sources"))
            #expect(names.contains("list_sources"))
            #expect(names.contains("get_source_content"))
            // A paper the chat brings up can be added on request.
            #expect(names.contains("import_paper_from_url"))
            // Library administration and duplicate review recording do not.
            #expect(!names.contains("delete_source"))
            #expect(!names.contains("end_review_session"))
        }

        // The agent surface still gets everything.
        let agentNames = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true,
            appTools: appTools,
            hasSynthesisContext: true,
            mode: .assistant
        ).map(\.name)
        #expect(agentNames.contains("delete_source"))
        #expect(agentNames.contains("end_review_session"))
    }

    @Test("Notebook chat reaches the whole library while staying pinned to its own Notebook")
    @MainActor
    func notebookChatScopesSourceTools() {
        let appTools: [ReviewSessionManager.AppToolDefinition] = [
            .init(name: "get_app_context", description: "Get context", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "list_sources", description: "List all sources", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "get_source_content", description: "Read source", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "search_sources_semantic", description: "Search sources", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "get_notebook_context", description: "Read notebook", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "add_notebook_sources", description: "Add notebook sources", inputSchemaJSON: "{\"type\":\"object\"}"),
            .init(name: "list_notebook_sources", description: "List notebook sources", inputSchemaJSON: "{\"type\":\"object\"}"),
        ]

        let names = ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true,
            appTools: appTools,
            hasSynthesisContext: true,
            notebookScopeID: "notebook-1"
        ).map(\.name)

        #expect(!names.contains("get_app_context"))
        #expect(names.contains("list_sources"))
        #expect(names.contains("get_source_content"))
        #expect(names.contains("search_sources_semantic"))
        #expect(names.contains("get_notebook_context"))
        #expect(names.contains("add_notebook_sources"))
        #expect(names.contains("list_notebook_sources"))

        // A chat that lives outside every Notebook has no Notebook context at all.
        // The sidebar's highlighted Notebook must not become one by way of
        // get_app_context, in either the study surface or the agent surface.
        for mode in [ReviewSessionManager.InitialPromptMode.review, .assistant] {
            let unscopedNames = ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: true,
                appTools: appTools,
                hasSynthesisContext: false,
                mode: mode,
                notebookScopeID: nil
            ).map(\.name)
            #expect(!unscopedNames.contains("get_app_context"))
            #expect(unscopedNames.contains("search_sources_semantic"))
        }

        // An unscoped search stays library-wide: the Notebook pool is already
        // attached, so a search exists to find what is not in hand yet.
        let defaultSearch = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "search_sources_semantic",
            arguments: ["query": "mitochondria"],
            notebookScopeID: "notebook-1"
        )
        #expect(defaultSearch["notebook_id"] == nil)
        #expect(defaultSearch["exclude_notebook_id"] == nil)

        // A deliberately scoped search is aimed at this Notebook, never another.
        let insideSearch = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "search_sources_semantic",
            arguments: ["query": "mitochondria", "notebook_id": "wrong-notebook"],
            notebookScopeID: "notebook-1"
        )
        #expect(insideSearch["notebook_id"] as? String == "notebook-1")

        let outsideSearch = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "search_sources_semantic",
            arguments: ["query": "mitochondria", "exclude_notebook_id": "wrong-notebook"],
            notebookScopeID: "notebook-1"
        )
        #expect(outsideSearch["notebook_id"] == nil)
        #expect(outsideSearch["exclude_notebook_id"] as? String == "notebook-1")

        let addSources = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "add_notebook_sources",
            arguments: [
                "notebook_id": "wrong-notebook",
                "source_ids": ["source-2"],
            ],
            notebookScopeID: "notebook-1"
        )
        #expect(addSources["notebook_id"] as? String == "notebook-1")

        // The notebook's chat checkboxes are this Notebook's, never another's.
        let selection = ReviewSessionManager.notebookScopedArgumentsForTesting(
            toolName: "set_notebook_source_selection",
            arguments: [
                "notebook_id": "wrong-notebook",
                "mode": "exclude",
                "source_ids": ["source-2"],
            ],
            notebookScopeID: "notebook-1"
        )
        #expect(selection["notebook_id"] as? String == "notebook-1")

        let prompt = ReviewSessionManager.nativeSystemPromptForTesting(
            topic: "Mitochondria",
            hasAttachedSource: true,
            appTools: appTools,
            notebookScopeID: "notebook-1"
        )
        #expect(prompt.contains("attached source catalog is the working set"))
        #expect(prompt.contains("The Notebook is a focus, not a wall"))
        #expect(prompt.contains("get_source_content read any source in it"))
        // Reading outside the catalog is a rule, not a deliberation: keyword
        // passages by id first, the whole text only when those do not answer.
        #expect(prompt.contains(ReviewSessionManager.outsideCatalogReadingRule))
        #expect(prompt.contains("retrieve_sources reads only the sources in this chat's catalog"))
        #expect(!prompt.contains("then read it with get_source_content"))
        #expect(prompt.contains("nothing to ask permission for"))
        #expect(prompt.contains("dated meeting recording, transcript, notes"))
        #expect(prompt.contains("just look it up and read it"))
        #expect(prompt.contains("does not add it to the Notebook"))
        #expect(prompt.contains("marks the rest in_chat false"))
        #expect(prompt.contains("only when the learner asks"))
        #expect(!prompt.contains("Notebook source boundary"))
        #expect(!prompt.contains("automatically restricted to this Notebook"))
    }

    @Test("Notebook chat reads a library source that is not in the Notebook")
    @MainActor
    func notebookChatReadsSourceOutsideItsNotebook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotebookChatLibraryReach_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let source = StudioArticle(
            url: "https://example.com/journal-club-recording",
            title: "Journal Club — Somatic Mutations",
            sourceType: .article,
            id: "journal-club-recording"
        )
        try await storage.saveSource(source)
        let notebook = try await storage.createCompanionGoal(
            title: "Thyroid Autoimmunity",
            topic: "thyroid autoimmunity",
            startAt: Date(),
            endAt: LearningGoalRecord.openEndedEndAt,
            dailyTarget: 3,
            discoveryEnabled: false,
            seedSourceIDs: []
        )

        // The meeting recording is nowhere near this Notebook's source pool, and
        // no outside search preceded the read. It is still the learner's own
        // library, so the read reaches the tool instead of being refused.
        let result = await ReviewSessionManager.notebookChatAppToolResultForTesting(
            storage: storage,
            notebookScopeID: notebook.id,
            toolName: "get_source_content",
            arguments: ["source_id": source.id]
        )
        #expect(!result.isError)
        #expect(result.text == "the tool ran")
    }

    @Test("Flattened turns merge roles and summarize tool traffic")
    @MainActor
    func flattenedTurnsMergeRoles() {
        let call = AIToolCallRequest(id: "c1", name: "list_sources", argumentsJSON: "{}")
        let messages = ReviewSessionManager.flattenedProviderMessagesForTesting(from: [
            .user("Hi"),
            .assistant(text: "Checking.", toolCalls: [call]),
            .toolResults([AIToolResultPayload(callID: "c1", toolName: "list_sources", text: "3 sources", isError: false)]),
            .user("Thanks"),
        ])

        #expect(messages.map(\.role) == ["user", "assistant", "user"])
        #expect(messages[1].content.contains("[Called list_sources]"))
        #expect(messages[2].content.contains("3 sources"))
    }
}
