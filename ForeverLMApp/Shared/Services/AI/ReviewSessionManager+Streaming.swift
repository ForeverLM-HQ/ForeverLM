// Part of ReviewSessionManager: streaming an assistant response, usage and cost tracking.

import Foundation
import Observation
import PDFKit
import os

extension ReviewSessionManager {
    func streamAssistantResponse(
        messageID: UUID,
        system: GenerationSystemPrompt,
        messages: [(role: String, content: String)],
        config: AITaskConfig,
        allowSourceRetrieval: Bool,
        webSearch: Bool = false
    ) async throws -> Message {
        chatMessages.append(Message(
            id: messageID,
            role: .assistant,
            content: "",
            modelProvider: config.provider.rawValue,
            modelID: config.model
        ))
        streamingMessageID = messageID
        defer { streamingMessageID = nil }

        var response = ""
        let toolCallPrefix = "<flm_tool_call>"
        var continuationAttempts = 0
        var emptyOutputRetries = 0
        var transientRetries = 0
        var contextOverflowRetries = 0
        var currentSystem = system
        var currentMessages = messages
        var currentMaxTokens = chatResponseMaxOutputTokens
        var lastStreamUIUpdate = Date.distantPast

        while true {
            do {
                let stream = await withSingleSourceUsageAttribution {
                    await aiService.streamChat(
                        system: currentSystem.stableWithSources,
                        volatileSystem: currentSystem.volatile,
                        messages: currentMessages,
                        config: config,
                        maxTokens: currentMaxTokens,
                        webSearch: webSearch
                    )
                }
                for try await delta in stream {
                    try Task.checkCancellation()
                    guard let displayDelta = displayableAssistantDelta(from: delta) else { continue }
                    response += displayDelta
                    let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    if toolCallPrefix.hasPrefix(trimmedResponse) || trimmedResponse.hasPrefix(toolCallPrefix) {
                        continue
                    }
                    publishStreamingAssistantContent(
                        messageID: messageID,
                        response: response,
                        lastUpdate: &lastStreamUIUpdate,
                        force: false
                    )
                }
                // A stream whose reader is cancelled ends like a finished one,
                // with no error. Without this, Stop mid-thought read as an empty
                // answer and sent a retry, and Stop mid-answer saved the part
                // written as the whole reply.
                try Task.checkCancellation()
                // The stream finished cleanly but produced no visible text — a
                // reasoning model that emitted only hidden thinking or metadata.
                // Retry with a direct-answer directive and a larger output budget
                // before ever surfacing an error. A reply that is only the
                // suggested-questions tail has said nothing either.
                if ChatFollowUps.hidingBlock(in: response).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   emptyOutputRetries < emptyOutputTokenRetryMaxAttempts {
                    emptyOutputRetries += 1
                    appendSystemActivity(
                        .retry,
                        slug: "empty_output_retry",
                        title: "Retrying for a visible answer",
                        detail: "the model streamed only hidden reasoning (attempt \(emptyOutputRetries) of \(emptyOutputTokenRetryMaxAttempts))",
                        before: messageID
                    )
                    currentMaxTokens = min(currentMaxTokens * 2, chatResponseMaxOutputTokensCeiling)
                    currentSystem = system
                    currentSystem.volatile += "\n\nYour previous response streamed no visible text — only hidden reasoning or metadata. Answer directly in plain text now. Lead with the answer and keep internal reasoning minimal."
                    currentMessages = messages
                    response = ""
                    continue
                }
                publishStreamingAssistantContent(
                    messageID: messageID,
                    response: response,
                    lastUpdate: &lastStreamUIUpdate,
                    force: true
                )
                break
            } catch AIError.outputTokenLimit(_) {
                let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)

                // 1) No visible text before the cap — typically a reasoning model that
                //    spent its whole output budget on hidden thinking. Give it more room
                //    and tell it to answer directly, a couple of times.
                if trimmedResponse.isEmpty,
                   emptyOutputRetries < emptyOutputTokenRetryMaxAttempts,
                   currentMaxTokens < chatResponseMaxOutputTokensCeiling {
                    emptyOutputRetries += 1
                    appendSystemActivity(
                        .retry,
                        slug: "empty_output_retry",
                        title: "Retrying for a visible answer",
                        detail: "the output budget was spent on hidden reasoning — doubling it (attempt \(emptyOutputRetries) of \(emptyOutputTokenRetryMaxAttempts))",
                        before: messageID
                    )
                    currentMaxTokens = min(currentMaxTokens * 2, chatResponseMaxOutputTokensCeiling)
                    currentSystem = system
                    currentSystem.volatile += "\n\nAnswer directly and concisely. Lead with the answer and keep internal reasoning minimal so the response fits within the output budget."
                    currentMessages = messages
                    response = ""
                    if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                        chatMessages[index].content = ""
                    }
                    continue
                }

                // 2) Have partial text and continuation budget left: compact the source
                //    context and continue the cut-off answer from where it stopped.
                if !trimmedResponse.isEmpty, continuationAttempts < outputTokenContinuationMaxAttempts {
                    continuationAttempts += 1
                    appendSystemActivity(
                        .continuation,
                        slug: "output_limit_continuation",
                        title: "Continuing past the output limit",
                        detail: "attempt \(continuationAttempts) of \(outputTokenContinuationMaxAttempts)",
                        before: messageID
                    )
                    currentSystem = GenerationSystemPrompt(
                        stable: compactedSystemPromptForOutputTokenRetry(
                            from: system.combined,
                            allowSourceRetrieval: allowSourceRetrieval
                        ),
                        volatile: ""
                    )
                    currentMessages = messages + [
                        ("assistant", trimmedResponse),
                        ("user", "Continue exactly from where you stopped. Do not repeat any text already written. Keep the continuation concise and complete the answer.")
                    ]
                    continue
                }

                // 3) Terminal: normal continuation couldn't finish within budget. Never
                //    dead-end on a raw max_tokens error — compact/summarize into a single
                //    complete, self-contained answer (or a short honest note if even that
                //    can't be produced).
                let finalAnswer = try await compactedFinalAnswerAfterOutputLimit(
                    partial: trimmedResponse,
                    system: system.combined,
                    messages: messages,
                    config: config,
                    anchorMessageID: messageID
                )
                response = finalAnswer
                if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
                    chatMessages[index].content = finalAnswer
                }
                break
            } catch {
                // Context overflow: the char→token estimate undershot and the
                // provider rejected the request as too large. This is recoverable —
                // compact the request (shrink attached source context, trim
                // accumulated tool results) and retry — so never dead-end on it.
                if !userStoppedGeneration,
                   AITransientErrorClassifier.isContextOverflow(error),
                   contextOverflowRetries < contextOverflowRetryMaxAttempts {
                    try Task.checkCancellation()
                    contextOverflowRetries += 1
                    logger.warning("Provider rejected the request as over the context window (attempt \(contextOverflowRetries)); compacting and retrying: \(error.localizedDescription)")
                    appendSystemActivity(
                        .compaction,
                        slug: "context_overflow_compaction",
                        title: "Compacted the request",
                        detail: "it exceeded the model's context window — retrying (attempt \(contextOverflowRetries) of \(contextOverflowRetryMaxAttempts))",
                        resultPreview: error.localizedDescription,
                        before: messageID
                    )
                    currentSystem.stable = compactedSystemPromptForContextOverflow(from: currentSystem.stableWithSources)
                    currentSystem.sources = ""
                    let overflowNote = "\n\nNote: the request was automatically compacted because it exceeded the model's context window. Answer from the material that remains; use retrieve_sources if a specific omitted passage is required."
                    if !currentSystem.volatile.hasSuffix(overflowNote) {
                        currentSystem.volatile += overflowNote
                    }
                    continue
                }

                // Transient provider failures (network blip, rate limit, overloaded)
                // get bounded retries with exponential backoff instead of killing the
                // turn. Anything else — auth, invalid request, cancellation — still
                // surfaces loudly.
                guard !userStoppedGeneration,
                      AITransientErrorClassifier.isTransient(error),
                      transientRetries < transientStreamRetryMaxAttempts else {
                    throw error
                }
                let rateLimited = AITransientErrorClassifier.isRateLimited(error)
                // The provider's Retry-After hint (e.g. on 429) takes precedence over
                // our default backoff when it asks for a longer wait.
                let retryAfter = AITransientErrorClassifier.retryAfterSeconds(error) ?? 0
                // A wait the server says outlasts our retry budget is not
                // something to sit through three times over — surface it now,
                // with the server's own message, which names the wait. A 429
                // carrying no hint still gets the normal backoff: upstream
                // provider limits are usually seconds, not the proxy's hour.
                guard retryAfter <= AITransientErrorClassifier.maximumRetryAfterWait else {
                    throw error
                }
                try Task.checkCancellation()
                transientRetries += 1
                let backoffSeconds = transientStreamRetryBaseDelaySeconds * pow(2.0, Double(transientRetries - 1))
                let delaySeconds = min(max(backoffSeconds, retryAfter), AITransientErrorClassifier.maximumRetryAfterWait)
                logger.warning("Transient AI stream failure (attempt \(transientRetries)), retrying in \(delaySeconds)s: \(error.localizedDescription)")
                appendSystemActivity(
                    .retry,
                    slug: "transient_stream_retry",
                    title: rateLimited ? "Waiting out an AI rate limit" : "Retrying after a connection error",
                    detail: "waiting \(Int(delaySeconds.rounded()))s (attempt \(transientRetries) of \(transientStreamRetryMaxAttempts))",
                    resultPreview: error.localizedDescription,
                    before: messageID
                )
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                let partial = response.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    // Carry the partially streamed answer forward and ask for a
                    // seamless continuation rather than restarting from scratch.
                    currentSystem = system
                    currentMessages = messages + [
                        ("assistant", partial),
                        ("user", "The connection dropped mid-response. Continue exactly from where you stopped. Do not repeat any text already written.")
                    ]
                }
                continue
            }
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ChatFollowUps.hidingBlock(in: trimmed).isEmpty else {
            chatMessages.removeAll { $0.id == messageID }
            throw AIError.apiError(Self.noVisibleAnswerMessage)
        }

        if let index = chatMessages.firstIndex(where: { $0.id == messageID }) {
            if parseRetrievalToolCall(trimmed) != nil || parseAppToolCall(trimmed) != nil {
                chatMessages[index].content = ""
            } else {
                chatMessages[index].content = parseSynthesisToolCall(trimmed) == nil
                    ? (Self.visibleAssistantText(from: trimmed) ?? trimmed)
                    : "Updating notebook notes..."
            }
        }
        return Message(id: messageID, role: .assistant, content: trimmed)
    }

    func displayableAssistantDelta(from delta: String) -> String? {
        AIStreamDeltaExtractor.text(fromRawDelta: delta)
    }

    private func publishStreamingAssistantContent(
        messageID: UUID,
        response: String,
        lastUpdate: inout Date,
        force: Bool
    ) {
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdate) >= streamUIUpdateInterval else { return }
        guard let index = chatMessages.firstIndex(where: { $0.id == messageID }) else { return }
        chatMessages[index].content = Self.visibleAssistantText(
            from: MemoryReviewSourceTurn.strippingTrailingPartialTag(
                Self.strippingTrailingPartialToolCallTag(response)
            )
        ) ?? Self.toolCallProgressMessage(for: response)
        lastUpdate = now
    }

    func finalizedVisibleResponseAfterOutputLimit(_ response: String) -> String? {
        guard let visible = Self.visibleAssistantText(from: response)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !visible.isEmpty else {
            return nil
        }
        return visible
    }

    /// Last-resort recovery when a response can't be completed within the output
    /// budget: ask the model for one concise, COMPLETE answer (compacting the
    /// cut-off draft when there is one), using a shrunken source context. Returns
    /// genuine salvaged model text when available; if compaction fails outright it
    /// surfaces the real error rather than persisting a canned apology as an answer.
    func compactedFinalAnswerAfterOutputLimit(
        partial: String,
        system: String,
        messages: [(role: String, content: String)],
        config: AITaskConfig,
        anchorMessageID: UUID? = nil
    ) async throws -> String {
        let directive: String
        if partial.isEmpty {
            directive = "Your previous attempt used the entire output budget without writing a visible answer. Answer the user's last message now in a few concise, complete sentences. Lead with the answer and do not include internal reasoning."
        } else {
            directive = """
            Your previous answer was cut off by the output token limit. Rewrite it as a concise, COMPLETE, self-contained answer in at most a few short paragraphs. Do not repeat this instruction or mention the limit.

            Cut-off draft:
            \(partial)
            """
        }
        let compactSystem = compactedSystemPromptForOutputTokenRetry(from: system, allowSourceRetrieval: false)
        let summaryMessages = messages + [(role: "user", content: directive)]

        let chipID = appendSystemActivity(
            .compaction,
            slug: "output_limit_final_compaction",
            title: "Compacting the cut-off answer",
            detail: "continuations could not finish it — rewriting as one complete answer",
            state: .running,
            before: anchorMessageID
        )

        // Surface a real compaction error loudly rather than masking it with canned
        // text — a swallowed failure here would otherwise be persisted as a graded
        // evaluation, which the no-fallback rule forbids.
        let summarized: String
        do {
            summarized = try await withSingleSourceUsageAttribution {
                try await aiService.callChat(
                    config: config,
                    system: compactSystem,
                    messages: summaryMessages,
                    maxTokens: chatResponseMaxOutputTokens
                )
            }
        } catch is CancellationError {
            removeSystemActivity(chipID)
            throw CancellationError()
        } catch {
            completeSystemActivity(
                chipID,
                state: .failed,
                title: "Could not compact the cut-off answer",
                resultPreview: error.localizedDescription
            )
            throw error
        }
        if let visible = Self.visibleAssistantText(from: summarized)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !visible.isEmpty {
            completeSystemActivity(chipID, state: .succeeded, title: "Compacted the cut-off answer")
            return visible
        }

        // Compaction produced no visible answer. Keep genuine partial model text if we
        // have it; never fabricate a canned apology as the answer/evaluation.
        if let salvaged = finalizedVisibleResponseAfterOutputLimit(partial) {
            completeSystemActivity(
                chipID,
                state: .failed,
                title: "Could not compact the cut-off answer",
                detail: "keeping the partial answer that streamed before the limit"
            )
            return salvaged
        }
        completeSystemActivity(
            chipID,
            state: .failed,
            title: "Could not compact the cut-off answer",
            detail: "the rewrite produced no visible text"
        )
        throw AIError.apiError("The provider hit its output token limit and could not produce a complete answer within budget. Narrow the question and try again.")
    }

    func compactedSystemPromptForOutputTokenRetry(
        from system: String,
        allowSourceRetrieval: Bool
    ) -> String {
        let retryInstruction = """

        The previous provider response reached its output token limit. Continue from the already-written assistant text with a shorter, bounded completion. Do not restart, do not repeat text, and ask for a narrower follow-up only if the remaining answer cannot fit.
        """
        guard !sourceContext.isEmpty else {
            return system + retryInstruction
        }

        let fullSourceContext = sourceContextForPrompt()
        let compactedSourceContext = compactedSourceContextForRetry(sourceContext)
        var compactedSystem = system
        if let range = compactedSystem.range(of: fullSourceContext) {
            compactedSystem.replaceSubrange(range, with: compactedSourceContext)
        }

        if allowSourceRetrieval {
            compactedSystem += """

            If more detail is required after this compact continuation, retrieve only the smallest focused source excerpt needed.
            """
        }

        return compactedSystem + retryInstruction
    }

    private func compactedSourceContextForRetry(_ context: String) -> String {
        let cleanContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanContext.count > compactedRetrySourceContextCharacterLimit else {
            return cleanContext
        }

        let separator = Self.sourceBlockSeparator
        let sections = cleanContext.components(separatedBy: separator)
        guard sections.count > 1 else {
            return String(cleanContext.prefix(compactedRetrySourceContextCharacterLimit))
                + "\n\n[Source context auto-compacted after the provider hit its output token limit.]"
        }

        var parts: [String] = []
        var remaining = compactedRetrySourceContextCharacterLimit

        // Every section is a loaded source block and they share the budget
        // evenly. Section 0 used to be the source inventory and was given a
        // larger slice for that reason; the inventory now rides in the
        // catalog instead, so the first source has no claim to extra room.
        for (index, section) in sections.enumerated() {
            guard remaining > 0 else { break }
            let sectionLimit = min(
                compactedRetrySectionCharacterLimit,
                max(0, remaining / max(sections.count - index, 1))
            )
            guard sectionLimit > 0 else { break }

            let compactedSection: String
            if section.count <= sectionLimit {
                compactedSection = section
            } else if let headerEnd = section.range(of: "\n\n") {
                let header = String(section[..<headerEnd.upperBound])
                let bodyBudget = max(0, sectionLimit - header.count)
                compactedSection = header
                    + String(section[headerEnd.upperBound...].prefix(bodyBudget))
                    + "\n\n[Excerpt auto-compacted for continuation.]"
            } else {
                compactedSection = String(section.prefix(sectionLimit))
                    + "\n\n[Excerpt auto-compacted for continuation.]"
            }

            parts.append(compactedSection)
            remaining -= compactedSection.count + separator.count
        }

        return parts.joined(separator: separator)
    }

    /// Aggressively compact a system prompt after the provider rejected the
    /// request as larger than its context window: shrink the attached source
    /// text to its compact retry form and trim accumulated tool results, while
    /// keeping the instruction head intact.
    func compactedSystemPromptForContextOverflow(from system: String) -> String {
        var compacted = system

        if !sourceContext.isEmpty {
            let fullSourceContext = sourceContextForPrompt()
            if let range = compacted.range(of: fullSourceContext) {
                compacted.replaceSubrange(range, with: compactedSourceContextForRetry(sourceContext))
            }
        }

        // Trim the accumulated tool-result block in place; the property is also
        // trimmed so subsequent rounds of this turn stay within budget.
        if !appToolResultContext.isEmpty,
           let start = compacted.range(of: "<foreverlm_tool_results>"),
           let end = compacted.range(of: "</foreverlm_tool_results>", range: start.upperBound..<compacted.endIndex) {
            appToolResultContext = trimmedToolResultEntries(appToolResultContext, budget: 8_000)
            compacted.replaceSubrange(
                start.upperBound..<end.lowerBound,
                with: "\n" + appToolResultContext + "\n"
            )
        }

        // Degenerate last resort: hard-cap the prompt, keeping the instruction head.
        if compacted.count > 120_000 {
            compacted = String(compacted.prefix(120_000))
                + "\n\n[Prompt hard-truncated after a context-window overflow.]"
        }
        return compacted
    }

    /// Publish the composition of the request about to be dispatched, for the
    /// composer's context gauge. Pure character arithmetic on strings already
    /// in memory — cheap enough for the main actor, once per round.
    func publishContextBreakdown(
        system: GenerationSystemPrompt,
        conversationCharacters: Int,
        toolCharacters: Int,
        config: AITaskConfig
    ) {
        // Mirrors sourceContextForPrompt()'s cap without materializing the
        // trimmed copy — this runs on the main actor once per round and the
        // context can carry 500k characters.
        //
        // The catalog counts as source, not instruction: it is per-source
        // material that scales with the pool, and folding it into
        // `instructionCharacters` would make a large notebook look like it had
        // an enormous system prompt and no attached sources.
        let sourceCharacters = min(sourceContext.count, sourceContextPromptCharacterLimit)
            + sourceManifest.count
        let providerName = config.provider.shortName
        contextBreakdown = ChatContextBreakdown(
            providerName: providerName,
            modelID: config.model,
            contextWindowTokens: AIService.contextWindowTokens(provider: config.provider, model: config.model),
            instructionCharacters: max(0, system.stableWithSources.count - sourceCharacters),
            sourceCharacters: sourceCharacters,
            toolCharacters: toolCharacters,
            conversationCharacters: conversationCharacters,
            volatileCharacters: system.volatile.count,
            perSource: perSourcePromptShares,
            // The ratio is only carried across rounds on the same model; a
            // different tokenizer would make it worse than the flat guess.
            priorCharactersPerToken: observedCharactersPerToken[calibrationKey(for: config)]
        )
        startObservingUsageEvents()
    }

    private func calibrationKey(for config: AITaskConfig) -> String {
        "\(config.provider.shortName)|\(config.model)"
    }

    /// One listener, two consumers of each recorded usage event: the session
    /// cost accumulator (any event stamped with this session's ID) and the
    /// gauge's char→token calibration (stream_chat only). Registered when a
    /// session opens or the gauge first publishes, whichever comes first.
    private func startObservingUsageEvents() {
        guard usageEventObserver == nil else { return }
        usageEventObserver = NotificationCenter.default.addObserver(
            forName: .aiUsageEventRecorded,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[AIUsageTracker.eventUserInfoKey] as? AIUsageEvent else { return }
            // `queue: .main` guarantees this block runs on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.accumulateSessionCost(from: event)
                if event.operation == "stream_chat" {
                    self.calibrateContextBreakdown(with: event)
                }
            }
        }
    }

    /// Starts the session cost at the ledger's persisted sum for this session
    /// and arms live accumulation. The cutoff taken here partitions the two:
    /// the storage sum covers rows recorded before it, the observer counts
    /// events from it on, so a row is never counted twice or missed however
    /// the load races an in-flight request.
    func beginSessionCostTracking() {
        guard let sessionID else { return }
        let cutoff = Date()
        sessionCostCutoff = cutoff
        sessionCost = ChatSessionCost()
        startObservingUsageEvents()
        Task { @MainActor [weak self, storage, logger] in
            let persisted: ChatSessionCost
            do {
                persisted = try await storage.aiUsageCost(sessionID: sessionID, before: cutoff)
            } catch {
                logger.error("Failed to load recorded session cost for \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
            // A different cutoff means another session opened while the query
            // ran; its tracking owns sessionCost now.
            guard let self, self.sessionCostCutoff == cutoff else { return }
            var merged = self.sessionCost ?? ChatSessionCost()
            merged.totalUSD += persisted.totalUSD
            merged.eventCount += persisted.eventCount
            merged.unpricedEventCount += persisted.unpricedEventCount
            self.sessionCost = merged
        }
    }

    private func accumulateSessionCost(from event: AIUsageEvent) {
        guard let sessionID, event.sessionID == sessionID,
              let cutoff = sessionCostCutoff, event.createdAt >= cutoff else { return }
        var cost = sessionCost ?? ChatSessionCost()
        if let usd = event.accountedCostUSD {
            cost.totalUSD += usd
        } else {
            cost.unpricedEventCount += 1
        }
        cost.eventCount += 1
        sessionCost = cost
    }

    func calibrateContextBreakdown(with event: AIUsageEvent) {
        guard var breakdown = contextBreakdown,
              event.provider == breakdown.providerName,
              event.model == breakdown.modelID,
              // Usage recorded before this request was assembled describes the
              // previous round; applying it would report the wrong total.
              event.createdAt >= breakdown.publishedAt else { return }
        let promptTokens = Self.promptTokens(of: event)
        guard promptTokens > 0, breakdown.totalCharacters > 0 else { return }
        breakdown.measuredPromptTokens = promptTokens
        contextBreakdown = breakdown
        observedCharactersPerToken["\(event.provider)|\(event.model)"] = breakdown.charactersPerToken
    }

    /// Total prompt tokens the provider billed, normalized across the two
    /// reporting conventions: Anthropic reports `input_tokens` exclusive of
    /// cache reads and writes, while OpenAI-style providers fold cached reads
    /// into `prompt_tokens` and don't bill cache writes separately.
    nonisolated static func promptTokens(of event: AIUsageEvent) -> Int {
        let input = event.inputTokens ?? 0
        guard event.provider == AIProvider.anthropic.shortName else { return input }
        return input + (event.cachedInputTokens ?? 0) + (event.cacheCreationInputTokens ?? 0)
    }

    /// Approximate request characters the native tool definitions add — name,
    /// description, and JSON schema per tool — for the context gauge.
    static func projectedToolCharacterCount(of tools: [AIToolSpec]) -> Int {
        tools.reduce(0) { partial, tool in
            let schemaBytes = (try? JSONSerialization.data(withJSONObject: tool.inputSchema))?.count ?? 0
            return partial + tool.name.count + tool.description.count + schemaBytes + 32
        }
    }

    /// Resolve a running harness row: final state, optionally a rewritten title
    /// and detail, and an expandable preview (e.g. the error behind a failure).
    private func completeSystemActivity(
        _ id: UUID,
        state: Message.ToolActivity.State,
        title: String? = nil,
        detail: String? = nil,
        resultPreview: String? = nil
    ) {
        guard let index = chatMessages.firstIndex(where: { $0.id == id }),
              var activity = chatMessages[index].toolActivity else { return }
        activity.state = state
        if let title { activity.customTitle = title }
        if let detail { activity.detail = detail }
        if let resultPreview { activity.resultPreview = String(resultPreview.prefix(1_200)) }
        chatMessages[index].toolActivity = activity
    }

    /// Drop a harness row entirely — used when the operation it announced was
    /// cancelled with the turn, where a frozen "running" spinner would be a lie.
    private func removeSystemActivity(_ id: UUID) {
        chatMessages.removeAll { $0.id == id }
    }

    private static func toolCallProgressMessage(for text: String) -> String {
        guard let object = toolCallObjectStatic(from: text),
              let tool = object["tool"] as? String else {
            return "Working..."
        }
        switch tool {
        case "add_to_synthesis", "replace_synthesis":
            return "Updating notebook notes..."
        case "retrieve_sources":
            return "Retrieving source context..."
        case "foreverlm_tool":
            if let name = object["name"] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Running \(name)..."
            }
            return "Running ForeverLM tool..."
        default:
            return "Working..."
        }
    }
}
