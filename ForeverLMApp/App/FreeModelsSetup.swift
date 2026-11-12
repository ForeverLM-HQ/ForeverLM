import Foundation
import OSLog
import UserNotifications

/// OpenRouter's free models as ordinary picks, on the learner's own
/// OpenRouter key: which free models can chat or run background work, best
/// first, and the free backups a free pick brings. Nothing is rerouted
/// behind the learner's back: a free model is a Setting like any other,
/// shown as the model it is.
///
/// Free models come and go, so the ranking is made against OpenRouter's live
/// directory: the preferred models still listed free, then the listed free
/// models with the longest context that can do the job.
enum FreeModelsSetup {
    /// OpenRouter's Free Models Router leads every list: it sends each
    /// request to a free model that is up, so it fails and times out less
    /// than any single free model (product owner, 2026-09-27). The single models
    /// stay offered after it, and become its backups.
    static let recommendedID = AIModelDefaults.openRouterFreeRouter

    static func isRecommended(_ id: String) -> Bool {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == recommendedID
    }

    /// Said beside the router wherever free models are offered.
    static let recommendation = "Recommended: OpenRouter's Free Models Router sends each request to a free model that is up and can do the job, so it fails and times out less than any one free model."

    static let preferredChat = [
        recommendedID,
        AIModelDefaults.freeGemma31B,
        AIModelDefaults.freeQwen27B,
        AIModelDefaults.freeNemotronSuper,
    ]
    static let preferredBackground = [
        recommendedID,
        AIModelDefaults.freeGemma26B,
        AIModelDefaults.freeNemotronSuper,
        AIModelDefaults.freeGemma31B,
    ]
    static let preferredVision = [
        recommendedID,
        AIModelDefaults.freeGemma31B,
        AIModelDefaults.freeQwen27B,
    ]

    static let openRouterPrivacyURL = AIFreeModels.openRouterPrivacyURL

    /// A free model ForeverLM can use: priced at zero, and not one OpenRouter
    /// refused to run outside the apps it lists (`AIFreeModelRestrictions`).
    static func isFree(_ model: OpenRouterDirectoryModel) -> Bool {
        AIFreeModels.isFreeModelID(model.id)
            && model.inputUSDPerMTokens == 0
            && model.outputUSDPerMTokens == 0
            && !AIFreeModelRestrictions.isRestricted(model.id)
    }

    static func isFreeModelID(_ id: String) -> Bool {
        AIFreeModels.isFreeModelID(id)
    }

    /// Whether a model may be picked for a role: not known to fail its test
    /// run of that work. The pickers read the stored verdicts
    /// (`AIModelQualification`); tests pass their own.
    typealias Qualifies = @Sendable (String, AIModelQualification.Role) -> Bool
    static let storedQualification: Qualifies = { !AIModelQualification.isKnownToFail(slug: $0, role: $1) }

    /// How many single free models Settings › Chat's Free list offers beside
    /// the router.
    static let chatAlternatives = 3

    static func customModel(_ model: OpenRouterDirectoryModel) -> AIModelCatalog.CustomOpenRouterModel {
        AIModelCatalog.CustomOpenRouterModel(
            id: model.id,
            name: model.name,
            inputUSDPerMTokens: model.inputUSDPerMTokens,
            outputUSDPerMTokens: model.outputUSDPerMTokens,
            contextLength: model.contextLength,
            supportsTools: model.supportsTools,
            supportsTemperature: model.supportsTemperature,
            supportsVision: model.supportsVision
        )
    }
}

// MARK: - One free model at a time

/// A free model for background work (product owner, 2026-09-25): setup and
/// Settings › Background offer one for background work that reads text and
/// one for work that reads images. Chat, text-to-speech and the other
/// settings keep their models.
extension FreeModelsSetup {
    /// The free models that can run a background task, best first, without
    /// those that failed a test run of it (`AIModelQualification`). Empty
    /// when none can.
    static func candidates(
        needsVision: Bool,
        from directory: [OpenRouterDirectoryModel],
        qualifies: Qualifies = FreeModelsSetup.storedQualification
    ) -> [OpenRouterDirectoryModel] {
        let role: AIModelQualification.Role = needsVision ? .backgroundImages : .background
        return rankedFree(needsVision: needsVision, from: directory).filter { qualifies($0.id, role) }
    }

    /// Every free model that could chat, best first, tested or not: the
    /// preferred chat models OpenRouter still lists, then the rest by context
    /// length. The chat sends its tool catalog on every turn, so each must
    /// take tools.
    static func rankedFreeForChat(from directory: [OpenRouterDirectoryModel]) -> [OpenRouterDirectoryModel] {
        let usable = directory.filter { isFree($0) && $0.supportsTools }
        let ranked = preferredChat.compactMap { id in usable.first { $0.id == id } }
        let rest = usable
            .filter { !preferredChat.contains($0.id) }
            .sorted { ($0.contextLength ?? 0, $1.id) > ($1.contextLength ?? 0, $0.id) }
        return ranked + rest
    }

    /// Every free model that could run a background task, best first,
    /// tested or not: the preferred ones OpenRouter still lists, then the
    /// rest by context length. Background tasks share the chat's request
    /// path, so each must take tools, and one for a task that reads images
    /// must read images.
    static func rankedFree(needsVision: Bool, from directory: [OpenRouterDirectoryModel]) -> [OpenRouterDirectoryModel] {
        let usable = directory.filter {
            isFree($0) && $0.supportsTools && (!needsVision || $0.supportsVision == true)
        }
        let preferred = needsVision ? preferredVision : preferredBackground
        let ranked = preferred.compactMap { id in usable.first { $0.id == id } }
        let rest = usable
            .filter { !preferred.contains($0.id) }
            .sorted { ($0.contextLength ?? 0, $1.id) > ($1.contextLength ?? 0, $0.id) }
        return ranked + rest
    }

