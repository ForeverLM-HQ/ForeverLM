import Foundation
import Testing
@testable import ForeverLM

/// Live probe: does every chat model ForeverLM offers actually answer through
/// the managed proxy right now?
///
/// The unit suites prove the request shape, the routing table and the error
/// wording; none of them can notice that a lab has started refusing a model,
/// that OpenRouter has delisted a slug, or that the Worker prices one model
/// and not another. On 2026-09-10 a Gemini 3.8 Flash chat failed with a bare
/// "Provider returned error (429)" and nothing in the test target could have
/// said so beforehand. This suite sends one tiny prompt per catalogued model
/// through the same `AIService.streamChat` path the chat uses and fails per
/// model, so the report names exactly which models are broken.
///
/// The probe goes through `streamChatWithTools` with the chat's real tool list, which
/// is the chat's own path and request shape — tools, `temperature: 0.4`, a
/// reasoning effort where the model takes one. The shape matters: the first
/// version of this probe used the plain `streamChat` path and passed for
/// Gemini 3.8 Flash while every real chat on it failed, because the chat's
/// `temperature` (which Google Vertex's endpoint does not list) plus the
/// proxy's `require_parameters` left Google AI Studio as the only routable
/// endpoint, and AI Studio was answering 429.
///
/// It is opt-in because it spends real money (a few tokens per model), needs
/// the network, and needs the test host signed in to ForeverLM AI — the Dev
/// app's managed session, which the host reads from the Keychain. Run it with
///
///     FOREVERLM_MODEL_SMOKE_TESTS=1 xcodebuild test-without-building \
///       -only-testing:ForeverLMMacUnitTests/ManagedModelSmokeTests …
///
/// Each prompt carries a nonce so neither `ai_response_cache` nor the Worker's
/// repeated-request guard can answer for the model.
///
/// First run, 2026-09-10: 34 models, 31 answered; the three that did not were
/// this list naming `openai/gpt-5.6` where the directory slug is
/// `openai/gpt-5.6-sol`, a 16-token budget too small for Muse Spark's
/// reasoning, and a real one — DeepInfra rate-limiting
/// `nvidia/nemotron-3-super-120b-a12b`, which the proxy's tail logged as
/// "OpenRouter chat request refused" with the lab named.
private let modelSmokeTestsEnabled =
    ProcessInfo.processInfo.environment["FOREVERLM_MODEL_SMOKE_TESTS"] == "1"

struct ManagedModelProbe: Sendable, CustomTestStringConvertible {
    let provider: AIProvider
    let model: String
    var testDescription: String { "\(provider.rawValue) · \(model)" }
}

@Suite("Managed Model Smoke", .serialized, .enabled(if: modelSmokeTestsEnabled))
struct ManagedModelSmokeTests {
    /// Every chat model the app catalogues per managed rail, plus the closed-lab
    /// slugs the picker lists from OpenRouter's directory that the app has no
    /// static entry for. Extend the last list when a model is added to the
    /// picker without a catalog entry.
    static let probes: [ManagedModelProbe] = {
        var probes: [ManagedModelProbe] = []
        func add(_ provider: AIProvider, _ models: [String]) {
            for model in models where !AIModelDefaults.isRetiredChatModel(provider: provider, model: model) {
                probes.append(ManagedModelProbe(provider: provider, model: model))
            }
        }
        add(.anthropic, AIModelDefaults.preferredAnthropic)
        add(.openai, AIModelDefaults.preferredOpenAI)
        add(.gemini, AIModelDefaults.preferredGemini)
        add(.xai, AIModelDefaults.preferredXAI)
        add(.meta, AIModelDefaults.preferredMeta)
        add(.openRouter, AIModelDefaults.preferredOpenRouter)
        add(.openRouter, openRouterDirectoryOnly)
        var seen = Set<String>()
        return probes.filter { seen.insert($0.testDescription).inserted }
    }()

