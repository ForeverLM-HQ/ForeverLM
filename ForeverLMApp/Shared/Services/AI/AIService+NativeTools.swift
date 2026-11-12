import Foundation

// Native provider tool calling ("function calling") for the in-app chat.
//
// The chat harness historically asked models to emit tool calls as
// <flm_tool_call>{JSON}</flm_tool_call> text and re-parsed it — workable, but it
// invited malformed JSON, "I'll search now" replies that call nothing, and
// tool-call text flickering into the transcript. Native tool use lets the
// provider's protocol carry the call: the model stops with an explicit tool-use
// stop reason, arguments arrive as structured JSON, and results go back as typed
// tool-result turns. It also keeps the system prompt stable across a turn's tool
// rounds, so providers can cache it. The text protocol remains the fallback for
// providers/models that reject native tool definitions.

/// A tool the model may call natively.
struct AIToolSpec {
    let name: String
    let description: String
    /// JSON Schema object describing the tool input.
    let inputSchema: [String: Any]

    init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// A tool from the portable tutor contract, so the in-app chat and the
    /// phone's memory review declare it from one definition.
    init(portable tool: TutorToolDefinition) {
        let dictionary = tool.requestDictionary
        self.init(
            name: tool.name,
            description: tool.description,
            inputSchema: dictionary["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]]
        )
    }

    /// The tools with each name kept once, the first definition winning.
    /// Every provider refuses a request that declares one name twice — Google
    /// as "Duplicate function declaration found", the others with a 400 of
    /// their own — so no request leaves `streamChatWithTools` without this.
    static func uniquedByName(_ tools: [AIToolSpec]) -> [AIToolSpec] {
        var seen = Set<String>()
        return tools.filter { seen.insert($0.name).inserted }
    }
}

/// One tool invocation requested by the model.
struct AIToolCallRequest {
    /// Provider call id (the chat-completions `tool_call` id). Synthesized
    /// when the stream carries none.
    let id: String
    let name: String
    /// Raw JSON string of the arguments exactly as streamed by the provider.
    let argumentsJSON: String

    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

/// The app's answer to one tool call, sent back to the model.
struct AIToolResultPayload {
    let callID: String
    let toolName: String
    let text: String
    let isError: Bool
    /// Pictures the tool hands the model with its text — a browser
    /// screenshot. OpenRouter's chat-completions shape takes a result string
    /// only, so the pictures follow as a user message that names the tool they
    /// came from.
    var images: [AIChatImage] = []

    init(callID: String, toolName: String, text: String, isError: Bool, images: [AIChatImage] = []) {
        self.callID = callID
        self.toolName = toolName
        self.text = text
        self.isError = isError
        self.images = images
    }

    /// The line that introduces pictures sent after a result on routes whose
    /// tool results are text only.
    var imageFollowUpText: String {
        "Picture\(images.count == 1 ? "" : "s") returned by \(toolName)."
    }
}

/// A picture sent with a learner turn, as the bytes the provider receives.
/// Every route takes it inline as base64; the media type is one of the four
/// `ChatImagePreparation` guarantees.
struct AIChatImage: Sendable, Equatable {
    let data: Data
    let mediaType: String

    var dataURL: String { "data:\(mediaType);base64,\(data.base64EncodedString())" }

    /// What one picture is taken to cost when the request is sized in
    /// characters. Providers bill a picture at roughly 1,600 tokens whatever
    /// its byte count once it is within their pixel limits; four characters a
    /// token keeps the projection in the units the budget code already uses.
    static let projectedCharacterCount = 6_400
}

/// One turn of a tool-aware conversation.
enum AIChatTurn {
    /// The learner's turn: text plus any pictures attached to it. Pictures go
    /// before the text on every route, which is where each provider's docs
    /// say a model reads them best.
    case user(String, images: [AIChatImage] = [])
    case assistant(text: String, toolCalls: [AIToolCallRequest])
    case toolResults([AIToolResultPayload])
}

/// One web page a server-side web search cited in a reply. OpenRouter
/// normalizes every engine's citations to OpenAI-style `url_citation`
/// annotations; only the fields the chat can render are kept.
struct AIWebCitation: Equatable, Sendable {
    let url: String
    let title: String
}

extension AIWebCitation {

    /// The page this citation points at, as a key that holds across the several
    /// URL forms one page arrives under. A provider's server-side search cites
    /// the search-result URL while `fetch_web_page` cites the URL its redirect
    /// chain landed on, and the two disagree over a trailing slash, a section
    /// fragment or a site's trailing path — so comparing raw strings listed one
    /// page twice under the same title. An identifier the page itself carries
    /// (a DOI, a PubMed or PMC accession) beats any URL comparison; failing
    /// that, the library's own URL normalization decides, which is also what
    /// decides whether a kept page is already in Sources.
    var pageIdentity: String {
        if let doi = Self.doi(in: url) { return "doi:\(doi)" }
        if let accession = Self.ncbiAccession(in: url) { return accession }
        return URLNormalizer.normalize(url)
    }