    /// Why no free model can be picked right now; nil when one can. Free
    /// models run only on the learner's own OpenRouter key, and the Data &
    /// Privacy switch asks OpenRouter for hosts that keep nothing, which no
    /// free model has.
    static func pickBlocker(
        hasOpenRouterKey: Bool = ManagedAI.ownKeyRouter == .openRouter,
        deniesDataCollection: Bool = AIDataPolicy.deniesDataCollection
    ) -> String? {
        if !hasOpenRouterKey {
            return "Free models run on your OpenRouter API key. Add it under AI Usage (the sidebar's OpenRouter button)."
        }
        if deniesDataCollection {
            return "Free models' providers may keep what you send, so “\(AIDataPolicy.switchTitle)” under \(AIDataPolicy.settingsLocation) leaves them no host. Turn it off to use one."
        }
        return nil
    }

    /// Said wherever a free model is offered or in use, before the learner
    /// relies on it.
    static let pickTradeoffs = "Free models cost nothing on OpenRouter for now, but a model may be free only for a limited time; when one you use starts costing money, ForeverLM moves your work to another free model and tells you. Their providers may keep and train on what you send, so keep anything sensitive away from them, and each model's terms, on its OpenRouter page, are yours to check. They are often busy or rate-limited, so work runs slower and fails more. Allow them in your OpenRouter privacy settings first."

    /// Adds a directory model to the catalog so its name and price resolve
    /// like any other pick, without offering it in the chat's model picker.
    static func catalog(_ model: OpenRouterDirectoryModel) {
        AIModelCatalog.addCustomOpenRouterModel(customModel(model), enableForChat: false)
    }

    /// Points the text-only Background default, or the multimodal one, at a
    /// free model. `backups` become its backup models when it has none yet.
    static func setFreeBackground(_ model: OpenRouterDirectoryModel, multimodal: Bool, backups: [OpenRouterDirectoryModel] = []) {
        catalog(model)
        if multimodal {
            KeychainService.setBackgroundMultimodalTaskRoute(provider: .openRouter, model: model.id)
        } else {
            KeychainService.setBackgroundTaskRoute(provider: .openRouter, model: model.id)
        }
        giveFreeBackups(backups, to: multimodal ? "background.images" : "background.text", primaryID: model.id)
    }

    /// How many free backups a free pick brings on its own. Two, although a
    /// learner may list up to `AIBackupModels.limit` :
    /// that limit is about what a learner may set. Each backup a failing
    /// call walks is one more request against the key's free-model quota,
    /// which OpenRouter counts per day across every free model, so ten
    /// automatic backups could spend a day's quota on a handful of calls
    /// that fail. The Free Models Router that leads the list already sends
    /// each request to a free model that is up.
    static let freeBackupCount = 2

    /// The free backups a free pick brings: the next free models for the
    /// same work, best first, never the pick itself.
    static func freeBackups(
        from candidates: [OpenRouterDirectoryModel],
        primaryID: String
    ) -> [OpenRouterDirectoryModel] {
        let primary = primaryID.lowercased()
        return Array(candidates.filter { $0.id.lowercased() != primary }.prefix(freeBackupCount))
    }

    /// A free pick comes with free backups (product owner, 2026-09-27: backup
    /// models "especially for free ones"): the next free models for the same
    /// work, from the same directory read (`freeBackups`). Free models are
    /// the ones most often busy, rate-limited or answering with nothing, so a
    /// free setting needs somewhere to go. Backups the learner already chose
    /// are theirs and stay.
    static func giveFreeBackups(
        _ candidates: [OpenRouterDirectoryModel],
        to slot: String,
        primaryID: String
    ) {
        guard AIBackupModels.stored(slot: slot).isEmpty else { return }
        let picks = freeBackups(from: candidates, primaryID: primaryID)
        guard !picks.isEmpty else { return }
        picks.forEach(catalog)
        AIBackupModels.set(picks.map { AITaskModelRoute(provider: .openRouter, model: $0.id) }, slot: slot)
    }
}

// MARK: - Whether OpenRouter lets the key use free models

/// OpenRouter refuses every free model until the learner allows free
/// endpoints in their own OpenRouter privacy settings, and nothing in its API
/// says whether they have. So setup asks with one free request on the
/// learner's key (product owner, 2026-09-26: the learner must make that choice
/// during onboarding, not find out when background work fails).
enum FreeModelAccess {
    enum Verdict: Equatable, Sendable {
        case allowed
        /// OpenRouter refused the free model over the account's privacy settings.
        case refused
        /// The request failed for another reason (busy, offline); the message
        /// says which, and nothing is known about the setting.
        case unknown(String)
    }

    /// Where OpenRouter's refusal is recognised: its own words ("data policy",
    /// "training violation") or ForeverLM's translation of them.
    static func verdict(forFailure message: String) -> Verdict {
        if AIDataPolicy.isTrainingPolicyRefusal(message)
            || AIDataPolicy.isDataPolicyRefusal(message)
            || message.lowercased().contains("train on what you send") {
            return .refused
        }
        return .unknown(message)
    }

