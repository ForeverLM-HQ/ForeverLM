import Foundation
import Testing
@testable import ForeverLM

@Suite("Free models setup")
struct FreeModelsSetupTests {
    /// The directory rules alone; the qualification gate has tests of its own.
    private let allPass: FreeModelsSetup.Qualifies = { _, _ in true }

    private func model(
        _ id: String,
        input: Double? = 0,
        output: Double? = 0,
        context: Int = 131_072,
        tools: Bool = true,
        vision: Bool? = false
    ) -> OpenRouterDirectoryModel {
        OpenRouterDirectoryModel(
            id: id,
            name: id,
            inputUSDPerMTokens: input,
            outputUSDPerMTokens: output,
            contextLength: context,
            price: nil,
            supportsTools: tools,
            supportsTemperature: true,
            supportsVision: vision
        )
    }

    @Test("Preferred free models win while OpenRouter still lists them")
    func preferred() throws {
        let choice = try #require(FreeModelsSetup.choose(from: [
            model("anthropic/claude-sonnet-5", input: 3, output: 15, vision: true),
            model("google/gemma-4-31b-it:free", context: 262_144, vision: true),
            model("google/gemma-4-26b-a4b-it:free", context: 262_144, vision: true),
            model("liquid/lfm-2.5-2.6b:free", context: 65_536),
        ], qualifies: allPass))
        #expect(choice.chat.id == "google/gemma-4-31b-it:free")
        #expect(choice.background.id == "google/gemma-4-26b-a4b-it:free")
        #expect(choice.vision?.id == "google/gemma-4-31b-it:free")
    }

    @Test("With no preferred model left, the longest-context free model with tools is used")
    func fallsBackToDirectory() throws {
        let choice = try #require(FreeModelsSetup.choose(from: [
            model("a/small:free", context: 32_768),
            model("b/large:free", context: 1_000_000),
            model("c/no-tools:free", context: 2_000_000, tools: false),
        ], qualifies: allPass))
        #expect(choice.chat.id == "b/large:free")
        #expect(choice.background.id == "b/large:free")
        #expect(choice.vision == nil, "no free model reads images here")
    }

    @Test("Only :free models priced at zero that take tools are chosen")
    func onlyFreeModels() {
        #expect(FreeModelsSetup.choose(from: [
            model("x/paid", input: 0.1, output: 0.2),
            model("y/unpriced:free", input: nil, output: nil),
            model("z/no-tools:free", tools: false),
        ], qualifies: allPass) == nil)
    }

    @Test("A background task is offered only the free models that can do it, best first")
    func perTaskCandidates() {
        let directory = [
            model("x/paid", input: 0.1, output: 0.2, context: 2_000_000, vision: true),
            model("a/text-only:free", context: 1_000_000),
            model("b/no-tools:free", context: 2_000_000, tools: false, vision: true),
            model("c/sees:free", context: 131_072, vision: true),
            model("google/gemma-4-26b-a4b-it:free", context: 32_768),
            model("d/unknown-vision:free", context: 65_536, vision: nil),
        ]

        let text = FreeModelsSetup.candidates(needsVision: false, from: directory, qualifies: allPass).map(\.id)
        #expect(text == [
            "google/gemma-4-26b-a4b-it:free",
            "a/text-only:free",
            "c/sees:free",
            "d/unknown-vision:free",
        ], "the preferred model leads, then the longest context")

        let vision = FreeModelsSetup.candidates(needsVision: true, from: directory, qualifies: allPass).map(\.id)
        #expect(vision == ["c/sees:free"], "only a model the directory says reads images")

        #expect(FreeModelsSetup.candidates(needsVision: true, from: [model("x/paid", input: 1, output: 1, vision: true)], qualifies: allPass).isEmpty)
    }

    @Test("No free model can be picked without an OpenRouter key or while the data switch is on")
    func pickBlocker() {
        #expect(FreeModelsSetup.pickBlocker(hasOpenRouterKey: true, deniesDataCollection: false) == nil)
        #expect(FreeModelsSetup.pickBlocker(hasOpenRouterKey: false, deniesDataCollection: false)?.contains("OpenRouter key") == true)
        #expect(FreeModelsSetup.pickBlocker(hasOpenRouterKey: true, deniesDataCollection: true)?.contains(AIDataPolicy.switchTitle) == true)
    }

    @Test("A free model that ended is replaced by the best other free model that can do the work")
    func replacementSkipsTheEndedModel() {
        let directory = [
            model("google/gemma-4-26b-a4b-it:free", context: 262_144),
            model("google/gemma-4-31b-it:free", context: 262_144, vision: true),
            model("liquid/lfm-2.5-2.6b:free", context: 65_536),
        ]
        let text = FreeModelReplacement.replacement(for: "Google/Gemma-4-26b-a4b-it:free", needsVision: false, from: directory, qualifies: allPass)
        #expect(text?.id == "google/gemma-4-31b-it:free")
        let vision = FreeModelReplacement.replacement(for: "google/gemma-4-31b-it:free", needsVision: true, from: directory, qualifies: allPass)
        #expect(vision == nil)
        let chat = FreeModelReplacement.chatReplacement(for: "google/gemma-4-31b-it:free", from: directory, qualifies: allPass)
        #expect(chat != nil)
        #expect(chat?.id != "google/gemma-4-31b-it:free")
    }

    @Test("Setup's free-model check reads OpenRouter's privacy refusal, and nothing else, as not allowed")
    func accessVerdict() {
        #expect(FreeModelAccess.verdict(forFailure: "No endpoints found matching your data policy (Free model training). Configure: https://openrouter.ai/settings/privacy") == .refused)
        #expect(FreeModelAccess.verdict(forFailure: "0 endpoints out of 1 requested are available: Free model training violation (account settings)") == .refused)
        #expect(FreeModelAccess.verdict(forFailure: AIDataPolicy.trainingRefusalExplanation(providerMessage: nil)) == .refused)
        #expect(FreeModelAccess.verdict(forFailure: "Rate limit exceeded: free-models-per-min") == .unknown("Rate limit exceeded: free-models-per-min"))
    }

    @Test("Free model ids are recognised by their suffix")
    func freeIDs() {
        #expect(FreeModelsSetup.isFreeModelID("google/gemma-4-31b-it:free"))
        #expect(FreeModelsSetup.isFreeModelID(" x/y:FREE "))
        #expect(!FreeModelsSetup.isFreeModelID("google/gemma-4-31b-it"))
    }

    @Test("OpenRouter's Free Models Router is free without the suffix, and no other router is")
    func freeRouterID() {
        #expect(FreeModelsSetup.isFreeModelID("openrouter/free"))
        #expect(FreeModelsSetup.isFreeModelID(" OpenRouter/Free "))
        #expect(!FreeModelsSetup.isFreeModelID("openrouter/auto"))
        #expect(FreeModelsSetup.isRecommended("openrouter/free"))
        #expect(!FreeModelsSetup.isRecommended("google/gemma-4-31b-it:free"))
    }

    @Test("Free mode picks the Free Models Router for every role while OpenRouter lists it")
    func routerLeads() throws {
        let directory = [
            model("google/gemma-4-31b-it:free", context: 262_144, vision: true),
            model("google/gemma-4-26b-a4b-it:free", context: 262_144, vision: true),
            model("openrouter/free", context: 200_000, vision: true),
        ]
        let choice = try #require(FreeModelsSetup.choose(from: directory, qualifies: allPass))
        #expect(choice.chat.id == "openrouter/free")
        #expect(choice.background.id == "openrouter/free")
        #expect(choice.vision?.id == "openrouter/free")
        // The single free models are still offered after it.
        #expect(FreeModelsSetup.rankedFreeForChat(from: directory).map(\.id) == [
            "openrouter/free", "google/gemma-4-31b-it:free", "google/gemma-4-26b-a4b-it:free",
        ])
        #expect(FreeModelsSetup.candidates(needsVision: false, from: directory, qualifies: allPass).map(\.id) == [
            "openrouter/free", "google/gemma-4-26b-a4b-it:free", "google/gemma-4-31b-it:free",
        ])
    }

    @Test("A router that failed its test run gives way to the single free models")
    func failedRouterGivesWay() throws {
        let choice = try #require(FreeModelsSetup.choose(from: [
            model("google/gemma-4-31b-it:free", context: 262_144, vision: true),
            model("openrouter/free", context: 200_000, vision: true),
        ], qualifies: { id, _ in id != "openrouter/free" }))
        #expect(choice.chat.id == "google/gemma-4-31b-it:free")
    }

    @Test("A router the directory lists with a price is not free")
    func pricedRouterIsNotFree() {
        #expect(!FreeModelsSetup.isFree(model("openrouter/free", input: 0.1, output: 0.1)))
    }

    /// A learner may list up to ten backups (product owner, 2026-09-27), but a free
    /// pick brings two of its own: each backup a failing call walks spends
    /// another request of the key's daily free-model quota.
    @Test("A free pick brings the next two free models as backups, however many there are, never itself")
    func freePickBringsTwoBackups() {
        let candidates = [
            model("openrouter/free", context: 200_000),
            model("google/gemma-4-26b-a4b-it:free", context: 262_144),
            model("nvidia/nemotron-3-super-120b-a12b:free", context: 262_144),
            model("google/gemma-4-31b-it:free", context: 262_144),
            model("liquid/lfm-2.5-2.6b:free", context: 65_536),
        ]
        #expect(FreeModelsSetup.freeBackupCount == 2)
        #expect(FreeModelsSetup.freeBackupCount < AIBackupModels.limit)
        #expect(FreeModelsSetup.freeBackups(from: candidates, primaryID: "OpenRouter/Free").map(\.id) == [
            "google/gemma-4-26b-a4b-it:free", "nvidia/nemotron-3-super-120b-a12b:free",
        ])
        #expect(FreeModelsSetup.freeBackups(from: candidates, primaryID: "google/gemma-4-26b-a4b-it:free").map(\.id) == [
            "openrouter/free", "nvidia/nemotron-3-super-120b-a12b:free",
        ])
        #expect(FreeModelsSetup.freeBackups(from: Array(candidates.prefix(1)), primaryID: "openrouter/free").isEmpty)
    }
}

