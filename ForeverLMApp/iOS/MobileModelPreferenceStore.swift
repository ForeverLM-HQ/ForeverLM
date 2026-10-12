import CloudKit
import Foundation

/// Resolves the account's model settings for iPhone and CarPlay.
///
/// Every key is read from and written to the replica as what §10 makes of it
/// (`MobilePreferenceRoute`): a `Setting`, or a field of the record a domain
/// prefix moved into. A cached local value is deliberately never used as an
/// offline inference fallback.
actor MobileModelPreferenceStore {
    static let shared = MobileModelPreferenceStore()

    private let recordWriter: @Sendable () async -> MobileRecordWriter?

    init(writer: @escaping @Sendable () async -> MobileRecordWriter? = { await MobileRecordWriter.current() }) {
        recordWriter = writer
    }

    private func requiredWriter() async throws -> MobileRecordWriter {
        guard let writer = await recordWriter() else { throw MobileRecordWriterError.zoneNotHeld }
        return writer
    }

    /// The route for `task`, after refreshing the account's settings. A transient
    /// iCloud failure comes back naming what did not start ("Listen could not
    /// start because…") rather than "this setting", so the banner says what to
    /// retry; the read itself has already been retried once by then.
    func resolve(_ task: AITask) async throws -> ResolvedAITextRoute {
        try await resolve(task, overriding: nil)
    }

    /// The route for `task`, on `preference` instead of the account's default
    /// chat model when one is given: a chat's own pick from its model chip
    /// (`offeredChatModels`). Free mode, the data policy and the model's host
    /// region still apply; only the chat tasks take a pick.
    func resolve(_ task: AITask, overriding preference: AIModelRoutePreference?) async throws -> ResolvedAITextRoute {
        do {
            return try await confinedToRegion(resolveModelRoute(task, overriding: preference))
        } catch let error as MobileModelRouteError {
            if case .iCloudUnavailable = error {
                throw MobileModelRouteError.iCloudUnavailable(activity: task.mobileActivityName)
            }
            throw error
        }
    }

    /// The models a chat's model chip offers: the account's default chat model
    /// first, then the models the learner offers in the Mac's chat picker
    /// (`MobileOfferedChatModels`), as the Mac's catalog offers them
    /// (`AIModelCatalog.isOffered`): only free ones while Free mode is on, and
    /// none whose host trains on prompts while the Data & Privacy switch is
    /// on. The default is returned on its own too.
    func offeredChatModels() async throws -> (choices: [MobileChatModelChoice], defaultChoice: MobileChatModelChoice?) {
        let freeMode = try await refreshFreeMode()
        let hidesTrainingModels = try await bool(forKey: AIDataPolicy.denyDataCollectionKey) ?? false
        let defaultPreference = try await chatRoutePreference()
        let enabled = try await stringArray(forKey: MobileOfferedChatModels.enabledIDsKey)
        let custom = try await data(forKey: MobileOfferedChatModels.customModelsKey)
        let names = MobileOfferedChatModels.customNames(from: custom)
        let defaultID = "\(defaultPreference.provider)|\(defaultPreference.model)"
        let choices = MobileOfferedChatModels.choices(
            enabledIDs: enabled,
            customNames: names,
            defaultPreference: defaultPreference,
            freeModeOn: freeMode
        ).filter { choice in
            // The default is what a chat runs on anyway, so it stays listed.
            guard hidesTrainingModels, choice.id != defaultID else { return true }
            let slug = (try? openRouterModelID(
                provider: choice.preference.provider,
                model: choice.preference.model,
                speed: choice.preference.speed
            )) ?? choice.preference.model
            return !AIDataPolicy.trainsOnInputs(modelSlug: slug)
        }
        return (choices, choices.first { $0.id == defaultID })
    }

    /// The account's chat model as the phone runs it: the atomic route row,
    /// else the legacy provider and model rows, else the phone's own default
    /// (`AIModelDefaults.mobileDefaultChatModel`).
    private func chatRoutePreference() async throws -> AIModelRoutePreference {
        if let atomic = try await routePreference(forKey: AIModelPreferenceKey.defaultChatRoute) {
            return atomic
        }
        if let legacy = try await legacyChatRoute() {
            return legacy
        }
        return AIModelRoutePreference(
            provider: AIModelDefaults.mobileDefaultChatProvider,
            model: AIModelDefaults.mobileDefaultChatModel
        )
    }

    /// The Mac keeps a model to one region's hosts per slot of Settings ›
    /// Chat and per model (`OpenRouterHostPreference`), and so does every
    /// request the phone sends on it: the route carries the region's
    /// endpoints, read from OpenRouter now, and a region whose list cannot be
    /// read stops the request. The phone follows no other host choice.
    private func confinedToRegion(_ route: ResolvedAITextRoute) async throws -> ResolvedAITextRoute {
        let ownSlot: String
        if route.task == .chat {
            ownSlot = "chat"
        } else {
            ownSlot = route.task.usesMultimodalBackgroundModelDefault ? "background.images" : "background.text"
        }
        // Every slot's row for the model at once: one round trip, not three.
        let rows = try await withThrowingTaskGroup(of: (String, OpenRouterHostPreference?).self) { group in
            for slot in OpenRouterHostPreference.sharedSlots {
                let key = OpenRouterHostPreference.key(slot: slot, slug: route.model)
                group.addTask { (slot, try await self.string(forKey: key).flatMap(OpenRouterHostPreference.decoded)) }
            }
            var rows: [String: OpenRouterHostPreference] = [:]
            for try await (slot, row) in group {
                if let row { rows[slot] = row }
            }
            return rows
        }
        guard let region = OpenRouterHostPreference.region(ownSlots: [ownSlot], row: { rows[$0] }) else { return route }
        let tags = try await OpenRouterRegionalEndpoints.shared.endpoints(for: route.model, region: region).map(\.tag)
        guard !tags.isEmpty else {
            throw OpenRouterRegionalEndpoints.Failure.noHost(model: route.model, region: region)
        }
        return route.confined(to: tags)
    }

    private func resolveModelRoute(_ task: AITask, overriding override: AIModelRoutePreference? = nil) async throws -> ResolvedAITextRoute {
        guard ManagedAI.isSignedIn else { throw MobileModelRouteError.notSignedIn }
        let routingMode = try await textRoutingMode()
        // The account's data-policy switch travels with the route so the
        // synchronous request builders need no store of their own.
        let deniesDataCollection = try await bool(forKey: AIDataPolicy.denyDataCollectionKey) ?? false
        let freeMode = try await refreshFreeMode()

        if task == .chat {
            let preference: AIModelRoutePreference
            if let override, override.isValid {
                preference = override
            } else {
                preference = try await chatRoutePreference()
            }
            return try resolved(preference, task: task, routingMode: routingMode, deniesDataCollection: deniesDataCollection, freeMode: freeMode)
        }

        // A task the learner gave a model of its own runs on it (2026-10-07,
        // as the Mac's `KeychainService.ownRoute(for:)` reads it): unusable
        // while Free mode is on and it is paid, when Background, which Free
        // mode moved, answers instead. Every other task runs on the account's
        // Background model.
        if let descriptor = AITaskSettingsCatalog.descriptor(forRawID: task.rawValue),
           descriptor.showInAdvancedSettings, descriptor.usesBackgroundModelDefault,
           let own = try await routePreference(forKey: AIModelPreferenceKey.taskRoute(task)),
           !freeMode || (own.provider == "OpenRouter" && AIFreeMode.isFreeModelID(own.model)) {
            return try resolved(own, task: task, routingMode: routingMode, deniesDataCollection: deniesDataCollection, freeMode: freeMode)
        }
        let backgroundKey = task.usesMultimodalBackgroundModelDefault
            ? AIModelPreferenceKey.backgroundMultimodalRoute
            : AIModelPreferenceKey.backgroundRoute
        let background: AIModelRoutePreference
        if let atomic = try await routePreference(forKey: backgroundKey) {
            background = atomic
        } else if !task.usesMultimodalBackgroundModelDefault,
                  let legacy = try await legacyBackgroundRoute() {
            background = legacy
        } else if task.usesMultimodalBackgroundModelDefault {
            background = AIModelRoutePreference(
                provider: AIModelDefaults.mobileDefaultBackgroundMultimodalProvider,
                model: AIModelDefaults.mobileDefaultBackgroundMultimodalModel
            )
        } else {
            background = AIModelRoutePreference(
                provider: AIModelDefaults.mobileDefaultBackgroundProvider,
                model: AIModelDefaults.mobileDefaultBackgroundModel
            )
        }
        return try resolved(background, task: task, routingMode: routingMode, deniesDataCollection: deniesDataCollection, freeMode: freeMode)
    }

    private func textRoutingMode() async throws -> AITextRoutingMode {
        // Match macOS: the learner's own router key names the transport; else
        // the server names it, the shipped default stands in until it has, and
        // legacy synced choices cannot move text traffic.
        if let own = ManagedAI.ownKeyRouter { return own.routingMode }
        return ManagedAI.requiredTextRoutingMode ?? .shippedDefault
    }

    /// Exact account scalar lookup for a synced setting.
    /// A CloudKit error is propagated; a stale local value is never substituted.
    func string(forKey key: String) async throws -> String? {
        try await fetchPreference(key) as? String
    }

    func bool(forKey key: String) async throws -> Bool? {
        try await fetchPreference(key) as? Bool
    }

    /// The account's Free mode switch, read from its row and written to
    /// `AIFreeMode.enabledKey` in `UserDefaults`, which is where `AIFreeMode.isOn`
    /// and so every guard in `ManagedAI` reads it. The phone hydrates no synced
    /// preference, so this is the only way the row reaches it. Anything that
    /// is about to spend reads it first. A failed read throws and leaves the
    /// last answer in place. A stale "on" refuses paid requests and a stale
    /// "off" lets them through, so a caller that must not spend on a stale
    /// answer lets the error stop it.
    @discardableResult
    func refreshFreeMode() async throws -> Bool {
        let isOn = try await bool(forKey: AIFreeMode.enabledKey) ?? false
        UserDefaults.standard.set(isOn, forKey: AIFreeMode.enabledKey)
        return isOn
    }

    /// A whole number, as the Mac's `SyncedStorage<Int>` writes it. Plist
    /// integers come back as `NSNumber`, so a value the Mac stored as a Bool
    /// would read as 0 or 1 here; no key is shared between the two shapes.
    func int(forKey key: String) async throws -> Int? {
        (try await fetchPreference(key) as? NSNumber)?.intValue
    }

    func setInt(_ value: Int, forKey key: String) async throws {
        try await save(value, forKey: key)
    }

    func stringArray(forKey key: String) async throws -> [String]? {
        try await fetchPreference(key) as? [String]
    }

    /// A row the Mac stores as data (`chatModels.openRouterCustom`, a JSON blob).
    func data(forKey key: String) async throws -> Data? {
        try await fetchPreference(key) as? Data
    }

    func setBool(_ value: Bool, forKey key: String) async throws {
        try await save(value, forKey: key)
    }

    func setString(_ value: String, forKey key: String) async throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MobileModelRouteError.invalidPreference(key) }
        try await save(trimmed, forKey: key)
    }

    /// Stores an optional account string. An empty value deliberately clears
    /// settings such as an Automatic Audio rule while retaining one portable
    /// Preference record shape across native and web clients.
    func setOptionalString(_ value: String, forKey key: String) async throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try await save(trimmed, forKey: key)
    }

    func setStringArray(_ value: [String], forKey key: String) async throws {
        try await save(value, forKey: key)
    }

    /// Clears an account value everywhere: a cleared Setting (records are never deleted) or an emptied
    /// field, so per-source state such as a listening position is retired on every device.
    func removeValue(forKey key: String) async throws {
        try await requiredWriter().writePreference(key, nil)
    }

    /// One key's value, as what the key is in the replica (`MobileWrite.writePreference`).
    private func save(_ value: Any, forKey key: String) async throws {
        try await requiredWriter().writePreference(key, value)
    }

    private func routePreference(forKey key: String) async throws -> AIModelRoutePreference? {
        guard let value = try await fetchPreference(key) else { return nil }
        guard let data = value as? Data else {
            throw MobileModelRouteError.invalidPreference(key)
        }
        do {
            let route = try JSONDecoder().decode(AIModelRoutePreference.self, from: data)
            guard route.isValid else { throw MobileModelRouteError.invalidPreference(key) }
            return route
        } catch let error as MobileModelRouteError {
            throw error
        } catch {
            throw MobileModelRouteError.invalidPreference(key)
        }
    }

    private func legacyChatRoute() async throws -> AIModelRoutePreference? {
        guard let storedProvider = try await fetchPreference("ai_provider") as? String else { return nil }
        let provider = try legacyProviderName(storedProvider)
        let modelKey: String
        switch provider {
        case "Anthropic (Claude)": modelKey = "anthropic_model"
        case "OpenAI (GPT)": modelKey = "openai_model"
        case "Google (Gemini)": modelKey = "gemini_model"
        case "xAI (Grok)": modelKey = "xai_model"
        case "OpenRouter": modelKey = "openrouter_model"
        case "Meta (Muse Spark)": modelKey = "meta_model"
        default: throw MobileModelRouteError.unsupportedProvider(provider)
        }
        let model = try await fetchPreference(modelKey) as? String ?? defaultModel(for: provider)
        return AIModelRoutePreference(provider: provider, model: model)
    }

    private func legacyBackgroundRoute() async throws -> AIModelRoutePreference? {
        guard let provider = try await fetchPreference("aiBackground.provider") as? String else { return nil }
        let perProviderKey = "aiBackground.model.\(provider)"
        let model: String
        if let selected = try await fetchPreference(perProviderKey) as? String {
            model = selected
        } else if let legacy = try await fetchPreference("aiBackground.model") as? String {
            model = legacy
        } else {
            model = defaultModel(for: provider)
        }
        return AIModelRoutePreference(provider: provider, model: model)
    }

    private func resolved(
        _ preference: AIModelRoutePreference,
        task: AITask,
        routingMode: AITextRoutingMode,
        deniesDataCollection: Bool,
        freeMode: Bool
    ) throws -> ResolvedAITextRoute {
        let provider = preference.provider
        let rawModel = preference.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawModel.isEmpty else { throw MobileModelRouteError.invalidPreference(task.rawValue) }
        // The Mac points every setting at a free model when Free mode goes on,
        // so a paid route here is one it could not move (a phone default no
        // device has written). Say so before building a request; `rewrite`
        // would refuse it anyway.
        if freeMode, !(provider == "OpenRouter" && AIFreeMode.isFreeModelID(rawModel)) {
            throw AIFreeMode.Refusal.paidModel(rawModel)
        }
        guard requestOptionsAreSupported(
            provider: provider,
            model: rawModel,
            effort: preference.effort,
            speed: preference.speed
        ) else {
            throw MobileModelRouteError.invalidPreference(AIModelPreferenceKey.taskRoute(task))
        }
        let supportedProviders: Set<String> = [
            "Anthropic (Claude)", "OpenAI (GPT)", "Google (Gemini)",
            "xAI (Grok)", "Meta (Muse Spark)", "OpenRouter",
        ]
        guard supportedProviders.contains(provider) else {
            throw MobileModelRouteError.unsupportedProvider(provider)
        }

        return ResolvedAITextRoute(
            task: task,
            provider: "OpenRouter",
            model: try openRouterModelID(
                provider: provider,
                model: rawModel,
                speed: preference.speed
            ),
            effort: preference.effort,
            deniesDataCollection: deniesDataCollection
        )
    }

    /// Checks the options synced as part of an atomic route. An unsupported
    /// effort or speed is a route error; it is never dropped while the same
    /// model request proceeds. Effort levels are OpenRouter's per model, and
    /// the Mac offers only those and clears a pick the next model does not
    /// take; the phone reads no catalog, so it accepts any level the app can
    /// store and refuses anything else.
    private func requestOptionsAreSupported(
        provider: String,
        model: String,
        effort: String?,
        speed: String?
    ) -> Bool {
        let normalized = model.lowercased()
        if let effort {
            guard ["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) else { return false }
        }

        if let speed, speed != "standard" {
            guard speed == "fast",
                  provider == "Anthropic (Claude)",
                  normalized.hasPrefix("claude-opus-5")
                    || normalized.hasPrefix("claude-opus-4-7")
                    || normalized.hasPrefix("claude-opus-4-8") else { return false }
        }
        return true
    }

    /// The course quiz sittings kept under `keys` (`courseQuiz.score.<quizID>`
    /// and, for a practice quiz scored before quizzes were stored,
    /// `lectureQuiz.score.<videoID>`), in one CloudKit round trip. A key with
    /// no row is absent from the answer; a row that is not a sitting is too.
    func lectureQuizScores(forKeys keys: [String]) async throws -> [String: LectureQuizScore] {
        try await preferenceValues(forKeys: keys).compactMapValues(LectureQuizScore.init(preferenceValue:))
    }

    /// The String rows under `keys`, read as `preferenceValues(forKeys:)`
    /// reads them: a few hundred to a round trip, and no round trip for no
    /// keys. A key with no row, or whose row is not a String, is absent.
    func strings(forKeys keys: [String]) async throws -> [String: String] {
        try await preferenceValues(forKeys: keys).compactMapValues { $0 as? String }
    }

    /// The `[String]` rows under `keys`, read as `strings(forKeys:)` reads
    /// them. A key with no row, or whose row is not a String array, is absent.
    func stringArrays(forKeys keys: [String]) async throws -> [String: [String]] {
        try await preferenceValues(forKeys: keys).compactMapValues { $0 as? [String] }
    }

    /// The values under `keys`. A key with no value is absent from the answer.
    private func preferenceValues(forKeys keys: [String]) async throws -> [String: Any] {
        try await requiredWriter().preferenceValues(keys)
    }


    /// Keeps a finished sitting as the synced row the Mac reads the same way
    /// (`StudioViewModel.recordCourseQuizScore`).
    func setLectureQuizScore(_ score: LectureQuizScore, forKey key: String) async throws {
        try await save(score.preferenceValue, forKey: key)
    }

    private func fetchPreference(_ key: String) async throws -> Any? {
        try await requiredWriter().preferenceValue(key)
    }

    private func legacyProviderName(_ raw: String) throws -> String {
        switch raw {
        case "anthropic": return "Anthropic (Claude)"
        case "openai": return "OpenAI (GPT)"
        case "gemini": return "Google (Gemini)"
        case "xai": return "xAI (Grok)"
        case "openrouter": return "OpenRouter"
        case "meta": return "Meta (Muse Spark)"
        default: throw MobileModelRouteError.unsupportedProvider(raw)
        }
    }

    private func defaultModel(for provider: String) -> String {
        switch provider {
        case "Anthropic (Claude)": return AIModelDefaults.mobileDefaultChatModel
        case "OpenAI (GPT)": return "gpt-5.6"
        case "Google (Gemini)": return "gemini-3.5-flash"
        case "xAI (Grok)": return "grok-4.3"
        case "OpenRouter": return AIModelDefaults.mobileDefaultBackgroundModel
        case "Meta (Muse Spark)": return "muse-spark-1.2"
        default: return ""
        }
    }

    /// The vendor-qualified slug OpenRouter addresses a model by.
    private func openRouterModelID(provider: String, model: String, speed: String?) throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") { return trimmed }

        let base: String
        switch provider {
        case "Anthropic (Claude)":
            base = "anthropic/\(canonicalAnthropicModel(trimmed))"
        case "OpenAI (GPT)":
            base = "openai/\(trimmed == "gpt-5.6" ? "gpt-5.6-sol" : trimmed)"
        case "Google (Gemini)":
            base = "google/\(trimmed)"
        case "xAI (Grok)":
            base = "x-ai/\(trimmed)"
        case "Meta (Muse Spark)":
            base = "meta/\(trimmed)"
        case "OpenRouter":
            return trimmed
        default:
            throw MobileModelRouteError.unsupportedProvider(provider)
        }

        if provider == "Anthropic (Claude)", speed == "fast", !base.hasSuffix("-fast") {
            return base + "-fast"
        }
        return base
    }

    private func canonicalAnthropicModel(_ model: String) -> String {
        let parts = model.split(separator: "-")
        guard parts.count >= 3,
              let minor = parts.last, minor.allSatisfy(\.isNumber),
              let major = parts.dropLast().last, major.allSatisfy(\.isNumber)
        else { return model }
        return parts.dropLast(2).joined(separator: "-") + "-\(major).\(minor)"
    }

}

