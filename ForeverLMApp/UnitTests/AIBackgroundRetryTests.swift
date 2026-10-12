import Foundation
import Testing
@testable import ForeverLM

/// The cleanup Setup's imports start must get through on free and cheap
/// models: retried in place when a call fails for a moment, paced per model
/// when the provider pushes back, and handed back to the queue for as long as
/// the provider says when that is longer than a retry should wait.
@Suite("AI background retry")
struct AIBackgroundRetryTests {
    private func http(_ status: Int, retryAfter: Double? = nil) -> AIError {
        .httpError(status: status, message: "failed (\(status))", retryAfterSeconds: retryAfter)
    }

    @Test("Transient failures back off exponentially with jitter, up to the attempt budget")
    func exponentialBackoff() throws {
        let error = http(503)
        let first = try #require(AIBackgroundRetry.delayBeforeRetry(after: error, failedAttempts: 1, random: 1))
        let second = try #require(AIBackgroundRetry.delayBeforeRetry(after: error, failedAttempts: 2, random: 1))
        let third = try #require(AIBackgroundRetry.delayBeforeRetry(after: error, failedAttempts: 3, random: 1))
        #expect(first == AIBackgroundRetry.baseDelay)
        #expect(second == AIBackgroundRetry.baseDelay * 2)
        #expect(third == AIBackgroundRetry.baseDelay * 4)
        // Jitter halves at most, so a batch that failed together spreads out.
        #expect(AIBackgroundRetry.delayBeforeRetry(after: error, failedAttempts: 1, random: 0) == AIBackgroundRetry.baseDelay / 2)
        #expect(AIBackgroundRetry.delayBeforeRetry(after: error, failedAttempts: AIBackgroundRetry.maximumAttempts, random: 1) == nil)
    }

    @Test("A rate limit waits longer, and a named Retry-After is honoured when short")
    func rateLimitsAndRetryAfter() {
        #expect(AIBackgroundRetry.delayBeforeRetry(after: http(429), failedAttempts: 1, random: 1) == AIBackgroundRetry.rateLimitBaseDelay)
        #expect(AIBackgroundRetry.delayBeforeRetry(after: http(429, retryAfter: 12), failedAttempts: 1, random: 0) == 12)
        // Longer than a retry should wait: the queue takes it from here.
        #expect(AIBackgroundRetry.delayBeforeRetry(after: http(429, retryAfter: 3_600), failedAttempts: 1, random: 0) == nil)
    }

    @Test("Permanent failures and cancellation are never retried")
    func permanentFailures() {
        #expect(AIBackgroundRetry.delayBeforeRetry(after: http(401), failedAttempts: 1, random: 0) == nil)
        #expect(AIBackgroundRetry.delayBeforeRetry(after: http(402), failedAttempts: 1, random: 0) == nil)
        #expect(AIBackgroundRetry.delayBeforeRetry(after: CancellationError(), failedAttempts: 1, random: 0) == nil)
    }

    @Test("run retries a transient failure and returns the eventual answer")
    func runRetriesUntilSuccess() async throws {
        let pacer = AIRequestPacer()
        let config = AITaskConfig(provider: .openRouter, apiKey: "", model: "deepseek/deepseek-v4-flash")
        let counter = Counter()
        let answer = try await AIBackgroundRetry.run(config: config, backups: [], pacer: pacer, sleep: { _ in }) { _ in
            if await counter.next() < 3 { throw AIError.httpError(status: 502, message: "bad gateway (502)", retryAfterSeconds: nil) }
            return "ok"
        }
        #expect(answer == "ok")
        #expect(await counter.value == 3)
    }

