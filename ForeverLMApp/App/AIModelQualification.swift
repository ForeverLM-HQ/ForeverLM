import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Mac's half of `AIModelQualification` (`Shared/Services/AI/AIModelQualificationCore.swift`
/// holds the records and the rules both apps share): its probes through
/// `AIService` and `MacArticleTTSClient`, the sweep of the settings in use,
/// and the pickers' wording.
extension AIModelQualification {
    /// The OpenRouter slug a provider + model selection is sent as.
    static func slug(provider: AIProvider, model: String) -> String {
        normalized(AIService.openAICompatibleModelID(provider: provider, model: model))
    }

    static func isPassed(provider: AIProvider, model: String, role: Role) -> Bool {
        isPassed(slug: slug(provider: provider, model: model), role: role)
    }

    static func isKnownToFail(provider: AIProvider, model: String, role: Role) -> Bool {
        isKnownToFail(slug: slug(provider: provider, model: model), role: role)
    }

    // MARK: Verdicts

    /// Whether a failed test says something about the model rather than about
    /// the moment, the account or the connection. Nil means inconclusive.
    static func failureVerdict(for error: Error) -> String? {
        if AITransientErrorClassifier.isCancellation(error) || AITransientErrorClassifier.isTransient(error) {
            return nil
        }
        let message = error.localizedDescription
        // The learner's OpenRouter privacy settings refuse every free model
        // alike; setup asks about that separately (`FreeModelAccess`).
        if AIDataPolicy.isTrainingPolicyRefusal(message) || AIDataPolicy.isDataPolicyRefusal(message) {
            return nil
        }
        guard let aiError = error as? AIError else { return nil }
        switch aiError {
        case .httpError(let status, let message, _):
            // 401 is the key, 402 the balance, 408 and 429 the moment.
            guard (400..<500).contains(status), ![401, 402, 408, 429].contains(status) else { return nil }
            return message
        case .invalidResponse:
            return "It answered with something ForeverLM could not read."
        case .apiError(let message):
            // A stream's in-band error is the model refusing the request.
            return message
        // A router's pick of a safety classifier says nothing of the model
        // under test (and is transient, so it never reaches here).
        case .missingAPIKey, .outputTokenLimit, .serviceUnreachable, .emptyAnswer, .safetyClassifierAnswer:
            return nil
        }
    }

    // MARK: Probes

    /// Whether this Mac may spend a request on a test right now: the same
    /// gates a background task's config passes.
    static var canTest: Bool {
        ManagedAI.isSignedIn
            && !AICreditEntitlement.isOutOfCredits
            && KeychainService.isAIUsageAllowed(for: .paperMetadata)
            && KeychainService.apiKey(for: .openRouter) != nil
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    #if DEBUG
    /// A config for a named OpenRouter model on this Mac's key, labelled for
    /// `task`, for a DEBUG eval that measures candidate models on that task's
    /// real request (`KnowledgeMapVoice+Eval.swift`). It picks no model.
    static func evalConfig(model: String, task: AITask) -> AITaskConfig? {
        guard let apiKey = KeychainService.apiKey(for: .openRouter) else { return nil }
        var config = AITaskConfig(provider: .openRouter, apiKey: apiKey, model: model)
        config.taskLabel = task.rawValue
        return config
    }
    #endif

    /// One small request of the role's shape. Throws what the request threw.
    static func probe(provider: AIProvider, model: String, role: Role) async throws {
        guard let apiKey = KeychainService.apiKey(for: provider) ?? KeychainService.apiKey(for: .openRouter) else {
            throw AIError.missingAPIKey
        }
        var config = AITaskConfig(provider: provider, apiKey: apiKey, model: model)
        config.taskLabel = taskLabel
        let service = AIService()
        switch role {
        case .chat:
            let tool = AIToolSpec(
                name: "look_up_word",
                description: "Looks a word up in the learner's library.",
                inputSchema: [
                    "type": "object",
                    "properties": ["word": ["type": "string"]],
                    "required": ["word"],
                ]
            )
            _ = try await service.streamChatWithTools(
                config: config,
                system: "You are a terse tutor. Answer in one word.",
                turns: [.user("Say OK.")],
                tools: [tool],
                maxTokens: 512,
                onTextDelta: { _ in }
            )
        case .background, .backgroundImages:
            let image = role == .backgroundImages ? probeImageJPEG : nil
            let user = image == nil
                ? "Say OK."
                : "Which colour fills this picture? One word."
            let reply = try await service.call(
                config: config,
                system: #"Reply with a JSON object {"answer": "<one word>"} and nothing else."#,
                user: user,
                maxTokens: 512,
                temperature: 0,
                imageJPEGData: image,
                disablesReasoning: true,
                allowsResponseCache: false,
                jsonMode: true
            )
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AIError.invalidResponse
            }
        case .speech:
            try await speechProbe(model: model, voice: resolvedSpeechVoice(model: model, voice: ""))
        }
    }

