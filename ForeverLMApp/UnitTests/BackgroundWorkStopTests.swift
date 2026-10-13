import Foundation
import Testing
@testable import ForeverLM

/// Stop on a paid step in the background-work list (`AIInFlightCalls`): the
/// step's requests in flight end at once and are aborted. A step that runs on
/// its own stays stopped until the learner resumes it, except for work they
/// ask for themselves; a step they asked for is only cancelled. Serialized:
/// the tests share one held stub. Each test binds a registry of its own with
/// stops kept in memory, so nothing reaches this Mac's settings or another
/// test's calls.
@Suite("Stopping a paid step", .serialized)
struct BackgroundWorkStopTests {
    /// A step that runs on its own (`AIUsageTaskNeed.optional`) and is no
    /// `AITask`, so no backup model or route is read from this Mac's settings.
    private static let backgroundStep = "meeting_icon"

    private func config(step: String) -> AITaskConfig {
        var config = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6")
        config.taskLabel = step
        return config
    }

    private func ask(_ service: AIService, _ config: AITaskConfig, _ question: String) -> Task<String, Error> {
        Task {
            try await service.call(config: config, system: "Answer in one sentence.", user: question, maxTokens: 64)
        }
    }

    @Test("Stop ends a background step's call in flight, aborts its request, and refuses the next until resumed", .timeLimit(.minutes(1)))
    func stopEndsAndHoldsTheStep() async throws {
        let registry = AIInFlightCalls(stops: .memory())
        let step = Self.backgroundStep
        #expect(AIInFlightCalls.staysStopped(step))
        StepStopHeldURLProtocol.reset(reply: "Protons leak back through the membrane.")
        let service = AIService(session: StepStopHeldURLProtocol.mockSession())
        let config = config(step: step)

        try await AIInFlightCalls.$current.withValue(registry) {
            let running = ask(service, config, "Why does the membrane potential fall?")
            try await StepStopHeldURLProtocol.waitUntil { started, _ in started == 1 }
            #expect(registry.snapshot.contains { $0.step == step })

            #expect(registry.stop(step: step) == 1)
            let result = await running.result
            guard case .failure(let error) = result, let stopped = error as? AIStepStoppedError else {
                Issue.record("expected the call to end as stopped, got \(result)")
                return
            }
            #expect(AITransientErrorClassifier.isCancellation(stopped))
            #expect(stopped.step == AIInFlightCalls.stepName(step) && stopped.staysStopped)
            // Nobody reads the reply any more, so the request is aborted too.
            try await StepStopHeldURLProtocol.waitUntil { _, aborted in aborted == 1 }
            #expect(registry.snapshot.isEmpty)
            #expect(registry.stoppedSteps.map(\.step) == [step])

            // The queue asking again is refused before any request is made.
            let refused = await ask(service, config, "What drives ATP synthase?").result
            guard case .failure(let refusal) = refused, refusal is AIStepStoppedError else {
                Issue.record("expected the stopped step to be refused, got \(refused)")
                return
            }
            #expect(StepStopHeldURLProtocol.counts().started == 1)

            // Work the learner asks for themselves still runs.
            let asked = AIUsageAttribution.$learnerAsked.withValue(true) {
                ask(service, config, "What does uncoupling protein 1 do?")
            }
            try await StepStopHeldURLProtocol.waitUntil { started, _ in started == 2 }
            StepStopHeldURLProtocol.releaseAll()
            #expect(try await asked.value == "Protons leak back through the membrane.")

            // Resumed, the step runs for the queue again.
            registry.resume(step: step)
            #expect(registry.stoppedSteps.isEmpty)
            let resumed = ask(service, config, "Where is the proton gradient kept?")
            try await StepStopHeldURLProtocol.waitUntil { started, _ in started == 3 }
            StepStopHeldURLProtocol.releaseAll()
            #expect(try await resumed.value == "Protons leak back through the membrane.")
        }
    }

    @Test("Stop cancels a step the learner asked for without holding it, so asking again runs it", .timeLimit(.minutes(1)))
    func stopOnlyCancelsRequestedWork() async throws {
        let registry = AIInFlightCalls(stops: .memory())
        // A label nothing classifies: work the learner asked for.
        let step = "stop_test_requested"
        #expect(!AIInFlightCalls.staysStopped(step))
        StepStopHeldURLProtocol.reset(reply: "A proton gradient.")
        let service = AIService(session: StepStopHeldURLProtocol.mockSession())
        let config = config(step: step)

        try await AIInFlightCalls.$current.withValue(registry) {
            let running = ask(service, config, "What does the electron transport chain build?")
            try await StepStopHeldURLProtocol.waitUntil { started, _ in started == 1 }
            #expect(registry.stop(step: step) == 1)
            let result = await running.result
            guard case .failure(let error) = result, let stopped = error as? AIStepStoppedError else {
                Issue.record("expected the call to end as stopped, got \(result)")
                return
            }
            #expect(!stopped.staysStopped)
            #expect(registry.stoppedSteps.isEmpty)

            let again = ask(service, config, "What does the gradient drive?")
            try await StepStopHeldURLProtocol.waitUntil { started, _ in started == 2 }
            StepStopHeldURLProtocol.releaseAll()
            #expect(try await again.value == "A proton gradient.")
        }
    }

    @Test("A chat the learner is typing in is not listed, and a stop never reaches it")
    func chatTurnsAreNotListed() throws {
        let registry = AIInFlightCalls(stops: .memory())
        for step in AIInFlightCalls.chatTurnSteps {
            #expect(try registry.begin(taskLabel: step, sourceTitle: nil, subjectID: nil) == nil)
        }
        #expect(registry.snapshot.isEmpty)
    }

