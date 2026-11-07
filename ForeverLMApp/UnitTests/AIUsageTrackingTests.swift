import Foundation
import SQLite3
import Testing
@testable import ForeverLM

@Suite("AI Usage Tracking")
struct AIUsageTrackingTests {
    private enum RequirementFailure: Error {
        case missingValue
    }

    @Test("Usage task labels describe the work performed")
    func usageTaskLabelsUseActiveVerbs() {
        #expect(AIUsageTaskLabel.text(for: "paper_metadata") == "Extract Paper Metadata")
        #expect(AIUsageTaskLabel.text(for: "paper_narration_preparation") == "Cleanup Content")
        #expect(AIUsageTaskLabel.text(for: "realtime_review_preparation") == "Create Review Questions")
        #expect(AIUsageTaskLabel.text(for: "review_dictation") == "Transcribe Review Dictation")
        #expect(AIUsageTaskLabel.text(for: "unknown_background_job") == "Unknown Background Job")
    }

    @Test("Source workflow attribution carries stable identity through child tasks")
    func sourceWorkflowAttributionCarriesStableIdentity() async {
        let article = StudioArticle(
            url: "https://example.com/watch?v=source-attribution",
            title: "A Source",
            sourceType: .video,
            id: "source-stable-id"
        )
        let source = AIUsageSource(source: article)

        let captured = await AIUsageAttribution.withSource(
            source,
            activityID: "activity-stable-id"
        ) {
            await Task {
                (
                    AIUsageAttribution.subjectID,
                    AIUsageAttribution.subjectType,
                    AIUsageAttribution.sourceTitle,
                    AIUsageAttribution.activityID
                )
            }.value
        }

        #expect(captured.0 == "source-stable-id")
        #expect(captured.1 == "video")
        #expect(captured.2 == "A Source")
        #expect(captured.3 == "activity-stable-id")
    }

    @Test("Podcast source attribution uses episode ledger type")
    func podcastSourceAttributionUsesEpisodeLedgerType() {
        let episode = StudioArticle(
            url: "podcast://episode/1",
            title: "Episode One",
            sourceType: .podcast,
            id: "episode-1"
        )
        #expect(AIUsageSource(source: episode).type == "podcast_episode")
    }

