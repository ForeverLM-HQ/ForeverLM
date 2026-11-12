import Foundation

// MARK: - Settings › AI Models and the AI usage ledger over MCP
//
// Three tools so an assistant can review what the learner spends on AI and
// change the model settings that drive it, without a Settings pane in the loop:
//
// - `get_ai_usage_report` reads the local AI usage ledger (`ai_usage_events`,
//   the same rows AI Usage › Activity aggregates) for a period and groups
//   spend by task, by model and by day, and beside every task the route it is
//   configured to run on today and that model's catalogue price.
// - `get_ai_task_settings` is Settings › AI Models as JSON: the Default Model,
//   the two Background models, the model each background task runs on, and
//   the catalogue every picker offers, priced from the one pricing table.
// - `set_ai_task_settings` writes through the exact `KeychainService` and
//   `AIModelCatalog` entry points the pane's own controls call, so the UI and
//   MCP cannot accept different selections.
//
// No number here is invented: a price the pricing table does not know is
// reported as null with `price_known: false`, and a call the ledger could not
// price is counted in `unpriced_calls` instead of being folded into a total.

extension MCPDataStore {
    // MARK: Period

    struct AIUsageReportPeriod: Equatable {
        let since: Date
        /// Exclusive.
        let until: Date
        let days: Int
        let explicit: Bool
    }

    private static let reportDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `days` back from now (default 30), or an explicit local-day range where
    /// `to` is inclusive. Refuses a period that is empty or runs backwards.
    static func aiUsageReportPeriod(days: Int?, from: String?, to: String?, now: Date = Date()) throws -> AIUsageReportPeriod {
        let calendar = Calendar.current
        let fromText = from?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let toText = to?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromText.isEmpty || !toText.isEmpty {
            guard days == nil else {
                throw MCPError.invalidInput("Pass either days or from/to, not both.")
            }
            func day(_ text: String, _ name: String) throws -> Date {
                guard let date = reportDayFormatter.date(from: text) else {
                    throw MCPError.invalidInput("\(name) must be a local calendar day written YYYY-MM-DD.")
                }
                return calendar.startOfDay(for: date)
            }
            let since = fromText.isEmpty ? calendar.startOfDay(for: calendar.date(byAdding: .day, value: -29, to: now) ?? now) : try day(fromText, "from")
            let lastDay = toText.isEmpty ? calendar.startOfDay(for: now) : try day(toText, "to")
            guard let until = calendar.date(byAdding: .day, value: 1, to: lastDay), until > since else {
                throw MCPError.invalidInput("to must be the same day as from or later.")
            }
            let dayCount = calendar.dateComponents([.day], from: since, to: until).day ?? 0
            return AIUsageReportPeriod(since: since, until: until, days: dayCount, explicit: true)
        }
        let dayCount = days ?? 30
        guard dayCount >= 1, dayCount <= 3660 else {
            throw MCPError.invalidInput("days must be between 1 and 3660.")
        }
        guard let since = calendar.date(byAdding: .day, value: -dayCount, to: now) else {
            throw MCPError.invalidInput("days is out of range.")
        }
        return AIUsageReportPeriod(since: since, until: now, days: dayCount, explicit: false)
    }

    // MARK: Prices and providers, as JSON

    /// The catalogue's price row for a route, per million tokens. Nil when the
    /// pricing table has no row: the payload says so rather than guessing.
    static func aiPriceRow(provider: AIProvider, model: String) -> [String: Any]? {
        if let rates = AIProviderPricing.textTokenRates(provider: provider, model: model) {
            return aiPriceRow(rates)
        }
        if let entry = AIModelCatalog.entry(provider: provider, modelID: model),
           let rates = AIModelListPrice.rates(for: entry) {
            return ["input_per_million_usd": rates.input, "output_per_million_usd": rates.output, "source": "directory_snapshot"]
        }
        return nil
    }

    /// Price row for a ledger row, whose provider is the `shortName` the
    /// recorder stamps ("OpenRouter", "Anthropic") and whose model is the slug
    /// that was actually sent.
    static func aiPriceRow(ledgerProvider: String, model: String) -> [String: Any]? {
        AIProviderPricing.tokenRates(provider: ledgerProvider.lowercased(), model: model.lowercased()).map(aiPriceRow)
    }

    private static func aiPriceRow(_ rates: AIProviderPricing.TokenRates) -> [String: Any] {
        var row: [String: Any] = [
            "input_per_million_usd": rates.input,
            "output_per_million_usd": rates.output,
            "source": "pricing_table",
        ]
        row["cached_input_per_million_usd"] = rates.cachedInput ?? NSNull()
        row["cache_write_per_million_usd"] = rates.cacheWrite ?? NSNull()
        return row
    }

    /// The provider a ledger row names, if it is one the app still knows.
    static func aiProvider(ledgerProvider: String) -> AIProvider? {
        AIProvider(ledgerName: ledgerProvider)
    }

    /// A provider as a caller names it: the slash token (`openrouter`), the
    /// short name (`OpenRouter`) or the stored raw value, case-insensitively.
    static func aiProvider(named text: String) -> AIProvider? {
        aiProvider(ledgerProvider: text)
    }

    static func aiProviderJSON(_ provider: AIProvider) -> [String: Any] {
        ["id": provider.slashToken, "label": provider.shortName]
    }

    static func aiModelDisplayName(provider: AIProvider?, model: String) -> String {
        guard let provider else { return model }
        return AIModelCatalog.displayName(provider: provider, modelID: model)
    }

