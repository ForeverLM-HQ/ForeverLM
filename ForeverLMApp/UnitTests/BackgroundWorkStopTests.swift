import Foundation
import Testing
@testable import ForeverLM

/// Stop on a model step in the background-work list (`AIInFlightCalls`): the
/// step's calls in flight end at once and their requests are aborted, and the
/// step is not asked again until the learner resumes it, except for work the
/// learner asks for themselves. Serialized: the tests share one held stub.
/// Each test stops a step label of its own, so calls elsewhere in the suite
/// run are never refused.
@Suite("Stopping a model step", .serialized)
struct BackgroundWorkStopTests {
    private func config(step: String) -> AITaskConfig {
        var config = AITaskConfig(provider: .anthropic, apiKey: "test-key", model: "claude-sonnet-4-6")
        // A label no task has, so no backup model is read from this Mac's settings.
        config.taskLabel = step
        return config
    }

    private func ask(_ service: AIService, _ config: AITaskConfig, _ question: String) -> Task<String, Error> {
        Task {
            try await service.call(config: config, system: "Answer in one sentence.", user: question, maxTokens: 64)
        }
    }

    @Test("Stop ends the step's call in flight, aborts its request, and refuses the next until resumed", .timeLimit(.minutes(1)))
    func stopEndsAndHoldsTheStep() async throws {
        let step = "stop_test_\(UUID().uuidString.prefix(8).lowercased())"
        defer { AIInFlightCalls.shared.resume(step: step) }
        StepStopHeldURLProtocol.reset(reply: "Protons leak back through the membrane.")
        let service = AIService(session: StepStopHeldURLProtocol.mockSession())
        let config = config(step: step)

        let running = ask(service, config, "Why does the membrane potential fall?")
        try await StepStopHeldURLProtocol.waitUntil { started, _ in started == 1 }
        #expect(AIInFlightCalls.shared.snapshot.contains { $0.step == step })

        #expect(AIInFlightCalls.shared.stop(step: step) == 1)
        let result = await running.result
        guard case .failure(let error) = result, let stopped = error as? AIStepStoppedError else {
            Issue.record("expected the call to end as stopped, got \(result)")
            return
        }
        #expect(AITransientErrorClassifier.isCancellation(stopped))
        #expect(stopped.step == AIInFlightCalls.stepName(step))
        // Nobody reads the reply any more, so the request is aborted too.
        try await StepStopHeldURLProtocol.waitUntil { _, aborted in aborted == 1 }
        #expect(!AIInFlightCalls.shared.snapshot.contains { $0.step == step })
        #expect(AIInFlightCalls.shared.stoppedSteps.contains { $0.step == step })

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
        AIInFlightCalls.shared.resume(step: step)
        #expect(!AIInFlightCalls.shared.stoppedSteps.contains { $0.step == step })
        let resumed = ask(service, config, "Where is the proton gradient kept?")
        try await StepStopHeldURLProtocol.waitUntil { started, _ in started == 3 }
        StepStopHeldURLProtocol.releaseAll()
        #expect(try await resumed.value == "Protons leak back through the membrane.")
    }

    @Test("A stop that lands before the call's cancel handle is attached cancels it on attach")
    func stopBeforeAttachCancelsAtOnce() throws {
        let step = "stop_test_\(UUID().uuidString.prefix(8).lowercased())"
        defer { AIInFlightCalls.shared.resume(step: step) }
        let id = try AIInFlightCalls.shared.begin(taskLabel: step, sourceTitle: "Bioenergetics 4", subjectID: "paper-1")
        #expect(AIInFlightCalls.shared.stop(step: step) == 0, "nothing to cancel yet")
        let cancelled = Flag()
        AIInFlightCalls.shared.attach(id) { cancelled.set() }
        #expect(cancelled.isSet)
        #expect(AIInFlightCalls.shared.end(id), "the call reports that it was stopped")
    }

    @Test("Stopping one step leaves other steps running")
    func stopIsPerStep() throws {
        let stopped = "stop_test_\(UUID().uuidString.prefix(8).lowercased())"
        let other = "stop_test_\(UUID().uuidString.prefix(8).lowercased())"
        defer { AIInFlightCalls.shared.resume(step: stopped) }
        let id = try AIInFlightCalls.shared.begin(taskLabel: other, sourceTitle: nil, subjectID: nil)
        let cancelled = Flag()
        AIInFlightCalls.shared.attach(id) { cancelled.set() }
        AIInFlightCalls.shared.stop(step: stopped)
        #expect(!cancelled.isSet)
        #expect(!AIInFlightCalls.shared.end(id))
        #expect(throws: AIStepStoppedError.self) {
            try AIInFlightCalls.shared.begin(taskLabel: stopped, sourceTitle: nil, subjectID: nil)
        }
    }

    @Test("A stopped step reads as a cancellation, typed or flattened into a message, and ends the backup chain")
    func stoppedReadsAsCancellation() {
        let error = AIStepStoppedError(step: "Text-to-Speech Preparation")
        #expect(AITransientErrorClassifier.isCancellation(error))
        #expect(AITransientErrorClassifier.shouldRetryAutomatically(error))
        #expect(!AIBackupModels.shouldTryBackup(after: error))
        let flattened = "Could not prepare this paper for reading aloud: \(error.localizedDescription)"
        #expect(AITransientErrorClassifier.isCancellationMessage(flattened))
        #expect(AITransientErrorClassifier.isCancellation(AIError.apiError(flattened)))
        #expect(error.localizedDescription.hasPrefix("You stopped Text-to-Speech Preparation."))
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