    /// A few tokens from the free model on the learner's own key. Free, and
    /// never served from the response cache, so it asks OpenRouter every time.
    static func check(model: String) async -> Verdict {
        guard let apiKey = KeychainService.apiKey(for: .openRouter) else {
            return .unknown("Add your OpenRouter key first.")
        }
        var config = AITaskConfig(provider: .openRouter, apiKey: apiKey, model: model)
        config.taskLabel = "free_model_check"
        do {
            _ = try await AIService().call(
                config: config,
                system: "Reply with the single word OK.",
                user: "OK",
                maxTokens: 8,
                disablesReasoning: true,
                allowsResponseCache: false
            )
            return .allowed
        } catch {
            return verdict(forFailure: error.localizedDescription)
        }
    }

    static let refusedExplanation = "Your OpenRouter account does not allow free models yet. In OpenRouter's privacy settings, turn on the free endpoints that may train on your inputs, then come back here."
}

// MARK: - Recommended models

/// The set of models Setup recommends, taken in one step (product owner,
/// 2026-09-28: "the user should have the ability to choose a default set of
/// models … during onboarding"). Chat runs on GLM 5.3 Flash "only provided if
/// it's open source and it's actually being run on the American Inference
/// Cloud. If not, then I want to find another open source model that is
/// actually run on American Inference Cloud. So I don't want the data to go
/// to China." Background work runs on "a free model as a default and an ultra
/// cheap model as a fallback".
///
/// Chosen from live data, like the free picks: OpenRouter's directory says
/// whether a model's weights are open (`huggingFaceID`), and its in-region
/// directory which of the model's hosts run in the US
/// (`OpenRouterRegionalEndpoints`). The chat model and the backup keep a host
/// row with the region (`OpenRouterHostPreference`), so every request for
/// them is confined to those hosts on the Mac and the phone. The free models
/// are not: OpenRouter lists no free endpoint in the US directory, and its
/// Free Models Router picks any free model.
enum RecommendedModels {
    static let region: OpenRouterHostPreference.Region = .us

    /// Chat's model: the first that qualifies (`qualifying`).
    static let preferredChat = [AIModelDefaults.recommendedGLMFlash, AIModelDefaults.recommendedGemma31B, AIModelDefaults.recommendedGPTOSS120B]
    /// The backup background work moves to when the free models fail, run
    /// on its cheapest host in the region: the first that qualifies.
    static let preferredBackup = [AIModelDefaults.recommendedGLMFlash, AIModelDefaults.recommendedDeepSeekFlash, AIModelDefaults.recommendedGPTOSS120B]
    /// The same for background work that reads images.
    static let preferredImagesBackup = [AIModelDefaults.recommendedGLMFlash, AIModelDefaults.recommendedGemma31B]
    /// Hosts in the region a model needs, so one that is down leaves another.
    static let minimumRegionHosts = 2

    struct Pick: Equatable, Sendable {
        let model: OpenRouterDirectoryModel
        /// Its endpoints in the region that take tools.
        let hosts: [OpenRouterRegionalEndpoints.Endpoint]

        var route: AITaskModelRoute { AITaskModelRoute(provider: .openRouter, model: model.id) }
    }

    struct Choice: Equatable, Sendable {
        let chat: Pick
        let backup: Pick
        /// Nil when no model qualifies to read images: that work keeps its model.
        let imagesBackup: Pick?
        /// The free model background work runs on first. Nil when no free
        /// model can be picked (`FreeModelsSetup.pickBlocker`); the backup is
        /// then background work's own model.
        let freeText: OpenRouterDirectoryModel?
        let freeVision: OpenRouterDirectoryModel?
    }

    enum Failure: LocalizedError, Equatable {
        case noChatModel
        case noBackgroundModel

        var errorDescription: String? {
            switch self {
            case .noChatModel:
                "No open-weight chat model has enough hosts in \(RecommendedModels.region.name) on OpenRouter right now. Try again later, or choose models below."
            case .noBackgroundModel:
                "No low-cost open-weight model has enough hosts in \(RecommendedModels.region.name) on OpenRouter right now. Try again later, or choose models below."
            }
        }
    }

    /// The first preferred model that is listed, takes tools, has open
    /// weights, reads images when asked to, is not known to fail the role,
    /// and has at least `minimumRegionHosts` hosts in the region that take
    /// tools. The list is the choice of model; the data decides whether it
    /// can be had.
    static func qualifying(
        _ preferred: [String],
        role: AIModelQualification.Role,
        needsVision: Bool = false,
        directory: [OpenRouterDirectoryModel],
        regionEndpoints: [String: [OpenRouterRegionalEndpoints.Endpoint]],
        qualifies: FreeModelsSetup.Qualifies = FreeModelsSetup.storedQualification
    ) -> Pick? {
        for id in preferred {
            let key = id.lowercased()
            guard let model = directory.first(where: { $0.id.lowercased() == key }),
                  model.supportsTools,
                  model.huggingFaceID != nil,
                  !needsVision || model.supportsVision == true,
                  qualifies(model.id, role)
            else { continue }
            let hosts = (regionEndpoints[key] ?? []).filter(\.supportsTools)
            guard hosts.count >= minimumRegionHosts else { continue }
            return Pick(model: model, hosts: hosts)
        }
        return nil
    }

    /// Every model the set could name, for one read of the region's lists.
    static var candidateIDs: [String] {
        var seen = Set<String>()
        return (preferredChat + preferredBackup + preferredImagesBackup).filter { seen.insert($0.lowercased()).inserted }
    }