    @Test("run gives a permanent failure straight back")
    func runStopsOnPermanentFailure() async {
        let config = AITaskConfig(provider: .openRouter, apiKey: "", model: "deepseek/deepseek-v4-flash")
        let counter = Counter()
        await #expect(throws: AIError.self) {
            try await AIBackgroundRetry.run(config: config, backups: [], pacer: AIRequestPacer(), sleep: { _ in }) { _ in
                _ = await counter.next()
                throw AIError.httpError(status: 400, message: "bad request (400)", retryAfterSeconds: nil)
            }
        }
        #expect(await counter.value == 1)
    }

    @Test("A 429 halves the model's concurrency, successes grow it back, and a long reset refuses without a request")
    func pacerBacksOffAndHoldsTheReset() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let pacer = AIRequestPacer(now: { clock.now })
        let lane = AIRequestPacer.Lane(model: "google/gemma-4-26b-a4b-it:free", isFree: true)
        #expect(await pacer.limit(for: lane) == 2)

        try await pacer.acquire(lane)
        await pacer.release(lane, after: AIError.httpError(status: 429, message: "rate limit (429)", retryAfterSeconds: 7_200))
        #expect(await pacer.limit(for: lane) == 1)
        #expect(await pacer.cooldownUntil(for: lane) == clock.now.addingTimeInterval(7_200))

        do {
            try await pacer.acquire(lane)
            Issue.record("A call inside a two-hour reset must be refused")
        } catch {
            #expect(AITransientErrorClassifier.isRateLimited(error))
            #expect(AITransientErrorClassifier.isTransient(error))
            let wait = try #require(AITransientErrorClassifier.retryAfterSeconds(error))
            #expect(abs(wait - 7_200) < 1)
        }

        clock.now = clock.now.addingTimeInterval(7_201)
        try await pacer.acquire(lane)
        await pacer.release(lane, after: nil)
        #expect(await pacer.limit(for: lane) == 2)
    }

    @Test("OpenRouter's X-RateLimit-Reset becomes the wait, from the header or the error body")
    func rateLimitReset() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let url = try #require(URL(string: "https://openrouter.ai/api/v1/chat/completions"))
        let resetMillis = String(Int((now.timeIntervalSince1970 + 3_600) * 1000))
        let headerResponse = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["X-RateLimit-Reset": resetMillis]))
        let fromHeader = try #require(AIService.rateLimitResetSeconds(from: headerResponse, body: Data(), now: now))
        #expect(abs(fromHeader - 3_600) < 1)

        let bare = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:]))
        let body = """
        {"error":{"message":"Rate limit exceeded: free-models-per-day","code":429,"metadata":{"headers":{"X-RateLimit-Limit":"50","X-RateLimit-Remaining":"0","X-RateLimit-Reset":"\(resetMillis)"}}}}
        """
        let fromBody = try #require(AIService.rateLimitResetSeconds(from: bare, body: Data(body.utf8), now: now))
        #expect(abs(fromBody - 3_600) < 1)

        #expect(AIService.rateLimitResetSeconds(from: bare, body: Data(), now: now) == nil)
        let past = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["X-RateLimit-Reset": String(Int((now.timeIntervalSince1970 - 5) * 1000))]))
        #expect(AIService.rateLimitResetSeconds(from: past, body: Data(), now: now) == nil)
    }

    // MARK: Backup models

    private func backup(_ model: String) -> AITaskConfig {
        var config = AITaskConfig(provider: .openRouter, apiKey: "", model: model)
        config.isBackup = true
        return config
    }

    @Test("A backup answers when the chosen model cannot, before any retry waits")
    func backupAnswersFirst() async throws {
        let config = AITaskConfig(provider: .openRouter, apiKey: "", model: "nvidia/nemotron-3-super-120b-a12b:free")
        let asked = ModelLog()
        let slept = ModelLog()
        let answer = try await AIBackgroundRetry.run(
            config: config,
            backups: [backup("google/gemma-4-26b-a4b-it:free"), backup("deepseek/deepseek-v4-flash")],
            pacer: AIRequestPacer(),
            sleep: { await slept.append("\($0)") }
        ) { candidate in
            await asked.append(candidate.model)
            if candidate.model == config.model { throw AIError.emptyAnswer(model: candidate.model) }
            if candidate.model == "google/gemma-4-26b-a4b-it:free" {
                throw AIError.httpError(status: 429, message: "temporarily rate-limited upstream (429)", retryAfterSeconds: nil)
            }
            return candidate.isBackup ? "from backup" : "from primary"
        }
        #expect(answer == "from backup")
        #expect(await asked.values == [config.model, "google/gemma-4-26b-a4b-it:free", "deepseek/deepseek-v4-flash"])
        #expect(await slept.values.isEmpty)
    }

    @Test("The chain stops at a failure every model shares, and at cancellation")
    func chainStopsOnSharedFailures() async {
        let config = AITaskConfig(provider: .openRouter, apiKey: "", model: "deepseek/deepseek-v4-flash")
        for shared: Error in [
            AIError.httpError(status: 401, message: "bad key (401)", retryAfterSeconds: nil),
            AIError.httpError(status: 402, message: "no balance (402)", retryAfterSeconds: nil),
            AIError.missingAPIKey,
            URLError(.notConnectedToInternet),
            CancellationError(),
        ] {
            let asked = ModelLog()
            await #expect(throws: Error.self) {
                try await AIBackgroundRetry.run(
                    config: config,
                    backups: [backup("google/gemma-4-26b-a4b-it:free")],
                    pacer: AIRequestPacer(),
                    sleep: { _ in }
                ) { candidate in
                    await asked.append(candidate.model)
                    throw shared
                }
            }
            let firstAsked = await asked.values.first
            #expect(firstAsked == config.model)
            let reachedBackup = await asked.values.contains("google/gemma-4-26b-a4b-it:free")
            #expect(!reachedBackup, Comment(rawValue: "\(shared)"))
        }
        #expect(AIBackupModels.shouldTryBackup(after: AIError.emptyAnswer(model: "m")))
        #expect(AIBackupModels.shouldTryBackup(after: AIError.invalidResponse))
        #expect(AIBackupModels.shouldTryBackup(after: AIError.apiError("Source Content Cleanup returned an invalid deletion plan.")))
        #expect(AIBackupModels.shouldTryBackup(after: AIError.httpError(status: 403, message: "only available on agentic harnesses (403)", retryAfterSeconds: nil)))
    }

    @Test("When no model answers, a failure worth waiting out is retried and reported over a permanent one")
    func chainFailurePrefersTheTransient() async throws {
        let config = AITaskConfig(provider: .openRouter, apiKey: "", model: "deepseek/deepseek-v4-flash")
        let rounds = Counter()
        let answer = try await AIBackgroundRetry.run(
            config: config,
            backups: [backup("google/gemma-4-26b-a4b-it:free")],
            pacer: AIRequestPacer(),
            sleep: { _ in }
        ) { candidate in
            if candidate.isBackup {
                if await rounds.next() < 2 {
                    throw AIError.httpError(status: 503, message: "overloaded (503)", retryAfterSeconds: nil)
                }
                return "second round"
            }
            throw AIError.httpError(status: 404, message: "no endpoints (404)", retryAfterSeconds: nil)
        }
        #expect(answer == "second round")

        let permanent = AIError.httpError(status: 404, message: "no endpoints (404)", retryAfterSeconds: nil)
        let transient = AIError.emptyAnswer(model: "m")
        guard case AIError.emptyAnswer = AIBackupModels.chainFailure([permanent, transient]) else {
            Issue.record("expected the transient failure")
            return
        }
        guard case AIError.httpError(404, _, _) = AIBackupModels.chainFailure([permanent, AIError.invalidResponse]) else {
            Issue.record("expected the chosen model's own failure")
            return
        }
    }

    @Test("A model cooling down past a retry's patience is passed over without a request")
    func coolingDownModelIsPassedOver() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let pacer = AIRequestPacer(now: { clock.now })
        let config = AITaskConfig(provider: .openRouter, apiKey: "", model: "google/gemma-4-26b-a4b-it:free")
        let lane = AIRequestPacer.Lane(config: config)
        try await pacer.acquire(lane)
        await pacer.release(lane, after: AIError.httpError(status: 429, message: "daily quota (429)", retryAfterSeconds: 3_600))
        let asked = ModelLog()
        let answer = try await AIBackgroundRetry.run(
            config: config,
            backups: [backup("deepseek/deepseek-v4-flash")],
            pacer: pacer,
            sleep: { _ in }
        ) { candidate in
            await asked.append(candidate.model)
            return candidate.model
        }
        #expect(answer == "deepseek/deepseek-v4-flash")
        #expect(await asked.values == ["deepseek/deepseek-v4-flash"])
    }

    @Test("A call inside a chain does not start a second one, and a backup never repeats the chosen model")
    func nestedChainsAndRepeats() {
        let config = AITaskConfig(provider: .openRouter, apiKey: "", model: "deepseek/deepseek-v4-flash")
        let chain = AIBackupModels.chain(for: config, backups: [backup("deepseek/deepseek-v4-flash"), backup("google/gemma-4-26b-a4b-it:free")])
        #expect(chain.map(\.model) == ["deepseek/deepseek-v4-flash", "google/gemma-4-26b-a4b-it:free"])
        AIBackupModels.$chainIsRunning.withValue(true) {
            #expect(AIBackupModels.chain(for: config, backups: [backup("google/gemma-4-26b-a4b-it:free")]).count == 1)
        }
        // Chat and call-site labels have no backups.
        var chat = config
        chat.taskLabel = AITask.chat.rawValue
        #expect(AIBackupModels.configs(after: chat).isEmpty)
        #expect(AIBackupModels.configs(after: config).isEmpty)
    }

    /// The product owner (2026-09-27): "please allow 10 backups for models that fail;
    /// not just 2".
    @Test("Stored backups keep their order, drop repeats and blanks, and stop at ten")
    func storedBackupsAreNormalized() throws {
        #expect(AIBackupModels.limit == 10)
        let defaults = try #require(UserDefaults(suiteName: "AIBackupModelsTests-\(UUID().uuidString)"))
        let slot = "background.text"
        let models = ["google/gemma-4-26b-a4b-it:free", "deepseek/deepseek-v4-flash", "z-ai/glm-5.3-flash"]
            + (4...12).map { "acme/model-\($0)" }
        // A row names its provider by AIProvider.rawValue, as set(_:slot:) writes it.
        var rows = models.map { ["provider": AIProvider.openRouter.rawValue, "model": $0] }
        rows.insert(["provider": AIProvider.openRouter.rawValue, "model": " "], at: 1)
        rows.insert(["provider": AIProvider.openRouter.rawValue, "model": "Google/Gemma-4-26b-a4b-it:free"], at: 2)
        rows.insert(["provider": "nonsense", "model": "x"], at: 3)
        let json = try JSONSerialization.data(withJSONObject: rows)
        defaults.set(String(decoding: json, as: UTF8.self), forKey: AIBackupModels.key(slot: slot))
        let stored = AIBackupModels.stored(slot: slot, defaults: defaults)
        #expect(stored.map(\.model) == Array(models.prefix(AIBackupModels.limit)))
        #expect(AIBackupModels.stored(slot: "background.images", defaults: defaults).isEmpty)
        #expect(SyncedPreferenceKeys.isSynced(AIBackupModels.key(slot: slot)))
    }

    @Test("A provider failure inside a 200 is the HTTP failure it names, retried like one")
    func inBodyProviderFailureIsItsStatus() async throws {
        let service = AIService(session: .shared)
        let url = try #require(URL(string: "https://ai.foreverlm.com/v1/proxy/openrouter/chat/completions"))
        let ok = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        // OpenRouter's errors page: headers sent, then the provider failed.
        let onlyError: [String: Any] = ["error": [
            "code": 502,
            "message": "Provider returned error",
            "metadata": ["provider_name": "Nebius"],
        ]]
        let failure = try #require(await service.inBodyProviderFailure(label: "OpenRouter request failed", http: ok, json: onlyError))
        guard case .httpError(let status, let message, _) = failure else {
            Issue.record("expected an HTTP failure, got \(failure)")
            return
        }
        #expect(status == 502)
        #expect(message.contains("Nebius"))
        #expect(message.contains("(502)"))
        #expect(AITransientErrorClassifier.isTransient(failure))

        // A generation that failed partway, and an error without a code.
        let midway: [String: Any] = ["choices": [[
            "finish_reason": "error",
            "error": ["code": 429, "message": "Rate limit exceeded upstream"],
            "message": ["role": "assistant", "content": ""],
        ]]]
        let rateLimited = try #require(await service.inBodyProviderFailure(label: "OpenRouter request failed", http: ok, json: midway))
        #expect(AITransientErrorClassifier.isRateLimited(rateLimited))
        let uncoded = try #require(await service.inBodyProviderFailure(label: "OpenRouter request failed", http: ok, json: ["error": ["message": "Upstream error"]]))
        guard case .httpError(502, _, _) = uncoded else {
            Issue.record("an error without a code is OpenRouter's 502, got \(uncoded)")
            return
        }

        let answered: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": "{}"]]]]
        #expect(await service.inBodyProviderFailure(label: "OpenRouter request failed", http: ok, json: answered) == nil)
    }

    @Test("A 200 with no completion is an empty answer to retry, not an unreadable one")
    func missingCompletionIsAnEmptyAnswer() throws {
        let model = "nvidia/nemotron-3-super-120b-a12b:free"
        for json: [String: Any] in [
            ["id": "gen-1", "choices": [[String: Any]]()],
            ["id": "gen-2"],
            ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": NSNull()]]]],
        ] {
            #expect(throws: AIError.self) { try AIService.completionText(in: json, model: model, jsonMode: false) }
            do {
                _ = try AIService.completionText(in: json, model: model, jsonMode: false)
            } catch {
                guard case AIError.emptyAnswer(let named) = error else {
                    Issue.record("expected emptyAnswer, got \(error)")
                    continue
                }
                #expect(named == model)
                #expect(AITransientErrorClassifier.isTransient(error))
                #expect(AIBackgroundRetry.delayBeforeRetry(after: error, failedAttempts: 1, random: 0) != nil)
                #expect(error.localizedDescription != AIError.invalidResponse.localizedDescription)
            }
        }
        // Empty text answers a JSON-mode request with nothing; elsewhere it is
        // the caller's to judge.
        let blank: [String: Any] = ["choices": [["message": ["content": "  "]]]]
        #expect(throws: AIError.self) { try AIService.completionText(in: blank, model: model, jsonMode: true) }
        #expect(try AIService.completionText(in: blank, model: model, jsonMode: false) == "")
        let answer: [String: Any] = ["choices": [["message": ["content": " {\"removeBlocks\":[]} "]]]]
        #expect(try AIService.completionText(in: answer, model: model, jsonMode: true) == "{\"removeBlocks\":[]}")
        #expect(throws: AIError.self) { try AIService.completionText(in: nil, model: model, jsonMode: true) }
    }

    @Test("The drain backs off from a minute to half an hour, never sooner than the provider said")
    func drainRetryDelay() {
        #expect(StudioViewModel.derivedSourceWorkRetryDelay(round: 0, serverWait: nil) == 60)
        #expect(StudioViewModel.derivedSourceWorkRetryDelay(round: 1, serverWait: nil) == 120)
        #expect(StudioViewModel.derivedSourceWorkRetryDelay(round: 20, serverWait: nil) == 30 * 60)
        #expect(StudioViewModel.derivedSourceWorkRetryDelay(round: 0, serverWait: 5 * 3_600) == 5 * 3_600)
        #expect(StudioViewModel.derivedSourceWorkRetryDelay(round: 3, serverWait: 10) == 480)
    }
}

private actor ModelLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor Counter {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