    /// A 16-pixel red square: the smallest picture every vision endpoint takes.
    static let probeImageJPEG: Data? = {
        let size = 16
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }()

    /// Tests one model for one role and records the verdict. Returns the
    /// status afterwards: unchanged when the test was inconclusive or could
    /// not run.
    @discardableResult
    static func qualify(provider: AIProvider, model: String, role: Role, force: Bool = false) async -> Status {
        if role == .speech {
            return await qualifySpeech(model: model, voice: "", force: force)
        }
        return await qualify(
            slug: Self.slug(provider: provider, model: model),
            role: role,
            force: force,
            canTest: canTest,
            verdict: failureVerdict(for:),
            probe: { try await probe(provider: provider, model: model, role: role) }
        )
    }

    // MARK: Text to speech

    /// One short synthesis through the client playback uses: the model's
    /// catalogued response format, this voice, the learner's own key or the
    /// managed rail. The number keeps the audio cache from answering.
    static func speechProbe(model: String, voice: String) async throws {
        let text = "This is a short test, number \(Int.random(in: 1000...9999))."
        _ = try await AIUsageAttribution.$task.withValue(taskLabel) {
            // Listed for the background-work list, where Stop cancels it.
            try await AIInFlightCalls.current.track(step: taskLabel) { _ in
                try await MacArticleTTSClient.openRouter(text: text, voice: voice, model: model)
            }
        }
    }

    /// Whether a failed synthesis says something about the model or its
    /// voice. Only a refusal of what the request names (`modelRefused`) or
    /// audio that never played counts; the key, the balance, the network, a
    /// busy endpoint and the learner's privacy settings leave it untested.
    static func speechFailureVerdict(for error: Error) -> String? {
        guard let error = error as? MacArticleTTSError else { return nil }
        switch error {
        case .modelRefused(_, _, let reason):
            if AIDataPolicy.isTrainingPolicyRefusal(reason) || AIDataPolicy.isDataPolicyRefusal(reason) {
                return nil
            }
            return reason
        case .unplayableAudio(_, let message):
            return message
        case .missingAPIKey, .badResponse, .providerRejected, .networkUnavailable:
            return nil
        }
    }

    /// Tests one model in one voice and records the verdict.
    @discardableResult
    static func qualifySpeech(model: String, voice: String, force: Bool = false) async -> Status {
        let voice = resolvedSpeechVoice(model: model, voice: voice)
        return await qualify(
            slug: speechSlug(model: model, voice: voice),
            role: .speech,
            force: force,
            canTest: canTest,
            verdict: speechFailureVerdict(for:),
            probe: { try await speechProbe(model: model, voice: voice) }
        )
    }

    /// The test a text-to-speech pick runs before it is applied: in Settings
    /// › Voice and over MCP. Like `testBeforeSelecting`, except that a free
    /// model whose test could not finish is applied anyway.
    static func testSpeechBeforeSelecting(model: String, voice: String) async -> SelectionVerdict {
        let voice = resolvedSpeechVoice(model: model, voice: voice)
        let verdict = await speechSelectionVerdict(
            slug: speechSlug(model: model, voice: voice),
            isFree: OpenRouterAudioPrices.price(for: model, kind: .speech)?.isFree == true,
            canTest: canTest,
            probe: { try await speechProbe(model: model, voice: voice) }
        )
        if verdict != .retryLater { await announceChange() }
        return verdict
    }

    /// `testSpeechBeforeSelecting` with what it reads passed in, reading a
    /// failed synthesis as the Mac's client reports it.
    static func speechSelectionVerdict(
        slug: String,
        isFree: Bool,
        canTest: Bool,
        defaults: UserDefaults = .standard,
        probe: () async throws -> Void
    ) async -> SelectionVerdict {
        await speechSelectionVerdict(
            slug: slug,
            isFree: isFree,
            canTest: canTest,
            defaults: defaults,
            verdict: speechFailureVerdict(for:),
            probe: probe
        )
    }