    @Test("A stop that lands before the request's cancel handle is attached cancels it on attach")
    func stopBeforeAttachCancelsAtOnce() throws {
        let registry = AIInFlightCalls(stops: .memory())
        let id = try registry.begin(taskLabel: Self.backgroundStep, sourceTitle: "Bioenergetics 4", subjectID: "meeting-1")
        #expect(registry.stop(step: Self.backgroundStep) == 0, "nothing to cancel yet")
        let cancelled = Flag()
        registry.attach(id) { cancelled.set() }
        #expect(cancelled.isSet)
        #expect(registry.end(id), "the request reports that it was stopped")
    }

    @Test("Stopping one step leaves other steps running")
    func stopIsPerStep() throws {
        let registry = AIInFlightCalls(stops: .memory())
        let id = try registry.begin(taskLabel: "notebook_cover", sourceTitle: nil, subjectID: nil)
        let cancelled = Flag()
        registry.attach(id) { cancelled.set() }
        registry.stop(step: Self.backgroundStep)
        #expect(!cancelled.isSet)
        #expect(!registry.end(id))
        #expect(throws: AIStepStoppedError.self) {
            try registry.begin(taskLabel: Self.backgroundStep, sourceTitle: nil, subjectID: nil)
        }
    }

    @Test("A stop made on another Mac cancels what this Mac is already running, but not what the learner asked for")
    func remoteStopCancelsInFlight() throws {
        let store = AIInFlightCalls.StoppedStepsStore.memory()
        let registry = AIInFlightCalls(stops: store)
        let queued = try registry.begin(taskLabel: Self.backgroundStep, sourceTitle: nil, subjectID: nil)
        let queuedCancelled = Flag()
        registry.attach(queued) { queuedCancelled.set() }
        let asked = try AIUsageAttribution.$learnerAsked.withValue(true) {
            try registry.begin(taskLabel: Self.backgroundStep, sourceTitle: nil, subjectID: nil)
        }
        let askedCancelled = Flag()
        registry.attach(asked) { askedCancelled.set() }

        // The synced list arrives from the other Mac.
        store.write([Self.backgroundStep])
        registry.cancelInFlightOfStoppedSteps()
        #expect(queuedCancelled.isSet)
        #expect(!askedCancelled.isSet)
    }

    @Test("A stopped step reads as a cancellation, typed or flattened into a message, and ends the backup chain")
    func stoppedReadsAsCancellation() {
        let error = AIStepStoppedError(step: "Text-to-Speech Preparation", staysStopped: true)
        #expect(AITransientErrorClassifier.isCancellation(error))
        #expect(AITransientErrorClassifier.shouldRetryAutomatically(error))
        #expect(!AIBackupModels.shouldTryBackup(after: error))
        let flattened = "Could not prepare this paper for reading aloud: \(error.localizedDescription)"
        #expect(AITransientErrorClassifier.isCancellationMessage(flattened))
        #expect(AITransientErrorClassifier.isCancellationMessage(error.localizedDescription))
        #expect(AITransientErrorClassifier.isCancellation(AIError.apiError(flattened)))
        #expect(error.localizedDescription.hasPrefix("You stopped Text-to-Speech Preparation."))
        #expect(AIStepStoppedError(step: "Write Report", staysStopped: false).localizedDescription == "You stopped Write Report.")
    }

    @Test("Background steps stay stopped and requested ones do not, as AI Usage classifies them")
    func whatStaysStopped() {
        #expect(AIInFlightCalls.staysStopped(AITask.paperTextToSpeechPreparation.rawValue))
        #expect(AIInFlightCalls.staysStopped(AITask.paperMetadata.rawValue))
        #expect(AIInFlightCalls.staysStopped("notebook_cover"))
        #expect(AIInFlightCalls.staysStopped("podcast_transcription"))
        #expect(AIInFlightCalls.staysStopped(AutomaticAudioStep.step))
        #expect(!AIInFlightCalls.staysStopped(AITask.reportWriting.rawValue))
        #expect(!AIInFlightCalls.staysStopped("doc_image"))
        #expect(!AIInFlightCalls.staysStopped(""))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Holds every request until the test releases it, the way a slow model holds
/// a step, and counts the requests URLSession aborted while they were held.
private final class StepStopHeldURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = ""
    nonisolated(unsafe) private static var held: [StepStopHeldURLProtocol] = []
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var aborted = 0

    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StepStopHeldURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset(reply: String) {
        lock.withLock { self.reply = reply; held = []; started = 0; aborted = 0 }
    }

    static func counts() -> (started: Int, aborted: Int) {
        lock.withLock { (started, aborted) }
    }

    /// Polls until `condition` holds; the test's time limit bounds the wait.
    static func waitUntil(_ condition: (_ started: Int, _ aborted: Int) -> Bool) async throws {
        while true {
            let now = counts()
            if condition(now.started, now.aborted) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Answers every request still held.
    static func releaseAll() {
        let (waiting, text) = lock.withLock {
            let waiting = held
            held = []
            return (waiting, reply)
        }
        for request in waiting { request.answer(text) }
    }

    // Every request this session makes is held here; none reaches a network.
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.started += 1
            Self.held.append(self)
        }
    }

    override func stopLoading() {
        Self.lock.withLock {
            if let index = Self.held.firstIndex(where: { $0 === self }) {
                Self.held.remove(at: index)
                Self.aborted += 1
            }
        }
    }

    private func answer(_ text: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let escaped = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let body = #"{"choices":[{"message":{"role":"assistant","content":\#(escaped)}}],"usage":{"prompt_tokens":10,"completion_tokens":10}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
