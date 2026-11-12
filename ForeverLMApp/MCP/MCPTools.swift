import Foundation
import OSLog

// MARK: - Tool Definition

struct MCPToolDef {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

extension MCPToolDef {
    /// Arguments that only mean something to a caller with no session of its own.
    /// In-app Chat already owns the review session its tool calls bind to.
    static let hostOwnedSessionArguments: Set<String> = ["operation_id"]

    /// The schema in-app Chat advertises: the remote schema minus the arguments the
    /// host already answers for. Offering them would invite the model to supply a
    /// value the app then has to ignore.
    var inAppInputSchema: [String: Any] {
        guard var properties = inputSchema["properties"] as? [String: Any] else { return inputSchema }
        let removed = Self.hostOwnedSessionArguments.filter { properties.removeValue(forKey: $0) != nil }
        guard !removed.isEmpty else { return inputSchema }
        var schema = inputSchema
        schema["properties"] = properties
        if let required = schema["required"] as? [String] {
            schema["required"] = required.filter { !removed.contains($0) }
        }
        return schema
    }
}

/// Clamp a model-supplied 0...1 score or severity so a hallucinated or out-of-range
/// value (e.g. 4.0 or -1) can never be persisted. Applied at the MCP tool boundary.
func clampUnitInterval(_ value: Double) -> Double { min(max(value, 0), 1) }
func clampUnitInterval(optional value: Double?) -> Double? { value.map { min(max($0, 0), 1) } }

// MARK: - MCP Tools Registry

/// How an MCP tool holds the cached SQLite connection while it runs.
enum MCPStoreOperationMode: Sendable {
    /// The tool only reads the cached connection. Any number of readers hold the
    /// gate together: a reader leaves no uncommitted rows for another to see.
    case shared
    /// The tool writes through the cached connection and holds the gate alone.
    case exclusive
}

/// The store gate as the running task holds it: set by the dispatcher for a
/// gated tool's whole run and by `MCPDataStore.withStoreGate` for one
/// stretch, so a stretch nested inside a hold runs under it rather than
/// queuing behind itself. A task spawned inside a hold inherits it; the hold
/// ends when its holder releases the gate, so a task that outlives it takes
/// the gate itself.
final class MCPStoreGateHold: @unchecked Sendable {
    @TaskLocal static var current: MCPStoreGateHold?

    let mode: MCPStoreOperationMode
    private let lock = AppLock()
    private var ended = false

    init(_ mode: MCPStoreOperationMode) {
        self.mode = mode
    }

    var isHeld: Bool { lock.withLock { !ended } }

    func end() {
        lock.withLock { ended = true }
    }
}

/// All MCP tool definitions and their handlers.
/// Reads/writes directly to the local knowledge.db plus synced file storage.
final class MCPToolRegistry: @unchecked Sendable {
    static let shared = MCPToolRegistry()
    let logger = Logger(subsystem: "ForeverLM", category: "MCPTools")
    let store: MCPDataStore
    /// Calls in flight by what they ask for (`repeatedCallKey`), so the same
    /// call made again while it runs waits for it. One per registry, as the
    /// store is: every caller in the app goes through `shared`.
    let repeatedCalls = MCPRepeatedCalls<ToolCallOutcome>()

    init(store: MCPDataStore = MCPDataStore()) {
        self.store = store
    }

    /// The picture object `save_course_quiz` and `set_course_quiz_picture`
    /// take (`CourseQuizPicture.parse`): a source's picture, an image in the
    /// store, or a brief for ForeverLM to draw.
    static var courseQuizPictureSchema: [String: Any] {
        [
            "type": "object",
            "description": "The picture the question is shown with: give one of image, image_id, at, page or brief.",
            "properties": [
                "image": ["type": "string", "description": "The Markdown image line (or its foreverlm://image address) that show_source_image returned for a lecture's frame or a reading's page, after you looked at it and cropped it; or that generate_image, save_image or list_images returned for an image in ForeverLM's store."],
                "image_id": ["type": "string", "description": "Instead: an image in ForeverLM's store by the image_id generate_image, save_image or list_images gave — drawn by ForeverLM, or made in ChatGPT, Claude or another app and kept with save_image. Its latest version is shown."],
                "at": ["type": "string", "description": "Instead: a time in the question's source video, seconds (265) or 4:25; the frame on screen then."],
                "page": ["type": "integer", "minimum": 1, "description": "Instead: a page of the question's source (a reading's PDF), counted from 1 within the source; crop it to the figure."],
                "crop": [
                    "type": "object",
                    "description": "With at or page: the part of the frame or page to show, as fractions of it from its top-left corner.",
                    "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]],
                    "required": ["x", "y", "width", "height"],
                ] as [String: Any],
                "brief": ["type": "string", "description": "Instead: what a picture ForeverLM draws for the question must show — the one idea it makes visible, what is drawn and how the parts relate, the few things labelled — with no invented data; add_course_quiz_pictures draws it on the learner's image model. With image_id, what that picture was made from."],
                "caption": ["type": "string", "description": "What the picture shows, in a few words that do not give the answer away."],
                "show_with": ["type": "string", "enum": ["question", "answer"], "description": "question: above the question, the learner needs it to answer. answer: shown with the grade, because it shows the answer."],
            ] as [String: Any],
            "required": ["show_with"],
        ]
    }

    static func cardImagesInputSchema(description: String) -> [String: Any] {
        [
            "type": "array",
            "maxItems": MemoryCard.maximumImagesPerFace,
            "description": description + " Each entry is the exact Markdown image line a ForeverLM image tool returned, or an object with its target and alt text. One entry per face may be a saved animation (from save_animation or list_animations), by its foreverlm-site://<animation_id>/ address: the card plays it inline with its own controls, on the back only once the back shows.",
            "items": [
                "type": ["string", "object"],
                "properties": [
                    "target": ["type": "string", "description": "A foreverlm://image source or generated-image address, or a saved animation's foreverlm-site://<animation_id>/ address."],
                    "alt": ["type": "string", "description": "A short accessible description of the picture."],
                ],
                "required": [] as [String],
            ] as [String: Any],
        ]
    }

