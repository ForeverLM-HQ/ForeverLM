import Foundation
import Testing
@testable import ForeverLM

@Suite("Model qualification")
struct AIModelQualificationTests {
    private func defaults() -> UserDefaults {
        let suite = "AIModelQualificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func model(_ id: String, vision: Bool = false) -> OpenRouterDirectoryModel {
        OpenRouterDirectoryModel(
            id: id,
            name: id,
            inputUSDPerMTokens: 0,
            outputUSDPerMTokens: 0,
            contextLength: 131_072,
            price: nil,
            supportsTools: true,
            supportsTemperature: true,
            supportsVision: vision
        )
    }

    @Test("A refusal about the model fails it; the moment, the key, the balance and the account do not")
    func failureVerdicts() {
        let harness = AIError.httpError(
            status: 403,
            message: "thinkingmachines/inkling-small:free is only available on agentic harnesses. [OpenRouter request failed (403)]",
            retryAfterSeconds: nil
        )
        #expect(AIModelQualification.failureVerdict(for: harness)?.contains("agentic harnesses") == true)
        let parameter = AIError.httpError(status: 400, message: "Reasoning is mandatory for this endpoint and cannot be disabled.", retryAfterSeconds: nil)
        #expect(AIModelQualification.failureVerdict(for: parameter) != nil)
        #expect(AIModelQualification.failureVerdict(for: AIError.invalidResponse) != nil)

        for status in [401, 402, 408, 429, 500, 503] {
            #expect(AIModelQualification.failureVerdict(
                for: AIError.httpError(status: status, message: "nope", retryAfterSeconds: nil)
            ) == nil, "status \(status) says nothing about the model")
        }
        #expect(AIModelQualification.failureVerdict(for: CancellationError()) == nil)
        #expect(AIModelQualification.failureVerdict(for: AIError.serviceUnreachable("offline")) == nil)
        #expect(AIModelQualification.failureVerdict(for: AIError.httpError(
            status: 404,
            message: "No endpoints found matching your data policy (Free model publication)",
            retryAfterSeconds: nil
        )) == nil, "the learner's OpenRouter privacy settings refuse every free model alike")
    }

    @Test("Verdicts are kept per model and role, and fall due again")
    func store() {
        let defaults = defaults()
        let slug = "Z-AI/GLM-5.3-Flash"
        #expect(AIModelQualification.status(slug: slug, role: .background, defaults: defaults) == .untested)
        #expect(AIModelQualification.needsTest(slug: slug, role: .background, defaults: defaults))

        let now = Date()
        AIModelQualification.store(.init(passed: true, message: nil, testedAt: now), slug: slug, role: .background, defaults: defaults)
        AIModelQualification.store(.init(passed: false, message: "no tools", testedAt: now), slug: slug, role: .chat, defaults: defaults)

        #expect(AIModelQualification.isPassed(slug: "z-ai/glm-5.3-flash", role: .background, defaults: defaults))
        #expect(AIModelQualification.status(slug: slug, role: .chat, defaults: defaults) == .failed("no tools"))
        #expect(AIModelQualification.status(slug: slug, role: .backgroundImages, defaults: defaults) == .untested)

        #expect(!AIModelQualification.needsTest(slug: slug, role: .background, now: now, defaults: defaults))
        #expect(AIModelQualification.needsTest(
            slug: slug, role: .chat,
            now: now.addingTimeInterval(AIModelQualification.failureLifetime + 1), defaults: defaults
        ), "a failure is asked again after a day")
        #expect(!AIModelQualification.needsTest(
            slug: slug, role: .background,
            now: now.addingTimeInterval(AIModelQualification.failureLifetime + 1), defaults: defaults
        ), "a pass lasts longer than a failure")
        #expect(AIModelQualification.needsTest(
            slug: slug, role: .background,
            now: now.addingTimeInterval(AIModelQualification.passLifetime + 1), defaults: defaults
        ))
    }

    @Test("Only a failed test counts as a known failure; a pass or no verdict does not")
    func knownToFail() {
        let defaults = defaults()
        #expect(!AIModelQualification.isKnownToFail(slug: "x/y", role: .chat, defaults: defaults))
        AIModelQualification.store(.init(passed: true, message: nil, testedAt: Date()), slug: "x/y", role: .chat, defaults: defaults)
        #expect(!AIModelQualification.isKnownToFail(slug: "x/y", role: .chat, defaults: defaults))
        AIModelQualification.store(.init(passed: false, message: "403", testedAt: Date()), slug: "x/y", role: .chat, defaults: defaults)
        #expect(AIModelQualification.isKnownToFail(slug: "x/y", role: .chat, defaults: defaults))
    }

    @Test("A pick that was not applied says why")
    func refusalText() {
        #expect(AIModelQualification.refusalText(name: "Inkling", role: .background, verdict: .go) == nil)
        let refused = AIModelQualification.refusalText(name: "Inkling", role: .background, verdict: .refused("only on agentic harnesses"))
        #expect(refused?.contains("Inkling failed a test run of background work") == true)
        #expect(refused?.contains("only on agentic harnesses") == true)
        #expect(refused?.contains("no longer offered") == false, "a failed model stays in the pickers")
        #expect(refused?.contains("choose it again") == true)
        #expect(AIModelQualification.refusalText(name: "Inkling", role: .chat, verdict: .retryLater)?.contains("Try again") == true)
    }

    @Test("Free picks skip a model that failed the role it would fill")
    func freePicksNeedAPass() throws {
        let directory = [
            model("google/gemma-4-31b-it:free", vision: true),
            model("google/gemma-4-26b-a4b-it:free"),
            model("thinkingmachines/inkling-small:free"),
        ]
        let refused: Set<String> = ["google/gemma-4-26b-a4b-it:free|background", "google/gemma-4-31b-it:free|background_images"]
        let qualifies: FreeModelsSetup.Qualifies = { id, role in !refused.contains("\(id)|\(role.rawValue)") }

        let choice = try #require(FreeModelsSetup.choose(from: directory, qualifies: qualifies))
        #expect(choice.chat.id == "google/gemma-4-31b-it:free")
        #expect(choice.background.id != "google/gemma-4-26b-a4b-it:free", "the preferred background model failed")
        #expect(choice.vision == nil, "the only model that reads images failed that test")

        #expect(!FreeModelsSetup.candidates(needsVision: false, from: directory, qualifies: qualifies)
            .map(\.id).contains("google/gemma-4-26b-a4b-it:free"))
        #expect(FreeModelsSetup.rankedFree(needsVision: false, from: directory).count == 3,
                "the ranking itself still lists every free model, for the tests to run on")
        #expect(FreeModelsSetup.rankedFreeForChat(from: directory).first?.id == "google/gemma-4-31b-it:free",
                "the chat ranking leads with the chat pick's own preference")
        #expect(FreeModelsSetup.choose(from: directory, qualifies: { _, _ in false }) == nil)
    }

    @Test("Streaming tasks need the chat's test; the rest need background work's, or its image variant")
    func taskRoles() {
        #expect(AITask.chat.qualificationRole == .chat)
        #expect(AITask.deepResearch.qualificationRole == .chat)
        #expect(AITask.paperMetadata.qualificationRole == .background)
        #expect(AITask.paperFigureUnderstanding.qualificationRole == .backgroundImages)
    }

    // MARK: Text to speech

    @Test("A text-to-speech test fails on a refusal of the model, its voice or its audio, never on the moment or the account")
    func speechFailureVerdicts() {
        let delisted = MacArticleTTSError.modelRefused(model: "deepgram/flux-tts:free", statusCode: 404, reason: "No endpoints found for deepgram/flux-tts:free.")
        #expect(AIModelQualification.speechFailureVerdict(for: delisted) == "No endpoints found for deepgram/flux-tts:free.")
        let format = MacArticleTTSError.modelRefused(model: "google/gemini-3.8-flash-tts", statusCode: 400, reason: "This model only supports response_format=pcm.")
        #expect(AIModelQualification.speechFailureVerdict(for: format)?.contains("response_format=pcm") == true)
        #expect(AIModelQualification.speechFailureVerdict(
            for: MacArticleTTSError.unplayableAudio(model: "x/y", message: "OpenRouter returned incomplete or corrupted speech after 4 attempts.")
        ) != nil)

        let inconclusive: [Error] = [
            MacArticleTTSError.modelRefused(model: "x/y:free", statusCode: 404, reason: "No endpoints found matching your data policy (Free model publication)"),
            MacArticleTTSError.badResponse("OpenRouter TTS failed (503): upstream busy"),
            MacArticleTTSError.providerRejected(provider: "OpenRouter", statusCode: 402, reason: "Insufficient credits."),
            MacArticleTTSError.missingAPIKey("ForeverLM AI"),
            MacArticleTTSError.networkUnavailable,
            CancellationError(),
            URLError(.timedOut),
        ]
        for error in inconclusive {
            #expect(AIModelQualification.speechFailureVerdict(for: error) == nil, "\(error.localizedDescription)")
        }
    }

    @Test("A text-to-speech verdict is kept per model and voice")
    func speechSlugs() {
        #expect(AIModelQualification.speechSlug(model: "Fish-Audio/S2.1-Pro", voice: "b347db") == "fish-audio/s2.1-pro#b347db")
        #expect(AIModelQualification.speechSlug(model: "deepgram/aura-2", voice: " ") == "deepgram/aura-2")
        #expect(AIModelQualification.speechSlug(model: "deepgram/aura-2", voice: "aura-2-thalia-en")
                != AIModelQualification.speechSlug(model: "deepgram/aura-2", voice: "aura-2-zeus-en"))
        #expect(AIModelQualification.Role.speech.label == "text to speech")
        #expect(AIModelQualification.Role(rawValue: "speech") == .speech)
    }

    private struct Refused: Error {}

    @Test("A text-to-speech pick is applied only once it passes; a refusal keeps the old one and choosing it again tests again")
    func speechSelection() async {
        let defaults = defaults()
        let slug = AIModelQualification.speechSlug(model: "test/\(UUID().uuidString)", voice: "jack")
        var calls = 0

        let refused = await AIModelQualification.speechSelectionVerdict(slug: slug, isFree: false, canTest: true, defaults: defaults) {
            calls += 1
            throw MacArticleTTSError.modelRefused(model: "test/model", statusCode: 400, reason: "Unknown voice jack.")
        }
        #expect(refused == .refused("Unknown voice jack."), "the pick is not applied")
        #expect(AIModelQualification.isKnownToFail(slug: slug, role: .speech, defaults: defaults))

        let again = await AIModelQualification.speechSelectionVerdict(slug: slug, isFree: false, canTest: true, defaults: defaults) {
            calls += 1
        }
        #expect(again == .go, "a failure is not final: choosing it again runs the test again")
        #expect(calls == 2)
        #expect(AIModelQualification.isPassed(slug: slug, role: .speech, defaults: defaults))

        let passed = await AIModelQualification.speechSelectionVerdict(slug: slug, isFree: false, canTest: true, defaults: defaults) {
            calls += 1
        }
        #expect(passed == .go)
        #expect(calls == 2, "a pass goes straight through")

        let text = AIModelQualification.speechRefusalText(name: "Jack (Deepgram Flux TTS Free)", verdict: refused)
        #expect(text == "Jack (Deepgram Flux TTS Free) failed a test run, so it was not selected. OpenRouter said: Unknown voice jack.")
        #expect(AIModelQualification.speechRefusalText(name: "Jack", verdict: .go) == nil)

        // set_app_setting answers the client with the same refusal.
        let answer = AIModelQualification.speechSettingRefusalText(name: "Jack (Deepgram Flux TTS Free)", verdict: refused)
        #expect(answer?.hasPrefix("Jack (Deepgram Flux TTS Free) failed a test run just now, so it was not applied.") == true)
        #expect(answer?.hasSuffix("OpenRouter said: Unknown voice jack.") == true)
        #expect(AIModelQualification.speechSettingRefusalText(name: "Jack", verdict: .retryLater)?.contains("Try again in a minute") == true)
        #expect(AIModelQualification.speechSettingRefusalText(name: "Jack", verdict: .go) == nil)
    }

    @Test("A text-to-speech test that cannot finish holds back a priced pick, not a free one")
    func speechTransientFailures() async {
        let defaults = defaults()
        let busy: () async throws -> Void = { throw MacArticleTTSError.badResponse("OpenRouter TTS failed (429): rate limited") }

        let paid = AIModelQualification.speechSlug(model: "test/\(UUID().uuidString)", voice: "")
        #expect(await AIModelQualification.speechSelectionVerdict(slug: paid, isFree: false, canTest: true, defaults: defaults, probe: busy) == .retryLater)
        #expect(AIModelQualification.status(slug: paid, role: .speech, defaults: defaults) == .untested,
                "nothing is recorded, so it is tested again")

        let free = AIModelQualification.speechSlug(model: "test/\(UUID().uuidString):free", voice: "")
        #expect(await AIModelQualification.speechSelectionVerdict(slug: free, isFree: true, canTest: true, defaults: defaults, probe: busy) == .go)
        #expect(AIModelQualification.status(slug: free, role: .speech, defaults: defaults) == .untested,
                "a free pick applied untested is tested when next used")

        var probed = false
        let offline = AIModelQualification.speechSlug(model: "test/\(UUID().uuidString)", voice: "")
        #expect(await AIModelQualification.speechSelectionVerdict(slug: offline, isFree: false, canTest: false, defaults: defaults) {
            probed = true
        } == .go, "a Mac that cannot test applies the pick, as for any model")
        #expect(!probed)
    }

    @Test("The settings in use include the text-to-speech pick, in its voice, when due")
    func sweepIncludesSpeech() {
        let defaults = defaults()
        let route = AITaskModelRoute(provider: .openRouter, model: "z-ai/glm-5.3-flash")
        let list = AIModelQualification.inUse(
            chat: route, background: route, backgroundImages: route,
            speech: (model: "deepgram/aura-2", voice: "aura-2-thalia-en")
        )
        let speech = AIModelQualification.InUse(provider: .openRouter, model: "deepgram/aura-2", role: .speech, voice: "aura-2-thalia-en")
        #expect(list.contains(speech))
        #expect(AIModelQualification.dueInUse(list, defaults: defaults).contains(speech))

        AIModelQualification.store(.init(passed: true, message: nil, testedAt: Date()), slug: speech.slug, role: .speech, defaults: defaults)
        #expect(!AIModelQualification.dueInUse(list, defaults: defaults).contains(speech), "a fresh pass is not asked again")

        #expect(!AIModelQualification.inUse(chat: route, background: route, backgroundImages: route, speech: nil)
            .contains { $0.role == .speech }, "an older provider's pick is not an OpenRouter model to test")
    }

    @Test("The image probe is a real JPEG")
    func probeImage() throws {
        let data = try #require(AIModelQualification.probeImageJPEG)
        #expect(data.starts(with: [0xFF, 0xD8]))
    }
}

