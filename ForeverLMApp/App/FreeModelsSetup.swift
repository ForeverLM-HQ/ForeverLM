import Foundation
import SwiftUI
import UserNotifications

/// Free mode's model picks: points chat, the Background models and text-to-speech
/// at OpenRouter's free models, on the learner's own OpenRouter key. It began
/// (2026-09-23) as the way to use ForeverLM without a plan, stopped being one
/// on 2026-09-25, stood in for a plan again on 2026-09-26 only, and since
/// 2026-09-27 needs one: without a plan the proxy refuses the key for every
/// model, `:free` ones included. With a plan it guarantees nothing sent is
/// charged to the learner's OpenRouter account.
/// Nothing is rerouted behind the learner's back: the choices are ordinary
/// Settings, shown as the models they are, and any of them can be changed
/// afterwards.
///
/// Free models come and go, so the choice is made against OpenRouter's live
/// directory: the first preferred model still listed free, else the listed
/// free model with the longest context that can do the job.
enum FreeModelsSetup {
    struct Choice: Equatable {
        let chat: OpenRouterDirectoryModel
        let background: OpenRouterDirectoryModel
        /// Nil when no free model reads images today; the vision tasks then
        /// keep their paid model.
        let vision: OpenRouterDirectoryModel?
    }

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
        "google/gemma-4-31b-it:free",
        "qwen/qwen3.8-27b:free",
        "nvidia/nemotron-3-super-120b-a12b:free",
    ]
    static let preferredBackground = [
        recommendedID,
        "google/gemma-4-26b-a4b-it:free",
        "nvidia/nemotron-3-super-120b-a12b:free",
        "google/gemma-4-31b-it:free",
    ]
    static let preferredVision = [
        recommendedID,
        "google/gemma-4-31b-it:free",
        "qwen/qwen3.8-27b:free",
    ]
    /// The free text-to-speech model Free mode prefers, while OpenRouter's speech
    /// directory lists it at no charge (`freeTextToSpeechModel(from:)`).
    static let textToSpeechModel = "fish-audio/s2.1-pro-free:free"

    /// The text-to-speech model Free mode switches to: `textToSpeechModel` while the
    /// speech catalog — OpenRouter's speech directory — lists it free, or else
    /// the first other `:free` model it lists at no charge. Nil when it lists
    /// none, and text-to-speech keeps its model.
    static func freeTextToSpeechModel(from models: [ArticleSpeechModelOption]) -> ArticleSpeechModelOption? {
        let free = models.filter { AIFreeMode.isFreeModelID($0.id) && $0.ratePerMillionCharacters == 0 }
        return free.first { $0.id == textToSpeechModel } ?? free.first
    }

    static let openRouterPrivacyURL = AIFreeMode.openRouterPrivacyURL

    /// A free model ForeverLM can use: priced at zero, and not one OpenRouter
    /// refused to run outside the apps it lists (`AIFreeModelRestrictions`).
    static func isFree(_ model: OpenRouterDirectoryModel) -> Bool {
        AIFreeMode.isFreeModelID(model.id)
            && model.inputUSDPerMTokens == 0
            && model.outputUSDPerMTokens == 0
            && !AIFreeModelRestrictions.isRestricted(model.id)
    }

    static func isFreeModelID(_ id: String) -> Bool {
        AIFreeMode.isFreeModelID(id)
    }

    /// Whether a model may be picked for a role: not known to fail its test
    /// run of that work. The pickers read the stored verdicts
    /// (`AIModelQualification`); tests pass their own.
    typealias Qualifies = @Sendable (String, AIModelQualification.Role) -> Bool
    static let storedQualification: Qualifies = { !AIModelQualification.isKnownToFail(slug: $0, role: $1) }

    /// Nil when OpenRouter lists no free model that can take the chat's tools
    /// and has not failed its test for chat or for background work.
    static func choose(
        from directory: [OpenRouterDirectoryModel],
        qualifies: Qualifies = FreeModelsSetup.storedQualification
    ) -> Choice? {
        // The chat sends its tool catalog on every turn, and the Background
        // tasks share the same request path, so every pick must take tools.
        let candidates = directory.filter { isFree($0) && $0.supportsTools }
        func pick(_ preferred: [String], _ fits: (OpenRouterDirectoryModel) -> Bool) -> OpenRouterDirectoryModel? {
            for id in preferred {
                if let model = candidates.first(where: { $0.id == id }), fits(model) { return model }
            }
            return candidates
                .filter(fits)
                .max { ($0.contextLength ?? 0, $1.id) < ($1.contextLength ?? 0, $0.id) }
        }
        guard let chat = pick(preferredChat, { qualifies($0.id, .chat) }),
              let background = pick(preferredBackground, { qualifies($0.id, .background) })
        else { return nil }
        return Choice(
            chat: chat,
            background: background,
            vision: pick(preferredVision, { $0.supportsVision == true && qualifies($0.id, .backgroundImages) })
        )
    }

    /// Reads the live directory, then points chat, the Background models and
    /// text-to-speech at free models. Returns what was chosen. Only
    /// `enableFreeMode()` calls it, so the switch always says what happened.
    @MainActor
    private static func apply() async throws -> Choice {
        let directory = try await OpenRouterCatalogAvailability.shared.models()
        // Each pick must have done its work once: test the model each role
        // would land on, moving down the ranking past any that fail.
        await AIModelQualification.qualifyFreeCandidates(from: directory)
        guard let choice = choose(from: directory) else { throw Failure.noFreeModel }
        var added: Set<String> = []
        for model in [choice.chat, choice.background, choice.vision].compactMap({ $0 }) where added.insert(model.id).inserted {
            AIModelCatalog.addCustomOpenRouterModel(customModel(model))
        }
        // The chat picker offers only free models while Free mode is on, so
        // the single free models join it beside the router: it is the
        // recommended pick, not the only one.
        let alternatives = rankedFreeForChat(from: directory).filter { storedQualification($0.id, .chat) }
        for model in alternatives.prefix(chatAlternatives + 1) where added.insert(model.id).inserted {
            AIModelCatalog.addCustomOpenRouterModel(customModel(model))
        }
        AIModelCatalog.setDefault(AIModelCatalogEntry(maker: .other, provider: .openRouter, modelID: choice.chat.id))
        // Docs follow the free Default Model; their own pick was saved with
        // the rest and comes back when Free mode goes off.
        KeychainService.setDocsRoute(nil)
        KeychainService.setBackgroundTaskRoute(provider: .openRouter, model: choice.background.id)
        // Backups too: the learner's own were saved with the rest and come
        // back when Free mode goes off, and a paid one would not run meanwhile.
        // The chat's serve a scheduled task's runs, which on a free model are
        // the runs that most need somewhere to go.
        giveFreeBackups(
            alternatives,
            to: AIBackupModels.chatSlot,
            primaryID: choice.chat.id,
            replacing: true
        )
        giveFreeBackups(
            candidates(needsVision: false, from: directory),
            to: "background.text",
            primaryID: choice.background.id,
            replacing: true
        )
        if let vision = choice.vision {
            KeychainService.setBackgroundMultimodalTaskRoute(provider: .openRouter, model: vision.id)
            giveFreeBackups(
                candidates(needsVision: true, from: directory),
                to: "background.images",
                primaryID: vision.id,
                replacing: true
            )
        }
        // The speech list is OpenRouter's directory, which this Mac may not
        // have read yet.
        await OpenRouterAudioDirectory.prepare(.speech)
        if let speech = freeTextToSpeechModel(from: ArticleSpeechCatalog.models) {
            MacArticleSpeechSettings.openRouterModel = speech.id
            ArticleSpeechSelection.selectModel(speech.id)
        }
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
        return choice
    }

    /// How many single free models Free mode adds to the chat picker
    /// beside its pick.
    static let chatAlternatives = 3

    enum Failure: LocalizedError {
        case noFreeModel
        case needsOpenRouterKey
        case needsPlan
        var errorDescription: String? {
            switch self {
            case .noFreeModel:
                "OpenRouter lists no free model that ForeverLM can chat with right now. Try again later."
            case .needsOpenRouterKey:
                "Free mode runs on your own OpenRouter key. Add one under Settings → AI Usage first."
            case .needsPlan:
                "Your OpenRouter key runs ForeverLM's AI features, free models included, once you choose a plan under Settings → Billing."
            }
        }
    }

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