    /// The title reduced to the work it names, or nil when it is too short to
    /// identify one. Titles are the only signal a citation carries that two
    /// publishers' pages are the same paper, so they have to be comparable
    /// across sites — but "Home" or "PDF" would collapse unrelated pages, so
    /// only a title long enough to name one specific work qualifies.
    var comparableWorkTitle: String? {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // "… - PMC", "… - ScienceDirect", "… | Nature": at most two suffixes,
        // so a title that is genuinely a chain of short clauses survives.
        for _ in 0..<2 {
            guard let trimmed = Self.trimmingPublisherSuffix(text) else { break }
            text = trimmed
        }
        let collapsed = text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count >= 30, collapsed.split(separator: " ").count >= 5 else { return nil }
        return collapsed
    }

    /// Whether two citations point at one page — the same URL in different
    /// clothes, or one work mirrored by its publishers.
    static func isSamePage(_ first: AIWebCitation, _ second: AIWebCitation) -> Bool {
        if first.pageIdentity == second.pageIdentity { return true }
        guard let title = first.comparableWorkTitle else { return false }
        return title == second.comparableWorkTitle
    }

    /// One row per page, in first-seen order. The first URL a page arrived
    /// under is the one kept, since that is the form the reply's prose links;
    /// a later duplicate only contributes a title when the kept row has none.
    static func deduplicated(_ citations: [AIWebCitation]) -> [AIWebCitation] {
        var kept: [AIWebCitation] = []
        var indexByIdentity: [String: Int] = [:]
        var indexByTitle: [String: Int] = [:]
        for citation in citations {
            let identity = citation.pageIdentity
            let workTitle = citation.comparableWorkTitle
            let existing = indexByIdentity[identity] ?? workTitle.flatMap { indexByTitle[$0] }
            if let existing {
                if kept[existing].title.isEmpty, !citation.title.isEmpty {
                    kept[existing] = AIWebCitation(url: kept[existing].url, title: citation.title)
                }
            } else {
                kept.append(citation)
            }
            // A page that arrived under a second URL or title is still that
            // row, so a third form finds it too rather than starting a fourth.
            let row = existing ?? kept.count - 1
            indexByIdentity[identity] = row
            if let workTitle { indexByTitle[workTitle] = row }
        }
        return kept
    }

    /// A DOI written into a URL, as publishers' landing pages, PDF endpoints
    /// and `doi.org` links all do. The query and fragment are excluded so a
    /// tracking parameter cannot become part of the identifier.
    static func doi(in urlString: String) -> String? {
        guard let match = urlString.range(
            of: #"10\.\d{4,9}/[^\s"'<>&?#]+"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        var doi = String(urlString[match]).lowercased()
        while let last = doi.last, ".,;:/".contains(last) { doi.removeLast() }
        // "10.1234/" alone is a prefix, not a DOI.
        guard let slash = doi.firstIndex(of: "/"), doi.index(after: slash) < doi.endIndex else { return nil }
        return doi
    }

    /// A PubMed or PMC accession, which the same article carries on both the
    /// current host and NCBI's older shared-domain paths. The two namespaces
    /// stay separate: a PMID and a PMCID cannot be mapped onto each other from
    /// the URL alone, so only identical accessions collapse.
    static func ncbiAccession(in urlString: String) -> String? {
        let normalized = URLNormalizer.normalize(urlString).lowercased()
        let host = normalized.split(separator: "/", maxSplits: 1).first.map(String.init) ?? normalized
        guard host == "ncbi.nlm.nih.gov" || host.hasSuffix(".ncbi.nlm.nih.gov") else { return nil }
        let path = String(normalized.dropFirst(host.count))
        if let range = path.range(of: #"pmc\d+"#, options: .regularExpression) {
            return "pmc:\(path[range])"
        }
        if host.hasPrefix("pubmed.") || path.hasPrefix("/pubmed/"),
           let range = path.range(of: #"/\d{4,9}"#, options: .regularExpression) {
            return "pmid:\(path[range].dropFirst())"
        }
        return nil
    }

    private static let publisherSuffixSeparators = [" - ", " – ", " — ", " | ", " :: "]

    /// The title without a trailing site name. A suffix that carries a digit is
    /// left alone: "Part 2" and "Page 3" name a different document, not the
    /// publisher.
    private static func trimmingPublisherSuffix(_ text: String) -> String? {
        for separator in publisherSuffixSeparators {
            guard let range = text.range(of: separator, options: .backwards) else { continue }
            let suffix = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !suffix.isEmpty,
                  suffix.split(separator: " ").count <= 3,
                  !suffix.contains(where: \.isNumber) else { continue }
            let head = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty else { continue }
            return head
        }
        return nil
    }
}

/// How much autonomous server-side searching a single response may perform.
/// Ordinary chat keeps the provider default; Deep Research asks for an explicit
/// ceiling so a long agentic search always terminates and its cost stays bounded.
///
/// No live route carries the ceiling. The first-party routes that sent it
/// (`max_uses`, `max_tool_calls`, `max_turns`) are gone, and OpenRouter's web
/// plugin takes no per-request search ceiling. It stays at the call sites so a
/// route that can carry it has it to hand.
enum AIWebSearchDepth: Sendable {
    case standard
    case deepResearch
    /// Discover's one search for a notebook's missing sources
    /// (`WebSourceDiscovery`): a single response that lists up to fifteen
    /// works, so it asks for more results than the plugin's default.
    case discovery

