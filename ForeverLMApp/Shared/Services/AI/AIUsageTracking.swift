import Foundation
import Observation
import os

// macOS-side AI usage ledger writer. The target-agnostic pieces (AIUsageReport,
// AIUsageParser, AIProviderPricing, AIUsageEvent) live in AIUsageReporting.swift,
// which is also compiled into the iOS target.

private let usageLedgerLogger = Logger(subsystem: "com.foreverlm", category: "AIUsageLedger")

/// Visibility for ledger bookkeeping failures. Every failure is counted in the
/// AI Usage & Costs pane and thrown back to the provider workflow: once a call
/// reaches a billable response, silently continuing without its durable record
/// is not an acceptable success state.
enum AIUsageLedgerHealth {
    static let failureCountKey = "ai.usage.ledger_write_failures"
    static let lastFailureKey = "ai.usage.ledger_last_failure"

    static func noteFailure(_ error: Error, provider: String, model: String, operation: String) {
        usageLedgerLogger.error("Usage ledger write failed for \(provider, privacy: .public)/\(model, privacy: .public) \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)")
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: failureCountKey) + 1, forKey: failureCountKey)
        defaults.set(
            "\(provider)/\(model) \(operation): \(error.localizedDescription)",
            forKey: lastFailureKey
        )
    }

    static var failureCount: Int {
        UserDefaults.standard.integer(forKey: failureCountKey)
    }

    static var lastFailureDescription: String? {
        UserDefaults.standard.string(forKey: lastFailureKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: failureCountKey)
        UserDefaults.standard.removeObject(forKey: lastFailureKey)
    }
}

extension Notification.Name {
    /// Posted for every AI usage event as it is recorded, with the event under
    /// `AIUsageTracker.eventUserInfoKey`. Lets live UI (the chat context gauge)
    /// show the latest request's cache read/write counts without polling SQLite.
    static let aiUsageEventRecorded = Notification.Name("AIUsageEventRecorded")
}