    @Test("Activity identity falls back to session and then event")
    func activityIdentityFallbacks() {
        #expect(AIUsageAttribution.resolvedActivityID(
            " activity-1 ",
            sessionID: "session-1",
            fallback: "event-1"
        ) == "activity-1")
        #expect(AIUsageAttribution.resolvedActivityID(
            "  ",
            sessionID: " session-1 ",
            fallback: "event-1"
        ) == "session-1")
        #expect(AIUsageAttribution.resolvedActivityID(
            nil,
            sessionID: nil,
            fallback: "event-1"
        ) == "event-1")
    }

    @Test("Parses OpenAI-compatible usage details")
    func parsesOpenAIUsageDetails() throws {
        let json = try expectJSONObject("""
        {
          "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 25,
            "total_tokens": 125,
            "prompt_tokens_details": { "cached_tokens": 40 },
            "completion_tokens_details": { "reasoning_tokens": 7 }
          }
        }
        """)

        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.inputTokens == 100)
        #expect(report.outputTokens == 25)
        #expect(report.cachedInputTokens == 40)
        #expect(report.reasoningTokens == 7)
        #expect(report.totalTokens == 125)
    }

    @Test("Parses Anthropic cache read and write usage")
    func parsesAnthropicCacheUsage() throws {
        let json = try expectJSONObject("""
        {
          "usage": {
            "input_tokens": 200,
            "output_tokens": 50,
            "cache_read_input_tokens": 80,
            "cache_creation_input_tokens": 15
          }
        }
        """)

        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.inputTokens == 200)
        #expect(report.outputTokens == 50)
        #expect(report.cachedInputTokens == 80)
        #expect(report.cacheCreationInputTokens == 15)
    }

    @Test("Extracts the served model from an Anthropic response")
    func extractsServedModelFromAnthropicResponse() throws {
        let json = try expectJSONObject("""
        {
          "model": "claude-opus-4-8-20260115",
          "usage": { "input_tokens": 200, "output_tokens": 50 }
        }
        """)

        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.servedModel == "claude-opus-4-8-20260115")
    }

    @Test("Extracts the served model from an Anthropic message_start stream event")
    func extractsServedModelFromMessageStartEvent() throws {
        let json = try expectJSONObject("""
        {
          "type": "message_start",
          "message": {
            "model": "claude-opus-4-8-20260115",
            "usage": { "input_tokens": 200, "output_tokens": 1 }
          }
        }
        """)

        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.servedModel == "claude-opus-4-8-20260115")
    }

    @Test("Served model differs only for a real provider substitution")
    func servedModelDetectsOnlyRealSubstitution() {
        // Substitution: a Fable request answered by Opus is recorded as Opus.
        let downgraded = AIUsageReport(servedModel: "claude-opus-4-8-20260115")
        #expect(downgraded.servedModelIfDifferent(fromRequested: "claude-fable-5") == "claude-opus-4-8-20260115")

        // A dated snapshot of the requested alias is the same model, not a fallback.
        let snapshot = AIUsageReport(servedModel: "claude-fable-5-20260514")
        #expect(snapshot.servedModelIfDifferent(fromRequested: "claude-fable-5") == nil)

        // Identical, namespaced, and missing echoes are not substitutions.
        let echo = AIUsageReport(servedModel: "claude-sonnet-5")
        #expect(echo.servedModelIfDifferent(fromRequested: "claude-sonnet-5") == nil)
        let namespacedEcho = AIUsageReport(servedModel: "anthropic/claude-sonnet-5")
        #expect(namespacedEcho.servedModelIfDifferent(fromRequested: "claude-sonnet-5") == nil)
        #expect(AIUsageReport.empty.servedModelIfDifferent(fromRequested: "claude-fable-5") == nil)
    }

    @Test("A router's pick is not a substitution, but the Free Models Router must land on a free model")
    func routerPicksAreNotSubstitutions() {
        let freePick = AIUsageReport(servedModel: "inclusionai/ling-3.0-flash-sante:free")
        #expect(freePick.servedModelIfDifferent(fromRequested: "openrouter/free") == "inclusionai/ling-3.0-flash-sante:free",
                "the ledger still records the model that ran")
        #expect(freePick.rejectedSubstitution(fromRequested: "openrouter/free") == nil)
        #expect(AIUsageReport(servedModel: "google/gemini-3.8-flash").rejectedSubstitution(fromRequested: "openrouter/free")
                == "google/gemini-3.8-flash", "a paid pick behind the free router is refused")
        #expect(AIUsageReport(servedModel: "anthropic/claude-sonnet-5").rejectedSubstitution(fromRequested: "openrouter/auto") == nil)
        #expect(AIUsageReport(servedModel: "claude-opus-4-8-20260115").rejectedSubstitution(fromRequested: "claude-fable-5")
                == "claude-opus-4-8-20260115", "a named model is still held to itself")
    }

    @Test("A router's safety-classifier pick is refused; a named classifier and other picks are not")
    func routerSafetyClassifierPicksAreRefused() {
        let classifier = AIUsageReport(servedModel: "nvidia/nemotron-3.5-content-safety:free")
        #expect(classifier.routedSafetyClassifier(fromRequested: "openrouter/free")
                == "nvidia/nemotron-3.5-content-safety:free")
        #expect(AIUsageReport(servedModel: "meta-llama/llama-guard-4-12b").routedSafetyClassifier(fromRequested: "openrouter/auto")
                == "meta-llama/llama-guard-4-12b")
        #expect(AIUsageReport(servedModel: "openai/gpt-oss-safeguard-20b").routedSafetyClassifier(fromRequested: "openrouter/auto")
                == "openai/gpt-oss-safeguard-20b")
        #expect(classifier.routedSafetyClassifier(fromRequested: "nvidia/nemotron-3.5-content-safety:free") == nil,
                "a model the learner named is held to their choice")
        #expect(AIUsageReport(servedModel: "inclusionai/ling-3.0-flash-sante:free").routedSafetyClassifier(fromRequested: "openrouter/free") == nil)
        #expect(AITransientErrorClassifier.isTransient(AIError.safetyClassifierAnswer(model: "nvidia/nemotron-3.5-content-safety:free")),
                "the router picks again on the next request")
    }

    @Test("Recording a router's safety-classifier pick throws its own error")
    func recordingRouterSafetyClassifierPickThrows() async {
        let service = AIService(session: .shared)
        do {
            try await service.recordUsage(
                provider: "OpenRouter",
                model: "openrouter/free",
                operation: "text_completion",
                fallbackReport: AIUsageReport(
                    inputTokens: 1721,
                    outputTokens: 223,
                    servedModel: "nvidia/nemotron-3.5-content-safety:free"
                )
            )
            Issue.record("A safety verdict was accepted as an answer")
        } catch AIError.safetyClassifierAnswer(let model) {
            #expect(model == "nvidia/nemotron-3.5-content-safety:free")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Provider model substitutions are rejected")
    func providerModelSubstitutionsAreRejected() async {
        let service = AIService(session: .shared)
        await #expect(throws: AIError.self) {
            try await service.recordUsage(
                provider: "Anthropic",
                model: "claude-fable-5",
                operation: "text_completion",
                fallbackReport: AIUsageReport(
                    inputTokens: 10,
                    outputTokens: 5,
                    servedModel: "claude-opus-4-8-20260115"
                )
            )
        }
    }

    @Test("Stream merge keeps the served model from message_start")
    func streamMergeKeepsServedModel() {
        var accumulated = AIUsageReport.empty
        accumulated.merge(AIUsageReport(inputTokens: 200, servedModel: "claude-opus-4-8-20260115"))
        accumulated.merge(AIUsageReport(outputTokens: 90))
        #expect(accumulated.servedModel == "claude-opus-4-8-20260115")
        #expect(accumulated.inputTokens == 200)
        #expect(accumulated.outputTokens == 90)
    }

    @Test("Persists usage events locally without enqueuing sync")
    func persistsUsageEventsLocallyWithoutSync() throws {
        let store = try KnowledgeStore(inMemory: true)
        let event = AIUsageEvent(
            id: "usage-1",
            provider: "OpenAI",
            model: "gpt-5.5",
            operation: "chat_completion",
            task: "chat",
            sessionID: "session-1",
            createdAt: Date(timeIntervalSinceReferenceDate: 1_234),
            inputTokens: 10,
            outputTokens: 5,
            cachedInputTokens: nil,
            cacheCreationInputTokens: nil,
            reasoningTokens: 2,
            audioInputTokens: nil,
            audioOutputTokens: nil,
            imageCount: nil,
            totalTokens: 17,
            characterCount: nil,
            durationSeconds: nil,
            providerReportedCost: 0.0012,
            estimatedCost: 0.0002,
            currency: "USD",
            rawUsageJSON: #"{"total_tokens":17}"#,
            clientPlatform: "macOS",
            latencyMilliseconds: 1_870
        )

        try store.saveAIUsageEvent(event)

        guard let loaded = try store.loadAIUsageEventForSync("usage-1") else {
            throw RequirementFailure.missingValue
        }
        #expect(loaded.model == "gpt-5.5")
        #expect(loaded.totalTokens == 17)
        #expect(loaded.latencyMilliseconds == 1_870)
        #expect(loaded.sessionID == "session-1")
        #expect(loaded.task == "chat")
        #expect(loaded.clientPlatform == "macOS")

        let platformFilter = KnowledgeStore.AIUsageEventFilter(clientPlatform: "macOS")
        #expect(try store.countAIUsageEvents(filter: platformFilter) == 1)
        #expect(try store.countAIUsageEvents(
            filter: .init(clientPlatform: "iOS")
        ) == 0)
        let facets = try store.loadAIUsageFacets()
        #expect(facets.platforms == ["macOS"])

        // Per-session cost: the billed amount wins over the estimate, and the
        // cutoff partitions rows for the live/persisted split.
        let cost = try store.aiUsageCost(
            sessionID: "session-1",
            before: Date(timeIntervalSinceReferenceDate: 2_000)
        )
        #expect(cost.totalUSD == 0.0012)
        #expect(cost.eventCount == 1)
        #expect(cost.unpricedEventCount == 0)
        let beforeRecord = try store.aiUsageCost(
            sessionID: "session-1",
            before: Date(timeIntervalSinceReferenceDate: 1_234)
        )
        #expect(beforeRecord.eventCount == 0)
        // AI usage telemetry is intentionally local-only: syncing per-API-call
        // events clogged the CloudKit queue (see saveAIUsageEvent).
        #expect(try store.hasPendingSyncChange(entity: .aiUsageEvent, logicalKey: "usage-1") == false)

        let summaries = try store.loadAIUsageSummaries()
        #expect(summaries.count == 1)
        #expect(summaries.first?.requestCount == 1)
        #expect(summaries.first?.inputTokens == 10)
        #expect(summaries.first?.outputTokens == 5)
        #expect(summaries.first?.providerReportedCost == 0.0012)
        #expect(summaries.first?.estimatedCost == 0.0002)
    }

    @Test("A direct-rail call stays in the ledger view inside server coverage")
    func ownKeyRowsSurviveServerCoverage() throws {
        let store = try KnowledgeStore(inMemory: true)

        func event(
            id: String,
            at seconds: TimeInterval,
            ownKey: Bool,
            serverLedgerID: Int64? = nil
        ) -> AIUsageEvent {
            AIUsageEvent(
                id: id,
                provider: "OpenRouter",
                model: "gpt-oss-120b",
                operation: "chat_completion",
                task: "paper_metadata",
                sessionID: nil,
                createdAt: Date(timeIntervalSinceReferenceDate: seconds),
                inputTokens: 10,
                outputTokens: 5,
                cachedInputTokens: nil,
                cacheCreationInputTokens: nil,
                reasoningTokens: nil,
                audioInputTokens: nil,
                audioOutputTokens: nil,
                imageCount: nil,
                totalTokens: 15,
                characterCount: nil,
                durationSeconds: nil,
                providerReportedCost: 0.001,
                estimatedCost: 0.001,
                currency: "USD",
                rawUsageJSON: nil,
                clientPlatform: "macOS",
                serverLedgerID: serverLedgerID,
                serverRequestID: nil,
                latencyMilliseconds: nil,
                ownKey: ownKey
            )
        }

        // Server coverage opens here, so from this instant on the proxy's own
        // rows are the authority for anything it billed.
        try store.saveAIUsageEvent(event(id: "server-1", at: 100, ownKey: false, serverLedgerID: 7))
        // A proxied call inside that window: its D1 row is coming, so the
        // client row defers rather than being counted a second time.
        try store.saveAIUsageEvent(event(id: "client-balance", at: 200, ownKey: false))
        // The same window, but the learner's own key paid and the call never
        // reached the proxy. No D1 row will ever arrive, so deferring would
        // erase the spend instead of deduplicating it.
        try store.saveAIUsageEvent(event(id: "client-own-key", at: 300, ownKey: true))

        let visible = try store.loadAIUsageEvents(limit: 100).map(\.id)
        #expect(visible.contains("server-1"))
        #expect(visible.contains("client-own-key"))
        #expect(!visible.contains("client-balance"))
        #expect(try store.countAIUsageEvents() == 2)

        // The account menu's "$x used today" reads
        // the key's share alone; the comp's share comes from the proxy.
        let ownKeyTotals = try store.aiUsageEventTotals(filter: .init(paidByOwnKey: true))
        #expect(ownKeyTotals.count == 1)
        #expect(ownKeyTotals.cost == 0.001)
        #expect(try store.aiUsageEventTotals(filter: .init(paidByOwnKey: false)).count == 1)
        #expect(try store.aiUsageEventTotals(filter: .init(
            since: Date(timeIntervalSinceReferenceDate: 301), paidByOwnKey: true
        )).count == 0)

        guard let reloaded = try store.loadAIUsageEventForSync("client-own-key") else {
            throw RequirementFailure.missingValue
        }
        #expect(reloaded.paidByOwnKey)
        #expect(try store.loadAIUsageEventForSync("client-balance")?.paidByOwnKey == false)
    }

    @Test("A row written before the rail column reads as proxied, not own-key")
    func historicalRowsReadAsProxied() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.execForTesting("""
            INSERT INTO ai_usage_events (id, provider, model, operation, task, created_at)
            VALUES ('legacy-1', 'OpenAI', 'gpt-5.5', 'chat_completion', 'chat', 1.0)
        """)

        #expect(try store.loadAIUsageEventForSync("legacy-1")?.paidByOwnKey == false)
    }

    @Test("Persists TTS character counts and estimated cost")
    func persistsSpeechQuantities() throws {
        let store = try KnowledgeStore(inMemory: true)
        let event = AIUsageEvent(
            id: "tts-1",
            provider: "OpenAI",
            model: "gpt-4o-mini-tts",
            operation: "text_to_speech",
            task: "read_aloud",
            sessionID: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 2_345),
            inputTokens: nil,
            outputTokens: nil,
            cachedInputTokens: nil,
            cacheCreationInputTokens: nil,
            reasoningTokens: nil,
            audioInputTokens: nil,
            audioOutputTokens: nil,
            imageCount: nil,
            totalTokens: nil,
            characterCount: 2_000,
            durationSeconds: 90,
            providerReportedCost: nil,
            estimatedCost: 0.04,
            currency: nil,
            rawUsageJSON: nil
        )

        try store.saveAIUsageEvent(event)

        guard let loaded = try store.loadAIUsageEventForSync("tts-1") else {
            throw RequirementFailure.missingValue
        }
        #expect(loaded.characterCount == 2_000)
        #expect(loaded.durationSeconds == 90)
        #expect(loaded.estimatedCost == 0.04)

        let summaries = try store.loadAIUsageSummaries()
        #expect(summaries.first?.characterCount == 2_000)
        #expect(summaries.first?.durationSeconds == 90)
        #expect(summaries.first?.estimatedCost == 0.04)
    }

    @Test("Groups usage by task and stable subject identity")
    func groupsUsageActivities() throws {
        let store = try KnowledgeStore(inMemory: true)
        var first = usageEvent(id: "activity-call-1", createdAt: 100, cost: 0.01)
        first.activityID = "format-run-1"
        first.subjectID = "episode-1"
        first.subjectType = "podcast_episode"
        first.subjectTitle = "Learning, Clearly"
        var second = usageEvent(id: "activity-call-2", createdAt: 101, cost: 0.02)
        second.activityID = "format-run-1"
        second.subjectID = "episode-1"
        second.subjectType = "podcast_episode"
        second.subjectTitle = "Learning, Clearly"
        var third = usageEvent(id: "activity-call-3", createdAt: 102, cost: 0.03)
        third.activityID = "format-run-2"
        third.subjectID = "episode-2"
        third.subjectType = "podcast_episode"
        third.subjectTitle = "Memory Systems"
        try store.saveAIUsageEvent(first)
        try store.saveAIUsageEvent(second)
        try store.saveAIUsageEvent(third)

        let tasks = try store.loadAIUsageTaskActivities()
        #expect(tasks.count == 1)
        #expect(tasks[0].task == "author_normalization")
        #expect(tasks[0].subjectType == "podcast_episode")
        #expect(tasks[0].subjectCount == 2)
        #expect(tasks[0].activityCount == 2)
        #expect(tasks[0].callCount == 3)
        #expect(abs((tasks[0].cost ?? 0) - 0.06) < 0.000000001)

        let subjects = try store.loadAIUsageSubjectActivities(task: "author_normalization")
        #expect(subjects.count == 2)
        let episode = try #require(subjects.first(where: { $0.subjectID == "episode-1" }))
        #expect(episode.subjectTitle == "Learning, Clearly")
        #expect(episode.activityCount == 1)
        #expect(episode.callCount == 2)
        #expect(abs((episode.cost ?? 0) - 0.03) < 0.000000001)
    }

    @Test("Activity rows come most spend first, not most recent first")
    func activityRowsSortBySpend() throws {
        let store = try KnowledgeStore(inMemory: true)
        // The newest task is the cheapest, and the two free tasks tie, so
        // only a spend sort puts chat first and the later free task above
        // the earlier one.
        try store.saveAIUsageEvent(usageEvent(id: "s-1", createdAt: 100, cost: 0.20, task: "chat"))
        try store.saveAIUsageEvent(usageEvent(id: "s-2", createdAt: 150, cost: 0.10, task: "chat"))
        try store.saveAIUsageEvent(usageEvent(id: "s-3", createdAt: 200, cost: 0, task: "chat_history_compaction"))
        try store.saveAIUsageEvent(usageEvent(id: "s-4", createdAt: 250, cost: 0, task: "paper_metadata"))
        try store.saveAIUsageEvent(usageEvent(id: "s-5", createdAt: 300, cost: 0.18, task: "content_cleanup"))
        try store.saveAIUsageEvent(usageEvent(id: "s-6", createdAt: 400, cost: 0.02, task: "chat_quiz_grading"))

        let tasks = try store.loadAIUsageTaskActivities()
        #expect(tasks.map(\.task) == [
            "chat",
            "content_cleanup",
            "chat_quiz_grading",
            "paper_metadata",
            "chat_history_compaction",
        ])
    }

    @Test("Activity rows count the calls OpenRouter billed to the learner's own key")
    func activityRowsCountBYOKCalls() throws {
        let store = try KnowledgeStore(inMemory: true)
        let model = "anthropic/claude-opus-5.5"
        try store.saveAIUsageEvent(usageEvent(
            id: "b-1", createdAt: 100, cost: 0, task: "chat", model: model,
            rawUsageJSON: #"{"cost":0,"cost_details":{"upstream_inference_cost":0.2},"is_byok":true}"#
        ))
        try store.saveAIUsageEvent(usageEvent(
            id: "b-2", createdAt: 101, cost: 0.3, task: "chat", model: model,
            rawUsageJSON: #"{"cost":0.3,"is_byok":false}"#
        ))
        try store.saveAIUsageEvent(usageEvent(id: "b-3", createdAt: 102, cost: 0.1, task: "chat", model: model))

        let chat = try #require(store.loadAIUsageTaskActivities().first)
        let use = try #require(chat.models.first)
        #expect(use.callCount == 3)
        #expect(use.byokCallCount == 1)
        #expect(use.creditCallCount == 1)
        #expect(AIActivitySettingsSection.byokRoute(chat.models)?.label == "BYOK 1 of 2")
    }

    @Test("The BYOK capsule names credits only for models a lab key pays for")
    func byokCapsuleCallsOutCreditsOnlyForLabKeys() {
        let allByok = [AIUsageModelUse(provider: "OpenRouter", model: "anthropic/claude-opus-5.5", callCount: 4, byokCallCount: 4)]
        #expect(AIActivitySettingsSection.byokRoute(allByok)?.label == "BYOK")
        #expect(AIActivitySettingsSection.byokRoute(allByok)?.isBYOK == true)

        let anthropicCredits = [AIUsageModelUse(provider: "OpenRouter", model: "anthropic/claude-opus-5.5", callCount: 4, creditCallCount: 4)]
        #expect(AIActivitySettingsSection.byokRoute(anthropicCredits)?.label == "OpenRouter credits")
        #expect(AIActivitySettingsSection.byokRoute(anthropicCredits)?.isBYOK == false)

        OpenRouterEndpointTierCatalog.cache([
            OpenRouterEndpointTier(tag: "openai", providerName: "OpenAI", inputUSDPerMTokens: 1, outputUSDPerMTokens: 4, cachedInputUSDPerMTokens: nil, discount: nil),
        ], for: "openai/byok-capsule-test")
        let openAICredits = [AIUsageModelUse(provider: "OpenRouter", model: "openai/byok-capsule-test", callCount: 3, creditCallCount: 3)]
        #expect(AIActivitySettingsSection.byokRoute(openAICredits)?.label == "OpenRouter credits")
        #expect(AIActivitySettingsSection.byokRoute(openAICredits)?.help.contains("OpenAI key") == true)

        let otherCredits = [AIUsageModelUse(provider: "OpenRouter", model: "deepseek/deepseek-v4.1-flash", callCount: 4, creditCallCount: 4)]
        #expect(AIActivitySettingsSection.byokRoute(otherCredits) == nil)
        #expect(AIActivitySettingsSection.byokRoute([AIUsageModelUse(provider: "OpenRouter", model: "anthropic/claude-opus-5.5", callCount: 2)]) == nil)
    }

    @Test("Activity rows name the models that served them, most calls first")
    func activityRowsNameTheirModels() throws {
        let store = try KnowledgeStore(inMemory: true)
        func call(_ id: String, at time: TimeInterval, subject: String, provider: String = "OpenRouter", model: String) throws {
            var event = usageEvent(id: id, createdAt: time, cost: 0.01, provider: provider, model: model)
            event.subjectID = subject
            event.subjectType = "paper"
            try store.saveAIUsageEvent(event)
        }
        try call("m-1", at: 100, subject: "paper-a", model: "z-ai/glm-5.3-flash")
        // The managed proxy's rows spell the router in lowercase; it is still
        // one model, so its calls count together.
        try call("m-2", at: 101, subject: "paper-a", provider: "openrouter", model: "z-ai/glm-5.3-flash")
        try call("m-3", at: 102, subject: "paper-a", model: "deepseek/deepseek-v4.1-flash")
        try call("m-4", at: 103, subject: "paper-b", model: "deepseek/deepseek-v4.1-flash")
        try call("m-5", at: 104, subject: "paper-b", model: "deepseek/deepseek-v4.1-flash")
        try call("m-6", at: 105, subject: "paper-c", model: "google/gemini-3.1-flash-lite-image")

        let task = try #require(store.loadAIUsageTaskActivities().first)
        #expect(task.models.map(\.model) == [
            "deepseek/deepseek-v4.1-flash",
            "z-ai/glm-5.3-flash",
            "google/gemini-3.1-flash-lite-image",
        ])
        #expect(task.models.map(\.callCount) == [3, 2, 1])

        let subjects = try store.loadAIUsageSubjectActivities(task: "author_normalization")
        let paperA = try #require(subjects.first(where: { $0.subjectID == "paper-a" }))
        #expect(paperA.models.map(\.model) == ["z-ai/glm-5.3-flash", "deepseek/deepseek-v4.1-flash"])
        #expect(paperA.models.map(\.callCount) == [2, 1])
        let paperB = try #require(subjects.first(where: { $0.subjectID == "paper-b" }))
        #expect(paperB.models == [AIUsageModelUse(provider: "OpenRouter", model: "deepseek/deepseek-v4.1-flash", callCount: 2)])

        // A page names only its own items' models.
        let page = try store.loadAIUsageSubjectActivities(task: "author_normalization", limit: 1, offset: 0)
        #expect(page.map(\.subjectID) == ["paper-c"])
        #expect(page.first?.models.map(\.model) == ["google/gemini-3.1-flash-lite-image"])
    }

    @Test("Usage subject aggregation pages before publishing rows to the UI")
    func usageSubjectAggregationIsPaged() throws {
        let store = try KnowledgeStore(inMemory: true)
        for index in 0..<75 {
            var event = usageEvent(
                id: "paged-call-\(index)",
                createdAt: Double(index),
                cost: 0.01
            )
            event.subjectID = "subject-\(index)"
            event.subjectType = "paper"
            event.subjectTitle = "Paper \(index)"
            try store.saveAIUsageEvent(event)
        }

        let task = try #require(store.loadAIUsageTaskActivities().first)
        #expect(task.subjectCount == 75)

        let page = try store.loadAIUsageSubjectActivities(
            task: "author_normalization",
            limit: 10,
            offset: 20
        )
        #expect(page.count == 10)
        #expect(page.first?.subjectID == "subject-54")
        #expect(page.last?.subjectID == "subject-45")
    }

    @Test("Historical calls without activity identity remain visible as activities")
    func historicalCallsRemainVisibleAsActivities() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveAIUsageEvent(usageEvent(id: "legacy-call", createdAt: 100, cost: 0.01))

        let task = try #require(store.loadAIUsageTaskActivities().first)
        #expect(task.subjectType == "activity")
        #expect(task.subjectCount == 1)
        #expect(task.activityCount == 1)
        #expect(task.callCount == 1)

        let activity = try #require(store.loadAIUsageSubjectActivities(task: "author_normalization").first)
        #expect(activity.subjectID == "legacy-call")
        #expect(activity.subjectType == "activity")
        #expect(activity.activityCount == 1)
        #expect(activity.callCount == 1)
    }

    @Test("Managed chat activity resolves its current session title")
    func chatActivityResolvesSessionTitle() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.createReviewSession(
            id: "chat-session-1",
            topic: "New Chat",
            sourceIDs: []
        )
        var event = usageEvent(
            id: "chat-call-1",
            createdAt: 100,
            cost: 0.01,
            task: "chat"
        )
        // Authoritative proxy rows preserve activity identity but do not carry
        // the local-only session_id column.
        event.activityID = "chat-session-1"
        try store.saveAIUsageEvent(event)
        var localEvent = usageEvent(
            id: "chat-call-2",
            createdAt: 101,
            cost: 0.01,
            task: "chat",
            sessionID: "chat-session-1"
        )
        localEvent.activityID = "chat-session-1"
        try store.saveAIUsageEvent(localEvent)
        try store.updateReviewSessionTitle(
            sessionID: "chat-session-1",
            title: "How attention changes memory"
        )

        let task = try #require(store.loadAIUsageTaskActivities().first)
        #expect(task.task == "chat")
        #expect(task.subjectType == "chat")
        #expect(task.subjectCount == 1)

        let chat = try #require(store.loadAIUsageSubjectActivities(task: "chat").first)
        #expect(chat.subjectID == "chat-session-1")
        #expect(chat.subjectType == "chat")
        #expect(chat.subjectTitle == "How attention changes memory")
        #expect(chat.activityCount == 1)
        #expect(chat.callCount == 2)
    }

    @Test("Server usage replaces client estimates during authoritative coverage")
    func serverUsageReconciliationIsAuthoritative() throws {
        let store = try KnowledgeStore(inMemory: true)
        let oldLocal = usageEvent(id: "old-local", createdAt: 100, cost: 0.25)
        let overlappingLocal = usageEvent(id: "overlap-local", createdAt: 300, cost: 9.99)
        try store.saveAIUsageEvent(oldLocal)
        try store.saveAIUsageEvent(overlappingLocal)

        let server = ManagedAI.UsageLedgerEvent(
            id: 42,
            provider: "openrouter",
            model: "deepseek/deepseek-v4-flash",
            task: "author_normalization",
            sourceTitle: "A Theory of Learning",
            subjectID: "source-42",
            subjectType: "article",
            activityID: "activity-42",
            requestID: "proxy-request-42",
            inputTokens: 383,
            outputTokens: 100,
            cachedInputTokens: 0,
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0,
            reasoningTokens: 0,
            webSearchCalls: 0,
            billedMicrousd: 125,
            exactCost: 1,
            clientPlatform: "macOS",
            clientBuild: "0.2.0 (20)",
            createdAtUnix: Date(timeIntervalSinceReferenceDate: 200).timeIntervalSince1970
        )
        try store.importManagedAIUsageEvents([server], through: 42)

        #expect(try store.managedAIUsageCursor() == 42)
        let events = try store.loadAIUsageEvents(limit: 10)
        #expect(Set(events.map(\.id)) == ["old-local", "managed-ledger-42"])
        #expect(events.first(where: { $0.id == "managed-ledger-42" })?.providerReportedCost == 0.000125)
        #expect(events.first(where: { $0.id == "managed-ledger-42" })?.clientPlatform == "macOS")
        #expect(events.first(where: { $0.id == "managed-ledger-42" })?.subjectID == "source-42")
        #expect(events.first(where: { $0.id == "managed-ledger-42" })?.subjectTitle == "A Theory of Learning")
        let totals = try store.aiUsageEventTotals()
        #expect(totals.count == 2)
        #expect(abs((totals.cost ?? 0) - 0.250125) < 0.000000001)
    }

    /// Reads versus writes, not a hit rate against total prompt tokens:
    /// `input_tokens` includes cached tokens on OpenAI-shaped providers and
    /// excludes them on Anthropic-direct, so a total-prompt denominator would
    /// double-count most of this app's traffic.
    @Test("A call that consumed nothing is priced at zero, not counted as unpriced")
    func zeroUsageCallIsPricedAtZero() throws {
        let store = try KnowledgeStore(inMemory: true)
        func event(
            id: String,
            inputTokens: Int?,
            totalTokens: Int?,
            providerReportedCost: Double?,
            estimatedCost: Double?
        ) -> AIUsageEvent {
            AIUsageEvent(
                id: id,
                provider: "OpenAI",
                model: "gpt-realtime-2.1-mini",
                operation: "realtime_voice",
                task: "voice_review",
                sessionID: "voice-1",
                createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
                inputTokens: inputTokens,
                outputTokens: 0,
                cachedInputTokens: 0,
                cacheCreationInputTokens: nil,
                reasoningTokens: nil,
                audioInputTokens: 0,
                audioOutputTokens: 0,
                imageCount: nil,
                totalTokens: totalTokens,
                characterCount: nil,
                durationSeconds: nil,
                providerReportedCost: providerReportedCost,
                estimatedCost: estimatedCost,
                currency: nil,
                rawUsageJSON: nil,
                clientPlatform: "macOS"
            )
        }

        // A voice session that ended before the model answered: the rate card
        // priced a response that consumed nothing, so $0 is the real cost.
        // Reporting it as missing spend told the user their total was a floor
        // when it was exact.
        let empty = event(
            id: "voice-empty",
            inputTokens: 0,
            totalTokens: 0,
            providerReportedCost: 0,
            estimatedCost: nil
        )
        #expect(empty.accountedCostUSD == 0)
        try store.saveAIUsageEvent(empty)
        #expect(try store.aiUsageEventTotals().unpriced == 0)
        #expect(try store.aiUsageEventTotals().cost == 0)
        #expect(try store.aiUsageCost(
            sessionID: "voice-1",
            before: Date(timeIntervalSinceReferenceDate: 2_000)
        ).unpricedEventCount == 0)

        // A zero reported against real tokens still means "not reported": the
        // call burned tokens somewhere, so it must not read as free.
        let unknown = event(
            id: "voice-unknown",
            inputTokens: 900,
            totalTokens: 900,
            providerReportedCost: 0,
            estimatedCost: nil
        )
        #expect(unknown.accountedCostUSD == nil)
        try store.saveAIUsageEvent(unknown)
        #expect(try store.aiUsageEventTotals().unpriced == 1)

        // And a row with no quantities recorded at all stays unknown: nothing
        // was observed, so nothing can be claimed about what it cost.
        let unobserved = event(
            id: "voice-unobserved",
            inputTokens: nil,
            totalTokens: nil,
            providerReportedCost: nil,
            estimatedCost: nil
        )
        #expect(unobserved.accountedCostUSD == nil)
        try store.saveAIUsageEvent(unobserved)
        #expect(try store.aiUsageEventTotals().unpriced == 2)
    }

    private func unpricedEvent(
        id: String,
        provider: String,
        model: String,
        input: Int,
        output: Int
    ) -> AIUsageEvent {
        AIUsageEvent(
            id: id,
            provider: provider,
            model: model,
            operation: "text_completion",
            task: "chat",
            sessionID: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            inputTokens: input,
            outputTokens: output,
            cachedInputTokens: nil,
            cacheCreationInputTokens: nil,
            reasoningTokens: nil,
            audioInputTokens: nil,
            audioOutputTokens: nil,
            imageCount: nil,
            totalTokens: input + output,
            characterCount: nil,
            durationSeconds: nil,
            providerReportedCost: nil,
            estimatedCost: nil,
            currency: nil,
            rawUsageJSON: nil,
            clientPlatform: "macOS"
        )
    }

    @Test("The write prices a call the rate card knows, even when its caller did not")
    func writePricesKnownModel() throws {
        let store = try KnowledgeStore(inMemory: true)
        try store.saveAIUsageEvent(
            unpricedEvent(id: "gpt55", provider: "OpenAI", model: "gpt-5.5", input: 1_000, output: 500)
        )
        let totals = try store.aiUsageEventTotals()
        #expect(totals.unpriced == 0)
        // 1,000 input tokens at $5/M plus 500 output tokens at $30/M.
        #expect(abs((totals.cost ?? 0) - 0.02) < 1e-9)
    }

    @Test("Rows stored without a cost are priced once a rate exists, and only those")
    func sweepPricesStoredRows() throws {
        let store = try KnowledgeStore(inMemory: true)
        // Raw inserts stand in for rows an older build wrote before the write
        // priced them.
        func insert(
            _ id: String,
            provider: String,
            model: String,
            input: Int,
            output: Int,
            reasoning: Int = 0,
            raw: String? = nil
        ) throws {
            let rawSQL = raw.map { "'\($0)'" } ?? "NULL"
            try store.execForTesting("""
                INSERT INTO ai_usage_events (
                    id, provider, model, operation, task, created_at,
                    input_tokens, output_tokens, reasoning_tokens, total_tokens, raw_usage_json
                ) VALUES (
                    '\(id)', '\(provider)', '\(model)', 'text_completion', 'chat', 1000,
                    \(input), \(output), \(reasoning), \(input + output), \(rawSQL)
                )
            """)
        }
        // The shape of the May 2026 rows: real tokens, recorded before the
        // rate card knew the model.
        try insert("legacy-chat", provider: "OpenAI", model: "gpt-5.5", input: 1_000, output: 500)
        try insert("legacy-embedding", provider: "OpenAI", model: "text-embedding-3-small", input: 50_000, output: 0)
        // A generation OpenRouter says it billed nothing for, on a model no
        // built-in rate covers.
        try insert(
            "billed-nothing",
            provider: "OpenRouter",
            model: "openai/gpt-unlisted",
            input: 0,
            output: 0,
            reasoning: 1_363,
            raw: #"{"completion_tokens":0,"cost":0,"cost_details":{"upstream_inference_cost":0},"is_byok":false,"prompt_tokens":0}"#
        )
        // A model nothing prices stays unpriced: counted, never guessed.
        try insert("unknown", provider: "OpenAI", model: "gpt-unlisted", input: 900, output: 100)
        #expect(try store.aiUsageEventTotals().unpriced == 4)

        #expect(try store.repriceUnpricedAIUsageEvents() == 3)
        let totals = try store.aiUsageEventTotals()
        #expect(totals.unpriced == 1)
        // $0.02 for the chat, 50,000 tokens at $0.02/M for the embedding, and
        // nothing for the call OpenRouter did not bill.
        #expect(abs((totals.cost ?? 0) - 0.021) < 1e-9)
        // Nothing left that can be priced, so a second sweep changes nothing.
        #expect(try store.repriceUnpricedAIUsageEvents() == 0)
    }

    @Test("A speech row waiting on OpenRouter's charge is found by its generation id and priced once")
    func generationCostFinishesAWaitingRow() throws {
        let store = try KnowledgeStore(inMemory: true)
        let waiting = AIUsageEvent(
            id: "speech-waiting",
            provider: "OpenRouter",
            model: "google/gemini-3.8-flash-tts",
            operation: "text_to_speech",
            task: "read_aloud",
            sessionID: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            inputTokens: nil,
            outputTokens: nil,
            cachedInputTokens: nil,
            cacheCreationInputTokens: nil,
            reasoningTokens: nil,
            audioInputTokens: nil,
            audioOutputTokens: nil,
            imageCount: nil,
            totalTokens: nil,
            characterCount: 790,
            durationSeconds: nil,
            providerReportedCost: nil,
            estimatedCost: nil,
            currency: nil,
            rawUsageJSON: CloudArticleTTS.generationMarker("gen-abc"),
            clientPlatform: "macOS"
        )
        try store.saveAIUsageEvent(waiting)
        // A row with no generation id has nothing to look up, so it is not waiting.
        try store.saveAIUsageEvent(unpricedEvent(id: "other", provider: "OpenAI", model: "gpt-unlisted", input: 9, output: 1))

        let found = try store.aiUsageEventsAwaitingGenerationCost(limit: 10)
        #expect(found.map { $0.id } == ["speech-waiting"])
        #expect(CloudArticleTTS.generationID(inRawUsageJSON: found[0].rawUsageJSON) == "gen-abc")

        try store.setAIUsageEventGenerationCost(id: "speech-waiting", costUSD: 0.0137)
        #expect(try store.aiUsageEventsAwaitingGenerationCost(limit: 10).isEmpty)
        // A cost already stamped is never rewritten.
        try store.setAIUsageEventGenerationCost(id: "speech-waiting", costUSD: 9)
        let totals = try store.aiUsageEventTotals()
        #expect(totals.unpriced == 1)
        #expect(abs((totals.cost ?? 0) - 0.0137) < 1e-9)
    }

    @Test("An unpriced call keeps its generation id beside its usage, so OpenRouter's charge can be read")
    func unpricedCallKeepsItsGenerationID() throws {
        // The transcription answer's own usage stays readable for repricing.
        let raw = #"{"cost":0,"input_tokens":6000,"output_tokens":832}"#
        let merged = try #require(AIUsageTracker.addingGenerationID("gen-123", to: raw))
        #expect(CloudArticleTTS.generationID(inRawUsageJSON: merged) == "gen-123")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
        )
        #expect(object["input_tokens"] as? Int == 6_000)
        #expect(object["output_tokens"] as? Int == 832)
        // A row with no usage JSON gets the bare marker.
        let bare = try #require(AIUsageTracker.addingGenerationID("gen-9", to: nil))
        #expect(CloudArticleTTS.generationID(inRawUsageJSON: bare) == "gen-9")

        // The id comes from the header first, else a `gen-` id in the body.
        let url = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
        let withHeader = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["X-Generation-Id": " gen-h "]
        ))
        let withoutHeader = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        #expect(ManagedTranscriptionClient.openRouterGenerationID(response: withHeader, body: ["id": "gen-b"]) == "gen-h")
        #expect(ManagedTranscriptionClient.openRouterGenerationID(response: withoutHeader, body: ["id": "gen-b"]) == "gen-b")
        #expect(ManagedTranscriptionClient.openRouterGenerationID(response: withoutHeader, body: ["id": "req_1"]) == nil)
    }

    @Test("A server row without an exact cost stays unpriced for the pane to show")
    func serverRowIsNeverRepriced() throws {
        let store = try KnowledgeStore(inMemory: true)
        var event = unpricedEvent(
            id: "managed-ledger-7",
            provider: "OpenAI",
            model: "gpt-5.5",
            input: 1_000,
            output: 500
        )
        event.serverLedgerID = 7
        try store.saveAIUsageEvent(event)
        #expect(try store.repriceUnpricedAIUsageEvents() == 0)
        #expect(try store.aiUsageEventTotals().unpriced == 1)
    }

    @Test("Only OpenRouter's complete zero reads as a call that billed nothing")
    func openRouterBilledNothingNeedsEveryZero() {
        #expect(AIUsageParser.openRouterBilledNothing(
            rawUsageJSON: #"{"cost":0,"cost_details":{"upstream_inference_cost":0},"is_byok":false}"#
        ))
        #expect(AIUsageParser.openRouterBilledNothing(rawUsageJSON: #"{"cost":0,"is_byok":false}"#))
        // BYOK: OpenRouter charged nothing because the learner's upstream key paid.
        #expect(!AIUsageParser.openRouterBilledNothing(
            rawUsageJSON: #"{"cost":0,"cost_details":{"upstream_inference_cost":0.004},"is_byok":true}"#
        ))
        #expect(!AIUsageParser.openRouterBilledNothing(rawUsageJSON: #"{"cost":0,"is_byok":true}"#))
        #expect(!AIUsageParser.openRouterBilledNothing(
            rawUsageJSON: #"{"cost":0,"cost_details":{"upstream_inference_cost":0.004},"is_byok":false}"#
        ))
        // Without an explicit zero charge there is no claim to trust.
        #expect(!AIUsageParser.openRouterBilledNothing(rawUsageJSON: #"{"prompt_tokens":0,"is_byok":false}"#))
        #expect(!AIUsageParser.openRouterBilledNothing(rawUsageJSON: #"{"cost":0.0012,"is_byok":false}"#))
        #expect(!AIUsageParser.openRouterBilledNothing(rawUsageJSON: nil))
    }

    @Test("An OpenRouter row stored without any usage is a failed attempt that cost nothing")
    func openRouterRowWithoutUsageIsFree() throws {
        let store = try KnowledgeStore(inMemory: true)
        // The shape of the rows an own-key :free call left when OpenRouter
        // answered 200 with no completion and no usage: nothing but identity.
        try store.execForTesting("""
            INSERT INTO ai_usage_events (id, provider, model, operation, task, created_at, own_key)
            VALUES ('empty-openrouter', 'OpenRouter', 'nvidia/nemotron-3-super-120b-a12b:free',
                    'text_completion', 'paper_metadata', 1000, 1)
        """)
        // The same emptiness from another provider says nothing about billing.
        try store.execForTesting("""
            INSERT INTO ai_usage_events (id, provider, model, operation, task, created_at, own_key)
            VALUES ('empty-openai', 'OpenAI', 'gpt-unlisted', 'text_completion', 'chat', 1000, 1)
        """)
        #expect(try store.aiUsageEventTotals().unpriced == 2)
        #expect(try store.repriceUnpricedAIUsageEvents() == 1)
        #expect(try store.aiUsageEventTotals().unpriced == 1)
    }

    @Test("A response that carries no usage leaves no ledger row")
    func responseWithoutUsageIsNotRecorded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-usage-none-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        let service = AIService(session: .shared, usageTracker: AIUsageTracker(storage: storage))
        try await AIUsageAttribution.$task.withValue("paper_metadata") {
            // OpenRouter's answer to a failed upstream attempt, and an empty
            // stream: neither billed anything.
            try await service.recordUsage(
                provider: .openRouter,
                model: "nvidia/nemotron-3-super-120b-a12b:free",
                operation: "text_completion",
                json: ["error": ["message": "Provider returned error", "code": 502]],
                fallbackReport: AIUsageReport(imageCount: 1)
            )
            try await service.recordUsage(
                provider: .openRouter,
                model: "nvidia/nemotron-3-super-120b-a12b:free",
                operation: "stream_chat",
                fallbackReport: .empty
            )
            #expect(try await storage.aiUsageEventTotals().count == 0)

            // A real usage object is still recorded.
            try await service.recordUsage(
                provider: .openRouter,
                model: "nvidia/nemotron-3-super-120b-a12b:free",
                operation: "text_completion",
                json: ["usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15, "cost": 0, "is_byok": false]]
            )
        }
        #expect(try await storage.aiUsageEventTotals().count == 1)
    }

    @Test("A :free slug is priced at zero, never at its paid sibling's rate")
    func freeSlugIsPricedAtZero() throws {
        let free = try #require(AIProviderPricing.textTokenRates(
            provider: .openRouter,
            model: "nvidia/nemotron-3-super-120b-a12b:free"
        ))
        #expect(free.input == 0)
        #expect(free.output == 0)
        let report = AIUsageReport(inputTokens: 1_774, outputTokens: 325, totalTokens: 2_099)
        #expect(AIProviderPricing.estimatedCostUSD(
            provider: "OpenRouter",
            model: "nvidia/nemotron-3-super-120b-a12b:free",
            report: report
        ) == 0)
        // The paid model the built-in row names keeps its price.
        let paid = try #require(AIProviderPricing.estimatedCostUSD(
            provider: "OpenRouter",
            model: "nvidia/nemotron-3-super-120b-a12b",
            report: report
        ))
        #expect(paid > 0)
    }

    @Test("OpenRouter's own zero outranks the rate card when a call is recorded")
    func openRouterZeroOutranksRateCard() throws {
        let billedNothing = #"{"completion_tokens":325,"cost":0,"cost_details":{"upstream_inference_cost":0},"is_byok":false,"prompt_tokens":1774}"#
        let report = AIUsageReport(
            inputTokens: 1_774,
            outputTokens: 325,
            totalTokens: 2_099,
            rawUsageJSON: billedNothing
        )
        // A model the built-in card prices: the estimate must still be zero.
        #expect(AIProviderPricing.estimatedCostUSD(
            provider: "OpenRouter",
            model: "nvidia/nemotron-3-super-120b-a12b",
            report: report
        ) == 0)
        // BYOK: OpenRouter's zero means the learner's upstream key paid.
        var byok = report
        byok.rawUsageJSON = #"{"cost":0,"cost_details":{"upstream_inference_cost":0.004},"is_byok":true}"#
        #expect((AIProviderPricing.estimatedCostUSD(
            provider: "OpenRouter",
            model: "nvidia/nemotron-3-super-120b-a12b",
            report: byok
        ) ?? 0) > 0)
    }

    @Test("Estimates stored for calls OpenRouter billed nothing for are zeroed, and only those")
    func inventedEstimatesAreZeroed() throws {
        let store = try KnowledgeStore(inMemory: true)
        // Raw inserts stand in for rows an older build stamped with the paid
        // sibling's list price.
        func insert(_ id: String, estimate: Double, raw: String, serverLedgerID: Int? = nil, createdAt: Int = 1000) throws {
            try store.execForTesting("""
                INSERT INTO ai_usage_events (
                    id, provider, model, operation, task, created_at,
                    input_tokens, output_tokens, total_tokens, estimated_cost, raw_usage_json, server_ledger_id
                ) VALUES (
                    '\(id)', 'OpenRouter', 'nvidia/nemotron-3-ultra-550b-a55b:free', 'text_completion', 'chat', \(createdAt),
                    1774, 325, 2099, \(estimate), '\(raw)', \(serverLedgerID.map(String.init) ?? "NULL")
                )
            """)
        }
        try insert("invented", estimate: 0.058, raw: #"{"cost":0,"cost_details":{"upstream_inference_cost":0},"is_byok":false}"#)
        // BYOK zero: the upstream key paid, so the estimate is real spend.
        try insert("byok", estimate: 0.004, raw: #"{"cost":0,"cost_details":{"upstream_inference_cost":0.004},"is_byok":true}"#)
        // A server row is D1's answer and is never rewritten here. Dated
        // after the client rows so the ledger's accounting view keeps them.
        try insert("server", estimate: 0.01, raw: #"{"cost":0,"is_byok":false}"#, serverLedgerID: 9, createdAt: 2000)

        #expect(try store.zeroEstimatesOpenRouterDidNotBill() == 1)
        #expect(try store.zeroEstimatesOpenRouterDidNotBill() == 0)
        let byID = Dictionary(
            uniqueKeysWithValues: try store.loadAIUsageEvents(limit: 10).map { ($0.id, $0.estimatedCost) }
        )
        #expect(byID["invented"] == 0)
        #expect(byID["byok"] == 0.004)
        #expect(byID["server"] == 0.01)

        // The write path applies the same rule to a row arriving with an
        // invented estimate (a sync from a device on an older build).
        let arriving = AIUsageEvent(
            id: "arriving",
            provider: "OpenRouter",
            model: "nvidia/nemotron-3-ultra-550b-a55b:free",
            operation: "text_completion",
            task: "chat",
            sessionID: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            inputTokens: 1_774,
            outputTokens: 325,
            cachedInputTokens: nil,
            cacheCreationInputTokens: nil,
            reasoningTokens: nil,
            audioInputTokens: nil,
            audioOutputTokens: nil,
            imageCount: nil,
            totalTokens: 2_099,
            characterCount: nil,
            durationSeconds: nil,
            providerReportedCost: nil,
            estimatedCost: 0.058,
            currency: nil,
            rawUsageJSON: #"{"cost":0,"is_byok":false}"#,
            clientPlatform: "macOS"
        )
        try store.saveAIUsageEvent(arriving)
        #expect(try store.loadAIUsageEvents(limit: 10).first { $0.id == "arriving" }?.estimatedCost == 0)
    }

    /// The remote overlay is off under test, so this pins the built-in rate
    /// card: a pinned or default model must not depend on the directory having
    /// loaded before its first call is recorded.
    @Test("Every model the app pins or defaults to has a built-in list price")
    func everyPinnedModelHasABuiltInListPrice() {
        let pinned: [(AIProvider, [String])] = [
            (.anthropic, AIModelDefaults.preferredAnthropic + [AIModelDefaults.mobileDefaultChatModel]),
            (.openai, AIModelDefaults.preferredOpenAI + [AIModelDefaults.podcastCleanupMaintenance]),
            (.gemini, AIModelDefaults.preferredGemini),
            (.xai, AIModelDefaults.preferredXAI),
            (.meta, AIModelDefaults.preferredMeta),
            (.openRouter, AIModelDefaults.preferredOpenRouter + [
                AIModelDefaults.defaultOpenRouter,
                AIModelDefaults.mobileDefaultBackgroundModel,
                AIModelDefaults.mobileDefaultBackgroundMultimodalModel,
                AIModelDefaults.paperTextToSpeechPreparation,
                "openai/\(AIModelDefaults.podcastCleanupMaintenance)",
            ]),
        ]
        for (provider, models) in pinned {
            for model in models {
                #expect(
                    AIProviderPricing.textTokenRates(provider: provider, model: model) != nil,
                    "\(provider.shortName) \(model) has no built-in list price"
                )
            }
        }
    }

    @Test("Cache read share reports reads against cache-handled tokens only")
    func cacheReadShareMath() {
        var totals = AIUsageEventTotals()
        // Nothing touched the cache: no share to report, not a zero share.
        #expect(totals.cacheReadShare == nil)

        totals.cacheReadTokens = 90_000
        totals.cacheWriteTokens = 10_000
        #expect(totals.cacheReadShare == 0.9)

        // Writing as much as you read barely breaks even.
        totals.cacheReadTokens = 5_000
        totals.cacheWriteTokens = 5_000
        #expect(totals.cacheReadShare == 0.5)

        // A prefix that changes before it can be reused: writes, no reads.
        totals.cacheReadTokens = 0
        totals.cacheWriteTokens = 40_000
        #expect(totals.cacheReadShare == 0)
    }

    @Test("Exact server repair replaces an already mirrored unmetered row")
    func exactServerRepairReplacesUnmeteredMirror() throws {
        let store = try KnowledgeStore(inMemory: true)
        let unmetered = ManagedAI.UsageLedgerEvent(
            id: 42,
            provider: "openrouter",
            model: "nvidia/parakeet-tdt-0.6b-v3",
            task: "review_dictation",
            sourceTitle: nil,
            subjectID: nil,
            subjectType: nil,
            activityID: "dictation-1",
            requestID: "proxy-request-42:unmetered",
            inputTokens: 0,
            outputTokens: 0,
            cachedInputTokens: 0,
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0,
            reasoningTokens: 0,
            webSearchCalls: 0,
            billedMicrousd: 0,
            exactCost: 0,
            clientPlatform: "macOS",
            clientBuild: "0.2.0 (20)",
            createdAtUnix: 100
        )
        try store.importManagedAIUsageEvents([unmetered], through: 42)

        let repaired = ManagedAI.UsageLedgerEvent(
            id: 43,
            provider: "openrouter",
            model: "nvidia/parakeet-tdt-0.6b-v3",
            task: "review_dictation",
            sourceTitle: nil,
            subjectID: nil,
            subjectType: nil,
            activityID: "dictation-1",
            requestID: "proxy-request-42",
            inputTokens: 0,
            outputTokens: 0,
            cachedInputTokens: 0,
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0,
            reasoningTokens: 0,
            webSearchCalls: 0,
            billedMicrousd: 80,
            exactCost: 1,
            clientPlatform: "macOS",
            clientBuild: "0.2.0 (20)",
            createdAtUnix: 100
        )
        try store.importManagedAIUsageEvents([repaired], through: 43)

        // An old build could have advanced its cursor after importing both
        // rows. Replaying the stale row models that persisted state and proves
        // a later event-driven sync still reconciles it.
        try store.importManagedAIUsageEvents([unmetered], through: 44)

        let events = try store.loadAIUsageEvents(limit: 10)
        #expect(events.map(\.id) == ["managed-ledger-43"])
        #expect(events.first?.providerReportedCost == 0.000080)
        #expect(try store.aiUsageEventTotals().unpriced == 0)
    }

    @Test("Usage remains durable when the knowledge schema is newer than the app")
    func forwardCompatibleUsageAppend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreverlm-usage-forward-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try KnowledgeStore(storeDirectory: root)
        }

        let path = root.appendingPathComponent("knowledge.db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        let futureVersion = KnowledgeStore.schemaVersion + 1
        #expect(
            sqlite3_exec(
                database,
                "PRAGMA user_version = \(futureVersion)",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )
        sqlite3_close(database)

        let event = usageEvent(id: "future-schema-usage", createdAt: 500, cost: 0.02)
        try await StorageService(storeRoot: root).saveAIUsageEvent(event)

        database = nil
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        var storedProvider: String?
        var storedCost: Double?
        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(
                database,
                "SELECT provider, provider_reported_cost FROM ai_usage_events WHERE id = ?",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        sqlite3_bind_text(
            statement,
            1,
            (event.id as NSString).utf8String,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
        if sqlite3_step(statement) == SQLITE_ROW {
            storedProvider = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            storedCost = sqlite3_column_double(statement, 1)
        }
        sqlite3_finalize(statement)

        var preservedVersion: Int32 = 0
        #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        if sqlite3_step(statement) == SQLITE_ROW {
            preservedVersion = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)

        #expect(storedProvider == "OpenRouter")
        #expect(storedCost == 0.02)
        #expect(preservedVersion == futureVersion)
    }

    @Test("Deterministic response cache honors its caller-supplied TTL")
    func deterministicResponseCacheTTL() throws {
        let store = try KnowledgeStore(inMemory: true)
        let writtenAt = Date(timeIntervalSinceReferenceDate: 1_000)
        try store.saveCachedAIResponse("normalized", for: "digest", at: writtenAt)

        #expect(try store.cachedAIResponse(
            for: "digest",
            notOlderThan: Date(timeIntervalSinceReferenceDate: 999)
        ) == "normalized")
        #expect(try store.cachedAIResponse(
            for: "digest",
            notOlderThan: Date(timeIntervalSinceReferenceDate: 1_001)
        ) == nil)
    }

    @Test("Parses whisper transcription duration")
    func parsesTranscriptionDuration() throws {
        let json = try expectJSONObject("""
        { "text": "hello", "duration": 42.5 }
        """)
        let report = AIUsageParser.report(fromTranscriptionResponse: json)
        #expect(report.durationSeconds == 42.5)
    }

    private func usageEvent(
        id: String,
        createdAt: TimeInterval,
        cost: Double,
        task: String = "author_normalization",
        sessionID: String? = nil,
        provider: String = "OpenRouter",
        model: String = "deepseek/deepseek-v4-flash",
        rawUsageJSON: String? = nil
    ) -> AIUsageEvent {
        AIUsageEvent(
            id: id,
            provider: provider,
            model: model,
            operation: "text_completion",
            task: task,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
            inputTokens: 383,
            outputTokens: 100,
            cachedInputTokens: nil,
            cacheCreationInputTokens: nil,
            reasoningTokens: nil,
            audioInputTokens: nil,
            audioOutputTokens: nil,
            imageCount: nil,
            totalTokens: 483,
            characterCount: nil,
            durationSeconds: nil,
            providerReportedCost: cost,
            estimatedCost: cost,
            currency: "USD",
            rawUsageJSON: rawUsageJSON
        )
    }

    @Test("Prices TTS by input characters")
    func pricesTTSByCharacters() throws {
        // A row an earlier build recorded on a host's own API has no
        // remembered rate card to fall back on (2026-09-27: "no need for any
        // other routes to models"): Groq and Together AI name no maker whose
        // OpenRouter row could price it, so it stays unpriced.
        for provider in ["Groq", "Together AI"] {
            let cost = OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
                AIProviderPricing.estimatedCostUSD(
                    provider: provider,
                    model: "canopylabs/orpheus-v1-english",
                    report: AIUsageReport(characterCount: 1_000_000)
                )
            }
            #expect(cost == nil, "\(provider)")
        }

        // OpenRouter's speech prices are OpenRouter's catalog's, in the unit
        // it bills each model by; unit tests pin that table rather than read it.
        let expectedOpenRouterRates: [(String, Double)] = [
            ("fish-audio/s2.1-pro-free:free", 0),
            ("deepgram/flux-tts:free", 0),
            ("hexgrad/kokoro-82m", 0.62),
            ("fish-audio/s2.1-pro", 15),
            ("microsoft/mai-voice-2-flash", 15),
            ("qwen/qwen-audio-3.0-tts-flash", 15),
        ]
        OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            for (model, rate) in expectedOpenRouterRates {
                let cost = AIProviderPricing.estimatedCostUSD(
                    provider: "OpenRouter",
                    model: model,
                    report: AIUsageReport(characterCount: 1_000_000)
                )
                #expect(cost.map { abs($0 - rate) < 0.000_001 } == true, "\(model)")
                #expect(AIProviderPricing.ttsDisplayRatePerMillionCharacters(
                    provider: "OpenRouter",
                    model: model
                ).map { abs($0 - rate) < 0.000_001 } == true, "\(model)")
            }
            // Gemini is billed by its tokens and has no per-character rate: a
            // character count is not what OpenRouter charges it by, so no
            // estimate is made up from it.
            #expect(AIProviderPricing.ttsDisplayRatePerMillionCharacters(
                provider: "OpenRouter",
                model: "google/gemini-3.1-flash-tts-preview"
            ) == nil)
        }
        // Unpinned, nothing but a `:free` id has a price.
        #expect(AIProviderPricing.ttsDisplayRatePerMillionCharacters(
            provider: "OpenRouter",
            model: "hexgrad/kokoro-82m"
        ) == nil)
    }

    @Test("Prices STT by audio duration")
    func pricesSTTByDuration() throws {
        // A whisper-1 row an earlier build recorded on OpenAI's own API is
        // priced at OpenRouter's row for openai/whisper-1: $0.0001 a second.
        let cost = OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            AIProviderPricing.estimatedCostUSD(
                provider: "OpenAI",
                model: "whisper-1",
                report: AIUsageReport(durationSeconds: 600)
            )
        }
        #expect(cost.map { abs($0 - 0.06) < 0.000_001 } == true)
        // Without OpenRouter's price there is none: no rate card stands in.
        #expect(AIProviderPricing.estimatedCostUSD(
            provider: "OpenAI",
            model: "whisper-1",
            report: AIUsageReport(durationSeconds: 600)
        ) == nil)
    }

    @Test("Shows normalized OpenRouter STT hourly prices")
    func openRouterSTTHourlyPrices() throws {
        // No provider argument: the rail is resolved from the model, because
        // the caller's idea of the provider and the route the request takes
        // were not the same thing.
        let (parakeet, qwen) = OpenRouterAudioPrices.$pinnedTable.withValue(AudioPriceFixture.table) {
            (
                AIProviderPricing.sttDisplayRatePerHour(model: "nvidia/parakeet-tdt-0.6b-v3"),
                AIProviderPricing.sttDisplayRatePerHour(model: "qwen/qwen3-asr-flash-2026-02-10")
            )
        }
        #expect(parakeet != nil)
        #expect(qwen != nil)
        #expect(abs((parakeet ?? 0) - 0.09) < 0.000_001)
        #expect(abs((qwen ?? 0) - 0.126) < 0.000_001)
    }

    @Test("Prices Anthropic tokens including cache reads and writes")
    func pricesAnthropicTokens() throws {
        // Sonnet 4.6: $3/M in, $15/M out, cache read 0.1x, cache write 1.25x.
        // Anthropic input_tokens excludes cached tokens, so nothing is subtracted.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "Anthropic",
            model: "claude-sonnet-4-6",
            report: AIUsageReport(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cachedInputTokens: 1_000_000,
                cacheCreationInputTokens: 1_000_000
            )
        )
        let expected = 3.0 + 15.0 + 0.3 + 3.75
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - expected) < 0.0001)
    }

    @Test("Prices Claude Opus 5 including prompt caching")
    func pricesClaudeOpus5() throws {
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "Anthropic",
            model: "claude-opus-5",
            report: AIUsageReport(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cachedInputTokens: 1_000_000,
                cacheCreationInputTokens: 1_000_000
            )
        )
        // $5 input + $25 output + $0.50 cache read + $6.25 cache write.
        let expected = 5.0 + 25.0 + 0.5 + 6.25
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - expected) < 0.0001)
    }

    @Test("Applies Sonnet 5 introductory pricing by event date")
    func pricesSonnet5ByDate() throws {
        let report = AIUsageReport(inputTokens: 1_000_000, outputTokens: 1_000_000)
        // Intro pricing ($2/$10) through 2026-08-31.
        let introCost = AIProviderPricing.estimatedCostUSD(
            provider: "Anthropic",
            model: "claude-sonnet-5",
            report: report,
            at: Date(timeIntervalSince1970: 1_752_600_000)  // 2025-07-15 < cutover
        )
        #expect(introCost != nil)
        #expect(abs((introCost ?? 0) - 12.0) < 0.0001)

        // Standard pricing ($3/$15) from 2026-09-01.
        let standardCost = AIProviderPricing.estimatedCostUSD(
            provider: "Anthropic",
            model: "claude-sonnet-5",
            report: report,
            at: Date(timeIntervalSince1970: 1_790_000_000)  // > 2026-09-01
        )
        #expect(standardCost != nil)
        #expect(abs((standardCost ?? 0) - 18.0) < 0.0001)
    }

    @Test("Prices 1-hour cache writes at 2x and 5-minute writes at 1.25x")
    func pricesAnthropicCacheWriteTTLSplit() throws {
        let json = try expectJSONObject("""
        {
          "usage": {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_creation": {
              "ephemeral_5m_input_tokens": 1000000,
              "ephemeral_1h_input_tokens": 1000000
            }
          }
        }
        """)
        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.cacheWrite5mInputTokens == 1_000_000)
        #expect(report.cacheWrite1hInputTokens == 1_000_000)
        #expect(report.cacheCreationInputTokens == 2_000_000)

        // Haiku 4.5 ($1/M in): 5m write 1.25x + 1h write 2x = $1.25 + $2.00.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "Anthropic",
            model: "claude-haiku-4-5",
            report: report
        )
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 3.25) < 0.0001)
    }

    @Test("Counts Anthropic server-side web searches and bills them per call")
    func pricesAnthropicWebSearch() throws {
        let json = try expectJSONObject("""
        {
          "usage": {
            "input_tokens": 0,
            "output_tokens": 0,
            "server_tool_use": { "web_search_requests": 3 }
          }
        }
        """)
        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.webSearchCalls == 3)

        // $10 per 1k searches → 3 searches = $0.03.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "Anthropic",
            model: "claude-haiku-4-5",
            report: report
        )
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 0.03) < 0.0001)
    }

    @Test("Counts OpenAI Responses web_search_call output items")
    func parsesOpenAIResponsesWebSearchCalls() throws {
        let json = try expectJSONObject("""
        {
          "output": [
            { "type": "web_search_call", "status": "completed" },
            { "type": "web_search_call", "status": "completed" },
            { "type": "message", "content": [] }
          ],
          "usage": { "input_tokens": 1000000, "output_tokens": 0 }
        }
        """)
        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.webSearchCalls == 2)

        // gpt-5.5: $5/M input + 2 × $0.01 per search.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "OpenAI",
            model: "gpt-5.5",
            report: report
        )
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 5.02) < 0.0001)
    }

    @Test("Parses Meta Responses usage from the terminal SSE envelope")
    func parsesMetaResponsesTerminalUsage() throws {
        let json = try expectJSONObject("""
        {
          "type": "response.completed",
          "response": {
            "model": "muse-spark-1.2",
            "output": [
              { "type": "web_search_call", "status": "completed", "results": [] },
              { "type": "message", "content": [] }
            ],
            "usage": {
              "input_tokens": 1200,
              "output_tokens": 300,
              "input_tokens_details": { "cached_tokens": 800 },
              "output_tokens_details": { "reasoning_tokens": 100 }
            }
          }
        }
        """)
        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.inputTokens == 1_200)
        #expect(report.outputTokens == 300)
        #expect(report.cachedInputTokens == 800)
        #expect(report.reasoningTokens == 100)
        #expect(report.webSearchCalls == 1)
        #expect(report.servedModel == "muse-spark-1.2")
    }

    @Test("Parses Groq stream usage nested under x_groq")
    func parsesGroqStreamUsage() throws {
        let json = try expectJSONObject("""
        {
          "choices": [],
          "x_groq": { "id": "req_1", "usage": { "prompt_tokens": 120, "completion_tokens": 30 } }
        }
        """)
        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.inputTokens == 120)
        #expect(report.outputTokens == 30)
    }

    @Test("Prices Gemini TTS by text input and audio output tokens")
    func pricesGeminiTTSTokens() throws {
        let json = try expectJSONObject("""
        {
          "usageMetadata": {
            "promptTokenCount": 1000000,
            "candidatesTokenCount": 1000000,
            "candidatesTokensDetails": [ { "modality": "AUDIO", "tokenCount": 1000000 } ],
            "totalTokenCount": 2000000
          }
        }
        """)
        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.audioOutputTokens == 1_000_000)

        // gemini-2.5-flash-preview-tts: $0.50/M text in + $10/M audio out. The
        // audio tokens are carved out of candidatesTokenCount, not double-billed.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "Gemini",
            model: "gemini-2.5-flash-preview-tts",
            report: report
        )
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 10.5) < 0.0001)

        // 3.1 flash TTS: $1/M in + $20/M audio out.
        let cost31 = AIProviderPricing.estimatedCostUSD(
            provider: "Gemini",
            model: "gemini-3.1-flash-tts-preview",
            report: report
        )
        #expect(cost31 != nil)
        #expect(abs((cost31 ?? 0) - 21.0) < 0.0001)
    }

    @Test("Halves token cost for Batch API usage")
    func pricesBatchAtHalfRate() throws {
        // gemini-3.1-flash-tts-preview interactive would be $21; batch is 50%.
        var ttsReport = AIUsageReport(
            inputTokens: 1_000_000,
            audioOutputTokens: 1_000_000,
            totalTokens: 2_000_000
        )
        ttsReport.outputTokens = 1_000_000
        ttsReport.billedAtBatchRates = true
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "Gemini",
            model: "gemini-3.1-flash-tts-preview",
            report: ttsReport
        )
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 10.5) < 0.0001)
    }

    @Test("Applies Gemini long-context tier above 200k prompt tokens")
    func pricesGeminiLongContext() throws {
        // gemini-2.5-pro below the threshold: $1.25/M in, $10/M out.
        let short = AIProviderPricing.estimatedCostUSD(
            provider: "Gemini",
            model: "gemini-2.5-pro",
            report: AIUsageReport(inputTokens: 100_000, outputTokens: 100_000)
        )
        #expect(short != nil)
        #expect(abs((short ?? 0) - (0.125 + 1.0)) < 0.0001)

        // Above 200k prompt tokens the whole request bills at $2.50/$15.
        let long = AIProviderPricing.estimatedCostUSD(
            provider: "Gemini",
            model: "gemini-2.5-pro",
            report: AIUsageReport(inputTokens: 400_000, outputTokens: 100_000)
        )
        #expect(long != nil)
        #expect(abs((long ?? 0) - (1.0 + 1.5)) < 0.0001)
    }

    @Test("Accumulate sums independent chunk reports")
    func accumulateSumsReports() throws {
        var total = AIUsageReport.empty
        total.accumulate(AIUsageReport(inputTokens: 100, audioOutputTokens: 2_000, totalTokens: 2_100))
        total.accumulate(AIUsageReport(inputTokens: 50, audioOutputTokens: 1_000, totalTokens: 1_050))
        #expect(total.inputTokens == 150)
        #expect(total.audioOutputTokens == 3_000)
        #expect(total.totalTokens == 3_150)
        #expect(total.hasBillableUsage)
    }

    @Test("Stream merge keeps cumulative maxima, not sums")
    func mergeKeepsCumulativeMaxima() throws {
        var report = AIUsageReport(inputTokens: 500)
        report.merge(AIUsageReport(inputTokens: 500, outputTokens: 20))
        report.merge(AIUsageReport(outputTokens: 45))
        #expect(report.inputTokens == 500)
        #expect(report.outputTokens == 45)
    }

    /// `recordUsage` builds its report as `fallbackReport` merged with the
    /// parsed response, so a vision call's stamped image count has to survive a
    /// provider payload that says nothing about images — which is every one of
    /// them. Without this the image side of slide-citation scanning (one call
    /// per slide) is unattributable in the ledger.
    @Test("A stamped image count survives merging provider usage")
    func stampedImageCountSurvivesProviderUsage() throws {
        let json = try expectJSONObject("""
        {
          "usage": { "prompt_tokens": 1500, "completion_tokens": 120, "total_tokens": 1620 }
        }
        """)

        var report = AIUsageReport(imageCount: 1)
        report.merge(AIUsageParser.report(from: json))

        #expect(report.imageCount == 1)
        #expect(report.inputTokens == 1_500)
        #expect(report.outputTokens == 120)
    }

    @Test("Subtracts cached tokens from OpenAI-style prompt totals")
    func pricesOpenAITokens() throws {
        // gpt-5.5: $5/M in, $30/M out, $0.50/M cached; prompt_tokens includes cached.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "OpenAI",
            model: "gpt-5.5",
            report: AIUsageReport(
                inputTokens: 1_000_000,
                outputTokens: 100_000,
                cachedInputTokens: 400_000
            )
        )
        let expected = 0.6 * 5.0 + 0.1 * 30.0 + 0.4 * 0.5
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - expected) < 0.0001)
    }

    @Test("Prices the gpt-4o mobile models by tokens, but not their TTS variant")
    func pricesGPT4oFamily() throws {
        // gpt-4o-mini (the mobile driving-mode model): $0.15/M in, $0.60/M out.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "OpenAI",
            model: "gpt-4o-mini",
            report: AIUsageReport(inputTokens: 1_000_000, outputTokens: 1_000_000)
        )
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - 0.75) < 0.0001)

        // gpt-4o-mini-tts is a speech model: the token-rate table must not
        // match it, or a character report would be priced as tokens. Its
        // price is OpenRouter's row for it or none, never a rate card.
        let ttsCost = AIProviderPricing.estimatedCostUSD(
            provider: "OpenAI",
            model: "gpt-4o-mini-tts",
            report: AIUsageReport(characterCount: 1_000_000)
        )
        #expect(ttsCost == nil)
    }

    @Test("Exposes Muse Spark list prices for model selection")
    func museSparkTextTokenRates() throws {
        let rates = try #require(
            AIProviderPricing.textTokenRates(
                provider: .openRouter,
                model: "meta/\(AIModelDefaults.latestMuseSpark)"
            )
        )
        #expect(rates.input == 1.25)
        #expect(rates.output == 4.25)
        #expect(rates.cachedInput == 0.15)
    }

    @Test("Exposes curated Mistral list prices for model selection")
    func mistralTextTokenRates() throws {
        let large = try #require(
            AIProviderPricing.textTokenRates(
                provider: .openRouter,
                model: "mistralai/mistral-large-2512"
            )
        )
        #expect(large.input == 0.50)
        #expect(large.output == 1.50)
        #expect(abs((large.cachedInput ?? 0) - 0.05) < 0.000_000_1)

        let small = try #require(
            AIProviderPricing.textTokenRates(
                provider: .openRouter,
                model: "mistralai/mistral-small-2603"
            )
        )
        #expect(small.input == 0.15)
        #expect(small.output == 0.60)
        #expect(abs((small.cachedInput ?? 0) - 0.015) < 0.000_000_1)
    }

    @Test("OpenRouter's effective promotional price replaces the built-in fallback")
    func openRouterPromotionalDirectoryPriceWins() throws {
        let base = AIProviderPricing.TokenRates(
            input: 4,
            output: 20,
            cachedInput: 0.4,
            cacheWrite: 5
        )
        let promotion = AIProviderPricing.RemoteModelPrice(
            input: 2,
            output: 10,
            cachedInput: 0.2,
            cacheWrite: 2.5,
            cacheWrite1h: nil,
            perWebSearchCall: 0.01
        )

        let effective = try #require(AIProviderPricing.applyingRemote(promotion, to: base))

        #expect(effective.input == 2)
        #expect(effective.output == 10)
        #expect(effective.cachedInput == 0.2)
        #expect(effective.cacheWrite == 2.5)
        #expect(AIModelPriceRefresher.freshnessInterval == 5 * 60)
    }

    @Test("The price overlay names the same OpenRouter row the request is routed to")
    func priceOverlaySlugMatchesTheRoutingSlug() {
        // "gpt-5.6" is OpenAI's alias for the Sol row; the overlay used to look
        // up "openai/gpt-5.6", find nothing, and quote the static list price
        // beside OpenRouter's promotion label.
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "openai", model: "gpt-5.6") == "openai/gpt-5.6-sol")
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "openai", model: "gpt-5.6-terra") == "openai/gpt-5.6-terra")
        // Anthropic's dashed version becomes OpenRouter's dotted one; a single
        // version component and a non-trailing number are left alone.
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "anthropic", model: "claude-opus-4-8") == "anthropic/claude-opus-4.8")
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "anthropic", model: "claude-sonnet-5") == "anthropic/claude-sonnet-5")
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "anthropic", model: "claude-3-haiku") == "anthropic/claude-3-haiku")
        // A dated id keeps its date after the dotted version, so the overlay's
        // undated-row fallback still finds "anthropic/claude-opus-4.8".
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "anthropic", model: "claude-opus-4-8-20260115") == "anthropic/claude-opus-4.8-20260115")
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "anthropic", model: "claude-opus-4-8-2026-01-15") == "anthropic/claude-opus-4.8-2026-01-15")
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "xai", model: "grok-4") == "x-ai/grok-4")
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "gemini", model: "gemini-2.5-pro") == "google/gemini-2.5-pro")
        // A full slug passes through; hosts with their own price cards have no row.
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "openrouter", model: "openai/gpt-5.6-sol") == "openai/gpt-5.6-sol")
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "openai", model: "openai/gpt-5.6-sol") == "openai/gpt-5.6-sol")
        #expect(AIProviderPricing.openRouterPriceSlug(provider: "groq", model: "openai/gpt-oss-120b") == nil)
        // The routing slug and the price slug agree on the same identity.
        #expect(OpenRouterModelID.slug(provider: .openai, model: "gpt-5.6")
            == AIProviderPricing.openRouterPriceSlug(provider: "openai", model: "gpt-5.6"))
        #expect(OpenRouterModelID.slug(provider: .anthropic, model: "claude-opus-4-8")
            == AIProviderPricing.openRouterPriceSlug(provider: "anthropic", model: "claude-opus-4-8"))
    }

    @Test("Exposes Muse Spark Contributor's consent-discounted list prices")
    func museSparkContributorTextTokenRates() throws {
        let rates = try #require(
            AIProviderPricing.textTokenRates(
                provider: .meta,
                model: AIModelDefaults.museSparkContributor
            )
        )
        #expect(rates.input == 0.10)
        #expect(rates.output == 0.20)
        #expect(rates.cachedInput == 0.002)
    }

    @Test("A price table that was never fetched counts as stale")
    func neverFetchedPriceTableIsStale() {
        // An unfetched table read as fresh once left most of the ledger
        // unpriced: 2,542 openai/gpt-5-nano calls carrying 10M tokens and no
        // cost at all.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(AIModelPriceRefresher.isStale(nil, now: now))
        #expect(AIModelPriceRefresher.isStale(
            now.addingTimeInterval(-AIModelPriceRefresher.freshnessInterval),
            now: now
        ))
        #expect(AIModelPriceRefresher.isStale(
            now.addingTimeInterval(-AIModelPriceRefresher.freshnessInterval + 1),
            now: now
        ) == false)
    }

    @Test("Prices xAI cached input at the discounted rate")
    func pricesXAICachedInput() throws {
        // grok: $1.25/M in, $2.50/M out, $0.20/M cached; OpenAI-style prompt
        // totals include cached tokens.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "xAI",
            model: "grok-3-mini-fast",
            report: AIUsageReport(
                inputTokens: 100_000,
                outputTokens: 10_000,
                cachedInputTokens: 40_000
            )
        )
        let expected = 0.06 * 1.25 + 0.01 * 2.5 + 0.04 * 0.20
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - expected) < 0.0001)
    }

    @Test("Prices OpenRouter catalog cache reads at OpenRouter's listed rates")
    func pricesOpenRouterCachedInput() throws {
        // deepseek-v4-pro via OpenRouter: $0.435/M in, $0.87/M out,
        // $0.003625/M cache read.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "OpenRouter",
            model: "deepseek/deepseek-v4-pro",
            report: AIUsageReport(
                inputTokens: 1_000_000,
                outputTokens: 0,
                cachedInputTokens: 500_000
            )
        )
        let expected = 0.5 * 0.435 + 0.5 * 0.003625
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - expected) < 0.0001)
    }

    @Test("Reuses Anthropic cache rates for Claude models routed through OpenRouter")
    func pricesOpenRouterAnthropicPassThrough() throws {
        // anthropic/claude-sonnet-4-6 via OpenRouter: $3/$15 with 0.1x reads
        // and 1.25x writes — but OpenRouter's normalized prompt_tokens includes
        // both cached and cache-write tokens, so they must be carved out of the
        // input charge instead of double-billing.
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "OpenRouter",
            model: "anthropic/claude-sonnet-4-6",
            report: AIUsageReport(
                inputTokens: 1_000_000,
                outputTokens: 0,
                cachedInputTokens: 600_000,
                cacheCreationInputTokens: 200_000
            )
        )
        // 200k uncached at $3 + 600k reads at $0.30 + 200k writes at $3.75.
        let expected = 0.2 * 3.0 + 0.6 * 0.3 + 0.2 * 3.75
        #expect(cost != nil)
        #expect(abs((cost ?? 0) - expected) < 0.0001)
    }

    @Test("Parses OpenRouter cache-write tokens from prompt_tokens_details")
    func parsesOpenRouterCacheWriteTokens() throws {
        let json = try expectJSONObject("""
        {
          "usage": {
            "prompt_tokens": 1000,
            "completion_tokens": 50,
            "prompt_tokens_details": {
              "cached_tokens": 600,
              "cache_write_tokens": 200
            }
          }
        }
        """)
        guard let report = AIUsageParser.report(from: json) else {
            throw RequirementFailure.missingValue
        }
        #expect(report.cachedInputTokens == 600)
        #expect(report.cacheCreationInputTokens == 200)
    }

    @Test("Returns nil for unknown models instead of guessing")
    func unknownModelHasNoEstimate() throws {
        let cost = AIProviderPricing.estimatedCostUSD(
            provider: "SomeProvider",
            model: "mystery-model-9000",
            report: AIUsageReport(inputTokens: 1_000)
        )
        #expect(cost == nil)
    }

    private func expectJSONObject(_ raw: String) throws -> [String: Any] {
        let data = Data(raw.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RequirementFailure.missingValue
        }
        return object
    }
}