    /// Results OpenRouter's web plugin returns per search, as its
    /// `max_results`. The Exa engine, which every model without a native
    /// engine falls back to, returns five by default
    /// (openrouter.ai/docs/features/web-search), too few for
    /// a list of ten. Nil leaves the plugin untouched, so an ordinary body carries
    /// no `max_results`.
    var pluginMaxResults: Int? {
        switch self {
        case .standard, .deepResearch: return nil
        case .discovery: return 12
        }
    }
}

/// Outcome of streaming one assistant step with tools enabled.
struct AIToolStreamResult {
    let text: String
    let toolCalls: [AIToolCallRequest]
    /// Web-search citations the provider attached to this step, in first-seen
    /// order, one entry per page rather than per URL form. Empty when web
    /// search is off or unused.
    var webCitations: [AIWebCitation] = []
}

/// Where the reasoning a tool-chat stream shows goes, bound for the length of
/// one `streamChatWithTools` call. Carried as a task local, the way usage
/// attribution is, so each provider path's runner can reach it without every
/// provider function growing a parameter it only passes along.
enum AIReasoningStream {
    @TaskLocal static var onDelta: (@Sendable (String) -> Void)?
}

enum AINativeToolSupport {
    /// True when a provider error indicates the model/endpoint rejected native
    /// tool definitions themselves (as opposed to a tool-unrelated 4xx) — the
    /// signal to fall back to the text tool protocol for the rest of the session.
    ///
    /// That fallback is sticky and the learner never sees why their chat got
    /// worse, so this stays deliberately narrow: a request the app can fix is
    /// not a capability the provider lacks.
    static func isNativeToolRejection(_ error: Error) -> Bool {
        let message: String
        switch error {
        case AIError.httpError(let status, let text, _):
            guard (400...499).contains(status) else { return false }
            message = text
        case AIError.apiError(let text):
            message = text
        default:
            return false
        }
        let lowered = message.lowercased()

        // A malformed round-trip reaches us in the same vocabulary a refusal
        // does. It names one item of a conversation we sent, though, not a
        // capability, and the answer to it is a better request rather than
        // giving up native tools for the session — so these win outright.
        // A Responses continuation missing its `reasoning` item is the standing
        // example: it says "function_call" and "invalid_request_error", which
        // was enough to strand whole sessions on the text protocol.
        let conversationShapeMarkers = [
            "function_call", "function_call_output", "tool_call_id", "call_id",
            "reasoning", "previous_response_id",
        ]
        if conversationShapeMarkers.contains(where: { lowered.contains($0) }) { return false }

        // The capability named as a parameter or a feature, never the bare word
        // "tool" — which appears in far too much unrelated 4xx prose to carry a
        // decision this durable.
        let capabilityMarkers = [
            "tools", "tool_choice", "tool use", "tool calling", "tool-calling",
            "function calling", "function-calling", "functions",
        ]
        guard capabilityMarkers.contains(where: { lowered.contains($0) }) else { return false }

        let rejectionMarkers = [
            "not supported", "unsupported", "does not support", "no support",
            "unknown parameter", "unexpected", "unrecognized", "invalid",
            "cannot be used", "not allowed", "not available"
        ]
        return rejectionMarkers.contains { lowered.contains($0) }
    }
}

/// Accumulates streamed native tool calls across SSE events: OpenRouter's
/// OpenAI-style `delta.tool_calls` fragments keyed by index.
struct AIToolCallStreamAccumulator {
    private struct PartialCall {
        var id: String
        var name: String
        var argumentsJSON: String
    }

    private var partials: [Int: PartialCall] = [:]
    private var order: [Int] = []
    private(set) var sawToolUseStop = false
    private var citationSeen: Set<String> = []
    private(set) var webCitations: [AIWebCitation] = []

    mutating func consume(_ json: [String: Any]) {
        if let choices = json["choices"] as? [[String: Any]] {
            consumeOpenAIStyleEvent(choices)
        }
    }