    /// What `set_app_setting` answers when a text-to-speech pick was not
    /// applied: the same rule as the pane, said to the client.
    static func speechSettingRefusalText(name: String, verdict: SelectionVerdict) -> String? {
        switch verdict {
        case .go:
            return nil
        case .refused(let message):
            return "\(name) failed a test run just now, so it was not applied. It stays in the list; ask again to run the test again. OpenRouter said: \(message)"
        case .retryLater:
            return "\(name) could not be tested just now (OpenRouter was busy or unreachable), and a priced text-to-speech model is applied only after it passes. Try again in a minute."
        }
    }

    /// Before a text-to-speech request goes out: starts a test of the pick
    /// when it is due, in the background. This is how a free model applied
    /// while its test could not finish is tested when next used.
    static func testSpeechWhenDue(model: String, voice: String) {
        let voice = resolvedSpeechVoice(model: model, voice: voice)
        guard needsTest(slug: speechSlug(model: model, voice: voice), role: .speech), canTest else { return }
        Task.detached(priority: .utility) {
            let before = speechStatus(model: model, voice: voice)
            if await qualifySpeech(model: model, voice: voice) != before { await announceChange() }
        }
    }

    /// After playback met a refusal of the model or its audio: tests the pair
    /// again in the background, so the verdict, not one chunk's failure,
    /// decides whether a repair skips it. Nothing when it was tested in the
    /// last few minutes.
    static func recheckSpeechAfterRefusal(model: String, voice: String) {
        let voice = resolvedSpeechVoice(model: model, voice: voice)
        if let record = record(slug: speechSlug(model: model, voice: voice), role: .speech),
           Date().timeIntervalSince(record.testedAt) < 5 * 60 {
            return
        }
        guard canTest else { return }
        Task.detached(priority: .utility) {
            await qualifySpeech(model: model, voice: voice, force: true)
            await announceChange()
        }
    }

    /// The roles a catalogue entry is tested for.
    static func roles(provider: AIProvider, model: String) -> [Role] {
        KeychainService.modelSupportsVision(provider: provider, model: model) == true
            ? [.chat, .background, .backgroundImages]
            : [.chat, .background]
    }

    /// One model a setting sends work to, and the test that work needs.
    struct InUse: Equatable, Sendable {
        let provider: AIProvider
        let model: String
        let role: Role
        /// The text-to-speech voice; nil for the other roles.
        var voice: String?

        var slug: String {
            role == .speech
                ? speechSlug(model: model, voice: voice ?? "")
                : AIModelQualification.slug(provider: provider, model: model)
        }
    }

    /// The settings' models, each for the work it does: the chat default,
    /// both Background models and, when it is an OpenRouter model, the
    /// text-to-speech pick in its voice.
    static func inUse(
        chat: AITaskModelRoute,
        background: AITaskModelRoute,
        backgroundImages: AITaskModelRoute,
        speech: (model: String, voice: String)?
    ) -> [InUse] {
        var list = [
            InUse(provider: chat.provider, model: chat.model, role: .chat),
            InUse(provider: background.provider, model: background.model, role: .background),
            InUse(provider: backgroundImages.provider, model: backgroundImages.model, role: .backgroundImages),
        ]
        if let speech {
            list.append(InUse(provider: .openRouter, model: speech.model, role: .speech, voice: speech.voice))
        }
        return list
    }

    /// Those whose verdict is due, each once.
    static func dueInUse(_ list: [InUse], now: Date = Date(), defaults: UserDefaults = .standard) -> [InUse] {
        var seen: Set<String> = []
        return list.filter { item in
            let id = item.slug
            return !id.isEmpty
                && seen.insert(key(slug: id, role: item.role)).inserted
                && needsTest(slug: id, role: item.role, now: now, defaults: defaults)
        }
    }