@Suite("Free mode")
struct FreeModeTests {
    private let proxyHost = "ai.foreverlm.com"

    private func post(_ url: String, body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return request
    }

    private func refusal(
        _ request: URLRequest,
        on: Bool = true,
        key: Bool = true,
        paid: Set<String> = []
    ) -> AIFreeMode.Refusal? {
        // The live table is filled by the host app's own directory read, so
        // the tests name what is listed as paid instead of reading it.
        AIFreeMode.refusal(for: request, isOn: on, hasOpenRouterKey: key, proxyHost: proxyHost, listedAsPaid: { paid.contains($0) })
    }

    @Test("Off, nothing is refused")
    func offRefusesNothing() {
        let request = post("https://openrouter.ai/api/v1/audio/speech", body: ["model": "openai/gpt-5-tts"])
        #expect(refusal(request, on: false) == nil)
        #expect(refusal(request) == .paidModel("openai/gpt-5-tts"))
    }

    @Test("A free model bound for OpenRouter passes, directly or through the proxy")
    func freeOpenRouterPasses() {
        #expect(refusal(post("https://openrouter.ai/api/v1/chat/completions",
                             body: ["model": "google/gemma-4-31b-it:free"])) == nil)
        #expect(refusal(post("https://ai.foreverlm.com/v1/proxy/openrouter/api/v1/chat/completions",
                             body: ["model": "google/gemma-4-31b-it:free"])) == nil)
        #expect(refusal(post("https://openrouter.ai/api/v1/chat/completions",
                             body: ["model": "openrouter/free"])) == nil)
        #expect(refusal(post("https://openrouter.ai/api/v1/chat/completions",
                             body: ["model": "openrouter/auto"])) == .paidModel("openrouter/auto"))
    }

    @Test("A paid model is refused by name")
    func paidModelRefused() {
        let request = post("https://openrouter.ai/api/v1/chat/completions", body: ["model": "anthropic/claude-sonnet-5"])
        #expect(refusal(request) == .paidModel("anthropic/claude-sonnet-5"))
        #expect(refusal(request)?.errorDescription?.contains(AIFreeMode.settingsLocation) == true)
    }

    @Test("A free id on another host, or a body with no model, fails closed")
    func unknownRequestsFailClosed() {
        #expect(refusal(post("https://api.example.com/v1/audio/transcriptions", body: ["model": "x/y:free"])) == .paidModel("x/y:free"))
        #expect(refusal(post("https://ai.foreverlm.com/v1/proxy/unsupported", body: ["model": "x/y:free"])) == .paidModel("x/y:free"))
        #expect(refusal(post("https://openrouter.ai/api/v1/audio/transcriptions", body: nil)) == .paidModel(nil))
    }

    @Test("Reads pass, since they spend nothing")
    func readsPass() {
        let request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/generation?id=gen-1")!)
        #expect(refusal(request) == nil)
    }

    @Test("Without an OpenRouter key a free model is refused too")
    func needsKey() {
        let request = post("https://openrouter.ai/api/v1/chat/completions", body: ["model": "google/gemma-4-31b-it:free"])
        #expect(refusal(request, key: false) == .needsOpenRouterKey)
    }

    @Test("A :free id the directory now lists with a price is refused as no longer free")
    func noLongerFreeRefused() {
        let request = post("https://openrouter.ai/api/v1/chat/completions", body: ["model": "google/gemma-4-31b-it:free"])
        #expect(refusal(request, paid: ["google/gemma-4-31b-it:free"]) == .noLongerFree("google/gemma-4-31b-it:free"))
        #expect(refusal(request, paid: ["qwen/qwen3.8-27b:free"]) == nil)
        #expect(refusal(request, on: false, paid: ["google/gemma-4-31b-it:free"]) == nil)
    }

    @Test("The live price table refuses only what a read listed with a price")
    func livePriceTable() {
        AIFreeModelPrices.record(["test/still-free:free": true, "Test/Now-Paid:free": false])
        #expect(AIFreeModelPrices.isListedAsPaid("test/now-paid:free"))
        #expect(!AIFreeModelPrices.isListedAsPaid("test/still-free:free"))
        #expect(!AIFreeModelPrices.isListedAsPaid("test/never-listed:free"))
        AIFreeModelPrices.record([:])
        #expect(AIFreeModelPrices.isListedAsPaid("test/now-paid:free"))
    }

    @Test("The zero price cap rides beside the provider preferences already there")
    func zeroPriceCap() throws {
        var payload: [String: Any] = ["model": "google/gemma-4-31b-it:free", "provider": ["order": ["google-ai-studio"]]]
        AIFreeMode.applyZeroPriceCap(to: &payload)
        let provider = try #require(payload["provider"] as? [String: Any])
        #expect(provider["order"] as? [String] == ["google-ai-studio"])
        let cap = try #require(provider["max_price"] as? [String: Any])
        for field in ["prompt", "completion", "request", "image"] {
            #expect(cap[field] as? Int == 0)
        }
    }

    @Test("The zero price cap drops plugins, which OpenRouter bills apart from the model")
    func zeroPriceCapDropsPlugins() {
        // Web search bills per result even on a :free model, and max_price
        // does not reach it (2026-09-26: no OpenRouter charge at all).
        var payload: [String: Any] = ["model": "google/gemma-4-31b-it:free", "plugins": [["id": "web"]]]
        AIFreeMode.applyZeroPriceCap(to: &payload)
        #expect(payload["plugins"] == nil)
    }

    @Test("A chat request is capped in place; a speech request is left as it is")
    func zeroPriceCapOnARequest() throws {
        var chat = post("https://openrouter.ai/api/v1/chat/completions",
                        body: ["model": "google/gemma-4-31b-it:free", "plugins": [["id": "web"]]])
        AIFreeMode.applyZeroPriceCap(toChatRequest: &chat)
        let body = try #require(chat.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["plugins"] == nil)
        #expect(body["model"] as? String == "google/gemma-4-31b-it:free")
        let provider = try #require(body["provider"] as? [String: Any])
        #expect((provider["max_price"] as? [String: Any])?["completion"] as? Int == 0)

        let speech = post("https://openrouter.ai/api/v1/audio/speech", body: ["model": "fish-audio/s2.1-pro-free:free"])
        var untouched = speech
        AIFreeMode.applyZeroPriceCap(toChatRequest: &untouched)
        #expect(untouched.httpBody == speech.httpBody)
    }

    @Test("What Free mode turns off is said wherever it is offered")
    func unavailableFeaturesAreNamed() {
        // "as long as it's clear that certain features are not available.
        // Like generating images and videos" (2026-09-26).
        for feature in ["image", "video", "web search", "transcription"] {
            #expect(AIFreeMode.unavailableNote.contains(feature), "\(feature)")
        }
        // Realtime voice went on 2026-10-01; nothing may still offer it.
        #expect(!AIFreeMode.unavailableNote.contains("realtime"))
        #expect(AIFreeMode.tradeoffs.contains(AIFreeMode.unavailableNote))
        #expect(AIFreeMode.confirmationMessage(turnsOffDataPolicySwitch: false).contains(AIFreeMode.unavailableNote))
        // Free mode runs on the key only where the account may run it (a plan
        // from 2026-09-27; the free days or paid since 2026-10-10), so
        // nothing may say otherwise.
        #expect(!AIFreeMode.summary.contains("no ForeverLM plan"))
        // Each model's terms are the learner's to read, on OpenRouter (2026-09-26).
        #expect(AIFreeMode.confirmationMessage(turnsOffDataPolicySwitch: false).contains(AIFreeMode.termsNote))
        #expect(FreeModelsSetup.pickTradeoffs.contains("terms"))
    }

    @Test("A refusal under the price cap says the model is no longer free, only in Free mode")
    func priceCapRefusalExplained() {
        let message = "No endpoints found matching your price constraints (max_price)."
        #expect(AIFreeMode.isPriceCapRefusal(message))
        #expect(!AIFreeMode.isPriceCapRefusal("No endpoints found matching your data policy"))
        let explained = AIFreeMode.refusalExplanation(forProviderBody: message, providerMessage: message, isOn: true)
        #expect(explained?.contains("no longer offers this model for free") == true)
        #expect(AIFreeMode.refusalExplanation(forProviderBody: message, providerMessage: message, isOn: false) == nil)
        let privacy = AIFreeMode.refusalExplanation(
            forProviderBody: "No endpoints found matching your data policy",
            providerMessage: nil,
            isOn: true
        )
        #expect(privacy?.contains("privacy settings") == true)
    }

    @Test("Busy and rate-limited failures say free models are often busy, once")
    func busyNote() {
        let annotated = AIFreeMode.annotatingBusy("Rate limited", status: 429, isOn: true)
        #expect(annotated.hasSuffix(AIFreeMode.busyNote))
        #expect(AIFreeMode.annotatingBusy(annotated, status: 429, isOn: true) == annotated)
        #expect(AIFreeMode.annotatingBusy("Bad request", status: 400, isOn: true) == "Bad request")
        #expect(AIFreeMode.annotatingBusy("Rate limited", status: 429, isOn: false) == "Rate limited")
    }

    @Test("The confirmation names training, overload, and the switch it turns off")
    func confirmationCopy() {
        let message = AIFreeMode.confirmationMessage(turnsOffDataPolicySwitch: true)
        #expect(message.contains("train"))
        #expect(message.contains("overloaded"))
        #expect(message.contains(AIDataPolicy.switchTitle))
        #expect(message.contains("limited time"))
        #expect(!AIFreeMode.confirmationMessage(turnsOffDataPolicySwitch: false).contains(AIDataPolicy.switchTitle))
        #expect(FreeModelsSetup.pickTradeoffs.contains("limited time"))
    }

    @Test("Saved selections survive the synced preference round trip")
    func savedSelectionsRoundTrip() throws {
        let saved = FreeModelsSetup.SavedSelections(
            defaultChat: .init(provider: "openrouter", model: "anthropic/claude-sonnet-5"),
            background: .init(provider: "openrouter", model: "google/gemini-3.8-flash"),
            backgroundMultimodal: .init(provider: "openrouter", model: "google/gemini-3.8-flash"),
            textToSpeechOpenRouterModel: "x/tts",
            textToSpeechModel: "x/tts",
            deniedDataCollection: true
        )
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(FreeModelsSetup.SavedSelections.self, from: data) == saved)
    }
}