@Suite("Text-to-speech pick repair")
struct TextToSpeechPickRepairTests {
    private let offered = ["fish-audio/s2.1-pro-free:free", "deepgram/aura-2", "google/gemini-3.1-flash-tts-preview"]
    private func voices(_ model: String) -> [String] {
        switch model {
        case "deepgram/aura-2": ["aura-2-thalia-en", "aura-2-zeus-en"]
        case "google/gemini-3.1-flash-tts-preview": ["Kore", "Puck"]
        default: ["b347db033a6549378b48d00acb0d06cd"]
        }
    }

    @Test("A pick still offered is kept, even one that failed its test")
    func keepsOfferedPick() {
        let pick = ArticleSpeechSelection.resolvedPick(
            storedModel: "deepgram/aura-2", storedVoice: "aura-2-zeus-en",
            offered: offered, voices: voices, failed: { _, _ in true }
        )
        #expect(pick.model == "deepgram/aura-2")
        #expect(pick.voice == "aura-2-zeus-en")
    }

    @Test("A vanished pick moves to the first offered model that has not failed, in a voice it offers")
    func repairsVanishedPick() {
        let failed: Set<String> = ["fish-audio/s2.1-pro-free:free|b347db033a6549378b48d00acb0d06cd"]
        let pick = ArticleSpeechSelection.resolvedPick(
            storedModel: "deepgram/flux-tts:free", storedVoice: "flux-jack-en",
            offered: offered, voices: voices, failed: { failed.contains("\($0)|\($1)") }
        )
        #expect(pick.model == "deepgram/aura-2", "the first offered model failed its test in the voice it would get")
        #expect(pick.voice == "aura-2-thalia-en")

        let kept = ArticleSpeechSelection.resolvedPick(
            storedModel: "google/gemini-3.8-flash-tts", storedVoice: "Puck",
            offered: ["deepgram/aura-2", "google/gemini-3.1-flash-tts-preview"], voices: voices,
            failed: { model, _ in model == "deepgram/aura-2" }
        )
        #expect(kept.model == "google/gemini-3.1-flash-tts-preview")
        #expect(kept.voice == "Puck", "a voice the new model offers is kept")

        let everyOneFailed = ArticleSpeechSelection.resolvedPick(
            storedModel: "deepgram/flux-tts:free", storedVoice: "flux-jack-en",
            offered: offered, voices: voices, failed: { _, _ in true }
        )
        #expect(everyOneFailed.model == offered[0], "with every model failed the first offered is used, as before")
    }