    private static func rounded(_ value: Double, places: Int = 6) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }

    private static func costJSON(_ cost: Double?) -> Any {
        cost.map { rounded($0) } ?? NSNull()
    }

    // MARK: Routes, as JSON

    /// Where a task's requests go today, exactly as `resolveConfig` would send
    /// them: the model, which setting it follows (task_model when the learner
    /// gave a background task a model of its own), whether a meeting task is
    /// being kept off a free model or waits for a paid one, the transport the routing policy maps it to, and the model's
    /// catalogue price.
    static func aiTaskRouteJSON(for task: AITask) -> [String: Any] {
        let selection = KeychainService.resolvedSelection(for: task)
        let ownRoute = KeychainService.ownRoute(for: task)
        let follows: String
        if task == .chat || !task.usesBackgroundModelDefault {
            follows = "default_model"
        } else if ownRoute != nil {
            follows = "task_model"
        } else if task.usesMultimodalBackgroundModelDefault {
            follows = "background_multimodal"
        } else {
            follows = "background_text"
        }
        let transport = KeychainService.routedTextSelection(provider: selection.provider, model: selection.model)
        let price = aiPriceRow(provider: selection.provider, model: selection.model)
        var json: [String: Any] = [
            "task": task.rawValue,
            "display_name": task.displayName,
            "follows": follows,
            "provider": aiProviderJSON(selection.provider),
            "model": selection.model,
            "model_display_name": AIModelCatalog.displayName(provider: selection.provider, modelID: selection.model),
            "requires_vision": task.requiresVision,
            "transport": ["provider": aiProviderJSON(transport.provider), "model": transport.model],
            "price": price ?? NSNull(),
            "price_known": price != nil,
            "in_catalogue": AIModelCatalog.entry(provider: selection.provider, modelID: selection.model) != nil,
        ]
        if AIModelDefaults.isRetiredChatModel(provider: selection.provider, model: selection.model) {
            json["retired"] = true
        }
        if task.sourceType == .meeting {
            // True while its Background model is free and it runs on a paid
            // one instead (`MeetingModels`).
            let background = KeychainService.displayedBackgroundTaskRoute(for: task)
            json["kept_off_free_model"] = ownRoute == nil
                && (background.provider != selection.provider || background.model != selection.model)
            // True while it has no paid model to run on and so waits.
            json["waiting_for_paid_model"] = KeychainService.isWaitingForPaidModel(task)
        }
        if KeychainService.canHaveOwnRoute(task) {
            json["has_own_model"] = ownRoute != nil
        }
        return json
    }

    static func aiRouteJSON(_ route: AITaskModelRoute) -> [String: Any] {
        let price = aiPriceRow(provider: route.provider, model: route.model)
        return [
            "provider": aiProviderJSON(route.provider),
            "model": route.model,
            "model_display_name": AIModelCatalog.displayName(provider: route.provider, modelID: route.model),
            "price": price ?? NSNull(),
            "price_known": price != nil,
        ]
    }

    // MARK: get_ai_usage_report

    func getAIUsageReport(days: Int?, from: String?, to: String?) throws -> String {
        let period = try Self.aiUsageReportPeriod(days: days, from: from, to: to)
        let kstore = try knowledgeStore()
        let filter = KnowledgeStore.AIUsageEventFilter(since: period.since, until: period.until)
        let totals = try kstore.aiUsageEventTotals(filter: filter)
        let rows = try kstore.loadAIUsageTaskModelSummaries(filter: filter)
        let dailyCosts = try kstore.loadAIUsageDailyCosts(filter: filter)
        return try jsonString(Self.aiUsageReportPayload(period: period, totals: totals, rows: rows, days: dailyCosts))
    }

    static func aiUsageReportPayload(
        period: AIUsageReportPeriod,
        totals: AIUsageEventTotals,
        rows: [AIUsageTaskModelSummary],
        days: [AIUsageDailyTotal]
    ) -> [String: Any] {
        let iso = KnowledgeStore.iso8601Formatter

        func sum(_ cost: Double?, _ add: Double?) -> Double? {
            guard let add else { return cost }
            return (cost ?? 0) + add
        }
        func averages(calls: Int, input: Int, output: Int, cached: Int, cost: Double?, unpriced: Int) -> [String: Any] {
            guard calls > 0 else { return [:] }
            var json: [String: Any] = [
                "input_tokens": Double(input) / Double(calls),
                "output_tokens": Double(output) / Double(calls),
                "cache_read_tokens": Double(cached) / Double(calls),
            ]
            // A per-call cost only over the calls that carry a cost; a total
            // spread over unpriced calls would understate what one call costs.
            if let cost, calls - unpriced > 0 {
                json["cost_usd"] = rounded(cost / Double(calls - unpriced))
            } else {
                json["cost_usd"] = NSNull()
            }
            return json
        }
        func cacheReadShare(read: Int, write: Int) -> Any {
            let handled = read + write
            guard handled > 0 else { return NSNull() }
            return rounded(Double(read) / Double(handled), places: 4)
        }

        // By task, with the models each task ran beneath it.
        var taskOrder: [String] = []
        var byTask: [String: [AIUsageTaskModelSummary]] = [:]
        for row in rows {
            if byTask[row.task] == nil { taskOrder.append(row.task) }
            byTask[row.task, default: []].append(row)
        }
        var taskPayloads: [[String: Any]] = taskOrder.map { key in
            let group = byTask[key] ?? []
            let calls = group.reduce(0) { $0 + $1.callCount }
            let input = group.reduce(0) { $0 + $1.inputTokens }
            let output = group.reduce(0) { $0 + $1.outputTokens }
            let cached = group.reduce(0) { $0 + $1.cachedInputTokens }
            let written = group.reduce(0) { $0 + $1.cacheCreationInputTokens }
            let reasoning = group.reduce(0) { $0 + $1.reasoningTokens }
            let unpriced = group.reduce(0) { $0 + $1.unpricedCallCount }
            let cost = group.reduce(nil as Double?) { sum($0, $1.cost) }
            let latest = group.map(\.latestAt).max()
            var json: [String: Any] = [
                "task": key.isEmpty ? NSNull() : key,
                "label": key.isEmpty ? "Untagged calls" : AIUsageTaskLabel.text(for: key),
                "calls": calls,
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_tokens": cached,
                "cache_write_tokens": written,
                "reasoning_tokens": reasoning,
                "cache_read_share": cacheReadShare(read: cached, write: written),
                "cost_usd": costJSON(cost),
                "unpriced_calls": unpriced,
                "per_call": averages(calls: calls, input: input, output: output, cached: cached, cost: cost, unpriced: unpriced),
                "latest_at": latest.map(iso.string) ?? NSNull(),
                "models": group.map { row -> [String: Any] in
                    let provider = aiProvider(ledgerProvider: row.provider)
                    return [
                        "provider": provider.map(aiProviderJSON) ?? ["id": row.provider.lowercased(), "label": row.provider],
                        "model": row.model,
                        "model_display_name": aiModelDisplayName(provider: provider, model: row.model),
                        "calls": row.callCount,
                        "input_tokens": row.inputTokens,
                        "output_tokens": row.outputTokens,
                        "cache_read_tokens": row.cachedInputTokens,
                        "cost_usd": costJSON(row.cost),
                        "unpriced_calls": row.unpricedCallCount,
                    ]
                },
            ]
            if let task = AITask(rawValue: key) {
                json["configurable"] = true
                json["current_route"] = aiTaskRouteJSON(for: task)
            } else {
                // Purpose labels such as read_aloud or chat_quiz_grading are not
                // separately configurable; they follow the feature that made them.
                json["configurable"] = false
                json["current_route"] = NSNull()
            }
            return json
        }
        taskPayloads.sort { lhs, rhs in
            let l = lhs["cost_usd"] as? Double ?? -1
            let r = rhs["cost_usd"] as? Double ?? -1
            if l != r { return l > r }
            return (lhs["calls"] as? Int ?? 0) > (rhs["calls"] as? Int ?? 0)
        }

        // By model, across tasks.
        var modelOrder: [String] = []
        var byModel: [String: [AIUsageTaskModelSummary]] = [:]
        for row in rows {
            let key = "\(row.provider)|\(row.model)"
            if byModel[key] == nil { modelOrder.append(key) }
            byModel[key, default: []].append(row)
        }
        var modelPayloads: [[String: Any]] = modelOrder.map { key in
            let group = byModel[key] ?? []
            let first = group[0]
            let provider = aiProvider(ledgerProvider: first.provider)
            let cost = group.reduce(nil as Double?) { sum($0, $1.cost) }
            let price = aiPriceRow(ledgerProvider: first.provider, model: first.model)
            return [
                "provider": provider.map(aiProviderJSON) ?? ["id": first.provider.lowercased(), "label": first.provider],
                "model": first.model,
                "model_display_name": aiModelDisplayName(provider: provider, model: first.model),
                "calls": group.reduce(0) { $0 + $1.callCount },
                "input_tokens": group.reduce(0) { $0 + $1.inputTokens },
                "output_tokens": group.reduce(0) { $0 + $1.outputTokens },
                "cache_read_tokens": group.reduce(0) { $0 + $1.cachedInputTokens },
                "cache_write_tokens": group.reduce(0) { $0 + $1.cacheCreationInputTokens },
                "cost_usd": costJSON(cost),
                "unpriced_calls": group.reduce(0) { $0 + $1.unpricedCallCount },
                "tasks": group.map(\.task).filter { !$0.isEmpty },
                "price": price ?? NSNull(),
                "price_known": price != nil,
            ]
        }
        modelPayloads.sort { ($0["cost_usd"] as? Double ?? -1) > ($1["cost_usd"] as? Double ?? -1) }

        let dayPayloads: [[String: Any]] = days.map { day in
            [
                "day": day.day,
                "calls": day.requestCount,
                "input_tokens": day.inputTokens,
                "output_tokens": day.outputTokens,
                "cost_usd": costJSON(day.estimatedCost),
            ]
        }

        var payload: [String: Any] = [
            "settings_pane": "AI Usage › Activity",
            "period": [
                "from": iso.string(from: period.since),
                "until": iso.string(from: period.until),
                "days": period.days,
                "explicit": period.explicit,
            ],
            "totals": [
                "calls": totals.count,
                "cost_usd": costJSON(totals.cost),
                "unpriced_calls": totals.unpriced,
                "cache_read_tokens": totals.cacheReadTokens,
                "cache_write_tokens": totals.cacheWriteTokens,
                "cache_read_share": totals.cacheReadShare.map { rounded($0, places: 4) } ?? NSNull(),
            ],
            "by_task": taskPayloads,
            "by_model": modelPayloads,
            "by_day": dayPayloads,
            "routing_mode": KeychainService.textRoutingMode.rawValue,
            "notes": [
                "cost_usd is what the provider billed when it reported an amount, else the list-price estimate stamped when the call was recorded; null means no call in the group could be priced.",
                "unpriced_calls are excluded from every cost_usd total; a total with unpriced calls beside it is a floor, not the spend.",
                "per_call.cost_usd divides the priced total by the priced calls only.",
                "current_route is what the task would run on now, which need not be the model the ledger rows ran on.",
                "Prices are USD per million tokens from the app's pricing table; price_known false means the table has no row and no estimate should be made.",
            ],
        ]
        if totals.count == 0 {
            payload["empty"] = true
        }
        return payload
    }

    // MARK: get_ai_task_settings

    /// `loadDirectory` reads OpenRouter's live directory for `free_models`;
    /// tests pass one that returns nil so no request leaves the machine.
    func getAITaskSettings(
        loadDirectory: () async -> [OpenRouterDirectoryModel]? = {
            try? await OpenRouterCatalogAvailability.shared.models()
        }
    ) async throws -> String {
        var payload = Self.aiTaskSettingsPayload(includeCatalogue: true)
        payload["free_models"] = Self.aiFreeModelsJSON(directory: await loadDirectory())
        payload["free_model_blocker"] = FreeModelsSetup.pickBlocker() ?? NSNull()
        return try jsonString(payload)
    }

    /// Background work's "Free models" submenus as data: the free models that
    /// can run text work and those that can run work that reads images, best
    /// first. Null when the directory could not be read.
    static func aiFreeModelsJSON(directory: [OpenRouterDirectoryModel]?) -> Any {
        guard let directory else { return NSNull() }
        func rows(_ needsVision: Bool) -> [[String: Any]] {
            FreeModelsSetup.candidates(needsVision: needsVision, from: directory).prefix(12).map { model in
                [
                    "provider": "openrouter",
                    "model": model.id,
                    "display_name": model.name,
                    "context_length": model.contextLength ?? NSNull(),
                    "recommended": FreeModelsSetup.isRecommended(model.id),
                ]
            }
        }
        return ["text": rows(false), "reads_images": rows(true)]
    }

    /// A free model named for a Background default or a task is catalogued
    /// here, as picking it from a "Free models" submenu does, so the
    /// catalogue check that follows accepts it. It must be one of the free
    /// models that can do the job, and a free model must be able to run.
    static func catalogFreeModelIfNeeded(provider rawProvider: String?, model rawModel: String?, needsVision: Bool) async throws {
        let model = (rawModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIFreeModels.isFreeModelID(model), aiProvider(named: rawProvider ?? "") == .openRouter else { return }
        if let blocker = FreeModelsSetup.pickBlocker() {
            throw MCPError.invalidInput(blocker)
        }
        guard AIModelCatalog.entry(provider: .openRouter, modelID: model) == nil else { return }
        let directory = try await OpenRouterCatalogAvailability.shared.models()
        if let listed = FreeModelsSetup.rankedFree(needsVision: needsVision, from: directory).first(where: { $0.id == model }) {
            try await requireQualified(provider: .openRouter, model: listed.id, role: needsVision ? .backgroundImages : .background)
        }
        guard let free = FreeModelsSetup.candidates(needsVision: needsVision, from: directory).first(where: { $0.id == model }) else {
            throw MCPError.invalidInput("\(model) is not one of OpenRouter's free models that can do this\(needsVision ? " (it must read images and take tools)" : " (it must take tools)"). Pick one from get_ai_task_settings' free_models.")
        }
        FreeModelsSetup.catalog(free)
    }

    static let aiTaskSettingsTargets = ["default_model", "docs", "background_text", "background_multimodal", "task_model", "meetings", "data_privacy", "host", "backups"]

    /// Arguments `set_ai_task_settings` does not take, because background tasks
    /// have no models of their own: `task_id` names the task. A caller sending
    /// these is told so rather than having them ignored.
    static let retiredAITaskSettingsArguments = ["task", "effort", "speed", "reset"]

    static func aiTaskSettingsPayload(includeCatalogue: Bool) -> [String: Any] {
        let chatProvider = KeychainService.aiProvider
        let chatModel = KeychainService.model(for: chatProvider)
        var defaultModel = aiRouteJSON(AITaskModelRoute(provider: chatProvider, model: chatModel))
        defaultModel["enabled_for_chat"] = AIModelCatalog.isEnabledChatSelection(provider: chatProvider, modelID: chatModel)
        defaultModel["follows"] = "chat and the tasks that share its selection"

        // Edit with AI in a Doc: Docs' own model, or the Default Model.
        var docs = aiRouteJSON(KeychainService.displayedDocsRoute)
        docs["follows_default_model"] = KeychainService.docsRoute == nil

        var backgroundText = aiRouteJSON(KeychainService.displayedBackgroundTaskRoute)
        backgroundText["is_shipped_default"] = KeychainService.backgroundTaskProvider == nil
        var backgroundMultimodal = aiRouteJSON(KeychainService.displayedBackgroundMultimodalTaskRoute)
        backgroundMultimodal["is_shipped_default"] = !Preferences.isSet(Prefs.Models.backgroundMultimodalRoute)

        let tasks: [[String: Any]] = AITask.advancedTasks.map { task in
            var json = aiTaskRouteJSON(for: task)
            json["description"] = task.description
            return json
        }

        let routingMode = KeychainService.textRoutingMode
        var payload: [String: Any] = [
            "settings_pane": "Settings › Chat for the chat's models, and Settings › Background for background work: Text-only and Multimodal, and a Tasks tab where each task can have a model of its own. Whether meetings may use a free model is asked in Setup",
            "default_model": defaultModel,
            "docs": docs,
            "background_text": backgroundText,
            "background_multimodal": backgroundMultimodal,
            "tasks": tasks,
            "meetings_may_use_free": MeetingModels.mayUseFree,
            "routing_mode": routingMode.rawValue,
            "hide_training_models": AIModelCatalog.hidesTrainingModels,
            "hosts": aiHostPreferencesJSON(),
            "backups": aiBackupsJSON(),
            "accepts": [
                "targets": aiTaskSettingsTargets,
                "providers": AIProvider.activeChatProviders.map(\.slashToken),
                "rule": "A selection is a provider id and a model id from the catalogue below, on a provider in providers. Target docs sets the model Edit with AI in a Doc runs on, as the menu under the ForeverLM mark on the Edit with AI panel does; docs with neither provider nor model sends Docs back to the Default Model (docs.follows_default_model). A chat's own model pick never reaches Docs. background_multimodal takes only a model that can read images. A background task runs on background_text or background_multimodal, as follows in its row of tasks says, unless the learner gave it a model of its own (follows task_model, has_own_model true): target task_model with task_id (a task id from tasks) and provider and model sets it, as a task's page under Settings › Background › Tasks does, takes only a model that can do that work (a task with requires_vision takes only a vision model), and with neither provider nor model sends the task back to following Background. Its backups and host are those of the Background model it would otherwise follow. Target data_privacy takes hide_training_models alone: true is Settings › Data & Privacy's “\(AIDataPolicy.switchTitle)”, which leaves every model marked trains_on_inputs out of the pickers and this catalogue; false offers them again, labelled. A free model that OpenRouter starts charging for, or stops listing, is moved off every setting on its own, onto another free model that can do the same work (the Free Models Router first, which never charges), and the learner is notified; there is no switch for it. In catalogue, output_tokens_per_second is OpenRouter's median output speed over the last 30 minutes on the host ForeverLM routes to — null until a picker has measured it, or on a route that never reaches OpenRouter — and openrouter_url is the model's page on OpenRouter. free_models lists OpenRouter's free models that can do background work, best first, as Background work's “Free models” submenus do: text for background_text, reads_images for background_multimodal (the Multimodal list). recommended marks OpenRouter's Free Models Router (\(AIModelDefaults.openRouterFreeRouter)), which sends each request to a free model that is up and can do the job, so it fails and times out less than any one free model: suggest it first, and the single free models after it. It suits background work, since nothing waits on that work, except the meeting tasks (\(MeetingModels.tasks.map(\.rawValue).joined(separator: ", "))): a meeting's transcript holds private conversations, and free models' providers may keep and train on what is sent. Setup asks about them when background work goes free. Unless meetings_may_use_free is true, a meeting task whose Background model is free runs on that model's first paid backup instead and skips its free backups; its row in tasks then says kept_off_free_model. With no paid backup it waits (waiting_for_paid_model) until the learner adds one or gives the task a model of its own; ForeverLM does not pick a paid model for them. A model set for the task itself is used as it is, free or not. So before moving background_text to a free model, ask whether meetings may use it too, and record the answer with target meetings, which takes meetings_may_use_free alone. A model from free_models is accepted as a selection for those targets even before the catalogue lists it, unless free_model_blocker says why no free model can run. It moves only that setting, and it costs nothing for now, but say first that its providers may keep and train on what is sent, that it is often busy or rate-limited, and that it may be free only for a limited time. Target host chooses which of a model's OpenRouter hosts runs one thing, as a chosen model card's ⋯ in Settings › Chat does: host_for is chat, background_text or background_multimodal; model (with provider) names the model, defaulting to what host_for runs on now (the Default Model for chat); host is automatic (the fastest host that caches prompts, the default), cheapest, or an endpoint tag from OpenRouter's GET /api/v1/models/{slug}/endpoints (\"deepinfra/fp4\"; an unknown tag is refused with the model's tags); host_fallback (pinned host only, default true) lets another host take over when it refuses; host_region us keeps whichever host choice is made to the hosts OpenRouter lists as running in the US (its us.openrouter.ai directory), so none of the model's other hosts, such as those in China, may take the work, and a request whose US list cannot be read is not sent; any lifts that; omitted, the stored region stays, and host_region alone changes only the region. A choice is kept per model, so it applies only while that model runs there; a background task follows the choice its Background setting made for the model it runs on, a backup included. hosts lists every stored choice. A pinned host replaces the Speed choice, and the price is that host's. Target backups sets a setting's backup models, as Use as Backup on a model card in Settings › Chat or Settings › Background does: backups_for is chat, background_text or background_multimodal; a background task uses the backups of the one it runs on. The chat's backups stand in for the Default Model only in a scheduled task's runs, which nobody is watching; a chat the learner types in stays on the model they picked; backups is the whole ordered list, at most \(AIBackupModels.limit), each a provider and model the same target would accept as its selection, and an empty list removes them. When the setting's model is busy, fails or sends back nothing usable, the work moves to its backups in order, each billed at its own price; a failure every model would share (no key, no balance, no connection) does not move. backups lists every setting that has them.",
            ],
            "reach": "account",
        ]
        if includeCatalogue {
            payload["catalogue"] = aiCatalogueJSON()
        }
        return payload
    }

    /// The catalogue the pickers offer: every maker group, newest model first,
    /// with the price row the Settings cards quote.
    static func aiCatalogueJSON() -> [[String: Any]] {
        let groups = AIModelCatalog.makerGroups
        let enabled = AIModelCatalog.enabledIDs
        let defaultID = AIModelCatalog.defaultEntry?.id
        let iso = KnowledgeStore.iso8601Formatter
        return groups.map { group in
            [
                "maker": group.maker.rawValue,
                "maker_label": group.maker.displayName,
                "models": group.entries.map { entry -> [String: Any] in
                    let price = aiPriceRow(provider: entry.provider, model: entry.modelID)
                    var json: [String: Any] = [
                        "provider": aiProviderJSON(entry.provider),
                        "model": entry.modelID,
                        "display_name": entry.displayName,
                        "price": price ?? NSNull(),
                        "price_known": price != nil,
                        "enabled_for_chat": enabled.contains(entry.id),
                        "is_default_model": entry.id == defaultID,
                        "selectable": AIProvider.activeChatProviders.contains(entry.provider)
                            && !AIModelDefaults.isRetiredChatModel(provider: entry.provider, model: entry.modelID),
                        "supported_efforts": AIRequestOptionSupport.supportedEfforts(provider: entry.provider, model: entry.modelID).map(\.rawValue),
                        "route_can_carry_speed": AIRequestOptionSupport.routeCanCarrySpeed(provider: entry.provider, model: entry.modelID),
                        "user_added": AIModelCatalog.isCustom(entry),
                        "trains_on_inputs": entry.trainsOnInputs,
                        // A model is tested the first time it is picked for chat,
                        // background work or work that reads images; one that
                        // failed stays offered and is tested again when picked.
                        "qualification": aiQualificationJSON(provider: entry.provider, model: entry.modelID),
                    ]
                    json["supports_vision"] = KeychainService.modelSupportsVision(provider: entry.provider, model: entry.modelID) ?? NSNull()
                    json["release_date"] = AIModelCatalog.releaseDate(for: entry).map(iso.string) ?? NSNull()
                    json["openrouter_url"] = OpenRouterModelPage.url(provider: entry.provider, model: entry.modelID)?
                        .absoluteString ?? NSNull()
                    // The figure the Settings card and the picker's Speed submenu quote, from
                    // the same cache; null until a picker has fetched it, or on
                    // a route that never reaches OpenRouter.
                    json["output_tokens_per_second"] = AIRequestOptionSupport
                        .openRouterSpeedSlug(
                            provider: entry.provider, model: entry.modelID,
                            routingMode: KeychainService.textRoutingMode)
                        .flatMap { OpenRouterModelSpeedCatalog.cachedTokensPerSecond(slug: $0, speed: .standard) }
                        .map { $0.rounded() } ?? NSNull()
                    return json
                },
            ]
        }
    }

    // MARK: Host choices

    /// Every stored host choice (`OpenRouterHostPreference`), as `hosts`.
    static func aiHostPreferencesJSON() -> [[String: Any]] {
        Prefs.Families.openRouterHost.rows().keys
            .sorted()
            .compactMap { rest -> [String: Any]? in
                guard let bar = rest.firstIndex(of: "|") else { return nil }
                let slot = String(rest[..<bar])
                let slug = String(rest[rest.index(after: bar)...])
                guard let preference = OpenRouterHostPreference.stored(slot: slot, slug: slug) else { return nil }
                var json: [String: Any] = ["model": slug]
                switch slot {
                case "chat": json["host_for"] = "chat"
                case "background.text": json["host_for"] = "background_text"
                case "background.images": json["host_for"] = "background_multimodal"
                default: return nil
                }
                switch preference.mode {
                case .automatic:
                    json["host"] = "automatic"
                case .cheapest:
                    json["host"] = "cheapest"
                case .host:
                    json["host"] = preference.tag ?? ""
                    json["host_name"] = preference.hostName ?? NSNull()
                    json["host_fallback"] = preference.allowsFallback
                }
                json["host_region"] = preference.region?.rawValue ?? "any"
                return json
            }
    }

    // MARK: Backup models

    /// The API name and ids for a backup slot (`AIBackupModels`).
    private static func backupsFor(slot: String) -> [String: Any]? {
        switch slot {
        case AIBackupModels.chatSlot: return ["backups_for": "chat"]
        case "background.text": return ["backups_for": "background_text"]
        case "background.images": return ["backups_for": "background_multimodal"]
        default: return nil
        }
    }

    /// Every setting's backup models, as `backups`.
    static func aiBackupsJSON() -> [[String: Any]] {
        AIBackupModels.allStored().sorted { $0.key < $1.key }.compactMap { slot, routes in
            guard var json = backupsFor(slot: slot) else { return nil }
            json["models"] = routes.map(aiRouteJSON)
            return json
        }
    }

    /// Target backups: Use as Backup's write. Returns whether anything changed.
    static func setAIBackups(
        backupsFor rawBackupsFor: String?,
        backups rawBackups: [[String: Any]]?
    ) async throws -> Bool {
        let backupsFor = (rawBackupsFor ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slot: String
        let primary: AITaskModelRoute
        let needsVision: Bool
        let role: AIModelQualification.Role
        switch backupsFor {
        case "chat":
            // Only a scheduled task's run walks these; a chat the learner
            // types in stays on the model they picked.
            slot = AIBackupModels.chatSlot
            let provider = KeychainService.aiProvider
            primary = AITaskModelRoute(provider: provider, model: KeychainService.model(for: provider))
            needsVision = false
            role = .chat
        case "background_text":
            slot = "background.text"
            primary = KeychainService.displayedBackgroundTaskRoute
            needsVision = false
            role = .background
        case "background_multimodal":
            slot = "background.images"
            primary = KeychainService.displayedBackgroundMultimodalTaskRoute
            needsVision = true
            role = .backgroundImages
        default:
            throw MCPError.invalidInput("backups_for must be chat, background_text or background_multimodal.")
        }
        guard let rawBackups else {
            throw MCPError.invalidInput("target backups takes backups: the ordered list of provider and model pairs, [] to remove them.")
        }
        guard rawBackups.count <= AIBackupModels.limit else {
            throw MCPError.invalidInput("A setting takes at most \(AIBackupModels.limit) backups.")
        }
        var routes: [AITaskModelRoute] = []
        for row in rawBackups {
            let provider = row["provider"] as? String
            let model = row["model"] as? String
            try await catalogFreeModelIfNeeded(provider: provider, model: model, needsVision: needsVision)
            let entry = try aiCatalogueSelection(provider: provider ?? "", model: model ?? "", needsVision: needsVision)
            let identity = AIBackupModels.identity(entry.provider, entry.modelID)
            guard identity != AIBackupModels.identity(primary.provider, primary.model) else {
                throw MCPError.invalidInput("\(entry.displayName) is the model this setting runs on, so it cannot also be its backup.")
            }
            guard !routes.contains(where: { AIBackupModels.identity($0.provider, $0.model) == identity }) else {
                throw MCPError.invalidInput("\(entry.displayName) is listed twice.")
            }
            try await requireQualified(provider: entry.provider, model: entry.modelID, role: role)
            routes.append(AITaskModelRoute(provider: entry.provider, model: entry.modelID))
        }
        guard AIBackupModels.stored(slot: slot) != routes else { return false }
        AIBackupModels.set(routes, slot: slot)
        return true
    }

    /// Target host: the host panel's write. Returns whether anything changed.
    static func setAIHost(
        hostFor rawHostFor: String?,
        provider rawProvider: String?,
        model rawModel: String?,
        host rawHost: String?,
        fallback: Bool?,
        region rawRegion: String? = nil
    ) async throws -> Bool {
        let hostFor = (rawHostFor ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slot: String
        let current: AITaskModelRoute
        switch hostFor {
        case "chat":
            slot = "chat"
            let provider = KeychainService.aiProvider
            current = AITaskModelRoute(provider: provider, model: KeychainService.model(for: provider))
        case "background_text":
            slot = "background.text"
            current = KeychainService.displayedBackgroundTaskRoute
        case "background_multimodal":
            slot = "background.images"
            current = KeychainService.displayedBackgroundMultimodalTaskRoute
        default:
            throw MCPError.invalidInput("host_for must be chat, background_text or background_multimodal.")
        }

        let modelText = (rawModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let slug: String
        if modelText.isEmpty {
            guard (rawProvider ?? "").isEmpty else { throw MCPError.invalidInput("provider needs a model.") }
            slug = OpenRouterModelID.slug(provider: current.provider, model: current.model)
        } else {
            let providerText = (rawProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = providerText.isEmpty
                ? AIProvider.openRouter
                : AIProvider.allCases.first { $0.slashToken == providerText || $0.rawValue == providerText }
            guard let provider else { throw MCPError.invalidInput("Unknown provider \(providerText).") }
            slug = OpenRouterModelID.slug(provider: provider, model: modelText)
        }

        // host_region keeps whichever host choice is made to the hosts
        // OpenRouter lists as running in one region; omitted, the region the
        // stored choice has stays.
        let stored = OpenRouterHostPreference.stored(slot: slot, slug: slug)
        let regionText = (rawRegion ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let region: OpenRouterHostPreference.Region?
        switch regionText {
        case "": region = stored?.region
        case "any": region = nil
        default:
            guard let named = OpenRouterHostPreference.Region(rawValue: regionText) else {
                throw MCPError.invalidInput("host_region must be \(OpenRouterHostPreference.Region.allCases.map(\.rawValue).joined(separator: ", ")) or any.")
            }
            region = named
        }
        var regionTags: Set<String>?
        if let region {
            let endpoints = try await OpenRouterRegionalEndpoints.shared.endpoints(for: slug, region: region)
            guard !endpoints.isEmpty else {
                throw MCPError.invalidInput("OpenRouter lists no host in \(region.name) for \(slug), so it cannot be kept there.")
            }
            regionTags = Set(endpoints.map(\.tag))
        }

        let hostText = (rawHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base: OpenRouterHostPreference
        switch hostText.lowercased() {
        case "":
            guard !regionText.isEmpty else {
                throw MCPError.invalidInput("target host takes host: automatic, cheapest, or an endpoint tag of the model; or host_region alone to keep the host choice and change its region.")
            }
            let kept = stored ?? OpenRouterHostPreference(mode: .automatic)
            base = OpenRouterHostPreference(
                mode: kept.mode,
                tag: kept.tag,
                hostName: kept.hostName,
                allowsFallback: fallback ?? kept.allowsFallback
            )
        case "automatic":
            base = OpenRouterHostPreference(mode: .automatic)
        case "cheapest":
            base = OpenRouterHostPreference(mode: .cheapest)
        default:
            let hosts = try await OpenRouterEndpointTierCatalog.shared.tiers(for: slug)
                .filter { !OpenRouterSpeedTier.isServiceTier($0.tag) }
            guard let endpoint = hosts.first(where: { $0.tag.lowercased() == hostText.lowercased() }) else {
                let tags = hosts.map(\.tag).joined(separator: ", ")
                throw MCPError.invalidInput("OpenRouter lists no host \(hostText) for \(slug). Its hosts: \(tags.isEmpty ? "none" : tags). A lab's fast, flex or priority tier is the speed setting, not a host.")
            }
            base = OpenRouterHostPreference(
                mode: .host,
                tag: endpoint.tag,
                hostName: endpoint.providerName,
                allowsFallback: fallback ?? true
            )
        }
        if fallback != nil, base.mode != .host {
            throw MCPError.invalidInput("host_fallback applies to a pinned host only.")
        }
        if let region, let regionTags, base.mode == .host,
           let tag = base.tag?.lowercased(), !regionTags.contains(tag) {
            throw MCPError.invalidInput("\(base.tag ?? tag) does not run in \(region.name). \(slug)'s hosts there: \(regionTags.sorted().joined(separator: ", ")).")
        }
        let preference = base.inRegion(region)
        guard stored != preference else { return false }
        OpenRouterHostPreference.set(preference, slot: slot, slug: slug)
        return true
    }

    // MARK: set_ai_task_settings

    /// One catalogue selection a caller named, validated the way the pane's
    /// menus limit what can be picked: a catalogued model on a provider the
    /// chat surface offers, not retired, and able to see images when the
    /// target needs that.
    static func aiCatalogueSelection(provider rawProvider: String, model rawModel: String, needsVision: Bool) throws -> AIModelCatalogEntry {
        let providerText = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerText.isEmpty, !model.isEmpty else {
            throw MCPError.invalidInput("Pass provider and model together, as get_ai_task_settings lists them in catalogue.")
        }
        guard let provider = aiProvider(named: providerText) else {
            throw MCPError.invalidInput("Unknown provider \(providerText). Providers: \(AIProvider.activeChatProviders.map(\.slashToken).joined(separator: ", ")).")
        }
        guard AIProvider.activeChatProviders.contains(provider) else {
            throw MCPError.invalidInput("\(provider.shortName) is not offered on this account right now. Providers: \(AIProvider.activeChatProviders.map(\.slashToken).joined(separator: ", ")).")
        }
        if AIModelCatalog.hidesTrainingModels, AIModelDefaults.trainsOnInputs(provider: provider, model: model) {
            throw MCPError.invalidInput("\(AIModelCatalog.displayName(provider: provider, modelID: model)) trains on what is sent to it, and “\(AIDataPolicy.switchTitle)” is on under \(AIDataPolicy.settingsLocation). Turn it off (target data_privacy, hide_training_models false) to select it.")
        }
        guard let entry = AIModelCatalog.entry(provider: provider, modelID: model) else {
            throw MCPError.invalidInput("\(model) is not in the \(provider.shortName) catalogue. Pick a model from get_ai_task_settings' catalogue; a model the catalogue does not list cannot be selected.")
        }
        guard !AIModelDefaults.isRetiredChatModel(provider: provider, model: model) else {
            throw MCPError.invalidInput("\(entry.displayName) is retired and cannot be selected.")
        }
        if needsVision, KeychainService.modelSupportsVision(provider: provider, model: model) == false {
            throw MCPError.invalidInput("\(entry.displayName) cannot read images; this target needs a vision model.")
        }
        return entry
    }

    /// A pick in a picker is applied only once the model passed a test run
    /// of the work (`AIModelQualification`), so a selection made here too:
    /// an untested model, or one that failed before, is tested now, on the
    /// spot. One this Mac cannot test (no key, no balance) is let through,
    /// since no work runs until it can.
    static func requireQualified(provider: AIProvider, model: String, role: AIModelQualification.Role) async throws {
        let name = AIModelCatalog.displayName(provider: provider, modelID: model)
        let retest = AIModelQualification.isKnownToFail(provider: provider, model: model, role: role)
        switch await AIModelQualification.qualify(provider: provider, model: model, role: role, force: retest) {
        case .passed:
            return
        case .failed(let message):
            throw MCPError.invalidInput("\(name) failed a test run of \(role.label) just now, so it was not applied. It stays in the catalogue; ask again to run the test again. OpenRouter said: \(message)")
        case .untested:
            guard AIModelQualification.canTest else { return }
            throw MCPError.invalidInput("\(name) could not be tested for \(role.label) just now (OpenRouter was busy or unreachable), and a model is offered only after it passes. Try again in a minute.")
        }
    }

    /// Each role's verdict for one catalogue model, as `qualification` in the
    /// catalogue: passed, failed with OpenRouter's words, or untested.
    static func aiQualificationJSON(provider: AIProvider, model: String) -> [String: Any] {
        var json: [String: Any] = [:]
        for role in AIModelQualification.roles(provider: provider, model: model) {
            let slug = AIModelQualification.slug(provider: provider, model: model)
            switch AIModelQualification.status(slug: slug, role: role) {
            case .passed: json[role.rawValue] = ["status": "passed"]
            case .failed(let message): json[role.rawValue] = ["status": "failed", "message": message]
            case .untested: json[role.rawValue] = ["status": "untested"]
            }
        }
        return json
    }

    /// Settings › AI Models, written. Each target goes through the call the
    /// pane's own control makes, so what the pane accepts and what this
    /// accepts are one and the same: `AIModelCatalog.setDefault` for the
    /// Default Model card, `setDocsRoute` for the Docs model,
    /// `setBackgroundTaskRoute` / `setBackgroundMultimodalTaskRoute`
    /// for the two Background pickers, `setOwnRoute` for one task's own
    /// model, and `MeetingModels.setMayUseFree` for
    /// Setup's Meetings answer. Returns the resulting settings without the
    /// catalogue. `retiredArguments` names any of
    /// `retiredAITaskSettingsArguments` the caller sent.
    func setAITaskSettings(
        target rawTarget: String,
        provider rawProvider: String?,
        model rawModel: String?,
        hideTrainingModels: Bool? = nil,
        meetingsMayUseFree: Bool? = nil,
        hostFor rawHostFor: String? = nil,
        host rawHost: String? = nil,
        hostFallback: Bool? = nil,
        hostRegion rawHostRegion: String? = nil,
        backupsFor rawBackupsFor: String? = nil,
        backups rawBackups: [[String: Any]]? = nil,
        taskID rawTaskID: String? = nil,
        retiredArguments: [String] = []
    ) async throws -> String {
        if !retiredArguments.isEmpty {
            throw MCPError.invalidInput("\(retiredArguments.joined(separator: ", ")) no longer apply. A background task's own model is target task_model with task_id (an id from get_ai_task_settings' tasks) and provider and model, and neither provider nor model sends it back to following background_text or background_multimodal. A meeting task stays off free models unless target meetings allows them or it has a model of its own.")
        }
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.aiTaskSettingsTargets.contains(target) else {
            throw MCPError.invalidInput("target must be one of \(Self.aiTaskSettingsTargets.joined(separator: ", ")).")
        }
        if target != "data_privacy", hideTrainingModels != nil {
            throw MCPError.invalidInput("hide_training_models applies to target data_privacy only.")
        }
        if target != "task_model", rawTaskID != nil {
            throw MCPError.invalidInput("task_id applies to target task_model only.")
        }
        if target != "meetings", meetingsMayUseFree != nil {
            throw MCPError.invalidInput("meetings_may_use_free applies to target meetings only.")
        }
        if target != "host", rawHostFor != nil || rawHost != nil || hostFallback != nil || rawHostRegion != nil {
            throw MCPError.invalidInput("host_for, host, host_fallback and host_region apply to target host only.")
        }
        if target != "backups", rawBackupsFor != nil || rawBackups != nil {
            throw MCPError.invalidInput("backups_for and backups apply to target backups only.")
        }
        let before = Self.aiTaskSettingsPayload(includeCatalogue: false)
        var changed: [String] = []

        switch target {
        case "default_model":
            let entry = try Self.aiCatalogueSelection(provider: rawProvider ?? "", model: rawModel ?? "", needsVision: false)
            let wasDefault = AIModelCatalog.isDefault(entry)
            if !wasDefault {
                try await Self.requireQualified(provider: entry.provider, model: entry.modelID, role: .chat)
                AIModelCatalog.setDefault(entry)
                changed.append("default_model")
            }
        case "docs":
            // Docs' own model, as the menu under the ForeverLM mark on the
            // Edit with AI panel sets it; neither provider nor model sends
            // Docs back to the Default Model.
            let providerText = (rawProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let modelText = (rawModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if providerText.isEmpty, modelText.isEmpty {
                if KeychainService.docsRoute != nil {
                    KeychainService.setDocsRoute(nil)
                    changed.append("docs")
                }
            } else {
                let entry = try Self.aiCatalogueSelection(provider: providerText, model: modelText, needsVision: false)
                let current = KeychainService.docsRoute
                if current?.provider != entry.provider || current?.model != entry.modelID {
                    try await Self.requireQualified(provider: entry.provider, model: entry.modelID, role: .chat)
                    KeychainService.setDocsRoute(AITaskModelRoute(provider: entry.provider, model: entry.modelID))
                    changed.append("docs")
                }
            }
        case "background_text":
            try await Self.catalogFreeModelIfNeeded(provider: rawProvider, model: rawModel, needsVision: false)
            let entry = try Self.aiCatalogueSelection(provider: rawProvider ?? "", model: rawModel ?? "", needsVision: false)
            let current = KeychainService.displayedBackgroundTaskRoute
            if current.provider != entry.provider || current.model != entry.modelID {
                try await Self.requireQualified(provider: entry.provider, model: entry.modelID, role: .background)
                KeychainService.setBackgroundTaskRoute(provider: entry.provider, model: entry.modelID)
                changed.append("background_text")
            }
        case "background_multimodal":
            try await Self.catalogFreeModelIfNeeded(provider: rawProvider, model: rawModel, needsVision: true)
            let entry = try Self.aiCatalogueSelection(provider: rawProvider ?? "", model: rawModel ?? "", needsVision: true)
            let current = KeychainService.displayedBackgroundMultimodalTaskRoute
            if current.provider != entry.provider || current.model != entry.modelID {
                try await Self.requireQualified(provider: entry.provider, model: entry.modelID, role: .backgroundImages)
                KeychainService.setBackgroundMultimodalTaskRoute(provider: entry.provider, model: entry.modelID)
                changed.append("background_multimodal")
            }
        case "task_model":
            // One background task's own model, as a task's page under Settings ›
            // Background › Tasks sets it; neither provider nor model sends the
            // task back to following Background.
            let idText = (rawTaskID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let task = AITask(rawValue: idText), KeychainService.canHaveOwnRoute(task) else {
                throw MCPError.invalidInput("target task_model takes task_id: one of \(AITask.advancedTasks.filter(KeychainService.canHaveOwnRoute).map(\.rawValue).joined(separator: ", ")).")
            }
            let providerText = (rawProvider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let modelText = (rawModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let current = KeychainService.ownRoute(for: task)
            if providerText.isEmpty, modelText.isEmpty {
                if current != nil {
                    KeychainService.setOwnRoute(nil, for: task)
                    changed.append("task_model")
                }
            } else {
                try await Self.catalogFreeModelIfNeeded(provider: rawProvider, model: rawModel, needsVision: task.requiresVision)
                let entry = try Self.aiCatalogueSelection(provider: providerText, model: modelText, needsVision: task.requiresVision)
                if current?.provider != entry.provider || current?.model != entry.modelID {
                    try await Self.requireQualified(provider: entry.provider, model: entry.modelID, role: task.qualificationRole)
                    KeychainService.setOwnRoute(AITaskModelRoute(provider: entry.provider, model: entry.modelID), for: task)
                    changed.append("task_model")
                }
            }
        case "data_privacy":
            // The Data & Privacy switch, written through the same synced rail
            // the pane's toggle uses, with the same catalog reaction.
            guard let hide = hideTrainingModels else {
                throw MCPError.invalidInput("target data_privacy takes hide_training_models: true or false.")
            }
            guard (rawProvider ?? "").isEmpty, (rawModel ?? "").isEmpty else {
                throw MCPError.invalidInput("target data_privacy takes hide_training_models alone, not a selection.")
            }
            if AIModelCatalog.hidesTrainingModels != hide {
                Preferences.set(hide, for: Prefs.AIPolicy.denyDataCollection)
                AIModelCatalog.dataPolicyDidChange()
                changed.append("hide_training_models")
            }
        case "meetings":
            // Setup's Meetings answer. It moves no model: a meeting task reads
            // it each time it runs (`MeetingModels.staysOffFree`).
            guard let allowed = meetingsMayUseFree else {
                throw MCPError.invalidInput("target meetings takes meetings_may_use_free: true lets meeting tasks run on a free Background model, false keeps them on a paid one.")
            }
            guard (rawProvider ?? "").isEmpty, (rawModel ?? "").isEmpty else {
                throw MCPError.invalidInput("target meetings takes meetings_may_use_free alone, not a selection.")
            }
            if MeetingModels.mayUseFree != allowed {
                MeetingModels.setMayUseFree(allowed)
                changed.append("meetings_may_use_free")
            }
        case "host":
            if try await Self.setAIHost(
                hostFor: rawHostFor,
                provider: rawProvider,
                model: rawModel,
                host: rawHost,
                fallback: hostFallback,
                region: rawHostRegion
            ) {
                changed.append("host")
            }
        case "backups":
            guard (rawProvider ?? "").isEmpty, (rawModel ?? "").isEmpty else {
                throw MCPError.invalidInput("target backups takes its models in backups, not provider and model.")
            }
            if try await Self.setAIBackups(backupsFor: rawBackupsFor, backups: rawBackups) {
                changed.append("backups")
            }
        default:
            break
        }

        await PreferenceStore.flushPendingWrites()

        var payload = Self.aiTaskSettingsPayload(includeCatalogue: false)
        payload["target"] = target
        payload["updated"] = !changed.isEmpty
        payload["changed"] = changed
        payload["before"] = [
            "default_model": before["default_model"] ?? NSNull(),
            "docs": before["docs"] ?? NSNull(),
            "background_text": before["background_text"] ?? NSNull(),
            "background_multimodal": before["background_multimodal"] ?? NSNull(),
        ]
        return try jsonString(payload)
    }
}