@Suite("Model price watch")
struct AIModelPriceWatchTests {
    private typealias Seen = AIModelPriceWatch.Seen

    private func row(_ id: String, input: Double?, output: Double?) -> OpenRouterDirectoryModel {
        OpenRouterDirectoryModel(
            id: id,
            name: "Name of \(id)",
            inputUSDPerMTokens: input,
            outputUSDPerMTokens: output,
            contextLength: 131_072,
            price: nil,
            supportsTools: true,
            supportsTemperature: true,
            supportsVision: false
        )
    }

    /// A read long enough to count as whole, plus the rows under test.
    private func directory(_ rows: [OpenRouterDirectoryModel]) -> [OpenRouterDirectoryModel] {
        rows + (0..<AIModelPriceWatch.minimumDirectoryRows).map { row("filler/model-\($0)", input: 1, output: 2) }
    }

    @Test("The first read of a model only records it")
    func firstReadRecords() {
        let result = AIModelPriceWatch.compare(
            watched: ["google/gemma-4-31b-it:free"],
            previous: [:],
            directory: directory([row("google/gemma-4-31b-it:free", input: 0, output: 0)])
        )
        #expect(result.changes.isEmpty)
        #expect(result.record["google/gemma-4-31b-it:free"] == Seen(name: "Name of google/gemma-4-31b-it:free", input: 0, output: 0))
    }

