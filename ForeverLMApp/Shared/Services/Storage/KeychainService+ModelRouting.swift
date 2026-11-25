// AI model routing preferences (chat, background and per-task routes).

import Foundation

extension KeychainService {
    // MARK: - Text Routing

    /// The transport every ordinary managed text request uses. The server names
    /// it; OpenRouter is the one text router and the shipped default.
    ///
    /// This is deliberately not the user's choice, and not a synced preference:
    /// the proxy refuses a request naming a different transport, so a stale
    /// synced value would only produce 403s. It is server policy because the
    /// reason to change it — a router outage, a de-listed model family — arrives
    /// without warning and must not wait on an App Store release. The setter
    /// still writes the preference so older builds keep a complete
    /// configuration, but nothing here reads it back.
    static var textRoutingMode: AITextRoutingMode {
        get {
            // The learner's own key names its router itself. The account-wide
            // policy exists to keep ForeverLM's spend on one exactly billed
            // rail; a request ForeverLM is not paying for is outside it, and the
            // proxy admits the key's router regardless of the policy.
            if let own = ManagedAI.ownKeyRouter { return own.routingMode }
            return .shippedDefault
        }
        set {
            Preferences.set(newValue.rawValue, for: Prefs.Models.textRoutingMode)
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    /// Applies the account transport policy after a task's canonical
    /// provider/model selection and request options have been validated.
    static func routedTextSelection(
        provider: AIProvider,
        model: String,
        speed: AISpeed? = nil,
        mode: AITextRoutingMode = textRoutingMode
    ) -> (provider: AIProvider, model: String) {
        switch mode {
        case .openRouter:
            return (.openRouter, OpenRouterModelID.slug(provider: provider, model: model))
        }
    }

    /// Re-applies the account-wide transport policy at the moment a request is
    /// dispatched. Background workflows can retain an `AITaskConfig` for many
    /// minutes; resolving only when that workflow starts would let an old
    /// config escape a transport change the server made in between.
    static func routedTextConfig(
        _ config: AITaskConfig,
        mode: AITextRoutingMode = textRoutingMode
    ) -> AITaskConfig {
        let routed = routedTextSelection(
            provider: config.provider,
            model: config.model,
            speed: config.speed,
            mode: mode
        )
        var result = AITaskConfig(
            provider: routed.provider,
            apiKey: apiKey(for: routed.provider) ?? config.apiKey,
            model: routed.model
        )
        result.effort = config.effort
        result.speed = config.speed
        result.taskLabel = config.taskLabel
        result.isBackup = config.isBackup
        return result
    }

    // MARK: - Background Model

    /// Routes used when the learner has never made a Background selection.
    /// Both are OpenRouter's Free Models Router, so opening the app never
    /// starts spending money (product owner, 2026-11-21: "You don't want to
    /// have people open the app and immediately it's already costing money by
    /// doing some background processing"). The router sends each request to a
    /// free model that can do the job, images included, so text and
    /// image-reading work share it.
    static let defaultBackgroundTaskRoute = AITaskModelRoute(
        provider: .openRouter,
        model: AIModelDefaults.openRouterFreeRouter
    )

    static let defaultBackgroundMultimodalTaskRoute = AITaskModelRoute(
        provider: .openRouter,
        model: AIModelDefaults.openRouterFreeRouter
    )

    static func storedRoute(_ key: AccountKey<Data?>) -> AIModelRoutePreference? {
        decodedRoute(Preferences.value(key))
    }

    static func storedRoute(_ key: AccountKey<Any?>) -> AIModelRoutePreference? {
        decodedRoute(Preferences.value(key) as? Data)
    }

    /// The `aiRoute.task.<task>` row: the model the learner gave one task.
    private static func taskRouteKey(_ task: AITask) -> AccountKey<Any?> {
        Prefs.Families.aiTaskRoute.key(task.rawValue)
    }

    private static func decodedRoute(_ stored: Data?) -> AIModelRoutePreference? {
        guard let data = stored,
              let route = try? JSONDecoder().decode(AIModelRoutePreference.self, from: data),
              route.isValid,
              let provider = AIProvider(rawValue: route.provider),
              provider.canServeStoredSelection,
              route.effort == nil || route.effort.flatMap(AIEffort.init(rawValue:)) != nil,
              route.speed == nil || route.speed.flatMap(AISpeed.init(rawValue:)) != nil else { return nil }
        return route
    }

    private static func storedRouteIsInvalid(_ key: AccountKey<Data?>) -> Bool {
        Preferences.isSet(key) && storedRoute(key) == nil
    }

    private static func storedRouteIsInvalid(_ key: AccountKey<Any?>) -> Bool {
        Preferences.isSet(key) && storedRoute(key) == nil
    }

    private static func modelRouteConfigurationIsInvalid(for task: AITask) -> Bool {
        let effectiveTask = task.followsChatRoute ? AITask.chat : task

        if effectiveTask == .chat {
            let taskKey = taskRouteKey(.chat)
            if storedRouteIsInvalid(taskKey) { return true }
            if Preferences.isSet(taskKey) { return false }
            if storedRouteIsInvalid(Prefs.Models.defaultChatRoute) { return true }
            guard !Preferences.isSet(Prefs.Models.defaultChatRoute),
                  let raw = load(.aiProvider) else { return false }
            return !["anthropic", "openai", "xai", "gemini", "meta", "openrouter"].contains(raw)
        }

        // A model the learner set for this task that cannot be read fails the
        // task closed rather than quietly running Background's.
        if storedRouteIsInvalid(taskRouteKey(effectiveTask)) { return true }

        if effectiveTask.usesMultimodalBackgroundModelDefault {
            return storedRouteIsInvalid(Prefs.Models.backgroundMultimodalRoute)
        }

        if storedRouteIsInvalid(Prefs.Models.backgroundRoute) { return true }
        guard !Preferences.isSet(Prefs.Models.backgroundRoute),
              let raw = Preferences.value(Prefs.Models.backgroundProvider) else { return false }
        guard let provider = AIProvider(rawValue: raw) else { return true }
        return !provider.canServeStoredSelection
    }

    private static func saveRoute(_ route: AIModelRoutePreference, to key: AccountKey<Data?>) {
        guard route.isValid, let data = try? JSONEncoder().encode(route) else { return }
        Preferences.set(data, for: key)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    private static func saveRoute(_ route: AIModelRoutePreference, to key: AccountKey<Any?>) {
        guard route.isValid, let data = try? JSONEncoder().encode(route) else { return }
        Preferences.set(data, for: key)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    static func setDefaultChatRoute(provider: AIProvider, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: provider.rawValue, model: trimmed),
            to: Prefs.Models.defaultChatRoute
        )
        // The per-provider model and the provider slot are the "last model per
        // provider" store the pickers read; the atomic route above is the
        // authoritative choice.
        setModel(trimmed, for: provider)
        aiProvider = provider
    }

    static func setBackgroundTaskRoute(provider: AIProvider, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: provider.rawValue, model: trimmed),
            to: Prefs.Models.backgroundRoute
        )
        Preferences.set(provider.rawValue, for: Prefs.Models.backgroundProvider)
        Preferences.set(trimmed, for: backgroundTaskModelKey(for: provider))
        Preferences.reset(Prefs.Models.retiredBackgroundModel)
    }