    static func choose(
        directory: [OpenRouterDirectoryModel],
        regionEndpoints: [String: [OpenRouterRegionalEndpoints.Endpoint]],
        freeText: OpenRouterDirectoryModel?,
        freeVision: OpenRouterDirectoryModel?,
        qualifies: FreeModelsSetup.Qualifies = FreeModelsSetup.storedQualification
    ) throws -> Choice {
        guard let chat = qualifying(preferredChat, role: .chat, directory: directory, regionEndpoints: regionEndpoints, qualifies: qualifies) else {
            throw Failure.noChatModel
        }
        guard let backup = qualifying(preferredBackup, role: .background, directory: directory, regionEndpoints: regionEndpoints, qualifies: qualifies) else {
            throw Failure.noBackgroundModel
        }
        let imagesBackup = qualifying(
            preferredImagesBackup, role: .backgroundImages, needsVision: true,
            directory: directory, regionEndpoints: regionEndpoints, qualifies: qualifies
        )
        return Choice(chat: chat, backup: backup, imagesBackup: imagesBackup, freeText: freeText, freeVision: freeVision)
    }

    /// Reads OpenRouter's directory, the region's hosts for every candidate,
    /// and the free models background work can run on, then chooses. Off the
    /// main actor.
    static func load() async throws -> Choice {
        let directory = try await OpenRouterCatalogAvailability.shared.models()
        let regionEndpoints = await withTaskGroup(of: (String, [OpenRouterRegionalEndpoints.Endpoint]?).self) { group in
            for id in candidateIDs {
                group.addTask {
                    let endpoints = try? await OpenRouterRegionalEndpoints.shared.endpoints(for: id, region: region)
                    return (id.lowercased(), endpoints)
                }
            }
            var table: [String: [OpenRouterRegionalEndpoints.Endpoint]] = [:]
            for await (id, endpoints) in group {
                if let endpoints { table[id] = endpoints }
            }
            return table
        }
        var freeText: OpenRouterDirectoryModel?
        var freeVision: OpenRouterDirectoryModel?
        if FreeModelsSetup.pickBlocker() == nil {
            await AIModelQualification.qualifyFreeCandidates(from: directory, wanted: 1)
            freeText = FreeModelsSetup.candidates(needsVision: false, from: directory).first
            freeVision = FreeModelsSetup.candidates(needsVision: true, from: directory).first
        }
        return try choose(directory: directory, regionEndpoints: regionEndpoints, freeText: freeText, freeVision: freeVision)
    }

    /// Whether the settings are the set now: chat on its model with the
    /// region's hosts, and background work on the free model (or the backup
    /// when there is none) with the backup behind it. Keychain reads: call
    /// off the main actor.
    static func isApplied(_ choice: Choice) -> Bool {
        let chatProvider = KeychainService.aiProvider
        guard chatProvider == .openRouter,
              KeychainService.model(for: chatProvider).lowercased() == choice.chat.model.id.lowercased(),
              OpenRouterHostPreference.stored(slot: AIBackupModels.chatSlot, slug: choice.chat.model.id)?.region == region
        else { return false }
        let background = KeychainService.displayedBackgroundTaskRoute
        let backupID = choice.backup.model.id.lowercased()
        let hasRegionalBackup = OpenRouterHostPreference.stored(slot: "background.text", slug: choice.backup.model.id)?.region == region
        if let free = choice.freeText {
            return background.model.lowercased() == free.id.lowercased()
                && AIBackupModels.stored(slot: "background.text").first?.model.lowercased() == backupID
                && hasRegionalBackup
        }
        return background.model.lowercased() == backupID && hasRegionalBackup
    }

    /// Takes the set. Meetings need nothing of their own: while background
    /// work is free and the learner has not let meetings go free, a meeting
    /// task runs on the default's first paid backup
    /// (`MeetingModels.paidRoute`), which is this set's backup, on its hosts
    /// in the region. Taking the set keeps meetings there, as its row says;
    /// Setup's Meetings answer can let them go free afterwards.
    @MainActor
    static func apply(_ choice: Choice) async throws {
        // Chat, on the region's hosts. The host row goes first, so no chat
        // starts on the new default before it is confined.
        let chatID = choice.chat.model.id
        OpenRouterHostPreference.set(
            OpenRouterHostPreference(mode: .automatic, region: region),
            slot: AIBackupModels.chatSlot,
            slug: chatID
        )
        AIModelCatalog.addCustomOpenRouterModel(FreeModelsSetup.customModel(choice.chat.model))
        AIModelCatalog.setDefault(AIModelCatalogEntry(maker: AIModelCatalog.maker(forOpenRouterSlug: chatID), provider: .openRouter, modelID: chatID))
        guard AIModelCatalog.defaultEntry?.modelID.lowercased() == chatID.lowercased() else {
            throw Failure.noChatModel
        }

        let backupRow = OpenRouterHostPreference(mode: .cheapest, region: region)

        // Background work that reads text.
        FreeModelsSetup.catalog(choice.backup.model)
        OpenRouterHostPreference.set(backupRow, slot: "background.text", slug: choice.backup.model.id)
        if let free = choice.freeText {
            MeetingModels.setMayUseFree(false)
            FreeModelsSetup.setFreeBackground(free, multimodal: false)
            AIBackupModels.set([choice.backup.route], slot: "background.text")
        } else {
            KeychainService.setBackgroundTaskRoute(provider: .openRouter, model: choice.backup.model.id)
            AIBackupModels.set([], slot: "background.text")
        }

        // Background work that reads images.
        if let imagesBackup = choice.imagesBackup {
            FreeModelsSetup.catalog(imagesBackup.model)
            OpenRouterHostPreference.set(backupRow, slot: "background.images", slug: imagesBackup.model.id)
            if let free = choice.freeVision {
                FreeModelsSetup.setFreeBackground(free, multimodal: true)
                AIBackupModels.set([imagesBackup.route], slot: "background.images")
            } else {
                KeychainService.setBackgroundMultimodalTaskRoute(provider: .openRouter, model: imagesBackup.model.id)
                AIBackupModels.set([], slot: "background.images")
            }
        } else if let free = choice.freeVision {
            FreeModelsSetup.setFreeBackground(free, multimodal: true)
        }

        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }
}