    @Test("A free model that lists a price is announced as no longer free")
    func freeToPaid() {
        let id = "google/gemma-4-31b-it:free"
        let result = AIModelPriceWatch.compare(
            watched: [id],
            previous: [id: Seen(name: "Gemma", input: 0, output: 0)],
            directory: directory([row(id, input: 0.1, output: 0.2)])
        )
        #expect(result.changes == [.noLongerFree(id: id, name: "Name of \(id)", now: Seen(name: "Name of \(id)", input: 0.1, output: 0.2))])
    }

    @Test("A free model OpenRouter stopped listing is announced once, then forgotten")
    func freeVariantEnded() {
        let id = "qwen/qwen3.8-27b:free"
        let first = AIModelPriceWatch.compare(
            watched: [id],
            previous: [id: Seen(name: "Qwen", input: 0, output: 0)],
            directory: directory([])
        )
        #expect(first.changes == [.freeVariantEnded(id: id, name: "Qwen")])
        #expect(first.record[id] == nil)
        let second = AIModelPriceWatch.compare(watched: [id], previous: first.record, directory: directory([]))
        #expect(second.changes.isEmpty)
    }

    @Test("A paid model that costs more is announced; a cut or a steady price is not")
    func priceRise() {
        let id = "anthropic/claude-sonnet-5"
        let before = Seen(name: "Sonnet", input: 3, output: 15)
        let rise = AIModelPriceWatch.compare(watched: [id], previous: [id: before], directory: directory([row(id, input: 3, output: 18)]))
        #expect(rise.changes.count == 1)
        if case .moreExpensive(_, _, let from, let to)? = rise.changes.first {
            #expect(from == before)
            #expect(to.output == 18)
        } else {
            Issue.record("Expected a price rise")
        }
        let cut = AIModelPriceWatch.compare(watched: [id], previous: [id: before], directory: directory([row(id, input: 1.5, output: 7.5)]))
        #expect(cut.changes.isEmpty)
        let steady = AIModelPriceWatch.compare(watched: [id], previous: [id: before], directory: directory([row(id, input: 3, output: 15)]))
        #expect(steady.changes.isEmpty)
    }