    /// Models the chat picker offers from OpenRouter's directory without a
    /// static catalog entry. Gemini 3.8 Flash is the one that failed on
    /// 2026-09-10.
    static let openRouterDirectoryOnly = [
        "google/gemini-3.8-flash",
        "anthropic/claude-sonnet-5",
        "openai/gpt-5.6-sol",
    ]

    @Test("Each catalogued chat model answers through the managed proxy", arguments: probes)
    func modelAnswers(_ probe: ManagedModelProbe) async throws {
        try #require(
            ManagedAI.isSignedIn,
            "The test host is not signed in to ForeverLM AI; sign in from the Dev app first."
        )
        var config = AITaskConfig(provider: probe.provider, apiKey: "", model: probe.model)
        config.taskLabel = "model_smoke_test"
        let nonce = UUID().uuidString.prefix(8)
        // The chat's real tool list, not a stand-in: on 2026-09-22 every
        // Gemini chat failed on a duplicated tool name that a one-tool probe
        // could never send. It costs roughly 20k input tokens per model.
        let tools = await ChatToolCatalog.assistantChatTools()
        let result: AIToolStreamResult
        do {
            result = try await AIService().streamChatWithTools(
                config: config,
                system: "Answer with one word. Do not call any tool.",
                turns: [.user("Say OK. (probe \(nonce))")],
                tools: tools,
                // Reasoning models spend the budget thinking before the word:
                // Muse Spark used 253 of 256 tokens on reasoning and reported a
                // length stop. One word costs nothing extra under a big cap.
                maxTokens: 1024
            ) { _ in }
        } catch {
            Issue.record("\(probe.testDescription) failed: \(error.localizedDescription)")
            return
        }
        // A model that answers by calling the tool has still answered.
        #expect(
            !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !result.toolCalls.isEmpty,
            "\(probe.testDescription) streamed nothing"
        )
    }

    /// Swapping the model mid-chat: the history holds a tool round another
    /// model made — its call ids, its result — and this model must take it
    /// and answer. A provider that refuses a foreign call id or an unpaired
    /// result fails here, not in the learner's chat after a switch.
    @Test("Each catalogued chat model continues a chat another model started", arguments: probes)
    func modelContinuesSwappedChat(_ probe: ManagedModelProbe) async throws {
        try #require(
            ManagedAI.isSignedIn,
            "The test host is not signed in to ForeverLM AI; sign in from the Dev app first."
        )
        var config = AITaskConfig(provider: probe.provider, apiKey: "", model: probe.model)
        config.taskLabel = "model_smoke_test"
        let nonce = UUID().uuidString.prefix(8)
        let tools = await ChatToolCatalog.assistantChatTools()
        let turns: [AIChatTurn] = [
            .user("What is on my plan today? (probe \(nonce))"),
            .assistant(text: "", toolCalls: [
                AIToolCallRequest(id: "toolu_swap_\(nonce)", name: "get_calendar_events", argumentsJSON: "{}"),
            ]),
            .toolResults([
                AIToolResultPayload(
                    callID: "toolu_swap_\(nonce)", toolName: "get_calendar_events",
                    text: "Today: read one paper on mitochondrial fission.", isError: false
                ),
            ]),
        ]
        let result: AIToolStreamResult
        do {
            result = try await AIService().streamChatWithTools(
                config: config,
                system: "Answer in one short sentence from the tool result. Do not call any tool.",
                turns: turns,
                tools: tools,
                maxTokens: 1024
            ) { _ in }
        } catch {
            Issue.record("\(probe.testDescription) refused a swapped history: \(error.localizedDescription)")
            return
        }
        #expect(
            !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !result.toolCalls.isEmpty,
            "\(probe.testDescription) streamed nothing"
        )
    }
}

// MARK: - Text to speech