/// A free model for background work without turning Free mode on (product owner,
/// 2026-09-25): setup and Settings › Background offer one for background
/// work that reads text and one for work that reads images. Chat, text-to-speech
/// and the other settings keep their models.
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

    /// The free models Free mode's chat pick chooses from, in the order it
    /// prefers them: the preferred chat models, then by context length.
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
    /// rest by context length. Like Free mode's picks, each must take tools,
    /// and one for a task that reads images must read images.
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
            return "Free models run on your own OpenRouter key. Add it under Settings › AI Usage."
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
    /// learner may list up to `AIBackupModels.limit` (ten since 2026-09-27):
    /// that request was about what a learner may set. Each backup a failing
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
    /// are theirs and stay; `replacing` is for Free mode, which saved them
    /// first.
    static func giveFreeBackups(
        _ candidates: [OpenRouterDirectoryModel],
        to slot: String,
        primaryID: String,
        replacing: Bool = false
    ) {
        guard replacing || AIBackupModels.stored(slot: slot).isEmpty else { return }
        let picks = freeBackups(from: candidates, primaryID: primaryID)
        guard !picks.isEmpty || replacing else { return }
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
/// Chosen from live data, like Free mode's picks: OpenRouter's directory says
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
    static let preferredChat = ["z-ai/glm-5.3-flash", "google/gemma-4-31b-it", "openai/gpt-oss-120b"]
    /// The backup background work moves to when the free models fail, run
    /// on its cheapest host in the region: the first that qualifies.
    static let preferredBackup = ["z-ai/glm-5.3-flash", "deepseek/deepseek-v4-flash", "openai/gpt-oss-120b"]
    /// The same for background work that reads images.
    static let preferredImagesBackup = ["z-ai/glm-5.3-flash", "google/gemma-4-31b-it"]
    /// Hosts in the region a model needs, so one that is down leaves another.
    static let minimumRegionHosts = 2

    struct Pick: Equatable, Sendable {
        let model: OpenRouterDirectoryModel
        /// Its endpoints in the region that take tools.
        let hosts: [OpenRouterRegionalEndpoints.Endpoint]

        var route: AITaskModelRoute { AITaskModelRoute(provider: .openRouter, model: model.id) }

        /// The cheapest of its hosts' prices, in and out, for the row.
        var cheapestPrice: (input: Double, output: Double)? {
            let prices: [(Double, Double)] = hosts.compactMap { host in
                guard let input = host.inputUSDPerMTokens, let output = host.outputUSDPerMTokens else { return nil }
                return (input, output)
            }
            return prices.min { $0.0 + $0.1 < $1.0 + $1.1 }.map { (input: $0.0, output: $0.1) }
        }
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
        case freeMode

        var errorDescription: String? {
            switch self {
            case .noChatModel:
                "No open-weight chat model has enough hosts in \(RecommendedModels.region.name) on OpenRouter right now. Try again later, or choose models below."
            case .noBackgroundModel:
                "No low-cost open-weight model has enough hosts in \(RecommendedModels.region.name) on OpenRouter right now. Try again later, or choose models below."
            case .freeMode:
                "Free mode is on, and the recommended chat model is paid. Turn Free mode off to use it."
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
        guard !AIFreeMode.isOn else { throw Failure.freeMode }

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
/// (product owner, 2026-09-26). It always runs on its own: the switch that turned
/// it off was removed on 2026-09-27, since the replacement leads with the
/// Free Models Router, which never charges. A setting no free model can take
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

    /// Free mode's chat pick from the directory without the ended model.
    static func chatReplacement(
        for endedID: String,
        from directory: [OpenRouterDirectoryModel],
        qualifies: FreeModelsSetup.Qualifies = FreeModelsSetup.storedQualification
    ) -> OpenRouterDirectoryModel? {
        let ended = endedID.lowercased()
        return FreeModelsSetup.choose(from: directory.filter { $0.id.lowercased() != ended }, qualifies: qualifies)?.chat
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

// MARK: - Free mode

/// The Mac half of `AIFreeMode`: what turning the switch on and off does to
/// the model settings. On, every setting points at a free model (`apply()`),
/// and the Data & Privacy switch goes off, since its request field would
/// leave a free model no host. What was replaced is kept in
/// `AIFreeMode.savedSelectionsKey` and put back when the switch goes off.
extension FreeModelsSetup {
    /// The selections Free mode replaced. Codable so it can ride the synced
    /// preference rail, and restored through the same setters Settings uses.
    struct SavedSelections: Codable, Equatable {
        struct Route: Codable, Equatable {
            let provider: String
            let model: String
        }

        var defaultChat: Route
        var background: Route
        var backgroundMultimodal: Route
        var textToSpeechOpenRouterModel: String
        var textToSpeechModel: String
        var deniedDataCollection: Bool
        /// Every setting's backup models (`AIBackupModels`), by slot. Nil in
        /// what builds before backups saved; their backups are left alone.
        var backups: [String: [Route]]? = nil
        /// Docs' own model (`KeychainService.docsRoute`); nil when Docs
        /// followed the Default Model, or in what builds before it saved.
        var docs: Route? = nil

        @MainActor
        static func capture() -> SavedSelections {
            let chatProvider = KeychainService.aiProvider
            let background = KeychainService.displayedBackgroundTaskRoute
            let multimodal = KeychainService.displayedBackgroundMultimodalTaskRoute
            return SavedSelections(
                defaultChat: Route(provider: chatProvider.rawValue, model: KeychainService.model(for: chatProvider)),
                background: Route(provider: background.provider.rawValue, model: background.model),
                backgroundMultimodal: Route(provider: multimodal.provider.rawValue, model: multimodal.model),
                textToSpeechOpenRouterModel: MacArticleSpeechSettings.openRouterModel,
                textToSpeechModel: ArticleSpeechSelection.modelID(),
                deniedDataCollection: AIDataPolicy.deniesDataCollection,
                backups: AIBackupModels.allStored().mapValues { routes in
                    routes.map { Route(provider: $0.provider.rawValue, model: $0.model) }
                },
                docs: KeychainService.docsRoute.map { Route(provider: $0.provider.rawValue, model: $0.model) }
            )
        }

        /// Puts each selection back when its model is still offered; one that
        /// was retired while Free mode was on keeps the free model it has.
        /// Runs after the switch is off, so the catalog offers paid models again.
        @MainActor
        func restore() {
            if let provider = AIProvider(rawValue: defaultChat.provider),
               let entry = AIModelCatalog.entry(provider: provider, modelID: defaultChat.model) {
                AIModelCatalog.setDefault(entry)
            }
            if let provider = AIProvider(rawValue: background.provider) {
                KeychainService.setBackgroundTaskRoute(provider: provider, model: background.model)
            }
            if let provider = AIProvider(rawValue: backgroundMultimodal.provider) {
                KeychainService.setBackgroundMultimodalTaskRoute(provider: provider, model: backgroundMultimodal.model)
            }
            if let docs, let provider = AIProvider(rawValue: docs.provider),
               AIModelCatalog.entry(provider: provider, modelID: docs.model) != nil {
                KeychainService.setDocsRoute(AITaskModelRoute(provider: provider, model: docs.model))
            }
            if ArticleSpeechCatalog.model(id: textToSpeechOpenRouterModel) != nil {
                MacArticleSpeechSettings.openRouterModel = textToSpeechOpenRouterModel
            }
            if ArticleSpeechCatalog.model(id: textToSpeechModel) != nil {
                ArticleSpeechSelection.selectModel(textToSpeechModel)
            }
            if let backups {
                let slots = Set(backups.keys).union(AIBackupModels.allStored().keys)
                for slot in slots {
                    let routes = (backups[slot] ?? []).compactMap { route in
                        AIProvider(rawValue: route.provider).map { AITaskModelRoute(provider: $0, model: route.model) }
                    }
                    AIBackupModels.set(routes, slot: slot)
                }
            }
            if deniedDataCollection, !AIDataPolicy.deniesDataCollection {
                PreferenceStore.set(true, forKey: AIDataPolicy.denyDataCollectionKey)
                AIModelCatalog.dataPolicyDidChange()
            }
        }
    }

    /// Turns Free mode on and returns the free models chosen. Needs the
    /// learner's own OpenRouter key, since free models never run on
    /// ForeverLM's, and a plan, without which the proxy refuses that key.
    @MainActor
    @discardableResult
    static func enableFreeMode() async throws -> Choice {
        guard ManagedAI.ownKeyRouter == .openRouter else { throw Failure.needsOpenRouterKey }
        guard ManagedAI.ownKeyAllowed else { throw Failure.needsPlan }
        // Captured before anything moves; a second call while on keeps the
        // first capture, which holds the learner's own picks.
        let saved = AIFreeMode.isOn ? nil : SavedSelections.capture()
        let choice = try await apply()
        if AIDataPolicy.deniesDataCollection {
            PreferenceStore.set(false, forKey: AIDataPolicy.denyDataCollectionKey)
            AIModelCatalog.dataPolicyDidChange()
        }
        if let saved, let data = try? JSONEncoder().encode(saved) {
            PreferenceStore.set(data, forKey: AIFreeMode.savedSelectionsKey)
        }
        PreferenceStore.set(true, forKey: AIFreeMode.enabledKey)
        AIModelCatalog.freeModeDidChange()
        return choice
    }

    /// Turns Free mode off and puts back the selections it replaced.
    @MainActor
    static func disableFreeMode() {
        let saved = UserDefaults.standard.data(forKey: AIFreeMode.savedSelectionsKey)
            .flatMap { try? JSONDecoder().decode(SavedSelections.self, from: $0) }
        PreferenceStore.set(false, forKey: AIFreeMode.enabledKey)
        PreferenceStore.remove(forKey: AIFreeMode.savedSelectionsKey)
        saved?.restore()
        AIModelCatalog.freeModeDidChange()
    }
}

/// The Free mode switch, with what it gives up said plainly: before it goes
/// on, in a confirmation that lists every trade-off, and for as long as it is
/// on, under the switch. Lives in Settings › AI Usage, under the OpenRouter
/// key it can go on only with; the plan it also needs is Settings › Billing.
struct FreeModeSettingsView: View {
    @State private var isOn = AIFreeMode.isOn
    @State private var hasOpenRouterKey = ManagedAI.ownKeyRouter == .openRouter
    @State private var hasPlan = ManagedAI.ownKeyAllowed
    @State private var confirming = false
    @State private var working = false
    @State private var chosen: FreeModelsSetup.Choice?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(AIFreeMode.switchTitle, isOn: Binding(
                get: { isOn },
                set: { wantsOn in
                    if wantsOn {
                        confirming = true
                    } else {
                        FreeModelsSetup.disableFreeMode()
                        chosen = nil
                        errorText = nil
                        refresh()
                    }
                }
            ))
            .disabled(working || (!isOn && !(hasOpenRouterKey && hasPlan)))
            .accessibilityIdentifier("settings.ai.freeMode")

            Text(AIFreeMode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !isOn, !(hasOpenRouterKey && hasPlan) {
                Text(hasOpenRouterKey ? "Needs a ForeverLM plan." : "Needs your own OpenRouter key and a ForeverLM plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if working {
                ProgressView().controlSize(.small)
            }

            if isOn {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AIFreeMode.tradeoffs, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let chosen {
                        Text(chosen.chat.id == chosen.background.id
                            ? "Chat and background work use \(chosen.chat.name)."
                            : "Chat uses \(chosen.chat.name), background work \(chosen.background.name).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label(FreeModelsSetup.recommendation, systemImage: "hand.thumbsup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Allow free models in your OpenRouter privacy settings", destination: FreeModelsSetup.openRouterPrivacyURL)
                        .font(.caption)
                    Link("Each free model's terms on OpenRouter", destination: AIFreeMode.openRouterFreeModelsURL)
                        .font(.caption)
                }
                .padding(.top, 2)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Turn on Free mode?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Turn On Free Mode") { enable() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AIFreeMode.confirmationMessage(turnsOffDataPolicySwitch: AIDataPolicy.deniesDataCollection))
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderDidChange).receive(on: RunLoop.main)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .managedAIOwnKeyDidChange).receive(on: RunLoop.main)) { _ in
            refresh()
        }
    }

    private func refresh() {
        isOn = AIFreeMode.isOn
        hasOpenRouterKey = ManagedAI.ownKeyRouter == .openRouter
        hasPlan = ManagedAI.ownKeyAllowed
    }

    private func enable() {
        working = true
        errorText = nil
        Task { @MainActor in
            defer {
                working = false
                refresh()
            }
            do {
                chosen = try await FreeModelsSetup.enableFreeMode()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Price watch

/// Tells the learner when a model they use starts costing money or costs more
/// (product owner, 2026-09-25: free models may be free only for a limited time, and
/// a model going from free to paid, or up in price, is shown as a
/// notification). Every read of OpenRouter's directory
/// (`AIModelPriceRefresher.ingest`: at launch, on app activation, when a
/// picker opens, and after a refusal under Free mode's zero price cap) is
/// compared with the prices the previous read recorded for the models the
/// learner's settings name: the chat default, both Background defaults and
/// every task's resolved model. Each change raises one banner for that model,
/// which opens Settings › Chat. The first read of a model only records it.
/// A free model that ended is swapped for another free one first, and the
/// banner says what moved; when nothing could move, the banner asks, and its
/// Switch to a Free Model action tries again against a fresh directory read.
enum AIModelPriceWatch {
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

    /// Device-local, like the price table it sits beside: each Mac reads the
    /// directory and notifies for itself.
    static let recordKey = "aiModelPriceWatch.lastSeen.v1"
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

    /// Compares one directory read with the previous record. Returns the
    /// changes to announce and the record to keep: only watched models, a
    /// paid model missing from one read kept as it was, a free one that
    /// vanished reported once and then forgotten.
    static func compare(
        watched: Set<String>,
        previous: [String: Seen],
        directory: [OpenRouterDirectoryModel]
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
                }
                continue
            }
            let now = Seen(name: row.name, input: input, output: output)
            record[key] = now
            guard let before else { continue }
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
        let changes: [Change] = lock.withLock {
            let previous = UserDefaults.standard.data(forKey: recordKey)
                .flatMap { try? JSONDecoder().decode([String: Seen].self, from: $0) } ?? [:]
            let result = compare(watched: watched, previous: previous, directory: directory)
            if result.record != previous, let data = try? JSONEncoder().encode(result.record) {
                UserDefaults.standard.set(data, forKey: recordKey)
            }
            return result.changes
        }
        guard !changes.isEmpty else { return }
        let freeModeOn = AIFreeMode.isOn
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
                await deliver(change, freeModeOn: freeModeOn)
            }
        }
    }

    /// OpenRouter refused a free model as limited to the apps it lists. Called
    /// once per model (`AIFreeModelRestrictions.record` says when it is new):
    /// the settings on it move to another free model, as for a free period
    /// that ended, and the banner asks only when nothing could move.
    static func observeRestriction(_ modelID: String) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let freeModeOn = AIFreeMode.isOn
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
            await deliver(change, freeModeOn: freeModeOn)
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
        sentences.append("Change it in \(AIFreeMode.modelsLocation).")
        return sentences.joined(separator: " ")
    }

    static func title(for change: Change) -> String {
        switch change {
        case .noLongerFree(_, let name, _), .freeVariantEnded(_, let name): "\(name) is no longer free"
        case .moreExpensive(_, let name, _, _): "\(name) now costs more"
        case .limitedToListedApps(_, let name): "\(name) is no longer free in ForeverLM"
        }
    }

    static func body(for change: Change, freeModeOn: Bool) -> String {
        let next = freeModeOn
            ? "Free mode will not use it. Switch to another free model?"
            : "Work that uses it now costs money. Switch to another free model?"
        switch change {
        case .noLongerFree(_, _, let now):
            return "OpenRouter now charges \(AIModelListPrice.pairLabel(input: now.input, output: now.output)) per million tokens in/out. \(next)"
        case .freeVariantEnded:
            return "OpenRouter stopped offering it for free. \(next)"
        case .limitedToListedApps:
            return "OpenRouter now offers it only inside the apps it lists, so every request from ForeverLM fails. Switch to another free model?"
        case .moreExpensive(_, _, let from, let to):
            return "Now \(AIModelListPrice.pairLabel(input: to.input, output: to.output)) per million tokens in/out, up from \(AIModelListPrice.pairLabel(input: from.input, output: from.output)). Change it in \(AIFreeMode.modelsLocation) if that is too much."
        }
    }

    /// Delivered at once, one banner per model: a later change to the same
    /// model replaces it. Asks for permission the first time, since the
    /// learner has something worth knowing right now.
    static func deliver(_ change: Change, freeModeOn: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = title(for: change)
        content.body = body(for: change, freeModeOn: freeModeOn)
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
        try? await center.add(request)
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