    @Test("A paid model missing from one read keeps its record and raises nothing")
    func paidModelMissing() {
        let id = "anthropic/claude-sonnet-5"
        let before = Seen(name: "Sonnet", input: 3, output: 15)
        let result = AIModelPriceWatch.compare(watched: [id], previous: [id: before], directory: directory([]))
        #expect(result.changes.isEmpty)
        #expect(result.record[id] == before)
    }

    @Test("A truncated read changes nothing, and unwatched models are dropped from the record")
    func truncatedAndUnwatched() {
        let id = "google/gemma-4-31b-it:free"
        let previous = [id: Seen(name: "Gemma", input: 0, output: 0), "old/model": Seen(name: "Old", input: 1, output: 1)]
        let truncated = AIModelPriceWatch.compare(watched: [id], previous: previous, directory: [row(id, input: 1, output: 1)])
        #expect(truncated.changes.isEmpty)
        #expect(truncated.record == previous)
        let whole = AIModelPriceWatch.compare(watched: [id], previous: previous, directory: directory([row(id, input: 0, output: 0)]))
        #expect(whole.record.keys.sorted() == [id])
    }

    @Test("Only a free model that ended offers the switch; a price rise does not")
    func endsFree() {
        let seen = Seen(name: "Y", input: 0.1, output: 0.4)
        #expect(AIModelPriceWatch.Change.noLongerFree(id: "x/y:free", name: "Y", now: seen).endsFree)
        #expect(AIModelPriceWatch.Change.freeVariantEnded(id: "x/y:free", name: "Y").endsFree)
        #expect(!AIModelPriceWatch.Change.moreExpensive(id: "x/y", name: "Y", from: seen, to: seen).endsFree)
        let change = AIModelPriceWatch.Change.noLongerFree(id: "x/y:free", name: "Y", now: seen)
        #expect(AIModelPriceWatch.body(for: change, freeModeOn: false).hasSuffix("Switch to another free model?"))
    }

    @Test("OpenRouter's listed-apps refusal names the model it refused")
    func listedAppsRefusal() {
        let message = "Paper Metadata AI (OpenRouter) failed after 1 attempt: thinkingmachines/inkling-small:free is only available on agentic harnesses. Try plugging it into a coding agent or productivity app listed on https://openrouter.ai/apps [OpenRouter request failed (403)]"
        #expect(AIFreeModelRestrictions.restrictedModel(inRefusal: message) == "thinkingmachines/inkling-small:free")
        #expect(AIFreeModelRestrictions.restrictedModel(inRefusal: "No endpoints found matching your data policy") == nil)
        #expect(AIModelPriceWatch.Change.limitedToListedApps(id: "x/y:free", name: "Y").endsFree)
    }

    @Test("A refused free model is recorded once and forgotten after a week")
    func restrictionRecord() throws {
        let suite = "FreeModelsSetupTests.restrictions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(AIFreeModelRestrictions.record("X/Y:free", now: now, defaults: defaults))
        #expect(!AIFreeModelRestrictions.record("x/y:free", now: now, defaults: defaults))
        #expect(AIFreeModelRestrictions.isRestricted("x/y:FREE", now: now, defaults: defaults))
        let later = now.addingTimeInterval(AIFreeModelRestrictions.retention + 1)
        #expect(!AIFreeModelRestrictions.isRestricted("x/y:free", now: later, defaults: defaults))
    }

    @Test("The switched banner says what moved and what could not")
    func switchedCopy() {
        let outcome = FreeModelReplacement.Outcome(
            moves: [.init(setting: "Background work", modelName: "Gemma 4 31B (free)")],
            stranded: ["Multimodal background work"]
        )
        let body = AIModelPriceWatch.switchedBody(outcome)
        #expect(body.contains("Background work now runs on Gemma 4 31B (free), which is free."))
        #expect(body.contains("No free model can do Multimodal background work today"))
    }

    @Test("The banner names the model and, in Free mode, says Free mode will not use it")
    func bannerCopy() {
        let change = AIModelPriceWatch.Change.noLongerFree(id: "x/y:free", name: "Y", now: Seen(name: "Y", input: 0.1, output: 0.4))
        #expect(AIModelPriceWatch.title(for: change) == "Y is no longer free")
        #expect(AIModelPriceWatch.body(for: change, freeModeOn: true).contains("Free mode will not use it"))
        #expect(AIModelPriceWatch.body(for: change, freeModeOn: false).contains("now costs money"))
    }
}

/// The product owner (2026-09-27) moved the meetings choice from a card in Settings ›
/// Background into Setup: meetings stay on a paid model when background work
/// goes free, unless the learner lets them go free too. Since 2026-09-28 that
/// is a rule applied when a meeting task runs, not a model pinned to each
/// meeting task (`MeetingModels`).
@Suite("Meetings off free models")
struct MeetingModelsTests {
    private let paid = AITaskModelRoute(provider: .openRouter, model: "deepseek/deepseek-v4-flash")
    private let router = AITaskModelRoute(provider: .openRouter, model: "openrouter/free")
    private let sonnet = AITaskModelRoute(provider: .openRouter, model: "anthropic/claude-sonnet-5")
    /// By the id alone, so no price read elsewhere in the run can change it.
    private let isFree: @Sendable (AITaskModelRoute) -> Bool = { AIFreeMode.isFreeModelID($0.model) }