    private mutating func consumeOpenAIStyleEvent(_ choices: [[String: Any]]) {
        for choice in choices {
            if choice["finish_reason"] as? String == "tool_calls" {
                sawToolUseStop = true
            }
            // Web-search citations. OpenRouter normalizes them to url_citation
            // annotations; depending on engine and stream shape they ride on the
            // delta, the (final) message, or the choice itself — read all three.
            for container in [choice["delta"], choice["message"]] {
                if let annotations = (container as? [String: Any])?["annotations"] as? [[String: Any]] {
                    consumeAnnotations(annotations)
                }
            }
            if let annotations = choice["annotations"] as? [[String: Any]] {
                consumeAnnotations(annotations)
            }
        }
        guard let delta = choices.first?["delta"] as? [String: Any],
              let toolCalls = delta["tool_calls"] as? [[String: Any]] else { return }
        for call in toolCalls {
            let index = call["index"] as? Int ?? 0
            var partial = partials[index] ?? PartialCall(id: "", name: "", argumentsJSON: "")
            if partials[index] == nil { order.append(index) }
            if let id = call["id"] as? String, !id.isEmpty {
                partial.id = id
            }
            if let function = call["function"] as? [String: Any] {
                if partial.name.isEmpty, let name = function["name"] as? String {
                    partial.name = name
                }
                if let fragment = function["arguments"] as? String {
                    partial.argumentsJSON += fragment
                }
            }
            partials[index] = partial
        }
    }

    /// Accepts both the documented nested shape
    /// `{"type":"url_citation","url_citation":{"url":…,"title":…}}` and a
    /// flattened `{"type":"url_citation","url":…}` defensively — annotation
    /// normalization is OpenRouter's, not a provider contract.
    private mutating func consumeAnnotations(_ annotations: [[String: Any]]) {
        for annotation in annotations {
            guard annotation["type"] as? String == "url_citation" else { continue }
            let body = annotation["url_citation"] as? [String: Any] ?? annotation
            appendCitation(url: body["url"] as? String, title: body["title"] as? String)
        }
    }

    private mutating func appendCitation(url rawURL: String?, title rawTitle: String?) {
        guard let url = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { return }
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let citation = AIWebCitation(url: url, title: title)
        // One annotation per claim means a page the reply leans on repeatedly
        // is annotated repeatedly, each time under whichever URL form the
        // search returned. Keep the page, not the string.
        guard citationSeen.insert(citation.pageIdentity).inserted else { return }
        webCitations.append(citation)
    }

    var toolCalls: [AIToolCallRequest] {
        order.compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            let json = partial.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIToolCallRequest(
                id: partial.id.isEmpty ? "call_\(index)" : partial.id,
                name: partial.name,
                argumentsJSON: json.isEmpty ? "{}" : json
            )
        }
    }
}

extension AIService {

    // MARK: - Native tool streaming

    /// Whether to attempt native tool calling for a provider+model. Deliberately
    /// optimistic: a provider that rejects tool definitions produces a typed 4xx
    /// that `AINativeToolSupport.isNativeToolRejection` recognizes, and the chat
    /// falls back to the text tool protocol for the rest of the session.
    static func supportsNativeTools(provider: AIProvider, model: String) -> Bool {
        true
    }