    /// A card's other sources: `{source_id, quote}` each, for `also_from`.
    static func cardAlsoFromInputSchema(description: String) -> [String: Any] {
        [
            "type": "array",
            "maxItems": MemoryCard.maximumLinkedSources,
            "description": description,
            "items": [
                "type": "object",
                "properties": [
                    "source_id": ["type": "string", "description": "Another source the card also stands on, from list_sources, a search or find_card_sources."],
                    "quote": ["type": "string", "description": "The passage of that source that states what the card asks, copied word for word from its text (get_source_content)."],
                ],
                "required": ["source_id", "quote"],
            ] as [String: Any],
        ]
    }
    // MARK: - Tool Dispatch

    static func title(for toolName: String) -> String {
        let words = toolName.split(separator: "_").map { word -> String in
            let text = String(word)
            guard let first = text.first else { return text }
            return first.uppercased() + String(text.dropFirst())
        }
        return words
            .joined(separator: " ")
            .replacingOccurrences(of: "Mcp", with: "MCP")
            .replacingOccurrences(of: "Ai", with: "AI")
            .replacingOccurrences(of: "Pdf", with: "PDF")
            .replacingOccurrences(of: "Url", with: "URL")
            .replacingOccurrences(of: "Youtube", with: "YouTube")
    }

    /// Whether a tool changes nothing. It decides more than consent wording: a
    /// read shares the store gate and triggers no reload here, and the gateway
    /// reads it from the published catalogue (`readOnlyHint`) to decide which
    /// calls the hosted mirror may answer once the relay may have handed the
    /// call to this Mac, since a read is safe to run twice and a write is not.
    static func isReadOnlyTool(_ toolName: String) -> Bool {
        readOnlyToolNames.contains(toolName) || settingsParityReadOnlyToolNames.contains(toolName)
    }

    /// ChatGPT Apps SDK treats missing tool impact annotations as a descriptor
    /// validation error. These hints only affect client-side consent wording; the
    /// server still enforces OAuth and tool-specific validation.
    static func annotations(for toolName: String) -> [String: Any] {
        let readOnly = isReadOnlyTool(toolName)
        return [
            "readOnlyHint": readOnly,
            "destructiveHint": !readOnly && destructiveToolNames.contains(toolName),
            "openWorldHint": !readOnly && openWorldToolNames.contains(toolName),
        ]
    }

    /// The whole tool surface an ingest-scoped (`mcp:ingest`) client may use.
    /// Everything else — reads, deletes, notebook/schedule state, outbound
    /// writes — is refused at dispatch and hidden from that client's
    /// tools/list.
    static let ingestAllowedTools: Set<String> = [
        "add_source", "add_sources", "update_source_content", "get_connector_inbox",
        "import_connector_paper", "get_mcp_status", "report_connector_status",
    ]

    /// Maximum items per `add_sources` call. The hosted relay forwards a
    /// request as a single WebSocket frame, so huge batches fail in transport
    /// anyway; this cap turns that into a clear, actionable error instead.
    static let maxBatchSourceItems = 50

    static func isToolAllowed(_ name: String, scope: MCPAuthScope) -> Bool {
        switch scope {
        case .full: return true
        case .ingest: return ingestAllowedTools.contains(name)
        }
    }

    /// An ingest plugin files into the library; which Notebook a source
    /// belongs in is the learner's (and their assistant's) call, so an
    /// add_source or add_sources from that scope naming a notebook_id is
    /// refused before anything is added.
    static func ingestNotebookRefusal(_ arguments: [String: Any], access: MCPAccessContext) -> String? {
        guard access.scope == .ingest,
              MCPDataStore.nilIfBlank(arguments["notebook_id"] as? String ?? "") != nil else { return nil }
        return "Error: notebook_id is not available to an ingest-only plugin. Nothing was added; add the source without notebook_id."
    }

    static func scopeRefusalMessage(toolName: String) -> String {
        "This connection is authorized with the ingest-only scope (mcp:ingest) and cannot call \(toolName). "
            + "Ingest connections may use: \(ingestAllowedTools.sorted().joined(separator: ", ")). "
            + "Reconnect with the full scope (mcp:tools) to use the rest of ForeverLM."
    }

    /// A tool call's outcome with an explicit error flag, so in-app callers never
    /// have to infer failure from message prefixes.
    struct ToolCallOutcome {
        let text: String
        let isError: Bool
        /// Pictures the tool hands back beside its text — a paper figure, a
        /// slide — which the protocol layer emits as MCP `image` content parts
        /// after the text. Empty for every tool but the picture tools.
        var images: [MCPToolImage] = []
    }

    /// The added-to-the-library window a source search asked for, under either
    /// spelling.
    ///
    /// The filters shipped as `date_from`/`date_to`, and that name is most of
    /// why they were misused: on a library search "date" reads as the source's
    /// own date, so a model asked about a 2021 book put 2021 here and lost a
    /// round to the refusal. The advertised names now carry the axis. The old
    /// ones still work — remote MCP clients hold cached schemas, and a caller
    /// that learned them should not break for having been early.
    static func searchAddedWindow(_ arguments: [String: Any]) -> (from: String?, to: String?) {
        (
            from: arguments["added_from"] as? String ?? arguments["date_from"] as? String,
            to: arguments["added_to"] as? String ?? arguments["date_to"] as? String
        )
    }

    func callTool(name rawName: String, arguments: [String: Any], access: MCPAccessContext) async -> String {
        await callToolDetailed(name: rawName, arguments: arguments, access: access).text
    }

