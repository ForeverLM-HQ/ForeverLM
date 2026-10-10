import Foundation
import Testing
@testable import ForeverLM

@Suite("Slow free model offer")
struct SlowFreeModelOfferTests {
    @Test("The offer waits for a long silence from a free model, and never comes back once dismissed")
    func offerNeedsAFreeModelSilentPastTheDelay() {
        let delay = SlowFreeModelWait.offerDelay
        #expect(SlowFreeModelWait.shouldOffer(isOnFreeModel: true, isWaitingForText: true, waited: delay, isDismissed: false))
        #expect(!SlowFreeModelWait.shouldOffer(isOnFreeModel: true, isWaitingForText: true, waited: delay - 1, isDismissed: false))
        // A paid model, an answer already landing, or Don't Ask Again.
        #expect(!SlowFreeModelWait.shouldOffer(isOnFreeModel: false, isWaitingForText: true, waited: delay * 3, isDismissed: false))
        #expect(!SlowFreeModelWait.shouldOffer(isOnFreeModel: true, isWaitingForText: false, waited: delay * 3, isDismissed: false))
        #expect(!SlowFreeModelWait.shouldOffer(isOnFreeModel: true, isWaitingForText: true, waited: delay * 3, isDismissed: true))
    }

    @Test("Don't Ask Again follows the account to every Mac")
    func dismissalSyncs() {
        #expect(SyncedPreferenceKeys.isSynced(SlowFreeModelWait.dismissedKey))
        #expect(SyncedPreferenceKeys.excluded[SlowFreeModelWait.dismissedKey] == nil)
    }

    private typealias Message = ReviewSessionManager.Message

    private static func toolRow(_ kind: Message.ToolActivity.Kind) -> Message {
        Message(
            role: .tool,
            content: "",
            toolActivity: Message.ToolActivity(kind: kind, toolName: "retrieve_sources", detail: nil, state: .succeeded, resultPreview: nil)
        )
    }

    @Test("A turn that has written nothing and run no tool can be asked again; one that has cannot")
    @MainActor
    func turnHasActedReadsOnlyTheRunningTurn() {
        let earlier: [Message] = [
            Message(role: .user, content: "What is a crista junction?"),
            Self.toolRow(.tool),
            Message(role: .assistant, content: "The narrow neck of a crista."),
            Message(role: .user, content: "And its width?"),
        ]
        // Only the thinking and a stream retry so far, and the empty reply row.
        let silent = earlier + [Self.toolRow(.thinking), Self.toolRow(.retry), Message(role: .assistant, content: " \n")]
        #expect(!ReviewSessionManager.turnHasActed(in: silent))
        #expect(!ReviewSessionManager.turnHasActed(in: earlier))
        // A tool ran: asking again could run it twice.
        #expect(ReviewSessionManager.turnHasActed(in: earlier + [Self.toolRow(.tool)]))
        // The reply has begun.
        #expect(ReviewSessionManager.turnHasActed(in: earlier + [Message(role: .assistant, content: "About 20")]))
    }

    private static let config = AITaskConfig(provider: .openRouter, apiKey: "test-key", model: "openrouter/free")

    private static func storedPairs(_ storage: StorageService, sessionID: String) async throws -> [(answer: String?, reply: String?)] {
        try await storage.loadReviewSessionExchanges(sessionID: sessionID)
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
            .map { (answer: $0.userAnswer, reply: $0.evaluation) }
    }

    @Test("Asked again on another model before a word, the turn leaves no error, no reply and an open row for the next one")
    @MainActor
    func restartBeforeAnyTextKeepsTheRowOpen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlowFreeModelRestart_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Cristae", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)

        await manager.saveLearnerMessageForTesting("how wide is a crista junction?")
        manager.beginTurnForTesting()
        let restarts = await manager.restartTurnForTesting(streamed: "", config: Self.config)

        #expect(restarts)
        #expect(manager.errorMessage == nil)
        #expect(!manager.canRetryLastGeneration)
        #expect(!manager.chatMessages.contains { $0.role == .assistant })
        let waiting = try await Self.storedPairs(storage, sessionID: "chat")
        #expect(waiting.map { $0.reply } == [nil])

        // The same turn again, now on the paid model: its reply takes the row.
        manager.beginTurnForTesting()
        let reply = "Around 20 to 40 nanometres."
        try await manager.finishTurnForTesting(reply: reply, config: Self.config)
        let pairs = try await Self.storedPairs(storage, sessionID: "chat")
        #expect(pairs.map { $0.answer } == ["how wide is a crista junction?"])
        #expect(pairs.map { $0.reply } == [reply])
    }

    @Test("Words that landed before the switch took hold end the turn as a Stop, with the words kept")
    @MainActor
    func restartAfterTextIsAStop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlowFreeModelRestartLate_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(storeRoot: root)
        try await storage.createReviewSession(id: "chat", topic: "Cristae", sourceIDs: [])
        let manager = ReviewSessionManager(storage: storage)
        manager.configureNavigationStateForTesting(sessionID: "chat", generationInFlight: false)

        await manager.saveLearnerMessageForTesting("how wide is a crista junction?")
        manager.beginTurnForTesting()
        let restarts = await manager.restartTurnForTesting(streamed: "Around 20", config: Self.config)

        #expect(!restarts)
        #expect(manager.errorMessage == nil)
        #expect(manager.chatMessages.last?.content == "Around 20")
        let kept = try await Self.storedPairs(storage, sessionID: "chat")
        #expect(kept.map { $0.reply } == ["Around 20"])
    }
}
