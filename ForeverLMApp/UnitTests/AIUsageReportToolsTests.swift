import Testing
import Foundation
@testable import ForeverLM

#if os(macOS)

/// `get_ai_usage_report`, `get_ai_task_settings` and `set_ai_task_settings`:
/// the ledger grouped the way the report promises, and Settings › AI Models
/// read and written through the pane's own entry points. Serialized because
/// the settings tests touch the process-wide preference keys the pane reads.
@Suite("AI usage report and AI task settings over MCP", .serialized)
struct AIUsageReportToolsTests {
    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The provider and model a task resolves to, as a comparable pair.
    private func selected(_ task: AITask) -> [String] {
        let selection = KeychainService.resolvedSelection(for: task)
        return [selection.provider.rawValue, selection.model]
    }

    private func payload(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func event(
        id: String,
        task: String?,
        provider: String,
        model: String,
        createdAt: Date,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        providerReportedCost: Double? = nil,
        estimatedCost: Double?
    ) -> AIUsageEvent {
        AIUsageEvent(
            id: id,
            provider: provider,
            model: model,
            operation: "text_completion",
            task: task,
            sessionID: nil,
            createdAt: createdAt,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reasoningTokens: nil,
            audioInputTokens: nil,
            audioOutputTokens: nil,
            imageCount: nil,
            totalTokens: inputTokens + outputTokens,
            characterCount: nil,
            durationSeconds: nil,
            providerReportedCost: providerReportedCost,
            estimatedCost: estimatedCost,
            currency: "USD",
            rawUsageJSON: nil,
            clientPlatform: "macOS"
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @Test("get_ai_usage_report groups the ledger by task, model and day, and never invents a price")
    func reportGroupsLedger() throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        ManagedAI.ownKeyOverrideForTesting = .some(nil)
        let kstore = try store.knowledgeStore()
        // Noon-anchored so "a day ago" never straddles a local midnight.
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        func daysAgo(_ days: Int) -> Date { Calendar.current.date(byAdding: .day, value: -days, to: now)! }

        let flash = AIModelDefaults.defaultOpenRouter
        try kstore.saveAIUsageEvent(event(
            id: "pm-1", task: "paper_metadata", provider: "OpenRouter", model: flash, createdAt: daysAgo(1),
            inputTokens: 10_000, outputTokens: 500, cachedInputTokens: 2_000, cacheCreationInputTokens: 1_000, estimatedCost: 0.002
        ))
        try kstore.saveAIUsageEvent(event(
            id: "pm-2", task: "paper_metadata", provider: "OpenRouter", model: flash, createdAt: daysAgo(2),
            inputTokens: 20_000, outputTokens: 1_500, estimatedCost: 0.004
        ))
        // The provider's billed amount outranks the estimate.
        try kstore.saveAIUsageEvent(event(
            id: "chat-1", task: "chat", provider: "Anthropic", model: AIModelDefaults.defaultAnthropic, createdAt: daysAgo(1),
            inputTokens: 5_000, outputTokens: 1_000, providerReportedCost: 0.05, estimatedCost: 0.04
        ))
        // A call nothing could price: counted, never folded into a total. The
        // model has to be one the rate card does not know, or the write itself
        // prices it (`AIUsageEvent.ledgerEstimatedCost`).
        try kstore.saveAIUsageEvent(event(
            id: "chat-2", task: "chat", provider: "Anthropic", model: "claude-unlisted-test", createdAt: daysAgo(3),
            inputTokens: 100, outputTokens: 10, estimatedCost: nil
        ))
        // Outside a 30-day window.
        try kstore.saveAIUsageEvent(event(
            id: "pm-old", task: "paper_metadata", provider: "OpenRouter", model: flash, createdAt: daysAgo(40),
            inputTokens: 1_000, outputTokens: 100, estimatedCost: 1.0
        ))

        let report = try payload(try store.getAIUsageReport(days: 30, from: nil, to: nil))
        let totals = try #require(report["totals"] as? [String: Any])
        #expect(totals["calls"] as? Int == 4)
        #expect(totals["unpriced_calls"] as? Int == 1)
        #expect(abs((totals["cost_usd"] as? Double ?? 0) - 0.056) < 1e-9)
        #expect(totals["cache_read_tokens"] as? Int == 2_000)
        #expect(totals["cache_write_tokens"] as? Int == 1_000)

        let byTask = try #require(report["by_task"] as? [[String: Any]])
        #expect(byTask.count == 2)
        // Sorted by spend: chat's $0.05 outranks paper metadata's $0.006.
        #expect(byTask[0]["task"] as? String == "chat")
        let chat = byTask[0]
        #expect(chat["calls"] as? Int == 2)
        #expect(chat["unpriced_calls"] as? Int == 1)
        #expect(abs((chat["cost_usd"] as? Double ?? 0) - 0.05) < 1e-9)
        let chatPerCall = try #require(chat["per_call"] as? [String: Any])
        // Divided over the one priced call, not over both.
        #expect(abs((chatPerCall["cost_usd"] as? Double ?? 0) - 0.05) < 1e-9)
        let chatRoute = try #require(chat["current_route"] as? [String: Any])
        #expect(chatRoute["follows"] as? String == "default_model")

        let paperMetadata = byTask[1]
        #expect(paperMetadata["task"] as? String == "paper_metadata")
        #expect(paperMetadata["label"] as? String == AIUsageTaskLabel.text(for: "paper_metadata"))
        #expect(paperMetadata["calls"] as? Int == 2)
        #expect(paperMetadata["input_tokens"] as? Int == 30_000)
        #expect(paperMetadata["output_tokens"] as? Int == 2_000)
        #expect(paperMetadata["cache_read_tokens"] as? Int == 2_000)
        #expect(paperMetadata["cache_write_tokens"] as? Int == 1_000)
        #expect(abs((paperMetadata["cache_read_share"] as? Double ?? 0) - 2.0 / 3.0) < 1e-3)
        #expect(abs((paperMetadata["cost_usd"] as? Double ?? 0) - 0.006) < 1e-9)
        #expect(paperMetadata["configurable"] as? Bool == true)
        let perCall = try #require(paperMetadata["per_call"] as? [String: Any])
        #expect(perCall["input_tokens"] as? Double == 15_000)
        #expect(perCall["output_tokens"] as? Double == 1_000)
        #expect(abs((perCall["cost_usd"] as? Double ?? 0) - 0.003) < 1e-9)
        let route = try #require(paperMetadata["current_route"] as? [String: Any])
        #expect(route["task"] as? String == "paper_metadata")
        #expect(["background_text", "task_override"].contains(route["follows"] as? String ?? ""))
        #expect(route["price_known"] is Bool)
        let models = try #require(paperMetadata["models"] as? [[String: Any]])
        #expect(models.count == 1)
        #expect(models[0]["model"] as? String == flash)
        #expect((models[0]["provider"] as? [String: Any])?["id"] as? String == "openrouter")

        let byModel = try #require(report["by_model"] as? [[String: Any]])
        #expect(byModel.count == 3)
        let flashRow = try #require(byModel.first { $0["model"] as? String == flash })
        #expect(flashRow["calls"] as? Int == 2)
        #expect(flashRow["tasks"] as? [String] == ["paper_metadata"])
        #expect((flashRow["model_display_name"] as? String)?.isEmpty == false)
        // Whatever the table says, the payload never guesses: a price is a row
        // or an explicit unknown.
        for row in byModel {
            let known = try #require(row["price_known"] as? Bool)
            #expect(known == !(row["price"] is NSNull))
        }

        let byDay = try #require(report["by_day"] as? [[String: Any]])
        #expect(byDay.count == 3)
        #expect(byDay.reduce(0) { $0 + ($1["calls"] as? Int ?? 0) } == 4)
        #expect(byDay.map { $0["day"] as? String ?? "" } == byDay.map { $0["day"] as? String ?? "" }.sorted())

        // An explicit local-day period reaches exactly the calls of that day.
        let day = Self.dayFormatter.string(from: daysAgo(2))
        let oneDay = try payload(try store.getAIUsageReport(days: nil, from: day, to: day))
        #expect((oneDay["totals"] as? [String: Any])?["calls"] as? Int == 1)
        #expect(((oneDay["period"] as? [String: Any])?["explicit"] as? Bool) == true)
        #expect(((oneDay["period"] as? [String: Any])?["days"] as? Int) == 1)

        // An empty period says so instead of reporting zeros as spend.
        let empty = try payload(try store.getAIUsageReport(days: nil, from: "2001-01-01", to: "2001-01-02"))
        #expect(empty["empty"] as? Bool == true)
        #expect(((empty["totals"] as? [String: Any])?["cost_usd"]) is NSNull)

        // Refused periods.
        #expect(throws: MCPError.self) { _ = try store.getAIUsageReport(days: 0, from: nil, to: nil) }
        #expect(throws: MCPError.self) { _ = try store.getAIUsageReport(days: 7, from: day, to: nil) }
        #expect(throws: MCPError.self) { _ = try store.getAIUsageReport(days: nil, from: "2026-09-10", to: "2026-09-01") }
        #expect(throws: MCPError.self) { _ = try store.getAIUsageReport(days: nil, from: "yesterday", to: nil) }
    }

    @Test("get_ai_task_settings and set_ai_task_settings are Settings › AI Models")
    func settingsRoundTrip() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        ManagedAI.ownKeyOverrideForTesting = .some(nil)

        let task = AITask.paperMetadata
        let defaults = UserDefaults.standard
        var keys = [
            AIModelPreferenceKey.taskRoute(task),
            AIModelPreferenceKey.backgroundRoute,
            AIModelPreferenceKey.backgroundMultimodalRoute,
            MeetingModels.mayUseFreeKey,
            "aiBackground.provider", "aiBackground.model",
        ]
        keys += ["provider", "model", "effort", "speed"].map { "aiTask.\(task.rawValue).\($0)" }
        keys += AIProvider.allCases.map { "aiBackground.model.\($0.rawValue)" }
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
        for key in keys { defaults.removeObject(forKey: key) }

        /// One write, labeled so a refusal names the step that produced it.
        func set(
            _ label: String, _ target: String, provider: String? = nil, model: String? = nil,
            meetingsMayUseFree: Bool? = nil, taskID: String? = nil
        ) async throws -> [String: Any] {
            do {
                return try payload(try await store.setAITaskSettings(
                    target: target, provider: provider, model: model, meetingsMayUseFree: meetingsMayUseFree,
                    taskID: taskID
                ))
            } catch {
                Issue.record("\(label): \(error)")
                throw error
            }
        }

        // Read: the shipped state of a fresh install for the keys cleared above.
        let settings = try payload(try await store.getAITaskSettings(loadDirectory: { nil }))
        #expect((settings["settings_pane"] as? String)?.hasPrefix("Settings › Chat") == true)
        let backgroundText = try #require(settings["background_text"] as? [String: Any])
        #expect(backgroundText["is_shipped_default"] as? Bool == true)
        #expect(backgroundText["model"] as? String == AIModelDefaults.defaultOpenRouter)
        #expect((backgroundText["provider"] as? [String: Any])?["id"] as? String == "openrouter")
        let backgroundMultimodal = try #require(settings["background_multimodal"] as? [String: Any])
        #expect(backgroundMultimodal["model"] as? String == AIModelDefaults.visionOpenRouter)
        let defaultModel = try #require(settings["default_model"] as? [String: Any])
        #expect((defaultModel["model"] as? String)?.isEmpty == false)
        let tasks = try #require(settings["tasks"] as? [[String: Any]])
        #expect(tasks.count == AITask.advancedTasks.count)
        let paperRow = try #require(tasks.first { $0["task"] as? String == task.rawValue })
        #expect(paperRow["follows"] as? String == "background_text")
        #expect(paperRow["display_name"] as? String == task.displayName)
        #expect(paperRow["model"] as? String == AIModelDefaults.defaultOpenRouter)
        #expect(paperRow["overridden"] == nil)
        #expect(paperRow["effort"] == nil)
        let meetingRow = try #require(tasks.first { $0["task"] as? String == AITask.meetingActionItems.rawValue })
        #expect(meetingRow["kept_off_free_model"] as? Bool == false)
        #expect(settings["meetings_may_use_free"] as? Bool == false)
        let catalogue = try #require(settings["catalogue"] as? [[String: Any]])
        #expect(!catalogue.isEmpty)
        var catalogued: [(String, String)] = []
        for group in catalogue {
            let models = try #require(group["models"] as? [[String: Any]])
            for model in models {
                let known = try #require(model["price_known"] as? Bool)
                #expect(known == !(model["price"] is NSNull))
                if known {
                    let price = try #require(model["price"] as? [String: Any])
                    #expect((price["input_per_million_usd"] as? Double ?? -1) >= 0)
                    #expect((price["output_per_million_usd"] as? Double ?? -1) >= 0)
                }
                catalogued.append(((model["provider"] as? [String: Any])?["id"] as? String ?? "", model["model"] as? String ?? ""))
            }
        }
        #expect(catalogued.contains { $0 == ("openrouter", AIModelDefaults.defaultOpenRouter) })
        #expect(catalogued.contains { $0 == ("anthropic", AIModelDefaults.defaultAnthropic) })
        let accepts = try #require(settings["accepts"] as? [String: Any])
        #expect(accepts["targets"] as? [String] == MCPDataStore.aiTaskSettingsTargets)
        #expect(!MCPDataStore.aiTaskSettingsTargets.contains("task"))

        // A task's own model is read and wins over Background's; target
        // task_model sets it and, with neither provider nor model, takes it back.
        let pro = "deepseek/deepseek-v4-pro"
        #expect(AIModelCatalog.entry(provider: .openRouter, modelID: pro) != nil)
        let own = try await set("task model", "task_model", provider: "openrouter", model: pro, taskID: task.rawValue)
        #expect(own["changed"] as? [String] == ["task_model"])
        #expect(KeychainService.ownRoute(for: task) == AITaskModelRoute(provider: .openRouter, model: pro))
        #expect(selected(task) == [AIProvider.openRouter.rawValue, pro])
        let ownTasks = try #require(own["tasks"] as? [[String: Any]])
        let ownRow = try #require(ownTasks.first { $0["task"] as? String == task.rawValue })
        #expect(ownRow["follows"] as? String == "task_model")
        #expect(ownRow["has_own_model"] as? Bool == true)
        #expect(try await set("task model again", "task_model", provider: "openrouter", model: pro, taskID: task.rawValue)["updated"] as? Bool == false)
        let followed = try await set("task model cleared", "task_model", taskID: task.rawValue)
        #expect(followed["changed"] as? [String] == ["task_model"])
        #expect(KeychainService.ownRoute(for: task) == nil)
        #expect(selected(task) == [AIProvider.openRouter.rawValue, AIModelDefaults.defaultOpenRouter])
        // A task that reads images takes only a model that does, and an unknown or
        // chat-following task is refused; task_id belongs to task_model alone.
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(
                target: "task_model", provider: "openrouter", model: AIModelDefaults.defaultOpenRouter,
                taskID: AITask.paperFigureUnderstanding.rawValue
            )
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "task_model", provider: "openrouter", model: pro, taskID: "chat")
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "background_text", provider: "openrouter", model: pro, taskID: task.rawValue)
        }

        // What set_ai_task_settings took for one task is refused by name.
        do {
            _ = try await store.setAITaskSettings(
                target: "background_text", provider: "openrouter", model: pro, retiredArguments: ["task", "effort"]
            )
            Issue.record("task and effort must be refused")
        } catch MCPError.invalidInput(let message) {
            #expect(message.hasPrefix("task, effort no longer apply"))
        }

        // The text-only Background picker.
        let background = try await set("background text", "background_text", provider: "openrouter", model: pro)
        #expect(background["changed"] as? [String] == ["background_text"])
        #expect(KeychainService.displayedBackgroundTaskRoute == AITaskModelRoute(provider: .openRouter, model: pro))
        #expect((background["background_text"] as? [String: Any])?["is_shipped_default"] as? Bool == false)
        // ...and the task that follows it now resolves there.
        #expect(selected(task) == [AIProvider.openRouter.rawValue, pro])
        // The same selection again changes nothing.
        let again = try await set("background text again", "background_text", provider: "OpenRouter", model: pro)
        #expect(again["updated"] as? Bool == false)

        // The multimodal picker takes only a model that can read images.
        #expect(KeychainService.modelSupportsVision(provider: .openRouter, model: AIModelDefaults.defaultOpenRouter) == false)
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "background_multimodal", provider: "openrouter", model: AIModelDefaults.defaultOpenRouter)
        }
        let gemini = AIModelDefaults.latestGemini
        _ = try await set("background multimodal", "background_multimodal", provider: "gemini", model: gemini)
        #expect(KeychainService.displayedBackgroundMultimodalTaskRoute == AITaskModelRoute(provider: .gemini, model: gemini))

        // Setup's Meetings answer, and nothing else, through target meetings.
        let allowed = try await set("meetings free", "meetings", meetingsMayUseFree: true)
        #expect(allowed["changed"] as? [String] == ["meetings_may_use_free"])
        #expect(MeetingModels.mayUseFree)
        #expect(allowed["meetings_may_use_free"] as? Bool == true)
        #expect(try await set("meetings free again", "meetings", meetingsMayUseFree: true)["updated"] as? Bool == false)
        _ = try await set("meetings paid", "meetings", meetingsMayUseFree: false)
        #expect(!MeetingModels.mayUseFree)
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "meetings", provider: nil, model: nil)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "meetings", provider: "openrouter", model: pro, meetingsMayUseFree: true)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "background_text", provider: "openrouter", model: pro, meetingsMayUseFree: true)
        }

        // Refused before anything is written: an unknown provider, a model the
        // catalogue does not list, a retired host, and the retired task target.
        let before = KeychainService.displayedBackgroundTaskRoute
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "background_text", provider: "acme", model: pro)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "background_text", provider: "openrouter", model: "acme/not-a-model")
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "background_text", provider: "groq", model: "openai/gpt-oss-120b")
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "default_model", provider: "anthropic", model: "claude-nonexistent-9")
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "task", provider: "openrouter", model: pro)
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "everything", provider: nil, model: nil)
        }
        #expect(KeychainService.displayedBackgroundTaskRoute == before)

        // Registered: the two readers and the writer, whose target enum is the
        // reader's accepts.targets, with no argument for one task.
        let tools = MCPToolRegistry(store: MCPDataStore()).tools
        #expect(tools.contains { $0.name == "get_ai_usage_report" })
        #expect(tools.contains { $0.name == "get_ai_task_settings" })
        let setter = try #require(tools.first { $0.name == "set_ai_task_settings" })
        let properties = try #require(setter.inputSchema["properties"] as? [String: Any])
        let target = try #require(properties["target"] as? [String: Any])
        #expect(target["enum"] as? [String] == MCPDataStore.aiTaskSettingsTargets)
        for retired in MCPDataStore.retiredAITaskSettingsArguments {
            #expect(properties[retired] == nil, "\(retired)")
        }
        #expect(properties["meetings_may_use_free"] != nil)
    }

    @Test("target docs gives Docs a model of their own, and takes it back")
    func docsTarget() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        ManagedAI.ownKeyOverrideForTesting = .some(nil)

        let defaults = UserDefaults.standard
        let key = AIModelPreferenceKey.docsRoute
        let prior = defaults.object(forKey: key)
        defer {
            if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
            KeychainService.resetChatSessionSelection()
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
        defaults.removeObject(forKey: key)
        #expect(SyncedPreferenceKeys.isSynced(key))
        #expect(SyncedPreferenceKeys.isPersistedModelConfiguration(key))

        // Unset, Docs follow the Default Model.
        let settings = try payload(try await store.getAITaskSettings(loadDirectory: { nil }))
        let docs = try #require(settings["docs"] as? [String: Any])
        #expect(docs["follows_default_model"] as? Bool == true)
        let defaultModel = try #require(settings["default_model"] as? [String: Any])
        #expect(docs["model"] as? String == defaultModel["model"] as? String)
        #expect(KeychainService.docsRoute == nil)

        // A catalogue model becomes Docs' own.
        let pro = "deepseek/deepseek-v4-pro"
        let picked = AITaskModelRoute(provider: .openRouter, model: pro)
        let set = try payload(try await store.setAITaskSettings(target: "docs", provider: "openrouter", model: pro))
        #expect(set["changed"] as? [String] == ["docs"])
        #expect(KeychainService.docsRoute == picked)
        #expect(KeychainService.displayedDocsRoute == picked)
        let written = try #require(set["docs"] as? [String: Any])
        #expect(written["follows_default_model"] as? Bool == false)
        #expect(written["model"] as? String == pro)
        let again = try payload(try await store.setAITaskSettings(target: "docs", provider: "OpenRouter", model: pro))
        #expect(again["updated"] as? Bool == false)

        // Refused before anything is written.
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "docs", provider: "openrouter", model: "acme/not-a-model")
        }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(target: "docs", provider: "openrouter", model: nil)
        }
        #expect(KeychainService.docsRoute == picked)

        // Neither provider nor model: Docs follow the Default Model again, and
        // a chat's own pick does not reach them.
        let cleared = try payload(try await store.setAITaskSettings(target: "docs", provider: nil, model: nil))
        #expect(cleared["changed"] as? [String] == ["docs"])
        #expect(KeychainService.docsRoute == nil)
        #expect(defaults.object(forKey: key) == nil)
        KeychainService.setTaskRoute(provider: .openRouter, model: pro, for: .chat)
        let chatDefault = KeychainService.aiProvider
        #expect(KeychainService.displayedDocsRoute == AITaskModelRoute(
            provider: chatDefault, model: KeychainService.model(for: chatDefault)
        ))
    }

    @Test("target backups sets a setting's backup models, as Use as Backup does")
    func backupsTarget() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        ManagedAI.ownKeyOverrideForTesting = .some(nil)

        let task = AITask.paperMetadata
        let defaults = UserDefaults.standard
        var keys = [
            AIBackupModels.key(slot: "background.text"),
            AIModelPreferenceKey.backgroundRoute,
            "aiBackground.provider", "aiBackground.model",
        ]
        keys += AIProvider.allCases.map { "aiBackground.model.\($0.rawValue)" }
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
        for key in keys { defaults.removeObject(forKey: key) }

        // Three OpenRouter catalogue models the text default does not run on.
        let background = KeychainService.displayedBackgroundTaskRoute
        let others = AIModelCatalog.makerGroups.flatMap(\.entries).filter {
            $0.provider == .openRouter
                && $0.modelID != background.model
                && !AIModelDefaults.isRetiredChatModel(provider: $0.provider, model: $0.modelID)
                && !(AIModelCatalog.hidesTrainingModels && AIModelDefaults.trainsOnInputs(provider: $0.provider, model: $0.modelID))
        }.map(\.modelID)
        try #require(others.count >= 3)
        let (first, second, third) = (others[0], others[1], others[2])
        func rows(_ models: [String]) -> [[String: Any]] { models.map { ["provider": "openrouter", "model": $0] } }
        func set(_ backupsFor: String, _ models: [String]) async throws -> [String: Any] {
            try payload(try await store.setAITaskSettings(
                target: "backups", provider: nil, model: nil,
                backupsFor: backupsFor, backups: rows(models)
            ))
        }

        let written = try await set("background_text", [first, second])
        #expect(written["changed"] as? [String] == ["backups"])
        #expect(AIBackupModels.stored(slot: "background.text").map(\.model) == [first, second])
        let listed = try #require(written["backups"] as? [[String: Any]])
        let row = try #require(listed.first { $0["backups_for"] as? String == "background_text" })
        #expect((row["models"] as? [[String: Any]])?.compactMap { $0["model"] as? String } == [first, second])
        #expect(try await set("background_text", [first, second])["updated"] as? Bool == false)

        // The setting's own model and a repeat are refused, and so is a list
        // past the limit, before any model in it is read.
        await #expect(throws: MCPError.self) { _ = try await set("background_text", [background.model]) }
        await #expect(throws: MCPError.self) { _ = try await set("background_text", [first, first]) }
        do {
            _ = try await set("background_text", Array(repeating: first, count: AIBackupModels.limit + 1))
            Issue.record("A list of \(AIBackupModels.limit + 1) backups must be refused")
        } catch MCPError.invalidInput(let message) {
            #expect(message.contains("at most \(AIBackupModels.limit)"))
        }
        // A third is taken: a setting may list up to ten (product owner, 2026-09-27:
        // "please allow 10 backups for models that fail; not just 2").
        #expect(try await set("background_text", [first, second, third])["changed"] as? [String] == ["backups"])
        #expect(AIBackupModels.stored(slot: "background.text").map(\.model) == [first, second, third])
        // backups belong to target backups alone.
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(
                target: "background_text", provider: "openrouter", model: first,
                backupsFor: "background_text", backups: rows([second])
            )
        }

        // Every background task uses its Background model's backups; no task
        // has its own.
        #expect(AIBackupModels.slot(for: task) == "background.text")
        #expect(AIBackupModels.slot(for: .paperFigureUnderstanding) == "background.images")
        await #expect(throws: MCPError.self) { _ = try await set("task", [second]) }

        // [] removes them, and the row goes with them.
        #expect(try await set("background_text", [])["changed"] as? [String] == ["backups"])
        #expect(defaults.object(forKey: AIBackupModels.key(slot: "background.text")) == nil)
    }

    @Test("backups_for chat sets the backups a scheduled task's run walks, and a typed chat walks none")
    func chatBackupsTarget() async throws {
        let (store, tmpPath) = try TestStores.mcp()
        defer { cleanup(tmpPath) }
        defer { ManagedAI.ownKeyOverrideForTesting = nil }
        ManagedAI.ownKeyOverrideForTesting = .some(nil)

        let defaults = UserDefaults.standard
        let key = AIBackupModels.key(slot: AIBackupModels.chatSlot)
        let prior = defaults.object(forKey: key)
        defer {
            if let prior { defaults.set(prior, forKey: key) } else { defaults.removeObject(forKey: key) }
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
        defaults.removeObject(forKey: key)

        let chatProvider = KeychainService.aiProvider
        let chatModel = KeychainService.model(for: chatProvider)
        let chatIdentity = AIBackupModels.identity(chatProvider, chatModel)
        let others = AIModelCatalog.makerGroups.flatMap(\.entries).filter {
            $0.provider == .openRouter
                && AIBackupModels.identity($0.provider, $0.modelID) != chatIdentity
                && !AIModelDefaults.isRetiredChatModel(provider: $0.provider, model: $0.modelID)
                && !(AIModelCatalog.hidesTrainingModels && AIModelDefaults.trainsOnInputs(provider: $0.provider, model: $0.modelID))
        }.map(\.modelID)
        try #require(others.count >= 2)
        func set(_ models: [(String, String)]) async throws -> [String: Any] {
            try payload(try await store.setAITaskSettings(
                target: "backups", provider: nil, model: nil,
                backupsFor: "chat", backups: models.map { ["provider": $0.0, "model": $0.1] }
            ))
        }

        let written = try await set([("openrouter", others[0]), ("openrouter", others[1])])
        #expect(written["changed"] as? [String] == ["backups"])
        #expect(AIBackupModels.stored(slot: AIBackupModels.chatSlot).map(\.model) == [others[0], others[1]])
        let listed = try #require(written["backups"] as? [[String: Any]])
        let row = try #require(listed.first { $0["backups_for"] as? String == "chat" })
        #expect((row["models"] as? [[String: Any]])?.compactMap { $0["model"] as? String } == [others[0], others[1]])
        // The Default Model cannot be its own backup, and task is refused.
        await #expect(throws: MCPError.self) { _ = try await set([(chatProvider.rawValue, chatModel)]) }
        await #expect(throws: MCPError.self) {
            _ = try await store.setAITaskSettings(
                target: "backups", provider: nil, model: nil,
                backupsFor: "chat", backups: [["provider": "openrouter", "model": others[0]]],
                retiredArguments: ["task"]
            )
        }

        // A chat the learner types in never walks them: the chat task has no
        // Background slot, so a call labelled chat resolves no backups.
        #expect(AIBackupModels.slot(for: .chat) == nil)
        var typed = AITaskConfig(provider: .openRouter, apiKey: "test", model: chatModel)
        typed.taskLabel = "chat"
        #expect(AIBackupModels.configs(after: typed).isEmpty)

        #expect(try await set([])["changed"] as? [String] == ["backups"])
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test("A report period is days back, or an inclusive local-day range")
    func periods() throws {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 15))!
        let thirty = try MCPDataStore.aiUsageReportPeriod(days: nil, from: nil, to: nil, now: now)
        #expect(thirty.days == 30)
        #expect(thirty.until == now)
        #expect(thirty.since == calendar.date(byAdding: .day, value: -30, to: now))
        #expect(!thirty.explicit)

        let week = try MCPDataStore.aiUsageReportPeriod(days: nil, from: "2026-09-01", to: "2026-09-07", now: now)
        #expect(week.days == 7)
        #expect(week.explicit)
        #expect(week.since == calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        #expect(week.until == calendar.date(from: DateComponents(year: 2026, month: 9, day: 8)))

        let openEnded = try MCPDataStore.aiUsageReportPeriod(days: nil, from: "2026-09-10", to: nil, now: now)
        #expect(openEnded.days == 3)
        #expect(openEnded.until == calendar.date(from: DateComponents(year: 2026, month: 9, day: 13)))

        #expect(throws: MCPError.self) { _ = try MCPDataStore.aiUsageReportPeriod(days: 3661, from: nil, to: nil, now: now) }
        #expect(throws: MCPError.self) { _ = try MCPDataStore.aiUsageReportPeriod(days: nil, from: "2026-09-08", to: "2026-09-07", now: now) }
    }
}

#endif