    /// - Parameter hostSessionID: the review session the caller is already inside.
    ///   In-app Chat is itself a recorded review session, so the session-creating
    ///   tools must bind to it instead of inserting a second, exchange-less session
    ///   row that shows up in the session browser as an unresumable phantom chat.
    ///   Remote MCP clients have no session of their own and pass nil.
    /// - Parameter access: what the caller's credential authorizes. Defaults to
    ///   `.internalFullAccess`, which is correct only for in-app callers — the
    ///   app process is the owner. Remote MCP entry points must always pass the
    ///   context derived from the request's bearer token.
    func callToolDetailed(
        name rawName: String,
        arguments: [String: Any],
        hostSessionID: String? = nil,
        access: MCPAccessContext = .internalFullAccess
    ) async -> ToolCallOutcome {
        let name = rawName
        // Defense in depth: the MCP protocol handler already refuses
        // out-of-scope calls with a JSON-RPC error before reaching here.
        guard Self.isToolAllowed(name, scope: access.scope) else {
            return ToolCallOutcome(text: "Error: \(Self.scopeRefusalMessage(toolName: rawName))", isError: true)
        }
        // Listing and stopping running work is not work to list or stop.
        if Self.runningWorkToolNames.contains(name) {
            return await performToolCall(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access)
        }
        let spendLimitUSD: Double?
        if Self.paidWorkToolNames.contains(name) {
            if let raw = arguments["approved_spend_usd"] {
                guard !(raw is Bool),
                      let number = raw as? NSNumber,
                      number.doubleValue.isFinite,
                      number.doubleValue > 0 else {
                    return ToolCallOutcome(text: "Error: approved_spend_usd must be a positive finite number.", isError: true)
                }
                spendLimitUSD = number.doubleValue
            } else {
                spendLimitUSD = MCPRunningWork.defaultSpendLimitUSD
            }
        } else {
            spendLimitUSD = nil
        }
        // A ceiling above the default is the caller's word until the learner
        // says yes in the app (security audit, 2026-11-12).
        if let spendLimitUSD, spendLimitUSD > MCPRunningWork.defaultSpendLimitUSD {
            let approved = await MCPLearnerConfirmation.ask(
                MCPLearnerConfirmation.spendRequest(
                    tool: name,
                    approvedUSD: spendLimitUSD,
                    caller: MCPLearnerConfirmation.callerName(access)
                )
            )
            guard approved else {
                return ToolCallOutcome(
                    text: String(format: "Error: the learner did not allow $%.2f for %@ in ForeverLM. Run it within the $%.2f default, or ask them to allow more when the app asks.", spendLimitUSD, name, MCPRunningWork.defaultSpendLimitUSD),
                    isError: true
                )
            }
        }
        // The same call made again while the first still runs, most often an
        // assistant retrying after its request timed out, waits for that one's
        // answer rather than doing the work twice (MCPRepeatedCalls).
        guard let key = Self.repeatedCallKey(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access) else {
            return await runListedCall(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access, spendLimitUSD: spendLimitUSD)
        }
        let outcome = await repeatedCalls.value(for: key) {
            await self.runListedCall(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access, spendLimitUSD: spendLimitUSD)
        }
        return outcome ?? ToolCallOutcome(
            text: "\(Self.stoppedResultPrefix) waiting for \(name). The same call goes on for another caller that made it.",
            isError: true
        )
    }

    /// One call, listed in `MCPRunningWork` while it runs.
    private func runListedCall(
        name: String,
        arguments: [String: Any],
        hostSessionID: String?,
        access: MCPAccessContext,
        spendLimitUSD: Double?
    ) async -> ToolCallOutcome {
        // Every other call runs as a task `cancel_ai_work` can stop, however
        // long it takes and whether or not its caller is still waiting.
        let run = await MCPRunningWork.shared.run(
            toolCall: name,
            about: MCPRunningWork.about(arguments),
            spendLimitUSD: spendLimitUSD
        ) {
            await self.performToolCall(name: name, arguments: arguments, hostSessionID: hostSessionID, access: access)
        }
        guard let stopper = run.stoppedBy, !run.value.text.hasPrefix(Self.stoppedResultPrefix) else { return run.value }
        // What a stopped call saved before it stopped is real, so the open
        // windows reload whatever the call itself answered.
        if Self.isMutatingTool(name) {
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        }
        let next = stopper == .spendLimit
            ? " Ask the learner before continuing. After explicit approval, repeat the operation with the approved total in approved_spend_usd."
            : ""
        return ToolCallOutcome(
            text: "\(Self.stoppedResultPrefix) \(stopper.answerPhrase) before \(name) finished. What it had already saved is kept.\(next)\n\n\(run.value.text)",
            isError: true,
            images: run.value.images
        )
    }

