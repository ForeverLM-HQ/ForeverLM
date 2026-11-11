import Foundation
import os

private let backgroundRetryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ForeverLM",
    category: "AIBackgroundRetry"
)

/// Retries and pacing for the background calls that clean up what a learner
/// imports: source cleanup, podcast ad cleanup, transcript formatting and the
/// slide reads of a video's cited-papers scan (product owner, 2026-09-24: Setup's
/// imports must get through, on free and cheap models too, with good retries).
///
/// Each call is retried in place when the failure is transient: exponential
/// backoff with jitter, or the server's own Retry-After when it names one short
/// enough to wait out. A longer wait is handed back to the durable queue, which
/// keeps the work and retries it on its own schedule
/// (`StudioViewModel.derivedSourceWorkRetryDelay`). A permanent failure (a
/// refused key, an invalid request) is never retried.
///
/// Interactive calls do not come through here: a learner waiting on an answer
/// is better served by the error than by a minute of silent retries.
enum AIBackgroundRetry {
    /// Attempts per call, the first included.
    static let maximumAttempts = 4
    static let baseDelay: Double = 2
    /// A 429 without Retry-After: the limits are per-minute windows, so the
    /// first wait is longer than for a dropped connection.
    static let rateLimitBaseDelay: Double = 8
    static let maximumBackoff: Double = 30
    /// The longest Retry-After worth waiting out inside the call.
    static let maximumInlineWait = AITransientErrorClassifier.maximumRetryAfterWait

    /// The wait before the next attempt, or nil to stop and throw.
    /// `random` in 0...1 spreads the retries of a batch that failed together.
    static func delayBeforeRetry(after error: Error, failedAttempts: Int, random: Double) -> Double? {
        guard failedAttempts < maximumAttempts,
              !AITransientErrorClassifier.isCancellation(error),
              AITransientErrorClassifier.isTransient(error) else { return nil }
        if let retryAfter = AITransientErrorClassifier.retryAfterSeconds(error) {
            return retryAfter <= maximumInlineWait ? retryAfter + random : nil
        }
        let base = AITransientErrorClassifier.isRateLimited(error) ? rateLimitBaseDelay : baseDelay
        let exponential = min(maximumBackoff, base * pow(2, Double(max(0, failedAttempts - 1))))
        return exponential * (0.5 + 0.5 * random)
    }