// MARK: - Replacing a free model that ended

/// Moves every setting that uses a free model OpenRouter now charges for, or
/// no longer lists, onto another free model that can do the same work
/// (product owner, 2026-09-26). It always runs on its own: there is no switch to
/// turn it off, since the replacement leads with the Free Models Router, which
/// never charges. A setting no free model can take
/// keeps the one it has, and the notification says so.
enum FreeModelReplacement {
    struct Move: Equatable, Sendable {
        let setting: String
        let modelName: String
    }

    struct Outcome: Equatable, Sendable {
        var moves: [Move] = []
        /// Settings still on the ended model, because no free model can do
        /// their work today.
        var stranded: [String] = []
        /// Settings that had the ended model as a backup and lost it, since
        /// no other free model could take its place.
        var removedBackups: [String] = []
    }

    /// The best free model for background work other than the one that ended.
    static func replacement(
        for endedID: String,
        needsVision: Bool,
        from directory: [OpenRouterDirectoryModel],
        qualifies: FreeModelsSetup.Qualifies = FreeModelsSetup.storedQualification
    ) -> OpenRouterDirectoryModel? {
        let ended = endedID.lowercased()
        return FreeModelsSetup.candidates(needsVision: needsVision, from: directory, qualifies: qualifies)
            .first { $0.id.lowercased() != ended }
    }

    /// The best free model for chat other than the one that ended.
    static func chatReplacement(
        for endedID: String,
        from directory: [OpenRouterDirectoryModel],
        qualifies: FreeModelsSetup.Qualifies = FreeModelsSetup.storedQualification
    ) -> OpenRouterDirectoryModel? {
        let ended = endedID.lowercased()
        return FreeModelsSetup.rankedFreeForChat(from: directory)
            .first { $0.id.lowercased() != ended && qualifies($0.id, .chat) }
    }

    /// What the switched banner calls a backup slot's setting.
    static func backupSettingName(_ slot: String) -> String? {
        switch slot {
        case AIBackupModels.chatSlot: return "Chat (scheduled tasks)"
        case "background.text": return "Background work"
        case "background.images": return "Multimodal background work"
        default: return nil
        }
    }

    /// The model a backup slot's setting runs on.
    private static func backupSlotPrimary(_ slot: String) -> AITaskModelRoute? {
        switch slot {
        case AIBackupModels.chatSlot:
            let provider = KeychainService.aiProvider
            return AITaskModelRoute(provider: provider, model: KeychainService.model(for: provider))
        case "background.text": return KeychainService.displayedBackgroundTaskRoute
        case "background.images": return KeychainService.displayedBackgroundMultimodalTaskRoute
        default: return nil
        }
    }

    @MainActor
    static func replace(_ endedID: String, directory: [OpenRouterDirectoryModel]) -> Outcome {
        let ended = endedID.lowercased()
        func uses(_ provider: AIProvider, _ model: String) -> Bool {
            provider == .openRouter && model.lowercased() == ended
        }
        var outcome = Outcome()
        func move(_ setting: String, to model: OpenRouterDirectoryModel?, apply: (OpenRouterDirectoryModel) -> Void) {
            guard let model else {
                outcome.stranded.append(setting)
                return
            }
            apply(model)
            outcome.moves.append(Move(setting: setting, modelName: model.name))
        }

        let chatProvider = KeychainService.aiProvider
        if uses(chatProvider, KeychainService.model(for: chatProvider)) {
            move("Chat", to: chatReplacement(for: endedID, from: directory)) { model in
                AIModelCatalog.addCustomOpenRouterModel(FreeModelsSetup.customModel(model))
                AIModelCatalog.setDefault(AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: model.id))
            }
        }
        // Docs' own model, when it is the free one that ended; Docs that
        // follow the Default Model moved with it above.
        if let docs = KeychainService.docsRoute, uses(docs.provider, docs.model) {
            move("Pages", to: chatReplacement(for: endedID, from: directory)) { model in
                AIModelCatalog.addCustomOpenRouterModel(FreeModelsSetup.customModel(model))
                KeychainService.setDocsRoute(AITaskModelRoute(provider: .openRouter, model: model.id))
            }
        }
        let background = KeychainService.displayedBackgroundTaskRoute
        if uses(background.provider, background.model) {
            move("Background work", to: replacement(for: endedID, needsVision: false, from: directory)) {
                FreeModelsSetup.setFreeBackground($0, multimodal: false)
            }
        }
        let multimodal = KeychainService.displayedBackgroundMultimodalTaskRoute
        if uses(multimodal.provider, multimodal.model) {
            move("Multimodal background work", to: replacement(for: endedID, needsVision: true, from: directory)) {
                FreeModelsSetup.setFreeBackground($0, multimodal: true)
            }
        }
        // A task with a model of its own on the ended one (Card Wording Check,
        // Card Drafting, ...) moves like Background's does. The learner's pick
        // for it was a free model, so its replacement is one too.
        for task in KeychainService.tasksWithOwnRoute(on: endedID) {
            move(task.displayName, to: replacement(for: endedID, needsVision: task.requiresVision, from: directory)) { model in
                FreeModelsSetup.catalog(model)
                KeychainService.setOwnRoute(AITaskModelRoute(provider: .openRouter, model: model.id), for: task)
            }
        }
        // A backup on the ended model takes the next free model for the same
        // work that its setting does not already run on; with none, it goes.
        for (slot, backups) in AIBackupModels.allStored().sorted(by: { $0.key < $1.key }) {
            guard let index = backups.firstIndex(where: { uses($0.provider, $0.model) }),
                  let setting = backupSettingName(slot) else { continue }
            let primary = backupSlotPrimary(slot)
            let taken = Set((backups + [primary].compactMap { $0 }).map { AIBackupModels.identity($0.provider, $0.model) })
            let pool: [OpenRouterDirectoryModel]
            if slot == AIBackupModels.chatSlot {
                pool = FreeModelsSetup.rankedFreeForChat(from: directory).filter { FreeModelsSetup.storedQualification($0.id, .chat) }
            } else {
                pool = FreeModelsSetup.candidates(needsVision: slot == "background.images", from: directory)
            }
            var kept = backups
            if let next = pool.first(where: {
                $0.id.lowercased() != ended && !taken.contains(AIBackupModels.identity(.openRouter, $0.id))
            }) {
                FreeModelsSetup.catalog(next)
                kept[index] = AITaskModelRoute(provider: .openRouter, model: next.id)
                outcome.moves.append(Move(setting: "A backup for \(setting)", modelName: next.name))
            } else {
                kept.remove(at: index)
                outcome.removedBackups.append(setting)
            }
            AIBackupModels.set(kept, slot: slot)
        }
        if !outcome.moves.isEmpty || !outcome.removedBackups.isEmpty {
            NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        }
        return outcome
    }
}