    /// One tool call: the store gate, the dispatch, and the refresh signal.
    private func performToolCall(
        name: String,
        arguments: [String: Any],
        hostSessionID: String?,
        access: MCPAccessContext
    ) async -> ToolCallOutcome {
        // One cached KnowledgeStore connection is shared by every tool. SQLite's
        // FULLMUTEX serializes individual calls, not a complete transaction, so a
        // nominally read-only tool can otherwise slip between statements and see
        // another task's uncommitted state. Hold the gate for the entire allowed
        // tool execution: a tool that writes holds it alone, a tool that only
        // reads shares it with every other reader. Non-store work inside a tool
        // deliberately shares that correctness boundary. Two kinds of tool are
        // left out: those that never touch the cached connection, and the long
        // paid ones that take the gate themselves around each stretch that
        // does, so their model calls hold nothing.
        let holdsStoreGate = !Self.storeGateExemptToolNames.contains(name)
            && !Self.selfGatedToolNames.contains(name)
            && !Self.settingsParityToolNames.contains(name)
        let gateMode = Self.storeGateMode(for: name)
        if holdsStoreGate { await store.acquireToolOperation(gateMode) }
        // Stopped while it waited for the gate, most often behind the very
        // writer the learner stopped with it: nothing has run, so nothing runs.
        if Task.isCancelled {
            if holdsStoreGate { await store.releaseToolOperation() }
            return ToolCallOutcome(text: "\(Self.stoppedResultPrefix) before \(name) started. Nothing was done.", isError: true)
        }
        let normalizedArguments = Self.normalizedArguments(
            toolName: name,
            arguments: Self.argumentsShaped(
                toSchema: tools.first(where: { $0.name == name })?.inputSchema ?? [:],
                arguments: arguments
            )
        )
        // A call an AI app made that sets ForeverLM's models to work draws its
        // popup in the Studio window while it runs (MCPToolActivity.swift).
        let activity = await store.beginToolActivity(name: name, arguments: normalizedArguments, access: access)
        let hold = holdsStoreGate ? MCPStoreGateHold(gateMode) : nil
        let chatModel = access.clientID == MCPAccessContext.internalFullAccess.clientID && ChatRequestedModel.toolNames.contains(name)
            ? ChatRequestedModel.config(forSession: hostSessionID)
            : nil
        let outcome: ToolCallOutcome = await ChatRequestedModel.$current.withValue(chatModel) {
          await MCPStoreGateHold.$current.withValue(hold) {
            await MCPToolActivityReporter.$current.withValue(activity) {
                if let media = await executeMediaTool(name: name, arguments: normalizedArguments) {
                    // The picture tools answer with text and images; every other tool
                    // is a string, and the string switch below stays as it is.
                    return ToolCallOutcome(text: media.text, isError: media.isError, images: media.images)
                }
                let result = await executeTool(
                    name: name,
                    arguments: normalizedArguments,
                    hostSessionID: hostSessionID,
                    access: access
                )
                return ToolCallOutcome(text: result, isError: Self.isFailureResult(result))
            }
          }
        }
        hold?.end()
        await activity?.end(outcome)
        if holdsStoreGate { await store.releaseToolOperation() }
        let isError = outcome.isError
        // A successful mutating tool changed persisted app state out from under any
        // open UI (the ⌘K command bar, the docked Chat column, or an external MCP
        // client). Signal the app to reload so views like the Sources sidebar and
        // today's plan don't go stale. Read-only queries and failures don't change state, so they stay quiet.
        if Self.isMutatingTool(name), !isError {
            NotificationCenter.default.post(name: .foreverLMDataDidChange, object: nil)
        }
        // A listing narrowed to a take says so (MCPTools+Sources.swift).
        return Self.notingScreenRecordNarrowing(outcome, toolName: name)
    }

    /// The tools whose answer is pictures as well as words. Nil for every
    /// other name, which then takes the string dispatch in `executeTool`.
    private func executeMediaTool(name: String, arguments: [String: Any]) async -> MCPDataStore.MediaToolResult? {
        switch name {
        case "inspect_paper_figure": return await store.inspectPaperFigure(arguments: arguments)
        case "show_source_image": return await store.showSourceImage(arguments: arguments)
        // A picture of the Canvas goes out as an image part as well as a file path.
        case "screenshot_canvas": return await store.screenshotCanvas(arguments: arguments)
        default: return await store.executeImageTool(name: name, arguments: arguments)
        }
    }