/// The sliding renewal that keeps a signed-in Mac signed in — and, with it,
/// everything the session reaches: Slack's connection lives on the gateway and
/// is read only with this session, so its "Connected" chip is the first thing
/// a lapsed session takes down.
@Suite("Managed Session Renewal")
struct ManagedSessionRenewalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test("A fresh 30-day session is left alone")
    func freshSessionIsNotRenewed() {
        #expect(ManagedAI.sessionNeedsRenewal(expiry: now.addingTimeInterval(30 * day), now: now) == false)
        #expect(ManagedAI.sessionNeedsRenewal(expiry: now.addingTimeInterval(16 * day), now: now) == false)
    }

    @Test("A session in its second half renews")
    func secondHalfRenews() {
        #expect(ManagedAI.sessionNeedsRenewal(expiry: now.addingTimeInterval(15 * day), now: now))
        #expect(ManagedAI.sessionNeedsRenewal(expiry: now.addingTimeInterval(3 * day), now: now))
        #expect(ManagedAI.sessionNeedsRenewal(expiry: now.addingTimeInterval(60), now: now))
    }

    @Test("A lapsed session is not renewed — the proxy would refuse, and only the Apple sheet brings it back")
    func lapsedSessionIsNotRenewed() {
        #expect(ManagedAI.sessionNeedsRenewal(expiry: now, now: now) == false)
        #expect(ManagedAI.sessionNeedsRenewal(expiry: now.addingTimeInterval(-day), now: now) == false)
    }

    @Test("A session with no recorded expiry renews to learn one")
    func unknownExpiryRenews() {
        #expect(ManagedAI.sessionNeedsRenewal(expiry: nil, now: now))
    }

    @Test("The renewal lead is half the proxy's 30-day session life")
    func leadIsHalfTheSessionLife() {
        #expect(ManagedAI.sessionRenewalLead == 15 * day)
    }
}