// MARK: - Price watch

/// Tells the learner when a model they use starts costing money or costs more
/// (product owner, 2026-09-25: free models may be free only for a limited time, and
/// a model going from free to paid, or up in price, is shown as a
/// notification). Every read of OpenRouter's directory
/// (`AIModelPriceRefresher.ingest`: at launch, on app activation, and when
/// a picker opens) is compared with the prices the previous read recorded
/// for the models the learner's settings name: the chat default, both
/// Background defaults and every task's resolved model. Each change raises
/// one banner for that model, which opens Settings › Chat. The first read of
/// a model only records it.
/// A free model that ended is swapped for another free one first, and the
/// banner says what moved; when nothing could move, the banner asks, and its
/// Switch to a Free Model action tries again against a fresh directory read.
enum AIModelPriceWatch {
    private static let logger = Logger(subsystem: "com.foreverlm", category: "ModelPriceWatch")

    /// What one read said about a watched model, in USD per million tokens.
    struct Seen: Codable, Equatable, Sendable {
        let name: String
        let input: Double
        let output: Double
        var isFree: Bool { input == 0 && output == 0 }
    }

    enum Change: Equatable, Sendable {
        /// A model listed at zero now lists a price.
        case noLongerFree(id: String, name: String, now: Seen)
        /// A free model OpenRouter stopped listing, which is how a `:free`
        /// variant usually ends.
        case freeVariantEnded(id: String, name: String)
        /// A paid model costs more for input or output.
        case moreExpensive(id: String, name: String, from: Seen, to: Seen)
        /// OpenRouter refused a free model because it offers it only inside
        /// the apps it lists; the directory still shows it free.
        case limitedToListedApps(id: String, name: String)

        var modelID: String {
            switch self {
            case .noLongerFree(let id, _, _), .freeVariantEnded(let id, _), .moreExpensive(let id, _, _, _),
                 .limitedToListedApps(let id, _): id
            }
        }

        var modelName: String {
            switch self {
            case .noLongerFree(_, let name, _), .freeVariantEnded(_, let name), .moreExpensive(_, let name, _, _),
                 .limitedToListedApps(_, let name): name
            }
        }

        /// A free model stopped being free: the settings using it can move to
        /// another free one.
        var endsFree: Bool {
            if case .moreExpensive = self { return false }
            return true
        }
    }

    static let identifierPrefix = "com.foreverlm.modelprice."
    /// The banner for a free model that ended, when it was not switched on
    /// its own, asks whether to switch: this action does it.
    static let categoryIdentifier = "com.foreverlm.modelprice.endedFree"
    static let switchActionIdentifier = "com.foreverlm.modelprice.switchToFree"
    static let modelIDKey = "modelID"
    static let modelNameKey = "modelName"
    /// A read with fewer rows is a truncated response, not models leaving.
    static let minimumDirectoryRows = 50
    /// Prices are compared to a hundredth of a cent per million tokens, so a
    /// float that round-trips through JSON never reads as a rise.
    static let tolerance = 0.000_1
    private static let lock = NSLock()

    /// What the watch keeps between reads: the last record of each watched
    /// model's price, and the free models reported as ended on first sight
    /// (`compare`'s `announced`), kept while the settings still name them.
    /// Device-local, like the price table it sits beside: each Mac reads the
    /// directory and notifies for itself.
    private struct WatchState {
        var previous: [String: Seen]
        var announced: Set<String>
    }

    nonisolated(unsafe) private static var cachedState: WatchState?