    /// An argument sent in the wrong JSON shape is read as the shape the
    /// tool's schema declares, when the value says the same thing either way.
    ///
    /// Every handler reads its arguments with a typed cast
    /// (`arguments["keywords"] as? [String] ?? []`), so a model that wrote
    /// `"keywords": "telomere"` for a list, `"limit": "5"` for an integer or
    /// `"include_archived": "true"` for a boolean had the value dropped without
    /// a word: the call then failed as if the argument were missing, or ran
    /// with the default (product owner, 2026-11-10, on a chat whose keyword
    /// search failed mid-answer: "quite often still agents just fail in their
    /// tasks"). Only a value whose type contradicts the schema is touched, and
    /// only at the top level:
    /// - a list declared, a string sent: the JSON list the string spells, or
    ///   the string as a list of one when the list holds strings. It is never
    ///   split on commas, which a phrase may contain.
    /// - an integer or number declared, a numeric string sent: the number.
    /// - a boolean declared, "true" or "false" sent: the boolean.
    /// - a string declared, a list of exactly one string sent: that string.
    static func argumentsShaped(toSchema schema: [String: Any], arguments: [String: Any]) -> [String: Any] {
        guard let properties = schema["properties"] as? [String: Any], !arguments.isEmpty else { return arguments }
        var shaped = arguments
        for (key, value) in arguments {
            guard let property = properties[key] as? [String: Any],
                  let declared = property["type"] as? String else { continue }
            switch declared {
            case "array":
                guard let text = value as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if trimmed.hasPrefix("["),
                   let data = trimmed.data(using: .utf8),
                   let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    shaped[key] = list
                } else if (property["items"] as? [String: Any])?["type"] as? String == "string" {
                    shaped[key] = [trimmed]
                }
            case "integer":
                guard let text = value as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let whole = Int(trimmed) {
                    shaped[key] = whole
                } else if let number = Double(trimmed), number.isFinite, number == number.rounded(), abs(number) < 1e15 {
                    shaped[key] = Int(number)
                }
            case "number":
                guard let text = value as? String,
                      let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      number.isFinite else { continue }
                shaped[key] = number
            case "boolean":
                guard let text = value as? String else { continue }
                switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true": shaped[key] = true
                case "false": shaped[key] = false
                default: continue
                }
            case "string":
                guard let list = value as? [Any], list.count == 1, let only = list[0] as? String else { continue }
                shaped[key] = only
            default:
                continue
            }
        }
        return shaped
    }

    /// An empty optional argument on a read-only tool means the same as leaving
    /// it out.
    ///
    /// Models routinely fill every slot in a schema, and an unused filter comes
    /// through as `""`: `search_sources_semantic` with `added_from ""` would be refused
    /// as "not a date", costing tool rounds to learn what the schema already
    /// said — omit it. A blank or whitespace
    /// string can filter on nothing, so on a tool that only reads, dropping it is
    /// exactly what the caller meant. Mutating tools keep their arguments as
    /// sent: several document `""` as a deliberate value ("pass instructions ""
    /// to clear"), and a required id that is blank should still fail on its own
    /// terms rather than silently become a different call.
    static func normalizedArguments(toolName: String, arguments: [String: Any]) -> [String: Any] {
        guard isReadOnlyTool(toolName) else { return arguments }
        return arguments.filter { _, value in
            guard let text = value as? String else { return true }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Tools that only read state; calling them must not trigger a UI refresh.
    /// This is also the gateway's read-only list (`isReadOnlyTool`, published as
    /// `readOnlyHint`): a tool here may be run again on the hosted mirror after
    /// the Mac ran it, so it must change nothing at all.
    private static let readOnlyToolNames: Set<String> = [
        "list_images", "get_image",
        // The Map's tools read it or change only what is on screen: a lens is
        // not saved until the learner keeps it, in the pane.
        "get_knowledge_map", "apply_map_lens", "clear_map_lens", "focus_map",
        // A check of the layout and a picture of it change nothing on the Canvas.
        "lint_canvas", "screenshot_canvas",
        "list_canvases",
        // The versions of one canvas kept on this Mac, listed.
        "list_canvas_versions",
        "get_canvas_memory",
        // The Atlases made, listed. get_atlas may write a concept in depth.
        "list_atlases",
        "list_running_ai_work",
        // report_connector_status is not here: it records the plugin's health
        // (its Device record, the connector's preferences), so it is a write.
        "get_mcp_status", "get_sync_status", "get_connector_inbox", "list_sources", "list_courses", "get_course", "get_lecture_papers",
        "get_course_quiz",
        "get_source_content", "list_source_actions",
        "inspect_paper_figure", "show_source_image",
        "get_walkthrough", "list_walkthroughs",
        "list_source_highlights", "search_source_highlights",
        "list_meeting_groups", "get_meeting_group", "list_meeting_action_items",
        "get_source_settings",
        "get_memory_review_settings",
        "list_cards",
        "list_source_card_coverage",
        "find_card_sources",
        "list_practices",
        // Today's cards with the wording to ask: nothing is marked asked.
        "get_due_cards",
        // A reading's questions and where each stands in Memory.
        "get_mnemonic_reading",
        "list_unconverted_zoom_recordings",
        "get_automatic_audio_settings",
        "get_day_settings",
        "get_own_router_key",
        "get_ai_usage_report", "get_ai_task_settings",
        "get_app_context",
        "list_notebooks", "get_notebook", "list_notebook_sources", "get_notebook_context",
        "list_notebook_collections",
        "list_notebook_files", "read_notebook_markdown_file", "list_docs", "read_doc",
        // A page's versions on this Mac, and the learner's spaces of pages
        // and their lists of goals and ideas.
        "list_doc_versions", "list_spaces", "list_space_lists",
        // The notes graph's reads. get_daily_note can make the day's empty
        // note when asked, so it is a writer here.
        "get_linked_references", "get_block",
        "list_teams", "list_notebook_tasks",
        // A team's requests for sources, read.
        "list_share_requests",
        "list_assignments", "get_family_plan",
        "get_calendar_events", "get_day_activity",
        "list_doc_chats", "list_doc_comments",
        "list_open_questions",
        "get_schedule", "get_today_sources", "list_goals",
        "get_goal",
        "list_ideas",
        "find_directions", "list_directions", "search_literature",
        "list_skills",
        "get_skill",
        // The notes ForeverLM keeps about the learner's work: a read.
        "list_working_notes",
        "search_sources_semantic", "search_sources_keyword", "list_shows", "filter_sources", "get_review_sessions",
        "get_review_session_transcript", "search_review_sessions",
        "list_review_session_links",
        "list_video_cited_papers",
        // A paper's stored reference list, and its PDF's reference text on request.
        "get_paper_references",
        "list_scheduled_tasks", "get_scheduled_task",
        "read_site_file",
        // The animations kept in the library, and an article's reading view
        // read from its file: neither changes anything.
        "list_animations", "get_article_reading_view",
        "list_slack_channels", "read_slack_channel", "read_slack_thread", "search_slack_messages",
        "get_linear_issue", "search_linear_issues", "list_linear_issues",
        "list_linear_teams", "list_linear_projects", "get_linear_project",
        "list_github_repositories", "get_github_repository", "list_github_files",
        "read_github_file", "search_github_code", "list_github_issues",
        "get_github_issue", "list_github_pull_requests", "get_github_pull_request",
        "list_github_commits",
        "search_notion", "get_notion_page", "list_notion_databases",
        "get_notion_database", "query_notion_database",
        "get_source_audio_status",
    ]

    /// Tools the dispatcher runs without the store gate, because nothing they
    /// run touches the cached connection.
    ///
    /// `callToolDetailed` holds the store's operation gate for a whole call so a
    /// multi-statement read never sees another tool's half-committed state. A
    /// tool whose store work goes through `notebookFileStorage` (the storage
    /// actor, which owns a connection of its own) or `withDB` (a connection
    /// opened for the one query) can neither see nor leave such state, and
    /// holding the gate across its network or model wait would only queue every
    /// other call behind it. A tool belongs here only after checking that
    /// nothing it runs calls `knowledgeStore()`; one that must, around a long
    /// wait, belongs in `selfGatedToolNames`.
    ///
    /// A Slack read is a round trip to the gateway and then to Slack — seconds,
    /// not milliseconds — and the library query it ends with opens a connection
    /// of its own. A Linear read is the same round trip and touches the store
    /// not at all; so is a GitHub read, and so is a Notion read.
    static let storeGateExemptToolNames: Set<String> = [
        // The Map lives in the Studio view model on the main actor; its one
        // library read (the cards' first highlights) goes through the storage
        // actor. Its edits write the learner's layout row through the
        // preference store, never the cached connection.
        "get_knowledge_map", "apply_map_lens", "clear_map_lens", "focus_map",
        "place_on_canvas", "take_off_canvas",
        "create_canvas_region", "update_canvas_region", "delete_canvas_region",
        "draw_canvas_arrow", "update_canvas_arrow", "delete_canvas_arrow",
        "undo_canvas", "keep_map_lens", "set_canvas_display",
        // The parity build's tools act on the same view model: a card's look,
        // Tidy Up and Align, a check of the layout, a picture of it (MCPTools+CanvasParity.swift).
        "update_canvas_card", "arrange_on_canvas", "lint_canvas", "screenshot_canvas",
        // The canvases themselves are layout rows too (MCPTools+Canvases.swift).
        "list_canvases", "create_canvas", "open_canvas", "update_canvas", "delete_canvas",
        // A canvas's versions are files beside knowledge.db and its layout row
        // (MCPTools+CanvasVersions.swift).
        "list_canvas_versions", "save_canvas_version", "restore_canvas_version",
        // The Space's lists are preference rows; their goals and ideas are
        // read through the Studio's storage actor (MCPTools+SpaceLists.swift).
        "list_space_lists", "create_space_list", "update_space_list", "delete_space_list",
        // Ask the Canvas waits on the chat model for seconds; its reads go
        // through the Studio's storage actor (MCPTools+CanvasAsk.swift).
        "ask_canvas",
        // The Atlas lives in the Studio view model; its retrieval, its rows
        // and its model calls go through the storage actor and the AI
        // service, never the cached connection, and a build takes tens of
        // seconds.
        "make_atlas", "get_atlas", "list_atlases", "delete_atlas",
        // Explains a figure it has never seen with a vision model call — tens
        // of seconds — and reads the paper through the storage actor.
        "inspect_paper_figure",
        // A stop must not queue behind the writer it stops, nor a resume
        // behind whatever is writing. None of them touches the cached
        // connection; stopping audio resolves its link token through the
        // storage actor.
        "list_running_ai_work", "cancel_ai_work", "resume_ai_work", "cancel_source_audio_generation",
        // Images live in files under the content root, never knowledge.db
        // (a notebook_id is read through the storage actor), and
        // generate_image waits on an image model for tens of seconds.
        "list_images", "get_image", "generate_image", "save_image", "rename_image", "delete_image",
        "list_slack_channels", "read_slack_channel", "read_slack_thread", "search_slack_messages",
        "get_linear_issue", "search_linear_issues", "list_linear_issues",
        "list_linear_teams", "list_linear_projects", "get_linear_project",
        "list_github_repositories", "get_github_repository", "list_github_files",
        "read_github_file", "search_github_code", "list_github_issues",
        "get_github_issue", "list_github_pull_requests", "get_github_pull_request",
        "list_github_commits",
        "search_notion", "get_notion_page", "list_notion_databases",
        "get_notion_database", "query_notion_database",
        // Long paid tools whose reads and writes all go through the storage
        // actor. Were generate_course_quizzes to hold the gate alone while
        // writing a course's quizzes on the learner's key, an assistant could
        // not read a transcript or save a quiz for minutes. A filmed
        // explainer waits on the learner's price dialog before the
        // coordinator films it.
        "generate_course_quizzes", "generate_walkthrough", "generate_explainer_video",
        // The Reader's Find on YouTube and Use Transcript: the episode is read
        // from the Studio and saved through its storage actor, around page
        // reads, YouTube calls and the learner's model.
        "find_podcast_on_youtube", "import_podcast_youtube_transcript",
        // The notes graph reads the Docs, their Markdown, the daily note and
        // the plans, and writes the note and a plan's template, through the
        // storage actor alone (MCPTools+NotesGraph.swift).
        "get_linked_references", "get_block", "get_daily_note", "append_to_daily_note", "get_plan",
        // The card review is the Studio view model's: the chosen cards are
        // read through the storage actor and dealt on the main actor, as
        // open_in_app waits on the window (MCPTools+Cards.swift).
        "practice_cards",
    ]

    /// Tools that wait on the network or a model — most of them long paid ones —
    /// which the dispatcher runs without the store gate because they
    /// take it themselves (`MCPDataStore.withStoreGate`), only around each
    /// stretch that touches the cached connection: reads shared with other
    /// readers, writes alone. Their model calls, transcriptions and downloads
    /// run between those stretches holding nothing, so a call that arrives
    /// meanwhile runs at once instead of waiting for the whole of theirs. A
    /// write that saves what a long wait produced reads its row again inside
    /// its stretch (`saveSourceAfterWait`), so an edit another call made during
    /// the wait is kept. A tool belongs here only after checking that every
    /// `knowledgeStore()` use it runs sits inside such a stretch.
    static let selfGatedToolNames: Set<String> = [
        // The lessons are written through the storage actor; each web page
        // the course cites is imported holding the gate alone, a paper read
        // by its models before the call goes on.
        "generate_course",
        // The quizzes are read and pictured through the storage actor; the
        // slides are captured in extract_video_slides' own stretches.
        "add_course_quiz_pictures",
        // Plans (or accepts an external assistant's plan) through the storage
        // actor and writes the readings there; the book and course are
        // resolved, and the report read, in shared stretches.
        "save_course_textbook_readings", "add_textbook_to_course",
        // The script is written through the storage actor; starting its audio
        // reads the library in one shared stretch.
        "generate_explainer",
        // The Notebook and its sources are read, and the overview saved,
        // through the storage actor; its audio is queued in one shared
        // stretch after the call answers.
        "generate_audio_overview",
        // The Notebook, its team, its sources and Docs are read, and the
        // report saved, through the storage actor; it never touches the
        // cached connection.
        "generate_report",
        // The sources, their decks and cards are read, and the drafts saved,
        // through the storage actor; the drafting runs after the answer.
        "draft_cards",
        // The Canvas is the Studio's, on the main actor; the passages are
        // searched, and the drafts saved, through the storage actor.
        "make_cards_from_canvas",
        // The sources and the reading are read, and each source's questions
        // saved, through the storage actor; the writing runs after the answer.
        "generate_mnemonic_reading",
        // A source's reading levels are read, and written when asked, through
        // the storage actor and the main actor's coordinator: no stretch of it
        // touches the cached connection, and a write waits on the model
        // holding nothing.
        "get_source_levels",
        // The session is read through the storage actor, and the transcript
        // attached in one stretch held alone.
        "transcribe_meeting_recording",
        // Streaming a video's frames, fetching its transcript and a model's
        // reading of its slides hold nothing; what they found is saved in
        // stretches of its own.
        "extract_video_slides", "fetch_video_transcript", "scan_video_for_cited_papers", "find_lecture_papers",
        // A paper's PDF import rewrites its whole row with what the metadata
        // model returned, so each paper holds the gate alone, and calls queued
        // meanwhile run between papers.
        "download_papers_needing_attention", "recheck_paywalled_papers",
        // A local PDF is matched and saved as a pending paper in stretches
        // held alone, around a copy and a text extraction that hold nothing;
        // its models read it after the call answers, holding the store only
        // to save. Held alone, seven imports sent together would run
        // one after another, a minute or more each, and a filter_sources
        // would wait behind them until its client timed out. import_local_file
        // routes a paper the same way, a book and a text file through the
        // Studio's storage actor.
        "import_local_pdf_as_paper", "import_local_file",
        // A paper's PDF is found, downloaded, read and looked up in the
        // scholarly indexes holding nothing; the library is asked for the
        // paper in shared stretches, and the pending paper (or a paywalled
        // one) saved in a stretch held alone that asks again. Its models read
        // it after the call answers, as a local PDF's do. A paper the library
        // lists without a PDF takes the download in a stretch held alone, its
        // metadata read included, as attach_pdf_to_paper holds it. The notebook
        // is checked and filed in stretches of their own.
        "import_paper_from_url",
        // A YouTube video's uploader is asked of YouTube holding nothing; the
        // row is then saved in one stretch held alone.
        "add_source",
        // Reads the Notebook and its sources in one shared stretch, searches
        // the web holding nothing, and reads the library's marks in a second
        // shared stretch. It writes nothing.
        "discover_sources",
        // Asks CloudKit which iCloud account this Mac syncs with, up to 4 s on
        // the first call for an account, holding nothing, then reads the
        // search index's coverage in one shared stretch. It writes nothing.
        "get_mcp_status",
    ]

    /// Writing tools whose writes never touch the cached connection.
    ///
    /// Publishing a Doc spends its time on the publishing service and records
    /// the result through the storage actor, which owns a connection of its
    /// own, and changing a passage of a site writes through the same actor;
    /// what these tools do on the cached connection is look up the sources a
    /// page cites. Holding the gate alone for that would queue every
    /// read behind an upload (a `list_teams` waiting half a minute behind a
    /// `publish_site`), so they share it like the readers they are on
    /// this connection. A tool belongs here only after checking that every
    /// write it makes goes through `notebookFileStorage`, never `knowledgeStore()`.
    static let sharedGateWritingToolNames: Set<String> = [
        "publish_doc", "unpublish_doc", "replace_site_text",
    ]

    /// How a tool holds the store gate: alone when it writes through the cached
    /// connection, shared with other readers otherwise.
    static func storeGateMode(for name: String) -> MCPStoreOperationMode {
        if !isMutatingTool(name) || sharedGateWritingToolNames.contains(name) { return .shared }
        return .exclusive
    }

    private static let destructiveToolNames: Set<String> = [
        // A region or an arrow gone from the learner's Canvas.
        "delete_canvas_region",
        "delete_canvas_arrow",
        "delete_image",
        "delete_skill",
        // A forgotten note is gone, and its line with it.
        "forget_working_note",
        "unschedule_sources",
        "clear_schedule_day",
        // Activity the app recorded goes for good, on every device.
        "forget_source_activity",
        // A skipped draft is never offered again.
        "triage_cards",
        // Starting a card over retires it and restarts its schedule, and a
        // retired card is never asked again.
        "update_card",
        "delete_notebook",
        "update_course",
        "delete_course",
        "update_notebook_notes",
        "write_notebook_markdown_file",
        "delete_source",
        "remove_source",
        "remove_course_lecture_item",
        // Replaces a quiz in the course, or removes one.
        "save_course_quiz",
        "delete_course_quiz",
        // Replaces the readings a book already has in the course.
        "save_course_textbook_readings", "add_textbook_to_course",
        "remove_all_from_podcast",
        "delete_review_session",
        "refetch_source_content",
        "clear_source_derived_data",
        "update_source",
        "update_source_content",
        "remove_connector_sources",
        "delete_scheduled_task",
        // A team Notebook's task disappears from every member's board.
        "delete_notebook_task",
        // Off ends every member's coverage under this account's plan.
        "set_family_plan",
        // An event leaves the learner's calendar, on every device it syncs to.
        "delete_calendar_event",
        "request_share",
        "list_share_requests",
        "fulfil_share_request",
        "decline_share_request",
        // The learner marked these passages by hand while reading; a deletion
        // throws away their own annotation, not derived state.
        "delete_source_highlight",
        // A walkthrough an assistant authored step by step is not regenerable
        // from anything; removing it is final.
        "delete_walkthrough",
        // The absorbed sessions' rows are archived and their text folded into
        // the survivor; splitting them apart again is by hand.
        "merge_meeting_sessions",
        // An Atlas goes for good; make_atlas writes it again on its model.
        "delete_atlas",
    ]

    private static let openWorldToolNames: Set<String> = [
        "create_x_post",
        // Read live from the learner's Slack workspace through the gateway.
        "list_slack_channels",
        "read_slack_channel",
        "read_slack_thread",
        "search_slack_messages",
        // Read live from the learner's Linear workspace through the gateway.
        "get_linear_issue",
        "search_linear_issues",
        "list_linear_issues",
        "list_linear_teams",
        "list_linear_projects",
        "get_linear_project",
        // Read live from the learner's GitHub repositories through the gateway.
        "list_github_repositories",
        "get_github_repository",
        "list_github_files",
        "read_github_file",
        "search_github_code",
        "list_github_issues",
        "get_github_issue",
        "list_github_pull_requests",
        "get_github_pull_request",
        "list_github_commits",
        // Read live from the learner's Notion workspace through the gateway.
        "search_notion",
        "get_notion_page",
        "list_notion_databases",
        "get_notion_database",
        "query_notion_database",
        "transcribe_meeting_recording",
        "attach_meeting_artifact",
        "import_meeting_transcript_files",
        // Sends every pending source's narration to the metered speech provider.
        "generate_source_audio",
        // Researches the live web, imports what it cites, and spends credits on
        // every planner and writer call.
        "generate_course",
        // Spends credits on one writer call per quiz, and can rewrite them all.
        "generate_course_quizzes",
        // Streams lecture videos for their slides and spends a call per quiz.
        "add_course_quiz_pictures",
        // Spends credits on the planning call, and replaces the book's readings.
        "add_textbook_to_course",
        // Reads a source and spends credits on the writing call, then may narrate.
        "generate_explainer",
        // Reads a Notebook's sources and spends credits on the writing and any
        // condensing calls, then may narrate.
        "generate_audio_overview",
        // Reads a Notebook's sources and spends credits on the writing and any
        // condensing calls.
        "generate_report",
        // Reads the library on a topic and spends credits on the Atlas call.
        "make_atlas",
        // Reads sources whole and spends credits on drafting their cards.
        "draft_cards",
        // Searches the sources behind the Canvas's Ideas and arrows and
        // spends credits on drafting their cards.
        "make_cards_from_canvas",
        // Reads sources whole and spends credits on writing their questions.
        "generate_mnemonic_reading",
        // Spends dollars on every filmed scene, after the app's price dialog.
        "generate_explainer_video",
        // Reads a paper and spends credits on the writing call and on every
        // animation it draws.
        "generate_walkthrough",
        "add_source",
        "add_sources",
        "import_connector_paper",
        "import_paper_from_url",
        "attach_text_file_to_source",
        "attach_pdf_to_paper",
        "attach_supplementary_pdf",
        "download_papers_needing_attention",
        "recheck_paywalled_papers",
        "follow_youtube_liked_videos",
        "follow_youtube_foreverlm_playlist",
        "import_youtube_playlist",
        // Reads the school's pages as the learner and spends speech-to-text
        // on every lecture's audio.
        "import_teachable_course",
        // Reads the learner's notebook from Google as the learner.
        "import_gemini_notebook",
        "refresh_youtube_sources",
        "extract_paper_metadata",
        "extract_article_metadata",
        "find_podcast_match",
        "resolve_podcast_match",
        // Read the episode's page and YouTube, and rank or format with the learner's model.
        "find_podcast_on_youtube",
        "import_podcast_youtube_transcript",
        "refetch_source_content",
        "import_local_pdf_as_paper",
        "import_local_file",
        "fetch_video_transcript",
        "fetch_source_from_archive",
        // Downloads the paper's PDF; scanning calls a vision model and scholarly APIs.
        "import_video_cited_paper",
        "scan_video_for_cited_papers",
        "scan_meeting_for_mentioned_papers",
        // Reads the article's page (fetching it when there is none) and spends a model call.
        "scan_article_for_linked_sources",
        // Searches the live web with the chat's model and opens the pages it
        // lists to check they are real. Kept out of `readOnlyToolNames` so a
        // client asks before it spends, at the cost of one library reload.
        "discover_sources",
        "find_lecture_papers",
        "ingest_lecture_papers",
        // Downloads storyboards and streams the video to capture slide frames.
        "extract_video_slides",
        // Asks Crossref and OpenAlex about every entry of a paper's list, a minute or
        // more; it reaches the library only through the storage actor.
        "resolve_paper_references",
    ]

    private static func isMutatingTool(_ name: String) -> Bool {
        !isReadOnlyTool(name)
    }

    /// callTool returns error/unknown-tool conditions as plain strings rather than
    /// throwing, so detect them here to avoid refreshing on a no-op.
    private static func isFailureResult(_ result: String) -> Bool {
        result.hasPrefix("Error:") || result.hasPrefix("Unknown tool:")
    }
}

// MARK: - Errors

enum MCPError: LocalizedError {
    case database(String)
    case notFound(String)
    case invalidInput(String)
    case embeddingUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .database(let msg): return "Database error: \(msg)"
        case .notFound(let msg): return msg
        case .invalidInput(let msg): return msg
        case .embeddingUnavailable(let msg): return msg
        }
    }
}