    /// Stream one assistant step of a tool-aware conversation. Text deltas are
    /// forwarded as they arrive on the service's executor; any native tool calls
    /// the model makes are accumulated and returned when the stream ends.
    /// `system` is the stable prompt head (instructions), `sourceSystem` the
    /// attached source text and `volatileSystem` the per-turn tail (history
    /// digest, retry nudges, tool results). OpenRouter receives them as
    /// separate system content blocks so the cached stable prefix survives
    /// tail churn; where the provider caches whole blocks (Anthropic) the
    /// source text is its own block, so text appended to it by a retrieval
    /// leaves the instructions' cache entry intact.
    func streamChatWithTools(
        config: AITaskConfig,
        system: String,
        sourceSystem: String = "",
        volatileSystem: String = "",
        turns: [AIChatTurn],
        tools: [AIToolSpec],
        maxTokens: Int,
        webSearch: Bool = false,
        webSearchDepth: AIWebSearchDepth = .standard,
        learnerTurnIndex: Int? = nil,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil,
        onTextDelta: @escaping (String) -> Void
    ) async throws -> AIToolStreamResult {
        let config = KeychainService.routedTextConfig(config)
        let tools = AIToolSpec.uniquedByName(tools)
        await Self.primeOpenRouterSpeedTier(for: config)
        // Defensive sizing, mirroring budgetedChatRequest: the session manager
        // compacts history and tool results before calling, so this trim is the
        // last line of defense against overflowing the model's window outright.
        let cappedMaxTokens = Self.cappedResponseTokens(
            provider: config.provider,
            model: config.model,
            requestedMaxTokens: maxTokens
        )
        let inputBudget = Self.inputCharacterBudget(
            provider: config.provider,
            model: config.model,
            requestedMaxTokens: maxTokens
        )
        var effectiveSystem = system
        var effectiveSources = sourceSystem
        var effectiveVolatile = volatileSystem
        let turnsSize = Self.projectedCharacterCount(of: turns)
        // A model with no published window is sent the request as built.
        if let inputBudget, system.count + sourceSystem.count + volatileSystem.count + turnsSize > inputBudget {
            let systemBudget = max(2_000, inputBudget - turnsSize)
            let combined = system + sourceSystem + volatileSystem
            if combined.count > systemBudget {
                // Emergency truncation collapses the stable/volatile split —
                // the request is over budget, so cache reuse is already lost.
                effectiveSystem = String(combined.prefix(systemBudget)) + Self.budgetSourceTruncationNote
                effectiveSources = ""
                effectiveVolatile = ""
            }
        }

        return try await AIReasoningStream.$onDelta.withValue(onReasoningDelta) {
            try await AIUsageAttribution.$task.withValue(config.taskLabel) {
                try await streamOpenAIStyleToolChat(
                    provider: config.provider, apiKey: config.apiKey,
                    system: effectiveSystem, sourceSystem: effectiveSources, volatileSystem: effectiveVolatile,
                    turns: turns, tools: tools, maxTokens: cappedMaxTokens, model: config.model,
                    effort: config.effort, speed: config.speed, webSearch: webSearch,
                    webSearchDepth: webSearchDepth,
                    learnerTurnIndex: learnerTurnIndex,
                    onTextDelta: onTextDelta
                )
            }
        }
    }

    /// Rough size of a tool-aware conversation in characters, for budgeting.
    static func projectedCharacterCount(of turns: [AIChatTurn]) -> Int {
        turns.reduce(0) { partial, turn in
            switch turn {
            case .user(let text, let images):
                return partial + text.count + 16 + images.count * AIChatImage.projectedCharacterCount
            case .assistant(let text, let toolCalls):
                return partial + text.count + 16 + toolCalls.reduce(0) {
                    $0 + $1.argumentsJSON.count + $1.name.count + 48
                }
            case .toolResults(let results):
                return partial + results.reduce(0) {
                    $0 + $1.text.count + 64 + $1.images.count * AIChatImage.projectedCharacterCount
                }
            }
        }
    }

    // MARK: - OpenAI-compatible providers

    private func streamOpenAIStyleToolChat(
        provider: AIProvider,
        apiKey: String,
        system: String,
        sourceSystem: String,
        volatileSystem: String,
        turns: [AIChatTurn],
        tools: [AIToolSpec],
        maxTokens: Int,
        model: String,
        effort: AIEffort?,
        speed: AISpeed?,
        webSearch: Bool,
        webSearchDepth: AIWebSearchDepth,
        learnerTurnIndex: Int?,
        onTextDelta: @escaping (String) -> Void
    ) async throws -> AIToolStreamResult {
        await Self.primeOpenRouterRegion(provider: provider, model: model)
        let payload = makeOpenAIStyleToolPayload(
            provider: provider,
            system: system,
            sourceSystem: sourceSystem,
            volatileSystem: volatileSystem,
            turns: turns,
            tools: tools,
            maxTokens: maxTokens,
            model: model,
            effort: effort,
            speed: speed,
            webSearch: webSearch,
            webSearchDepth: webSearchDepth,
            learnerTurnIndex: learnerTurnIndex
        )

        // One endpoint for every OpenRouter-backed provider.
        guard let endpoint = Self.openAICompatibleChatEndpoint(for: provider),
              let url = URL(string: endpoint) else {
            throw AIError.apiError("\(provider.shortName) has no chat-completions endpoint configured.")
        }
        try Self.requireOpenRouterRegion(payload, provider: provider)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Deterministic key order: this payload carries the tool catalogue,
        // which is part of the provider's repeated prompt prefix. An unstable
        // encoding must never create a different logical request on retry.
        request.httpBody = try AIService.stableJSONBody(payload)
        try Self.prepareOpenAICompatibleRequestForTransport(&request, provider: provider)

        return try await runToolSSE(request: request, provider: provider, model: model, onTextDelta: onTextDelta)
    }