enum MobileModelRouteError: LocalizedError {
    case notSignedIn
    /// `activity` is what the phone was about to do for the learner ("Listen",
    /// "The chat"), when the caller knows; nil reads as a settings check.
    case iCloudUnavailable(activity: String? = nil)
    case cannotVerifySettings(String)
    case invalidPreference(String)
    case unsupportedProvider(String)

    /// iCloud being briefly unreachable is not a settings problem, and saying so
    /// sent people looking in the wrong place. A stale device token produced
    /// "Could not verify the current AI model settings … Account temporarily
    /// unavailable due to bad or missing auth token", which reads as though the
    /// account or the model configuration were broken when neither is.
    ///
    /// The busy and offline codes belong in the same bucket and were missed the
    /// first time round. A throttled container reports "Operation throttled by
    /// previous server http 429 reply. Retry after 14.7 seconds", and that was
    /// being announced as a settings problem too — on a simulator with no iCloud
    /// account it is the *only* thing the app says, so it reads as the model
    /// configuration being broken when nothing is wrong but a busy container.
    static func from(_ error: Error, activity: String? = nil) -> MobileModelRouteError {
        guard let ckError = error as? CKError else {
            return .cannotVerifySettings(error.localizedDescription)
        }
        if Self.transientCodes.contains(ckError.code) {
            return .iCloudUnavailable(activity: activity)
        }
        return .cannotVerifySettings(error.localizedDescription)
    }