    @Test("The repair is said once, naming the model that went and the one in use")
    func repairNotice() {
        let repair = MacArticleSpeechSettings.SelectionRepair(
            oldModel: "deepgram/flux-tts:free",
            newModel: "fish-audio/s2.1-pro",
            newVoice: "b347db033a6549378b48d00acb0d06cd"
        )
        // The new pick's label reads the speech list this host last read.
        let label = ArticleSpeechCatalog.selectionLabel(model: "fish-audio/s2.1-pro", voice: "b347db033a6549378b48d00acb0d06cd")
        #expect(repair.message == "Deepgram Flux TTS Free is no longer offered; using \(label).")
        let unknown = MacArticleSpeechSettings.SelectionRepair(
            oldModel: "vendor/gone-tts",
            newModel: "fish-audio/s2.1-pro",
            newVoice: "b347db033a6549378b48d00acb0d06cd"
        )
        #expect(unknown.message.hasPrefix("vendor/gone-tts is no longer offered; using "))
        #expect(!repair.message.contains("Choose it again"))
    }

    @Test("Repairs in a row are said as one, from the model last heard; a round trip says nothing")
    func combinedRepairs() {
        typealias Repair = MacArticleSpeechSettings.SelectionRepair
        let first = Repair(oldModel: "vendor/a", newModel: "vendor/b", newVoice: "v1")
        let second = Repair(oldModel: "vendor/b", newModel: "vendor/c", newVoice: "v2")
        #expect(Repair.combined(nil, then: nil) == nil)
        #expect(Repair.combined(first, then: nil) == first, "a directory read's repair waits for the next use")
        #expect(Repair.combined(nil, then: second) == second)
        #expect(Repair.combined(first, then: second) == Repair(oldModel: "vendor/a", newModel: "vendor/c", newVoice: "v2"))
        let back = Repair(oldModel: "vendor/b", newModel: "vendor/a", newVoice: "v1")
        #expect(Repair.combined(first, then: back) == nil)
    }
}