    private func route(
        _ task: AITask,
        on background: AITaskModelRoute,
        mayUseFree: Bool = false,
        freeModeOn: Bool = false,
        paidBackup: AITaskModelRoute? = nil
    ) -> AITaskModelRoute? {
        MeetingModels.route(
            for: task,
            background: background,
            staysOffFree: MeetingModels.staysOffFree(task, mayUseFree: mayUseFree, freeModeOn: freeModeOn),
            paid: { paidBackup ?? paid },
            isFree: isFree
        )
    }

    @Test("The meeting tasks are the three that read a meeting's recording or transcript")
    func meetingTasks() {
        #expect(Set(MeetingModels.tasks) == [.meetingSessionDetails, .meetingPaperDiscovery, .meetingActionItems])
    }

    @Test("A meeting task on a free Background model runs on the paid model instead")
    func meetingOffFree() {
        #expect(route(.meetingActionItems, on: router) == paid)
        #expect(route(.meetingSessionDetails, on: router) == paid)
    }

    @Test("A meeting task on a free Background model with no paid backup waits, on no model ForeverLM picked")
    func meetingWaitsWithoutPaidBackup() {
        let none = MeetingModels.route(
            for: .meetingActionItems,
            background: router,
            staysOffFree: true,
            paid: { nil },
            isFree: isFree
        )
        #expect(none == nil)
        // A paid Background model is no reason to wait.
        let onPaid = MeetingModels.route(
            for: .meetingActionItems,
            background: sonnet,
            staysOffFree: true,
            paid: { nil },
            isFree: isFree
        )
        #expect(onPaid == sonnet)
    }

    @Test("A meeting task follows a paid Background model as it is")
    func meetingOnPaid() {
        #expect(route(.meetingActionItems, on: sonnet) == sonnet)
    }

    @Test("Letting meetings use free models, or Free mode, sends them to the free model")
    func meetingsAllowedFree() {
        #expect(route(.meetingActionItems, on: router, mayUseFree: true) == router)
        #expect(route(.meetingActionItems, on: router, freeModeOn: true) == router)
    }

    @Test("Every other background task follows a free Background model")
    func otherTasksFollowFree() {
        #expect(route(.transcriptFormatting, on: router) == router)
        #expect(!MeetingModels.staysOffFree(.paperMetadata, mayUseFree: false, freeModeOn: false))
    }
}

@Suite("Hosts in one region")
struct RegionalHostTests {
    private func endpoint(_ tag: String, tools: Bool = true) -> OpenRouterRegionalEndpoints.Endpoint {
        OpenRouterRegionalEndpoints.Endpoint(
            tag: tag, providerName: tag, supportsTools: tools, inputUSDPerMTokens: 0.1, outputUSDPerMTokens: 0.3
        )
    }

    private func provider(_ payload: [String: Any]) -> [String: Any] {
        payload["provider"] as? [String: Any] ?? [:]
    }

    @Test("A model kept in the US names only its US endpoints, narrowed to those that cache, whatever else the route asks")
    func regionBoundsTheRoute() {
        var automatic: [String: Any] = ["model": "z-ai/glm-5.3-flash"]
        OpenRouterRoutePreference.applyFastestCachingRoute(
            to: &automatic,
            cachingEndpointTags: ["fireworks/us", "z-ai/fp8"],
            regionEndpointTags: ["fireworks/us", "deepinfra/fp4"]
        )
        #expect(provider(automatic)["only"] as? [String] == ["fireworks/us"])
        #expect(provider(automatic)["sort"] as? String == "throughput")

        // No caching endpoint in the region: every one in it, never a caching one outside it.
        var apart: [String: Any] = ["model": "m"]
        OpenRouterRoutePreference.applyFastestCachingRoute(
            to: &apart, cachingEndpointTags: ["z-ai/fp8"], regionEndpointTags: ["deepinfra/fp4", "baseten/fp8"]
        )
        #expect(provider(apart)["only"] as? [String] == ["deepinfra/fp4", "baseten/fp8"])

        // The caching filter stands down under the data-policy switch; the region does not.
        var denied: [String: Any] = ["model": "m", "provider": ["data_collection": "deny"]]
        OpenRouterRoutePreference.applyFastestCachingRoute(
            to: &denied, cachingEndpointTags: ["fireworks/us"], regionEndpointTags: ["fireworks/us", "deepinfra/fp4"]
        )
        #expect(provider(denied)["only"] as? [String] == ["fireworks/us", "deepinfra/fp4"])

        // A pinned host keeps its order, inside the region.
        var pinned: [String: Any] = ["model": "m", "provider": ["order": ["deepinfra/fp4"], "allow_fallbacks": true]]
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &pinned, regionEndpointTags: ["deepinfra/fp4", "fireworks/us"])
        #expect(provider(pinned)["order"] as? [String] == ["deepinfra/fp4"])
        #expect(provider(pinned)["only"] as? [String] == ["deepinfra/fp4", "fireworks/us"])
        #expect(provider(pinned)["sort"] == nil)