    /// Asks again about the models the settings already send work to, when
    /// their verdict is due. A handful of requests, never the catalogue.
    static func sweepInUse() async {
        guard canTest else { return }
        let chatProvider = KeychainService.aiProvider
        var speech: (model: String, voice: String)?
        if MacArticleSpeechSettings.provider == .openRouter {
            // The voice resolves against OpenRouter's speech list.
            await OpenRouterAudioDirectory.prepare(.speech)
            speech = (MacArticleSpeechSettings.openRouterModel, MacArticleSpeechSettings.openRouterVoice)
        }
        await run(dueInUse(inUse(
            chat: AITaskModelRoute(provider: chatProvider, model: KeychainService.model(for: chatProvider)),
            background: KeychainService.displayedBackgroundTaskRoute,
            backgroundImages: KeychainService.displayedBackgroundMultimodalTaskRoute,
            speech: speech
        )))
    }

    /// The on-the-spot test a first selection runs. A model that already
    /// passed goes straight through. One that failed before is tested again
    /// rather than refused on its old verdict.
    static func testBeforeSelecting(provider: AIProvider, model: String, role: Role) async -> SelectionVerdict {
        let retest = isKnownToFail(provider: provider, model: model, role: role)
        switch await qualify(provider: provider, model: model, role: role, force: retest) {
        case .passed:
            await announceChange()
            return .go
        case .failed(let message):
            await announceChange()
            return .refused(message)
        case .untested:
            return canTest ? .retryLater : .go
        }
    }

    /// The sentence a picker shows when a pick was not applied.
    static func refusalText(name: String, role: Role, verdict: SelectionVerdict) -> String? {
        switch verdict {
        case .go:
            return nil
        case .refused(let message):
            return "\(name) failed a test run of \(role.label), so it was not selected. It stays in the list; choose it again to run the test again. OpenRouter said: \(message)"
        case .retryLater:
            return "\(name) could not be tested just now (OpenRouter was busy or unreachable), and a model is used only once it passes. Try again in a moment."
        }
    }

    /// Before a free model is picked automatically (setup, the replacement
    /// of one that ended), tests the free models in the order the
    /// pick ranks them until one per role passes, so the pick lands on a
    /// model that ran. Usually one request per role: the first candidate.
    static func qualifyFreeCandidates(from directory: [OpenRouterDirectoryModel], wanted: Int = 1) async {
        guard canTest else { return }
        await qualifyUntilPassed(FreeModelsSetup.rankedFreeForChat(from: directory), role: .chat, wanted: wanted)
        await qualifyUntilPassed(FreeModelsSetup.rankedFree(needsVision: false, from: directory), role: .background, wanted: wanted)
        await qualifyUntilPassed(FreeModelsSetup.rankedFree(needsVision: true, from: directory), role: .backgroundImages, wanted: wanted)
    }

    private static func qualifyUntilPassed(_ models: [OpenRouterDirectoryModel], role: Role, wanted: Int) async {
        var passed = 0
        var changed = false
        for model in models {
            if passed >= wanted { break }
            let before = record(slug: model.id, role: role)
            let verdict = await qualify(provider: .openRouter, model: model.id, role: role)
            if record(slug: model.id, role: role) != before { changed = true }
            if verdict == .passed { passed += 1 }
        }
        if changed { await announceChange() }
    }

    private static func run(_ items: [InUse]) async {
        guard !items.isEmpty else { return }
        let width = 4
        await withTaskGroup(of: Void.self) { group in
            for (index, item) in items.enumerated() {
                if index >= width { await group.next() }
                group.addTask {
                    if item.role == .speech {
                        _ = await qualifySpeech(model: item.model, voice: item.voice ?? "")
                    } else {
                        _ = await qualify(provider: item.provider, model: item.model, role: item.role)
                    }
                }
            }
        }
        await announceChange()
    }

    @MainActor
    private static func announceChange() {
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    // MARK: Picker notes

    /// Why a selection failed its last test, for the line under its picker;
    /// nil when it passed or has not been tested yet.
    static func failureMessage(provider: AIProvider, model: String, role: Role) -> String? {
        if case .failed(let message) = status(slug: slug(provider: provider, model: model), role: role) {
            return message
        }
        return nil
    }
}

extension AITask {
    /// Which test a model runs before a picker applies it to this task: the
    /// streaming tasks send the chat's request, the others a one-shot.
    var qualificationRole: AIModelQualification.Role {
        switch self {
        case .chat, .deepResearch, .sourceDiscovery, .citationResolution, .mobileReview, .mobileVoiceAgent:
            return .chat
        default:
            return requiresVision ? .backgroundImages : .background
        }
    }
}