@Suite("Text-to-speech pick on the iPhone")
struct PhoneTextToSpeechPickTests {
    private let offered = ["fish-audio/s2.1-pro-free:free", "deepgram/aura-2", "google/gemini-3.1-flash-tts-preview"]
    private func voices(_ model: String) -> [String] {
        switch model {
        case "deepgram/aura-2": ["aura-2-thalia-en", "aura-2-zeus-en"]
        case "google/gemini-3.1-flash-tts-preview": ["Kore", "Puck"]
        case "fish-audio/s2.1-pro-free:free": ["b347db033a6549378b48d00acb0d06cd"]
        default: []
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "PhoneTextToSpeechPickTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func modelKey() -> String { ArticleSpeechSelection.modelDefaultsKey }
    private func voiceKey(_ model: String) -> String { ArticleSpeechSelection.voiceDefaultsKey(forModel: model) }

    @Test("A pick OpenRouter stopped offering is repaired by the Mac's rule, written back and said once")
    func repairsVanishedPick() {
        let defaults = defaults()
        defaults.set("deepgram/flux-tts:free", forKey: modelKey())
        defaults.set("flux-jack-en", forKey: voiceKey("deepgram/flux-tts:free"))
        let failed: Set<String> = ["fish-audio/s2.1-pro-free:free|b347db033a6549378b48d00acb0d06cd"]

        let repair = ArticleSpeechSelection.repairStoredPick(
            defaults: defaults, offered: offered, isDirectoryBacked: true,
            voices: voices, failed: { failed.contains("\($0)|\($1)") }
        )
        #expect(repair == ArticleSpeechSelection.Repair(
            oldModel: "deepgram/flux-tts:free", newModel: "deepgram/aura-2", newVoice: "aura-2-thalia-en"
        ), "the first offered model failed its test in the voice it would get")
        #expect(defaults.string(forKey: modelKey()) == "deepgram/aura-2")
        #expect(defaults.string(forKey: voiceKey("deepgram/aura-2")) == "aura-2-thalia-en")
        #expect(repair?.message.hasPrefix("Deepgram Flux TTS Free is no longer offered; using ") == true)

        #expect(ArticleSpeechSelection.repairStoredPick(
            defaults: defaults, offered: offered, isDirectoryBacked: true,
            voices: voices, failed: { failed.contains("\($0)|\($1)") }
        ) == nil, "a repaired pick is offered, so the next use says nothing")
    }

    @Test("A pick missing from a list this device has not read is left alone")
    func leavesPickBeforeTheListIsRead() {
        let defaults = defaults()
        defaults.set("vendor/added-since-tts", forKey: modelKey())
        #expect(ArticleSpeechSelection.repairStoredPick(
            defaults: defaults, offered: offered, isDirectoryBacked: false,
            voices: voices, failed: { _, _ in false }
        ) == nil)
        #expect(defaults.string(forKey: modelKey()) == "vendor/added-since-tts")
    }

    @Test("Nothing stored reads as the default model, which is repaired too when it went")
    func repairsTheDefaultModel() {
        let defaults = defaults()
        let offeredWithoutDefault = offered.filter { $0 != ArticleSpeechCatalog.defaultModelID }
        let repair = ArticleSpeechSelection.repairStoredPick(
            defaults: defaults, offered: offeredWithoutDefault, isDirectoryBacked: true,
            voices: voices, failed: { _, _ in false }
        )
        #expect(repair?.oldModel == ArticleSpeechCatalog.defaultModelID)
        #expect(repair?.newModel == offeredWithoutDefault[0])
        #expect(defaults.string(forKey: modelKey()) == offeredWithoutDefault[0])

        let untouched = self.defaults()
        #expect(ArticleSpeechSelection.repairStoredPick(
            defaults: untouched, offered: offered, isDirectoryBacked: true,
            voices: voices, failed: { _, _ in false }
        ) == nil)
        #expect(untouched.string(forKey: modelKey()) == nil, "an offered default is not written")
        #expect(untouched.string(forKey: voiceKey(ArticleSpeechCatalog.defaultModelID)) == nil,
                "nor its voice, which already reads as the first")
    }

    @Test("A voice the model dropped becomes its first without a word; a model still offered is kept even after a failed test")
    func repairsVanishedVoiceSilently() {
        let defaults = defaults()
        defaults.set("deepgram/aura-2", forKey: modelKey())
        defaults.set("Kore", forKey: voiceKey("deepgram/aura-2"))
        #expect(ArticleSpeechSelection.repairStoredPick(
            defaults: defaults, offered: offered, isDirectoryBacked: true,
            voices: voices, failed: { _, _ in true }
        ) == nil)
        #expect(defaults.string(forKey: modelKey()) == "deepgram/aura-2")
        #expect(defaults.string(forKey: voiceKey("deepgram/aura-2")) == "aura-2-thalia-en")
    }

    @Test("The phone's test fails on a refusal of the model, its voice or its audio, never on the moment or the account")
    func cloudVerdicts() {
        typealias Failure = CloudArticleTTS.GenerationError
        #expect(CloudArticleTTS.qualificationVerdict(
            for: Failure.rejected(model: "deepgram/flux-tts:free", statusCode: 404, reason: "No endpoints found for deepgram/flux-tts:free.")
        ) == "No endpoints found for deepgram/flux-tts:free.")
        #expect(CloudArticleTTS.qualificationVerdict(
            for: Failure.rejected(model: "google/gemini-3.8-flash-tts", statusCode: 400, reason: "This model only supports response_format=pcm.")
        )?.contains("response_format=pcm") == true)
        #expect(CloudArticleTTS.qualificationVerdict(
            for: Failure.rejected(model: "x/y", statusCode: 200, reason: "The model provider returned audio that could not be decoded.")
        ) != nil, "audio that did not play")

        let inconclusive: [Error] = [
            Failure.rejected(model: "x/y:free", statusCode: 404, reason: "No endpoints found matching your data policy (Free model publication)"),
            Failure.rejected(model: "x/y", statusCode: 429, reason: "Rate limited."),
            Failure.rejected(model: "x/y", statusCode: 503, reason: "Upstream busy."),
            Failure.missingAPIKey,
            Failure.networkUnavailable,
            Failure.failedAfterRetries("The request timed out."),
            Failure.badResponse("ForeverLM AI returned audio without a metering receipt."),
            ManagedAI.ServiceError(code: "credits_empty", message: "Your balance is empty."),
            CancellationError(),
            URLError(.timedOut),
        ]
        for error in inconclusive {
            #expect(CloudArticleTTS.qualificationVerdict(for: error) == nil, "\(error.localizedDescription)")
        }
    }

    @Test("A phone pick is applied only once it passes; a busy free model goes and a busy priced one waits")
    func cloudSelection() async {
        let suite = "PhoneTextToSpeechPickTests.records.\(UUID().uuidString)"
        let records = UserDefaults(suiteName: suite)!
        defer { records.removePersistentDomain(forName: suite) }
        let slug = AIModelQualification.speechSlug(model: "test/\(UUID().uuidString)", voice: "jack")

        let refused = await AIModelQualification.speechSelectionVerdict(
            slug: slug, isFree: false, canTest: true, defaults: records,
            verdict: CloudArticleTTS.qualificationVerdict(for:)
        ) {
            throw CloudArticleTTS.GenerationError.rejected(model: "test/model", statusCode: 400, reason: "Unknown voice jack.")
        }
        #expect(refused == .refused("Unknown voice jack."))
        #expect(AIModelQualification.speechRefusalText(name: "Jack", verdict: refused)
                == "Jack failed a test run, so it was not selected. OpenRouter said: Unknown voice jack.")

        let busy: () async throws -> Void = {
            throw CloudArticleTTS.GenerationError.rejected(model: "test/model", statusCode: 429, reason: "Rate limited.")
        }
        let paid = AIModelQualification.speechSlug(model: "test/\(UUID().uuidString)", voice: "")
        #expect(await AIModelQualification.speechSelectionVerdict(
            slug: paid, isFree: false, canTest: true, defaults: records,
            verdict: CloudArticleTTS.qualificationVerdict(for:), probe: busy
        ) == .retryLater)
        let free = AIModelQualification.speechSlug(model: "test/\(UUID().uuidString):free", voice: "")
        #expect(await AIModelQualification.speechSelectionVerdict(
            slug: free, isFree: true, canTest: true, defaults: records,
            verdict: CloudArticleTTS.qualificationVerdict(for:), probe: busy
        ) == .go)
        #expect(AIModelQualification.status(slug: free, role: .speech, defaults: records) == .untested,
                "a free pick applied untested is tested when next used")
    }
}