        var cheapest: [String: Any] = ["model": "m"]
        OpenRouterHostPreference(mode: .cheapest, region: .us).apply(to: &cheapest)
        OpenRouterRoutePreference.applyFastestCachingRoute(to: &cheapest, regionEndpointTags: ["a/x", "b/y"])
        #expect(provider(cheapest)["sort"] as? String == "price")
        #expect(provider(cheapest)["only"] as? [String] == ["a/x", "b/y"])
    }

    @Test("A host row keeps its region through its synced text, and a row from before regions allows any host")
    func hostRowRegion() throws {
        let row = OpenRouterHostPreference(mode: .cheapest, region: .us)
        let text = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(OpenRouterHostPreference.decoded(text) == row)
        let older = #"{"mode":"host","tag":"deepinfra/fp4","hostName":"DeepInfra","allowsFallback":true}"#
        #expect(OpenRouterHostPreference.decoded(older)?.tag == "deepinfra/fp4")
        #expect(OpenRouterHostPreference.decoded(older)?.region == nil)

        #expect(!OpenRouterHostPreference(mode: .automatic).isValid, "Automatic anywhere is no row")
        #expect(OpenRouterHostPreference(mode: .automatic, region: .us).isValid)
        #expect(OpenRouterHostPreference(mode: .automatic, region: .us).inRegion(nil) == nil)
        #expect(OpenRouterHostPreference(mode: .cheapest, region: .us).inRegion(nil) == OpenRouterHostPreference(mode: .cheapest))
        #expect(OpenRouterHostPreference(mode: .automatic, region: .us).label == "US providers")
        #expect(OpenRouterHostPreference(mode: .cheapest, region: .us).label == "Cheapest US provider")

        var body: [String: Any] = ["model": "m"]
        OpenRouterHostPreference(mode: .automatic, region: .us).apply(to: &body)
        #expect(body["provider"] == nil, "the region needs the model's endpoints, which the route step takes")
    }

    @Test("The work's own slot decides the region; work with no slot follows the model wherever it is kept in one")
    func regionFollowsTheModel() {
        let rows: [String: OpenRouterHostPreference] = [
            "chat": OpenRouterHostPreference(mode: .automatic, region: .us),
            "background.images": OpenRouterHostPreference(mode: .cheapest),
        ]
        func region(_ own: [String]) -> OpenRouterHostPreference.Region? {
            OpenRouterHostPreference.region(ownSlots: own) { rows[$0] }
        }
        #expect(region(["chat"]) == .us)
        // A chat's title, Deep Research: no slot of their own, so the chat's region.
        #expect(region([]) == .us)
        // Background work with no row for the model follows it too.
        #expect(region(["background.text"]) == .us)
        // A row of the work's own that allows any host is the learner's choice for it.
        #expect(region(["background.images"]) == nil)
        let none = OpenRouterHostPreference.region(ownSlots: ["chat"], row: { _ in nil })
        #expect(none == nil)
    }

    @Test("The US directory's rows parse to their tags once each, and any other shape is a failed read")
    func parsesTheRegionDirectory() throws {
        let json = #"{"data":{"endpoints":[{"tag":"Fireworks/us","provider_name":"Fireworks","pricing":{"prompt":"0.000000225","completion":"0.00000075"},"supported_parameters":["tools","reasoning"]},{"tag":"fireworks/us","provider_name":"Fireworks"},{"tag":"baseten/fp8","provider_name":"BaseTen","supported_parameters":["temperature"]}]}}"#
        let rows = try #require(OpenRouterRegionalEndpoints.parse(Data(json.utf8)))
        #expect(rows.map(\.tag) == ["fireworks/us", "baseten/fp8"])
        #expect(rows.map(\.supportsTools) == [true, false])
        #expect(rows.first?.inputUSDPerMTokens == 0.225)
        #expect(rows.last?.inputUSDPerMTokens == nil)
        #expect(OpenRouterRegionalEndpoints.parse(Data(#"{"error":{"message":"Not Found","code":404}}"#.utf8)) == nil)
    }

    @Test("A body for a model kept in the US is sent only when its only names US endpoints and nothing else")
    func requireConfined() throws {
        // A slug of its own, so no other test's cache entry can answer.
        let slug = "test/region-\(UUID().uuidString.lowercased())"
        let confined: [String: Any] = ["model": slug, "provider": ["only": ["deepinfra/fp4"]]]
        #expect(throws: OpenRouterRegionalEndpoints.Failure.unknown(model: slug, region: .us)) {
            try OpenRouterRegionalEndpoints.requireConfined(confined, region: .us)
        }
        OpenRouterRegionalEndpoints.cache([], slug: slug, region: .us)
        #expect(throws: OpenRouterRegionalEndpoints.Failure.noHost(model: slug, region: .us)) {
            try OpenRouterRegionalEndpoints.requireConfined(confined, region: .us)
        }
        OpenRouterRegionalEndpoints.cache([endpoint("deepinfra/fp4"), endpoint("fireworks/us")], slug: slug, region: .us)
        try OpenRouterRegionalEndpoints.requireConfined(confined, region: .us)
        #expect(throws: OpenRouterRegionalEndpoints.Failure.unknown(model: slug, region: .us)) {
            try OpenRouterRegionalEndpoints.requireConfined(
                ["model": slug, "provider": ["only": ["deepinfra/fp4", "z-ai/fp8"]]], region: .us
            )
        }
        #expect(throws: OpenRouterRegionalEndpoints.Failure.unknown(model: slug, region: .us)) {
            try OpenRouterRegionalEndpoints.requireConfined(["model": slug], region: .us)
        }
    }

    @Test("A phone route kept in the US carries its endpoints into the body")
    func phoneRouteCarriesTheRegion() throws {
        let route = ResolvedAITextRoute(task: .chat, provider: "OpenRouter", model: "z-ai/glm-5.3-flash")
            .confined(to: ["deepinfra/fp4", "fireworks/us"])
        let request = try MobileOpenRouterChat.request(
            route: route,
            system: "stable source and instructions",
            messages: [(role: "user", content: "question")],
            maxTokens: 100
        )
        let data = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(provider(payload)["only"] as? [String] == ["deepinfra/fp4", "fireworks/us"])
    }
}

@Suite("Recommended models")
struct RecommendedModelsTests {
    private let allPass: FreeModelsSetup.Qualifies = { _, _ in true }