    /// The CloudKit failures that pass on their own, and so are both retried
    /// once and, if they persist, reported as iCloud being unreachable rather
    /// than as a settings problem.
    static let transientCodes: Set<CKError.Code> = [
        .notAuthenticated,
        .accountTemporarilyUnavailable,
        .managedAccountRestricted,
        .requestRateLimited,
        .serviceUnavailable,
        .zoneBusy,
        .networkUnavailable,
        .networkFailure,
    ]

    /// How long to wait before the one silent retry of a CloudKit call, or nil
    /// when the failure is not the transient kind. CloudKit's own retry-after
    /// hint is honoured, floored so a zero does not retry instantly into the
    /// same outage and capped so a throttled container ("Retry after 14.7
    /// seconds") does not hold a tap on Listen for a quarter of a minute.
    static func transientRetryDelay(for error: Error) -> Duration? {
        guard let ckError = error as? CKError, transientCodes.contains(ckError.code) else { return nil }
        let suggested = ckError.retryAfterSeconds ?? 2
        return .seconds(min(max(suggested, 0.5), 3))
    }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with Apple before using AI."
        case .iCloudUnavailable(let activity):
            let opening = activity.map { "\($0) could not start because iCloud could not be reached." }
                ?? "iCloud could not be reached, so this setting could not be checked."
            return "\(opening) It was tried twice and no request was sent. Try again in a moment; nothing is wrong with the account or the model settings."
        case .cannotVerifySettings(let detail):
            return "Could not verify the current AI model settings. No request was sent. \(detail)"
        case .invalidPreference(let key):
            return "The synced AI model setting \(key) is invalid. No request was sent."
        case .unsupportedProvider(let provider):
            return "The selected provider \(provider) is not available on this device. No request was sent."
        }
    }
}