    /// The stored state, read with `lock` released and published under it (a
    /// defaults read must not happen while a lock is held).
    private static func loadedState() -> WatchState {
        if let cached = lock.withLock({ cachedState }) { return cached }
        let previous = Preferences.value(Prefs.Models.priceWatchLastSeen)
            .flatMap { try? JSONDecoder().decode([String: Seen].self, from: $0) } ?? [:]
        let announced = Set(Preferences.value(Prefs.Models.priceWatchAnnouncedEnded) ?? [])
        let stored = WatchState(previous: previous, announced: announced)
        return lock.withLock {
            if let cachedState { return cachedState }
            cachedState = stored
            return stored
        }
    }

    /// Compares one directory read with the previous record. Returns the
    /// changes to announce and the record to keep: only watched models, a
    /// paid model missing from one read kept as it was, a free one that
    /// vanished reported once and then forgotten.
    ///
    /// A `:free` id with no earlier record is judged by this read alone: the
    /// record only holds models seen while listed, so a pick made after its
    /// row left, or a task's own pick the record never took, would otherwise
    /// never be noticed (the Card Wording Check on a delisted Nemotron). `announced` holds the ids already reported that way, so a
    /// model nothing could replace is not announced on every read.
    static func compare(
        watched: Set<String>,
        previous: [String: Seen],
        directory: [OpenRouterDirectoryModel],
        announced: Set<String> = []
    ) -> (changes: [Change], record: [String: Seen]) {
        guard directory.count >= minimumDirectoryRows else { return ([], previous) }
        let rows = Dictionary(directory.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [Change] = []
        var record: [String: Seen] = [:]
        for id in watched.sorted() {
            let key = id.lowercased()
            let before = previous[key]
            guard let row = rows[key], let input = row.inputUSDPerMTokens, let output = row.outputUSDPerMTokens else {
                if let before {
                    if before.isFree, rows[key] == nil {
                        changes.append(.freeVariantEnded(id: id, name: before.name))
                    } else {
                        record[key] = before
                    }
                } else if key.hasSuffix(":free"), rows[key] == nil, !announced.contains(key) {
                    changes.append(.freeVariantEnded(id: id, name: id))
                }
                continue
            }
            let now = Seen(name: row.name, input: input, output: output)
            record[key] = now
            guard let before else {
                if key.hasSuffix(":free"), !now.isFree, !announced.contains(key) {
                    changes.append(.noLongerFree(id: row.id, name: row.name, now: now))
                }
                continue
            }
            if before.isFree, !now.isFree {
                changes.append(.noLongerFree(id: row.id, name: row.name, now: now))
            } else if !before.isFree,
                      now.input > before.input + tolerance || now.output > before.output + tolerance {
                changes.append(.moreExpensive(id: row.id, name: row.name, from: before, to: now))
            }
        }
        return (changes, record)
    }

    /// The OpenRouter slugs the learner's settings send work to.
    static func watchedModelIDs() -> Set<String> {
        var ids: Set<String> = []
        func add(_ provider: AIProvider, _ model: String) {
            guard AIService.routesThroughOpenRouter(provider) else { return }
            let slug = AIService.openAICompatibleModelID(provider: provider, model: model)
            if !slug.isEmpty { ids.insert(slug) }
        }
        let chatProvider = KeychainService.aiProvider
        add(chatProvider, KeychainService.model(for: chatProvider))
        let background = KeychainService.displayedBackgroundTaskRoute
        add(background.provider, background.model)
        let multimodal = KeychainService.displayedBackgroundMultimodalTaskRoute
        add(multimodal.provider, multimodal.model)
        for task in AITask.allCases {
            let selection = KeychainService.resolvedSelection(for: task)
            add(selection.provider, selection.model)
            // A free pick of its own that ended resolves to Background's model
            // above, so it is named here as the learner set it.
            if let own = KeychainService.storedOwnRoute(for: task) { add(own.provider, own.model) }
        }
        for route in AIBackupModels.allStored().values.flatMap({ $0 }) {
            add(route.provider, route.model)
        }
        return ids
    }

    /// Called with every directory read. Off the main actor; the record is a
    /// small UserDefaults value, and delivery is asynchronous.
    static func observe(_ directory: [OpenRouterDirectoryModel]) {
        // The hosted unit tests launch the app, whose own directory read
        // would otherwise record prices and could raise banners mid-run.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let watched = watchedModelIDs()
        let stored = loadedState()
        // The comparison and the in-memory copy change under the lock; the
        // stored rows are written after it is released.
        let (changes, recordToWrite, announcedToWrite): ([Change], [String: Seen]?, [String]?) = lock.withLock {
            let state = cachedState ?? stored
            let result = compare(watched: watched, previous: state.previous, directory: directory, announced: state.announced)
            let lowered = Set(watched.map { $0.lowercased() })
            let kept = state.announced.union(result.changes.filter(\.endsFree).map { $0.modelID.lowercased() }).intersection(lowered)
            cachedState = WatchState(previous: result.record, announced: kept)
            return (
                result.changes,
                result.record != state.previous ? result.record : nil,
                kept != state.announced ? kept.sorted() : nil
            )
        }
        if let recordToWrite, let data = try? JSONEncoder().encode(recordToWrite) {
            Preferences.set(data, for: Prefs.Models.priceWatchLastSeen)
        }
        if let announcedToWrite {
            Preferences.set(announcedToWrite, for: Prefs.Models.priceWatchAnnouncedEnded)
        }
        guard !changes.isEmpty else { return }
        Task.detached(priority: .utility) {
            for change in changes {
                if change.endsFree {
                    await AIModelQualification.qualifyFreeCandidates(from: directory)
                    let outcome = await FreeModelReplacement.replace(change.modelID, directory: directory)
                    if !outcome.moves.isEmpty {
                        await deliverSwitched(modelID: change.modelID, name: change.modelName, outcome: outcome)
                        continue
                    }
                }
                await deliver(change)
            }
        }
    }

    /// OpenRouter refused a free model as limited to the apps it lists. Called
    /// once per model (`AIFreeModelRestrictions.record` says when it is new):
    /// the settings on it move to another free model, as for a free period
    /// that ended, and the banner asks only when nothing could move.
    static func observeRestriction(_ modelID: String) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task.detached(priority: .utility) {
            let directory = (try? await OpenRouterCatalogAvailability.shared.models()) ?? []
            let name = directory.first { $0.id.lowercased() == modelID.lowercased() }?.name ?? modelID
            let change = Change.limitedToListedApps(id: modelID, name: name)
            if !directory.isEmpty {
                await AIModelQualification.qualifyFreeCandidates(from: directory)
                let outcome = await FreeModelReplacement.replace(modelID, directory: directory)
                if !outcome.moves.isEmpty {
                    await deliverSwitched(modelID: modelID, name: name, outcome: outcome, title: title(for: change))
                    return
                }
            }
            await deliver(change)
        }
    }