    static func setBackgroundMultimodalTaskRoute(provider: AIProvider, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: provider.rawValue, model: trimmed),
            to: Prefs.Models.backgroundMultimodalRoute
        )
    }

    // MARK: - A Background task's own model

    /// Whether `task` can be given a model of its own: it runs on a Background
    /// model today and is one of the tasks Settings › Background lists.
    static func canHaveOwnRoute(_ task: AITask) -> Bool {
        task.usesBackgroundModelDefault && AITask.advancedTasks.contains(task)
    }

    /// The model the learner set for `task` itself, which wins over Background's
    /// (product owner, 2026-10-07: "people should be allowed to set it for each task
    /// still somehow"). Synced as `aiRoute.task.<task>`. Nil while the task
    /// follows Background, and while the pick is a free model that OpenRouter
    /// now charges for.
    static func ownRoute(for task: AITask) -> AITaskModelRoute? {
        guard let route = storedOwnRoute(for: task) else { return nil }
        if AIFreeModels.isFreeModelID(route.model), AIFreeModelPrices.hasEnded(route.model) { return nil }
        return route
    }

    /// The model the learner set for `task` as stored, including a free model
    /// whose free period ended (`ownRoute` hides that one).
    static func storedOwnRoute(for task: AITask) -> AITaskModelRoute? {
        guard canHaveOwnRoute(task),
              let stored = storedRoute(taskRouteKey(task)),
              let provider = AIProvider(rawValue: stored.provider) else { return nil }
        return AITaskModelRoute(provider: provider, model: stored.model)
    }

    /// The tasks whose own pick is `model`, as stored: unlike `ownRoute`, still
    /// naming a free model whose free period ended, so the price watch can move it.
    static func tasksWithOwnRoute(on model: String) -> [AITask] {
        let wanted = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AITask.allCases.filter { task in
            guard let route = storedOwnRoute(for: task), route.provider == .openRouter else { return false }
            return route.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
    }

    /// Gives `task` a model of its own, or with nil sends it back to
    /// Background's.
    static func setOwnRoute(_ route: AITaskModelRoute?, for task: AITask) {
        guard canHaveOwnRoute(task) else { return }
        guard let route else {
            Preferences.reset(taskRouteKey(task))
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
            return
        }
        let trimmed = route.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: route.provider.rawValue, model: trimmed),
            to: taskRouteKey(task)
        )
    }

    /// The synced mark that Canvas Voice was given its starting model, so a
    /// learner who sends it back to Background is not given it again, here
    /// or on another Mac (`aiSeeded.task.<task>`).
    private static func seededKey(_ task: AITask) -> AccountKey<Any?> {
        Prefs.Families.aiSeededTask.key(task.rawValue)
    }

    /// Gives Canvas Voice its starting model (`AIModelDefaults.canvasVoice`)
    /// as a model of its own, once for the account, when it has none: speaking
    /// to the canvas is waited on, and Background's model is chosen for work
    /// nobody waits on. Run when the learner first speaks to a canvas rather
    /// than at launch, so a new Mac has read the account's settings first.
    /// It then shows, and is changed, in Settings › Background › Tasks like
    /// any model the learner set.
    static func seedCanvasVoiceRoute() {
        guard canHaveOwnRoute(.canvasVoice),
              Preferences.value(seededKey(.canvasVoice)) as? Bool != true,
              storedRoute(taskRouteKey(.canvasVoice)) == nil else { return }
        Preferences.set(true, for: seededKey(.canvasVoice))
        setOwnRoute(AITaskModelRoute(provider: .openRouter, model: AIModelDefaults.canvasVoice), for: .canvasVoice)
    }

    /// The synced mark that Card Answer Check was given its starting model
    /// (`aiSeeded.task.<task>`), as Canvas Voice's.
    /// Gives Card Answer Check its starting model
    /// (`AIModelDefaults.cardAnswerCheck`) as a model of its own, once for the
    /// account, when it has none. Without it Check follows the chat's model, which can
    /// be a free one that stops answering, with no model of its own to
    /// change. It then shows, and is changed, in Settings › Background › Tasks.
    static func seedCardAnswerCheckRoute() {
        guard canHaveOwnRoute(.cardAnswerCheck),
              Preferences.value(seededKey(.cardAnswerCheck)) as? Bool != true,
              storedRoute(taskRouteKey(.cardAnswerCheck)) == nil else { return }
        Preferences.set(true, for: seededKey(.cardAnswerCheck))
        setOwnRoute(AITaskModelRoute(provider: .openRouter, model: AIModelDefaults.cardAnswerCheck), for: .cardAnswerCheck)
    }

    /// The synced mark that Go Deeper was given its starting model
    /// (`aiSeeded.task.<task>`), as Card Answer Check's.
    /// Gives Go Deeper its starting model (`AIModelDefaults.goDeeper`) as a
    /// model of its own, once for the account, when it has none: it followed
    /// the chat's model and could not be changed. Changed afterwards in
    /// Settings › Background › Tasks.
    static func seedGoDeeperRoute() {
        guard canHaveOwnRoute(.cardGoDeeper),
              Preferences.value(seededKey(.cardGoDeeper)) as? Bool != true,
              storedRoute(taskRouteKey(.cardGoDeeper)) == nil else { return }
        Preferences.set(true, for: seededKey(.cardGoDeeper))
        setOwnRoute(AITaskModelRoute(provider: .openRouter, model: AIModelDefaults.goDeeper), for: .cardGoDeeper)
    }

    // MARK: - Docs Model

    /// The model a Doc's Edit with AI runs on, when the learner gave Docs one
    /// of their own; nil while Docs follow the Default Model (product owner,
    /// 2026-09-29: "for rewrites; let me choose a model"). Synced like the
    /// Default Model. Never the chat on screen's own pick: a model tried in
    /// one chat is not a choice about docs.
    static var docsRoute: AITaskModelRoute? {
        guard let route = storedRoute(Prefs.Models.docsRoute),
              let provider = AIProvider(rawValue: route.provider) else { return nil }
        return AITaskModelRoute(provider: provider, model: route.model)
    }

    /// What a Doc's Edit with AI runs on: Docs' own model, else the Default Model.
    static var displayedDocsRoute: AITaskModelRoute {
        if let docsRoute { return docsRoute }
        let provider = aiProvider
        return AITaskModelRoute(provider: provider, model: model(for: provider))
    }

    /// Gives Docs a model of their own, or with nil sends them back to the
    /// Default Model.
    static func setDocsRoute(_ route: AITaskModelRoute?) {
        guard let route else {
            Preferences.reset(Prefs.Models.docsRoute)
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
            return
        }
        let trimmed = route.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveRoute(
            AIModelRoutePreference(provider: route.provider.rawValue, model: trimmed),
            to: Prefs.Models.docsRoute
        )
    }

    /// The config for a Doc's Edit with AI, through the same checks as
    /// `resolveConfig(for: .chat)`, on `displayedDocsRoute`. The effort is the
    /// one last chosen in a chat when the model offers it, as a new chat
    /// starts on; Docs have no speed of their own. A stored Docs model that
    /// cannot be read fails closed instead of quietly running the Default Model.
    static func resolveDocsConfig() -> AITaskConfig? {
        guard ManagedAI.isSignedIn else { return nil }
        guard !storedRouteIsInvalid(Prefs.Models.docsRoute) else { return nil }
        if docsRoute == nil, modelRouteConfigurationIsInvalid(for: .chat) { return nil }
        guard !AICreditEntitlement.isOutOfCredits else { return nil }
        let route = displayedDocsRoute
        let effort = chosenChatEffort.flatMap { chosen in
            AIRequestOptionSupport.supportedEfforts(provider: route.provider, model: route.model)
                .contains(chosen) ? chosen : nil
        }
        return textConfig(
            provider: route.provider,
            model: route.model,
            requiresVision: false,
            effort: effort,
            requestedSpeed: nil,
            taskLabel: "doc_edit"
        )
    }

    /// The model of the chat on screen, held in memory for that chat only.
    /// Nothing else takes a model of its own: every background task runs on
    /// Background's Text-only or Multimodal model (`backgroundRoute(for:)`).
    static func setTaskRoute(
        provider: AIProvider,
        model: String,
        effort: AIEffort? = nil,
        speed: AISpeed? = nil,
        for task: AITask
    ) {
        guard isChat(task) else { return }
        chatModelLock.lock()
        chatSessionProvider = provider
        chatSessionModel = model
        chatSessionEffort = effort
        chatSessionSpeed = speed
        chatModelLock.unlock()
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// Provider used by background tasks (everything except Chat). Nil means
    /// `defaultBackgroundTaskRoute`.
    static var backgroundTaskProvider: AIProvider? {
        get {
            if let route = storedRoute(Prefs.Models.backgroundRoute) {
                return AIProvider(rawValue: route.provider)
            }
            guard let raw = Preferences.value(Prefs.Models.backgroundProvider) else { return nil }
            return AIProvider.allCases.first { $0.rawValue == raw }
        }
        set {
            Preferences.set(newValue?.rawValue, for: Prefs.Models.backgroundProvider)
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    /// Model used by background tasks on the currently selected background provider,
    /// or nil to use that provider's default model.
    static var backgroundTaskModel: String? {
        get { backgroundTaskModel(for: backgroundTaskProvider ?? defaultBackgroundTaskRoute.provider) }
        set { setBackgroundTaskModel(newValue, for: backgroundTaskProvider ?? defaultBackgroundTaskRoute.provider) }
    }

    /// Background › Text: the persisted selection or the explicit shipped
    /// default.
    static var displayedBackgroundTaskRoute: AITaskModelRoute {
        guard let provider = backgroundTaskProvider else {
            return defaultBackgroundTaskRoute
        }
        return AITaskModelRoute(
            provider: provider,
            model: backgroundTaskModel(for: provider) ?? model(for: provider)
        )
    }

    /// Background › Multimodal: the persisted vision route or the explicit
    /// shipped default.
    static var displayedBackgroundMultimodalTaskRoute: AITaskModelRoute {
        guard let route = storedRoute(Prefs.Models.backgroundMultimodalRoute),
              let provider = AIProvider(rawValue: route.provider) else {
            return defaultBackgroundMultimodalTaskRoute
        }
        return AITaskModelRoute(provider: provider, model: route.model)
    }

    static func displayedBackgroundTaskRoute(for task: AITask) -> AITaskModelRoute {
        task.usesMultimodalBackgroundModelDefault
            ? displayedBackgroundMultimodalTaskRoute
            : displayedBackgroundTaskRoute
    }

    /// The model a background task runs on: its own (`ownRoute(for:)`), else
    /// Background's Text-only or Multimodal model, except that a meeting task
    /// does not follow that onto a free one (`MeetingModels`). A meeting task
    /// with nowhere paid to go shows Background's here, but
    /// `isWaitingForPaidModel` is true and no request is built for it.
    static func backgroundRoute(for task: AITask) -> AITaskModelRoute {
        if let own = ownRoute(for: task) { return own }
        let background = displayedBackgroundTaskRoute(for: task)
        return meetingRoute(for: task, background: background) ?? background
    }

    /// A meeting task that stays off free models, whose Background model is
    /// free and which has no paid backup to run on: it waits for the learner
    /// to choose a paid model, here or in Setup.
    static func isWaitingForPaidModel(_ task: AITask) -> Bool {
        guard ownRoute(for: task) == nil else { return false }
        return meetingRoute(for: task, background: displayedBackgroundTaskRoute(for: task)) == nil
    }

    private static func meetingRoute(for task: AITask, background: AITaskModelRoute) -> AITaskModelRoute? {
        MeetingModels.route(
            for: task,
            background: background,
            staysOffFree: MeetingModels.staysOffFree(task),
            paid: { MeetingModels.paidRoute(multimodal: task.usesMultimodalBackgroundModelDefault) }
        )
    }

    // The pick is stored per provider. A single shared slot meant switching
    // providers had to clear it, so leaving a provider and coming back read as
    // "never picked" and silently reverted to that provider's chat default.
    private static func backgroundTaskModelKey(for provider: AIProvider) -> AccountKey<Any?> {
        Prefs.Families.aiBackground.key("model.\(provider.rawValue)")
    }

    /// The background-task model picked for a specific provider, or nil when that
    /// provider has never been given one.
    static func backgroundTaskModel(for provider: AIProvider) -> String? {
        if let route = storedRoute(Prefs.Models.backgroundRoute),
           route.provider == provider.rawValue {
            return route.model
        }
        return Preferences.value(backgroundTaskModelKey(for: provider)) as? String
    }

    static func setBackgroundTaskModel(_ model: String?, for provider: AIProvider) {
        let key = backgroundTaskModelKey(for: provider)
        if let model, !model.isEmpty { Preferences.set(model, for: key) }
        else { Preferences.reset(key) }
        Preferences.reset(Prefs.Models.retiredBackgroundModel)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The provider a task runs on when the chat has no model of its own.
    /// Chat, text-only background work, and multimodal background work each
    /// follow their corresponding Settings selection.
    static func fallbackProvider(for task: AITask) -> AIProvider {
        guard task.usesBackgroundModelDefault else { return aiProvider }
        return backgroundRoute(for: task).provider
    }

    /// The provider a task will actually use: the chat's own pick, then the task's fallback.
    static func resolvedProvider(for task: AITask) -> AIProvider {
        taskProvider(task) ?? fallbackProvider(for: task)
    }

    // MARK: - Per-Task Model Configuration

    // The Chat model pick (`.chat`) is held in memory only, never persisted:
    // a model chosen from the chat bar belongs to the current chat, and every new
    // chat starts back on the Default Model from Settings. Persisting it created a
    // hidden override that contradicted the Settings pane with no way to see why.
    private static let chatModelLock = AppLock()

    private static var chatSessionProvider: AIProvider?

    private static var chatSessionModel: String?

    private static var chatSessionEffort: AIEffort?

    private static var chatSessionSpeed: AISpeed?

    /// The in-memory override only exists when the complete route is still
    /// enabled. A saved chat can restore a historical model identity for
    /// display, but disabling or removing that model makes the current chat
    /// follow the Settings default immediately.
    private static func enabledChatSessionRoute() -> (
        provider: AIProvider,
        model: String,
        effort: AIEffort?,
        speed: AISpeed?
    )? {
        chatModelLock.lock()
        let route = (
            provider: chatSessionProvider,
            model: chatSessionModel,
            effort: chatSessionEffort,
            speed: chatSessionSpeed
        )
        chatModelLock.unlock()
        guard let provider = route.provider,
              let model = route.model,
              AIProvider.activeChatProviders.contains(provider),
              AIModelCatalog.isEnabledChatSelection(provider: provider, modelID: model) else {
            return nil
        }
        return (provider, model, route.effort, route.speed)
    }

    /// Return Chat to the Settings default without touching persisted
    /// preferences. Used whenever the UI leaves one chat for a fresh one.
    static func resetChatSessionSelection() {
        chatModelLock.lock()
        chatSessionProvider = nil
        chatSessionModel = nil
        chatSessionEffort = nil
        chatSessionSpeed = nil
        chatModelLock.unlock()
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    static func resetChatSessionSelectionIfMatching(provider: AIProvider, model: String) {
        chatModelLock.lock()
        let matches = chatSessionProvider == provider && chatSessionModel == model
        if matches {
            chatSessionProvider = nil
            chatSessionModel = nil
            chatSessionEffort = nil
            chatSessionSpeed = nil
        }
        chatModelLock.unlock()
        if matches {
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
    }

    // The four parts of the chat's own pick. Only the chat has one: the
    // tasks that follow the chat's route read it, and every other task runs
    // on Background's model (product owner, 2026-09-28: "I don't think anybody will
    // actually want to set the model for all these specific tasks"), so for
    // them each read is nil and each write is refused.

    /// The chat's own provider, or nil to use the Default Model.
    static func taskProvider(_ task: AITask) -> AIProvider? {
        if task.followsChatRoute { return taskProvider(.chat) }
        guard task == .chat else { return nil }
        return enabledChatSessionRoute()?.provider
    }

    /// Set or clear the chat's own provider.
    static func setTaskProvider(_ provider: AIProvider?, for task: AITask) {
        guard isChat(task) else { return }
        chatModelLock.lock()
        chatSessionProvider = provider
        chatModelLock.unlock()
        // Drop any override persisted before chat picks became session-scoped.
        Preferences.reset(Prefs.Models.chatTaskProvider)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The chat's own model, or nil to use the Default Model.
    static func taskModel(_ task: AITask) -> String? {
        if task.followsChatRoute { return taskModel(.chat) }
        guard task == .chat else { return nil }
        return enabledChatSessionRoute()?.model
    }

    /// Set or clear the chat's own model.
    static func setTaskModel(_ model: String?, for task: AITask) {
        guard isChat(task) else { return }
        chatModelLock.lock()
        chatSessionModel = (model?.isEmpty == false) ? model : nil
        chatModelLock.unlock()
        // Drop any override persisted before chat picks became session-scoped.
        Preferences.reset(Prefs.Models.chatTaskModel)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The chat's own effort, else the effort last chosen from the chat bar
    /// when the chat's model offers it, else nil for the model's default.
    ///
    /// Unlike its model, a chat's effort does not reset with each new chat.
    /// Starting every new chat on the model's default effort would have the product owner
    /// set Low again in each one (product owner, 2026-09-28: "whenever I set the level of
    /// reasoning, I want that to persist"). A chat whose model does not offer
    /// the chosen effort runs on that model's default; the choice itself is
    /// kept for the next model that does.
    static func taskEffort(_ task: AITask) -> AIEffort? {
        if task.followsChatRoute { return taskEffort(.chat) }
        guard task == .chat else { return nil }
        if let own = enabledChatSessionRoute()?.effort { return own }
        guard let chosen = chosenChatEffort else { return nil }
        let selection = resolvedSelection(for: .chat)
        let offered = AIRequestOptionSupport.supportedEfforts(provider: selection.provider, model: selection.model)
        return offered.contains(chosen) ? chosen : nil
    }

    /// The effort last picked from a chat's effort control. It follows the
    /// account like the Default Model it sits beside. Only a learner's pick
    /// writes it — never a restored chat's effort, nor one dropped because a
    /// new model does not offer it.
    static var chosenChatEffort: AIEffort? {
        get {
            Preferences.value(Prefs.Models.defaultChatEffort)
                .flatMap(AIEffort.init(rawValue:))
        }
        set {
            Preferences.set(newValue?.rawValue, for: Prefs.Models.defaultChatEffort)
        }
    }

    /// Chat effort and speed ride on the in-memory session route, and that
    /// route only counts once it names a provider *and* a model — which, until
    /// this ran, happened only when a model had been picked from the chat bar.
    /// Tuning a chat still following the Settings default therefore had nowhere
    /// to live: `enabledChatSessionRoute()` stayed nil, the read came back
    /// empty, and the composer's effort chip snapped back to Medium the moment
    /// its storage sync ran. Pinning the resolved default model
    /// makes the pick the same session-scoped route a model pick makes, so a
    /// new chat still returns to the Settings default with it.
    private static func pinChatSessionRouteToResolvedModelIfMissing() {
        // Resolve before taking the lock: `resolvedSelection` reads the session
        // route itself, and the lock is not reentrant.
        let resolved = resolvedSelection(for: .chat)
        chatModelLock.lock()
        defer { chatModelLock.unlock() }
        guard chatSessionProvider == nil || chatSessionModel == nil else { return }
        chatSessionProvider = resolved.provider
        chatSessionModel = resolved.model
    }

    /// Set or clear the chat's own effort, session-scoped like its model.
    static func setTaskEffort(_ effort: AIEffort?, for task: AITask) {
        guard isChat(task) else { return }
        if effort != nil {
            pinChatSessionRouteToResolvedModelIfMissing()
        }
        chatModelLock.lock()
        chatSessionEffort = effort
        chatModelLock.unlock()
        Preferences.reset(Prefs.Models.chatTaskEffort)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    /// The chat's own speed, else the speed last chosen from the chat bar
    /// when the chat's model offers it, else nil for standard speed.
    ///
    /// Like its effort, a chat's speed does not reset with each new chat: the
    /// product owner set Fast and found every next chat back on Standard
    /// (product owner, 2026-11-10: "like next chat, it's already gone again"). A model whose
    /// hosts OpenRouter has listed without that tier runs at standard speed;
    /// the choice itself is kept for the next model that has it.
    static func taskSpeed(_ task: AITask) -> AISpeed? {
        if task.followsChatRoute { return taskSpeed(.chat) }
        guard task == .chat else { return nil }
        if let own = enabledChatSessionRoute()?.speed { return own }
        guard let chosen = chosenChatSpeed else { return nil }
        let selection = resolvedSelection(for: .chat)
        guard let slug = AIRequestOptionSupport.openRouterSpeedSlug(
            provider: selection.provider,
            model: selection.model,
            routingMode: textRoutingMode
        ) else { return nil }
        // A cold cache is not "unsupported", as in the picker: the request
        // path and the picker's own tier load settle it once OpenRouter answers.
        if let tiers = OpenRouterEndpointTierCatalog.cachedTiers(slug: slug),
           OpenRouterSpeedTier.tier(for: chosen, slug: slug, in: tiers) == nil {
            return nil
        }
        return chosen
    }

    /// The speed last picked from a chat's speed control; nil is Standard.
    /// It follows the account like the effort beside it. Only a learner's
    /// pick writes it — never a restored chat's speed, nor one dropped
    /// because a new model has no such tier.
    static var chosenChatSpeed: AISpeed? {
        get {
            Preferences.value(Prefs.Models.defaultChatSpeed)
                .flatMap(AISpeed.init(rawValue:))
                .flatMap { $0 == .standard ? nil : $0 }
        }
        set {
            let stored = newValue == .standard ? nil : newValue
            Preferences.set(stored?.rawValue, for: Prefs.Models.defaultChatSpeed)
        }
    }

    /// Set or clear the chat's own speed, session-scoped like its model.
    static func setTaskSpeed(_ speed: AISpeed?, for task: AITask) {
        guard isChat(task) else { return }
        if let speed, speed != .standard {
            pinChatSessionRouteToResolvedModelIfMissing()
        }
        chatModelLock.lock()
        chatSessionSpeed = speed
        chatModelLock.unlock()
        Preferences.reset(Prefs.Models.chatTaskSpeed)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    private static func isChat(_ task: AITask) -> Bool {
        guard task == .chat else {
            assertionFailure("\(task.rawValue) has no model of its own; it runs on Background's")
            return false
        }
        return true
    }

    /// Explicit permission for automatic LLM work to consume the learner's AI
    /// credits. This syncs with the account through the `aiBackground.` prefix.
    static var hasConsentedToBackgroundAIUsage: Bool {
        get { Preferences.value(Prefs.Models.backgroundUsageConsented) }
        set { Preferences.set(newValue, for: Prefs.Models.backgroundUsageConsented) }
    }

    static let backgroundAIUsageConsentKey = Prefs.Models.backgroundUsageConsented.name

    /// Remove credentials from the retired client-side provider integrations
    /// and all former direct-Meta trial flags.
    /// This fixed-size upgrade cleanup runs once per installation; no request
    /// path can read these values after the update.
    static func purgeRetiredProviderData() {
        guard Preferences.value(Prefs.Lifecycle.retiredProviderDataPurged) != true else { return }

        for key: Key in [
            .anthropicAPIKey, .openAIAPIKey, .groqAPIKey, .cerebrasAPIKey,
            .geminiAPIKey, .xaiAPIKey, .retiredMetaTrialAPIKey,
            .fireworksAPIKey, .nvidiaAPIKey, .openRouterAPIKey,
            .elevenLabsAPIKey, .togetherAIAPIKey, .wisprAPIKey,
            .assemblyAIAPIKey, .cartesiaAPIKey,
        ] {
            delete(key)
        }
        for member in [
            "metaFreeTrial.active",
            "metaFreeTrial.startedAt",
            "metaFreeTrial.exhausted",
            "metaFreeTrial.limitUSD",
        ] {
            Preferences.reset(Prefs.Families.aiBackground.key(member))
        }
        Preferences.set(true, for: Prefs.Lifecycle.retiredProviderDataPurged)
    }

    /// Chat and reviews are initiated directly by the learner. On the
    /// managed rail, every task that follows the Background model is blocked
    /// until onboarding has captured explicit credit consent.
    static func isAIUsageAllowed(for task: AITask) -> Bool {
        return !task.usesBackgroundModelDefault || hasConsentedToBackgroundAIUsage
    }

    /// The three reasons a signed-in learner's background work cannot run.
    /// Named so the surfaces that must route each one to its own fix — the
    /// paper row's recovery button most visibly — match on a constant rather
    /// than on a re-typed sentence.
    static let emptyBalanceMessage = "Add your OpenRouter key in AI Usage (the sidebar's OpenRouter button) to run this."

    static let invalidModelRouteMessage =
        "The selected AI model route is invalid. Choose the model again in Settings."

    static let backgroundAIConsentMessage =
        "Background AI usage has not been accepted. Open Getting Started to review and agree to it."

    /// Why `resolveConfig` came back nil when a learner asks for background work
    /// directly and deserves better than "configure an API key". Nil when
    /// missing consent is not the reason.
    static func backgroundAIUnavailableMessage(for task: AITask) -> String? {
        if AICreditEntitlement.isOutOfCredits {
            return emptyBalanceMessage
        }
        if modelRouteConfigurationIsInvalid(for: task) {
            return invalidModelRouteMessage
        }
        guard task.usesBackgroundModelDefault, !hasConsentedToBackgroundAIUsage else { return nil }
        return backgroundAIConsentMessage
    }

    /// Get the custom prompt override for a specific AI task, or nil to use the built-in default.
    static func taskPrompt(_ task: AITask) -> String? {
        Preferences.value(Prefs.Families.aiTask.key("\(task.rawValue).prompt")) as? String
    }

    /// The provider and model a task will actually use: a background task's
    /// is its own or Background's (`backgroundRoute(for:)`), the chat's its own pick or
    /// the Default Model. Unlike `resolveConfig`, this answers regardless of
    /// session state, so Settings can show what each task resolves to before
    /// sign-in.
    static func resolvedSelection(for task: AITask) -> (provider: AIProvider, model: String) {
        if task.usesBackgroundModelDefault {
            let route = backgroundRoute(for: task)
            return (route.provider, route.model)
        }
        let provider = taskProvider(task) ?? fallbackProvider(for: task)
        return (provider, taskModel(task) ?? model(for: provider))
    }

    /// Resolve the full config (provider + credential + model) for an AI task.
    static func resolveConfig(
        for task: AITask,
        explicitlyAuthorizedBackgroundUsage: Bool = false
    ) -> AITaskConfig? {
        guard ManagedAI.isSignedIn else { return nil }
        // Corrupt, half-synced, or retired provider/model preferences are a
        // configuration failure.
        guard !modelRouteConfigurationIsInvalid(for: task) else {
            return nil
        }
        // Background work can run without a click, so signing in is not consent
        // to spend credits on it. The onboarding acknowledgement is a separate,
        // synced prerequisite checked before any request can be built.
        guard explicitlyAuthorizedBackgroundUsage || isAIUsageAllowed(for: task) else { return nil }
        // The managed rail cannot pay. Refusing at the one place a config is built stops
        // every automatic path — classification, metadata, transcripts, review —
        // from firing requests the proxy will only refuse, and leaves that work
        // pending instead of failed. Reading what is already in the library needs
        // no config and is untouched by this.
        guard !AICreditEntitlement.isOutOfCredits else { return nil }
        // A meeting with no paid model to run on waits, like one with no key.
        guard !isWaitingForPaidModel(task) else { return nil }
        let (provider, resolvedModel) = resolvedSelection(for: task)
        return textConfig(
            provider: provider,
            model: resolvedModel,
            requiresVision: task.requiresVision,
            effort: taskEffort(task),
            requestedSpeed: taskSpeed(task),
            taskLabel: task.rawValue
        )
    }

    /// `resolveConfig` once a route is chosen: the checks every text route
    /// passes before it may be sent, shared with `resolveDocsConfig`.
    private static func textConfig(
        provider: AIProvider,
        model resolvedModel: String,
        requiresVision: Bool,
        effort: AIEffort?,
        requestedSpeed: AISpeed?,
        taskLabel: String
    ) -> AITaskConfig? {
        if AIModelDefaults.isRetiredChatModel(provider: provider, model: resolvedModel) {
            return nil
        }
        // A selected text-only model for a vision task is a configuration error,
        // not permission to bill a different model. Background › Multimodal
        // takes a model that reads images; until one is chosen the task fails
        // closed.
        if requiresVision,
           modelSupportsVision(provider: provider, model: resolvedModel) != true {
            return nil
        }
        // Effort and speed are part of the selected route. If the current model
        // cannot honor either value, the route is invalid; silently omitting it
        // would execute a materially different request than Settings promises.
        if let effort {
            guard AIRequestOptionSupport.supportedEfforts(
                provider: provider,
                model: resolvedModel
            ).contains(effort) else { return nil }
        }
        // A speed rides along whenever the route can carry one. Whether the
        // model's fast endpoint is known is decided at dispatch, after the
        // endpoint cache is primed; failing the whole config on a cold cache
        // here would take the chat down for a stored preference.
        let speed = requestedSpeed.flatMap { speed -> AISpeed? in
            guard speed != .standard else { return nil }
            return AIRequestOptionSupport.routeCanCarrySpeed(provider: provider, model: resolvedModel)
                ? speed : nil
        }
        let routed = routedTextSelection(provider: provider, model: resolvedModel, speed: speed)
        guard let apiKey = apiKey(for: routed.provider) else { return nil }
        var config = AITaskConfig(provider: routed.provider, apiKey: apiKey, model: routed.model)
        // Tag the ledger with the task this config was resolved for, so the AI
        // Usage pane can say which feature each call served.
        config.taskLabel = taskLabel
        config.effort = effort
        config.speed = speed
        return config
    }

    /// Whether a model accepts image input, as far as can be known without a
    /// network call. `nil` means unknown — callers must warn only on a definite
    /// `false`, never on `nil`, so a capable new model is never wrongly flagged.
    ///
    /// The closed labs' currently-offered models are all multimodal, so those
    /// providers answer `true`. OpenRouter is mixed: the answer comes from the
    /// capability captured when the user added the model, then from the directory
    /// snapshot cached alongside prices, and is `nil` until a fetch has run.
    static func modelSupportsVision(provider: AIProvider, model: String) -> Bool? {
        switch provider {
        case .anthropic, .openai, .gemini, .xai, .meta:
            return true
        case .openRouter:
            // The Free Models Router only picks a free model that can do the
            // job, so a request with images lands on one that reads them.
            if model == AIModelDefaults.visionOpenRouter
                || model == AIModelDefaults.openRouterFreeRouter {
                return true
            }
            // Pinned capabilities are available at build time and must not
            // depend on a directory refresh before a vision route is filtered.
            if AIModelDefaults.preferredOpenRouter.contains(model) {
                return model == "meta/\(AIModelDefaults.latestMuseSpark)"
                    || model == "meta-llama/llama-4-maverick"
            }
            if let known = AIModelCatalog.customOpenRouterModel(id: model)?.supportsVision {
                return known
            }
            return AIModelCatalog.openRouterModelSupportsVision(model)
        default:
            return nil
        }
    }
}