    /// Run one background call with pacing and retries.
    ///
    /// `operation` is handed the model to use: `config` first, then each of
    /// its backup models (`AIBackupModels`) when the one before failed in a
    /// way another model could get past. A retry walks the chain again from
    /// the top. A model whose rate limit outlasts a retry's patience is
    /// passed over without a request, so its backup can answer meanwhile.
    /// `backups` overrides the stored ones (tests pass them).
    static func run<T: Sendable>(
        config: AITaskConfig,
        backups: [AITaskConfig]? = nil,
        pacer: AIRequestPacer = .shared,
        sleep: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        _ operation: (AITaskConfig) async throws -> T
    ) async throws -> T {
        let chain = AIBackupModels.chain(for: config, backups: backups)
        var failures = 0
        while true {
            try Task.checkCancellation()
            var errors: [Error] = []
            for (index, candidate) in chain.enumerated() {
                let lane = AIRequestPacer.Lane(config: candidate)
                let hasNext = index + 1 < chain.count
                do {
                    try await pacer.acquire(lane)
                } catch {
                    if AITransientErrorClassifier.isCancellation(error) { throw error }
                    errors.append(error)
                    guard hasNext, AIBackupModels.shouldTryBackup(after: error) else { break }
                    continue
                }
                do {
                    // The chain is walked here; a call inside must not walk it again.
                    let value = try await AIBackupModels.$chainIsRunning.withValue(true) {
                        try await operation(candidate)
                    }
                    await pacer.release(lane, after: nil)
                    if index > 0 {
                        backgroundRetryLogger.notice(
                            "Backup \(candidate.model, privacy: .public) answered for \(config.model, privacy: .public)"
                        )
                    }
                    return value
                } catch {
                    await pacer.release(lane, after: error)
                    if AITransientErrorClassifier.isCancellation(error) { throw error }
                    errors.append(error)
                    guard hasNext, AIBackupModels.shouldTryBackup(after: error, from: candidate) else { break }
                    backgroundRetryLogger.notice(
                        "\(candidate.model, privacy: .public) failed, trying backup \(chain[index + 1].model, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            let error = AIBackupModels.chainFailure(errors)
            failures += 1
            guard let wait = delayBeforeRetry(
                after: error,
                failedAttempts: failures,
                random: Double.random(in: 0...1)
            ) else { throw error }
            backgroundRetryLogger.notice(
                "Retrying \(config.model, privacy: .public) in \(wait, format: .fixed(precision: 1))s after attempt \(failures): \(error.localizedDescription, privacy: .public)"
            )
            try await sleep(wait)
        }
    }
}

// MARK: - Backup models

/// Up to ten models a background model setting falls back to, in order, when
/// the model it names cannot give an answer. The product owner asked for this on
/// 2026-09-27, after a paper's cleanup stopped on free Nemotron: "for certain
/// models, especially free ones, we can add some backup models", and raised
/// the limit from two the same day. Both of Settings › Background's models
/// can list them, Text-only and Multimodal, and every background task uses the
/// backups of the one it runs on.
///
/// A backup is tried as soon as the model before it fails in a way another
/// model could get past: busy or rate-limited, an empty answer, a refusal, or
/// an answer the work could not use. A failure every model would share never
/// moves on: cancellation, no connection, no key, no balance. Each backup is
/// resolved as the chosen model is (its key, reading images, a failed test
/// run). It is never sent a request cut down to fit a smaller
/// context window; a backup that cannot take the whole request is passed
/// over (`AIService.call`). The ledger names the model that answered.
///
/// A chat the learner types in has no backups: they chose the model they are
/// talking to. The Chat model's backups (slot `chat`) serve the chats nobody
/// is watching, a scheduled task's runs (`ScheduledTaskRunner`, the product owner,
/// 2026-09-27: a task turned on overnight, on a free model, should not simply
/// error out). They are chosen on the Chat pane's cards like any other
/// setting's.
enum AIBackupModels {
    /// Synced: `aiBackups.<slot>` holds a JSON array of provider and model
    /// pairs, in order. Slots are `ModelPickerSlot` ids: `chat`,
    /// `background.text` and `background.images`.
    static let keyPrefix = Prefs.Families.aiBackups.prefix
    /// The most backups a setting may list, from Settings or over MCP
    /// (product owner, 2026-09-27: "please allow 10 backups for models that fail;
    /// not just 2"). What a learner may set, not what is set for them: a
    /// free pick brings `FreeModelsSetup.freeBackupCount` of its own.
    static let limit = 10

    private struct StoredRoute: Codable {
        let provider: String
        let model: String
    }

    static func key(slot: String) -> String { Prefs.Families.aiBackups.name(slot) }

    /// The Chat model's slot, `ModelPickerSlot.chat.id`. Only a scheduled
    /// task's run walks it.
    static let chatSlot = "chat"

    /// A scheduled run's backups, in order, each resolved as a background
    /// backup is (its key, a model OpenRouter refuses, a failed test run of
    /// chat) and labelled `chat` in the ledger. Keychain reads:
    /// call off the main actor.
    static func chatConfigs() -> [AITaskConfig] {
        stored(slot: chatSlot).compactMap { config(for: $0, task: .chat) }
    }

    /// The slot whose backups a task uses: its Background model's. Nil for
    /// chat and anything else that does not run on a Background model.
    static func slot(for task: AITask) -> String? {
        guard task.usesBackgroundModelDefault, AITask.advancedTasks.contains(task) else { return nil }
        return backgroundSlot(multimodal: task.usesMultimodalBackgroundModelDefault)
    }

    static func backgroundSlot(multimodal: Bool) -> String {
        multimodal ? "background.images" : "background.text"
    }

    /// The slot's backups in order, without repeats or retired providers.
    static func stored(slot: String, defaults: UserDefaults = .standard) -> [AITaskModelRoute] {
        guard let text = defaults.string(forKey: key(slot: slot)),
              let data = text.data(using: .utf8),
              let rows = try? JSONDecoder().decode([StoredRoute].self, from: data)
        else { return [] }
        return normalized(rows.compactMap { row in
            AIProvider(rawValue: row.provider).map { AITaskModelRoute(provider: $0, model: row.model) }
        })
    }

    /// Every slot that lists backups.
    static func allStored(defaults: UserDefaults = .standard) -> [String: [AITaskModelRoute]] {
        var result: [String: [AITaskModelRoute]] = [:]
        for slot in Prefs.Families.aiBackups.rows(in: defaults).keys {
            let routes = stored(slot: slot, defaults: defaults)
            if !routes.isEmpty { result[slot] = routes }
        }
        return result
    }

    /// Replaces the slot's backups. An empty list removes the row.
    static func set(_ routes: [AITaskModelRoute], slot: String) {
        let routes = normalized(routes)
        let rows = routes.map { StoredRoute(provider: $0.provider.rawValue, model: $0.model) }
        if rows.isEmpty {
            Preferences.reset(Prefs.Families.aiBackups.key(slot))
        } else if let data = try? JSONEncoder().encode(rows), let text = String(data: data, encoding: .utf8) {
            Preferences.set(text, for: Prefs.Families.aiBackups.key(slot))
        }
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    private static func normalized(_ routes: [AITaskModelRoute]) -> [AITaskModelRoute] {
        var seen = Set<String>()
        var kept: [AITaskModelRoute] = []
        for route in routes {
            let model = route.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, route.provider.canServeStoredSelection else { continue }
            guard seen.insert(identity(route.provider, model)).inserted else { continue }
            kept.append(AITaskModelRoute(provider: route.provider, model: model))
            if kept.count == limit { break }
        }
        return kept
    }

    /// One model under two hosts' names ("gpt-5.6", "openai/gpt-5.6") is one.
    static func identity(_ provider: AIProvider, _ model: String) -> String {
        OpenRouterModelID.slug(provider: provider, model: model).lowercased()
    }

    /// Whether another model could get past this failure. A failure every
    /// model would meet the same way stops the chain. `candidate` is the model
    /// that failed: a free one that gets a 402 is the one model OpenRouter now
    /// charges for ("no longer free"), not an empty balance, so its backups
    /// still answer.
    static func shouldTryBackup(after error: Error, from candidate: AITaskConfig? = nil) -> Bool {
        if AITransientErrorClassifier.isCancellation(error) { return false }
        // The connection, not the model.
        if error is URLError { return false }
        switch error {
        case AIError.missingAPIKey, AIError.serviceUnreachable:
            return false
        case AIError.httpError(let status, _, _):
            // 401 is the key and 402 the balance, whichever model is asked.
            if status == 402, let candidate,
               AIFreeModels.isFreeSelection(provider: candidate.provider, model: candidate.model) { return true }
            return status != 401 && status != 402
        default:
            return true
        }
    }

    /// Set while a chain is being walked, so a call made inside it does not
    /// walk the chain again: `AIBackgroundRetry.run` wraps calls that go
    /// through `AIService.call`.
    @TaskLocal static var chainIsRunning = false

    /// The models to try, `primary` first. Only `primary` inside a chain.
    static func chain(for primary: AITaskConfig, backups: [AITaskConfig]? = nil) -> [AITaskConfig] {
        guard !chainIsRunning else { return [primary] }
        let primaryIdentity = identity(primary.provider, primary.model)
        var seen: Set<String> = [primaryIdentity]
        return [primary] + (backups ?? configs(after: primary)).filter {
            seen.insert(identity($0.provider, $0.model)).inserted
        }
    }

    /// The backups to try after `primary`, resolved as `resolveConfig`
    /// resolves the model it stands in for. Empty for a config that serves
    /// no background task (chat, or a call site's own label).
    static func configs(after primary: AITaskConfig) -> [AITaskConfig] {
        guard let label = primary.taskLabel,
              let task = AITask(rawValue: label),
              let slot = Self.slot(for: task) else { return [] }
        return stored(slot: slot).compactMap { config(for: $0, task: task) }
    }

    private static func config(for route: AITaskModelRoute, task: AITask) -> AITaskConfig? {
        if AIModelDefaults.isRetiredChatModel(provider: route.provider, model: route.model) { return nil }
        if task.requiresVision,
           KeychainService.modelSupportsVision(provider: route.provider, model: route.model) != true {
            return nil
        }
        let routed = KeychainService.routedTextSelection(provider: route.provider, model: route.model)
        // A meeting that stays off free models stays off free backups too.
        if MeetingModels.staysOffFree(task),
           AIFreeModels.isFreeSelection(provider: routed.provider, model: routed.model) {
            return nil
        }
        // A free backup whose free period ended would bill for work the
        // learner set up to cost nothing. The price watch says so, and the
        // replacement moves the backup on; until then it sits out.
        if AIFreeModels.isFreeModelID(routed.model), AIFreeModelPrices.hasEnded(routed.model) { return nil }
        // OpenRouter refuses it to ForeverLM, or it failed a test run of this
        // work: asking it again only delays the answer.
        if AIFreeModelRestrictions.isRestricted(routed.model) { return nil }
        if AIModelQualification.failureMessage(
            provider: routed.provider,
            model: routed.model,
            role: task.qualificationRole
        ) != nil { return nil }
        guard let apiKey = KeychainService.apiKey(for: routed.provider) else { return nil }
        var config = AITaskConfig(provider: routed.provider, apiKey: apiKey, model: routed.model)
        config.taskLabel = task.rawValue
        config.isBackup = true
        return config
    }

    /// The failure a chain that found no answer reports: the first one worth
    /// waiting out, since a later try may then succeed; otherwise the chosen
    /// model's own.
    static func chainFailure(_ errors: [Error]) -> Error {
        errors.first { AITransientErrorClassifier.isTransient($0) }
            ?? errors.first
            ?? AIError.invalidResponse
    }

    /// Runs `operation` on `primary`, then on each backup while the failure
    /// is one another model could get past. For a single call; queue work
    /// that paces and retries goes through `AIBackgroundRetry.run`.
    static func run<T: Sendable>(
        primary: AITaskConfig,
        _ operation: (AITaskConfig) async throws -> T
    ) async throws -> T {
        let chain = Self.chain(for: primary)
        guard chain.count > 1 else { return try await operation(primary) }
        return try await $chainIsRunning.withValue(true) {
            var errors: [Error] = []
            for (index, candidate) in chain.enumerated() {
                do {
                    let value = try await operation(candidate)
                    if index > 0 {
                        backgroundRetryLogger.notice(
                            "Backup \(candidate.model, privacy: .public) answered for \(primary.model, privacy: .public)"
                        )
                    }
                    return value
                } catch {
                    if AITransientErrorClassifier.isCancellation(error) { throw error }
                    errors.append(error)
                    guard index + 1 < chain.count, shouldTryBackup(after: error, from: candidate) else { break }
                    backgroundRetryLogger.notice(
                        "\(candidate.model, privacy: .public) failed, trying backup \(chain[index + 1].model, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw chainFailure(errors)
        }
    }
}

/// How many background calls may be in flight per model, and when a model
/// may be called again after a rate limit.
///
/// Additive increase, multiplicative decrease: every 429 halves the model's
/// concurrency and every run of successes as long as the current limit adds
/// one back. A free model starts at two, since OpenRouter serves free models
/// about twenty requests a minute; a paid one starts at 24. A rate limit that names its reset
/// (Retry-After, or OpenRouter's X-RateLimit-Reset, which is how the daily
/// free-model quota says when it refills) holds every call to that model until
/// then, and a call that would wait longer than a retry should is refused at
/// once, without a request, so the queue can wait instead of the provider
/// being asked again for nothing.
actor AIRequestPacer {
    static let shared = AIRequestPacer()

    struct Lane: Hashable, Sendable {
        let model: String
        let isFree: Bool

        init(config: AITaskConfig) {
            model = config.model
            isFree = AIFreeModels.isFreeSelection(provider: config.provider, model: config.model)
        }

        init(model: String, isFree: Bool) {
            self.model = model
            self.isFree = isFree
        }

        /// A paid model starts above what the drains put in flight together
        /// (twelve source cleanups, two podcast passes of two chunks, a few
        /// transcripts), so pacing only ever bites once a model pushes back.
        var initialLimit: Int { isFree ? 2 : 24 }
        var ceiling: Int { isFree ? 4 : 48 }
    }

    private struct State {
        var limit: Int
        var inFlight = 0
        var successesSinceIncrease = 0
        var cooldownUntil: Date?
    }

    private var states: [Lane: State] = [:]
    private var waiters: [Lane: [(id: UUID, continuation: CheckedContinuation<Void, Never>)]] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Wait for a slot on `lane`.
    ///
    /// Nonisolated on purpose: every read and write of `states` and `waiters`
    /// happens inside an isolated method this awaits (`admit`, `park`,
    /// `resumeWaiter`), so none of it rests on a hop back to the actor after
    /// a waiter is resumed. Swift 6.4's optimizer dropped that hop when this
    /// loop ran on the actor: the closure handed to the nonisolated(nonsending)
    /// `withTaskCancellationHandler` lost its return to the actor after its
    /// continuation resumed, the caller skips its own hop after such a call,
    /// and the woken waiter ran the rest of the loop on the cooperative pool,
    /// appending to `waiters` beside the actor. Release builds only; build 216
    /// crashed in `Array.append` when twelve transcript formats queued on a
    /// free lane at once.
    nonisolated func acquire(_ lane: Lane) async throws {
        while true {
            try Task.checkCancellation()
            switch try await admit(lane) {
            case .admitted:
                return
            case .coolingDown(let remaining):
                try await Task.sleep(for: .seconds(remaining))
            case .full:
                let id = UUID()
                await withTaskCancellationHandler {
                    await self.park(id, in: lane)
                } onCancel: {
                    Task { await self.resumeWaiter(id, in: lane) }
                }
            }
        }
    }

    private enum Admission: Sendable {
        case admitted
        case coolingDown(Double)
        case full
    }

    /// Take a slot if one is free. A cooldown longer than a retry's patience
    /// is refused here, without a request.
    private func admit(_ lane: Lane) throws -> Admission {
        var state = states[lane] ?? State(limit: lane.initialLimit)
        if let until = state.cooldownUntil {
            let remaining = until.timeIntervalSince(now())
            if remaining > AIBackgroundRetry.maximumInlineWait {
                throw Self.coolingDown(lane, until: until, remaining: remaining)
            }
            if remaining > 0 { return .coolingDown(remaining) }
            state.cooldownUntil = nil
        }
        if state.inFlight < state.limit {
            state.inFlight += 1
            states[lane] = state
            return .admitted
        }
        states[lane] = state
        return .full
    }

    /// Wait until `release` or a cancel resumes this waiter.
    ///
    /// The check and the append are one step on the actor, so nothing slips
    /// between them: a slot freed since `admit` sends the caller straight back
    /// to try again, and so does a cancel that landed first, whose
    /// `resumeWaiter` would otherwise find nothing to resume and leave this
    /// waiting forever.
    private func park(_ id: UUID, in lane: Lane) async {
        await withCheckedContinuation { continuation in
            let state = states[lane] ?? State(limit: lane.initialLimit)
            if Task.isCancelled || state.inFlight < state.limit {
                continuation.resume()
                return
            }
            waiters[lane, default: []].append((id, continuation))
        }
    }

    /// Give the slot back. `error` is nil after a success.
    func release(_ lane: Lane, after error: Error?) {
        var state = states[lane] ?? State(limit: lane.initialLimit)
        state.inFlight = max(0, state.inFlight - 1)
        if let error {
            if AITransientErrorClassifier.isRateLimited(error) {
                state.limit = max(1, state.limit / 2)
                state.successesSinceIncrease = 0
                if let retryAfter = AITransientErrorClassifier.retryAfterSeconds(error), retryAfter > 0 {
                    let until = now().addingTimeInterval(retryAfter)
                    state.cooldownUntil = max(state.cooldownUntil ?? until, until)
                }
            }
        } else {
            state.successesSinceIncrease += 1
            if state.successesSinceIncrease >= state.limit {
                state.limit = min(lane.ceiling, state.limit + 1)
                state.successesSinceIncrease = 0
            }
        }
        states[lane] = state
        // Wake everyone waiting: each re-checks the limit and the cooldown,
        // and those that do not fit wait again.
        let woken = waiters.removeValue(forKey: lane) ?? []
        for waiter in woken { waiter.continuation.resume() }
    }

    func limit(for lane: Lane) -> Int { states[lane]?.limit ?? lane.initialLimit }
    func cooldownUntil(for lane: Lane) -> Date? { states[lane]?.cooldownUntil }
    func waiterCount(for lane: Lane) -> Int { waiters[lane]?.count ?? 0 }

    private func resumeWaiter(_ id: UUID, in lane: Lane) {
        guard var list = waiters[lane], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let waiter = list.remove(at: index)
        waiters[lane] = list
        waiter.continuation.resume()
    }

    /// The refusal for a call that would wait past a retry's patience. It is a
    /// 429 carrying the time left, so every queue files it as a rate limit to
    /// wait out, never as a failure of the source.
    private static func coolingDown(_ lane: Lane, until: Date, remaining: Double) -> AIError {
        let time = until.formatted(date: .omitted, time: .shortened)
        return AIError.httpError(
            status: 429,
            message: "\(lane.model) hit its rate limit; waiting work resumes at \(time). (429)",
            retryAfterSeconds: remaining
        )
    }
}

// MARK: - Meetings off free models

/// Meetings do not follow background work onto a free model. A meeting's
/// transcript holds private conversations, and free models' providers may
/// keep and train on what is sent (product owner, 2026-09-27). Setup asks whether
/// they may when background work goes free; unless the learner lets them, a
/// meeting task whose Background model is free runs on that model's first
/// paid backup instead and skips its free backups. With no paid backup the
/// task waits, like one with no key: ForeverLM no longer picks a paid model
/// the learner never chose (product owner, 2026-10-07: "don't do this by default").
/// A model the learner sets for the task itself is theirs
/// (`KeychainService.taskRoute(for:)`) and is not second-guessed.
///
/// A rule rather than a setting: until 2026-09-28 Setup kept meetings paid
/// by giving each meeting task a model of its own, and those went with the
/// Specific tasks menu.
enum MeetingModels {
    /// Synced, with the rest of `aiBackground.`: Setup's answer. False, the
    /// recommendation, keeps meetings on a paid model.
    static let mayUseFreeKey = Prefs.Models.meetingsMayUseFree.name

    /// Setup's one sentence on why meetings stay on a paid model.
    static let privacyReason = "A meeting's transcript holds private conversations, and free models' providers may keep and train on what is sent."

    /// The background tasks that read a meeting's recording or transcript.
    static var tasks: [AITask] {
        AITask.advancedTasks.filter { $0.sourceType == .meeting }
    }

    static var mayUseFree: Bool {
        Preferences.value(Prefs.Models.meetingsMayUseFree) ?? false
    }

    static func setMayUseFree(_ allowed: Bool) {
        Preferences.set(allowed, for: Prefs.Models.meetingsMayUseFree)
        NotificationCenter.default.post(name: .aiProviderDidChange, object: nil)
    }

    static func isFree(_ route: AITaskModelRoute) -> Bool {
        AIFreeModels.isFreeSelection(provider: route.provider, model: route.model)
    }

    /// Whether `task` is kept off free models now.
    static func staysOffFree(_ task: AITask, mayUseFree: Bool = MeetingModels.mayUseFree) -> Bool {
        task.sourceType == .meeting && !mayUseFree
    }

    /// The model `task` runs on when its Background model is `background`:
    /// that model, unless the task stays off free models and it is free, in
    /// which case the paid one, or nil (the task waits) when there is none.
    static func route(
        for task: AITask,
        background: AITaskModelRoute,
        staysOffFree: Bool,
        paid: () -> AITaskModelRoute?,
        isFree: (AITaskModelRoute) -> Bool = MeetingModels.isFree
    ) -> AITaskModelRoute? {
        guard staysOffFree, isFree(background) else { return background }
        return paid()
    }

    /// The paid model a meeting runs on while its Background model is free:
    /// that model's first paid backup, which is the paid model the learner
    /// chose for the work (Setup's recommended set puts it there, on its hosts
    /// in the US). Nil when it has none: the meeting waits for the learner to
    /// choose one. A backup's host choice is kept on the Background model's
    /// slot, so the meeting follows it there.
    static func paidRoute(
        multimodal: Bool,
        defaults: UserDefaults = .standard,
        isFree: (AITaskModelRoute) -> Bool = MeetingModels.isFree
    ) -> AITaskModelRoute? {
        let slot = AIBackupModels.backgroundSlot(multimodal: multimodal)
        return AIBackupModels.stored(slot: slot, defaults: defaults).first(where: { !isFree($0) })
    }
}