/// Live probe: does every text-to-speech model OpenRouter's speech list
/// offers still speak, in its first voice, through the call playback makes?
///
/// On 2026-10-03 a stored pick, `deepgram/flux-tts:free`, had left the list,
/// and Gemini 3.8 Flash TTS answered 400 to every request ("only supports
/// response_format=pcm"); neither showed anywhere before a learner pressed
/// Listen. This sends one short synthesis per offered model through
/// `AIModelQualification.speechProbe` (`MacArticleTTSClient.openRouter`, the
/// model's catalogued response format) and records each model that fails,
/// naming whether OpenRouter refused it or the test could not finish.
///
/// Opt-in under the chat suite's switch, for the same reasons: it spends
/// real money (a sentence per model), needs the network, and the test host
/// is signed in only under that switch (`ManagedAI`). Run it with
/// `FOREVERLM_MODEL_SMOKE_TESTS=1` and
/// `-only-testing:ForeverLMMacUnitTests/ManagedSpeechModelSmokeTests`.
@Suite("Managed Speech Model Smoke", .serialized, .enabled(if: modelSmokeTestsEnabled))
struct ManagedSpeechModelSmokeTests {
    @Test("Each offered text-to-speech model speaks through OpenRouter")
    func everyModelSpeaks() async throws {
        try #require(
            ManagedAI.isSignedIn,
            "The test host is not signed in to ForeverLM AI; sign in from the Dev app first."
        )
        _ = try await OpenRouterAudioDirectory.refresh(.speech, force: true)
        try #require(ArticleSpeechCatalog.isDirectoryBacked, "OpenRouter's speech list could not be read.")
        let models = ArticleSpeechCatalog.models.map(\.id)
        #expect(!models.isEmpty)
        for model in models {
            let voice = AIModelQualification.resolvedSpeechVoice(model: model, voice: "")
            do {
                try await AIModelQualification.speechProbe(model: model, voice: voice)
            } catch {
                let label = voice.isEmpty ? model : "\(model) · \(voice)"
                if let refusal = AIModelQualification.speechFailureVerdict(for: error) {
                    Issue.record("\(label) was refused: \(refusal)")
                } else {
                    Issue.record("\(label) could not be tested: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - The chat's real tool list, as every provider receives it

/// The tools an in-app chat actually carries: the Mac's MCP catalog, mapped the
/// way `StudioAssistantSession` maps it, then filtered and merged with the
/// chat's own tools by `ReviewSessionManager`.
enum ChatToolCatalog {
    static var appTools: [ReviewSessionManager.AppToolDefinition] {
        MCPToolRegistry.shared.tools.map { tool in
            ReviewSessionManager.AppToolDefinition(
                name: tool.name,
                description: tool.description,
                inputSchemaJSON: StudioAssistantSession.jsonString(for: tool.inAppInputSchema)
            )
        }
    }

    /// The command-the-app chat with a source attached: the largest tool list
    /// any request sends.
    @MainActor
    static func assistantChatTools(
        webSearch: ReviewSessionManager.WebSearchAccess = .unavailable
    ) -> [AIToolSpec] {
        ReviewSessionManager.nativeToolSpecsForTesting(
            hasAttachedSource: true,
            appTools: appTools,
            hasSynthesisContext: true,
            mode: .assistant,
            webSearch: webSearch
        )
    }

    /// The names a provider request declares, whatever its shape: Anthropic
    /// and Responses `tools[].name`, Chat Completions `tools[].function.name`,
    /// Gemini `tools[].functionDeclarations[].name`. A server tool with no name
    /// (Responses' `web_search`) declares nothing.
    static func declaredNames(in payload: [String: Any]) -> [String] {
        let tools = payload["tools"] as? [[String: Any]] ?? []
        return tools.flatMap { tool -> [String] in
            if let declarations = tool["functionDeclarations"] as? [[String: Any]] {
                return declarations.compactMap { $0["name"] as? String }
            }
            if let function = tool["function"] as? [String: Any], let name = function["name"] as? String {
                return [name]
            }
            return (tool["name"] as? String).map { [$0] } ?? []
        }
    }

    /// Each function tool's parameter schema as the payload carries it.
    static func declaredSchemas(in payload: [String: Any]) -> [(name: String, schema: [String: Any])] {
        let tools = payload["tools"] as? [[String: Any]] ?? []
        return tools.flatMap { tool -> [(name: String, schema: [String: Any])] in
            if let declarations = tool["functionDeclarations"] as? [[String: Any]] {
                return declarations.compactMap { declaration in
                    guard let name = declaration["name"] as? String,
                          let schema = declaration["parameters"] as? [String: Any] else { return nil }
                    return (name, schema)
                }
            }
            if let function = tool["function"] as? [String: Any],
               let name = function["name"] as? String,
               let schema = function["parameters"] as? [String: Any] {
                return [(name, schema)]
            }
            if let name = tool["name"] as? String,
               let schema = (tool["input_schema"] ?? tool["parameters"]) as? [String: Any] {
                return [(name, schema)]
            }
            return []
        }
    }

    /// A name every provider takes: Anthropic and OpenAI allow
    /// `[A-Za-z0-9_-]{1,64}`, and Google also wants a letter or underscore first.
    static func isPortableToolName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// Schema faults a provider answers with a 400 for the whole request: an
    /// array without `items`, a `required` name that is not a property, a
    /// non-string `enum` (Google), and — for Google — any keyword outside the
    /// subset its function declarations accept.
    static func schemaFaults(_ schema: [String: Any], path: String, gemini: Bool) -> [String] {
        var faults: [String] = []
        if gemini {
            let allowed: Set<String> = ["type", "format", "description", "nullable", "enum", "items", "properties", "required"]
            for key in schema.keys where !allowed.contains(key) {
                faults.append("\(path): Google does not take \"\(key)\"")
            }
            if let type = schema["type"], !(type is String) {
                faults.append("\(path): Google wants one type, not \(type)")
            }
            if let values = schema["enum"] as? [Any], values.contains(where: { !($0 is String) }) {
                faults.append("\(path): Google takes string enums only")
            }
        }
        let types: [String] = (schema["type"] as? String).map { [$0] } ?? (schema["type"] as? [String] ?? [])
        if types.contains("array"), schema["items"] == nil {
            faults.append("\(path): array without items")
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for required in schema["required"] as? [String] ?? [] where properties[required] == nil {
            faults.append("\(path): requires \"\(required)\", which is not a property")
        }
        for (name, value) in properties {
            if let child = value as? [String: Any] {
                faults += schemaFaults(child, path: "\(path).\(name)", gemini: gemini)
            }
        }
        if let items = schema["items"] as? [String: Any] {
            faults += schemaFaults(items, path: "\(path)[]", gemini: gemini)
        }
        return faults
    }

    /// Everything in a request body that one provider or another refuses
    /// outright, named so a failure says which tool broke which rule.
    static func requestFaults(in payload: [String: Any], gemini: Bool) -> [String] {
        var faults: [String] = []
        if !JSONSerialization.isValidJSONObject(payload) {
            faults.append("the body is not JSON-serialisable")
        }
        let names = declaredNames(in: payload)
        var seen = Set<String>()
        for name in names where !seen.insert(name).inserted {
            faults.append("\(name) is declared twice")
        }
        for name in names where !isPortableToolName(name) {
            faults.append("\(name) is not a name every provider takes")
        }
        for (name, schema) in declaredSchemas(in: payload) {
            if schema["type"] as? String != "object" {
                faults.append("\(name): parameters are not an object schema")
            }
            faults += schemaFaults(schema, path: name, gemini: gemini)
        }
        return faults
    }
}

/// Offline and free: the request every provider receives is one it accepts.
///
/// The 2026-09-22 case: `inspect_paper_figure` had been the chat's own tool
/// and gained an MCP twin of the same name three days earlier; the agent chat
/// sent both, and Google refused every chat on Gemini with "Duplicate function
/// declaration found". The live smoke suite could not have seen it — it sent
/// one toy tool — and no offline test built the chat's real tool list. These do,
/// for every chat mode and every provider shape, so the next collision, bad
/// name or schema a provider refuses fails here instead of in a learner's chat.
@Suite("Chat Tool Requests", .serialized)
struct ChatToolRequestTests {
    static let webSearchAccesses: [ReviewSessionManager.WebSearchAccess] = [.unavailable, .native, .onRequest]

    @Test(
        "Every chat mode declares each tool once, with names and schemas every provider takes",
        arguments: ReviewSessionManager.InitialPromptMode.allCases, [true, false]
    )
    @MainActor
    func chatToolListIsValidInEveryMode(mode: ReviewSessionManager.InitialPromptMode, attached: Bool) {
        for webSearch in Self.webSearchAccesses {
            let specs = ReviewSessionManager.nativeToolSpecsForTesting(
                hasAttachedSource: attached,
                appTools: ChatToolCatalog.appTools,
                hasSynthesisContext: attached,
                mode: mode,
                webSearch: webSearch
            )
            let label = "\(mode.rawValue), attached: \(attached), web: \(webSearch)"
            #expect(!specs.isEmpty, "\(label) carries no tools")
            var seen = Set<String>()
            let duplicates = specs.map(\.name).filter { !seen.insert($0).inserted }
            #expect(duplicates.isEmpty, "\(label) declares \(duplicates) twice")
            for spec in specs {
                #expect(ChatToolCatalog.isPortableToolName(spec.name), "\(label): \(spec.name)")
                #expect(!spec.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(label): \(spec.name) has no description")
                #expect(spec.inputSchema["type"] as? String == "object", "\(label): \(spec.name)")
                let faults = ChatToolCatalog.schemaFaults(spec.inputSchema, path: spec.name, gemini: false)
                #expect(faults.isEmpty, "\(label): \(faults)")
            }
        }
    }

    @Test("The chat's own picture tools win over their MCP twins")
    @MainActor
    func nativeToolsWinOverMCPTwins() {
        // Both are in the Mac's MCP catalog and defined by the chat itself; the
        // chat's version is the one that resolves against the attached pool.
        let specs = ChatToolCatalog.assistantChatTools()
        for name in ["inspect_paper_figure", "show_source_image"] {
            let matches = specs.filter { $0.name == name }
            #expect(matches.count == 1, "\(name) is declared \(matches.count) times")
        }
        let mcpInspect = MCPToolRegistry.shared.tools.first { $0.name == "inspect_paper_figure" }
        let chatInspect = specs.first { $0.name == "inspect_paper_figure" }
        #expect(mcpInspect != nil)
        #expect(chatInspect?.description != mcpInspect?.description, "the MCP twin replaced the chat's own tool")
    }

    @Test("A duplicated tool reaches no provider twice")
    func duplicatesAreDroppedFirstWins() {
        let first = AIToolSpec(name: "a", description: "first", inputSchema: ["type": "object"])
        let second = AIToolSpec(name: "a", description: "second", inputSchema: ["type": "object"])
        let other = AIToolSpec(name: "b", description: "b", inputSchema: ["type": "object"])
        let unique = AIToolSpec.uniquedByName([first, other, second])
        #expect(unique.map(\.name) == ["a", "b"])
        #expect(unique.first?.description == "first")
    }

    /// The Chat Completions shape, for every provider whose text reaches
    /// OpenRouter — OpenRouter itself and the retired long-tail hosts whose
    /// stored selections travel there.
    static let chatCompletionsProviders = AIProvider.allCases.filter {
        AIService.routesThroughOpenRouter($0)
    }

    @Test("Each Chat Completions provider's request carries the real tool list cleanly", arguments: chatCompletionsProviders)
    func chatCompletionsShapeIsValid(_ provider: AIProvider) async {
        let tools = await ChatToolCatalog.assistantChatTools(webSearch: .native)
        let payload = await AIService().makeOpenAIStyleToolPayload(
            provider: provider, system: "s", volatileSystem: "",
            turns: [.user("Plan my day.")], tools: tools,
            maxTokens: 1024, model: AIModelDefaults.defaultOpenRouter, effort: nil,
            webSearch: true
        )
        #expect(ChatToolCatalog.declaredNames(in: payload).count == tools.count, "\(provider.rawValue) dropped tools")
        let faults = ChatToolCatalog.requestFaults(in: payload, gemini: false)
        #expect(faults.isEmpty, "\(provider.rawValue): \(faults)")
    }

    /// Swapping models mid-chat: a conversation whose tool rounds another
    /// model made is replayed to this one. Each shape must pair every result
    /// with the call it answers, or the provider refuses the history.
    @Test("A conversation another model started replays to the OpenRouter shape")
    func swappedModelHistoryPairsEveryResult() {
        let turns: [AIChatTurn] = [
            .user("Which of my papers should I read today?"),
            .assistant(text: "Let me look.", toolCalls: [
                // An Anthropic-style id and the synthesized kind Gemini gets.
                AIToolCallRequest(id: "toolu_01A", name: "list_sources", argumentsJSON: #"{"limit":5}"#),
                AIToolCallRequest(id: "gemini-call-1", name: "get_calendar_events", argumentsJSON: "{}"),
            ]),
            .toolResults([
                AIToolResultPayload(callID: "toolu_01A", toolName: "list_sources", text: "Paper A", isError: false),
                AIToolResultPayload(callID: "gemini-call-1", toolName: "get_calendar_events", text: "Nothing planned", isError: true),
            ]),
            .assistant(text: "Read Paper A.", toolCalls: []),
            .user("And after that?"),
        ]

        // Chat Completions: every tool message names a tool_calls id.
        let chat = AIService.openAIStyleToolMessages(system: "s", turns: turns)
        #expect(JSONSerialization.isValidJSONObject(chat))
        let callIDs = chat.flatMap { $0["tool_calls"] as? [[String: Any]] ?? [] }.compactMap { $0["id"] as? String }
        let toolIDs = chat.filter { $0["role"] as? String == "tool" }.compactMap { $0["tool_call_id"] as? String }
        #expect(callIDs == ["toolu_01A", "gemini-call-1"])
        #expect(toolIDs == callIDs)
    }

    /// The whole send path, stubbed at the network: `streamChatWithTools` with
    /// the chat's real tools plus a deliberate duplicate, for every catalogued
    /// model. Whatever routing does with the provider, the body that leaves the
    /// Mac declares each tool once.
    @Test("No request leaves the Mac declaring a tool twice", arguments: ManagedModelSmokeTests.probes)
    func sentRequestDeclaresEachToolOnce(_ probe: ManagedModelProbe) async throws {
        var tools = await ChatToolCatalog.assistantChatTools()
        let duplicated = try #require(tools.first { $0.name == "inspect_paper_figure" })
        tools.append(duplicated)

        ChatRequestCaptureURLProtocol.reset()
        let service = AIService(session: ChatRequestCaptureURLProtocol.session())
        let config = AITaskConfig(provider: probe.provider, apiKey: "test-key", model: probe.model)
        _ = try? await service.streamChatWithTools(
            config: config,
            system: "Answer with one word.",
            turns: [.user("Plan my day.")],
            tools: tools,
            maxTokens: 1024
        ) { _ in }

        let body = try #require(ChatRequestCaptureURLProtocol.bodies().last, "\(probe.testDescription) sent nothing")
        let payload = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any],
            "\(probe.testDescription) sent a body that is not a JSON object"
        )
        let names = ChatToolCatalog.declaredNames(in: payload)
        #expect(names.count == tools.count - 1, "\(probe.testDescription) declared \(names.count) of \(tools.count - 1) tools")
        let isGemini = payload["contents"] != nil
        let faults = ChatToolCatalog.requestFaults(in: payload, gemini: isGemini)
        #expect(faults.isEmpty, "\(probe.testDescription): \(faults)")
    }
}

/// Captures every request body and answers 400, so a send ends at once
/// without touching the network.
final class ChatRequestCaptureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Data] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatRequestCaptureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lock.lock(); captured = []; lock.unlock()
    }

    static func bodies() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        Self.lock.lock(); Self.captured.append(body); Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"captured"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