    /// The notification's Switch to a Free Model: reads the directory again,
    /// so the replacement is chosen from what OpenRouter lists now.
    static func switchToFree(modelID: String, name: String) async {
        guard let directory = try? await OpenRouterCatalogAvailability.shared.models() else { return }
        await AIModelQualification.qualifyFreeCandidates(from: directory)
        let outcome = await FreeModelReplacement.replace(modelID, directory: directory)
        await deliverSwitched(modelID: modelID, name: name, outcome: outcome)
    }

    /// What a switch did, in one banner that replaces the one that asked.
    static func switchedBody(_ outcome: FreeModelReplacement.Outcome) -> String {
        var sentences: [String] = []
        for move in outcome.moves {
            sentences.append("\(move.setting) now runs on \(move.modelName), which is free.")
        }
        if !outcome.stranded.isEmpty {
            let list = ListFormatter.localizedString(byJoining: outcome.stranded)
            sentences.append("No free model can do \(list) today, so it still uses this model and costs money.")
        }
        if !outcome.removedBackups.isEmpty {
            let list = ListFormatter.localizedString(byJoining: outcome.removedBackups)
            sentences.append("It is no longer a backup for \(list): no other free model can take its place.")
        }
        if outcome.moves.isEmpty, outcome.stranded.isEmpty, outcome.removedBackups.isEmpty {
            sentences.append("Nothing uses it any more.")
        }
        sentences.append("Change it in Settings › Chat.")
        return sentences.joined(separator: " ")
    }

    static func title(for change: Change) -> String {
        switch change {
        case .noLongerFree(_, let name, _), .freeVariantEnded(_, let name): "\(name) is no longer free"
        case .moreExpensive(_, let name, _, _): "\(name) now costs more"
        case .limitedToListedApps(_, let name): "\(name) is no longer free in ForeverLM"
        }
    }

    static func body(for change: Change) -> String {
        let next = "Work that uses it now costs money. Switch to another free model?"
        switch change {
        case .noLongerFree(_, _, let now):
            return "OpenRouter now charges \(AIModelListPrice.pairLabel(input: now.input, output: now.output)) per million tokens in/out. \(next)"
        case .freeVariantEnded:
            return "OpenRouter stopped offering it for free. \(next)"
        case .limitedToListedApps:
            return "OpenRouter now offers it only inside the apps it lists, so every request from ForeverLM fails. Switch to another free model?"
        case .moreExpensive(_, _, let from, let to):
            return "Now \(AIModelListPrice.pairLabel(input: to.input, output: to.output)) per million tokens in/out, up from \(AIModelListPrice.pairLabel(input: from.input, output: from.output)). Change it in Settings › Chat if that is too much."
        }
    }

    /// Delivered at once, one banner per model: a later change to the same
    /// model replaces it. Asks for permission the first time, since the
    /// learner has something worth knowing right now.
    static func deliver(_ change: Change) async {
        let content = UNMutableNotificationContent()
        content.title = title(for: change)
        content.body = body(for: change)
        if change.endsFree {
            await registerCategory()
            content.categoryIdentifier = categoryIdentifier
            content.userInfo = [modelIDKey: change.modelID, modelNameKey: change.modelName]
        }
        await post(content, modelID: change.modelID)
    }

    static func deliverSwitched(
        modelID: String,
        name: String,
        outcome: FreeModelReplacement.Outcome,
        title: String? = nil
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title ?? "\(name) is no longer free"
        content.body = switchedBody(outcome)
        await post(content, modelID: modelID)
    }

    private static func post(_ content: UNMutableNotificationContent, modelID: String) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifierPrefix + modelID,
            content: content,
            trigger: nil
        )
        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        do {
            try await center.add(request)
        } catch {
            logger.error("Posting the price notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func registerCategory() async {
        let switchAction = UNNotificationAction(
            identifier: switchActionIdentifier,
            title: "Switch to a Free Model",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [switchAction],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        var all = await center.notificationCategories().filter { $0.identifier != categoryIdentifier }
        all.insert(category)
        center.setNotificationCategories(all)
    }
}