    /// Pure payload assembly shared by production and cache-contract tests.
    /// Keeping this out of the URLSession path lets tests inspect the exact
    /// OpenRouter body that a paper chat sends, rather than testing cache
    /// helpers in isolation and assuming the final request used them.
    func makeOpenAIStyleToolPayload(
        provider: AIProvider,
        system: String,
        sourceSystem: String = "",
        volatileSystem: String,
        turns: [AIChatTurn],
        tools: [AIToolSpec],
        maxTokens: Int,
        model: String,
        effort: AIEffort?,
        speed: AISpeed? = nil,
        webSearch: Bool = false,
        webSearchDepth: AIWebSearchDepth = .standard,
        learnerTurnIndex: Int? = nil
    ) -> [String: Any] {
        let slug = Self.openAICompatibleModelID(provider: provider, model: model)
        // Source text is a block of its own only where the provider caches
        // whole blocks and honours several breakpoints (Anthropic); elsewhere
        // it stays part of the one stable block, as it always was.
        let sourcesOwnBlock = !sourceSystem.isEmpty && Self.openRouterModelSupportsCacheTTL(slug)
        let headSystem = sourcesOwnBlock ? system : system + sourceSystem
        let combinedSystem = (sourcesOwnBlock ? headSystem + sourceSystem : headSystem) + volatileSystem
        var messages = Self.openAIStyleToolMessages(system: combinedSystem, turns: turns)
        let hasVolatile = !volatileSystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if (hasVolatile || sourcesOwnBlock), !messages.isEmpty {
            var blocks: [[String: Any]] = [["type": "text", "text": headSystem]]
            if sourcesOwnBlock {
                blocks.append(["type": "text", "text": sourceSystem])
            }
            if hasVolatile {
                blocks.append(["type": "text", "text": volatileSystem])
            }
            messages[0]["content"] = blocks
        }
        var payload: [String: Any] = [
            "model": slug,
            "messages": messages,
            "stream": true,
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema,
                    ] as [String: Any],
                ] as [String: Any]
            }
        }
        if webSearch, Self.routesThroughOpenRouter(provider), Self.openRouterWebPluginAttaches(
            slug: slug,
            isToolContinuationRound: {
                if case .toolResults? = turns.last { return true }
                return false
            }(),
            isExplicitWebEscalation: {
                guard case .toolResults(let results)? = turns.last else { return false }
                return results.contains { $0.toolName == "request_web_search" && !$0.isError }
            }()
        ) {
            payload["plugins"] = [Self.openRouterWebPlugin(depth: webSearchDepth)]
        }
        payload["max_tokens"] = maxTokens
        // GPT-5 rejects an explicit temperature; everything else keeps 0.4.
        if !Self.openAIModelRequiresDefaultTemperature(slug) {
            payload["temperature"] = 0.4
        }
        if let effort,
           AIRequestOptionSupport.supportedEfforts(provider: provider, model: model).contains(effort) {
            Self.applyReasoningEffort(effort, provider: provider, to: &payload)
        }
        AIService.applyOpenRouterPayloadExtras(
            &payload,
            provider: provider,
            speed: speed,
            learnerMessageIndex: learnerTurnIndex.flatMap {
                Self.openAIStyleMessageIndex(ofLearnerTurn: $0, in: turns)
            }
        )
        return payload
    }

    /// Where `turns[turnIndex]` lands in `openAIStyleToolMessages`, counting
    /// the system message first; nil unless that turn is a learner turn.
    static func openAIStyleMessageIndex(ofLearnerTurn turnIndex: Int, in turns: [AIChatTurn]) -> Int? {
        guard turns.indices.contains(turnIndex), case .user = turns[turnIndex] else { return nil }
        var index = 1
        for turn in turns.prefix(turnIndex) {
            switch turn {
            case .user, .assistant:
                index += 1
            case .toolResults(let results):
                index += results.count + (results.contains { !$0.images.isEmpty } ? 1 : 0)
            }
        }
        return index
    }

    static func openAIStyleToolMessages(system: String, turns: [AIChatTurn]) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            switch turn {
            case .user(let text, let images):
                guard !images.isEmpty else {
                    messages.append(["role": "user", "content": text])
                    continue
                }
                // OpenRouter normalizes OpenAI-style image_url parts for every
                // vision-capable model it fronts; a model without vision
                // rejects the request and that error reaches the learner.
                var parts: [[String: Any]] = images.map { image in
                    ["type": "image_url", "image_url": ["url": image.dataURL]]
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(["type": "text", "text": text])
                }
                messages.append(["role": "user", "content": parts])
            case .assistant(let text, let toolCalls):
                var message: [String: Any] = ["role": "assistant", "content": text]
                if !toolCalls.isEmpty {
                    message["tool_calls"] = toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.argumentsJSON,
                            ],
                        ] as [String: Any]
                    }
                }
                messages.append(message)
            case .toolResults(let results):
                for result in results {
                    messages.append([
                        "role": "tool",
                        "tool_call_id": result.callID,
                        "content": result.text,
                    ])
                }
                // A tool message carries text only, so a picture a tool
                // returned follows as a user message naming the tool.
                let pictured = results.filter { !$0.images.isEmpty }
                if !pictured.isEmpty {
                    var parts: [[String: Any]] = []
                    for result in pictured {
                        parts.append(["type": "text", "text": result.imageFollowUpText])
                        parts.append(contentsOf: result.images.map { image in
                            ["type": "image_url", "image_url": ["url": image.dataURL]]
                        })
                    }
                    messages.append(["role": "user", "content": parts])
                }
            }
        }
        return messages
    }

    // MARK: - Web search (OpenRouter web plugin)

    /// The OpenRouter web plugin, engine unspecified on purpose: OpenRouter
    /// picks the provider's native web search where one exists and falls back
    /// to Exa elsewhere, so new native engines are adopted without an app
    /// update. The plain `plugins` parameter is used rather than the `:online`
    /// slug suffix because the managed proxy validates the request's `model`
    /// against OpenRouter's directory, and the suffixed slug is not in it.
    static let openRouterWebPlugin: [String: Any] = ["id": "web"]

    /// The web plugin for a search of this depth: the plain plugin, with
    /// `max_results` when the depth asks for more results than the default.
    static func openRouterWebPlugin(depth: AIWebSearchDepth) -> [String: Any] {
        var plugin = openRouterWebPlugin
        if let maxResults = depth.pluginMaxResults { plugin["max_results"] = maxResults }
        return plugin
    }

    /// Slug prefixes OpenRouter documents as having native web search: the
    /// provider injects a server-side search tool the model invokes only when
    /// it decides to, and only performed searches bill. Everything else falls
    /// back to the Exa engine, which runs one search per request
    /// unconditionally (openrouter.ai/docs/features/web-search, 2026-07-21).
    static func openRouterSlugHasNativeWebSearch(_ slug: String) -> Bool {
        let lowered = slug.lowercased()
        return ["anthropic/", "openai/", "google/", "x-ai/", "perplexity/"]
            .contains { lowered.hasPrefix($0) }
    }

    /// Whether an enabled web search actually rides on this request.
    ///
    /// Native engines attach whenever web escalation enables them: idle tool
    /// costs nothing. Exa normally stays off tool-result continuation rounds
    /// because it searches unconditionally, but the dedicated escalation marker
    /// deliberately enables it for exactly that next round.
    static func openRouterWebPluginAttaches(
        slug: String,
        isToolContinuationRound: Bool,
        isExplicitWebEscalation: Bool = false
    ) -> Bool {
        if openRouterSlugHasNativeWebSearch(slug) { return true }
        return !isToolContinuationRound || isExplicitWebEscalation
    }

    /// How a model reaches OpenRouter's prompt cache; the rule lives in
    /// `OpenRouterCachePolicy` so the iPhone request builder shares it.
    static func openRouterCachePolicy(for model: String) -> OpenRouterCachePolicy {
        OpenRouterCachePolicy.policy(for: model)
    }

    /// Models for which OpenRouter documents explicit `cache_control`.
    static func openRouterModelNeedsExplicitCacheControl(_ model: String) -> Bool {
        if case .explicitBreakpoints = openRouterCachePolicy(for: model) { return true }
        return false
    }

    /// Whether a `ttl` may ride along with the OpenRouter cache breakpoints.
    /// OpenRouter documents `"ttl": "1h"` for Anthropic models only; its
    /// Alibaba/Qwen and Gemini caching use provider-managed/default TTLs; whether
    /// either ignores or rejects Anthropic's `ttl` field is undocumented, so we
    /// don't send it there
    /// (openrouter.ai/docs/features/prompt-caching, 2026-07-18).
    static func openRouterModelSupportsCacheTTL(_ model: String) -> Bool {
        if case .explicitBreakpoints(let ttl) = openRouterCachePolicy(for: model) {
            return ttl != nil
        }
        return false
    }

    /// Add prompt-cache breakpoints to an OpenAI-format message array: the
    /// system prompt and the trailing user or tool message are converted to
    /// multipart text blocks carrying `cache_control`. On the system message
    /// the marker goes on the FIRST block — when the content was pre-split
    /// into [stable head, volatile tail] the breakpoint must sit at the end
    /// of the stable head, and single-block content is first == last. On the
    /// trailing message it goes on the last block; marking tool-result
    /// messages matters because mid-loop requests end on `role: "tool"`, and
    /// without a breakpoint there every tool round re-reads the whole
    /// conversation (including large tool results) at the uncached rate.
    /// OpenRouter forwards the markers to providers that discount cached reads
    /// and strips them elsewhere. Empty content is left untouched (Anthropic
    /// rejects empty text blocks).
    ///
    /// The marker always goes INSIDE a content block, never at the message top
    /// level — string content is wrapped into a one-element text block to carry
    /// it. On the OpenAI wire format OpenRouter honours only content-part
    /// markers: a top-level `cache_control` is ignored on assistant messages
    /// and has been reported to hang the request on `role: "tool"`. That is
    /// also why an empty trailing message is skipped rather than given a
    /// top-level marker.
    ///
    /// `systemTTL` extends the system breakpoint past Anthropic's default
    /// 5 minutes (pass `"1h"` where supported); the trailing-message breakpoint
    /// always keeps the default. Anthropic requires longer-TTL breakpoints to
    /// precede shorter ones, and the system message sorts first, so 1h → 5m
    /// satisfies that ordering.
    ///
    /// `markTrailingMessage: false` leaves the trailing message unmarked, for a
    /// request that will not be sent again (a one-shot task whose only user turn
    /// is a document read once): where a write bills above the plain input rate,
    /// marking that turn would pay the premium for nothing.
    ///
    /// A system message whose second block is the source text
    /// (`isSourceTextBlock`) gets a breakpoint on that block too, with the same
    /// ttl: the instructions and the text then cache apart, and a retrieval
    /// that appends to the text rewrites only the text. `historyBreakpointBefore`
    /// is the index of the per-turn tail message; the last message ahead of it
    /// that can carry a marker gets one (default ttl), because the next turn
    /// repeats the conversation up to there and nothing after it. Anthropic
    /// allows four breakpoints: head, source text, history, trailing message.
    static func openAIStyleMessagesMarkingCacheBreakpoints(
        _ messages: [[String: Any]],
        systemTTL: String? = nil,
        markTrailingMessage: Bool = true,
        historyBreakpointBefore tailIndex: Int? = nil
    ) -> [[String: Any]] {
        var marked = messages

        func markedBlocks(_ content: Any?, markFirst: Bool, ttl: String?) -> [[String: Any]]? {
            var marker: [String: Any] = ["type": "ephemeral"]
            if let ttl {
                marker["ttl"] = ttl
            }
            if var blocks = content as? [[String: Any]], !blocks.isEmpty {
                let index = markFirst ? 0 : blocks.count - 1
                blocks[index]["cache_control"] = marker
                return blocks
            }
            if let text = content as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [
                    [
                        "type": "text",
                        "text": text,
                        "cache_control": marker,
                    ] as [String: Any]
                ]
            }
            return nil
        }

        if let systemIndex = marked.firstIndex(where: { ($0["role"] as? String) == "system" }),
           let blocks = markedBlocks(marked[systemIndex]["content"], markFirst: true, ttl: systemTTL) {
            marked[systemIndex]["content"] = blocks
        }
        if let systemIndex = marked.firstIndex(where: { ($0["role"] as? String) == "system" }),
           var blocks = marked[systemIndex]["content"] as? [[String: Any]],
           blocks.count == 2, isSourceTextBlock(blocks[1]),
           let sourceText = blocks[1]["text"] as? String,
           !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var marker: [String: Any] = ["type": "ephemeral"]
            if let systemTTL {
                marker["ttl"] = systemTTL
            }
            blocks[1]["cache_control"] = marker
            marked[systemIndex]["content"] = blocks
        }
        if let tailIndex, tailIndex > 0, tailIndex <= marked.count {
            let systemIndex = marked.firstIndex(where: { ($0["role"] as? String) == "system" })
            // Walk back past a message that cannot carry a marker (an assistant
            // turn that is only tool calls has no text block).
            for index in stride(from: tailIndex - 1, through: 0, by: -1) where index != systemIndex {
                guard let blocks = markedBlocks(marked[index]["content"], markFirst: false, ttl: nil) else { continue }
                marked[index]["content"] = blocks
                break
            }
        }
        if markTrailingMessage,
           let lastIndex = marked.indices.last,
           let role = marked[lastIndex]["role"] as? String,
           role == "user" || role == "tool",
           let blocks = markedBlocks(marked[lastIndex]["content"], markFirst: false, ttl: nil) {
            marked[lastIndex]["content"] = blocks
        }
        return marked
    }

    // MARK: - Shared SSE runner

    private func runToolSSE(
        request: URLRequest,
        provider: AIProvider,
        model: String,
        onTextDelta: @escaping (String) -> Void
    ) async throws -> AIToolStreamResult {
        var accumulator = AIToolCallStreamAccumulator()
        var text = ""
        let onReasoningDelta = AIReasoningStream.onDelta
        try await streamSSE(
            request: request,
            usageProvider: provider.shortName,
            usageModel: model,
            onEvent: { json in
                accumulator.consume(json)
                if let onReasoningDelta, let reasoning = AIStreamDeltaExtractor.reasoning(from: json) {
                    onReasoningDelta(reasoning)
                }
                return AIStreamDeltaExtractor.text(from: json)
            },
            onDelta: { delta in
                text += delta
                onTextDelta(delta)
            }
        )
        return AIToolStreamResult(
            text: text,
            toolCalls: accumulator.toolCalls,
            webCitations: accumulator.webCitations
        )
    }
}