// MARK: - Text-to-speech selection

extension MobileModelPreferenceStore {
    struct TextToSpeechSelection: Sendable, Equatable {
        let model: String
        let voice: String?
    }

    /// The account's text-to-speech model and voice — the rows the Mac's Settings
    /// write (`ArticleSpeechSelection.syncedModelKey` and friends). nil when no
    /// device has chosen yet, in which case this phone keeps its own pick.
    func textToSpeechSelection() async throws -> TextToSpeechSelection? {
        let model = try await string(forKey: ArticleSpeechSelection.syncedModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else { return nil }
        let voice = try await string(forKey: ArticleSpeechSelection.syncedVoiceKey)
        return TextToSpeechSelection(model: model, voice: voice)
    }

    /// Records this phone's pick on the account. The provider row is set as
    /// well, so a Mac still on an older provider follows the pick instead of
    /// keeping a model row it never reads.
    func setTextToSpeechSelection(model: String, voice: String?) async throws {
        try await setString(model, forKey: ArticleSpeechSelection.syncedModelKey)
        if let voice, !voice.isEmpty {
            try await setString(voice, forKey: ArticleSpeechSelection.syncedVoiceKey)
        }
        if try await string(forKey: ArticleSpeechSelection.syncedProviderKey)
            != ArticleSpeechSelection.syncedProvider {
            try await setString(
                ArticleSpeechSelection.syncedProvider,
                forKey: ArticleSpeechSelection.syncedProviderKey
            )
        }
    }
}

extension ArticleSpeechPreferences {
    /// Pulls the account's selection onto this phone — before Settings shows
    /// it, and immediately before a billable request. Throws when iCloud
    /// cannot answer; the caller decides whether that stops the request.
    func refreshFromAccount() async throws {
        // The catalog is OpenRouter's speech list, so read it before the
        // account's pick is checked against it: a model the Mac chose from
        // that list is not among the ones this build records. A failed read
        // leaves the recorded list, and a pick outside it is not adopted.
        await OpenRouterAudioDirectory.prepare(.speech)
        reloadFromStorage()
        // Only the free voices run while Free mode is on; `rewrite` reads the
        // switch this refresh writes.
        try await MobileModelPreferenceStore.shared.refreshFreeMode()
        guard let synced = try await MobileModelPreferenceStore.shared.textToSpeechSelection() else {
            return
        }
        adoptSyncedSelection(model: synced.model, voice: synced.voice)
    }

    /// Pushes this phone's current selection to the account.
    func pushToAccount() async throws {
        try await MobileModelPreferenceStore.shared.setTextToSpeechSelection(
            model: modelID,
            voice: voiceID(forModel: modelID)
        )
    }
}

extension AITask {
    /// What the phone was about to do for the learner when a task's route was
    /// being resolved, in the words the banner uses ("Listen could not start").
    /// Nil for the background tasks nobody tapped, which keep the settings
    /// wording.
    var mobileActivityName: String? {
        switch self {
        case .chat: return "The chat"
        case .paperTextToSpeechPreparation, .paperNarrationPreparation: return "Listen"
        case .mobileReview: return "The review"
        case .mobileVoiceAgent: return "The voice conversation"
        case .realtimeReviewPreparation: return "The review"
        case .explainerWriting: return "The explainer"
        case .walkthroughWriting, .walkthroughAnimation: return "The walkthrough"
        default: return nil
        }
    }
}