    private func model(_ id: String, openWeights: Bool = true, tools: Bool = true, vision: Bool = false) -> OpenRouterDirectoryModel {
        OpenRouterDirectoryModel(
            id: id,
            name: id,
            inputUSDPerMTokens: 0.15,
            outputUSDPerMTokens: 0.5,
            contextLength: 1_048_576,
            price: nil,
            supportsTools: tools,
            supportsTemperature: true,
            supportsVision: vision,
            huggingFaceID: openWeights ? "org/\(id)" : nil
        )
    }

    private func host(_ tag: String, tools: Bool = true, input: Double? = 0.15, output: Double? = 0.5) -> OpenRouterRegionalEndpoints.Endpoint {
        OpenRouterRegionalEndpoints.Endpoint(
            tag: tag, providerName: tag, supportsTools: tools, inputUSDPerMTokens: input, outputUSDPerMTokens: output
        )
    }

    /// GLM 5.3 Flash's hosts in OpenRouter's US directory on 2026-09-28.
    private var glmUSHosts: [OpenRouterRegionalEndpoints.Endpoint] {
        [
            host("sail-research/us", input: 0.045, output: 0.6),
            host("deepinfra/fp4", input: 0.075, output: 0.25),
            host("baseten/fp8"),
            host("fireworks/us", input: 0.225, output: 0.75),
        ]
    }

    private let glmID = "z-ai/glm-5.3-flash"
    private let gemmaID = "google/gemma-4-31b-it"

    @Test("GLM 5.3 Flash takes chat and both backups while its weights are open and it has hosts in the US")
    func glmWhileItQualifies() throws {
        let choice = try RecommendedModels.choose(
            directory: [model(glmID, vision: true), model(gemmaID, vision: true)],
            regionEndpoints: [glmID: glmUSHosts],
            freeText: nil,
            freeVision: nil,
            qualifies: allPass
        )
        #expect(choice.chat.model.id == glmID)
        #expect(choice.chat.hosts.count == 4)
        #expect(choice.backup.model.id == glmID)
        #expect(choice.imagesBackup?.model.id == glmID)
        let price = try #require(choice.backup.cheapestPrice)
        #expect(price.input == 0.075)
        #expect(price.output == 0.25)
    }

    @Test("Closed weights, too few US hosts that take tools, or a failed test run pass GLM over for the next open model")
    func passedOver() {
        let gemmaHosts = [host("deepinfra/fp8"), host("deepinfra/ultra")]
        func chat(
            _ directory: [OpenRouterDirectoryModel],
            glmHosts: [OpenRouterRegionalEndpoints.Endpoint],
            qualifies: @escaping FreeModelsSetup.Qualifies = { _, _ in true }
        ) -> String? {
            RecommendedModels.qualifying(
                RecommendedModels.preferredChat,
                role: .chat,
                directory: directory,
                regionEndpoints: [glmID: glmHosts, gemmaID: gemmaHosts],
                qualifies: qualifies
            )?.model.id
        }
        #expect(chat([model(glmID, openWeights: false), model(gemmaID)], glmHosts: glmUSHosts) == gemmaID)
        #expect(chat([model(glmID), model(gemmaID)], glmHosts: [host("fireworks/us")]) == gemmaID)
        #expect(chat([model(glmID), model(gemmaID)], glmHosts: [host("a/x", tools: false), host("b/y")]) == gemmaID)
        #expect(chat([model(glmID, tools: false), model(gemmaID)], glmHosts: glmUSHosts) == gemmaID)
        // A closure written inside #expect sends the compiler's diagnostic
        // pass into "failed to produce diagnostic for expression" and fails
        // the target's build, so the failed test run is named first.
        let glmFailedItsTestRun: FreeModelsSetup.Qualifies = { [glmID] id, _ in id != glmID }
        #expect(chat([model(glmID), model(gemmaID)], glmHosts: glmUSHosts, qualifies: glmFailedItsTestRun) == gemmaID)
        #expect(chat([model(glmID), model(gemmaID)], glmHosts: glmUSHosts) == glmID)
    }

    @Test("Work that reads images gets a backup only from a model that reads images")
    func imagesBackupReadsImages() throws {
        let choice = try RecommendedModels.choose(
            directory: [model(glmID, vision: false)],
            regionEndpoints: [glmID: glmUSHosts],
            freeText: nil,
            freeVision: nil,
            qualifies: allPass
        )
        #expect(choice.backup.model.id == glmID)
        #expect(choice.imagesBackup == nil)
    }

    @Test("With no model that qualifies the set says so, and chooses nothing in its place")
    func nothingQualifies() {
        #expect(throws: RecommendedModels.Failure.noChatModel) {
            try RecommendedModels.choose(
                directory: [model(glmID), model(gemmaID)],
                regionEndpoints: [:],
                freeText: nil,
                freeVision: nil,
                qualifies: allPass
            )
        }
    }

    @Test("A meeting task's paid model is the Background default's first paid backup, else none")
    func meetingsFollowThePaidBackup() throws {
        let defaults = try #require(UserDefaults(suiteName: "RecommendedModelsTests.\(UUID().uuidString)"))
        let isFree: (AITaskModelRoute) -> Bool = { AIFreeMode.isFreeModelID($0.model) }
        // No paid backup, no paid model: ForeverLM does not pick one.
        #expect(MeetingModels.paidRoute(multimodal: false, defaults: defaults, isFree: isFree) == nil)
        let provider = AIProvider.openRouter.rawValue
        defaults.set(
            #"[{"provider":"\#(provider)","model":"google/gemma-4-26b-a4b-it:free"},{"provider":"\#(provider)","model":"z-ai/glm-5.3-flash"}]"#,
            forKey: AIBackupModels.key(slot: "background.text")
        )
        #expect(MeetingModels.paidRoute(multimodal: false, defaults: defaults, isFree: isFree)
            == AITaskModelRoute(provider: .openRouter, model: glmID))
        #expect(MeetingModels.paidRoute(multimodal: true, defaults: defaults, isFree: isFree) == nil)
    }
}