actor AIUsageTracker {
    static let shared = AIUsageTracker()
    static let eventUserInfoKey = "event"

    private let storage: StorageService

    init(storage: StorageService = StorageService()) {
        self.storage = storage
    }

    // The sessionID/task defaults read the caller's task-local binding (default
    // arguments evaluate at the call site), so every existing record call
    // inside a bound chat turn attributes itself with no signature changes.
    func record(
        provider: String,
        model: String,
        operation: String,
        report: AIUsageReport? = nil,
        eventID: String = UUID().uuidString,
        createdAt: Date = Date(),
        sessionID: String? = AIUsageAttribution.sessionID,
        task: String? = AIUsageAttribution.task,
        activityID: String? = AIUsageAttribution.activityID,
        subjectID: String? = AIUsageAttribution.subjectID,
        subjectType: String? = AIUsageAttribution.subjectType,
        subjectTitle: String? = AIUsageAttribution.sourceTitle,
        ownKey: Bool? = nil
    ) async throws {
        let cleanProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOperation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTask = task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanProvider.isEmpty,
              !cleanModel.isEmpty,
              !cleanOperation.isEmpty,
              !cleanTask.isEmpty else {
            let error = KnowledgeStoreError.invalidData(
                "AI usage cannot be recorded without provider, model, operation, and task identity."
            )
            AIUsageLedgerHealth.noteFailure(
                error,
                provider: cleanProvider.isEmpty ? "missing-provider" : cleanProvider,
                model: cleanModel.isEmpty ? "missing-model" : cleanModel,
                operation: cleanOperation.isEmpty ? "missing-operation" : cleanOperation
            )
            throw error
        }

        let usage = report ?? .empty
        // Every call must belong to an activity. A chat/review session is the
        // stable activity when one exists; genuinely one-off calls use their
        // immutable event id. Keeping this invariant at the ledger boundary
        // prevents a newly added call path from silently creating anonymous
        // rows even if its higher-level workflow forgot to bind a task local.
        let resolvedActivityID = AIUsageAttribution.resolvedActivityID(
            activityID,
            sessionID: sessionID,
            fallback: eventID
        )
        let event = AIUsageEvent(
            id: eventID,
            provider: cleanProvider,
            model: cleanModel,
            operation: cleanOperation,
            task: cleanTask,
            sessionID: sessionID,
            activityID: resolvedActivityID,
            subjectID: subjectID,
            subjectType: subjectType,
            subjectTitle: subjectTitle,
            createdAt: createdAt,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cachedInputTokens: usage.cachedInputTokens,
            cacheCreationInputTokens: usage.cacheCreationInputTokens,
            reasoningTokens: usage.reasoningTokens,
            audioInputTokens: usage.audioInputTokens,
            audioOutputTokens: usage.audioOutputTokens,
            imageCount: usage.imageCount,
            totalTokens: usage.totalTokens,
            characterCount: usage.characterCount,
            durationSeconds: usage.durationSeconds,
            providerReportedCost: usage.providerReportedCost,
            estimatedCost: AIProviderPricing.estimatedCostUSD(
                provider: cleanProvider,
                model: cleanModel,
                report: usage,
                at: createdAt
            ),
            currency: usage.currency,
            rawUsageJSON: usage.rawUsageJSON,
            clientPlatform: ManagedAI.clientPlatform,
            latencyMilliseconds: usage.latencyMilliseconds,
            ownKey: ownKey ?? Self.wentDirectOnOwnKey(providerShortName: cleanProvider)
        )
        do {
            // A lock another writer holds past the busy timeout clears on its
            // own; losing the row would drop its spend from every total.
            var attempt = 0
            while true {
                do {
                    try await storage.saveAIUsageEvent(event)
                    break
                } catch where KnowledgeStoreError.isTransientLock(error) && attempt < 3 {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                }
            }
        } catch {
            AIUsageLedgerHealth.noteFailure(
                error,
                provider: cleanProvider,
                model: cleanModel,
                operation: cleanOperation
            )
            throw error
        }
        // Live UI observes only durable rows. Posting before the write made a
        // failed event look recorded until the pane reloaded from SQLite.
        #if os(macOS)
        if let cost = event.accountedCostUSD {
            MCPRunningWork.shared.recordSpend(cost, for: MCPRunningWork.currentCallID)
        }
        #endif
        await Self.publishRecordedEvent(event)
    }

    /// Zeroes estimates OpenRouter says it never billed
    /// (`KnowledgeStore.zeroEstimatesOpenRouterDidNotBill`), then prices the
    /// stored rows the rate card can now price and nobody has yet
    /// (`KnowledgeStore.repriceUnpricedAIUsageEvents`). Runs whenever the
    /// price tables load or refresh and whenever the Usage pane opens, so a
    /// row recorded before a rate existed is priced as soon as one does.
    /// A failure leaves those rows unpriced and still counted by the pane's
    /// warning, so it is logged rather than raised.
    static func repriceLedger(storage: StorageService = StorageService()) async {
        do {
            let corrected = try await storage.zeroEstimatesOpenRouterDidNotBill()
            if corrected > 0 {
                usageLedgerLogger.info("Zeroed \(corrected, privacy: .public) usage estimates OpenRouter never billed")
            }
            // Picture calls are priced from OpenRouter's image directory;
            // read it only when a picture row is waiting for a price.
            if try await storage.unpricedImageUsageEventCount() > 0 {
                _ = try? await ImageGenerationDirectory.modelsWithPrices()
            }
            let priced = try await storage.repriceUnpricedAIUsageEvents()
            if priced > 0 {
                usageLedgerLogger.info("Priced \(priced, privacy: .public) usage rows that had no recorded cost")
            }
        } catch {
            usageLedgerLogger.error("Usage ledger repricing failed: \(error.localizedDescription, privacy: .public)")
        }
        // Reading OpenRouter's charge is a network wait, so it never holds up
        // the caller (the Usage pane reloads right after this returns).
        Task.detached(priority: .utility) {
            await resolveGenerationCosts(storage: storage)
        }
    }

    /// Stamps OpenRouter's charge on one row recorded with its generation id.
    /// Reads the record on the full retry schedule, since it was only just
    /// created; a record still unreadable after that is left for
    /// `resolveGenerationCosts`.
    static func resolveGenerationCost(
        eventID: String,
        generationID: String,
        storage: StorageService = StorageService()
    ) async {
        guard let cost = await CloudArticleTTS.openRouterGenerationCostUSD(id: generationID) else { return }
        do {
            try await storage.setAIUsageEventGenerationCost(id: eventID, costUSD: cost)
        } catch {
            usageLedgerLogger.error("Generation cost was not stored: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let generationSweepLock = OSAllocatedUnfairLock(initialState: false)

    /// Finishes every row still waiting on its OpenRouter charge: a lookup that
    /// lost to a rate limit, a record that settled after the retry schedule
    /// ended, an app that quit mid-wait, or a row an iPhone recorded. One
    /// unretried read per row, newest first, so a run is bounded and the next
    /// one (the pane opening, the price tables refreshing) continues.
    static func resolveGenerationCosts(storage: StorageService = StorageService(), limit: Int = 300) async {
        let alreadyRunning = generationSweepLock.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else { return }
        defer { generationSweepLock.withLock { $0 = false } }

        guard let waiting = try? await storage.aiUsageEventsAwaitingGenerationCost(limit: limit),
              !waiting.isEmpty else { return }
        await withTaskGroup(of: (String, Double)?.self) { group in
            for row in waiting {
                guard let generationID = CloudArticleTTS.generationID(inRawUsageJSON: row.rawUsageJSON) else { continue }
                group.addTask {
                    guard let cost = await CloudArticleTTS.openRouterGenerationCostUSD(id: generationID, delays: [0]) else {
                        return nil
                    }
                    return (row.id, cost)
                }
            }
            var resolved = 0
            for await result in group {
                guard let (id, cost) = result else { continue }
                if (try? await storage.setAIUsageEventGenerationCost(id: id, costUSD: cost)) != nil { resolved += 1 }
            }
            if resolved > 0 {
                usageLedgerLogger.info("Read OpenRouter's charge for \(resolved, privacy: .public) usage rows")
            }
        }
    }

    /// Whether this call was paid by the learner's own router key *and* went
    /// straight to that router, which is what `AIUsageEvent.ownKey` records.
    ///
    /// Resolved from the router the provider's traffic actually travels to,
    /// never from the provider label alone: Groq, Cerebras and the rest of the
    /// long tail record their own names while travelling to openrouter.ai,
    /// where an OpenRouter key pays for them. This is the same reason
    /// `AIService.routesThroughOpenRouter` keys off the resolved endpoint
    /// rather than the enum case.
    ///
    /// A router the proxy still spends the key on returns false: that call
    /// produces an authoritative server row, and its client row must keep
    /// deferring to it.
    private static func wentDirectOnOwnKey(providerShortName name: String) -> Bool {
        guard let own = ManagedAI.ownKey, own.router.sendsDirect else { return false }
        guard let provider = AIProvider.allCases.first(where: {
            $0.shortName.caseInsensitiveCompare(name) == .orderedSame
        }) else { return false }
        switch own.router {
        case .openRouter: return AIService.routesThroughOpenRouter(provider)
        }
    }

    /// NotificationCenter publishers deliver synchronously on the posting
    /// thread. Keep the durable write on this actor, then cross to the main
    /// actor before notifying SwiftUI subscribers that update observable state.
    @MainActor
    private static func publishRecordedEvent(_ event: AIUsageEvent) {
        NotificationCenter.default.post(
            name: .aiUsageEventRecorded,
            object: nil,
            userInfo: [Self.eventUserInfoKey: event]
        )
    }
}

/// Latest streamed-chat usage event, republished on the main actor for the
/// chat context gauge. Chat streaming (both the native-tool and text-protocol
/// paths) records with operation "stream_chat"; other operations are ignored.
@MainActor
@Observable
final class ChatUsageLiveMonitor {
    static let shared = ChatUsageLiveMonitor()

    private(set) var latestStreamChatEvent: AIUsageEvent?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {}

    /// Begin observing. Idempotent, so callers can invoke it from any view's
    /// `onAppear` without tracking whether the listener is already running.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .aiUsageEventRecorded,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[AIUsageTracker.eventUserInfoKey] as? AIUsageEvent,
                  event.operation == "stream_chat" else { return }
            // `queue: .main` guarantees this block runs on the main thread, so
            // the isolation is real even though the closure isn't typed for it.
            MainActor.assumeIsolated {
                self?.latestStreamChatEvent = event
            }
        }
    }
}

extension AIProviderPricing {
    /// List-price token rates for a text model, shared by usage estimates and
    /// model-selection UI. Unknown provider/model combinations stay unpriced.
    /// Lives here (not in AIUsageReporting.swift) because `AIProvider` is a
    /// macOS-only type.
    static func textTokenRates(provider: AIProvider, model: String) -> TokenRates? {
        tokenRates(
            provider: provider.shortName.lowercased(),
            model: model.lowercased()
        )
    }
}
